//! Step 5 (phase 2): emit the tape IR as an **XLA computation**.
//!
//! This is the Rust half of the compiled-backend plan
//! (`tests/conformance/compiled_rhs/README.md`). It walks a [`TapeProgram`]
//! once and builds, through the `xla` crate's `XlaBuilder`, a single program
//!
//! ```text
//! rhs(u: f64[N], p: f64[M], t: f64[]) -> du: f64[N]
//! ```
//!
//! that reproduces what [`super::exec`] / `super::refexec` compute for the
//! same inputs — numerically, within the tier's tolerance classes, never bit
//! for bit (XLA's `exp`/`log`/`pow` are not Rust's libm).
//!
//! ## Hard error, never a fallback
//!
//! A model carrying ANY instruction this emitter cannot lower — a
//! [`Instr::Fallback`] rule above all, which by definition wants the
//! interpreter back — is a **compile error** naming the rule and the reason
//! ([`XlaEmitError`]). There is no mixed execution and no interpreter arm: the
//! adapter turns the error into the tier's `refused` outcome and moves on to
//! the next fixture. This is the ruling of 2026-09-13 made mechanical.
//!
//! ## Layout conventions this file has to honour
//!
//! * **A slot's array value is ROW-MAJOR over `SlotDesc::shape`**, the same
//!   convention `refexec`'s `ArrayD` values use. Scalars are rank-0.
//! * **The flat state vector `u` is COLUMN-MAJOR per variable block**, while
//!   the tape reads state arrays row-major (that is exactly what the fast
//!   executor's `state_rm` mirror is for). So an [`Operand::State`] is
//!   `u[off..off+n]` reshaped to the REVERSED shape and transposed — the
//!   column-major-to-row-major relabelling, which costs nothing in XLA.
//! * **`dy` is column-major per variable block** for the same reason, so the
//!   root does the inverse transpose per variable and concatenates the blocks
//!   in `flat_offset` order.
//!
//! ## Cadence
//!
//! CONST, SEGMENT and CONTINUOUS are all emitted into the ONE program, in
//! program order. That recomputes the parameter-invariant prefix on every
//! call, which the slab executor hoists. Hoisting it here — emitting the
//! CONST/SEGMENT prefix as a separate computation whose outputs are extra
//! parameters of the continuous one, or letting XLA constant-fold it behind a
//! donated buffer — is a later optimization, deliberately not done in this
//! phase: it changes nothing about the numbers and everything about the
//! amount of machinery under test.
//!
//! ## Fusion
//!
//! The emitter is built over the UNFUSED tape: [`emit_rhs`] calls
//! `build_tape_opts(.., None)`, so [`Instr::Fused`] never reaches the match.
//! A fused group is a scalar micro-program over a register file — precisely
//! the shape XLA's own fusion wants to choose for itself.
//!
//! ## When the tape grows
//!
//! The instruction match ends in a catch-all arm that REFUSES with a message
//! saying the tape grew and this emitter has to follow. New instruction kinds
//! (array constants, carried observed shapes, rank-0 reductions) therefore
//! surface as named refusals rather than as wrong numbers. That arm is where
//! they plug in.

use super::super::{ArrayCompiled, BinCode, UnCode, VarShape};
use super::ir::*;
use std::collections::HashMap;
use std::fmt;
use xla::{ArrayElement, ElementType, PrimitiveType, XlaBuilder, XlaComputation, XlaOp};

/// A model the emitter refuses to lower.
///
/// `rule` names the tape rule (or the pseudo-rule `<program>` for a
/// whole-program property) and `reason` says what could not be lowered. The
/// conformance adapter copies both straight into the tier's `refused` entry,
/// which is why they are separate fields rather than one message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct XlaEmitError {
    /// The rule whose lowering failed, or `<program>`.
    pub rule: String,
    /// Why it could not be lowered.
    pub reason: String,
}

impl XlaEmitError {
    pub fn new(rule: impl Into<String>, reason: impl Into<String>) -> Self {
        XlaEmitError {
            rule: rule.into(),
            reason: reason.into(),
        }
    }
}

impl fmt::Display for XlaEmitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "rule {}: {}", self.rule, self.reason)
    }
}

impl std::error::Error for XlaEmitError {}

/// A lowered right-hand side: the computation plus the shapes its caller has
/// to feed it.
pub struct EmittedRhs {
    computation: XlaComputation,
    n_states: usize,
    params_len: usize,
    n_instrs: usize,
}

impl EmittedRhs {
    /// The `rhs(u, p, t) -> du` computation.
    pub fn computation(&self) -> &XlaComputation {
        &self.computation
    }
    /// Length of the flat state vector `u` and of the result `du`.
    pub fn n_states(&self) -> usize {
        self.n_states
    }
    /// Length of the `p` buffer the compiled program expects, which is
    /// `max(tape params, 1)`: a model with no parameters still gets a
    /// one-element dummy, because a zero-element PJRT buffer is an awkward
    /// thing to build on every call for no gain. A caller with fewer values
    /// than this zero-fills the rest (`CompiledRhs::eval` does).
    pub fn params_len(&self) -> usize {
        self.params_len
    }
    /// Tape instruction count that was lowered (diagnostics only).
    pub fn n_instrs(&self) -> usize {
        self.n_instrs
    }
    /// HLO text of the computation, for a debug dump. NEVER a gate: the tier
    /// compares numbers, never programs.
    pub fn hlo_text(&self) -> Result<String, XlaEmitError> {
        self.computation
            .proto()
            .to_string()
            .map_err(|e| XlaEmitError::new("<program>", format!("HLO dump failed: {e}")))
    }
}

/// Build this model's tape (fusion OFF) and emit it as an XLA computation.
///
/// The single entry point outside this module. Everything the emitter needs
/// beyond the tape — the flat state layout, the parameter count, the working
/// precision — it reads off `compiled`.
pub fn emit_rhs(compiled: &ArrayCompiled) -> Result<EmittedRhs, XlaEmitError> {
    // Evaluate under the model's own captured precision, exactly as
    // `debug_eval_rhs` does: the tape lowering consults it.
    let _guard = compiled.precision.enter();
    if compiled.precision.is_f32() {
        return Err(XlaEmitError::new(
            "<program>",
            "document working precision is Float32; this emitter lowers the \
             Float64 kernel tables only (the tier's precision-changing \
             fixtures are excluded, CONFORMANCE_SPEC §5.38.4)",
        ));
    }
    if crate::precision::has_variable_overrides() {
        return Err(XlaEmitError::new(
            "<program>",
            "document carries per-variable element types (esm-spec §11.3.1); \
             the tape itself is disabled for such documents",
        ));
    }
    // `None` = the fusion pass off. The emitter is defined over the unfused
    // instruction set; see the module docs.
    let (prog, _report) = compiled.build_tape_opts(&std::collections::HashSet::new(), None);
    emit_program(&prog, compiled)
}

/// Emit an already-built program. Split out so a test can drive a program it
/// built itself.
pub(crate) fn emit_program(
    prog: &TapeProgram,
    compiled: &ArrayCompiled,
) -> Result<EmittedRhs, XlaEmitError> {
    let builder = XlaBuilder::new("earthsci_rhs");
    let mut em = Emitter::new(&builder, prog, compiled)?;
    let du = em.run()?;
    let computation = du
        .build()
        .map_err(|e| XlaEmitError::new("<program>", format!("XlaBuilder::build failed: {e}")))?;
    Ok(EmittedRhs {
        computation,
        n_states: compiled.n_states,
        // The DECLARED buffer length, which is what a caller has to feed:
        // `Emitter::new` widens a zero-parameter model to `f64[1]`.
        params_len: prog.params_len.max(1),
        n_instrs: prog.instrs.len(),
    })
}

// ---------------------------------------------------------------------------
// The emitter.
// ---------------------------------------------------------------------------

type R<T> = Result<T, XlaEmitError>;

struct Emitter<'a> {
    b: &'a XlaBuilder,
    prog: &'a TapeProgram,
    /// `u`, `p`, `t` parameters.
    u: XlaOp,
    p: XlaOp,
    t: XlaOp,
    /// Per-slot SSA value; `None` until the defining instruction is emitted.
    slots: Vec<Option<XlaOp>>,
    /// Per `prog.state_vars` index: the state array as the tape reads it
    /// (row-major over its shape; rank 0 for a 0-d variable).
    state: Vec<XlaOp>,
    /// Observed values published by [`Instr::Export`], keyed by name — the
    /// only channel an [`Operand::Obs`] can resolve through here.
    obs: HashMap<String, XlaOp>,
    /// `dy` accumulator, one ROW-MAJOR block per state variable, in
    /// `var_order`. `None` = nothing written yet (stays zero).
    blocks: Vec<Option<XlaOp>>,
    /// State variables ordered by `flat_offset`, with their layout.
    var_order: Vec<(String, VarShape)>,
    /// Variable name → index into `var_order` / `blocks`.
    var_ix: HashMap<String, usize>,
    /// Rule name attached to whatever instruction is being lowered, for the
    /// error's `rule` field.
    cur_rule: String,
}

impl<'a> Emitter<'a> {
    fn new(b: &'a XlaBuilder, prog: &'a TapeProgram, compiled: &'a ArrayCompiled) -> R<Self> {
        let n_states = compiled.n_states;
        let pm = prog.params_len.max(1);
        let u = b
            .parameter(0, f64::TY, &[n_states as i64], "u")
            .map_err(|e| XlaEmitError::new("<program>", format!("parameter u: {e}")))?;
        let p = b
            .parameter(1, f64::TY, &[pm as i64], "p")
            .map_err(|e| XlaEmitError::new("<program>", format!("parameter p: {e}")))?;
        let t = b
            .parameter(2, f64::TY, &[], "t")
            .map_err(|e| XlaEmitError::new("<program>", format!("parameter t: {e}")))?;

        // The flat layout is the model's, not the tape's: a variable the tape
        // never touches still owns its slice of `du`.
        let mut var_order: Vec<(String, VarShape)> = compiled
            .var_shapes
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        var_order.sort_by_key(|(_, v)| v.flat_offset);
        let mut next = 0usize;
        for (name, vs) in &var_order {
            if vs.flat_offset != next {
                return Err(XlaEmitError::new(
                    "<program>",
                    format!(
                        "flat state layout is not contiguous: variable {name} starts at \
                         {} but {next} was expected",
                        vs.flat_offset
                    ),
                ));
            }
            next += vs.shape.iter().product::<usize>().max(1);
        }
        if next != n_states {
            return Err(XlaEmitError::new(
                "<program>",
                format!("flat state layout covers {next} slots but the model declares {n_states}"),
            ));
        }
        let var_ix: HashMap<String, usize> = var_order
            .iter()
            .enumerate()
            .map(|(i, (n, _))| (n.clone(), i))
            .collect();

        let mut em = Emitter {
            b,
            prog,
            u,
            p,
            t,
            slots: vec![None; prog.slots.len()],
            state: Vec::new(),
            obs: HashMap::new(),
            blocks: vec![None; var_order.len()],
            var_order,
            var_ix,
            cur_rule: "<program>".to_string(),
        };
        em.state = em.build_state_views()?;
        Ok(em)
    }

    /// One view per `prog.state_vars` entry: the variable's block of `u`,
    /// relabelled from column-major to row-major (see the module docs).
    fn build_state_views(&self) -> R<Vec<XlaOp>> {
        let mut out = Vec::with_capacity(self.prog.state_vars.len());
        for sv in &self.prog.state_vars {
            let off = sv.flat_offset as i64;
            let n: usize = sv.shape.iter().product::<usize>().max(1);
            let flat = self
                .u
                .slice_in_dim(off, off + n as i64, 1, 0)
                .map_err(|e| self.err(format!("state slice for {}: {e}", sv.name)))?;
            let op = if sv.shape.is_empty() {
                flat.reshape(&[])
                    .map_err(|e| self.err(format!("state reshape for {}: {e}", sv.name)))?
            } else {
                let rev: Vec<i64> = sv.shape.iter().rev().map(|&d| d as i64).collect();
                let perm: Vec<i64> = (0..sv.shape.len() as i64).rev().collect();
                flat.reshape(&rev)
                    .and_then(|a| a.transpose(&perm))
                    .map_err(|e| self.err(format!("state relabel for {}: {e}", sv.name)))?
            };
            out.push(op);
        }
        Ok(out)
    }

    fn err(&self, reason: impl Into<String>) -> XlaEmitError {
        XlaEmitError::new(self.cur_rule.clone(), reason)
    }

    /// Lower the whole program and return the root `du`.
    fn run(&mut self) -> R<XlaOp> {
        self.emit_range(0, self.prog.instrs.len())?;
        self.assemble_du()
    }

    // -- small builder helpers ---------------------------------------------

    fn dims(&self, op: &XlaOp) -> R<Vec<usize>> {
        op.dims().map_err(|e| self.err(format!("dims: {e}")))
    }

    fn c(&self, v: f64) -> R<XlaOp> {
        self.b.c0(v).map_err(|e| self.err(format!("constant: {e}")))
    }

    fn ci(&self, v: i64) -> R<XlaOp> {
        self.b
            .c0(v)
            .map_err(|e| self.err(format!("s64 constant: {e}")))
    }

    fn zeros(&self, dims: &[usize]) -> R<XlaOp> {
        let z = self.c(0.0)?;
        if dims.is_empty() {
            return Ok(z);
        }
        let d: Vec<i64> = dims.iter().map(|&x| x as i64).collect();
        z.broadcast(&d).map_err(|e| self.err(format!("zeros: {e}")))
    }

    /// A scalar constant with `like`'s shape (so every binary op below has two
    /// operands of exactly the same shape and never leans on XLA's implicit
    /// rank-0 broadcast).
    fn splat_like(&self, like: &XlaOp, v: f64) -> R<XlaOp> {
        let d = self.dims(like)?;
        let c = self.c(v)?;
        if d.is_empty() {
            return Ok(c);
        }
        let d: Vec<i64> = d.iter().map(|&x| x as i64).collect();
        c.broadcast(&d).map_err(|e| self.err(format!("splat: {e}")))
    }

    /// Broadcast a rank-0 value to `dims`; pass anything else through after
    /// checking it already has that shape.
    fn to_shape(&self, op: &XlaOp, dims: &[usize]) -> R<XlaOp> {
        let have = self.dims(op)?;
        if have == dims {
            return Ok(op.clone());
        }
        if have.is_empty() {
            let d: Vec<i64> = dims.iter().map(|&x| x as i64).collect();
            return op
                .broadcast(&d)
                .map_err(|e| self.err(format!("broadcast to {dims:?}: {e}")));
        }
        Err(self.err(format!(
            "operand shape {have:?} does not match the instruction's box {dims:?}"
        )))
    }

    fn pred_to_f64(&self, op: XlaOp) -> R<XlaOp> {
        op.convert(PrimitiveType::F64)
            .map_err(|e| self.err(format!("pred -> f64: {e}")))
    }

    fn wrap(&self, r: Result<XlaOp, xla::Error>, what: &str) -> R<XlaOp> {
        r.map_err(|e| self.err(format!("{what}: {e}")))
    }

    // -- operands ----------------------------------------------------------

    /// Resolve an operand to its natural value (rank 0 for a scalar).
    fn operand(&self, op: &Operand) -> R<XlaOp> {
        match op {
            Operand::Lit(v) => self.c(*v),
            Operand::Time => Ok(self.t.clone()),
            Operand::Param(ix) => {
                let i = *ix as i64;
                self.wrap(
                    self.p
                        .slice_in_dim(i, i + 1, 1, 0)
                        .and_then(|s| s.reshape(&[])),
                    &format!("parameter {ix}"),
                )
            }
            Operand::Slot(s) => self.slots[*s as usize]
                .clone()
                .ok_or_else(|| self.err(format!("read of slot {s} before its definition"))),
            Operand::State(ix) => Ok(self.state[*ix as usize].clone()),
            Operand::Obs(ix) => self.obs_value(*ix as usize),
        }
    }

    fn obs_value(&self, ix: usize) -> R<XlaOp> {
        let name = &self.prog.obs_reads[ix];
        self.obs.get(name).cloned().ok_or_else(|| {
            self.err(format!(
                "observed `{name}` is read but never published on the tape — it comes \
                 from a fallback rule or a build-time seed, neither of which this \
                 emitter can reproduce"
            ))
        })
    }

    fn src(&self, s: &SrcRef) -> R<XlaOp> {
        match s {
            SrcRef::Slot(id) => self.slots[*id as usize]
                .clone()
                .ok_or_else(|| self.err(format!("gather source slot {id} is undefined"))),
            SrcRef::State(ix) => Ok(self.state[*ix as usize].clone()),
            SrcRef::Obs(ix) => self.obs_value(*ix as usize),
        }
    }

    /// The output box of a slot, as a `dims` slice (empty for a scalar).
    fn out_dims(&self, slot: SlotId) -> Vec<usize> {
        let d = &self.prog.slots[slot as usize];
        if d.scalar {
            Vec::new()
        } else {
            d.shape.to_vec()
        }
    }

    // -- kernels -----------------------------------------------------------

    /// `binary_kernel_of(op)` in XLA. Operands already share a shape.
    fn bin(&self, op: BinCode, a: &XlaOp, b: &XlaOp) -> R<XlaOp> {
        let cmp = |r: Result<XlaOp, xla::Error>, what: &str| -> R<XlaOp> {
            self.pred_to_f64(self.wrap(r, what)?)
        };
        match op {
            BinCode::Add => self.wrap(a.add_(b), "add"),
            BinCode::Sub => self.wrap(a.sub_(b), "sub"),
            BinCode::Mul => self.wrap(a.mul_(b), "mul"),
            BinCode::Div => self.wrap(a.div_(b), "div"),
            BinCode::Pow => self.wrap(a.pow(b), "pow"),
            BinCode::Atan2 => self.wrap(a.atan2(b), "atan2"),
            // `f64::min`/`max` return the OTHER operand when one is NaN; XLA's
            // Min/Max propagate it. Re-select so the two agree on NaN, which
            // costs four ops and removes a whole class of silent divergence.
            BinCode::Min => self.nan_aware(a, b, true),
            BinCode::Max => self.nan_aware(a, b, false),
            BinCode::Eq => cmp(a.eq(b), "eq"),
            BinCode::Ne => cmp(a.ne(b), "ne"),
            BinCode::Lt => cmp(a.lt(b), "lt"),
            BinCode::Le => cmp(a.le(b), "le"),
            BinCode::Gt => cmp(a.gt(b), "gt"),
            BinCode::Ge => cmp(a.ge(b), "ge"),
            BinCode::And => {
                let za = self.splat_like(a, 0.0)?;
                let x = self.wrap(a.ne(&za), "and: a != 0")?;
                let y = self.wrap(b.ne(&za), "and: b != 0")?;
                self.pred_to_f64(self.wrap(x.and(&y), "and")?)
            }
            BinCode::Or => {
                let za = self.splat_like(a, 0.0)?;
                let x = self.wrap(a.ne(&za), "or: a != 0")?;
                let y = self.wrap(b.ne(&za), "or: b != 0")?;
                self.pred_to_f64(self.wrap(x.or(&y), "or")?)
            }
            BinCode::Unknown => Err(self.err(
                "binary operator resolved to BinCode::Unknown (the interpreter's NaN \
                 sentinel); refusing rather than emitting a silent NaN",
            )),
        }
    }

    fn nan_aware(&self, a: &XlaOp, b: &XlaOp, is_min: bool) -> R<XlaOp> {
        let base = if is_min {
            self.wrap(a.min(b), "min")?
        } else {
            self.wrap(a.max(b), "max")?
        };
        let a_nan = self.wrap(a.ne(a), "a is NaN")?;
        let b_nan = self.wrap(b.ne(b), "b is NaN")?;
        let r = self.wrap(b_nan.select(a, &base), "min/max: b NaN")?;
        self.wrap(a_nan.select(b, &r), "min/max: a NaN")
    }

    /// `unary_kernel_of(op)` in XLA. XLA's op set has no `tan`, `asin`,
    /// `acos`, `atan`, `log10` or the hyperbolics other than `tanh`, so those
    /// are synthesized from the ops it does have. Each identity is chosen to
    /// keep the small-argument and infinite cases right, not merely the
    /// algebra: `sinh`/`asinh`/`acosh` switch between a `log1p`/`expm1` form
    /// near the cancelling region and a plain form outside it.
    ///
    /// KNOWN LIMIT: the plain arms of `asinh`/`acosh` square their argument,
    /// so they overflow to infinity above about 1e154 where the true value is
    /// finite (~355). No fixture in the corpus reaches that; a model that does
    /// needs the log-shifted identity instead.
    fn un(&self, op: UnCode, a: &XlaOp) -> R<XlaOp> {
        let one = self.splat_like(a, 1.0)?;
        let two = self.splat_like(a, 2.0)?;
        let half = self.splat_like(a, 0.5)?;
        let zero = self.splat_like(a, 0.0)?;
        match op {
            UnCode::Exp => self.wrap(a.exp(), "exp"),
            UnCode::Ln => self.wrap(a.log(), "log"),
            UnCode::Log10 => {
                let l = self.wrap(a.log(), "log10: log")?;
                let c = self.splat_like(a, std::f64::consts::LN_10)?;
                self.wrap(l.div_(&c), "log10: div")
            }
            UnCode::Sqrt => self.wrap(a.sqrt(), "sqrt"),
            UnCode::Abs => self.wrap(a.abs(), "abs"),
            UnCode::Sign => {
                // The interpreter's kernel is `x>0 ? 1 : x<0 ? -1 : 0`, which
                // maps NaN and -0.0 to +0.0; XLA's `sign` maps NaN to NaN and
                // -0.0 to -0.0. Spell out the interpreter's form.
                let neg = self.splat_like(a, -1.0)?;
                let pos = self.wrap(a.gt(&zero), "sign: >0")?;
                let negp = self.wrap(a.lt(&zero), "sign: <0")?;
                let inner = self.wrap(negp.select(&neg, &zero), "sign: inner")?;
                self.wrap(pos.select(&one, &inner), "sign: outer")
            }
            UnCode::Floor => self.wrap(a.floor(), "floor"),
            UnCode::Ceil => self.wrap(a.ceil(), "ceil"),
            UnCode::Sin => self.wrap(a.sin(), "sin"),
            UnCode::Cos => self.wrap(a.cos(), "cos"),
            UnCode::Tan => {
                let s = self.wrap(a.sin(), "tan: sin")?;
                let c = self.wrap(a.cos(), "tan: cos")?;
                self.wrap(s.div_(&c), "tan: div")
            }
            UnCode::Asin => {
                // atan2(x, sqrt(1 - x^2)): exact at |x| = 1 (atan2(±1, 0)) and
                // NaN outside the domain, both matching `f64::asin`.
                let x2 = self.wrap(a.mul_(a), "asin: x^2")?;
                let r = self.wrap(one.sub_(&x2), "asin: 1-x^2")?;
                let s = self.wrap(r.sqrt(), "asin: sqrt")?;
                self.wrap(a.atan2(&s), "asin: atan2")
            }
            UnCode::Acos => {
                let x2 = self.wrap(a.mul_(a), "acos: x^2")?;
                let r = self.wrap(one.sub_(&x2), "acos: 1-x^2")?;
                let s = self.wrap(r.sqrt(), "acos: sqrt")?;
                self.wrap(s.atan2(a), "acos: atan2")
            }
            UnCode::Atan => self.wrap(a.atan2(&one), "atan"),
            UnCode::Sinh => {
                // |x| <= 0.5: (expm1(x) + expm1(x)/(expm1(x)+1))/2, which has
                // no cancellation as x -> 0. Outside: (exp(x) - exp(-x))/2,
                // which is also what keeps ±inf mapping to ±inf.
                let e = self.wrap(a.expm1(), "sinh: expm1")?;
                let d = self.wrap(e.add_(&one), "sinh: expm1+1")?;
                let q = self.wrap(e.div_(&d), "sinh: ratio")?;
                let small = self.wrap(
                    e.add_(&q).and_then(|s| s.mul_(&half)),
                    "sinh: small-argument form",
                )?;
                let ex = self.wrap(a.exp(), "sinh: exp")?;
                let en = self.wrap(a.neg().and_then(|n| n.exp()), "sinh: exp(-x)")?;
                let big = self.wrap(
                    ex.sub_(&en).and_then(|s| s.mul_(&half)),
                    "sinh: plain form",
                )?;
                let thresh = self.splat_like(a, 0.5)?;
                let absx = self.wrap(a.abs(), "sinh: |x|")?;
                let use_big = self.wrap(absx.gt(&thresh), "sinh: select")?;
                self.wrap(use_big.select(&big, &small), "sinh: merge")
            }
            UnCode::Cosh => {
                let ex = self.wrap(a.exp(), "cosh: exp")?;
                let en = self.wrap(a.neg().and_then(|n| n.exp()), "cosh: exp(-x)")?;
                self.wrap(ex.add_(&en).and_then(|s| s.mul_(&half)), "cosh")
            }
            UnCode::Tanh => self.wrap(a.tanh(), "tanh"),
            UnCode::Asinh => {
                let absx = self.wrap(a.abs(), "asinh: |x|")?;
                let x2 = self.wrap(absx.mul_(&absx), "asinh: x^2")?;
                let root = self.wrap(x2.add_(&one).and_then(|s| s.sqrt()), "asinh: sqrt")?;
                // small: log1p(a + a^2/(1 + sqrt(1+a^2)))
                let den = self.wrap(one.add_(&root), "asinh: 1+sqrt")?;
                let frac = self.wrap(x2.div_(&den), "asinh: ratio")?;
                let small = self.wrap(
                    absx.add_(&frac).and_then(|s| s.log1p()),
                    "asinh: small-argument form",
                )?;
                let big = self.wrap(absx.add_(&root).and_then(|s| s.log()), "asinh: plain form")?;
                let use_big = self.wrap(absx.gt(&two), "asinh: select")?;
                let mag = self.wrap(use_big.select(&big, &small), "asinh: merge")?;
                let negm = self.wrap(mag.neg(), "asinh: negate")?;
                let isneg = self.wrap(a.lt(&zero), "asinh: sign")?;
                self.wrap(isneg.select(&negm, &mag), "asinh: apply sign")
            }
            UnCode::Acosh => {
                // x < 1 must be NaN: both arms take a square root of a
                // negative number there, so both deliver it.
                let s = self.wrap(a.sub_(&one), "acosh: x-1")?;
                let sp2 = self.wrap(s.add_(&two), "acosh: x+1")?;
                let root = self.wrap(s.mul_(&sp2).and_then(|q| q.sqrt()), "acosh: sqrt")?;
                let small = self.wrap(
                    s.add_(&root).and_then(|q| q.log1p()),
                    "acosh: small-argument form",
                )?;
                let x2 = self.wrap(a.mul_(a), "acosh: x^2")?;
                let root2 = self.wrap(x2.sub_(&one).and_then(|q| q.sqrt()), "acosh: sqrt2")?;
                let big = self.wrap(a.add_(&root2).and_then(|q| q.log()), "acosh: plain form")?;
                let use_big = self.wrap(a.gt(&two), "acosh: select")?;
                self.wrap(use_big.select(&big, &small), "acosh: merge")
            }
            UnCode::Atanh => {
                // 0.5 * log1p(2x / (1 - x)): x = ±1 give ±inf and |x| > 1 give
                // NaN, matching `f64::atanh`.
                let num = self.wrap(two.mul_(a), "atanh: 2x")?;
                let den = self.wrap(one.sub_(a), "atanh: 1-x")?;
                let q = self.wrap(num.div_(&den), "atanh: ratio")?;
                self.wrap(
                    q.log1p().and_then(|l| l.mul_(&half)),
                    "atanh: 0.5*log1p",
                )
            }
            UnCode::Not => {
                let p = self.wrap(a.eq(&zero), "not")?;
                self.pred_to_f64(p)
            }
            UnCode::Unknown => Err(self.err(
                "unary operator resolved to UnCode::Unknown (the interpreter's NaN \
                 sentinel); refusing rather than emitting a silent NaN",
            )),
        }
    }

    // -- the instruction loop ----------------------------------------------

    fn emit_range(&mut self, start: usize, end: usize) -> R<()> {
        let mut pc = start;
        while pc < end {
            if let Some(ord) = self.prog.provenance.get(pc) {
                if let Some(info) = self.prog.rules.get(*ord as usize) {
                    self.cur_rule = info.name.clone();
                }
            }
            if let Instr::JmpIfZero {
                cond,
                n_true,
                n_false,
            } = &self.prog.instrs[pc]
            {
                let (nt, nf) = (*n_true as usize, *n_false as usize);
                let cond = cond.clone();
                let t_start = pc + 1;
                let f_start = t_start + nt;
                let f_end = f_start + nf;
                if f_end > end {
                    return Err(self.err(format!(
                        "JmpIfZero at {pc} spans past the end of its section ({f_end} > {end})"
                    )));
                }
                self.emit_branch(&cond, t_start, f_start, f_end)?;
                pc = f_end;
                continue;
            }
            self.emit_one(pc)?;
            pc += 1;
        }
        Ok(())
    }

    /// Lower a `JmpIfZero` pair as `select`.
    ///
    /// The tape short-circuits: the untaken branch NEVER executes. A single
    /// XLA program has no such thing, so both branches are emitted and the
    /// live-out slots selected. That is value-equivalent because every
    /// instruction the tape can put in a branch is a pure floating-point map —
    /// an untaken `log(-1)` or `1/0` produces a NaN or an infinity that the
    /// `select` then discards, and IEEE-754 arithmetic raises no trap that
    /// could escape. (`XlaOp::conditional` would preserve the short circuit
    /// literally; it is not used because it would need a separate builder and
    /// an explicit tuple of every live value crossing the branch, for no
    /// difference in the numbers.)
    ///
    /// A branch carrying a side effect — a `DyWrite`, an `Export`, a
    /// `Fallback` — is refused rather than guessed at.
    fn emit_branch(&mut self, cond: &Operand, t0: usize, f0: usize, f1: usize) -> R<()> {
        for pc in t0..f1 {
            match &self.prog.instrs[pc] {
                Instr::DyWrite { .. } | Instr::Export { .. } | Instr::Fallback { .. } => {
                    return Err(self.err(format!(
                        "instruction {} inside a JmpIfZero branch has an effect beyond \
                         its slot; this emitter lowers branches as `select` over both \
                         arms and cannot order such an effect",
                        self.prog.instrs[pc].opcode()
                    )));
                }
                _ => {}
            }
        }
        let c = self.operand(cond)?;
        if !self.dims(&c)?.is_empty() {
            return Err(self.err("JmpIfZero condition is not a scalar"));
        }
        let cz = self.c(0.0)?;
        let pred0 = self.wrap(c.ne(&cz), "JmpIfZero: cond != 0")?;

        let before = self.slots.clone();
        let blocks_before = self.blocks.clone();
        self.emit_range(t0, f0)?;
        let after_t = std::mem::replace(&mut self.slots, before.clone());
        let blocks_t = std::mem::replace(&mut self.blocks, blocks_before.clone());
        self.emit_range(f0, f1)?;
        let after_f = std::mem::take(&mut self.slots);
        let blocks_f = std::mem::take(&mut self.blocks);
        if blocks_t.len() != blocks_f.len() {
            return Err(self.err("JmpIfZero branches disagree on the dy blocks"));
        }
        self.blocks = blocks_before;

        let mut merged = Vec::with_capacity(after_t.len());
        for i in 0..after_t.len() {
            let v = match (&after_t[i], &after_f[i]) {
                (Some(tv), Some(fv)) => {
                    if before[i].is_some() && std::ptr::eq(tv, fv) {
                        // Untouched by both arms.
                        Some(tv.clone())
                    } else {
                        let dims = self.dims(tv)?;
                        let fd = self.dims(fv)?;
                        if dims != fd {
                            return Err(self.err(format!(
                                "JmpIfZero phi slot {i} has shape {dims:?} on one arm and \
                                 {fd:?} on the other"
                            )));
                        }
                        let pred = if dims.is_empty() {
                            pred0.clone()
                        } else {
                            let d: Vec<i64> = dims.iter().map(|&x| x as i64).collect();
                            self.wrap(pred0.broadcast(&d), "JmpIfZero: broadcast cond")?
                        };
                        Some(self.wrap(pred.select(tv, fv), "JmpIfZero: select")?)
                    }
                }
                // Defined on one arm only: it can only be read inside that
                // arm (the tape joins its branches on a shared phi slot), so
                // keeping it is safe and keeps nested branches working.
                (Some(v), None) | (None, Some(v)) => Some(v.clone()),
                (None, None) => None,
            };
            merged.push(v);
        }
        self.slots = merged;
        Ok(())
    }

    fn emit_one(&mut self, pc: usize) -> R<()> {
        let instr = self.prog.instrs[pc].clone();
        match &instr {
            Instr::Bin { op, a, b, out } => {
                let dims = self.out_dims(*out);
                let av = self.operand(a)?;
                let bv = self.operand(b)?;
                let av = self.to_shape(&av, &dims)?;
                let bv = self.to_shape(&bv, &dims)?;
                let v = self.bin(*op, &av, &bv)?;
                self.define(*out, v);
            }
            Instr::Un { op, a, out } => {
                let dims = self.out_dims(*out);
                let av = self.operand(a)?;
                let av = self.to_shape(&av, &dims)?;
                let v = self.un(*op, &av)?;
                self.define(*out, v);
            }
            Instr::Neg { a, out } => {
                let dims = self.out_dims(*out);
                let av = self.operand(a)?;
                let av = self.to_shape(&av, &dims)?;
                // `vec_negate`, i.e. `-x`, NOT `0 - x` (they differ on ±0).
                let v = self.wrap(av.neg(), "neg")?;
                self.define(*out, v);
            }
            Instr::Select { cond, a, b, out } => {
                let dims = self.out_dims(*out);
                let cv = self.operand(cond)?;
                let av = self.operand(a)?;
                let bv = self.operand(b)?;
                let cv = self.to_shape(&cv, &dims)?;
                let av = self.to_shape(&av, &dims)?;
                let bv = self.to_shape(&bv, &dims)?;
                let z = self.splat_like(&cv, 0.0)?;
                let pred = self.wrap(cv.ne(&z), "select: cond != 0")?;
                let v = self.wrap(pred.select(&av, &bv), "select")?;
                self.define(*out, v);
            }
            Instr::Gather { src, plan, out } => {
                let s = self.src(src)?;
                let plan = &self.prog.plans[*plan as usize];
                let have = self.dims(&s)?;
                if have != plan.src_shape.as_slice() {
                    return Err(self.err(format!(
                        "gather source has shape {have:?} but the plan expects {:?}",
                        &plan.src_shape[..]
                    )));
                }
                let v = self.emit_gather(plan, &s)?;
                self.define(*out, v);
            }
            Instr::LoadElem { src, idx, out } => {
                let s = self.src(src)?;
                let mut cur = s;
                for (d, &i) in idx.iter().enumerate() {
                    cur = self.wrap(
                        cur.slice_in_dim(i as i64, i as i64 + 1, 1, d as i64),
                        "load_elem: slice",
                    )?;
                }
                let v = self.wrap(cur.reshape(&[]), "load_elem: reshape")?;
                self.define(*out, v);
            }
            Instr::Ramp { axis, lo, out } => {
                let dims = self.out_dims(*out);
                if dims.is_empty() {
                    return Err(self.err("Ramp into a scalar slot"));
                }
                let d: Vec<i64> = dims.iter().map(|&x| x as i64).collect();
                // Integer ramp then one convert, so the value is exactly
                // `(lo + p) as f64` rather than an f64 add.
                let io = self.wrap(
                    self.b.iota(ElementType::S64, &d, *axis as i64),
                    "ramp: iota",
                )?;
                let loc = self.ci(*lo)?;
                let loc = self.wrap(loc.broadcast(&d), "ramp: broadcast lo")?;
                let v = self.wrap(
                    io.add_(&loc).and_then(|s| s.convert(PrimitiveType::F64)),
                    "ramp: add + convert",
                )?;
                self.define(*out, v);
            }
            Instr::Fill { v, out } => {
                let dims = self.out_dims(*out);
                let vv = self.operand(v)?;
                if !self.dims(&vv)?.is_empty() {
                    return Err(self.err("Fill with an array operand"));
                }
                let vv = self.to_shape(&vv, &dims)?;
                self.define(*out, vv);
            }
            Instr::Copy { a, out } => {
                let dims = self.out_dims(*out);
                let av = self.operand(a)?;
                let av = self.to_shape(&av, &dims)?;
                self.define(*out, av);
            }
            Instr::Region {
                base,
                src,
                region,
                out,
            } => {
                let spec = &self.prog.regions[*region as usize];
                let basev = self.slots[*base as usize]
                    .clone()
                    .ok_or_else(|| self.err("Region base slot is undefined"))?;
                let sv = self.operand(src)?;
                let upd = self.to_shape(&sv, &spec.shape)?;
                let starts: Vec<XlaOp> = spec
                    .dest_lo
                    .iter()
                    .map(|&x| self.ci(x as i64))
                    .collect::<R<Vec<_>>>()?;
                let v = self.wrap(
                    basev.dynamic_update_slice(&upd, &starts),
                    "region: dynamic_update_slice",
                )?;
                self.define(*out, v);
            }
            Instr::Export { slot, export } => {
                let name = self.prog.exports[*export as usize].0.clone();
                let v = self.slots[*slot as usize]
                    .clone()
                    .ok_or_else(|| self.err("exported slot is undefined"))?;
                self.obs.insert(name, v);
            }
            Instr::DyWrite { write } => {
                let w = self.prog.dy_writes[*write as usize].clone();
                self.emit_dy_write(&w)?;
            }
            Instr::Fallback { rule } => {
                let info = &self.prog.rules[*rule as usize];
                let reason = match &info.status {
                    RuleStatus::Fallback(r) => r.clone(),
                    RuleStatus::Taped => "<taped rule reached through Fallback>".to_string(),
                };
                return Err(XlaEmitError::new(
                    info.name.clone(),
                    format!(
                        "rule is not on the tape (the lowering bailed: {reason}); a \
                         compiled program cannot re-enter the interpreter, so the whole \
                         model is refused"
                    ),
                ));
            }
            Instr::JmpIfZero { .. } => {
                return Err(self.err("JmpIfZero reached emit_one (handled by emit_range)"));
            }
            Instr::Fused { .. } => {
                return Err(self.err(
                    "Instr::Fused reached the emitter; the tape must be built with the \
                     fusion pass OFF for emission (build_tape_opts(.., None)) — a fused \
                     group is a scalar micro-program, which is the shape XLA's own \
                     fusion chooses for itself",
                ));
            }
            // ---- WHERE NEW TAPE INSTRUCTIONS PLUG IN --------------------
            // The tape is growing in parallel (array constants, carried
            // observed shapes, rank-0 reductions). Anything this emitter has
            // not learned lands here and is REFUSED by name, so the gap shows
            // up as a named refusal in the conformance report instead of as
            // wrong numbers. Add the arm above, not a special case here.
            #[allow(unreachable_patterns)]
            other => {
                return Err(self.err(format!(
                    "tape instruction `{}` has no lowering: the tape has grown and the \
                     XLA emitter must follow",
                    other.opcode()
                )));
            }
        }
        Ok(())
    }

    fn define(&mut self, slot: SlotId, v: XlaOp) {
        self.slots[slot as usize] = Some(v);
    }

    // -- gather ------------------------------------------------------------

    /// Lower one precompiled [`GatherPlan`] — a transliteration of
    /// `refexec::exec_gather`'s four stages into XLA:
    ///
    /// 1. fixed source axes -> `slice_in_dim` + `reshape` (drop the axis);
    /// 2. the mapped-axis permutation -> `transpose`;
    /// 3. broadcast axes -> one `broadcast_in_dim`;
    /// 4. the per-axis copy-segment schedule -> nested `slice_in_dim` +
    ///    `concat_in_dim`, with a zero constant for every uncovered (ghost)
    ///    stretch. The schedule is a CARTESIAN product of per-axis segments,
    ///    which is exactly what that nesting expresses; contiguous plans (the
    ///    common shifted-stencil read) collapse to a single slice with no
    ///    concatenation at all.
    ///
    /// The alternative — an XLA `gather` over an explicit index array — would
    /// materialize one s64 index per output element for what is, in every plan
    /// the corpus produces, pure affine data movement.
    fn emit_gather(&self, plan: &GatherPlan, src: &XlaOp) -> R<XlaOp> {
        let mut cur = src.clone();
        // 1. fixed axes, descending so lower axis numbers stay valid.
        for &(d, i0) in &plan.fixed_desc {
            let dims = self.dims(&cur)?;
            if d >= dims.len() {
                return Err(self.err("gather plan fixes an axis the source does not have"));
            }
            let mut nd: Vec<i64> = dims.iter().map(|&x| x as i64).collect();
            nd.remove(d);
            cur = self.wrap(
                cur.slice_in_dim(i0 as i64, i0 as i64 + 1, 1, d as i64)
                    .and_then(|s| s.reshape(&nd)),
                "gather: fixed axis",
            )?;
        }
        // 2. permutation of the remaining source axes.
        if plan.perm.len() > 1 && !plan.perm.iter().enumerate().all(|(i, &p)| i == p) {
            let perm: Vec<i64> = plan.perm.iter().map(|&x| x as i64).collect();
            cur = self.wrap(cur.transpose(&perm), "gather: transpose")?;
        }
        // 3. broadcast axes.
        let out_ndim = plan.shape.len();
        let mapped_axes: Vec<i64> = (0..out_ndim)
            .filter(|&a| plan.mapped[a])
            .map(|a| a as i64)
            .collect();
        let cur_dims = self.dims(&cur)?;
        if cur_dims.len() != mapped_axes.len() {
            return Err(self.err(format!(
                "gather plan maps {} source axes but {} output axes are marked mapped",
                cur_dims.len(),
                mapped_axes.len()
            )));
        }
        if out_ndim > 0 {
            let mut bshape: Vec<i64> = Vec::with_capacity(out_ndim);
            let mut k = 0usize;
            for a in 0..out_ndim {
                if plan.mapped[a] {
                    bshape.push(cur_dims[k] as i64);
                    k += 1;
                } else {
                    bshape.push(plan.shape[a] as i64);
                }
            }
            if bshape.len() != cur_dims.len() || !mapped_axes.iter().enumerate().all(|(i, &a)| a as usize == i) {
                cur = self.wrap(
                    cur.broadcast_in_dim(&bshape, &mapped_axes),
                    "gather: broadcast_in_dim",
                )?;
            }
        }
        // 4. the copy-segment schedule.
        self.emit_segments(&cur, plan, 0)
    }

    fn emit_segments(&self, cur: &XlaOp, plan: &GatherPlan, d: usize) -> R<XlaOp> {
        if d == plan.shape.len() {
            return Ok(cur.clone());
        }
        let extent = plan.shape[d];
        let mut segs: Vec<(usize, usize, usize)> = plan.segs[d].to_vec();
        segs.sort_by_key(|s| s.0);
        // Fast path: one segment covering the whole axis with no offset.
        if segs.len() == 1 && segs[0] == (0, extent, 0) {
            let cd = self.dims(cur)?;
            if cd[d] == extent {
                return self.emit_segments(cur, plan, d + 1);
            }
        }
        let cd = self.dims(cur)?;
        let piece_zeros = |len: usize| -> R<XlaOp> {
            let mut shape: Vec<usize> = cd.clone();
            shape[d] = len;
            for (e, s) in shape.iter_mut().enumerate().skip(d + 1) {
                *s = plan.shape[e];
            }
            self.zeros(&shape)
        };
        let mut pieces: Vec<XlaOp> = Vec::new();
        let mut next = 0usize;
        for (o, l, s) in segs {
            if o < next {
                return Err(self.err("gather plan segments overlap along an axis"));
            }
            if o > next {
                pieces.push(piece_zeros(o - next)?);
            }
            let sl = self.wrap(
                cur.slice_in_dim(s as i64, (s + l) as i64, 1, d as i64),
                "gather: segment slice",
            )?;
            pieces.push(self.emit_segments(&sl, plan, d + 1)?);
            next = o + l;
        }
        if next > extent {
            return Err(self.err("gather plan segments run past the output extent"));
        }
        if next < extent {
            pieces.push(piece_zeros(extent - next)?);
        }
        match pieces.len() {
            0 => Err(self.err("gather plan has no segments and no extent along an axis")),
            1 => Ok(pieces.remove(0)),
            _ => {
                let head = pieces.remove(0);
                self.wrap(
                    head.concat_in_dim(&pieces, d as i64),
                    "gather: concat_in_dim",
                )
            }
        }
    }

    // -- dy ----------------------------------------------------------------

    /// Apply one [`DyWrite`] to the accumulator block of its variable.
    ///
    /// `refexec` writes straight into the flat, COLUMN-MAJOR `dy`. Here each
    /// variable keeps a ROW-MAJOR block of its own logical shape and the whole
    /// set is relabelled to column-major once, in [`Self::assemble_du`], so a
    /// write is a plain `dynamic_update_slice` at `dest_lo` rather than a
    /// strided scatter.
    fn emit_dy_write(&mut self, w: &DyWrite) -> R<()> {
        // `DyWrite::var` is only meaningful for the ARRAY form. A scalar rule
        // (`RhsRule::Scalar` / `IndexedScalar`) carries `var: 0` as a dummy
        // and addresses `dy` by the absolute flat slot in `scalar_flat`, so
        // its owning variable has to be found from that slot instead — using
        // `var` there would write into whichever variable happens to sit
        // first in the layout.
        let vi = match w.scalar_flat {
            Some(flat) => self.var_owning_slot(flat)?,
            None => {
                let sv = &self.prog.state_vars[w.var as usize];
                *self.var_ix.get(&sv.name).ok_or_else(|| {
                    self.err(format!("dy write names unknown variable {}", sv.name))
                })?
            }
        };
        let (var_name, vs) = &self.var_order[vi];
        let var_name = var_name.clone();
        let shape: Vec<usize> = vs.shape.clone();
        let var_offset = vs.flat_offset;
        let val = self.slots[w.slot as usize]
            .clone()
            .ok_or_else(|| self.err("dy-write slot is undefined"))?;
        let val_dims = self.dims(&val)?;

        let cur = match &self.blocks[vi] {
            Some(b) => b.clone(),
            None => self.zeros(&shape)?,
        };

        let next = match w.scalar_flat {
            Some(flat) => {
                // A scalar rule writing ONE flat slot: decode its
                // column-major position inside the variable's box.
                if !val_dims.is_empty() {
                    return Err(self.err("scalar dy write with an array value"));
                }
                if shape.is_empty() {
                    val
                } else {
                    let mut rem = flat - var_offset;
                    let mut multi = vec![0usize; shape.len()];
                    for d in 0..shape.len() {
                        multi[d] = rem % shape[d];
                        rem /= shape[d];
                    }
                    if rem != 0 {
                        return Err(self.err("scalar dy write lands past its variable block"));
                    }
                    let ones: Vec<i64> = shape.iter().map(|_| 1i64).collect();
                    let upd = self.wrap(val.reshape(&ones), "dy write: reshape scalar")?;
                    let starts: Vec<XlaOp> = multi
                        .iter()
                        .map(|&x| self.ci(x as i64))
                        .collect::<R<Vec<_>>>()?;
                    self.wrap(
                        cur.dynamic_update_slice(&upd, &starts),
                        "dy write: dynamic_update_slice",
                    )?
                }
            }
            None => {
                if shape.is_empty() {
                    if !val_dims.is_empty() {
                        return Err(self.err("array dy write into a 0-d variable"));
                    }
                    val
                } else {
                    if val_dims.len() != shape.len() {
                        return Err(self.err(format!(
                            "dy write value has rank {} but variable {var_name} has rank {}",
                            val_dims.len(),
                            shape.len()
                        )));
                    }
                    let starts: Vec<XlaOp> = w
                        .dest_lo
                        .iter()
                        .map(|&x| self.ci(x as i64))
                        .collect::<R<Vec<_>>>()?;
                    self.wrap(
                        cur.dynamic_update_slice(&val, &starts),
                        "dy write: dynamic_update_slice",
                    )?
                }
            }
        };
        self.blocks[vi] = Some(next);
        Ok(())
    }

    /// The variable whose flat block contains `flat`.
    fn var_owning_slot(&self, flat: usize) -> R<usize> {
        for (i, (_, vs)) in self.var_order.iter().enumerate() {
            let n: usize = vs.shape.iter().product::<usize>().max(1);
            if flat >= vs.flat_offset && flat < vs.flat_offset + n {
                return Ok(i);
            }
        }
        Err(self.err(format!(
            "scalar dy write addresses flat slot {flat}, which lies in no variable block"
        )))
    }

    /// Concatenate the per-variable blocks into the flat, column-major `du`.
    fn assemble_du(&mut self) -> R<XlaOp> {
        self.cur_rule = "<program>".to_string();
        let mut flat: Vec<XlaOp> = Vec::with_capacity(self.var_order.len());
        for (i, (_, vs)) in self.var_order.iter().enumerate() {
            let n: usize = vs.shape.iter().product::<usize>().max(1);
            let blk = match &self.blocks[i] {
                Some(b) => b.clone(),
                None => self.zeros(&vs.shape)?,
            };
            let f = if vs.shape.is_empty() {
                self.wrap(blk.reshape(&[1]), "du: reshape scalar block")?
            } else {
                // Row-major -> column-major is the reversing transpose.
                let perm: Vec<i64> = (0..vs.shape.len() as i64).rev().collect();
                self.wrap(
                    blk.transpose(&perm).and_then(|b| b.reshape(&[n as i64])),
                    "du: relabel block",
                )?
            };
            flat.push(f);
        }
        match flat.len() {
            0 => self.zeros(&[0]),
            1 => Ok(flat.remove(0)),
            _ => {
                let head = flat.remove(0);
                self.wrap(head.concat_in_dim(&flat, 0), "du: concat")
            }
        }
    }
}
