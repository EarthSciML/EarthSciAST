//! What the tape's test modules share: compiling a fixture document, seeded
//! states, bitwise comparison, instruction counts, the JSON builders of the
//! fixture documents, and the one A/B harness, [`ab_harness`], that builds a
//! fixture's fused and unfused programs and runs both executors over them
//! against the per-cell oracle. Its options pick the parameter maps, states
//! and times, whether the fast executor keeps one warm scratch per program or
//! takes a fresh one per evaluation (comparing the latched fault too), and
//! whether the row-major program and split execution join in. Three presets
//! name the configurations the tests use: [`ab_check`], [`ab`] and
//! [`oracle_ab`].

use super::super::{ArrayCompiled, RhsScratch, RhsStats};
use super::ir::*;
use super::refexec::run_reference;
use super::taped;
use crate::simulate_array::take_const_array_oob;
use crate::types::EsmFile;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

pub(super) fn typed(doc: serde_json::Value) -> EsmFile {
    // Through `load`, not `serde_json::from_value`: load activates the AST
    // interner, so structurally identical subtrees share one `Arc` — the
    // property the pointer-keyed value numbering exploits (exactly as the
    // production `load_path_with_options` path does).
    crate::parse::load_string(&doc.to_string()).expect("fixture document loads")
}

pub(super) fn compile(doc: serde_json::Value) -> ArrayCompiled {
    ArrayCompiled::from_file(&typed(doc)).expect("fixture compiles")
}

/// The production superop configuration (env-independent for tests).
pub(super) fn superop_cfg() -> super::fuse::SuperopCfg {
    super::fuse::SuperopCfg { ext_pairs: true }
}

/// Deterministic pseudo-random state in `[lo, hi)` (xorshift-style LCG).
pub(super) fn seeded_state(n: usize, seed: u64, lo: f64, hi: f64) -> Vec<f64> {
    let mut x = seed.wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(1);
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            let u = (x >> 11) as f64 / (1u64 << 53) as f64;
            lo + u * (hi - lo)
        })
        .collect()
}

/// The counterpart of [`ab_check`] for a document the tape cannot lower:
/// BOTH builds (fused and unfused) must decline and leave no program, and a
/// scratch asked for a tape must be refused, naming the declined rule — never
/// handed back without a tape to run the legacy evaluator. Returns the fused
/// build's decline.
pub(super) fn declined_check(doc: serde_json::Value) -> DeclinedTape {
    let compiled = compile(doc);
    let (fused, report) = compiled.build_tape_opts(&HashSet::new(), Some(superop_cfg()));
    let (unfused, _) = compiled.build_tape_opts(&HashSet::new(), None);
    let Err(declined) = fused else {
        panic!("the fixture must decline a rule:\n{report}");
    };
    assert!(unfused.is_err(), "the unfused build must decline too");
    assert_refused(&compiled, &declined);
    declined
}

/// A scratch asked of a model whose tape declined is refused with
/// `compiler_refused_rule`, naming the first declined rule and its reason.
pub(super) fn assert_refused(compiled: &ArrayCompiled, declined: &DeclinedTape) {
    let (rule, reason) = declined
        .declined_rules()
        .into_iter()
        .next()
        .expect("a declined tape names at least one rule");
    match compiled.debug_new_scratch_taped() {
        Ok(_) => panic!("a declined build must not hand back a scratch"),
        Err(crate::simulate::SimulateError::Compile(
            crate::compile_error::CompileError::CompilerRefusedRule {
                rule: r,
                reason: why,
                ..
            },
        )) => {
            assert_eq!(r, rule);
            assert_eq!(why, reason);
        }
        Err(e) => panic!("expected compiler_refused_rule, got {e:?}"),
    }
}

/// `a` and `b` equal bit for bit, element by element.
pub(super) fn assert_bits_eq(a: &[f64], b: &[f64], what: &str) {
    assert_eq!(a.len(), b.len(), "{what}: length");
    for (k, (x, y)) in a.iter().zip(b.iter()).enumerate() {
        assert_eq!(
            x.to_bits(),
            y.to_bits(),
            "{what}: dy[{k}] diverged: {x:?} ({:016x}) vs {y:?} ({:016x})",
            x.to_bits(),
            y.to_bits()
        );
    }
}

/// A fresh scratch carrying `prog`.
pub(super) fn scratch_with(compiled: &ArrayCompiled, prog: TapeProgram) -> RhsScratch {
    let mut s = compiled.new_scratch();
    s.install_tape(std::sync::Arc::new(prog));
    s
}

/// The fast executor's `dy` on `scratch` at one state, time and parameter
/// vector.
pub(super) fn fast_dy(
    compiled: &ArrayCompiled,
    scratch: &mut RhsScratch,
    state: &[f64],
    t: f64,
    param_vec: &[f64],
) -> Vec<f64> {
    let mut dy = vec![0.0; state.len()];
    compiled.debug_eval_rhs_into(
        state,
        t,
        param_vec,
        &mut dy,
        scratch,
        &mut RhsStats::default(),
    );
    dy
}

/// The fast executor on `scratch` writes `dy_ref` bit for bit.
pub(super) fn assert_fast_matches(
    compiled: &ArrayCompiled,
    scratch: &mut RhsScratch,
    param_vec: &[f64],
    state: &[f64],
    t: f64,
    dy_ref: &[f64],
    label: &str,
) {
    let dy = fast_dy(compiled, scratch, state, t, param_vec);
    assert_bits_eq(&dy, dy_ref, &format!("{label}: fast executor"));
}

/// One program the A/B harness builds and runs.
#[derive(Clone, Copy)]
enum Arm {
    Fused,
    Unfused,
    /// The fused program without the state-layout alignment the fused build
    /// may carry: both storage orders must agree.
    RowMajorFused,
}

impl Arm {
    fn label(self) -> &'static str {
        match self {
            Arm::Fused => "fused",
            Arm::Unfused => "unfused",
            Arm::RowMajorFused => "row-major fused",
        }
    }

    fn build(self, compiled: &ArrayCompiled) -> TapeProgram {
        let none = HashSet::new();
        taped(match self {
            Arm::Fused => compiled.build_tape_opts(&none, Some(superop_cfg())),
            Arm::Unfused => compiled.build_tape_opts(&none, None),
            Arm::RowMajorFused => compiled.build_tape_layout(&none, Some(superop_cfg()), false),
        })
        .0
    }

    /// A scratch kept warm across every evaluation: the production taped
    /// scratch for the fused program, a bare one carrying the build for the
    /// others.
    fn warm_scratch(self, compiled: &ArrayCompiled) -> RhsScratch {
        match self {
            Arm::Fused => compiled
                .debug_new_scratch_taped()
                .expect("the tape lowers every rule"),
            _ => {
                let mut s = RhsScratch::new(&compiled.var_shapes);
                s.install_tape(std::sync::Arc::new(self.build(compiled)));
                s
            }
        }
    }
}

/// How the fast executor's scratch is kept across the A/B harness's
/// evaluations.
#[derive(Clone, Copy, PartialEq)]
pub(super) enum Scratches {
    /// One warm scratch per program across every state and time.
    Warm,
    /// A fresh scratch per evaluation, comparing the latched const-array
    /// fault too: a CONST-section fault latches when the section primes,
    /// which a warm scratch has already done.
    FreshWithFaults,
}

/// What the A/B harness evaluates: the parameter maps, the seeded states
/// `0..seeds` drawn in `[lo, hi)`, the times, how scratches are kept, and
/// whether the row-major fused program and three-wide split execution are
/// compared too.
pub(super) struct AbOptions<'a> {
    pub params: &'a [HashMap<String, f64>],
    pub seeds: u64,
    pub lo: f64,
    pub hi: f64,
    pub times: &'a [f64],
    pub scratches: Scratches,
    pub row_major_and_split: bool,
}

/// The fused program the A/B harness built, and the unfused one's length.
pub(super) struct AbOutcome {
    pub fused: TapeProgram,
    pub unfused_len: usize,
}

/// Build the fused and unfused tapes of `compiled` — each must lower every
/// rule, the unfused one must not fuse, and fusion must not grow the program
/// — and require that the reference executor and the fast executor, over
/// every program `opts` names, write the per-cell oracle's `dy` bit for bit
/// at every parameter map, seeded state and time of `opts`.
pub(super) fn ab_harness(compiled: &ArrayCompiled, opts: &AbOptions) -> AbOutcome {
    let none = HashSet::new();
    let (fused, report) = taped(compiled.build_tape_opts(&none, Some(superop_cfg())));
    let (unfused, report_uf) = taped(compiled.build_tape_opts(&none, None));
    for rep in [&report, &report_uf] {
        assert!(
            rep.fallbacks.is_empty(),
            "the tape must lower every rule: {:?}",
            rep.fallbacks
        );
    }
    assert!(
        unfused.fused.is_empty() && unfused.fuse_stats.n_groups == 0,
        "the unfused build must not fuse"
    );
    assert!(
        all_instrs(&fused).count() <= all_instrs(&unfused).count(),
        "fusion must not grow the program"
    );
    let arms: &[Arm] = if opts.row_major_and_split {
        &[Arm::Fused, Arm::Unfused, Arm::RowMajorFused]
    } else {
        &[Arm::Fused, Arm::Unfused]
    };
    let warm = opts.scratches == Scratches::Warm;
    let mut warm_arms: Vec<(Arm, TapeProgram, RhsScratch)> = if warm {
        arms.iter()
            .map(|&a| (a, a.build(compiled), a.warm_scratch(compiled)))
            .collect()
    } else {
        Vec::new()
    };
    for (arm, prog, scratch) in &warm_arms {
        match arm {
            Arm::Fused => assert!(scratch.has_tape(), "fixture scratch must carry a tape"),
            Arm::RowMajorFused => assert!(!prog.col_major),
            Arm::Unfused => {}
        }
    }
    let n = compiled.state_variable_names().len();
    let mut stats = RhsStats::default();
    for params in opts.params {
        let pv = compiled.debug_resolve_params(params);
        for seed in 0..opts.seeds {
            let state = seeded_state(n, seed, opts.lo, opts.hi);
            for &t in opts.times {
                if !warm {
                    compare_fresh(compiled, arms, params, &state, t);
                    continue;
                }
                let (oracle, _) = compiled.debug_eval_rhs(&state, t, params);
                for (arm, prog, scratch) in &mut warm_arms {
                    let what = format!("seed {seed} t {t}: {}", arm.label());
                    let mut dy = vec![0.0f64; n];
                    run_reference(prog, compiled, &state, &pv, t, &mut dy);
                    assert_bits_eq(&dy, &oracle, &format!("{what} reference executor"));
                    let mut dy = vec![0.0f64; n];
                    compiled.debug_eval_rhs_into(&state, t, &pv, &mut dy, scratch, &mut stats);
                    assert_bits_eq(&dy, &oracle, &format!("{what} fast executor"));
                }
                // Every instruction split three wide, whatever its size, is
                // the serial executor bit for bit.
                #[cfg(not(target_arch = "wasm32"))]
                if opts.row_major_and_split {
                    for (arm, _, scratch) in &mut warm_arms {
                        if matches!(arm, Arm::Unfused) {
                            continue;
                        }
                        let mut dy = vec![0.0f64; n];
                        super::exec::force_split(Some(3));
                        compiled.debug_eval_rhs_into(&state, t, &pv, &mut dy, scratch, &mut stats);
                        super::exec::force_split(None);
                        let what = format!("seed {seed} t {t}: {} split executor", arm.label());
                        assert_bits_eq(&dy, &oracle, &what);
                    }
                }
            }
        }
    }
    if warm {
        assert!(stats.taped_rules > 0, "the fast executor must have run");
    }
    AbOutcome {
        fused,
        unfused_len: all_instrs(&unfused).count(),
    }
}

/// Each of `arms`, built afresh, in both executors (the fast one on a fresh
/// scratch) against the oracle at one state, time and parameter map: `dy`
/// bit for bit and the latched const-array fault.
fn compare_fresh(
    compiled: &ArrayCompiled,
    arms: &[Arm],
    params: &HashMap<String, f64>,
    state: &[f64],
    t: f64,
) {
    let n = state.len();
    let pv = compiled.debug_resolve_params(params);
    take_const_array_oob();
    let (dy_oracle, _) = compiled.debug_eval_rhs(state, t, params);
    let f_oracle = take_const_array_oob();
    for arm in arms {
        let label = arm.label();
        let p = arm.build(compiled);
        let mut dy = vec![0.0f64; n];
        run_reference(&p, compiled, state, &pv, t, &mut dy);
        let f_ref = take_const_array_oob();
        assert_bits_eq(&dy, &dy_oracle, &format!("{label} reference executor"));
        assert_eq!(f_ref, f_oracle, "{label} reference executor fault");
        let mut scratch = scratch_with(compiled, p);
        let dy = fast_dy(compiled, &mut scratch, state, t, &pv);
        let f_fast = take_const_array_oob();
        assert_bits_eq(&dy, &dy_oracle, &format!("{label} fast executor"));
        assert_eq!(f_fast, f_oracle, "{label} fast executor fault");
    }
}

/// [`ab_harness`] against the production interpreter with no parameters on
/// warm scratches, the row-major program and split execution included, at
/// four states seeded in `[lo, hi)`. Returns the fused program.
pub(super) fn ab_check(doc: serde_json::Value, lo: f64, hi: f64) -> TapeProgram {
    let compiled = compile(doc);
    let opts = AbOptions {
        params: &no_params(),
        seeds: 4,
        lo,
        hi,
        times: &[0.0, 0.37, 2.5],
        scratches: Scratches::Warm,
        row_major_and_split: true,
    };
    ab_harness(&compiled, &opts).fused
}

/// [`ab_harness`] under each parameter map, on a fresh scratch per
/// evaluation with the latched fault compared, at three states seeded in
/// `[-2, 2)`. Returns the fused program.
pub(super) fn ab(compiled: &ArrayCompiled, param_maps: &[HashMap<String, f64>]) -> TapeProgram {
    let opts = AbOptions {
        params: param_maps,
        seeds: 3,
        lo: -2.0,
        hi: 2.0,
        times: &[0.0, 0.7],
        scratches: Scratches::FreshWithFaults,
        row_major_and_split: false,
    };
    ab_harness(compiled, &opts).fused
}

/// Compare the fused and unfused tapes, in both executors, against the
/// oracle at one state, time and parameter map: `dy` bit for bit and the
/// latched fault.
pub(super) fn compare_tape_at(
    compiled: &ArrayCompiled,
    params: &HashMap<String, f64>,
    state: &[f64],
    t: f64,
) {
    compare_fresh(compiled, &[Arm::Fused, Arm::Unfused], params, state, t);
}

/// [`ab_harness`] on `doc` built under its own precision environment, with
/// no parameters on warm scratches, at four states seeded in `[0.25, 2.5)`.
/// Returns the fused program and the unfused one's length.
pub(super) fn oracle_ab(doc: Value) -> (TapeProgram, usize) {
    let file = typed(doc);
    let env = crate::precision_infer::env_of_file(&file).expect("precision environment");
    let file = crate::precision_infer::annotated(&file)
        .expect("precision inference")
        .unwrap_or(file);
    let _env = env.enter();
    let compiled = ArrayCompiled::from_file(&file).expect("fixture compiles");
    let opts = AbOptions {
        params: &no_params(),
        seeds: 4,
        lo: 0.25,
        hi: 2.5,
        times: &[0.0, 0.37, 2.5],
        scratches: Scratches::Warm,
        row_major_and_split: false,
    };
    let out = ab_harness(&compiled, &opts);
    (out.fused, out.unfused_len)
}

/// The tape's refusals when it refuses any rule; otherwise [`compare_tape_at`] at
/// each of `states` under each parameter map, and no refusals.
pub(super) fn agrees_or_refuses(
    compiled: &ArrayCompiled,
    param_maps: &[HashMap<String, f64>],
    states: &[Vec<f64>],
) -> Vec<(String, String)> {
    let (_, report) = compiled.build_tape_opts(&HashSet::new(), Some(superop_cfg()));
    if !report.fallbacks.is_empty() {
        return report.fallbacks;
    }
    for params in param_maps {
        for state in states {
            compare_tape_at(compiled, params, state, 0.0);
        }
    }
    Vec::new()
}

pub(super) fn no_params() -> Vec<HashMap<String, f64>> {
    vec![HashMap::new()]
}

/// How many instructions of `prog` satisfy `pred`.
pub(super) fn count_where(prog: &TapeProgram, pred: impl Fn(&Instr) -> bool) -> usize {
    all_instrs(prog).filter(|i| pred(i)).count()
}

/// Every instruction of `prog` and of each function it calls (each function
/// once: an operator definition is compiled once, however often it is called).
pub(super) fn all_instrs(prog: &TapeProgram) -> impl Iterator<Item = &Instr> {
    prog.instrs
        .iter()
        .chain(prog.funcs.iter().flat_map(|f| f.instrs.iter()))
}

/// How many instructions of a given opcode the program carries.
pub(super) fn opcount(prog: &TapeProgram, opcode: &str) -> usize {
    count_where(prog, |i| i.opcode() == opcode)
}

/// The operator node `o(args…)`.
pub(super) fn op(o: &str, args: Vec<Value>) -> Value {
    json!({"op": o, "args": args})
}

/// `v[subs…]`.
pub(super) fn ix(v: &str, subs: Vec<Value>) -> Value {
    let mut args = vec![json!(v)];
    args.extend(subs);
    json!({"op": "index", "args": args})
}

/// `base[subs…]`, `base` any expression.
pub(super) fn idx(base: Value, subs: &[Value]) -> Value {
    let mut args = vec![base];
    args.extend(subs.iter().cloned());
    json!({"op": "index", "args": args})
}

/// The `faq` over `ranges` with output indices `out` and body `expr`.
pub(super) fn faq(out: &[&str], ranges: Value, expr: Value) -> Value {
    json!({"op": "faq", "args": [], "output_idx": out, "ranges": ranges, "expr": expr})
}

/// The `faq` of `body` over `i ∈ [1, n]`.
pub(super) fn agg(n: i64, body: Value) -> Value {
    faq(&["i"], json!({"i": [1, n]}), body)
}

/// `D(var[out…])` over `ranges`.
pub(super) fn d_lhs(var: &str, out: &[&str], ranges: Value) -> Value {
    let subs = out.iter().map(|s| json!(s)).collect();
    faq(
        out,
        ranges,
        json!({"op": "D", "args": [ix(var, subs)], "wrt": "t"}),
    )
}

/// `D(var[out…]) = rhs` over `ranges`, `rhs` the body of each cell.
pub(super) fn d_eq_over(var: &str, out: &[&str], ranges: Value, rhs: Value) -> Value {
    json!({
        "lhs": d_lhs(var, out, ranges.clone()),
        "rhs": faq(out, ranges, rhs)
    })
}

/// `D(var[i]) = rhs` over `i ∈ [1, n]`, `rhs` the body of each cell.
pub(super) fn d_eq(var: &str, n: i64, rhs: Value) -> Value {
    d_eq_over(var, &["i"], json!({"i": [1, n]}), rhs)
}

/// `D(var[i])` over `i ∈ [1, n]` equal to the whole right-hand side `rhs`.
pub(super) fn d_eq_with_rhs(var: &str, n: i64, rhs: Value) -> Value {
    let mut eq = d_eq(var, n, Value::Null);
    eq["rhs"] = rhs;
    eq
}

/// The periodic-wrap index idiom the lat-lon discretization emits:
/// `ifelse(inner < lo, inner + P, ifelse(inner > hi, inner - P, inner))`.
pub(super) fn wrap(inner: Value, lo: i64, hi: i64) -> Value {
    let p = hi - lo + 1;
    op(
        "ifelse",
        vec![
            op("<", vec![inner.clone(), json!(lo)]),
            op("+", vec![inner.clone(), json!(p)]),
            op(
                "ifelse",
                vec![
                    op(">", vec![inner.clone(), json!(hi)]),
                    op("-", vec![inner.clone(), json!(p)]),
                    inner,
                ],
            ),
        ],
    )
}

pub(super) fn plus(a: Value, b: Value) -> Value {
    json!({"op": "+", "args": [a, b]})
}

pub(super) fn minus(a: Value, b: Value) -> Value {
    json!({"op": "-", "args": [a, b]})
}

/// The literal `const` node holding `v`.
pub(super) fn konst(v: Value) -> Value {
    json!({"op": "const", "args": [], "value": v})
}

/// The literal `const` array `v`.
pub(super) fn lit(v: &[f64]) -> Value {
    konst(json!(v))
}

/// `name` applied with `bindings`.
pub(super) fn apply(name: &str, bindings: Value) -> Value {
    json!({"op": "apply_operator", "args": [], "name": name, "bindings": bindings})
}

/// The `expression_templates` of the repository library `lib/<file>`.
pub(super) fn library(file: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../lib")
        .join(file);
    let text = std::fs::read_to_string(&path).expect("library file");
    let lib: Value = serde_json::from_str(&text).expect("library parses");
    lib["operators"].clone()
}

/// A one-model document named `name`, with `domain` when given.
pub(super) fn named_doc(
    name: &str,
    variables: Value,
    equations: Vec<Value>,
    domain: Option<Value>,
) -> Value {
    let mut d = json!({
        "esm": "2.0.0",
        "metadata": {"name": name},
        "models": {"M": {"variables": variables, "equations": equations}}
    });
    if let Some(dom) = domain {
        d["domain"] = dom;
    }
    d
}

/// A document named `name` declaring the index sets `sets`, with `model` as
/// its one model.
pub(super) fn document(name: &str, sets: Value, model: Value) -> Value {
    json!({"esm": "2.0.0", "metadata": {"name": name}, "index_sets": sets, "models": {"M": model}})
}

/// The one-model document of the array-form tests.
pub(super) fn doc(vars: Value, eqs: Vec<Value>) -> Value {
    named_doc("tape_array_forms", vars, eqs, None)
}

/// [`oracle_ab`] at two grid sizes, requiring the same lowered program length
/// (the unfused one: fusion's grouping may differ with the box size).
pub(super) fn flat_in_n(make: impl Fn(i64) -> Value, small: i64, large: i64) -> TapeProgram {
    let (_, a) = oracle_ab(make(small));
    let (b, b_len) = oracle_ab(make(large));
    assert_eq!(
        a, b_len,
        "the program must not grow with the grid ({small} vs {large} cells)"
    );
    b
}

/// The `Instr::Count`s of `prog`, as `(rel, sorted)`.
pub(super) fn counts(prog: &TapeProgram) -> Vec<(CountRel, bool)> {
    all_instrs(prog)
        .filter_map(|i| match i {
            Instr::Count { rel, sorted, .. } => Some((*rel, *sorted)),
            _ => None,
        })
        .collect()
}
