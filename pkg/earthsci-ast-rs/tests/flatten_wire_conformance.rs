//! `tests/conformance/flatten_wire/`: the flattened system as this binding
//! writes it out, byte for byte against the shared golden every binding
//! writes (esm-spec §9.6.11, "A flattened system keeps its applications'
//! meaning on the wire"; esm-libraries-spec §4.7.5, "Pointwise lift: operands
//! read per cell"). The golden form is in the case directory's README. Each
//! written-out system is also read back and built under both compilers, and
//! must give the initial state and right-hand side the original gives, bit
//! for bit, or be refused where the original is.
//!
//! `flatten` keeps operator references (esm-spec §9.6.4). Each case's
//! `refs_golden` is the flattened system with its references kept and the
//! registry entries they reach; `golden` is its expansion, made here by
//! [`expanded`], an expansion local to this test (the crate's flatten and
//! build never expand a reference).
#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{
    Compiler, EsmFile, FlattenedSystem, ProblemOptions, esm_problem, flatten,
    format_canonical_float, initial_state, load_path, load_string, rhs_program,
};
use indexmap::IndexMap;
use serde_json::{Value, json};
use std::collections::HashMap;

use crate::common;

/// `v` as canonical JSON: keys sorted by code point, no whitespace, integers
/// as written, floats through `format_canonical_float`.
fn canonical(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => match (n.as_i64(), n.as_u64()) {
            (Some(i), _) => out.push_str(&i.to_string()),
            (None, Some(u)) => out.push_str(&u.to_string()),
            _ => out.push_str(&format_canonical_float(n.as_f64().unwrap())),
        },
        Value::String(s) => out.push_str(&serde_json::to_string(s).unwrap()),
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical(x, out);
            }
            out.push(']');
        }
        Value::Object(o) => {
            let mut keys: Vec<&String> = o.keys().collect();
            keys.sort();
            out.push('{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::to_string(k).unwrap());
                out.push(':');
                canonical(&o[k], out);
            }
            out.push('}');
        }
    }
}

/// The golden form of `flat`: its equations and field initial conditions as
/// they serialize, and every variable's declared shape.
fn wire_form(flat: &FlattenedSystem) -> String {
    let equations: Vec<Value> = flat
        .equations
        .iter()
        .map(|e| {
            json!({
                "lhs": serde_json::to_value(&e.lhs).unwrap(),
                "rhs": serde_json::to_value(&e.rhs).unwrap(),
            })
        })
        .collect();
    let field_ics: Vec<Value> = flat
        .field_ics
        .iter()
        .map(|(target, rhs)| json!({"target": target, "rhs": serde_json::to_value(rhs).unwrap()}))
        .collect();
    let mut shapes = serde_json::Map::new();
    for part in [
        &flat.state_variables,
        &flat.parameters,
        &flat.observed_variables,
    ] {
        for (name, var) in part {
            shapes.insert(name.clone(), json!(var.shape));
        }
    }
    let mut out = String::new();
    canonical(
        &json!({"equations": equations, "field_ics": field_ics, "shapes": shapes}),
        &mut out,
    );
    out.push('\n');
    out
}

/// The flattened system with its references kept: the equations and field
/// initial conditions as they serialize, and every registry entry they
/// reach, through the bodies of the entries they reach (the Julia test's
/// `_fw_refs_form`).
fn refs_form(flat: &FlattenedSystem) -> String {
    let wire = |e: &earthsci_ast::Expr| serde_json::to_value(e).unwrap();
    let equations: Vec<Value> = flat
        .equations
        .iter()
        .map(|e| json!({"lhs": wire(&e.lhs), "rhs": wire(&e.rhs)}))
        .collect();
    let field_ics: Vec<Value> = flat
        .field_ics
        .iter()
        .map(|(target, rhs)| json!({"target": target, "rhs": wire(rhs)}))
        .collect();
    let roots = flat
        .equations
        .iter()
        .flat_map(|e| [&e.lhs, &e.rhs])
        .chain(flat.field_ics.iter().map(|(_, r)| r));
    let templates: serde_json::Map<String, Value> = flat
        .operators()
        .reachable(roots)
        .into_iter()
        .map(|n| {
            let decl = flat.template_registry[&n].clone();
            (n, decl)
        })
        .collect();
    let mut out = String::new();
    canonical(
        &json!({"equations": equations, "field_ics": field_ics, "templates": templates}),
        &mut out,
    );
    out.push('\n');
    out
}

/// `v` (an expression on the wire) with every reference replaced by its
/// expansion against `reg` (esm-spec §9.6.4 rule 2): the definition's body
/// with each parameter, wherever the body spells it (never a reference's
/// `name`), replaced by the binding's expansion. For this test's comparison
/// with the expanded golden only.
fn expand_value(v: &Value, reg: &IndexMap<String, Value>) -> Value {
    fn substitute(body: &Value, b: &serde_json::Map<String, Value>) -> Value {
        match body {
            Value::String(s) => b.get(s).cloned().unwrap_or_else(|| body.clone()),
            Value::Array(a) => Value::Array(a.iter().map(|x| substitute(x, b)).collect()),
            Value::Object(o) => {
                let is_ref = o.get("op").and_then(Value::as_str) == Some("apply_operator");
                Value::Object(
                    o.iter()
                        .map(|(k, x)| {
                            let x = if is_ref && k == "name" {
                                x.clone()
                            } else {
                                substitute(x, b)
                            };
                            (k.clone(), x)
                        })
                        .collect(),
                )
            }
            _ => body.clone(),
        }
    }
    match v {
        Value::Object(o) if o.get("op").and_then(Value::as_str) == Some("apply_operator") => {
            let name = o["name"].as_str().unwrap();
            let decl = reg
                .get(name)
                .unwrap_or_else(|| panic!("no registry entry {name}"));
            let bindings: serde_json::Map<String, Value> = o
                .get("bindings")
                .and_then(Value::as_object)
                .map(|b| {
                    b.iter()
                        .map(|(k, x)| (k.clone(), expand_value(x, reg)))
                        .collect()
                })
                .unwrap_or_default();
            expand_value(&substitute(&decl["body"], &bindings), reg)
        }
        Value::Object(o) => Value::Object(
            o.iter()
                .map(|(k, x)| (k.clone(), expand_value(x, reg)))
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.iter().map(|x| expand_value(x, reg)).collect()),
        _ => v.clone(),
    }
}

/// `flat` with every reference in its equations, their contributions and its
/// field initial conditions expanded ([`expand_value`]), as the Julia tests'
/// `expand_flattened_refs` gives the expanded form.
pub(crate) fn expanded(flat: &FlattenedSystem) -> FlattenedSystem {
    let reg = &flat.template_registry;
    let ex = |e: &earthsci_ast::Expr| -> earthsci_ast::Expr {
        serde_json::from_value(expand_value(&serde_json::to_value(e).unwrap(), reg)).unwrap()
    };
    let mut out = flat.clone();
    for eq in &mut out.equations {
        eq.lhs = ex(&eq.lhs);
        eq.rhs = ex(&eq.rhs);
    }
    for (_, rhs) in &mut out.field_ics {
        *rhs = ex(rhs);
    }
    for cs in &mut out.equation_contributions {
        for c in cs {
            c.expr = ex(&c.expr);
        }
    }
    out
}

/// The flattened system written as a document, as a consumer that splits it
/// into derived documents does: one model per component, each variable with
/// its declared type, `shape` and `default`, each equation and each field
/// initial condition (as `ic(x) = rhs`) in the model that owns its subject,
/// every reference fully qualified.
pub(crate) fn flattened_document(flat: &FlattenedSystem) -> Value {
    // The planner writes the expanded system (references expanded at its
    // own boundary, esm-spec §9.6.4 rule 2).
    let flat = &expanded(flat);
    fn owner(name: &str) -> &str {
        name.rsplit_once('.').expect("dotted").0
    }
    let mut models = serde_json::Map::new();
    for (kind, part) in [
        ("unknown", &flat.state_variables),
        ("parameter", &flat.parameters),
        ("unknown", &flat.observed_variables),
    ] {
        for (name, var) in part {
            let (component, local) = name.rsplit_once('.').expect("dotted");
            let model = models
                .entry(component.to_string())
                .or_insert_with(|| json!({"variables": {}, "equations": []}));
            let mut decl = json!({"type": kind});
            if let Some(shape) = var.shape.as_ref().filter(|s| !s.is_empty()) {
                decl["shape"] = json!(shape);
            }
            if let Some(d) = &var.default {
                decl["default"] = serde_json::to_value(d).unwrap();
            }
            model["variables"][local] = decl;
        }
    }
    let mut push = |subject: &str, lhs: Value, rhs: Value| {
        models[owner(subject)]["equations"]
            .as_array_mut()
            .unwrap()
            .push(json!({"lhs": lhs, "rhs": rhs}));
    };
    for eq in &flat.equations {
        let lhs = serde_json::to_value(&eq.lhs).unwrap();
        // The first name the left-hand side reads: the variable, or the
        // differentiated (possibly pointwise-lifted) state.
        let text = lhs.to_string();
        let subject = text
            .split('"')
            .find(|t| t.contains('.') && !t.starts_with('.'))
            .expect("a qualified subject")
            .to_string();
        push(&subject, lhs, serde_json::to_value(&eq.rhs).unwrap());
    }
    for (target, rhs) in &flat.field_ics {
        push(
            target,
            json!({"op": "ic", "args": [target]}),
            serde_json::to_value(rhs).unwrap(),
        );
    }
    let sets: serde_json::Map<String, Value> = flat
        .index_sets
        .iter()
        .map(|(k, v)| (k.clone(), serde_json::to_value(v).unwrap()))
        .collect();
    json!({"esm": "1.3.0", "metadata": {"name": "written"}, "index_sets": sets, "models": models})
}

/// The initial state and the right-hand side at it, by state name, under
/// `compiler`; `Err` when the build refuses `file`.
fn built(file: &EsmFile, compiler: Compiler) -> Result<Vec<(String, u64, u64)>, String> {
    let opts = ProblemOptions {
        compiler: Some(compiler),
        ..Default::default()
    };
    let prob = esm_problem(file, (0.0, 1.0), opts).map_err(|e| e.to_string())?;
    let prog = rhs_program(&prob).map_err(|e| e.to_string())?;
    let u = initial_state(&prob).map_err(|e| e.to_string())?;
    let p = prog
        .parameter_vector(&HashMap::new())
        .map_err(|e| e.to_string())?;
    let mut ws = prog.new_workspace();
    let mut du = vec![0.0; prog.n_states()];
    prog.eval_into(&u, &[], &p, 0.0, &prog.default_forcing(), &mut du, &mut ws)
        .map_err(|e| e.to_string())?;
    let mut rows = Vec::new();
    for b in prog.state_layout() {
        let n: usize = b.shape.iter().product::<usize>().max(1);
        for k in 0..n {
            let at = b.flat_offset + k;
            rows.push((
                format!("{}[{k}]", b.name),
                u[at].to_bits(),
                du[at].to_bits(),
            ));
        }
    }
    rows.sort();
    Ok(rows)
}

#[test]
fn the_flattened_system_on_the_wire_matches_the_shared_golden() {
    for (name, _, file) in cases() {
        let kept = flatten(&file).unwrap_or_else(|e| panic!("{name}: {e}"));
        // The flattened system with its references kept (esm-spec §9.6.4,
        // §9.6.11), byte for byte.
        let case = &case_entries()[&name];
        let dir = common::category_dir("flatten_wire");
        let refs_golden = case["refs_golden"].as_str().expect("a refs_golden");
        let got = refs_form(&kept);
        let want = std::fs::read_to_string(dir.join(refs_golden)).unwrap();
        assert!(
            got == want,
            "{name}: the flattened form with references kept differs from the golden\n got: {got}\nwant: {want}"
        );
        // Its expansion, the form a consumer that expands at its boundary
        // writes out.
        let got = wire_form(&expanded(&kept));
        let want = std::fs::read_to_string(dir.join(case["golden"].as_str().unwrap())).unwrap();
        assert!(
            got == want,
            "{name}: the flattened wire form differs from the golden\n got: {got}\nwant: {want}"
        );
    }
}

/// Every case of `cases.json`, by name.
fn case_entries() -> serde_json::Map<String, Value> {
    let dir = common::category_dir("flatten_wire");
    let cases: Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("cases.json")).unwrap()).unwrap();
    let cases = cases["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 8);
    cases
        .iter()
        .map(|c| (c["name"].as_str().unwrap().to_string(), c.clone()))
        .collect()
}

/// Every case: its name, whether the reference evaluator builds it, and its
/// fixture loaded.
fn cases() -> Vec<(String, bool, EsmFile)> {
    let dir = common::category_dir("flatten_wire");
    case_entries()
        .into_iter()
        .map(|(name, case)| {
            let file = load_path(dir.join(case["fixture"].as_str().unwrap()))
                .unwrap_or_else(|e| panic!("{name}: {e}"));
            (name, case["builds"].as_bool().unwrap(), file)
        })
        .collect()
}

/// The flattened system written out (expanded, as the planner writes it) and
/// read back builds under both compilers to the original's initial state and
/// right-hand side, bit for bit, or is refused where the original is.
#[test]
fn the_written_out_system_builds_as_the_original() {
    for (name, builds, file) in cases() {
        let flat = expanded(&flatten(&file).unwrap_or_else(|e| panic!("{name}: {e}")));
        let text = flattened_document(&flat).to_string();
        let back = load_string(&text).unwrap_or_else(|e| panic!("{name}: read back: {e}\n{text}"));
        for compiler in [Compiler::Interpreter, Compiler::Native] {
            let original = built(&file, compiler);
            let written = built(&back, compiler);
            // `native` declines a rule holding an operator reference until it
            // compiles a definition as a called function (QUESTIONS.md Q1);
            // the read-back system is expanded, so the two cannot agree yet.
            if compiler == Compiler::Native
                && original.as_ref().is_err_and(|e| {
                    format!("{e:?}")
                        .contains("the native compiler does not yet compile a definition")
                })
            {
                eprintln!("skip  {name} under native: QUESTIONS.md Q1");
                continue;
            }
            match (&original, &written) {
                (Ok(o), Ok(w)) => assert_eq!(o, w, "{name} under {compiler:?}"),
                (Err(_), Err(_)) => {}
                _ => panic!(
                    "{name} under {compiler:?}: the original and the read-back system \
                     disagree on building: {original:?} vs {written:?}"
                ),
            }
            // `builds` is the reference evaluator's verdict; a strict compiler
            // may refuse more, provided it refuses the read-back system too.
            if compiler == Compiler::Interpreter {
                assert_eq!(original.is_ok(), builds, "{name}: {original:?}");
            }
        }
    }
}

/// The template-origin mark is load provenance (esm-spec §9.6.11): a document
/// that spells it is refused by the schema, as in every binding, rather than
/// read as a template application.
#[test]
fn an_authored_template_origin_mark_is_refused() {
    let doc = json!({
        "esm": "1.3.0", "metadata": {"name": "authored_mark"},
        "index_sets": {"c": {"kind": "interval", "size": 3}},
        "models": {"M": {
            "variables": {
                "u": {"type": "parameter", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
                "y": {"type": "unknown"}
            },
            "equations": [{"lhs": "y", "rhs": {
                "op": "faq", "args": [], "output_idx": [],
                "ranges": {"k": {"from": "c"}},
                "__esm_template_origin": "linear", "expr": "u"
            }}]
        }}
    });
    let err = load_string(&doc.to_string()).expect_err("an authored mark is refused");
    assert!(err.to_string().contains("__esm_template_origin"), "{err}");
}
