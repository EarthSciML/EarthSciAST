# The initialization system (esm 2.5.0; esm-spec §11.4.2–§11.4.4).
#
# `ic(v)` is v's value at `t0` anywhere in an equation. An equation that
# mentions `ic` is an initialization equation and holds at `t0` only. This file
# holds what every reader of those equations shares, so they cannot drift:
#
#   * the ONE classification (`_ic_role`): an explicit initial condition
#     `ic(u) ~ e` (e mentions no `ic`, u not an observed), an equation of the
#     initialization system, and the unknown such an equation is in solved
#     form for — used by flatten, `validate`, the tree-walk build, the strip
#     and the ModelingToolkit export;
#   * the ONE count of an equation's scalar equations and of the cells an
#     explicit initial condition sets (`_ic_equation_count`, `_ic_cover_cells`);
#   * the trajectory-read refusal (`_refuse_ic_trajectory_reads`), the typed
#     form of the §11.4.4 rewrite, and the plain-text spelling diagnostics use.
#
# The build's plan of the system is tree_walk/build_ic_system.jl; the loader's
# migration is ic_migration.jl.

_is_ic_node(e) = e isa OpExpr && (e::OpExpr).op == "ic"

"""
    _mentions_ic(e) -> Bool

Whether `e` holds an `ic` node anywhere (esm-spec §11.4.3).
"""
_mentions_ic(e::ASTExpr) = _any_subexpr(_is_ic_node, e)

_is_initialization_equation(eq::Equation) = _mentions_ic(eq.lhs) || _mentions_ic(eq.rhs)

"""
    _IcRole

How the initialization system reads one equation (esm-spec §11.4.3), from
[`_ic_role`](@ref): the ONE classification flatten, `validate`, the build, the
strip and the ModelingToolkit export share.

* `kind` is `:dynamics` (the equation mentions no `ic`), `:explicit` (an
  explicit initial condition `ic(u) ~ e`, `e` mentioning no `ic`) or
  `:system` (every other initialization equation).
* `target` is the unknown `u` an `:explicit` equation sets, or the one a
  `:system` equation is in SOLVED FORM for (one side exactly `ic(u)`, the
  other not mentioning `ic(u)`), else `nothing`.
* `oriented` is the equation with `ic(target)` on the left (`e ~ ic(u)` is the
  same equation as `ic(u) ~ e`), else the equation as written.
"""
struct _IcRole
    kind::Symbol
    target::Union{Nothing, String}
    oriented::Equation
end

_no_observed(::AbstractString) = false

"""
    _ic_role(eq; isobserved) -> _IcRole

The classification of `eq` (see [`_IcRole`](@ref)). `isobserved(name)` says
whether a name is an observed: `ic(y)` of an observed is never a target
(esm-spec §11.4.3 "Explicit initial conditions"). `validate`, which cannot tell
observeds, leaves it at its default (none is).
"""
function _ic_role(eq::Equation; isobserved = _no_observed)
    _is_initialization_equation(eq) || return _IcRole(:dynamics, nothing, eq)
    for (side, other, flip) in ((eq.lhs, eq.rhs, false), (eq.rhs, eq.lhs, true))
        t = _ic_lhs_variable(side)
        (t === nothing || isobserved(t)) && continue
        (t, false) in _ic_reads(other) && continue
        o = flip ? Equation(eq.rhs, eq.lhs; _comment = eq._comment) : eq
        return _IcRole(_mentions_ic(other) ? :system : :explicit, t, o)
    end
    return _IcRole(:system, nothing, eq)
end

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
        if o.op == "D" && (o.wrt === nothing || o.wrt == "t") && length(o.args) == 1 &&
                o.args[1] isa VarExpr && isunk((o.args[1]::VarExpr).name)
            return OpExpr("ic", ASTExpr[o])
        end
        _is_ic_node(o) && return o
        return map_children(x -> _ic_migrate_typed(x, isunk), o)
    end
    return e
end

# A predicate: whether a name is a declared unknown of `model`.
_is_unknown_of(model::Model) =
    n -> (v = get(model.variables, n, nothing); v !== nothing && v.type == UnknownVariable)

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
    isunk = _is_unknown_of(model)
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
                    "[deprecated_field] the initialization equation $(_ic_text(eq)) of a model with no " *
                        "time derivative has no reading as a starting point (esm-spec §11.4.4)";
                    code = ERROR_CODES.DEPRECATED_FIELD
                )
            )
        end
    end
    return eqs, guesses
end

# ---- Counting: an equation's scalar equations, a starting value's cells ----

# The sizes of `index_sets` (an index-set name → its size, or its member count).
_index_set_sizes(index_sets) = Dict{String, Int}(
    String(k) => (v.size !== nothing ? v.size : length(v.members))
        for (k, v) in index_sets if v isa IndexSet && (v.size !== nothing || v.members !== nothing)
)

# The cells of a `faq` with output indices (one integer vector per cell, in
# column-major order) from its ranges, each `{from: set}` (its size in `sizes`)
# or a literal `[lo, hi]`; `nothing` for a `faq` without output indices or a
# range that does not resolve to integers here.
function _faq_cells(op::OpExpr, sizes::AbstractDict)
    names = _output_idx_strings(op)
    isempty(names) && return nothing
    rd = _ranges_dict(op)
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
    return Vector{Int}[collect(Int, t) for t in Iterators.product(axes...)]
end

_is_cell_faq(e) = e isa OpExpr && _is_faq_op((e::OpExpr).op) && !isempty(_output_idx_strings(e::OpExpr))

"""
    _ic_cover_cells(rhs, sizes) -> Union{Nothing, Vector{Vector{Int}}}

The cells of its target an explicit initial condition `ic(u) ~ rhs` sets
(esm-spec §11.4.3): a `faq` right-hand side's range cells, else `nothing`,
every cell.
"""
_ic_cover_cells(rhs::ASTExpr, sizes::AbstractDict) =
    _is_cell_faq(rhs) ? _faq_cells(rhs::OpExpr, sizes) : nothing

# The axes the value of `e` ranges over (esm-spec §4.3.4), each an index-set
# name with its size; a `faq`'s output axes are its own. An operand an `index`
# consumes with its subscripts contributes none; elementwise operands align by
# index-set name. A variable's axes are its declared shape in `var_sets`
# (empty: every variable reads as one value). `nothing` when a size is unknown.
function _ic_value_axes(e::ASTExpr, sizes::AbstractDict, var_sets::AbstractDict, out = Dict{String, Int}())
    if e isa VarExpr
        for s in get(var_sets, (e::VarExpr).name, String[])
            sz = get(sizes, s, nothing)
            sz === nothing && return nothing
            out[s] = sz
        end
        return out
    end
    e isa OpExpr || return out
    op = e::OpExpr
    if _is_cell_faq(op)
        # Each output axis: the index set its range names (so it aligns with
        # an operand over that set), else its own literal extent.
        rd = _ranges_dict(op)
        for (d, n) in enumerate(_output_idx_strings(op))
            r = get(rd, n, nothing)
            from = r isa AbstractDict && haskey(r, "from") ? String(r["from"]) :
                (r !== nothing && hasproperty(r, :from) ? String(getproperty(r, :from)) : nothing)
            if from !== nothing
                sz = get(sizes, from, nothing)
                sz === nothing && return nothing
                out[from] = sz
            else
                rr = try
                    _expand_int_range(r)
                catch
                    return nothing
                end
                out["\0faq\0$(objectid(op))\0$(d)"] = length(rr)
            end
        end
        return out
    end
    _is_faq_op(op.op) && return out
    op.op == "index" && return out
    if op.op == "ic"
        a = _ic_arg(op)
        a === nothing && return out
        return _ic_value_axes(VarExpr(first(a)), sizes, var_sets, out)
    end
    for a in op.args
        _ic_value_axes(a, sizes, var_sets, out) === nothing && return nothing
    end
    return out
end

"""
    _ic_equation_count(eq, sizes, var_sets) -> Union{Int, Nothing}

The scalar equations an initialization equation stands for (esm-spec §11.4.3
"Balance", "What `validate` reports"): the cells of the axes its sides range
over ([`_ic_value_axes`](@ref)), so a `faq` side with output indices has one
per cell of its ranges, `index(ic(u), k) ~ e` has one, and a whole-array
equation (with `var_sets`) one per element. `nothing` when an extent cannot be
read.
"""
function _ic_equation_count(eq::Equation, sizes::AbstractDict, var_sets::AbstractDict)
    n = 1
    for side in (eq.lhs, eq.rhs)
        ax = _ic_value_axes(side, sizes, var_sets)
        ax === nothing && return nothing
        n = max(n, prod(values(ax); init = 1))
    end
    return n
end

# ---- Messages ----

# `e` as plain text in the spec's own notation (`ic(x) + ic(y)`, `ic(D(x))`),
# for a diagnostic that names an initialization equation. A node it has no
# spelling for shows as its Typst math.
function _ic_text(e::ASTExpr)
    e isa VarExpr && return (e::VarExpr).name
    e isa NumExpr && return string((e::NumExpr).value)
    e isa IntExpr && return string((e::IntExpr).value)
    e isa OpExpr || return string(e)
    op = e::OpExpr
    args = op.args
    if op.op in ("+", "*", "-", "/", "^") && length(args) >= 2 && op.expr_body === nothing
        return "(" * join((_ic_text(a) for a in args), " $(op.op) ") * ")"
    elseif op.op == "-" && length(args) == 1
        return "-" * _ic_text(args[1])
    elseif op.op in ("ic", "D", "index") || (_op_spec(op.op) !== nothing && !_is_faq_op(op.op))
        return op.op * "(" * join((_ic_text(a) for a in args), ", ") * ")"
    end
    return string(e)
end
_ic_text(eq::Equation) = _ic_strip_parens(_ic_text(eq.lhs)) * " ~ " * _ic_strip_parens(_ic_text(eq.rhs))
_ic_strip_parens(s::String) = (startswith(s, "(") && endswith(s, ")") && _ic_parens_balanced(s[2:(end - 1)])) ? s[2:(end - 1)] : s
function _ic_parens_balanced(s)
    d = 0
    for c in s
        c == '(' && (d += 1)
        c == ')' && (d -= 1)
        d < 0 && return false
    end
    return d == 0
end

# ---- Trajectory reads (esm-spec §11.4.2) ----

"""
    _refuse_ic_trajectory_reads(eqs, states, obs; error)

esm-spec §11.4.2: an equation that mentions `ic` holds at t0 only, so one of
`eqs` that also reads a state's trajectory — bare, or `D(state)`, outside `ic`,
directly or through the observeds `obs` (name → definition) — is refused with
`ic_reads_state`. `error(code, message)` makes the exception (the tree-walk
build's `TreeWalkError` by default).
"""
function _refuse_ic_trajectory_reads(
        eqs, states::AbstractSet{String}, obs::AbstractDict;
        error = (code, msg) -> TreeWalkError(code, msg)
    )
    for eq in eqs, side in (eq.lhs, eq.rhs)
        hit = _ic_trajectory_read(side, states, obs)
        hit === nothing && continue
        state, chain = hit
        reads = isempty(chain) ? "reads '$(state)', a state" :
            "reads '" * join(chain, "', which reads '") * "', which reads '$(state)', a state"
        throw(
            error(
                ERROR_CODES.IC_READS_STATE,
                "the initialization equation $(first(_ic_text(eq), 200)) $(reads), outside " *
                    "`ic`. An equation that mentions `ic` holds at the start of the run only, " *
                    "so it reads starting values `ic(w)`, never a state's trajectory " *
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

"""
    _refuse_flat_ic_trajectory_reads(flat)

[`_refuse_ic_trajectory_reads`](@ref) over the initialization equations of the
flattened system `flat`, for a compiler that hands the system on (`:mtk`).
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
    return _refuse_ic_trajectory_reads(
        eqs, states, obs; error = (code, msg) -> SimulateError("[$(code)] " * msg, code)
    )
end
