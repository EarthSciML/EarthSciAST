# ============================================================
# The compiled observed program (the output-time observed route)
# ============================================================
#
# Reading an observed at output time — `observed_field(prob, name; u, t)`, an
# inline-test assertion, an output sink — is an evaluation esm-libraries-spec
# §2.5.10 puts under the compiler's rule. Under `native` it runs a program
# compiled ONCE per build and name, from the same cascade the right-hand side
# takes: each array observed on the path to the requested one is a synthesized
# fill equation (`_materialized_fill_equation`) whose output slots are a block
# above the state in one extended value vector, exactly the factored
# array-observed levels `f!` fills on every call (`_fill_obs_levels!`), with the
# requested observed as the last level's output. A scalar observed is one
# compiled node over that vector, the scalar walker the right-hand side's
# scalar equations use. The build of a program is independent of N; a run is
# one pass over the vector.
#
# The program reads the STATE through the build's own layout, so the same
# program answers at any `(u, t)` — which is what makes a state-dependent
# observed readable at all — and the parameters the build bound.
#
# `interpreter` does not come here: it keeps the build-time cellwise evaluator
# (`evaluate_cellwise`), the oracle this program is checked against bit for bit.

# Everything a program build needs from the build that produced the problem.
# Captured by `_build_compile_evaluator` into the problem's `BuildInspection`,
# bound to the problem when `esm_problem` publishes it, and holding the
# problem's programs as they are built.
mutable struct _ObsProgramCtx
    model::Any
    cls::Any
    parts::Any
    index_sets::AbstractDict
    var_map::Any                         # the ODE layout (a `StateLayout`)
    array_var_info::Any
    n_states::Int
    p::Any                               # the parameter NamedTuple the build bound
    param_sym_set::Any
    const_registry::AbstractDict
    pgather::AbstractDict
    reg_funcs::AbstractDict
    template_sites::Any
    discrete_caches::Dict{String,Array{Float64}}
    # Every observed definition the build's split published (inlined and
    # materialized), by build name, as authored after lowering.
    defs::Dict{String,ASTExpr}
    state_names::Set{String}
    programs::Dict{String,Any}
    lock::ReentrantLock
end

"""
    _ObservedProgram

One compiled observed. `levels` fill the array observeds on the path to it in
dependency order over an extended vector of `n_total` slots whose first
`n_states` are the state; the result is `out_slots` of that vector, in the
ROW-MAJOR cell order of `cells` (the order `observed_field` and the inline-test
runner return), or `scalar` evaluated over it for a rank-0 observed. A
discrete-cadence field is read out of its cache instead (`cache`).
"""
struct _ObservedProgram
    name::String
    dims::Vector{Int}
    cells::Vector{Vector{Int}}
    levels::Tuple
    scalar::Any                          # `_Node` or `nothing`
    cache::Union{Nothing,Array{Float64}}
    n_total::Int
    n_states::Int
    out_slots::Vector{Int}
    reads_state::Bool
    reads_time::Bool
end

# Whether the plan in force runs the array cascade — `native` and `xla` do,
# `interpreter` does not.
_array_cascade_on() = (pl = _compiler_plan_now(); pl.stencil || pl.codegen ||
                       pl.array_contraction)

# Whether `def` reads a continuous state and whether it reads `t`, in any
# expression field. Loop symbols the definition binds are not references.
function _def_state_time_refs(def::ASTExpr, state_names::Set{String})
    bound = Set{String}()
    foreach_subexpr_once(def) do e
        e isa OpExpr || return nothing
        if e.output_idx !== nothing
            for s in e.output_idx
                push!(bound, String(s))
            end
        end
        if e.ranges !== nothing
            for k in keys(e.ranges)
                push!(bound, String(k))
            end
        end
        nothing
    end
    st = false
    tm = false
    foreach_subexpr_once(def) do e
        (e isa VarExpr && !(e.name in bound)) || return nothing
        e.name == "t" ? (tm = true) : (e.name in state_names && (st = true))
        nothing
    end
    return st, tm
end

# The row-major (last index fastest) cells of a dense `1…dims` box — the order
# every observed-field surface returns.
_row_major_cells(dims::Vector{Int}) =
    sort!(vec(Vector{Int}[collect(Int, Tuple(I)) for I in CartesianIndices(Tuple(dims))]))

# The program for build name `name`, built on first request and kept on the
# context, or `nothing` when the name is not an observed this route can take
# (the caller then takes the build-time cellwise route). Refusals raised while
# compiling propagate.
function _observed_program!(ctx::_ObsProgramCtx, name::String)
    lock(ctx.lock) do
        haskey(ctx.programs, name) && return ctx.programs[name]
        prog = _build_observed_program(ctx, name)
        ctx.programs[name] = prog
        return prog
    end
end

# A compile against a layout of its own must not share the build-scoped state
# slot tables (`_STATE_SLOT_TABLES`, keyed by array name) with any other
# layout: a program's extended layout places the materialized observeds
# differently from the right-hand side's and from another program's, so a table
# cached under one layout reads the wrong slots under the next. `f` runs with
# an empty table, and the caller's tables are put back afterwards. One compile
# at a time, since the table is process-wide.
const _OWN_SLOT_TABLES_LOCK = ReentrantLock()

function _with_own_state_slot_tables(f)
    lock(_OWN_SLOT_TABLES_LOCK) do
        saved = copy(_STATE_SLOT_TABLES)
        empty!(_STATE_SLOT_TABLES)
        try
            return f()
        finally
            empty!(_STATE_SLOT_TABLES)
            merge!(_STATE_SLOT_TABLES, saved)
        end
    end
end

_build_observed_program(ctx::_ObsProgramCtx, name::String) =
    _with_own_state_slot_tables(() -> _build_observed_program_impl(ctx, name))

function _build_observed_program_impl(ctx::_ObsProgramCtx, name::String)
    model = ctx.model
    v = get(model.variables, name, nothing)
    v === nothing && return nothing
    if haskey(ctx.discrete_caches, name)
        cache = ctx.discrete_caches[name]
        dims = collect(Int, size(cache))
        return _ObservedProgram(name, dims, _row_major_cells(dims), (), nothing,
                                cache, 0, ctx.n_states, Int[], false, false)
    end
    haskey(ctx.defs, name) || return nothing
    shaped = _is_array_shape(v.shape)
    # An array observed is taken when it is one the right-hand side's factoring
    # could materialize — a promoted array observed; the others keep the
    # build-time route.
    shaped && !(name in ctx.cls.array_inline_vars) && return nothing
    dims = Int[]
    if shaped
        d = _materialized_obs_dims(ctx.defs[name], v.shape, ctx.index_sets,
                                   ctx.parts.derived_extents)
        (d === nothing || isempty(d) || any(<=(0), d)) && return nothing
        length(v.shape) == length(d) || return nothing
        dims = d
    end
    # The array observeds this one reads, directly or through other observeds,
    # each materialized as a level of its own — the same factoring the
    # right-hand side applies — so a producer is evaluated once, not once per
    # cell of each reader.
    mat = _program_materialized_set(ctx, name, shaped)
    mat_vars = collect(mat)
    parts = ctx.parts
    cls = ctx.cls
    _, resolved_obs, raw_obs, mat_defs = _split_observed_and_derivatives(
        parts.equations, parts.observed_names, cls.geom_ring_vars,
        cls.geom_setup_vars, cls.geom_inline_vars, cls.array_inline_vars, mat,
        Set{String}(n for (n, vv) in model.variables if _is_array_shape(vv.shape)))
    # The extended layout: the state, then one block per materialized observed.
    mat_dims = Dict{String,Vector{Int}}()
    for m in mat_vars
        mat_dims[m] = m == name ? dims :
            _materialized_obs_dims(mat_defs[m], model.variables[m].shape,
                                   ctx.index_sets, parts.derived_extents)
    end
    avi = copy(ctx.array_var_info)
    blocks = Pair{String,Tuple{Vector{Int},Vector{Int}}}[]
    for m in sort(mat_vars)
        avi[m] = (ones(Int, length(mat_dims[m])), copy(mat_dims[m]))
        push!(blocks, m => avi[m])
    end
    vm = _layout_extend(ctx.var_map, blocks)
    n_total = length(vm)
    # Whether the program reads the state or `t`: a property of every body it
    # evaluates, each with the non-materialized observeds substituted in.
    st = false
    tm = false
    for m in mat_vars
        s1, t1 = _def_state_time_refs(_sub_preserving(mat_defs[m], resolved_obs),
                                      ctx.state_names)
        st |= s1; tm |= t1
    end
    levels = Any[]
    if !isempty(mat_vars)
        for lvl in _materialized_obs_levels(mat_defs, mat, raw_obs)
            lvl_scalars = Tuple{Int,_Node}[]
            lvl_kernels = _AccKernel[]
            lvl_scans = _ScanFold[]
            lvl_acs = _ArrayContraction[]
            for m in lvl
                feq = _materialized_fill_equation(m, mat_defs[m], mat_dims[m])
                se, pcs, aks, sfs, acs = _with_rule_alias(m, m) do
                    _compile_derivative_equations(Equation[feq], resolved_obs, avi, vm,
                        ctx.const_registry, ctx.pgather, ctx.param_sym_set,
                        ctx.reg_funcs, n_total; template_sites=ctx.template_sites)
                end
                for (slot, ex) in se
                    push!(lvl_scalars, (slot, _compile(ex, vm, ctx.param_sym_set,
                                                       ctx.reg_funcs)))
                end
                append!(lvl_scalars, pcs)
                append!(lvl_kernels, aks)
                append!(lvl_scans, sfs)
                append!(lvl_acs, acs)
            end
            merged, _ = _merge_acc_kernel_classes(lvl_kernels)
            section = _with_open_rule_label(name) do
                _make_kernel_section(merged)
            end
            push!(levels, (lvl_scalars, section, lvl_scans,
                           _make_contraction_section(lvl_acs)))
        end
    end
    scalar = nothing
    out_slots = Int[]
    cells = shaped ? _row_major_cells(dims) : [Int[]]
    if shaped
        b = _layout_block(vm, name)
        out_slots = Int[_block_slot(b, c) for c in cells]
    else
        body = get(resolved_obs, name, nothing)
        body === nothing && return nothing
        s1, t1 = _def_state_time_refs(body, ctx.state_names)
        st |= s1; tm |= t1
        scalar = _compile(_resolve_indices(body, avi, vm, ctx.const_registry, ctx.pgather),
                          vm, ctx.param_sym_set, ctx.reg_funcs)
    end
    return _ObservedProgram(name, dims, cells, Tuple(levels), scalar, nothing,
                            n_total, ctx.n_states, out_slots, st, tm)
end

# Run `f` with `label` as the rule a refusal raised inside it names, outside
# any build (an output-time read has no build record open).
function _with_open_rule_label(f, label::String)
    rec = _BuildRecord(_compiler_plan_now())
    rec.current = label
    return _with_build_record(f, rec)
end

# The array observeds a program for `name` materializes: `name` itself when it
# is an array, and every array observed it reaches through the observed
# definitions that the right-hand side's factoring would also accept — a
# promoted array observed (`array_inline_vars`), not a discrete cache (read
# from its buffer) and not read in a structural position, where the build needs
# its value as a constant.
function _program_materialized_set(ctx::_ObsProgramCtx, name::String, shaped::Bool)
    model = ctx.model
    defs = ctx.defs
    out = Set{String}()
    shaped && push!(out, name)
    seen = Set{String}([name])
    frontier = collect(_referenced_var_names(defs[name]))
    while !isempty(frontier)
        r = pop!(frontier)
        (r in seen || !haskey(defs, r)) && continue
        push!(seen, r)
        append!(frontier, collect(_referenced_var_names(defs[r])))
        r in ctx.cls.array_inline_vars || continue
        haskey(ctx.discrete_caches, r) && continue
        rv = get(model.variables, r, nothing)
        (rv !== nothing && _is_array_shape(rv.shape)) || continue
        d = _materialized_obs_dims(defs[r], rv.shape, ctx.index_sets,
                                   ctx.parts.derived_extents)
        (d === nothing || isempty(d) || any(<=(0), d) ||
         length(rv.shape) != length(d)) && continue
        push!(out, r)
    end
    producers = setdiff(out, (name,))
    if !isempty(producers)
        hits = Set{String}()
        sseen = _ObsSeen()
        for n in seen
            haskey(defs, n) && _array_obs_structural_refs!(defs[n], producers, hits, sseen)
        end
        setdiff!(out, hits)
    end
    return out
end

# Run `prog` at state `u` (`nothing` for a program that reads none) and time
# `t`. Returns the field in row-major cell order. Kernel sections carry scratch,
# so one program runs one call at a time.
function _run_observed_program(ctx::_ObsProgramCtx, prog::_ObservedProgram,
                               u::Union{Nothing,AbstractVector}, t::Float64)
    if prog.cache !== nothing
        c = prog.cache
        return ndims(c) > 1 ? vec(permutedims(c, reverse(1:ndims(c)))) : vec(copy(c))
    end
    if u !== nothing && length(u) != prog.n_states
        throw(SimulateError("observed_field: `u` has $(length(u)) elements but the " *
                            "problem's state vector has $(prog.n_states)"))
    end
    pp = ctx.p === nothing ? NamedTuple() : ctx.p
    return lock(ctx.lock) do
        ue = zeros(Float64, prog.n_total)
        u === nothing || copyto!(ue, 1, u, 1, prog.n_states)
        _fill_obs_levels!(prog.levels, ue, pp, t, Float64)
        prog.scalar === nothing ? ue[prog.out_slots] :
            Float64[_eval_node(prog.scalar, ue, pp, t)]
    end
end

# The build name a read resolves to: the component-qualified spelling first,
# then the bare one where the caller allows it — the order `_observed_field`
# looks the published forms up in.
function _program_build_name(ctx::_ObsProgramCtx, qualified::String,
                             bare::Union{Nothing,String})
    known(n) = haskey(ctx.defs, n) || haskey(ctx.discrete_caches, n)
    known(qualified) && return qualified
    (bare !== nothing && known(bare)) && return bare
    return nothing
end

# The program context `prob`'s own build captured, or `nothing` for a problem
# whose build captured none (a compiler that builds its own program).
_obs_ctx(prob) = lock(() -> get(prob.inspection.observed_ctxs, prob.run_file, nothing),
                      prob.inspection.observed_lock)

# Whether a read was served by a compiled observed program: the output-time
# row's tier says so. Task-local, like the per-cell count beside it
# (compiler.jl), so another task's reads do not leak in.
const _PROGRAM_READ_KEY = :earthsci_obs_program_read

function _counting_program_reads(f)
    outer = get(task_local_storage(), _PROGRAM_READ_KEY, nothing)
    r = Ref(0)
    v = task_local_storage(f, _PROGRAM_READ_KEY, r)
    outer === nothing || (outer[] += r[])
    return v, r[]
end

_note_program_read!() =
    (r = get(task_local_storage(), _PROGRAM_READ_KEY, nothing);
     r === nothing || (r[] += 1); nothing)
