//! The operator registry: the single source of truth for **which `op` strings
//! exist** and **how many `args` each one takes** (esm-spec §4.2 / §4.3).
//!
//! Before this module the crate had no arity check anywhere — neither
//! [`crate::validate`] nor [`crate::structural`] — and the schema deliberately
//! leaves `args` at `minItems: 0`, because a *schema* cannot express "`atan2`
//! takes exactly two arguments but `+` takes any number". The result was that a
//! malformed-but-schema-valid node reached the evaluators, where the two of them
//! disagreed about what it meant: the per-cell oracle
//! ([`crate::simulate_array::eval`]) folded `-(3,1,1)` to `NaN` while the
//! vectorized overlay ([`crate::simulate_array::vectorized`]) left-folded it to
//! `1.0`, and `atan2` with one argument indexed `args[1]` and **panicked**.
//!
//! The registry closes that class of bug at the source: an op/arity pair that
//! this table rejects never reaches an evaluator, so the evaluators are only
//! ever asked to agree on nodes that are *legal*, and for those they agree by
//! construction.
//!
//! # The two tiers (esm-spec §4.2)
//!
//! - **Evaluable core (closed).** Everything in [`arity_of`]. Adding one is a
//!   spec change. A core op with the wrong arity is a hard error
//!   ([`OpError::Arity`]).
//! - **Rewrite-target (open).** Everything else — the sugar ops
//!   `grad`/`div`/`laplacian`/`curl`/`∇`/`integral`, a *spatial* `D`, and any
//!   user-defined op. These have **no evaluator**; they MUST be eliminated by a
//!   rewrite rule (§9.6) before evaluation. Reaching an evaluator with one still
//!   present is [`OpError::Unlowered`] → diagnostic `unlowered_operator`.
//!
//! A **misspelled** op (`"expp"`) is, formally, an open-tier op for which no
//! rewrite rule exists — so it lands in the same `unlowered_operator` bucket
//! rather than being silently evaluated to `NaN`. That is the spec's own answer
//! (§9.6.3 constraint 6: "any node whose `op` is not in the evaluable-core set
//! … is rejected with diagnostic `unlowered_operator`"), and it is why a typo is
//! now loud instead of quietly poisoning a trajectory with `NaN`.

use crate::types::{Expr, ExpressionNode};

/// How many `args` an evaluable-core operator accepts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Arity {
    /// Exactly `n` arguments (`atan2` → 2, `ifelse` → 3, `const` → 0).
    Exact(usize),
    /// Between `lo` and `hi` inclusive (`-` → 1 or 2: negation or subtraction).
    Between(usize, usize),
    /// At least `n` (`+`/`*` are n-ary; `min`/`max` are n-ary with `n >= 2`).
    AtLeast(usize),
    /// Any arity, including zero. Used by the ops whose operands do not live in
    /// `args` at all (`aggregate`/`makearray` carry them in `expr`/`values`;
    /// `fn` defers to the closed-function registry's own signature check).
    Any,
}

impl Arity {
    /// Does `n` satisfy this arity?
    #[must_use]
    pub fn admits(self, n: usize) -> bool {
        match self {
            Self::Exact(k) => n == k,
            Self::Between(lo, hi) => n >= lo && n <= hi,
            Self::AtLeast(k) => n >= k,
            Self::Any => true,
        }
    }

    /// Human-readable expectation, for diagnostics.
    #[must_use]
    pub fn describe(self) -> String {
        match self {
            Self::Exact(k) => format!("exactly {k}"),
            Self::Between(lo, hi) => format!("{lo} or {hi}"),
            Self::AtLeast(k) => format!("at least {k}"),
            Self::Any => "any number of".to_string(),
        }
    }
}

/// What is wrong with an operator node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpError {
    /// A known evaluable-core op applied to the wrong number of arguments.
    Arity {
        /// The operator name.
        op: String,
        /// How many arguments it was given.
        got: usize,
        /// What the spec says it takes.
        expected: String,
    },
    /// A rewrite-target op (sugar, spatial `D`, user op, or a typo) reached
    /// evaluation without being lowered. Diagnostic code `unlowered_operator`.
    Unlowered {
        /// The operator name.
        op: String,
    },
    /// A `makearray` whose `regions` are ragged (regions disagreeing on rank)
    /// or carry an inverted bound pair. Diagnostic code
    /// `makearray_region_inverted` (esm-spec §4.3.2).
    MakearrayRegion {
        /// What is wrong with the regions.
        reason: String,
    },
}

impl std::fmt::Display for OpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Arity { op, got, expected } => {
                write!(f, "operator '{op}' takes {expected} argument(s), got {got}")
            }
            Self::Unlowered { op } => write!(
                f,
                "operator '{op}' has no evaluator and was not lowered by any rewrite rule"
            ),
            Self::MakearrayRegion { reason } => write!(f, "{reason}"),
        }
    }
}

/// Validate a `makearray` node's `regions` block (esm-spec §4.3.2).
///
/// Two things can be wrong with it, and both used to **panic** the per-cell
/// evaluator rather than being reported:
///
/// 1. **Ragged regions.** `eval_makearray` took its rank from `regions[0]` and
///    then indexed `lo[d]`/`hi[d]` for every `d` of *every* region, so a second
///    region of higher rank ran off the end of the bounding box.
/// 2. **An inverted bound pair.** The bounding-box extent `hi - lo + 1` was cast
///    `as usize`, so a reversed region such as `[5, 2]` produced an extent of
///    `-2`, wrapped to `usize::MAX - 1`, and blew up in `ArrayD::zeros` with a
///    capacity overflow.
///
/// The spec draws the line precisely: `stop == start - 1` is the canonical
/// **empty** region — it is what a metaparameter-folded interior region
/// (`[2, N-1]` at `N = 2`) legitimately produces, contributes no cells, and MUST
/// load cleanly. Anything *further* inverted (`stop < start - 1`) is an
/// authoring error and is rejected with `makearray_region_inverted`.
///
/// # Errors
///
/// [`OpError::MakearrayRegion`] naming the offending region.
pub fn check_makearray_regions(node: &ExpressionNode) -> Result<(), OpError> {
    let Some(regions) = node.regions.as_deref() else {
        return Ok(());
    };
    let bad = |reason: String| Err(OpError::MakearrayRegion { reason });

    if let Some(values) = node.values.as_deref()
        && values.len() != regions.len()
    {
        return bad(format!(
            "makearray has {} region(s) but {} value(s) — they must correspond one-to-one",
            regions.len(),
            values.len()
        ));
    }

    let Some(first) = regions.first() else {
        return Ok(());
    };
    let ndim = first.len();
    for (i, region) in regions.iter().enumerate() {
        if region.len() != ndim {
            return bad(format!(
                "makearray region {i} has rank {} but region 0 has rank {ndim} — every region \
                 must address the same number of dimensions",
                region.len()
            ));
        }
        for (d, pair) in region.iter().enumerate() {
            let [start, stop] = *pair;
            // `stop == start - 1` is the legal empty spelling; only a further
            // inversion is an error.
            if stop < start - 1 {
                return bad(format!(
                    "makearray region {i} dimension {d} has inverted bounds [{start}, {stop}]: \
                     stop < start - 1 (the empty spelling [{start}, {}] is legal, anything \
                     further inverted is not)",
                    start - 1
                ));
            }
        }
    }
    Ok(())
}

/// The rewrite-target sugar ops (esm-spec §4.2 / §9.6.8): differential-operator
/// shorthand with no evaluator. One list feeds the compile-time reject walk and
/// the runtime backstop in `eval_op`.
pub const REWRITE_TARGET_SUGAR: [&str; 6] = ["grad", "div", "laplacian", "curl", "∇", "integral"];

/// The arity of an evaluable-core operator, or `None` if `op` is not in the
/// closed core set (esm-spec §4.2) — i.e. it is an open-tier rewrite target.
///
/// The unary elementary functions are grouped; every arity here is the one the
/// spec's §4.2 tables state.
#[must_use]
pub fn arity_of(op: &str) -> Option<Arity> {
    let a = match op {
        // --- Arithmetic (§4.2). `+`/`*` are n-ary; `-` is unary OR binary;
        // `/` and `^` are strictly binary.
        "+" | "*" => Arity::AtLeast(1),
        "-" => Arity::Between(1, 2),
        "/" | "^" => Arity::Exact(2),
        // `neg` is the canonical unary negation `canonicalize.rs` emits.
        "neg" => Arity::Exact(1),

        // --- Elementary functions (§4.2). All unary except `atan2` and
        // `min`/`max`.
        "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil" | "sin"
        | "cos" | "tan" | "asin" | "acos" | "atan" | "sinh" | "cosh" | "tanh" | "asinh"
        | "acosh" | "atanh" => Arity::Exact(1),
        "atan2" => Arity::Exact(2),
        // "n-ary with arity >= 2 … Conforming bindings MUST reject `min`/`max`
        // nodes with fewer than two arguments." (§4.2)
        "min" | "max" => Arity::AtLeast(2),

        // --- Conditionals / logic (§4.2).
        "ifelse" => Arity::Exact(3),
        "==" | "!=" | "<" | "<=" | ">" | ">=" => Arity::Exact(2),
        "and" | "or" => Arity::AtLeast(2),
        "not" => Arity::Exact(1),

        // --- Calculus (§4.2). A `D` with `wrt: "t"` is the structural time
        // derivative (evaluable-core); a SPATIAL `D` is a rewrite target and is
        // caught by `classify` below, which inspects `wrt`.
        "D" | "ic" => Arity::Exact(1),

        // --- Events (§4.2).
        "Pre" => Arity::Exact(1),

        // --- Inline constants (§4.2): "`args` MUST be empty `[]`".
        "const" => Arity::Exact(0),
        // Nullary boolean literal — an always-true join/`filter` predicate (§4.3).
        "true" => Arity::Exact(0),

        // --- Closed-registry invocation (§4.2 / §9.2). The registry checks the
        // per-function signature itself (`unknown_closed_function`), so arity is
        // open here.
        "fn" => Arity::Any,
        // Lowered at load time (§4.5 / §9.5). `enum` is `[enum_name, symbol]`;
        // `table_lookup` carries its inputs in `axes`, so "`args` MUST be empty".
        "enum" => Arity::Exact(2),
        "table_lookup" => Arity::Exact(0),
        // Expanded at load time (§9.6); its operands live in `bindings`.
        "apply_expression_template" => Arity::Any,

        // --- Array / tensor (§4.3). `aggregate` and `makearray` carry their
        // real operands in `expr` / `values`, and `args` is conventionally the
        // (possibly empty) operand list, so their arity is open.
        "aggregate" => Arity::Any,
        "makearray" => Arity::Any,
        // "`args[0]` is the array; `args[1..]` are the index expressions."
        "index" => Arity::AtLeast(1),
        "broadcast" => Arity::AtLeast(1),
        "reshape" | "transpose" => Arity::Exact(1),
        "concat" => Arity::AtLeast(1),

        // --- Relational / value-invention & geometry (§4.3 companions). These
        // are BUILD-TIME ops, evaluated by `value_invention.rs` (not by the
        // per-cell oracle), so they are known-and-legal here even though
        // `eval_op` has no arm for them. Their operand shapes are checked by
        // that evaluator.
        "skolem" | "rank" | "distinct" => Arity::Any,
        "argmin" | "argmax" => Arity::Any,
        "intersect_polygon" | "polygon_intersection_area" => Arity::Exact(2),

        _ => return None,
    };
    Some(a)
}

/// Is `op` an evaluable-core operator (esm-spec §4.2)?
#[must_use]
pub fn is_core_op(op: &str) -> bool {
    arity_of(op).is_some()
}

/// Classify one operator node: `Ok(())` if it is an evaluable-core op with a
/// legal arity, otherwise the reason it may not reach an evaluator.
///
/// A `D` node is the one op whose tier depends on a *field* rather than its
/// name: `wrt: "t"` is the structural time derivative (core), while a spatial
/// `wrt` is a rewrite target (§4.2). `check_node` is where that distinction
/// lives, so every caller inherits it.
///
/// # Errors
///
/// [`OpError::Unlowered`] for an open-tier op (sugar, spatial `D`, user op, or a
/// misspelling); [`OpError::Arity`] for a core op with the wrong argument count.
pub fn check_node(node: &ExpressionNode) -> Result<(), OpError> {
    let op = node.op.as_str();

    // A spatial `D` — or any `D` carrying a non-time `wrt` — is a rewrite
    // target, not the structural time derivative.
    if op == "D" && node.wrt.as_deref().is_some_and(|w| w != "t") {
        return Err(OpError::Unlowered { op: op.to_string() });
    }

    let Some(arity) = arity_of(op) else {
        // Open tier: the named sugar ops and anything unrecognised (including a
        // typo) share one diagnostic — `unlowered_operator` (§9.6.3 c.6).
        return Err(OpError::Unlowered { op: op.to_string() });
    };

    if !arity.admits(node.args.len()) {
        return Err(OpError::Arity {
            op: op.to_string(),
            got: node.args.len(),
            expected: arity.describe(),
        });
    }

    // `makearray` carries its real structure in `regions`/`values`, not `args`,
    // so arity alone says nothing about whether it is well-formed.
    if op == "makearray" {
        check_makearray_regions(node)?;
    }
    Ok(())
}

/// Walk an expression tree and return the first operator node that may not
/// reach an evaluator.
///
/// The walk uses [`ExpressionNode::for_each_child`], the crate's one-walker
/// keystone, so it descends into every expression-bearing sidecar field
/// (`expr`, `values`, `filter`, `key`, `axes`, `bindings`, …) and not merely
/// `args` — a hand-rolled `args`-only walk would miss exactly the
/// `aggregate.expr` bodies where these malformed nodes hide.
///
/// # Errors
///
/// The first [`OpError`] encountered, in pre-order.
pub fn check_expr(expr: &Expr) -> Result<(), OpError> {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => Ok(()),
        Expr::Operator(node) => {
            check_node(node)?;
            let mut first_err: Option<OpError> = None;
            node.for_each_child(&mut |child| {
                if first_err.is_none()
                    && let Err(e) = check_expr(child)
                {
                    first_err = Some(e);
                }
            });
            match first_err {
                Some(e) => Err(e),
                None => Ok(()),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(json: serde_json::Value) -> Expr {
        serde_json::from_value(json).expect("fixture parses")
    }

    #[test]
    fn spec_arities_are_pinned() {
        assert_eq!(arity_of("atan2"), Some(Arity::Exact(2)));
        assert_eq!(arity_of("min"), Some(Arity::AtLeast(2)));
        assert_eq!(arity_of("max"), Some(Arity::AtLeast(2)));
        assert_eq!(arity_of("/"), Some(Arity::Exact(2)));
        assert_eq!(arity_of("^"), Some(Arity::Exact(2)));
        assert_eq!(arity_of("-"), Some(Arity::Between(1, 2)));
        assert_eq!(arity_of("+"), Some(Arity::AtLeast(1)));
        assert_eq!(arity_of("ifelse"), Some(Arity::Exact(3)));
        assert_eq!(arity_of("const"), Some(Arity::Exact(0)));
        assert_eq!(arity_of("expp"), None, "a typo is not a core op");
    }

    /// R1: the node that used to panic with an index-out-of-bounds.
    #[test]
    fn underapplied_atan2_is_an_arity_error() {
        let e = check_expr(&node(serde_json::json!({"op": "atan2", "args": [1.0]})))
            .expect_err("atan2/1 must be rejected");
        assert!(matches!(e, OpError::Arity { ref op, got: 1, .. } if op == "atan2"));
        let e = check_expr(&node(serde_json::json!({"op": "atan2", "args": []})))
            .expect_err("atan2/0 must be rejected");
        assert!(matches!(e, OpError::Arity { got: 0, .. }));
    }

    /// R2: the empty `neg` that panicked on the vectorized path.
    #[test]
    fn empty_neg_is_an_arity_error() {
        assert!(matches!(
            check_expr(&node(serde_json::json!({"op": "neg", "args": []}))),
            Err(OpError::Arity { got: 0, .. })
        ));
    }

    /// R3: the exact nodes on which the two evaluators disagreed. None of them
    /// is legal, so neither evaluator ever sees one again.
    #[test]
    fn the_divergent_arities_are_all_rejected() {
        for j in [
            serde_json::json!({"op": "-", "args": [3.0, 1.0, 1.0]}),
            serde_json::json!({"op": "/", "args": [8.0, 2.0, 2.0]}),
            serde_json::json!({"op": "^", "args": [2.0, 3.0, 4.0]}),
            serde_json::json!({"op": "min", "args": [5.0]}),
            serde_json::json!({"op": "max", "args": [5.0]}),
            serde_json::json!({"op": "and", "args": [5.0]}),
        ] {
            let e = check_expr(&node(j.clone()));
            assert!(
                matches!(e, Err(OpError::Arity { .. })),
                "{j} must be an arity error, got {e:?}"
            );
        }
    }

    #[test]
    fn legal_arities_pass() {
        for j in [
            serde_json::json!({"op": "+", "args": ["a", "b", "c"]}),
            serde_json::json!({"op": "-", "args": ["a"]}),
            serde_json::json!({"op": "-", "args": ["a", "b"]}),
            serde_json::json!({"op": "min", "args": ["a", "b", "c"]}),
            serde_json::json!({"op": "atan2", "args": ["a", "b"]}),
            serde_json::json!({"op": "ifelse", "args": ["c", "a", "b"]}),
            serde_json::json!({"op": "D", "args": ["u"], "wrt": "t"}),
        ] {
            check_expr(&node(j.clone())).unwrap_or_else(|e| panic!("{j} should be legal: {e}"));
        }
    }

    /// R7: a misspelled op is loud, not a silent `NaN`.
    #[test]
    fn a_typo_is_an_unlowered_operator() {
        let e = check_expr(&node(serde_json::json!({"op": "expp", "args": ["x"]})))
            .expect_err("a typo must be rejected");
        assert!(matches!(e, OpError::Unlowered { ref op } if op == "expp"));
    }

    #[test]
    fn sugar_and_spatial_d_are_unlowered() {
        for j in [
            serde_json::json!({"op": "grad", "args": ["u"], "dim": "x"}),
            serde_json::json!({"op": "laplacian", "args": ["u"]}),
            serde_json::json!({"op": "D", "args": ["u"], "wrt": "x"}),
        ] {
            assert!(
                matches!(check_expr(&node(j.clone())), Err(OpError::Unlowered { .. })),
                "{j} must be unlowered"
            );
        }
    }

    /// R5: the two `makearray` region shapes that panicked the evaluator.
    #[test]
    fn ragged_and_inverted_makearray_regions_are_rejected() {
        // Ragged: region 1 has rank 2, region 0 has rank 1.
        let ragged = node(serde_json::json!({
            "op": "makearray",
            "regions": [[[1, 3]], [[1, 3], [1, 2]]],
            "values": [0.0, 1.0],
            "args": []
        }));
        assert!(
            matches!(check_expr(&ragged), Err(OpError::MakearrayRegion { .. })),
            "a ragged regions list must be rejected, not panic"
        );

        // Inverted: [5, 2] has stop < start - 1 (extent would be -2).
        let inverted = node(serde_json::json!({
            "op": "makearray",
            "regions": [[[5, 2]]],
            "values": [0.0],
            "args": []
        }));
        assert!(
            matches!(check_expr(&inverted), Err(OpError::MakearrayRegion { .. })),
            "an inverted region must be rejected, not overflow ArrayD::zeros"
        );
    }

    /// The legal EMPTY spelling `stop == start - 1` (§4.3.2) — what a
    /// metaparameter-folded interior region produces at its minimum extent —
    /// must still load cleanly. This is the boundary the inverted check must
    /// not overshoot.
    #[test]
    fn the_empty_region_spelling_is_legal() {
        let empty = node(serde_json::json!({
            "op": "makearray",
            "regions": [[[2, 1]], [[1, 1]]],
            "values": [0.0, 1.0],
            "args": []
        }));
        check_expr(&empty).expect("[2, 1] is the canonical empty region and is legal");
    }

    /// The walk must descend into sidecar fields, not just `args` — a malformed
    /// node hiding in an `aggregate.expr` body is the whole point.
    #[test]
    fn the_walk_descends_into_sidecar_fields() {
        let agg = node(serde_json::json!({
            "op": "aggregate",
            "output_idx": ["i"],
            "expr": {"op": "atan2", "args": [1.0]},
            "args": ["u"]
        }));
        assert!(
            matches!(check_expr(&agg), Err(OpError::Arity { .. })),
            "an arity error inside `aggregate.expr` must be found"
        );
    }
}
