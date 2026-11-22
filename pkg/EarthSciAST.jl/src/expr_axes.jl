# ============================================================================
# expr_axes.jl — the one inference of the index sets an expression's value
# spans (esm-spec §4.3.4; esm-libraries-spec §4.7.5, "Pointwise lift: which
# states are lifted"). The pointwise lift, shape promotion and the elementwise
# template lift all ask it, so a variable cannot be an array to one of them and
# a scalar to another.
# ============================================================================

"""
    _ShapeEnv(known; defs, scalar, names, unknown, ctx, iv)

What [`_expr_axes`](@ref) knows about names:

- `known`: names with a fixed shape (a declared one, `[]` for a declared
  scalar, a lifted state's grid, a shape an earlier pass inferred);
- `defs`: bare-left-hand-side definitions, followed (once, memoized) for a name
  not in `known`; a name reached again while its own definition is being read
  is undecided;
- `scalar`: names read as scalars whatever they declare (the sources of
  non-pointwise `variable_map` entries into the component being lifted);
- `names`: every declared variable; one with no shape and no definition is a
  scalar;
- `unknown`: the answer for any other name (`nothing`, undecided, for the
  lift; `String[]` for shape promotion, which reads loop symbols too);
- `iv`: the independent variable's name (`domain.independent_variable`,
  esm-spec §11.3), a scalar unless a declaration says otherwise;
- `ctx`: the template-application context (`_ElementwiseContext`), or
  `nothing`. With one, a template application is elementwise in the arrays its
  expansion reads in value positions (esm-spec §9.6.11); without, it is
  undecided.
"""
struct _ShapeEnv{C}
    known::Dict{String, Vector{String}}
    defs::OrderedDict{String, ASTExpr}
    scalar::Set{String}
    names::Set{String}
    unknown::Union{Nothing, Vector{String}}
    iv::String
    ctx::C
    memo::Dict{String, Union{Vector{String}, Nothing}}
end

_ShapeEnv(
    known::Dict{String, Vector{String}};
    defs = OrderedDict{String, ASTExpr}(), scalar = Set{String}(), names = Set{String}(),
    unknown = nothing, ctx = nothing, iv::AbstractString = "t"
) = _ShapeEnv(
    known, defs, scalar, names, unknown, String(iv), ctx, Dict{String, Union{Vector{String}, Nothing}}()
)

function _name_axes(env::_ShapeEnv, name::String)::Union{Vector{String}, Nothing}
    name in env.scalar && return String[]
    haskey(env.known, name) && return copy(env.known[name])
    name == env.iv && return String[]
    haskey(env.memo, name) && return env.memo[name]
    body = get(env.defs, name, nothing)
    if body === nothing
        name in env.names && return String[]
        return env.unknown === nothing ? nothing : copy(env.unknown)
    end
    env.memo[name] = nothing
    out = _expr_axes(env, body)
    env.memo[name] = out
    return out
end

"""
    _expr_axes(env::_ShapeEnv, e) -> Union{Vector{String}, Nothing}

The ordered index sets `e`'s value spans, `String[]` for a scalar, `nothing`
when undecided:

- a number, a `const` whose value is a number, `true`, `false` and the
  independent variable are scalars;
- a name is answered by `env` ([`_ShapeEnv`](@ref));
- a structural `D(e)` (`wrt` `t` or absent) has the axes of `e`;
- an elementwise operator (`_is_elementwise_node`: a scalar operator, or a
  `broadcast` whose `fn` is one) has the UNION of its operands' axes in order
  of first appearance — `a[lon] + b[lat]` spans `[lon, lat]`, the outer
  product — and is undecided if any operand is;
- with a template context, a template application is elementwise in the
  arrays its expansion reads in value positions;
- an `index` whose subscripts are all scalars is a scalar, otherwise
  undecided;
- a `faq` with no output indices is a scalar; one whose every output index
  ranges `{"from": X}` has those index sets in `output_idx` order; any other is
  undecided;
- every other node is undecided: it consumes its operands whole.
"""
function _expr_axes(env::_ShapeEnv, e::ASTExpr)::Union{Vector{String}, Nothing}
    (e isa NumExpr || e isa IntExpr) && return String[]
    e isa VarExpr && return _name_axes(env, e.name)
    e isa OpExpr || return nothing
    op = e.op
    if env.ctx !== nothing && (op == "apply_operator" || e.template_origin !== nothing)
        return _union_axes(env, _application_operands(e, env.known, env.ctx))
    elseif op == "const"
        return e.value isa Number ? String[] : nothing
    elseif op == "true" || op == "false"
        return String[]
    elseif op == "index"
        for k in 2:length(e.args)
            ax = _expr_axes(env, e.args[k])
            (ax !== nothing && isempty(ax)) || return nothing
        end
        return String[]
    elseif op == "faq"
        (e.output_idx === nothing || isempty(e.output_idx)) && return String[]
        axes = String[]
        for sym in e.output_idx
            spec = (sym isa AbstractString && e.ranges !== nothing) ?
                get(e.ranges, String(sym), nothing) : nothing
            spec isa IndexSetRef || return nothing
            push!(axes, spec.from)
        end
        return axes
    elseif op == "D" && (e.wrt === nothing || e.wrt == "t") && length(e.args) == 1
        return _expr_axes(env, e.args[1])
    end
    _is_elementwise_node(e) || return nothing
    return _union_axes(env, e.args)
end

function _union_axes(env::_ShapeEnv, operands)::Union{Vector{String}, Nothing}
    out = String[]
    for a in operands
        ax = _expr_axes(env, a)
        ax === nothing && return nothing
        for x in ax
            x in out || push!(out, x)
        end
    end
    return out
end
