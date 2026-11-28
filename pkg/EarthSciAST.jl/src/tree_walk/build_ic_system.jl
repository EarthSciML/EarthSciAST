# tree_walk/build_ic_system.jl — the initialization system (esm 2.5.0,
# esm-spec §11.4.2–§11.4.3) in the tree-walk build.
#
# Three stages, one per build phase that has what it needs:
#
#   * build entry (`_split_initialization_system`): every initialization
#     equation that is not an explicit initial condition leaves the equation
#     stream for `model.initialization_equations`, before any pass that reads
#     equations as dynamics sees one.
#   * phase 2 (`_ic_system_structure`): the equations' trajectory reads are
#     refused (`ic_reads_state`), their observed and tendency starting values
#     are expanded (§11.4.2 item 8), each is classified as explicit in one
#     unknown (`ic(u) ~ e`) or implicit, and the explicit ones are ordered by
#     what they read. Each explicit one becomes a SEED, `u ~ e′` with every
#     `ic(w)` read as `w`: the build's initialization-equation seed evaluates
#     it against the state built so far (`_seed_init_u0!`).
#   * phase 4 (`_ic_system_finish`): with the state layout, the explicit
#     initial conditions and the supplied values in hand, the balance is
#     checked (`ic_system_unbalanced`), then the implicit part — the implicit
#     equations, those on a dependency cycle, and every equation that reads one
#     of their unknowns — is refused (`unsupported_construct`) or, under the
#     strip class `initialization`, left at its starting point and handed back.
#     The seeds that remain are returned in order.

# One equation of the initialization system.
struct _IcSysEq
    # As authored (flattened), for diagnostics and the stripped residual.
    authored::Equation
    # The target of an equation explicit in one unknown (`ic(u) ~ e`), else
    # `nothing`.
    target::Union{Nothing, String}
    # The unknowns whose starting value the equation reads, the target
    # excluded, after the item-8 expansions.
    reads::Vector{String}
    # Every variable the equation mentions as a starting value (the target
    # included), for the balance.
    mentions::Vector{String}
    # The seed (`u ~ e′`), for an explicit one.
    seed::Union{Nothing, Equation}
end

struct _IcSystem
    eqs::Vector{_IcSysEq}
    # The explicit equations in dependency order (indices into `eqs`).
    order::Vector{Int}
    # The implicit ones: not explicit in one unknown, or on a cycle.
    implicit::Vector{Int}
end

const _EMPTY_IC_SYSTEM = _IcSystem(_IcSysEq[], Int[], Int[])

"""
    _split_initialization_system(model) -> Model

`model` with every initialization equation that is not an explicit initial
condition (esm-spec §11.4.3) moved out of `equations` into
`initialization_equations`, after a typed model's deprecated block is read as
the loader reads it (§11.4.4). The same object when there is nothing to move.
"""
function _split_initialization_system(model::Model)
    migrated, guesses = _migrate_typed_initialization(model)
    any(
        eq -> _is_initialization_equation(eq) &&
            (!_is_explicit_ic(eq) || _ic_needs_alignment(eq, model) !== nothing),
        model.equations
    ) || !isempty(model.initialization_equations) || return model
    kept = Equation[]
    sys = Equation[]
    for eq in Iterators.flatten((model.equations, migrated))
        if _is_initialization_equation(eq) && !_is_explicit_ic(eq)
            push!(sys, eq)
        else
            lifted = _is_explicit_ic(eq) ? _ic_needs_alignment(eq, model) : nothing
            push!(kept, lifted === nothing ? eq : lifted)
        end
    end
    # The trajectory reads are judged on the model as written, whose
    # classification still sees the equation a refused one would have been.
    _refuse_ic_trajectory_reads(
        sys, Set{String}(solver_unknowns(model)), observed_definitions(model)
    )
    g = isempty(guesses) ? model.guesses : merge(model.guesses, guesses)
    return reconstruct(model; equations = kept, initialization_equations = sys, guesses = g)
end

# An explicit initial condition of an array unknown whose right-hand side is a
# whole-array expression over an operand of another shape (`ic(aw) ~ aw0`, `aw`
# over `[lev, bin]`, `aw0` over `[lev]`): the equation with its right-hand side
# written as the `faq` over the target's shape, each operand read at the cell
# aligned by index-set NAME, so a lower-rank operand repeats along the axes it
# does not carry (esm-spec §11.4.3 "Arrays", §4.3.4 rule 1). `nothing` when the
# equation needs no alignment.
function _ic_needs_alignment(eq::Equation, model::Model)
    t = _ic_lhs_variable(eq.lhs)
    t === nothing && return nothing
    v = get(model.variables, t, nothing)
    (v === nothing || !_is_array_shape(v.shape)) && return nothing
    rhs = eq.rhs
    rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op) && return nothing
    shape = String[String(s) for s in v.shape]
    var_shapes = Dict{String, Vector{String}}(
        n => String[String(s) for s in w.shape] for (n, w) in model.variables if w.shape !== nothing
    )
    arrayvars = Set{String}(n for (n, w) in model.variables if _is_array_shape(w.shape))
    any(n -> n in arrayvars && var_shapes[n] != shape, _referenced_var_names(rhs)) || return nothing
    return Equation(eq.lhs, _lift_to_faq(rhs, shape, arrayvars, var_shapes); _comment = eq._comment)
end

# esm-spec §11.4.2: an equation that mentions `ic` holds at t0 only, so one
# that also reads a state's trajectory (`D(x) ~ -(x - ic(x))/tau`) is refused.
function _refuse_ic_trajectory_reads(sys, states::AbstractSet{String}, obs::AbstractDict)
    for eq in sys, side in (eq.lhs, eq.rhs)
        hit = _ic_trajectory_read(side, states, obs)
        hit === nothing && continue
        state, chain = hit
        label = first(string(eq), 200)
        reads = isempty(chain) ? "reads '$(state)', a state" :
            "reads '" * join(chain, "', which reads '") * "', which reads '$(state)', a state"
        throw(
            TreeWalkError(
                ERROR_CODES.IC_READS_STATE,
                "the initialization equation $(label) $(reads), outside `ic`. An " *
                    "equation that mentions `ic` holds at the start of the run only, so " *
                    "it reads starting values `ic(w)`, never a state's trajectory " *
                    "(esm-spec §11.4.2)"
            )
        )
    end
    return nothing
end

# The first state an expression reads outside its `ic` terms, directly or
# through a chain of observeds: `(state, chain)`, or `nothing`.
function _ic_trajectory_read(e::ASTExpr, states::AbstractSet{String}, obs::AbstractDict)
    rest = _without_ic(e)
    dnode = Ref{Any}(nothing)
    foreach_subexpr(rest) do x
        if dnode[] === nothing && x isa OpExpr && (x::OpExpr).op == "D"
            dnode[] = x
        end
    end
    if dnode[] !== nothing
        r = _referenced_var_names(dnode[])
        return (isempty(r) ? "D(…)" : "D($(first(sort!(collect(r)))))", String[])
    end
    seen = Set{String}()
    function walk(names, chain)
        for m in sort!(collect(names))
            m in states && return (m, chain)
            if haskey(obs, m) && !(m in seen)
                push!(seen, m)
                hit = walk(_referenced_var_names(_without_ic(obs[m])), String[chain; m])
                hit === nothing || return hit
            end
        end
        return nothing
    end
    return walk(_referenced_var_names(rest), String[])
end

# `e` with every starting value of an observed `ic(y)` replaced by `y`'s
# definition with each unknown `w` it reads as `ic(w)`, and every `ic(D(x))` by
# `x`'s tendency read the same way (esm-spec §11.4.2 item 8), to a fixed point.
function _ic_expand(e::ASTExpr, obs::AbstractDict, tend::AbstractDict, isunk, depth::Int = 0)
    depth > 64 && throw(
        TreeWalkError(
            ERROR_CODES.UNSUPPORTED_CONSTRUCT,
            "the initialization system: the starting value of an observed or a tendency " *
                "expands without end (a definition cycle) in $(first(string(e), 200))"
        )
    )
    changed = Ref(false)
    function f(x::ASTExpr)
        if _is_ic_node(x)
            a = _ic_arg(x::OpExpr)
            a === nothing && return x
            name, is_d = a
            if is_d
                haskey(tend, name) || throw(
                    TreeWalkError(
                        ERROR_CODES.UNSUPPORTED_CONSTRUCT,
                        "the initialization system reads ic(D($name)), the tendency of " *
                            "'$name' at the start, but '$name' has no whole-variable `D` " *
                            "equation this build can read it from (esm-spec §11.4.2)"
                    )
                )
                changed[] = true
                return _ic_migrate_typed(tend[name], isunk)
            elseif haskey(obs, name)
                changed[] = true
                return _ic_migrate_typed(obs[name], isunk)
            end
            return x
        end
        return map_children(f, x)
    end
    out = f(e)
    return changed[] ? _ic_expand(out, obs, tend, isunk, depth + 1) : out
end

_ic_names(e::ASTExpr) = String[n for (n, d) in _ic_reads(e) if !d]

"""
    _ic_system_structure(model, sys; index_sets) -> _IcSystem

Phase 2 of the initialization system (see the file header): trajectory reads
refused, starting values of observeds and tendencies expanded, each equation
classified, the explicit ones ordered and given their seed.
"""
function _ic_system_structure(model::Model, sys::Vector{Equation})
    isempty(sys) && return _EMPTY_IC_SYSTEM
    obs = observed_definitions(model)
    states = Set{String}(solver_unknowns(model))
    tend = Dict{String, ASTExpr}()
    for eq in model.equations
        l = eq.lhs
        if l isa OpExpr && (l::OpExpr).op == "D" && length((l::OpExpr).args) == 1 &&
                (l::OpExpr).args[1] isa VarExpr
            n = ((l::OpExpr).args[1]::VarExpr).name
            haskey(tend, n) || (tend[n] = eq.rhs)
        end
    end
    isunk(n) = (v = get(model.variables, n, nothing); v !== nothing && v.type == UnknownVariable)
    arrayvars = Set{String}(n for (n, v) in model.variables if _is_array_shape(v.shape))
    var_shapes = Dict{String, Vector{String}}(
        n => String[String(s) for s in v.shape] for (n, v) in model.variables if v.shape !== nothing
    )
    eqs = _IcSysEq[]
    _refuse_ic_trajectory_reads(sys, states, obs)
    for eq in sys
        lhs = _ic_expand(eq.lhs, obs, tend, isunk)
        rhs = _ic_expand(eq.rhs, obs, tend, isunk)
        t = _ic_lhs_variable(lhs)
        rnames = _ic_names(rhs)
        mentions = unique!(vcat(_ic_names(lhs), rnames))
        if t !== nothing && !haskey(obs, t) && !(t in rnames) && t in states
            body = _ic_as_state(rhs)
            if t in arrayvars && !(body isa OpExpr && _is_faq_op((body::OpExpr).op) &&
                    !isempty(_output_idx_strings(body::OpExpr)))
                body = _lift_to_faq(body, var_shapes[t], arrayvars, var_shapes)
            end
            push!(
                eqs, _IcSysEq(
                    eq, t, String[n for n in rnames if n != t], mentions,
                    Equation(VarExpr(t), body; _comment = eq._comment)
                )
            )
        else
            push!(eqs, _IcSysEq(eq, nothing, mentions, mentions, nothing))
        end
    end
    # Kahn's order over the explicit equations: one reading another's target
    # comes after it. What stays on a cycle is implicit.
    by_target = Dict{String, Vector{Int}}()
    for (i, e) in enumerate(eqs)
        e.target === nothing || push!(get!(by_target, e.target, Int[]), i)
    end
    deps = Dict{Int, Set{Int}}()
    for (i, e) in enumerate(eqs)
        e.target === nothing && continue
        d = Set{Int}()
        for r in e.reads, j in get(by_target, r, Int[])
            push!(d, j)
        end
        deps[i] = d
    end
    order = Int[]
    done = Set{Int}()
    progress = true
    while progress
        progress = false
        for i in sort!(collect(keys(deps)))
            i in done && continue
            if issubset(deps[i], done)
                push!(order, i)
                push!(done, i)
                progress = true
            end
        end
    end
    implicit = Int[i for i in eachindex(eqs) if !(i in done)]
    return _IcSystem(eqs, order, implicit)
end

# ---- phase 4 -----------------------------------------------------------------

# The slots of state variable `name` in `layout`, or empty.
function _ic_var_slots(layout::StateLayout, name::String)
    s = get(layout, name, 0)
    s != 0 && return Int[s]
    b = _layout_block(layout, name)
    b === nothing && return Int[]
    return collect((b.base):(b.base + b.len - 1))
end

# The slots of `name` a cell-assigning faq right-hand side covers, else all.
function _ic_cover_slots(layout::StateLayout, name::String, rhs::ASTExpr, sizes)
    if rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op) && !isempty(_output_idx_strings(rhs::OpExpr))
        cells = _faq_range_cells(rhs::OpExpr, sizes)
        if cells !== nothing
            b = _layout_block(layout, name)
            b === nothing || return Int[s for s in (_block_slot(b, c) for c in cells) if s != 0]
        end
    end
    return _ic_var_slots(layout, name)
end

# The slots a supplied-value map names (`initial_conditions`, the caller's `u0`).
function _ic_supplied_slots(layout::StateLayout, n::Int, sup)
    sup === nothing && return Set{Int}()
    sup isa AbstractVector && return Set{Int}(1:n)
    (sup isa AbstractDict && !isempty(sup)) || return Set{Int}()
    a = fill(NaN, n)
    b = zeros(n)
    named = Set{Int}()
    try
        _apply_initial_conditions!(a, layout, sup)
        _apply_initial_conditions!(b, layout, sup)
    catch err
        # A key that names no state element (an algebraic unknown a strip
        # removed, say) is the seeding's own diagnostic, not the balance's.
        err isa EarthSciASTError || rethrow()
        return named
    end
    for i in 1:n
        (!isnan(a[i]) || !iszero(b[i])) && push!(named, i)
    end
    return named
end

# Max flow on the bipartite equation/unknown graph (Edmonds–Karp on the small
# variable-level graph): source → equation (its scalar count), equation →
# variable it mentions (unbounded), variable → sink (its unknown elements).
# Returns `(flow, eq_left, var_left)`, the capacity each side did not use.
function _ic_assignment(eq_cap::Vector{Int}, var_cap::Vector{Int}, adj::Vector{Vector{Int}})
    ne, nv = length(eq_cap), length(var_cap)
    N = ne + nv + 2
    S, T = N - 1, N
    cap = zeros(Int, N, N)
    for i in 1:ne
        cap[S, i] = eq_cap[i]
        for v in adj[i]
            cap[i, ne + v] = typemax(Int) ÷ 4
        end
    end
    for v in 1:nv
        cap[ne + v, T] = var_cap[v]
    end
    flow = 0
    while true
        prev = zeros(Int, N)
        prev[S] = S
        q = [S]
        while !isempty(q) && prev[T] == 0
            u = popfirst!(q)
            for w in 1:N
                if prev[w] == 0 && cap[u, w] > 0
                    prev[w] = u
                    push!(q, w)
                end
            end
        end
        prev[T] == 0 && break
        f = typemax(Int)
        w = T
        while w != S
            f = min(f, cap[prev[w], w])
            w = prev[w]
        end
        w = T
        while w != S
            cap[prev[w], w] -= f
            cap[w, prev[w]] += f
            w = prev[w]
        end
        flow += f
    end
    return flow, Int[cap[S, i] for i in 1:ne], Int[cap[ne + v, T] for v in 1:nv]
end

# The scalar equation count of an implicit equation: a top-level cell-assigning
# `faq`'s cells, else the product of the index sets its array operands range
# over (elementwise, aligned by name: §11.4.3 "Arrays"), else 1.
function _ic_eq_count(eq::Equation, model::Model, sizes)
    for side in (eq.lhs, eq.rhs)
        if side isa OpExpr && _is_faq_op((side::OpExpr).op) && !isempty(_output_idx_strings(side::OpExpr))
            c = _faq_range_cells(side::OpExpr, sizes)
            c === nothing || return length(c)
        end
    end
    sets = String[]
    for n in union(_referenced_var_names(eq.lhs), _referenced_var_names(eq.rhs))
        v = get(model.variables, n, nothing)
        (v === nothing || !_is_array_shape(v.shape)) && continue
        for s in v.shape
            String(s) in sets || push!(sets, String(s))
        end
    end
    return prod((get(sizes, s, 1) for s in sets); init = 1)
end

# What the strip class `initialization` hands back (API_SPEC §5.8): the removed
# equations, their unknowns as element names in state-layout order and each
# unknown's starting point. PR #820's draft shape; kept in this one record.
struct _StrippedInitialization
    equations::Vector{Equation}
    unknowns::Vector{String}
    x0::Vector{Float64}
end

# Whether the current Problem construction asked for the strip class
# `initialization` (`esm_problem(…; strip)`, set by `_stripped_problem`).
_strip_initialization_requested() = get(task_local_storage(), :esm_strip_initialization, false)::Bool

# A starting point of an element of the removed implicit part (API_SPEC §5.8,
# PR #820's draft): the supplied value of an algebraic unknown, else its
# `guesses` entry, else its declared default, else 0.
function _ic_starting_point(model::Model, name::String, slot::Int, u0, algebraic_supplied::Set{Int}, params)
    slot in algebraic_supplied && return u0[slot]
    g = get(model.guesses, name, nothing)
    if g !== nothing
        g isa Real && return Float64(g)
        return Float64(evaluate_expr(g, params))
    end
    v = get(model.variables, name, nothing)
    d = v === nothing ? nothing : v.default
    d isa Real && return Float64(d)
    return 0.0
end

"""
    _ic_system_finish(sys, model, layout, u0; …) -> (seeds, stripped)

Phase 4 of the initialization system (see the file header). Returns the seeds
to evaluate in order and, under the strip class `initialization`, what was
handed back (`nothing` otherwise).
"""
function _ic_system_finish(
        sys::_IcSystem, model::Model, layout::StateLayout, u0::Vector{Float64};
        eq_ics::AbstractDict, field_ics, initial_conditions::AbstractDict,
        caller_u0, index_sets::AbstractDict, params::AbstractDict
    )
    isempty(sys.eqs) && return Equation[], nothing
    n = length(u0)
    sizes = Dict{String, Int}(
        String(k) => v.size for (k, v) in index_sets if v isa IndexSet && v.size !== nothing
    )
    ode = Set{String}(ode_states(model))
    slotvar(s) = s <= length(_layout_scalar_names(layout)) ? _layout_scalar_names(layout)[s] :
        _layout_block_name(layout, s)
    # ---- known: explicit initial conditions, then supplied ODE-state values ----
    known = Set{Int}()
    for k in keys(eq_ics)
        union!(known, _ic_var_slots(layout, String(k)))
    end
    for (t, r) in field_ics
        union!(known, _ic_cover_slots(layout, t, r, sizes))
    end
    supplied = union(
        _ic_supplied_slots(layout, n, initial_conditions),
        _ic_supplied_slots(layout, n, caller_u0)
    )
    supplied_ode = Set{Int}(s for s in supplied if slotvar(s) in ode)
    algebraic_supplied = setdiff(supplied, supplied_ode)
    union!(known, supplied_ode)
    # ---- unknowns and the balance ----
    vars = String[]
    for e in sys.eqs, m in e.mentions
        m in vars || push!(vars, m)
    end
    var_unknown = Dict{String, Vector{Int}}(
        v => Int[s for s in _ic_var_slots(layout, v) if !(s in known)] for v in vars
    )
    eq_cap = Int[
        e.target !== nothing ?
            length(_ic_cover_slots(layout, e.target, e.seed.rhs, sizes)) :
            _ic_eq_count(e.authored, model, sizes)
        for e in sys.eqs
    ]
    vidx = Dict{String, Int}(v => i for (i, v) in enumerate(vars))
    adj = Vector{Int}[Int[vidx[m] for m in e.mentions] for e in sys.eqs]
    var_cap = Int[length(var_unknown[v]) for v in vars]
    flow, eq_left, var_left = _ic_assignment(eq_cap, var_cap, adj)
    n_eq, n_unk = sum(eq_cap; init = 0), sum(var_cap; init = 0)
    if !(flow == n_eq == n_unk)
        dir = n_eq > n_unk ? "over-determined" : n_eq < n_unk ? "under-determined" :
            "without an assignment of one equation to each unknown"
        undetermined = String[vars[v] for v in eachindex(vars) if var_left[v] > 0]
        spare = String[first(string(sys.eqs[i].authored), 160) for i in eachindex(sys.eqs) if eq_left[i] > 0]
        why = String[]
        for e in sys.eqs
            e.target === nothing && continue
            hit = intersect(Set(_ic_var_slots(layout, e.target)), supplied_ode)
            isempty(hit) || push!(
                why, "the supplied value of " * join(sort!([_slot_key(layout, s) for s in hit]), ", ") *
                    " makes it a known of the system"
            )
        end
        throw(
            TreeWalkError(
                ERROR_CODES.IC_SYSTEM_UNBALANCED,
                "the initialization system is $(dir): $(n_eq) scalar equation(s), " *
                    "$(n_unk) scalar unknown(s) (esm-spec §11.4.3). " *
                    "Unknowns no equation determines: " *
                    (isempty(undetermined) ? "none" : join(undetermined, ", ")) * ". " *
                    "Equations no unknown is left for: " *
                    (isempty(spare) ? "none" : join(spare, "; ")) * "." *
                    (isempty(why) ? "" : " " * join(why, "; ") * ".") *
                    " A declared default is a starting point, never an equation of the system."
            )
        )
    end
    # ---- the implicit part, and everything that reads one of its unknowns ----
    removed = Set{Int}(sys.implicit)
    if !isempty(removed)
        grew = true
        while grew
            grew = false
            cut = Set{String}()
            for i in removed, m in sys.eqs[i].mentions
                isempty(var_unknown[m]) || push!(cut, m)
            end
            for i in sys.order
                i in removed && continue
                if any(r -> r in cut, sys.eqs[i].reads)
                    push!(removed, i)
                    grew = true
                end
            end
        end
    end
    stripped = nothing
    if !isempty(removed)
        labels = String[first(string(sys.eqs[i].authored), 160) for i in sort!(collect(removed))]
        _strip_initialization_requested() || throw(
            TreeWalkError(
                ERROR_CODES.UNSUPPORTED_CONSTRUCT,
                "the initialization system is truly implicit (esm-spec §11.4.3): " *
                    join(labels, "; ") * " must be solved for their unknowns, and the " *
                    "tree-walk evaluator has no nonlinear solver. It does not start the " *
                    "run from the guesses instead. Build with compiler = :mtk to solve it, " *
                    "or pass `strip = (:initialization,)` to esm_problem to take it over"
            )
        )
        slots = Set{Int}()
        for i in removed, m in sys.eqs[i].mentions
            union!(slots, var_unknown[m])
        end
        ord = sort!(collect(slots))
        x0 = Float64[]
        for s in ord
            v = _ic_starting_point(model, slotvar(s), s, u0, algebraic_supplied, params)
            u0[s] = v
            push!(x0, v)
        end
        stripped = _StrippedInitialization(
            Equation[sys.eqs[i].authored for i in sort!(collect(removed))],
            String[_slot_key(layout, s) for s in ord], x0
        )
    end
    seeds = Equation[sys.eqs[i].seed for i in sys.order if !(i in removed)]
    return seeds, stripped
end
