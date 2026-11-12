//! Strip and expose (issue #543, CONFORMANCE_SPEC §5.57), driven by the shared
//! manifest at `tests/conformance/strip_and_expose/`.
//!
//! `ESM_WRITE_STRIP_GOLDENS=1` rewrites the committed stripped-object goldens
//! from this binding instead of comparing against them.

use earthsci_ast::{
    Compiler, KernelSet, KernelSpec, ProblemOptions, SolveOptions, StripSet, compile_kernels,
    esm_problem, rhs_program, stripped,
};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

fn category_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/strip_and_expose")
}

fn manifest() -> Value {
    let raw = std::fs::read_to_string(category_dir().join("manifest.json"))
        .expect("the strip_and_expose manifest is readable");
    serde_json::from_str(&raw).expect("the strip_and_expose manifest parses")
}

fn classes(v: &Value) -> StripSet {
    StripSet::from_names(
        v.as_array()
            .expect("a class list")
            .iter()
            .map(|c| c.as_str().expect("a class name")),
    )
    .expect("known classes")
}

fn build(
    path: &str,
    strip: StripSet,
    compiler: Compiler,
) -> Result<earthsci_ast::EsmProblem, earthsci_ast::SimulateError> {
    let p = category_dir().join(path);
    esm_problem(
        p.as_path(),
        (0.0, 1.0),
        ProblemOptions {
            strip,
            compiler: Some(compiler),
            ..Default::default()
        },
    )
}

#[test]
fn per_class_strip_builds_its_own_class_and_refuses_the_others() {
    let m = manifest();
    for case in m["per_class"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        let path = case["path"].as_str().unwrap();
        if !case["builds_with"].is_null() {
            let set = classes(&case["builds_with"]);
            build(path, set, Compiler::Native)
                .unwrap_or_else(|e| panic!("{id}: does not build with {set:?}: {e}"));
        }
        for refusal in case["refuses_with"].as_array().unwrap() {
            let set = classes(refusal);
            let err = build(path, set, Compiler::Native)
                .err()
                .unwrap_or_else(|| panic!("{id}: builds with {set:?}, should refuse"));
            if let Some(code) = case["refusal_code"].as_str() {
                assert!(
                    err.to_string().contains(code),
                    "{id} with {set:?}: refused with `{err}`, not `{code}`"
                );
            }
        }
    }
}

#[test]
fn stripped_object_matches_the_golden_byte_for_byte() {
    let m = manifest();
    let write = std::env::var("ESM_WRITE_STRIP_GOLDENS").is_ok_and(|v| v == "1");
    for case in m["stripped_goldens"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        let tspan = case["tspan"].as_array().map_or((0.0, 1.0), |s| {
            (s[0].as_f64().unwrap(), s[1].as_f64().unwrap())
        });
        let p: HashMap<String, f64> = case["p"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(k, v)| (k.clone(), v.as_f64().unwrap()))
            .collect();
        let prob = esm_problem(
            category_dir()
                .join(case["path"].as_str().unwrap())
                .as_path(),
            tspan,
            ProblemOptions {
                strip: classes(&case["strip"]),
                compiler: Some(Compiler::Native),
                p,
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{id}: {e}"));
        let got = stripped(&prob).canonical_json();
        let golden = category_dir().join(case["golden"].as_str().unwrap());
        if write {
            std::fs::write(&golden, &got).unwrap();
            continue;
        }
        let want = std::fs::read_to_string(&golden)
            .unwrap_or_else(|e| panic!("{id}: golden {}: {e}", golden.display()));
        assert_eq!(
            got, want,
            "{id}: the stripped object differs from its golden"
        );
    }
}

#[test]
fn a_stripped_problem_is_not_solvable() {
    let m = manifest();
    for case in m["not_solvable"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        let p = category_dir().join(case["path"].as_str().unwrap());
        let span = case["tspan"].as_array().unwrap();
        let prob = esm_problem(
            p.as_path(),
            (span[0].as_f64().unwrap(), span[1].as_f64().unwrap()),
            ProblemOptions {
                strip: classes(&case["strip"]),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{id}: {e}"));
        match case["expect"].as_str().unwrap() {
            "solves" => {
                assert!(!prob.is_stripped(), "{id}: nothing to strip, yet stripped");
                earthsci_ast::solve(&prob, &SolveOptions::default())
                    .unwrap_or_else(|e| panic!("{id}: does not solve: {e}"));
            }
            code => {
                assert!(prob.is_stripped(), "{id}: not stripped");
                let e = earthsci_ast::solve(&prob, &SolveOptions::default())
                    .expect_err("solve must refuse");
                assert!(e.to_string().starts_with(code), "{id}: solve: {e}");
                let e = match earthsci_ast::init(&prob, &SolveOptions::default()) {
                    Ok(_) => panic!("{id}: init must refuse"),
                    Err(e) => e,
                };
                assert!(e.to_string().starts_with(code), "{id}: init: {e}");
            }
        }
    }
}

fn specs(v: &Value) -> Vec<KernelSpec> {
    KernelSpec::list_from_json(v).expect("the specs parse")
}

/// `named` laid out over `layout`: each block's values by name (a number or a
/// column-major list).
fn assemble(layout: &[earthsci_ast::StateBlock], named: &Value, what: &str) -> Vec<f64> {
    let n: usize = layout
        .iter()
        .map(|b| b.shape.iter().product::<usize>().max(1))
        .sum();
    let mut out = vec![f64::NAN; n];
    for b in layout {
        let len = b.shape.iter().product::<usize>().max(1);
        let v = &named[&b.name];
        let vals: Vec<f64> = match v {
            Value::Number(x) => vec![x.as_f64().unwrap(); len],
            Value::Array(a) => a.iter().map(|x| x.as_f64().unwrap()).collect(),
            _ => panic!("{what}: no value for block '{}'", b.name),
        };
        assert_eq!(vals.len(), len, "{what}: block '{}'", b.name);
        out[b.flat_offset..b.flat_offset + len].copy_from_slice(&vals);
    }
    out
}

fn eval(ks: &KernelSet, probe: &Value) -> (Vec<f64>, Vec<earthsci_ast::KernelBlock>) {
    let k = ks
        .get(probe["kernel"].as_str().unwrap())
        .expect("the kernel exists");
    let u = assemble(ks.state_layout(), &probe["u"], "u");
    let z = assemble(ks.z_layout(), &probe["z"], "z");
    let p = ks.parameter_vector(&HashMap::new()).unwrap();
    let fs = ks.default_forcing();
    let mut ws = k.new_workspace();
    let mut out = vec![f64::NAN; k.len()];
    k.eval_into(
        &u,
        &z,
        &p,
        probe["t"].as_f64().unwrap(),
        probe["dt"].as_f64().unwrap(),
        &fs,
        &mut out,
        &mut ws,
    )
    .expect("the kernel evaluates");
    (out, k.layout().to_vec())
}

fn close(got: f64, want: f64, rtol: f64, atol: f64) -> bool {
    (got - want).abs() <= atol + rtol * want.abs()
}

#[test]
fn kernel_probes_match_their_analytic_anchors() {
    let m = manifest();
    let tol = &m["tolerance_classes"]["algebraic"];
    let (rtol, atol) = (tol["rtol"].as_f64().unwrap(), tol["atol"].as_f64().unwrap());
    for case in m["kernels"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        let mut sets = Vec::new();
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            let prob = build(
                case["path"].as_str().unwrap(),
                classes(&case["strip"]),
                compiler,
            )
            .unwrap_or_else(|e| panic!("{id}: {e}"));
            let ks = compile_kernels(&prob, &specs(&case["specs"]))
                .unwrap_or_else(|e| panic!("{id} ({compiler}): {e}"));
            sets.push(ks);
        }
        for probe in case["probes"].as_array().unwrap() {
            let (native, layout) = eval(&sets[0], probe);
            let (interp, _) = eval(&sets[1], probe);
            let expected = probe["expected"].as_object().unwrap();
            let k = probe["kernel"].as_str().unwrap();
            for (label, want) in expected {
                let want: Vec<f64> = match want {
                    Value::Number(x) => vec![x.as_f64().unwrap()],
                    Value::Array(a) => a.iter().map(|x| x.as_f64().unwrap()).collect(),
                    _ => panic!(),
                };
                let range = if label == "u" || label == "du" {
                    0..native.len()
                } else {
                    let b = layout
                        .iter()
                        .find(|b| &b.label == label)
                        .unwrap_or_else(|| panic!("{id}/{k}: no output labelled {label}"));
                    let len = b.shape.iter().product::<usize>().max(1);
                    b.offset..b.offset + len
                };
                let got = &native[range.clone()];
                assert_eq!(got.len(), want.len(), "{id}/{k}/{label}: length");
                for (i, (g, w)) in got.iter().zip(&want).enumerate() {
                    assert!(
                        close(*g, *w, rtol, atol),
                        "{id}/{k}/{label}[{i}]: native {g}, anchor {w}"
                    );
                    let gi = interp[range.start + i];
                    assert!(
                        close(gi, *w, rtol, atol),
                        "{id}/{k}/{label}[{i}]: interpreter {gi}, anchor {w}"
                    );
                }
            }
        }
    }
}

/// The document with every event deleted: models, subsystems at any depth,
/// reaction systems, and coupling event entries.
fn without_events(v: &mut Value) {
    if let Some(o) = v.as_object_mut() {
        o.remove("continuous_events");
        o.remove("discrete_events");
        if let Some(Value::Array(c)) = o.get_mut("coupling") {
            c.retain(|e| e["type"] != "event");
        }
        for (_, x) in o.iter_mut() {
            without_events(x);
        }
    } else if let Some(a) = v.as_array_mut() {
        for x in a {
            without_events(x);
        }
    }
}

#[test]
fn the_stripped_rhs_equals_the_event_free_document() {
    let m = manifest();
    for case in m["remaining_rhs"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        let path = case["path"].as_str().unwrap();
        let prob = build(path, classes(&case["strip"]), Compiler::Native).unwrap();
        let ks = compile_kernels(&prob, &specs(&serde_json::json!([{"name": "rhs"}]))).unwrap();
        let mut doc: Value =
            serde_json::from_str(&std::fs::read_to_string(category_dir().join(path)).unwrap())
                .unwrap();
        without_events(&mut doc);
        let control = esm_problem(
            &doc,
            (0.0, 1.0),
            ProblemOptions {
                base_path: Some(category_dir().join(path).parent().unwrap().to_path_buf()),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{id}: control: {e}"));
        let prog = rhs_program(&control).unwrap();
        for probe in case["probes"].as_array().unwrap() {
            let (u0, _) = prog.default_state();
            let u = if probe["u"].is_null() {
                u0.iter()
                    .map(|x| if x.is_nan() { 0.5 } else { *x })
                    .collect()
            } else {
                assemble(prog.state_layout(), &probe["u"], "u")
            };
            let t = probe["t"].as_f64().unwrap();
            let p = prog.parameter_vector(&HashMap::new()).unwrap();
            let mut want = vec![f64::NAN; u.len()];
            let mut ws = prog.new_workspace();
            prog.eval_into(&u, &[], &p, t, &prog.default_forcing(), &mut want, &mut ws)
                .unwrap();
            let k = ks.get("rhs").unwrap();
            let mut got = vec![f64::NAN; k.len()];
            let mut kws = k.new_workspace();
            let pk = ks.parameter_vector(&HashMap::new()).unwrap();
            k.eval_into(
                &u,
                &[],
                &pk,
                t,
                0.0,
                &ks.default_forcing(),
                &mut got,
                &mut kws,
            )
            .unwrap();
            assert_eq!(
                got.iter().map(|x| x.to_bits()).collect::<Vec<_>>(),
                want.iter().map(|x| x.to_bits()).collect::<Vec<_>>(),
                "{id}: rhs kernel {got:?} vs control {want:?}"
            );
        }
    }
}

#[test]
fn refusals_name_their_code() {
    let m = manifest();
    for case in m["refusals"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        let prob = build(
            case["path"].as_str().unwrap(),
            classes(&case["strip"]),
            Compiler::Native,
        )
        .unwrap_or_else(|e| panic!("{id}: {e}"));
        let err = KernelSpec::list_from_json(&case["specs"])
            .and_then(|s| compile_kernels(&prob, &s))
            .err()
            .unwrap_or_else(|| panic!("{id}: compiled, should refuse"));
        let msg = err.to_string();
        let want = &case["expect_error"];
        assert!(
            msg.starts_with(want["code"].as_str().unwrap()),
            "{id}: `{msg}`"
        );
        for s in want["mentions"].as_array().unwrap() {
            assert!(msg.contains(s.as_str().unwrap()), "{id}: `{msg}` lacks {s}");
        }
    }
}

#[test]
fn kernels_are_send_sync_and_clone() {
    fn check<T: Send + Sync + Clone>() {}
    check::<earthsci_ast::Kernel>();
    check::<KernelSet>();
    check::<KernelSpec>();
    fn send<T: Send>() {}
    send::<earthsci_ast::KernelWorkspace>();
}
