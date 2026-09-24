//! A variable the model declares with NO `shape` is a 0-D quantity, and every
//! `faq` that reads it by name must see a NUMBER (issue #431).
//!
//! The build pipeline is the one place a build-time field's rank is chosen, and
//! it used to choose it from the VALUE: a body that evaluated to a plain number
//! was materialized at shape `[1]` whatever the declaration said. That is one
//! rank too many for an unshaped variable, and the rank is load-bearing —
//! `simulate_array`'s name lookup answers a 0-D entry with a scalar and
//! anything else with an array — so a bare `base` inside a later `faq` body
//! resolved to a rank-1 ARRAY where the body wanted a number and the whole
//! aggregate collapsed to the evaluator's NaN sentinel. Nothing refused: a
//! one-element field still reports the right number when it is read directly,
//! so the scalar looked correct and every aggregate over it was NaN.
//!
//! Three properties are pinned. The first two are measured against arithmetic
//! done here in plain Rust rather than against recorded numbers:
//!
//! 1. **A scalar is readable inside a `faq`, however it is spelled.** The same
//!    document is built four ways — the scalar produced by a fully contracted
//!    `faq` or by a `const` body, and read either by bare name or through a
//!    subscript-free `index(base)` — and all four must give `s[k] = base + k`.
//!    A fifth spelling gives `base` a length-1 AXIS and reads it as
//!    `index(base, 1)`; that one always worked, and it is here so a regression
//!    that breaks the shaped path cannot hide behind the unshaped fix.
//! 2. **The rank comes from the DECLARATION, not from the value.** `base`
//!    declared with no `shape` is a rank-0 field even though its body is a
//!    reduction; `base` declared over a 1-long index set is a rank-1 field of
//!    one element even though its value is a single number. Those two are the
//!    same number and different shapes, which is exactly the distinction the
//!    defect erased.
//! 3. **A subscript on the rank-0 field is REFUSED by name.** Rank 0 is the
//!    right rank, and it makes `index(base, 1)` a subscript on something with
//!    no axes. That spelling resolved while the field was `[1]`, so the fix
//!    moves it — and it must move to a named fault, not to the evaluator's
//!    NaN sentinel, which every `max`/`ifelse`/comparison downstream launders
//!    into a plausible number.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{ProblemInput, ProblemOptions, esm_problem, observed_field};
use serde_json::{Value, json};

/// The index set every spelling sweeps: `v[k] = k` for `k` in `1..=N`.
const N: usize = 4;

/// The oracle, in plain Rust: `base` is the sum of `1..=N` and `s[k]` is
/// `base + k`. Nothing in the library participates.
fn oracle() -> (f64, Vec<f64>) {
    let v: Vec<f64> = (1..=N).map(|k| k as f64).collect();
    let base: f64 = v.iter().sum();
    let s: Vec<f64> = (1..=N).map(|k| base + k as f64).collect();
    (base, s)
}

/// A document whose `s[k] = <base_read> + k`, with `base` declared and defined
/// by the caller. `base_decl` is the variable entry, `base_eq` its equation (or
/// `None` for a variable a `const` body defines inline), and `base_read` the
/// expression `s`'s body reads it through.
fn document(base_decl: Value, base_eq: Option<Value>, base_read: Value) -> Value {
    let mut equations = vec![json!({
        "lhs": "v",
        "rhs": {"op": "faq", "args": [], "output_idx": ["k"],
                "ranges": {"k": {"from": "rows"}}, "expr": "k"}
    })];
    if let Some(eq) = base_eq {
        equations.push(eq);
    }
    equations.push(json!({
        "lhs": "s",
        "rhs": {"op": "faq", "args": [], "output_idx": ["k"],
                "ranges": {"k": {"from": "rows"}},
                "expr": {"op": "+", "args": [base_read, "k"]}}
    }));
    json!({
        "esm": "1.2.0",
        "metadata": {"name": "ScalarOperand", "authors": ["regression"], "tags": ["probe"],
                     "description": "base is a scalar; s[k] = base + k."},
        "index_sets": {"rows": {"kind": "interval", "size": N}, "one": {"kind": "interval", "size": 1}},
        "models": {"ScalarOperand": {
            "variables": {
                "v": {"type": "unknown", "units": "1", "shape": ["rows"], "description": "1..N."},
                "base": base_decl,
                "s": {"type": "unknown", "units": "1", "shape": ["rows"], "description": "base + k."}
            },
            "equations": equations
        }}
    })
}

/// `base` declared with no `shape`, defined by a fully contracted `faq`.
fn unshaped_sum() -> (Value, Option<Value>) {
    (
        json!({"type": "unknown", "units": "1", "description": "Their sum, as a SCALAR."}),
        Some(json!({
            "lhs": "base",
            "rhs": {"op": "faq", "args": [], "output_idx": [],
                    "ranges": {"k": {"from": "rows"}}, "reduce": "+",
                    "expr": {"op": "index", "args": ["v", "k"]}}
        })),
    )
}

/// The same variable, defined by a `const` body rather than by a reduction —
/// the spelling that shows the defect was in the unshaped VARIABLE and not in
/// the reduction that happened to produce it.
fn unshaped_const(value: f64) -> (Value, Option<Value>) {
    (
        json!({"type": "unknown", "units": "1", "description": "A scalar constant."}),
        Some(json!({"lhs": "base", "rhs": {"op": "const", "args": [], "value": value}})),
    )
}

/// `base` declared over a 1-long axis but DEFINED by a plain number. The
/// declaration keeps the axis, so the field is `[1]` — the one case the
/// non-scalar arm of the rank decision actually decides, and the one where
/// `[1]` is also the declared extent.
fn shaped_const(value: f64) -> (Value, Option<Value>) {
    (
        json!({"type": "unknown", "units": "1", "shape": ["one"],
               "description": "A scalar body on a 1-long axis."}),
        Some(json!({"lhs": "base", "rhs": {"op": "const", "args": [], "value": value}})),
    )
}

/// `base` declared over a 1-long axis: a rank-1 field of one element, read
/// through a subscript. This spelling was never broken.
fn axis_of_one() -> (Value, Option<Value>) {
    (
        json!({"type": "unknown", "units": "1", "shape": ["one"], "description": "Their sum, on a 1-long axis."}),
        Some(json!({
            "lhs": "base",
            "rhs": {"op": "faq", "args": [], "output_idx": ["j"],
                    "ranges": {"j": {"from": "one"}, "k": {"from": "rows"}}, "reduce": "+",
                    "expr": {"op": "index", "args": ["v", "k"]}}
        })),
    )
}

/// The build the CLI takes for a document with nothing to integrate: the
/// pipeline ON, which is what materializes a SHAPED field (`esm simulate`
/// rebuilds this way, and the inline-test runner retries this way).
fn opts() -> ProblemOptions {
    ProblemOptions {
        // The pipeline's per-cell walk is refused by a strict native (#484), so
        // these semantics are checked on the reference evaluator.
        compiler: Some(earthsci_ast::Compiler::Interpreter),
        build_pipeline: true,
        ..Default::default()
    }
}

/// Build `doc` and read one field back, flattened to a `Vec` in its own order.
fn field(doc: &Value, name: &str) -> Vec<f64> {
    let prob = esm_problem(ProblemInput::Json(doc), (0.0, 0.0), opts())
        .unwrap_or_else(|e| panic!("esm_problem: {e}"));
    let a = observed_field(&prob, name).unwrap_or_else(|e| panic!("observed_field({name}): {e}"));
    a.iter().copied().collect()
}

/// Build `doc` and read one field back, keeping whichever error came first.
/// Construction and the read are two chances to refuse, and a fail-closed
/// diagnostic may surface at either.
fn build_error(doc: &Value, name: &str) -> String {
    match esm_problem(ProblemInput::Json(doc), (0.0, 0.0), opts()) {
        Err(e) => e.to_string(),
        Ok(prob) => match observed_field(&prob, name) {
            Err(e) => e.to_string(),
            Ok(a) => panic!(
                "expected a refusal, got {name} = {:?}",
                a.iter().collect::<Vec<_>>()
            ),
        },
    }
}

/// The rank a field comes back with.
fn field_shape(doc: &Value, name: &str) -> Vec<usize> {
    let prob = esm_problem(ProblemInput::Json(doc), (0.0, 0.0), opts())
        .unwrap_or_else(|e| panic!("esm_problem: {e}"));
    let a = observed_field(&prob, name).unwrap_or_else(|e| panic!("observed_field({name}): {e}"));
    a.shape().to_vec()
}

#[test]
fn every_spelling_of_a_scalar_reads_inside_a_faq() {
    let (base, s_want) = oracle();

    let (unshaped_decl, unshaped_eq) = unshaped_sum();
    let (const_decl, const_eq) = unshaped_const(base);
    let (axis_decl, axis_eq) = axis_of_one();

    let cases: Vec<(&str, Value)> = vec![
        (
            "a contracted faq, read by bare name",
            document(unshaped_decl.clone(), unshaped_eq.clone(), json!("base")),
        ),
        (
            "a contracted faq, read as index(base) with no subscript",
            document(
                unshaped_decl,
                unshaped_eq,
                json!({"op": "index", "args": ["base"]}),
            ),
        ),
        (
            "a const scalar, read by bare name",
            document(const_decl.clone(), const_eq.clone(), json!("base")),
        ),
        (
            "a const scalar, read as index(base) with no subscript",
            document(
                const_decl,
                const_eq,
                json!({"op": "index", "args": ["base"]}),
            ),
        ),
        (
            "a 1-long axis, read as index(base, 1)",
            document(
                axis_decl,
                axis_eq,
                json!({"op": "index", "args": ["base", 1]}),
            ),
        ),
    ];

    for (label, doc) in cases {
        let got_base = field(&doc, "base");
        assert_eq!(
            got_base.len(),
            1,
            "[{label}] base holds exactly one number whatever its rank"
        );
        assert_eq!(
            got_base[0], base,
            "[{label}] the scalar itself was always right; it is the read that failed"
        );
        let got_s = field(&doc, "s");
        assert!(
            got_s.iter().all(|x| x.is_finite()),
            "[{label}] s came back {got_s:?}: a scalar operand that reads as NaN is \
             exactly issue #431, and a silent NaN is the worst available outcome"
        );
        assert_eq!(got_s, s_want, "[{label}] s[k] must be base + k");
    }
}

#[test]
fn a_fields_rank_is_its_declarations_not_its_values() {
    let (unshaped_decl, unshaped_eq) = unshaped_sum();
    let (axis_decl, axis_eq) = axis_of_one();

    let unshaped = document(unshaped_decl, unshaped_eq, json!("base"));
    let shaped = document(
        axis_decl,
        axis_eq,
        json!({"op": "index", "args": ["base", 1]}),
    );

    assert_eq!(
        field_shape(&unshaped, "base"),
        Vec::<usize>::new(),
        "a variable declared with no `shape` is a rank-0 field, however its body \
         happened to be written"
    );
    assert_eq!(
        field_shape(&shaped, "base"),
        vec![1],
        "a variable declared over a 1-long index set keeps that axis, even though \
         its value is a single number"
    );
    // The two carry the same number: the rank is the only thing that differs,
    // which is why the defect was silent.
    assert_eq!(field(&unshaped, "base"), field(&shaped, "base"));

    // And a shaped variable is untouched by the rank decision.
    assert_eq!(field_shape(&unshaped, "s"), vec![N]);

    // The other arm: a DECLARED SHAPE keeps its axis even when the body is a
    // plain number, which is the only thing the non-scalar arm decides. A
    // 1-long axis is the case where `[1]` is also the declared extent, so this
    // pins the arm without pinning the broadcast gap (issue #219) alongside it.
    let (const_axis_decl, const_axis_eq) = shaped_const(7.0);
    let shaped_const_doc = document(
        const_axis_decl,
        const_axis_eq,
        json!({"op": "index", "args": ["base", 1]}),
    );
    assert_eq!(
        field_shape(&shaped_const_doc, "base"),
        vec![1],
        "a scalar body under a declared 1-long axis keeps that axis"
    );
    assert_eq!(field(&shaped_const_doc, "base"), vec![7.0]);
}

/// A SUBSCRIPT on an unshaped scalar is refused by name, not answered with a
/// number.
///
/// Making an unshaped variable rank-0 makes `index(base, 1)` — which resolved
/// while the field was rank-1 `[1]` — a subscript on a value with no axes.
/// The evaluator returned a bare NaN for that, so the document that used to
/// print a number printed `NaN` instead, and `esm validate` still accepted it.
/// A NaN is the worst outcome available here: `max(x, 0)`, `ifelse` and every
/// comparison launder one into a plausible number, so the wrong answer travels
/// with nothing attached saying it is wrong. The fault is latched on the same
/// channel as the other fail-closed gathers and names the offending base.
#[test]
fn a_subscript_on_an_unshaped_scalar_is_a_named_fault() {
    let (const_decl, const_eq) = unshaped_const(3.0);
    let subscripted = document(
        const_decl,
        const_eq,
        json!({"op": "index", "args": ["base", 1]}),
    );
    let msg = build_error(&subscripted, "s");
    assert!(
        msg.contains("E_TREEWALK_INDEX_ON_SCALAR"),
        "the refusal must carry the code, so a reader can look it up: {msg}"
    );
    assert!(
        msg.contains("base"),
        "the refusal must name what was subscripted: {msg}"
    );
    // The identity spelling is NOT this condition: `index(base)` with no
    // subscript still reads the scalar. Without this, a check that refused
    // every `index` on a 0-D value would pass the assertions above and break
    // the spelling issue #431 exists to support.
    let (const_decl, const_eq) = unshaped_const(3.0);
    let identity = document(
        const_decl,
        const_eq,
        json!({"op": "index", "args": ["base"]}),
    );
    assert_eq!(field(&identity, "s"), vec![4.0, 5.0, 6.0, 7.0]);
}
