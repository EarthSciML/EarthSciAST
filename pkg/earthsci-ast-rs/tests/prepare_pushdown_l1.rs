//! PUBLIC-SURFACE projection pushdown at L1 — the Rust port of the Julia
//! `prepare_pushdown_record_gate_test.jl` (whose exact document is the
//! committed conformance fixture `tests/conformance/pushdown/fixtures/
//! pushdown_l1.esm`, frozen numerics included).
//!
//! Drives the clean 9-cell isrm-shaped document through the PUBLIC `prepare`
//! surface with `pushdown_rewrite: true` and mock providers:
//!
//! * the rewrite runs engine-side; the SR gates derive from the rewrite's OWN
//!   record + the document coupling (no hand-authored gate);
//! * the in-model LCC projection observeds `X`/`Y` are evaluated by the
//!   build-time coordinate path ahead of value-invention;
//! * the gated mocks must be fetched PRE-SLICED (selection = fixed layer 0 +
//!   the record-derived members + all receptors), never wholesale;
//! * every result is read back through the prepared document's own graph and
//!   compared against the plain-Rust STEP-0 oracle.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;
use std::rc::Rc;

use ndarray::{ArrayD, IxDyn};
use serde_json::Value;

use earthsci_ast::{AxisSel, PrepareError, PrepareProvider};
use earthsci_ast::{ProblemOptions, esm_problem, observed_field};

// ---- Lambert conformal conic (unit sphere), plain-Rust ORACLE --------------

struct Lcc {
    n: f64,
    rf: f64,
    rho0: f64,
    lam0: f64,
}

fn d2r(d: f64) -> f64 {
    d.to_radians()
}

fn lcc_consts(lat1: f64, lat2: f64, lat0: f64, lon0: f64) -> Lcc {
    let (p1, p2, p0, l0) = (d2r(lat1), d2r(lat2), d2r(lat0), d2r(lon0));
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

fn lcc_fwd(lon_deg: f64, lat_deg: f64, c: &Lcc) -> (f64, f64) {
    let qp = std::f64::consts::FRAC_PI_4;
    let rho = c.rf / (qp + d2r(lat_deg) / 2.0).tan().powf(c.n);
    let theta = c.n * (d2r(lon_deg) - c.lam0);
    (rho * theta.sin(), c.rho0 - rho * theta.cos())
}

fn lcc_inv(x: f64, y: f64, c: &Lcc) -> (f64, f64) {
    let rho = c.n.signum() * (x * x + (c.rho0 - y) * (c.rho0 - y)).sqrt();
    let theta = x.atan2(c.rho0 - y);
    let lon = (c.lam0 + theta / c.n).to_degrees();
    let lat =
        (2.0 * (c.rf / rho).powf(1.0 / c.n).atan() - std::f64::consts::FRAC_PI_2).to_degrees();
    (lon, lat)
}

// ---- provider mocks — NO hand-authored gate anywhere -----------------------

struct MockConst(Vec<f64>);

impl PrepareProvider for MockConst {
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError> {
        Ok(ArrayD::from_shape_vec(IxDyn(&[self.0.len()]), self.0.clone()).unwrap())
    }
}

#[derive(Debug, PartialEq)]
enum Call {
    Wholesale,
    Selection(Vec<AxisSel>),
}

struct MockGated {
    full: ArrayD<f64>, // native [layer, src, rcv]
    calls: Rc<RefCell<Vec<Call>>>,
}

impl PrepareProvider for MockGated {
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError> {
        self.calls.borrow_mut().push(Call::Wholesale);
        Ok(self.full.clone())
    }

    fn supports_selection(&self) -> bool {
        true
    }

    fn sample_with_selection(
        &mut self,
        selection: &[AxisSel],
    ) -> Result<ArrayD<f64>, PrepareError> {
        self.calls
            .borrow_mut()
            .push(Call::Selection(selection.to_vec()));
        let mut arr = self.full.clone();
        for (i, ax) in selection.iter().enumerate() {
            if let AxisSel::Indices(idx) = ax {
                arr = arr.select(ndarray::Axis(i), idx);
            }
        }
        Ok(arr)
    }
}

fn arr1(v: &[f64]) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
}

fn assert_close(name: &str, got: &ArrayD<f64>, want: &[f64]) {
    let g: Vec<f64> = got.iter().copied().collect();
    assert_eq!(
        g.len(),
        want.len(),
        "{name}: length {} != {}",
        g.len(),
        want.len()
    );
    for (i, (a, b)) in g.iter().zip(want).enumerate() {
        // Julia-isapprox semantics: exact equality (covers ±inf — the L1
        // numerics deliberately overflow the deaths exponent) or rel-tol.
        if a == b {
            continue;
        }
        let tol = 1e-9 * b.abs().max(1.0);
        assert!((a - b).abs() <= tol, "{name}[{i}]: {a} != {b} (tol {tol})");
    }
}

#[test]
fn prepare_pushdown_l1_matches_the_step0_oracle_with_presliced_gated_fetch() {
    l1_against_the_oracle(false);
}

/// The same document beside a second model that has nothing to rewrite, with
/// no model selected: the build is the whole document, and the rewrite still
/// runs on the model whose pattern matches rather than being skipped. Every
/// name is then spelled `Model.var`.
#[test]
fn prepare_pushdown_l1_rewrites_its_model_in_a_whole_document_build() {
    l1_against_the_oracle(true);
}

fn l1_against_the_oracle(with_bystander: bool) {
    let q = |n: &str| {
        if with_bystander {
            format!("ISRM.{n}")
        } else {
            n.to_string()
        }
    };
    const GRID: usize = 9;
    const N_RCV: usize = 4;
    const N_REC: usize = 5;
    const N_LAYER: usize = 3;

    // ---- fixture geometry (identical to the Julia test) ---------------------
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
    let xtarget = [1.0, 3.0, 1.0, 5.0, 1.5];
    let ytarget = [1.0, 1.0, 3.0, 5.0, 1.5];
    let mut lon = Vec::new();
    let mut lat = Vec::new();
    for r in 0..N_REC {
        let (lo, la) = lcc_inv(xtarget[r], ytarget[r], &c);
        lon.push(lo);
        lat.push(la);
    }
    let projx: Vec<f64> = (0..N_REC).map(|r| lcc_fwd(lon[r], lat[r], &c).0).collect();
    let projy: Vec<f64> = (0..N_REC).map(|r| lcc_fwd(lon[r], lat[r], &c).1).collect();
    for r in 0..N_REC {
        assert!((projx[r] - xtarget[r]).abs() < 1e-9 && (projy[r] - ytarget[r]).abs() < 1e-9);
    }

    let emis_annual = [10.0, 20.0, 30.0, 40.0, 50.0];
    let is_voc = [1.0, 0.0, 1.0, 0.0, 0.0];
    let is_nox = [0.0, 1.0, 0.0, 0.0, 0.0];
    let is_nh3 = [0.0, 0.0, 0.0, 0.0, 1.0];
    let is_sox = [0.0, 0.0, 0.0, 0.0, 0.0];
    let is_pm25 = [0.0, 0.0, 0.0, 1.0, 0.0];
    let total_pop = [100.0, 200.0, 300.0, 400.0];
    let mortality = [500.0, 600.0, 700.0, 800.0];
    const FACT: f64 = 28766.639;
    const POP_SCALE: f64 = 1.0465819687408728;
    const MORT_SCALE: f64 = 1.025229357798165;
    const RR_K: f64 = 1.06;
    const RR_L: f64 = 1.14;
    const LVARS: [&str; 5] = ["SOA", "pNO3", "pNH4", "pSO4", "PrimaryPM25"];
    let base: HashMap<&str, f64> = [
        ("SOA", 1.0),
        ("pNO3", 2.0),
        ("pNH4", 3.0),
        ("pSO4", 4.0),
        ("PrimaryPM25", 5.0),
    ]
    .into_iter()
    .collect();
    let mut full_sr: HashMap<&str, ArrayD<f64>> = HashMap::new();
    for name in LVARS {
        let mut a = ArrayD::zeros(IxDyn(&[N_LAYER, GRID, N_RCV]));
        for l in 0..N_LAYER {
            for s in 0..GRID {
                for r in 0..N_RCV {
                    a[[l, s, r]] = l as f64 * 1.0e6
                        + base[name] * 1000.0
                        + (s + 1) as f64 * 10.0
                        + (r + 1) as f64;
                }
            }
        }
        full_sr.insert(name, a);
    }

    // ---- plain-Rust STEP-0 ORACLE -------------------------------------------
    let cont = |c0: usize, r: usize| {
        w[c0] <= projx[r] && projx[r] < ev[c0] && sv[c0] <= projy[r] && projy[r] < nv[c0]
    };
    let mut members: Vec<usize> = (0..GRID)
        .filter(|&c0| (0..N_REC).any(|r| cont(c0, r)))
        .collect();
    members.sort_unstable();
    assert_eq!(members, vec![0, 1, 3, 8]); // 1-based [1, 2, 4, 9]
    let np = members.len();
    let pathway_is: HashMap<&str, &[f64; 5]> = [
        ("SOA", &is_voc),
        ("pNO3", &is_nox),
        ("pNH4", &is_nh3),
        ("pSO4", &is_sox),
        ("PrimaryPM25", &is_pm25),
    ]
    .into_iter()
    .collect();
    let oracle_e = |is_p: &[f64; 5]| -> Vec<f64> {
        members
            .iter()
            .map(|&c0| {
                (0..N_REC)
                    .map(|r| if cont(c0, r) { 1.0 } else { 0.0 } * emis_annual[r] * is_p[r])
                    .sum()
            })
            .collect()
    };
    let oracle_conc = |name: &str| -> Vec<f64> {
        let ep = oracle_e(pathway_is[name]);
        (0..N_RCV)
            .map(|rcv| {
                (0..np)
                    .map(|ci| full_sr[name][[0, members[ci], rcv]] * ep[ci])
                    .sum()
            })
            .collect()
    };
    let oracle_total: Vec<f64> = (0..N_RCV)
        .map(|rcv| FACT * LVARS.iter().map(|n| oracle_conc(n)[rcv]).sum::<f64>())
        .collect();
    let oracle_deaths = |rr: f64| -> Vec<f64> {
        (0..N_RCV)
            .map(|rcv| {
                ((rr.ln() / 10.0 * oracle_total[rcv]).exp() - 1.0)
                    * total_pop[rcv]
                    * POP_SCALE
                    * mortality[rcv]
                    * MORT_SCALE
                    / 100000.0
            })
            .collect()
    };

    // ---- the committed fixture IS the authored document ---------------------
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/pushdown/fixtures/pushdown_l1.esm");
    let mut doc: Value =
        serde_json::from_str(&std::fs::read_to_string(&fixture).expect("read pushdown_l1.esm"))
            .expect("parse pushdown_l1.esm");
    if with_bystander {
        doc["models"]["Bystander"] = serde_json::json!({
            "variables": {"two": {"type": "unknown", "units": "1"}},
            "equations": [{"lhs": "two", "rhs": {"op": "+", "args": [1.0, 1.0]}}]
        });
    }

    // ---- providers: mocks only, keyed by the document's loader variables ----
    let mut providers: Vec<(String, Box<dyn PrepareProvider>)> = vec![
        (
            "ISRM.TotalPop".into(),
            Box::new(MockConst(total_pop.to_vec())),
        ),
        (
            "ISRM.MortalityRate".into(),
            Box::new(MockConst(mortality.to_vec())),
        ),
        ("ISRM.emis_lon".into(), Box::new(MockConst(lon.clone()))),
        ("ISRM.emis_lat".into(), Box::new(MockConst(lat.clone()))),
        (
            "ISRM.emis_annual".into(),
            Box::new(MockConst(emis_annual.to_vec())),
        ),
        ("ISRM.is_VOC".into(), Box::new(MockConst(is_voc.to_vec()))),
        ("ISRM.is_NOx".into(), Box::new(MockConst(is_nox.to_vec()))),
        ("ISRM.is_NH3".into(), Box::new(MockConst(is_nh3.to_vec()))),
        ("ISRM.is_SOx".into(), Box::new(MockConst(is_sox.to_vec()))),
        ("ISRM.is_PM25".into(), Box::new(MockConst(is_pm25.to_vec()))),
    ];
    let mut call_logs: HashMap<String, Rc<RefCell<Vec<Call>>>> = HashMap::new();
    for v in LVARS {
        let calls = Rc::new(RefCell::new(Vec::new()));
        call_logs.insert(v.to_string(), calls.clone());
        providers.push((
            format!("ISRM.SR_{v}"),
            Box::new(MockGated {
                full: full_sr[v].clone(),
                calls,
            }),
        ));
    }

    // src rects ride const_arrays under their BARE authored names.
    let ca: HashMap<String, ArrayD<f64>> = [
        ("src_W".to_string(), arr1(&w)),
        ("src_S".to_string(), arr1(&sv)),
        ("src_E".to_string(), arr1(&ev)),
        ("src_N".to_string(), arr1(&nv)),
    ]
    .into_iter()
    .collect();

    let opts = ProblemOptions {
        // The pipeline's per-cell walk is refused by a strict native (#484), so
        // these semantics are checked on the reference evaluator.
        compiler: Some(earthsci_ast::Compiler::Interpreter),
        model_name: (!with_bystander).then(|| "ISRM".to_string()),
        pushdown_rewrite: true,
        ..Default::default()
    };
    let prep = esm_problem(
        &doc,
        (0.0, 0.0),
        ProblemOptions {
            // The pipeline's per-cell walk is refused by a strict native (#484), so
            // these semantics are checked on the reference evaluator.
            compiler: Some(earthsci_ast::Compiler::Interpreter),
            const_arrays: ca,
            build_providers: providers,
            ..opts
        },
    )
    .expect("prepare");

    // ---- the rewrite fired and recorded its own gate ------------------------
    let set = prep.document()["metadata"]["x_esd"]["pushdown"]["gated_select"]["gated_by"]
        .as_str()
        .unwrap();
    assert_eq!(set, "pd_support__src_cells");
    assert_eq!(prep.gated_provider_keys().len(), 5);
    let faq_members = &prep.members()["pd_faq__src_cells"];
    assert_eq!(faq_members, &vec![1i64, 2, 4, 9]);

    // ---- the gated mocks were fetched pre-sliced, never wholesale -----------
    let expect_sel = vec![
        AxisSel::Indices(vec![0]),
        AxisSel::Indices(members.clone()),
        AxisSel::All,
    ];
    for v in LVARS {
        let calls = call_logs[v].borrow();
        assert_eq!(
            calls.len(),
            1,
            "{v}: expected exactly one gated fetch, got {calls:?}"
        );
        match &calls[0] {
            Call::Selection(sel) => assert_eq!(sel, &expect_sel, "{v}: wrong selection"),
            Call::Wholesale => panic!("{v}: fetched WHOLESALE"),
        }
    }

    // ---- results through the prepared document's own graph ------------------
    assert_close(
        "E_VOC",
        &observed_field(&prep, &q("E_VOC")).unwrap(),
        &oracle_e(&is_voc),
    );
    assert_close(
        "E_PM25",
        &observed_field(&prep, &q("E_PM25")).unwrap(),
        &oracle_e(&is_pm25),
    );
    assert_close(
        "conc_SOA",
        &observed_field(&prep, &q("conc_SOA")).unwrap(),
        &oracle_conc("SOA"),
    );
    assert_close(
        "TotalPM25",
        &observed_field(&prep, &q("TotalPM25")).unwrap(),
        &oracle_total,
    );
    assert_close(
        "deathsK",
        &observed_field(&prep, &q("deathsK")).unwrap(),
        &oracle_deaths(RR_K),
    );
    assert_close(
        "deathsL",
        &observed_field(&prep, &q("deathsL")).unwrap(),
        &oracle_deaths(RR_L),
    );
    assert!(observed_field(&prep, "no_such_observed").is_err());
}

/// n=1 pin (cross-language: the Python binding's scalarisation footgun): every
/// emission record lands in ONE grid cell, so the engine-derived support set
/// has exactly one member and the `pd_member_factor__*` feedback vector is a
/// SIZE-1 array. A one-member axis must stay an axis — the generated
/// `index(F, index(mf, c))` gathers, the one-member gated selection, and the
/// full downstream graph must all evaluate. Rust never had the footgun; this
/// keeps it that way.
#[test]
fn prepare_pushdown_l1_single_member_support_set() {
    const GRID: usize = 9;
    const N_RCV: usize = 4;
    const N_REC: usize = 5;
    const N_LAYER: usize = 3;

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

    // All five records inside cell 0 (rect [0,2) × [0,2)).
    let c = lcc_consts(33.0, 45.0, 40.0, -97.0);
    let xtarget = [0.5, 1.0, 1.5, 0.5, 1.2];
    let ytarget = [0.5, 0.5, 1.0, 1.5, 0.8];
    let mut lon = Vec::new();
    let mut lat = Vec::new();
    for r in 0..N_REC {
        let (lo, la) = lcc_inv(xtarget[r], ytarget[r], &c);
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
    const FACT: f64 = 28766.639;
    const POP_SCALE: f64 = 1.0465819687408728;
    const MORT_SCALE: f64 = 1.025229357798165;
    const RR_K: f64 = 1.06;
    const RR_L: f64 = 1.14;
    const LVARS: [&str; 5] = ["SOA", "pNO3", "pNH4", "pSO4", "PrimaryPM25"];
    let base: HashMap<&str, f64> = [
        ("SOA", 1.0),
        ("pNO3", 2.0),
        ("pNH4", 3.0),
        ("pSO4", 4.0),
        ("PrimaryPM25", 5.0),
    ]
    .into_iter()
    .collect();
    let mut full_sr: HashMap<&str, ArrayD<f64>> = HashMap::new();
    for name in LVARS {
        let mut a = ArrayD::zeros(IxDyn(&[N_LAYER, GRID, N_RCV]));
        for l in 0..N_LAYER {
            for s in 0..GRID {
                for r in 0..N_RCV {
                    a[[l, s, r]] = l as f64 * 1.0e6
                        + base[name] * 1000.0
                        + (s + 1) as f64 * 10.0
                        + (r + 1) as f64;
                }
            }
        }
        full_sr.insert(name, a);
    }

    // Oracle with the one-member support set {cell 0}: every record contributes.
    let pathway_is: HashMap<&str, &[f64; 5]> = [
        ("SOA", &is_voc),
        ("pNO3", &is_nox),
        ("pNH4", &is_nh3),
        ("pSO4", &is_sox),
        ("PrimaryPM25", &is_pm25),
    ]
    .into_iter()
    .collect();
    let oracle_e =
        |is_p: &[f64; 5]| -> Vec<f64> { vec![(0..N_REC).map(|r| emis_annual[r] * is_p[r]).sum()] };
    let oracle_conc = |name: &str| -> Vec<f64> {
        let ep = oracle_e(pathway_is[name]);
        (0..N_RCV)
            .map(|rcv| full_sr[name][[0, 0, rcv]] * ep[0])
            .collect()
    };
    let oracle_total: Vec<f64> = (0..N_RCV)
        .map(|rcv| FACT * LVARS.iter().map(|n| oracle_conc(n)[rcv]).sum::<f64>())
        .collect();
    let oracle_deaths = |rr: f64| -> Vec<f64> {
        (0..N_RCV)
            .map(|rcv| {
                ((rr.ln() / 10.0 * oracle_total[rcv]).exp() - 1.0)
                    * total_pop[rcv]
                    * POP_SCALE
                    * mortality[rcv]
                    * MORT_SCALE
                    / 100000.0
            })
            .collect()
    };

    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/pushdown/fixtures/pushdown_l1.esm");
    let doc: Value =
        serde_json::from_str(&std::fs::read_to_string(&fixture).expect("read pushdown_l1.esm"))
            .expect("parse pushdown_l1.esm");

    let mut providers: Vec<(String, Box<dyn PrepareProvider>)> = vec![
        (
            "ISRM.TotalPop".into(),
            Box::new(MockConst(total_pop.to_vec())),
        ),
        (
            "ISRM.MortalityRate".into(),
            Box::new(MockConst(mortality.to_vec())),
        ),
        ("ISRM.emis_lon".into(), Box::new(MockConst(lon.clone()))),
        ("ISRM.emis_lat".into(), Box::new(MockConst(lat.clone()))),
        (
            "ISRM.emis_annual".into(),
            Box::new(MockConst(emis_annual.to_vec())),
        ),
        ("ISRM.is_VOC".into(), Box::new(MockConst(is_voc.to_vec()))),
        ("ISRM.is_NOx".into(), Box::new(MockConst(is_nox.to_vec()))),
        ("ISRM.is_NH3".into(), Box::new(MockConst(is_nh3.to_vec()))),
        ("ISRM.is_SOx".into(), Box::new(MockConst(is_sox.to_vec()))),
        ("ISRM.is_PM25".into(), Box::new(MockConst(is_pm25.to_vec()))),
    ];
    let mut call_logs: HashMap<String, Rc<RefCell<Vec<Call>>>> = HashMap::new();
    for v in LVARS {
        let calls = Rc::new(RefCell::new(Vec::new()));
        call_logs.insert(v.to_string(), calls.clone());
        providers.push((
            format!("ISRM.SR_{v}"),
            Box::new(MockGated {
                full: full_sr[v].clone(),
                calls,
            }),
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

    let opts = ProblemOptions {
        // The pipeline's per-cell walk is refused by a strict native (#484), so
        // these semantics are checked on the reference evaluator.
        compiler: Some(earthsci_ast::Compiler::Interpreter),
        model_name: Some("ISRM".to_string()),
        pushdown_rewrite: true,
        ..Default::default()
    };
    let prep = esm_problem(
        &doc,
        (0.0, 0.0),
        ProblemOptions {
            // The pipeline's per-cell walk is refused by a strict native (#484), so
            // these semantics are checked on the reference evaluator.
            compiler: Some(earthsci_ast::Compiler::Interpreter),
            const_arrays: ca,
            build_providers: providers,
            ..opts
        },
    )
    .expect("prepare with |members| = 1");

    // The engine derived a ONE-member support set…
    assert_eq!(&prep.members()["pd_faq__src_cells"], &vec![1i64]);
    // …and each gated fetch pushed exactly that one-member selection down.
    let expect_sel = vec![
        AxisSel::Indices(vec![0]),
        AxisSel::Indices(vec![0]),
        AxisSel::All,
    ];
    for v in LVARS {
        let calls = call_logs[v].borrow();
        assert_eq!(
            calls.len(),
            1,
            "{v}: expected one gated fetch, got {calls:?}"
        );
        match &calls[0] {
            Call::Selection(sel) => assert_eq!(sel, &expect_sel, "{v}: wrong selection"),
            Call::Wholesale => panic!("{v}: fetched WHOLESALE"),
        }
    }

    // The full downstream graph evaluated off the one-member axis.
    let e_voc = observed_field(&prep, "E_VOC").unwrap();
    assert_eq!(e_voc.len(), 1, "E_VOC must stay a length-1 ARRAY");
    assert_close("E_VOC", &e_voc, &oracle_e(&is_voc));
    assert_close(
        "conc_SOA",
        &observed_field(&prep, "conc_SOA").unwrap(),
        &oracle_conc("SOA"),
    );
    assert_close(
        "TotalPM25",
        &observed_field(&prep, "TotalPM25").unwrap(),
        &oracle_total,
    );
    assert_close(
        "deathsK",
        &observed_field(&prep, "deathsK").unwrap(),
        &oracle_deaths(RR_K),
    );
    assert_close(
        "deathsL",
        &observed_field(&prep, "deathsL").unwrap(),
        &oracle_deaths(RR_L),
    );
}

// ---- the same document under the strict `native` ----------------------------

/// Build the committed L1 document (or `doc`, a variant of it) through the
/// pipeline under `compiler`, with the first test's mock data. Returns the
/// build and each gated provider's call log.
#[allow(clippy::type_complexity)]
fn l1_build(
    doc: &Value,
    compiler: earthsci_ast::Compiler,
) -> (
    Result<earthsci_ast::EsmProblem, earthsci_ast::SimulateError>,
    Vec<Rc<RefCell<Vec<Call>>>>,
) {
    const GRID: usize = 9;
    const N_RCV: usize = 4;
    const N_LAYER: usize = 3;
    let (mut w, mut sv, mut ev, mut nv) = (
        vec![0.0; GRID],
        vec![0.0; GRID],
        vec![0.0; GRID],
        vec![0.0; GRID],
    );
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
    let (lon, lat): (Vec<f64>, Vec<f64>) =
        [(1.0, 1.0), (3.0, 1.0), (1.0, 3.0), (5.0, 5.0), (1.5, 1.5)]
            .iter()
            .map(|&(x, y)| lcc_inv(x, y, &c))
            .unzip();
    let mut providers: Vec<(String, Box<dyn PrepareProvider>)> = vec![
        (
            "ISRM.TotalPop".into(),
            Box::new(MockConst(vec![100.0, 200.0, 300.0, 400.0])),
        ),
        (
            "ISRM.MortalityRate".into(),
            Box::new(MockConst(vec![500.0, 600.0, 700.0, 800.0])),
        ),
        ("ISRM.emis_lon".into(), Box::new(MockConst(lon))),
        ("ISRM.emis_lat".into(), Box::new(MockConst(lat))),
        (
            "ISRM.emis_annual".into(),
            Box::new(MockConst(vec![10.0, 20.0, 30.0, 40.0, 50.0])),
        ),
        (
            "ISRM.is_VOC".into(),
            Box::new(MockConst(vec![1.0, 0.0, 1.0, 0.0, 0.0])),
        ),
        (
            "ISRM.is_NOx".into(),
            Box::new(MockConst(vec![0.0, 1.0, 0.0, 0.0, 0.0])),
        ),
        (
            "ISRM.is_NH3".into(),
            Box::new(MockConst(vec![0.0, 0.0, 0.0, 0.0, 1.0])),
        ),
        ("ISRM.is_SOx".into(), Box::new(MockConst(vec![0.0; 5]))),
        (
            "ISRM.is_PM25".into(),
            Box::new(MockConst(vec![0.0, 0.0, 0.0, 1.0, 0.0])),
        ),
    ];
    let mut logs = Vec::new();
    for (i, v) in ["SOA", "pNO3", "pNH4", "pSO4", "PrimaryPM25"]
        .iter()
        .enumerate()
    {
        let full = ArrayD::from_shape_fn(IxDyn(&[N_LAYER, GRID, N_RCV]), |ix| {
            ix[0] as f64 * 1.0e6
                + (i + 1) as f64 * 1000.0
                + (ix[1] + 1) as f64 * 10.0
                + (ix[2] + 1) as f64
        });
        let calls = Rc::new(RefCell::new(Vec::new()));
        logs.push(calls.clone());
        providers.push((format!("ISRM.SR_{v}"), Box::new(MockGated { full, calls })));
    }
    let ca: HashMap<String, ArrayD<f64>> = [
        ("src_W", &w),
        ("src_S", &sv),
        ("src_E", &ev),
        ("src_N", &nv),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), arr1(v)))
    .collect();
    let built = esm_problem(
        doc,
        (0.0, 0.0),
        ProblemOptions {
            compiler: Some(compiler),
            model_name: Some("ISRM".to_string()),
            pushdown_rewrite: true,
            const_arrays: ca,
            build_providers: providers,
            ..Default::default()
        },
    );
    (built, logs)
}

fn l1_doc() -> Value {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/pushdown/fixtures/pushdown_l1.esm");
    serde_json::from_str(&std::fs::read_to_string(&fixture).expect("read pushdown_l1.esm"))
        .expect("parse pushdown_l1.esm")
}

/// The rewritten document's join-gated binning aggregates (`E_*`) and the
/// rest of its build-time graph are lowered on the tape under `native`
/// rather than walked per cell, and every field agrees with the interpreter
/// bit for bit.
#[test]
fn prepare_pushdown_l1_builds_under_native_bit_identical_to_the_interpreter() {
    let doc = l1_doc();
    let (native, _) = l1_build(&doc, earthsci_ast::Compiler::Native);
    let native = native.expect("native builds the L1 document");
    let (interp, _) = l1_build(&doc, earthsci_ast::Compiler::Interpreter);
    let interp = interp.expect("interpreter");
    for name in [
        "E_VOC",
        "E_NOx",
        "E_NH3",
        "E_SOx",
        "E_PM25",
        "conc_SOA",
        "TotalPM25",
        "deathsK",
        "deathsL",
    ] {
        let bits = |p: &earthsci_ast::EsmProblem| -> Vec<u64> {
            observed_field(p, name)
                .unwrap()
                .iter()
                .map(|x| x.to_bits())
                .collect()
        };
        assert_eq!(bits(&native), bits(&interp), "{name}");
    }
    let report = native.compiler_report();
    let row = report
        .rules()
        .iter()
        .find(|r| r.rule == "ISRM.E_VOC")
        .unwrap_or_else(|| panic!("no E_VOC row: {report}"));
    assert_eq!(row.tier, "taped", "{report}");
}

/// A strict refusal whose cause has nothing to do with the gated data is
/// raised BEFORE the gated fetch: an observed that reads no gated slab is
/// evaluated ahead of it, so the refusal costs no fetch. The refusal names
/// what the overlay and the tape each declined. (`probe_fn` is the rule
/// refused once every other rule of the document lowers; until then it may
/// be an earlier one.)
#[test]
fn a_native_refusal_unrelated_to_the_gated_data_comes_before_the_gated_fetch() {
    let mut doc = l1_doc();
    let m = &mut doc["models"]["ISRM"];
    m["variables"]["probe_tbl"] =
        serde_json::json!({"type": "unknown", "units": "1", "shape": ["emis_records"]});
    m["variables"]["probe_fn"] =
        serde_json::json!({"type": "unknown", "units": "1", "shape": ["emis_records"]});
    let eqs = m["equations"].as_array_mut().unwrap();
    eqs.push(serde_json::json!({"lhs": "probe_tbl", "rhs": {
        "op": "faq", "args": [], "output_idx": ["e"], "ranges": {"e": {"from": "emis_records"}},
        "expr": {"op": "*", "args": [2.0, {"op": "index", "args": ["emis_annual", "e"]}]}}}));
    // `datetime.year` at arity 2, which the registry answers with
    // `closed_function_arity` at evaluation: neither the overlay nor the tape
    // lowers it. (An `interp.linear` over a non-`const` table used to be the
    // probe; load now refuses that document, esm-spec §9.2, ruling Q-106.)
    eqs.push(serde_json::json!({"lhs": "probe_fn", "rhs": {
        "op": "faq", "args": [], "output_idx": ["e"], "ranges": {"e": {"from": "emis_records"}},
        "expr": {"op": "fn", "name": "datetime.year",
                 "args": [{"op": "index", "args": ["probe_tbl", "e"]}, 1.0]}}}));

    let (native, logs) = l1_build(&doc, earthsci_ast::Compiler::Native);
    match native {
        Err(earthsci_ast::SimulateError::Compile(
            earthsci_ast::CompileError::CompilerRefusedRule {
                kind, rule, reason, ..
            },
        )) => {
            assert_eq!(kind, "build-time observed");
            assert!(reason.contains("whole-array overlay declined"), "{reason}");
            assert!(reason.contains("the tape declined it"), "{reason}");
            if rule == "ISRM.probe_fn" {
                assert!(reason.contains("datetime.year"), "{reason}");
            }
        }
        Err(e) => panic!("expected compiler_refused_rule, got {e}"),
        Ok(_) => panic!("expected a refusal"),
    }
    for calls in &logs {
        assert!(
            calls.borrow().is_empty(),
            "fetched before refusing: {:?}",
            calls.borrow()
        );
    }

    // The interpreter builds it, fetching each gated slab once.
    let (interp, logs) = l1_build(&doc, earthsci_ast::Compiler::Interpreter);
    interp.expect("the interpreter builds it");
    for calls in &logs {
        assert_eq!(calls.borrow().len(), 1);
    }
}

/// A document in which the pushdown pattern matches two models, built whole,
/// is refused naming both: the rewrite records one gate per document, so it
/// cannot rewrite both, and rewriting one would silently leave the other
/// fetching whole.
#[test]
fn a_whole_document_build_whose_pushdown_matches_two_models_is_refused() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/pushdown/fixtures/pushdown_l1.esm");
    let mut doc: Value =
        serde_json::from_str(&std::fs::read_to_string(&fixture).expect("read pushdown_l1.esm"))
            .expect("parse pushdown_l1.esm");
    doc["models"]["ISRM2"] = doc["models"]["ISRM"].clone();
    let msg = match esm_problem(
        &doc,
        (0.0, 0.0),
        ProblemOptions {
            compiler: Some(earthsci_ast::Compiler::Interpreter),
            pushdown_rewrite: true,
            ..Default::default()
        },
    ) {
        Ok(_) => panic!("built a document whose rewrite matches two models"),
        Err(e) => e.to_string(),
    };
    assert!(
        msg.contains("pushdown") && msg.contains("ISRM, ISRM2"),
        "{msg}"
    );
}
