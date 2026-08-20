//! `prepare`'s progress observer — the build-time counterpart of
//! `SimulateOptions::progress`.
//!
//! A document with no ODEs never reaches `simulate`, so nothing in the solver's
//! observer helps it: a dispatched static evaluation of the InMAP ISRM is a
//! black box for eight to fifteen minutes, with no progress, no cancel, and no
//! way to enforce a resource cap short of killing the process. These tests pin
//! the three properties that make the observer worth having:
//!
//! 1. it fires in EVERY phase and names the item each report is about, so a
//!    stopping point is attributable;
//! 2. it fires *inside* the two phases that dominate a large build — one report
//!    per observed, and one per request of the gated fetch, which
//!    `gated_fetch_batch` subdivides;
//! 3. attaching it changes nothing: `Flow::Continue` throughout, batched or
//!    not, produces bit-identical fields.
//!
//! The document is the committed L1 pushdown fixture — the 9-cell isrm-shaped
//! model that exercises the gated pre-sliced fetch and the whole observed graph
//! with mock providers and no network.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use ndarray::{ArrayD, IxDyn};
use serde_json::Value;

use earthsci_ast::prepare::{
    AxisSel, Flow, PrepareError, PrepareOptions, PreparePhase, PrepareProgress, PrepareProvider,
    Prepared, prepare,
};

// ---- Lambert conformal conic (unit sphere), to place points inside cells ----

struct Lcc {
    n: f64,
    rf: f64,
    rho0: f64,
    lam0: f64,
}

fn lcc_consts(lat1: f64, lat2: f64, lat0: f64, lon0: f64) -> Lcc {
    let (p1, p2, p0, l0) = (
        lat1.to_radians(),
        lat2.to_radians(),
        lat0.to_radians(),
        lon0.to_radians(),
    );
    let qp = std::f64::consts::FRAC_PI_4;
    let n = (p1.cos() / p2.cos()).ln() / ((qp + p2 / 2.0).tan() / (qp + p1 / 2.0).tan()).ln();
    let rf = p1.cos() * (qp + p1 / 2.0).tan().powf(n) / n;
    let rho0 = rf / (qp + p0 / 2.0).tan().powf(n);
    Lcc {
        n,
        rf,
        rho0,
        lam0: l0,
    }
}

fn lcc_inv(x: f64, y: f64, c: &Lcc) -> (f64, f64) {
    let rho = c.n.signum() * (x * x + (c.rho0 - y) * (c.rho0 - y)).sqrt();
    let theta = x.atan2(c.rho0 - y);
    let lon = (c.lam0 + theta / c.n).to_degrees();
    let lat =
        (2.0 * (c.rf / rho).powf(1.0 / c.n).atan() - std::f64::consts::FRAC_PI_2).to_degrees();
    (lon, lat)
}

// ---- provider mocks ---------------------------------------------------------

struct MockConst(Vec<f64>);

impl PrepareProvider for MockConst {
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError> {
        Ok(ArrayD::from_shape_vec(IxDyn(&[self.0.len()]), self.0.clone()).unwrap())
    }
}

struct MockGated {
    full: ArrayD<f64>, // native [layer, src, rcv]
    calls: Rc<RefCell<Vec<Vec<AxisSel>>>>,
}

impl PrepareProvider for MockGated {
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError> {
        panic!("the gated mock must never be fetched wholesale");
    }

    fn supports_selection(&self) -> bool {
        true
    }

    fn sample_with_selection(
        &mut self,
        selection: &[AxisSel],
    ) -> Result<ArrayD<f64>, PrepareError> {
        self.calls.borrow_mut().push(selection.to_vec());
        let mut arr = self.full.clone();
        for (i, ax) in selection.iter().enumerate() {
            if let AxisSel::Indices(idx) = ax {
                arr = arr.select(ndarray::Axis(i), idx);
            }
        }
        Ok(arr)
    }
}

// ---- one recorded report ----------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
struct Event {
    phase: PreparePhase,
    done: usize,
    total: Option<usize>,
    item: String,
}

type Log = Arc<Mutex<Vec<Event>>>;

/// An observer that records everything and never cancels.
fn recorder(log: &Log) -> earthsci_ast::prepare::PrepareProgressFn {
    let log = log.clone();
    Arc::new(move |p: &PrepareProgress<'_>| {
        log.lock().unwrap().push(Event {
            phase: p.phase,
            done: p.done,
            total: p.total,
            item: p.item.to_string(),
        });
        Flow::Continue
    })
}

// ---- the fixture ------------------------------------------------------------

const GRID: usize = 9;
const N_RCV: usize = 4;
const N_REC: usize = 5;
const N_LAYER: usize = 3;
const LVARS: [&str; 5] = ["SOA", "pNO3", "pNH4", "pSO4", "PrimaryPM25"];
/// The engine derives this support set from the emissions; it is what the gated
/// fetch selects along the source axis, and what a batch subdivides.
const MEMBERS0: [usize; 4] = [0, 1, 3, 8];

/// Build the fixture's providers and const arrays, and run `prepare`.
///
/// Returns the prepared artifact plus, per gated variable, the selections its
/// provider actually saw — so a test can check both what came out and how it
/// was asked for.
#[allow(clippy::type_complexity)]
fn run(
    opts_from: impl FnOnce(&mut PrepareOptions),
) -> (
    Result<Prepared, PrepareError>,
    HashMap<String, Vec<Vec<AxisSel>>>,
) {
    let mut w = vec![0.0; GRID];
    let mut sv = vec![0.0; GRID];
    let mut ev = vec![0.0; GRID];
    let mut nv = vec![0.0; GRID];
    for row in 1..=3usize {
        for col in 1..=3usize {
            let k = (row - 1) * 3 + col - 1;
            w[k] = (col - 1) as f64 * 2.0;
            ev[k] = col as f64 * 2.0;
            sv[k] = (row - 1) as f64 * 2.0;
            nv[k] = row as f64 * 2.0;
        }
    }

    let c = lcc_consts(33.0, 45.0, 40.0, -97.0);
    let xt = [1.0, 3.0, 1.0, 5.0, 1.5];
    let yt = [1.0, 1.0, 3.0, 5.0, 1.5];
    let (mut lon, mut lat) = (Vec::new(), Vec::new());
    for r in 0..N_REC {
        let (lo, la) = lcc_inv(xt[r], yt[r], &c);
        lon.push(lo);
        lat.push(la);
    }

    let emis_annual = [10.0, 20.0, 30.0, 40.0, 50.0];
    let is_voc = [1.0, 0.0, 1.0, 0.0, 0.0];
    let is_nox = [0.0, 1.0, 0.0, 0.0, 0.0];
    let is_nh3 = [0.0, 0.0, 0.0, 0.0, 1.0];
    let is_sox = [0.0, 0.0, 0.0, 0.0, 0.0];
    let is_pm25 = [0.0, 0.0, 0.0, 1.0, 0.0];
    let total_pop = [100.0, 200.0, 300.0, 400.0];
    let mortality = [500.0, 600.0, 700.0, 800.0];
    let base: HashMap<&str, f64> = [
        ("SOA", 1.0),
        ("pNO3", 2.0),
        ("pNH4", 3.0),
        ("pSO4", 4.0),
        ("PrimaryPM25", 5.0),
    ]
    .into_iter()
    .collect();

    let arr1 = |v: &[f64]| ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap();

    let mut providers: Vec<(String, Box<dyn PrepareProvider>)> = vec![
        (
            "ISRM.TotalPop".into(),
            Box::new(MockConst(total_pop.to_vec())),
        ),
        (
            "ISRM.MortalityRate".into(),
            Box::new(MockConst(mortality.to_vec())),
        ),
        ("ISRM.emis_lon".into(), Box::new(MockConst(lon))),
        ("ISRM.emis_lat".into(), Box::new(MockConst(lat))),
        (
            "ISRM.emis_annual".into(),
            Box::new(MockConst(emis_annual.to_vec())),
        ),
        ("ISRM.is_VOC".into(), Box::new(MockConst(is_voc.to_vec()))),
        ("ISRM.is_NOx".into(), Box::new(MockConst(is_nox.to_vec()))),
        ("ISRM.is_NH3".into(), Box::new(MockConst(is_nh3.to_vec()))),
        ("ISRM.is_SOx".into(), Box::new(MockConst(is_sox.to_vec()))),
        (
            "ISRM.is_PM25".into(),
            Box::new(MockConst(is_pm25.to_vec())),
        ),
    ];
    let mut call_logs: HashMap<String, Rc<RefCell<Vec<Vec<AxisSel>>>>> = HashMap::new();
    for v in LVARS {
        let mut a = ArrayD::zeros(IxDyn(&[N_LAYER, GRID, N_RCV]));
        for l in 0..N_LAYER {
            for s in 0..GRID {
                for r in 0..N_RCV {
                    a[[l, s, r]] = l as f64 * 1.0e6
                        + base[v] * 1000.0
                        + (s + 1) as f64 * 10.0
                        + (r + 1) as f64;
                }
            }
        }
        let calls = Rc::new(RefCell::new(Vec::new()));
        call_logs.insert(format!("ISRM.SR_{v}"), calls.clone());
        providers.push((
            format!("ISRM.SR_{v}"),
            Box::new(MockGated { full: a, calls }),
        ));
    }

    let ca: HashMap<String, ArrayD<f64>> = [
        ("src_W".to_string(), arr1(&w)),
        ("src_S".to_string(), arr1(&sv)),
        ("src_E".to_string(), arr1(&ev)),
        ("src_N".to_string(), arr1(&nv)),
    ]
    .into_iter()
    .collect();

    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/pushdown/fixtures/pushdown_l1.esm");
    let doc: Value =
        serde_json::from_str(&std::fs::read_to_string(&fixture).expect("read pushdown_l1.esm"))
            .expect("parse pushdown_l1.esm");

    let mut opts = PrepareOptions {
        model_name: Some("ISRM".to_string()),
        pushdown_rewrite: true,
        ..Default::default()
    };
    opts_from(&mut opts);
    let prep = prepare(&doc, ca, providers, &opts);

    let seen = call_logs
        .into_iter()
        .map(|(k, v)| (k, v.borrow().clone()))
        .collect();
    (prep, seen)
}

fn fields_of(p: &Prepared) -> Vec<(String, Vec<u64>)> {
    let mut out: Vec<(String, Vec<u64>)> = p
        .fields
        .iter()
        // Bits, not floats: "the observer changed nothing" has to mean
        // bit-identical, or a batched fetch could reassociate a sum and pass.
        .map(|(k, v)| (k.clone(), v.iter().map(|x| x.to_bits()).collect()))
        .collect();
    out.sort();
    out
}

fn count(log: &[Event], phase: PreparePhase) -> usize {
    log.iter().filter(|e| e.phase == phase).count()
}

// ============================================================================

/// Every phase reports, and the two phases that dominate a real build report
/// per unit of work rather than once.
#[test]
fn the_observer_fires_in_every_phase_and_names_each_item() {
    let log: Log = Arc::new(Mutex::new(Vec::new()));
    let (prep, _) = run(|o| o.progress = Some(recorder(&log)));
    prep.expect("prepare");
    let log = log.lock().unwrap().clone();

    // 1. No phase is silent. A phase nobody hears from is a phase a host cannot
    //    show, cancel in, or bill against.
    for phase in PreparePhase::ALL {
        assert!(
            log.iter().any(|e| e.phase == phase),
            "phase {phase:?} never reported; got {log:#?}"
        );
    }

    // 2. `Observeds` reports PER OBSERVED, not once. The fixture's graph has
    //    eleven of them; two (the LCC projections X/Y) are materialized by the
    //    coordinate pre-pass and reported there instead.
    let n_obs = count(&log, PreparePhase::Observeds);
    assert!(
        n_obs >= 8,
        "expected a report per observed, got {n_obs}: {:#?}",
        log.iter()
            .filter(|e| e.phase == PreparePhase::Observeds)
            .collect::<Vec<_>>()
    );
    let named: Vec<&str> = log
        .iter()
        .filter(|e| e.phase == PreparePhase::Observeds && !e.item.is_empty())
        .map(|e| e.item.as_str())
        .collect();
    for want in ["E_VOC", "conc_SOA", "TotalPM25", "deathsK", "deathsL"] {
        assert!(named.contains(&want), "no report named {want}: {named:?}");
    }

    // 3. `GatedFetch` reports PER REQUEST — one per gated provider here, since
    //    this run did not ask for batching — and names which one.
    let gated: Vec<&Event> = log
        .iter()
        .filter(|e| e.phase == PreparePhase::GatedFetch && !e.item.is_empty())
        .collect();
    assert_eq!(gated.len(), LVARS.len(), "{gated:#?}");
    for v in LVARS {
        assert!(gated.iter().any(|e| e.item == format!("ISRM.SR_{v}")));
    }

    // 4. The counters are usable: monotone within a phase, and ending at the
    //    total, so `fraction()` reaches 1.0 rather than stopping at (n-1)/n.
    for phase in PreparePhase::ALL {
        let evs: Vec<&Event> = log.iter().filter(|e| e.phase == phase).collect();
        let mut last = 0;
        for e in &evs {
            assert!(
                e.done >= last,
                "{phase:?}: {} went back from {last}",
                e.done
            );
            last = e.done;
        }
        if let Some(last_ev) = evs.last()
            && let Some(t) = last_ev.total
        {
            assert_eq!(last_ev.done, t, "{phase:?} never reached its total");
            // A phase with nothing to do reports 0 of 0; `fraction()` answers
            // 0.0 there rather than dividing by zero.
            assert_eq!(last_ev.fraction_check(), if t > 0 { 1.0 } else { 0.0 });
        }
    }
}

impl Event {
    fn fraction_check(&self) -> f64 {
        PrepareProgress {
            phase: self.phase,
            done: self.done,
            total: self.total,
            item: &self.item,
        }
        .fraction()
    }
}

/// `gated_fetch_batch` turns the single longest thing the build does into as
/// many reports as the host asks for — and the answer does not move.
#[test]
fn a_batched_gated_fetch_reports_per_batch_and_is_bit_identical() {
    let (plain, plain_calls) = run(|_| {});
    let plain = plain.expect("prepare (unbatched)");

    let log: Log = Arc::new(Mutex::new(Vec::new()));
    let (batched, batched_calls) = run(|o| {
        o.progress = Some(recorder(&log));
        o.gated_fetch_batch = Some(1); // one source cell per request
    });
    let batched = batched.expect("prepare (batched)");
    let log = log.lock().unwrap().clone();

    // The result is the same, to the bit.
    assert_eq!(fields_of(&plain), fields_of(&batched));
    assert_eq!(plain.members, batched.members);

    // The unbatched run made ONE request per gated provider, selecting the
    // whole support set; the batched run made one per member, in order.
    for v in LVARS {
        let key = format!("ISRM.SR_{v}");
        assert_eq!(plain_calls[&key].len(), 1, "{key} unbatched");
        assert_eq!(
            plain_calls[&key][0][1],
            AxisSel::Indices(MEMBERS0.to_vec()),
            "{key} unbatched selection"
        );

        let runs = &batched_calls[&key];
        assert_eq!(runs.len(), MEMBERS0.len(), "{key} batched");
        for (i, sel) in runs.iter().enumerate() {
            // Only the gated axis is subdivided: the fixed layer and the full
            // receptor axis are untouched, which is why the pieces reassemble.
            assert_eq!(sel[0], AxisSel::Indices(vec![0]), "{key} batch {i} layer");
            assert_eq!(
                sel[1],
                AxisSel::Indices(vec![MEMBERS0[i]]),
                "{key} batch {i}"
            );
            assert_eq!(sel[2], AxisSel::All, "{key} batch {i} receptors");
        }
    }

    // And the observer saw every one of them: 5 providers x 4 members, versus
    // the 5 reports the same phase would have produced unbatched.
    let n_gated = count(&log, PreparePhase::GatedFetch);
    assert_eq!(
        n_gated,
        LVARS.len() * MEMBERS0.len() + 1, // + the phase-complete report
        "gated fetch reports: {:#?}",
        log.iter()
            .filter(|e| e.phase == PreparePhase::GatedFetch)
            .collect::<Vec<_>>()
    );
    // The running count spans the whole phase rather than restarting per
    // provider, so a host can drive one bar across all of them.
    let totals: Vec<Option<usize>> = log
        .iter()
        .filter(|e| e.phase == PreparePhase::GatedFetch)
        .map(|e| e.total)
        .collect();
    assert!(
        totals
            .iter()
            .all(|t| *t == Some(LVARS.len() * MEMBERS0.len()))
    );
}

/// `Flow::Cancel` stops the build, and the error says where — a phase and an
/// item, not "somewhere in the last eight minutes".
#[test]
fn cancelling_stops_at_a_named_point_and_is_distinguishable_from_a_failure() {
    // Cancel on the third request of the gated fetch. With one member per
    // request that is mid-provider: the point is that the fetch itself is
    // interruptible, which a between-phases callback could not do.
    let seen: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let (res, calls) = run(|o| {
        let seen = seen.clone();
        o.gated_fetch_batch = Some(1);
        o.progress = Some(Arc::new(move |p: &PrepareProgress<'_>| {
            if p.phase != PreparePhase::GatedFetch || p.item.is_empty() {
                return Flow::Continue;
            }
            let mut s = seen.lock().unwrap();
            s.push(p.item.to_string());
            if s.len() == 3 {
                Flow::Cancel
            } else {
                Flow::Continue
            }
        }));
    });

    let Err(e) = res else {
        panic!("the build should have been cancelled")
    };
    assert!(e.is_cancelled(), "not recognised as a cancel: {e}");
    assert!(
        e.0.contains("the gated fetch"),
        "the message does not name the phase: {e}"
    );
    assert!(
        e.0.contains("ISRM.SR_"),
        "the message does not name the item: {e}"
    );
    assert!(
        e.0.contains("(3 of 20)"),
        "the message does not locate the request: {e}"
    );

    // The cancel landed BEFORE the request it reported, so the fetch it would
    // have issued never happened: two requests in, not three.
    let issued: usize = calls.values().map(|v| v.len()).sum();
    assert_eq!(
        issued, 2,
        "a cancelled request was issued anyway: {calls:#?}"
    );

    // A genuine failure is NOT mistaken for a cancel.
    let (res, _) = run(|o| o.model_name = Some("NoSuchModel".into()));
    let Err(e) = res else {
        panic!("prepare accepted an unknown model")
    };
    assert!(!e.is_cancelled(), "a real failure read as a cancel: {e}");
}

/// A `Flow::Continue` observer is an observer, not a mutation: the artifact is
/// identical to the one an unobserved build produces.
#[test]
fn observing_does_not_change_the_result() {
    let (plain, _) = run(|_| {});
    let log: Log = Arc::new(Mutex::new(Vec::new()));
    let (watched, _) = run(|o| o.progress = Some(recorder(&log)));
    let (plain, watched) = (plain.expect("plain"), watched.expect("watched"));

    assert_eq!(fields_of(&plain), fields_of(&watched));
    assert_eq!(plain.members, watched.members);
    assert_eq!(plain.extents, watched.extents);
    assert_eq!(plain.gated_provider_keys, watched.gated_provider_keys);
    assert!(!log.lock().unwrap().is_empty(), "the observer never fired");
}

/// `PrepareOptions` still prints. It carries a trait object now, so `Debug` is
/// hand-written and could silently lose a field.
#[test]
fn prepare_options_still_debug_prints() {
    let log: Log = Arc::new(Mutex::new(Vec::new()));
    let opts = PrepareOptions {
        pushdown_rewrite: true,
        gated_fetch_batch: Some(64),
        progress: Some(recorder(&log)),
        ..Default::default()
    };
    let s = format!("{opts:?}");
    for want in [
        "model_name",
        "metaparameters",
        "base_path",
        "pushdown_rewrite",
        "parameters",
        "verbose",
        "<observer>",
        "gated_fetch_batch: Some(64)",
    ] {
        assert!(s.contains(want), "Debug lost {want}: {s}");
    }
}
