"""
Expression substitution and structural operations module.

This module provides functions for working with ESM format expressions:
- Variable substitution with scoped reference support
- Free variable analysis
- Expression simplification through constant folding

All operations are non-mutating and return new Expr objects.

Numerical evaluation lives in `tree_walk.jl` (`evaluate_expr` /
`build_evaluator`) — the official ESS Julia evaluator — so this module
hosts no parallel dispatch table. `simplify`'s constant-folding step
delegates to `evaluate_expr` so adding an op to the tree-walk evaluator
transparently extends the folder.
"""

# ========================================
# 0. Shared sub-expression traversal
# ========================================

"""
    child_exprs(e::Expr) -> Vector{Expr}

All immediate sub-expressions of `e`, drawn from EVERY expression-bearing
`OpExpr` field — not just `args`. This is the ONE shared traversal used by
[`free_variables`](@ref), [`Base.contains`](@ref contains), and (field-wise)
[`substitute`](@ref), so dependency analysis sees variables nested inside
aggregate/arrayop bodies (`expr_body`), filter predicates (`filter`), integral
bounds (`lower`/`upper`), makearray `values`, table-lookup axis inputs
(`table_axes`), expression-valued dense `ranges` bounds, and value-invention
`key` expressions.

Non-expression fields (`wrt`, `dim`, `int_var`, `output_idx`, `join`,
`regions`, `shape`, `perm`, `axis`, `fn`, `name`, `value`, `table`, `output`,
`id`, `manifold`, `distinct`, …) carry strings/ints/const data, not `Expr`
sub-trees, and are not traversed. `wrt` names a variable and is handled
separately by `free_variables`/`contains`. Literal and variable leaves have no
children.
"""
child_exprs(::NumExpr) = Expr[]
child_exprs(::IntExpr) = Expr[]
child_exprs(::VarExpr) = Expr[]

function child_exprs(e::OpExpr)::Vector{Expr}
    out = Expr[]
    append!(out, e.args)
    for f in (e.lower, e.upper, e.expr_body, e.filter, e.key)
        f === nothing || push!(out, f)
    end
    if e.values !== nothing
        append!(out, e.values)
    end
    if e.table_axes !== nothing
        for k in sort!(collect(keys(e.table_axes)))
            push!(out, e.table_axes[k])
        end
    end
    if e.ranges !== nothing
        # A `ranges` entry is an `IndexSetRef` (no sub-expressions) or a dense
        # bound vector whose entries may be expression-valued.
        for k in sort!(collect(keys(e.ranges)))
            v = e.ranges[k]
            if v isa AbstractVector
                for x in v
                    x isa Expr && push!(out, x)
                end
            end
        end
    end
    return out
end

# Index/loop symbols BOUND by this node itself (aggregate/arrayop range keys,
# `output_idx` axis names, an integral's `int_var`). These are node-local
# binders, not references to enclosing-scope variables.
function _bound_symbols(e::OpExpr)::Vector{String}
    out = String[]
    e.int_var === nothing || push!(out, e.int_var::String)
    if e.ranges !== nothing
        for k in keys(e.ranges)
            push!(out, String(k))
        end
    end
    if e.output_idx !== nothing
        for x in e.output_idx
            x isa AbstractString && push!(out, String(x))
        end
    end
    return out
end

# ========================================
# 0b. Field-preserving structural rewrite
# ========================================

"""
    map_children(f, e::Expr) -> Expr

Return a copy of `e` with `f` applied to each immediate sub-expression, preserving
`e`'s concrete type and every non-expression field. Leaf nodes (`NumExpr`,
`IntExpr`, `VarExpr`) are returned unchanged. For `OpExpr`, `f` is applied to every
expression-bearing field — the SAME set [`child_exprs`](@ref) traverses (`args`,
`lower`, `upper`, `expr_body`, `filter`, `key`, `values`, `table_axes`, and dense
`ranges` bounds) — and the node is rebuilt via [`reconstruct`](@ref), so a newly
added `OpExpr` field can never be silently dropped by a rewrite.

This is the ONE field-preserving structural-rewrite primitive: `substitute`,
`simplify`, and the flatten/lowering rewrites are expressed in terms of it so the
expression-bearing field list lives in exactly one place (here and its read-only
twin `child_exprs`).
"""
map_children(f, e::NumExpr)::Expr = e
map_children(f, e::IntExpr)::Expr = e
map_children(f, e::VarExpr)::Expr = e

function map_children(f, e::OpExpr)::Expr
    mapf(x) = x === nothing ? nothing : f(x)
    new_args = Expr[f(arg) for arg in e.args]
    new_values = e.values === nothing ? nothing :
        Expr[f(v) for v in e.values]
    new_table_axes = e.table_axes === nothing ? nothing :
        Dict{String,Expr}(k => f(v) for (k, v) in e.table_axes)
    new_ranges = e.ranges === nothing ? nothing :
        Dict{String,Any}(k => (v isa AbstractVector ?
                Any[x isa Expr ? f(x) : x for x in v] : v)
            for (k, v) in e.ranges)
    return reconstruct(e;
        args = new_args,
        lower = mapf(e.lower), upper = mapf(e.upper),
        expr_body = mapf(e.expr_body), filter = mapf(e.filter),
        values = new_values, table_axes = new_table_axes,
        ranges = new_ranges, key = mapf(e.key))
end

# ========================================
# 1. Variable Substitution
# ========================================

"""
    substitute(expr::Expr, bindings::Dict{String,Expr})::Expr

Recursively replace variables in an expression with provided bindings.
Supports scoped reference resolution - if a variable is not found in bindings,
it remains unchanged. Returns a new Expr object (non-mutating).

# Arguments
- `expr`: The expression to perform substitution on
- `bindings`: Dictionary mapping variable names to replacement expressions

# Examples
```julia
# Simple substitution
x = VarExpr("x")
y = VarExpr("y")
sum_expr = OpExpr("+", [x, y])
bindings = Dict("x" => NumExpr(2.0))
result = substitute(sum_expr, bindings)  # OpExpr("+", [NumExpr(2.0), VarExpr("y")])

# Nested substitution
nested = OpExpr("*", [OpExpr("+", [x, NumExpr(1.0)]), y])
result = substitute(nested, bindings)  # OpExpr("*", [OpExpr("+", [NumExpr(2.0), NumExpr(1.0)]), VarExpr("y")])
```
"""
function substitute(expr::NumExpr, bindings::Dict{String,Expr})::Expr
    return expr  # Numeric literals are unchanged
end

function substitute(expr::IntExpr, bindings::Dict{String,Expr})::Expr
    return expr  # Integer literals are unchanged
end

function substitute(expr::VarExpr, bindings::Dict{String,Expr})::Expr
    return get(bindings, expr.name, expr)  # Replace if bound, otherwise keep original
end

# Field-preserving substitution: recurse into EVERY sub-expression the node
# carries (via the shared `map_children` rewrite) — not just `args` — so
# substitution is complete inside aggregate/arrayop bodies, filter predicates,
# integral bounds, makearray values, table-lookup axis inputs, value-invention
# `key` expressions, and expression-valued dense `ranges` bounds. `map_children`
# routes through `reconstruct`, preserving all non-expression fields (semiring,
# output_idx, table, manifold, id, join, …) that earlier hand-listed rebuilds
# silently dropped. Bound locals (index vars, `int_var`) are short local symbols
# never present in `bindings` (namespaced globals / parameter names), so
# recursing cannot capture them.
substitute(expr::OpExpr, bindings::Dict{String,Expr})::Expr =
    map_children(x -> substitute(x, bindings), expr)

# ========================================
# 2. Free Variable Analysis
# ========================================

"""
    free_variables(expr::Expr)::Set{String}

Extract all free (unbound) variable names from an expression.
Returns a set of variable names that appear in the expression.

# Examples
```julia
x = VarExpr("x")
y = VarExpr("y")
sum_expr = OpExpr("+", [x, y])
vars = free_variables(sum_expr)  # Set(["x", "y"])

nested = OpExpr("*", [OpExpr("+", [x, NumExpr(1.0)]), y])
vars = free_variables(nested)  # Set(["x", "y"])
```
"""
function free_variables(expr::NumExpr)::Set{String}
    return Set{String}()  # No variables in numeric literals
end

function free_variables(expr::IntExpr)::Set{String}
    return Set{String}()  # No variables in integer literals
end

function free_variables(expr::VarExpr)::Set{String}
    return Set([expr.name])  # Single variable
end

function free_variables(expr::OpExpr)::Set{String}
    # Union of free variables from EVERY expression-bearing field (via the
    # shared `child_exprs` traversal), so dependency analysis sees references
    # inside aggregate/arrayop bodies, filter predicates, integral bounds,
    # makearray values, and table-lookup axis inputs.
    result = Set{String}()
    for c in child_exprs(expr)
        union!(result, free_variables(c))
    end

    # Symbols bound by THIS node (aggregate/arrayop loop indices, an
    # integral's `int_var`) are local binders, not free references.
    for b in _bound_symbols(expr)
        delete!(result, b)
    end

    # Add variables from wrt field if present
    if expr.wrt !== nothing
        push!(result, expr.wrt)
    end

    return result
end

# ========================================
# 3. Variable Containment Check
# ========================================

"""
    Base.contains(expr::Expr, var::String)::Bool

Check if an expression contains a specific variable name.
Returns true if the variable appears anywhere in the expression — including
inside aggregate/arrayop bodies, filter predicates, integral bounds,
makearray values, and table-lookup axis inputs (the shared `child_exprs`
traversal). Unlike [`free_variables`](@ref), node-local binder symbols are
NOT subtracted: this is a pure containment check.

Defined as methods of `Base.contains` (haystack/needle semantics match);
there is no package-local `contains` function shadowing `Base`.

# Examples
```julia
x = VarExpr("x")
y = VarExpr("y")
sum_expr = OpExpr("+", [x, y])
contains(sum_expr, "x")  # true
contains(sum_expr, "z")  # false
```
"""
function Base.contains(expr::IntExpr, var::String)::Bool
    return false  # Integer literals don't contain variables
end

function Base.contains(expr::NumExpr, var::String)::Bool
    return false  # Numeric literals don't contain variables
end

function Base.contains(expr::VarExpr, var::String)::Bool
    return expr.name == var
end

function Base.contains(expr::OpExpr, var::String)::Bool
    # Check every expression-bearing field via the shared traversal.
    for c in child_exprs(expr)
        if contains(c, var)
            return true
        end
    end

    # Check wrt field
    if expr.wrt !== nothing && expr.wrt == var
        return true
    end

    return false
end

# ========================================
# 4. Evaluation error type
# ========================================

"""
    UnboundVariableError

Raised by [`evaluate_expr`](@ref) (the tree-walk evaluator entry point)
when an expression references a variable name that is not in the supplied
bindings. Defined here so it is in scope for callers that catch the
"binding not yet resolved" signal during iterated observed-variable
fixed-point passes.
"""
struct UnboundVariableError <: Exception
    variable_name::String
    message::String
end

Base.showerror(io::IO, e::UnboundVariableError) =
    print(io, "UnboundVariableError: ", e.message)

# ========================================
# 5. Expression Simplification
# ========================================

"""
    simplify(expr::Expr)::Expr

Perform constant folding and algebraic simplification on an expression.
Returns a new simplified Expr object (non-mutating).

# Simplification Rules
- Constant folding: `2 + 3` → `5`
- Additive identity: `x + 0` → `x`, `0 + x` → `x`
- Multiplicative identity: `x * 1` → `x`, `1 * x` → `x`
- Multiplicative zero: `x * 0` → `0`, `0 * x` → `0`
- Exponentiation: `x^0` → `1`, `x^1` → `x`

# Examples
```julia
# Constant folding
expr = OpExpr("+", [NumExpr(2.0), NumExpr(3.0)])
result = simplify(expr)  # NumExpr(5.0)

# Identity elimination
expr = OpExpr("*", [VarExpr("x"), NumExpr(1.0)])
result = simplify(expr)  # VarExpr("x")
```
"""
function simplify(expr::NumExpr)::Expr
    return expr  # Already simplified
end

function simplify(expr::IntExpr)::Expr
    return expr  # Already simplified
end

function simplify(expr::VarExpr)::Expr
    return expr  # Already simplified
end

"""
    is_literal(expr::Expr)::Bool

True iff `expr` is a numeric literal (either integer or float node).
"""
is_literal(expr::Expr)::Bool = isa(expr, NumExpr) || isa(expr, IntExpr)

"""
    literal_value(expr::Expr)

Return the numeric value of a literal node, as `Float64`. Throws on non-literals.
"""
literal_value(expr::NumExpr) = expr.value
literal_value(expr::IntExpr) = Float64(expr.value)

function simplify(expr::OpExpr)::Expr
    # Recurse into EVERY sub-expression via the shared field-preserving rewrite,
    # so folding and identity rules also reach aggregate/arrayop bodies, filter
    # predicates, integral bounds, makearray values, table axes, and dense range
    # bounds — not just top-level `args`. `recursed` carries the simplified
    # children in all fields; the algebraic rules below only reshape `args`.
    recursed = map_children(simplify, expr)::OpExpr
    simplified_args = recursed.args

    op = recursed.op

    # Try constant folding first - if all arguments are numeric, evaluate.
    # Per RFC §5.4.1, promotion happens only in evaluate, not simplify;
    # so when mixed int/float inputs fold, the result is a float literal.
    # When all inputs are integer, preserve integer result (for ops whose
    # integer result is representable — fall back to float on non-integer).
    # Folding is delegated to the official tree-walk evaluator
    # (`evaluate_expr`) so the simplifier shares the runner's dispatch
    # table and there is no parallel operator switch in this module.
    if all(is_literal, simplified_args)
        try
            result_value = evaluate_expr(recursed, Dict{String,Float64}())
            all_int = all(arg -> isa(arg, IntExpr), simplified_args)
            if all_int && isfinite(result_value) && result_value == trunc(result_value) &&
               abs(result_value) <= Float64(typemax(Int64))
                return IntExpr(Int64(result_value))
            end
            return NumExpr(result_value)
        catch
            # If evaluation fails, continue with algebraic simplification
        end
    end

    # Helper: true when arg is a numeric literal equal to v (compared by value).
    is_lit_val(arg, v) = (isa(arg, NumExpr) && arg.value == v) ||
                         (isa(arg, IntExpr) && Float64(arg.value) == v)

    # Algebraic simplification rules
    if op == "+"
        # Remove zeros: x + 0 = x, 0 + x = x
        non_zero_args = filter(arg -> !is_lit_val(arg, 0.0), simplified_args)
        if length(non_zero_args) == 0
            return NumExpr(0.0)
        elseif length(non_zero_args) == 1
            return non_zero_args[1]
        else
            return reconstruct(recursed; args=Expr[non_zero_args...])
        end

    elseif op == "*"
        # Check for zeros: x * 0 = 0, 0 * x = 0
        for arg in simplified_args
            if is_lit_val(arg, 0.0)
                return NumExpr(0.0)
            end
        end

        # Remove ones: x * 1 = x, 1 * x = x
        non_one_args = filter(arg -> !is_lit_val(arg, 1.0), simplified_args)
        if length(non_one_args) == 0
            return NumExpr(1.0)
        elseif length(non_one_args) == 1
            return non_one_args[1]
        else
            return reconstruct(recursed; args=Expr[non_one_args...])
        end

    elseif op == "^" && length(simplified_args) == 2
        base = simplified_args[1]
        exponent = simplified_args[2]

        # x^0 = 1
        if is_lit_val(exponent, 0.0)
            return NumExpr(1.0)
        end

        # x^1 = x
        if is_lit_val(exponent, 1.0)
            return base
        end

        # 0^x = 0 (for x > 0)
        if is_lit_val(base, 0.0) && is_literal(exponent) && literal_value(exponent) > 0.0
            return NumExpr(0.0)
        end

        # 1^x = 1
        if is_lit_val(base, 1.0)
            return NumExpr(1.0)
        end

        return recursed

    elseif op == "-" && length(simplified_args) == 2
        # x - 0 = x
        if is_lit_val(simplified_args[2], 0.0)
            return simplified_args[1]
        end

        return recursed

    elseif op == "/" && length(simplified_args) == 2
        # x / 1 = x
        if is_lit_val(simplified_args[2], 1.0)
            return simplified_args[1]
        end

        # 0 / x = 0 (for x != 0)
        if isa(simplified_args[1], NumExpr) && simplified_args[1].value == 0.0
            return NumExpr(0.0)
        end

        return recursed
    end

    # If no simplification rules apply, return the fully-recursed expression.
    return recursed
end