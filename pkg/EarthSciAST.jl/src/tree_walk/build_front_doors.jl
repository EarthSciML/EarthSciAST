# tree_walk/build_front_doors.jl — the entry points: `_build_evaluator`, the dictionary front door,
# gated-provider fetch, `param_map`, `parameter_classes`, `expanded_model` and
# `evaluate_expr`.

# CONFORMANCE_SPEC §5.18.2: this evaluator computes in binary64 only, so a
# variable whose working precision is binary32 — its own `element_type`, else the
# document's `domain.element_type` — is refused rather than evaluated in another
# precision. After esm-spec §4.7 "Working precision crosses a mount" a mounted
# binary32 leaf reaches here as exactly such per-variable declarations.
function _refuse_float32(model::Model, document::AbstractString, name::AbstractString)
    for (vname, v) in model.variables
        something(v.element_type, document) == "Float32" || continue
        throw(
            TreeWalkError(
                ERROR_CODES.FLOAT32_UNSUPPORTED,
                "variable '$(isempty(name) ? vname : "$(name).$(vname)")' is declared binary32 " *
                    "(element_type \"Float32\"), but the Julia tree-walk evaluator computes in " *
                    "binary64; refusing the build rather than returning a binary64 answer " *
                    "(CONFORMANCE_SPEC §5.18.2)"
            )
        )
    end
    for (sname, sub) in model.subsystems
        sub isa Model && _refuse_float32(sub, document, isempty(name) ? sname : "$(name).$(sname)")
    end
    return nothing
end

function _refuse_float32(file::EsmFile, model_name)
    document = something(
        file.domain === nothing ? nothing : file.domain.element_type,
        "Float64"
    )
    models = file.models === nothing ? Dict{String, Model}() : file.models
    for (name, model) in models
        (model_name === nothing || name == model_name) || continue
        model isa Model && _refuse_float32(model, document, name)
    end
    if document == "Float32" && file.reaction_systems !== nothing &&
            !isempty(file.reaction_systems)
        throw(
            TreeWalkError(
                ERROR_CODES.FLOAT32_UNSUPPORTED,
                "the document declares `domain.element_type: \"Float32\"`, but the Julia " *
                    "tree-walk evaluator computes in binary64; refusing the build rather than " *
                    "returning a binary64 answer (CONFORMANCE_SPEC §5.18.2)"
            )
        )
    end
    return nothing
end

"""
    _build_evaluator(model::Model; initial_conditions=Dict(),
                    parameter_overrides=Dict(), tspan=nothing, kwargs...)

Build a tree-walk ODE RHS evaluator for `model` (internal; callers use
[`esm_problem`](@ref), and the package's tests and adapters
`EarthSciAST.Internal.build`, both of which flatten first). Returns `(f!, u0,
p, tspan, var_map)`; everything else the build produced goes to its `products`
record ([`BuildProducts`](@ref)).

State variables may be scalar or array-shaped; an array state is laid out as
one block of cells (`StateLayout`). `faq` and `makearray` are supported in expression
position: scalar `faq` (empty `output_idx`) is expanded inline;
`index(faq(...), k...)` and `index(makearray(...), k...)` are
resolved at build time, and so are `index(reshape|transpose|concat(...), k...)`
(each is a gather of its operand) and `broadcast` (lowered to its `fn`). A bare
`reshape`, `transpose` or `concat` outside an `index` is refused at build with
`unevaluable_operator`.

The returned `f!` closure reads `u`, the captured parameter vector
`p` (a NamedTuple keyed by parameter name), and `t`, and writes
time-derivatives into `du`. Observed variables are substituted into
RHS expressions at build time.

Keyword arguments (see `_build_evaluator_impl` for the full set,
including `const_arrays`, `param_arrays`, `const_array_boundaries`,
`index_sets`, and `products`, a [`BuildProducts`](@ref) record):

* `initial_conditions::AbstractDict` — override the default values in
  `model.variables` for specific state variables. A value is a real number,
  or — for a SHAPED unknown — INLINE ARRAY DATA (a nested array matching the
  declared `shape`, esm-spec §6.6.2), which is expanded into the per-cell
  initial values.
* `parameter_overrides::AbstractDict` — override the default
  values for specific parameters. A value is a real number, or — for a SHAPED
  parameter — INLINE ARRAY DATA, which is registered as build-time data in
  `const_arrays` rather than as a scalar `p` slot (esm-spec §6.3 / §6.6.2). A
  SCALAR `default` on a shaped parameter is filled densely over the whole
  declared grid unless `const_arrays` or `param_arrays` already supplies that
  name, so a large data-backed parameter should be built with its data
  supplied. Keys may be spelled either LOCALLY
  (`pert_amp`, the form esm-spec §6.6 pins for a test's
  `parameter_overrides`) or with the flattening qualification the run
  document carries (`SimpleClimate.pert_amp`); both resolve to the same
  parameter, and an ambiguous local name (the same parameter in two
  mounted components) is left unbound rather than guessed at. The
  resolved values are load-time constants, so they bind the build-time
  evaluation scope too — the coordinate-expression `ic` seed and the
  §6.6.5 reference / observed assertion scope recorded in `products` —
  not just the runtime parameter NamedTuple.
* `tspan::Union{Nothing,Tuple{Real,Real}}` — explicit time span. If
  `nothing`, the default `(0.0, 1.0)` is returned.
* `form::Symbol` — what to return in the RHS slot (`:inplace`, the
  default, or `:oop`). `:inplace` gives the `f!(du, u, p, t)` above:
  zero-allocation at Float64 AND eltype-generic, so it both solves and
  differentiates (ForwardDiff over the state or over the parameters; a
  stiff solve gets an exact AD Jacobian for free). It is the evaluator.
  `:oop` gives the OUT-OF-PLACE BUILD PRODUCT instead — the compiled
  intermediate representation itself, wrapped so that its arity (three
  arguments) reads as out-of-place, plus the live forcing buffers this
  build bound. It does not evaluate on the host: it is what a COMPILED
  backend lowers into a program of its own. `direct_rhs`
  (`EarthSciASTReactantExt`) is the one in tree; see
  `docs/src/compiled-backend-devices.md`. Its live forcing buffers
  (`param_arrays` + discrete caches) are exposed as ARGUMENTS via
  [`forcing_buffers`](@ref) / [`forcing_buffer_index`](@ref), so a compiled
  program receives them as real inputs and an in-place refresh
  ([`sync_forcing!`](@ref)) stays visible to it.
"""
function _build_evaluator(model::Model; kwargs...)
    _refuse_float32(model, "Float64", "")
    return _build_evaluator_impl(model; kwargs...)
end

"""
    param_map(p) -> Dict{String,Int}

Parameter NAME → its position in a parameter VECTOR, the `p`-side mirror of the
`var_map` an [`esm_problem`](@ref) Problem carries for the state.

Take it from the Problem's `p`:

```julia
prob = esm_problem(doc, tspan)
pm = param_map(prob.p)             # "k_diff" => 1, "k_rxn" => 3, …
θ  = ComponentVector(prob.p)       # the same order, as an AbstractVector
prob.f!(du, u, θ, t)               # …and it is accepted as `p`
```

The Problem already carries `p`, so this is a FUNCTION OF `p` rather than a
second field that would have to be kept in step with it. That costs nothing
in fidelity: the order is the build's own (`param_names` is sorted, and the `p`
NamedTuple is built from it in that order), and `keys(p)` IS that order, so this
map and the `idx` baked into every `_NK_PARAM` node are the same numbering by
construction rather than by agreement.

A parameter-free model carries SciMLBase's `nothing` sentinel as `p` and maps to
the empty Dict.
"""
param_map(p::NamedTuple) = Dict{String, Int}(
    String(k) => i
        for (i, k) in enumerate(keys(p))
)
param_map(::Nothing) = Dict{String, Int}()

"""
    parameter_classes(x) -> Dict{String,Symbol}

Parameter NAME → what KIND of parameter it is in the build that produced `x`
(a [`BuildInspection`](@ref) or an `EsmProblem`). Four classes:

| class | where its value is consumed | overridable at solve time? |
|---|---|---|
| `:numeric` | the runtime `p` vector | **yes** — swap `p` (`remake`), differentiable |
| `:structural` | BUILD time (setup geometry, value-invention extents, binning coordinates, join key columns, `ic()` folds) | no — rebuild the problem |
| `:const_folded` | frozen into the build's const arrays and inlined into the RHS | no — rebuild with new data |
| `:forcing` | a live buffer a discrete provider rewrites in place | no — write the buffer |

The partition is **derived, not declared**: every one of these is spelled
`"type": "parameter"` in the document, so the discriminator is where the value is
CONSUMED. The build records the names its build-time consumers resolve (see the
`_PARAM_READS` seam) and anything they touched is `:structural` — by
construction, not by a second static reading of the document.

`:structural` is per NAME, not per use: a name read once at build stays
structural even when the RHS also reads it at runtime, because the value baked
into the build and the value in `p` would then disagree.

`:const_folded` deserves its own name rather than being folded into
`:structural`: differentiating w.r.t. one returns an unconditional ZERO, and a
finite-difference check on its declared default CONFIRMS that zero (perturbing
the default changes nothing either) — a wrong gradient and a wrong check
agreeing silently. It is refused explicitly, with its own message.

Like [`param_map`](@ref) this is a function of an artifact rather than an extra
return value. Pass `inspect = BuildInspection()` to `esm_problem`, or read it
off the `EsmProblem` that `esm_problem` returns.

```julia
prob = esm_problem("model.esm", tspan)
cls  = parameter_classes(prob)
θ    = [n for (n, c) in cls if c === :numeric]     # what a gradient may target
solve(remake(prob; p = Dict(θ[1] => 2.0)), Tsit5())
```
"""
parameter_classes(insp::BuildInspection) = insp.param_classes

"""
    _build_evaluator(file::EsmFile; model_name=nothing, kwargs...)

Delegate to the typed entry point after selecting the model.
"""
function _build_evaluator(
        file::EsmFile;
        model_name::Union{Nothing, AbstractString} = nothing,
        kwargs...
    )
    _refuse_float32(file, model_name)
    model = _select_model(file, model_name)
    # Thread the document-scoped index-set registry into the typed evaluator.
    return _build_evaluator(
        model; index_sets = file.index_sets,
        _template_reg = _component_template_reg(file, model_name),
        kwargs...
    )
end

# The selected model's surviving-reference registry ("models.<name>" in
# `EsmFile.component_templates`, esm-spec §9.6.4 Option B), or `nothing` when the
# document carries none. Mirrors `_select_model`'s name resolution; a selection
# `_select_model` would reject returns `nothing` here and lets it throw.
function _component_template_reg(file::EsmFile, model_name)
    ct = file.component_templates
    ct === nothing && return nothing
    name = model_name !== nothing ? String(model_name) :
        (
            file.models !== nothing && length(file.models) == 1 ?
            String(first(keys(file.models))) : nothing
        )
    name === nothing && return nothing
    return get(ct, "models.$name", nothing)
end

"""
    expanded_model(file::EsmFile, model_name=nothing) -> Model

A deep copy of the selected model with every surviving Option-B
`apply_expression_template` reference (esm-spec §9.6.4) expanded against the
document's `component_templates` — the same expansion `_build_evaluator`
performs before compiling, exposed as a public seam so downstream tools
(e.g. EarthSciASTDiff, which differentiates the tree) analyze the expressions
the evaluator compiles. The build goes on to rewrite this tree further without
changing its value (recurrence groups stacked, `broadcast` lowered, nested
reductions hoisted, subtrees interned), so the evaluator's own tree can differ
from this one in structure. `file` is not mutated.

Model selection matches the build's: `model_name = nothing`
selects the document's only model, or throws `E_TREEWALK_AMBIGUOUS_MODEL`
when there are several; an unknown name throws `E_TREEWALK_NO_MODEL`.
A document with no surviving references returns the plain copy.
"""
function expanded_model(
        file::EsmFile,
        model_name::Union{Nothing, AbstractString} = nothing
    )::Model
    model = deepcopy(_select_model(file, model_name))
    reg = _component_template_reg(file, model_name)
    reg === nothing || _expand_model_refs!(model, reg)
    return model
end

# The const-array keys an authored bare factor name resolves to in THIS build.
# The front-door build keeps bare names, but `esm_problem` flattens first — every
# variable is namespaced to `<OrigModel>.<name>` (the model itself renamed
# `Flattened`), while document-scoped index-set fields (`member_factor`) and gate
# `applies_to` stay bare. So a bare authored name must be injected under BOTH the
# bare key AND every model-variable key whose final dotted segment matches it, so
# the gather (which reads the namespaced ref) resolves in either build path.
function _const_factor_aliases(model, bare::AbstractString)
    keys_out = Set{String}([String(bare)])
    if model !== nothing
        for k in keys(model.variables)
            ks = String(k)
            (
                ks == bare || (
                    occursin('.', ks) &&
                        String(split(ks, '.')[end]) == bare
                )
            ) && push!(keys_out, ks)
        end
    end
    return keys_out
end

# The const-array keys ONE GATED PROVIDER may publish its fetched variable `nm`
# under, given every gate issued in the same fetch.
#
# `_const_factor_aliases` resolves a bare authored name against EVERY model
# variable whose final dotted segment matches it. That is exactly what a
# document-scoped `member_factor` wants, and it is WRONG for a gated provider:
# sibling loaders may expose the SAME variable name — `ISRM_SR_L0.SOA`,
# `ISRM_SR_L1.SOA` and `ISRM_SR_L2.SOA` are three DIFFERENT slabs of one zarr
# store, told apart only by which loader they came from — so tail-matching makes
# each of those three providers claim all three aliases. Whichever provider the
# `gated` collection happens to visit last then silently wins for all of them,
# and every model array is contracted against one arbitrary sibling's slab. The
# collection is a `Dict`, so which sibling wins is hash order: a wrong answer
# that is stable within a run, differs per variable name, and raises nothing.
#
# A provider claims an alias when it is the SOLE claimant, or when the alias IS
# its own provider key — the post-flatten `"<Loader>.<var>"` spelling of exactly
# that provider's variable, which no sibling can also be. An alias that several
# providers claim and none owns is AMBIGUOUS and is left unwritten: a missing
# const array is a loud failure at gather time, an arbitrarily chosen one is
# this bug.
function _gated_alias_claims(gated::AbstractDict, model)
    claims = Dict{String, Set{String}}()      # alias => the provider keys claiming it
    for (key, entry) in gated
        _, gate = _unbundle_gated(entry)
        gate === nothing && continue
        applies = get(gate, "applies_to", nothing)
        applies === nothing && continue
        for name in applies
            for a in _const_factor_aliases(model, String(name))
                push!(get!(claims, a, Set{String}()), String(key))
            end
        end
    end
    return claims
end

function _gated_const_keys(
        claims::AbstractDict, model, key::AbstractString,
        nm::AbstractString
    )
    aliases = _const_factor_aliases(model, nm)
    ks = String[
        a for a in aliases
            if length(get(claims, a, Set{String}([String(key)]))) == 1 ||
            a == String(key)
    ]
    isempty(ks) && throw(
        RefreshError(
            "gated provider '$key' variable '$nm': every const-array key it resolves " *
                "to ($(sort!(collect(aliases)))) is also claimed by another gated " *
                "provider, so the fetched slab has no unambiguous name to be published " *
                "under. Key the provider \"<Loader>.<var>\" so its own spelling can win, " *
                "or give the sibling loaders' variables distinct names"
        )
    )
    return ks
end

# ---- Phase 2b Hook 1 helper: members-fed-back-as-const-factor ----------------
# Scan the document index-set registry for `kind:"derived"` sets that name a
# `member_factor`; for each, surface its value-invention MEMBERS (the invented,
# sorted-distinct, 1-based full-grid ids in `vi_members[from_faq]`) as a dense
# 1-D Float64 const array keyed by the factor name (and its namespaced aliases,
# see `_const_factor_aliases`). Returns a `name => vector` dict to merge into
# `const_arrays`. A derived set with no `member_factor`, or whose producer did
# not materialise, contributes nothing.
function _feed_back_vi_members(index_sets, vi_members::AbstractDict, model)
    out = Dict{String, Any}()
    index_sets === nothing && return out
    for (_, is) in index_sets
        is isa IndexSet || continue
        is.kind == "derived" || continue
        mf = is.member_factor
        (mf === nothing || is.from_faq === nothing) && continue
        faq = String(is.from_faq)
        haskey(vi_members, faq) || continue
        mem = vi_members[faq]
        # members are scalar integer keys (value_invention.jl).
        vec = Vector{Float64}(undef, length(mem))
        ok = true
        for (i, m) in enumerate(mem)
            if m isa Real
                vec[i] = Float64(m)
            else
                ok = false
                break
            end
        end
        ok || throw(
            TreeWalkError(
                "E_TREEWALK_VI_MEMBER_FACTOR",
                "derived index set member_factor '$mf' requires SCALAR members; " *
                    "got a non-numeric member for faq '$faq'"
            )
        )
        for k in _const_factor_aliases(model, String(mf))
            out[k] = vec
        end
    end
    return out
end

# ---- Phase 2b Hook 2 helper: gated-provider deferral → selective fetch -------
# Resolve each stashed GATED provider's `selection` from the now-materialised
# value-invention members, fetch ONLY the compact slab, and return a
# `model-var-name => compact Float64 array` dict to merge into `const_arrays`.
#
# `gated` maps a provider KEY to either the bare provider or a `(prov=…, gate=…)`
# bundle; `provider_gate_spec(prov)` supplies the gate when the bundle omits it.
# A gate is `Dict("axes"=>[…], "applies_to"=>[names…])` where each native axis is
# one of `Dict("fixed"=>[i])` (0-based native index → DROPPED length-1 axis),
# `Dict("range"=>Dict("start"=>a,"stop"=>b,"step"=>s))` (a half-open strided
# window, axis KEPT), `Dict("gated_by"=>"<derived set>")` (the set's members,
# 1-based, as the new axis), or `"all"` (whole axis) — ONE vocabulary, whether
# the author wrote it as a loader `select` (esm-spec §8.9.2) or the pushdown
# rewrite generated it (CONFORMANCE_SPEC §5.5). The compact gated axis length is
# asserted to equal the gating set's materialised extent.
function _fetch_gated_providers(gated::AbstractDict, index_sets, vi, t0::Float64, model)
    out = Dict{String, Any}()
    (vi === nothing) && isempty(gated) && return out
    # Who may publish under which const-array key — computed over ALL the gates
    # up front, because "am I the only claimant?" is not a per-provider question.
    alias_claims = _gated_alias_claims(gated, model)
    # derived set name → its producer faq id (for `gated_by` resolution).
    set_to_faq = Dict{String, String}()
    if index_sets !== nothing
        for (sname, is) in index_sets
            is isa IndexSet || continue
            is.kind == "derived" && is.from_faq !== nothing &&
                (set_to_faq[String(sname)] = String(is.from_faq))
        end
    end
    vi_members = vi === nothing ? Dict{String, Vector{Any}}() : vi.members
    vi_extents = vi === nothing ? Dict{String, Int}() : vi.extents

    for (key, entry) in gated
        prov, gate = _unbundle_gated(entry)
        gate === nothing && continue
        axes = get(gate, "axes", nothing)
        applies = get(gate, "applies_to", nothing)
        (axes === nothing || applies === nothing) && throw(
            RefreshError(
                "gated provider '$key' gate spec needs both `axes` and `applies_to`"
            )
        )

        selection = Vector{Any}(undef, length(axes))
        drop_axes = Int[]                 # positions of `fixed` axes (dropped)
        gated_pos = 0                     # position of the single gated axis
        gated_extent = 0
        for (ax_i, ax) in enumerate(axes)
            if ax == "all"
                selection[ax_i] = Colon()
            elseif ax isa AbstractDict && haskey(ax, "fixed")
                fx = ax["fixed"]
                fi = fx isa AbstractVector ? Int(first(fx)) : Int(fx)
                selection[ax_i] = fi + 1          # 0-based native → 1-based neutral
                push!(drop_axes, ax_i)
            elseif ax isa AbstractDict && haskey(ax, "range")
                # The half-open strided window of the SAME per-axis vocabulary a
                # loader's `select` writes (esm-spec §8.9.2) — the axis is kept,
                # so it neither drops nor gates. Bounds are already integers here
                # (a metaparameter name resolves where the select is parsed).
                r = ax["range"]
                start = Int(get(r, "start", 0))
                stop = Int(r["stop"])
                step = Int(get(r, "step", 1))
                step >= 1 || throw(
                    RefreshError(
                        "gated provider '$key' axis $ax_i: range.step must be >= 1, got $step"
                    )
                )
                selection[ax_i] = collect((start + 1):step:stop)   # 0-based → 1-based
            elseif ax isa AbstractDict && haskey(ax, "gated_by")
                sname = String(ax["gated_by"])
                haskey(set_to_faq, sname) || throw(
                    RefreshError(
                        "gated provider '$key' gates on '$sname' which is not a " *
                            "derived index set with a from_faq"
                    )
                )
                faq = set_to_faq[sname]
                haskey(vi_members, faq) || throw(
                    RefreshError(
                        "gated provider '$key' gates on '$sname' (faq '$faq') but its " *
                            "value-invention members were not materialised"
                    )
                )
                mem = Int[Int(m) for m in vi_members[faq]]   # 1-based ids, set order
                selection[ax_i] = mem
                gated_pos = ax_i
                gated_extent = get(vi_extents, faq, length(mem))
            else
                throw(
                    RefreshError(
                        "gated provider '$key' axis $ax_i is malformed " *
                            "(expected \"all\", {\"fixed\":[i]}, {\"range\":{start,stop,step}}, " *
                            "or {\"gated_by\":set})"
                    )
                )
            end
        end
        gated_pos == 0 && throw(
            RefreshError(
                "gated provider '$key' declares no {\"gated_by\":…} axis"
            )
        )

        # position of the compact gated axis AFTER dropping the fixed axes.
        gated_pos_out = gated_pos - count(<(gated_pos), drop_axes)
        drop_tuple = Tuple(drop_axes)

        supports = provider_supports_selection(prov)
        if supports
            sample = provider_sample(prov, t0; selection = selection)
            for name in applies
                nm = String(name)
                field = _sample_field(sample, nm)
                isempty(drop_tuple) || (field = dropdims(field; dims = drop_tuple))
                # The slab, a bare-array sample, takes the conversion a whole
                # sample does (`forcing_from_sample`).
                arr = forcing_from_sample(field, nm)
                size(arr, gated_pos_out) == gated_extent || throw(
                    RefreshError(
                        "gated provider '$key' variable '$nm': fetched compact axis is " *
                            "$(size(arr, gated_pos_out)) but the gating set extent is $gated_extent"
                    )
                )
                for k in _gated_const_keys(alias_claims, model, key, nm)
                    out[k] = arr
                end
            end
        else
            # FALLBACK: reader cannot push down — fetch whole, then slice by the
            # same per-axis selection (a fixed `Int` DROPS the axis, a gated or
            # range axis is an index vector, `all` is `Colon()`), so the sliced
            # result matches the pushdown result exactly.
            sample = provider_sample(prov, t0)
            for name in applies
                nm = String(name)
                full = _sample_field(sample, nm)
                field = full[selection...]
                arr = forcing_from_sample(field, nm)
                size(arr, gated_pos_out) == gated_extent || throw(
                    RefreshError(
                        "gated provider '$key' variable '$nm' (fallback slice): compact axis " *
                            "is $(size(arr, gated_pos_out)) but the gating set extent is $gated_extent"
                    )
                )
                for k in _gated_const_keys(alias_claims, model, key, nm)
                    out[k] = arr
                end
            end
        end
    end
    return out
end

# A stashed gated entry is either the bare provider (gate via `provider_gate_spec`)
# or a `(prov=…, gate=…)` / `Dict("prov"=>…, "gate"=>…)` bundle.
function _unbundle_gated(entry)
    if entry isa NamedTuple && haskey(entry, :prov)
        return entry.prov, (
                haskey(entry, :gate) && entry.gate !== nothing ?
                entry.gate : provider_gate_spec(entry.prov)
            )
    elseif entry isa AbstractDict && haskey(entry, "prov")
        g = get(entry, "gate", nothing)
        return entry["prov"], (g === nothing ? provider_gate_spec(entry["prov"]) : g)
    else
        return entry, provider_gate_spec(entry)
    end
end

"""
    _build_evaluator(esm::AbstractDict; model_name=nothing, kwargs...)

Parse a raw ESM dict, then delegate to the typed entry point, which is faster
for callers that already have a parsed `Model`.

`const_arrays` (forwarded via kwargs) accepts pre-computed float arrays keyed
by name; a read `index(name, i…)` at constant subscripts is inlined as a
literal value.
"""
function _build_evaluator(
        esm::AbstractDict; compiler::Union{Symbol, CompilerPlan} = :native, kwargs...
    )
    # Before the pre-build work below, which is not cheap and which a refusal
    # would throw away.
    _xla_check_form(
        compiler isa Symbol ? compiler : compiler.name, get(kwargs, :form, :inplace)
    )
    # The requested plan is installed HERE, not only at `_build_evaluator_impl`:
    # the binning-coordinate derivation and value invention below run first and
    # hand their results to the build as const arrays, so a per-cell setup sweep
    # they perform is never seen again. Outside this scope they would run under
    # the process default, which is not strict and not the interpreter.
    return _with_compiler_plan(_plan_for(compiler)) do
        _build_evaluator_dict(esm; compiler = compiler, kwargs...)
    end
end

function _build_evaluator_dict(
        esm::AbstractDict;
        model_name::Union{Nothing, AbstractString} = nothing,
        kwargs...
    )
    kwd = Dict{Symbol, Any}(kwargs)

    # ---- Phase 4: AUTOMATIC projection-pushdown desugar (opt-in) ----
    # When `pushdown_rewrite=true`, recognise the ISRM-shaped `+`-aggregate /
    # sparse-binned-factor pattern in a CLEAN model and generate the four
    # hand-authored Phase-2b constructs (derived set + `distinct` producer +
    # member_factor + gated_select) BEFORE parsing, so the value-invention
    # front door and the impl re-parse both see them. A no-op (returns `esm`
    # unchanged) when the pattern does not match or the semiring guard fails.
    # OFF by default: every existing build path is byte-identical.
    if get(kwd, :pushdown_rewrite, false) === true
        esm = desugar_pushdown(esm; model_name = model_name)
    end
    delete!(kwd, :pushdown_rewrite)

    # `coerce_esm_file` normalizes every dict-like carrier (JSON3 object,
    # native Dict, JSONLikeDict) itself — no JSON-string round-trip.
    file = _coerce_or_load(esm)
    _refuse_float32(file, model_name)

    # ---- Value-invention front-door (RFC §6.1), on the TYPED IR ----
    # `OpExpr` preserves the full value-invention vocabulary (`id`, `distinct`,
    # `key`, `join`; see OPEXPR_FIELD_TABLE), so any derived index set is
    # materialised from the typed model and the extents threaded into the typed
    # path. A no-op (and byte-identical) for models without a `distinct` producer.
    model = _select_model_or_nothing(file, model_name)

    # ---- §9.6.4 rule 2 at the FRONT-DOOR pre-passes ----
    # Option B keeps `apply_expression_template` references UNINLINED until the
    # build boundary, where `_build_evaluator_impl` expands them with site
    # recording. But several build-time pre-passes run out HERE, before that
    # entry: the binning-coordinate derivation, value invention, the
    # `member_factor` feedback and the overlap-env derivation. They evaluate
    # expression bodies directly through `_eval_cellwise`, which has no
    # `apply_expression_template` arm — so a document that factors a
    # build-time-evaluated observed (an LCC projection, say) through a template
    # died here with `E_TREEWALK_UNSUPPORTED_OP` while the SAME document built
    # in Rust and Python. Rule 2 governs: a reference DENOTES its expansion and
    # every consumer MAY expand. Expand once for these passes, on a copy — the
    # impl expands its own copy and keeps its sites, and a model with no
    # surviving reference is not touched, so every existing build is
    # byte-identical.
    if model !== nothing && _model_has_surviving_refs(model)
        _tmpl_reg = _component_template_reg(file, model_name)
        if _tmpl_reg !== nothing
            model = _expansion_copy(model)
            # The impl expands the same model against the same registry: it
            # takes this expansion's cache (`_ExpandCache`).
            cache = _ExpandCache()
            _expand_model_refs!(model, _tmpl_reg; memo = cache)
            kwd[:_expand_cache] = cache
        end
    end

    # ---- §9.6.3 constraint 6 at the FRONT-DOOR pre-passes ----
    # The binning-coordinate derivation and value invention below evaluate
    # observed bodies before `_build_evaluator_impl` is reached, so the
    # rewrite-target walk runs here too, ahead of them.
    if model !== nothing
        cache = get(kwd, :_expand_cache, nothing)
        if cache isa _ExpandCache
            _reject_unlowered_operators(model, cache.gate_lhs, cache.gate_rhs)
        else
            _reject_unlowered_operators(model)
        end
    end

    # ---- Caller-key canonicalization (esm-spec §6.6) ----
    # Rewrite the caller's LOCAL-named `parameter_overrides` onto this
    # document's (flattening-qualified) parameter names once, at the front
    # door, so the setup env, the binning-coordinate derivation, the
    # value-invention materialisation, and the typed impl below all read the
    # SAME resolved values. Without this a spec-spelled `{"pert_amp": 0}`
    # missed every one of them and the run silently used the default.
    if model !== nothing && haskey(kwd, :parameter_overrides)
        kwd[:parameter_overrides] = _normalize_param_override_keys(
            model, kwd[:parameter_overrides]
        )
    end
    # The same for the caller's `const_arrays` keys, so the front-door pre-passes
    # below read a shaped parameter's array under the name the model spells.
    if model !== nothing && haskey(kwd, :const_arrays)
        kwd[:const_arrays] = _normalize_const_array_keys(model, kwd[:const_arrays])
    end
    if model !== nothing && haskey(kwd, :const_array_boundaries)
        kwd[:const_array_boundaries] = _normalize_const_array_keys(
            model, kwd[:const_array_boundaries]
        )
    end

    # ---- Build-time binning-coordinate derivation (RFC §8.6.1 purity) ----
    # A broad-phase binning coordinate declared INLINE as a reduce aggregate over the
    # in-file `const` geometry (e.g. `src_lon[i] = min_v src_poly[i,v,1]`) is a
    # build-time constant. Evaluate it once from the const-op arrays and thread it
    # into `const_arrays`, so a key over `floor(index(src_lon,i)/dx)` resolves at setup
    # without the host supplying the coordinate. No-op (byte-identical) when no such
    # observed exists.
    _params = get(kwd, :parameter_overrides, Dict{String, Float64}())
    _ca = Dict{String, Any}(String(k) => v for (k, v) in get(kwd, :const_arrays, Dict{String, Any}()))
    # The build-time parameter-read sink (see `_PARAM_READS`) is created HERE,
    # not in the impl: two of the build-time consumers — the binning-coordinate
    # derivation and value invention (whose `_vi_param` reads decide an index-set
    # EXTENT, i.e. `length(u)`) — run at this front door, before the impl entry.
    # The same set is threaded down so the classification sees all of them.
    _preads = get(kwd, :_param_reads, nothing)
    _preads === nothing && (_preads = Set{String}())
    kwd[:_param_reads] = _preads
    if model !== nothing
        # The coordinate buffers a value-invention key GATHERS from (`src_lon`,
        # `tgt_lon`): a build-time-constant one is derived here so a
        # TEMPLATE-CONSTRUCTED (aggregate-valued) coordinate is admissible as a
        # key index target (not only a const-supplied / reduce-over-const one).
        _vi_targets = _vi_index_targets(model)
        # A coordinate whose body needs the GENERAL build-time evaluator (an LCC
        # projection's trig/`^` expansion — ops outside the setup-time geometry
        # vocabulary) is projected HERE, before value-invention, and its `X`/`Y`
        # fed into `const_arrays`.
        _derived = _with_param_reads(_preads) do
            _derive_binning_coords(
                model, file.index_sets, _ca, _params, _vi_targets
            )
        end
        if !isempty(_derived)
            merge!(_ca, _derived)
            kwd[:const_arrays] = _ca
        end
    end

    # A value-invention key column may be an unknown defined by a `const`
    # equation (esm-spec §4.2): that is build-time data exactly as a supplied
    # const array is, so the relational engine reads it. The extra entries are
    # scoped to value invention; `kwd[:const_arrays]` is not widened.
    _vi_ca = _ca
    if model !== nothing
        for (n, defn) in observed_definitions(model)
            (_is_array_shape(model.variables[n].shape) && _is_const_op(defn)) || continue
            haskey(_ca, n) && continue
            _vi_ca === _ca && (_vi_ca = copy(_ca))
            _vi_ca[n] = _const_op_to_array((defn::OpExpr).value)
        end
    end
    _vi = model === nothing ? nothing :
        _with_param_reads(_preads) do
            materialize_value_invention(
                model, file.index_sets,
                _vi_ca, _params
            )
    end

    # ---- Phase 2b Hook 1: value-invention MEMBERS fed back as const factors ----
    # A `kind:"derived"` index set may name a `member_factor` — a model parameter
    # const factor the build fills HERE with the set's materialised member ids
    # (`vi.members[from_faq]`, 1-based full-grid ids). This is the ONLY path a
    # derived set's member VALUES (not just its dense extent `[1,n]`) reach the
    # ODE body: `cell_W[c] = index(W, index(<member_factor>, c))` gathers the
    # full-grid rows the compact derived axis selects. (There is NO `member(set,c)`
    # IR op — this feedback IS the mechanism.) Mirrors the `_derive_binning_coords`
    # merge above: the injected factor rides `const_arrays` into the impl build.
    if _vi !== nothing && !isempty(_vi.members)
        _fed = _feed_back_vi_members(file.index_sets, _vi.members, model)
        if !isempty(_fed)
            merge!(_ca, _fed)
            kwd[:const_arrays] = _ca
        end
    end

    # ---- Phase 2b Hook 1b: OVERLAP env factors on a DERIVED axis ----
    # §5.5.6 requires an `join.overlap` gate's envelope factors to be const-array
    # data — the broad phase runs ONCE at build time. The pushdown rewrite gates
    # each rewritten binning aggregate on the generated `pd_cell__*` gathers,
    # which live on the compact derived axis and so cannot exist until the axis
    # is sized (value invention) and its member factor is fed back (Hook 1
    # above). Derive them here, immediately after. No-op (byte-identical) for a
    # document whose overlap-gate factors are already const arrays — which is
    # every document that predates the rewrite's forward gate.
    if model !== nothing
        _envf = _with_param_reads(_preads) do
            _derive_overlap_env_factors(
                model, file.index_sets, _ca, _params,
                (_vi === nothing ? Dict{String, Int}() : _vi.extents)
            )
        end
        if !isempty(_envf)
            merge!(_ca, _envf)
            kwd[:const_arrays] = _ca
        end
    end

    # ---- Phase 2b Hook 2: gated-provider deferral → post-VI selective fetch ----
    # A GATED provider (its `.esm` data_loader declares a `gated_select`; the
    # runner reports it via `provider_gate_spec`) was SKIPPED by the eager const
    # loop in `esm_problem` and stashed in `_gated_providers`. Now that value-invention
    # has materialised the gating derived set's members + extent, push that set
    # down to the provider as a per-axis `selection` and fetch ONLY the compact
    # slab, merging it into `const_arrays` under the model variable name(s) the
    # gate's `applies_to` lists. This is the const-tier dependency edge:
    # value-invention (above) → gated provider_sample(selection) → const merge.
    _gated = get(kwd, :_gated_providers, nothing)
    if _gated !== nothing && !isempty(_gated)
        _t0 = Float64(get(kwd, :_sample_time, 0.0))
        _fetched = _fetch_gated_providers(_gated, file.index_sets, _vi, _t0, model)
        if !isempty(_fetched)
            merge!(_ca, _fetched)
            kwd[:const_arrays] = _ca
        end
    end
    # These are consumed here; do not forward to the typed impl entry point.
    delete!(kwd, :_gated_providers)
    delete!(kwd, :_sample_time)

    kwd[:_vi_extents] = _vi === nothing ? Dict{String, Int}() : _vi.extents
    kwd[:_vi_vars] = _vi === nothing ? Set{String}() : _vi.vi_var_names
    kwd[:_vi_maps] = _vi === nothing ? _EMPTY_VI_MAPS : (maps = _vi.maps, map_sets = _vi.map_sets)
    # A range-restricted program keeps what the front door produced, so a later
    # restriction of it re-lowers without re-reading the document.
    _range_front_door_done(_range_spec_now(), file, model_name, kwd)
    return _build_evaluator(file; model_name = model_name, kwd...)
end

# Does any equation / variable expression of `model` (or a subsystem) carry a
# surviving `apply_expression_template` node? Build-time guard input; one cheap
# whole-model walk (the traversal descends `bindings` too, which is harmless
# here — the apply node itself is what is being detected). Identity-memoized
# (`foreach_subexpr_once`): an existence predicate is path-multiplicity-
# insensitive, and equation trees can be compact DAGs (ESS-0hh).
function _model_has_surviving_refs(model::Model)
    found = false
    check(e) = e === nothing || found ? nothing : foreach_subexpr_once(e) do x
            x isa OpExpr && x.op == "apply_expression_template" && (found = true)
            nothing
    end
    for eqs in (model.equations, model.initialization_equations)
        for eq in eqs
            check(eq.lhs); check(eq.rhs)
        end
    end
    # A parameter update's `when` / `expression` are expression positions too,
    # and an unlowered template reference in one is just as surviving.
    for (_, var) in model.variables
        var.update === nothing && continue
        for rule in var.update
            check(rule.when); check(rule.expression)
        end
    end
    if !found
        for (_, sub) in model.subsystems
            sub isa Model && _model_has_surviving_refs(sub) && (found = true)
        end
    end
    return found
end

# Select one typed model from an `EsmFile`, mirroring `_select_model`'s name
# resolution WITHOUT throwing: the value-invention front-door skips
# materialisation when no model matches and lets the typed entry point raise the
# proper `E_TREEWALK_NO_MODEL` / `E_TREEWALK_AMBIGUOUS_MODEL` diagnostic.
function _select_model_or_nothing(file::EsmFile, model_name)
    models = file.models
    (models === nothing || isempty(models)) && return nothing
    model_name !== nothing && return get(models, String(model_name), nothing)
    return length(models) == 1 ? first(values(models)) : nothing
end

"""
    evaluate_expr(expr::ASTExpr, bindings::AbstractDict)::Float64

Evaluate a single AST expression at the supplied numeric `bindings` by
running it through the same compile + walker pipeline as
the evaluator build. All keys of `bindings` are exposed as readable
state variables; the special name `"t"` (if present) is bound to the
walker's time argument as well. Adding an op to the tree-walk evaluator
transparently extends this entry point — there is no separate dispatch
table.

Throws `UnboundVariableError` when `expr` references a name that is not
in `bindings` and is not the time variable; other failures surface as
[`TreeWalkError`](@ref).
"""
function evaluate_expr(
        expr::ASTExpr, bindings::AbstractDict
    )::Float64
    var_map = Dict{String, Int}()
    u = Vector{Float64}(undef, length(bindings))
    i = 0
    for (name, _) in bindings
        i += 1
        sname = String(name)
        var_map[sname] = i
        u[i] = Float64(bindings[name])
    end
    node = try
        _compile(expr, var_map, Set{Symbol}())
    catch e
        if e isa TreeWalkError && e.code == "E_TREEWALK_UNBOUND_VARIABLE"
            throw(
                UnboundVariableError(
                    e.detail,
                    "Variable '$(e.detail)' not found in bindings"
                )
            )
        end
        rethrow(e)
    end
    t = haskey(bindings, "t") ? Float64(bindings["t"]) : 0.0
    return _eval_node(node, u, NamedTuple(), t)
end


# esm-spec §4.3.1 (issue #441): refuse a `faq` whose `expr` or `filter` reads a
# shaped variable by bare name, with the same code `validate` reports. Run on the
# template-expanded model at the build entry, so the refusal does not depend on
# whether the name was written inline or delivered by a template binding.
function _refuse_faq_bare_array_operands(model::Model)
    shapes = Dict{String, Vector{String}}(
        n => String[String(x) for x in v.shape]
            for (n, v) in model.variables if v.shape !== nothing && !isempty(v.shape)
    )
    isempty(shapes) && return nothing
    for (i, eq) in enumerate(model.equations)
        # A bare read of the variable an observed or recurrence definition
        # defines is a self-reference the recurrence / cycle rules own; a
        # derivative's state is not exempt.
        defined = faq_bare_exempt_names(eq.lhs)
        found = faq_bare_array_operands(eq.rhs, shapes; exclude = defined)
        isempty(found) && continue
        field, name, shape = first(found)
        throw(
            TreeWalkError(
                ERROR_CODES.FAQ_BARE_ARRAY_OPERAND,
                "equations[$i].rhs: " * faq_bare_array_operand_message(field, name, shape)
            )
        )
    end
    return nothing
end
