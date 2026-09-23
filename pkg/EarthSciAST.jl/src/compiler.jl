# ============================================================
# Choosing the compiler (API_SPEC §5.8, esm-libraries-spec §2.5.10)
# ============================================================
#
# `compiler` names the strategy that builds a problem's right-hand side. The
# vocabulary is closed and identical in every binding; this file holds Julia's
# side of it: the vocabulary, the per-tier PLAN each value expands to, the
# per-build REPORT that says which tier every rule landed on, and the refusal
# helper the strict `native` compiler raises through.
#
# The plan is the ONLY place a tier reads its own on/off state from. No
# environment variable selects an evaluation strategy: the vocabulary value is
# the whole answer, so an environment and an argument have nothing to disagree
# about (esm-libraries-spec §2.5.10). What survives in `ENV` is the tuning
# thresholds — a node budget, a function-size cap, a threading floor, an
# admission floor — each of which is a REFUSAL BOUNDARY under `native` rather
# than a fallback trigger, and two experimental tiers that ship off.

"""
    COMPILER_VOCABULARY

The closed set of `compiler` values (esm-libraries-spec §2.5.10), in the order
the spec lists them. A value outside it raises `compiler_unknown`; a value in
it that this binding cannot provide raises `compiler_unavailable`. Neither is
ever answered by building with a different compiler.
"""
const COMPILER_VOCABULARY = (:interpreter, :native, :xla, :mtk, :sympy)

# ---------------------------------------------------------------------------
# The plan: one Bool per tier, derived from the vocabulary value
# ---------------------------------------------------------------------------
#
# Every field is "this tier may run". `native` has them all true; `interpreter`
# has them all false. A field exists here for a tier only when turning it off
# changes which evaluator runs — a tuning threshold (a node budget, a cell
# floor) is a different thing and stays where it is, and so is MEMOIZATION.
#
# MEMOIZATION IS NOT A TIER. The load-time expansion memo
# (`_expand_expr_refs`) and the reference-preserving template image
# (`lower_expression_templates`) make the same program out of the same
# document; what they save is build wall time, not a tree walk per cell. So
# `interpreter` keeps both: an oracle that re-derives the program it is about
# to compare against would be a slower way to build the SAME answer, and on the
# documents it exists to run it is the difference between minutes and hours.
struct CompilerPlan
    name::Symbol          # the vocabulary value this plan implements
    strict::Bool          # refuse a rule this compiler cannot express
    # ---- kernel emission ----
    codegen::Bool                 # the RuntimeGeneratedFunction emitter
    dual_codegen::Bool            # its overflow (typemax-budget) second pass
    f64_overflow::Bool            # …also serving Float64 calls
    codegen_body_split::Bool
    cg_foreign_scratch::Bool
    cg_helper_dedup::Bool
    # ---- the array cascade ----
    stencil::Bool                 # the affine stencil tier
    array_contraction::Bool
    contraction_loop::Bool
    subtree_tbl::Bool
    state_box::Bool
    obsref::Bool
    lane_affine_key::Bool
    xeq_variant::Bool
    join_on_gate::Bool
    # ---- kernel assembly ----
    oop_merge::Bool               # kernel-class merges (both spellings)
    oop_merge_expand::Bool
    oop_batch::Bool
    direct_class_emit::Bool
    cross_eq_class_emit::Bool
    lane_intern::Bool
    xcse::Bool
    # ---- prelude cadence ----
    tiered::Bool                  # the const/time cadence tiers
    tcadence::Bool
    # ---- build-once machinery whose OFF state is a reference path ----
    intern::Bool
    setup_map_compile_once::Bool
    geom_sweep_specialize::Bool
    geom_overlap_gate::Bool
end

# Threading is deliberately NOT a plan field. A chunked kernel is
# value-identical to the serial one by construction — the chunks write disjoint
# slots — so it is not a choice of evaluator; how many cells are worth a thread
# dispatch is a tuning threshold (`ESS_THREADS_MIN_CELLS`), read on the
# right-hand-side call where the build's plan is no longer in scope.

_plan_all(name::Symbol, strict::Bool, on::Bool) =
    CompilerPlan(name, strict,
                 on, on, on, on, on, on,
                 on, on, on, on, on, on, on, on, on,
                 on, on, on, on, on, on, on,
                 on, on,
                 on, on, on, on)

"""
    _compiler_plan(compiler::Symbol) -> CompilerPlan

Expand a vocabulary value into the tier plan that implements it. Raises for the
values this binding does not provide, never substituting another one.
"""
function _compiler_plan(compiler::Symbol)
    if compiler === :native
        return _plan_all(:native, true, true)
    elseif compiler === :interpreter
        return _plan_all(:interpreter, false, false)
    elseif compiler === :xla
        # The specialty compiler that needs a HEAVY EXTERNAL DEPENDENCY: the
        # direct StableHLO emitter, which exists only with Reactant in the
        # session. `_xla_extension` raises `compiler_unavailable` when it is
        # not, which is the right failure for a value that IS in the
        # vocabulary, and the device is resolved to a client here too — a
        # mistyped `EARTHSCI_JULIA_XLA_DEVICE` is an `ArgumentError`, a GPU
        # this process does not have is `compiler_unavailable` — so neither
        # waits for a load, a flatten and a build. Everything else about the
        # lane is in compiler_xla.jl.
        # The PLAN is `native`'s: the emitter lowers the compiled tree-walk
        # intermediate representation, so the tiers that build it all run, and
        # they run strictly — a rule `native` would refuse is a rule `:xla` has
        # no program for either.
        _xla_extension()
        _xla_client(_xla_device())
        return _plan_all(:xla, true, true)
    elseif compiler === :mtk
        # VOCABULARY FIRST, AVAILABILITY SECOND. `:mtk` is a member of the
        # closed vocabulary, so a session without ModelingToolkit hears
        # `compiler_unavailable` naming what to load — never `compiler_unknown`,
        # which would say the value does not exist.
        #
        # `:mtk` is a SPECIALTY compiler: it works only for some documents, and
        # it is the one that runs EVENTS and IMPLICIT EQUATIONS (the constructs
        # CONFORMANCE_SPEC §5.39 has every other evaluator refuse). `:native`
        # remains the universally fast default with no heavy external
        # dependency; `:interpreter` remains the simple oracle that checks them.
        Base.get_extension(EarthSciAST, :EarthSciASTMTKExt) === nothing &&
            throw(SimulateError(
                "compiler=:mtk builds a ModelingToolkit `System` and needs " *
                "ModelingToolkit loaded — add `using ModelingToolkit` so the " *
                "EarthSciASTMTKExt extension activates. It is a SPECIALTY " *
                "compiler that runs only some documents (it is the one that runs " *
                "events and implicit equations); compiler=:native is the " *
                "universally fast default",
                ERROR_CODES.COMPILER_UNAVAILABLE))
        # Every `native` tier is OFF: this compiler emits nothing of this
        # package's own, so a tier flag would describe a cascade that never
        # runs. `strict` stays TRUE — `:mtk` refuses a document it cannot
        # express by name (`compiler_refused_rule`) rather than building part
        # of it, which is what `_refuse_rule` reads off the plan in force.
        return _plan_all(:mtk, true, false)
    elseif compiler === :sympy
        throw(SimulateError(
            "compiler=:sympy is a Python-binding compiler (a lambdified SymPy " *
            "scalar right-hand side) and has no Julia implementation; use " *
            "compiler=:native, or the Python binding's esm_problem(..., " *
            "compiler=\"sympy\")",
            ERROR_CODES.COMPILER_UNAVAILABLE))
    end
    throw(SimulateError(
        "compiler=:$compiler is outside the vocabulary; it is one of " *
        join((":" * String(v) for v in COMPILER_VOCABULARY), ", "),
        ERROR_CODES.COMPILER_UNKNOWN))
end

# The plan in force. Task-local so a nested build cannot leak its plan into the
# caller's, with a process-wide default for the entry points that never go
# through `_with_compiler_plan` (a direct `_compile` call in a test, say).
# `Base.ScopedValues` would say this more directly but is 1.11+, and this
# package supports 1.10. That default is NON-strict: outside a build there is
# no `compiler` keyword to have been strict about, and a refusal raised there
# would name a compiler nobody asked for.
const _COMPILER_PLAN_KEY = :earthsci_compiler_plan
const _DEFAULT_COMPILER_PLAN = _plan_all(:native, false, true)

_compiler_plan_now()::CompilerPlan =
    get(task_local_storage(), _COMPILER_PLAN_KEY, _DEFAULT_COMPILER_PLAN)

_with_compiler_plan(f, plan::CompilerPlan) =
    task_local_storage(f, _COMPILER_PLAN_KEY, plan)

# The plan a `compiler` keyword produces. The keyword has no "unset" value: a
# caller who names nothing gets the strict `:native` a caller who names it
# gets, because a default that was quietly more permissive than the same value
# spelled out is the second way of saying the same thing that §2.5.10 exists to
# remove.
_plan_for(compiler::Symbol) = _compiler_plan(compiler)

# ---------------------------------------------------------------------------
# The report: which tier each rule landed on
# ---------------------------------------------------------------------------

"""
    CompilerRuleRecord

One rule of one build: an equation, an observed, or a setup array, the tier it
landed on, and every decline it collected getting there.

* `rule` — the rule's identity, component-qualified the way the document spells
  it (a derivative target with its output axes, an observed's name, a setup
  array's name).
* `kind` — `:equation`, `:observed`, `:setup_array`, or `:rhs_program` for a
  compiler that emits ONE program for the whole assembled right-hand side
  (`:xla`) rather than lowering it rule by rule.
* `tier` — where it landed: `:affine`, `:scan`, `:array_contraction_codegen`,
  `:percell_build` (scalarized per output cell at BUILD, then compiled),
  `:codegen`, `:interpreter`, `:setup_compiled`, `:setup_percell`; and, on the
  `:rhs_program` row an `:xla` build adds, `:xla_direct_cpu` /
  `:xla_direct_gpu`, which name the emitter and the device together.
* `declines` — `tier => reason` for every tier that looked at this rule and
  passed, deepest reason last.
"""
struct CompilerRuleRecord
    rule::String
    kind::Symbol
    tier::Symbol
    declines::Vector{Pair{Symbol,Symbol}}
end

"""
    CompilerReport

What a build did, per rule. [`compiler_report`](@ref) returns one.

* `compiler` — the vocabulary value that built this problem.
* `rules` — a [`CompilerRuleRecord`](@ref) per equation / observed / setup
  array, in build order.
* `tally` — this build's cascade counters (the per-build twin of the
  process-global `_CASCADE_TALLY`), for the counts a per-rule row does not
  carry: emitted kernels, class merges, subtree-table rescues.

`tier_histogram(report)` folds `rules` into tier → count, which is what
`show(::EsmProblem)` prints.
"""
struct CompilerReport
    compiler::Symbol
    rules::Vector{CompilerRuleRecord}
    tally::Dict{Symbol,Int}
end
CompilerReport(compiler::Symbol) =
    CompilerReport(compiler, CompilerRuleRecord[], Dict{Symbol,Int}())

"""
    tier_histogram(report::CompilerReport) -> Vector{Pair{Symbol,Int}}

The report's rules folded into `tier => count`, ordered by descending count and
then by tier name, so two builds of the same document print the same line.
"""
function tier_histogram(r::CompilerReport)
    h = Dict{Symbol,Int}()
    for rec in r.rules
        h[rec.tier] = get(h, rec.tier, 0) + 1
    end
    out = collect(h)
    sort!(out; by = kv -> (-kv[2], String(kv[1])))
    return out
end

function Base.show(io::IO, r::CompilerReport)
    print(io, "CompilerReport(:", r.compiler, ", ", length(r.rules), " rules")
    for (tier, n) in tier_histogram(r)
        print(io, ", ", tier, "=", n)
    end
    print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", r::CompilerReport)
    println(io, "CompilerReport — compiler :", r.compiler)
    hist = tier_histogram(r)
    println(io, "  tiers: ",
            isempty(hist) ? "(no rules recorded)" :
            join(("$(t)=$(n)" for (t, n) in hist), ", "))
    for rec in r.rules
        print(io, "  ", rec.kind, " ", rec.rule, " → ", rec.tier)
        isempty(rec.declines) ||
            print(io, "  [declined: ",
                  join(("$(t):$(why)" for (t, why) in rec.declines), ", "), "]")
        println(io)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# The per-build record
# ---------------------------------------------------------------------------
#
# The process-global `_CASCADE_TALLY` cannot answer "what did THIS build do" —
# two builds in one session add into the same Dict, and a caller holding two
# problems cannot tell them apart. This record is per build: `build_evaluator`
# installs one for the duration of the build and the problem keeps it.
mutable struct _BuildRecord
    plan::CompilerPlan
    rules::Vector{CompilerRuleRecord}
    tally::Dict{Symbol,Int}
    # The rule the cascade is working on, so a decline raised several frames
    # deeper can name it. Empty between rules.
    current::String
    current_kind::Symbol
    declines::Vector{Pair{Symbol,Symbol}}
end
_BuildRecord(plan::CompilerPlan) =
    _BuildRecord(plan, CompilerRuleRecord[], Dict{Symbol,Int}(), "", :equation,
                 Pair{Symbol,Symbol}[])

const _BUILD_RECORD_KEY = :earthsci_build_record

_build_record()::Union{Nothing,_BuildRecord} =
    get(task_local_storage(), _BUILD_RECORD_KEY, nothing)

_with_build_record(f, rec::_BuildRecord) =
    task_local_storage(f, _BUILD_RECORD_KEY, rec)

# Name the rule the cascade is about to work on. Declines recorded while it is
# open attach to it; `_land_rule!` closes it.
function _open_rule!(rule::AbstractString, kind::Symbol)
    rec = _build_record()
    rec === nothing && return nothing
    rec.current = String(rule)
    rec.current_kind = kind
    empty!(rec.declines)
    return nothing
end

function _note_decline!(tier::Symbol, reason::Symbol)
    rec = _build_record()
    rec === nothing && return nothing
    push!(rec.declines, tier => reason)
    return nothing
end

function _land_rule!(tier::Symbol)
    rec = _build_record()
    rec === nothing && return nothing
    isempty(rec.current) && return nothing
    push!(rec.rules, CompilerRuleRecord(rec.current, rec.current_kind, tier,
                                        copy(rec.declines)))
    rec.current = ""
    empty!(rec.declines)
    return nothing
end

# A rule with no cascade stage of its own (a setup array, a materialized
# observed): one call, no open/close pair.
function _record_rule!(rule::AbstractString, kind::Symbol, tier::Symbol;
                       declines::Vector{Pair{Symbol,Symbol}} = Pair{Symbol,Symbol}[])
    rec = _build_record()
    rec === nothing && return nothing
    push!(rec.rules, CompilerRuleRecord(String(rule), kind, tier, declines))
    # Closing the rule matters as much as filing it: a label left open would be
    # read by the next refusal several stages later and name the wrong thing.
    rec.current == String(rule) && (rec.current = ""; empty!(rec.declines))
    return nothing
end

# The rule the cascade currently has open, for a refusal raised deeper than the
# stage that named it. `fallback` is what a refusal outside any single rule says
# — the assembled right-hand side belongs to every array equation at once, so
# there is no one rule to name.
_current_rule_label(fallback::AbstractString = "(unnamed rule)") =
    (rec = _build_record(); rec === nothing || isempty(rec.current) ?
     String(fallback) : rec.current)

function _finish_report(rec::_BuildRecord)
    return CompilerReport(rec.plan.name, copy(rec.rules), copy(rec.tally))
end

# ---------------------------------------------------------------------------
# The refusal
# ---------------------------------------------------------------------------

"""
    _refuse_rule(rule, reason) -> never returns

Raise `compiler_refused_rule` for the compiler in force. The message names the
compiler, the rule (component-qualified) and the deepest reason, which is the
shape §2.5.10 fixes and what the compiler-agreement tier reads back.
"""
function _refuse_rule(rule::AbstractString, reason::AbstractString)
    plan = _compiler_plan_now()
    throw(TreeWalkError(ERROR_CODES.COMPILER_REFUSED_RULE,
        "compiler=:$(plan.name) refuses '$rule': $reason"))
end

# True when the compiler in force refuses a rule it cannot express rather than
# demoting it. Every refusal site is guarded by this, so `:interpreter` — which
# is DEFINED as the slow path — never trips one.
_compiler_is_strict() = _compiler_plan_now().strict

"""
    _refuse_percell_evaluation(rule, what, cells) -> nothing or never returns

The refusal for a materialization that RESOLVES AND COMPILES the expression once
per cell. §2.5.10 puts every evaluation a compiler performs for the problem
under the refusal rule, not the right-hand side alone: the materialization of
constants and static observeds at construction, the initial-state seed and the
observeds reported at output times are each a place a binding walks the tree per
cell, and each of them makes the compiler's name describe nothing if it is
allowed to happen quietly.

A compile-once sweep that then evaluates an ALREADY COMPILED node per cell is
not one of these and never reaches here: what is refused is re-deriving the
program for every cell.
"""
function _refuse_percell_evaluation(rule::AbstractString, what::AbstractString,
                                    cells::Union{Nothing,Integer})
    _compiler_is_strict() || return nothing
    over = cells === nothing ? "" :
           ", over $cells cell" * (cells == 1 ? "" : "s")
    _refuse_rule(rule,
        "$what resolves and compiles the expression once per cell$over, " *
        "because the compile-once form declined it. That is a tree walk per " *
        "cell at construction time, which esm-libraries-spec §2.5.10 puts " *
        "under the same rule as the right-hand side. Build with " *
        "compiler=:interpreter to run it")
end
