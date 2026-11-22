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

function _refuse_float32(file::EsmFile, model_name::Union{Nothing, AbstractString})
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
`_record_param_read` seam) and anything they touched is `:structural` — by
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
    _build_selected(file::EsmFile, model_name, opts::BuildOptions)

The build of `file`'s selected model from the products of the front door
(`_front_door`): the build itself, with no pre-pass. A re-lowering of a
range-restricted program re-enters here with the options the front door
produced (`_relower_options`).
"""
function _build_selected(
        file::EsmFile, model_name::Union{Nothing, AbstractString}, opts::BuildOptions
    )
    model = _time_spelled_t(_select_model(file, model_name), _indep_var(file))
    # Thread the document-scoped index-set registry into the typed evaluator.
    return _build_evaluator_impl(
        model; index_sets = file.index_sets,
        _template_reg = _component_template_reg(file, model_name),
        _build_kwargs(opts)...
    )
end

# The build spells the time variable `t`: `_compile` lowers a bare `t` to the
# time node, and the cadence classifiers, the initial-state pass and the
# synthesized fill equations (`D(…; wrt = "t")`) test that name. A document
# whose independent variable has another name (`domain.independent_variable`,
# esm-spec §11.3) has every free read of it, and every `wrt` naming it,
# respelled `t` at this boundary. After flatten every declared name is
# qualified (`Component.var`), so the respelling cannot capture one; a bare
# `t` declared in the model would be one, and is refused. A scope binding the
# name (an aggregate's index, an integral's variable) keeps its own reads.
function _time_spelled_t(model::Model, iv::String)
    iv == "t" && return model
    _refuse_bare_t(model, iv)
    return map_expressions(_time_respeller(iv), model)
end
# The whole document (the front door's pre-passes read its selected model).
function _time_spelled_t(file::EsmFile)
    iv = _indep_var(file)
    iv == "t" && return file
    file.models === nothing || foreach(m -> _refuse_bare_t(m, iv), values(file.models))
    return map_expressions(_time_respeller(iv), file)
end

function _refuse_bare_t(model::Model, iv::String)
    return haskey(model.variables, "t") && throw(
        TreeWalkError(
            "E_TREEWALK_TIME_NAME_CLASH",
            "the independent variable is '$iv', but the model declares a bare variable " *
                "named 't', the build's spelling of time"
        )
    )
end

function _time_respeller(iv::String)
    function respell(e::ASTExpr)::ASTExpr
        e isa VarExpr && return (e::VarExpr).name == iv ? VarExpr("t") : e
        e isa OpExpr || return e
        o = e::OpExpr
        binds = (o.output_idx !== nothing && any(==(iv), o.output_idx)) ||
            (o.ranges !== nothing && haskey(o.ranges, iv)) || o.int_var == iv
        binds && return o
        r = map_children(respell, o)
        return (r isa OpExpr && (r::OpExpr).wrt == iv) ? reconstruct(r::OpExpr; wrt = "t") : r
    end
    return respell
end

# The selected model's surviving-reference registry ("models.<name>" in
# `EsmFile.component_templates`, esm-spec §9.6.4 Option B), or `nothing` when the
# document carries none. Mirrors `_select_model`'s name resolution; a selection
# `_select_model` would reject returns `nothing` here and lets it throw.
function _component_template_reg(file::EsmFile, model_name::Union{Nothing, AbstractString})
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

Not for build or analysis paths: esm-spec §9.6.4 rule 2 says builders,
evaluators and analyses SHOULD NOT expand references (they analyse and compile
each template once). This is an explicit expansion utility for tools and
interchange.
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

"""
    _build_evaluator(file::EsmFile; compiler = :native, model_name = nothing, kwargs...)
    _build_evaluator(esm::AbstractDict; pushdown_rewrite = false, model_name = nothing, kwargs...)

Build the selected model of a document: the front door's pre-passes
(`_front_door`), then the build. A native document is coerced first, after the
projection-pushdown desugar when `pushdown_rewrite` asks for it.

`const_arrays` accepts pre-computed float arrays keyed by name; a read
`index(name, i…)` at constant subscripts is inlined as a literal value.
"""
function _build_evaluator(
        file::EsmFile; compiler::Union{Symbol, CompilerPlan} = :native,
        model_name::Union{Nothing, AbstractString} = nothing, kwargs...
    )
    # Before the pre-build work, which is not cheap and which a refusal would
    # throw away.
    _xla_check_form(
        compiler isa Symbol ? compiler : compiler.name, get(kwargs, :form, :inplace)
    )
    # The plan is installed for the front door as well as the build: the
    # binning-coordinate derivation and value invention run first and hand their
    # results to the build as const arrays, so a per-cell setup sweep they perform
    # is never seen again. Outside this scope they would run under the process
    # default, which is not strict and not the interpreter.
    return _with_compiler_plan(_plan_for(compiler)) do
        _build_front(_front_door(file, model_name; compiler = compiler, kwargs...))
    end
end

function _build_evaluator(
        esm::AbstractDict; pushdown_rewrite::Bool = false,
        model_name::Union{Nothing, AbstractString} = nothing, kwargs...
    )
    pushdown_rewrite && (esm = desugar_pushdown(esm; model_name = model_name))
    return _build_evaluator(_coerce_or_load(esm); model_name = model_name, kwargs...)
end

"""
    _FrontDoor

What the build's pre-passes produced for one document: the document and the
model they selected, the value-invention result, and the build's options with
the pre-passes' products added (the canonical override and const-array keys,
the derived const arrays, the build-time parameter-read set, the template
expansion cache). `_build_front` builds from it; a range-restricted program
keeps it to re-lower without re-reading the document.
"""
struct _FrontDoor
    file::EsmFile
    model_name::Union{Nothing, String}
    model::Union{Nothing, Model}
    vi::Any
    opts::BuildOptions
end

# Add `extra` to the const arrays the build of `front` reads (the gated
# provider fetch's slabs). The registry is copied first: it may be the caller's.
function _merge_front_const_arrays!(front::_FrontDoor, extra::AbstractDict)
    isempty(extra) && return front
    ca = Dict{String, Any}(
        String(k) => v for (k, v) in something(front.opts.const_arrays, Dict{String, Any}())
    )
    merge!(ca, extra)
    front.opts.const_arrays = ca
    return front
end

# The build from a front door's product. A range-restricted program's build
# records the product first, so a restriction of it re-lowers from there.
function _build_front(front::_FrontDoor)
    opts = front.opts
    opts.vi_extents = front.vi === nothing ? Dict{String, Int}() : front.vi.extents
    opts.vi_vars = front.vi === nothing ? Set{String}() : front.vi.vi_var_names
    opts.vi_maps = front.vi === nothing ? _EMPTY_VI_MAPS :
        (maps = front.vi.maps, map_sets = front.vi.map_sets)
    _range_front_door_done(_range_spec_now(), front.file, front.model_name, opts)
    return _build_selected(front.file, front.model_name, opts)
end

# The build's pre-passes over `file`'s selected model: the binary32 refusal,
# template expansion and the unlowered-operator gate for the passes below,
# caller-key canonicalization, the binning-coordinate derivation, value
# invention, the value-invention members fed back as const factors, and the
# overlap envelope factors.
function _front_door(
        file::EsmFile, model_name::Union{Nothing, AbstractString};
        kwargs...
    )::_FrontDoor
    opts = BuildOptions(; kwargs...)
    _refuse_float32(file, model_name)
    file = _time_spelled_t(file)

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
            # The pre-passes read the model as the build does: references
            # compiled as calls, with the template table in the build state
            # (`_tpl_prepare_model!`, on a copy and against a copy of the
            # registry; the impl prepares its own from `file`).
            model = _expansion_copy(model)
            model, _ = _tpl_prepare_model!(model, copy(_tmpl_reg), file.index_sets, Dict{String, Int}(); refuse = false)
        end
    end

    # ---- §9.6.3 constraint 6 at the FRONT-DOOR pre-passes ----
    # The binning-coordinate derivation and value invention below evaluate
    # observed bodies before `_build_evaluator_impl` is reached, so the
    # rewrite-target walk runs here too, ahead of them.
    if model !== nothing
        cache = opts.expand_cache
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
    if model !== nothing && opts.parameter_overrides !== nothing
        opts.parameter_overrides = _normalize_param_override_keys(
            model, opts.parameter_overrides
        )
    end
    # The same for the caller's `const_arrays` keys, so the front-door pre-passes
    # below read a shaped parameter's array under the name the model spells.
    if model !== nothing && opts.const_arrays !== nothing
        opts.const_arrays = _normalize_const_array_keys(model, opts.const_arrays)
    end
    if model !== nothing && opts.const_array_boundaries !== nothing
        opts.const_array_boundaries = _normalize_const_array_keys(
            model, opts.const_array_boundaries
        )
    end

    # ---- Build-time binning-coordinate derivation (RFC §8.6.1 purity) ----
    # A broad-phase binning coordinate declared INLINE as a reduce aggregate over the
    # in-file `const` geometry (e.g. `src_lon[i] = min_v src_poly[i,v,1]`) is a
    # build-time constant. Evaluate it once from the const-op arrays and thread it
    # into `const_arrays`, so a key over `floor(index(src_lon,i)/dx)` resolves at setup
    # without the host supplying the coordinate. No-op (byte-identical) when no such
    # observed exists.
    _params = something(opts.parameter_overrides, Dict{String, Float64}())
    _ca = Dict{String, Any}(String(k) => v for (k, v) in something(opts.const_arrays, Dict{String, Any}()))
    # The build-time parameter-read sink (see `_record_param_read`) is created HERE,
    # not in the impl: two of the build-time consumers — the binning-coordinate
    # derivation and value invention (whose `_vi_param` reads decide an index-set
    # EXTENT, i.e. `length(u)`) — run at this front door, before the impl entry.
    # The same set is threaded down so the classification sees all of them.
    _preads = something(opts.param_reads, Set{String}())
    opts.param_reads = _preads
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
            opts.const_arrays = _ca
        end
    end

    # A value-invention key column may be an unknown defined by a `const`
    # equation (esm-spec §4.2): that is build-time data exactly as a supplied
    # const array is, so the relational engine reads it. The extra entries are
    # scoped to value invention; `opts.const_arrays` is not widened.
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
                _vi_ca, _params; independent_variable = _indep_var(file)
            )
    end

    # ---- Value-invention members fed back as const factors ----
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
            opts.const_arrays = _ca
        end
    end

    # ---- Overlap envelope factors on a derived axis ----
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
            opts.const_arrays = _ca
        end
    end

    return _FrontDoor(
        file, model_name === nothing ? nothing : String(model_name), model, _vi, opts
    )
end

# Does any equation / variable expression of `model` (or a subsystem) carry a
# surviving `apply_expression_template` node? Build-time guard input; one cheap
# whole-model walk (the traversal descends `bindings` too, which is harmless
# here — the apply node itself is what is being detected). Identity-memoized
# (`foreach_subexpr_once`): an existence predicate is path-multiplicity-
# insensitive, and equation trees can be compact DAGs.
function _model_has_surviving_refs(model::Model)
    found = false
    check(e) = e === nothing || found ? nothing : foreach_subexpr_once(e) do x
            x isa OpExpr && x.op == "apply_operator" && (found = true)
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


# esm-spec §4.3.1: refuse a `faq` whose `expr` or `filter` reads a
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
        found = faq_bare_array_operands(eq.rhs, shapes; exclude = defined, through_calls = true)
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
