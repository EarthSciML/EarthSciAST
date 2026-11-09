//! Elementwise application of an expression template over array arguments
//! (esm-spec §9.6.11), carried out as a per-cell lift when a model is built.
//!
//! A template written for scalar inputs — the `lib/interp.esm` lookups are the
//! motivating case — reads a scalar-role parameter inside a reduction body
//! (`faq` with no output index) or an `index` subscript. Bound to an array, by
//! the author or by a coupling that feeds an array into a parameter the
//! component declared scalar, the substituted expansion reads a whole array
//! where the body needs one value. §9.6.11 gives the application its
//! elementwise meaning: it is evaluated once per element of the array
//! argument.
//!
//! This binding expands every template reference at load, so by the time a
//! model is built the application boundary is gone. The rule is therefore
//! applied to its trace on the expanded, flattened equations: an observed
//! equation whose right-hand side reads a shaped variable by bare name in a
//! *scalar slot* — inside the body or filter of a reduction `faq`, or inside an
//! `index` subscript — is rewritten into a `faq` over the result's index sets
//! whose body is the right-hand side with every bare shaped read gathered at
//! that cell, aligned by index-set name (§4.3.4). Every elementwise operator
//! between the root and the application commutes with the per-cell reading,
//! so the lift evaluates the application elementwise and the rest of the
//! right-hand side exactly as the whole-array form would.
//!
//! An equation with no such read is left exactly as it was.

use crate::types::{Expr, ExpressionNode, Model, RangeSpec};
use std::collections::{HashMap, HashSet};

/// Lift every observed equation of `model` that reads a shaped variable in a
/// scalar slot (see the module docs), and give each lifted variable that was
/// declared without a `shape` the index sets it was lifted over. Returns those
/// shapes, by variable name.
///
/// Repeats until no equation changes, so a chain — a lifted observed read in a
/// scalar slot of another template application — is lifted link by link.
///
/// # Errors
///
/// `array_shape_mismatch` (esm-spec §4.3.4) when the array arguments of a
/// lifted right-hand side have no common index sets: neither one's index sets
/// contain the other's, or an operand names an index set the declared result
/// shape does not.
pub(crate) fn lift_elementwise_applications(
    model: &mut Model,
) -> Result<HashMap<String, Vec<String>>, String> {
    let mut shapes: HashMap<String, Vec<String>> = model
        .variables
        .iter()
        .filter_map(|(n, v)| match &v.shape {
            Some(s) if !s.is_empty() => Some((n.clone(), s.clone())),
            _ => None,
        })
        .collect();
    // A variable declared WITHOUT a shape whose definition is elementwise over
    // shaped operands is an array too (§4.3.4). Its shape is needed to see it
    // in a scalar slot downstream, but nothing here writes it: only a lifted
    // definition gains a declared shape.
    let unshaped: HashSet<String> = model
        .variables
        .iter()
        .filter(|(_, v)| v.shape.is_none())
        .map(|(n, _)| n.clone())
        .collect();
    let mut lifted: HashMap<String, Vec<String>> = HashMap::new();
    let mut changed = true;
    let mut passes = 0usize;
    while changed && passes <= model.equations.len() + 1 {
        changed = false;
        passes += 1;
        for k in 0..model.equations.len() {
            let Expr::Variable(lhs) = &model.equations[k].lhs else {
                continue;
            };
            let lhs = lhs.clone();
            let rhs = &model.equations[k].rhs;
            if !has_scalar_slot_read(rhs, &shapes) {
                // Not lifted: record the elementwise shape of an unshaped
                // definition so a reader of it can be lifted.
                if unshaped.contains(&lhs) && !shapes.contains_key(&lhs) {
                    let mut reads = Vec::new();
                    collect_reads(rhs, &shapes, &HashSet::new(), false, &mut |n, slot| {
                        if !slot {
                            reads.push(n.to_string());
                        }
                    });
                    if let Ok(Some(axes)) = union_axes(&reads, &shapes) {
                        shapes.insert(lhs, axes);
                        changed = true;
                    }
                }
                continue;
            }
            let declared = model
                .variables
                .get(&lhs)
                .and_then(|v| v.shape.clone())
                .filter(|s| !s.is_empty());
            let axes = match &declared {
                Some(s) => s.clone(),
                None => {
                    let mut reads = Vec::new();
                    collect_reads(rhs, &shapes, &HashSet::new(), false, &mut |n, _| {
                        reads.push(n.to_string());
                    });
                    union_axes(&reads, &shapes)
                        .map_err(|m| format!("array_shape_mismatch: '{lhs}': {m}"))?
                        .ok_or_else(|| format!("array_shape_mismatch: '{lhs}': no array operand"))?
                }
            };
            if (1..axes.len()).any(|d| axes[..d].contains(&axes[d])) {
                return Err(format!(
                    "array_shape_mismatch: '{lhs}': the elementwise application is over \
                     {axes:?}, which names one index set twice, so a read has no single \
                     axis to align to (esm-spec §9.6.11)"
                ));
            }
            let loops = fresh_loops(rhs, axes.len());
            let ctx = Lift {
                axes: &axes,
                loops: &loops,
                shapes: &shapes,
                lhs: &lhs,
            };
            let body = ctx.wrap(rhs, &HashSet::new())?;
            let ranges: HashMap<String, RangeSpec> = loops
                .iter()
                .zip(&axes)
                .map(|(l, a)| {
                    (
                        l.clone(),
                        RangeSpec::IndexSetRef {
                            from: a.clone(),
                            of: None,
                        },
                    )
                })
                .collect();
            model.equations[k].rhs = Expr::operator(ExpressionNode {
                op: "faq".to_string(),
                args: Vec::new(),
                output_idx: Some(loops),
                ranges: Some(ranges),
                expr: Some(Box::new(body)),
                ..Default::default()
            });
            if declared.is_none() {
                shapes.insert(lhs.clone(), axes.clone());
                lifted.insert(lhs, axes);
            }
            changed = true;
        }
    }
    for (name, axes) in &lifted {
        if let Some(var) = model.variables.get_mut(name) {
            var.shape = Some(axes.clone());
        }
    }
    Ok(lifted)
}

/// The argument positions of a closed function that take a whole array (the
/// table and axes of an interpolation), which a per-cell reading leaves whole.
fn whole_array_fn_args(name: Option<&str>) -> &'static [usize] {
    match name {
        Some("interp.linear") => &[0, 1],
        Some("interp.bilinear") => &[0, 1, 2],
        Some("interp.searchsorted") => &[1],
        _ => &[],
    }
}

/// Visit every bare variable read of `expr` in VALUE position — an operand of
/// an elementwise operator, a closed-function scalar argument, a reduction
/// body or filter, an `index` subscript — with `slot` true when the read sits
/// in a scalar slot (a reduction body or filter, or a subscript). A name a
/// reduction binds as a loop symbol is not a read. An `index` base and every
/// operand an op consumes whole (an array-producing `faq`, `makearray`, the
/// shape, geometry and relational ops) are not visited.
fn collect_reads(
    expr: &Expr,
    shapes: &HashMap<String, Vec<String>>,
    bound: &HashSet<String>,
    slot: bool,
    f: &mut dyn FnMut(&str, bool),
) {
    match expr {
        Expr::Variable(n) => {
            if !bound.contains(n) && shapes.contains_key(n) {
                f(n, slot);
            }
        }
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Operator(node) => match node.op.as_str() {
            "index" => {
                for a in node.args.iter().skip(1) {
                    collect_reads(a, shapes, bound, true, f);
                }
            }
            "faq" => {
                if node.output_idx.as_ref().is_some_and(|o| !o.is_empty()) {
                    return;
                }
                let inner = reduction_bound(node, bound);
                if let Some(b) = &node.expr {
                    collect_reads(b, shapes, &inner, true, f);
                }
                if let Some(b) = &node.filter {
                    collect_reads(b, shapes, &inner, true, f);
                }
            }
            "fn" => {
                let whole = whole_array_fn_args(node.name.as_deref());
                for (i, a) in node.args.iter().enumerate() {
                    if !whole.contains(&i) {
                        collect_reads(a, shapes, bound, slot, f);
                    }
                }
            }
            _ if crate::op_registry::is_elementwise_node(node) => {
                for a in &node.args {
                    collect_reads(a, shapes, bound, slot, f);
                }
            }
            _ => {}
        },
    }
}

/// `bound` plus the loop symbols a reduction `faq` binds.
fn reduction_bound(node: &ExpressionNode, bound: &HashSet<String>) -> HashSet<String> {
    let mut inner = bound.clone();
    if let Some(r) = &node.ranges {
        inner.extend(r.keys().cloned());
    }
    inner
}

/// Whether `expr` reads a shaped variable by bare name in a scalar slot.
fn has_scalar_slot_read(expr: &Expr, shapes: &HashMap<String, Vec<String>>) -> bool {
    let mut found = false;
    collect_reads(expr, shapes, &HashSet::new(), false, &mut |_, slot| {
        found |= slot;
    });
    found
}

/// The index sets an elementwise application over the shaped `reads` runs
/// over: the one read's index sets that contain every other read's (§4.3.4).
/// `Ok(None)` when nothing is read; `Err` when no read's index sets contain
/// all the others'.
fn union_axes(
    reads: &[String],
    shapes: &HashMap<String, Vec<String>>,
) -> Result<Option<Vec<String>>, String> {
    let mut acc: Option<&Vec<String>> = None;
    for n in reads {
        let Some(s) = shapes.get(n) else { continue };
        acc = match acc {
            None => Some(s),
            Some(cur) if s.iter().all(|a| cur.contains(a)) => Some(cur),
            Some(cur) if cur.iter().all(|a| s.contains(a)) => Some(s),
            Some(cur) => {
                return Err(format!(
                    "array arguments over {cur:?} and {s:?} (from '{n}'): neither one's index \
                     sets contain the other's, so there is no elementwise result shape \
                     (esm-spec §9.6.11, §4.3.4)"
                ));
            }
        };
    }
    Ok(acc.cloned())
}

/// `n` loop names that no name in `expr` uses.
fn fresh_loops(expr: &Expr, n: usize) -> Vec<String> {
    let mut used: HashSet<String> = HashSet::new();
    names_in(expr, &mut used);
    let mut prefix = "_p".to_string();
    loop {
        let loops: Vec<String> = (0..n).map(|d| format!("{prefix}{d}")).collect();
        if loops.iter().all(|l| !used.contains(l)) {
            return loops;
        }
        prefix.insert(0, '_');
    }
}

fn names_in(expr: &Expr, out: &mut HashSet<String>) {
    match expr {
        Expr::Variable(n) => {
            out.insert(n.clone());
        }
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Operator(node) => {
            for a in &node.args {
                names_in(a, out);
            }
            if let Some(b) = &node.expr {
                names_in(b, out);
            }
            if let Some(b) = &node.filter {
                names_in(b, out);
            }
            if let Some(r) = &node.ranges {
                out.extend(r.keys().cloned());
            }
            if let Some(o) = &node.output_idx {
                out.extend(o.iter().cloned());
            }
        }
    }
}

/// One lift: the result's index sets and the loop symbol over each.
struct Lift<'a> {
    axes: &'a [String],
    loops: &'a [String],
    shapes: &'a HashMap<String, Vec<String>>,
    lhs: &'a str,
}

impl Lift<'_> {
    /// `expr` read at the current cell: every bare shaped read in value
    /// position (the positions [`collect_reads`] visits) gathered at the loops
    /// its index sets name.
    fn wrap(&self, expr: &Expr, bound: &HashSet<String>) -> Result<Expr, String> {
        match expr {
            Expr::Variable(n) if !bound.contains(n) => match self.shapes.get(n) {
                Some(shape) => self.gather(n, shape),
                None => Ok(expr.clone()),
            },
            Expr::Variable(_) | Expr::Number(_) | Expr::Integer(_) => Ok(expr.clone()),
            Expr::Operator(node) => {
                let mut out = ExpressionNode::clone(node);
                match node.op.as_str() {
                    "index" => {
                        for a in out.args.iter_mut().skip(1) {
                            *a = self.wrap(a, bound)?;
                        }
                    }
                    "faq" => {
                        if node.output_idx.as_ref().is_some_and(|o| !o.is_empty()) {
                            return Ok(expr.clone());
                        }
                        let inner = reduction_bound(node, bound);
                        if let Some(b) = &node.expr {
                            out.expr = Some(Box::new(self.wrap(b, &inner)?));
                        }
                        if let Some(b) = &node.filter {
                            out.filter = Some(Box::new(self.wrap(b, &inner)?));
                        }
                    }
                    "fn" => {
                        let whole = whole_array_fn_args(node.name.as_deref());
                        for (i, a) in out.args.iter_mut().enumerate() {
                            if !whole.contains(&i) {
                                *a = self.wrap(a, bound)?;
                            }
                        }
                    }
                    _ if crate::op_registry::is_elementwise_node(node) => {
                        for a in out.args.iter_mut() {
                            *a = self.wrap(a, bound)?;
                        }
                    }
                    _ => return Ok(expr.clone()),
                }
                Ok(Expr::operator(out))
            }
        }
    }

    /// `index(name, …)` with each of `name`'s index sets read at the loop over
    /// the same index set of the result, so a read over a subset of the
    /// result's index sets replicates along the rest (§4.3.4).
    fn gather(&self, name: &str, shape: &[String]) -> Result<Expr, String> {
        let mut args = Vec::with_capacity(shape.len() + 1);
        args.push(Expr::Variable(name.to_string()));
        for (d, axis) in shape.iter().enumerate() {
            let p = self.axes.iter().position(|a| a == axis);
            match p {
                Some(p) if !shape[..d].contains(axis) => {
                    args.push(Expr::Variable(self.loops[p].clone()));
                }
                _ => {
                    return Err(format!(
                        "array_shape_mismatch: '{}': '{name}' (shape {shape:?}) is an array \
                         argument of an elementwise application over {:?}, which is not \
                         shaped over its index set '{axis}' exactly once (esm-spec §9.6.11, \
                         §4.3.4)",
                        self.lhs, self.axes
                    ));
                }
            }
        }
        Ok(Expr::operator(ExpressionNode {
            op: "index".to_string(),
            args,
            ..Default::default()
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(json: &str) -> Expr {
        serde_json::from_str(json).expect("expr")
    }

    #[test]
    fn a_reduction_body_read_is_a_scalar_slot_read() {
        let shapes: HashMap<String, Vec<String>> =
            [("lev".to_string(), vec!["c".to_string()])].into();
        let e = parse(
            r#"{"op":"faq","args":[],"output_idx":[],"ranges":{"k":[1,3]},
                "expr":{"op":"<=","args":[{"op":"index","args":["ax","k"]},"lev"]}}"#,
        );
        assert!(has_scalar_slot_read(&e, &shapes));
        // An elementwise read alone is ordinary broadcasting: no lift.
        assert!(!has_scalar_slot_read(
            &parse(r#"{"op":"*","args":[2,"lev"]}"#),
            &shapes
        ));
        // A read the reduction binds as its own loop symbol is not a variable read.
        let shadow = parse(
            r#"{"op":"faq","args":[],"output_idx":[],"ranges":{"lev":[1,3]},
                "expr":{"op":"index","args":["ax","lev"]}}"#,
        );
        assert!(!has_scalar_slot_read(&shadow, &shapes));
    }

    #[test]
    fn incomparable_array_arguments_are_refused() {
        let shapes: HashMap<String, Vec<String>> = [
            ("a".to_string(), vec!["x".to_string()]),
            ("b".to_string(), vec!["y".to_string()]),
        ]
        .into();
        let err = union_axes(&["a".into(), "b".into()], &shapes).unwrap_err();
        assert!(err.contains("neither one's index sets"), "{err}");
        let shapes2: HashMap<String, Vec<String>> = [
            ("a".to_string(), vec!["z".to_string()]),
            (
                "b".to_string(),
                vec!["x".to_string(), "y".to_string(), "z".to_string()],
            ),
        ]
        .into();
        assert_eq!(
            union_axes(&["a".into(), "b".into()], &shapes2).unwrap(),
            Some(vec!["x".to_string(), "y".to_string(), "z".to_string()])
        );
    }
}
