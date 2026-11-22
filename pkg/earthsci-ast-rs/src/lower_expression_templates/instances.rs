//! Rewriting inside template bodies, once per template instance (esm-spec
//! §9.6.4 rule 3). After a component's expression positions reach their §9.6.3
//! fixpoint (where every firing wrote a reference, constraint 7), the
//! component's rules, and its `enum` lowering, apply inside the bodies of the
//! templates its references reach — without expanding any reference.
//!
//! An instance is a template plus, per parameter, the literal bound to it when
//! the parameter sits in a structural position of the body, and otherwise the
//! kind of what is bound (a bare variable with its declared shape, a literal,
//! any other expression). Each instance's body is rewritten once; inside it a
//! parameter is a leaf ([`BodyView`]). When every reachable instance of a
//! template rewrites to the same body, that body replaces the template's in
//! place — unless a registry entry rule 3 leaves as authored still references
//! the template, directly or through such entries; otherwise each distinct body
//! becomes `<name>.variant<k>`, numbered by canonical bytes, and every
//! reference is re-pointed to the entry of its instance. Mirrors the Julia reference `templates/instances.jl`.

use super::*;
use std::collections::{HashMap, HashSet};

// ---------------------------------------------------------------------------
// Canonical bytes (CONFORMANCE_SPEC §5.5.3): compact JSON, keys sorted
// ---------------------------------------------------------------------------

/// A number in canonical form (CONFORMANCE_SPEC §5.5.3.1): an integer as
/// written, an integral Int64-representable float as an integer (rule 1), any
/// other float as its shortest round-tripping digits laid out Julia-style
/// (rule 2: `1.0e-12`, never `1e-12`).
fn canonical_number(n: &serde_json::Number, out: &mut String) {
    if n.is_i64() || n.is_u64() {
        out.push_str(&n.to_string());
        return;
    }
    let Some(f) = n.as_f64() else {
        out.push_str(&n.to_string());
        return;
    };
    match crate::types::canonical_i64(f) {
        Some(i) => out.push_str(&i.to_string()),
        None => out.push_str(&crate::canonicalize::format_julia_float(f)),
    }
}

fn canonical_string(s: &str, out: &mut String) {
    out.push_str(&serde_json::to_string(s).expect("string"));
}

fn canonical_write_value(v: &Value, out: &mut String) {
    match v {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort_unstable();
            out.push('{');
            for (i, k) in keys.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical_string(k, out);
                out.push(':');
                canonical_write_value(&map[k.as_str()], out);
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (i, x) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical_write_value(x, out);
            }
            out.push(']');
        }
        Value::Number(n) => canonical_number(n, out),
        Value::String(s) => canonical_string(s, out),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Null => out.push_str("null"),
    }
}

fn canonical_write(s: &SNode, out: &mut String) {
    match s {
        SNode::Obj(fields) => {
            let mut idx: Vec<usize> = (0..fields.len()).collect();
            idx.sort_unstable_by(|&a, &b| fields[a].0.as_bytes().cmp(fields[b].0.as_bytes()));
            out.push('{');
            for (i, j) in idx.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical_string(&fields[j].0, out);
                out.push(':');
                canonical_write(&fields[j].1, out);
            }
            out.push('}');
        }
        SNode::Arr(items) => {
            out.push('[');
            for (i, x) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical_write(x, out);
            }
            out.push(']');
        }
        SNode::Data(v) => canonical_write_value(v, out),
        SNode::Num(n) => canonical_number(n, out),
        SNode::Str(st) => canonical_string(st, out),
        SNode::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        SNode::Null => out.push_str("null"),
    }
}

/// The canonical byte form of a shared JSON value (CONFORMANCE_SPEC §5.5.3):
/// compact (`,` and `:` separators), object keys sorted by UTF-8 bytes at every
/// level, integral Int64-representable floats written as integers. Orders the
/// variants of esm-spec §9.6.4 rule 3. Mirrors `_canonical_compact`.
pub(super) fn canonical_compact(s: &SNode) -> String {
    let mut out = String::new();
    canonical_write(s, &mut out);
    out
}

/// [`canonical_compact`] of an owned JSON value.
pub(crate) fn canonical_compact_value(v: &Value) -> String {
    let mut out = String::new();
    canonical_write_value(v, &mut out);
    out
}

// ---------------------------------------------------------------------------
// Instances
// ---------------------------------------------------------------------------

/// The instance entry of a bare variable with declared shape `shape`.
pub(super) fn shape_entry(shape: &[String]) -> String {
    let mut out = String::from("V");
    canonical_write_value(
        &Value::Array(shape.iter().map(|s| Value::String(s.clone())).collect()),
        &mut out,
    );
    out
}

/// Fields whose value is an Expression (an operand position): a parameter
/// string there is an operand; anywhere else it is structural.
const OPERAND_FIELDS: [&str; 5] = ["expr", "filter", "key", "lower", "upper"];
const OPERAND_LIST_FIELDS: [&str; 2] = ["args", "values"];

/// The parameters `p` of a template that occur in a structural position of
/// `x` (esm-spec §9.6.4 rule 3): anywhere but an operand position — a scalar
/// field (`wrt`, `dim`, `fn`, …), a `ranges` bound or `from`, an `enum`
/// argument. An operand position is an element of `args` or `values` (but not
/// an `enum` op's `args`), the value of `expr`, `filter`, `key`, `lower` or
/// `upper`, a value of a nested reference's `bindings`, or the body itself.
/// Mirrors `_structural_walk!`.
fn structural_walk(out: &mut HashSet<String>, x: &SNode, p: &HashSet<String>, operand: bool) {
    match x {
        SNode::Str(s) if !operand && p.contains(s) => {
            out.insert(s.clone());
        }
        SNode::Arr(items) => {
            for v in items {
                structural_walk(out, v, p, operand);
            }
        }
        SNode::Obj(fields) => {
            let op = obj_op(fields).unwrap_or("");
            for (k, v) in fields {
                let k = k.as_str();
                if k == "op" || (k == "name" && op == APPLY_OP) {
                    continue;
                } else if k == "bindings"
                    && op == APPLY_OP
                    && let SNode::Obj(b) = &**v
                {
                    for (_, bv) in b {
                        structural_walk(out, bv, p, true);
                    }
                } else if (OPERAND_LIST_FIELDS.contains(&k) && op != "enum")
                    || OPERAND_FIELDS.contains(&k)
                {
                    structural_walk(out, v, p, true);
                } else {
                    structural_walk(out, v, p, false);
                }
            }
        }
        _ => {}
    }
}

/// Every `apply_expression_template` node in `node`, pre-order (document
/// order), each node identity once; references inside a reference's
/// `bindings` included.
pub(super) fn collect_apply_nodes(node: &Sv, out: &mut Vec<Sv>, seen: &mut PtrSet) {
    match &**node {
        SNode::Arr(items) => {
            if !seen.insert(node) {
                return;
            }
            for c in items {
                collect_apply_nodes(c, out, seen);
            }
        }
        SNode::Obj(fields) => {
            if !seen.insert(node) {
                return;
            }
            if obj_op(fields) == Some(APPLY_OP) {
                out.push(node.clone());
            }
            for (_, v) in fields {
                collect_apply_nodes(v, out, seen);
            }
        }
        _ => {}
    }
}

/// The instance entry (esm-spec §9.6.4 rule 3) for one parameter bound to `v`,
/// with the literal a structural position reads (if any): inside a body
/// (`bv`), a binding that is one of the body's own parameters forwards the
/// enclosing instance's entry; a structural parameter takes the literal bound
/// (`"L"` + canonical bytes); otherwise the kind — `"V"` + shape for a bare
/// variable with a declared shape, `"V"` for one without, `"N"` for a number or
/// boolean literal, `"E"` for any other expression. Mirrors `_instance_entry`.
fn instance_entry(
    v: &Sv,
    structural: bool,
    l: &Lowering,
    bv: Option<&BodyView>,
) -> (String, Option<Sv>) {
    if let (SNode::Str(s), Some(view)) = (&**v, bv)
        && view.params.contains(s)
    {
        return (
            view.entries.get(s).cloned().unwrap_or_default(),
            view.lit.get(s).cloned(),
        );
    }
    if structural {
        return match &**v {
            SNode::Str(_) | SNode::Num(_) | SNode::Bool(_) => {
                (format!("L{}", canonical_compact(v)), Some(v.clone()))
            }
            _ => ("E".to_string(), None),
        };
    }
    match &**v {
        SNode::Str(s) => match l.shape_env().get(s) {
            Some(shape) => (shape_entry(shape), None),
            None => ("V".to_string(), None),
        },
        SNode::Num(_) | SNode::Bool(_) => ("N".to_string(), None),
        _ => ("E".to_string(), None),
    }
}

/// One rewritten template instance: the template's `name`, the body as rule 3
/// rewrote it (references not yet re-pointed to variants), the instance key of
/// every reference in that body (by node identity, and in visiting order), and
/// its height — the deepest rewrite depth below the reference that names it
/// (own passes, or a written reference's pass plus the height of the instance
/// it names).
struct InstanceResult {
    name: String,
    body: Sv,
    refs: PtrMemo<String>,
    ref_keys: Vec<String>,
    height: usize,
}

#[derive(Default)]
struct Rule3State {
    done: HashMap<String, InstanceResult>,
    active: Vec<String>,
    structural: HashMap<String, HashSet<String>>,
    order: Vec<String>,
}

/// The structural parameters of template `name`, plus each parameter
/// forwarded whole into a structural parameter of a template its body
/// references (transitively): through the reference the parameter reaches a
/// structural position of the expansion. Memoized; a template reached again
/// while being computed contributes its direct set. Mirrors
/// `_template_structural!`.
fn template_structural(
    st: &mut Rule3State,
    l: &Lowering,
    name: &str,
    decl: &Sv,
) -> HashSet<String> {
    if let Some(r) = st.structural.get(name) {
        return r.clone();
    }
    let params: HashSet<String> = decl_params(decl).into_iter().collect();
    let body = decl_body(decl);
    let mut s = HashSet::new();
    structural_walk(&mut s, &body, &params, true);
    st.structural.insert(name.to_string(), s.clone());
    let mut applies = Vec::new();
    collect_apply_nodes(&body, &mut applies, &mut PtrSet::default());
    for n in applies {
        let SNode::Obj(fields) = &*n else { continue };
        let (Some(SNode::Str(inner)), Some(SNode::Obj(b))) = (
            obj_get(fields, "name").map(|v| &**v),
            obj_get(fields, "bindings").map(|v| &**v),
        ) else {
            continue;
        };
        let Some(idecl) = l.named.get(inner).cloned() else {
            continue;
        };
        let inner_s = template_structural(st, l, inner, &idecl);
        for (k, v) in b {
            if let SNode::Str(vs) = &**v
                && params.contains(vs)
                && inner_s.contains(k)
            {
                s.insert(vs.clone());
            }
        }
    }
    st.structural.insert(name.to_string(), s.clone());
    s
}

fn nonterminating(scope: &str, msg: String) -> ExpressionTemplateError {
    err(
        codes::REWRITE_RULE_NONTERMINATING,
        format!("{scope}: {msg} (esm-spec §9.6.4 rule 3)"),
    )
}

/// The rewritten instance a reference `n` names (its key), computed once per
/// instance. A reference the author wrote must name a match-less template
/// (§9.6.2); one a firing wrote (it has a depth) names its rule. `bv` is the
/// enclosing body's view when `n` sits in a template body, `None` at a call
/// site. Mirrors `_ref_instance!`.
fn ref_instance(
    st: &mut Rule3State,
    l: &Lowering,
    n: &Sv,
    bv: Option<&BodyView>,
    scope: &str,
) -> Result<String, ExpressionTemplateError> {
    let SNode::Obj(fields) = &**n else {
        unreachable!("only reference nodes are instances")
    };
    let written = l.depth_of(n).is_some();
    let (name, decl, b) = resolve_apply_site(fields, &l.named, scope, !written)?;
    let params = decl_params(&decl);
    let structural = template_structural(st, l, &name, &decl);
    let mut entries = Vec::with_capacity(params.len());
    let mut lits = HashMap::new();
    for p in &params {
        let v = binds_get(&b, p).expect("bindings cover params");
        let (e, lit) = instance_entry(v, structural.contains(p), l, bv);
        entries.push(e);
        if let Some(lit) = lit {
            lits.insert(p.clone(), lit);
        }
    }
    instance(st, l, &name, &decl, &params, entries, lits)
}

fn instance(
    st: &mut Rule3State,
    l: &Lowering,
    name: &str,
    decl: &Sv,
    params: &[String],
    entries: Vec<String>,
    lits: HashMap<String, Sv>,
) -> Result<String, ExpressionTemplateError> {
    let mut key = name.to_string();
    for e in &entries {
        key.push('\x1f');
        key.push_str(e);
    }
    if st.done.contains_key(&key) {
        return Ok(key);
    }
    let tscope = format!("{}.operators.{name}", l.scope);
    if st.active.contains(&key) {
        return Err(nonterminating(
            &tscope,
            format!(
                "rewriting template '{name}' needs the same template instance again — a \
                 `match` rule re-introduces its own pattern through the template's body"
            ),
        ));
    }
    st.active.push(key.clone());
    let view = BodyView {
        params: params.iter().cloned().collect(),
        lit: lits,
        entries: params.iter().cloned().zip(entries).collect(),
    };
    let body = lower_body_enums(
        &decl_body(decl),
        &view,
        l.enums.as_ref(),
        &mut PtrMemo::default(),
    )?;
    let body = instance_partial(&body, &view, &mut PtrMemo::default());
    // A body's calls resolve in the scope of the definition's owners
    // (esm-spec §4.7, §9.6.12).
    let (rewritten, passes) = l.with_call_scope(l.owner_scope(name), || {
        rewrite_to_fixpoint(&body, l, &tscope, Some(&view))
    })?;
    let mut refs = PtrMemo::default();
    let mut ref_keys = Vec::new();
    let mut height = passes;
    let mut applies = Vec::new();
    collect_apply_nodes(&rewritten, &mut applies, &mut PtrSet::default());
    for n in applies {
        let ck = ref_instance(st, l, &n, Some(&view), &tscope)?;
        let child_height = st.done[&ck].height;
        height = height.max(l.depth_of(&n).unwrap_or(0) + child_height);
        refs.insert(&n, ck.clone());
        ref_keys.push(ck);
    }
    if height > MAX_REWRITE_PASSES {
        return Err(nonterminating(
            &tscope,
            format!(
                "a rewrite inside template '{name}' has depth {height}, beyond \
                 MAX_REWRITE_PASSES={MAX_REWRITE_PASSES} (depth counts through template bodies)"
            ),
        ));
    }
    st.active.pop();
    st.done.insert(
        key.clone(),
        InstanceResult {
            name: name.to_string(),
            body: rewritten,
            refs,
            ref_keys,
            height,
        },
    );
    st.order.push(key.clone());
    Ok(key)
}

/// esm-spec §4.2 "Reading earlier documents": a `D` whose `wrt` is one of the
/// definition's `params` is decided per instance — where the instance binds
/// that parameter to an axis name other than `"t"`, the `D` reads as `partial`
/// in this instance (the wire boundary left it as written). Bound to `"t"`, it
/// stays the time derivative. Mirrors the Julia reference `_instance_partial`.
fn instance_partial(node: &Sv, view: &BodyView, memo: &mut PtrMemo<Sv>) -> Sv {
    match &**node {
        SNode::Obj(fields) => {
            if let Some(hit) = memo.get(node) {
                return hit.clone();
            }
            let spatial = obj_op(fields) == Some("D")
                && match obj_get(fields, "wrt").map(|w| &**w) {
                    Some(SNode::Str(w)) if view.params.contains(w) => {
                        matches!(view.lit.get(w).map(|x| &**x), Some(SNode::Str(lit)) if lit != "t")
                    }
                    _ => false,
                };
            let mut changed = spatial;
            let mut out = Vec::with_capacity(fields.len());
            for (k, v) in fields {
                let nv = if spatial && k == "op" {
                    Rc::new(SNode::Str("partial".to_string()))
                } else {
                    let nv = instance_partial(v, view, memo);
                    changed |= !Rc::ptr_eq(&nv, v);
                    nv
                };
                out.push((k.clone(), nv));
            }
            let res = if changed {
                Rc::new(SNode::Obj(out))
            } else {
                node.clone()
            };
            memo.insert(node, res.clone());
            res
        }
        SNode::Arr(items) => {
            if let Some(hit) = memo.get(node) {
                return hit.clone();
            }
            let mut changed = false;
            let mut out = Vec::with_capacity(items.len());
            for v in items {
                let nv = instance_partial(v, view, memo);
                changed |= !Rc::ptr_eq(&nv, v);
                out.push(nv);
            }
            let res = if changed {
                Rc::new(SNode::Arr(out))
            } else {
                node.clone()
            };
            memo.insert(node, res.clone());
            res
        }
        _ => node.clone(),
    }
}

/// The `enum` lowering of esm-spec §9.3 applied inside a template body for one
/// instance (§9.6.4 rule 3): an `enum` op whose two arguments are strings, or
/// parameters the instance binds to strings, becomes its `const`; one still
/// spelled with an unbound parameter stays as written. Mirrors
/// `_lower_body_enums`.
fn lower_body_enums(
    node: &Sv,
    view: &BodyView,
    enums: Option<&Value>,
    memo: &mut PtrMemo<Sv>,
) -> Result<Sv, ExpressionTemplateError> {
    match &**node {
        SNode::Obj(fields) => {
            if let Some(hit) = memo.get(node) {
                return Ok(hit.clone());
            }
            let res = if obj_op(fields) == Some("enum") {
                match obj_get(fields, "args").map(|a| &**a) {
                    Some(SNode::Arr(args)) if args.len() == 2 => {
                        let resolved: Vec<Option<String>> = args
                            .iter()
                            .map(|a| match &**a {
                                SNode::Str(s) if view.params.contains(s) => {
                                    match view.lit.get(s).map(|x| &**x) {
                                        Some(SNode::Str(t)) => Some(t.clone()),
                                        _ => None,
                                    }
                                }
                                SNode::Str(s) => Some(s.clone()),
                                _ => None,
                            })
                            .collect();
                        if resolved.iter().all(Option::is_some) {
                            let Value::Object(mut n2) = to_value(node) else {
                                unreachable!("an object node")
                            };
                            n2.insert(
                                "args".to_string(),
                                Value::Array(
                                    resolved
                                        .into_iter()
                                        .map(|s| Value::String(s.expect("some")))
                                        .collect(),
                                ),
                            );
                            to_shared(&crate::lower_enums::lower_enum_op_against(enums, &n2)?)
                        } else {
                            node.clone()
                        }
                    }
                    _ => node.clone(),
                }
            } else {
                let mut changed = false;
                let mut out = Vec::with_capacity(fields.len());
                for (k, v) in fields {
                    let nv = lower_body_enums(v, view, enums, memo)?;
                    changed |= !Rc::ptr_eq(&nv, v);
                    out.push((k.clone(), nv));
                }
                if changed {
                    Rc::new(SNode::Obj(out))
                } else {
                    node.clone()
                }
            };
            memo.insert(node, res.clone());
            Ok(res)
        }
        SNode::Arr(items) => {
            if let Some(hit) = memo.get(node) {
                return Ok(hit.clone());
            }
            let mut changed = false;
            let mut out = Vec::with_capacity(items.len());
            for v in items {
                let nv = lower_body_enums(v, view, enums, memo)?;
                changed |= !Rc::ptr_eq(&nv, v);
                out.push(nv);
            }
            let res = if changed {
                Rc::new(SNode::Arr(out))
            } else {
                node.clone()
            };
            memo.insert(node, res.clone());
            Ok(res)
        }
        _ => Ok(node.clone()),
    }
}

/// `x` with every reference re-pointed to the entry its instance was given:
/// `refs` maps a reference node (by identity) to its instance key, `final_` an
/// instance key to the registry name its body lives under. Mirrors
/// `_repoint_refs`.
fn repoint_refs(
    x: &Sv,
    refs: &PtrMemo<String>,
    final_: &HashMap<String, String>,
    memo: &mut PtrMemo<Sv>,
) -> Sv {
    match &**x {
        SNode::Obj(fields) => {
            if let Some(hit) = memo.get(x) {
                return hit.clone();
            }
            let is_apply = obj_op(fields) == Some(APPLY_OP);
            let mut changed = false;
            let mut out = Vec::with_capacity(fields.len());
            for (k, v) in fields {
                if is_apply && k == "name" {
                    out.push((k.clone(), v.clone()));
                    continue;
                }
                let nv = repoint_refs(v, refs, final_, memo);
                changed |= !Rc::ptr_eq(&nv, v);
                out.push((k.clone(), nv));
            }
            if is_apply && let Some(key) = refs.get(x) {
                let newname = &final_[key];
                let current = match obj_get(fields, "name").map(|v| &**v) {
                    Some(SNode::Str(s)) => Some(s.as_str()),
                    _ => None,
                };
                if current != Some(newname.as_str()) {
                    for (k, v) in out.iter_mut() {
                        if k == "name" {
                            *v = Rc::new(SNode::Str(newname.clone()));
                        }
                    }
                    changed = true;
                }
            }
            let res = if changed {
                Rc::new(SNode::Obj(out))
            } else {
                x.clone()
            };
            memo.insert(x, res.clone());
            res
        }
        SNode::Arr(items) => {
            if let Some(hit) = memo.get(x) {
                return hit.clone();
            }
            let mut changed = false;
            let mut out = Vec::with_capacity(items.len());
            for v in items {
                let nv = repoint_refs(v, refs, final_, memo);
                changed |= !Rc::ptr_eq(&nv, v);
                out.push(nv);
            }
            let res = if changed {
                Rc::new(SNode::Arr(out))
            } else {
                x.clone()
            };
            memo.insert(x, res.clone());
            res
        }
        _ => x.clone(),
    }
}

/// The template-level order in which instances are named: a template after
/// every template its instances' bodies reference. A cycle is a rule that
/// re-introduces itself through a template body. Mirrors
/// `_rule3_template_order`.
fn rule3_template_order(
    st: &Rule3State,
    by_template: &indexmap::IndexMap<String, Vec<String>>,
    scope: &str,
) -> Result<Vec<String>, ExpressionTemplateError> {
    let mut deps: HashMap<&str, Vec<String>> = HashMap::new();
    for (t, keys_t) in by_template {
        let mut ds: Vec<String> = Vec::new();
        for k in keys_t {
            for ck in &st.done[k].ref_keys {
                let n = &st.done[ck].name;
                if !ds.contains(n) {
                    ds.push(n.clone());
                }
            }
        }
        deps.insert(t.as_str(), ds);
    }
    fn visit(
        t: &str,
        deps: &HashMap<&str, Vec<String>>,
        state: &mut HashMap<String, u8>,
        order: &mut Vec<String>,
        scope: &str,
    ) -> Result<(), ExpressionTemplateError> {
        match state.get(t).copied().unwrap_or(0) {
            2 => return Ok(()),
            1 => {
                return Err(nonterminating(
                    scope,
                    format!(
                        "template '{t}' reaches itself through the references rules wrote in \
                         template bodies"
                    ),
                ));
            }
            _ => {}
        }
        state.insert(t.to_string(), 1);
        for d in deps.get(t).map(Vec::as_slice).unwrap_or(&[]) {
            visit(d, deps, state, order, scope)?;
        }
        state.insert(t.to_string(), 2);
        order.push(t.to_string());
        Ok(())
    }
    let mut order = Vec::new();
    let mut state = HashMap::new();
    for t in by_template.keys() {
        visit(t, &deps, &mut state, &mut order, scope)?;
    }
    Ok(order)
}

/// The templates whose reached instances rewrite to more than one distinct
/// body. Naming each single-bodied template in place or as `<name>.variant1`
/// renames every reference to it alike, so which bodies are distinct does not
/// depend on that choice: this provisional pass names every single-bodied
/// template in place. Mirrors `_rule3_multi`.
fn rule3_multi(
    st: &Rule3State,
    by_template: &indexmap::IndexMap<String, Vec<String>>,
    order: &[String],
) -> HashSet<String> {
    let mut final_: HashMap<String, String> = HashMap::new();
    let mut multi = HashSet::new();
    for t in order {
        let keys_t = &by_template[t];
        let canon: Vec<String> = keys_t
            .iter()
            .map(|k| {
                let r = &st.done[k];
                canonical_compact(&repoint_refs(
                    &r.body,
                    &r.refs,
                    &final_,
                    &mut PtrMemo::default(),
                ))
            })
            .collect();
        let mut distinct = canon.clone();
        distinct.sort_unstable();
        distinct.dedup();
        if distinct.len() == 1 {
            for k in keys_t {
                final_.insert(k.clone(), t.clone());
            }
            continue;
        }
        multi.insert(t.clone());
        for (k, c) in keys_t.iter().zip(&canon) {
            let i = distinct.binary_search(c).expect("distinct of canon");
            final_.insert(k.clone(), format!("{t}\u{1f}{}", i + 1));
        }
    }
    multi
}

/// The reached match-less templates whose authored body stays reachable from
/// a registry entry that rule 3 does not rewrite under its own name (esm-spec
/// §9.6.4 rule 3): a match-less entry no reference reaches, one whose
/// instances took variants, and, transitively, any reached template such an
/// entry references. Such a template keeps its authored body; a single
/// rewritten body is registered as `<name>.variant1` instead. Mirrors
/// `_rule3_exposed`.
fn rule3_exposed(
    st: &Rule3State,
    l: &Lowering,
    by_template: &indexmap::IndexMap<String, Vec<String>>,
    order: &[String],
) -> HashSet<String> {
    let named = &l.named;
    let matchless = |n: &str| named.get(n).is_some_and(|d| !decl_has_match(d));
    let mut memo: HashMap<String, Vec<String>> = HashMap::new();
    let mut refs_of = |n: &str| -> Vec<String> {
        if let Some(r) = memo.get(n) {
            return r.clone();
        }
        let mut names = Vec::new();
        collect_apply_names_sv(&decl_body(&named[n]), &mut names, &mut PtrSet::default());
        let mut r: Vec<String> = names
            .into_iter()
            .filter(|x| by_template.contains_key(x) && matchless(x))
            .collect();
        r.sort_unstable();
        r.dedup();
        memo.insert(n.to_string(), r.clone());
        r
    };
    let mut stack: Vec<String> = named
        .keys()
        .filter(|n| !by_template.contains_key(*n) && matchless(n))
        .cloned()
        .collect();
    let need_multi = by_template
        .keys()
        .any(|t| matchless(t) && !refs_of(t).is_empty());
    if need_multi {
        stack.extend(
            rule3_multi(st, by_template, order)
                .into_iter()
                .filter(|t| matchless(t)),
        );
    }
    let mut visible = HashSet::new();
    while let Some(n) = stack.pop() {
        for r in refs_of(&n) {
            if visible.insert(r.clone()) {
                stack.push(r);
            }
        }
    }
    visible
}

/// A decl's fields without `match`, `where` and `priority`.
fn match_stripped(decl: &Sv) -> Vec<(String, Sv)> {
    match &**decl {
        SNode::Obj(fields) => fields
            .iter()
            .filter(|(k, _)| !matches!(k.as_str(), "match" | "where" | "priority"))
            .cloned()
            .collect(),
        _ => Vec::new(),
    }
}

fn set_body(fields: &mut Vec<(String, Sv)>, body: Sv) {
    match fields.iter_mut().find(|(k, _)| k == "body") {
        Some((_, v)) => *v = body,
        None => fields.push(("body".to_string(), body)),
    }
}

/// Esm-spec §9.6.4 rule 3 for one component whose expression positions
/// (`sites`: each a diagnostic scope and a tree, the coupling transforms it
/// receives included) have reached the §9.6.3 fixpoint: rewrite the body of
/// every template instance their references reach, place each result (in
/// place, or as `<name>.variant<k>`), re-point the references (in `sites`),
/// materialize each referenced `match` rule without its `match`, `where` and
/// `priority`, and check the rewrite depth of every call site. Updates
/// `l.named`, and returns the registry entries to write into the component's
/// `expression_templates` block, in order (an existing name keeps its
/// position, a new one is appended). Mirrors `_apply_rule3!`.
pub(super) fn apply_rule3(
    l: &mut Lowering,
    sites: &mut [(String, Sv)],
) -> Result<Vec<(String, Sv)>, ExpressionTemplateError> {
    let mut st = Rule3State::default();
    let mut site_refs: PtrMemo<String> = PtrMemo::default();
    for (scope, tree) in sites.iter() {
        let mut applies = Vec::new();
        collect_apply_nodes(tree, &mut applies, &mut PtrSet::default());
        for n in applies {
            let key = ref_instance(&mut st, l, &n, None, scope)?;
            let res = &st.done[&key];
            let d = l.depth_of(&n).unwrap_or(0) + res.height;
            if d > MAX_REWRITE_PASSES {
                return Err(nonterminating(
                    scope,
                    format!(
                        "a rewrite through template '{}' has depth {d}, beyond \
                         MAX_REWRITE_PASSES={MAX_REWRITE_PASSES} (depth counts through template \
                         bodies)",
                        res.name
                    ),
                ));
            }
            site_refs.insert(&n, key);
        }
    }
    if st.order.is_empty() {
        return Ok(Vec::new());
    }

    let mut by_template: indexmap::IndexMap<String, Vec<String>> = indexmap::IndexMap::new();
    for k in &st.order {
        by_template
            .entry(st.done[k].name.clone())
            .or_default()
            .push(k.clone());
    }
    let mut final_: HashMap<String, String> = HashMap::new();
    let mut updates: Vec<(String, Sv)> = Vec::new();
    let mut taken: HashSet<String> = l.named.keys().cloned().collect();
    let order = rule3_template_order(&st, &by_template, &l.scope)?;
    let exposed = rule3_exposed(&st, l, &by_template, &order);
    for t in order {
        let keys_t = &by_template[&t];
        let bodies: Vec<Sv> = keys_t
            .iter()
            .map(|k| {
                let r = &st.done[k];
                repoint_refs(&r.body, &r.refs, &final_, &mut PtrMemo::default())
            })
            .collect();
        let canon: Vec<String> = bodies.iter().map(|b| canonical_compact(b)).collect();
        let mut distinct: Vec<String> = canon.clone();
        distinct.sort_unstable();
        distinct.dedup();
        let decl = l.named[&t].clone();
        if distinct.len() == 1
            && !(exposed.contains(&t) && distinct[0] != canonical_compact(&decl_body(&decl)))
        {
            for k in keys_t {
                final_.insert(k.clone(), t.clone());
            }
            let has_match = decl_has_match(&decl);
            let mut nd = match &*decl {
                SNode::Obj(fields) if !has_match => fields.clone(),
                _ => match_stripped(&decl),
            };
            if distinct[0] != canonical_compact(&decl_body(&decl)) {
                set_body(&mut nd, bodies[0].clone());
            } else if !has_match {
                continue;
            }
            let nd = Rc::new(SNode::Obj(nd));
            l.named.insert(t.clone(), nd.clone());
            updates.push((t.clone(), nd));
        } else {
            let mut names: HashMap<&str, String> = HashMap::new();
            for (i, c) in distinct.iter().enumerate() {
                let mut vn = format!("{t}.variant{}", i + 1);
                while taken.contains(&vn) {
                    vn.push('_');
                }
                taken.insert(vn.clone());
                let mut nd = match_stripped(&decl);
                let first = canon
                    .iter()
                    .position(|x| x == c)
                    .expect("distinct of canon");
                set_body(&mut nd, bodies[first].clone());
                let nd = Rc::new(SNode::Obj(nd));
                l.named.insert(vn.clone(), nd.clone());
                l.inherit_owners(&vn, &t);
                updates.push((vn.clone(), nd));
                names.insert(c.as_str(), vn);
            }
            for (k, c) in keys_t.iter().zip(&canon) {
                final_.insert(k.clone(), names[c.as_str()].clone());
            }
        }
    }
    for (_, tree) in sites.iter_mut() {
        *tree = repoint_refs(tree, &site_refs, &final_, &mut PtrMemo::default());
    }
    Ok(updates)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The variant-ordering bytes spell numbers as CONFORMANCE_SPEC §5.5.3.1
    /// does: integral floats as integers, other floats Julia-style.
    #[test]
    fn canonical_compact_numbers_follow_5_5_3_1() {
        let v = json!({"b": [1.0e-12, 2.0, 0.25, 1.0e16, 7], "a": -3.5e-6});
        assert_eq!(
            canonical_compact_value(&v),
            r#"{"a":-3.5e-6,"b":[1.0e-12,2,0.25,10000000000000000,7]}"#
        );
        assert_eq!(
            canonical_compact(&to_shared(&v)),
            canonical_compact_value(&v)
        );
    }
}
