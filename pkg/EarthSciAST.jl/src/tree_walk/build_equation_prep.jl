# tree_walk/build_equation_prep.jl — equation preparation before classification: `broadcast` lowering,
# indexed observed left-hand sides, the whole-array derivative lift and the
# elementwise array-observed fold.

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
# `reshape`/`transpose`/`concat` are NOT lowered here — they are genuine shape
# ops with no scalar-operator spelling. Under an `index` they become gathers of
# their operand (`_index_through_shape_op`, shape_ops.jl); a bare one still meets
# its `unevaluable_operator` rejection in `_compile_op`.
#
# DAG-SAFE, WITHOUT TAXING THE COMMON CASE.
# `map_children` already declines to REBUILD an unchanged node, which keeps a
# shared DAG shared on the way out — but the WALK itself was per-PATH, so a node
# reachable by 2^d paths was re-entered 2^d times even when nothing changed and
# nothing was rebuilt. dag_walk_memo_test.jl's depth-32 chain pins that case.
#
# The obvious fix — memoize every node on identity — is sound (the rewrite is a
# pure, context-free function of the node) but it is NOT free: an `IdDict` probe
# plus insert per node costs several times the un-memoized walk on trees with no
# sharing, and an ordinary model's equations are exactly that shape. Paying a
# constant-factor tax on every build to defend against a pathological one is the
# wrong trade.
#
# So: walk UN-MEMOIZED under a visit BUDGET, and only if the budget is exhausted
# — which only a shared DAG with an exponential path count can do — redo the walk
# memoized. Both paths compute the same function, so which one ran is
# unobservable except in time and in SHARING: the memoized path maps a node
# reached twice to the same output object rather than two equal copies, which is
# the DAG-preserving direction and already what the unchanged case did.
#
# So an unshared tree pays only one `Ref` decrement per node, and a doubling DAG
# pays the budget once before switching to the linear memoized walk. That burn is
# a one-time CONSTANT, not a scaling term. Tripping the budget is not an error
# condition — a legitimately huge single expression simply takes the memoized
# path, which is the linear one.
const _LOWER_BCAST_BUDGET = 1 << 21     # ~2.1M node visits, ~0.1 s un-memoized

struct _BroadcastBudgetExceeded <: EarthSciASTError end

function _lower_broadcast(expr::ASTExpr)::ASTExpr
    expr isa OpExpr || return expr
    try
        return _lower_broadcast_budgeted(expr, Ref(_LOWER_BCAST_BUDGET))
    catch err
        err isa _BroadcastBudgetExceeded || rethrow()
    end
    return _lower_broadcast_memoized(expr, IdDict{OpExpr, ASTExpr}())
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
        map_children(x -> _lower_broadcast_budgeted(x, fuel), expr::OpExpr)
    )
end

function _lower_broadcast_memoized(
        expr::ASTExpr,
        memo::IdDict{OpExpr, ASTExpr}
    )::ASTExpr
    expr isa OpExpr || return expr
    key = expr::OpExpr
    hit = get(memo, key, nothing)
    hit === nothing || return hit
    out = _lower_broadcast_node(
        map_children(x -> _lower_broadcast_memoized(x, memo), key)
    )
    memo[key] = out
    return out
end

# Lower every `broadcast` node at every expression site of a Model and of its
# Model subsystems.
_lower_broadcast_model(model::Model)::Model = map_expressions(_lower_broadcast, model)

# ---- Indexed observed-LHS normalization (esm-spec §6.3.1) ---------------------
# esm-spec §6.3.1 admits TWO LHS spellings for the equation that DEFINES an
# unknown: bare (`y ~ f(…)`) and indexed (`y[i] ~ f(…)`, "which defines the whole
# array `y`"). Both are normative and neither is restricted by rank — the spec is
# explicit that the defining form is read through the LHS's BASE NAME, so "an
# arrayed definition is observed exactly as its scalar counterpart is".
#
# Every downstream owner-bucket collector in this build, though, tests the
# SYNTACTIC `eq.lhs isa VarExpr` — the WS4 elementwise fold, the promoted-faq
# inline set (`_collect_array_inline_vars`), the bare-alias array registration.
# An ARRAY-shaped observed written with the indexed spelling therefore landed in
# no bucket at all and fell through to `_partition_variables` as
# `E_TREEWALK_UNSUPPORTED_SHAPE: <name>` — a loud refusal of a document Rust and
# Python both run. The scalar case never showed it, because a scalar
# observed has no `index` shell to write.
#
# Fix the SPELLING once, here, upstream of every classifier, rather than teaching
# each bucket a second LHS form (and rather than widening the geometry-ring gate,
# which would let the shape through with no owner). Recognised form:
#
#     aggregate{k… over R…}(index(V, k…))  ~  rhs
#
# where the shell's `output_idx` is exactly the identity gather's subscripts in
# order, its `ranges` bind exactly those symbols, it carries no contraction or
# gating clause (`filter` / `join` / `key` / `distinct`), and `V` is an
# OBSERVED unknown of this model whose declared rank matches, or whose shape is
# undeclared (the frame then gives it). A
# derivative LHS (`aggregate{k}(D(index(u,k)))`) has a `D` body, not an `index`
# body, so the ODE partition is untouched; so is an ODE state, an algebraic
# unknown, and any genuine expression LHS.
#
# The rewrite moves the frame from the LHS onto the RHS:
#
#   * the RHS mentions NO frame symbol — it is already the whole array
#     (`aggregate{k}(2*u[k])`), so the LHS shell simply drops:  `V ~ rhs`;
#   * the RHS mentions one — it is a PER-CELL body (`2*u[k]`), so it is wrapped
#     in the LHS's own frame:  `V ~ aggregate{k… over R…}(rhs)`.
#
# Both spell the same array the indexed equation defined, in the bare form the
# rest of the build already handles. `free_variables` does the binder
# subtraction, so an RHS aggregate that binds `k` itself counts as closed.
# Byte-identical (the ORIGINAL equations vector, by identity) for any model with
# no indexed observed LHS.
#
# The BARE-INDEX spelling `index(V, k…) ~ rhs` (no shell) binds none of its
# subscripts, so its range has to come from the RHS: it runs exactly when the RHS
# is a `faq` whose `output_idx` names the subscripts in order, and it then
# normalizes to `V ~ rhs` (CONFORMANCE_SPEC §5.36.2). Any other bare-index
# definition of an observed is refused with `indexed_definition_unsupported_form`
# rather than left to fall through to a shape error. A value-invention output
# (`vi_vars`) is materialized by its own engine and filtered out of the ODE
# later, so its definitions are left exactly as authored.
function _normalize_indexed_observed_lhs(
        eqs::Vector{Equation}, model::Model;
        vi_vars::Set{String} = Set{String}()
    )
    observed_here = Set{String}(observed_unknowns(model))
    isempty(observed_here) && return eqs
    out = nothing
    for (i, eq) in enumerate(eqs)
        rewritten = if eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "index"
            _rewrite_bare_index_observed_lhs(eq, model, observed_here, vi_vars)
        else
            _rewrite_indexed_observed_lhs(eq, model, observed_here)
        end
        if rewritten === nothing
            out === nothing || push!(out, eq)
        else
            out === nothing && (out = Equation[eqs[j] for j in 1:(i - 1)])
            push!(out, rewritten)
        end
    end
    return out === nothing ? eqs : out
end

# One equation of the above: the rewritten `V ~ …` equation, or `nothing` when
# this LHS is not the indexed-observed spelling (leave it exactly as authored).
function _rewrite_indexed_observed_lhs(
        eq::Equation, model::Model,
        observed_here::Set{String}
    )
    lhs = eq.lhs
    lhs isa OpExpr || return nothing
    shell = lhs::OpExpr
    # `faq` is the internal twin of the public `aggregate` spelling; both are
    # addressing shells to `_lhs_unwrap`, so both normalize here.
    (shell.op == "faq") || return nothing
    # A shell that CONTRACTS or GATES is not pure addressing — it computes.
    (
        shell.filter === nothing && shell.join === nothing && shell.key === nothing &&
            shell.distinct !== true
    ) || return nothing
    body = shell.expr_body
    body isa OpExpr || return nothing
    gather = body::OpExpr
    gather.op == "index" || return nothing
    isempty(gather.args) && return nothing
    head = gather.args[1]
    head isa VarExpr || return nothing
    name = (head::VarExpr).name
    name in observed_here || return nothing
    var = get(model.variables, name, nothing)
    var === nothing && return nothing
    # An observed whose `shape` was never declared takes its rank and extent
    # from this frame (it is anonymous, esm-spec §4.3.4); a declared shape must
    # agree in rank.
    declared = _is_array_shape(var.shape)
    idx = shell.output_idx
    idx === nothing && return nothing
    syms = String[]
    for x in idx
        x isa AbstractString || return nothing      # a literal singleton axis
        push!(syms, String(x))
    end
    isempty(syms) && return nothing                 # a SCALAR reduction, not a frame
    (!declared || length(syms) == length(var.shape)) || return nothing
    # The gather must be the IDENTITY on the frame: `index(V, k…)`, same symbols,
    # same order. `index(V, k+1)` or a permutation writes something else.
    length(gather.args) == length(syms) + 1 || return nothing
    for (a, s) in zip(view(gather.args, 2:length(gather.args)), syms)
        (a isa VarExpr && (a::VarExpr).name == s) || return nothing
    end
    ranges = shell.ranges
    ranges === nothing && return nothing
    length(ranges) == length(syms) || return nothing
    all(s -> haskey(ranges, s), syms) || return nothing

    rhs = eq.rhs
    rhs_free = free_variables(rhs)
    if _anyof(s -> s in rhs_free, syms)
        rhs = OpExpr(
            "faq", ASTExpr[];
            output_idx = Any[s for s in syms],
            ranges = Dict{String, Any}(s => ranges[s] for s in syms),
            expr_body = rhs
        )
    end
    return Equation(VarExpr(name), rhs; _comment = eq._comment)
end

# The variable a bare-index LHS writes, read through nested `index` wrappers the
# way Python's `_vi_lhs_base` and Rust's `base_variable` read it, so all three
# bindings agree on WHICH definition a nested gather is (and refuse it alike).
function _bare_index_head_name(e)
    e isa VarExpr && return (e::VarExpr).name
    if e isa OpExpr && (e::OpExpr).op == "index" && !isempty((e::OpExpr).args)
        return _bare_index_head_name((e::OpExpr).args[1])
    end
    return nothing
end

# One bare-index equation of `_normalize_indexed_observed_lhs`: `V ~ rhs` when it
# is the runnable form, `nothing` when `V` is not an observed this pass owns (an
# ODE state, an algebraic unknown, a value-invention output), and a refusal
# otherwise. The gather must be the DIRECT one, `index(V, k…)`: `index(index(V,
# j), k)` addresses a cell of a cell, not the whole of `V`. Flatten namespaces a
# free LHS subscript (`k` becomes `Model.k`) but not a `faq` binder, so a
# subscript matches its binder in either spelling.
function _rewrite_bare_index_observed_lhs(
        eq::Equation, model::Model,
        observed_here::Set{String}, vi_vars::Set{String}
    )
    gather = eq.lhs::OpExpr
    isempty(gather.args) && return nothing
    head = gather.args[1]
    name = _bare_index_head_name(head)
    name === nothing && return nothing
    (name in observed_here && !(name in vi_vars)) || return nothing
    subs = view(gather.args, 2:length(gather.args))
    prefix = (dot = findlast('.', name)) === nothing ? "" : name[1:dot]
    rhs = eq.rhs
    frame = rhs isa OpExpr && (rhs::OpExpr).op == "faq" ? (rhs::OpExpr).output_idx : nothing
    # A plain-symbol subscript at any level of the gather that neither the
    # right-hand frame binds nor a variable names is a free index symbol: the
    # document is invalid (esm-spec §6.3.1, `unbound_index_symbol`). Flatten
    # namespaces a free LHS symbol (`k` becomes `Model.k`) but not a binder.
    binders = Set{String}()
    frame === nothing || for b in frame
        b isa AbstractString || continue
        push!(binders, String(b)); push!(binders, prefix * String(b))
    end
    g = gather
    while true
        for s in view(g.args, 2:length(g.args))
            s isa VarExpr || continue
            sn = (s::VarExpr).name
            (sn in binders || haskey(model.variables, sn)) && continue
            local_sym = startswith(sn, prefix) ? sn[(length(prefix) + 1):end] : sn
            throw(
                TreeWalkError(
                    ERROR_CODES.UNBOUND_INDEX_SYMBOL,
                    "'$name' is defined by a left-hand side that subscripts with " *
                        "'$local_sym', which no faq binds (esm-spec §6.3.1)"
                )
            )
        end
        h = g.args[1]
        (h isa OpExpr && (h::OpExpr).op == "index" && !isempty((h::OpExpr).args)) || break
        g = h::OpExpr
    end
    binds = head isa VarExpr &&
        frame !== nothing && !isempty(subs) && length(frame) == length(subs) &&
        all(zip(subs, frame)) do (s, b)
        s isa VarExpr && b isa AbstractString &&
            ((s::VarExpr).name == b || (s::VarExpr).name == prefix * b)
    end
    var = get(model.variables, name, nothing)
    rank_agrees = var === nothing || !_is_array_shape(var.shape) ||
        length(var.shape) == length(subs)
    (binds && rank_agrees) ||
        throw(
        TreeWalkError(
            ERROR_CODES.INDEXED_DEFINITION_UNSUPPORTED_FORM,
            "'$name' is defined by a bare-index LHS that is not runnable; the RHS " *
                "must be a faq whose output_idx names the LHS subscripts in order " *
                "(esm-spec §6.3.1)"
        )
    )
    return Equation(VarExpr(name), rhs; _comment = eq._comment)
end

# ---- Whole-array declared-shape derivative lift -------------------------------
# A declared array-shaped state may be integrated by a WHOLE-ARRAY equation
# `D(SST) = <array-valued rhs>` (bare `VarExpr` LHS, no per-cell `index`). The
# tree-walk's derivative partition only recognises `D(scalar)`, `D(index(var,k))`,
# and `faq(D(index(var,…)))`, so lift the whole-array form into the `faq`
# per-cell form the machinery already consumes: loop over the state's declared
# shape index set(s), gathering every array operand of the rhs per cell (a genuine
# scalar / reduction leaf is left as-is by `_index_array_leaves`). This also lets
# `_discover_array_cells` enumerate the state's cells from the lifted `faq`
# ranges — a declared array state with a broadcast `ic` and no per-cell equation
# otherwise resolves to no cells.
function _lift_wholearray_deriv_equations(
        eqs::Vector{Equation},
        var_shapes::Dict{String, Vector{String}}, arrayvars::Set{String}
    )
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
            # Uniform loop names (`_lp0`, `_lp1`, …), so two lifted equations
            # over the same shape index the same (interned) producers with
            # identical index expressions and the per-build `_XEqStore` shares
            # one compiled template body across them. The names are internal
            # loop indices, never part of a cell key, branch key or value. If
            # the rhs uses an `_lpN` name as a variable (or the state is so
            # named), this equation takes state-suffixed names instead.
            loops = String["_lp$(i - 1)" for i in 1:length(shape)]
            clash = vname in loops
            clash || foreach_subexpr_once(eq.rhs) do x
                clash || (x isa VarExpr && x.name in loops && (clash = true))
                nothing
            end
            if clash
                loops = String["_lp$(i - 1)_$(vname)" for i in 1:length(shape)]
            end
            ranges = Dict{String, Any}()
            for i in eachindex(shape)
                ranges[loops[i]] = IndexSetRef(shape[i])
            end
            idx_args = ASTExpr[VarExpr(vname)]
            for l in loops
                push!(idx_args, VarExpr(l))
            end
            lhs_body = OpExpr("D", ASTExpr[OpExpr("index", idx_args)]; wrt = lhs.wrt)
            new_lhs = OpExpr(
                "faq", ASTExpr[];
                output_idx = Any[l for l in loops], ranges = ranges,
                expr_body = lhs_body
            )
            # Name-based operand alignment (esm-spec §4.3.4): each array-variable
            # leaf is gathered at the loops bound to ITS OWN declared index sets,
            # so a lower-rank operand broadcasts along the missing axes and a
            # name-permuted operand transposes instead of being reinterpreted.
            # Anonymous-shape nodes (producers, literals) stay positional.
            new_rhs = _index_array_leaves(
                eq.rhs, arrayvars, loops;
                align = _AxisAlign(shape, var_shapes)
            )
            push!(out, Equation(new_lhs, new_rhs; _comment = eq._comment))
        else
            push!(out, eq)
        end
    end
    return out
end

# Elementwise scalar ops whose ARRAY-shaped observed the WS4 fold may inline: the
# arithmetic / transcendental functions that broadcast per cell. An array observed
# whose top-level op is anything else — a producer (`makearray`/`faq`/
# `faq`), a `const` field, a gather/reshape (`index`, `reshape`, `transpose`,
# `concat`, `broadcast`), a value-invention op (`distinct`), or a bare alias — is left to
# its own dedicated handler (const_arrays, `_array_inline_vars`, geometry setup,
# the bare-alias path).
#
# INVARIANT: every op here MUST have a scalar arm in `_eval_node_op` (and hence a
# matching arm in `_eval_acc_op`) — the fold inlines the op into a state RHS,
# so a non-evaluable op would convert a clear build-time UNSUPPORTED_SHAPE error
# into a runtime UNSUPPORTED_OP after folding. The set therefore holds only the
# esm-spec §4.2 evaluable-core elementwise ops (plus the deprecated `neg`/`pow`
# word spellings, which an AST built in code may still carry). Membership is declared per-op in src/op_registry.jl
# (flag `:ws4_foldable`) and pinned by op_registry_test.jl; the containment
# invariant above is pinned by tree_walk_op_table_test.jl.
const _WS4_FOLDABLE_ELEMENTWISE_OPS = _ops_with(:ws4_foldable)

# Identity-memoized `substitute` with FULL field coverage: shared input nodes
# map to ONE shared output node, so substituting into a structurally-shared
# DAG yields a DAG of the same shape instead of re-inflating it into an
# exponentially larger TREE (plain `substitute` rebuilds every changed
# ancestor once per PATH — on a doubling chain the output itself blows up in
# MEMORY, not just time). Results are identical to `substitute` up
# to sharing.
#
# NOT `_sub_preserving` (expression.jl): that helper substitutes only
# through args / expr_body / values / filter / ranges — the fields its
# per-cell faq callers need — while the fold below rewrites arbitrary
# READER equations, which may reference a folded name inside an integral
# bound, a value-invention `key`, or a `bindings` value.
# Routing through the `map_children` generated full field walk covers every
# expression-bearing field exactly as `substitute` does (and inherits its
# identity-preserving no-change fast path). Fresh memo per top-level call:
# `bindings` is fixed within one call, so input identity → output is sound.
function _substitute_shared(
        e::ASTExpr, bindings::Dict{String, ASTExpr},
        memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}()
    )
    e isa OpExpr || return substitute(e, bindings)
    cached = get(memo, e, nothing)
    cached === nothing || return cached
    r = map_children(x -> _substitute_shared(x, bindings, memo), e)
    memo[e] = r
    return r
end

# ---- Index push-down: which operand of an `index` gather is ARRAY-valued? ----
# Shared predicate of the two `index(<elementwise op>, k…)` push-down branches —
# `_resolve_indices_op` (resolve.jl) and `_stencilize_index` (stencil.jl). Both
# distribute a gather over an elementwise combination,
#
#     index(op(a, b, …), k…)  ->  op(index(a, k…), index(b, k…), …)
#
# and both need to know WHICH operands to wrap: an array-valued one is gathered,
# a genuinely scalar one (a literal, a scalar parameter) broadcasts and must be
# left alone. `is_array_leaf(name) -> Bool` is the caller's own array-VARIABLE
# test (an array state slot, a forcing buffer, a const array), which is the only
# part that differs between the two sites.
#
# An expression is array-valued here when it is
#
#   * an array PRODUCER node — a `makearray`, or a `faq` that
#     keeps at least one symbolic output index (a SCALAR reduction, whose
#     `output_idx` is empty, produces a scalar and must NOT be gathered); or
#   * a variable leaf the caller recognizes as an array; or
#   * an ELEMENTWISE combination (`_is_scalar_op`) that is array-valued by this
#     same rule at any depth.
#
# The last clause matters: testing only the immediate operands would miss `index(1 + cos(pi*zc), j)` — the shape an elementwise-defined
# array observed (`f = 1 + cos(pi*zc)`) takes once
# `_fold_elementwise_array_observeds` inlines it into a reader that gathers it,
# `index(f, j)` — matched nothing: `1` is a literal and `cos(pi*zc)` is neither a
# producer node nor a variable, so no operand was wrapped, the gather was
# dropped, and the array leaf `zc` survived bare into `_compile` as
# `E_TREEWALK_UNBOUND_VARIABLE: zc`. Recursing through elementwise
# ops sees `zc` under the `cos`, wraps `cos(pi*zc)` whole, and the re-resolution
# of `index(cos(pi*zc), j)` pushes the gather down the same way until it lands on
# the leaf as `1 + cos(pi*index(zc, j))`. Distribution is exact for an
# elementwise op, so this is the same value the explicit gather spelling would
# have produced.
#
# IDENTITY-MEMOIZED over `OpExpr`: the folded body is a
# structurally-shared DAG, and `any` over a shared subtree would otherwise be
# re-walked once per path. One memo per push-down decision — `is_array_leaf` is
# fixed within it.
# A const-array registry entry that holds exactly ONE element is a SCALAR field,
# not a gatherable array: `_resolve_indices(::VarExpr)` const-folds a bare
# reference to it to its literal value (the RFC pure-io-data-loaders §4.3 0-D
# loader field). It must therefore stay OUT of an index push-down's leaf test —
# wrapping it would gather a 1-element array at the enclosing loop's subscript
# and read out of range for every cell but the first. A size-1 INDEX SET is the
# same object and the same answer: its only legal subscript is 1, which is what
# the const-fold already returns.
_is_scalar_const_field(v) = v isa AbstractArray && length(v) == 1

function _index_pushdown_arrayish(
        e::ASTExpr, is_array_leaf,
        memo::IdDict{OpExpr, Bool} = IdDict{OpExpr, Bool}()
    )::Bool
    if e isa VarExpr
        return is_array_leaf((e::VarExpr).name)
    elseif e isa OpExpr
        o = e::OpExpr
        cached = get(memo, o, nothing)
        cached === nothing || return cached::Bool
        r = _is_array_producer(o) || o.op in _SHAPE_REMAP_OPS ||
            (
            _is_scalar_op(o.op) &&
                _anyof(a -> _index_pushdown_arrayish(a, is_array_leaf, memo), o.args)
        )
        memo[o] = r
        return r
    end
    return false
end

# The names a template reference in `equations` binds by name (a binding that
# is a bare variable), at any depth.
function _names_bound_to_references(equations::Vector{Equation})
    out = Set{String}()
    seen = IdDict{OpExpr, Nothing}()
    function walk(e)
        e isa OpExpr || return
        haskey(seen, e) && return
        seen[e] = nothing
        if _tpl_is_call(e) && e.bindings !== nothing
            for (_, v) in e.bindings
                v isa VarExpr && push!(out, v.name)
            end
        end
        foreach_child(walk, e)
        return
    end
    for eq in equations
        walk(eq.lhs)
        walk(eq.rhs)
    end
    return out
end

# The elementwise array definition `rhs` (operators over variables and
# numbers) of an observed of declared shape `shape`, as the producer it
# denotes: `faq` over `shape` (one output index per axis) whose term reads
# each shaped variable at the output indices. A scalar `rhs` (no shaped
# operand: a number, a scalar variable) is that `faq` with no operands, its
# value replicated over `shape` (esm-spec §4.3.4). `nothing` when a shaped
# operand's shape is not `shape` (a broadcast the lift does not write) or a
# node is not an elementwise operator.
function _lift_elementwise_array_def(rhs::ASTExpr, shape, model::Model)
    sh = String[String(x) for x in shape]
    idx = String["__esm_lift_$k" for k in eachindex(sh)]
    reads = String[]
    ok = Ref(true)
    function lift(x)
        ok[] || return x
        if x isa VarExpr
            v = get(model.variables, x.name, nothing)
            v === nothing && return x
            _is_array_shape(v.shape) || return x
            if String[String(a) for a in v.shape] != sh
                ok[] = false
                return x
            end
            x.name in reads || push!(reads, x.name)
            return OpExpr("index", ASTExpr[x, (VarExpr(i) for i in idx)...])
        end
        (x isa NumExpr || x isa IntExpr) && return x
        if x isa OpExpr && x.op in _WS4_FOLDABLE_ELEMENTWISE_OPS && _tpl_structless(x) &&
                isempty(_bound_symbols(x)) && !_tpl_is_call(x)
            return reconstruct(x; args = ASTExpr[lift(a) for a in x.args])
        end
        ok[] = false
        return x
    end
    body = lift(rhs)
    ok[] || return nothing
    return OpExpr(
        "faq", ASTExpr[VarExpr(n) for n in reads];
        output_idx = Any[idx...],
        ranges = Dict{String, Any}(idx[k] => IndexSetRef(sh[k]) for k in eachindex(sh)),
        expr_body = body
    )
end

# ---- Elementwise array-observed fold (WS4: readable PDE-leaf decomposition) ----
# Fold every ARRAY-shaped observed whose (already-discretization-lowered) defining
# equation RHS is an ELEMENTWISE expression — top-level op in
# `_WS4_FOLDABLE_ELEMENTWISE_OPS`, or a scalar that replicates over the declared
# shape — into the equations that read it, in dependency order, returning
# `(rewritten_equations, folded_names)`.
#
# This lets a library PDE leaf be authored with readable intermediate array fields
# (a level-set's `grad_safe = grad_mag + ε`, `U_n = (u·∇ψ)/grad_safe`,
# `S_n = R_0·(1+φ_W+φ_S)`) instead of one monolithic inlined `D(ψ,t)` RHS — the
# evaluator otherwise rejects such an observed as `E_TREEWALK_UNSUPPORTED_SHAPE`
# (only a producer-defined array observed inlines, via `_array_inline_vars`).
# Array observeds defined by a bare array PRODUCER
# (the discretized `psi_x = D(ψ,x)`, `grad_mag = sqrt(D(ψ,x)²+D(ψ,y)²)`, both
# lowered to `makearray` by the mounted scheme) are LEFT UNTOUCHED — they define
# their own per-cell indexing and are inlined by the `_array_inline_vars` index
# beta-reduction downstream. So the fold pulls only the elementwise combinators
# into the state equation, whose whole-array lift then indexes the surviving
# producer refs per cell, as a hand-inlined RHS would.
#
# This is the model-level counterpart of `inline_elementwise_array_observeds`
# (shape_promotion.jl). Runs after observed-equation synthesis and before the
# whole-array derivative lift. Byte-identical (empty fold, same equations vector)
# for any model with no elementwise array observed.
function _fold_elementwise_array_observeds(equations::Vector{Equation}, model::Model)
    observed_here = Set{String}(observed_unknowns(model))
    function is_array_obs(name)
        var = get(model.variables, name, nothing)
        return var !== nothing && name in observed_here &&
            _is_array_shape(var.shape)
    end
    # A bare `name = rhs` algebraic definition per name (the D(state,t) equation
    # has an OpExpr lhs, so it is never a target — only its RHS is rewritten).
    defs = Dict{String, ASTExpr}()
    for eq in equations
        lhs = eq.lhs
        if lhs isa VarExpr
            defs[lhs.name] = eq.rhs
        end
    end
    # A SCALAR right-hand side — a number, or a reference to an unshaped declared
    # variable — is the zero-operand case of the same elementwise rule: it
    # replicates along every axis of the observed's declared shape (esm-spec
    # §4.3.4), so it folds exactly as `rhs + 0` would. A reference to a SHAPED
    # variable is a bare alias and stays with its own handler.
    function is_scalar_rhs(rhs)
        (rhs isa NumExpr || rhs isa IntExpr) && return true
        rhs isa VarExpr || return false
        var = get(model.variables, rhs.name, nothing)
        return var !== nothing && !_is_array_shape(var.shape)
    end
    # An array observed a template reference binds BY NAME (an argument the
    # call passes whole, `K` in `flux(u = u, K = K)`, or a name its body reads
    # from the caller, which the build's references carry as a binding,
    # `_tpl_augment`) is not folded: its substituted body would reach the call
    # as an expression, which the build passes as no array (it compiles a
    # reference as a call, never expanding it). Such a name is kept out of the
    # fold targets, and a definition that would have folded (an elementwise
    # one, a scalar, an alias of a target) is lifted to the producer it
    # denotes, `faq` over its declared shape (`_lift_elementwise_array_def`),
    # so it is a producer-defined array observed (materialized, read by name).
    # The lift reads each target it names through that target's resolved
    # body, so it reads no name the fold removes. A definition the lift cannot
    # write folds as before.
    function select_targets(kept)
        targets = Dict{String, ASTExpr}()
        # Selection runs to a FIXED POINT, because an observed that merely
        # ALIASES another target (`chain = lit`, `lit = 1.5`) has to fold with
        # it: the substitution below rewrites every surviving reader, so
        # folding only the referent would leave the alias behind as a shaped
        # observed carrying the referent's body — exactly the form this fold
        # exists to remove, and the one the evaluator rejects as
        # `E_TREEWALK_UNSUPPORTED_SHAPE`. An alias of a NON-target (`a = col`,
        # a const-array producer) is untouched and stays with the bare-alias
        # handler.
        while true
            grew = false
            for (name, rhs) in defs
                (haskey(targets, name) || name in kept || !is_array_obs(name)) && continue
                if would_fold(rhs, targets)
                    targets[name] = rhs
                    grew = true
                end
            end
            grew || break
        end
        return targets
    end
    would_fold(rhs, targets) = (rhs isa OpExpr && rhs.op in _WS4_FOLDABLE_ELEMENTWISE_OPS) ||
        is_scalar_rhs(rhs) || (rhs isa VarExpr && haskey(targets, rhs.name))
    # Dependency order among the targets (the chain is feed-forward; a cycle is
    # a genuine authoring error), and each target's fully-resolved body. Only
    # target→target edges are ordered; references to producer observeds /
    # params / state are leaves left in place. `_substitute_shared`, not plain
    # `substitute`: a raw target body can be a DAG (template lowering shares
    # subtrees by reference), and the per-path rebuild would materialize it as
    # an exponentially large tree.
    function resolve_targets(targets)
        deps = Dict(
            name => intersect(free_variables(rhs), keys(targets))
                for (name, rhs) in targets
        )
        order = _dependency_order(
            collect(keys(targets)), name -> deps[name];
            on_cycle = _ -> throw(
                TreeWalkError(
                    "E_TREEWALK_CYCLIC_ARRAY_OBSERVED",
                    "cyclic elementwise array-observed dependency among $(collect(keys(targets)))"
                )
            )
        )
        resolved = Dict{String, ASTExpr}()
        for name in order
            resolved[name] = _substitute_shared(targets[name], resolved)
        end
        return resolved
    end
    bound = _names_bound_to_references(equations)
    kept = Set{String}(n for n in bound if is_array_obs(n) && haskey(defs, n))
    local targets, resolved
    lifted = Dict{String, ASTExpr}()
    while true
        targets = select_targets(kept)
        resolved = resolve_targets(targets)
        empty!(lifted)
        unlifted = String[]
        for name in kept
            rhs = defs[name]
            would_fold(rhs, targets) || continue
            f = _lift_elementwise_array_def(
                _substitute_shared(rhs, resolved), model.variables[name].shape, model
            )
            f === nothing ? push!(unlifted, name) : (lifted[name] = f)
        end
        isempty(unlifted) && break
        setdiff!(kept, unlifted)
    end
    if !isempty(lifted)
        equations = copy(equations)
        for (k, eq) in enumerate(equations)
            lhs = eq.lhs
            (lhs isa VarExpr && haskey(lifted, lhs.name)) || continue
            equations[k] = Equation(lhs, lifted[lhs.name]; _comment = eq._comment)
        end
    end
    isempty(targets) && return (equations, Set{String}())

    # Drop each folded definition and substitute its fully-resolved RHS into
    # every remaining reader (sharing-preserving, as above).
    folded = Set{String}(keys(targets))
    out = Equation[]
    for eq in equations
        lhs = eq.lhs
        if lhs isa VarExpr && lhs.name in folded
            continue
        end
        push!(
            out, Equation(
                lhs, _substitute_shared(eq.rhs, resolved);
                _comment = eq._comment
            )
        )
    end
    return (out, folded)
end
