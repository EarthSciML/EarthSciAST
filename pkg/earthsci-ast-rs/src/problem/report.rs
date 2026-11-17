//! The compiler report every Problem carries, and the compiler's gate over
//! the rule set (esm-libraries-spec §2.5.10).

use super::*;

/// Build the per-rule record, and — under a STRICT compiler ([`Compiler::Native`]
/// or [`Compiler::Xla`]) — REFUSE the document when any rule failed to lower
/// (esm-libraries-spec §2.5.10).
///
/// This is the whole of that strictness, and it lives at construction for the
/// reason §2.5.2 gives: a document that never became a Problem has no run to
/// describe, so a build failure must be raised where the build happens.
///
/// **It gates more than the right-hand side.** §2.5.10 puts "the
/// materialization of constants and static observeds at construction, the
/// per-segment seed, the right-hand side, and the observeds reported at output
/// times" all under the refusal. In this binding every one of those is an
/// evaluation of the SAME rule set, so one gate over the rule set covers them
/// all — and the driver then SERVES those passes from the tape under both
/// strict compilers (`simulate_array::driver`), which is what makes the gate honest rather than merely necessary.
///
/// `xla` is gated HERE as well as by its emitter, and the order matters: this
/// gate names the rule, its component and its cadence tier, while an emitter
/// refusal names only the rule as the compiled model spells it, or the
/// instruction it choked on. A rule that never reached the tape is therefore
/// reported here, in full.
pub(super) fn build_compiler_report(
    backend: &Backend,
    model_name: Option<&str>,
    compiler: Compiler,
    discrete_forcing: &std::collections::HashSet<String>,
    #[cfg_attr(not(feature = "solve"), allow(unused_variables))] p: &HashMap<String, f64>,
    #[cfg_attr(not(feature = "solve"), allow(unused_variables))] t0: f64,
) -> Result<CompilerReport, SimulateError> {
    let compiled = match backend {
        // No compiled model. A state-free document's observed graph was
        // evaluated — and gated — by `static_observed_fields`, whose rows the
        // caller adds.
        Backend::Static(_) => return Ok(CompilerReport::empty(compiler)),
        Backend::Array(c) => c,
    };
    // Before either compiler's own gate, so both refuse a live envelope
    // factor the same way (CONFORMANCE_SPEC §5.5.6).
    compiled
        .refuse_live_overlap_factors()
        .map_err(|e| compiled.show_error(e))?;
    #[cfg_attr(not(feature = "solve"), allow(unused_mut))]
    let mut report = rule_report(compiled, model_name, compiler, discrete_forcing, true)?;
    // The field initial conditions are evaluated outside the compiled rule
    // set — the interpreter walks them per cell, the other compilers lower
    // what it would walk on a standalone tape — so they are exercised HERE,
    // where a strict compiler refuses one the tape declines, and reported
    // ahead of the model's rules.
    #[cfg(feature = "solve")]
    {
        let model = model_name.unwrap_or("");
        let mut ic_rows = Vec::new();
        // An `ic` that reads a state has no value at the start of the run
        // (esm-spec §11.4.2): refused before anything evaluates one.
        compiled
            .refuse_ic_state_reads()
            .map_err(|e| compiled.show_error(e))?;
        for r in compiled.field_ic_records(p, t0, discrete_forcing) {
            let route = match r.route {
                Ok(route) => route,
                Err(declined) => {
                    return Err(SimulateError::Compile(
                        crate::compile_error::CompileError::CompilerRefusedRule {
                            compiler: compiler.as_str(),
                            kind: r.kind,
                            rule: qualify(model, &r.name),
                            tier: "const",
                            reason: format!(
                                "evaluated at setup, and a `faq` in it would be walked once \
                                 per cell; the tape declined it: {declined}; {}",
                                crate::simulate_array::ONE_CELL_NOTE
                            ),
                        },
                    ));
                }
            };
            ic_rows.push(build_time_row(
                compiler,
                qualify(model, &r.name),
                r.kind,
                route,
            ));
        }
        report.rules.splice(0..0, ic_rows);
    }
    Ok(report)
}

/// The report row of one evaluation construction performs OUTSIDE the
/// compiled model's rule set, at setup (`"const"`), served by `route`.
///
/// Under [`Compiler::Interpreter`] every such row is the per-cell oracle, by
/// design, and carries no reason, exactly as its rule rows do. Elsewhere the
/// tier says what served it: `"vectorized"` for the reference evaluator over
/// whole arrays with no cell walked, `"taped"` for a standalone tape.
pub(super) fn build_time_row(
    compiler: Compiler,
    rule: String,
    kind: &'static str,
    route: crate::simulate_array::BuildRoute,
) -> CompilerRuleReport {
    use crate::simulate_array::BuildRoute;
    let tier = match route {
        _ if compiler == Compiler::Interpreter => "oracle",
        BuildRoute::Whole => "vectorized",
        BuildRoute::Tape => "taped",
        BuildRoute::PerCell => "oracle",
    };
    CompilerRuleReport {
        rule,
        kind,
        cadence: "const",
        tier,
        reason: None,
    }
}

/// The per-rule record of one compiled model, refusing under a strict compiler
/// the first rule that did not lower ([`build_compiler_report`]).
///
/// `xla_emitted` says whether the model's right-hand side is the emitted XLA
/// program. A state-free model has none, so under [`Compiler::Xla`] its rules
/// are reported as the tape's, which is what evaluates them.
pub(super) fn rule_report(
    compiled: &ArrayCompiled,
    model_name: Option<&str>,
    compiler: Compiler,
    discrete_forcing: &std::collections::HashSet<String>,
    xla_emitted: bool,
) -> Result<CompilerReport, SimulateError> {
    let (records, tape_report) = compiled.tape_rule_records(discrete_forcing);
    let model = model_name.unwrap_or("");
    let mut rules = Vec::with_capacity(records.len());
    for r in records {
        let qualified = qualify(model, &r.name);
        if compiler.is_strict()
            && let Some(reason) = &r.fallback_reason
        {
            return Err(SimulateError::Compile(
                crate::compile_error::CompileError::CompilerRefusedRule {
                    compiler: compiler.as_str(),
                    kind: r.kind,
                    rule: qualified,
                    tier: r.cadence,
                    reason: reason.clone(),
                },
            ));
        }
        let tier = match (compiler, &r.fallback_reason) {
            // Under `interpreter` the tape is never installed, so every rule
            // runs on the per-cell oracle by design — not as a decline. The
            // tape build above ran only to classify each rule's cadence and is
            // discarded; it evaluates nothing.
            (Compiler::Interpreter, _) => "oracle",
            // Under `xla` the gate above has already refused anything that did
            // not lower, so every rule reaching here is in the emitted
            // program. It is reported as `"xla"` rather than as `"taped"`
            // because the tape is where it was lowered FROM, not what
            // evaluates it.
            (Compiler::Xla, _) if xla_emitted => "xla",
            (_, None) => "taped",
            (_, Some(_)) => "fallback",
        };
        rules.push(CompilerRuleReport {
            rule: qualified,
            kind: r.kind,
            cadence: r.cadence,
            tier,
            // Under `interpreter` there is no decline to report: the tape was
            // never going to run, so what it would have said about a rule is
            // not this compiler's story.
            reason: match compiler {
                Compiler::Interpreter => None,
                _ => r.fallback_reason,
            },
        });
    }
    let (fused_groups, fused_instructions) = if compiler == Compiler::Interpreter {
        (0, 0)
    } else {
        (tape_report.fuse.n_groups, tape_report.fuse.n_member_instrs)
    };
    Ok(CompilerReport {
        compiler,
        rules,
        fused_groups,
        fused_instructions,
    })
}

/// Why a compiler in the vocabulary cannot be provided here, and what would
/// provide it (esm-libraries-spec §2.5.10: the message names what to load or
/// build). `None` for the two this binding implements.
///
/// A refusal, never a substitution — answering `xla` by building `native`
/// would make the compiler's name describe nothing, which is the failure
/// §2.5.10 exists to prevent.
pub(super) fn unavailable_reason(compiler: Compiler) -> Option<String> {
    match compiler {
        Compiler::Native | Compiler::Interpreter => None,
        Compiler::Xla => xla_unavailable_reason(),
        Compiler::Mtk => Some(
            "a ModelingToolkit system needs Julia and ModelingToolkit.jl, and this binding has \
             no ModelingToolkit runtime to load; `mtk` is provided by the Julia binding"
                .to_string(),
        ),
        Compiler::Sympy => Some(
            "a lambdified SymPy right-hand side needs Python and SymPy, and this binding has \
             neither; `sympy` is provided by the Python binding"
                .to_string(),
        ),
    }
}

/// Whether `xla` can be provided by THIS build and THIS process, and what is
/// missing when it cannot.
///
/// `xla` is the specialty compiler that needs a heavy external dependency, and
/// the dependency can be absent in two different places: the crate can be
/// built without the `xla` feature, or it can have the feature and still find
/// no usable XLA runtime to start (no unpacked `xla_extension`, no device for
/// the requested platform). Both are `compiler_unavailable` and neither says
/// anything about what the emitter can lower, so both are answered here —
/// BEFORE any document is looked at, so the answer is a property of the build
/// and not of the input.
///
/// The client is a process-wide singleton and caches its own failure, so
/// probing it per Problem costs one atomic read after the first.
#[cfg(feature = "xla")]
pub(super) fn xla_unavailable_reason() -> Option<String> {
    crate::xla_runtime::client().err().map(|e| {
        format!(
            "this build has the `xla` feature, but no usable XLA runtime in this process: {e}. \
             Point XLA_EXTENSION_DIR at an unpacked xla_extension release \
             (scripts/fetch-xla-extension.sh) and rebuild against it"
        )
    })
}

#[cfg(not(feature = "xla"))]
pub(super) fn xla_unavailable_reason() -> Option<String> {
    Some(
        "this binding's StableHLO emitter over the tape is behind the `xla` Cargo feature, \
         which this build does not have: rebuild with `--features xla` and XLA_EXTENSION_DIR \
         pointing at an unpacked xla_extension release (scripts/fetch-xla-extension.sh)"
            .to_string(),
    )
}

/// Emit and compile the right-hand side for [`Compiler::Xla`], once, on the
/// backend the build just produced.
///
/// A no-op for every other compiler, and for a backend with no right-hand side
/// to emit: a state-free document is not integrated, so no compiler is chosen
/// for it and there is nothing to lower.
///
/// The two failures are kept apart, because they say different things:
///
///   * the emitter REFUSED this model — a named
///     [`CompileError::CompilerRefusedRule`], the same failure a rule the tape
///     could not lower raises, so a caller (and the compiler-agreement tier)
///     reads one shape whichever half declined;
///   * the XLA runtime broke — [`SimulateError::CompilerUnavailable`], which
///     is a fact about this process and says nothing about the document.
pub(super) fn install_xla_program(
    backend: &Backend,
    model_name: Option<&str>,
    compiler: Compiler,
) -> Result<(), SimulateError> {
    // `model_name` is read only on the `xla` build; without the feature the
    // whole body is the early return, and `compiler` is already known to be
    // something this build provides.
    let _ = (backend, model_name);
    if compiler != Compiler::Xla {
        return Ok(());
    }
    #[cfg(feature = "xla")]
    {
        use crate::xla_runtime::CompileRhsError;
        let Backend::Array(compiled) = backend else {
            return Ok(());
        };
        if !compiled.has_differential_equations() {
            return Ok(());
        }
        match compiled.install_xla_rhs() {
            Ok(()) => Ok(()),
            Err(CompileRhsError::Refused(e)) => {
                Err(SimulateError::Compile(
                    crate::compile_error::CompileError::CompilerRefusedRule {
                        compiler: Compiler::Xla.as_str(),
                        // The emitter refuses per INSTRUCTION, and an instruction
                        // belongs to a rule whose kind it does not carry, so the
                        // kind is the neutral one rather than a guess between
                        // "observed" and "state derivative".
                        kind: "rule",
                        rule: qualify(model_name.unwrap_or(""), &e.rule),
                        // The emitted program computes every cadence section on
                        // every call (`xla_emit`'s module docs), so a refusal
                        // anywhere in it costs on the continuous schedule.
                        tier: "continuous",
                        reason: e.reason,
                    },
                ))
            }
            Err(CompileRhsError::Runtime(details)) => Err(SimulateError::CompilerUnavailable {
                compiler: Compiler::Xla.as_str(),
                details,
            }),
        }
    }
    #[cfg(not(feature = "xla"))]
    {
        // Unreachable: `compile_backend` answered `compiler_unavailable` for
        // `xla` before any backend existed.
        Ok(())
    }
}
