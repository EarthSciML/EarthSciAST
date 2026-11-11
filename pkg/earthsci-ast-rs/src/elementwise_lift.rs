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
//! This binding expands every template reference at load and marks the root
//! of each expansion with its template's name
//! ([`ExpressionNode::template_origin`]). The rule applies to those marked
//! applications only: an observed equation whose right-hand side holds, in
//! elementwise position, an application whose expansion reads a shaped
//! variable in a value position (an operand of an elementwise operator, the
//! body or filter of a reduction, an `index` subscript) is rewritten into a `faq` over the result's index sets.
//! Its body is the right-hand side with each such read, and each bare shaped
//! read outside the applications in elementwise position, gathered at that
//! cell, aligned by index-set name (§4.3.4). Every elementwise operator
//! between the root and an application commutes with the per-cell reading, so
//! the lift evaluates the application elementwise and the rest of the
//! right-hand side exactly as the whole-array form would.
//!
//! An equation with no such application is left exactly as it was: a shaped
//! read an author wrote by hand in a reduction body or a subscript is never
//! given this meaning.

use crate::types::{Expr, ExpressionNode, Model, RangeSpec};
use std::collections::{HashMap, HashSet};

/// Lift every observed equation of `model` that applies a template
/// elementwise (see the module docs), and give each lifted variable that was
/// declared without a `shape` the index sets it was lifted over. Returns those
/// shapes, by variable name. A variable declared `shape: []` is a scalar and
/// is never lifted. A field initial condition `ic(x) = rhs` is lifted over
/// `x`'s declared shape.
///
/// Repeats until no equation changes, so a chain — a lifted observed read by
/// another elementwise application — is lifted link by link.
///
/// # Errors
///
/// `array_shape_mismatch` (esm-spec §9.6.11, §4.3.4) when the array arguments
/// of a lifted right-hand side have no common index sets (neither one's index
/// sets contain the other's, or an operand names an index set the declared
/// result shape does not), and when an application of any equation reads an
/// anonymous array (a `const` array literal, a `reshape` result) in a value
/// position, which has no index sets to align by.
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
    // as an array argument downstream, but nothing here writes it: only a
    // lifted definition gains a declared shape.
    let unshaped: HashSet<String> = model
        .variables
        .iter()
        .filter(|(_, v)| v.shape.is_none())
        .map(|(n, _)| n.clone())
        .collect();
    for eq in &model.equations {
        refuse_anonymous_arrays(&eq.rhs, &eq.lhs)?;
    }
    let mut lifted: HashMap<String, Vec<String>> = HashMap::new();
    let mut changed = true;
    let mut passes = 0usize;
    while changed && passes <= model.equations.len() + 1 {
        changed = false;
        passes += 1;
        for k in 0..model.equations.len() {
            // A field initial condition `ic(x) = rhs` is lifted over `x`'s
            // declared shape; it defines no variable, so it shapes none.
            let (lhs, is_ic) = match &model.equations[k].lhs {
                Expr::Variable(n) => (n.clone(), false),
                other => match crate::flatten::extract_ic_target(other) {
                    Some(t) => (t, true),
                    None => continue,
                },
            };
            let rhs = &model.equations[k].rhs;
            let mut reads: Vec<(String, bool)> = Vec::new();
            walk(rhs, &shapes, &HashSet::new(), false, &mut |seen| {
                if let Seen::Read { name, inside } = seen {
                    reads.push((name.to_string(), inside));
                }
            });
            if !reads.iter().any(|(_, inside)| *inside) {
                // Not lifted: record the elementwise shape of an unshaped
                // definition so an application reading it can be lifted.
                if !is_ic && unshaped.contains(&lhs) && !shapes.contains_key(&lhs) {
                    let names: Vec<String> = reads.into_iter().map(|(n, _)| n).collect();
                    if let Ok(Some(axes)) = union_axes(&names, &shapes) {
                        shapes.insert(lhs, axes);
                        changed = true;
                    }
                }
                continue;
            }
            let declared = model.variables.get(&lhs).and_then(|v| v.shape.clone());
            let axes = match &declared {
                // `shape: []` declares a scalar (esm-spec §4.3.1): never lifted.
                Some(s) if s.is_empty() => continue,
                Some(s) => s.clone(),
                // An initial condition takes its state's declared shape only.
                None if is_ic => continue,
                None => {
                    let names: Vec<String> = reads.into_iter().map(|(n, _)| n).collect();
                    union_axes(&names, &shapes)
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
            let body = intern_tree(&ctx.wrap(rhs, &HashSet::new(), false)?);
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

/// `expr` with every structurally identical subtree one shared node, as load
/// interns a document ([`crate::intern`]).
///
/// The lifted body is a new tree, and the copies an expanded template repeats
/// in it — the query of `linear` sits in five bracket counts and the blend,
/// each count over the same `const` axis — must be one node again: the native
/// tape's value numbering keys a node by its address, so unshared copies are
/// each evaluated once per cell, where the same `faq` written by hand
/// evaluates them once. The whole body is rebuilt bottom-up under one
/// interning scope, not only the nodes the lift rewrote: the subtrees it keeps
/// may already be unshared copies (flatten rewrites a coupled component's
/// equations node by node).
fn intern_tree(expr: &Expr) -> Expr {
    fn go(e: &Expr, memo: &mut HashMap<*const ExpressionNode, Expr>) -> Expr {
        let Expr::Operator(node) = e else {
            return e.clone();
        };
        let key = std::sync::Arc::as_ptr(node);
        if let Some(hit) = memo.get(&key) {
            return hit.clone();
        }
        let out = Expr::operator(node.map_children(&mut |c| go(c, memo)));
        memo.insert(key, out.clone());
        out
    }
    let _intern = crate::intern::InternScope::new();
    go(expr, &mut HashMap::new())
}

/// What [`walk`] reports.
enum Seen<'a> {
    /// A shaped variable read by bare name in a value position; `inside` when
    /// the read is inside a template application.
    Read { name: &'a str, inside: bool },
    /// An anonymous array (a `const` array literal, a `reshape` result) in a
    /// value position inside a template application.
    Anonymous { node: &'a ExpressionNode },
}

/// Visit every value position of `expr` (esm-spec §9.6.11). Outside a
/// template application those are the operands of elementwise operators, the
/// positions the per-cell reading commutes with. Inside one (a node carrying a
/// [`ExpressionNode::template_origin`], and everything below it) they are also
/// the body and filter of a reduction `faq` and the subscripts of an `index`,
/// where the template reads its scalar-role parameters. A name a reduction
/// binds as a loop symbol is not a read. An `index` base and every operand an
/// op consumes whole (an array-producing `faq`, `makearray`, the shape and
/// relational ops) are array positions, not visited.
fn walk<'a>(
    expr: &'a Expr,
    shapes: &HashMap<String, Vec<String>>,
    bound: &HashSet<String>,
    inside: bool,
    f: &mut dyn FnMut(Seen<'a>),
) {
    match expr {
        Expr::Variable(n) => {
            if !bound.contains(n) && shapes.contains_key(n) {
                f(Seen::Read { name: n, inside });
            }
        }
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Operator(node) => {
            let inside = inside || node.template_origin.is_some();
            match node.op.as_str() {
                "index" if inside => {
                    for a in node.args.iter().skip(1) {
                        walk(a, shapes, bound, true, f);
                    }
                }
                "faq" if inside && is_reduction(node) => {
                    let inner = reduction_bound(node, bound);
                    if let Some(b) = &node.expr {
                        walk(b, shapes, &inner, true, f);
                    }
                    if let Some(b) = &node.filter {
                        walk(b, shapes, &inner, true, f);
                    }
                }
                "const" if inside && node.value.as_ref().is_some_and(|v| v.is_array()) => {
                    f(Seen::Anonymous { node });
                }
                "reshape" if inside => f(Seen::Anonymous { node }),
                _ if crate::op_registry::is_elementwise_node(node) => {
                    for a in &node.args {
                        walk(a, shapes, bound, inside, f);
                    }
                }
                _ => {}
            }
        }
    }
}

/// Whether `node` is a `faq` with no output index (a reduction to a scalar).
fn is_reduction(node: &ExpressionNode) -> bool {
    node.output_idx.as_ref().is_none_or(|o| o.is_empty())
}

/// `array_shape_mismatch` when a template application in `rhs` reads an
/// anonymous array in a value position: it has no index sets, so nothing
/// says which element each cell reads (esm-spec §9.6.11).
fn refuse_anonymous_arrays(rhs: &Expr, lhs: &Expr) -> Result<(), String> {
    let mut found: Option<String> = None;
    walk(rhs, &HashMap::new(), &HashSet::new(), false, &mut |seen| {
        if let Seen::Anonymous { node } = seen {
            found.get_or_insert_with(|| node.op.clone());
        }
    });
    let Some(op) = found else {
        return Ok(());
    };
    let lhs = match lhs {
        Expr::Variable(n) => n.clone(),
        other => crate::display::to_unicode(other),
    };
    Err(format!(
        "array_shape_mismatch: '{lhs}': a template application reads an anonymous array \
         (a `{op}` node) where its body reads a scalar; an array argument of an elementwise \
         application must be declared over index sets, so each cell knows which element it \
         reads (esm-spec §9.6.11)"
    ))
}

/// `bound` plus the loop symbols a reduction `faq` binds.
fn reduction_bound(node: &ExpressionNode, bound: &HashSet<String>) -> HashSet<String> {
    let mut inner = bound.clone();
    if let Some(r) = &node.ranges {
        inner.extend(r.keys().cloned());
    }
    inner
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

/// Every name `expr` reads or binds: the names the lift's loop symbols must
/// not shadow. Every expression-bearing field ([`ExpressionNode::for_each_child`])
/// and every name-bearing one: the symbols a node binds (`int_var`, range
/// keys, `output_idx`), a range's `of` parents, `wrt`, `dim`, an
/// argmin/argmax `arg`, and a `table_lookup`'s axis names. The Julia
/// binding's `_ew_names!`.
fn names_in(expr: &Expr, out: &mut HashSet<String>) {
    match expr {
        Expr::Variable(n) => {
            out.insert(n.clone());
        }
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Operator(node) => {
            for name in [&node.int_var, &node.wrt, &node.dim, &node.arg]
                .into_iter()
                .flatten()
            {
                out.insert(name.clone());
            }
            if let Some(r) = &node.ranges {
                for (k, spec) in r {
                    out.insert(k.clone());
                    if let RangeSpec::IndexSetRef { of: Some(of), .. } = spec {
                        out.extend(of.iter().cloned());
                    }
                }
            }
            if let Some(o) = &node.output_idx {
                out.extend(o.iter().cloned());
            }
            if let Some(a) = &node.axes {
                out.extend(a.keys().cloned());
            }
            node.for_each_child(&mut |c| names_in(c, out));
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
    /// `expr` read at the current cell: every shaped read [`walk`] visits
    /// gathered at the loops its index sets name; `inside` as for [`walk`].
    fn wrap(&self, expr: &Expr, bound: &HashSet<String>, inside: bool) -> Result<Expr, String> {
        match expr {
            Expr::Variable(n) if !bound.contains(n) => match self.shapes.get(n) {
                Some(shape) => self.gather(n, shape),
                None => Ok(expr.clone()),
            },
            Expr::Variable(_) | Expr::Number(_) | Expr::Integer(_) => Ok(expr.clone()),
            Expr::Operator(node) => {
                let inside = inside || node.template_origin.is_some();
                let mut out = ExpressionNode::clone(node);
                match node.op.as_str() {
                    "index" if inside => {
                        for a in out.args.iter_mut().skip(1) {
                            *a = self.wrap(a, bound, true)?;
                        }
                    }
                    "faq" if inside && is_reduction(node) => {
                        let inner = reduction_bound(node, bound);
                        if let Some(b) = &node.expr {
                            out.expr = Some(Box::new(self.wrap(b, &inner, true)?));
                        }
                        if let Some(b) = &node.filter {
                            out.filter = Some(Box::new(self.wrap(b, &inner, true)?));
                        }
                    }
                    _ if crate::op_registry::is_elementwise_node(node) => {
                        for a in out.args.iter_mut() {
                            *a = self.wrap(a, bound, inside)?;
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

    /// Every `(name, inside)` read [`walk`] reports for `expr`.
    fn reads(expr: &Expr, shapes: &HashMap<String, Vec<String>>) -> Vec<(String, bool)> {
        let mut out = Vec::new();
        walk(expr, shapes, &HashSet::new(), false, &mut |seen| {
            if let Seen::Read { name, inside } = seen {
                out.push((name.to_string(), inside));
            }
        });
        out
    }

    #[test]
    fn only_a_template_application_reads_inside_a_reduction() {
        let shapes: HashMap<String, Vec<String>> =
            [("lev".to_string(), vec!["c".to_string()])].into();
        let count = |mark: &str| {
            parse(&format!(
                r#"{{"op":"faq","args":[],"output_idx":[],"ranges":{{"k":[1,3]}}{mark},
                    "expr":{{"op":"<=","args":[{{"op":"index","args":["ax","k"]}},"lev"]}}}}"#
            ))
        };
        // The expansion of an application reads `lev` where its body reads a
        // scalar: the application is elementwise.
        let marked = count(r#","__esm_template_origin":"linear""#);
        assert_eq!(reads(&marked, &shapes), vec![("lev".to_string(), true)]);
        // The same reduction written by hand is not an application, and a
        // read in its body is not one of the positions the lift reads.
        assert!(reads(&count(""), &shapes).is_empty());
        // An elementwise read outside an application is ordinary broadcasting.
        assert_eq!(
            reads(&parse(r#"{"op":"*","args":[2,"lev"]}"#), &shapes),
            vec![("lev".to_string(), false)]
        );
        // A read the reduction binds as its own loop symbol is not a variable read.
        let shadow = parse(
            r#"{"op":"faq","args":[],"output_idx":[],"ranges":{"lev":[1,3]},
                "__esm_template_origin":"t","expr":{"op":"index","args":["ax","lev"]}}"#,
        );
        assert!(reads(&shadow, &shapes).is_empty());
    }

    /// `doc`'s one model flattened as a build sees it, the lift run on it:
    /// what it lifted, and `M.<lhs>`'s right-hand side before and after.
    fn lift_doc(doc: &serde_json::Value, lhs: &str) -> (HashMap<String, Vec<String>>, Expr, Expr) {
        let file = crate::parse::load_string(&doc.to_string()).expect("loads");
        let flat = crate::flatten::flatten(&file).expect("flattens");
        let mut model = crate::simulate_array::model_from_flattened(&flat);
        let rhs = |m: &Model| {
            m.equations
                .iter()
                .find(|e| matches!(&e.lhs, Expr::Variable(n) if n == lhs))
                .expect("defined")
                .rhs
                .clone()
        };
        let before = rhs(&model);
        let lifted = lift_elementwise_applications(&mut model).expect("lift");
        (lifted, before, rhs(&model))
    }

    fn probe_doc(
        variables: serde_json::Value,
        rhs: serde_json::Value,
        model: serde_json::Value,
    ) -> serde_json::Value {
        let mut m = serde_json::json!({
            "variables": variables,
            "equations": [
                {"lhs": "y", "rhs": rhs},
                {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "y"}
            ]
        });
        if let (Some(m), Some(extra)) = (m.as_object_mut(), model.as_object()) {
            m.extend(extra.clone());
        }
        serde_json::json!({
            "esm": "2.0.0", "metadata": {"name": "taa_probe"},
            "index_sets": {"c": {"kind": "interval", "size": 3},
                           "verts": {"kind": "interval", "size": 4},
                           "coord": {"kind": "interval", "size": 2}},
            "models": {"M": m}
        })
    }

    #[test]
    fn a_shaped_read_written_by_hand_is_not_lifted() {
        // The reduction a `linear` expansion holds, written by hand: no
        // template application, so the lift leaves it as written.
        let doc = probe_doc(
            serde_json::json!({
                "u": {"type": "parameter", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
                "y": {"type": "unknown"}, "s": {"type": "unknown", "default": 0.0}}),
            serde_json::json!({"op": "faq", "args": [], "output_idx": [],
                "ranges": {"k": {"from": "c"}}, "expr": "u"}),
            serde_json::json!({}),
        );
        let (lifted, before, after) = lift_doc(&doc, "M.y");
        assert!(lifted.is_empty());
        assert_eq!(before, after);
    }

    #[test]
    fn an_anonymous_array_argument_is_refused() {
        let rhs = parse(
            r#"{"op":"faq","args":[],"output_idx":[],"ranges":{"k":[1,3]},
                "__esm_template_origin":"linear",
                "expr":{"op":"<=","args":[{"op":"index","args":["ax","k"]},
                    {"op":"const","args":[],"value":[1.0,2.0]}]}}"#,
        );
        let err = refuse_anonymous_arrays(&rhs, &Expr::Variable("y".into())).unwrap_err();
        assert!(err.starts_with("array_shape_mismatch: 'y'"), "{err}");
        // A table the body reads whole (an `index` base) is not an argument
        // read per cell.
        let table = parse(
            r#"{"op":"faq","args":[],"output_idx":[],"ranges":{"k":[1,3]},
                "__esm_template_origin":"linear",
                "expr":{"op":"index","args":[{"op":"const","args":[],"value":[1.0,2.0]},"k"]}}"#,
        );
        assert!(refuse_anonymous_arrays(&table, &Expr::Variable("y".into())).is_ok());
    }

    #[test]
    fn the_lifted_body_shares_its_repeated_subtrees() {
        // Two copies of one bracket count, as an expanded `linear` repeats it,
        // parsed outside an interning scope: distinct nodes going in, one node
        // in the lifted body, so the tape evaluates the count once per cell.
        let count = r#"{"op":"faq","args":[],"output_idx":[],"ranges":{"k":[1,3]},
            "expr":{"op":"ifelse","args":[{"op":"<=","args":[
                {"op":"index","args":[{"op":"const","args":[],"value":[1.0,2.0,3.0]},"k"]},
                "lev"]},1,0]}}"#;
        let e = parse(&format!(r#"{{"op":"+","args":[{count},{count}]}}"#));
        let Expr::Operator(n) = &e else { panic!() };
        let (Expr::Operator(a), Expr::Operator(b)) = (&n.args[0], &n.args[1]) else {
            panic!()
        };
        assert!(!std::sync::Arc::ptr_eq(a, b));
        let shapes: HashMap<String, Vec<String>> =
            [("lev".to_string(), vec!["c".to_string()])].into();
        let (axes, loops) = (vec!["c".to_string()], vec!["_p0".to_string()]);
        let ctx = Lift {
            axes: &axes,
            loops: &loops,
            shapes: &shapes,
            lhs: "x",
        };
        let body = intern_tree(&ctx.wrap(&e, &HashSet::new(), true).expect("lift"));
        let Expr::Operator(n) = &body else { panic!() };
        let (Expr::Operator(a), Expr::Operator(b)) = (&n.args[0], &n.args[1]) else {
            panic!()
        };
        assert!(std::sync::Arc::ptr_eq(a, b));
    }

    #[test]
    fn loop_symbols_avoid_a_name_bound_in_any_field() {
        // An integral's variable is a name the right-hand side binds.
        let rhs = parse(
            r#"{"op":"*","args":["rho",{"op":"integral","args":[1.0],"var":"_p0",
                "lower":0.0,"upper":1.0}]}"#,
        );
        assert_eq!(fresh_loops(&rhs, 2), vec!["__p0", "__p1"]);
        assert_eq!(fresh_loops(&parse(r#""rho""#), 1), vec!["_p0"]);
    }

    #[test]
    fn a_variable_declared_scalar_is_not_lifted() {
        // `shape: []` declares a scalar (esm-spec §4.3.1): its elementwise
        // application is left as written.
        let doc = probe_doc(
            serde_json::json!({
                "u": {"type": "parameter", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
                "y": {"type": "unknown", "shape": []},
                "s": {"type": "unknown", "default": 0.0}}),
            serde_json::json!({"op": "apply_expression_template", "args": [], "name": "twice",
                "bindings": {"x": "u"}}),
            serde_json::json!({"expression_templates": {"twice": {"params": ["x"],
                "body": {"op": "*", "args": [2, "x"]}}}}),
        );
        let (lifted, before, after) = lift_doc(&doc, "M.y");
        assert!(lifted.is_empty());
        assert_eq!(before, after);
        let Expr::Operator(n) = &after else {
            panic!("{after:?}")
        };
        assert_eq!(n.op, "*", "flatten left the application as written");
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
