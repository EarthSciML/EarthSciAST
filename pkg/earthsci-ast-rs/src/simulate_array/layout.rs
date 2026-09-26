//! Column-major layout helpers: flat↔multi index conversion, ndarray
//! materialization of column-major blocks, Cartesian index enumeration, and
//! the state layout's slot names and coverage.

use super::*;

pub(super) fn multi_to_flat_col_major(multi: &[i64], shape: &[usize], origin: &[i64]) -> usize {
    if shape.is_empty() {
        return 0;
    }
    let mut flat: usize = 0;
    let mut stride: usize = 1;
    for d in 0..shape.len() {
        let off = (multi[d] - origin[d]).max(0) as usize;
        flat += off * stride;
        stride *= shape[d];
    }
    flat
}

pub(super) fn flat_to_multi_col_major(flat: usize, shape: &[usize]) -> Vec<usize> {
    let mut out = vec![0usize; shape.len()];
    let mut rem = flat;
    for d in 0..shape.len() {
        out[d] = rem % shape[d];
        rem /= shape[d];
    }
    out
}

/// Build a column-major ndarray from a flat slice. ndarray uses row-major
/// strides natively, so we construct via `from_shape_vec` with a reversed
/// shape and then `permuted_axes` to get the column-major view.
pub(super) fn col_major_to_arrayd(flat: &[f64], shape: &[usize]) -> ArrayD<f64> {
    if shape.is_empty() {
        return ArrayD::from_elem(IxDyn(&[]), flat[0]);
    }
    // Build row-major array with reversed shape, then reverse axes. The
    // element order in `flat` is column-major, which equals row-major of
    // the reversed-shape array.
    let rev_shape: Vec<usize> = shape.iter().rev().copied().collect();
    let arr = ArrayD::from_shape_vec(IxDyn(&rev_shape), flat.to_vec()).unwrap_or_else(|e| {
        panic!(
            "col_major_to_arrayd shape mismatch: shape {shape:?} (product {}) \
             vs {} elements: {e}",
            shape.iter().product::<usize>(),
            flat.len(),
        )
    });
    let perm: Vec<usize> = (0..shape.len()).rev().collect();
    arr.permuted_axes(perm).as_standard_layout().into_owned()
}

/// Flatten an ndarray into column-major order.
pub(super) fn arrayd_to_col_major(arr: &ArrayD<f64>) -> Vec<f64> {
    if arr.ndim() == 0 {
        return vec![arr[IxDyn(&[])]];
    }
    let shape: Vec<usize> = arr.shape().to_vec();
    let total: usize = shape.iter().product();
    let mut out = vec![0.0f64; total];
    for flat in 0..total {
        let multi = flat_to_multi_col_major(flat, &shape);
        out[flat] = arr[IxDyn(&multi)];
    }
    out
}

/// Streaming, allocation-free enumerator over the Cartesian product of inclusive
/// `(lo, hi)` ranges, in lexicographic order with dim0 outermost/slowest and the
/// last dim fastest (no ranges ⇒ one empty tuple, any `lo > hi` dim ⇒ zero
/// tuples). It yields `&[i64]` slices out of a single reused stack buffer.
///
/// The per-cell reduction kernel ([`reduce_contraction`]) rebuilt the *whole*
/// contraction product on every output cell, so the throw-away per-tuple
/// `Vec<i64>` dominated the array-simulate profile (~23% of samples were just
/// `drop_in_place::<Vec<i64>>`). This enumerator allocates nothing per tuple.
///
/// Because each yielded slice borrows the shared buffer, this is a *lending*
/// iterator: it exposes an inherent [`CartesianTuples::next`] for use in a
/// `while let Some(tuple) = it.next()` loop rather than implementing [`Iterator`].
pub(super) struct CartesianTuples<'a> {
    ranges: &'a [(i64, i64)],
    cur: SmallVec<[i64; 4]>,
    started: bool,
    done: bool,
}

impl<'a> CartesianTuples<'a> {
    #[inline]
    pub(super) fn new(ranges: &'a [(i64, i64)]) -> Self {
        // Any empty dim (lo > hi) makes the whole product empty (zero tuples).
        let done = ranges.iter().any(|&(lo, hi)| lo > hi);
        let cur: SmallVec<[i64; 4]> = ranges.iter().map(|&(lo, _)| lo).collect();
        CartesianTuples {
            ranges,
            cur,
            started: false,
            done,
        }
    }

    /// Advance to the next tuple, returning it as a slice into the reused buffer,
    /// or `None` once the product is exhausted.
    #[inline]
    pub(super) fn next(&mut self) -> Option<&[i64]> {
        if self.done {
            return None;
        }
        if !self.started {
            // First tuple: every dim at its lower bound (an empty product of no
            // ranges yields exactly one empty tuple, like `vec![vec![]]`).
            self.started = true;
            return Some(&self.cur[..]);
        }
        // Odometer increment: advance the last (fastest-varying) dim, carrying
        // left into slower dims — reproduces the lexicographic order.
        let mut d = self.ranges.len();
        while d > 0 {
            d -= 1;
            if self.cur[d] < self.ranges[d].1 {
                self.cur[d] += 1;
                return Some(&self.cur[..]);
            }
            self.cur[d] = self.ranges[d].0;
        }
        self.done = true;
        None
    }
}

// ============================================================================
// State slots named from per-array metadata
// ============================================================================
//
// The state vector is laid out array by array: each state variable owns the
// contiguous slots `flat_offset .. flat_offset + product(shape)`, column-major
// within the array ([`VarShape`]). That metadata is the whole layout, so a
// slot's NAME (`u[2,3]`, or a bare `s` for a 0-D state) is computed from it
// when a public surface asks — the reported state names, an override key, a
// diagnostic — rather than stored per slot. [`slot_name`], [`slot_names`] and
// [`lookup_slot`] are the three directions, and they agree with each other by
// construction: `lookup_slot(slot_name(k)) == Some(k)`.

/// Slots in one variable's range (`max(1)`: a 0-D state owns one slot).
fn var_slot_count(vs: &VarShape) -> usize {
    vs.shape.iter().copied().product::<usize>().max(1)
}

/// Append `[i,j,...]` for column-major cell `flat` of `vs` (1-based, from the
/// variable's origin) to `out`. Nothing for a 0-D state.
fn push_cell_suffix(out: &mut String, vs: &VarShape, flat: usize) {
    use std::fmt::Write as _;
    if vs.shape.is_empty() {
        return;
    }
    out.push('[');
    let mut rem = flat;
    for (d, (&n, &o)) in vs.shape.iter().zip(vs.origin.iter()).enumerate() {
        if d > 0 {
            out.push(',');
        }
        let _ = write!(out, "{}", (rem % n) as i64 + o);
        rem /= n;
    }
    out.push(']');
}

/// The variable owning `slot`, with the slot's position inside it. The
/// variables are in slot order, so this is a binary search.
fn owner_of(
    var_shapes: &IndexMap<String, VarShape>,
    slot: usize,
) -> Option<(&str, &VarShape, usize)> {
    let k = var_shapes.partition_point(|_, vs| vs.flat_offset <= slot);
    let (name, vs) = var_shapes.get_index(k.checked_sub(1)?)?;
    let local = slot - vs.flat_offset;
    (local < var_slot_count(vs)).then_some((name.as_str(), vs, local))
}

/// The name of state slot `slot`: `u[2,3]` for a cell of an array state, the
/// bare variable name for a 0-D one. `None` past the end of the state vector.
pub(super) fn slot_name(var_shapes: &IndexMap<String, VarShape>, slot: usize) -> Option<String> {
    let (name, vs, local) = owner_of(var_shapes, slot)?;
    let mut out = String::with_capacity(name.len() + 8);
    out.push_str(name);
    push_cell_suffix(&mut out, vs, local);
    Some(out)
}

/// Every state slot's name, in slot order, with each variable's name spelled
/// by `base` (the identity for the model's own names, or a qualification).
/// The cell suffix is appended after `base`, which is exact for a
/// qualification because the suffix carries no `.`.
pub(super) fn slot_names_with(
    var_shapes: &IndexMap<String, VarShape>,
    mut base: impl FnMut(&str) -> String,
) -> Vec<String> {
    let total = var_shapes.values().map(var_slot_count).sum();
    let mut out = Vec::with_capacity(total);
    for (name, vs) in var_shapes {
        let spelled = base(name);
        for local in 0..var_slot_count(vs) {
            let mut s = String::with_capacity(spelled.len() + 8);
            s.push_str(&spelled);
            push_cell_suffix(&mut s, vs, local);
            out.push(s);
        }
    }
    out
}

/// Every state slot's name, in slot order.
pub(super) fn slot_names(var_shapes: &IndexMap<String, VarShape>) -> Vec<String> {
    slot_names_with(var_shapes, str::to_string)
}

/// The column-major cell `idx` designates in `vs` — the text between the
/// brackets of a slot name, `2,3` — or `None` unless it is EXACTLY what
/// [`slot_name`] prints for some cell: one canonical decimal per axis (no sign,
/// no leading zero, no whitespace), each inside the axis's range.
fn parse_cell(vs: &VarShape, idx: &str) -> Option<usize> {
    let mut flat = 0usize;
    let mut stride = 1usize;
    let mut parts = idx.split(',');
    for (&n, &o) in vs.shape.iter().zip(vs.origin.iter()) {
        let p = parts.next()?;
        let canonical = !p.is_empty()
            && p.len() <= 19
            && p.bytes().all(|b| b.is_ascii_digit())
            && (p == "0" || !p.starts_with('0'));
        if !canonical {
            return None;
        }
        let v: i64 = p.parse().ok()?;
        let off = usize::try_from(v.checked_sub(o)?).ok()?;
        if off >= n {
            return None;
        }
        flat += off * stride;
        stride *= n;
    }
    parts.next().is_none().then_some(flat)
}

/// The state slot a name designates — the inverse of [`slot_name`] — or `None`
/// when no slot is named that.
pub(super) fn lookup_slot(var_shapes: &IndexMap<String, VarShape>, key: &str) -> Option<usize> {
    if let Some(vs) = var_shapes.get(key) {
        return vs.shape.is_empty().then_some(vs.flat_offset);
    }
    let (base, idx) = split_cell_suffix(key)?;
    let vs = var_shapes.get(base)?;
    if vs.shape.is_empty() {
        return None;
    }
    Some(vs.flat_offset + parse_cell(vs, idx)?)
}

/// `u[2,3]` split into `("u", "2,3")`; `None` for a key with no trailing
/// bracketed cell.
fn split_cell_suffix(key: &str) -> Option<(&str, &str)> {
    let inner = key.strip_suffix(']')?;
    let open = inner.rfind('[')?;
    Some((&inner[..open], &inner[open + 1..]))
}

/// The state slots as the override-key canonicalization sees them
/// (esm-spec §6.6.2): every slot name, answered from the layout.
pub(super) struct SlotNames<'a>(pub(super) &'a IndexMap<String, VarShape>);

impl crate::simulate::KnownNames for SlotNames<'_> {
    fn contains(&self, key: &str) -> bool {
        lookup_slot(self.0, key).is_some()
    }

    fn suffix_owners(&self, key: &str) -> Vec<String> {
        // A slot name's cell suffix carries no `.`, so a key is a dotted
        // suffix of `V[cell]` exactly when its part before the cell is a
        // dotted suffix of the variable name `V` and the cell is one of `V`'s.
        let (base, idx) = match split_cell_suffix(key) {
            Some((b, i)) => (b, Some(i)),
            None => (key, None),
        };
        let mut out = Vec::new();
        for (name, vs) in self.0 {
            if !crate::simulate::is_dotted_suffix(name, base) {
                continue;
            }
            let fits = match idx {
                None => vs.shape.is_empty(),
                Some(i) => !vs.shape.is_empty() && parse_cell(vs, i).is_some(),
            };
            if fits {
                out.push(match idx {
                    None => name.clone(),
                    Some(i) => format!("{name}[{i}]"),
                });
            }
        }
        out
    }
}

/// Which state slots a derivative equation defines, one flag per slot: the
/// build's check that every slot has exactly the definition it needs (stage 7
/// and 8 of [`ArrayCompiled::from_model`]). A flag per slot, so marking a
/// whole array or an axis-aligned box of it is a fill.
pub(super) struct SlotCoverage {
    covered: Vec<bool>,
}

impl SlotCoverage {
    pub(super) fn new(n_states: usize) -> Self {
        SlotCoverage {
            covered: vec![false; n_states],
        }
    }

    /// Mark one slot. A slot past the end of the state vector is ignored: it
    /// designates nothing, and only the state slots are ever checked.
    pub(super) fn insert(&mut self, slot: usize) {
        if let Some(c) = self.covered.get_mut(slot) {
            *c = true;
        }
    }

    /// Mark `len` consecutive slots from `start`.
    pub(super) fn insert_range(&mut self, start: usize, len: usize) {
        let n = self.covered.len();
        let lo = start.min(n);
        let hi = start.saturating_add(len).min(n);
        self.covered[lo..hi].fill(true);
    }

    /// The first slot no equation defines.
    pub(super) fn first_uncovered(&self) -> Option<usize> {
        self.covered.iter().position(|c| !c)
    }
}

/// Write variable `vs`'s default into `out` (its own slot range, column-major)
/// and say whether it declared one. A broadcast is one fill; inline array data
/// is gathered from its row-major order.
pub(super) fn write_state_default(vs: &VarShape, default: &StateDefault, out: &mut [f64]) -> bool {
    match default {
        StateDefault::Scalar(None) => false,
        StateDefault::Scalar(Some(v)) => {
            out.fill(*v);
            true
        }
        StateDefault::Field(row_major) => {
            let shape = &vs.shape;
            let rank = shape.len();
            let mut row_stride = vec![0usize; rank];
            let mut acc = 1usize;
            for d in (0..rank).rev() {
                row_stride[d] = acc;
                acc *= shape[d];
            }
            // A column-major odometer (axis 0 fastest) carrying the cell's
            // row-major offset along with it.
            let mut multi = vec![0usize; rank];
            let mut roff = 0usize;
            for o in out.iter_mut() {
                *o = row_major[roff];
                for d in 0..rank {
                    multi[d] += 1;
                    roff += row_stride[d];
                    if multi[d] < shape[d] {
                        break;
                    }
                    roff -= row_stride[d] * shape[d];
                    multi[d] = 0;
                }
            }
            true
        }
    }
}

/// An index expression as the integer-linear form `c + Σ_k a_k · t_k` over the
/// loop symbols `idx_names` — exactly the function `eval_simple_index`
/// computes, taken apart once instead of evaluated per cell. Integer and
/// numeric literals are constants, `+` / `-` of two arguments combine, a
/// symbol that is not a loop symbol and any other node read as 0. A symbol
/// bound twice in `idx_names` reads its LAST binding, as the per-cell bind map
/// does.
fn linear_index(expr: &Expr, idx_names: &[String]) -> (i64, Vec<i64>) {
    let mut coef = vec![0i64; idx_names.len()];
    let c = linear_index_into(expr, idx_names, 1, &mut coef);
    (c, coef)
}

fn linear_index_into(expr: &Expr, idx_names: &[String], sign: i64, coef: &mut [i64]) -> i64 {
    match expr {
        Expr::Integer(n) => sign * *n,
        Expr::Number(n) => sign * (*n as i64),
        Expr::Variable(name) => {
            if let Some(k) = idx_names.iter().rposition(|n| n == name) {
                coef[k] += sign;
            }
            0
        }
        Expr::Operator(node) if (node.op == "+" || node.op == "-") && node.args.len() == 2 => {
            let a = linear_index_into(&node.args[0], idx_names, sign, coef);
            let s2 = if node.op == "+" { sign } else { -sign };
            a + linear_index_into(&node.args[1], idx_names, s2, coef)
        }
        _ => 0,
    }
}

/// Mark the slots an array-op derivative `D(index(var, lhs...))` over the
/// loop box `ranges` defines: for each tuple of the box, the cell its
/// left-hand index expressions evaluate to, with the flat offset
/// `multi_to_flat_col_major` gives it.
///
/// The index expressions are taken apart into linear forms once. When every
/// axis is a distinct loop symbol plus a constant (or a constant) and lands
/// inside the variable's extent, the image is an axis-aligned box of the
/// array and is marked a column at a time; any other form is evaluated per
/// cell from the linear form, which is the same arithmetic.
pub(super) fn mark_faq_lhs_coverage(
    vs: &VarShape,
    idx_names: &[String],
    ranges: &[(i64, i64)],
    lhs_idx_exprs: &[Expr],
    coverage: &mut SlotCoverage,
) {
    if ranges.iter().any(|&(lo, hi)| lo > hi) {
        return; // an empty box has no tuple
    }
    let forms: Vec<(i64, Vec<i64>)> = lhs_idx_exprs
        .iter()
        .map(|e| linear_index(e, idx_names))
        .collect();
    if let Some(bx) = coverage_box(vs, ranges, &forms) {
        mark_box(vs, &bx, coverage);
        return;
    }
    let mut multi = vec![0i64; forms.len()];
    let mut tuples = CartesianTuples::new(ranges);
    while let Some(t) = tuples.next() {
        for (m, (c, coef)) in multi.iter_mut().zip(&forms) {
            *m = c + coef.iter().zip(t).map(|(a, v)| a * v).sum::<i64>();
        }
        let flat = multi_to_flat_col_major(&multi, &vs.shape, &vs.origin);
        coverage.insert(vs.flat_offset + flat);
    }
}

/// The per-axis `[lo, hi]` (0-based, inside the extent) the forms map the box
/// onto, when that image is the whole box product: see
/// [`mark_faq_lhs_coverage`].
fn coverage_box(
    vs: &VarShape,
    ranges: &[(i64, i64)],
    forms: &[(i64, Vec<i64>)],
) -> Option<Vec<(usize, usize)>> {
    let rank = vs.shape.len();
    if forms.len() < rank {
        return None;
    }
    let mut used = vec![false; ranges.len()];
    let mut out = Vec::with_capacity(rank);
    for d in 0..rank {
        let (c, coef) = &forms[d];
        let mut nz = coef.iter().enumerate().filter(|(_, a)| **a != 0);
        let (lo, hi) = match (nz.next(), nz.next()) {
            (None, _) => (*c, *c),
            (Some((k, 1)), None) if !used[k] => {
                used[k] = true;
                (c.checked_add(ranges[k].0)?, c.checked_add(ranges[k].1)?)
            }
            _ => return None,
        };
        let o = vs.origin[d];
        let lo0 = usize::try_from(lo.checked_sub(o)?).ok()?;
        let hi0 = usize::try_from(hi.checked_sub(o)?).ok()?;
        if hi0 >= vs.shape[d] {
            return None;
        }
        out.push((lo0, hi0));
    }
    Some(out)
}

/// Mark every cell of the box `bx` (0-based inclusive per axis) of `vs`.
fn mark_box(vs: &VarShape, bx: &[(usize, usize)], coverage: &mut SlotCoverage) {
    if bx.is_empty() {
        coverage.insert(vs.flat_offset);
        return;
    }
    let rank = bx.len();
    let mut stride = vec![1usize; rank];
    for d in 1..rank {
        stride[d] = stride[d - 1] * vs.shape[d - 1];
    }
    let run = bx[0].1 - bx[0].0 + 1;
    let mut idx: Vec<usize> = bx.iter().map(|&(lo, _)| lo).collect();
    loop {
        let base: usize = idx.iter().zip(&stride).map(|(i, s)| i * s).sum();
        coverage.insert_range(vs.flat_offset + base, run);
        // Advance the outer axes (1..rank), axis 1 fastest.
        let mut d = 1;
        loop {
            if d == rank {
                return;
            }
            if idx[d] < bx[d].1 {
                idx[d] += 1;
                break;
            }
            idx[d] = bx[d].0;
            d += 1;
        }
    }
}

#[cfg(test)]
mod slot_layout_tests {
    use super::*;
    use crate::simulate::KnownNames;

    /// `s` (0-D), `M.u` over 3x2, `v` over 4: slots 0, 1..=6, 7..=10.
    fn layout() -> IndexMap<String, VarShape> {
        let mut m = IndexMap::new();
        let mut off = 0;
        for (name, shape) in [("s", vec![]), ("M.u", vec![3, 2]), ("v", vec![4])] {
            let n = shape.iter().product::<usize>().max(1);
            m.insert(
                name.to_string(),
                VarShape {
                    origin: vec![1; shape.len()],
                    shape,
                    flat_offset: off,
                },
            );
            off += n;
        }
        m
    }

    /// The names are the column-major cells the per-slot table used to hold,
    /// and every one of them looks up to its own slot.
    #[test]
    fn slot_names_round_trip_through_lookup() {
        let m = layout();
        let names = slot_names(&m);
        assert_eq!(
            names,
            [
                "s", "M.u[1,1]", "M.u[2,1]", "M.u[3,1]", "M.u[1,2]", "M.u[2,2]", "M.u[3,2]",
                "v[1]", "v[2]", "v[3]", "v[4]"
            ]
        );
        for (k, n) in names.iter().enumerate() {
            assert_eq!(slot_name(&m, k).as_deref(), Some(n.as_str()));
            assert_eq!(lookup_slot(&m, n), Some(k), "{n}");
        }
        assert_eq!(slot_name(&m, names.len()), None);
    }

    /// Only the exact printed spelling names a slot.
    #[test]
    fn lookup_refuses_every_other_spelling() {
        let m = layout();
        for key in [
            "M.u",
            "v",
            "s[1]",
            "v[0]",
            "v[5]",
            "v[01]",
            "v[+1]",
            "v[ 1]",
            "v[1,1]",
            "M.u[1]",
            "M.u[1,2,1]",
            "M.u[1,]",
            "v[]",
            "v[1",
            "u[1,1]",
            "w",
        ] {
            assert_eq!(lookup_slot(&m, key), None, "{key}");
        }
    }

    /// Rule-3 candidates: a key that is a dotted suffix of a slot name.
    #[test]
    fn suffix_owners_carry_the_cell() {
        let m = layout();
        let names = SlotNames(&m);
        assert_eq!(names.suffix_owners("u[2,1]"), ["M.u[2,1]"]);
        assert!(names.suffix_owners("u[4,1]").is_empty());
        assert!(names.suffix_owners("u").is_empty());
        assert!(names.suffix_owners("v[1]").is_empty());
        assert!(names.contains("M.u[3,2]") && !names.contains("u[3,2]"));
    }

    /// Inline array data (row-major) lands in the column-major slots.
    #[test]
    fn a_field_default_is_gathered_column_major() {
        let vs = VarShape {
            shape: vec![3, 2],
            origin: vec![1, 1],
            flat_offset: 0,
        };
        let mut out = vec![0.0; 6];
        let row_major = vec![11.0, 12.0, 21.0, 22.0, 31.0, 32.0];
        assert!(write_state_default(
            &vs,
            &StateDefault::Field(row_major),
            &mut out
        ));
        assert_eq!(out, [11.0, 21.0, 31.0, 12.0, 22.0, 32.0]);
        assert!(!write_state_default(
            &vs,
            &StateDefault::Scalar(None),
            &mut out
        ));
    }

    /// The box fast path marks exactly what the per-cell arithmetic does,
    /// shifted and out-of-range forms included.
    #[test]
    fn faq_coverage_box_matches_per_cell_marking() {
        let vs = VarShape {
            shape: vec![4, 3],
            origin: vec![1, 1],
            flat_offset: 2,
        };
        let names = vec!["i".to_string(), "j".to_string()];
        let v = |n: &str| Expr::Variable(n.to_string());
        let add = |a: Expr, b: i64| {
            Expr::operator(crate::types::ExpressionNode {
                op: "+".into(),
                args: vec![a, Expr::Integer(b)],
                ..Default::default()
            })
        };
        let cases: Vec<(Vec<(i64, i64)>, Vec<Expr>)> = vec![
            (vec![(1, 4), (1, 3)], vec![v("i"), v("j")]),
            (vec![(1, 3), (2, 3)], vec![add(v("i"), 1), v("j")]),
            (vec![(1, 3), (1, 4)], vec![v("j"), v("i")]),
            (vec![(1, 4), (1, 3)], vec![v("i"), Expr::Integer(2)]),
            (vec![(1, 4), (1, 3)], vec![add(v("i"), 2), v("j")]),
            (vec![(1, 2), (1, 2)], vec![v("i"), v("i")]),
        ];
        for (ranges, lhs) in cases {
            let mut fast = SlotCoverage::new(16);
            mark_faq_lhs_coverage(&vs, &names, &ranges, &lhs, &mut fast);
            // The per-cell interpretation this replaced.
            let mut slow = SlotCoverage::new(16);
            let mut t = CartesianTuples::new(&ranges);
            while let Some(tuple) = t.next() {
                let binds: HashMap<String, i64> =
                    names.iter().cloned().zip(tuple.iter().copied()).collect();
                let multi: Vec<i64> = lhs.iter().map(|e| eval_simple_index(e, &binds)).collect();
                slow.insert(
                    vs.flat_offset + multi_to_flat_col_major(&multi, &vs.shape, &vs.origin),
                );
            }
            assert_eq!(fast.covered, slow.covered, "{ranges:?}");
        }
    }
}
