//! Recurrence groups (esm-spec §4.3.1.2): several array observeds, each defined
//! by a `faq` over ONE shared cell frame, that read one another — and
//! themselves — only at strictly earlier positions along one shared axis.
//!
//! A group is evaluated by the normative reduction §4.3.1.2 states: as the
//! single §4.3.1.1 recurrence of a STACKED array `W` over the frame extended by
//! a trailing member axis `m ∈ 1..M` (members in the within-cell order: a
//! member read at the cell being written precedes its reader, ties in equation
//! order), whose cell
//! body at `m = p` is member `p`'s cell body with every `index(V_q, i…)` read of
//! a member rewritten to `index(W, i…, q)`; each member is then the slice
//! `V_p[i…] = W[i…, p]`. That rewrite runs here, on the model, before any rule
//! is built, so every evaluation route this crate has — the per-step observed
//! materialization, the build pipeline, the tape and the emitters downstream
//! of it — sweeps a group through the ONE recurrence implementation they
//! already share (CONFORMANCE_SPEC §5.19.3b). Nothing downstream knows a group
//! exists, except that the recurrence lowering admits a constant index on the
//! member axis and nowhere else ([`MEMBER_SYM`]).
//!
//! The member axis is innermost, so the sweep visits the recurrence axis
//! outermost, the remaining frame axes inside it, and the members fastest —
//! the order §4.3.1.2 fixes. A same-cell read of a peer therefore reads a cell
//! already published, and every other peer read is provably strictly earlier
//! on the recurrence axis, so no value depends on anything the order leaves
//! open.

use std::collections::{BTreeSet, HashMap};

use crate::compile_error::CompileError;
use crate::types::{Equation, Expr, ExpressionNode, IndexSet, Model, ModelVariable, RangeSpec};

/// The frame symbol of a stacked group's member axis. Reserved: the recurrence
/// lowering admits a constant index on an axis of this name, and only there.
pub(crate) const MEMBER_SYM: &str = "__esm_recurrence_member";

fn group_err(code: &str, detail: String) -> CompileError {
    CompileError::InterpreterBuildError {
        details: format!("{code}: {detail}"),
    }
}

/// One member, decomposed: its equation, the frame it sweeps and its cell body.
struct Member {
    var: String,
    eq_idx: usize,
    idx_names: Vec<String>,
    ranges: HashMap<String, RangeSpec>,
    body: Expr,
}

/// The frame and per-cell body of member `var`'s defining equation: either
/// `V ~ faq{output_idx: k…, …}` (the body is that `faq` restricted to one
/// cell) or the indexed-`faq` LHS form `faq{expr: index(V, k…)} ~ body`.
fn decompose(var: &str, eq_idx: usize, eq: &Equation) -> Result<Member, CompileError> {
    let unsupported = || {
        group_err(
            "recurrence_unsupported_form",
            format!(
                "'{var}' is a member of a recurrence group, but its definition is not one `faq` \
                 over its cell frame, so the group cannot be swept cell by cell \
                 (esm-spec §4.3.1.1, §4.3.1.2)."
            ),
        )
    };
    match (&eq.lhs, &eq.rhs) {
        (Expr::Variable(v), Expr::Operator(r)) if v == var && crate::faq::is_faq_op(&r.op) => {
            let idx_names = r.output_idx.clone().unwrap_or_default();
            if idx_names.is_empty() {
                return Err(unsupported());
            }
            Ok(Member {
                var: var.to_string(),
                eq_idx,
                body: super::compile::cell_restrict_aggregate(r, &idx_names),
                ranges: r.ranges.clone().unwrap_or_default(),
                idx_names,
            })
        }
        (Expr::Operator(l), rhs) if crate::faq::is_faq_op(&l.op) => {
            let idx_names = l.output_idx.clone().unwrap_or_default();
            if idx_names.is_empty() {
                return Err(unsupported());
            }
            Ok(Member {
                var: var.to_string(),
                eq_idx,
                body: rhs.clone(),
                ranges: l.ranges.clone().unwrap_or_default(),
                idx_names,
            })
        }
        _ => Err(unsupported()),
    }
}

/// `e` with every `index(V_q, a…)` of a member `V_q` rewritten to
/// `index(W, a…, q)`, and a bare read of a member refused.
fn stack_reads(e: &Expr, members: &[&str], w: &str) -> Result<Expr, CompileError> {
    match e {
        Expr::Variable(v) if members.contains(&v.as_str()) => Err(group_err(
            "recurrence_not_wellfounded",
            format!(
                "'{v}' is read bare inside its recurrence group. A bare read names the whole \
                 array, which does not exist while the group sweeps it (esm-spec §4.3.1.2)."
            ),
        )),
        Expr::Operator(node) => {
            if node.op == "index"
                && let Some(Expr::Variable(v)) = node.args.first()
                && let Some(q) = members.iter().position(|m| *m == v.as_str())
            {
                let mut args = Vec::with_capacity(node.args.len() + 1);
                args.push(Expr::Variable(w.to_string()));
                for a in &node.args[1..] {
                    args.push(stack_reads(a, members, w)?);
                }
                args.push(Expr::Integer(q as i64 + 1));
                let mut out = (**node).clone();
                out.args = args;
                return Ok(Expr::operator(out));
            }
            let mut err: Option<CompileError> = None;
            let mapped = node.map_children(&mut |c| match stack_reads(c, members, w) {
                Ok(x) => x,
                Err(e) => {
                    err.get_or_insert(e);
                    c.clone()
                }
            });
            match err {
                Some(e) => Err(e),
                None => Ok(Expr::operator(mapped)),
            }
        }
        other => Ok(other.clone()),
    }
}

/// Does `e` read member `peer` at the cell being written — `index(peer, k…)`
/// with every index the bare frame symbol of its axis?
fn reads_same_cell(e: &Expr, peer: &str, idx_names: &[String]) -> bool {
    let Expr::Operator(node) = e else {
        return false;
    };
    if node.op == "index"
        && matches!(node.args.first(), Some(Expr::Variable(v)) if v == peer)
        && node.args.len() == idx_names.len() + 1
        && node.args[1..]
            .iter()
            .zip(idx_names)
            .all(|(a, n)| matches!(a, Expr::Variable(v) if v == n))
    {
        return true;
    }
    node.any_child(&mut |c| reads_same_cell(c, peer, idx_names))
}

/// The members in the order §4.3.1.2 fixes for the member axis: a member that
/// another reads at the cell being written comes before it (rule 1), ties in
/// equation order. The validator rejects a cycle among such reads; one that
/// reached the build anyway is refused here rather than ordered arbitrarily.
fn order_within_cell(members: Vec<Member>) -> Result<Vec<Member>, CompileError> {
    let n = members.len();
    let deps: Vec<Vec<usize>> = (0..n)
        .map(|i| {
            (0..n)
                .filter(|&j| {
                    j != i && reads_same_cell(&members[i].body, &members[j].var, &members[i].idx_names)
                })
                .collect()
        })
        .collect();
    let mut placed = vec![false; n];
    let mut order: Vec<usize> = Vec::with_capacity(n);
    while order.len() < n {
        let Some(next) = (0..n).find(|&i| !placed[i] && deps[i].iter().all(|&j| placed[j])) else {
            return Err(group_err(
                "recurrence_not_wellfounded",
                format!(
                    "the members of the recurrence group {:?} read one another at the cell \
                     being written in a cycle (esm-spec §4.3.1.2 rule 1).",
                    members.iter().map(|m| m.var.as_str()).collect::<Vec<_>>()
                ),
            ));
        };
        placed[next] = true;
        order.push(next);
    }
    let mut slots: Vec<Option<Member>> = members.into_iter().map(Some).collect();
    Ok(order.into_iter().map(|i| slots[i].take().expect("each member placed once")).collect())
}

/// `a == b` as an expression node.
fn eq_node(a: Expr, b: Expr) -> Expr {
    Expr::operator(ExpressionNode {
        op: "==".into(),
        args: vec![a, b],
        ..Default::default()
    })
}

/// Rewrite every recurrence group of `model` into its stacked single
/// recurrence plus one slice per member (module docs). A model with no group —
/// every model that does not use the construct — is returned untouched after
/// one classification pass.
pub(crate) fn lower_recurrence_groups(
    model: &mut Model,
    index_sets: &mut HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    let groups: Vec<BTreeSet<String>> =
        crate::structural::recurrence_groups_of_parts(&model.variables, &model.equations);
    for group in groups {
        lower_one_group(model, index_sets, &group)?;
    }
    Ok(())
}

fn lower_one_group(
    model: &mut Model,
    index_sets: &mut HashMap<String, IndexSet>,
    group: &BTreeSet<String>,
) -> Result<(), CompileError> {
    // Members in equation order first; `order_within_cell` then puts them in
    // the order §4.3.1.2 fixes for the member axis.
    let mut members: Vec<Member> = Vec::new();
    for (i, eq) in model.equations.iter().enumerate() {
        let target = match crate::classification::lhs_form_ref(&eq.lhs) {
            crate::classification::LhsFormRef::Bare(n) => n.to_string(),
            _ => match &eq.lhs {
                Expr::Operator(l) if crate::faq::is_faq_op(&l.op) => match l.expr.as_deref() {
                    Some(Expr::Operator(inner)) if inner.op == "index" => {
                        match inner.args.first() {
                            Some(Expr::Variable(v)) => v.clone(),
                            _ => continue,
                        }
                    }
                    _ => continue,
                },
                _ => continue,
            },
        };
        if group.contains(&target) && !members.iter().any(|m| m.var == target) {
            members.push(decompose(&target, i, eq)?);
        }
    }
    if members.len() != group.len() {
        return Err(group_err(
            "recurrence_unsupported_form",
            format!("the recurrence group {group:?} has a member with no defining `faq` equation"),
        ));
    }
    let members = order_within_cell(members)?;
    let first = &members[0];
    for m in &members[1..] {
        if m.idx_names != first.idx_names
            || m.idx_names
                .iter()
                .any(|n| m.ranges.get(n) != first.ranges.get(n))
        {
            return Err(group_err(
                "recurrence_group_axis_mismatch",
                format!(
                    "'{}' and '{}' form a recurrence group but do not sweep the same cell frame \
                     (output indices {:?} vs {:?}); every member shares one frame \
                     (esm-spec §4.3.1.2).",
                    m.var, first.var, m.idx_names, first.idx_names
                ),
            ));
        }
    }
    let decl = |v: &str| model.variables.get(v);
    let shape: Vec<String> = decl(&first.var)
        .and_then(|d| d.shape.clone())
        .unwrap_or_default();
    let element_type = decl(&first.var).and_then(|d| d.element_type.clone());
    for m in &members[1..] {
        if decl(&m.var).and_then(|d| d.shape.clone()).unwrap_or_default() != shape {
            return Err(group_err(
                "recurrence_group_axis_mismatch",
                format!(
                    "'{}' and '{}' form a recurrence group but are declared over different \
                     shapes (esm-spec §4.3.1.2).",
                    m.var, first.var
                ),
            ));
        }
        if decl(&m.var).and_then(|d| d.element_type.clone()) != element_type {
            return Err(group_err(
                "recurrence_unsupported_form",
                format!(
                    "the members '{}' and '{}' of a recurrence group declare different \
                     `element_type`s; this binding sweeps a group at one working precision.",
                    m.var, first.var
                ),
            ));
        }
    }
    if first.idx_names.iter().any(|n| n == MEMBER_SYM) {
        return Err(group_err(
            "recurrence_unsupported_form",
            format!("'{MEMBER_SYM}' is reserved for the member axis of a recurrence group"),
        ));
    }

    let names: Vec<&str> = members.iter().map(|m| m.var.as_str()).collect();
    let mut w = format!("__esm_recurrence_group__{}", names.join("__"));
    while model.variables.contains_key(&w) || index_sets.contains_key(&format!("{w}__members"))
    {
        w.push('_');
    }
    let member_set = format!("{w}__members");
    let m_count = members.len() as i64;

    // The stacked body: `ifelse(m == 1, body_1, ifelse(m == 2, body_2, … body_M))`,
    // a scalar-conditioned `ifelse`, so only the selected member's body is
    // evaluated at each cell (esm-spec §4.3.1.1).
    let mut stacked: Option<Expr> = None;
    for (p, m) in members.iter().enumerate().rev() {
        let body = stack_reads(&m.body, &names, &w)?;
        stacked = Some(match stacked {
            None => body,
            Some(rest) => Expr::operator(ExpressionNode {
                op: "ifelse".into(),
                args: vec![
                    eq_node(Expr::Variable(MEMBER_SYM.into()), Expr::Integer(p as i64 + 1)),
                    body,
                    rest,
                ],
                ..Default::default()
            }),
        });
    }
    let stacked = stacked.expect("a group has at least two members");

    let mut out_idx = first.idx_names.clone();
    out_idx.push(MEMBER_SYM.into());
    let mut ranges = first.ranges.clone();
    ranges.insert(MEMBER_SYM.into(), RangeSpec::Interval([1, m_count]));
    let w_rhs = Expr::operator(ExpressionNode {
        op: "faq".into(),
        args: vec![],
        output_idx: Some(out_idx),
        ranges: Some(ranges),
        expr: Some(Box::new(stacked)),
        ..Default::default()
    });

    // Each member becomes the slice `V_p[k…] = W[k…, p]`.
    for (p, m) in members.iter().enumerate() {
        let mut gather = vec![Expr::Variable(w.clone())];
        gather.extend(m.idx_names.iter().map(|n| Expr::Variable(n.clone())));
        gather.push(Expr::Integer(p as i64 + 1));
        let slice = Expr::operator(ExpressionNode {
            op: "faq".into(),
            args: vec![],
            output_idx: Some(m.idx_names.clone()),
            ranges: Some(m.ranges.clone()),
            expr: Some(Box::new(Expr::operator(ExpressionNode {
                op: "index".into(),
                args: gather,
                ..Default::default()
            }))),
            ..Default::default()
        });
        let eq = &mut model.equations[m.eq_idx];
        eq.lhs = Expr::Variable(m.var.clone());
        eq.rhs = slice;
    }

    let mut w_shape = shape;
    w_shape.push(member_set.clone());
    let set: IndexSet = serde_json::from_value(serde_json::json!({
        "kind": "interval",
        "size": m_count,
    }))
    .expect("an interval index set deserializes");
    index_sets.insert(member_set, set);
    let mut w_decl: ModelVariable = serde_json::from_value(serde_json::json!({
        "type": "unknown",
    }))
    .expect("an unknown deserializes");
    w_decl.shape = Some(w_shape);
    w_decl.element_type = element_type;
    w_decl.description = Some(format!(
        "the stacked recurrence group {names:?} (esm-spec §4.3.1.2), introduced by the build"
    ));
    model.variables.insert(w.clone(), w_decl);
    let insert_at = members.iter().map(|m| m.eq_idx).min().expect("a group has members");
    model.equations.insert(
        insert_at,
        Equation {
            lhs: Expr::Variable(w),
            rhs: w_rhs,
            comment: None,
        },
    );
    Ok(())
}
