//! The `public_rhs_program` conformance suite (CONFORMANCE_SPEC §5.51,
//! `tests/conformance/public_rhs_program/README.md`): every case of the
//! manifest under `Compiler::Native`, checked bitwise against the taped debug
//! seam and against the program's own serial results.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use earthsci_ast::{
    Compiler, ForcingSet, ProblemOptions, RhsError, RhsProgram, SlotKind, esm_problem, rhs_program,
};
use ndarray::{ArrayD, IxDyn, ShapeBuilder};
use serde_json::Value;

fn suite_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/public_rhs_program")
        .canonicalize()
        .expect("suite directory")
}

fn manifest() -> Value {
    let text = std::fs::read_to_string(suite_dir().join("manifest.json")).expect("manifest");
    serde_json::from_str(&text).expect("manifest parses")
}

fn fnv1a32(key: &str) -> u32 {
    key.bytes().fold(0x811c_9dc5u32, |h, b| {
        (h ^ u32::from(b)).wrapping_mul(0x0100_0193)
    })
}

/// The suite's `hash01` generator.
fn h(key: &str, k: u32) -> f64 {
    let mut x = fnv1a32(key).wrapping_add(0x9e37_79b1u32.wrapping_mul(k));
    x ^= x >> 16;
    x = x.wrapping_mul(0x85eb_ca6b);
    x ^= x >> 13;
    x = x.wrapping_mul(0xc2b2_ae35);
    x ^= x >> 16;
    f64::from(x) / 4_294_967_296.0
}

fn bits(v: &[f64]) -> Vec<u64> {
    v.iter().map(|x| x.to_bits()).collect()
}

fn problem(c: &Value, options: &Value) -> earthsci_ast::EsmProblem {
    let path = suite_dir().join(c["document"].as_str().unwrap());
    esm_problem(
        path.as_path(),
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(Compiler::Native),
            runtime_array_parameters: options["runtime_array_parameters"]
                .as_bool()
                .unwrap_or(false),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("{}: build: {e}", c["id"]))
}

/// One drawn evaluation point.
struct Draw {
    u: Vec<f64>,
    p: Vec<f64>,
    t: f64,
}

fn draws(prog: &RhsProgram, n: usize) -> Vec<Draw> {
    (0..n)
        .map(|d| {
            let mut u = vec![f64::NAN; prog.n_states()];
            for b in prog.state_layout() {
                let len: usize = b.shape.iter().product();
                for k in 0..len {
                    u[b.flat_offset + k] = 0.5 + h(&format!("u{d}/{}", b.name), k as u32 + 1);
                }
            }
            let overrides: HashMap<String, f64> = if d == 0 {
                HashMap::new()
            } else {
                prog.parameters()
                    .iter()
                    .map(|s| (s.name.clone(), 0.5 + h(&format!("p{d}/{}", s.name), 1)))
                    .collect()
            };
            Draw {
                u,
                p: prog.parameter_vector(&overrides).expect("parameter vector"),
                t: if d == 0 {
                    0.0
                } else {
                    10.0 * h(&format!("t{d}"), 1)
                },
            }
        })
        .collect()
}

/// Sets D, A and B.
fn sets(prog: &RhsProgram, replace: Option<&str>) -> Vec<ForcingSet> {
    let d = prog.default_forcing();
    let a_bufs: Vec<Arc<[f64]>> = prog
        .forcing_slots()
        .iter()
        .map(|s| {
            (1..=s.len())
                .map(|k| 0.5 + h(&format!("fA/{}", s.name), k as u32))
                .collect()
        })
        .collect();
    let a = ForcingSet::new(prog, a_bufs.clone()).expect("set A");
    let Some(name) = replace else {
        return vec![d];
    };
    let i = prog
        .forcing_slots()
        .iter()
        .position(|s| s.name == name)
        .expect("replace slot");
    let buf: Arc<[f64]> = (1..=prog.forcing_slots()[i].len())
        .map(|k| 0.5 + h(&format!("fB/{name}"), k as u32))
        .collect();
    let (a_epoch, a_first) = (a.epoch(), a.buffer(i).to_vec());
    let b = a.replace(i, buf).expect("set B");
    assert_eq!(a.epoch(), a_epoch, "building B changed A's epoch");
    assert_eq!(bits(a.buffer(i)), bits(&a_first), "building B changed A");
    let again = ForcingSet::new(prog, a_bufs).expect("set A again");
    assert_ne!(
        again.epoch(),
        a.epoch(),
        "the same buffers took a used epoch"
    );
    let epochs = [d.epoch(), a.epoch(), b.epoch()];
    assert!(
        epochs[0] != epochs[1] && epochs[1] != epochs[2] && epochs[0] != epochs[2],
        "epochs {epochs:?}"
    );
    vec![d, a, b]
}

fn eval(
    prog: &RhsProgram,
    x: &Draw,
    fs: &ForcingSet,
    ws: &mut earthsci_ast::RhsWorkspace,
) -> Result<Vec<f64>, RhsError> {
    let mut du = vec![f64::NAN; prog.n_states()];
    prog.eval_into(&x.u, &[], &x.p, x.t, fs, &mut du, ws)?;
    Ok(du)
}

/// The variable a slot name belongs to (`q[2,3]` -> `q`).
fn var_of(slot: &str) -> &str {
    slot.split('[').next().unwrap()
}

/// Whether the program's flattened `name` is the reference's `rname`.
fn same_name(name: &str, rname: &str) -> bool {
    name == rname || name.ends_with(&format!(".{rname}"))
}

/// The reference: `debug_eval_rhs_into` on a fresh taped scratch of the
/// Problem's compiled model, its forcing buffer holding `fs`'s data. The
/// state is mapped between the two layouts by variable (each block is
/// column-major in both).
fn reference(
    prob: &earthsci_ast::EsmProblem,
    prog: &RhsProgram,
    x: &Draw,
    fs: &ForcingSet,
) -> Vec<f64> {
    let c = prob.debug_array_compiled().expect("array backend");
    let _env = c.debug_precision_env().enter();
    {
        let handle = c.forcing_handle();
        let mut buf = handle.borrow_mut();
        for (k, s) in fs.slots().iter().enumerate() {
            let key = buf
                .keys()
                .find(|n| same_name(&s.name, n))
                .cloned()
                .unwrap_or_else(|| s.name.clone());
            let a = ArrayD::from_shape_vec(IxDyn(&s.shape).f(), fs.buffer(k).to_vec())
                .expect("slot shape");
            buf.insert(key, a.as_standard_layout().into_owned());
        }
    }
    let names = c.state_variable_names().to_vec();
    let start = |name: &str| -> usize {
        names
            .iter()
            .position(|n| same_name(name, var_of(n)))
            .unwrap_or_else(|| panic!("no reference state for {name}"))
    };
    let mut y = vec![f64::NAN; c.n_states()];
    for b in prog.state_layout() {
        let len: usize = b.shape.iter().product::<usize>().max(1);
        let r = start(&b.name);
        y[r..r + len].copy_from_slice(&x.u[b.flat_offset..b.flat_offset + len]);
    }
    let named: HashMap<String, f64> = prog
        .parameters()
        .iter()
        .zip(&x.p)
        .flat_map(|(s, v)| {
            let bare = s.name.rsplit('.').next().unwrap().to_string();
            [(s.name.clone(), *v), (bare, *v)]
        })
        .collect();
    let pv = c.debug_resolve_params(&named);
    let mut scratch = c.debug_new_scratch_taped().expect("taped scratch");
    let mut dy = vec![f64::NAN; c.n_states()];
    c.debug_eval_rhs_into(&y, x.t, &pv, &mut dy, &mut scratch, &mut Default::default());
    let mut out = vec![f64::NAN; prog.n_states()];
    for b in prog.state_layout() {
        let len: usize = b.shape.iter().product::<usize>().max(1);
        let r = start(&b.name);
        out[b.flat_offset..b.flat_offset + len].copy_from_slice(&dy[r..r + len]);
    }
    out
}

/// Check 1: the surface the manifest records.
fn surface(c: &Value, prog: &RhsProgram) {
    let id = &c["id"];
    assert_eq!(
        prog.n_states() as u64,
        c["n_states"].as_u64().unwrap(),
        "{id}"
    );
    let lay: Vec<(String, u64, Vec<u64>)> = prog
        .state_layout()
        .iter()
        .map(|b| {
            (
                b.name.clone(),
                b.flat_offset as u64,
                b.shape.iter().map(|&n| n as u64).collect(),
            )
        })
        .collect();
    let want: Vec<(String, u64, Vec<u64>)> = c["state_layout"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| {
            (
                b["name"].as_str().unwrap().to_string(),
                b["offset"].as_u64().unwrap(),
                b["shape"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|n| n.as_u64().unwrap())
                    .collect(),
            )
        })
        .collect();
    assert_eq!(lay, want, "{id}: state_layout");
    let params: Vec<(String, Option<u64>)> = prog
        .parameters()
        .iter()
        .map(|s| (s.name.clone(), s.default.map(f64::to_bits)))
        .collect();
    let want: Vec<(String, Option<u64>)> = c["parameters"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            (
                s["name"].as_str().unwrap().to_string(),
                s["default"].as_f64().map(f64::to_bits),
            )
        })
        .collect();
    assert_eq!(params, want, "{id}: parameters");
    slots_match(id, prog, &c["forcing_slots"]);
}

fn slots_match(id: &Value, prog: &RhsProgram, want: &Value) {
    let got: Vec<(String, Vec<u64>, &str)> = prog
        .forcing_slots()
        .iter()
        .map(|s| {
            (
                s.name.clone(),
                s.shape.iter().map(|&n| n as u64).collect(),
                match s.kind {
                    SlotKind::Forcing => "forcing",
                    SlotKind::ArrayParameter => "array_parameter",
                },
            )
        })
        .collect();
    let want: Vec<(String, Vec<u64>, &str)> = want
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            (
                s["name"].as_str().unwrap().to_string(),
                s["shape"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|n| n.as_u64().unwrap())
                    .collect(),
                s["kind"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(got, want, "{id}: forcing_slots");
}

/// Checks 2 and 4.
fn defaults_and_parameters(c: &Value, prog: &RhsProgram) {
    let id = &c["id"];
    let d = prog.default_forcing();
    assert_eq!(
        d.epoch(),
        prog.default_forcing().epoch(),
        "{id}: two defaults"
    );
    for (k, s) in prog.forcing_slots().iter().enumerate() {
        let want: Vec<f64> = c["default_forcing"][&s.name]
            .as_array()
            .unwrap_or_else(|| panic!("{id}: no default_forcing for {}", s.name))
            .iter()
            .map(|v| v.as_f64().unwrap())
            .collect();
        assert_eq!(bits(d.buffer(k)), bits(&want), "{id}: default {}", s.name);
    }
    let p = prog.parameter_vector(&HashMap::new()).expect("defaults");
    let want: Vec<f64> = prog
        .parameters()
        .iter()
        .map(|s| s.default.unwrap())
        .collect();
    assert_eq!(bits(&p), bits(&want), "{id}: parameter_vector(&{{}})");
    let err = prog
        .parameter_vector(&HashMap::from([("NoSuchModel.nothing".to_string(), 1.0)]))
        .expect_err("an unknown override is refused");
    assert!(
        err.to_string().contains("NoSuchModel.nothing"),
        "{id}: {err}"
    );
}

/// The task list: every draw with every set.
fn tasks(n_draws: usize, n_sets: usize) -> Vec<(usize, usize)> {
    (0..n_draws)
        .flat_map(|d| (0..n_sets).map(move |s| (d, s)))
        .collect()
}

/// Checks 6 and 7 over `tasks` (`serial` the serial results). With `fault`,
/// thread 1 evaluates that draw on every call and must get the fault.
fn history_and_concurrency(
    m: &Value,
    prog: &RhsProgram,
    ds: &[Draw],
    fs: &[ForcingSet],
    tasks: &[(usize, usize)],
    serial: &[Vec<f64>],
    fault: Option<(&Draw, &str)>,
) {
    // 6: shuffled order, then task 1 again, against a fresh workspace.
    let mut order: Vec<usize> = (0..tasks.len()).collect();
    order.sort_by(|&a, &b| {
        h("order", a as u32 + 1)
            .partial_cmp(&h("order", b as u32 + 1))
            .unwrap()
            .then(a.cmp(&b))
    });
    let mut ws = prog.new_workspace();
    for &i in &order {
        let (d, s) = tasks[i];
        let _ = eval(prog, &ds[d], &fs[s], &mut ws).expect("history eval");
    }
    let (d, s) = tasks[0];
    let again = eval(prog, &ds[d], &fs[s], &mut ws).expect("history eval");
    assert_eq!(bits(&again), bits(&serial[0]), "history independence");

    // 7: threads x calls at the drawn tasks.
    let threads = m["concurrency"]["threads"].as_u64().unwrap() as usize;
    let calls = m["concurrency"]["calls_per_thread"].as_u64().unwrap() as u32;
    let n = tasks.len();
    std::thread::scope(|sc| {
        for q in 1..=threads {
            let prog = prog.clone();
            sc.spawn(move || {
                let mut ws = prog.new_workspace();
                for j in 1..=calls {
                    if q == 1
                        && let Some((x, code)) = fault
                    {
                        match eval(&prog, x, &fs[0], &mut ws) {
                            Err(RhsError::Fault { code: got, .. }) => assert_eq!(got, code),
                            other => panic!("thread 1 call {j}: expected the fault, got {other:?}"),
                        }
                        continue;
                    }
                    let t = (h(&format!("c{q}"), j) * n as f64).floor() as usize;
                    let (d, s) = tasks[t];
                    let du = eval(&prog, &ds[d], &fs[s], &mut ws)
                        .unwrap_or_else(|e| panic!("thread {q} call {j}: {e}"));
                    assert_eq!(bits(&du), bits(&serial[t]), "thread {q} call {j} task {t}");
                }
            });
        }
    });
}

fn forcing_case(m: &Value, c: &Value) {
    let id = &c["id"];
    let n_draws = m["draws"]["count"].as_u64().unwrap() as usize;
    let prob = problem(c, &c["options"]);
    let prog = rhs_program(&prob).unwrap_or_else(|e| panic!("{id}: rhs_program: {e}"));
    surface(c, &prog);
    defaults_and_parameters(c, &prog);
    let fs = sets(&prog, c["replace_slot"].as_str());
    let ds = draws(&prog, n_draws);
    let tasks = tasks(n_draws, fs.len());
    // 5: equivalence, one workspace in list order.
    let mut ws = prog.new_workspace();
    let serial: Vec<Vec<f64>> = tasks
        .iter()
        .map(|&(d, s)| {
            let got = eval(&prog, &ds[d], &fs[s], &mut ws).expect("eval");
            let want = reference(&prob, &prog, &ds[d], &fs[s]);
            assert_eq!(bits(&got), bits(&want), "{id}: task ({d}, {s})");
            got
        })
        .collect();
    // The stale-forcing control.
    let mut ws = prog.new_workspace();
    let r_a = eval(&prog, &ds[0], &fs[1], &mut ws).expect("eval");
    let r_b = eval(&prog, &ds[0], &fs[2], &mut ws).expect("eval");
    assert_ne!(bits(&r_a), bits(&r_b), "{id}: set B was not read");
    assert_eq!(bits(&r_b), bits(&serial[2]), "{id}: (0, B)");
    if c["stale_control"]["rust"].as_bool() == Some(true) {
        stale_negative_control(&prob, &prog, &ds[0], &fs[1], &fs[2], &r_a);
    }
    if let Some(twin) = c.get("baked_twin") {
        let baked = rhs_program(&problem(c, &twin["options"])).expect("baked twin");
        assert!(baked.parameters().len() == twin["parameters"].as_array().unwrap().len());
        slots_match(id, &baked, &twin["forcing_slots"]);
        let fb = baked.default_forcing();
        let mut wb = baked.new_workspace();
        for (d, x) in ds.iter().enumerate() {
            let xb = Draw {
                u: x.u.clone(),
                p: baked.parameter_vector(&HashMap::new()).expect("defaults"),
                t: x.t,
            };
            let got = eval(&baked, &xb, &fb, &mut wb).expect("baked eval");
            let k = tasks.iter().position(|&t| t == (d, 0)).unwrap();
            assert_eq!(bits(&got), bits(&serial[k]), "{id}: baked twin, draw {d}");
        }
    }
    history_and_concurrency(m, &prog, &ds, &fs, &tasks, &serial, None);
}

/// The old path's stale read: one taped debug scratch, `A`'s data, then the
/// buffer overwritten in place with `B`'s data and the same draw again.
fn stale_negative_control(
    prob: &earthsci_ast::EsmProblem,
    prog: &RhsProgram,
    x: &Draw,
    a: &ForcingSet,
    b: &ForcingSet,
    r_a: &[f64],
) {
    let c = prob.debug_array_compiled().expect("array backend");
    let _env = c.debug_precision_env().enter();
    let write = |fs: &ForcingSet| {
        let handle = c.forcing_handle();
        let mut buf = handle.borrow_mut();
        for (k, s) in fs.slots().iter().enumerate() {
            let key = buf
                .keys()
                .find(|n| same_name(&s.name, n))
                .cloned()
                .unwrap_or_else(|| s.name.clone());
            let arr = ArrayD::from_shape_vec(IxDyn(&s.shape).f(), fs.buffer(k).to_vec())
                .expect("slot shape");
            buf.insert(key, arr.as_standard_layout().into_owned());
        }
    };
    let names = c.state_variable_names().to_vec();
    let mut y = vec![f64::NAN; c.n_states()];
    let mut place = Vec::new();
    for blk in prog.state_layout() {
        let len: usize = blk.shape.iter().product::<usize>().max(1);
        let r = names
            .iter()
            .position(|n| same_name(&blk.name, var_of(n)))
            .unwrap();
        y[r..r + len].copy_from_slice(&x.u[blk.flat_offset..blk.flat_offset + len]);
        place.push((blk.flat_offset, r, len));
    }
    let named: HashMap<String, f64> = prog
        .parameters()
        .iter()
        .zip(&x.p)
        .flat_map(|(s, v)| {
            [
                (s.name.clone(), *v),
                (s.name.rsplit('.').next().unwrap().to_string(), *v),
            ]
        })
        .collect();
    let pv = c.debug_resolve_params(&named);
    write(a);
    let mut scratch = c.debug_new_scratch_taped().expect("taped scratch");
    let mut dy = vec![f64::NAN; c.n_states()];
    c.debug_eval_rhs_into(&y, x.t, &pv, &mut dy, &mut scratch, &mut Default::default());
    write(b);
    c.debug_eval_rhs_into(&y, x.t, &pv, &mut dy, &mut scratch, &mut Default::default());
    let mut stale = vec![f64::NAN; prog.n_states()];
    for (o, r, len) in place {
        stale[o..o + len].copy_from_slice(&dy[r..r + len]);
    }
    assert_eq!(
        bits(&stale),
        bits(r_a),
        "the negative control lost its teeth: the old path read the new buffer"
    );
}

fn fault_case(m: &Value, c: &Value) {
    let id = &c["id"];
    let n_draws = m["draws"]["count"].as_u64().unwrap() as usize;
    let prob = problem(c, &c["options"]);
    let prog = rhs_program(&prob).unwrap_or_else(|e| panic!("{id}: rhs_program: {e}"));
    surface(c, &prog);
    defaults_and_parameters(c, &prog);
    let fs = sets(&prog, None);
    let state = |v: &Value| -> Draw {
        let mut u = vec![f64::NAN; prog.n_states()];
        for b in prog.state_layout() {
            u[b.flat_offset] = v[&b.name].as_f64().unwrap();
        }
        Draw {
            u,
            p: prog.parameter_vector(&HashMap::new()).expect("defaults"),
            t: 0.0,
        }
    };
    let (bad, ok) = (state(&c["fault_state"]), state(&c["ok_state"]));
    let code = c["expect_error"]["code"].as_str().unwrap();
    let mut ws = prog.new_workspace();
    match eval(&prog, &bad, &fs[0], &mut ws) {
        Err(RhsError::Fault { code: got, .. }) => assert_eq!(got, code, "{id}"),
        other => panic!("{id}: expected the fault, got {other:?}"),
    }
    let after = eval(&prog, &ok, &fs[0], &mut ws).expect("the workspace recovers");
    let fresh = eval(&prog, &ok, &fs[0], &mut prog.new_workspace()).expect("fresh");
    assert_eq!(bits(&after), bits(&fresh), "{id}: no latch");
    // The task list: the draws with set D, then the ok state.
    let mut ds = draws(&prog, n_draws);
    ds.push(ok);
    let tasks: Vec<(usize, usize)> = (0..ds.len()).map(|d| (d, 0)).collect();
    let mut ws = prog.new_workspace();
    let serial: Vec<Vec<f64>> = tasks
        .iter()
        .map(|&(d, s)| eval(&prog, &ds[d], &fs[s], &mut ws).expect("serial eval"))
        .collect();
    history_and_concurrency(m, &prog, &ds, &fs, &tasks, &serial, Some((&bad, code)));
}

#[test]
fn public_rhs_program_manifest() {
    let m = manifest();
    for chk in m["generator"]["checks"].as_array().unwrap() {
        let got = h(
            chk["key"].as_str().unwrap(),
            chk["k"].as_u64().unwrap() as u32,
        );
        assert_eq!(
            got.to_bits(),
            chk["h"].as_f64().unwrap().to_bits(),
            "generator check {chk}"
        );
    }
    for c in m["cases"].as_array().unwrap() {
        match c["kind"].as_str().unwrap() {
            "forcing" | "array_parameters" => forcing_case(&m, c),
            "fault" => fault_case(&m, c),
            other => panic!("unknown case kind `{other}`"),
        }
    }
}
