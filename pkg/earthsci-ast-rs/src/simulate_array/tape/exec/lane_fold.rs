//! Folded lane programs: the execution form of a lane program's
//! micro-program ([`Instr::Lanes`]).
//!
//! A mechanism's lane program is almost entirely `+ - * /` chains and
//! negations: a reaction rate is a product of a rate constant and its
//! reactants, a species' tendency a left-to-right sum of signed rates. Run one
//! micro-op at a time, every link of a chain stores its chunk into the
//! register file and the next link loads it back. This module decodes the
//! micro-program, once per executor, into folds: `out = ((t0 op t1) op t2)
//! ...`, one operation for a whole chain, its terms read with their sign
//! flipped where a negation fed them. The chunk loop keeps a strip of
//! [`STRIP`] lanes' accumulators in CPU registers across the chain and stores
//! once, straight into `dy` when the fold's value is a unit-step write.
//!
//! Bit identity: a fold applies, to each lane, exactly the kernels of the
//! micro-ops it replaces in their order (`acc op t` with the accumulator on
//! the left, as each link had it). A negation is a sign flip (`-x` is
//! exactly `x` with its sign bit toggled), so applying it to a term as it
//! is read gives the bits the negation's own register held. Folding moves a
//! chain's links to where its last link was; every value is pure and every
//! term it reads is defined before, so no read changes. Only the `f64`
//! kernels are folded: under Float32 a lane program runs its micro-ops one
//! at a time (see `lanes.rs`).

use super::*;

/// The sign bit of an `f64`: a term read with `bits ^ SIGN` is negated.
const SIGN: u64 = 1 << 63;

/// Lanes a fold keeps in CPU registers at a time (eight AVX2 vectors: enough
/// independent accumulators to cover an add's latency).
pub(super) const STRIP: usize = 32;

/// The operation of a fold's chain.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub(super) enum FoldOp {
    Add = 0,
    Sub = 1,
    Mul = 2,
    Div = 3,
}

impl FoldOp {
    fn of(op: BinCode) -> Option<Self> {
        match op {
            BinCode::Add => Some(FoldOp::Add),
            BinCode::Sub => Some(FoldOp::Sub),
            BinCode::Mul => Some(FoldOp::Mul),
            BinCode::Div => Some(FoldOp::Div),
            _ => None,
        }
    }
}

/// One term of a fold: its source, read negated when `neg`.
#[derive(Clone, Copy, Debug)]
pub(super) struct Term {
    pub src: MRef,
    pub neg: bool,
}

/// Where a fold stores its value.
#[derive(Clone, Copy, Debug)]
pub(super) enum LOut {
    Reg(GroupIx),
    /// The unit-step `dy` run of `LaneSpec::writes[k]`.
    Dy(u32),
}

/// One operation of a folded lane program.
#[derive(Clone, Debug)]
pub(super) enum LOp {
    /// `out = ((t0 op t1) op t2) ...` over `LaneCode::terms[lo..hi]`. A
    /// one-term fold is a copy or a negation (`op` unused).
    Fold {
        op: FoldOp,
        terms: (u32, u32),
        out: LOut,
    },
    /// A micro-op no fold covers, on the folded program's registers.
    Other(MicroOp),
}

/// A lane program decoded into folds (see the module docs).
#[derive(Clone, Debug)]
pub(super) struct LaneCode {
    pub ops: Vec<LOp>,
    pub terms: Vec<Term>,
    pub n_regs: usize,
    /// Per `LaneSpec::writes[k]`: its source after the program, or `None`
    /// when a fold stores it directly.
    pub writes: Vec<Option<MRef>>,
    /// The program resolved for the strip loop.
    pub strips: Strips,
}

/// Elements from one strip register's start to the next: a strip plus a
/// cache line, so the registers do not fall into the same cache sets.
pub(super) const SSTRIDE: usize = STRIP + 8;

/// The vectors a strip loop addresses, by index into a call's bases (each
/// already advanced to the call's first lane where it is lane-indexed).
pub(super) const B_STATE: usize = 0;
pub(super) const B_PARAM: usize = 1;
pub(super) const B_REG: usize = 2;
pub(super) const B_SPLAT: usize = 3;
pub(super) const B_DY: usize = 4;
pub(super) const N_BASES: usize = 5;

/// A folded program resolved for the strip loop, the same for every call:
/// every operand and destination as a base and an offset.
#[derive(Clone, Debug)]
pub(super) struct Strips {
    pub sops: Vec<SOp>,
    pub tptr: Vec<TPtr>,
    /// Per input, where its lanes are read (a unit-step state or parameter
    /// run in place, else its strip register, filled every strip).
    pub inputs: Vec<TPtr>,
    pub gathered: Vec<u32>,
    /// Lanes from a call's first lane up to which each in-place vector is
    /// read, or stored (`dy`): a call checks them against its vectors once.
    pub ends: [usize; N_BASES],
    /// `f64`s of strip registers: the program's, then one per input.
    pub reg_elems: usize,
    /// The most common base, modulo a cache line's 8 `f64`s, of the
    /// unit-step `dy` runs (`None`: no such run): split cuts are placed so
    /// those runs' share boundaries fall on cache-line boundaries.
    #[cfg_attr(target_arch = "wasm32", allow(dead_code))]
    pub dy_phase: Option<usize>,
}

/// Visit every operand of a lane micro-op.
fn operands_mut(op: &mut MicroOp, mut f: impl FnMut(&mut MRef)) {
    match op {
        MicroOp::Bin { a, b, .. } => {
            f(a);
            f(b);
        }
        MicroOp::Un { a, .. } | MicroOp::Neg { a, .. } | MicroOp::Mov { a, .. } => f(a),
        MicroOp::Select { cond, a, b, .. } => {
            f(cond);
            f(a);
            f(b);
        }
        MicroOp::Bin2 { .. } | MicroOp::Bin3 { .. } | MicroOp::Scan { .. } => {
            unreachable!("a lane program holds no superops or scans")
        }
    }
}

fn out_mut(op: &mut MicroOp) -> &mut GroupIx {
    match op {
        MicroOp::Bin { out, .. }
        | MicroOp::Un { out, .. }
        | MicroOp::Neg { out, .. }
        | MicroOp::Mov { out, .. }
        | MicroOp::Select { out, .. }
        | MicroOp::Bin2 { out, .. }
        | MicroOp::Bin3 { out, .. }
        | MicroOp::Scan { out, .. } => out,
    }
}

/// A value of the program under decoding (indexed by its micro-op).
enum Node {
    /// `op` is `None` for a one-term copy or negation, which folds into
    /// any chain.
    Fold {
        op: Option<FoldOp>,
        terms: Vec<Term>,
    },
    Other(MicroOp),
    /// Folded into a later value, or never read.
    Dead,
}

/// Decode a lane program (see the module docs). `None` for a program too
/// large for SSA numbering in a [`GroupIx`].
pub(super) fn decode(ls: &LaneSpec) -> Option<LaneCode> {
    let n = ls.micro.len();
    if n >= GroupIx::MAX as usize {
        return None;
    }
    // SSA: value k is micro-op k's result.
    let mut cur = vec![GroupIx::MAX; ls.n_regs as usize];
    let ssa_ref = |m: &mut MRef, cur: &[GroupIx]| {
        if let MRef::Reg(r) = m {
            *r = cur[*r as usize];
        }
    };
    let mut ssa: Vec<MicroOp> = Vec::with_capacity(n);
    for (k, op) in ls.micro.iter().enumerate() {
        let mut op = op.clone();
        operands_mut(&mut op, |m| ssa_ref(m, &cur));
        let o = out_mut(&mut op);
        cur[*o as usize] = k as GroupIx;
        *o = k as GroupIx;
        ssa.push(op);
    }
    let wsrc: Vec<MRef> = ls
        .writes
        .iter()
        .map(|w| {
            let mut m = w.src;
            ssa_ref(&mut m, &cur);
            m
        })
        .collect();
    let mut uses = vec![0u32; n];
    for op in &mut ssa {
        operands_mut(op, |m| {
            if let MRef::Reg(r) = m {
                uses[*r as usize] += 1;
            }
        });
    }
    for m in &wsrc {
        if let MRef::Reg(r) = m {
            uses[*r as usize] += 1;
        }
    }

    // Fold the chains, in program order.
    let mut nodes: Vec<Node> = Vec::with_capacity(n);
    for op in &ssa {
        let node = match op {
            MicroOp::Neg { a, .. } => Node::Fold {
                op: None,
                terms: vec![term(*a, true, &mut nodes, &mut uses)],
            },
            MicroOp::Mov { a, .. } => Node::Fold {
                op: None,
                terms: vec![term(*a, false, &mut nodes, &mut uses)],
            },
            MicroOp::Bin { op, a, b, .. } if FoldOp::of(*op).is_some() => {
                let f = FoldOp::of(*op);
                let mut terms = match *a {
                    MRef::Reg(t)
                        if uses[t as usize] == 1
                            && matches!(&nodes[t as usize],
                                Node::Fold { op: o, .. } if o.is_none() || *o == f) =>
                    {
                        let Node::Fold { terms, .. } =
                            std::mem::replace(&mut nodes[t as usize], Node::Dead)
                        else {
                            unreachable!()
                        };
                        uses[t as usize] = 0;
                        terms
                    }
                    a => vec![term(a, false, &mut nodes, &mut uses)],
                };
                terms.push(term(*b, false, &mut nodes, &mut uses));
                Node::Fold { op: f, terms }
            }
            other => Node::Other(other.clone()),
        };
        nodes.push(node);
    }

    // A fold read only by a unit-step write stores into `dy`.
    let mut direct: Vec<Option<u32>> = vec![None; n];
    let mut writes: Vec<Option<MRef>> = Vec::with_capacity(wsrc.len());
    for (k, (w, src)) in ls.writes.iter().zip(&wsrc).enumerate() {
        if let MRef::Reg(v) = *src
            && uses[v as usize] == 1
            && matches!(nodes[v as usize], Node::Fold { .. })
            && matches!(w.dst, LaneDst::Dy(LaneIx::Affine { step: 1, .. }))
        {
            direct[v as usize] = Some(k as u32);
            writes.push(None);
        } else {
            writes.push(Some(*src));
        }
    }

    // Registers: linear scan over the surviving values in program order; a
    // value's register is taken before its dying operands' are freed, so it
    // never aliases one of them.
    let order: Vec<usize> = (0..n)
        .filter(|&k| uses[k] > 0 && !matches!(nodes[k], Node::Dead))
        .collect();
    let mut last = vec![0usize; n];
    for (p, &k) in order.iter().enumerate() {
        reads(&mut nodes[k], &mut |m| {
            if let MRef::Reg(v) = m {
                last[*v as usize] = p;
            }
        });
    }
    for m in writes.iter().flatten() {
        if let MRef::Reg(v) = m {
            last[*v as usize] = usize::MAX;
        }
    }
    let mut phys = vec![GroupIx::MAX; n];
    let mut free: Vec<GroupIx> = Vec::new();
    let mut n_regs: usize = 0;
    let mut code = LaneCode {
        ops: Vec::with_capacity(order.len()),
        terms: Vec::new(),
        n_regs: 0,
        writes: Vec::new(),
        strips: Strips {
            sops: Vec::new(),
            tptr: Vec::new(),
            inputs: Vec::new(),
            gathered: Vec::new(),
            ends: [0; N_BASES],
            reg_elems: 0,
            dy_phase: None,
        },
    };
    for (p, &k) in order.iter().enumerate() {
        let out = match direct[k] {
            Some(w) => LOut::Dy(w),
            None => {
                let r = free.pop().unwrap_or_else(|| {
                    n_regs += 1;
                    (n_regs - 1) as GroupIx
                });
                phys[k] = r;
                LOut::Reg(r)
            }
        };
        let mut dying: smallvec::SmallVec<[GroupIx; 4]> = smallvec::SmallVec::new();
        reads(&mut nodes[k], &mut |m| {
            if let MRef::Reg(v) = m {
                let v0 = *v as usize;
                *v = phys[v0];
                if last[v0] == p && !dying.contains(v) {
                    dying.push(*v);
                }
            }
        });
        free.extend(dying);
        match std::mem::replace(&mut nodes[k], Node::Dead) {
            Node::Fold { op, terms } => {
                let lo = code.terms.len() as u32;
                code.terms.extend(terms);
                code.ops.push(LOp::Fold {
                    op: op.unwrap_or(FoldOp::Add),
                    terms: (lo, code.terms.len() as u32),
                    out,
                });
            }
            Node::Other(mut op) => {
                let LOut::Reg(r) = out else {
                    unreachable!("only a fold stores into dy")
                };
                *out_mut(&mut op) = r;
                code.ops.push(LOp::Other(op));
            }
            Node::Dead => unreachable!("dead values are not ordered"),
        }
    }
    code.writes = writes
        .into_iter()
        .map(|m| {
            m.map(|m| match m {
                MRef::Reg(v) => MRef::Reg(phys[v as usize]),
                other => other,
            })
        })
        .collect();
    code.n_regs = n_regs;
    code.strips = strips_of(ls, &code);
    Some(code)
}

/// Resolve `code` for the strip loop (see [`Strips`]).
fn strips_of(ls: &LaneSpec, code: &LaneCode) -> Strips {
    let n_regs = code.n_regs;
    let lanes = ls.lanes as usize;
    let mut ends = [0usize; N_BASES];
    let mut gathered = Vec::new();
    let inputs: Vec<TPtr> = ls
        .inputs
        .iter()
        .enumerate()
        .map(|(i, inp)| match (inp.kind, &inp.ix) {
            (LaneKind::State | LaneKind::Param, LaneIx::Affine { base, step: 1 }) => {
                let b = if inp.kind == LaneKind::State {
                    B_STATE
                } else {
                    B_PARAM
                };
                ends[b] = ends[b].max(*base as usize + lanes);
                TPtr::at(b, *base as usize, false, true)
            }
            _ => {
                gathered.push(i as u32);
                TPtr::at(B_REG, (n_regs + i) * SSTRIDE, false, false)
            }
        })
        .collect();
    let tptr = code
        .terms
        .iter()
        .map(|t| match t.src {
            MRef::Reg(r) => TPtr::at(B_REG, r as usize * SSTRIDE, t.neg, false),
            MRef::In(i) => inputs[i as usize].negated(t.neg),
            MRef::Scal(s) => TPtr::at(B_SPLAT, s as usize * STRIP, t.neg, false),
        })
        .collect();
    let sops = code
        .ops
        .iter()
        .enumerate()
        .map(|(k, op)| match op {
            LOp::Fold { op, terms, out } => match out {
                LOut::Reg(r) => SOp::fold(*op, *terms, B_REG, *r as usize * SSTRIDE, false),
                LOut::Dy(w) => {
                    let LaneDst::Dy(LaneIx::Affine { base, .. }) = &ls.writes[*w as usize].dst
                    else {
                        unreachable!("a fold stores into a unit-step dy run")
                    };
                    ends[B_DY] = ends[B_DY].max(*base as usize + lanes);
                    SOp::fold(*op, *terms, B_DY, *base as usize, true)
                }
            },
            LOp::Other(m) => SOp {
                n: k as u32,
                off: super::super::fuse::micro_out(m) as usize * SSTRIDE,
                ..SOp::NULL
            },
        })
        .collect();
    let mut phases = [0usize; 8];
    for w in &ls.writes {
        if let LaneDst::Dy(LaneIx::Affine { base, step: 1 }) = w.dst {
            phases[base as usize % 8] += 1;
        }
    }
    let dy_phase = (0..8)
        .max_by_key(|&p| (phases[p], std::cmp::Reverse(p)))
        .filter(|&p| phases[p] > 0);
    Strips {
        dy_phase,
        sops,
        tptr,
        inputs,
        gathered,
        ends,
        reg_elems: (n_regs + ls.inputs.len()) * SSTRIDE,
    }
}

/// Visit every value `node` reads.
fn reads(node: &mut Node, f: &mut dyn FnMut(&mut MRef)) {
    match node {
        Node::Fold { terms, .. } => terms.iter_mut().for_each(|t| f(&mut t.src)),
        Node::Other(op) => operands_mut(op, f),
        Node::Dead => {}
    }
}

/// The term that reads `m` (negated when `neg`): a copy or negation of
/// another value is read through, its own value then losing that reader.
fn term(m: MRef, neg: bool, nodes: &mut [Node], uses: &mut [u32]) -> Term {
    if let MRef::Reg(t) = m
        && let Node::Fold { op: None, terms } = &nodes[t as usize]
        && let [inner] = terms[..]
    {
        let t = t as usize;
        uses[t] -= 1;
        if uses[t] == 0 {
            nodes[t] = Node::Dead;
        } else if let MRef::Reg(s) = inner.src {
            uses[s as usize] += 1;
        }
        return Term {
            src: inner.src,
            neg: inner.neg ^ neg,
        };
    }
    Term { src: m, neg }
}

/// A fold term (or an input's lanes) resolved for the strip loop: at strip
/// offset `off` its lanes are `bases[base][self.off + (off & adv)..]`, the
/// next [`STRIP`] of them, each with its bits XORed with `neg`. `adv` is
/// all ones for a state or parameter run read in place (the strip moves
/// along it) and 0 for a strip register or a scalar's splat (the same strip
/// every time).
#[derive(Clone, Copy, Debug)]
pub(super) struct TPtr {
    pub off: usize,
    pub neg: u64,
    pub adv: usize,
    pub base: usize,
}

impl TPtr {
    fn at(base: usize, off: usize, neg: bool, moves: bool) -> Self {
        TPtr {
            off,
            neg: if neg { SIGN } else { 0 },
            adv: if moves { usize::MAX } else { 0 },
            base,
        }
    }

    /// The same lanes, negated when `neg`.
    fn negated(self, neg: bool) -> Self {
        TPtr {
            neg: if neg { SIGN } else { 0 },
            ..self
        }
    }

    /// Where its strip at offset `off` starts.
    #[inline(always)]
    pub(super) fn ptr(&self, bases: &[*mut f64; N_BASES], off: usize) -> *const f64 {
        bases[self.base].wrapping_add(self.off + (off & self.adv))
    }
}

/// [`SOp::kind`] of a micro-op that is not a fold.
pub(super) const OTHER: u8 = 4;

/// One operation of the strip loop: a fold of `n` terms from `t` (`kind`
/// its [`FoldOp`]), or ([`OTHER`]) the micro-op `LaneCode::ops[n]`. Its
/// value goes to `bases[base][off + (o & dadv)..]` at strip offset `o`: a
/// strip register (`dadv` 0) or the fold's run of `dy` (all ones).
#[derive(Clone, Copy, Debug)]
pub(super) struct SOp {
    pub kind: u8,
    pub n: u32,
    pub t: u32,
    pub base: usize,
    pub off: usize,
    pub dadv: usize,
}

impl SOp {
    const NULL: SOp = SOp {
        kind: OTHER,
        n: 0,
        t: 0,
        base: B_REG,
        off: 0,
        dadv: 0,
    };

    fn fold(op: FoldOp, terms: (u32, u32), base: usize, off: usize, moves: bool) -> Self {
        SOp {
            kind: op as u8,
            n: terms.1 - terms.0,
            t: terms.0,
            base,
            off,
            dadv: if moves { usize::MAX } else { 0 },
        }
    }

    /// Where its strip at offset `o` is stored.
    #[inline(always)]
    pub(super) fn dst(&self, bases: &[*mut f64; N_BASES], o: usize) -> *mut f64 {
        bases[self.base].wrapping_add(self.off + (o & self.dadv))
    }
}

/// One strip of an `N`-term fold. The terms are read exactly once each, in
/// order; `acc` lives in CPU registers.
#[inline(always)]
unsafe fn strip_n<const N: usize>(
    o: &SOp,
    t: &[TPtr],
    b: &[*mut f64; N_BASES],
    off: usize,
    dst: *mut f64,
    f: impl Fn(f64, f64) -> f64 + Copy,
) {
    let t: &[TPtr; N] = t[o.t as usize..][..N].try_into().expect("N terms");
    unsafe { strip_terms(t, b, off, dst, f) }
}

#[inline(always)]
unsafe fn strip_terms(
    t: &[TPtr],
    b: &[*mut f64; N_BASES],
    off: usize,
    dst: *mut f64,
    f: impl Fn(f64, f64) -> f64 + Copy,
) {
    let (t0, rest) = t.split_first().expect("a fold has a term");
    let mut acc = [0.0f64; STRIP];
    // SAFETY (every read below): the caller checked that each term's strip
    // lies in its vector (see `Strips::ends`).
    let p0 = t0.ptr(b, off);
    for (k, a) in acc.iter_mut().enumerate() {
        *a = f64::from_bits(unsafe { *p0.add(k) }.to_bits() ^ t0.neg);
    }
    for tj in rest {
        let p = tj.ptr(b, off);
        for (k, a) in acc.iter_mut().enumerate() {
            *a = f(*a, f64::from_bits(unsafe { *p.add(k) }.to_bits() ^ tj.neg));
        }
    }
    // SAFETY: `dst` is a strip register or the fold's own `dy` run, disjoint
    // from every term.
    unsafe { std::ptr::copy_nonoverlapping(acc.as_ptr(), dst, STRIP) };
}

/// One strip (lanes `off .. off + STRIP` of the call) of the fold `o`,
/// stored to `dst`.
#[inline(always)]
pub(super) unsafe fn strip_fold(
    o: &SOp,
    t: &[TPtr],
    b: &[*mut f64; N_BASES],
    off: usize,
    dst: *mut f64,
) {
    macro_rules! by_n {
        ($f:expr) => {
            unsafe {
                match o.n {
                    1 => strip_n::<1>(o, t, b, off, dst, $f),
                    2 => strip_n::<2>(o, t, b, off, dst, $f),
                    3 => strip_n::<3>(o, t, b, off, dst, $f),
                    4 => strip_n::<4>(o, t, b, off, dst, $f),
                    n => strip_terms(&t[o.t as usize..][..n as usize], b, off, dst, $f),
                }
            }
        };
    }
    match o.kind {
        0 => by_n!(|x, y| x + y),
        1 => by_n!(|x, y| x - y),
        2 => by_n!(|x, y| x * y),
        _ => by_n!(|x, y| x / y),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(base: u32) -> LaneTable {
        LaneTable {
            kind: LaneKind::State,
            ix: LaneIx::Affine { base, step: 1 },
        }
    }

    /// `r = k * a * b` read by two writes, one of them through `-r + c + r`:
    /// the product is one fold kept in a register, the negation is read
    /// through, and the sum is one fold stored straight into its `dy` run.
    #[test]
    fn decode_folds_chains_and_negations() {
        let bin = |op, a, b, out| MicroOp::Bin { op, a, b, out };
        let ls = LaneSpec {
            lanes: 64,
            inputs: vec![input(0), input(64), input(128)],
            scalars: vec![Operand::Param(0)],
            micro: vec![
                bin(BinCode::Mul, MRef::Scal(0), MRef::In(0), 0),
                bin(BinCode::Mul, MRef::Reg(0), MRef::In(1), 1),
                MicroOp::Neg {
                    a: MRef::Reg(1),
                    out: 2,
                },
                bin(BinCode::Add, MRef::Reg(2), MRef::In(2), 3),
                bin(BinCode::Add, MRef::Reg(3), MRef::Reg(1), 4),
            ],
            n_regs: 5,
            writes: vec![
                LaneWrite {
                    src: MRef::Reg(4),
                    dst: LaneDst::Dy(LaneIx::Affine { base: 0, step: 1 }),
                },
                LaneWrite {
                    src: MRef::Reg(1),
                    dst: LaneDst::Dy(LaneIx::Affine { base: 64, step: 1 }),
                },
            ],
            direct: Vec::new(),
        };
        let code = decode(&ls).expect("decodes");
        assert_eq!(code.ops.len(), 2, "{:?}", code.ops);
        let LOp::Fold {
            op: FoldOp::Mul,
            terms: (0, 3),
            out: LOut::Reg(r),
        } = code.ops[0]
        else {
            panic!("{:?}", code.ops[0])
        };
        assert!(matches!(
            code.ops[1],
            LOp::Fold {
                op: FoldOp::Add,
                terms: (3, 6),
                out: LOut::Dy(0)
            }
        ));
        let negs: Vec<bool> = code.terms.iter().map(|t| t.neg).collect();
        assert_eq!(negs, [false, false, false, true, false, false]);
        assert_eq!(code.terms[3].src, MRef::Reg(r));
        assert_eq!(code.terms[5].src, MRef::Reg(r));
        assert!(code.writes[0].is_none());
        assert_eq!(code.writes[1], Some(MRef::Reg(r)));
        assert_eq!(code.n_regs, 1);
        assert_eq!(code.strips.sops.len(), 2);
        assert_eq!(code.strips.ends[B_STATE], 128 + 64);
        assert_eq!(code.strips.ends[B_DY], 64);
    }

    /// A chain with its accumulator on the right is two folds: `a + t` is
    /// not `t + a` for every pair of NaN operands.
    #[test]
    fn decode_keeps_operand_order() {
        let ls = LaneSpec {
            lanes: 64,
            inputs: vec![input(0), input(64)],
            scalars: Vec::new(),
            micro: vec![
                MicroOp::Bin {
                    op: BinCode::Add,
                    a: MRef::In(0),
                    b: MRef::In(1),
                    out: 0,
                },
                MicroOp::Bin {
                    op: BinCode::Add,
                    a: MRef::In(0),
                    b: MRef::Reg(0),
                    out: 1,
                },
            ],
            n_regs: 2,
            writes: vec![LaneWrite {
                src: MRef::Reg(1),
                dst: LaneDst::Dy(LaneIx::Affine { base: 0, step: 1 }),
            }],
            direct: Vec::new(),
        };
        let code = decode(&ls).expect("decodes");
        assert_eq!(code.ops.len(), 2, "{:?}", code.ops);
        assert_eq!(code.terms.len(), 4);
    }
}
