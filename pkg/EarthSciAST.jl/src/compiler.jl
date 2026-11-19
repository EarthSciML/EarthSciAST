# ============================================================
# Choosing the compiler (API_SPEC §5.8, esm-libraries-spec §2.5.10)
# ============================================================
#
# `compiler` names the strategy that builds a problem's right-hand side, from a
# closed vocabulary shared by every binding. This file holds the vocabulary, the
# per-tier plan each value expands to, the per-build report of which tier every
# rule landed on, and the refusal helper the strict `native` compiler raises
# through.
#
# The plan is the only place a tier reads its on/off state from; no environment
# variable selects an evaluation strategy (esm-libraries-spec §2.5.10). The
# tuning thresholds left in `ENV` are refusal boundaries under `native`, not
# fallback triggers.

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
# Every field is "this tier may run": all true for `native`, all false for
# `interpreter`. A field exists only for a tier whose switch changes which
# evaluator runs. Tuning thresholds are not plan fields, and neither is
# memoization (the load-time expansion memo, `_expand_expr_refs`, and the
# reference-preserving template image, `lower_expression_templates`), which
# changes build time and not the program, so `interpreter` keeps it.
struct CompilerPlan
    name::Symbol          # the vocabulary value this plan implements
    strict::Bool          # refuse a rule this compiler cannot express
    # ---- kernel emission ----
    codegen::Bool                 # the RuntimeGeneratedFunction emitter
    scalar_codegen::Bool          # the scalar equations and the prelude (scalar_codegen.jl)
    # The emitted contraction loop's algebraic rewrites (array_contraction.jl):
    # the indicator sum emitted as a count. Off, the loop is the plain fold.
    count_fold::Bool
    # The scalar-spine emitters' sharing of a repeated sub-tree: computed once
    # per evaluation, read at each use. Off, every occurrence is emitted where
    # it stands.
    share_subtrees::Bool
    # ---- the array cascade ----
    stencil::Bool                 # the affine stencil tier
    array_contraction::Bool
    contraction_loop::Bool
    join_on_gate::Bool
    # ---- kernel assembly ----
    # Kernel-class merges: the per-cell entries of every equation pooled into
    # classes, both class-merge rounds over the assembled kernels, and the
    # out-of-place product's lane-batched scalar groups.
    oop_merge::Bool
    xcse::Bool
    # ---- prelude cadence ----
    tiered::Bool                  # the const/time cadence tiers
    tcadence::Bool
    # ---- build-once machinery whose OFF state is a reference path ----
    intern::Bool
    # Every construction-time compiled form: the fills of setup_fill.jl (setup
    # MAP and makearray, field `ic`, faq `initialization_equations`) and the
    # compile-once sweeps behind them (those, and `seed_expression_ic!`). Off,
    # each takes its per-cell reference form.
    setup_map_compile_once::Bool
    geom_overlap_gate::Bool
end

# Threading is not a plan field: a chunked kernel writes disjoint slots and is
# value-identical to the serial one; its floor is the tuning threshold
# `_Tuning.thread_min_work`.

# A plan by keyword: every tier flag defaults to `compiled` (all on for a
# compiling plan, all off for the interpreter's). Tests and bisections switch
# single tiers off by naming them.
function CompilerPlan(name::Symbol; strict::Bool, compiled::Bool, tiers...)
    flags = fieldnames(CompilerPlan)[3:end]
    for k in keys(tiers)
        k in flags || throw(ArgumentError("CompilerPlan: no tier flag `$k`"))
    end
    return CompilerPlan(name, strict, (Bool(get(tiers, f, compiled)) for f in flags)...)
end

_plan_all(name::Symbol, strict::Bool, on::Bool) = CompilerPlan(name; strict = strict, compiled = on)

# `plan` with the named fields replaced.
_plan_with(plan::CompilerPlan; kw...) =
    CompilerPlan((get(kw, f, getfield(plan, f)) for f in fieldnames(CompilerPlan))...)

# True when the construction-time compile-once forms may run (see the plan
# field). A compile-once form is not a per-cell route, so it is gated on this
# and never on a right-hand-side tier: `:mtk` turns every one of those off.
_setup_compile_once_enabled() = _compiler_plan_now().setup_map_compile_once

"""
    _compiler_plan(compiler::Symbol) -> CompilerPlan

Check that `compiler` is a vocabulary value this session can run
(`_check_compiler`) and expand it into the tier plan that implements it
(`_plan`). Raises for the values this binding does not provide, never
substituting another one.
"""
_compiler_plan(compiler::Symbol) = (_check_compiler(compiler); _plan(compiler))

"""
    _plan(compiler::Symbol) -> CompilerPlan

The tier plan of a vocabulary value already checked by `_check_compiler`: a
pure expansion, with no availability probe, for an evaluation on behalf of a
problem that compiler built.
"""
function _plan(compiler::Symbol)
    compiler === :native && return _plan_all(:native, true, true)
    compiler === :interpreter && return _plan_all(:interpreter, false, false)
    # `:xla`'s plan is `native`'s: the emitter lowers the compiled tree-walk
    # intermediate representation, so the tiers that build it all run, and
    # they run strictly — a rule `native` would refuse is a rule `:xla` has no
    # program for either.
    compiler === :xla && return _plan_all(:xla, true, true)
    # `:mtk`: every right-hand-side tier is OFF, since this compiler emits
    # nothing of this package's own; `strict` stays TRUE, so `:mtk` refuses a
    # document it cannot express by name (`compiler_refused_rule`). The
    # construction-time compile-once forms stay ON: ModelingToolkit owns the
    # right-hand side, not the evaluations this package still performs for the
    # problem (a `seed_ic!` hook's `seed_expression_ic!` above all), which run
    # under this plan strictly and so need the compiled-once form.
    compiler === :mtk &&
        return CompilerPlan(:mtk; strict = true, compiled = false, setup_map_compile_once = true)
    return _check_compiler(compiler)
end

"""
    _check_compiler(compiler::Symbol)

Raise `compiler_unknown` for a value outside the vocabulary and
`compiler_unavailable` for one this session cannot run; return `nothing`
otherwise.
"""
function _check_compiler(compiler::Symbol)
    if compiler === :native || compiler === :interpreter
        return nothing
    elseif compiler === :xla
        # Needs Reactant (`compiler_unavailable` without it). The device is
        # resolved here too, so a mistyped `EARTHSCI_JULIA_XLA_DEVICE`
        # (`ArgumentError`) or a missing GPU (`compiler_unavailable`) is reported
        # before any load. The lane itself is in compiler_xla.jl.
        _xla_extension()
        _xla_client(_xla_device())
        return nothing
    elseif compiler === :mtk
        # A vocabulary value, so a session without ModelingToolkit hears
        # `compiler_unavailable`, not `compiler_unknown`.
        Base.get_extension(EarthSciAST, :EarthSciASTMTKExt) === nothing &&
            throw(
            SimulateError(
                "compiler=:mtk builds a ModelingToolkit `System` and needs " *
                    "ModelingToolkit loaded — add `using ModelingToolkit` so the " *
                    "EarthSciASTMTKExt extension activates. It is a SPECIALTY " *
                    "compiler that runs only some documents (it is the one that runs " *
                    "events and implicit equations); compiler=:native is the " *
                    "universally fast default",
                ERROR_CODES.COMPILER_UNAVAILABLE
            )
        )
        return nothing
    elseif compiler === :sympy
        throw(
            SimulateError(
                "compiler=:sympy is a Python-binding compiler (a lambdified SymPy " *
                    "scalar right-hand side) and has no Julia implementation; use " *
                    "compiler=:native, or the Python binding's esm_problem(..., " *
                    "compiler=\"sympy\")",
                ERROR_CODES.COMPILER_UNAVAILABLE
            )
        )
    end
    throw(
        SimulateError(
            "compiler=:$compiler is outside the vocabulary; it is one of " *
                join((":" * String(v) for v in COMPILER_VOCABULARY), ", "),
            ERROR_CODES.COMPILER_UNKNOWN
        )
    )
end

# The plan in force is the build context's (below), with a process-wide default
# for the entry points that never go through `_with_compiler_plan` (a direct
# `_compile` call in a test, say). That default is NON-strict: outside a build
# there is no `compiler` keyword to have been strict about, and a refusal raised
# there would name a compiler nobody asked for.
const _DEFAULT_COMPILER_PLAN = _plan_all(:native, false, true)

_compiler_plan_now()::CompilerPlan =
    (c = _build_ctx(); c === nothing ? _DEFAULT_COMPILER_PLAN : c.plan)

_with_compiler_plan(f, plan::CompilerPlan) =
    _with_build_ctx(f, _ctx_with(_build_ctx(); plan = plan))

# The plan a `compiler` keyword produces; naming nothing is the strict `:native`.
_plan_for(compiler::Symbol) = _compiler_plan(compiler)
# The internal build entry (`_build_evaluator_impl`) also takes a plan, so a test
# can build with one no vocabulary value names (a non-strict `native`, say).
_plan_for(plan::CompilerPlan) = plan

# ---------------------------------------------------------------------------
# The report: which tier each rule landed on
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Declines: why a tier did not take a rule
# ---------------------------------------------------------------------------
#
# A tier that does not take a rule says so in ONE way: it throws (or, from a
# helper that tries a form and reports back, returns) a `_Decline` carrying a
# reason from the closed vocabulary below and a free-text detail. The cascade's
# driver catches it, files it against the rule with the tier's name
# (`_note_decline!`), and offers the rule to the next tier; a strict refusal
# then prints every decline the rule collected. Any other exception a tier
# raises is not a decline and propagates.

"""
    _DECLINE_REASONS

The closed vocabulary of decline reasons, `reason => meaning`, in the order
the `CompilerRuleRecord` docstring and API_SPEC §5.8 list them. A `_Decline`
with a reason outside it is a programming error.
"""
const _DECLINE_REASONS = (
    # Admission: the shape of the equation is not the tier's.
    :lhs_not_indexed_derivative => "the left-hand side is not `D(index(var, i…))`",
    :lhs_subscript_count => "the left-hand side's subscripts do not match the output indices",
    :no_output_index => "the equation has no output index",
    :no_contracted_index => "the equation has no contracted index",
    :range_not_unit_run => "an output range is empty or not a unit-step run",
    :below_floor => "the contraction is shorter than the tier's length floor",
    :tier_off => "the tier is off under this compiler",
    # The contraction.
    :gated_reduction => "a contraction with a join gate, whose terms vary per output cell",
    :filtered_reduction => "a contraction with a filter the tier cannot guard",
    :ragged_contraction => "a contracted range that is not a constant dense range",
    :contracted_axis_cut => "a contracted axis the box cut splits, so one fold cannot walk it in one piece",
    # The body.
    :symbolic_body_did_not_lower => "the body does not resolve or compile with its indices kept symbolic",
    :unsupported_op => "an operator the tier has no form for",
    :unknown_kind => "a compiled node kind the tier has no form for",
    :call_array_args => "a template call that passes arrays, in a context that has no array arguments (setup geometry)",
    :call_array_forward => "a template call, inside another call's body, passing on an array that is not that body's own array argument",
    :unknown_array => "a gather of a name that is not a known array",
    :malformed_index => "an `index` node with no operand",
    :subscript_rank_mismatch => "a gather whose subscript count is not the array's rank",
    :subscript_not_static => "a subscript that is not an integer function of the loop indices and build-time tables",
    :gathered_reduction_shape => "a gathered reduction whose output indices do not match its subscripts",
    :region_value_shape => "a `makearray` region value whose rank does not match the region",
    :region_multi_index => "a `makearray` region selected by a subscript of several loop indices",
    :guarded_out_of_range => "a constant subscript out of range under a run-time guard",
    :output_layout_not_affine => "the output cells' slots are not an affine function of the loop indices",
    :subtree_table_declined => "a build-time-evaluable subtree that the compile-once evaluator declined",
    # The one-pass equality scatter.
    :scatter_too_many_pinned_cells => "the equality filter pins more output cells than the scatter takes",
    :scatter_ragged_or_empty => "a scatter whose contracted range is ragged or empty",
    :scatter_ragged_reads_output => "a ragged scatter whose body reads its own output",
    # The code generator.
    :budget => "the generated code would exceed its node budget",
    :unsupported_desc => "an access descriptor the code generator has no form for",
    :unsupported_bound => "a loop bound the code generator cannot write",
    :foreign_scratch => "a read of a scratch buffer the generated function does not own",
    :subcall_order => "a sub-kernel call emitted before its invariants are in scope",
    :loopvar_out_of_scope => "a loop variable read outside the loop that binds it",
    :loop_reentered => "a loop entered again inside its own body",
    :lane_spec_on_scalar_spine => "a lane descriptor on a scalar spine",
    :cached_scalar_slot => "a cached scalar slot the generated function cannot read",
)

const _DECLINE_MEANING = Dict{Symbol, String}(_DECLINE_REASONS)

"""
    _Decline(reason, detail = "")

Why a tier did not take a rule: `reason` from [`_DECLINE_REASONS`](@ref), and
`detail` naming the construct. Thrown by a tier (`_decline`), or returned by a
helper whose caller decides; caught only by the cascade's driver and by the
code generator's per-kernel transaction.
"""
struct _Decline <: EarthSciASTError
    reason::Symbol
    detail::String
    function _Decline(reason::Symbol, detail::AbstractString = "")
        haskey(_DECLINE_MEANING, reason) || throw(
            ArgumentError("decline reason :$reason is outside the vocabulary (_DECLINE_REASONS)")
        )
        return new(reason, String(detail))
    end
end

_decline(reason::Symbol, detail::AbstractString = "") = throw(_Decline(reason, detail))

Base.showerror(io::IO, d::_Decline) =
    print(io, d.reason, isempty(d.detail) ? "" : " ($(d.detail))")

# A decline in words, for a refusal's sentence: its meaning, then its detail.
_decline_words(d::_Decline) =
    _DECLINE_MEANING[d.reason] * (isempty(d.detail) ? "" : " ($(d.detail))")

# One row of `CompilerRuleRecord.declines`.
const _DeclineRow = @NamedTuple{tier::Symbol, reason::Symbol, detail::String}

_decline_row(tier::Symbol, d::_Decline) = _DeclineRow((tier, d.reason, d.detail))

# A decline as a refusal prints it: `tier: reason (detail)`, the detail cut to
# `width` characters.
function _decline_text(r::_DeclineRow; width::Int = 200)
    isempty(r.detail) && return "$(r.tier): $(r.reason)"
    d = length(r.detail) > width ? first(r.detail, width) * "…" : r.detail
    return "$(r.tier): $(r.reason) ($d)"
end

"""
    _attempt(f, tier) -> f() | nothing

Run one tier's offer. A `_Decline` it raises is filed against the open rule
under `tier` and answered with `nothing`; anything else propagates.
"""
function _attempt(f, tier::Symbol)
    try
        return f()
    catch err
        err isa _Decline || rethrow()
        _note_decline!(tier, err)
        return nothing
    end
end

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
* `tier` — where it landed:
  - right-hand side: `:affine`, `:scan`, `:array_contraction_codegen`,
    `:empty_output` (an array equation over an empty output range: no cell to
    build or run), `:percell_build` (scalarized per output cell at BUILD, then
    compiled),
    `:codegen`, `:interpreter` (walked per cell as trees on every call);
    `:scalar_codegen` (a scalar equation emitted as generated code, with the
    other units of its structural class, by the scalar codegen tier) and
    `:scalar_loop_codegen` (the same, with a reduction kept as a runtime loop
    in that code); `:scalar` and `:scalar_loop` are those equations when the
    tier is off (`interpreter`) or could not model them: walked once per slot
    on every call by the scalar walker;
  - construction: `:setup_codegen` (filled through the right-hand-side cascade
    and emitted code, run once), `:setup_compiled` (compiled once, evaluated per
    cell),
    `:setup_loaded` (copied out of a supplied array), `:setup_constant`
    (evaluated once and filled), `:setup_percell` (resolved and compiled per
    cell), and `:discrete_percell` (a discrete-cadence field, resolved and
    compiled per cell at build and walked per cell at every data refresh;
    under `native` such a field is instead an `:observed` row on the
    right-hand-side tier its compiled fill landed on);
  - output time, added by `observed_field` the first time it reads a name:
    `:output_compiled_once` or `:output_percell`;
  - and, on the `:rhs_program` row an `:xla` build adds, `:xla_direct_cpu` /
    `:xla_direct_gpu`, which name the emitter and the device together.
  Under a strict compiler `:interpreter`, `:setup_percell`,
  `:discrete_percell` and `:output_percell` are refusals instead, and so is
  `:percell_build` in the in-place form, so a `native` report never shows them.
* `declines` — one `(tier, reason, detail)` named tuple for every tier that
  looked at this rule and passed, deepest last. `tier` names the tier
  (`:equality_scatter`, `:affine`, `:array_contraction`, …), `reason` is one
  of the closed vocabulary below, and `detail` is free text naming the
  construct (the operator, the variable, the error the body raised); it is
  `""` when the reason says it all. A strict refusal prints every decline
  with its detail.

Decline reasons (the closed vocabulary; [`_DECLINE_REASONS`] holds it with
the same words):

$(join(("  - `:$(k)` — $(v)" for (k, v) in _DECLINE_REASONS), "\n"))
"""
struct CompilerRuleRecord
    rule::String
    kind::Symbol
    tier::Symbol
    declines::Vector{_DeclineRow}
end
CompilerRuleRecord(rule::AbstractString, kind::Symbol, tier::Symbol) =
    CompilerRuleRecord(String(rule), kind, tier, _DeclineRow[])

"""
    CompilerReport

What a build did, per rule. [`compiler_report`](@ref) returns one.

* `compiler` — the vocabulary value that built this problem.
* `rules` — a [`CompilerRuleRecord`](@ref) per equation / observed / setup
  array, in build order.
* `tally` — this build's cascade counters, for the counts a per-rule row does
  not carry: emitted kernels, class merges, subtree-table rescues.

`tier_histogram(report)` folds `rules` into tier → count, which is what
`show(::EsmProblem)` prints.
"""
struct CompilerReport
    compiler::Symbol
    rules::Vector{CompilerRuleRecord}
    tally::Dict{Symbol, Int}
end
CompilerReport(compiler::Symbol) =
    CompilerReport(compiler, CompilerRuleRecord[], Dict{Symbol, Int}())

"""
    tier_histogram(report::CompilerReport) -> Vector{Pair{Symbol,Int}}

The report's rules folded into `tier => count`, ordered by descending count and
then by tier name, so two builds of the same document print the same line.
"""
function tier_histogram(r::CompilerReport)
    h = Dict{Symbol, Int}()
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
    return print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", r::CompilerReport)
    println(io, "CompilerReport — compiler :", r.compiler)
    hist = tier_histogram(r)
    println(
        io, "  tiers: ",
        isempty(hist) ? "(no rules recorded)" :
            join(("$(t)=$(n)" for (t, n) in hist), ", ")
    )
    for rec in r.rules
        print(io, "  ", rec.kind, " ", rec.rule, " → ", rec.tier)
        isempty(rec.declines) ||
            print(
            io, "  [declined: ",
            join(("$(d.tier):$(d.reason)" for d in rec.declines), ", "), "]"
        )
        println(io)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# The per-build record
# ---------------------------------------------------------------------------
#
# What ONE build did. `_build_evaluator_impl` installs a record for the duration
# of the build (task-local, so concurrent builds keep their own), and the
# finished report goes to the build's products and its problem.
mutable struct _BuildRecord
    plan::CompilerPlan
    rules::Vector{CompilerRuleRecord}
    tally::Dict{Symbol, Int}
    # The rule the cascade is working on, so a decline raised several frames
    # deeper can name it. Empty between rules.
    current::String
    current_kind::Symbol
    declines::Vector{_DeclineRow}
end
_BuildRecord(plan::CompilerPlan) =
    _BuildRecord(
    plan, CompilerRuleRecord[], Dict{Symbol, Int}(), "", :equation,
    _DeclineRow[]
)

_build_record()::Union{Nothing, _BuildRecord} =
    (c = _build_ctx(); c === nothing ? nothing : c.record)

_with_build_record(f, rec::_BuildRecord) =
    _with_build_ctx(f, _ctx_with(_build_ctx(); record = rec))

# ---------------------------------------------------------------------------
# The build context
# ---------------------------------------------------------------------------
#
# Everything that decides what ONE build produces and is not an argument: the
# plan, the record, the build's mutable scratch (`_BuildState`), its tuning
# (`_Tuning`, read from the environment once when the build starts) and the
# settings a caller fixes for everything it starts (a range spec, a workspace
# capture, the engagement-count sink, the merge re-check). It is installed
# under one task-local key, so two builds on two tasks never share any of it;
# concurrent builds are supported.
#
# The state is per build. `_build_evaluator_impl` starts every build with a
# fresh one (`_new_build_ctx`); an output-time compile, which builds against a
# layout of its own, starts a child (`_child_build_ctx`). Changing only the
# plan, the record or a caller setting (`_with_compiler_plan`,
# `_with_build_record`, `_with_range_spec`, …) keeps the state of the context it
# narrows. A caller setting reaches every build and child started inside it.

# A range-restricted program's spec (`_TileSpec`, `_LaneSpec`, `_CaptureSpec`;
# src/range/, src/rhs_program.jl, tree_walk/range_hooks.jl).
abstract type _RangeSpec end

# What a program build records for its workspaces (src/rhs_program.jl). A
# program's workspace is a private instance of its compiled right-hand side. The
# instance needs, by identity, the arrays through which the build reads each
# live buffer (its `_PGatherArray`s) and every array generated code writes at
# run time besides `du` and the per-call state types (a build registers each as
# scratch where it allocates it). A build with no capture open records nothing.
struct _WsCapture
    pgathers::Vector{Any}
    scratch::IdDict{Any, Nothing}
end
_WsCapture() = _WsCapture(Any[], IdDict{Any, Nothing}())

mutable struct _BuildState
    # A state array's slot map (table, run base, strides), by array name
    # (`_resolve_state_gather`). It depends on the layout the build resolves
    # against.
    slot_tables::Dict{String, Tuple{Vector{Int}, Int, Vector{Int}}}
    # A reserved runtime loop variable's counter `Ref`, by name: written where
    # the resolve keeps an index symbolic, read by `_compile(::VarExpr)`.
    loopvars::Dict{Symbol, Base.RefValue{Int}}
    # The counter that names those variables. A child state shares its parent's,
    # so a name is unique across a build and everything it starts.
    loopvar_count::Base.RefValue{Int}
    # Depth of the array-equation per-cell resolve (`_compile_faq_percell!`);
    # a scalar reduction nested inside one unrolls rather than loops.
    array_cell_depth::Int
    # The build-time parameter-read sink (`_with_param_reads`), or `nothing`.
    param_reads::Union{Nothing, Set{String}}
    # The kernels a shifted scatter's pieces compiled to, held out of the kernel
    # class merge (scatter.jl); `nothing` outside a build, where nothing is held
    # out.
    scatter_keep::Union{Nothing, IdDict{Any, Nothing}}
    # The scalar parameter values a join gate's computed key column reads while
    # the gates resolve (`_with_join_params`, join_key_columns.jl); empty otherwise.
    join_params::Dict{String, Float64}
    # The build's template call targets (`_CallTable`, tree_walk/call.jl), or
    # `nothing` when the build has no template registry. A child state shares
    # its parent's.
    calls::Any
    # While a call target's body compiles: its argument map (`_ArgMap`).
    argmap::Any
end
_BuildState(
    count::Base.RefValue{Int} = Ref(0);
    scatter_keep::Union{Nothing, IdDict{Any, Nothing}} = nothing,
    calls = nothing
) = _BuildState(
    Dict{String, Tuple{Vector{Int}, Int, Vector{Int}}}(),
    Dict{Symbol, Base.RefValue{Int}}(), count, 0, nothing, scatter_keep,
    Dict{String, Float64}(), calls, nothing
)

"""
    _Tuning

The build's tuning thresholds, read from the environment once when a build
starts (`_tuning_from_env`) and held on its `_BuildContext`, so every stage of
one build sees one value of each and a section's first call reads no
environment. None changes a computed value; the first two are refusal
boundaries under `compiler = :native` (crossing one decides whether a rule is
compiled or refused), the rest move work between equivalent forms.

| Field | Variable | Default | Meaning |
|---|---|---|---|
| `node_budget` | `ESS_CODEGEN_NODE_BUDGET` | 64,000,000 | emitted nodes one generated section may hold; past it the section is refused (strict) or walked |
| `contraction_loop_min` | `ESS_CONTRACTION_LOOP_MIN` | 8 | reduction length at and above which a scalar reduction loops at run time instead of unrolling |
| `array_contraction_min` | `ESS_ARRAY_CONTRACTION_MIN` | 1024 | reduction length at and above which an out-of-place array einsum takes the whole-array contraction nest |
| `fn_node_cap` | `ESS_CODEGEN_FN_NODE_CAP` | 20,000 | emitted nodes per generated sub-function before a body is split; 0 never splits |
| `split_transport` | `ESS_CODEGEN_SPLIT_TRANSPORT` | `""` | `"value"` or `"definition"` forces how split sub-functions are carried; empty decides by size |
| `by_value_min_nodes` | (`_CG_BY_VALUE_MIN_NODES[]`) | 100,000 | function size above which split sub-functions are carried by value |
| `thread_min_work` | `ESS_THREADS_MIN_WORK` | 6,000 | least node evaluations per chunk of a threaded section |

A non-numeric value falls back to the default; the two contraction floors
also ignore values below 1.
"""
struct _Tuning
    node_budget::Int
    contraction_loop_min::Int
    array_contraction_min::Int
    fn_node_cap::Int
    split_transport::String
    by_value_min_nodes::Int
    thread_min_work::Int
end

_env_int(name::String, default::Int) = something(tryparse(Int, get(ENV, name, "")), default)

function _env_floor(name::String, default::Int)
    n = tryparse(Int, get(ENV, name, ""))
    return (n === nothing || n < 1) ? default : n
end

_tuning_from_env() = _Tuning(
    _env_int("ESS_CODEGEN_NODE_BUDGET", 64_000_000),
    _env_floor("ESS_CONTRACTION_LOOP_MIN", 8),
    _env_floor("ESS_ARRAY_CONTRACTION_MIN", 1024),
    _env_int("ESS_CODEGEN_FN_NODE_CAP", 20_000),
    get(ENV, "ESS_CODEGEN_SPLIT_TRANSPORT", ""),
    _CG_BY_VALUE_MIN_NODES[],
    _env_int("ESS_THREADS_MIN_WORK", _THREAD_MIN_WORK_DEFAULT),
)

struct _BuildContext
    plan::CompilerPlan
    record::Union{Nothing, _BuildRecord}
    state::_BuildState
    tuning::_Tuning
    # Caller settings, inherited by every context started inside this one.
    range_spec::Union{Nothing, _RangeSpec}
    ws_capture::Union{Nothing, _WsCapture}
    # The engagement-count sink (`_with_counts`), or `nothing`.
    counts::Union{Nothing, Dict{Symbol, Int}}
    # Apply the kernel class merge twice and count what the second application
    # merges (tests only; `_merge_acc_kernel_classes`).
    merge_recheck::Bool
end

const _BUILD_CTX_KEY = :earthsci_build_context

_build_ctx()::Union{Nothing, _BuildContext} =
    get(task_local_storage(), _BUILD_CTX_KEY, nothing)

_with_build_ctx(f, ctx::_BuildContext) = task_local_storage(f, _BUILD_CTX_KEY, ctx)

# The open build's tuning, or the environment's now when no build is open.
_tuning_now()::_Tuning = (c = _build_ctx(); c === nothing ? _tuning_from_env() : c.tuning)

# A context over `state` with the tuning read now and `outer`'s caller
# settings (none when `outer` is `nothing`).
function _fresh_ctx(
        plan::CompilerPlan, record::Union{Nothing, _BuildRecord}, state::_BuildState,
        outer::Union{Nothing, _BuildContext}
    )
    return _BuildContext(
        plan, record, state, _tuning_from_env(),
        outer === nothing ? nothing : outer.range_spec,
        outer === nothing ? nothing : outer.ws_capture,
        outer === nothing ? nothing : outer.counts,
        outer === nothing ? false : outer.merge_recheck
    )
end

# `c` with its plan, record or a caller setting replaced, the state and tuning
# kept; a fresh context when no build is open.
function _ctx_with(
        c::Union{Nothing, _BuildContext}; plan = nothing, record = nothing,
        range_spec = nothing, ws_capture = nothing, counts = nothing,
        merge_recheck = nothing
    )
    c === nothing && (
        c = _fresh_ctx(something(plan, _DEFAULT_COMPILER_PLAN), record, _BuildState(), nothing)
    )
    return _BuildContext(
        something(plan, c.plan), something(record, Some(c.record)), c.state, c.tuning,
        something(range_spec, Some(c.range_spec)),
        something(ws_capture, Some(c.ws_capture)),
        something(counts, Some(c.counts)),
        something(merge_recheck, c.merge_recheck)
    )
end

# The context a build runs in: its plan and record, fresh state (with the
# build's scatter set), the tuning read now. The loop-variable counter and the
# caller settings continue the enclosing context's.
function _new_build_ctx(plan::CompilerPlan, record::Union{Nothing, _BuildRecord})
    outer = _build_ctx()
    count = outer === nothing ? Ref(0) : outer.state.loopvar_count
    return _fresh_ctx(
        plan, record,
        _BuildState(
            count; scatter_keep = IdDict{Any, Nothing}(),
            calls = outer === nothing ? nothing : outer.state.calls
        ), outer
    )
end

# A compile against a layout of its own, inside or after a build: the current
# plan, record, tuning and caller settings, fresh slot tables and loop registry,
# no parameter-read sink. Inside a build it holds out the build's scatter set.
function _child_build_ctx()
    outer = _build_ctx()
    outer === nothing && return _fresh_ctx(_DEFAULT_COMPILER_PLAN, nothing, _BuildState(), nothing)
    return _BuildContext(
        outer.plan, outer.record,
        _BuildState(
            outer.state.loopvar_count; scatter_keep = outer.state.scatter_keep,
            calls = outer.state.calls
        ),
        outer.tuning, outer.range_spec, outer.ws_capture, outer.counts, outer.merge_recheck
    )
end

# Run `f` with slot tables of its own on the current build state, for a compile
# inside a build against a layout of its own (a discrete materializer's fill);
# the build's tables are back afterwards.
function _with_own_slot_tables(f)
    st = _build_state()
    saved = st.slot_tables
    st.slot_tables = Dict{String, Tuple{Vector{Int}, Int, Vector{Int}}}()
    try
        return f()
    finally
        st.slot_tables = saved
    end
end

# The state a resolve or compile writes to: the open build's, else this task's
# own (a resolve or compile called outside any build, as a test does), kept for
# the life of the task.
const _TASK_STATE_KEY = :earthsci_build_state

function _build_state()::_BuildState
    c = _build_ctx()
    c === nothing || return c.state
    return get!(_BuildState, task_local_storage(), _TASK_STATE_KEY)::_BuildState
end

# The caller settings, read and installed.
_range_spec_now()::Union{Nothing, _RangeSpec} =
    (c = _build_ctx(); c === nothing ? nothing : c.range_spec)
_with_range_spec(f, spec::_RangeSpec) =
    _with_build_ctx(f, _ctx_with(_build_ctx(); range_spec = spec))

_ws_capture_now()::Union{Nothing, _WsCapture} =
    (c = _build_ctx(); c === nothing ? nothing : c.ws_capture)
_with_ws_capture(f, cap::_WsCapture) =
    _with_build_ctx(f, _ctx_with(_build_ctx(); ws_capture = cap))

_merge_recheck_on()::Bool = (c = _build_ctx(); c !== nothing && c.merge_recheck)
_with_merge_recheck(f) = _with_build_ctx(f, _ctx_with(_build_ctx(); merge_recheck = true))

# The open build's scatter set (scatter.jl), `nothing` outside a build.
_scatter_keep_now()::Union{Nothing, IdDict{Any, Nothing}} =
    (c = _build_ctx(); c === nothing ? nothing : c.state.scatter_keep)

# ---------------------------------------------------------------------------
# Engagement counts
# ---------------------------------------------------------------------------
#
# How often a build path engaged: every cascade tally key, plus the counters
# below that no `CompilerReport` row carries (a geometry sweep that took the
# candidate drive, a setup map served by its fast path, a value-invention
# binding visited). They are observations only; nothing reads them to decide
# what to build. They land in the `Dict` that `Internal.counting` (or
# `Internal.build`) puts on the build context, and nowhere when none is open, so
# an `esm_problem` build pays one lookup per event and keeps nothing.
#
#   :geom_overlap_drive / :geom_overlap_gate_only / :geom_overlap_none
#                          — an overlap-gated setup geometry sweep, by how its
#                            candidate set was driven (setup_sweep.jl)
#   :geom_eq_drive         — an equality-gated setup sweep driven by its key
#   :setup_map_fastpath_hit / :setup_map_fastpath_miss
#                          — a setup map compiled once / walked per cell
#   :cellwise_fastpath_hit / :cellwise_fastpath_miss
#                          — `_cellwise_compile_once` compiled / declined
#   :vi_enum_visits        — one binding visited by a value-invention or
#                            overlap-gated enumeration
#   :compile_calls / :branch_templates / :body_variants
#                          — node lowerings, stencil spine templates and
#                            stencil body variants
_counts_sink()::Union{Nothing, Dict{Symbol, Int}} =
    (c = _build_ctx(); c === nothing ? nothing : c.counts)

function _count!(k::Symbol, n::Int = 1)
    c = _counts_sink()
    c === nothing || (c[k] = get(c, k, 0) + n)
    return nothing
end

# Record `n` under `k` when it is larger than what `k` holds (a maximum, kept
# in the same sink as the counts).
function _count_max!(k::Symbol, n::Int)
    c = _counts_sink()
    c === nothing || (c[k] = max(get(c, k, 0), n))
    return nothing
end

# `(f(), counts)`: the value and every count `f` produced on this task. A nested
# call also adds its counts into the enclosing one.
function _with_counts(f)
    outer = _counts_sink()
    c = Dict{Symbol, Int}()
    v = _with_build_ctx(f, _ctx_with(_build_ctx(); counts = c))
    if outer !== nothing
        for (k, n) in c
            outer[k] = get(outer, k, 0) + n
        end
    end
    return v, c
end

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

# File a decline against the open rule.
function _note_decline!(tier::Symbol, d::_Decline)
    rec = _build_record()
    rec === nothing && return nothing
    push!(rec.declines, _decline_row(tier, d))
    return nothing
end
_note_decline!(tier::Symbol, reason::Symbol, detail::AbstractString = "") =
    _note_decline!(tier, _Decline(reason, detail))
_note_decline!(r::_DeclineRow) = _note_decline!(r.tier, r.reason, r.detail)

# The declines the open rule has collected so far.
_open_declines() = (rec = _build_record(); rec === nothing ? _DeclineRow[] : copy(rec.declines))

function _land_rule!(tier::Symbol)
    rec = _build_record()
    rec === nothing && return nothing
    isempty(rec.current) && return nothing
    push!(
        rec.rules, CompilerRuleRecord(
            rec.current, rec.current_kind, tier,
            copy(rec.declines)
        )
    )
    rec.current = ""
    empty!(rec.declines)
    return nothing
end

# A rule with no cascade stage of its own (a setup array, a materialized
# observed): one call, no open/close pair.
function _record_rule!(
        rule::AbstractString, kind::Symbol, tier::Symbol;
        declines::Vector{_DeclineRow} = _DeclineRow[]
    )
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
    (
    rec = _build_record(); rec === nothing || isempty(rec.current) ?
        String(fallback) : rec.current
)

function _finish_report(rec::_BuildRecord)
    # A nested reduction the build lifted into an internal observed
    # (tree_walk/hoist.jl) reports under the variable it was lifted from.
    rules = CompilerRuleRecord[
        _is_hoisted_name(r.rule) ?
            CompilerRuleRecord(_hoist_public_label(r.rule), r.kind, r.tier, r.declines) : r
            for r in rec.rules
    ]
    return CompilerReport(rec.plan.name, rules, copy(rec.tally))
end

# ---------------------------------------------------------------------------
# What one output-time read did
# ---------------------------------------------------------------------------
#
# `observed_field` files one report row per name, saying whether the read walked
# per cell. That is a question about ONE CALL: another task's evaluations must
# not add into it, and neither may an attempt the read made and then abandoned.
# So the read installs a
# task-local counter, the per-cell cellwise route bumps it once it has SERVED a
# value, and a caller that swallows a failed attempt drops what the attempt
# counted (`_percell_mark` / `_percell_restore!`).
const _PERCELL_COUNT_KEY = :earthsci_percell_count

_percell_counter()::Union{Nothing, Base.RefValue{Int}} =
    get(task_local_storage(), _PERCELL_COUNT_KEY, nothing)

# `(f(), n)`: the value and the number of per-cell evaluations that served it.
# A nested count also adds into the enclosing one.
function _counting_percell(f)
    outer = _percell_counter()
    r = Ref(0)
    v = task_local_storage(f, _PERCELL_COUNT_KEY, r)
    outer === nothing || (outer[] += r[])
    return v, r[]
end

_note_percell!() = (r = _percell_counter(); r === nothing || (r[] += 1); nothing)
_percell_mark() = (r = _percell_counter(); r === nothing ? 0 : r[])
_percell_restore!(n::Int) = (r = _percell_counter(); r === nothing || (r[] = n); nothing)

# ---------------------------------------------------------------------------
# The refusal
# ---------------------------------------------------------------------------

"""
    _refuse_rule(rule, reason) -> never returns

Raise `compiler_refused_rule` for the compiler in force. The message names the
compiler, the rule (component-qualified) and the deepest reason, which is the
shape §2.5.10 fixes and what the compiler-agreement tier reads back.
"""
_refuse_rule(rule::AbstractString, reason::AbstractString) =
    _refuse_rule(_compiler_plan_now(), rule, reason)

# The refusal under an explicit `plan`, for one raised after the build that
# produced a problem has returned (the `:xla` emission works on the build's
# product).
function _refuse_rule(plan::CompilerPlan, rule::AbstractString, reason::AbstractString)
    throw(
        TreeWalkError(
            ERROR_CODES.COMPILER_REFUSED_RULE,
            "compiler=:$(plan.name) refuses '$rule': $reason",
            String(rule)
        )
    )
end

# True when the compiler in force refuses a rule it cannot express rather than
# demoting it. Read only by the per-cell license below: no route decides on
# strictness itself.
_compiler_is_strict() = _compiler_plan_now().strict

# ---------------------------------------------------------------------------
# The per-cell license
# ---------------------------------------------------------------------------
#
# "No fallback" is a property of the TYPES, not a check at each route. Every
# routine that works per cell — that resolves and compiles an expression once
# per cell at construction, or walks a tree once per cell on a right-hand-side
# call, a data refresh or an output read — takes a `_PerCellLicense` as its
# first argument, and so does every evaluator structure that walks per cell (a
# kernel section's per-cell runner, the walked recurrence sweep). Those
# routines and structures ARE the interpreter: `compiler = :interpreter` runs
# them, and nothing a strict compiler builds can.
#
# A license is a value only a NON-strict plan can produce: its one constructor
# reads the plan in force and refuses under a strict one. Under `native` (and
# `xla` and `mtk`) no license exists, so no per-cell routine can be called and
# no walking structure can be built. A route asks for one through
# `_percell_license`, which, under a strict plan, raises the route's named
# refusal instead of returning.
#
# The one per-cell evaluation a strict plan performs is a PROBE: a refusal
# whose subject no form can evaluate must report the document's own error (an
# undeclared name, an out-of-range gather), not "this compiler cannot run it",
# so it evaluates one cell first and discards the value. A probe is a
# `_PerCellProbe`, accepted only by the single-cell routines; every loop over
# cells and every walking structure takes the license alone.
#
# The out-of-place product (`form = :oop`) has a token of its own,
# `_OopCells`: its per-cell build scalarizes cells for a whole-program
# compiler to lower, and is never a host evaluator (tree_walk/oop.jl).

"""
    _PerCellLicense

Proof that the plan in force may evaluate per cell (see the section comment
above). Its only constructor refuses under a strict plan; routes obtain one
through [`_percell_license`](@ref), which names the rule in the refusal.
"""
struct _PerCellLicense
    plan::Symbol
    function _PerCellLicense()
        plan = _compiler_plan_now()
        # Reached only by a route that skipped `_percell_license`; the route's
        # own refusal would have named its rule.
        plan.strict && throw(
            TreeWalkError(
                ERROR_CODES.COMPILER_REFUSED_RULE,
                "compiler=:$(plan.name) refuses a per-cell evaluation: a strict " *
                    "compiler has no per-cell route (esm-libraries-spec §2.5.10). Build " *
                    "with compiler=:interpreter to run it"
            )
        )
        return new(plan.name)
    end
end

"""
    _PerCellProbe

Permission to evaluate ONE cell for a refusal's diagnostic, its value discarded.
Accepted only by single-cell routines (`_PerCellAccess`), never by a loop over
cells or a structure that walks per call.
"""
struct _PerCellProbe end

const _PerCellAccess = Union{_PerCellLicense, _PerCellProbe}

"""
    _OopCells

The out-of-place product's permission to build an array equation one output
cell at a time: the cells become lanes of the compiled program a whole-program
backend lowers (`form = :oop`), never trees a host evaluator walks. Made only by
the out-of-place build.
"""
struct _OopCells end

"""
    _percell_license(rule, reason; probe = nothing) -> _PerCellLicense

A license under a non-strict plan. Under a strict one, run `probe(_PerCellProbe())`
(when given) for its diagnostic, then raise `compiler_refused_rule` naming `rule`
with `reason` — a string, or a function of the probe's result.
"""
function _percell_license(rule::AbstractString, reason; probe = nothing)
    _compiler_is_strict() || return _PerCellLicense()
    r = probe === nothing ? nothing : probe(_PerCellProbe())
    return _refuse_rule(rule, reason isa AbstractString ? reason : reason(r))
end

"""
    _percell_evaluation_license(rule, what, cells; probe, one_cell) -> _PerCellLicense

The license for a materialization that RESOLVES AND COMPILES the expression once
per cell. §2.5.10 puts every evaluation a compiler performs for the problem
under the refusal rule, not the right-hand side alone: the materialization of
constants and static observeds at construction, the initial-state seed and the
observeds reported at output times are each a place a binding walks the tree per
cell, and each of them makes the compiler's name describe nothing if it is
allowed to happen quietly.

A compile-once sweep that then evaluates an ALREADY COMPILED node per cell is
not one of these and never asks: what is refused is re-deriving the program for
every cell.
"""
function _percell_evaluation_license(
        rule::AbstractString, what::AbstractString,
        cells::Union{Nothing, Integer};
        probe = nothing, one_cell::Bool = false
    )
    over = cells === nothing ? "" :
        ", over $cells cell" * (cells == 1 ? "" : "s")
    reason = "$what resolves and compiles the expression once per cell$over, " *
        "because the compile-once form declined it. That is a tree walk per " *
        "cell at construction time, which esm-libraries-spec §2.5.10 puts " *
        "under the same rule as the right-hand side. Build with " *
        "compiler=:interpreter to run it" * (one_cell ? ". " * _ONE_CELL_NOTE : "")
    return _percell_license(rule, reason; probe = probe)
end

# Said by every refusal raised once ONE cell of a per-cell route has been
# evaluated for its diagnostic (`one_cell = true` above), in the words the Rust
# binding uses for its own: the cells it did not evaluate may still hold a
# document error, and only the interpreter would find it.
const _ONE_CELL_NOTE =
    "Only one cell of it was evaluated before this refusal, so a document error " *
    "in a cell that was not (an out-of-range gather at the last cell, say) is not " *
    "reported here; the interpreter evaluates every cell and reports it"

# The same, for a refusal whose diagnostic evaluated only some terms of one cell
# (a contraction too long to build in full, `_refuse_faq_percell`), and for one
# that evaluated no term at all (a join gate that admitted none it tried).
const _PART_CELL_NOTE =
    "Only some terms of one cell of it (the first and last value of each " *
    "contracted index, or at most its first 1024 admitted terms) were evaluated " *
    "before this refusal, so a document error in a term or cell that was not is " *
    "not reported here; the interpreter evaluates every cell and reports it"
const _NO_CELL_NOTE =
    "No term of it was evaluated before this refusal (its join gate admitted " *
    "none of the terms tried), so a document error in it is not reported here; " *
    "the interpreter evaluates every cell and reports it"
