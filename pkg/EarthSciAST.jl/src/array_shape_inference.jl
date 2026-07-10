# Standalone array-variable shape inference over flattened equations (gt-vt3).
# Deliberately independent of FlattenedSystem — called at MTK build time from
# ext/EarthSciASTMTKExt.jl so scalar-only callers pay no cost. Split from
# flatten.jl.

# ========================================
# Array-variable shape inference (gt-vt3)
# ========================================

"""
    infer_array_shapes(equations::Vector{Equation}) -> Dict{String, Vector{UnitRange{Int}}}

Walk every `arrayop`, `makearray`, and `index` node in the equation set and
compute, for each array-shaped variable, the union of ranges observed across
all references. The result maps variable name → per-axis `UnitRange{Int}`
vector (empty for scalar variables; one entry per dimension for array
variables). Only variables that actually appear inside an array operator get
a shape — scalar variables are absent from the result dict.

Semantics:
- For a `VarExpr` appearing as the first argument of an `index` node, each
  subsequent argument is an index expression (literal int, symbolic index
  name, or affine offset like `i+1`). The range of that index determines the
  variable's length on that axis. Affine offsets widen the required range
  (e.g. `u[i-1]` and `u[i+1]` in `i in 2:9` force `u` to span `1:10`).
- For an `arrayop`, its `output_idx` and `ranges` combined define the
  iteration space. Index names with no explicit range are left for
  inference from their usages inside the body.
- Conflicts: if a variable is referenced with inconsistent dimensionality
  across equations, this function raises an `ArgumentError`.

This pass is deliberately standalone — it does not mutate `FlattenedSystem`.
It is called at MTK build time from `ext/EarthSciASTMTKExt.jl` so
scalar-only callers pay no cost.
"""
function infer_array_shapes(equations::Vector{Equation})
    shapes = Dict{String,Vector{UnitRange{Int}}}()
    for eq in equations
        _scan_shape!(shapes, eq.lhs, Dict{String,UnitRange{Int}}())
        _scan_shape!(shapes, eq.rhs, Dict{String,UnitRange{Int}}())
    end
    return shapes
end

# Walk an expression tree recording per-variable axis extents. `idx_env`
# maps index-symbol name (`"i"`, `"j"`) to the UnitRange it iterates over
# in the enclosing `arrayop`, so `index(u, i-1, j+1)` inside `i in 2:9` can
# be resolved to a concrete range on each axis.
function _scan_shape!(shapes::Dict{String,Vector{UnitRange{Int}}},
                      expr::Expr,
                      idx_env::Dict{String,UnitRange{Int}})
    if expr isa NumExpr || expr isa IntExpr || expr isa VarExpr
        return
    end
    expr isa OpExpr || return

    if expr.op == "index"
        _record_index!(shapes, expr, idx_env)
        for a in expr.args[2:end]
            _scan_shape!(shapes, a, idx_env)
        end
        return
    end

    if expr.op == "arrayop" || expr.op == "aggregate"
        # Extend idx_env with any explicit ranges declared on this node.
        new_env = copy(idx_env)
        if expr.ranges !== nothing
            for (name, r) in expr.ranges
                lo, hi = _range_bounds(r)
                lo === nothing && continue  # expression-valued / index-set bounds — skip for static shape analysis
                new_env[name] = lo:hi
            end
        end
        if expr.expr_body !== nothing
            _scan_shape!(shapes, expr.expr_body, new_env)
        end
        for a in expr.args
            _scan_shape!(shapes, a, new_env)
        end
        return
    end

    if expr.op == "makearray"
        if expr.values !== nothing
            for v in expr.values
                _scan_shape!(shapes, v, idx_env)
            end
        end
        for a in expr.args
            _scan_shape!(shapes, a, idx_env)
        end
        return
    end

    # Generic recursion for other operators (+, -, *, /, ^, elementary
    # functions, D, grad, etc.). The optional `expr_body` field is scanned
    # only for array ops above, so we skip it here.
    for a in expr.args
        _scan_shape!(shapes, a, idx_env)
    end
end

# An index-set reference (RFC §5.2) carries no statically-known bound here
# (interval size / categorical members / ragged length live in the registry,
# resolved by the evaluator) — skip it for static shape analysis.
_range_bounds(::IndexSetRef) = (nothing, nothing)
function _range_bounds(r::AbstractVector)
    all(x -> x isa Integer, r) || return nothing, nothing  # expression-valued stop — skip for static analysis
    if length(r) == 2
        return Int(r[1]), Int(r[2])
    elseif length(r) == 3
        return Int(r[1]), Int(r[3])  # [start, step, stop]
    end
    throw(ArgumentError("range must have 2 or 3 entries, got $(length(r))"))
end

# Record a shape entry for `u` from `index(u, i1, i2, ...)`. Each index
# expression is evaluated against `idx_env` to determine the range it
# sweeps over on that axis. Returns nothing on a miss (scalar access).
function _record_index!(shapes::Dict{String,Vector{UnitRange{Int}}},
                        idx_node::OpExpr,
                        idx_env::Dict{String,UnitRange{Int}})
    isempty(idx_node.args) && return
    first_arg = idx_node.args[1]
    first_arg isa VarExpr || return
    vname = first_arg.name
    axis_ranges = UnitRange{Int}[]
    for idx_expr in idx_node.args[2:end]
        r = _eval_index_range(idx_expr, idx_env)
        r === nothing && return  # opaque — can't infer this axis
        push!(axis_ranges, r)
    end

    if haskey(shapes, vname)
        existing = shapes[vname]
        if length(existing) != length(axis_ranges)
            throw(ArgumentError(
                "Inconsistent dimensionality for variable '$vname': " *
                "saw $(length(existing))-D and $(length(axis_ranges))-D references"))
        end
        for (i, r) in enumerate(axis_ranges)
            existing[i] = min(first(existing[i]), first(r)):max(last(existing[i]), last(r))
        end
    else
        shapes[vname] = axis_ranges
    end
end

# Evaluate an index expression against the index-symbol environment.
# Supports: integer literals, bare index symbols (VarExpr in idx_env), and
# affine offsets `op("+", [idx, NumExpr(k)])` / `op("-", ...)` with either
# operand order. Returns a UnitRange representing the range that expression
# sweeps, or `nothing` if the shape cannot be inferred from this node alone.
function _eval_index_range(idx_expr::Expr, idx_env::Dict{String,UnitRange{Int}})
    if idx_expr isa IntExpr
        v = Int(idx_expr.value)
        return v:v
    elseif idx_expr isa NumExpr
        v = Int(idx_expr.value)
        return v:v
    elseif idx_expr isa VarExpr
        if haskey(idx_env, idx_expr.name)
            return idx_env[idx_expr.name]
        end
        return nothing
    elseif idx_expr isa OpExpr && idx_expr.op in ("+", "-") && length(idx_expr.args) == 2
        a, b = idx_expr.args
        base, offset = _split_affine(a, b)
        base === nothing && return nothing
        haskey(idx_env, base) || return nothing
        env_r = idx_env[base]
        shift = idx_expr.op == "+" ? offset : -offset
        return (first(env_r) + shift):(last(env_r) + shift)
    end
    return nothing
end

function _split_affine(a::Expr, b::Expr)
    if a isa VarExpr && b isa IntExpr
        return a.name, Int(b.value)
    elseif a isa IntExpr && b isa VarExpr
        return b.name, Int(a.value)
    elseif a isa VarExpr && b isa NumExpr
        return a.name, Int(b.value)
    elseif a isa NumExpr && b isa VarExpr
        return b.name, Int(a.value)
    end
    return nothing, 0
end
