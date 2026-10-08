//! Rerolling: scalar instructions repeated with one structure become one
//! lane program.
//!
//! A document of many 0-D boxes (`scalar_chemistry`: one scalar ODE per
//! state, the same mechanism written out once per box) lowers to one scalar
//! instruction per operation per box, and the fusion pass only fuses arrays,
//! so each of those runs through the instruction loop by itself. This pass
//! works on each straight run of scalar instructions in two steps.
//!
//! First it shares repeated values: an instruction applying the same kernel
//! to the same operands as an earlier one of the run is dropped and its
//! readers read the earlier value (the equations write each reaction rate
//! once per species it changes; the lowering numbers values only within one
//! rule).
//!
//! Then it finds the repetition. The connected pieces of the run's data-flow
//! graph that have the same shape (the same operations on the same literals,
//! wired the same way) and differ only in WHICH states, parameters or slots
//! they read become the lanes of one [`Instr::Lanes`]: the shared shape is
//! its micro-program, each source that differs between lanes an input with
//! one entry per lane, and each `dy` write a write with one position per
//! lane.
//!
//! Bit identity is structural: a lane applies the kernels its scalar
//! instructions applied, in their order, to the same operand values, and a
//! shared value is the same kernel on the same operands. Nothing is a
//! reduction, so the order lanes run in reaches no result. A rerolled piece
//! defines nothing outside itself but its `dy` writes, which address distinct
//! positions (checked), so moving it after the rest of its run changes no
//! read.
//!
//! The pass runs only on straight-line code: never inside a conditional
//! region or a recurrence body (their skip counts and per-cell order are
//! fixed), and a run never spans a section boundary or a precision change.
//! A value read after its run or published keeps its own instruction, and a
//! piece holding one stays scalar.

use super::ir::*;
use rustc_hash::FxHashMap;
use smallvec::smallvec;

/// The fewest repetitions worth rerolling: below this the gathers and the
/// fused group's setup cost about what the scalar instructions do.
const MIN_LANES: usize = 4;

/// The most instructions or leaves a rerolled piece may have: every one
/// needs a register, input or scalar index of a lane program
/// ([`GroupIx`]).
const MAX_PIECE: usize = 1 << 14;

/// The fewest scalar instructions worth compiling into a one-lane block.
const MIN_BLOCK: usize = 4;

/// Encoding tags (high byte of a token).
const T_BIN: u64 = 1 << 56;
const T_UN: u64 = 2 << 56;
const T_NEG: u64 = 3 << 56;
const T_SEL: u64 = 4 << 56;
const T_FILL: u64 = 5 << 56;
const T_COPY: u64 = 6 << 56;
const T_DY: u64 = 7 << 56;
const T_INT: u64 = 8 << 56;
const T_LEAF: u64 = 9 << 56;
const T_TIME: u64 = 10 << 56;
const T_LIT: u64 = 11 << 56;

/// A source a piece reads that its own instructions do not define.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum Leaf {
    State(u32),
    Param(u32),
    Slot(SlotId),
}

impl Leaf {
    fn kind(self) -> LaneKind {
        match self {
            Leaf::State(_) => LaneKind::State,
            Leaf::Param(_) => LaneKind::Param,
            Leaf::Slot(_) => LaneKind::Slot,
        }
    }

    fn operand(self) -> Operand {
        match self {
            Leaf::State(i) => Operand::State(i),
            Leaf::Param(p) => Operand::Param(p),
            Leaf::Slot(s) => Operand::Slot(s),
        }
    }
}

/// The operands of a batchable instruction, in order (a `DyWrite` reads its
/// slot).
fn operands(ins: &Instr, prog: &TapeProgram) -> smallvec::SmallVec<[Operand; 3]> {
    match ins {
        Instr::Bin { a, b, .. } => smallvec![*a, *b],
        Instr::Un { a, .. } | Instr::Neg { a, .. } | Instr::Copy { a, .. } => smallvec![*a],
        Instr::Fill { v, .. } => smallvec![*v],
        Instr::Select { cond, a, b, .. } => smallvec![*cond, *a, *b],
        Instr::DyWrite { write } => {
            smallvec![Operand::Slot(prog.dy_writes[*write as usize].slot)]
        }
        _ => smallvec![],
    }
}

/// Whether `ins` is a scalar instruction this pass may move into a lane.
fn batchable(ins: &Instr, prog: &TapeProgram, n_defs: &[u32]) -> bool {
    let scalar_out = |out: &SlotId| {
        let d = &prog.slots[*out as usize];
        d.scalar && n_defs[*out as usize] == 1
    };
    let ok_operand = |o: &Operand| match o {
        Operand::Obs(_) => false,
        Operand::State(i) => prog.state_vars[*i as usize].shape.is_empty(),
        Operand::Slot(s) => prog.slots[*s as usize].scalar,
        Operand::Lit(_) | Operand::Param(_) | Operand::Time => true,
    };
    let shape_ok = match ins {
        Instr::Bin { out, .. }
        | Instr::Un { out, .. }
        | Instr::Neg { out, .. }
        | Instr::Select { out, .. }
        | Instr::Fill { out, .. }
        | Instr::Copy { out, .. } => scalar_out(out),
        Instr::DyWrite { write } => {
            let w = &prog.dy_writes[*write as usize];
            w.scalar_flat.is_some() && w.scatter.is_none() && prog.slots[w.slot as usize].scalar
        }
        _ => false,
    };
    shape_ok && operands(ins, prog).iter().all(ok_operand)
}

/// Rewrite every run of the program (see the module docs). Leaves a program
/// with nothing to share or reroll untouched.
pub(super) fn reroll_program(prog: &mut TapeProgram) {
    let a = Analysis::of(prog);
    let runs = a.runs(prog, 2);
    let edits: Vec<_> = runs
        .into_iter()
        .filter_map(|r| cse_run(prog, &a, r.clone()).map(|body| (r, body)))
        .collect();
    if !edits.is_empty() {
        splice(prog, edits);
    }

    let a = Analysis::of(prog);
    let runs = a.runs(prog, MIN_BLOCK);
    let ctx = Ctx {
        prog,
        def_pc: &a.def_pc,
        last_read: &a.last_read,
        exported: &a.exported,
    };
    let plans: Vec<_> = runs
        .into_iter()
        .filter_map(|r| ctx.plan_run(r.clone()).map(|p| (r, p)))
        .collect();
    if !plans.is_empty() {
        rewrite(prog, plans);
    }
}

/// Where each slot is defined and last read, and which instructions may move.
struct Analysis {
    n_defs: Vec<u32>,
    def_pc: Vec<usize>,
    last_read: Vec<usize>,
    exported: Vec<bool>,
    /// Instructions inside a conditional region or a recurrence body (or
    /// heading one): never moved.
    fixed: Vec<bool>,
}

impl Analysis {
    fn of(prog: &TapeProgram) -> Self {
        let n = prog.instrs.len();
        let n_slots = prog.slots.len();
        let tables = prog.tables();
        let mut n_defs = vec![0u32; n_slots];
        let mut def_pc = vec![usize::MAX; n_slots];
        let mut last_read = vec![0usize; n_slots];
        for (pc, ins) in prog.instrs.iter().enumerate() {
            ins.for_each_def(&tables, |s| {
                n_defs[s as usize] += 1;
                if def_pc[s as usize] == usize::MAX {
                    def_pc[s as usize] = pc;
                }
            });
            ins.for_each_read(&tables, |s| {
                last_read[s as usize] = last_read[s as usize].max(pc);
            });
        }
        let mut exported = vec![false; n_slots];
        for (_, s) in &prog.exports {
            exported[*s as usize] = true;
        }
        let mut fixed = vec![false; n];
        for (pc, ins) in prog.instrs.iter().enumerate() {
            let len = match ins {
                Instr::JmpIfZero {
                    n_true, n_false, ..
                } => (*n_true + *n_false) as usize,
                Instr::Sweep { spec } => prog.sweeps[*spec as usize].body_len as usize,
                _ => continue,
            };
            for f in &mut fixed[pc..(pc + 1 + len).min(n)] {
                *f = true;
            }
        }
        Analysis {
            n_defs,
            def_pc,
            last_read,
            exported,
            fixed,
        }
    }

    /// Maximal ranges of at least `min_len` movable batchable instructions
    /// inside one section at one precision.
    fn runs(&self, prog: &TapeProgram, min_len: usize) -> Vec<std::ops::Range<usize>> {
        let n = prog.instrs.len();
        let ok = |i: usize| !self.fixed[i] && batchable(&prog.instrs[i], prog, &self.n_defs);
        let mut runs = Vec::new();
        let mut pc = 0usize;
        while pc < n {
            if !ok(pc) {
                pc += 1;
                continue;
            }
            let start = pc;
            let sec = prog.section_of(start);
            let prec = prog.precision.get(start).copied();
            pc += 1;
            while pc < n
                && ok(pc)
                && prog.section_of(pc) == sec
                && prog.precision.get(pc).copied() == prec
            {
                pc += 1;
            }
            if pc - start >= min_len {
                runs.push(start..pc);
            }
        }
        runs
    }

    /// Whether a value defined in `run` is read after it or published.
    fn escapes(&self, s: SlotId, run: &std::ops::Range<usize>) -> bool {
        self.exported[s as usize] || self.last_read[s as usize] >= run.end
    }
}

/// An operand as two words, for the sharing key.
fn op_key(o: &Operand) -> [u64; 2] {
    match o {
        Operand::Slot(s) => [0, *s as u64],
        Operand::Lit(v) => [1, v.to_bits()],
        Operand::Param(p) => [2, *p as u64],
        Operand::Time => [3, 0],
        Operand::State(i) => [4, *i as u64],
        Operand::Obs(i) => [5, *i as u64],
    }
}

/// Share repeated pure scalar instructions within one run: an instruction
/// that applies the same kernel to the same operands as an earlier one of
/// the run computes the same bits, so its readers read the earlier value
/// instead. Operands are compared as written, never reordered, so `x * y`
/// and `y * x` stay apart. A value read after the run or published keeps
/// its own instruction. Returns the run's new instructions, or `None` when
/// nothing repeats.
///
/// The model's equations write each reaction rate once per species it
/// changes; the lowering numbers values within one rule, so this is where
/// the copies of a rate in different equations become one.
fn cse_run(
    prog: &mut TapeProgram,
    a: &Analysis,
    run: std::ops::Range<usize>,
) -> Option<Vec<(Instr, usize)>> {
    let mut rename: FxHashMap<SlotId, SlotId> = FxHashMap::default();
    let mut seen: FxHashMap<[u64; 7], SlotId> = FxHashMap::default();
    let mut body: Vec<(Instr, usize)> = Vec::with_capacity(run.len());
    let ren = |o: &mut Operand, rename: &FxHashMap<SlotId, SlotId>| {
        if let Operand::Slot(s) = o
            && let Some(&t) = rename.get(s)
        {
            *s = t;
        }
    };
    for pc in run.clone() {
        let mut ins = prog.instrs[pc].clone();
        let key: Option<([u64; 7], SlotId)> = match &mut ins {
            Instr::Bin { op, a, b, out } => {
                ren(a, &rename);
                ren(b, &rename);
                let (x, y) = (op_key(a), op_key(b));
                Some(([1, *op as u64, x[0], x[1], y[0], y[1], 0], *out))
            }
            Instr::Un { op, a, out } => {
                ren(a, &rename);
                let x = op_key(a);
                Some(([2, *op as u64, x[0], x[1], 0, 0, 0], *out))
            }
            Instr::Neg { a, out } => {
                ren(a, &rename);
                let x = op_key(a);
                Some(([3, 0, x[0], x[1], 0, 0, 0], *out))
            }
            Instr::Select { cond, a, b, out } => {
                ren(cond, &rename);
                ren(a, &rename);
                ren(b, &rename);
                let (c, x, y) = (op_key(cond), op_key(a), op_key(b));
                // `Select` has three operands; the op word carries the first.
                Some(([4 | (c[0] << 8), c[1], x[0], x[1], y[0], y[1], 0], *out))
            }
            Instr::Fill { v, .. } | Instr::Copy { a: v, .. } => {
                ren(v, &rename);
                None
            }
            Instr::DyWrite { write } => {
                let w = &mut prog.dy_writes[*write as usize];
                if let Some(&t) = rename.get(&w.slot) {
                    w.slot = t;
                }
                None
            }
            _ => unreachable!("only batchable instructions reach a run"),
        };
        if let Some((k, out)) = key {
            match seen.get(&k) {
                Some(&prev) if !a.escapes(out, &run) => {
                    rename.insert(out, prev);
                    continue;
                }
                Some(_) => {}
                None => {
                    seen.insert(k, out);
                }
            }
        }
        body.push((ins, pc));
    }
    (body.len() < run.len()).then_some(body)
}

/// The analysis inputs every run shares.
struct Ctx<'a> {
    prog: &'a TapeProgram,
    def_pc: &'a [usize],
    last_read: &'a [usize],
    exported: &'a [bool],
}

/// One piece: its instructions (program order) and the leaves it reads, in
/// first-read order.
struct Piece {
    instrs: Vec<usize>,
    leaves: Vec<Leaf>,
}

/// The rewrite of one run: the instructions that stay as they are (program
/// order) and the classes of pieces to reroll, each listed lane by lane.
struct RunPlan {
    keep: Vec<usize>,
    classes: Vec<Vec<Piece>>,
    /// Compile `keep` into consecutive one-lane blocks (see [`emit_block`]):
    /// each block's instructions (a run of `keep`) and the slots of it that
    /// are read after it. Empty: `keep` stays as it is.
    blocks: Vec<(Vec<usize>, Vec<SlotId>)>,
}

impl Ctx<'_> {
    fn plan_run(&self, run: std::ops::Range<usize>) -> Option<RunPlan> {
        let prog = self.prog;
        let len = run.len();
        let local = |s: SlotId| {
            let d = self.def_pc[s as usize];
            run.contains(&d).then(|| d - run.start)
        };
        // Distinct `dy` targets, so the pieces may be reordered.
        let mut targets: Vec<usize> = Vec::new();
        for pc in run.clone() {
            if let Instr::DyWrite { write } = &prog.instrs[pc] {
                targets.push(
                    prog.dy_writes[*write as usize]
                        .scalar_flat
                        .expect("scalar write"),
                );
            }
        }
        targets.sort_unstable();
        if targets.windows(2).any(|w| w[0] == w[1]) {
            return None;
        }
        if len < 2 * MIN_LANES {
            return self.block_plan(&run, (0..len).map(|k| run.start + k).collect(), Vec::new());
        }

        // Lane-free instructions read no state and no lane-dependent value of
        // the run; they stay where they are and are leaves to the pieces, so a
        // value every box shares does not join the boxes into one piece.
        let mut lane_free = vec![false; len];
        let mut parent: Vec<usize> = (0..len).collect();
        fn find(p: &mut [usize], mut x: usize) -> usize {
            while p[x] != x {
                p[x] = p[p[x]];
                x = p[x];
            }
            x
        }
        for k in 0..len {
            let ins = &prog.instrs[run.start + k];
            let ops = operands(ins, prog);
            let free = !matches!(ins, Instr::DyWrite { .. })
                && ops.iter().all(|o| match o {
                    Operand::State(_) => false,
                    Operand::Slot(s) => local(*s).is_none_or(|j| lane_free[j]),
                    _ => true,
                });
            lane_free[k] = free;
            if free {
                continue;
            }
            for o in &ops {
                if let Operand::Slot(s) = o
                    && let Some(j) = local(*s)
                    && !lane_free[j]
                {
                    let (a, b) = (find(&mut parent, j), find(&mut parent, k));
                    parent[a] = b;
                }
            }
        }
        // Pieces in order of their first instruction.
        let mut piece_of: FxHashMap<usize, usize> = FxHashMap::default();
        let mut pieces: Vec<Vec<usize>> = Vec::new();
        for k in 0..len {
            if lane_free[k] {
                continue;
            }
            let root = find(&mut parent, k);
            let p = *piece_of.entry(root).or_insert_with(|| {
                pieces.push(Vec::new());
                pieces.len() - 1
            });
            pieces[p].push(k);
        }

        // Encode each piece; group the ones with equal encodings.
        let mut classes: FxHashMap<Vec<u64>, Vec<usize>> = FxHashMap::default();
        let mut order: Vec<Vec<u64>> = Vec::new();
        let mut encoded: Vec<Option<Piece>> = Vec::with_capacity(pieces.len());
        for (pi, ks) in pieces.iter().enumerate() {
            match self.encode(&run, ks, &local, &lane_free) {
                Some((code, piece)) => {
                    let e = classes.entry(code.clone()).or_default();
                    if e.is_empty() {
                        order.push(code);
                    }
                    e.push(pi);
                    encoded.push(Some(piece));
                }
                None => encoded.push(None),
            }
        }
        let mut chosen = vec![false; pieces.len()];
        let mut out_classes: Vec<Vec<Piece>> = Vec::new();
        for code in &order {
            let members = &classes[code];
            if members.len() < MIN_LANES {
                continue;
            }
            let mut lanes = Vec::with_capacity(members.len());
            for &pi in members {
                chosen[pi] = true;
                lanes.push(encoded[pi].take().expect("encoded once"));
            }
            // The lanes are independent, so their order is free: order them
            // by where they write, which makes the per-lane positions of a
            // document whose states are grouped by species evenly spaced
            // (stored and walked without a table).
            lanes.sort_by_key(|p| {
                p.instrs.iter().find_map(|&pc| match &prog.instrs[pc] {
                    Instr::DyWrite { write } => prog.dy_writes[*write as usize].scalar_flat,
                    _ => None,
                })
            });
            out_classes.push(lanes);
        }
        let mut moved = vec![false; len];
        for (pi, ks) in pieces.iter().enumerate() {
            if chosen[pi] {
                for &k in ks {
                    moved[k] = true;
                }
            }
        }
        let keep = (0..len)
            .filter(|&k| !moved[k])
            .map(|k| run.start + k)
            .collect();
        self.block_plan(&run, keep, out_classes)
    }

    /// The plan for a run whose `keep` instructions stay outside every
    /// class: a block when there are enough of them, else as they are.
    fn block_plan(
        &self,
        run: &std::ops::Range<usize>,
        keep: Vec<usize>,
        classes: Vec<Vec<Piece>>,
    ) -> Option<RunPlan> {
        if keep.len() < MIN_BLOCK {
            return (!classes.is_empty()).then_some(RunPlan {
                keep,
                classes,
                blocks: Vec::new(),
            });
        }
        // A value of the block is written back when anything after the block
        // reads it: the classes (emitted after it), or the program after the
        // run.
        let prog = self.prog;
        let tables = prog.tables();
        let mut read_by_class = rustc_hash::FxHashSet::default();
        for p in classes.iter().flatten() {
            for &pc in &p.instrs {
                prog.instrs[pc].for_each_read(&tables, |s| {
                    read_by_class.insert(s);
                });
            }
        }
        // Blocks of at most `MAX_PIECE` instructions (a block indexes its
        // registers and scalars in 16 bits); a value a later block reads is
        // written back too.
        let mut blocks: Vec<(Vec<usize>, Vec<SlotId>)> = Vec::new();
        let mut read_later = read_by_class;
        for part in keep.chunks(MAX_PIECE).rev() {
            let outs = part
                .iter()
                .filter_map(|&pc| prog.instrs[pc].out())
                .filter(|s| {
                    self.exported[*s as usize]
                        || self.last_read[*s as usize] >= run.end
                        || read_later.contains(s)
                })
                .collect();
            for &pc in part {
                prog.instrs[pc].for_each_read(&tables, |s| {
                    read_later.insert(s);
                });
            }
            blocks.push((part.to_vec(), outs));
        }
        blocks.reverse();
        Some(RunPlan {
            keep,
            classes,
            blocks,
        })
    }

    /// The structural encoding of one piece, or `None` when the piece must
    /// stay scalar (a value of it is read outside the run).
    fn encode(
        &self,
        run: &std::ops::Range<usize>,
        ks: &[usize],
        local: &impl Fn(SlotId) -> Option<usize>,
        lane_free: &[bool],
    ) -> Option<(Vec<u64>, Piece)> {
        let prog = self.prog;
        let mut pos_in_piece: FxHashMap<usize, u64> = FxHashMap::default();
        let mut leaves: Vec<Leaf> = Vec::new();
        let mut leaf_ix: FxHashMap<Leaf, usize> = FxHashMap::default();
        let mut code: Vec<u64> = Vec::with_capacity(ks.len() * 4);
        for (i, &k) in ks.iter().enumerate() {
            let pc = run.start + k;
            let ins = &prog.instrs[pc];
            if let Some(out) = ins.out()
                && (self.exported[out as usize] || self.last_read[out as usize] >= run.end)
            {
                return None;
            }
            code.push(match ins {
                Instr::Bin { op, .. } => T_BIN | *op as u64,
                Instr::Un { op, .. } => T_UN | *op as u64,
                Instr::Neg { .. } => T_NEG,
                Instr::Select { .. } => T_SEL,
                Instr::Fill { .. } => T_FILL,
                Instr::Copy { .. } => T_COPY,
                Instr::DyWrite { .. } => T_DY,
                _ => unreachable!("only batchable instructions reach a piece"),
            });
            for o in operands(ins, prog) {
                let leaf = match o {
                    Operand::Lit(v) => {
                        code.push(T_LIT);
                        code.push(v.to_bits());
                        continue;
                    }
                    Operand::Time => {
                        code.push(T_TIME);
                        continue;
                    }
                    Operand::Slot(s) => match local(s) {
                        Some(j) if !lane_free[j] => {
                            code.push(T_INT | pos_in_piece[&j]);
                            continue;
                        }
                        _ => Leaf::Slot(s),
                    },
                    Operand::State(ix) => Leaf::State(ix),
                    Operand::Param(p) => Leaf::Param(p),
                    Operand::Obs(_) => unreachable!("not batchable"),
                };
                let j = *leaf_ix.entry(leaf).or_insert_with(|| {
                    leaves.push(leaf);
                    leaves.len() - 1
                });
                let kind = match leaf.kind() {
                    LaneKind::State => 0u64,
                    LaneKind::Param => 1,
                    LaneKind::Slot => 2,
                };
                code.push(T_LEAF | (kind << 32) | j as u64);
            }
            pos_in_piece.insert(k, i as u64);
        }
        // A piece that writes no derivative computes nothing anything reads;
        // one too large for a lane program's 16-bit tables stays scalar.
        let writes = ks
            .iter()
            .any(|&k| matches!(prog.instrs[run.start + k], Instr::DyWrite { .. }));
        if !writes || ks.len() >= MAX_PIECE || leaves.len() >= MAX_PIECE {
            return None;
        }
        Some((
            code,
            Piece {
                instrs: ks.iter().map(|&k| run.start + k).collect(),
                leaves,
            },
        ))
    }
}

/// Apply the run plans: each run becomes the instructions it keeps, then
/// its classes' lane instructions.
fn rewrite(prog: &mut TapeProgram, plans: Vec<(std::ops::Range<usize>, RunPlan)>) {
    let old = std::mem::take(&mut prog.instrs);
    let mut edits: Vec<(std::ops::Range<usize>, Vec<(Instr, usize)>)> = Vec::new();
    for (range, plan) in plans {
        let mut body: Vec<(Instr, usize)> = Vec::new();
        if plan.blocks.is_empty() {
            body.extend(plan.keep.iter().map(|&k| (old[k].clone(), k)));
        }
        for (pcs, outs) in &plan.blocks {
            emit_block(prog, &old, pcs, outs, &mut body);
        }
        for lanes in &plan.classes {
            emit_class(prog, &old, lanes, &mut body);
        }
        edits.push((range, body));
    }
    prog.instrs = old;
    splice(prog, edits);
}

/// Replace each (ascending, disjoint) instruction range with its new
/// instructions, each tagged with the old position whose provenance and
/// precision it takes, and recount the sections. A range never spans a
/// section boundary.
fn splice(prog: &mut TapeProgram, edits: Vec<(std::ops::Range<usize>, Vec<(Instr, usize)>)>) {
    let old = std::mem::take(&mut prog.instrs);
    let old_prov = std::mem::take(&mut prog.provenance);
    let old_prec = std::mem::take(&mut prog.precision);
    let tagged = !old_prec.is_empty();
    let n = old.len();
    let mut instrs: Vec<Instr> = Vec::with_capacity(n);
    let mut prov: Vec<u32> = Vec::with_capacity(n);
    let mut prec = Vec::with_capacity(if tagged { n } else { 0 });
    let mut counts = [0u32; 3];
    let mut edits = edits.into_iter().peekable();
    let mut old = old.into_iter().enumerate();
    while let Some((pc, ins)) = old.next() {
        // The old section counts stay in place until the end.
        let sec = prog.section_of(pc) as usize;
        let body = match edits.peek() {
            Some((range, _)) if range.start == pc => {
                let (range, body) = edits.next().expect("peeked");
                for _ in pc + 1..range.end {
                    old.next();
                }
                body
            }
            _ => vec![(ins, pc)],
        };
        for (ins, from) in body {
            instrs.push(ins);
            prov.push(old_prov[from]);
            if tagged {
                prec.push(old_prec[from]);
            }
            counts[sec] += 1;
        }
    }
    prog.instrs = instrs;
    prog.provenance = prov;
    prog.precision = prec;
    prog.n_const = counts[Cadence::Const as usize];
    prog.n_segment = counts[Cadence::Segment as usize];
}

/// Build one class's lane program and emit its instruction. Lane 0's
/// instructions are the template; each leaf the lanes all share becomes a
/// scalar operand, each other leaf an input with one source per lane.
fn emit_class(
    prog: &mut TapeProgram,
    old: &[Instr],
    lanes: &[Piece],
    out: &mut Vec<(Instr, usize)>,
) {
    let head = &lanes[0];
    let mut scalars: Vec<Operand> = Vec::new();
    let mut scal_ix: FxHashMap<[u64; 2], GroupIx> = FxHashMap::default();
    let mut scal = |o: Operand, scalars: &mut Vec<Operand>| -> MRef {
        let ix = *scal_ix.entry(op_key(&o)).or_insert_with(|| {
            scalars.push(o);
            (scalars.len() - 1) as GroupIx
        });
        MRef::Scal(ix)
    };
    let mut inputs: Vec<LaneTable> = Vec::new();
    let mut leaf_ref: Vec<MRef> = Vec::with_capacity(head.leaves.len());
    for (j, &leaf) in head.leaves.iter().enumerate() {
        if lanes.iter().all(|p| p.leaves[j] == leaf) {
            leaf_ref.push(scal(leaf.operand(), &mut scalars));
            continue;
        }
        let ix: Vec<u32> = lanes
            .iter()
            .map(|p| match p.leaves[j] {
                Leaf::State(i) => prog.state_vars[i as usize].flat_offset as u32,
                Leaf::Param(q) => q,
                Leaf::Slot(s) => s,
            })
            .collect();
        inputs.push(LaneTable {
            kind: leaf.kind(),
            ix: LaneIx::of(ix),
        });
        leaf_ref.push(MRef::In((inputs.len() - 1) as GroupIx));
    }
    let leaf_ix: FxHashMap<Leaf, usize> = head
        .leaves
        .iter()
        .enumerate()
        .map(|(j, l)| (*l, j))
        .collect();

    // The template as SSA micro-ops (op `k` defines register `k`); a
    // `Fill`/`Copy` is its operand, so it needs no op of its own.
    let mut micro: Vec<MicroOp> = Vec::new();
    let mut value: FxHashMap<SlotId, MRef> = FxHashMap::default();
    let mut writes: Vec<(MRef, LaneIx)> = Vec::new();
    for (i, &pc) in head.instrs.iter().enumerate() {
        let mut map = |o: Operand, scalars: &mut Vec<Operand>| -> MRef {
            match o {
                Operand::Lit(_) | Operand::Time => scal(o, scalars),
                Operand::Slot(s) if value.contains_key(&s) => value[&s],
                _ => leaf_ref[leaf_ix[&leaf_of(o)]],
            }
        };
        let k = micro.len() as GroupIx;
        let (op, def) = match &old[pc] {
            Instr::Bin { op, a, b, out } => {
                let (a, b) = (map(*a, &mut scalars), map(*b, &mut scalars));
                (
                    Some(MicroOp::Bin {
                        op: *op,
                        a,
                        b,
                        out: k,
                    }),
                    *out,
                )
            }
            Instr::Un { op, a, out } => {
                let a = map(*a, &mut scalars);
                (Some(MicroOp::Un { op: *op, a, out: k }), *out)
            }
            Instr::Neg { a, out } => {
                let a = map(*a, &mut scalars);
                (Some(MicroOp::Neg { a, out: k }), *out)
            }
            Instr::Select { cond, a, b, out } => {
                let cond = map(*cond, &mut scalars);
                let a = map(*a, &mut scalars);
                let b = map(*b, &mut scalars);
                (Some(MicroOp::Select { cond, a, b, out: k }), *out)
            }
            Instr::Fill { v: a, out } | Instr::Copy { a, out } => {
                let v = map(*a, &mut scalars);
                value.insert(*out, v);
                continue;
            }
            Instr::DyWrite { write } => {
                let v = map(
                    Operand::Slot(prog.dy_writes[*write as usize].slot),
                    &mut scalars,
                );
                let pos: Vec<u32> = lanes
                    .iter()
                    .map(|p| match &old[p.instrs[i]] {
                        Instr::DyWrite { write } => prog.dy_writes[*write as usize]
                            .scalar_flat
                            .expect("scalar write")
                            as u32,
                        _ => unreachable!("lanes share their structure"),
                    })
                    .collect();
                writes.push((v, LaneIx::of(pos)));
                continue;
            }
            _ => unreachable!("only batchable instructions reach a piece"),
        };
        micro.extend(op);
        value.insert(def, MRef::Reg(k));
    }

    // Registers: every written register lives to the end.
    let mut live: Vec<(GroupIx, SlotId)> = writes
        .iter()
        .filter_map(|(m, _)| match m {
            MRef::Reg(r) => Some((*r, 0)),
            _ => None,
        })
        .collect();
    let n_regs = super::fuse::allocate_registers(&mut micro, &mut live);
    let mut live = live.into_iter();
    let writes: Vec<LaneWrite> = writes
        .into_iter()
        .map(|(m, pos)| LaneWrite {
            src: match m {
                MRef::Reg(_) => MRef::Reg(live.next().expect("one per register write").0),
                other => other,
            },
            dst: LaneDst::Dy(pos),
        })
        .collect();
    let direct = direct_writes(&micro, &writes);
    let spec = prog.lanes.len() as u32;
    prog.lanes.push(LaneSpec {
        lanes: lanes.len() as u32,
        inputs,
        scalars,
        micro,
        n_regs,
        writes,
        direct,
    });
    out.push((Instr::Lanes { spec }, head.instrs[0]));
}

/// [`LaneSpec::direct`] of an allocated lane program.
fn direct_writes(micro: &[MicroOp], writes: &[LaneWrite]) -> Vec<(u32, u32)> {
    let mut direct = Vec::new();
    for (k, w) in writes.iter().enumerate() {
        let (MRef::Reg(r), LaneDst::Dy(LaneIx::Affine { step: 1, .. })) = (&w.src, &w.dst) else {
            continue;
        };
        if writes.iter().filter(|o| o.src == MRef::Reg(*r)).count() > 1 {
            continue;
        }
        let Some(at) = micro
            .iter()
            .rposition(|op| super::fuse::micro_out(op) == *r)
        else {
            continue;
        };
        if micro[at + 1..]
            .iter()
            .any(|op| super::fuse::reads_reg(op, *r))
        {
            continue;
        }
        direct.push((at as u32, k as u32));
    }
    direct
}

/// Compile the straight run `pcs` into one one-lane [`Instr::Lanes`]: every
/// operand it does not define becomes a scalar, read once per call; its
/// values live in registers; each `dy` write becomes a write and each value
/// in `outs` (read after the block) is written back to its slot.
fn emit_block(
    prog: &mut TapeProgram,
    old: &[Instr],
    pcs: &[usize],
    outs: &[SlotId],
    out: &mut Vec<(Instr, usize)>,
) {
    let mut scalars: Vec<Operand> = Vec::new();
    let mut scal_ix: FxHashMap<[u64; 2], GroupIx> = FxHashMap::default();
    let mut micro: Vec<MicroOp> = Vec::new();
    let mut value: FxHashMap<SlotId, MRef> = FxHashMap::default();
    let mut writes: Vec<(MRef, LaneDst)> = Vec::new();
    for &pc in pcs {
        let mut map = |o: Operand| -> MRef {
            if let Operand::Slot(s) = o
                && let Some(m) = value.get(&s)
            {
                return *m;
            }
            let ix = *scal_ix.entry(op_key(&o)).or_insert_with(|| {
                scalars.push(o);
                (scalars.len() - 1) as GroupIx
            });
            MRef::Scal(ix)
        };
        let k = micro.len() as GroupIx;
        let (op, def) = match &old[pc] {
            Instr::Bin { op, a, b, out } => {
                let (a, b) = (map(*a), map(*b));
                (
                    MicroOp::Bin {
                        op: *op,
                        a,
                        b,
                        out: k,
                    },
                    *out,
                )
            }
            Instr::Un { op, a, out } => (
                MicroOp::Un {
                    op: *op,
                    a: map(*a),
                    out: k,
                },
                *out,
            ),
            Instr::Neg { a, out } => (MicroOp::Neg { a: map(*a), out: k }, *out),
            Instr::Select { cond, a, b, out } => {
                let (cond, a, b) = (map(*cond), map(*a), map(*b));
                (MicroOp::Select { cond, a, b, out: k }, *out)
            }
            Instr::Fill { v: a, out } | Instr::Copy { a, out } => {
                let v = map(*a);
                value.insert(*out, v);
                continue;
            }
            Instr::DyWrite { write } => {
                let w = &prog.dy_writes[*write as usize];
                let v = map(Operand::Slot(w.slot));
                let pos = w.scalar_flat.expect("scalar write") as u32;
                writes.push((v, LaneDst::Dy(LaneIx::Affine { base: pos, step: 0 })));
                continue;
            }
            _ => unreachable!("only batchable instructions reach a block"),
        };
        micro.push(op);
        value.insert(def, MRef::Reg(k));
    }
    for &s in outs {
        writes.push((value[&s], LaneDst::Slot(s)));
    }
    let mut live: Vec<(GroupIx, SlotId)> = writes
        .iter()
        .filter_map(|(m, _)| match m {
            MRef::Reg(r) => Some((*r, 0)),
            _ => None,
        })
        .collect();
    let n_regs = super::fuse::allocate_registers(&mut micro, &mut live);
    let mut live = live.into_iter();
    let writes = writes
        .into_iter()
        .map(|(m, dst)| LaneWrite {
            src: match m {
                MRef::Reg(_) => MRef::Reg(live.next().expect("one per register write").0),
                other => other,
            },
            dst,
        })
        .collect();
    let spec = prog.lanes.len() as u32;
    prog.lanes.push(LaneSpec {
        lanes: 1,
        inputs: Vec::new(),
        scalars,
        micro,
        n_regs,
        writes,
        direct: Vec::new(),
    });
    out.push((Instr::Lanes { spec }, pcs[0]));
}

/// The leaf a non-literal operand names.
fn leaf_of(o: Operand) -> Leaf {
    match o {
        Operand::State(i) => Leaf::State(i),
        Operand::Param(p) => Leaf::Param(p),
        Operand::Slot(s) => Leaf::Slot(s),
        _ => unreachable!("not a leaf"),
    }
}
