//! Test-only REFERENCE executor for the tape IR — a straightforward, slow,
//! allocation-happy interpreter of the program, used by the A/B tests to pin
//! the LOWERING bit-for-bit against `evaluate_rhs_with_scratch` (the full
//! production path). This is NOT the Step 3b fast executor: it ignores the
//! slab coloring entirely (per-slot owned buffers) so that a coloring bug
//! cannot mask a lowering bug, and it clones freely.

use super::super::*;
use super::exec::run_rhs_oracle;
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
        if pc >= prog.instrs.len() {
            break;
        }
        let instr = &prog.instrs[pc];
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
                let mut arr = ArrayD::<f64>::zeros(IxDyn(&desc.shape.to_vec()));
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
                    RefVal::Arr(ArrayD::<f64>::from_elem(IxDyn(&desc.shape.to_vec()), s))
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
                match info.kind {
                    RuleKind::Observed(i) => {
                        let rule = &compiled.observed_rules[i];
                        materialize_observeds_append(
                            &mut obs,
                            std::slice::from_ref(rule),
                            &state_arrays,
                            params,
                            &compiled.param_names,
                            t,
                            &derived_rings,
                            &compiled.forcing,
                            false,
                            &mut RhsStats::default(),
                            None,
                            &compiled.const_scope,
                        );
                    }
                    RuleKind::Rhs(i) => {
                        run_rhs_oracle(
                            &compiled.rhs_rules[i],
                            &compiled.var_shapes,
                            &compiled.param_names,
                            &state_arrays,
                            &obs,
                            params,
                            t,
                            &derived_rings,
                            &compiled.forcing,
                            dy,
                            &compiled.const_scope,
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
                // strip-mining), pinning the fusion pass itself.
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
                let mut covered = 0usize;
                for run in &fs.runs {
                    for k in 0..run.len as usize {
                        let at = run.out_off as usize + k;
                        let get = |m: &MRef, regs: &[f64]| -> f64 {
                            match m {
                                MRef::Reg(r) => regs[*r as usize],
                                MRef::Scal(i) => svals[*i as usize],
                                MRef::In(i) => {
                                    let inp = &fs.inputs[*i as usize];
                                    match inp.shifted_ix {
                                        None => flats[*i as usize][at],
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
                            match op {
                                MicroOp::Bin { op, a, b, out } => {
                                    regs[*out as usize] =
                                        binary_kernel_of(*op)(get(a, &regs), get(b, &regs));
                                }
                                MicroOp::Un { op, a, out } => {
                                    regs[*out as usize] = unary_kernel_of(*op)(get(a, &regs));
                                }
                                MicroOp::Neg { a, out } => {
                                    regs[*out as usize] = -get(a, &regs);
                                }
                                MicroOp::Select { cond, a, b, out } => {
                                    regs[*out as usize] = if get(cond, &regs) != 0.0 {
                                        get(a, &regs)
                                    } else {
                                        get(b, &regs)
                                    };
                                }
                                MicroOp::Mov { a, out } => {
                                    regs[*out as usize] = get(a, &regs);
                                }
                                MicroOp::Bin2 {
                                    op1,
                                    a,
                                    b,
                                    op2,
                                    c,
                                    swap,
                                    out,
                                } => {
                                    let t = binary_kernel_of(*op1)(
                                        get(a, &regs),
                                        get(b, &regs),
                                    );
                                    let cv = get(c, &regs);
                                    regs[*out as usize] = if *swap {
                                        binary_kernel_of(*op2)(cv, t)
                                    } else {
                                        binary_kernel_of(*op2)(t, cv)
                                    };
                                }
                                MicroOp::Bin3 {
                                    op1,
                                    a,
                                    b,
                                    op2,
                                    c,
                                    swap2,
                                    op3,
                                    d,
                                    swap3,
                                    out,
                                } => {
                                    let t1 = binary_kernel_of(*op1)(
                                        get(a, &regs),
                                        get(b, &regs),
                                    );
                                    let cv = get(c, &regs);
                                    let t2 = if *swap2 {
                                        binary_kernel_of(*op2)(cv, t1)
                                    } else {
                                        binary_kernel_of(*op2)(t1, cv)
                                    };
                                    let dv = get(d, &regs);
                                    regs[*out as usize] = if *swap3 {
                                        binary_kernel_of(*op3)(dv, t2)
                                    } else {
                                        binary_kernel_of(*op3)(t2, dv)
                                    };
                                }
                            }
                        }
                        for (oi, &(reg, _)) in fs.outputs.iter().enumerate() {
                            outs[oi][at] = regs[reg as usize];
                        }
                    }
                    covered += run.len as usize;
                }
                assert_eq!(covered, n, "run schedule tiles the box");
                for (ovals, &(_, slot)) in outs.into_iter().zip(fs.outputs.iter()) {
                    let desc = &prog.slots[slot as usize];
                    let arr = ArrayD::from_shape_vec(IxDyn(&desc.shape.to_vec()), ovals)
                        .expect("output shape");
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
    let mut result = ArrayD::<f64>::zeros(IxDyn(&plan.shape.to_vec()));
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
// production fast executor so both fallback arms are the same code.
