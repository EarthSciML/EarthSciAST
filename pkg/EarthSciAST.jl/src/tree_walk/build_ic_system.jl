# tree_walk/build_ic_system.jl — the initialization system (esm 2.5.0,
# esm-spec §11.4.2–§11.4.3) in the tree-walk build.
#
# Every equation is classified once, by `_ic_role` (initialization_system.jl),
# the classification flatten, `validate` and the strip share. Three stages, one
# per build phase that has what it needs:
#
#   * build entry (`_split_initialization_system`): every initialization
#     equation that is not an explicit initial condition leaves the equation
#     stream for `model.initialization_equations`, before any pass that reads
#     equations as dynamics sees one, and its trajectory reads are refused
#     (`ic_reads_state`).
#   * phase 2 (`_ic_system_structure`): the starting values of observeds and
#     tendencies are expanded (§11.4.2 item 8) and each equation in solved form
#     (`ic(u) ~ e`) gets its SEED, `u ~ e′` with every `ic(w)` read as `w`: the
#     build's initialization-equation seed evaluates it against the state built
#     so far (`_seed_faq_init_u0!`).
#   * phase 4 (`_ic_system_finish`): with the state layout, the explicit
#     initial conditions and the supplied values in hand, the knowns are fixed
#     (explicit initial conditions, supplied ODE values, then the declared
#     defaults of the ODE states no solved-form equation is left for), the
#     balance is checked (`ic_system_unbalanced`), the solved-form equations are
#     ordered by what they read, and the implicit part — the equations not in
#     solved form, those on a dependency cycle, and every solved-form one that
#     reads one of their undetermined starting values — is refused
#     (`unsupported_construct`) or, under the strip class `initialization`,
#     handed back. The seeds that remain are returned in order.

# One equation of the initialization system.
struct _IcSysEq
    # As authored (flattened), for diagnostics and the stripped residual.
    authored::Equation
    # The unknown the equation is in solved form for (`ic(u) ~ e`), else
    # `nothing`.
    target::Union{Nothing, String}
    # The unknowns whose starting value the equation reads, the target
    # excluded, after the item-8 expansions.
    reads::Vector{String}
    # Every variable the equation mentions as a starting value (the target
    # included), for the balance.
    mentions::Vector{String}
    # The seed (`u ~ e′`), for an equation in solved form.
    seed::Union{Nothing, Equation}
    # An explicit initial condition evaluated by the seed rather than the field
    # fold (a `faq` over some of its target's cells, `_ic_partial_faq`): not an
    # equation of the system, its cells are knowns of it.
    explicit::Bool
end
_IcSysEq(a, t, r, m, s) = _IcSysEq(a, t, r, m, s, false)
_with_seed(e::_IcSysEq, seed::Equation) = _IcSysEq(e.authored, e.target, e.reads, e.mentions, seed, e.explicit)

struct _IcSystem
    eqs::Vector{_IcSysEq}
end

const _EMPTY_IC_SYSTEM = _IcSystem(_IcSysEq[])

"""
    _split_initialization_system(model) -> Model

`model` with every initialization equation that is not an explicit initial
condition (esm-spec §11.4.3, [`_ic_role`](@ref)) moved out of `equations` into
`initialization_equations`, after a typed model's deprecated block is read as
the loader reads it (§11.4.4). An explicit `e ~ ic(u)` is filed as
`ic(u) ~ e`. The trajectory reads of the moved equations are refused
(`ic_reads_state`). The same object when there is nothing to change.
"""
function _split_initialization_system(model::Model)
    migrated, guesses = _migrate_typed_initialization(model)
    obs = observed_definitions(model)
    isobs = n -> haskey(obs, n)
    changed = !isempty(model.initialization_equations)
    kept = Equation[]
    sys = Equation[]
    for eq in Iterators.flatten((model.equations, migrated))
        r = _ic_role(eq; isobserved = isobs)
        if r.kind === :system
            push!(sys, eq)
            changed = true
        elseif r.kind === :explicit
            lifted = _ic_needs_alignment(r.oriented, model)
            e = lifted === nothing ? r.oriented : lifted
            e === eq || (changed = true)
            push!(kept, e)
        else
            push!(kept, eq)
        end
    end
    changed || return model
    _refuse_ic_trajectory_reads(sys, Set{String}(solver_unknowns(model)), obs)
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
    rhs = _ic_aligned_rhs(t, eq.rhs, model.variables)
    return rhs === nothing ? nothing : Equation(eq.lhs, rhs; _comment = eq._comment)
end

# The right-hand side of `ic(t) ~ rhs` written as the `faq` over `t`'s shape,
# aligned by index-set name, or `nothing` when it needs no alignment
# (`_ic_needs_alignment`). `variables` maps each name to its declaration.
function _ic_aligned_rhs(t::String, rhs::ASTExpr, variables::AbstractDict)
    v = get(variables, t, nothing)
    (v === nothing || !_is_array_shape(v.shape)) && return nothing
    rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op) && return nothing
    shape = String[String(s) for s in v.shape]
    var_shapes = Dict{String, Vector{String}}(
        n => String[String(s) for s in w.shape] for (n, w) in variables if w.shape !== nothing
    )
    arrayvars = Set{String}(n for (n, w) in variables if _is_array_shape(w.shape))
    any(n -> n in arrayvars && var_shapes[n] != shape, _referenced_var_names(rhs)) || return nothing
    return _lift_to_faq(rhs, shape, arrayvars, var_shapes)
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

# `e` with every observed it reads replaced by its definition, to a fixed point.
function _ic_inline_observeds(e::ASTExpr, obs::AbstractDict, depth::Int = 0)
    depth > 64 && throw(
        TreeWalkError(
            ERROR_CODES.UNSUPPORTED_CONSTRUCT,
            "the initialization system: an observed's definition expands without end " *
                "(a definition cycle) in $(first(_ic_text(e), 200))"
        )
    )
    e isa VarExpr && haskey(obs, (e::VarExpr).name) &&
        return _ic_inline_observeds(obs[(e::VarExpr).name], obs, depth + 1)
    return map_children(x -> _ic_inline_observeds(x, obs, depth), e)
end

_ic_names(e::ASTExpr) = String[n for (n, d) in _ic_reads(e) if !d]

"""
    _ic_system_structure(model, sys) -> _IcSystem

Phase 2 of the initialization system (see the file header): the starting
values of observeds and tendencies expanded, each equation classified
([`_ic_role`](@ref)) and, in solved form for a state, given its seed.
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
    isunk = _is_unknown_of(model)
    arrayvars = Set{String}(n for (n, v) in model.variables if _is_array_shape(v.shape))
    var_shapes = Dict{String, Vector{String}}(
        n => String[String(s) for s in v.shape] for (n, v) in model.variables if v.shape !== nothing
    )
    eqs = _IcSysEq[]
    for eq in sys
        # The authored equation is what a diagnostic or a stripped residual
        # shows; the classification reads it with the item-8 expansions.
        x = Equation(_ic_expand(eq.lhs, obs, tend, isunk), _ic_expand(eq.rhs, obs, tend, isunk))
        r = _ic_role(x; isobserved = n -> haskey(obs, n))
        mentions = unique!(vcat(_ic_names(x.lhs), _ic_names(x.rhs)))
        t = r.target
        if t !== nothing && t in states
            # The seed reads the state built so far, where an observed has no
            # slot: a bare read of one (`ic(z) ~ ic(x) + g`) is its definition,
            # evaluated at the start like any other start-of-run read.
            body = _ic_inline_observeds(_ic_as_state(r.oriented.rhs), obs)
            if t in arrayvars && !_is_cell_faq(body)
                body = _lift_to_faq(body, var_shapes[t], arrayvars, var_shapes)
            end
            push!(
                eqs, _IcSysEq(
                    eq, t, String[n for n in mentions if n != t], mentions,
                    Equation(VarExpr(t), body; _comment = eq._comment)
                )
            )
        else
            push!(eqs, _IcSysEq(eq, nothing, mentions, mentions, nothing))
        end
    end
    return _IcSystem(eqs)
end

# The equations `idx` of `eqs` (each in solved form) in dependency order: one
# reading another's target comes after it (Kahn's order). Returns
# `(order, cyclic)`, `cyclic` the ones left on a dependency cycle.
function _ic_seed_order(eqs::Vector{_IcSysEq}, idx::Vector{Int})
    by_target = Dict{String, Vector{Int}}()
    for i in idx
        push!(get!(by_target, eqs[i].target, Int[]), i)
    end
    deps = Dict{Int, Set{Int}}(
        i => Set{Int}(j for r in eqs[i].reads for j in get(by_target, r, Int[])) for i in idx
    )
    order = Int[]
    done = Set{Int}()
    progress = true
    while progress
        progress = false
        for i in idx
            i in done && continue
            if issubset(deps[i], done)
                push!(order, i)
                push!(done, i)
                progress = true
            end
        end
    end
    return order, Int[i for i in idx if !(i in done)]
end

# Whether the explicit initial condition `ic(t) ~ rhs` (ranges resolved) is a
# cell-assigning `faq` that sets only some of `t`'s cells — a partial range, or
# a pointwise filter whose excluded cells take the semiring's 0. The field fold
# writes every cell of its target, so such an initial condition is evaluated by
# the initialization-equation seed, which writes the cells of its ranges only
# and leaves the rest at their default.
function _ic_partial_faq(t::String, rhs::ASTExpr, model::Model, index_sets, derived_extents)
    (rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op)) || return false
    op = rhs::OpExpr
    names = _output_idx_strings(op)
    isempty(names) && return false
    op.filter === nothing || return true
    v = get(model.variables, t, nothing)
    (v === nothing || !_is_array_shape(v.shape)) && return false
    exts = _declared_shape_extents(v.shape, index_sets, derived_extents)
    (exts === nothing || length(exts) != length(names)) && return false
    rd = _ranges_dict(op)
    for (d, n) in enumerate(names)
        r = get(rd, n, nothing)
        r isa AbstractVector || return false
        rr = try
            collect(_expand_int_range(r))
        catch
            return false
        end
        (isempty(rr) || first(rr) != 1 || last(rr) != exts[d] || length(rr) != exts[d]) && return true
    end
    return false
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

# What the strip class `initialization` hands back (API_SPEC §5.8): the removed
# equations, their unknowns as element names in state-layout order and each
# unknown's starting point. PR #820's draft shape; kept in this one record.
struct _StrippedInitialization
    equations::Vector{Equation}
    unknowns::Vector{String}
    x0::Vector{Float64}
end

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

# The slots of `name` an explicit initial condition or a seed with right-hand
# side `rhs` sets (`_ic_cover_cells`): a cell-assigning `faq`'s cells, else all.
function _ic_cover_slots(layout::StateLayout, name::String, rhs::ASTExpr, sizes)
    cells = _ic_cover_cells(rhs, sizes)
    if cells !== nothing
        b = _layout_block(layout, name)
        b === nothing || return Int[s for s in (_block_slot(b, c) for c in cells) if s != 0]
    end
    return _ic_var_slots(layout, name)
end

# Whether the current Problem construction asked for the strip class
# `initialization` (`esm_problem(…; strip)`, set by `_stripped_problem`).
_strip_initialization_requested() = get(task_local_storage(), :esm_strip_initialization, false)::Bool

# The algebraic unknowns the strip class `algebraic` handed to the caller (by
# flattened name; set by `_stripped_problem`): their starting values are the
# caller's to find (esm-spec §11.4.3).
_strip_algebraic_names() = get(task_local_storage(), :esm_strip_algebraic, String[])::Vector{String}

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
    sizes = _index_set_sizes(index_sets)
    var_sets = Dict{String, Vector{String}}(
        k => String[String(s) for s in v.shape] for (k, v) in model.variables if _is_array_shape(v.shape)
    )
    ode = Set{String}(ode_states(model))
    slots(v) = _ic_var_slots(layout, v)
    cover(e::_IcSysEq) = _ic_cover_slots(layout, e.target, e.seed.rhs, sizes)
    slotvar(s) = s <= length(_layout_scalar_names(layout)) ? _layout_scalar_names(layout)[s] :
        _layout_block_name(layout, s)
    # ---- known: explicit initial conditions, then supplied ODE-state values ----
    known = Set{Int}()
    for k in keys(eq_ics)
        union!(known, slots(String(k)))
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
    explicit_seeds = Equation[]
    for e in sys.eqs
        e.explicit || continue
        union!(known, cover(e))
        push!(explicit_seeds, e.seed)
    end
    members = Int[i for i in eachindex(sys.eqs) if !sys.eqs[i].explicit]
    isempty(members) && return explicit_seeds, nothing
    # ---- an equation solved for a known is not explicit in it (§11.4.3) ----
    eqs = copy(sys.eqs)
    why = String[]
    for i in members
        e = eqs[i]
        e.target === nothing && continue
        hit = intersect(Set{Int}(cover(e)), known)
        isempty(hit) && continue
        eqs[i] = _IcSysEq(e.authored, nothing, e.mentions, e.mentions, nothing)
        push!(
            why, "$(join(sort!([_slot_key(layout, s) for s in hit]), ", ")) is already known " *
                (
                isempty(intersect(hit, supplied_ode)) ? "from an explicit initial condition" :
                    "from its supplied value"
            ) * ", so $(_ic_text(e.authored)) is not solved for it"
        )
    end
    # ---- the declared defaults of ODE states (§11.4.3 "Declared defaults") ----
    # A known, unless an equation in solved form is left for the state; a
    # stripped algebraic unknown's starting value is the caller's.
    yielded = Set{Int}()
    for i in members
        eqs[i].target === nothing || union!(yielded, cover(eqs[i]))
    end
    caller = Set{Int}()
    for z in _strip_algebraic_names()
        union!(caller, setdiff(slots(z), known))
    end
    vars = String[]
    for i in members, m in eqs[i].mentions
        m in vars || push!(vars, m)
    end
    for v in vars
        d = get(model.variables, v, nothing)
        (v in ode && d !== nothing && d.default !== nothing) || continue
        for s in slots(v)
            s in yielded || s in caller || push!(known, s)
        end
    end
    # ---- unknowns and the balance ----
    var_unknown = Dict{String, Vector{Int}}(
        v => Int[s for s in slots(v) if !(s in known) && !(s in caller)] for v in vars
    )
    eq_cap = Int[
        (
            e = eqs[i]; e.target !== nothing ? length(cover(e)) :
                something(_ic_equation_count(e.authored, sizes, var_sets), 1)
        )
            for i in members
    ]
    vidx = Dict{String, Int}(v => i for (i, v) in enumerate(vars))
    adj = Vector{Int}[Int[vidx[m] for m in eqs[i].mentions] for i in members]
    var_cap = Int[length(var_unknown[v]) for v in vars]
    flow, eq_left, var_left = _ic_assignment(eq_cap, var_cap, adj)
    n_eq, n_unk = sum(eq_cap; init = 0), sum(var_cap; init = 0)
    if !(flow == n_eq == n_unk)
        dir = n_eq > n_unk ? "over-determined" : n_eq < n_unk ? "under-determined" :
            "without an assignment of one equation to each unknown"
        undetermined = String[vars[v] for v in eachindex(vars) if var_left[v] > 0]
        spare = String[
            first(_ic_text(eqs[members[k]].authored), 160) for k in eachindex(members) if eq_left[k] > 0
        ]
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
                    " The declared default of a state is a known starting value unless an " *
                    "equation in solved form is left for that state; an algebraic unknown's " *
                    "default is only a starting guess."
            )
        )
    end
    # ---- the solved-form equations in order; the implicit part ----
    order, cyclic = _ic_seed_order(eqs, Int[i for i in members if eqs[i].target !== nothing])
    implicit = vcat(Int[i for i in members if eqs[i].target === nothing], cyclic)
    # A starting value the implicit part has to determine (one its equations
    # mention that no ordered solved-form equation gives), or a stripped
    # algebraic unknown's, is undetermined; a solved-form equation that reads
    # one joins the implicit part, and its target is then undetermined too.
    solved = Set{Int}()
    for i in order
        union!(solved, cover(eqs[i]))
    end
    undetermined = copy(caller)
    for i in implicit, m in eqs[i].mentions, s in var_unknown[m]
        s in solved || push!(undetermined, s)
    end
    removed = Set{Int}(implicit)
    for i in order
        e = eqs[i]
        if any(r -> any(in(undetermined), slots(r)), e.reads)
            push!(removed, i)
            union!(undetermined, cover(e))
        end
    end
    kept = Int[i for i in order if !(i in removed)]
    seeds = vcat(explicit_seeds, Equation[eqs[i].seed for i in kept])
    isempty(removed) && return seeds, nothing
    rem = sort!(collect(removed))
    _strip_initialization_requested() || throw(
        TreeWalkError(
            ERROR_CODES.UNSUPPORTED_CONSTRUCT,
            "the initialization system is truly implicit (esm-spec §11.4.3): " *
                join((first(_ic_text(eqs[i].authored), 160) for i in rem), "; ") *
                " must be solved for their unknowns, and the tree-walk evaluator has no " *
                "nonlinear solver. It does not start the run from the guesses instead. " *
                "Build with compiler = :mtk to solve it, or pass " *
                "`strip = (:initialization,)` to esm_problem to take it over"
        )
    )
    given = Set{Int}()
    for i in kept
        union!(given, cover(eqs[i]))
    end
    unk = Set{Int}()
    for i in rem, m in eqs[i].mentions, s in var_unknown[m]
        s in given || push!(unk, s)
    end
    ord = sort!(collect(unk))
    x0 = Float64[]
    for s in ord
        v = _ic_starting_point(model, slotvar(s), s, u0, algebraic_supplied, params)
        u0[s] = v
        push!(x0, v)
    end
    stripped = _StrippedInitialization(
        Equation[eqs[i].authored for i in rem], String[_slot_key(layout, s) for s in ord], x0
    )
    return seeds, stripped
end
