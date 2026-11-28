//! The `ic_system` conformance suite (`tests/conformance/ic_system/`; esm
//! 2.5.0, esm-spec §11.4.2–§11.4.4, API_SPEC §5.8): generalized `ic`
//! equations and the initialization system.
//!
//! Each case builds its fixture with the case's `tspan`, `p`, `u0` and
//! `strip` under `native`, then checks the whole initial state against
//! `expected` (through `initial_state` and a solve's first saved point), or
//! the construction error's code, or the members of the stripped object it
//! names. Each load checks the loaded document (the migrated equations, the
//! guesses, the removed field), a load refusal, or `validate`'s codes.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::{
    Compiler, ProblemOptions, SolveOptions, StripSet, esm_problem, initial_state, load_path,
    solve, stripped, to_json, validate,
};
use serde_json::Value;

use crate::common;

fn numbers(v: &Value) -> HashMap<String, f64> {
    v.as_object()
        .map(|o| {
            o.iter()
                .map(|(k, x)| (k.clone(), x.as_f64().expect("a number")))
                .collect()
        })
        .unwrap_or_default()
}

fn build(c: &Value) -> Result<earthsci_ast::EsmProblem, earthsci_ast::SimulateError> {
    let path = common::category_dir("ic_system").join(c["fixture"].as_str().unwrap());
    let t = common::floats(&c["tspan"]);
    let names: Vec<&str> = c["strip"]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    esm_problem(
        path.as_path(),
        (t[0], t[1]),
        ProblemOptions {
            compiler: Some(Compiler::Native),
            p: numbers(&c["p"]),
            u0: numbers(&c["u0"]),
            strip: StripSet::from_names(names).expect("strip classes"),
            ..Default::default()
        },
    )
}

/// JSON equality with numbers compared by value.
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        (x, y) => x == y,
    }
}

#[test]
fn ic_system_cases() {
    let m = common::tier_manifest("ic_system");
    assert_eq!(m["category"].as_str(), Some("ic_system"));
    let rtol = m["tolerances"]["rtol"].as_f64().unwrap();
    let atol = m["tolerances"]["atol"].as_f64().unwrap();
    let cases = m["cases"].as_array().unwrap();
    assert!(cases.len() >= 20, "the manifest must not go vacuous");
    let mut failures: Vec<String> = Vec::new();
    for c in cases {
        let id = c["id"].as_str().unwrap();
        if let Some(code) = c["error_code"].as_str() {
            match build(c).and_then(|p| initial_state(&p).map(|_| ())) {
                Ok(()) => failures.push(format!("{id}: expected {code}, but the Problem built")),
                Err(e) if e.to_string().contains(code) => {}
                Err(e) => failures.push(format!("{id}: expected {code}, got: {e}")),
            }
            continue;
        }
        let prob = match build(c) {
            Ok(p) => p,
            Err(e) => {
                failures.push(format!("{id}: builds: {e}"));
                continue;
            }
        };
        if let Some(want) = c["stripped"].as_object() {
            let got: Value = serde_json::from_str(&stripped(&prob).canonical_json()).unwrap();
            for (k, v) in want {
                let g = if k == "algebraic_z0" {
                    &got["algebraic"]["z0"]
                } else {
                    &got[k.as_str()]
                };
                if !same(g, v) {
                    failures.push(format!("{id}: stripped `{k}` = {g}, expected {v}"));
                }
            }
        }
        if c["not_solvable"].as_bool() == Some(true) {
            match solve(&prob, &SolveOptions::default()) {
                Err(e) if e.to_string().contains("stripped_problem_not_solvable") => {}
                Err(e) => failures.push(format!("{id}: solve refused with {e}")),
                Ok(_) => failures.push(format!("{id}: a stripped Problem solved")),
            }
        }
        let u0 = match initial_state(&prob) {
            Ok(u) => u,
            Err(e) => {
                failures.push(format!("{id}: initial state: {e}"));
                continue;
            }
        };
        let names = prob.state_variable_names();
        let expected = numbers(&c["expected"]);
        // This binding keeps a stripped algebraic unknown (a `z` unknown) in
        // the Problem's state vector, held at its warm start; the manifest's
        // `expected` is the state without them (API_SPEC §5.8: `u` is the
        // state layout with the `z` unknowns removed).
        let z: Vec<String> = stripped(&prob)
            .algebraic_unknowns()
            .into_iter()
            .map(str::to_string)
            .collect();
        let in_z = |n: &str| z.iter().any(|w| n == w || n.starts_with(&format!("{w}[")));
        let got: HashMap<&str, f64> = names
            .iter()
            .map(String::as_str)
            .zip(u0.iter().copied())
            .filter(|(n, _)| !in_z(n))
            .collect();
        let mut want_names: Vec<&String> = expected.keys().collect();
        want_names.sort();
        let mut got_names: Vec<&str> = got.keys().copied().collect();
        got_names.sort();
        if got_names != want_names.iter().map(|s| s.as_str()).collect::<Vec<_>>() {
            failures.push(format!(
                "{id}: state elements {got_names:?}, expected {want_names:?}"
            ));
            continue;
        }
        for (n, want) in &expected {
            let v = got[n.as_str()];
            if (v - want).abs() > atol + rtol * want.abs() {
                failures.push(format!("{id}: {n} = {v}, expected {want}"));
            }
        }
        if prob.is_stripped() {
            continue;
        }
        let t0 = common::floats(&c["tspan"])[0];
        match solve(
            &prob,
            &SolveOptions {
                saveat: Some(vec![t0]),
                ..Default::default()
            },
        ) {
            Ok(sol) => {
                for (k, n) in names.iter().enumerate() {
                    if sol.state[k][0].to_bits() != u0[k].to_bits() {
                        failures.push(format!("{id}: {n}: the solve starts elsewhere"));
                    }
                }
            }
            Err(e) => failures.push(format!("{id}: solve: {e}")),
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn ic_system_loads() {
    let m = common::tier_manifest("ic_system");
    let mut failures: Vec<String> = Vec::new();
    for c in m["loads"].as_array().unwrap() {
        let id = c["id"].as_str().unwrap();
        let path = common::category_dir("ic_system").join(c["fixture"].as_str().unwrap());
        let loaded = load_path(&path);
        if let Some(code) = c["load_error"].as_str() {
            match loaded {
                Ok(_) => failures.push(format!("{id}: expected a load refusal ({code})")),
                Err(e) if e.to_string().contains(code) => {}
                Err(e) => failures.push(format!("{id}: refused without `{code}`: {e}")),
            }
            continue;
        }
        let file = match loaded {
            Ok(f) => f,
            Err(e) => {
                failures.push(format!("{id}: loads: {e}"));
                continue;
            }
        };
        if let Some(want) = c["validate_errors"].as_array() {
            let got: Vec<String> = validate(&file)
                .structural_errors
                .iter()
                .map(|e| e.code.to_string())
                .collect();
            let want: Vec<String> = want
                .iter()
                .map(|w| w.as_str().unwrap().to_string())
                .collect();
            if got != want {
                failures.push(format!("{id}: validate codes {got:?}, expected {want:?}"));
            }
        }
        let doc: Value = serde_json::from_str(&to_json(&file).unwrap()).unwrap();
        let Some(model) = c["model"].as_str() else {
            continue;
        };
        let md = &doc["models"][model];
        if let Some(field) = c["no_field"].as_str()
            && md.get(field).is_some()
        {
            failures.push(format!("{id}: `{field}` survives the load"));
        }
        let eqs = md["equations"].as_array().cloned().unwrap_or_default();
        if let Some(tail) = c["equations_tail"].as_array() {
            if eqs.len() < tail.len() {
                failures.push(format!("{id}: {} equations", eqs.len()));
            } else {
                for (got, want) in eqs[eqs.len() - tail.len()..].iter().zip(tail) {
                    let pick = |v: &Value| {
                        serde_json::json!({"lhs": v["lhs"].clone(), "rhs": v["rhs"].clone()})
                    };
                    if !same(&pick(got), &pick(want)) {
                        failures.push(format!("{id}: equation {got}, expected {want}"));
                    }
                }
            }
        }
        if let Some(n) = c["equations_count"].as_u64()
            && eqs.len() as u64 != n
        {
            failures.push(format!("{id}: {} equations, expected {n}", eqs.len()));
        }
        if let Some(want) = c.get("guesses")
            && !same(&md["guesses"], want)
        {
            failures.push(format!("{id}: guesses {}, expected {want}", md["guesses"]));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
