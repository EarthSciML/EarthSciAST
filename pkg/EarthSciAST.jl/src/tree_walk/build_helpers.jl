# ========================================================================
# tree_walk/build_helpers.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Build-time helpers: the shared read-only _EMPTY_* sentinels, the
# const-array boundary policy (BoundedConstArray), the whole-array
# derivative lift, and the WS4 elementwise array-observed fold.
# ========================================================================

# ─────────────────────────────────────────────────────────────────────────────
# SHARED READ-ONLY `_EMPTY_*` SENTINELS — invariant: NEVER MUTATED.
#
# The `_EMPTY_*` constants scattered through this evaluator
# (`_EMPTY_DERIVED_EXTENTS`, `_EMPTY_IDX_ENV`, `_EMPTY_VI_MAPS`,
# `_EMPTY_FACTOR_SCOPE`, `_EMPTY_CONST_ARRAYS`, `_EMPTY_PARAMS`,
# `_EMPTY_PGATHER`) are single shared MUTABLE Dicts used as "no entries"
# default arguments so hot build paths don't allocate a fresh empty Dict per
# call. They are read-only BY CONVENTION ONLY (Julia has no frozen Dict, and
# switching to a distinct immutable type would perturb the type-stable
# hot-path signatures): every consumer may only `haskey`/`get`/iterate them,
# never `setindex!`/`push!`/`merge!` into one. Writing to a sentinel would
# silently leak state into every later build in the process. Code paths that
# need a mutable dict must branch to a fresh instance (see e.g. the
# `_derived_extents` selection in `_build_evaluator_impl`). The invariant is
# pinned by a test that asserts each sentinel is still empty after a full
# build+evaluate cycle (tree_walk_op_table_test.jl).
# ─────────────────────────────────────────────────────────────────────────────
const _EMPTY_DERIVED_EXTENTS = Dict{String,Int}()

# Shared read-only empty loop-variable environment (see the `_EMPTY_*` sentinel
# block above). `_eval_const_int` only ever
# reads its `idx_env` (haskey / getindex, never assigns), so index args that
# carry no unresolved loop variable — the common per-cell gather case, where the
# outer loop vars are already substituted to literals — can pass this single
# instance instead of allocating a fresh `Dict{String,Int}()` per index arg. In
# a stencil RHS that is a handful of freshly-GC'd dicts per neighbour gather per
# cell removed from the build-time allocation load.
const _EMPTY_IDX_ENV = Dict{String,Int}()

# An explicit empty shape (`[]`, a rank-0 declaration) is scalar, not an array;
# only a non-empty declared shape marks an array variable. `nothing` (no shape) is
# also scalar.
_is_array_shape(shape) = shape !== nothing && !isempty(shape)

# ---- Aggregate-node field accessors -------------------------------------------
# The `output_idx` / `ranges` fields of an aggregate/arrayop/makearray node are
# optional on the wire (`nothing` when absent), and `output_idx` may carry
# non-string entries that every consumer skips. These accessors are the single
# spelling of "the string output indices" and "a ranges table" (formerly
# duplicated across the build/resolve expansion and cell-discovery sites).
_output_idx_strings(op::OpExpr) = op.output_idx === nothing ? String[] :
    String[String(s) for s in op.output_idx if s isa AbstractString]
_ranges_dict(op::OpExpr) = op.ranges === nothing ? Dict{String,Any}() : op.ranges

# ---- Kahn-style dependency ordering (shared ready-set loop) ---------------------
# Order `names` so every name comes after the names it depends on. `deps(name)`
# returns the subset of `names` that must precede it (recomputed per pass — cheap
# at build time and keeps the callers' original shape); `on_cycle(done)` MUST
# throw (each call site owns its error code/message) and is called when a full
# pass over the remaining names makes no progress, i.e. the residue is cyclic.
# Within a pass the scan follows the iteration order of `names`, so the result
# is deterministic for a given input collection.
function _dependency_order(names, deps::F; on_cycle::G) where {F,G}
    order = String[]
    done = Set{String}()
    total = length(names)
    while length(order) < total
        progressed = false
        for n in names
            n in done && continue
            if all(d -> d in done, deps(n))
                push!(order, n)
                push!(done, n)
                progressed = true
            end
        end
        progressed || on_cycle(done)
    end
    return order
end

# ---- Const-array boundary policy (ess-gj4) ----
# A const array (Fornberg weights, mesh connectivity, a per-cell metric factor)
# may carry a per-dimension boundary policy so that a stencil gather at an
# out-of-range index resolves declaratively instead of erroring. This mirrors the
# state-variable gather, which honors grid periodicity (periodic-wrap) and applies
# a finite boundary policy at non-periodic edges. The covariant-FV connection
# terms gather metric factors at lat±1 / lon±1 offsets; on a lon-periodic metric
# those must WRAP, and at a non-periodic lat pole they must edge-extend — the
# zero-ghost convention is physically wrong for a metric.
#
# Per-dimension policy symbols:
#   :periodic — wrap the index into 1..N via mod1; correct for a periodic axis.
#   :clamp    — edge-extend (clamp to 1..N); the correct finite policy for a
#               metric/geometry factor at a non-periodic boundary.
#   :error    — throw E_TREEWALK_CONSTARRAY_OOB (default for any array WITHOUT a
#               declared policy, so genuine out-of-bounds bugs in connectivity /
#               stencil-weight factors are never masked).
const _CONST_BOUNDARY_KINDS = (:periodic, :clamp, :error)

# A const array tagged with a per-dimension boundary policy. It IS an
# `AbstractArray{Float64,N}` (forwards size/getindex to `data`), so it flows
# through the existing `const_arrays` threading transparently; only the gather's
# out-of-range handling branches on the wrapper via `_const_dim_boundary`.
struct BoundedConstArray{N} <: AbstractArray{Float64,N}
    data::Array{Float64,N}
    boundary::NTuple{N,Symbol}   # per-dim: :periodic | :clamp | :error
end
Base.size(a::BoundedConstArray) = size(a.data)
Base.IndexStyle(::Type{<:BoundedConstArray}) = IndexLinear()
Base.@propagate_inbounds Base.getindex(a::BoundedConstArray, i::Int) = a.data[i]

# Per-dimension boundary policy: declared dims for a BoundedConstArray, :error
# (throw on OOB) for any plain const array.
_const_dim_boundary(a::BoundedConstArray, d::Int) = a.boundary[d]
_const_dim_boundary(::AbstractArray, ::Int) = :error

# Resolve a possibly-out-of-range 1-based index `i` in dimension `d` (size `n`) of
# const array `name` per its boundary policy. In-range indices pass through.
function _resolve_const_index(arr::AbstractArray, name::AbstractString,
                              d::Int, i::Int, n::Int)
    (1 <= i <= n) && return i
    pol = _const_dim_boundary(arr, d)
    if n >= 1
        pol === :periodic && return mod1(i, n)
        pol === :clamp && return clamp(i, 1, n)
    end
    throw(TreeWalkError("E_TREEWALK_CONSTARRAY_OOB",
          "const array '$(name)' index $(i) out of range 1..$(n) in dim $(d)"))
end

# Wrap a const array with a declared per-dimension boundary policy. `boundary` is
# an iterable of per-dim policy symbols (or strings); its length must equal the
# array rank and each entry must be one of `_CONST_BOUNDARY_KINDS`.
function _wrap_bounded_const(arr::Array{Float64,N}, boundary, name::AbstractString) where {N}
    syms = Symbol[Symbol(b) for b in boundary]
    length(syms) == N ||
        throw(TreeWalkError("E_TREEWALK_CONSTARRAY_BOUNDARY_NDIM",
              "const array '$(name)' boundary has $(length(syms)) dims but array is $(N)D"))
    for s in syms
        s in _CONST_BOUNDARY_KINDS ||
            throw(TreeWalkError("E_TREEWALK_CONSTARRAY_BOUNDARY_KIND",
                  "const array '$(name)' boundary '$(s)' must be one of $(_CONST_BOUNDARY_KINDS)"))
    end
    return BoundedConstArray{N}(arr, NTuple{N,Symbol}(syms))
end

# ---- Whole-array declared-shape derivative lift -------------------------------
# A declared array-shaped state may be integrated by a WHOLE-ARRAY equation
# `D(SST) = <array-valued rhs>` (bare `VarExpr` LHS, no per-cell `index`). The
# tree-walk's derivative partition only recognises `D(scalar)`, `D(index(var,k))`,
# and `arrayop(D(index(var,…)))`, so lift the whole-array form into the `arrayop`
# per-cell form the machinery already consumes: loop over the state's declared
# shape index set(s), gathering every array operand of the rhs per cell (a genuine
# scalar / reduction leaf is left as-is by `_index_array_leaves`). This also lets
# `_discover_array_cells` enumerate the state's cells from the lifted `arrayop`
# ranges — a declared array state with a broadcast `ic` and no per-cell equation
# otherwise resolves to no cells.
function _lift_wholearray_deriv_equations(eqs::Vector{Equation},
        var_shapes::Dict{String,Vector{String}}, arrayvars::Set{String})
    # `D(x)` where the whole (un-indexed) `x` is a declared array variable.
    is_wholearray_D(lhs) = lhs isa OpExpr && (lhs::OpExpr).op == "D" &&
        length((lhs::OpExpr).args) == 1 &&
        (lhs::OpExpr).args[1] isa VarExpr &&
        ((lhs::OpExpr).args[1]::VarExpr).name in arrayvars
    any(eq -> is_wholearray_D(eq.lhs), eqs) || return eqs
    out = Equation[]
    for eq in eqs
        lhs = eq.lhs
        if is_wholearray_D(lhs)
            lhs = lhs::OpExpr
            vname = (lhs.args[1]::VarExpr).name
            shape = var_shapes[vname]
            loops = String["_lp$(i-1)_$(vname)" for i in 1:length(shape)]
            ranges = Dict{String,Any}()
            for i in eachindex(shape)
                ranges[loops[i]] = IndexSetRef(shape[i])
            end
            idx_args = Expr[VarExpr(vname)]
            for l in loops
                push!(idx_args, VarExpr(l))
            end
            lhs_body = OpExpr("D", Expr[OpExpr("index", idx_args)]; wrt=lhs.wrt)
            new_lhs = OpExpr("arrayop", Expr[];
                             output_idx=Any[l for l in loops], ranges=ranges,
                             expr_body=lhs_body)
            new_rhs = _index_array_leaves(eq.rhs, arrayvars, loops)
            push!(out, Equation(new_lhs, new_rhs; _comment=eq._comment))
        else
            push!(out, eq)
        end
    end
    return out
end

# Elementwise scalar ops whose ARRAY-shaped observed the WS4 fold may inline: the
# arithmetic / transcendental functions that broadcast per cell. An array observed
# whose top-level op is anything else — a producer (`makearray`/`arrayop`/
# `aggregate`), a `const` field, a geometry kernel (`intersect_polygon`, …), a
# gather/reshape (`index`, `reshape`, `transpose`, `concat`, `broadcast`), a
# value-invention op (`skolem`/`distinct`/`rank`), or a bare alias — is left to
# its own dedicated handler (const_arrays, `_array_inline_vars`, geometry setup,
# the bare-alias path). Restricting the fold to this allowlist keeps it provably
# regression-free: an elementwise array observed was previously REJECTED
# (`E_TREEWALK_UNSUPPORTED_SHAPE`), so no prior-passing build exercised one.
#
# INVARIANT: every op here MUST have a scalar arm in `_eval_node_op` (and hence a
# vectorized arm in `_eval_vec_op`) — the fold inlines the op into a state RHS,
# so a non-evaluable op would convert a clear build-time UNSUPPORTED_SHAPE error
# into a runtime UNSUPPORTED_OP after folding. The set therefore holds only the
# esm-spec §4.2 evaluable-core elementwise ops (plus the canonicalize-internal
# `neg`/`pow` aliases). Membership is declared per-op in src/op_registry.jl
# (flag `:ws4_foldable`) and pinned by op_registry_test.jl; the containment
# invariant above is pinned by tree_walk_op_table_test.jl.
const _WS4_FOLDABLE_ELEMENTWISE_OPS = _ops_with(:ws4_foldable)

# ---- Elementwise array-observed fold (WS4: readable PDE-leaf decomposition) ----
# Fold every ARRAY-shaped observed whose (already-discretization-lowered) defining
# equation RHS is an ELEMENTWISE expression — top-level op in
# `_WS4_FOLDABLE_ELEMENTWISE_OPS` — into the equations that read it, in dependency
# order, returning `(rewritten_equations, folded_names)`.
#
# This lets a library PDE leaf be authored with readable intermediate array fields
# (a level-set's `grad_safe = grad_mag + ε`, `U_n = (u·∇ψ)/grad_safe`,
# `S_n = R_0·(1+φ_W+φ_S)`) instead of one monolithic inlined `D(ψ,t)` RHS — the
# evaluator otherwise rejects such an observed as `E_TREEWALK_UNSUPPORTED_SHAPE`
# (only a producer-defined array observed inlines, via `_array_inline_vars`, and
# only a clip ring materializes). Array observeds defined by a bare array PRODUCER
# (the discretized `psi_x = D(ψ,x)`, `grad_mag = sqrt(D(ψ,x)²+D(ψ,y)²)`, both
# lowered to `makearray` by the mounted scheme) are LEFT UNTOUCHED — they define
# their own per-cell indexing and are inlined by the `_array_inline_vars` index
# beta-reduction downstream. So the fold pulls only the elementwise combinators
# into the state equation, whose whole-array lift then indexes the surviving
# producer refs per cell — reproducing the hand-inlined RHS the leaf used to carry.
#
# This is the model-level counterpart of `inline_elementwise_array_observeds`
# (shape_promotion.jl). Runs after observed-equation synthesis and before the
# whole-array derivative lift. Byte-identical (empty fold, same equations vector)
# for any model with no elementwise array observed.
function _fold_elementwise_array_observeds(equations::Vector{Equation}, model::Model)
    function is_array_obs(name)
        var = get(model.variables, name, nothing)
        return var !== nothing && var.type == ObservedVariable &&
               _is_array_shape(var.shape)
    end
    # A bare `name = rhs` algebraic definition per name (the D(state,t) equation
    # has an OpExpr lhs, so it is never a target — only its RHS is rewritten).
    defs = Dict{String,Expr}()
    for eq in equations
        lhs = eq.lhs
        if lhs isa VarExpr
            defs[lhs.name] = eq.rhs
        end
    end
    targets = Dict{String,Expr}()
    for (name, rhs) in defs
        if is_array_obs(name) && rhs isa OpExpr &&
           rhs.op in _WS4_FOLDABLE_ELEMENTWISE_OPS
            targets[name] = rhs
        end
    end
    isempty(targets) && return (equations, Set{String}())

    # Dependency order among the targets (the chain is feed-forward; a cycle is a
    # genuine authoring error). Only target→target edges are ordered; references
    # to producer observeds / params / state are leaves left in place.
    deps = Dict(name => intersect(free_variables(rhs), keys(targets))
                for (name, rhs) in targets)
    order = _dependency_order(collect(keys(targets)), name -> deps[name];
        on_cycle=_ -> throw(TreeWalkError("E_TREEWALK_CYCLIC_ARRAY_OBSERVED",
            "cyclic elementwise array-observed dependency among $(collect(keys(targets)))")))
    resolved = Dict{String,Expr}()
    for name in order
        resolved[name] = substitute(targets[name], resolved)
    end

    # Drop each folded definition and substitute its fully-resolved RHS into
    # every remaining reader.
    folded = Set{String}(keys(targets))
    out = Equation[]
    for eq in equations
        lhs = eq.lhs
        if lhs isa VarExpr && lhs.name in folded
            continue
        end
        push!(out, Equation(lhs, substitute(eq.rhs, resolved); _comment=eq._comment))
    end
    return (out, folded)
end
