//! Test-only REFERENCE executor for the tape IR — a straightforward, slow,
//! allocation-happy interpreter of the program, used by the A/B tests to pin
//! the LOWERING bit-for-bit against `evaluate_rhs_with_scratch` (the full
//! production path). This is NOT the Step 3b fast executor: it ignores the
//! slab coloring entirely (per-slot owned buffers) so that a coloring bug
//! cannot mask a lowering bug, and it clones freely.

use super::super::eval::clip_area_value;
use super::super::*;
use super::exec::{eval_micro_op, forcing_len, load_forcing, run_rhs_oracle};
use super::ir::*;
use ndarray::{ArrayD, ArrayViewD, Axis, IxDyn, Slice};
use std::cell::RefCell;
use std::collections::HashMap;

/// One computed slot value.
#[derive(Clone, Debug)]
pub(super) enum RefVal {
    Scalar(f64),
    Arr(ArrayD<f64>),
}

/// Everything a run leaves behind, for test inspection.
pub(super) struct RefRun {
    /// Per-slot values; `None` = the defining instruction never executed
    /// (dead code, or an untaken `JmpIfZero` branch — which the short-circuit
    /// test asserts on).
    pub slots: Vec<Option<RefVal>>,
    /// The runtime observed map (fallback rule outputs + exports).
    pub obs: ArrMap,
}

/// Execute all three sections of `prog` once, writing `dy`.
pub(super) fn run_reference(
    prog: &TapeProgram,
    compiled: &ArrayCompiled,
    state: &[f64],
    params: &[f64],
    t: f64,
    dy: &mut [f64],
) -> RefRun {
    let state_arrays = build_state_arrays(&compiled.var_shapes, state);
    let mut obs: ArrMap = ArrMap::default();
    let derived_rings: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
    let mut slots: Vec<Option<RefVal>> = vec![None; prog.slots.len()];

    // Pending skip regions from taken JmpIfZero branches:
    // (position at which to skip, how many instructions to skip).
    let mut pending: Vec<(usize, usize)> = Vec::new();
    // The open recurrence sweep: its `Sweep`'s position and current cell.
    let mut sweep: Option<(usize, Vec<usize>)> = None;
    let mut pc = 0usize;
    while pc < prog.instrs.len() {
        while let Some(&(pos, skip)) = pending.last() {
            if pc == pos {
                pending.pop();
                pc += skip;
            } else {
                break;
            }
        }
        if let Some((spc, mut cell)) = sweep.take() {
            let Instr::Sweep { spec } = &prog.instrs[spc] else {
                unreachable!("an open sweep starts at a Sweep")
            };
            let sw = &prog.sweeps[*spec as usize];
            if pc == spc + 1 + sw.body_len as usize {
                let RefVal::Scalar(v) =
                    resolve(prog, &slots, &state_arrays, &obs, params, t, &sw.result)
                else {
                    panic!("a recurrence cell is a scalar");
                };
                let prec = prog
                    .precision
                    .get(spc)
                    .copied()
                    .unwrap_or_else(crate::precision::active);
                let Some(RefVal::Arr(a)) = &mut slots[sw.out as usize] else {
                    panic!("the sweep's array is defined");
                };
                a[IxDyn(&cell)] = prec.round(v);
                if sw.advance(&mut cell) {
                    for (&c, &x) in sw.coords.iter().zip(&cell) {
                        slots[c as usize] = Some(RefVal::Scalar((x + 1) as f64));
                    }
                    pc = spc + 1;
                    sweep = Some((spc, cell));
                    continue;
                }
            } else {
                sweep = Some((spc, cell));
            }
        }
        if pc >= prog.instrs.len() {
            break;
        }
        let instr = &prog.instrs[pc];
        let _precision = prog
            .precision
            .get(pc)
            .filter(|&&p| p != crate::precision::active())
            .map(|&p| crate::precision::enter(p));
        match instr {
            Instr::Bin { op, a, b, out } => {
                let f = binary_kernel_of(*op);
                let av = resolve(prog, &slots, &state_arrays, &obs, params, t, a);
                let bv = resolve(prog, &slots, &state_arrays, &obs, params, t, b);
                let v = match (av, bv) {
                    (RefVal::Scalar(x), RefVal::Scalar(y)) => RefVal::Scalar(f(x, y)),
                    (RefVal::Scalar(x), RefVal::Arr(ya)) => RefVal::Arr(ya.mapv(|y| f(x, y))),
                    (RefVal::Arr(xa), RefVal::Scalar(y)) => RefVal::Arr(xa.mapv(|x| f(x, y))),
                    (RefVal::Arr(xa), RefVal::Arr(ya)) => {
                        assert_eq!(xa.shape(), ya.shape(), "Bin operand shapes");
                        let mut o = xa.clone();
                        ndarray::Zip::from(&mut o)
                            .and(&ya)
                            .for_each(|x, &y| *x = f(*x, y));
                        RefVal::Arr(o)
                    }
                };
                slots[*out as usize] = Some(v);
            }
            Instr::Un { op, a, out } => {
                let f = unary_kernel_of(*op);
                let av = resolve(prog, &slots, &state_arrays, &obs, params, t, a);
                let v = match av {
                    RefVal::Scalar(x) => RefVal::Scalar(f(x)),
                    RefVal::Arr(xa) => RefVal::Arr(xa.mapv(f)),
                };
                slots[*out as usize] = Some(v);
            }
            Instr::Neg { a, out } => {
                let av = resolve(prog, &slots, &state_arrays, &obs, params, t, a);
                let v = match av {
                    RefVal::Scalar(x) => RefVal::Scalar(-x),
                    RefVal::Arr(xa) => RefVal::Arr(xa.mapv(|x| -x)),
                };
                slots[*out as usize] = Some(v);
            }
            Instr::Select { cond, a, b, out } => {
                let cv = resolve(prog, &slots, &state_arrays, &obs, params, t, cond);
                let av = resolve(prog, &slots, &state_arrays, &obs, params, t, a);
                let bv = resolve(prog, &slots, &state_arrays, &obs, params, t, b);
                let desc = &prog.slots[*out as usize];
                let v = if desc.scalar {
                    let (RefVal::Scalar(c), RefVal::Scalar(x), RefVal::Scalar(y)) = (&cv, &av, &bv)
                    else {
                        panic!("scalar Select with array operands");
                    };
                    RefVal::Scalar(if *c != 0.0 { *x } else { *y })
                } else {
                    let shape: Vec<usize> = desc.shape.to_vec();
                    let cf = to_shape(&cv, &shape);
                    let af = to_shape(&av, &shape);
                    let bf = to_shape(&bv, &shape);
                    let mut o = ArrayD::<f64>::zeros(IxDyn(&shape));
                    ndarray::Zip::from(&mut o)
                        .and(&cf)
                        .and(&af)
                        .and(&bf)
                        .for_each(|s, &c, &x, &y| *s = if c != 0.0 { x } else { y });
                    RefVal::Arr(o)
                };
                slots[*out as usize] = Some(v);
            }
            Instr::Gather { src, plan, out } => {
                let plan = &prog.plans[*plan as usize];
                let sv = resolve_src(prog, &slots, &state_arrays, &obs, src);
                let v = exec_gather(plan, sv.view());
                slots[*out as usize] = Some(RefVal::Arr(v));
            }
            Instr::LoadElem { src, idx, out } => {
                let sv = resolve_src(prog, &slots, &state_arrays, &obs, src);
                let v = sv[IxDyn(&idx[..])];
                slots[*out as usize] = Some(RefVal::Scalar(v));
            }
            Instr::Ramp { axis, lo, out } => {
                let desc = &prog.slots[*out as usize];
                let a = *axis as usize;
                let lo = *lo;
                let mut arr = ArrayD::<f64>::zeros(IxDyn(&desc.shape));
                arr.indexed_iter_mut()
                    .for_each(|(idx, v)| *v = (lo + idx[a] as i64) as f64);
                slots[*out as usize] = Some(RefVal::Arr(arr));
            }
            Instr::Fill { v, out } => {
                let vv = resolve(prog, &slots, &state_arrays, &obs, params, t, v);
                let RefVal::Scalar(s) = vv else {
                    panic!("Fill with an array operand");
                };
                let desc = &prog.slots[*out as usize];
                let val = if desc.scalar {
                    RefVal::Scalar(s)
                } else {
                    RefVal::Arr(ArrayD::<f64>::from_elem(IxDyn(&desc.shape), s))
                };
                slots[*out as usize] = Some(val);
            }
            Instr::Copy { a, out } => {
                let v = resolve(prog, &slots, &state_arrays, &obs, params, t, a);
                slots[*out as usize] = Some(v);
            }
            Instr::Region {
                base,
                src,
                region,
                out,
            } => {
                let spec = &prog.regions[*region as usize];
                let Some(RefVal::Arr(basev)) = &slots[*base as usize] else {
                    panic!("Region base slot not an array");
                };
                let mut o = basev.clone();
                let sv = resolve(prog, &slots, &state_arrays, &obs, params, t, src);
                {
                    let mut sub = o.slice_each_axis_mut(|ax| {
                        let d = ax.axis.index();
                        Slice::from(spec.dest_lo[d]..spec.dest_lo[d] + spec.shape[d])
                    });
                    match &sv {
                        RefVal::Scalar(s) => sub.fill(*s),
                        RefVal::Arr(a) => {
                            assert_eq!(a.shape(), &spec.shape[..], "Region source shape");
                            sub.assign(a);
                        }
                    }
                }
                slots[*out as usize] = Some(RefVal::Arr(o));
            }
            Instr::Assemble { table, out } => {
                let desc = &prog.slots[*out as usize];
                let mut o = ArrayD::<f64>::zeros(IxDyn(&desc.shape));
                for (src, region) in &prog.assemblies[*table as usize].parts {
                    let spec = &prog.regions[*region as usize];
                    let sv = resolve(prog, &slots, &state_arrays, &obs, params, t, src);
                    let mut sub = o.slice_each_axis_mut(|ax| {
                        let d = ax.axis.index();
                        Slice::from(spec.dest_lo[d]..spec.dest_lo[d] + spec.shape[d])
                    });
                    match &sv {
                        RefVal::Scalar(s) => sub.fill(*s),
                        RefVal::Arr(a) => {
                            assert_eq!(a.shape(), &spec.shape[..], "Assemble source shape");
                            sub.assign(a);
                        }
                    }
                }
                slots[*out as usize] = Some(RefVal::Arr(o));
            }
            Instr::ConstArray { data, out } => {
                let d = &prog.const_data[*data as usize];
                let arr = ArrayD::from_shape_vec(IxDyn(&d.shape[..]), d.values.clone())
                    .expect("ConstArray payload matches its shape");
                slots[*out as usize] = Some(RefVal::Arr(arr));
            }
            Instr::LoadForcing { forcing, out } => {
                let fr = &prog.forcings[*forcing as usize];
                let mut buf = vec![0.0f64; forcing_len(fr)];
                load_forcing(
                    fr,
                    &compiled.forcing.borrow(),
                    &compiled.declared_names,
                    &mut buf,
                );
                slots[*out as usize] = Some(if fr.shape.is_empty() {
                    RefVal::Scalar(buf[0])
                } else {
                    RefVal::Arr(
                        ArrayD::from_shape_vec(IxDyn(&fr.shape[..]), buf)
                            .expect("a forcing load fills its whole box"),
                    )
                });
            }
            Instr::Interp { table, x, y, out } => {
                let tbl = &prog.interp_tables[*table as usize];
                let xv = resolve(prog, &slots, &state_arrays, &obs, params, t, x);
                // `y` is read only by `interp.bilinear`; NaN stands in for the
                // unread argument of the other two entries.
                let yv = match y {
                    Some(y) => resolve(prog, &slots, &state_arrays, &obs, params, t, y),
                    None => RefVal::Scalar(f64::NAN),
                };
                let desc = &prog.slots[*out as usize];
                let v = if desc.scalar {
                    let (RefVal::Scalar(a), RefVal::Scalar(b)) = (&xv, &yv) else {
                        panic!("scalar Interp with array operands");
                    };
                    RefVal::Scalar(tbl.at(*a, *b))
                } else {
                    let shape: Vec<usize> = desc.shape.to_vec();
                    let xf = to_shape(&xv, &shape);
                    let yf = to_shape(&yv, &shape);
                    let mut o = ArrayD::<f64>::zeros(IxDyn(&shape));
                    ndarray::Zip::from(&mut o)
                        .and(&xf)
                        .and(&yf)
                        .for_each(|s, &a, &b| *s = tbl.at(a, b));
                    RefVal::Arr(o)
                };
                slots[*out as usize] = Some(v);
            }
            Instr::Reduce {
                op,
                init,
                src,
                axes,
                src_shape,
                out,
            } => {
                let f = binary_kernel_of(*op);
                let sv = resolve_src(prog, &slots, &state_arrays, &obs, src);
                assert_eq!(sv.shape(), &src_shape[..], "Reduce source box");
                let desc = &prog.slots[*out as usize];
                let mut acc = ArrayD::<f64>::from_elem(IxDyn(&desc.shape[..]), *init);
                let keep: Vec<usize> = (0..sv.ndim())
                    .filter(|d| !axes.contains(&(*d as u8)))
                    .collect();
                // `indexed_iter` walks a standard-layout array in row-major
                // order — the order the `Instr::Reduce` contract fixes.
                let sv = if sv.is_standard_layout() {
                    sv
                } else {
                    sv.as_standard_layout().to_owned()
                };
                let mut dst_idx: Vec<usize> = vec![0; keep.len()];
                for (idx, &x) in sv.indexed_iter() {
                    for (j, &d) in keep.iter().enumerate() {
                        dst_idx[j] = idx[d];
                    }
                    let a = &mut acc[IxDyn(&dst_idx)];
                    *a = f(*a, x);
                }
                let val = if desc.scalar {
                    RefVal::Scalar(acc[IxDyn(&[])])
                } else {
                    RefVal::Arr(acc)
                };
                slots[*out as usize] = Some(val);
            }
            Instr::Scan {
                op,
                init,
                src,
                axis,
                inclusive,
                src_shape,
                out,
            } => {
                let f = binary_kernel_of(*op);
                let sv = resolve_src(prog, &slots, &state_arrays, &obs, src);
                assert_eq!(sv.shape(), &src_shape[..], "Scan source box");
                let ax = Axis(*axis as usize);
                let mut o = ArrayD::<f64>::zeros(IxDyn(&src_shape[..]));
                // One lane per position of the other axes, swept ascending —
                // `run_prefix_scan`'s loop, written out.
                for (mut ol, sl) in o.lanes_mut(ax).into_iter().zip(sv.lanes(ax)) {
                    let mut acc = *init;
                    for (y, &x) in ol.iter_mut().zip(sl.iter()) {
                        if *inclusive {
                            acc = f(acc, x);
                            *y = acc;
                        } else {
                            *y = acc;
                            acc = f(acc, x);
                        }
                    }
                }
                slots[*out as usize] = Some(RefVal::Arr(o));
            }
            Instr::PolyArea { a, b, geom, out } => {
                // Every element clipped DENSELY, with no broad phase: the
                // definition the fast executor's candidate enumeration is
                // pinned against.
                let spec = &prog.geoms[*geom as usize];
                let av = resolve_src(prog, &slots, &state_arrays, &obs, a);
                let bv = resolve_src(prog, &slots, &state_arrays, &obs, b);
                assert_eq!(av.shape(), &spec.a.src_shape[..], "PolyArea table a");
                assert_eq!(bv.shape(), &spec.b.src_shape[..], "PolyArea table b");
                let ring = |t: &ArrayD<f64>, r: &RingRef, pos: &[usize]| -> Vec<(f64, f64)> {
                    let mut view = t.view();
                    for s in &r.sel {
                        let i = match *s {
                            RingSel::Fixed(i) => i,
                            RingSel::Axis { axis, off } => {
                                (pos[axis as usize] as i64 + off) as usize
                            }
                        };
                        view = view.index_axis_move(Axis(0), i);
                    }
                    (0..view.shape()[0])
                        .map(|v| (view[IxDyn(&[v, 0])], view[IxDyn(&[v, 1])]))
                        .collect()
                };
                let desc = &prog.slots[*out as usize];
                let val = if desc.scalar {
                    let (ra, rb) = (ring(&av, &spec.a, &[]), ring(&bv, &spec.b, &[]));
                    RefVal::Scalar(clip_area_value(&ra, &rb, spec.manifold))
                } else {
                    let mut o = ArrayD::<f64>::zeros(IxDyn(&desc.shape[..]));
                    for (pos, y) in o.indexed_iter_mut() {
                        let pos = ndarray::Dimension::slice(&pos).to_vec();
                        let pos = &pos[..];
                        let (ra, rb) = (ring(&av, &spec.a, pos), ring(&bv, &spec.b, pos));
                        *y = clip_area_value(&ra, &rb, spec.manifold);
                    }
                    RefVal::Arr(o)
                };
                slots[*out as usize] = Some(val);
            }
            Instr::IndexGather {
                src,
                idx,
                spec,
                out,
            } => {
                let spec = &prog.index_gathers[*spec as usize];
                let sv = resolve_src(prog, &slots, &state_arrays, &obs, src);
                assert_eq!(sv.shape(), &spec.src_shape[..], "IndexGather source box");
                let iv = resolve(prog, &slots, &state_arrays, &obs, params, t, idx);
                let iv = to_shape(&iv, &spec.shape);
                let mut o = ArrayD::<f64>::zeros(IxDyn(&spec.shape[..]));
                let mut at: Vec<usize> = vec![0; spec.axes.len()];
                for (pos, y) in o.indexed_iter_mut() {
                    let pos = ndarray::Dimension::slice(&pos).to_vec();
                    let pos = &pos[..];
                    let mut ghost = false;
                    for (d, ax) in spec.axes.iter().enumerate() {
                        at[d] = match *ax {
                            GatherAxis::Fixed(i) => i,
                            GatherAxis::Affine { axis, off } => {
                                (pos[axis as usize] as i64 + off) as usize
                            }
                            GatherAxis::Data => match data_subscript(iv[IxDyn(pos)], sv.shape()[d])
                            {
                                Some(p) => p,
                                None => {
                                    ghost = true;
                                    0
                                }
                            },
                        };
                    }
                    *y = if ghost { 0.0 } else { sv[IxDyn(&at)] };
                }
                slots[*out as usize] = Some(RefVal::Arr(o));
            }
            Instr::TableGather { src, table, out } => {
                let sv = resolve_src(prog, &slots, &state_arrays, &obs, src);
                let tbl = &prog.gather_tables[*table as usize];
                assert_eq!(sv.shape(), &tbl.src_shape[..], "TableGather source box");
                let flat: Vec<f64> = sv.iter().copied().collect();
                let vals: Vec<f64> = tbl
                    .pos
                    .iter()
                    .map(|&p| {
                        if p == GATHER_GHOST {
                            0.0
                        } else {
                            flat[p as usize]
                        }
                    })
                    .collect();
                let n = vals.len();
                let o = ArrayD::from_shape_vec(IxDyn(&[n]), vals).expect("1-D gather box");
                slots[*out as usize] = Some(RefVal::Arr(o));
            }
            Instr::SegReduce {
                op,
                init,
                src,
                mask,
                table,
                out,
            } => {
                let f = binary_kernel_of(*op);
                let terms = match slots[*src as usize].as_ref() {
                    Some(RefVal::Arr(a)) => a.iter().copied().collect::<Vec<f64>>(),
                    other => panic!("SegReduce source is not an array slot: {other:?}"),
                };
                let keep: Option<Vec<f64>> = mask.map(|m| match slots[m as usize].as_ref() {
                    Some(RefVal::Arr(a)) => a.iter().copied().collect(),
                    other => panic!("SegReduce mask is not an array slot: {other:?}"),
                });
                let rows = &prog.seg_tables[*table as usize].rows;
                let mut cells = Vec::with_capacity(rows.len() - 1);
                for c in 0..rows.len() - 1 {
                    let mut acc = *init;
                    for k in rows[c] as usize..rows[c + 1] as usize {
                        if keep.as_ref().is_none_or(|m| m[k] != 0.0) {
                            acc = f(acc, terms[k]);
                        }
                    }
                    cells.push(acc);
                }
                let desc = &prog.slots[*out as usize];
                let val = if desc.scalar {
                    RefVal::Scalar(cells[0])
                } else {
                    RefVal::Arr(
                        ArrayD::from_shape_vec(IxDyn(&desc.shape[..]), cells)
                            .expect("SegReduce output box"),
                    )
                };
                slots[*out as usize] = Some(val);
            }
            Instr::Reshape { src, out } => {
                let sv = resolve_src(prog, &slots, &state_arrays, &obs, src);
                let desc = &prog.slots[*out as usize];
                // `iter()` is the logical row-major walk.
                let flat: Vec<f64> = sv.iter().copied().collect();
                let arr = ArrayD::from_shape_vec(IxDyn(&desc.shape[..]), flat)
                    .expect("Reshape keeps the element count");
                slots[*out as usize] = Some(RefVal::Arr(arr));
            }
            Instr::Fault { fault } => {
                crate::simulate_array::eval::latch_gather_fault(
                    prog.faults[*fault as usize].clone(),
                );
            }
            Instr::Sweep { spec } => {
                let sw = &prog.sweeps[*spec as usize];
                assert!(sweep.is_none(), "recurrence sweeps do not nest");
                if sw.n_cells() == 0 {
                    pc += 1 + sw.body_len as usize;
                    continue;
                }
                slots[sw.out as usize] = Some(RefVal::Arr(ArrayD::from_elem(
                    IxDyn(&sw.shape[..]),
                    f64::NAN,
                )));
                let cell = vec![0usize; sw.shape.len()];
                for &c in &sw.coords {
                    slots[c as usize] = Some(RefVal::Scalar(1.0));
                }
                sweep = Some((pc, cell));
            }
            Instr::ScalarRead { src, spec, out } => {
                let sp = &prog.scalar_reads[*spec as usize];
                let sv = resolve_src(prog, &slots, &state_arrays, &obs, src);
                let raw: Vec<i64> = sp
                    .subs
                    .iter()
                    .map(
                        |o| match resolve(prog, &slots, &state_arrays, &obs, params, t, o) {
                            RefVal::Scalar(x) => subscript_of(x),
                            RefVal::Arr(_) => panic!("a run-time subscript is a scalar"),
                        },
                    )
                    .collect();
                let cur = sweep.as_ref().map_or(&[][..], |(_, c)| &c[..]);
                let v = match sp.resolve(&raw, sv.shape(), &prog.sweeps, cur) {
                    ScalarReadAt::Elem(ix) => {
                        let x = sv[IxDyn(&ix)];
                        if matches!(sp.kind, ScalarReadKind::SelfRead { .. }) {
                            crate::precision::active().round(x)
                        } else {
                            x
                        }
                    }
                    ScalarReadAt::Ghost => 0.0,
                    ScalarReadAt::Fault(msg) => {
                        crate::simulate_array::eval::latch_gather_fault(msg);
                        f64::NAN
                    }
                };
                slots[*out as usize] = Some(RefVal::Scalar(v));
            }
            Instr::JmpIfZero {
                cond,
                n_true,
                n_false,
            } => {
                let cv = resolve(prog, &slots, &state_arrays, &obs, params, t, cond);
                let RefVal::Scalar(c) = cv else {
                    panic!("JmpIfZero with an array condition");
                };
                if c != 0.0 {
                    // Execute the true region, then skip the false one.
                    pending.push((pc + 1 + *n_true as usize, *n_false as usize));
                } else {
                    pc += *n_true as usize; // skip straight to the false region
                }
            }
            Instr::Fallback { rule } => {
                let info = &prog.rules[*rule as usize];
                // Both fallback arms re-enter the interpreter under the same
                // contract: no CSE memo, and an empty compiled-RHS
                // derived-extents map.
                let env = EvalEnv {
                    state_arrays: &state_arrays,
                    params,
                    param_names: &compiled.param_names,
                    t,
                    derived_rings: &derived_rings,
                    derived_extents: empty_derived_extents(),
                    forcing: &compiled.forcing,
                    cse: None,
                    const_lits: None,
                    const_arrays: &compiled.const_scope,
                    declared: &compiled.declared_names,
                };
                match info.kind {
                    RuleKind::Observed(i) => {
                        let rule = &compiled.observed_rules[i];
                        materialize_observeds_pass(
                            &mut obs,
                            std::slice::from_ref(rule),
                            &ObsPass {
                                env,
                                force_scalar: false,
                            },
                            &mut RhsStats::default(),
                        );
                    }
                    RuleKind::Rhs(i) => {
                        run_rhs_oracle(
                            &compiled.rhs_rules[i],
                            &compiled.var_shapes,
                            &env,
                            &obs,
                            dy,
                        );
                    }
                }
            }
            Instr::Export { slot, export } => {
                let name = prog.exports[*export as usize].0.clone();
                let v = slots[*slot as usize]
                    .as_ref()
                    .expect("exported slot is defined");
                let arr = match v {
                    RefVal::Scalar(s) => ArrayD::from_elem(IxDyn(&[]), *s),
                    RefVal::Arr(a) => a.clone(),
                };
                obs.insert(name, arr);
            }
            Instr::Fused { spec } => {
                // Straightforward per-element interpretation of the fused
                // micro-program (independent of the fast executor's chunked
                // strip-mining), pinning the fusion pass itself. Micro-op
                // scalar semantics come from the shared `eval_micro_op`;
                // operand access here stays bounds-checked slices, so an
                // out-of-range run offset panics instead of reading UB.
                let fs = &prog.fused[*spec as usize];
                let svals: Vec<f64> = fs
                    .scalars
                    .iter()
                    .map(
                        |op| match resolve(prog, &slots, &state_arrays, &obs, params, t, op) {
                            RefVal::Scalar(s) => s,
                            RefVal::Arr(a) if a.ndim() == 0 => a[IxDyn(&[])],
                            other => panic!("fused scalar operand is {other:?}"),
                        },
                    )
                    .collect();
                let in_arrs: Vec<ArrayD<f64>> = fs
                    .inputs
                    .iter()
                    .map(|inp| {
                        let a = resolve_src(prog, &slots, &state_arrays, &obs, &inp.src);
                        assert_eq!(a.shape(), &inp.src_shape[..], "fused input box");
                        if a.is_standard_layout() {
                            a
                        } else {
                            a.as_standard_layout().to_owned()
                        }
                    })
                    .collect();
                let flats: Vec<&[f64]> = in_arrs
                    .iter()
                    .map(|a| a.as_slice().expect("standard layout"))
                    .collect();
                let n = fs.n_elems();
                let mut regs = vec![0.0f64; fs.n_regs as usize];
                let mut outs: Vec<Vec<f64>> = fs.outputs.iter().map(|_| vec![0.0; n]).collect();
                let mut acc: Vec<f64> = fs
                    .reduce
                    .as_ref()
                    .map_or_else(Vec::new, |r| vec![r.init; r.n_inner]);
                let mut covered = 0usize;
                for run in &fs.schedule.expanded() {
                    for k in 0..run.len as usize {
                        let at = run.out_off as usize + k;
                        let get = |m: &MRef, regs: &[f64]| -> f64 {
                            match m {
                                MRef::Reg(r) => regs[*r as usize],
                                MRef::Scal(i) => svals[*i as usize],
                                MRef::In(i) => {
                                    let inp = &fs.inputs[*i as usize];
                                    match inp.shifted_ix {
                                        None => match inp.index {
                                            Some((by, n)) => {
                                                match data_subscript(flats[by as usize][at], n) {
                                                    Some(p) => flats[*i as usize][p],
                                                    None => 0.0,
                                                }
                                            }
                                            None => flats[*i as usize][at],
                                        },
                                        Some(s) => {
                                            let o = run.in_off[s as usize];
                                            if o == GHOST_OFF {
                                                0.0
                                            } else {
                                                flats[*i as usize]
                                                    [(o + k as i64 * inp.elem_stride) as usize]
                                            }
                                        }
                                    }
                                }
                            }
                        };
                        for op in &fs.micro {
                            eval_micro_op(op, &mut regs, get);
                        }
                        for (oi, &(reg, _)) in fs.outputs.iter().enumerate() {
                            outs[oi][at] = regs[reg as usize];
                        }
                        if let Some(r) = &fs.reduce {
                            let a = &mut acc[at % r.n_inner];
                            *a = binary_kernel_of(r.op)(*a, regs[r.reg as usize]);
                        }
                    }
                    covered += run.len as usize;
                }
                assert_eq!(covered, n, "run schedule tiles the box");
                if let Some(r) = &fs.reduce {
                    let desc = &prog.slots[r.out as usize];
                    slots[r.out as usize] = Some(if desc.scalar {
                        RefVal::Scalar(acc[0])
                    } else {
                        RefVal::Arr(
                            ArrayD::from_shape_vec(IxDyn(&desc.shape), acc)
                                .expect("reduction output shape"),
                        )
                    });
                }
                for (ovals, &(_, slot)) in outs.into_iter().zip(fs.outputs.iter()) {
                    let desc = &prog.slots[slot as usize];
                    let arr =
                        ArrayD::from_shape_vec(IxDyn(&desc.shape), ovals).expect("output shape");
                    slots[slot as usize] = Some(RefVal::Arr(arr));
                }
            }
            Instr::DyWrite { write } => {
                let w = &prog.dy_writes[*write as usize];
                let v = slots[w.slot as usize]
                    .as_ref()
                    .expect("dy-write slot is defined");
                match (w.scalar_flat, v) {
                    (Some(flat), RefVal::Scalar(s)) => dy[flat] = *s,
                    (Some(flat), RefVal::Arr(a)) if a.ndim() == 0 => dy[flat] = a[IxDyn(&[])],
                    (None, RefVal::Arr(a)) => {
                        let sv = &prog.state_vars[w.var as usize];
                        let vs = VarShape {
                            shape: sv.shape.to_vec(),
                            origin: sv.origin.to_vec(),
                            flat_offset: sv.flat_offset,
                        };
                        scatter_col_major_offset(a.view(), dy, &vs, &w.dest_lo);
                    }
                    other => panic!("malformed DyWrite: {other:?}"),
                }
            }
        }
        pc += 1;
    }
    RefRun { slots, obs }
}

/// Resolve an operand to an owned value.
fn resolve(
    prog: &TapeProgram,
    slots: &[Option<RefVal>],
    state_arrays: &ArrMap,
    obs: &ArrMap,
    params: &[f64],
    t: f64,
    op: &Operand,
) -> RefVal {
    match op {
        Operand::Lit(v) => RefVal::Scalar(*v),
        Operand::Param(p) => RefVal::Scalar(params[*p as usize]),
        Operand::Time => RefVal::Scalar(t),
        Operand::Slot(s) => slots[*s as usize]
            .clone()
            .unwrap_or_else(|| panic!("read of undefined slot {s}")),
        Operand::State(ix) => {
            let name = &prog.state_vars[*ix as usize].name;
            let a = state_arrays.get(name).expect("state array present");
            if a.ndim() == 0 {
                RefVal::Scalar(a[IxDyn(&[])])
            } else {
                RefVal::Arr(a.clone())
            }
        }
        Operand::Obs(ix) => {
            let name = &prog.obs_reads[*ix as usize];
            let a = obs
                .get(name)
                .unwrap_or_else(|| panic!("observed `{name}` not materialized before read"));
            if a.ndim() == 0 {
                RefVal::Scalar(a[IxDyn(&[])])
            } else {
                RefVal::Arr(a.clone())
            }
        }
    }
}

/// Resolve a gather source to an owned array.
fn resolve_src(
    prog: &TapeProgram,
    slots: &[Option<RefVal>],
    state_arrays: &ArrMap,
    obs: &ArrMap,
    src: &SrcRef,
) -> ArrayD<f64> {
    match src {
        SrcRef::Slot(s) => match &slots[*s as usize] {
            Some(RefVal::Arr(a)) => a.clone(),
            other => panic!("gather source slot {s} is {other:?}"),
        },
        SrcRef::State(ix) => state_arrays[&prog.state_vars[*ix as usize].name].clone(),
        SrcRef::Obs(ix) => obs[&prog.obs_reads[*ix as usize]].clone(),
    }
}

/// Broadcast a value to `shape` (scalar fill; array must match exactly).
fn to_shape(v: &RefVal, shape: &[usize]) -> ArrayD<f64> {
    match v {
        RefVal::Scalar(s) => ArrayD::from_elem(IxDyn(shape), *s),
        RefVal::Arr(a) => {
            assert_eq!(a.shape(), shape, "operand shape");
            a.clone()
        }
    }
}

/// Execute one precompiled gather plan — a transliteration of
/// `eval_vec_index`'s copy phase.
fn exec_gather(plan: &GatherPlan, src: ArrayViewD<'_, f64>) -> ArrayD<f64> {
    assert_eq!(src.shape(), &plan.src_shape[..], "gather source shape");
    let out_ndim = plan.shape.len();
    let mut rv = src;
    for &(d, i0) in &plan.fixed_desc {
        rv = rv.index_axis_move(Axis(d), i0);
    }
    let mut rv = rv.permuted_axes(IxDyn(&plan.perm[..]));
    for a in 0..out_ndim {
        if !plan.mapped[a] {
            rv = rv.insert_axis(Axis(a));
        }
    }
    let bshape: Vec<usize> = (0..out_ndim)
        .map(|a| {
            if plan.mapped[a] {
                rv.shape()[a]
            } else {
                plan.shape[a]
            }
        })
        .collect();
    let rvb = rv.broadcast(IxDyn(&bshape)).expect("gather broadcast");
    let mut result = ArrayD::<f64>::zeros(IxDyn(&plan.shape));
    let mut pick = vec![0usize; out_ndim];
    loop {
        {
            let mut out_view = result.slice_each_axis_mut(|ax| {
                let d = ax.axis.index();
                let (o, l, _) = plan.segs[d][pick[d]];
                Slice::from(o..o + l)
            });
            let src_sub = rvb.slice_each_axis(|ax| {
                let d = ax.axis.index();
                let (_, l, s) = plan.segs[d][pick[d]];
                Slice::from(s..s + l)
            });
            out_view.assign(&src_sub);
        }
        let mut d = 0;
        let mut done = false;
        loop {
            if d == out_ndim {
                done = true;
                break;
            }
            pick[d] += 1;
            if pick[d] < plan.segs[d].len() {
                break;
            }
            pick[d] = 0;
            d += 1;
        }
        if done {
            break;
        }
    }
    result
}

// The per-cell oracle for one fallback RHS rule lives in `super::exec`
// (`run_rhs_oracle`), shared between this reference executor and the
// production fast executor so both fallback arms are the same code. Likewise
// `eval_micro_op` is the shared single definition of micro-op scalar
// semantics.
