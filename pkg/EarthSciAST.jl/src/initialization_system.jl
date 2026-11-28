# The initialization system (esm 2.5.0; esm-spec §11.4.2–§11.4.4).
#
# `ic(v)` is v's value at `t0` anywhere in an equation. An equation that
# mentions `ic` is an initialization equation and holds at `t0` only. An
# EXPLICIT initial condition `ic(u) ~ e` (e mentions no `ic`) is evaluated
# directly, as the field and scalar `ic` folds always have; every other
# initialization equation is an equation of one system, which this file
# classifies, balances and orders:
#
#   * TRIANGULAR: every equation explicit in one unknown, `ic(u) ~ e`, and the
#     dependencies acyclic. Solved by substitution, in dependency order, by
#     the build's initialization-equation seed (`_seed_init_u0!`), which reads
#     every other starting value off the state it has built so far.
#   * TRULY IMPLICIT: anything else. The tree-walk build has no nonlinear
#     solver, so it refuses it (`unsupported_construct`) or, under
#     `strip = (:initialization,)`, hands it to the caller.
#
# Pure AST helpers here; the build-side plan is `_ic_system_plan`
# (tree_walk/build_ic_system.jl).

_is_ic_node(e) = e isa OpExpr && (e::OpExpr).op == "ic"

"""
    _mentions_ic(e) -> Bool

Whether `e` holds an `ic` node anywhere (esm-spec §11.4.3).
"""
_mentions_ic(e::ASTExpr) = _any_subexpr(_is_ic_node, e)

_is_initialization_equation(eq::Equation) = _mentions_ic(eq.lhs) || _mentions_ic(eq.rhs)

"""
    _is_explicit_ic(eq) -> Bool

An explicit initial condition (esm-spec §11.4.3): `ic(u) ~ e`, `u` a variable
reference and `e` mentioning no `ic`.
"""
_is_explicit_ic(eq::Equation) = _ic_lhs_variable(eq.lhs) !== nothing && !_mentions_ic(eq.rhs)

# The argument of an `ic` node: `(name, false)` for `ic(w)`, `(name, true)` for
# `ic(D(w))`, `nothing` for a malformed one (the loader refuses those, §4.2).
function _ic_arg(e::OpExpr)
    length(e.args) == 1 || return nothing
    a = e.args[1]
    a isa VarExpr && return ((a::VarExpr).name, false)
    if a isa OpExpr && (a::OpExpr).op == "D" && length((a::OpExpr).args) == 1 &&
            (a::OpExpr).args[1] isa VarExpr
        return (((a::OpExpr).args[1]::VarExpr).name, true)
    end
    return nothing
end

# Every `ic` node of `e`, as `(name, is_tendency)`.
function _ic_reads(e::ASTExpr)
    out = Tuple{String, Bool}[]
    foreach_subexpr(e) do x
        if _is_ic_node(x)
            a = _ic_arg(x::OpExpr)
            a === nothing || (a in out || push!(out, a))
        end
    end
    return out
end

# `e` with every `ic` subtree removed (replaced by 0): what an initialization
# equation reads outside its starting values.
_without_ic(e::ASTExpr) = _is_ic_node(e) ? NumExpr(0.0) : map_children(_without_ic, e)

"""
    _ic_as_state(e) -> ASTExpr

`e` with every `ic(w)` read as `w` and every `ic(D(w))` as `D(w)`: the form a
seed that reads the state built so far evaluates, and the form ModelingToolkit's
`initialization_eqs` take (esm-spec §11.4.4).
"""
function _ic_as_state(e::ASTExpr)
    if _is_ic_node(e)
        return (e::OpExpr).args[1]
    end
    return map_children(_ic_as_state, e)
end

# `e` with every reference to an unknown (`isunk(name)`) read as `ic(name)` and
# every `D(w)` of one as `ic(D(w))` (esm-spec §11.4.4): the typed twin of the
# loader's `_raw_ic_migrate`, for a `Model` built in memory with
# `initialization_equations`.
function _ic_migrate_typed(e::ASTExpr, isunk)
    if e isa VarExpr
        return isunk((e::VarExpr).name) ? OpExpr("ic", ASTExpr[e]) : e
    elseif e isa OpExpr
        o = e::OpExpr
        if o.op == "D" && length(o.args) == 1 && o.args[1] isa VarExpr &&
                isunk((o.args[1]::VarExpr).name)
            return OpExpr("ic", ASTExpr[o])
        end
        _is_ic_node(o) && return o
        return map_children(x -> _ic_migrate_typed(x, isunk), o)
    end
    return e
end

"""
    _migrate_typed_initialization(model) -> (equations, guesses)

A typed model's deprecated `initialization_equations` (esm-spec §11.4.4) as the
loader reads them: `ic` equations to append to `equations`, or, for a model with
no time derivative, `guesses` entries (an existing entry kept). An equation that
already mentions `ic` is kept as written.
"""
function _migrate_typed_initialization(model::Model)
    eqs = Equation[]
    guesses = Dict{String, Union{Float64, ASTExpr}}()
    isempty(model.initialization_equations) && return eqs, guesses
    isunk(n) = (v = get(model.variables, n, nothing); v !== nothing && v.type == UnknownVariable)
    has_d = any(eq -> _any_subexpr(x -> x isa OpExpr && (x::OpExpr).op == "D", eq.lhs), model.equations)
    for eq in model.initialization_equations
        if _is_initialization_equation(eq)
            push!(eqs, eq)
        elseif has_d
            push!(
                eqs, Equation(
                    _ic_migrate_typed(eq.lhs, isunk), _ic_migrate_typed(eq.rhs, isunk);
                    _comment = eq._comment
                )
            )
        elseif eq.lhs isa VarExpr && isunk((eq.lhs::VarExpr).name)
            n = (eq.lhs::VarExpr).name
            haskey(model.guesses, n) || haskey(guesses, n) || (guesses[n] = eq.rhs)
        else
            throw(
                ParseError(
                    "[deprecated_field] the initialization equation $(eq) of a model with no " *
                        "time derivative has no reading as a starting point (esm-spec §11.4.4)";
                    code = ERROR_CODES.DEPRECATED_FIELD
                )
            )
        end
    end
    return eqs, guesses
end

# The scalar element count of a cell-assigning `faq`'s ranges, or `nothing`
# when a range does not resolve to integers here.
function _faq_range_cells(rhs::OpExpr, sizes::AbstractDict)
    names = _output_idx_strings(rhs)
    isempty(names) && return nothing
    rd = _ranges_dict(rhs)
    cells = Vector{Vector{Int}}()
    axes = Vector{Vector{Int}}()
    for n in names
        r = get(rd, n, nothing)
        r === nothing && return nothing
        from = r isa AbstractDict && haskey(r, "from") ? String(r["from"]) :
            (hasproperty(r, :from) ? String(getproperty(r, :from)) : nothing)
        if from !== nothing
            sz = get(sizes, from, nothing)
            sz === nothing && return nothing
            push!(axes, collect(1:sz))
        else
            rr = try
                collect(_expand_int_range(r))
            catch
                return nothing
            end
            push!(axes, Int[x for x in rr])
        end
    end
    for t in Iterators.product(axes...)
        push!(cells, collect(Int, t))
    end
    return cells
end

"""
    _refuse_flat_ic_trajectory_reads(flat)

esm-spec §11.4.2: an initialization equation of `flat` that reads a state's
trajectory — bare, or `D(state)`, outside `ic`, directly or through observeds —
is refused with `ic_reads_state`. The tree-walk build checks the same in
`_ic_system_structure`; a compiler that hands the system on (`:mtk`) calls this.
"""
function _refuse_flat_ic_trajectory_reads(flat)
    eqs = Equation[eq for eq in flat.equations if _is_initialization_equation(eq)]
    append!(eqs, flat.initialization_equations)
    isempty(eqs) && return nothing
    states = Set{String}(n for n in keys(flat.state_variables) if !haskey(flat.observed_variables, n))
    obs = Dict{String, ASTExpr}()
    for eq in flat.equations
        eq.lhs isa VarExpr && haskey(flat.observed_variables, (eq.lhs::VarExpr).name) &&
            (obs[(eq.lhs::VarExpr).name] = eq.rhs)
    end
    for eq in eqs, side in (eq.lhs, eq.rhs)
        hit = _ic_trajectory_read(side, states, obs)
        hit === nothing && continue
        state, chain = hit
        reads = isempty(chain) ? "reads '$(state)', a state" :
            "reads '" * join(chain, "', which reads '") * "', which reads '$(state)', a state"
        throw(
            SimulateError(
                "[ic_reads_state] the initialization equation $(first(string(eq), 200)) " *
                    "$(reads), outside `ic` (esm-spec §11.4.2)",
                ERROR_CODES.IC_READS_STATE
            )
        )
    end
    return nothing
end
