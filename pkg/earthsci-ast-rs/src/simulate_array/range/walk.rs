//! The expression walker under every range restriction (API_SPEC §5.8): it
//! finds what a rule reads over a box of output cells, and rewrites the rule
//! so that it computes only that box.
//!
//! The walk follows the tape lowering's own reading of each construct, so the
//! rewritten rule lowers to the instructions the whole-domain rule lowers to,
//! restricted to the box:
//!
//! * `index(V, subs…)` of a state or observed reads, along each axis, the image
//!   of the box under the subscript as [`classify_axis_role`] classifies it (an
//!   affine shift or periodic wrap of one output symbol, or a constant).
//! * `index(makearray(…), subs…)` reads the makearray over the image of the box,
//!   so its regions are clipped to that image (RFC U3 §4 rule 1): a region the
//!   image misses is dropped, the others keep their order. A region value is
//!   lowered over its region with the box's symbols rebound to it, and a `faq`
//!   region value over its own ranges placed by shape, so the ranges are
//!   clipped by the same amounts.
//! * `index(faq(…), subs…)` likewise clips the `faq`'s output ranges.
//! * An operator reference (esm-spec §9.6.4) is read through, never expanded:
//!   the walk enters the body of the instance it names with each parameter
//!   standing for what the reference binds to it, as the tape's call does
//!   (`tape/lower/calls.rs`). A parameter bound to a state or observed is that
//!   array, passed whole and read in place, so a read the body makes of the
//!   parameter is a read of the array at the same cells, recorded against it;
//!   a binding that reads a loop symbol is read where the body reads the
//!   parameter, in the frame it was written in; any other binding is a value
//!   the caller computes, walked at the call site. The halo is therefore the
//!   one the expansion has. When restricting the body to the box changes it,
//!   the reference is pointed at a restricted definition of its own
//!   ([`RestrictedDef`]): the restricted body, compiled as a function like any
//!   other instance; the caller holds the call, not the body.
//!
//! What cannot be restricted exactly is refused, never approximated.

use super::super::vectorized::{
    AxisIndex, AxisRole, VecBox, classify_axis_role, region_value_axes,
};
use crate::binders::{Binders, free_names};
use crate::operator_refs::{APPLY_OP, Instances, reference_node};
use crate::types::{Expr, ExpressionNode, RangeSpec, RegionBound};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;

/// One axis of a state or observed under a decomposition.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum AxisSpec {
    /// Not cut: every tile holds the whole axis. `set` is its index-set name
    /// when the declaration names one.
    Whole { set: Option<String> },
    /// A decomposed cell set, or a face set staggered off one: the global
    /// domain is `1..=hi` (`N` cells, or `N + 1` faces), `period` is the cell
    /// set's period, `cell` the decomposed cell set's name and `set` this
    /// axis's own index-set name.
    Cut {
        set: String,
        cell: String,
        hi: i64,
        period: Option<i64>,
        face: bool,
    },
}

impl AxisSpec {
    pub(crate) fn cut_cell(&self) -> Option<&str> {
        match self {
            AxisSpec::Cut { cell, .. } => Some(cell),
            AxisSpec::Whole { .. } => None,
        }
    }
}

/// A state or observed the walker may meet: its axes and its global extent.
#[derive(Clone, Debug)]
pub(crate) struct VarInfo {
    pub(crate) axes: Vec<AxisSpec>,
    /// Inclusive global box per axis.
    pub(crate) extent: Vec<(i64, i64)>,
}

impl VarInfo {
    pub(crate) fn is_cut(&self) -> bool {
        self.axes.iter().any(|a| a.cut_cell().is_some())
    }
}

/// Why a walk refused a rule.
#[derive(Clone, Debug)]
pub(crate) struct Refusal {
    /// `range_global_locality`, or `compiler_refused_rule` for a construct a
    /// range restriction cannot express exactly.
    pub(crate) code: &'static str,
    pub(crate) message: String,
}

type WResult<T> = Result<T, Refusal>;

/// One read the walk recorded: `var` along its axis `axis`, over the global
/// cells `lo..=hi`.
#[derive(Clone, Debug)]
pub(crate) struct Read {
    pub(crate) var: String,
    pub(crate) axis: usize,
    pub(crate) lo: i64,
    pub(crate) hi: i64,
}

/// The box symbols in force: each bound to an inclusive range of global
/// coordinates, with the decomposed cell set its coordinate runs along (when
/// it runs along one). `contracted` are the reduction symbols of the
/// enclosing `faq`s.
#[derive(Clone, Debug, Default)]
pub(crate) struct Scope {
    pub(crate) syms: Vec<String>,
    pub(crate) lo: Vec<i64>,
    pub(crate) hi: Vec<i64>,
    pub(crate) sets: Vec<Option<String>>,
    pub(crate) contracted: Vec<String>,
}

impl Scope {
    /// Classify `e` against this box, as the lowering classifies a subscript.
    fn role(&self, e: &Expr) -> Option<AxisRole> {
        let bx = VecBox {
            syms: &self.syms,
            cnames: &[],
            cvals: &[],
        };
        classify_axis_role(e, &bx)
    }

    /// The hull of the image of the box along output axis `a` under `ax`.
    fn image(&self, a: usize, ax: &AxisIndex) -> (i64, i64) {
        match ax {
            AxisIndex::Affine(k) => (self.lo[a] + k, self.hi[a] + k),
            AxisIndex::Wrap { k, period, lo } => {
                let mut mn = i64::MAX;
                let mut mx = i64::MIN;
                for g in self.lo[a]..=self.hi[a] {
                    let w = wrap(g + k, *lo, *period);
                    mn = mn.min(w);
                    mx = mx.max(w);
                }
                (mn, mx)
            }
        }
    }

    /// The image of the box along output axis `a` under `ax`, as its
    /// maximal runs of consecutive cells: one run for an affine shift, two
    /// for a periodic wrap that crosses the seam.
    fn image_runs(&self, a: usize, ax: &AxisIndex) -> Vec<(i64, i64)> {
        match ax {
            AxisIndex::Affine(_) => vec![self.image(a, ax)],
            AxisIndex::Wrap { k, period, lo } => {
                let mut runs: Vec<(i64, i64)> = Vec::new();
                for g in self.lo[a]..=self.hi[a] {
                    let w = wrap(g + k, *lo, *period);
                    match runs.last_mut() {
                        Some(r) if r.1 + 1 == w => r.1 = w,
                        _ => runs.push((w, w)),
                    }
                }
                runs
            }
        }
    }

    /// Bind `syms` (shadowing any outer binding of the same names) over the
    /// given ranges, keeping the outer symbols the new ones do not shadow.
    fn nested(
        &self,
        syms: &[String],
        ranges: &[(i64, i64)],
        sets: &[Option<String>],
        contracted: &[String],
    ) -> Scope {
        let mut out = Scope {
            syms: syms.to_vec(),
            lo: ranges.iter().map(|r| r.0).collect(),
            hi: ranges.iter().map(|r| r.1).collect(),
            sets: sets.to_vec(),
            contracted: contracted.to_vec(),
        };
        for (i, s) in self.syms.iter().enumerate() {
            if !syms.contains(s) && !contracted.contains(s) {
                out.syms.push(s.clone());
                out.lo.push(self.lo[i]);
                out.hi.push(self.hi[i]);
                out.sets.push(self.sets[i].clone());
            }
        }
        for c in &self.contracted {
            if !out.contracted.contains(c) && !syms.contains(c) {
                out.contracted.push(c.clone());
            }
        }
        out
    }
}

/// `x` folded once into `lo..lo + period` from either side: the subscript the
/// periodic-wrap idiom reads.
fn wrap(x: i64, lo: i64, period: i64) -> i64 {
    if x < lo {
        x + period
    } else if x > lo + period - 1 {
        x - period
    } else {
        x
    }
}

fn mentions_any(e: &Expr, names: &[String]) -> bool {
    match e {
        Expr::Variable(v) => names.iter().any(|n| n == v),
        Expr::Operator(node) => node.any_child(&mut |c| mentions_any(c, names)),
        _ => false,
    }
}

fn region_box(region: &[[RegionBound; 2]]) -> Option<Vec<(i64, i64)>> {
    region
        .iter()
        .map(|r| crate::types::region_bounds(r).map(|[lo, hi]| (lo, hi)))
        .collect()
}

fn faq_ranges(node: &ExpressionNode, names: &[String]) -> Option<Vec<(i64, i64)>> {
    let ranges = node.ranges.as_ref()?;
    names
        .iter()
        .map(|n| {
            ranges
                .get(n)
                .and_then(RangeSpec::bounds)
                .map(|[lo, hi]| (lo, hi))
        })
        .collect()
}

fn contracted_of(node: &ExpressionNode) -> Vec<String> {
    let out_idx: &[String] = node.output_idx.as_deref().unwrap_or(&[]);
    let mut c: Vec<String> = node
        .ranges
        .as_ref()
        .map(|r| r.keys().filter(|k| !out_idx.contains(k)).cloned().collect())
        .unwrap_or_default();
    c.sort();
    c
}

/// A 128-bit hash of `text`: the name of a restricted definition is its
/// definition's name and the hash of its body, so equal restrictions share
/// one definition.
fn text_hash(text: &str) -> u128 {
    use std::hash::{Hash, Hasher};
    let mut a = std::collections::hash_map::DefaultHasher::new();
    let mut b = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut a);
    0x5bd1_e995u32.hash(&mut b);
    text.hash(&mut b);
    (u128::from(a.finish()) << 64) | u128::from(b.finish())
}

/// A makearray of literal zeros over `bx`: what a gather of a region-free box
/// reads, as one constant the lowering builds without reading anything.
fn zero_makearray(bx: &[(i64, i64)]) -> Expr {
    let mut node = ExpressionNode {
        op: "makearray".to_string(),
        ..Default::default()
    };
    node.regions = Some(vec![
        bx.iter()
            .map(|&(lo, hi)| [RegionBound::Int(lo), RegionBound::Int(hi)])
            .collect(),
    ]);
    node.values = Some(vec![Expr::Number(0.0)]);
    Expr::operator(node)
}

/// What a definition parameter stands for inside a body the walk entered.
#[derive(Clone, Debug)]
enum Bound {
    /// A state or observed of the program, passed whole and read in place:
    /// the body's reads of the parameter are reads of it.
    Array(String),
    /// A binding that reads a loop symbol (of the call's box or of the body):
    /// read where the body reads the parameter, its names resolved in the
    /// frame it was written in.
    Inline(Expr, Rc<Frame>),
    /// A value the caller computes, walked at the call site: reading it in
    /// the body reads nothing more. `true` when it reads a decomposed array.
    Value(bool),
}

/// The parameters in force: empty at a rule (the root frame), else those of
/// the body being walked. A body reads only its parameters and its own loop
/// symbols (esm-spec §9.6.4 rule 7), so any other name it reads is none of
/// the program's arrays.
#[derive(Debug, Default)]
struct Frame {
    params: HashMap<String, Bound>,
    in_body: bool,
}

/// What a variable leaf names where the walk reads it.
enum Leaf {
    /// A loop symbol in force, or a name that is none of the program's arrays.
    Plain,
    /// The program's state or observed of that name.
    Array(String),
    /// A parameter bound to a binding read at its use.
    Inline(Expr, Rc<Frame>),
    /// A parameter bound to a value the caller computes from a decomposed
    /// array.
    CutValue,
}

/// A definition restricted to a box: the reference the walk rewrote names it
/// in place of the definition it restricts. Its parameters are the
/// definition's, less those the instance spelled into its body; its body is
/// the instance body restricted, already through every build pass.
#[derive(Clone, Debug)]
pub(crate) struct RestrictedDef {
    pub(crate) name: String,
    pub(crate) params: Vec<String>,
    pub(crate) body: Expr,
}

/// Where a reference sits, which decides how its body is read.
#[derive(Clone, Copy)]
enum Ctx<'e> {
    /// An ordinary operand, over the box.
    Plain,
    /// The base of an `index` at these subscripts.
    Indexed(&'e [Expr]),
    /// A makearray region value, the region clipped from `ro` to `rc`, its
    /// axes along `sets`.
    Region {
        ro: &'e [(i64, i64)],
        rc: &'e [(i64, i64)],
        sets: &'e [Option<String>],
    },
}

/// How deep references may nest before the walk gives up (a definition that
/// reaches itself is refused by the build before this matters).
const MAX_REFERENCE_DEPTH: usize = 64;

pub(crate) struct Walker<'a> {
    pub(crate) vars: &'a HashMap<String, VarInfo>,
    /// The rule being walked, as a diagnostic names it.
    pub(crate) rule: String,
    pub(crate) reads: Vec<Read>,
    /// The instances the rule's references name.
    ops: &'a Instances,
    frame: Rc<Frame>,
    depth: usize,
    /// The restricted definitions the rewritten rule's references name.
    pub(crate) restricted: Vec<RestrictedDef>,
}

impl<'a> Walker<'a> {
    pub(crate) fn new(
        vars: &'a HashMap<String, VarInfo>,
        ops: &'a Instances,
        rule: impl Into<String>,
    ) -> Self {
        Walker {
            vars,
            rule: rule.into(),
            reads: Vec::new(),
            ops,
            frame: Rc::new(Frame::default()),
            depth: 0,
            restricted: Vec::new(),
        }
    }

    /// What the variable leaf `v` names over `sc`, in the current frame.
    fn leaf(&self, v: &str, sc: &Scope) -> Leaf {
        if sc.syms.iter().any(|s| s == v) || sc.contracted.iter().any(|s| s == v) {
            return Leaf::Plain;
        }
        match self.frame.params.get(v) {
            Some(Bound::Array(root)) => Leaf::Array(root.clone()),
            Some(Bound::Inline(e, fr)) => Leaf::Inline(e.clone(), Rc::clone(fr)),
            Some(Bound::Value(true)) => Leaf::CutValue,
            Some(Bound::Value(false)) => Leaf::Plain,
            None if self.frame.in_body => Leaf::Plain,
            None if self.vars.contains_key(v) => Leaf::Array(v.to_string()),
            None => Leaf::Plain,
        }
    }

    /// Walk `e` over `sc` with `frame` in force (a binding read at its use).
    /// The walk records its reads; the rewritten binding is not kept, so a
    /// binding the box would rewrite is refused.
    fn walk_in(&mut self, frame: Rc<Frame>, e: &Expr, sc: &Scope) -> WResult<()> {
        let saved = std::mem::replace(&mut self.frame, frame);
        let r = self.expr(e, sc);
        self.frame = saved;
        if r? != *e {
            return self.refuse(
                "passes an operator reference a binding that reads a loop symbol and that the \
                 tile's box would rewrite",
            );
        }
        Ok(())
    }

    fn refuse<T>(&self, what: impl std::fmt::Display) -> WResult<T> {
        Err(Refusal {
            code: crate::diagnostic::codes::COMPILER_REFUSED_RULE,
            message: format!("tile restriction: rule `{}` {what}", self.rule),
        })
    }

    fn global<T>(&self, what: impl std::fmt::Display, set: &str) -> WResult<T> {
        Err(Refusal {
            code: crate::diagnostic::codes::RANGE_GLOBAL_LOCALITY,
            message: format!(
                "rule `{}` {what} along the decomposed axis `{set}`, so its locality is global \
                 along `{set}`",
                self.rule
            ),
        })
    }

    /// Walk `e` over the box `sc`, recording its reads and returning it
    /// restricted to the box.
    pub(crate) fn expr(&mut self, e: &Expr, sc: &Scope) -> WResult<Expr> {
        match e {
            Expr::Number(_) | Expr::Integer(_) => Ok(e.clone()),
            Expr::Variable(v) => match self.leaf(v, sc) {
                Leaf::Plain | Leaf::CutValue => Ok(e.clone()),
                Leaf::Inline(b, fr) => {
                    self.walk_in(fr, &b, sc)?;
                    Ok(e.clone())
                }
                Leaf::Array(root) => {
                    let info = &self.vars[&root];
                    if info.is_cut() {
                        return self.refuse(format_args!(
                            "reads the decomposed array `{root}` whole, not through a subscript"
                        ));
                    }
                    for (axis, &(lo, hi)) in info.extent.iter().enumerate() {
                        self.reads.push(Read {
                            var: root.clone(),
                            axis,
                            lo,
                            hi,
                        });
                    }
                    Ok(e.clone())
                }
            },
            Expr::Operator(node) => self.op(node, sc),
        }
    }

    fn op(&mut self, node: &Arc<ExpressionNode>, sc: &Scope) -> WResult<Expr> {
        match node.op.as_str() {
            "index" if !node.args.is_empty() => self.index(node, sc),
            APPLY_OP => self.reference(node, Ctx::Plain, sc),
            "makearray" => {
                let regions = node
                    .regions
                    .as_ref()
                    .map(|r| r.iter().map(|x| region_box(x)).collect::<Option<Vec<_>>>());
                let Some(Some(regions)) = regions else {
                    return self.refuse("holds a makearray with a symbolic region bound");
                };
                let nd = regions.first().map_or(0, Vec::len);
                let mut bb = vec![(i64::MAX, i64::MIN); nd];
                for r in &regions {
                    for (d, &(lo, hi)) in r.iter().enumerate().take(nd) {
                        bb[d] = (bb[d].0.min(lo), bb[d].1.max(hi));
                    }
                }
                let sets = vec![None; nd];
                self.makearray(node, &bb, &sets, sc)
            }
            "faq" => {
                let out_idx: Vec<String> = node.output_idx.clone().unwrap_or_default();
                let Some(ranges) = faq_ranges(node, &out_idx) else {
                    return self.refuse("holds a faq whose output ranges do not resolve");
                };
                let sets = vec![None; out_idx.len()];
                self.faq(node, &ranges, &sets, sc)
            }
            _ => {
                let mut err = None;
                let out = node.map_children(&mut |c| match self.expr(c, sc) {
                    Ok(x) => x,
                    Err(r) => {
                        err.get_or_insert(r);
                        c.clone()
                    }
                });
                match err {
                    Some(r) => Err(r),
                    None => Ok(Expr::operator(out)),
                }
            }
        }
    }

    /// The image box of `subs` over `sc`, axis by axis, with the cell set each
    /// subscript's symbol runs along.
    fn image_box(
        &self,
        subs: &[Expr],
        sc: &Scope,
        what: &str,
    ) -> WResult<(Vec<(i64, i64)>, Vec<Option<String>>)> {
        let mut bx = Vec::with_capacity(subs.len());
        let mut sets = Vec::with_capacity(subs.len());
        for s in subs {
            if mentions_any(s, &sc.contracted) {
                return self.refuse(format_args!("subscripts {what} with a reduction index"));
            }
            match sc.role(s) {
                Some(AxisRole::Map { out_axis, ax }) => {
                    bx.push(sc.image(out_axis, &ax));
                    sets.push(sc.sets[out_axis].clone());
                }
                Some(AxisRole::Const(g)) => {
                    bx.push((g, g));
                    sets.push(None);
                }
                None => {
                    return self.refuse(format_args!("subscripts {what} at a computed position"));
                }
            }
        }
        Ok((bx, sets))
    }

    fn index(&mut self, node: &Arc<ExpressionNode>, sc: &Scope) -> WResult<Expr> {
        let base = &node.args[0];
        let subs = &node.args[1..];
        let mut new_subs = Vec::with_capacity(subs.len());
        for s in subs {
            new_subs.push(self.expr(s, sc)?);
        }
        let rebuilt = |base: Expr, subs: Vec<Expr>| {
            let mut n = ExpressionNode::clone(node);
            n.args = std::iter::once(base).chain(subs).collect();
            Expr::operator(n)
        };
        if let Expr::Variable(v) = base {
            match self.leaf(v, sc) {
                Leaf::Array(root) => {
                    self.index_array(&root, subs, sc)?;
                    return Ok(rebuilt(base.clone(), new_subs));
                }
                Leaf::Inline(b, fr) => {
                    self.walk_in(fr, &b, sc)?;
                    return Ok(rebuilt(base.clone(), new_subs));
                }
                // The call computes the value over its own box, so a read of
                // it at other cells is not a read of the array it came from.
                Leaf::CutValue => {
                    return self.refuse(format_args!(
                        "subscripts the operator parameter `{v}`, bound to a value computed \
                         from a decomposed array"
                    ));
                }
                Leaf::Plain => {}
            }
        }
        if let Expr::Operator(inner) = base {
            if inner.op == APPLY_OP {
                let r = self.reference(inner, Ctx::Indexed(subs), sc)?;
                return Ok(rebuilt(r, new_subs));
            }
            if let Some(b) = self.indexed_base(inner, subs, sc)? {
                return Ok(rebuilt(b, new_subs));
            }
        }
        let b = self.expr(base, sc)?;
        Ok(rebuilt(b, new_subs))
    }

    /// Record the reads of `index(v, subs…)` over `sc`, `v` the program's
    /// state or observed of that name.
    fn index_array(&mut self, v: &str, subs: &[Expr], sc: &Scope) -> WResult<()> {
        let info = &self.vars[v];
        if info.axes.len() != subs.len() {
            if info.is_cut() {
                return self.refuse(format_args!(
                    "reads `{v}` with {} subscripts for its {} axes",
                    subs.len(),
                    info.axes.len()
                ));
            }
            return Ok(());
        }
        for (d, s) in subs.iter().enumerate() {
            let runs = match &info.axes[d] {
                AxisSpec::Whole { .. } => vec![info.extent[d]],
                AxisSpec::Cut { cell, set, .. } => {
                    if mentions_any(s, &sc.contracted) {
                        return self.global(format_args!("contracts `{v}`"), set);
                    }
                    match sc.role(s) {
                        Some(AxisRole::Map { out_axis, ax }) => {
                            if let Some(other) = &sc.sets[out_axis]
                                && other != cell
                            {
                                return self.refuse(format_args!(
                                    "reads `{v}` along `{set}` at a subscript that runs \
                                     along `{other}`"
                                ));
                            }
                            sc.image_runs(out_axis, &ax)
                        }
                        Some(AxisRole::Const(g)) => vec![(g, g)],
                        None => {
                            return self.global(
                                format_args!("reads `{v}` at a data-dependent subscript"),
                                set,
                            );
                        }
                    }
                }
            };
            for (lo, hi) in runs {
                self.reads.push(Read {
                    var: v.to_string(),
                    axis: d,
                    lo,
                    hi,
                });
            }
        }
        Ok(())
    }

    /// `index(base, subs…)` of a makearray or an array-valued `faq` over
    /// `sc`: the base restricted to the image of the box. `None` for any
    /// other base.
    fn indexed_base(
        &mut self,
        inner: &Arc<ExpressionNode>,
        subs: &[Expr],
        sc: &Scope,
    ) -> WResult<Option<Expr>> {
        if inner.op == "makearray" {
            let (bx, sets) = self.image_box(subs, sc, "a makearray")?;
            return self.makearray(inner, &bx, &sets, sc).map(Some);
        }
        if inner.op != "faq" || inner.output_idx.as_ref().is_none_or(|o| o.is_empty()) {
            return Ok(None);
        }
        let (bx, sets) = self.image_box(subs, sc, "an array-valued faq")?;
        let out_idx = inner.output_idx.clone().unwrap_or_default();
        let Some(ranges) = faq_ranges(inner, &out_idx) else {
            return self.refuse("holds a faq whose output ranges do not resolve");
        };
        if ranges.len() != bx.len() {
            return self.refuse("subscripts a faq with the wrong number of indices");
        }
        let clipped: Vec<(i64, i64)> = ranges
            .iter()
            .zip(&bx)
            .map(|(&(lo, hi), &(a, b))| (lo.max(a), hi.min(b)))
            .collect();
        if clipped.iter().any(|(lo, hi)| lo > hi) {
            return Ok(Some(zero_makearray(&bx)));
        }
        self.faq(inner, &clipped, &sets, sc).map(Some)
    }

    /// The operator reference `node` over `sc`, read through the body of the
    /// instance it names, in the position `ctx`. The reference is kept; when
    /// the box restricts the body, it is pointed at a [`RestrictedDef`]
    /// holding the restricted body.
    fn reference(&mut self, node: &Arc<ExpressionNode>, ctx: Ctx<'_>, sc: &Scope) -> WResult<Expr> {
        // A call in a region value is lowered over the region's box: its
        // bindings are read there.
        let region_sc;
        let bsc = match ctx {
            Ctx::Region { rc, sets, .. } => {
                region_sc = self.region_scope(rc, sets, sc)?;
                &region_sc
            }
            _ => sc,
        };
        let name = node.name.as_deref().unwrap_or("");
        let ops = self.ops;
        if self.depth >= MAX_REFERENCE_DEPTH {
            return self.refuse(format_args!(
                "nests operator references more than {MAX_REFERENCE_DEPTH} deep at `{name}`"
            ));
        }
        let inst = match ops.instance_of_node(node) {
            Ok(i) => i,
            Err(e) => return self.refuse(format_args!("holds an operator reference: {e}")),
        };
        let Some(r) = reference_node(node) else {
            return self.refuse("holds an operator reference without a name");
        };
        // The loop symbols the expansion binds around a binding: those the
        // instance body binds and those of the bodies it reaches.
        let mut binders: HashSet<String> = inst.binders().clone();
        binders.extend(
            ops.registry()
                .captured_symbols(&inst.definition.name)
                .iter()
                .cloned(),
        );
        let reads_loop = |e: &Expr| {
            free_names(e, Binders::SCOPE)
                .iter()
                .any(|n| bsc.syms.contains(n) || bsc.contracted.contains(n) || binders.contains(n))
        };
        let mut frame = Frame {
            params: HashMap::new(),
            in_body: true,
        };
        let mut bindings = node.bindings.clone().unwrap_or_default();
        let mut params = Vec::new();
        for p in &inst.definition.params {
            // An instance parameter is spelled into the instance body.
            if inst.instance_params.contains(p) {
                continue;
            }
            params.push(p.clone());
            let Some(b) = r.binding(p) else { continue };
            let leaf = match b {
                Expr::Variable(n) => Some(self.leaf(n, bsc)),
                _ => None,
            };
            let bound = match leaf {
                Some(Leaf::Array(root)) => Bound::Array(root),
                Some(Leaf::Inline(x, fr)) => Bound::Inline(x, fr),
                _ if reads_loop(b) => Bound::Inline(b.clone(), Rc::clone(&self.frame)),
                _ => {
                    let first = self.reads.len();
                    let nb = self.expr(b, bsc)?;
                    if nb != *b {
                        bindings.insert(p.clone(), nb);
                    }
                    let cut = self.reads[first..]
                        .iter()
                        .any(|r| self.vars[&r.var].axes[r.axis].cut_cell().is_some());
                    Bound::Value(cut)
                }
            };
            frame.params.insert(p.clone(), bound);
        }
        let saved = std::mem::replace(&mut self.frame, Rc::new(frame));
        self.depth += 1;
        let walked = self.body_root(&inst.body, ctx, sc);
        self.depth -= 1;
        self.frame = saved;
        let body = walked?;
        let same_bindings = node
            .bindings
            .as_ref()
            .map_or(bindings.is_empty(), |b| *b == bindings);
        if body == inst.body && same_bindings {
            return Ok(Expr::Operator(Arc::clone(node)));
        }
        let mut n = ExpressionNode::clone(node);
        if body != inst.body {
            let text = serde_json::to_string(&body).unwrap_or_default();
            let restricted = format!("{}\0tile\0{:032x}", inst.definition.name, text_hash(&text));
            self.restricted.push(RestrictedDef {
                name: restricted.clone(),
                params,
                body,
            });
            n.name = Some(restricted);
        }
        if !same_bindings {
            n.bindings = Some(bindings);
        }
        Ok(Expr::operator(n))
    }

    /// The body `e` of an instance the walk entered, in the position `ctx`
    /// of its reference: read as the expansion reads that position, so a
    /// makearray or `faq` there is restricted as it would be in place.
    fn body_root(&mut self, e: &Expr, ctx: Ctx<'_>, sc: &Scope) -> WResult<Expr> {
        match ctx {
            Ctx::Plain => self.expr(e, sc),
            Ctx::Indexed(subs) => {
                if let Expr::Operator(node) = e {
                    if node.op == APPLY_OP {
                        return self.reference(node, ctx, sc);
                    }
                    if let Some(b) = self.indexed_base(node, subs, sc)? {
                        return Ok(b);
                    }
                }
                self.expr(e, sc)
            }
            Ctx::Region { ro, rc, sets } => self.region_value(e, ro, rc, sets, sc),
        }
    }

    /// A `faq` evaluated over `ranges` (its output symbols, in order), each
    /// symbol running along `sets`.
    fn faq(
        &mut self,
        node: &Arc<ExpressionNode>,
        ranges: &[(i64, i64)],
        sets: &[Option<String>],
        sc: &Scope,
    ) -> WResult<Expr> {
        let out_idx: Vec<String> = node.output_idx.clone().unwrap_or_default();
        let contracted = contracted_of(node);
        let inner = sc.nested(&out_idx, ranges, sets, &contracted);
        let mut n = ExpressionNode::clone(node);
        if !out_idx.is_empty() {
            let mut rmap = n.ranges.clone().unwrap_or_default();
            for (name, &(lo, hi)) in out_idx.iter().zip(ranges) {
                rmap.insert(name.clone(), RangeSpec::Interval([lo, hi]));
            }
            n.ranges = Some(rmap);
        }
        if let Some(body) = node.expr.as_deref() {
            n.expr = Some(Box::new(self.expr(body, &inner)?));
        }
        if let Some(filter) = node.filter.as_deref() {
            n.filter = Some(Box::new(self.expr(filter, &inner)?));
        }
        Ok(Expr::operator(n))
    }

    /// A makearray read over `need` (one inclusive range per axis), whose axes
    /// run along `sets`, inside the box `sc`.
    fn makearray(
        &mut self,
        node: &Arc<ExpressionNode>,
        need: &[(i64, i64)],
        sets: &[Option<String>],
        sc: &Scope,
    ) -> WResult<Expr> {
        let (Some(regions), Some(values)) = (node.regions.as_ref(), node.values.as_ref()) else {
            return self.refuse("holds a makearray with no regions");
        };
        let mut new_regions = Vec::new();
        let mut new_values = Vec::new();
        for (region, value) in regions.iter().zip(values) {
            let Some(rb) = region_box(region) else {
                return self.refuse("holds a makearray with a symbolic region bound");
            };
            if rb.len() != need.len() {
                return self.refuse("reads a makearray at the wrong rank");
            }
            if rb.iter().any(|(lo, hi)| lo > hi) {
                // The legal empty spelling covers no cell; the lowering still
                // evaluates its value over the empty box, which reads nothing.
                new_regions.push(region.clone());
                new_values.push(value.clone());
                continue;
            }
            let rc: Vec<(i64, i64)> = rb
                .iter()
                .zip(need)
                .map(|(&(lo, hi), &(a, b))| (lo.max(a), hi.min(b)))
                .collect();
            if rc.iter().any(|(lo, hi)| lo > hi) {
                continue;
            }
            let v = self.region_value(value, &rb, &rc, sets, sc)?;
            new_regions.push(
                rc.iter()
                    .map(|&(lo, hi)| [RegionBound::Int(lo), RegionBound::Int(hi)])
                    .collect(),
            );
            new_values.push(v);
        }
        if new_regions.is_empty()
            || new_regions
                .iter()
                .all(|r| region_box(r).is_some_and(|b| b.iter().any(|(lo, hi)| lo > hi)))
        {
            return Ok(zero_makearray(need));
        }
        let mut n = ExpressionNode::clone(node);
        n.regions = Some(new_regions);
        n.values = Some(new_values);
        Ok(Expr::operator(n))
    }

    /// One region value, its region clipped from `ro` to `rc`.
    fn region_value(
        &mut self,
        v: &Expr,
        ro: &[(i64, i64)],
        rc: &[(i64, i64)],
        sets: &[Option<String>],
        sc: &Scope,
    ) -> WResult<Expr> {
        match v {
            Expr::Operator(node)
                if (node.op == "faq")
                    && node.output_idx.as_ref().is_some_and(|o| !o.is_empty()) =>
            {
                let out_idx = node.output_idx.clone().unwrap_or_default();
                let Some(fr) = faq_ranges(node, &out_idx) else {
                    return self.refuse("holds a faq region value whose ranges do not resolve");
                };
                let fshape: Vec<usize> = fr
                    .iter()
                    .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
                    .collect();
                let rshape: Vec<usize> = ro
                    .iter()
                    .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
                    .collect();
                let Some(covered) = region_value_axes(&fshape, &rshape) else {
                    return self.refuse("holds a faq region value that does not fit its region");
                };
                let region_axes: Vec<usize> = (0..ro.len()).filter(|&d| covered[d]).collect();
                if region_axes.len() != fr.len() {
                    return self.refuse("holds a faq region value that does not fit its region");
                }
                let mut ranges = Vec::with_capacity(fr.len());
                let mut fsets = Vec::with_capacity(fr.len());
                for (f, &d) in region_axes.iter().enumerate() {
                    let (flo, fhi) = fr[f];
                    ranges.push((flo + (rc[d].0 - ro[d].0), fhi - (ro[d].1 - rc[d].1)));
                    fsets.push(sets[d].clone());
                }
                self.faq(node, &ranges, &fsets, sc)
            }
            // A call is lowered over the region's box, and its body is the
            // region value the expansion holds there.
            Expr::Operator(node) if node.op == APPLY_OP => {
                self.reference(node, Ctx::Region { ro, rc, sets }, sc)
            }
            Expr::Operator(node)
                if node.op != "index" && node.op != "faq" && node.op != "makearray" =>
            {
                let mut err = None;
                let out =
                    node.map_children(&mut |c| match self.region_value(c, ro, rc, sets, sc) {
                        Ok(x) => x,
                        Err(r) => {
                            err.get_or_insert(r);
                            c.clone()
                        }
                    });
                match err {
                    Some(r) => Err(r),
                    None => Ok(Expr::operator(out)),
                }
            }
            _ => {
                let inner = self.region_scope(rc, sets, sc)?;
                self.expr(v, &inner)
            }
        }
    }

    /// `sc` with the box's symbols rebound to the region `rc`, as the
    /// lowering's region box rebinds them.
    fn region_scope(
        &self,
        rc: &[(i64, i64)],
        sets: &[Option<String>],
        sc: &Scope,
    ) -> WResult<Scope> {
        if sc.syms.len() < rc.len() {
            return self.refuse("holds a makearray whose rank exceeds its box");
        }
        let mut inner = sc.clone();
        for d in 0..rc.len() {
            inner.lo[d] = rc[d].0;
            inner.hi[d] = rc[d].1;
            inner.sets[d] = sets[d].clone().or_else(|| sc.sets[d].clone());
        }
        Ok(inner)
    }
}
