# ========================================================================
# tree_walk/build_helpers.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Build-time helpers: the shared read-only _EMPTY_* sentinels, the
# const-array boundary policy (BoundedConstArray), the whole-array
# derivative lift, and the WS4 elementwise array-observed fold.
# ========================================================================

# ─────────────────────────────────────────────────────────────────────────────
# BUILD-TIME BENCHMARK COUNTERS (RFC out-of-line-expression-templates §12).
#
# The RFC's headline metric is "node-lowerings" — distinct objects `_compile`
# lowers — and "spine templates" — `_build_branch_template` calls. These two
# `Ref`s let a benchmark script (`scripts/bench-out-of-line.jl`) count them
# without a bespoke instrument. OFF by default: `_BENCH_ON[]` is a single Ref
# read per call on the COLD build path (never per RHS evaluation), so the effect
# on a normal build is negligible and on a normal solve is zero. A benchmark
# sets `_BENCH_ON[] = true`, zeroes the counters, builds, and reads them back.
const _BENCH_ON = Ref(false)
const _BENCH_COMPILE_CALLS = Ref(0)
const _BENCH_BRANCH_TEMPLATES = Ref(0)
# Compile-once tier (RFC §7.7 "compile references natively"): distinct template-
# body variants compiled — one per (use site, region class). The RFC's ~21.
const _BENCH_BODY_VARIANTS = Ref(0)
_bench_reset!() = (_BENCH_COMPILE_CALLS[] = 0; _BENCH_BRANCH_TEMPLATES[] = 0;
                   _BENCH_BODY_VARIANTS[] = 0; nothing)

# Lockstep site translation (compile-once template tier): a SHAPE-PRESERVING
# equation rewrite — join-gate or index-set-range resolution rebuilds a node's
# non-expression fields (`ranges`, `join_gates`) and every ancestor — detaches
# recorded expansion roots from the tree by identity. Walk the old and new trees
# in parallel (`child_exprs` yields the same expression slots in the same order
# when only non-expression fields changed) and map each recorded root to its
# rebuilt counterpart. Old keys are kept (harmless — they no longer appear in
# any tree); a subtree whose expression-slot count changed is skipped, so its
# sites degrade to the fused build — slower, never wrong.
# Identity-deduped on the OLD node (ESS-0hh): the shape-preserving rewrites are
# identity-memoized, so a shared old node maps to exactly ONE new node — a
# repeat (old, new) visit through another parent is redundant, and skipping it
# keeps the lockstep walk O(distinct nodes) on a shared DAG (unchanged
# subtrees already short-circuit via `old === new`).
function _translate_sites_lockstep!(sites::IdDict{OpExpr,OpExpr},
                                    old::ASTExpr, new::ASTExpr,
                                    seen::IdDict{OpExpr,Nothing}=IdDict{OpExpr,Nothing}())
    old === new && return nothing
    (old isa OpExpr && new isa OpExpr) || return nothing
    haskey(seen, old) && return nothing
    seen[old] = nothing
    ap = get(sites, old, nothing)
    ap === nothing || (sites[new] = ap)
    co = child_exprs(old)
    cn = child_exprs(new)
    length(co) == length(cn) || return nothing
    for i in eachindex(co)
        _translate_sites_lockstep!(sites, co[i], cn[i], seen)
    end
    return nothing
end
function _translate_equation_sites!(sites::Union{Nothing,IdDict{OpExpr,OpExpr}},
                                    old_eqs::Vector{Equation}, new_eqs::Vector{Equation})
    (sites === nothing || old_eqs === new_eqs) && return nothing
    length(old_eqs) == length(new_eqs) || return nothing
    for i in eachindex(old_eqs)
        _translate_sites_lockstep!(sites, old_eqs[i].lhs, new_eqs[i].lhs)
        _translate_sites_lockstep!(sites, old_eqs[i].rhs, new_eqs[i].rhs)
    end
    return nothing
end

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

# ---- `broadcast` lowering (esm-spec §4.3.4) -----------------------------------
# `{"op":"broadcast","fn":F,"args":[…]}` applies the SCALAR operator `F`
# element-wise to its operands. That is exactly what a bare `{"op":F,"args":[…]}`
# node already means on this path — the leaf-indexing rewrites gather every array
# operand per cell (name-aligned, see `_AxisAlign`) and leave genuine scalars
# alone — so `broadcast` is LOWERED to its `fn` op at the entry to the build and
# never reaches the evaluator as a distinct node. Lowering (rather than teaching
# every ladder a `broadcast` arm) is what makes the spec's identity
# `broadcast(fn=F, [x]) ≡ F(x)` true BY CONSTRUCTION: one node kind, one set of
# arms, one CSE/fold/stencil classification.
#
# The `fn` contract is checked here (`_broadcast_fn_problem`, op_registry.jl —
# the same predicate `validate()` reports as `invalid_broadcast_fn`), so a bogus
# `fn` is a BUILD error even for a caller that never ran `validate()`.
# `reshape`/`transpose`/`concat` are NOT lowered — they are genuine shape ops
# with no scalar-operator spelling, and keep their `E_TREEWALK_UNSUPPORTED_OP`
# rejection in `_compile_op`.
#
# DAG-SAFE, WITHOUT TAXING THE COMMON CASE (ESS-0hh).
# `map_children` already declines to REBUILD an unchanged node, which keeps a
# shared DAG shared on the way out — but the WALK itself was per-PATH, so a node
# reachable by 2^d paths was re-entered 2^d times even when nothing changed and
# nothing was rebuilt. On dag_walk_memo_test.jl's depth-32 chain that was 457 s,
# and 6245 of 6255 profiler samples at depth 28.
#
# The obvious fix — memoize every node on identity — is sound (the rewrite is a
# pure, context-free function of the node) but it is NOT free: an `IdDict` probe
# plus insert per node MEASURED 2.6× the un-memoized walk on trees with no
# sharing (55 → 142 ns/node), and an ordinary model's equations are exactly that
# shape. Paying a constant-factor tax on every build to defend against a
# pathological one is the wrong trade.
#
# So: walk UN-MEMOIZED under a visit BUDGET, and only if the budget is exhausted
# — which only a shared DAG with an exponential path count can do — redo the walk
# memoized. Both paths compute the same function, so which one ran is
# unobservable except in time and in SHARING: the memoized path maps a node
# reached twice to the same output object rather than two equal copies, which is
# the DAG-preserving direction and already what the unchanged case did.
#
# MEASURED. Unshared trees: back to the original walk cost (the residue is one
# `Ref` decrement per node), against 2.6× for the unconditional memo. The 64×64
# advection build of tree_walk_test.jl — 4096 equations, ~40k nodes, no sharing —
# runs 0.54 s against its 5.0 s budget. Doubling DAGs: FLAT ~0.3 s for the whole
# depth-8-through-40 build, of which ~0.25 s is the budget burned before the
# switch. That burn is a one-time CONSTANT, not a scaling term, and it buys the
# common case paying nothing. Tripping the budget is not an error condition — a
# legitimately huge single expression simply takes the memoized path, which is
# the linear one.
const _LOWER_BCAST_BUDGET = 1 << 21     # ~2.1M node visits, ~0.1 s un-memoized

struct _BroadcastBudgetExceeded <: Exception end

function _lower_broadcast(expr::ASTExpr)::ASTExpr
    expr isa OpExpr || return expr
    try
        return _lower_broadcast_budgeted(expr, Ref(_LOWER_BCAST_BUDGET))
    catch err
        err isa _BroadcastBudgetExceeded || rethrow()
    end
    return _lower_broadcast_memoized(expr, IdDict{OpExpr,ASTExpr}())
end

# The lowering itself, shared by both walks: `e` is the node with its children
# already rewritten.
@inline function _lower_broadcast_node(e::ASTExpr)::ASTExpr
    (e isa OpExpr && (e::OpExpr).op == "broadcast") || return e
    b = e::OpExpr
    prob = _broadcast_fn_problem(b.fn, length(b.args))
    prob === nothing || throw(TreeWalkError("E_TREEWALK_BROADCAST_FN", prob.message))
    # Only `op`/`fn`/`args` are meaningful on a broadcast node; the lowered node
    # is the plain scalar-op spelling of the same expression.
    return OpExpr(String(b.fn), copy(b.args))
end

function _lower_broadcast_budgeted(expr::ASTExpr, fuel::Ref{Int})::ASTExpr
    expr isa OpExpr || return expr
    (fuel[] -= 1) > 0 || throw(_BroadcastBudgetExceeded())
    return _lower_broadcast_node(
        map_children(x -> _lower_broadcast_budgeted(x, fuel), expr::OpExpr))
end

function _lower_broadcast_memoized(expr::ASTExpr,
                                   memo::IdDict{OpExpr,ASTExpr})::ASTExpr
    expr isa OpExpr || return expr
    key = expr::OpExpr
    hit = get(memo, key, nothing)
    hit === nothing || return hit
    out = _lower_broadcast_node(
        map_children(x -> _lower_broadcast_memoized(x, memo), key))
    memo[key] = out
    return out
end

# Lower every `broadcast` node in a Model's expression-bearing fields (variable
# `expression`s, equations, initialization equations, guesses) and, recursively,
# in its Model subsystems. Returns the SAME model object when nothing changed.
# Shaped after `_intern_model` (src/intern.jl).
function _lower_broadcast_model(model::Model)::Model
    vars = model.variables
    nvars = vars
    for (name, v) in vars
        v.expression === nothing && continue
        ne = _lower_broadcast(v.expression)
        if ne !== v.expression
            nvars === vars && (nvars = copy(vars))
            nvars[name] = reconstruct(v; expression=ne)
        end
    end
    lower_eqs(eqs) = begin
        out = eqs
        for (i, eq) in enumerate(eqs)
            nl = _lower_broadcast(eq.lhs)
            nr = _lower_broadcast(eq.rhs)
            if nl !== eq.lhs || nr !== eq.rhs
                out === eqs && (out = copy(eqs))
                out[i] = Equation(nl, nr; _comment=eq._comment)
            end
        end
        out
    end
    eqs = lower_eqs(model.equations)
    ieqs = lower_eqs(model.initialization_equations)
    guesses = model.guesses
    ng = guesses
    for (k, g) in guesses
        g isa ASTExpr || continue
        r = _lower_broadcast(g)
        if r !== g
            ng === guesses && (ng = copy(guesses))
            ng[k] = r
        end
    end
    subs = model.subsystems
    nsubs = subs
    for (k, s) in subs
        s isa Model || continue
        ns = _lower_broadcast_model(s)
        if ns !== s
            nsubs === subs && (nsubs = copy(subs))
            nsubs[k] = ns
        end
    end
    (nvars === vars && eqs === model.equations &&
     ieqs === model.initialization_equations && ng === guesses &&
     nsubs === subs) && return model
    return Model(nvars, eqs, model.discrete_events, model.continuous_events,
                 nsubs; tolerance=model.tolerance, tests=model.tests,
                 initialization_equations=ieqs, guesses=ng,
                 system_kind=model.system_kind)
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
            # A3 (cross-equation variant memo): UNIFORM loop names (`_lp0`,
            # `_lp1`, …) rather than the historical state-suffixed
            # `_lp0_$(vname)`, so two lifted equations over the same shape index
            # the same (interned) rhs producers with IDENTICAL index
            # expressions — which is what lets the per-build `_XEqStore` share
            # one compiled template body across D(m,t)/D(mq,t)/D(dev,t).
            # Pure alpha-renaming: the generated names are engine-internal loop
            # indices, never part of a cell key, branch key, or emitted value.
            # Collision guard: if the rhs actually uses an `_lpN` name as a
            # variable (or the state itself is so named), fall back to the
            # historical suffixed names for THIS equation — the pre-A3 scheme,
            # whose own collision exposure was the same one suffix over.
            loops = String["_lp$(i-1)" for i in 1:length(shape)]
            clash = vname in loops
            clash || foreach_subexpr_once(eq.rhs) do x
                clash || (x isa VarExpr && x.name in loops && (clash = true))
                nothing
            end
            if clash
                loops = String["_lp$(i-1)_$(vname)" for i in 1:length(shape)]
            end
            ranges = Dict{String,Any}()
            for i in eachindex(shape)
                ranges[loops[i]] = IndexSetRef(shape[i])
            end
            idx_args = ASTExpr[VarExpr(vname)]
            for l in loops
                push!(idx_args, VarExpr(l))
            end
            lhs_body = OpExpr("D", ASTExpr[OpExpr("index", idx_args)]; wrt=lhs.wrt)
            new_lhs = OpExpr("arrayop", ASTExpr[];
                             output_idx=Any[l for l in loops], ranges=ranges,
                             expr_body=lhs_body)
            # Name-based operand alignment (esm-spec §4.3.4): each array-variable
            # leaf is gathered at the loops bound to ITS OWN declared index sets,
            # so a lower-rank operand broadcasts along the missing axes and a
            # name-permuted operand transposes instead of being reinterpreted.
            # Anonymous-shape nodes (producers, literals) stay positional.
            new_rhs = _index_array_leaves(eq.rhs, arrayvars, loops;
                                          align = _AxisAlign(shape, var_shapes))
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

# Identity-memoized `substitute` with FULL field coverage: shared input nodes
# map to ONE shared output node, so substituting into a structurally-shared
# DAG yields a DAG of the same shape instead of re-inflating it into an
# exponentially larger TREE (plain `substitute` rebuilds every changed
# ancestor once per PATH — on a doubling chain the output itself blows up in
# MEMORY, not just time; ESS-0hh). Results are identical to `substitute` up
# to sharing.
#
# NOT `_sub_preserving` (tree_walk/helpers.jl): that helper substitutes only
# through args / expr_body / values / filter / ranges — the fields its
# per-cell arrayop callers need — while the fold below rewrites arbitrary
# READER equations, which may reference a folded name inside an integral
# bound, a table-lookup axis, a value-invention `key`, or a `bindings` value.
# Routing through the `map_children` generated full field walk covers every
# expression-bearing field exactly as `substitute` does (and inherits its
# identity-preserving no-change fast path). Fresh memo per top-level call:
# `bindings` is fixed within one call, so input identity → output is sound.
# (Spelled `IdDict{OpExpr,ASTExpr}`, not the `_SubMemo` alias — helpers.jl,
# which defines the alias, is included after this file.)
function _substitute_shared(e::ASTExpr, bindings::Dict{String,ASTExpr},
                            memo::IdDict{OpExpr,ASTExpr}=IdDict{OpExpr,ASTExpr}())
    e isa OpExpr || return substitute(e, bindings)
    cached = get(memo, e, nothing)
    cached === nothing || return cached
    r = map_children(x -> _substitute_shared(x, bindings, memo), e)
    memo[e] = r
    return r
end

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
    defs = Dict{String,ASTExpr}()
    for eq in equations
        lhs = eq.lhs
        if lhs isa VarExpr
            defs[lhs.name] = eq.rhs
        end
    end
    targets = Dict{String,ASTExpr}()
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
    # `_substitute_shared`, not plain `substitute`: a raw target body can be a
    # DAG (template lowering shares subtrees by reference), and the per-path
    # rebuild would materialize it as an exponentially large tree.
    resolved = Dict{String,ASTExpr}()
    for name in order
        resolved[name] = _substitute_shared(targets[name], resolved)
    end

    # Drop each folded definition and substitute its fully-resolved RHS into
    # every remaining reader (sharing-preserving, as above).
    folded = Set{String}(keys(targets))
    out = Equation[]
    for eq in equations
        lhs = eq.lhs
        if lhs isa VarExpr && lhs.name in folded
            continue
        end
        push!(out, Equation(lhs, _substitute_shared(eq.rhs, resolved);
                            _comment=eq._comment))
    end
    return (out, folded)
end
