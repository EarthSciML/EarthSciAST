# Reading an observed field off a Problem (`observed_field`, API_SPEC §5.8).
#
# One reader serves the public `observed_field`, an output sink's snapshot and
# an inline-test assertion. A name is resolved against the Problem's observeds
# (`_observed_field_impl`); the field is then produced by the first route of
# `_observed_field` that can serve it, every route answering in row-major cell
# order.

"""
    observed_field(prob::EsmProblem, name; u = nothing, t = nothing) -> Vector{Float64}

The observed `name` of the problem, as a flat vector in row-major cell order
(last index fastest; one element for a scalar observed).

With no `u`, it is the field the BUILD defines: a state-free observed evaluated
with the parameters the problem was built with, at `t = 0` unless `t` is given.
With `u` — a state vector laid out like `prob.u0`, such as `sol.u[k]` — it is
the observed at that state and time `t` (default `0`), which is how a
STATE-DEPENDENT observed is read; `t` is `sol.t[k]` for a saved solution point.
A read at a state or time binds the problem's own parameters `prob.p`, so on a
`remake(prob; p = …)` it answers with the substituted values.

Under `compiler = :native` the value comes from a program compiled once per
problem and name — the same array cascade as the right-hand side, run over the
state — so a read costs one pass over the field whatever `u` and `t` are. Under
`compiler = :interpreter` it is the build-time cellwise evaluator, the oracle the
compiled program agrees with bit for bit. The first read of a name files an
`:observed` row in [`compiler_report`](@ref) naming the route
(`:output_compiled`, or `:output_compiled_once` / `:output_percell` for the
cellwise evaluator); an observed native cannot compile is refused by name.

Two arguments (API_SPEC §5.8): the problem owns what its build produced, so no
[`BuildInspection`](@ref) is passed here.
`u` and `t` are keywords, not arguments: the result has the rank of the field
whatever they are, which API_SPEC §5.8 lets a binding that can overload spell
this way.

Resolution is the cross-binding rule of API_SPEC §5.8, in precedence order:

1. **Exact hit** — `name` is a flattened observed name (`"ISRM.deathsK"`).
2. **Bare name** — `name` carries no `.`, and the document has exactly ONE
   component; it then resolves to the unique observed with that tail
   (`"deathsK"`).

A bare name against a MULTI-component document is refused, with every qualified
candidate named, rather than bound to an arbitrary one.

Throws a `SimulateError` when `name` is not an evaluable observed (an unsized
axis, or not an observed at all), or when it reads the state and no `u` was
given.
"""
function observed_field(
        prob::EsmProblem, name::AbstractString;
        u::Union{Nothing, AbstractVector} = nothing,
        t::Union{Nothing, Real} = nothing
    )
    return _observed_field_read(prob, String(name), u, t, prob.p)
end

# `observed_field` with the parameter carrier `p` to read at: the problem's own,
# or a running integrator's (an output sink's snapshot).
function _observed_field_read(
        prob::EsmProblem, name::String,
        u::Union{Nothing, AbstractVector},
        t::Union{Nothing, Real}, p
    )
    # A compiler that built its own program answers for its own observeds: under
    # `:mtk` the value lives in the compiled system's OBSERVED EQUATIONS, which
    # this package's build-time observed graph knows nothing about.
    backend = _compiler_backend(prob.f!)
    backend === nothing ||
        return _backend_observed_field(backend, prob, name; u = u, t = t)
    # Reading an observed at output time is one of the evaluations
    # esm-libraries-spec §2.5.10 puts under the compiler's refusal rule, so it
    # runs under the plan that BUILT the problem rather than under whatever
    # plan (if any) happens to be in scope on the reader's task.
    return _with_compiler_plan(_plan(compiler(prob))) do
        _with_problem_calls(prob) do
            _observed_field_memo(prob, name, u, t, p)
        end
    end
end

# Run `f` with the problem's template call targets (call.jl) on the current
# build state: an output-time read compiles and evaluates the build's
# expressions, whose template references are calls.
function _with_problem_calls(f, prob::EsmProblem)
    octx = prob.build.products.observed_ctx
    calls = octx === nothing ? nothing : octx.calls
    calls === nothing && return f()
    st = _build_state()
    saved = st.calls
    st.calls = calls
    try
        return f()
    finally
        st.calls = saved
    end
end

# The output-time tiers an `observed_field` row can carry.
const _OUTPUT_TIERS = (:output_compiled, :output_compiled_once, :output_percell)

# The output-time route, reported in the problem's compiler report and, for the
# build-time read (no `u`, no `t`), memoized on the problem's build. The first
# read of a name in this build files one `:observed` row saying which route
# served it, from what THIS call did (`_counting_program_reads`,
# `_counting_percell`). A memoized read at the same forcing epoch returns the
# stored field without evaluating anything: that read is state-free, so only an
# in-place refresh of a live buffer (which bumps the epoch) can move it. A
# `remake` of the problem shares the build and so the memo: the build-time read
# reports what the build materialized (API_SPEC §5.8), with the build's
# parameters, which a `p` or `u0` swap does not change. A read at a state or
# time is the observed as a function of `(u, p, t)`, so it binds `p` — the
# reading problem's, or the running integrator's.
function _observed_field_memo(
        prob::EsmProblem, name::String,
        u::Union{Nothing, AbstractVector} = nothing,
        t::Union{Nothing, Real} = nothing, p = nothing
    )
    build = prob.build
    memoizable = u === nothing && t === nothing
    memoizable && (p = nothing)
    # The read gathers the discrete-cadence caches, so bring them up to an
    # announced forcing write first, as `f!` does; a read between the
    # announcement and the next `f!` would otherwise store the old fill under
    # the new epoch. It also settles the epoch the memo is keyed on, since a
    # refill bumps it.
    prob.dm.refresh!()
    epoch = _epoch_value(prob.dm.epoch)
    if memoizable
        hit = lock(() -> get(build.observed_memo, name, nothing), build.observed_lock)
        hit !== nothing && hit.epoch == epoch && return copy(hit.value)
    end
    (v, nprog), percell = _counting_percell() do
        _counting_program_reads() do
            _observed_field_impl(prob, name; u = u, t = t, p = p)
        end
    end
    lock(build.observed_lock) do
        # One row per name per build, filed into this build's report.
        rules = build.products.compiler_report.rules
        if !any(
                r -> r.kind === :observed && r.rule == name && r.tier in _OUTPUT_TIERS,
                rules
            )
            tier = nprog > 0 ? :output_compiled :
                percell > 0 ? :output_percell : :output_compiled_once
            push!(rules, CompilerRuleRecord(name, :observed, tier))
        end
        memoizable && (build.observed_memo[name] = _ObservedMemo(epoch, copy(v)))
    end
    return v
end

function _observed_field_impl(
        prob::EsmProblem, name::AbstractString;
        u::Union{Nothing, AbstractVector} = nothing,
        t::Union{Nothing, Real} = nothing, p = nothing
    )
    insp = prob.build.products
    ctx = _obs_ctx(prob)
    file = prob.run_file
    (file.models !== nothing && !isempty(file.models)) || throw(
        SimulateError(
            "observed_field: prepared document has no model",
            ERROR_CODES.INTERNAL_ERROR
        )
    )
    mname = String(first(keys(file.models)))
    field_of(k) = _observed_field(
        insp, file, mname, k; ctx = ctx, u = u, t = t,
        var_map = prob.var_map, p = p
    )
    # A name an `operator_compose` renaming match DELETED addresses a field that
    # MOVED (issue #230). The merge only ever REMOVES a spelling, so resolving
    # here can never shadow a live field.
    v = get(prob.merged_renames, String(name), String(name))
    model = file.models[mname]
    observeds = NameTable(observed_unknowns(model))
    comps = _name_components(observeds)
    single = length(comps) == 1
    fld = field_of(v)
    if fld === nothing && !occursin('.', v)
        # Bare spelling: resolved only on a SINGLE-component document (API_SPEC
        # §5.8). On a multi-component one the bare name is refused with every
        # candidate named.
        r = resolve_key(observeds, v; bare = :single_component)
        if r.name !== nothing
            fld = field_of(r.name)
        elseif r.how === :ambiguous && !single
            throw(
                SimulateError(
                    "observed_field: '$name' is a bare name and this problem has " *
                        "$(length(comps)) components ($(join(sort!(collect(comps)), ", "))); " *
                        "qualify it as one of: $(join(r.candidates, ", "))",
                    ERROR_CODES.AMBIGUOUS_OUTPUT_NAME
                )
            )
        end
    end
    if fld === nothing
        # MATERIALIZED observeds. A build-once body (an overlap-area weight, a
        # gated reduction) is materialized at
        # SETUP into `insp.setup_arrays` rather than left as a build-time
        # observed — and so, transitively, is everything downstream of it, since
        # a setup array is a build constant and its readers fold against it.
        # `_observed_field` looks only at the observed graph, so on a document
        # whose emissions come from an area overlap rather than a point
        # containment that is the WHOLE reported chain: the per-cell emissions,
        # the source-receptor contraction, the concentrations and the deaths all
        # became unreadable BY NAME, even though the build computed every one of
        # them. `const_arrays` is the same story one step earlier: a projected
        # coordinate (`X`, `Y`) is materialized ahead of value invention and
        # seeded there as a build constant, so it too is computed and unreadable.
        # The array the build itself used is the value; return it rather than
        # re-deriving it. Flattened in the same ROW-MAJOR cell order
        # `_observed_field` returns (`_state_cells`, the Python `np.ndindex` and
        # the Rust row-major enumeration all agree on it), so the two paths are
        # interchangeable at any rank.
        # The setup arrays are keyed by the name as the SETUP pass saw it — the
        # AUTHORED model's flattened name (`ISRM.E_PM25`) — while `mname` here
        # is the RUN document's single model, which flattening renamed
        # (`Flattened`). So resolve by tail as well, and only when it is
        # unambiguous: two models may carry the same local name, and answering
        # a bare `E_PM25` with an arbitrary one of them would be worse than
        # refusing.
        # GUARD: only an OBSERVED may be answered this way. `const_arrays` also
        # holds every array-valued PARAMETER, and quietly returning one of those
        # from `observed_field` would turn a wrong name into a plausible answer.
        obs = Set{String}(observed_unknowns(model))
        is_obs = any(
            k -> (
                String(k) == v ||
                    (single && String(split(String(k), '.')[end]) == v)
            )
                && String(k) in obs, keys(model.variables)
        )
        is_obs || throw(
            SimulateError(
                "observed_field: '$name' is not a build-time-evaluable observed of the " *
                    "prepared document",
                ERROR_CODES.OBSERVED_FIELD_UNAVAILABLE
            )
        )
        arr = nothing
        for reg in (insp.setup_arrays, insp.const_arrays)
            arr = get(reg, mname * "." * v, get(reg, v, nothing))
            if arr === nothing && single
                # Bare tail, single-component only — same §5.8 gate the observed
                # graph applies above, so the two fallbacks cannot disagree
                # about whether a bare name is answerable.
                hits = [
                    k for k in keys(reg)
                        if occursin('.', k) && String(split(k, '.')[end]) == v
                ]
                length(hits) == 1 && (arr = reg[first(hits)])
            end
            arr isa AbstractArray || (arr = nothing)
            arr === nothing || break
        end
        arr === nothing && throw(
            SimulateError(
                "observed_field: '$name' is not a build-time-evaluable observed of the " *
                    "prepared document",
                ERROR_CODES.OBSERVED_FIELD_UNAVAILABLE
            )
        )
        return ndims(arr) > 1 ? vec(permutedims(arr, reverse(1:ndims(arr)))) : vec(arr)
    end
    return fld[1]
end

# Build-time scalar-parameter scope for §6.6.5 cellwise references, as the
# component that OWNS the test writes names.
#
# `BuildInspection.params` is keyed by the FLATTENED parameter name (e.g. "M.k",
# "M.sub.g") — matching a resolved observed expression, which flattening
# qualifies. A test author's analytic `reference`, however, spells a name the way
# the owning component's own EQUATIONS spell it: BARE ("k") for the component's
# own parameter, and by the MOUNT NAME ("sub.g") for one reached through a
# subsystem mount. So the scope binds, in decreasing precedence:
#
#  1. the flattened key VERBATIM;
#  2. every key under `owner.`, stripped of that prefix — the owning component's
#     own namespace, which is what its equations resolve against. "M.sub.g" is
#     "sub.g" here even in a document where five OTHER components each mount a
#     `sub` of their own. This is the same re-attachment `_scope_to_component`
#     performs on an override key: `wrf.g` resolves in a `reference` as it
#     does in every equation of a coupling and in `parameter_overrides`,
#     where `<Model>.wrf.g` alone would be a spelling a mount edge does NOT
#     rewrite, so it
#     pins a component to being mounted under its own model name;
#  3. every GLOBALLY unambiguous dotted suffix ("M.sub.g" -> "sub.g", "g"), the
#     alias set esm-spec §6.6.2 rule 3 gives an override key. This is what lets
#     a test name a parameter the owner does not own, and it subsumes the
#     bare-tail alias this function bound before.
#
# A suffix carried by two or more flattened names is AMBIGUOUS and binds nothing
# at step 3 — the flattened key stays authoritative and such a reference must
# qualify further (step 2 still reaches the owner's own, which is unambiguous by
# construction: flattened keys are unique, so their owner-relative remainders are
# too). A name that is neither is UNBOUND, which is what keeps a typo ("sub.gg")
# an error rather than a silent zero.
#
# The suffixes are the override resolver's own (`NameTable`, src/name_table.jl),
# so the two positions cannot drift apart.
function _param_scope_with_aliases(
        params::AbstractDict,
        owner::AbstractString = ""
    )::Dict{String, Float64}
    out = Dict{String, Float64}(String(k) => Float64(v) for (k, v) in params)
    # (2) The owner's own namespace, as its equations spell it.
    if !isempty(owner)
        prefix = String(owner) * "."
        for (k, v) in params
            s = String(k)
            startswith(s, prefix) || continue
            rest = s[(ncodeunits(prefix) + 1):end]
            haskey(out, rest) || (out[rest] = Float64(v))
        end
    end
    # (3) Globally unambiguous dotted suffixes (esm-spec §6.6.2 rule 3).
    byname = Dict{String, Any}(String(k) => v for (k, v) in params)
    for (suffix, names) in NameTable(keys(byname)).by_suffix
        (length(names) == 1 && !haskey(out, suffix)) &&
            (out[suffix] = Float64(byname[only(names)]))
    end
    return out
end

# The TRAJECTORY SAMPLE as an evaluation scope: every state of `var_map`, read
# out of the flat state vector `state` and re-assembled into the shape its
# references expect — an array state as an `Array{Float64}` addressed by its own
# 1-based cell tuple, under its flattened stem (`"PB.u"`, from the `"PB.u[3]"`
# cell keys); a scalar state as a `Float64`.
#
# This is what makes a STATE-DEPENDENT observed readable at an assertion time.
# `evaluate_cellwise` binds names from two scopes — `const_arrays` (arrays) and
# `params` (scalars) — and STATE was in neither, so `dudt = D(D(u,lev),lev)`
# could only ever fail with `E_TREEWALK_UNBOUND_VARIABLE: PB.u`. Handing it the
# solved state at the assertion time binds exactly the names the resolved
# observed expression reads, and nothing else: the values are the solver's own,
# so the observed is evaluated at the state the trajectory actually had.
#
# A stem whose cell keys do not tile a dense box (a partial or ragged layout) is
# skipped rather than guessed at. `_parse_cell_key` (tree_walk.jl) is the single
# inverse of the `name[i,j]` cell-key encoding.
function _state_scope(var_map::StateLayout, state::AbstractVector)
    # The layout IS the cell table: each array is one contiguous column-major
    # block, so its sample is a reshaped slice, with no key made or parsed. A
    # block whose box does not start at 1 does not tile a dense 1-based array
    # and is skipped, as below.
    arrays = Dict{String, Any}()
    scalars = Dict{String, Float64}()
    for (i, s) in enumerate(_layout_scalar_names(var_map))
        i <= length(state) && (scalars[s] = Float64(state[i]))
    end
    for b in _layout_blocks(var_map)
        (all(==(1), b.lo) && b.base + b.len - 1 <= length(state)) || continue
        ext = Tuple(b.hi[d] - b.lo[d] + 1 for d in eachindex(b.lo))
        arrays[b.name] = Array{Float64}(
            reshape(
                Float64[state[k] for k in b.base:(b.base + b.len - 1)], ext
            )
        )
    end
    return arrays, scalars
end

function _state_scope(var_map::AbstractDict, state::AbstractVector)
    arrays = Dict{String, Any}()
    scalars = Dict{String, Float64}()
    cells = Dict{String, Vector{Tuple{Vector{Int}, Int}}}()
    for (name, slot) in var_map
        s = String(name)
        i = Int(slot)
        (1 <= i <= length(state)) || continue
        parsed = _parse_cell_key(s)
        if parsed === nothing
            scalars[s] = Float64(state[i])
        else
            stem, cell = parsed
            push!(get!(cells, String(stem), Tuple{Vector{Int}, Int}[]), (cell, i))
        end
    end
    for (stem, entries) in cells
        nd = length(first(entries)[1])
        all(e -> length(e[1]) == nd, entries) || continue
        exts = Int[maximum(e[1][d] for e in entries) for d in 1:nd]
        (prod(exts) == length(entries) && all(>(0), exts)) || continue
        arr = Array{Float64}(undef, exts...)
        for (cell, slot) in entries
            arr[cell...] = Float64(state[slot])
        end
        arrays[stem] = arr
    end
    return arrays, scalars
end

# Extents of a declared `shape`, one per axis, or `nothing` when any axis is not
# sized at build time. Shared by the observed-field materialization and the
# per-cell lift of an author-level observed body, so both enumerate the same
# cells from the same index-set registry.
function _shape_extents(
        insp::BuildProducts, file::EsmFile,
        shape
    )::Union{Vector{Int}, Nothing}
    exts = Int[]
    for s in shape
        iset = get(file.index_sets, String(s), nothing)
        iset === nothing && return nothing
        e = if iset.kind == "interval"
            iset.size
        elseif iset.kind == "categorical"
            iset.members === nothing ? nothing : length(iset.members)
        elseif iset.kind == "derived"
            # A DERIVED axis is sized by value invention, which has already run
            # by the time an observed field is requested. `derived_extents` is
            # keyed by the PRODUCER id, so resolve through `from_faq` — without
            # this an observed shaped on an invented axis (ISRM's per-source
            # `E_VOC` over `emis_src_cells`) is simply unreadable, even though
            # the same axis resolves fine one level down when the observed is a
            # producer of something else.
            iset.from_faq === nothing ? nothing :
                get(insp.derived_extents, String(iset.from_faq), nothing)
        else
            nothing
        end
        e === nothing && return nothing
        push!(exts, Int(e))
    end
    return exts
end

# The const-array key holding `<mname>.<name>`'s materialized buffer, or
# `nothing` when the build materialized no such field FOR THIS COMPONENT.
#
# QUALIFIED-FIRST, the array analog of `_scalar_slot` / `_state_cells` (§6.6,
# §6.6.5): the model-qualified key wins outright, and the BARE key is this
# component's only when no model qualifies that suffix — a bare-keyed registry
# is the single-model build. Reading the bare key while some `<other>.<name>`
# exists would answer an `M2` assertion with `M1`'s buffer, which is exactly
# what the two-pass rule elsewhere in this file exists to prevent.
function _const_array_key(
        insp::BuildProducts, mname::AbstractString,
        name::AbstractString
    )::Union{String, Nothing}
    qual = String(mname) * "." * String(name)
    haskey(insp.const_arrays, qual) && return qual
    haskey(insp.const_arrays, String(name)) || return nothing
    suffix = "." * String(name)
    any(k -> endswith(String(k), suffix), keys(insp.const_arrays)) && return nothing
    return String(name)
end

# The component's OWN defining equation for `variable`, lowered to the per-cell
# form `evaluate_cellwise` consumes and rewritten into the build's FLATTENED
# name scope. This is the fallback for an observed the build published in
# neither `observed_exprs` nor `observed_defs` — an observed the
# elementwise fold inlined into its readers and dropped, which for a DEAD one
# (nothing reads it) means dropped outright.
#
# Three rewrites, in this order:
#
#  1. NAMED PRODUCERS. A reference to another observed of the same component is
#     replaced by that observed's published body when the build has one, and
#     otherwise — the same deadness, one level down — by ITS authored body,
#     resolved recursively. A name the build materialized into a const array is
#     left alone: the buffer is the cheaper and more faithful answer.
#  2. PER-CELL LIFT. The authored body is a WHOLE-ARRAY expression (`2 * u`),
#     while `evaluate_cellwise` walks one output cell at a time. Wrapping it in
#     a `faq` over the declared shape — through the same
#     `_index_array_leaves` the build's own promotion uses, with §4.3.4 name
#     alignment — is exactly the form the published map would have carried, and
#     its ranges are the extents already resolved for the cell enumeration, so
#     nothing here re-derives an axis.
#  3. QUALIFICATION. The authored equation names its operands as the AUTHOR
#     wrote them (`base`), while the build's const-array and parameter scopes
#     — and the trajectory sample `_state_scope` builds — are keyed by the
#     flattened name (`M.base`, `M.u`). Each bare leaf that resolves under
#     `<model>.<name>` in any of those scopes is rewritten to it; one that does
#     not is left untouched, so an unresolvable reference still raises the
#     unbound-variable error it earns rather than being silently renamed.
#     Including the state scopes here is what lets a DEAD observed that reads
#     STATE compose with the state-dependent path: this function makes it reach
#     the scope, and the sample makes its `u` resolve once it is `M.u`.
#
# Returns `nothing` when `variable` has no defining equation in the component,
# or when it reappears on its OWN dependency chain (a cycle is the build's to
# diagnose). `chain` is the path from the asserted name down to this one, NOT
# the set of everything visited: two siblings that read the same dead observed
# are a DIAMOND, not a cycle, and each must resolve it.
function _authored_observed_body(
        insp::BuildProducts, file::EsmFile, model::Model,
        mname::AbstractString, variable::AbstractString,
        exts::Vector{Int},
        chain::Vector{String} = String[];
        state_arrays::AbstractDict = Dict{String, Any}(),
        state_scalars::AbstractDict = Dict{String, Float64}()
    )
    String(variable) in chain && return nothing
    chain = vcat(chain, String(variable))
    body = observed_definition(model, String(variable))
    body === nothing && return nothing

    observed_here = Set{String}(observed_unknowns(model))
    var_shapes = Dict{String, Vector{String}}()
    for (n, mv) in model.variables
        mv.shape === nothing && continue
        var_shapes[String(n)] = String[String(x) for x in mv.shape]
    end
    arrayvars = Set{String}(
        String(n) for (n, mv) in model.variables
            if _is_array_shape(mv.shape)
    )

    # (1) Resolve the other observeds this body names.
    subs = Dict{String, ASTExpr}()
    for n in free_variables(body)
        name = String(n)
        (name == String(variable) || !(name in observed_here)) && continue
        qual = String(mname) * "." * name
        _const_array_key(insp, mname, name) === nothing || continue
        producer = get(insp.observed_exprs, qual, get(insp.observed_exprs, name, nothing))
        if producer === nothing
            nested = get(model.variables, name, nothing)
            nested === nothing && continue
            nshape = nested.shape === nothing ? String[] : nested.shape
            nexts = _shape_extents(insp, file, nshape)
            producer = nexts === nothing ? nothing :
                _authored_observed_body(
                    insp, file, model, mname, name, nexts, chain;
                    state_arrays = state_arrays,
                    state_scalars = state_scalars
                )
        end
        producer === nothing || (subs[name] = producer)
    end
    isempty(subs) || (body = substitute(body, subs))

    # (2) Lift the whole-array body to the per-cell `faq` form — through the
    # BUILD'S OWN `_lift_to_faq` (shape_promotion.jl), with the resolved
    # extents as ranges. Sharing it is the point: the `_p<k>` loop convention
    # and the §4.3.4 alignment then cannot drift from the promotion that minted
    # the published bodies this one stands in for.
    if !isempty(exts)
        body = _lift_to_faq(
            body, get(var_shapes, String(variable), String[]),
            arrayvars, var_shapes; bounds = exts
        )
    end

    # (3) Rewrite bare operand names into the build's flattened scope.
    renames = Dict{String, ASTExpr}()
    for n in free_variables(body)
        name = String(n)
        haskey(renames, name) && continue
        qual = String(mname) * "." * name
        (
            haskey(insp.const_arrays, qual) || haskey(insp.params, qual) ||
                haskey(state_arrays, qual) || haskey(state_scalars, qual)
        ) || continue
        renames[name] = VarExpr(qual)
    end
    isempty(renames) || (body = substitute(body, renames))

    # (4) Resolve `{from}` index-set ranges as the build resolves its equations
    # (`_resolve_index_set_ranges`): a ragged range becomes its per-cell
    # `[1, index(offsets, of…)]` bound, the offsets factor bound by bare name
    # to the in-scope array.
    if _has_index_set_ref(body)
        scope = Dict{String, Nothing}(String(k) => nothing for k in keys(insp.const_arrays))
        for k in keys(state_arrays)
            scope[String(k)] = nothing
        end
        body = _resolve_isr(
            body, file.index_sets, insp.derived_extents,
            _ragged_factor_scope(file.index_sets, scope)
        )
    end
    return body
end

# The build's resolved scalar parameter values with the scalar slots of the
# carrier `p` laid over them — the values a read against a remade problem binds.
# A positional carrier (a `ComponentVector`, a plain vector) is in the order of
# the build's own parameter NamedTuple, `ctx.p`.
_params_at(params::AbstractDict, ::Nothing, ctx) = params
function _params_at(params::AbstractDict, p::NamedTuple, ctx)
    out = Dict{String, Float64}(String(k) => Float64(v) for (k, v) in params)
    for (k, v) in pairs(p)
        v isa Real && (out[String(k)] = Float64(v))
    end
    return out
end
function _params_at(params::AbstractDict, p::AbstractVector, ctx)
    names = ctx === nothing || !(ctx.p isa NamedTuple) ? () : keys(ctx.p)
    length(names) == length(p) || throw(
        SimulateError(
            "observed_field: the parameter vector has $(length(p)) elements but the " *
                "build's parameter set has $(length(names))",
            ERROR_CODES.ARRAY_SHAPE_MISMATCH
        )
    )
    return _params_at(params, NamedTuple{names}(Tuple(p)), ctx)
end

"""
    _observed_field(products, file, mname, variable; ctx, u, t, var_map, p) -> (values, cells) | nothing

The field of observed `variable` of the component at `mname` in `file`, as its
values in row-major cell order (last index fastest, the Python `np.ndindex` and
Rust row-major order) and the cells, or `nothing` when `variable` is not an
observed of that component with a sized shape. A shapeless observed is rank 0:
one empty cell.

`products` are the build's; `ctx` its observed-program context (`nothing` for
a build that made none); `u` and `t` the state and time to read at (`nothing`
reads the build-time field); `var_map` the layout `u` is in; `p` the parameter
carrier to bind (`nothing` binds the build's own values).

The field is produced by the first route of `_OBSERVED_ROUTES` that serves it:

1. `_route_program` — the compiled observed program (observed_program.jl),
   under a plan that runs the array cascade, or under any plan for an
   observed that reaches a causal recurrence (which has no cellwise form);
2. `_route_buffer` — the buffer the build materialized, for an observed the
   build published no definition of because its body is build-once;
3. `_route_build_equation` — for an observed the build published no
   definition of, the build model's own defining equation with every observed
   it reads filled by that observed's program (`_authored_via_programs`);
4. `_route_definition` — the published definition (else the authored one,
   `_authored_observed_body`) evaluated per cell, its named producers
   materialized first when they all can be (`_materialized_obs_scope`).
"""
function _observed_field(
        insp::BuildProducts, file::EsmFile,
        mname::AbstractString, variable::AbstractString;
        ctx = nothing,
        u::Union{Nothing, AbstractVector} = nothing,
        t::Union{Nothing, Real} = nothing,
        var_map::Union{Nothing, AbstractDict} = nothing,
        p = nothing
    )
    # `models === nothing` for a document of reaction systems only, whose
    # components declare species rather than variables: no observed here.
    model = _component_at(file, mname)
    model isa Model || return nothing
    v = get(model.variables, String(variable), nothing)
    (v !== nothing && String(variable) in observed_unknowns(model)) || return nothing
    exts = _shape_extents(insp, file, v.shape === nothing ? String[] : v.shape)
    exts === nothing && return nothing
    r = _ObservedRead(insp, file, model, mname, variable, exts, ctx, u, t, var_map, p)
    for route in _OBSERVED_ROUTES
        got = route(r)
        got === nothing || return got
    end
    return nothing
end

# One `_observed_field` request, as its routes read it.
mutable struct _ObservedRead
    const products::BuildProducts
    const file::EsmFile
    const model::Model
    const mname::String
    const variable::String
    const qualified::String
    # The observed's BARE spelling, which names the reading component's own
    # observed; `nothing` under a scoped (dotted) component path, where a hit
    # under the bare name would belong to a different component.
    const bare::Union{Nothing, String}
    const exts::Vector{Int}
    const ctx::Any
    const u::Union{Nothing, AbstractVector}
    const t::Float64                      # 0.0 when no time was given
    const t_given::Bool
    const var_map::Union{Nothing, AbstractDict}
    const p::Any
    # Whether the plan runs the array cascade (else observed programs and
    # fills are walked per cell).
    const cascade::Bool
    # The trajectory sample at `u` and `t` as array and scalar scopes, made on
    # first use (`_read_scope`).
    scope::Union{Nothing, Tuple{Dict{String, Any}, Dict{String, Float64}}}
end

function _ObservedRead(insp, file, model, mname, variable, exts, ctx, u, t, var_map, p)
    mname, variable = String(mname), String(variable)
    return _ObservedRead(
        insp, file, model, mname, variable, mname * "." * variable,
        occursin('.', mname) ? nothing : variable, exts, ctx, u,
        t === nothing ? 0.0 : Float64(t), t !== nothing, var_map, p,
        _array_cascade_on(), nothing
    )
end

# The state at `r.u` (read through `r.var_map`) and the given time as the
# array and scalar scopes a cellwise evaluation binds; empty without either.
function _read_scope(r::_ObservedRead)
    if r.scope === nothing
        arrays, scalars = (r.u === nothing || r.var_map === nothing) ?
            (Dict{String, Any}(), Dict{String, Float64}()) : _state_scope(r.var_map, r.u)
        scalars = Dict{String, Float64}(String(k) => Float64(x) for (k, x) in scalars)
        r.t_given && (scalars["t"] = r.t)
        r.scope = (Dict{String, Any}(String(k) => x for (k, x) in arrays), scalars)
    end
    return r.scope
end

# A definition the build published for the observed (`defs` is the inlined
# `observed_exprs` or the un-inlined `observed_defs`): under the qualified name,
# else the bare one where that is the reading component's.
_published(r::_ObservedRead, defs::AbstractDict) =
    get(defs, r.qualified, r.bare === nothing ? nothing : get(defs, r.bare, nothing))

function _route_program(r::_ObservedRead)
    r.ctx === nothing && return nothing
    bname = _program_build_name(r.ctx, r.qualified, r.bare)
    (bname !== nothing && (r.cascade || _obs_reaches_recurrence(r.ctx, bname))) ||
        return nothing
    prog = _observed_program!(r.ctx, bname)
    (prog !== nothing && prog.dims == r.exts) || return nothing
    (r.u === nothing && prog.reads_state) && throw(
        SimulateError(
            "observed '$(r.variable)' reads the continuous state, so it is not " *
                "a build-time field; pass the state to read it at, " *
                "`observed_field(prob, name; u = …, t = …)`",
            ERROR_CODES.OBSERVED_FIELD_UNAVAILABLE
        )
    )
    vals = _run_observed_program(r.ctx, prog, r.u, r.t, r.p)
    # Under the interpreter the program's fills are walked per cell.
    r.cascade ? _note_program_read!() : _note_percell!()
    return (vals, prog.cells)
end

# An observed whose body is build-once (a document-literal `const` array, a
# setup geometry buffer) is dropped from the observed graph because its value
# already sits in the const-array registry; the buffer is the answer every
# reader of it saw.
function _route_buffer(r::_ObservedRead)
    (
        _published(r, r.products.observed_exprs) === nothing &&
            _published(r, r.products.observed_defs) === nothing
    ) || return nothing
    key = _const_array_key(r.products, r.mname, r.variable)
    buf = key === nothing ? nothing : r.products.const_arrays[key]
    (buf isa AbstractArray && eltype(buf) <: Real && size(buf) == Tuple(r.exts)) ||
        return nothing
    # Row-major is column-major of the axes reversed.
    vals = ndims(buf) <= 1 ? Vector{Float64}(vec(buf)) :
        Vector{Float64}(vec(permutedims(buf, ndims(buf):-1:1)))
    return (vals, _row_major_cells(r.exts))
end

# An observed the build published no definition of (one the elementwise fold
# inlined into its readers and dropped, or one nothing reads) is still
# assertable (esm-spec §6.6.5): its defining equation is read from the BUILD's
# model, where expression templates are expanded.
function _route_build_equation(r::_ObservedRead)
    r.ctx === nothing && return nothing
    (
        _published(r, r.products.observed_exprs) === nothing &&
            _published(r, r.products.observed_defs) === nothing
    ) || return nothing
    cells = _row_major_cells(r.exts)
    arrays, scalars = _read_scope(r)
    got = _authored_via_programs(
        r.ctx, r.products, r.qualified, cells, r.u, r.t, r.p, r.mname, arrays, scalars
    )
    return got === nothing ? nothing : (got, cells)
end

function _route_definition(r::_ObservedRead)
    insp = r.products
    arrays, scalars = _read_scope(r)
    # The fully-substituted form is self-contained; the un-inlined one names
    # its producers, so it evaluates only when every one of them is filled.
    inlined = _published(r, insp.observed_exprs)
    raw = _published(r, insp.observed_defs)
    expr = inlined === nothing ? raw : inlined
    if expr === nothing
        expr = _authored_observed_body(
            insp, r.file, r.model, r.mname, r.variable, r.exts;
            state_arrays = arrays, state_scalars = scalars
        )
        expr === nothing && return nothing
    end
    cells = _row_major_cells(r.exts)
    # The trajectory sample wins over a same-named build constant: a name that
    # is a STATE is not a constant. Time is bound on its own argument, never as
    # a parameter named `t`.
    params = merge(
        _param_scope_with_aliases(_params_at(insp.params, r.p, r.ctx), r.mname), scalars
    )
    const_scope = isempty(arrays) ? insp.const_arrays :
        merge(Dict{String, Any}(String(k) => x for (k, x) in insp.const_arrays), arrays)
    if raw !== nothing
        field = _with_materialized_producers(r, raw, cells, params, const_scope)
        field === nothing || return (field, cells)
    end
    return (evaluate_cellwise(expr, cells; const_arrays = const_scope, params = params, t = r.t), cells)
end

# The un-inlined definition `raw` evaluated once over `cells` after its named
# producers are filled in dependency order (`_materialized_obs_scope`), each by
# its compiled program where it has one. `nothing` when no producer could be
# filled, or when filling or evaluating fails in a way the self-contained
# inlined form does not (a producer reads a provider array not fetched yet, or
# an axis this scope cannot size), so the caller evaluates that form instead.
function _with_materialized_producers(r::_ObservedRead, raw, cells, params, const_scope)
    n0 = _percell_mark()
    try
        pread = (r.ctx === nothing || !r.cascade) ? nothing : (n, ex) -> begin
                bn = _program_build_name(r.ctx, r.mname * "." * n, n)
                bn === nothing && return nothing
                prog = _observed_program!(r.ctx, bn)
                (prog === nothing || prog.dims != ex || (r.u === nothing && prog.reads_state)) &&
                return nothing
                _note_program_read!()
                return _run_observed_program(r.ctx, prog, r.u, r.t, r.p)
            end
        ca = _materialized_obs_scope(
            r.products, r.file, r.mname, r.variable, params;
            base = const_scope, t = r.t, program_read = pread
        )
        ca === const_scope && return nothing
        return evaluate_cellwise(raw, cells; const_arrays = ca, params = params, t = r.t)
    catch err
        err isa EarthSciASTError || rethrow()
        # Whatever the abandoned attempt walked per cell served nothing.
        _percell_restore!(n0)
        return nothing
    end
end

const _OBSERVED_ROUTES = (_route_program, _route_buffer, _route_build_equation, _route_definition)

# An observed the build published no form of, evaluated from the build's own
# defining equation: each observed it reads by name is filled by that
# observed's compiled program (row-major values back into an array), a scalar
# one bound as a value, and the body then evaluated over `cells` with those in
# scope. `nothing` when the equation, or any observed it reads, has no such
# form, or the body does not compile once; the caller then takes the authored
# route.
function _authored_via_programs(
        ctx, insp::BuildProducts, qualified::String, cells,
        u, t::Float64, p, mname::String,
        state_arrays::AbstractDict, state_scalars::AbstractDict
    )
    # One array scope and one parameter scope for the whole recursion: a field
    # filled at any level is the same named observed at the same state and time
    # wherever else it is read, so a level reuses what a deeper one filled.
    ca = Dict{String, Any}(String(k) => v for (k, v) in insp.const_arrays)
    for (k, v) in state_arrays
        ca[String(k)] = v
    end
    params = _param_scope_with_aliases(_params_at(insp.params, p, ctx), mname)
    for (k, v) in state_scalars
        params[String(k)] = Float64(v)
    end
    return _authored_via_programs!(ca, params, ctx, qualified, cells, u, t, p, 0)
end

function _authored_via_programs!(
        ca::Dict{String, Any}, params::Dict{String, Float64}, ctx,
        qualified::String, cells, u, t::Float64, p, depth::Int
    )
    # The build's model names the observed without the document's outer scope
    # (`Flattened.M.x` asserted, `M.x` built): the longest dotted suffix it has.
    body = nothing
    name = qualified
    while true
        body = observed_definition(ctx.model, name)
        (body !== nothing || !occursin('.', name)) && break
        name = name[(findfirst('.', name) + 1):end]
    end
    body === nothing && return nothing
    qualified = name
    # A BARE array name of the target's rank reads the target's cell (§4.3.4,
    # the name-aligned elementwise case); a bare one of any other rank has no
    # cellwise reading here, so decline before filling anything it reads. A
    # name read only as an explicit `index` target is read where it says.
    nidx = isempty(cells) ? 0 : length(cells[1])
    bare, targets = _bare_reads!(Set{String}(), Set{String}(), body, Set{String}())
    for n in bare
        a = get(ca, n, nothing)
        v = get(ctx.model.variables, n, nothing)
        rank = a isa AbstractArray ? ndims(a) :
            (haskey(params, n) || v === nothing || v.shape === nothing) ? 0 :
            length(v.shape)
        (rank == 0 || rank == nidx) || return nothing
    end
    for n in _referenced_var_names(body)
        (haskey(ca, n) || haskey(params, n) || n == qualified) && continue
        if !(haskey(ctx.defs, n) || haskey(ctx.discrete_caches, n))
            # Another observed the build published nothing for: the same
            # evaluation, recursively, over its own declared cells.
            depth >= 16 && return nothing
            v = get(ctx.model.variables, n, nothing)
            (v === nothing || observed_definition(ctx.model, n) === nothing) && continue
            ext = Int[]
            for sname in (v.shape === nothing ? String[] : v.shape)
                is = get(ctx.index_sets, String(sname), nothing)
                (is isa IndexSet && is.size isa Int && is.size > 0) || return nothing
                push!(ext, is.size)
            end
            vals = _authored_via_programs!(
                ca, params, ctx, n, _row_major_cells(ext), u,
                t, p, depth + 1
            )
            vals === nothing && return nothing
            if isempty(ext)
                params[n] = Float64(vals[1])
            else
                ca[n] = length(ext) == 1 ? Vector{Float64}(vals) :
                    permutedims(
                        reshape(Vector{Float64}(vals), reverse(ext)...),
                        length(ext):-1:1
                    )
            end
            continue
        end
        prog = try
            _observed_program!(ctx, n)
        catch err
            err isa EarthSciASTError || rethrow()
            return nothing
        end
        (prog === nothing || (u === nothing && prog.reads_state)) && return nothing
        vals = _run_observed_program(ctx, prog, u, t, p)
        _array_cascade_on() ? _note_program_read!() : _note_percell!()
        if isempty(prog.dims)
            params[n] = Float64(vals[1])
        else
            d = prog.dims
            ca[n] = length(d) == 1 ? Vector{Float64}(vals) :
                permutedims(
                    reshape(Vector{Float64}(vals), reverse(d)...),
                    length(d):-1:1
                )
        end
    end
    syms = String["__esm_oidx_$d" for d in 1:nidx]
    subs = Dict{String, ASTExpr}()
    for n in bare
        a = get(ca, n, nothing)
        (a isa AbstractArray && ndims(a) >= 1) || continue
        ndims(a) == nidx || return nothing
        subs[n] = OpExpr("index", ASTExpr[VarExpr(n), (VarExpr(x) for x in syms)...])
    end
    if !isempty(subs)
        body = any(n -> n in targets, keys(subs)) ? _align_bare_reads(body, subs) :
            _sub_preserving(body, subs)
    end
    ce = _cellwise_compile_once(body, nidx, ca, params; t = t)
    ce === nothing && return nothing
    return Float64[ce(c) for c in cells]
end

# The target of an explicit `index` read (`x` in `index(x, i)`), or `nothing`.
_index_target(o::OpExpr) =
    (o.op == "index" && !isempty(o.args) && o.args[1] isa VarExpr) ? o.args[1] : nothing

# The names `e` reads BARE — free (no binder inside `e` binds them) and not the
# target of an explicit `index` read — into `out`, and the explicit targets
# into `targets`.
function _bare_reads!(
        out::Set{String}, targets::Set{String}, e::ASTExpr,
        bound::Set{String}
    )
    if e isa VarExpr
        (e::VarExpr).name in bound || push!(out, (e::VarExpr).name)
        return out, targets
    end
    e isa OpExpr || return out, targets
    o = e::OpExpr
    b = _bound_symbols(o)
    inner = isempty(b) ? bound : union(bound, b)
    tgt = _index_target(o)
    tgt === nothing || push!(targets, (tgt::VarExpr).name)
    for c in child_exprs(o)
        c === tgt || _bare_reads!(out, targets, c, inner)
    end
    return out, targets
end

# `e` with each bare read of a name in `subs` (as `_bare_reads!` finds them)
# replaced by its entry. `_sub_preserving` does the same when no name in
# `subs` is also an explicit target.
function _align_bare_reads(e::ASTExpr, subs::Dict{String, ASTExpr})
    e isa VarExpr && return get(subs, (e::VarExpr).name, e)
    e isa OpExpr || return e
    o = e::OpExpr
    if _binds_any(o, subs)
        subs = _shadowed_bindings(o, subs)
        isempty(subs) && return o
    end
    tgt = _index_target(o)
    return map_children(x -> x === tgt ? x : _align_bare_reads(x, subs), o)
end

"""
    _materialized_obs_scope(insp, file, mname, target, params; base) -> const-array scope

Materialize the ARRAY-shaped observed producers `target` depends on, once each in
dependency order, and return `base` augmented with those buffers.

`base` is the array scope the producers are evaluated AGAINST as well as the map
that is extended, and defaults to `insp.const_arrays` — the build-time answer.
A §6.6.5 assertion passes the build's const arrays plus the trajectory sample
(`_state_scope`), so a state-dependent target's producers resolve against the
solved state.

`evaluate_cellwise` walks the expression once per output cell, so an array
observed inlined into its readers would be re-executed at every cell of the
consumer's field; materializing each producer once removes that factor. The
right-hand side's factoring (`_collect_materialized_array_obs`) roots liveness
at the `D`/`ic` equations and so does nothing for a model with no state; this
path roots it at the requested observed.

Values are the same computation, but reading buffers instead of the inlined
body can reassociate floating-point sums between producers, so a downstream
field may differ in its last bits.

Returns `base` ITSELF (by identity, which is how the caller detects the no-op)
when there is nothing to materialize, so models whose observeds are scalar or
independent pay nothing.
"""
function _materialized_obs_scope(
        insp::BuildProducts, file::EsmFile,
        mname::AbstractString, target::AbstractString,
        params::AbstractDict;
        base::AbstractDict = insp.const_arrays,
        t::Float64 = 0.0, program_read = nothing
    )
    isempty(insp.observed_defs) && return base
    model = _component_at(file, mname)
    model isa Model || return base

    # TWO published forms of an observed's body, and this needs BOTH.
    #
    #   `observed_defs`  — UN-inlined: names its producers, so it is cheap to
    #                      evaluate once every producer is a buffer, but it only
    #                      resolves when every one of them IS.
    #   `observed_exprs` — fully substituted: always self-contained, and the only
    #                      form published for an observed the build inlined away.
    #
    # The second is not a redundant copy. An intermediate the build folded into
    # its readers — a rank-2 projected coordinate feeding a rank-1 length, say —
    # appears in `observed_exprs` and NOT in `observed_defs`, and it is not a
    # const array either. Traversing only the un-inlined map therefore stops at
    # the first such name: its readers' definitions reference it, the reference
    # is unbound, and EVERY producer above it fails in turn. The chain is then
    # inlined into the consumer and re-executed per output cell, which is the
    # exact cost this function exists to remove — silently, because the failure
    # is a caught exception and the fallback is merely slow, not wrong.
    raw_def(n) = get(
        insp.observed_defs, String(mname) * "." * n,
        get(insp.observed_defs, n, nothing)
    )
    res_def(n) = get(
        insp.observed_exprs, String(mname) * "." * n,
        get(insp.observed_exprs, n, nothing)
    )
    function lookup(n)                      # traversal: prefer the un-inlined form
        d = raw_def(n)
        return d === nothing ? res_def(n) : d
    end
    # Extents of an array observed from its declared shape. Goes through the
    # build's own resolver so a DATA-DERIVED axis works too — the ISRM emission
    # binning is shaped on `emis_src_cells`, whose size value invention
    # discovers, and an interval-only lookup would skip exactly the observed
    # that matters most. `nothing` ⇒ not materializable (scalar / unsized axis).
    observed_here = Set{String}(observed_unknowns(model))
    function extents(n)
        v = get(model.variables, n, nothing)
        (
            v !== nothing && n in observed_here &&
                v.shape !== nothing && !isempty(v.shape)
        ) || return nothing
        ex = Int[]
        for s in v.shape
            iset = get(file.index_sets, String(s), nothing)
            iset === nothing && return nothing
            e = if iset.kind == "interval"
                iset.size
            elseif iset.kind == "categorical"
                iset.members === nothing ? nothing : length(iset.members)
            elseif iset.kind == "derived"
                # `derived_extents` is keyed by the PRODUCER id, so follow the
                # set's `from_faq`. Without this the ISRM emission binning —
                # shaped on the value-invented `emis_src_cells` — is skipped,
                # and skipping it leaves every consumer above it unresolvable.
                iset.from_faq === nothing ? nothing :
                    get(insp.derived_extents, String(iset.from_faq), nothing)
            else
                nothing
            end
            (e === nothing || Int(e) <= 0) && return nothing
            push!(ex, Int(e))
        end
        return isempty(ex) ? nothing : ex
    end

    # Post-order DFS from the target over observed→observed references: a name is
    # emitted only after everything it reads, so a single left-to-right pass fills
    # buffers in dependency order. Cycles cannot occur (the build already rejects
    # them), but `onstack` keeps this total even if one slipped through.
    order = String[]; done = Set{String}(); onstack = Set{String}()
    function visit(n)
        (n in done || n in onstack) && return
        push!(onstack, n)
        def = lookup(n)
        if def !== nothing
            for r in EarthSciAST._referenced_var_names(def)
                lookup(String(r)) === nothing || visit(String(r))
            end
        end
        delete!(onstack, n); push!(done, n)
        return push!(order, n)
    end
    visit(String(target))

    ca = Dict{String, Any}(base)
    materialized = 0
    for n in order
        n == String(target) && continue        # the caller evaluates this one
        haskey(ca, n) && continue              # already supplied by the caller
        lookup(n) === nothing && continue
        ex = extents(n); ex === nothing && continue
        any(<=(0), ex) && continue
        cells = _row_major_cells(ex)
        # Try the un-inlined body first — it reads the buffers already filled, so
        # it is the cheap one — and fall back to the fully substituted body when
        # it cannot resolve. Both compute the same number: the substituted form
        # is literally what the consumer would otherwise have recomputed inline.
        # A producer neither form can evaluate here (one reading STATE, say) just
        # stays un-materialized, and its readers inline it.
        # Under a compiler that runs the array cascade, the producer's own
        # compiled observed program first (`program_read`): one pass, no per-cell
        # resolve.
        vals = program_read === nothing ? nothing : program_read(n, ex)
        n0 = _percell_mark()
        vals === nothing || @goto have_vals
        for cand in (raw_def(n), res_def(n))
            cand === nothing && continue
            vals = try
                evaluate_cellwise(cand, cells; const_arrays = ca, params = params, t = t)
            catch err
                err isa EarthSciASTError || rethrow()
                nothing
            end
            vals === nothing || break
        end
        @label have_vals
        # A producer left un-materialized served nothing, however it was tried.
        (vals !== nothing && length(vals) == length(cells)) ||
            (_percell_restore!(n0); continue)
        buf = Array{Float64}(undef, Tuple(ex)...)
        @inbounds for (i, c) in enumerate(cells)
            buf[CartesianIndex(Tuple(c))] = vals[i]
        end
        ca[n] = buf
        materialized += 1
    end
    return materialized == 0 ? base : ca
end
