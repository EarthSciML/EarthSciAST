//! Bit-identity tests for the `#[target_feature]` SIMD clones of the fused
//! chunk executor. Test-only, and separate from `fused` because the fixture
//! (a `FusedSpec` exercising every micro-op kind) is larger than the
//! executor it drives.

// ---------------------------------------------------------------------------
// Step 4b: SIMD-clone bit-identity tests. The `#[target_feature]` clones are
// the SAME Rust source under wider codegen; these tests pin that claim on
// adversarial inputs (NaNs, signed zeros, denormals, infinities, extreme
// magnitudes) across chunk boundaries, ghost runs and strided pre-loads. Any
// bit difference outside the documented NaN-payload latitude means the
// widened codegen reassociated or contracted something, and that clone must
// be rejected.
// ---------------------------------------------------------------------------

use super::fused::{
    FCHUNK, RunCursor, Window, dispatch_bin_kernel, dispatch_un_kernel, exec_fused_runs_generic,
    node_elems,
};
#[cfg(target_arch = "x86_64")]
use super::fused::{exec_fused_runs_avx2, exec_fused_runs_avx512};
use super::*;

/// Adversarial + pseudorandom input of length `n`, seeded.
///
/// NOTE on NaNs (`with_nan`): when BOTH operands of a commutative op are
/// NaNs with different payloads, x86 propagates whichever payload lands
/// in the first source slot — and LLVM (whose semantics leave NaN
/// payloads nondeterministic) may commute operands differently per
/// codegen width, so such cases legitimately differ between
/// equally-correct clones without any reassociation. Measured here
/// twice: a payload qNaN input trips it directly, and even a canonical
/// qNaN input trips it in chains, when `inf - inf` GENERATES the
/// negative hardware qNaN (fff8…) that then meets the positive input
/// NaN (7ff8…). Therefore the strict byte-equality set excludes NaN
/// inputs (all NaNs are then hardware-GENERATED — 0/0, inf-inf, 0*inf —
/// which yield the identical fff8… at every width, keeping both-NaN
/// cases deterministic), and a second set adds NaN inputs with NaN
/// results compared by class (non-NaN results stay byte-strict).
fn adversarial(n: usize, seed: u64, with_nan: bool) -> Vec<f64> {
    let specials = [
        if with_nan { f64::NAN } else { -7.25 },
        1.5e-310, // denormal
        0.0,
        -0.0,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::MIN_POSITIVE, // smallest normal
        5e-324,            // smallest denormal
        -5e-324,
        2.2e-308, // denormal
        f64::MAX,
        f64::MIN,
        1.0,
        -1.0,
        1.5,
        -2.5,
        1e308,
        -1e308,
        3.5e-320, // denormal
        0.1,
    ];
    let mut x = seed.wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(1);
    (0..n)
        .map(|k| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            if k % 3 == 0 {
                specials[(x as usize) % specials.len()]
            } else {
                // Mix magnitudes; keep bit-level variety.
                let u = (x >> 11) as f64 / (1u64 << 53) as f64;
                (u - 0.5) * 10f64.powi((x % 61) as i32 - 30)
            }
        })
        .collect()
}

/// Build a `FusedSpec` + inputs exercising every micro-op kind, run it
/// through every available SIMD clone, and assert byte-identical outputs
/// (NaN results compared by class when `with_nan` — see `adversarial`).
fn drive(with_nan: bool) {
    const N: usize = 2500; // chunk boundaries at 1024, 2048 + short tail
    let a = adversarial(N, 1, with_nan);
    let b = adversarial(N, 2, with_nan);
    let shifted = adversarial(N + 16, 3, with_nan);
    let strided = adversarial(2 * N + 8, 4, with_nan);
    let svals = [
        if with_nan { f64::NAN } else { 3.75 },
        -0.0,
        2.5,
        5e-324,
        f64::INFINITY,
    ];

    let inputs = vec![
        // 0, 1: aligned reads.
        FusedInput {
            src: SrcRef::Slot(0),
            shifted_ix: None,
            src_shape: DimU::from_elem(N, 1),
            elem_stride: 1,
            load_reg: GroupIx::MAX,
            index: None,
            gather: None,
        },
        FusedInput {
            src: SrcRef::Slot(1),
            shifted_ix: None,
            src_shape: DimU::from_elem(N, 1),
            elem_stride: 1,
            load_reg: GroupIx::MAX,
            index: None,
            gather: None,
        },
        // 2: shifted stride-1 read (ghost over the last run).
        FusedInput {
            src: SrcRef::Slot(2),
            shifted_ix: Some(0),
            src_shape: DimU::from_elem(N + 16, 1),
            elem_stride: 1,
            load_reg: GroupIx::MAX,
            index: None,
            gather: None,
        },
        // 3: strided (elem_stride 2) read through a pre-load register.
        FusedInput {
            src: SrcRef::Slot(3),
            shifted_ix: Some(1),
            src_shape: DimU::from_elem(2 * N + 8, 1),
            elem_stride: 2,
            load_reg: GroupIx::MAX, // patched below once n_regs is known
            index: None,
            gather: None,
        },
    ];

    // Micro program: every Bin code, every monomorphized Un code, Neg,
    // Selects (register / input / scalar conds), Mov, and every Bin2
    // combo in both swap orientations, with operand kinds mixed.
    let mut micro: Vec<MicroOp> = Vec::new();
    let bins = [
        BinCode::Add,
        BinCode::Sub,
        BinCode::Mul,
        BinCode::Div,
        BinCode::Pow,
        BinCode::Min,
        BinCode::Max,
        BinCode::Eq,
        BinCode::Ne,
        BinCode::Lt,
        BinCode::Le,
        BinCode::Gt,
        BinCode::Ge,
    ];
    for (i, op) in bins.iter().enumerate() {
        let (a, b) = match i % 4 {
            0 => (MRef::In(0), MRef::In(1)),
            1 => (MRef::In(2), MRef::In(0)),
            2 => (MRef::Scal(i as GroupIx % 5), MRef::In(3)),
            _ => (MRef::In(1), MRef::Scal((i as GroupIx + 2) % 5)),
        };
        let out = micro.len() as GroupIx;
        micro.push(MicroOp::Bin { op: *op, a, b, out });
    }
    let uns = [
        UnCode::Abs,
        UnCode::Sqrt,
        UnCode::Exp,
        UnCode::Ln,
        UnCode::Log10,
        UnCode::Sin,
        UnCode::Cos,
        UnCode::Tanh,
        UnCode::Floor,
        UnCode::Ceil,
        UnCode::Sign,
    ];
    for (i, op) in uns.iter().enumerate() {
        let a = match i % 3 {
            0 => MRef::In(0),
            1 => MRef::In(2),
            _ => MRef::Reg(i as GroupIx), // an earlier Bin result
        };
        let out = micro.len() as GroupIx;
        micro.push(MicroOp::Un { op: *op, a, out });
    }
    let out = micro.len() as GroupIx;
    micro.push(MicroOp::Neg {
        a: MRef::In(3),
        out,
    });
    let out = micro.len() as GroupIx;
    micro.push(MicroOp::Select {
        cond: MRef::Reg(9), // an Lt mask
        a: MRef::In(0),
        b: MRef::In(1),
        out,
    });
    let out = micro.len() as GroupIx;
    micro.push(MicroOp::Select {
        cond: MRef::In(2),
        a: MRef::Reg(0),
        b: MRef::Scal(1),
        out,
    });
    let out = micro.len() as GroupIx;
    micro.push(MicroOp::Select {
        cond: MRef::Scal(2),
        a: MRef::In(1),
        b: MRef::In(0),
        out,
    });
    let out = micro.len() as GroupIx;
    micro.push(MicroOp::Mov {
        a: MRef::In(3),
        out,
    });
    let arith = [BinCode::Add, BinCode::Sub, BinCode::Mul, BinCode::Div];
    for op1 in arith {
        for op2 in arith {
            for swap in [false, true] {
                let out = micro.len() as GroupIx;
                micro.push(MicroOp::Bin2 {
                    op1,
                    a: MRef::In(0),
                    b: MRef::In(1),
                    op2,
                    c: MRef::In(2),
                    swap,
                    out,
                });
            }
        }
    }
    // Extended Bin2 pairs (`bin2_pair_ok` beyond the arith square).
    let ext = [
        (BinCode::Mul, BinCode::Gt),
        (BinCode::Mul, BinCode::Ge),
        (BinCode::Mul, BinCode::Lt),
        (BinCode::Mul, BinCode::Le),
        (BinCode::Min, BinCode::Max),
        (BinCode::Max, BinCode::Min),
        (BinCode::Mul, BinCode::Min),
        (BinCode::Min, BinCode::Mul),
        (BinCode::Mul, BinCode::Max),
        (BinCode::Max, BinCode::Mul),
    ];
    for (i, (op1, op2)) in ext.iter().enumerate() {
        for swap in [false, true] {
            let out = micro.len() as GroupIx;
            micro.push(MicroOp::Bin2 {
                op1: *op1,
                a: MRef::In(1),
                b: MRef::In(2),
                op2: *op2,
                c: if i % 2 == 0 {
                    MRef::In(0)
                } else {
                    MRef::Scal(i as GroupIx % 5)
                },
                swap,
                out,
            });
        }
    }
    // Bin3: the full arith cube in all four swap orientations, cycling
    // operand kinds through aligned / shifted (incl. ghost) / strided /
    // splat-scalar / register sources.
    let mut pat = 0usize;
    for op1 in arith {
        for op2 in arith {
            for op3 in arith {
                for (swap2, swap3) in [(false, false), (true, false), (false, true), (true, true)] {
                    let (a, b, c, d) = match pat % 4 {
                        0 => (MRef::In(0), MRef::In(1), MRef::In(2), MRef::In(3)),
                        1 => (MRef::In(2), MRef::Scal(0), MRef::In(0), MRef::Scal(3)),
                        2 => (MRef::Scal(2), MRef::In(3), MRef::Scal(1), MRef::In(1)),
                        _ => (MRef::In(1), MRef::In(0), MRef::Reg(0), MRef::In(2)),
                    };
                    pat += 1;
                    let out = micro.len() as GroupIx;
                    micro.push(MicroOp::Bin3 {
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
                    });
                }
            }
        }
    }
    let n_ops = micro.len();
    let n_regs = n_ops as GroupIx;
    let mut inputs = inputs;
    inputs[3].load_reg = n_regs; // one strided pre-load register

    // Runs: [0, 1300) shifted-src offset 5, as a 650-element run repeated
    // twice (so the clones walk a repetition too); [1300, N) ghost for the
    // stride-1 shifted input. The strided input stays live in both.
    let schedule = RunSchedule {
        nodes: vec![
            RunNode::Repeat {
                count: 2,
                body: 1,
                out_step: 650,
                in_step: SmallVec::from_slice(&[650, 2 * 650]),
            },
            RunNode::Run(FusedRun {
                out_off: 0,
                len: 650,
                in_off: SmallVec::from_slice(&[5i64, 3]),
            }),
            RunNode::Run(FusedRun {
                out_off: 1300,
                len: (N - 1300) as u32,
                in_off: SmallVec::from_slice(&[GHOST_OFF, 3 + 2 * 1300]),
            }),
        ],
        n_runs: 3,
        depth: 1,
    };
    let fs = FusedSpec {
        shape: DimU::from_elem(N, 1),
        inputs,
        scalars: Vec::new(), // svals are passed directly
        micro,
        n_regs,
        n_load_regs: 1,
        n_splat_regs: 6,          // 5 scalars + the zero register
        outputs: SmallVec::new(), // outs are passed directly
        direct: SmallVec::new(),
        scan_fuse: SmallVec::new(),
        schedule,
        reduce: None,
        interleave: None,
        n_fused_instrs: 0,
        n_folded_gathers: 0,
    };

    let bases: Vec<*const f64> = vec![a.as_ptr(), b.as_ptr(), shifted.as_ptr(), strided.as_ptr()];
    let ne = node_elems(&fs.schedule.nodes);
    // Runs the group as the given `(lo, hi, period)` windows, in order (the
    // whole group when `windows` is `[(0, usize::MAX, 0)]`), into fresh
    // output buffers.
    let run_windows = |wider: u8, windows: &[(usize, usize, usize)]| -> Vec<Vec<f64>> {
        let mut outbufs: Vec<Vec<f64>> = (0..n_ops).map(|_| vec![0.0f64; N]).collect();
        let outs: Vec<(GroupIx, *mut f64)> = outbufs
            .iter_mut()
            .enumerate()
            .map(|(i, buf)| (i as GroupIx, buf.as_mut_ptr()))
            .collect();
        let mut fregs = vec![0.0f64; (n_regs as usize + 1 + 6) * FCHUNK];
        let mut cursor = RunCursor::for_spec(&fs);
        for &(lo, hi, period) in windows {
            let win = Window {
                lo,
                hi,
                period,
                node_elems: &ne,
            };
            match wider {
                0 => unsafe {
                    exec_fused_runs_generic(
                        &fs,
                        &svals,
                        &bases,
                        &outs,
                        std::ptr::null_mut(),
                        &[],
                        &mut fregs,
                        &mut cursor,
                        win,
                    )
                },
                #[cfg(target_arch = "x86_64")]
                1 => unsafe {
                    exec_fused_runs_avx2(
                        &fs,
                        &svals,
                        &bases,
                        &outs,
                        std::ptr::null_mut(),
                        &[],
                        &mut fregs,
                        &mut cursor,
                        win,
                    )
                },
                #[cfg(target_arch = "x86_64")]
                2 => unsafe {
                    exec_fused_runs_avx512(
                        &fs,
                        &svals,
                        &bases,
                        &outs,
                        std::ptr::null_mut(),
                        &[],
                        &mut fregs,
                        &mut cursor,
                        win,
                    )
                },
                _ => panic!("level unavailable in this build"),
            }
        }
        outbufs
    };
    let run_level = |wider: u8| run_windows(wider, &[(0, usize::MAX, 0)]);

    // Every wider clone this host can run is compared bit-for-bit against the
    // generic executor. Non-x86 targets build only the generic path, so there
    // the test checks just that it runs.
    let reference = run_level(0);
    // A threaded call runs the group as disjoint windows on separate
    // workers. Windows that cut through a repetition, a run, a chunk and the
    // ghost run must reproduce the whole-group result exactly.
    for cuts in [
        &[0usize, 8, 650, 1024, 1296, 1304, 2048, N][..],
        &[0, 1, 649, 651, 1299, 1301, N - 1, N],
        &[0, 640, 1952, N],
    ] {
        let windows: Vec<(usize, usize, usize)> =
            cuts.windows(2).map(|w| (w[0], w[1], 0)).collect();
        assert_bits_eq(&reference, &run_windows(0, &windows), "windows", with_nan);
        // Out of order, as workers may finish in any order.
        let rev: Vec<(usize, usize, usize)> = windows.iter().rev().copied().collect();
        assert_bits_eq(
            &reference,
            &run_windows(0, &rev),
            "windows reversed",
            with_nan,
        );
    }
    // Periodic windows (an absorbed reduction's inner positions), cutting
    // the period at unaligned places too.
    for (period, cuts) in [
        (650usize, &[0usize, 8, 333, 650][..]),
        (1000, &[0, 1, 999, 1000]),
        (N, &[0, 1300, N]),
    ] {
        let windows: Vec<(usize, usize, usize)> =
            cuts.windows(2).map(|w| (w[0], w[1], period)).collect();
        assert_bits_eq(&reference, &run_windows(0, &windows), "periodic", with_nan);
    }
    #[cfg(target_arch = "x86_64")]
    {
        if std::arch::is_x86_feature_detected!("avx2") {
            let got = run_level(1);
            assert_bits_eq(&reference, &got, "avx2", with_nan);
        }
        if std::arch::is_x86_feature_detected!("avx512f")
            && std::arch::is_x86_feature_detected!("avx512vl")
            && std::arch::is_x86_feature_detected!("avx512dq")
            && std::arch::is_x86_feature_detected!("avx512bw")
        {
            let got = run_level(2);
            assert_bits_eq(&reference, &got, "avx512", with_nan);
        }
    }
    #[cfg(not(target_arch = "x86_64"))]
    let _ = reference;
}

/// Strict byte equality: NaN-free adversarial inputs (±inf, ±0,
/// denormals, extremes); every NaN in the pipeline is hardware-generated
/// and identical at every width, so results must match to the bit.
#[test]
fn simd_clone_bit_identity() {
    drive(false);
}

/// NaN-bearing inputs: non-NaN results byte-strict; NaN results
/// class-compared (payload latitude under commutation, see
/// `adversarial`).
#[test]
fn simd_clone_bit_identity_nan_inputs() {
    drive(true);
}

fn assert_bits_eq(want: &[Vec<f64>], got: &[Vec<f64>], label: &str, nan_class: bool) {
    for (op, (w, g)) in want.iter().zip(got.iter()).enumerate() {
        for (k, (a, b)) in w.iter().zip(g.iter()).enumerate() {
            if nan_class && a.is_nan() && b.is_nan() {
                continue;
            }
            assert_eq!(
                a.to_bits(),
                b.to_bits(),
                "{label}: micro-op {op} elem {k}: generic {a:?} ({:016x}) vs {label} {b:?} ({:016x})",
                a.to_bits(),
                b.to_bits()
            );
        }
    }
}

/// Every arm of the kernel dispatch macros computes the same bits as the
/// shared kernel table it stands in for, over every operator code.
#[test]
fn dispatch_arms_match_the_kernel_tables() {
    use {BinCode as B, UnCode as U};
    const XS: &[f64] = &[
        0.0,
        -0.0,
        1.0,
        -1.0,
        0.5,
        -3.25,
        2.0,
        0.999,
        1.5,
        f64::MIN_POSITIVE,
        5e-324,
        1e300,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NAN,
    ];
    let bins = [
        B::Add,
        B::Sub,
        B::Mul,
        B::Div,
        B::Pow,
        B::Atan2,
        B::Min,
        B::Max,
        B::Eq,
        B::Ne,
        B::Lt,
        B::Le,
        B::Gt,
        B::Ge,
        B::And,
        B::Or,
        B::Unknown,
    ];
    let uns = [
        U::Exp,
        U::Ln,
        U::Log10,
        U::Sqrt,
        U::Abs,
        U::Sign,
        U::Floor,
        U::Ceil,
        U::Sin,
        U::Cos,
        U::Tan,
        U::Asin,
        U::Acos,
        U::Atan,
        U::Sinh,
        U::Cosh,
        U::Tanh,
        U::Asinh,
        U::Acosh,
        U::Atanh,
        U::Not,
        U::Unknown,
    ];
    for op in bins {
        for &x in XS {
            for &y in XS {
                macro_rules! k {
                    ($f:expr) => {{
                        let f = $f;
                        f(x, y)
                    }};
                }
                let got: f64 = dispatch_bin_kernel!(&op, k);
                let want = binary_kernel_of(op)(x, y);
                assert_eq!(got.to_bits(), want.to_bits(), "{op:?}({x:?}, {y:?})");
            }
        }
    }
    for op in uns {
        for &x in XS {
            macro_rules! k {
                ($f:expr) => {{
                    let f = $f;
                    f(x)
                }};
            }
            let got: f64 = dispatch_un_kernel!(&op, k);
            let want = unary_kernel_of(op)(x);
            assert_eq!(got.to_bits(), want.to_bits(), "{op:?}({x:?})");
        }
    }
}
