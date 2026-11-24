//! Causal self-reference (recurrence) analysis along one index axis —
//! esm-spec §4.3.1.1 and §4.3.1.2.
//!
//! An equation defining an array-shaped unknown `V` whose RHS reads
//! `index(V, …)` at a strictly earlier position along one of the defining
//! aggregate's output axes is a RECURRENCE DEFINITION of `V`. This module is
//! the one implementation of the analysis that decides whether such a read is
//! well founded. Its two callers differ only in what they can resolve and how
//! they report:
//!
//! * the validator (`structural.rs`) sees ranges before they are resolved
//!   against the index-set registry and reports a structural error code;
//! * the compiler (`simulate_array/compile.rs`) sees resolved ranges and
//!   reports a build error.
//!
//! Each supplies its own range-bounds callback and maps a [`SelfReadDefect`] to
//! its own error. Rationale, alternatives, and the reason the lag is DERIVED
//! rather than declared: `docs/content/rfcs/causal-self-reference-recurrence.md`.

use std::collections::HashMap;

use crate::types::{Expr, RangeSpec};

/// Integer bounds of the index symbols in scope.
pub(crate) type SymbolBounds = HashMap<String, (i64, i64)>;

/// The affine form of an index expression with respect to the frame symbol
/// `sym`: the coefficient of `sym`, plus the integer bounds of the symbol-free
/// part — `None` when those bounds cannot be proved.
///
/// The two halves carry different weight. The **coefficient** must be provable:
/// unless the expression carries `sym` exactly once with coefficient 1 it does
/// not name a position relative to the cell being written, and there is nothing
/// to interpret. The **constant part** need not be: an unprovable offset is a
/// lag whose sign is unknown, which esm-spec §4.3.1.1 admits and leaves to the
/// runtime's fail-closed read — a cell the sweep has not published cannot be
/// read, so an unprovable lag cannot produce a wrong number, only a fault.
///
/// The validator proves LESS than the compiler (it sees ranges before they are
/// resolved against the registry), so treating an unresolvable symbol as fatal
/// would make the validator reject documents the evaluator accepts — the one
/// disagreement between the two that is never defensible.
pub(crate) struct Affine {
    pub(crate) coef: i64,
    pub(crate) konst: Option<(i64, i64)>,
}

pub(crate) fn affine_in_sym(e: &Expr, sym: &str, env: &SymbolBounds) -> Option<Affine> {
    let konst = |lo: i64, hi: i64| {
        Some(Affine {
            coef: 0,
            konst: Some((lo, hi)),
        })
    };
    match e {
        Expr::Integer(n) => konst(*n, *n),
        Expr::Number(f) if f.fract() == 0.0 && f.is_finite() => {
            let n = *f as i64;
            konst(n, n)
        }
        Expr::Variable(v) if v == sym => Some(Affine {
            coef: 1,
            konst: Some((0, 0)),
        }),
        Expr::Variable(v) => Some(Affine {
            coef: 0,
            konst: env.get(v).copied(),
        }),
        Expr::Operator(node) if node.args.len() == 2 => {
            let a = affine_in_sym(&node.args[0], sym, env)?;
            let b = affine_in_sym(&node.args[1], sym, env)?;
            let both = a.konst.zip(b.konst);
            match node.op.as_str() {
                "+" => Some(Affine {
                    coef: a.coef + b.coef,
                    konst: both.map(|((la, ha), (lb, hb))| (la + lb, ha + hb)),
                }),
                "-" => Some(Affine {
                    coef: a.coef - b.coef,
                    konst: both.map(|((la, ha), (lb, hb))| (la - hb, ha - lb)),
                }),
                // Scaling only by a symbol-free integer whose value is PINNED
                // (`lo == hi`): otherwise the product is not affine with a known
                // coefficient, and the coefficient is the half that must be
                // provable.
                "*" => {
                    let (k, other) = match (a.coef, a.konst, b.coef, b.konst) {
                        (0, Some((lo, hi)), _, _) if lo == hi => (lo, &b),
                        (_, _, 0, Some((lo, hi))) if lo == hi => (lo, &a),
                        _ => return None,
                    };
                    Some(Affine {
                        coef: other.coef * k,
                        konst: other.konst.map(|(lo, hi)| {
                            let (p, q) = (lo * k, hi * k);
                            (p.min(q), p.max(q))
                        }),
                    })
                }
                _ => None,
            }
        }
        _ => None,
    }
}

/// One causal read found in a variable's defining RHS.
pub(crate) struct SelfRead<'a> {
    /// The variable read: the equation's own variable, or (esm-spec §4.3.1.2)
    /// a peer in its recurrence group.
    pub(crate) target: &'a str,
    /// The read's index arguments (`args[1..]` of the `index` node).
    pub(crate) args: &'a [Expr],
    /// Bounds of every index symbol bound by an enclosing `faq` at the point
    /// the read was found — the scope a symbol-valued lag is proved in.
    /// Innermost binding wins, matching the evaluator's `loop_binds` shadowing.
    pub(crate) env: SymbolBounds,
    /// Reached only through a construct that evaluates its operand whole (a
    /// `makearray` region value, or an operand of an op in
    /// [`op_blocks_cell_restriction`]), so no cell-by-cell sweep can supply it.
    pub(crate) unsequenceable: bool,
}

/// Every causal read of `vars` in one RHS, and the first of `vars` read BARE
/// (which is never a causal read — esm-spec §4.3.1.1 rejection 4 — because the
/// whole array does not exist during the sweep).
pub(crate) struct SelfReads<'a> {
    pub(crate) reads: Vec<SelfRead<'a>>,
    pub(crate) bare: Option<&'a str>,
}

/// Ops whose operands are consumed WHOLE — a self-read underneath one of these
/// names a cell of an array that has to exist in full before the op can run, so
/// no cell-by-cell sweep can supply it (esm-spec §4.3.1.1 `recurrence_unsupported_form`).
fn op_blocks_cell_restriction(op: &str) -> bool {
    // `apply_operator` is not here: a reference's bindings are read where its
    // body reads them, cell by cell, and the walk visits them as the
    // reference's expansion holds them.
    matches!(op, "reshape" | "transpose" | "concat" | "broadcast")
}

/// Walk `e` collecting every `index(v, …)` read of a name in `vars`. `bounds`
/// resolves a `faq` range to the integer bounds its symbol takes; a range it
/// cannot resolve leaves the symbol unbounded.
pub(crate) fn collect_self_reads<'a>(
    e: &'a Expr,
    vars: &[&str],
    bounds: &dyn Fn(&RangeSpec) -> Option<(i64, i64)>,
) -> SelfReads<'a> {
    let mut out = SelfReads {
        reads: Vec::new(),
        bare: None,
    };
    let mut env: Vec<(String, (i64, i64))> = Vec::new();
    walk_self_reads(e, vars, bounds, &mut env, false, &mut out);
    out
}

fn walk_self_reads<'a>(
    e: &'a Expr,
    vars: &[&str],
    bounds: &dyn Fn(&RangeSpec) -> Option<(i64, i64)>,
    env: &mut Vec<(String, (i64, i64))>,
    blocked: bool,
    out: &mut SelfReads<'a>,
) {
    let Expr::Operator(node) = e else {
        if let Expr::Variable(v) = e
            && vars.contains(&v.as_str())
            && out.bare.is_none()
        {
            out.bare = Some(v.as_str());
        }
        return;
    };
    let pushed = if crate::faq::is_faq_op(&node.op) {
        let before = env.len();
        if let Some(m) = node.ranges.as_ref() {
            env.extend(
                m.iter()
                    .filter_map(|(k, spec)| bounds(spec).map(|b| (k.clone(), b))),
            );
        }
        env.len() - before
    } else {
        0
    };
    let self_target = match node.args.first() {
        Some(Expr::Variable(v)) if node.op == "index" && vars.contains(&v.as_str()) => {
            Some(v.as_str())
        }
        _ => None,
    };
    if let Some(target) = self_target {
        // Innermost binding wins: later entries overwrite earlier ones.
        let snapshot: SymbolBounds = env.iter().cloned().collect();
        out.reads.push(SelfRead {
            target,
            args: &node.args[1..],
            env: snapshot,
            unsequenceable: blocked,
        });
    }
    // A `makearray` REGION VALUE is evaluated once for the whole region, so a
    // self-read inside one cannot be sequenced; the region ORDER decides which
    // write wins, not which cell is evaluated when (esm-spec §4.3.2).
    let blocked_children = blocked || op_blocks_cell_restriction(&node.op);
    // `args[0]` of a self-read is the name itself, not a bare read of the
    // array; every other operand is walked normally (an index expression may
    // itself contain a self-read).
    let skip = usize::from(self_target.is_some());
    for a in node.args.iter().skip(skip) {
        walk_self_reads(a, vars, bounds, env, blocked_children, out);
    }
    for side in [
        node.expr.as_deref(),
        node.filter.as_deref(),
        node.key.as_deref(),
        node.lower.as_deref(),
        node.upper.as_deref(),
    ]
    .into_iter()
    .flatten()
    {
        walk_self_reads(side, vars, bounds, env, blocked_children, out);
    }
    if let Some(vs) = node.values.as_ref() {
        for v in vs {
            walk_self_reads(v, vars, bounds, env, true, out);
        }
    }
    // An operator reference's bindings are read where its definition's body
    // reads each parameter, in this scope (esm-spec §9.6.4): a self-read in a
    // binding is a self-read of the equation, as in the reference's
    // expansion. Visited in sorted parameter-name order, so the reads are
    // collected in a fixed order.
    if let Some(r) = crate::operator_refs::reference_node(node) {
        let mut keys: Vec<&String> = r.bindings.keys().collect();
        keys.sort();
        for k in keys {
            walk_self_reads(&r.bindings[k], vars, bounds, env, blocked_children, out);
        }
    }
    env.truncate(env.len() - pushed);
}

/// The first reason a set of causal reads is not a well-founded recurrence
/// along one axis. `d` is always a position in the frame's `idx_names`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SelfReadDefect {
    /// A read supplies `supplied` indices against a frame of `axes` axes.
    Arity { supplied: usize, axes: usize },
    /// Index `d` is not affine in its frame symbol.
    NotAffine { d: usize },
    /// Index `d` carries its frame symbol with a coefficient other than 1.
    Coefficient { d: usize, coef: i64 },
    /// Index `d` names the cell being written or a later one on its axis.
    Forward { d: usize },
    /// A read is offset on axis `d` as well as on an earlier axis.
    MultiAxis { d: usize },
    /// A read of the variable itself is at the same cell on every axis.
    SameCell,
    /// A read of peer `target` is not provably strictly earlier on axis `d`.
    PeerUnproven { target: String, d: usize },
    /// Two reads fold along different axes.
    AxisDisagree { prev: usize, d: usize },
    /// A read of a stacked recurrence group does not select a member with a
    /// constant in `1..=hi` on the member axis `d`.
    MemberSelect { d: usize, hi: i64 },
}

/// What a well-founded set of causal reads folds along.
pub(crate) struct Fold {
    /// The recurrence axis; `None` when every read is a same-cell read of a
    /// peer or of an earlier stacked member.
    pub(crate) axis: Option<usize>,
    /// The largest proven lag along the axis (0 for an unprovable lag).
    pub(crate) max_lag: i64,
    /// Whether every lag was shown `>= 1` statically.
    pub(crate) lag_proven: bool,
    /// The peers read at the cell being written (esm-spec §4.3.1.2 rule 1).
    pub(crate) same_cell: Vec<String>,
}

/// How one index argument of a causal read relates to its frame symbol,
/// written in terms of the LAG `sym - <index expression>`, so a positive lag is
/// an earlier position.
enum SelfIdx {
    /// The lag is exactly zero.
    Identity,
    /// A lag that is not provably zero-or-forward, so this axis IS the
    /// recurrence axis. `proven` records whether every value of the lag was
    /// shown `>= 1` statically; when it is false the read may name the cell
    /// being written or a later one for some values of a contracted symbol, and
    /// the runtime's fail-closed read is what rules those out (esm-spec
    /// §4.3.1.1 point 5).
    Offset {
        proven: bool,
        max_lag: i64,
    },
    /// A lag that is provably `<= 0` for every value.
    Forward,
    NotAffine,
    Coefficient(i64),
}

fn classify_index(arg: &Expr, sym: &str, env: &SymbolBounds) -> SelfIdx {
    let Some(Affine { coef, konst }) = affine_in_sym(arg, sym, env) else {
        return SelfIdx::NotAffine;
    };
    if coef != 1 {
        return SelfIdx::Coefficient(coef);
    }
    let Some((clo, chi)) = konst else {
        // A lag whose sign could not be proved. Admitted as the recurrence
        // axis: it is not provably wrong, and the cells where it would be
        // ill-founded cannot be read (they are not published).
        return SelfIdx::Offset {
            proven: false,
            max_lag: 0,
        };
    };
    let (lag_lo, lag_hi) = (-chi, -clo);
    if lag_lo == 0 && lag_hi == 0 {
        return SelfIdx::Identity;
    }
    if lag_hi <= 0 {
        return SelfIdx::Forward;
    }
    SelfIdx::Offset {
        proven: lag_lo >= 1,
        max_lag: lag_hi,
    }
}

/// Classify the causal reads of `var`'s definition against its frame.
///
/// `frame_env` bounds the frame symbols themselves; each read's own scope is
/// layered over it. `member_axis` names the member axis of a stacked
/// recurrence group (esm-spec §4.3.1.2) and its member count: on that axis a
/// read selects a member with a constant instead of naming an offset, and a
/// read that is same-cell everywhere else reads an earlier member.
pub(crate) fn classify_self_reads(
    reads: &[SelfRead<'_>],
    var: &str,
    idx_names: &[String],
    frame_env: &SymbolBounds,
    member_axis: Option<(usize, i64)>,
) -> Result<Fold, SelfReadDefect> {
    let mut fold = Fold {
        axis: None,
        max_lag: 0,
        lag_proven: true,
        same_cell: Vec::new(),
    };
    for read in reads {
        if read.args.len() != idx_names.len() {
            return Err(SelfReadDefect::Arity {
                supplied: read.args.len(),
                axes: idx_names.len(),
            });
        }
        let mut env = frame_env.clone();
        env.extend(read.env.iter().map(|(k, v)| (k.clone(), *v)));
        let mut lagged: Option<(usize, i64)> = None;
        let mut proven = true;
        for (d, arg) in read.args.iter().enumerate() {
            if let Some((m, hi)) = member_axis
                && m == d
            {
                if matches!(arg, Expr::Integer(q) if (1..=hi).contains(q)) {
                    continue;
                }
                return Err(SelfReadDefect::MemberSelect { d, hi });
            }
            match classify_index(arg, &idx_names[d], &env) {
                SelfIdx::Identity => {}
                SelfIdx::Forward => return Err(SelfReadDefect::Forward { d }),
                SelfIdx::NotAffine => return Err(SelfReadDefect::NotAffine { d }),
                SelfIdx::Coefficient(coef) => {
                    return Err(SelfReadDefect::Coefficient { d, coef });
                }
                SelfIdx::Offset {
                    proven: p,
                    max_lag: hi,
                } => {
                    if lagged.is_some() {
                        return Err(SelfReadDefect::MultiAxis { d });
                    }
                    proven &= p;
                    lagged = Some((d, hi));
                }
            }
        }
        let Some((d, hi)) = lagged else {
            // A read of a PEER at the cell being written is an ordering WITHIN
            // the cell (esm-spec §4.3.1.2 rule 1): recorded, and rejected only
            // if such reads form a cycle. A stacked group's same-cell read of
            // an EARLIER member is admitted by the fail-closed read exactly
            // when that member precedes this one.
            if read.target != var {
                fold.same_cell.push(read.target.to_string());
                continue;
            }
            if member_axis.is_some() {
                continue;
            }
            return Err(SelfReadDefect::SameCell);
        };
        // A self-read need not be provably earlier (the runtime's fail-closed
        // read rules out the rest); a PEER read must be, because an
        // unpublished-cell fault is not order-free between two variables.
        if read.target != var && !proven {
            return Err(SelfReadDefect::PeerUnproven {
                target: read.target.to_string(),
                d,
            });
        }
        fold.lag_proven &= proven;
        match fold.axis {
            None => fold.axis = Some(d),
            Some(prev) if prev == d => {}
            Some(prev) => return Err(SelfReadDefect::AxisDisagree { prev, d }),
        }
        fold.max_lag = fold.max_lag.max(hi);
    }
    Ok(fold)
}

/// Guidance appended to the not-affine refusal of a causal self-read. The case
/// it names is the one authors reach for: a lag read from DATA
/// (`k - index(lag, k)`), where `lag[k]` is a value rather than a symbol with a
/// range. Shared by the validator and the compile path so the two refusals say
/// the same thing.
pub(crate) fn data_lag_guidance(var: &str, sym: &str) -> String {
    format!(
        "If the offset is read from data (`{sym} - index(lag, {sym})`), it has no direct \
         spelling; contract it instead: either order the axis so the predecessor is the \
         preceding position and the lag is the constant 1, or range a contracted index `a` \
         over the lag's bounds and select the matching term with \
         `ifelse(index(lag, {sym}) == a, <term reading index({var}, {sym} - a)>, 0)`."
    )
}
