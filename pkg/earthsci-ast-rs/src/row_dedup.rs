//! Evaluate a relational `faq` once per DISTINCT driving row, not once per row.
//!
//! A relational document keeps its facts in long 1-D relations: a rate table
//! of half a million rows whose every row carries a source type, a fuel type,
//! a model year. A rule over such a relation, `out[b, ...] = faq over b, ...`,
//! very often reads its output row `b` ONLY through a few of those 1-D key
//! columns -- `index(rt_fuelTypeID, b)` in the body, `rt_fuelTypeID` as a join
//! key on `b`'s side. Two rows that agree on every column the rule reads then
//! receive the identical value: the same tuples are enumerated for both, in the
//! same order, with the same numbers. Half a million rows can have a few
//! thousand distinct signatures, and the rule was paying for every row.
//!
//! [`plan`] recognises that shape and rewrites the rule to range over one
//! REPRESENTATIVE row per signature (the first, in row order): each column the
//! rule reads at `b` is replaced by its gather at the representatives, and
//! `b`'s range shrinks to their count. [`expand`] then gathers the result back
//! along `b`'s axis. Nothing is approximated -- each output cell is computed by
//! exactly the evaluation it would have had, on a row that is equal in every
//! value the rule can see -- so the field is bit-identical.
//!
//! The rewrite declines (returns `None`, and the rule is evaluated as written)
//! whenever exactness is not evident from the syntax: `b` read any way other
//! than `index(V, b)` of a materialized 1-D array of `b`'s length or a join key
//! column on `b`'s side; `b` rebound by a nested node; a range whose extent
//! depends on `b` (a ragged range `of` it); any read of the observed being
//! defined, whose `b` axis the rewrite shrinks; an operator reference whose
//! definition the rule cannot read (no registry, or an unresolved name) or
//! whose body reads `b` or the observed itself free, or binds a loop symbol
//! named `b`; a constant join key; or too few duplicate signatures for the
//! rewrite to pay.
//!
//! An operator reference otherwise reads `b` only through its bindings
//! (esm-spec §9.6.4 rule 2: the expansion substitutes them into the body,
//! where no name of the body captures `b`), so the bindings are scanned and
//! rewritten like any other subexpression and the reference is kept; the
//! decision about its body is made once per definition
//! ([`crate::operator_refs::DefinitionReads`]).

use std::collections::{BTreeMap, HashMap};

use ndarray::{ArrayD, Axis};
use rustc_hash::FxHashMap;

use crate::join::KeyColumn;
use crate::simulate_array::ArrMap;
use crate::types::{Expr, ExpressionNode, RangeSpec};

/// Below this many rows the rewrite is not worth its bookkeeping.
const MIN_ROWS: usize = 1024;

thread_local! {
    static ENABLED: std::cell::Cell<Option<bool>> = const { std::cell::Cell::new(None) };
    static APPLIED: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// How many rules this thread has evaluated through the rewrite (tests read it
/// to show the rewrite actually ran).
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn rewrites_applied() -> u64 {
    APPLIED.with(|c| c.get())
}

pub(crate) fn note_applied() {
    APPLIED.with(|c| c.set(c.get() + 1));
}

/// Whether the rewrite is on for this thread: a [`set_row_dedup`] override,
/// else `ESS_ROW_DEDUP` (`0` turns it off; read once per process), else on.
/// The switch exists for A/B measurement and for tests that show the rewrite
/// changes cost and not answers.
pub(crate) fn row_dedup_enabled() -> bool {
    static ENV: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    ENABLED.with(|c| c.get()).unwrap_or_else(|| {
        *ENV.get_or_init(|| std::env::var("ESS_ROW_DEDUP").map_or(true, |v| v.trim() != "0"))
    })
}

/// Turn the rewrite on or off for THIS thread, returning the previous override.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn set_row_dedup(on: Option<bool>) -> Option<bool> {
    ENABLED.with(|c| c.replace(on))
}

/// What [`plan`] produced: the rewritten rule, the temporary columns it reads,
/// and how to scatter its result back.
pub(crate) struct DedupPlan {
    /// The rule over the representative rows.
    pub expr: Expr,
    /// `(temporary name, gathered column)` pairs the rewritten rule reads;
    /// the caller moves them into its namespace.
    pub columns: Vec<(String, ArrayD<f64>)>,
    /// Position of `b` in the rule's `output_idx`, i.e. the result's axis.
    pub axis: usize,
    /// For each original row (0-based), its representative's 0-based index.
    pub row_to_rep: Vec<usize>,
    /// Number of representatives.
    pub reps: usize,
    /// Number of original rows.
    pub rows: usize,
}

/// Plan the rewrite of `expr` (already range-resolved) for the observed `name`.
///
/// `expr` is a `faq`, or an elementwise tree (`+`, `ifelse`, ...) whose leaves
/// are `faq`s with one `output_idx` and literals: every leaf is rewritten
/// against the same representatives, so the tree combines them cell for cell
/// exactly as it combined the originals.
#[cfg(test)]
pub(crate) fn plan(name: &str, expr: &Expr, arrays: &ArrMap) -> Option<DedupPlan> {
    plan_in(name, expr, arrays, &Default::default())
}

/// [`plan`], the rule's operator references read through `operators` (the
/// registry they resolve against; a flattened system's, whose bodies are
/// closed, or a component's).
pub(crate) fn plan_in(
    name: &str,
    expr: &Expr,
    arrays: &ArrMap,
    operators: &crate::operator_refs::OperatorRegistry,
) -> Option<DedupPlan> {
    let mut leaves: Vec<&ExpressionNode> = Vec::new();
    if !faq_leaves(expr, &mut leaves) || leaves.is_empty() {
        return None;
    }
    let top = leaves[0];
    let output_idx = top.output_idx.as_ref()?;
    let ranges = top.ranges.as_ref()?;
    // The candidate driving symbol: the output index over the most rows.
    let (axis, sym, rows) = output_idx
        .iter()
        .enumerate()
        .filter_map(|(i, s)| match ranges.get(s)? {
            RangeSpec::Interval([lo, hi]) if *lo == 1 && hi >= lo => {
                Some((i, s.as_str(), (*hi) as usize))
            }
            _ => None,
        })
        .max_by_key(|&(_, _, n)| n)?;
    if rows < MIN_ROWS {
        return None;
    }
    // Every array the rules read at `sym`, with the axis each is read on.
    let mut cols: BTreeMap<String, usize> = BTreeMap::new();
    let ok_col = |v: &str, axis: usize| {
        arrays
            .get(v)
            .is_some_and(|a| a.ndim() > axis && a.shape()[axis] == rows)
    };
    let scope = Scope {
        name,
        sym,
        operators,
    };
    for leaf in &leaves {
        if leaf.output_idx.as_ref() != Some(output_idx)
            || leaf.ranges.as_ref().and_then(|r| r.get(sym))
                != Some(&RangeSpec::Interval([1, rows as i64]))
            || leaf
                .ranges
                .as_ref()
                .is_some_and(|r| r.values().any(|spec| range_reads(spec, sym)))
            || !leaf_reads(leaf, &scope, &ok_col, arrays, &mut cols)
        {
            return None;
        }
    }
    if cols.is_empty() {
        // No rule reads `sym` at all: every row is equal, but a rule like that
        // is cheap per row anyway and its shape is unusual.
        return None;
    }
    // Group the rows by the bits of everything read at `sym`: a 1-D column's
    // value, or a wider array's whole slice at that row.
    let col_vals: Vec<(&ArrayD<f64>, usize)> =
        cols.iter().map(|(c, &ax)| (&arrays[c], ax)).collect();
    let mut seen: FxHashMap<Vec<u64>, usize> = FxHashMap::default();
    let mut rep_rows: Vec<usize> = Vec::new();
    let mut row_to_rep = Vec::with_capacity(rows);
    let mut sig = Vec::with_capacity(col_vals.len());
    for r in 0..rows {
        sig.clear();
        for &(a, ax) in &col_vals {
            if a.ndim() == 1 {
                sig.push(a[[r]].to_bits());
            } else {
                sig.extend(a.index_axis(Axis(ax), r).iter().map(|v| v.to_bits()));
            }
        }
        // Look up first: only a NEW signature is copied into the map.
        let rep = match seen.get(sig.as_slice()) {
            Some(&rep) => rep,
            None => {
                let rep = rep_rows.len();
                seen.insert(sig.clone(), rep);
                rep_rows.push(r);
                rep
            }
        };
        row_to_rep.push(rep);
    }
    let reps = rep_rows.len();
    if reps * 2 > rows {
        return None;
    }
    // The temporary arrays: each one read at `sym`, gathered at the
    // representatives along the axis it is read on.
    let rename: HashMap<String, String> = cols
        .keys()
        .map(|c| (c.clone(), format!("{c}\u{0}dedup\u{0}{name}")))
        .collect();
    let columns = cols
        .iter()
        .map(|(c, &ax)| (rename[c].clone(), arrays[c].select(Axis(ax), &rep_rows)))
        .collect();
    let mut expr = expr.clone();
    rewrite_leaves(&mut expr, sym, reps, &rename, &cols);
    Some(DedupPlan {
        expr,
        columns,
        axis,
        row_to_rep,
        reps,
        rows,
    })
}

/// Collect the `faq` leaves of an elementwise tree; `false` for anything else
/// (a bare array operand, a non-elementwise node).
fn faq_leaves<'e>(e: &'e Expr, out: &mut Vec<&'e ExpressionNode>) -> bool {
    match e {
        Expr::Integer(_) | Expr::Number(_) => true,
        Expr::Variable(_) => false,
        Expr::Operator(n) => {
            if crate::faq::is_faq_op(&n.op) {
                if n.key.is_some() {
                    return false;
                }
                out.push(n);
                return true;
            }
            if n.op == "broadcast" || !crate::op_registry::is_elementwise_node(n) {
                return false;
            }
            let mut ok = true;
            n.for_each_child(&mut |c| ok = ok && faq_leaves(c, out));
            ok
        }
    }
}

/// The rule being planned: the observed it defines, and its driving symbol.
struct Scope<'a> {
    name: &'a str,
    sym: &'a str,
    operators: &'a crate::operator_refs::OperatorRegistry,
}

/// Whether a range's extent is a function of `sym`: a ragged range `of` it
/// (its per-row length is read from an `offsets` array at `sym`, which the
/// row signature does not cover).
fn range_reads(spec: &RangeSpec, sym: &str) -> bool {
    match spec {
        RangeSpec::RaggedDyn { of, .. } => of.iter().any(|s| s == sym),
        RangeSpec::IndexSetRef { of: Some(of), .. } => of.iter().any(|s| s == sym),
        _ => false,
    }
}

/// Whether `leaf` reads `sym` only as `index` subscripts and join key columns
/// over materialized arrays, collecting them into `cols`.
fn leaf_reads(
    leaf: &ExpressionNode,
    scope: &Scope<'_>,
    ok_col: &impl Fn(&str, usize) -> bool,
    arrays: &ArrMap,
    cols: &mut BTreeMap<String, usize>,
) -> bool {
    let sym = scope.sym;
    let mut body_ok = true;
    leaf.for_each_child(&mut |c| {
        body_ok = body_ok && scan(c, scope, ok_col, cols);
    });
    if !body_ok {
        return false;
    }
    for clause in leaf.join.iter().flatten() {
        if let Some(ov) = &clause.overlap {
            if ov.sym_src.as_deref() == Some(sym) || ov.sym_tgt.as_deref() == Some(sym) {
                return false;
            }
            continue;
        }
        let Some(g) = &clause.on_gate else { continue };
        // A key column naming the observed being defined reads it whole.
        if g.cols_l
            .iter()
            .chain(g.cols_r.iter())
            .any(|c| matches!(c, KeyColumn::Column(v) if v == scope.name))
        {
            return false;
        }
        let side = if g.sym_l == sym {
            &g.cols_l
        } else if g.sym_r == sym {
            &g.cols_r
        } else {
            continue;
        };
        for c in side {
            match c {
                KeyColumn::Column(v)
                    if ok_col(v, 0)
                        && arrays[v].ndim() == 1
                        && *cols.entry(v.clone()).or_insert(0) == 0 => {}
                _ => return false,
            }
        }
    }
    true
}

/// Rewrite every `faq` leaf of the elementwise tree `e` over the
/// representatives: `sym`'s range shrinks to `reps`, and each read array and
/// join key column at `sym` is renamed to its gathered copy.
fn rewrite_leaves(
    e: &mut Expr,
    sym: &str,
    reps: usize,
    rename: &HashMap<String, String>,
    cols: &BTreeMap<String, usize>,
) {
    let Some(n) = e.node_mut() else { return };
    if !crate::faq::is_faq_op(&n.op) {
        n.for_each_child_mut(&mut |c| rewrite_leaves(c, sym, reps, rename, cols));
        return;
    }
    n.ranges
        .as_mut()
        .expect("a planned leaf has ranges")
        .insert(sym.to_string(), RangeSpec::Interval([1, reps as i64]));
    n.for_each_child_mut(&mut |c| rewrite(c, sym, rename, cols));
    for clause in n.join.iter_mut().flatten() {
        let Some(g) = &mut clause.on_gate else {
            continue;
        };
        let side = if g.sym_l == sym {
            &mut g.cols_l
        } else if g.sym_r == sym {
            &mut g.cols_r
        } else {
            continue;
        };
        // The gate keeps its id: the evaluator's match-set memo is keyed by
        // the id together with each data key column's length and content
        // fingerprint, and a gathered column is shorter than the original.
        for c in side.iter_mut() {
            if let KeyColumn::Column(v) = c
                && let Some(new) = rename.get(v)
            {
                *v = new.clone();
            }
        }
    }
}

/// Whether `e` reads `sym` only as one argument of `index(V, ...)` with
/// `ok_col(V, axis)`, always on the same axis of a given `V`, collecting those
/// `V` and their axes. Any read of the observed being defined declines: the
/// rewrite shrinks its `sym` axis, so even a read at a fixed row (a causal
/// self-reference) would address a representative, not that row.
fn scan(
    e: &Expr,
    scope: &Scope<'_>,
    ok_col: &impl Fn(&str, usize) -> bool,
    cols: &mut BTreeMap<String, usize>,
) -> bool {
    let sym = scope.sym;
    match e {
        Expr::Variable(v) => v != sym && v != scope.name,
        Expr::Operator(n) => {
            if let Some(r) = crate::operator_refs::reference_node(n) {
                let Some(def) = scope.operators.resolve(&r) else {
                    return false;
                };
                let reads = def.reads(scope.operators);
                if reads.free.contains(sym)
                    || reads.free.contains(scope.name)
                    || reads.binders.contains(sym)
                {
                    return false;
                }
                return r.bindings.values().all(|b| scan(b, scope, ok_col, cols));
            }
            if n.op == "index"
                && let Some(ax) = sym_axis(n, sym)
            {
                let Expr::Variable(v) = &n.args[0] else {
                    return false;
                };
                if v == scope.name || !ok_col(v, ax) || *cols.entry(v.clone()).or_insert(ax) != ax {
                    return false;
                }
                // The other subscripts must not read `sym` themselves.
                return n.args[1..]
                    .iter()
                    .enumerate()
                    .all(|(i, a)| i == ax || scan(a, scope, ok_col, cols));
            }
            // A nested node that binds `sym` again is a different variable,
            // and one whose range extent depends on `sym` reads it unseen.
            if n.ranges
                .as_ref()
                .is_some_and(|r| r.contains_key(sym) || r.values().any(|s| range_reads(s, sym)))
                || n.output_idx
                    .as_ref()
                    .is_some_and(|o| o.iter().any(|s| s == sym))
                || n.int_var.as_deref() == Some(sym)
            {
                return false;
            }
            // A nested gate keyed on `sym` would read columns at it too, and
            // one keyed on the observed being defined reads it whole.
            if n.join.as_ref().is_some_and(|js| {
                js.iter().any(|c| {
                    c.on_gate.as_ref().is_some_and(|g| {
                        g.sym_l == sym
                            || g.sym_r == sym
                            || g.cols_l
                                .iter()
                                .chain(g.cols_r.iter())
                                .any(|c| matches!(c, KeyColumn::Column(v) if v == scope.name))
                    })
                })
            }) {
                return false;
            }
            !n.any_child(&mut |c| !scan(c, scope, ok_col, cols))
        }
        _ => true,
    }
}

/// The subscript position (0-based, after the array) at which `index` node `n`
/// reads exactly the bare symbol `sym`, if it does at exactly one position.
fn sym_axis(n: &crate::types::ExpressionNode, sym: &str) -> Option<usize> {
    let mut hit = None;
    for (i, a) in n.args.iter().skip(1).enumerate() {
        if matches!(a, Expr::Variable(s) if s == sym) {
            if hit.is_some() {
                return None;
            }
            hit = Some(i);
        }
    }
    hit
}

/// Rename `V` in every `index(V, ...)` of `e` that reads `sym` on `V`'s
/// recorded axis; every other read of `V` keeps the whole array.
fn rewrite(
    e: &mut Expr,
    sym: &str,
    rename: &HashMap<String, String>,
    cols: &BTreeMap<String, usize>,
) {
    let Some(n) = e.node_mut() else { return };
    if n.op == "index"
        && let Some(ax) = sym_axis(n, sym)
        && let Expr::Variable(v) = &n.args[0]
        && cols.get(v) == Some(&ax)
        && let Some(new) = rename.get(v)
    {
        n.args[0] = Expr::Variable(new.clone());
        for a in n.args[1..].iter_mut() {
            rewrite(a, sym, rename, cols);
        }
        return;
    }
    n.for_each_child_mut(&mut |c| rewrite(c, sym, rename, cols));
}

/// Scatter a result over the representatives back over every row.
pub(crate) fn expand(plan: &DedupPlan, a: ArrayD<f64>) -> Option<ArrayD<f64>> {
    if a.ndim() <= plan.axis || a.shape()[plan.axis] != plan.reps {
        return None;
    }
    let out = a.select(Axis(plan.axis), &plan.row_to_rep);
    debug_assert_eq!(out.shape()[plan.axis], plan.rows);
    Some(out)
}

#[cfg(test)]
mod tests {
    //! The rewrite changes cost, never answers: each document below is built
    //! under `native` with the rewrite on and off and under the reference
    //! interpreter, and every field agrees bit for bit.
    use std::collections::HashMap;

    use ndarray::{ArrayD, IxDyn};
    use serde_json::{Value, json};

    use crate::{Compiler, EsmProblem, ProblemOptions, esm_problem, observed_field};

    const N: usize = 4096;

    fn build(
        doc: &Value,
        compiler: Compiler,
        dedup: bool,
        consts: &HashMap<String, ArrayD<f64>>,
    ) -> EsmProblem {
        let prev = super::set_row_dedup(Some(dedup));
        let p = esm_problem(
            doc,
            (0.0, 1.0),
            ProblemOptions {
                compiler: Some(compiler),
                const_arrays: consts.clone(),
                build_pipeline: true,
                ..Default::default()
            },
        )
        .expect("builds");
        super::set_row_dedup(prev);
        p
    }

    fn bits(p: &EsmProblem, name: &str) -> Vec<u64> {
        observed_field(p, name)
            .unwrap_or_else(|e| panic!("{name}: {e}"))
            .iter()
            .map(|x| x.to_bits())
            .collect()
    }

    /// `rows` is a long relation whose rows repeat a few (fuel, year) keys; a
    /// small `table` is keyed by fuel. The rules read their row only through
    /// key columns (`one_d`), also through a 2-D array's row (`two_d`), and
    /// one reads the row number itself (`reads_row`), which must not be
    /// rewritten.
    fn doc() -> (Value, HashMap<String, ArrayD<f64>>) {
        let col = |set: &str| json!({"type": "parameter", "default": 0.0, "shape": [set]});
        let doc = json!({
            "esm": "2.0.0",
            "metadata": {"name": "RowDedup"},
            "index_sets": {
                "rows": {"kind": "interval", "size": N},
                "table": {"kind": "interval", "size": 8},
                "hours": {"kind": "interval", "size": 3}
            },
            "models": {"M": {
                "variables": {
                    "fuel": col("rows"), "year": col("rows"),
                    "tfuel": col("table"), "tval": col("table"),
                    "wide": {"type": "unknown", "shape": ["rows", "hours"]},
                    "one_d": {"type": "unknown", "shape": ["rows"]},
                    "two_d": {"type": "unknown", "shape": ["rows", "hours"]},
                    "reads_row": {"type": "unknown", "shape": ["rows"]},
                    "tree": {"type": "unknown", "shape": ["rows"]}
                },
                "equations": [
                    {"lhs": "wide", "rhs": {"op": "faq", "args": [], "output_idx": ["b", "h"],
                        "ranges": {"b": {"from": "rows"}, "h": {"from": "hours"}},
                        "expr": {"op": "*", "args": [{"op": "index", "args": ["year", "b"]}, "h"]}}},
                    {"lhs": "one_d", "rhs": {"op": "faq", "args": [], "output_idx": ["b"],
                        "ranges": {"b": {"from": "rows"}, "w": {"from": "table"}},
                        "join": [{"on": [["fuel", "tfuel"]]}],
                        "filter": {"op": "<", "args": [{"op": "index", "args": ["tval", "w"]},
                                                       {"op": "index", "args": ["year", "b"]}]},
                        "expr": {"op": "/", "args": [{"op": "index", "args": ["tval", "w"]},
                                                     {"op": "index", "args": ["year", "b"]}]}}},
                    {"lhs": "two_d", "rhs": {"op": "faq", "args": [], "output_idx": ["b", "h"],
                        "ranges": {"b": {"from": "rows"}, "h": {"from": "hours"}, "w": {"from": "table"}},
                        "join": [{"on": [["fuel", "tfuel"]]}],
                        "expr": {"op": "*", "args": [{"op": "index", "args": ["tval", "w"]},
                                                     {"op": "index", "args": ["wide", "b", "h"]}]}}},
                    {"lhs": "tree", "rhs": {"op": "+", "args": [
                        {"op": "faq", "args": [], "output_idx": ["b"],
                         "ranges": {"b": {"from": "rows"}, "w": {"from": "table"}},
                         "join": [{"on": [["fuel", "tfuel"]]}],
                         "expr": {"op": "index", "args": ["tval", "w"]}},
                        {"op": "faq", "args": [], "semiring": "bool_and_or", "output_idx": ["b"],
                         "ranges": {"b": {"from": "rows"}},
                         "expr": {"op": ">", "args": [{"op": "index", "args": ["year", "b"]}, 2002.0]}},
                        0.25]}},
                    {"lhs": "reads_row", "rhs": {"op": "faq", "args": [], "output_idx": ["b"],
                        "ranges": {"b": {"from": "rows"}, "w": {"from": "table"}},
                        "join": [{"on": [["fuel", "tfuel"]]}],
                        "expr": {"op": "+", "args": ["b", {"op": "index", "args": ["tval", "w"]}]}}}
                ]
            }}
        });
        let fuel: Vec<f64> = (0..N).map(|i| (i % 3 + 1) as f64).collect();
        let year: Vec<f64> = (0..N).map(|i| (2000 + (i / 7) % 5) as f64 + 0.1).collect();
        let tfuel: Vec<f64> = (0..8).map(|i| (i % 4 + 1) as f64).collect();
        let tval: Vec<f64> = (0..8).map(|i| 1999.0 + 0.7 * i as f64).collect();
        let consts = [
            ("fuel", fuel),
            ("year", year),
            ("tfuel", tfuel),
            ("tval", tval),
        ]
        .into_iter()
        .map(|(k, v)| {
            (
                k.to_string(),
                ArrayD::from_shape_vec(IxDyn(&[v.len()]), v).unwrap(),
            )
        })
        .collect();
        (doc, consts)
    }

    #[test]
    fn the_rewrite_changes_cost_not_answers() {
        let (doc, consts) = doc();
        let before = super::rewrites_applied();
        let on = build(&doc, Compiler::Native, true, &consts);
        // wide (it reads its row only through `year`), one_d, two_d and the
        // elementwise tree; reads_row is declined.
        assert_eq!(super::rewrites_applied() - before, 4, "the rewrite ran");
        let off = build(&doc, Compiler::Native, false, &consts);
        let oracle = build(&doc, Compiler::Interpreter, true, &consts);
        for f in ["M.one_d", "M.two_d", "M.reads_row", "M.wide", "M.tree"] {
            assert_eq!(bits(&on, f), bits(&off, f), "{f}: on vs off");
            assert_eq!(bits(&on, f), bits(&oracle, f), "{f}: native vs interpreter");
        }
    }

    #[test]
    fn plan_takes_key_reads_and_declines_a_row_read() {
        let (doc, consts) = doc();
        let p = build(&doc, Compiler::Native, false, &consts);
        // Rebuild the arrays the rules read, as the pipeline holds them.
        let mut arrays = crate::simulate_array::ArrMap::default();
        for (k, v) in &consts {
            arrays.insert(k.clone(), v.clone());
        }
        arrays.insert("wide".into(), observed_field(&p, "M.wide").unwrap());
        let parsed = crate::load_string(&doc.to_string()).unwrap();
        let index_sets: HashMap<String, crate::types::IndexSet> = parsed
            .index_sets
            .clone()
            .unwrap_or_default()
            .into_iter()
            .collect();
        let mut model = parsed.models.as_ref().unwrap()["M"].clone();
        crate::join::resolve_aggregate_joins(
            &mut model,
            &index_sets,
            crate::join::declared_var_shapes,
        )
        .unwrap();
        let rule = |lhs: &str| {
            let eq = model
                .equations
                .iter()
                .find(|e| matches!(&e.lhs, crate::Expr::Variable(v) if v == lhs))
                .unwrap();
            let mut e = eq.rhs.clone();
            crate::faq::resolve_expr_ranges_with_extents(&mut e, &index_sets, &HashMap::new())
                .unwrap();
            e
        };
        // 3 fuels x 5 years.
        let plan = super::plan("one_d", &rule("one_d"), &arrays).expect("one_d is rewritten");
        assert_eq!((plan.rows, plan.reps), (N, 15));
        // The wide row adds nothing: it is a function of the year.
        let plan = super::plan("two_d", &rule("two_d"), &arrays).expect("two_d is rewritten");
        assert_eq!((plan.rows, plan.reps), (N, 15));
        let plan = super::plan("tree", &rule("tree"), &arrays).expect("tree is rewritten");
        assert_eq!((plan.rows, plan.reps), (N, 15));
        assert!(super::plan("reads_row", &rule("reads_row"), &arrays).is_none());

        // The same rule with its body handed to an operator reference: the
        // reference reads the driving row only through its binding, which is
        // scanned and rewritten like any other subexpression; the reference
        // stays. Without the registry it is declined.
        let mut wrapped = rule("one_d");
        let crate::Expr::Operator(node) = &mut wrapped else {
            panic!("one_d is a faq")
        };
        let node = std::sync::Arc::make_mut(node);
        let body = node.expr.take().expect("faq body");
        node.expr = Some(Box::new(crate::Expr::operator(
            crate::types::ExpressionNode {
                op: crate::operator_refs::APPLY_OP.into(),
                name: Some("id".into()),
                bindings: Some(HashMap::from([("x".to_string(), *body)])),
                ..Default::default()
            },
        )));
        let ids = crate::operator_refs::OperatorRegistry::from_json(
            serde_json::json!({"id": {"params": ["x"], "body": "x"},
                               "reads_free": {"params": ["x"], "body": {"op": "+", "args": ["x", "one_d"]}}})
                .as_object()
                .unwrap(),
        );
        assert!(super::plan("one_d", &wrapped, &arrays).is_none());
        let plan = super::plan_in("one_d", &wrapped, &arrays, &ids).expect("rewritten through id");
        assert_eq!((plan.rows, plan.reps), (N, 15));
        assert!(crate::operator_refs::has_reference(&plan.expr));
        // A body that reads the observed being defined is declined.
        let crate::Expr::Operator(node) = &mut wrapped else {
            unreachable!()
        };
        let node = std::sync::Arc::make_mut(node);
        if let Some(crate::Expr::Operator(r)) = node.expr.as_deref_mut() {
            std::sync::Arc::make_mut(r).name = Some("reads_free".into());
        }
        assert!(super::plan_in("one_d", &wrapped, &arrays, &ids).is_none());
    }

    /// A ragged inner range `of` the driving row reads that row's member
    /// count from `offsets`, which no subscript in the body names. Every row
    /// here has the same key (`fuel`) and the same padded member row, but its
    /// count cycles 1, 2, 3, so the rule must not be rewritten: one
    /// representative's count would be scattered to every row.
    #[test]
    fn a_ragged_range_of_the_driving_row_is_not_rewritten() {
        let doc = json!({
            "esm": "2.0.0",
            "metadata": {"name": "RowDedupRagged"},
            "index_sets": {
                "rows": {"kind": "interval", "size": N},
                "slots": {"kind": "interval", "size": 3},
                "flat": {"kind": "interval", "size": 3},
                "mof": {"kind": "ragged", "of": ["rows"], "offsets": "cnt", "values": "mem"}
            },
            "models": {"M": {
                "variables": {
                    "fuel": {"type": "parameter", "default": 0.0, "shape": ["rows"]},
                    "cnt": {"type": "parameter", "default": 0.0, "shape": ["rows"]},
                    "mem": {"type": "parameter", "default": 0.0, "shape": ["rows", "slots"]},
                    "flatv": {"type": "parameter", "default": 0.0, "shape": ["flat"]},
                    "rag": {"type": "unknown", "shape": ["rows"]}
                },
                "equations": [
                    {"lhs": "rag", "rhs": {"op": "faq", "args": [], "output_idx": ["b"],
                        "ranges": {"b": {"from": "rows"}, "j": {"from": "mof", "of": ["b"]}},
                        "expr": {"op": "*", "args": [
                            {"op": "index", "args": ["fuel", "b"]},
                            {"op": "index", "args": ["flatv",
                                {"op": "index", "args": ["mem", "b", "j"]}]}]}}}
                ]
            }}
        });
        let arr = |shape: &[usize], v: Vec<f64>| ArrayD::from_shape_vec(IxDyn(shape), v).unwrap();
        let consts: HashMap<String, ArrayD<f64>> = [
            ("fuel", arr(&[N], vec![2.0; N])),
            (
                "cnt",
                arr(&[N], (0..N).map(|i| (i % 3 + 1) as f64).collect()),
            ),
            (
                "mem",
                arr(&[N, 3], (0..N).flat_map(|_| [1.0, 2.0, 3.0]).collect()),
            ),
            ("flatv", arr(&[3], vec![10.0, 20.0, 30.0])),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        let on = build(&doc, Compiler::Native, true, &consts);
        let off = build(&doc, Compiler::Native, false, &consts);
        let oracle = build(&doc, Compiler::Interpreter, true, &consts);
        assert_eq!(bits(&on, "M.rag"), bits(&off, "M.rag"), "on vs off");
        assert_eq!(
            bits(&on, "M.rag"),
            bits(&oracle, "M.rag"),
            "native vs interpreter"
        );
        let field = observed_field(&on, "M.rag").unwrap();
        assert_eq!(
            field.iter().take(3).copied().collect::<Vec<_>>(),
            vec![20.0, 60.0, 120.0],
            "each row sums its own members"
        );
    }

    /// A read of the observed being defined at a FIXED row (a causal
    /// self-reference) is declined too: the rewrite shrinks the output's
    /// driving axis, so `index(out, 5)` would read the fifth representative,
    /// not original row 5.
    #[test]
    fn a_self_read_of_the_observed_is_not_rewritten() {
        let year: Vec<f64> = (0..N).map(|i| (2000 + i % 5) as f64).collect();
        let mut arrays = crate::simulate_array::ArrMap::default();
        arrays.insert(
            "year".into(),
            ArrayD::from_shape_vec(IxDyn(&[N]), year).unwrap(),
        );
        arrays.insert("out".into(), ArrayD::zeros(IxDyn(&[N])));
        let rule = |extra: Value| -> crate::Expr {
            serde_json::from_value(json!({
                "op": "faq", "args": [], "output_idx": ["b"],
                "ranges": {"b": [1, N]},
                "expr": {"op": "+", "args": [{"op": "index", "args": ["year", "b"]}, extra]}
            }))
            .unwrap()
        };
        assert!(
            super::plan("out", &rule(json!(1.0)), &arrays).is_some(),
            "without the self-read the rule is rewritten"
        );
        assert!(
            super::plan(
                "out",
                &rule(json!({"op": "index", "args": ["out", 5]})),
                &arrays
            )
            .is_none(),
            "a fixed-row self-read is declined"
        );
        assert!(
            super::plan("out", &rule(json!("out")), &arrays).is_none(),
            "a bare self-read is declined"
        );
    }
}
