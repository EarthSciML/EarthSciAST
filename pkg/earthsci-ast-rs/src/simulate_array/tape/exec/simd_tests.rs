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

use super::fused::{FCHUNK, exec_fused_runs_generic};
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
            load_reg: u16::MAX,
        },
        FusedInput {
            src: SrcRef::Slot(1),
            shifted_ix: None,
            src_shape: DimU::from_elem(N, 1),
            elem_stride: 1,
            load_reg: u16::MAX,
        },
        // 2: shifted stride-1 read (ghost over the last run).
        FusedInput {
            src: SrcRef::Slot(2),
            shifted_ix: Some(0),
            src_shape: DimU::from_elem(N + 16, 1),
            elem_stride: 1,
            load_reg: u16::MAX,
        },
        // 3: strided (elem_stride 2) read through a pre-load register.
        FusedInput {
            src: SrcRef::Slot(3),
            shifted_ix: Some(1),
            src_shape: DimU::from_elem(2 * N + 8, 1),
            elem_stride: 2,
            load_reg: u16::MAX, // patched below once n_regs is known
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
            2 => (MRef::Scal(i as u16 % 5), MRef::In(3)),
            _ => (MRef::In(1), MRef::Scal((i as u16 + 2) % 5)),
        };
        let out = micro.len() as u16;
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
            _ => MRef::Reg(i as u16), // an earlier Bin result
        };
        let out = micro.len() as u16;
        micro.push(MicroOp::Un { op: *op, a, out });
    }
    let out = micro.len() as u16;
    micro.push(MicroOp::Neg {
        a: MRef::In(3),
        out,
    });
    let out = micro.len() as u16;
    micro.push(MicroOp::Select {
        cond: MRef::Reg(9), // an Lt mask
        a: MRef::In(0),
        b: MRef::In(1),
        out,
    });
    let out = micro.len() as u16;
    micro.push(MicroOp::Select {
        cond: MRef::In(2),
        a: MRef::Reg(0),
        b: MRef::Scal(1),
        out,
    });
    let out = micro.len() as u16;
    micro.push(MicroOp::Select {
        cond: MRef::Scal(2),
        a: MRef::In(1),
        b: MRef::In(0),
        out,
    });
    let out = micro.len() as u16;
    micro.push(MicroOp::Mov {
        a: MRef::In(3),
        out,
    });
    let arith = [BinCode::Add, BinCode::Sub, BinCode::Mul, BinCode::Div];
    for op1 in arith {
        for op2 in arith {
            for swap in [false, true] {
                let out = micro.len() as u16;
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
            let out = micro.len() as u16;
            micro.push(MicroOp::Bin2 {
                op1: *op1,
                a: MRef::In(1),
                b: MRef::In(2),
                op2: *op2,
                c: if i % 2 == 0 {
                    MRef::In(0)
                } else {
                    MRef::Scal(i as u16 % 5)
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
                    let out = micro.len() as u16;
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
    let n_regs = n_ops as u16;
    let mut inputs = inputs;
    inputs[3].load_reg = n_regs; // one strided pre-load register

    // Runs: [0, 1300) shifted-src offset 5; [1300, N) ghost for the
    // stride-1 shifted input. The strided input stays live in both.
    let runs = vec![
        FusedRun {
            out_off: 0,
            len: 1300,
            in_off: SmallVec::from_slice(&[5i64, 3]),
        },
        FusedRun {
            out_off: 1300,
            len: (N - 1300) as u32,
            in_off: SmallVec::from_slice(&[GHOST_OFF, 3 + 2 * 1300]),
        },
    ];
    let fs = FusedSpec {
        shape: DimU::from_elem(N, 1),
        inputs,
        scalars: Vec::new(), // svals are passed directly
        micro,
        n_regs,
        n_load_regs: 1,
        n_splat_regs: 6,          // 5 scalars + the zero register
        outputs: SmallVec::new(), // outs are passed directly
        runs,
        n_fused_instrs: 0,
        n_folded_gathers: 0,
    };

    let bases: Vec<*const f64> = vec![a.as_ptr(), b.as_ptr(), shifted.as_ptr(), strided.as_ptr()];
    let run_level = |wider: u8| -> Vec<Vec<f64>> {
        let mut outbufs: Vec<Vec<f64>> = (0..n_ops).map(|_| vec![0.0f64; N]).collect();
        let outs: Vec<(u16, *mut f64)> = outbufs
            .iter_mut()
            .enumerate()
            .map(|(i, buf)| (i as u16, buf.as_mut_ptr()))
            .collect();
        let mut fregs = vec![0.0f64; (n_regs as usize + 1 + 6) * FCHUNK];
        match wider {
            0 => unsafe { exec_fused_runs_generic(&fs, &svals, &bases, &outs, &mut fregs) },
            #[cfg(target_arch = "x86_64")]
            1 => unsafe { exec_fused_runs_avx2(&fs, &svals, &bases, &outs, &mut fregs) },
            #[cfg(target_arch = "x86_64")]
            2 => unsafe { exec_fused_runs_avx512(&fs, &svals, &bases, &outs, &mut fregs) },
            _ => panic!("level unavailable in this build"),
        }
        outbufs
    };

    let reference = run_level(0);
    let mut levels_checked = 0;
    #[cfg(target_arch = "x86_64")]
    {
        if std::arch::is_x86_feature_detected!("avx2") {
            let got = run_level(1);
            assert_bits_eq(&reference, &got, "avx2", with_nan);
            levels_checked += 1;
        }
        if std::arch::is_x86_feature_detected!("avx512f")
            && std::arch::is_x86_feature_detected!("avx512vl")
            && std::arch::is_x86_feature_detected!("avx512dq")
            && std::arch::is_x86_feature_detected!("avx512bw")
        {
            let got = run_level(2);
            assert_bits_eq(&reference, &got, "avx512", with_nan);
            levels_checked += 1;
        }
    }
    // On non-x86 hosts there is nothing to compare against — the test
    // degenerates to "the generic path runs" (levels_checked = 0).
    let _ = levels_checked;
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
