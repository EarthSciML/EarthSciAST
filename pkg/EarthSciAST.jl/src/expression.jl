"""
Expression substitution and structural operations module.

This module provides functions for working with ESM format expressions:
- Variable substitution with scoped reference support
- Free variable analysis
- Expression simplification through constant folding

All operations are non-mutating and return new ASTExpr objects.

Numerical evaluation lives in `tree_walk.jl` (`evaluate_expr` /
`build_evaluator`) — the official EarthSciAST Julia evaluator — so this module
hosts no parallel dispatch table. `simplify`'s constant-folding step
delegates to `evaluate_expr` so adding an op to the tree-walk evaluator
transparently extends the folder.
"""

# ========================================
# 0. Shared sub-expression traversal (GENERATED from OPEXPR_FIELD_TABLE)
# ========================================
#
# Every walker below is `@eval`-generated from `OPEXPR_FIELD_TABLE` (types.jl),
# so the expression-bearing field set exists in EXACTLY ONE place. Traversal
# order is struct-field order: `args`, `lower`, `upper`, `expr_body`, dense
# `ranges` bounds, `values`, `table_axes` (sorted keys), `filter`, `key`,
# `bindings` (sorted keys).

# Build one visit statement per expression-bearing table row. `wrap` maps the
# child-element expression (a `Symbol` naming a local bound to one child) to
# the statement that visits it — spliced INLINE, so the generated walkers stay
# closure-free (see `_foreach_subexpr_children` note below).
function _opexpr_child_stmts(wrap::Function)::Vector{Expr}
    stmts = Expr[]
    for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
        if spec.kind === :expr
            push!(stmts, :(let x = e.$f
                x === nothing || $(wrap(:x))
            end))
        elseif spec.kind === :expr_vec
            # `args` is the one never-`nothing` instance; the guard folds away.
            push!(stmts, :(let v = e.$f
                if v !== nothing
                    for x in v
                        $(wrap(:x))
                    end
                end
            end))
        elseif spec.kind === :expr_map
            push!(stmts, :(let m = e.$f
                if m !== nothing
                    for mk in sort!(collect(keys(m)))
                        let x = m[mk]
                            $(wrap(:x))
                        end
                    end
                end
            end))
        elseif spec.kind === :ranges
            # A `ranges` entry is an `IndexSetRef` (no sub-expressions) or a
            # dense bound vector whose entries may be expression-valued.
            push!(stmts, :(let m = e.$f
                if m !== nothing
                    for mk in sort!(collect(keys(m)))
                        v = m[mk]
                        if v isa AbstractVector
                            for x in v
                                x isa ASTExpr && $(wrap(:x))
                            end
                        end
                    end
                end
            end))
        end
    end
    return stmts
end

"""
    child_exprs(e::ASTExpr) -> Vector{ASTExpr}

All immediate sub-expressions of `e`, drawn from EVERY expression-bearing
`OpExpr` field — not just `args`. This is the ONE shared traversal used by
[`free_variables`](@ref), [`Base.contains`](@ref contains), and (field-wise)
[`substitute`](@ref), so dependency analysis sees variables nested inside
aggregate/arrayop bodies (`expr_body`), filter predicates (`filter`), integral
bounds (`lower`/`upper`), makearray `values`, table-lookup axis inputs
(`table_axes`), expression-valued dense `ranges` bounds, value-invention
`key` expressions, AND expression-template `bindings` values (historically the
one field this traversal missed while validate's copy missed `ranges` — both
walkers are now generated from `OPEXPR_FIELD_TABLE` and traverse both).

Non-expression fields (kind `:scalar`/`:join`/`:internal` in the table: `wrt`,
`dim`, `int_var`, `output_idx`, `join`, `regions`, `shape`, `perm`, `axis`,
`fn`, `name`, `value`, `table`, `output`, `id`, `manifold`, `distinct`, …)
carry strings/ints/const data, not `ASTExpr` sub-trees, and are not traversed.
`wrt` names a variable and is handled separately by
`free_variables`/`contains`. Literal and variable leaves have no children.
"""
child_exprs(::NumExpr) = ASTExpr[]
child_exprs(::IntExpr) = ASTExpr[]
child_exprs(::VarExpr) = ASTExpr[]

@eval function child_exprs(e::OpExpr)::Vector{ASTExpr}
    out = ASTExpr[]
    $(_opexpr_child_stmts(x -> :(push!(out, $x)))...)
    return out
end

"""
    foreach_subexpr(f, expr::ASTExpr) -> Nothing

Apply `f` to `expr` and to every descendant expression node, depth-first,
parent before children, drawing children from [`child_exprs`](@ref) — so `f`
sees expressions nested in EVERY expression-bearing `OpExpr` field
(aggregate/arrayop bodies, filters, integral bounds, makearray `values`,
table-lookup axis inputs, dense `ranges` bounds, value-invention `key`s,
template `bindings` values), not just `args`.

Build predicate scans and collectors on this instead of hand-rolling a
recursive field walk: a hand-rolled walk over `args` (or a partial field list)
silently misses variables in the fields above, and a newly added
expression-bearing `OpExpr` field then has to be patched into every copy.
`OPEXPR_FIELD_TABLE` (types.jl) is the ONE place that enumerates the field
list; every walker here is generated from it. Internal — read-only traversal;
for structure-preserving rewrites use `map_children`.
"""
# Apply `f` to each immediate child WITHOUT materializing a `child_exprs`
# vector — same generated field set, same order. Used by the hot read-only
# walks (`foreach_subexpr`, `_stencil_var_set`) so a whole-tree scan allocates
# nothing on the common args-only node.
@eval function foreach_child(f, e::OpExpr)
    $(_opexpr_child_stmts(x -> :(f($x)))...)
    return nothing
end
foreach_child(::Any, ::NumExpr) = nothing
foreach_child(::Any, ::IntExpr) = nothing
foreach_child(::Any, ::VarExpr) = nothing

function foreach_subexpr(f, expr::ASTExpr)
    f(expr)
    _foreach_subexpr_children(f, expr)
    return nothing
end
# Recurse without an allocating per-node closure: `f` is threaded straight through
# each recursive `foreach_subexpr` call (the generator splices
# `foreach_subexpr(f, x)` directly into the field walk — a
# `c -> foreach_subexpr(f, c)` closure would allocate once per node, which is
# exactly the cost this removes).
_foreach_subexpr_children(f, ::NumExpr) = nothing
_foreach_subexpr_children(f, ::IntExpr) = nothing
_foreach_subexpr_children(f, ::VarExpr) = nothing
@eval function _foreach_subexpr_children(f, e::OpExpr)
    $(_opexpr_child_stmts(x -> :(foreach_subexpr(f, $x)))...)
    return nothing
end

@eval function foreach_child_with_path(g, e::OpExpr, path::String)
    $((
        begin
            w = string(spec.wire)
            if spec.kind === :expr
                :(let x = e.$f
                    x === nothing || g(x, string(path, $("/" * w)))
                end)
            elseif spec.kind === :expr_vec
                :(let v = e.$f
                    if v !== nothing
                        for (i, x) in enumerate(v)
                            g(x, string(path, $("/" * w * "/"), i - 1))
                        end
                    end
                end)
            elseif spec.kind === :expr_map
                :(let m = e.$f
                    if m !== nothing
                        for mk in sort!(collect(keys(m)))
                            g(m[mk], string(path, $("/" * w * "/"), mk))
                        end
                    end
                end)
            else # :ranges
                :(let m = e.$f
                    if m !== nothing
                        for mk in sort!(collect(keys(m)))
                            v = m[mk]
                            if v isa AbstractVector
                                for (i, x) in enumerate(v)
                                    x isa ASTExpr &&
                                        g(x, string(path, $("/" * w * "/"), mk, "/", i - 1))
                                end
                            end
                        end
                    end
                end)
            end
        end
        for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
        if spec.kind in (:expr, :expr_vec, :expr_map, :ranges)
    )...)
    return nothing
end

@doc """
    foreach_child_with_path(g, e::OpExpr, path::String) -> Nothing

Apply `g(child, child_path)` to each immediate sub-expression of `e` — the
SAME generated field set and order as [`child_exprs`](@ref) — where
`child_path` extends `path` with the child's WIRE-key segment
(JSON-Pointer-style): `<path>/args/<i>`, `<path>/lower`, `<path>/expr`,
`<path>/ranges/<key>/<i>`, `<path>/values/<i>`, `<path>/axes/<key>`,
`<path>/filter`, `<path>/key`, `<path>/bindings/<key>` (indices 0-based).
Used by validate's reference walk so its descent can never drift from the
shared traversal.
""" foreach_child_with_path

# Index/loop symbols BOUND by this node itself (aggregate/arrayop range keys,
# `output_idx` axis names, an integral's `int_var`). These are node-local
# binders, not references to enclosing-scope variables.
#
# NOT the same set as validate.jl's `_bound_index_symbols`, deliberately: that
# checker additionally credits an argmin/argmax `arg` witness, subscript-
# position index names (`index(u, i+1)`), a `skolem` first-arg binder, and
# `bindings` KEYS (template formal parameters — the table's `binds_scope`
# flag) into reference-check scope, because validation answers "could this
# name legally appear here?" while this helper answers the narrower
# "does THIS node bind this symbol for `free_variables` subtraction?".
# Widening this set would silently hide real free variables from dependency
# analysis.
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
    map_children(f, e::ASTExpr) -> ASTExpr

Return a copy of `e` with `f` applied to each immediate sub-expression, preserving
`e`'s concrete type and every non-expression field. Leaf nodes (`NumExpr`,
`IntExpr`, `VarExpr`) are returned unchanged. For `OpExpr`, `f` is applied to every
expression-bearing field — the SAME set [`child_exprs`](@ref) traverses (`args`,
`lower`, `upper`, `expr_body`, dense `ranges` bounds, `values`, `table_axes`,
`filter`, `key`, and `bindings` values) — and the node is rebuilt via
[`reconstruct`](@ref), so a newly added `OpExpr` field can never be silently
dropped by a rewrite.

This is the ONE field-preserving structural-rewrite primitive: `substitute`,
`simplify`, and the flatten/lowering rewrites are expressed in terms of it, and
its field walk is GENERATED from `OPEXPR_FIELD_TABLE` (types.jl) so the
expression-bearing field list lives in exactly one place.
"""
map_children(f, e::NumExpr)::ASTExpr = e
map_children(f, e::IntExpr)::ASTExpr = e
map_children(f, e::VarExpr)::ASTExpr = e

# Generated per-field rebuild statements + the reconstruct kwargs they feed.
function _opexpr_map_children_parts()
    stmts = Expr[]
    kwargs = Expr[]
    for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
        nf = Symbol(:new_, f)
        if spec.kind === :expr
            push!(stmts, :($nf = mapf(e.$f)))
        elseif spec.kind === :expr_vec
            if f === :args
                push!(stmts, :($nf = ASTExpr[mapf(x) for x in e.$f]))
            else
                push!(stmts, :($nf = e.$f === nothing ? nothing :
                    ASTExpr[mapf(x) for x in e.$f]))
            end
        elseif spec.kind === :expr_map
            push!(stmts, :($nf = e.$f === nothing ? nothing :
                Dict{String,ASTExpr}(k => mapf(v) for (k, v) in e.$f)))
        elseif spec.kind === :ranges
            push!(stmts, :($nf = e.$f === nothing ? nothing :
                Dict{String,Any}(k => (v isa AbstractVector ?
                        Any[x isa ASTExpr ? mapf(x) : x for x in v] : v)
                    for (k, v) in e.$f)))
        else
            continue
        end
        push!(kwargs, Expr(:kw, f, nf))
    end
    return stmts, kwargs
end

@eval function map_children(f, e::OpExpr)::ASTExpr
    # IDENTITY-PRESERVING: when `f` fixes every sub-expression (returns it
    # `===`-identical), the node itself is returned, not a reconstruct-copy.
    # This is what lets a whole-tree rewrite pass (enum lowering, substitute
    # with no hits, …) leave a structurally-SHARED expression DAG shared —
    # an unconditional rebuild would rematerialize the DAG as an exponential
    # tree — and it matches the `r !== args[i]` did-this-subtree-change
    # identity convention used throughout the tree walk (types.jl).
    changed = false
    mapf(x) = x === nothing ? nothing :
        (r = f(x); r === x || (changed = true); r)
    $(first(_opexpr_map_children_parts())...)
    changed || return e
    return reconstruct(e; $(last(_opexpr_map_children_parts())...))
end

# ========================================
# 1. Variable Substitution
# ========================================

"""
    substitute(expr::ASTExpr, bindings::Dict{String,ASTExpr})::ASTExpr

Recursively replace variables in an expression with provided bindings.
Supports scoped reference resolution - if a variable is not found in bindings,
it remains unchanged. Returns a new ASTExpr object (non-mutating).

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
function substitute(expr::NumExpr, bindings::Dict{String,ASTExpr})::ASTExpr
    return expr  # Numeric literals are unchanged
end

function substitute(expr::IntExpr, bindings::Dict{String,ASTExpr})::ASTExpr
    return expr  # Integer literals are unchanged
end

function substitute(expr::VarExpr, bindings::Dict{String,ASTExpr})::ASTExpr
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
substitute(expr::OpExpr, bindings::Dict{String,ASTExpr})::ASTExpr =
    map_children(x -> substitute(x, bindings), expr)

# ========================================
# 2. Free Variable Analysis
# ========================================

"""
    free_variables(expr::ASTExpr)::Set{String}

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
    Base.contains(expr::ASTExpr, var::String)::Bool

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
    simplify(expr::ASTExpr)::ASTExpr

Perform constant folding and algebraic simplification on an expression.
Returns a new simplified ASTExpr object (non-mutating).

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
function simplify(expr::NumExpr)::ASTExpr
    return expr  # Already simplified
end

function simplify(expr::IntExpr)::ASTExpr
    return expr  # Already simplified
end

function simplify(expr::VarExpr)::ASTExpr
    return expr  # Already simplified
end

"""
    is_literal(expr::ASTExpr)::Bool

True iff `expr` is a numeric literal (either integer or float node).
"""
is_literal(expr::ASTExpr)::Bool = isa(expr, NumExpr) || isa(expr, IntExpr)

"""
    literal_value(expr::ASTExpr)

Return the numeric value of a literal node, as `Float64`. Throws on non-literals.
"""
literal_value(expr::NumExpr) = expr.value
literal_value(expr::IntExpr) = Float64(expr.value)

# Int64-representability of an integral Float64 — TWO deliberately different
# bounds, each pinned by its caller's behavior:
#
#  - `_int64_maybe_representable(f)`: `abs(f) <= Float64(typemax(Int64))`.
#    `Float64(typemax(Int64))` rounds UP to 2^63, so `f == 2^63` passes and the
#    caller's subsequent `Int64(f)` throws `InexactError` — which `simplify`'s
#    fold deliberately catches as "decline to fold" (algebraic fallthrough, NOT
#    a `NumExpr` fold). Tightening the bound would change that path's result.
#
#  - `_int64_exactly_representable(f)`: half-open signed range
#    `Float64(typemin(Int64)) <= f < 2^63` — every passing integral value
#    converts via `Int64(f)` without error. Used by the canonical `const`-value
#    emitter (canonicalize.jl), which must never throw on the boundary.
_int64_maybe_representable(f::Float64)::Bool = abs(f) <= Float64(typemax(Int64))
_int64_exactly_representable(f::Float64)::Bool =
    Float64(typemin(Int64)) <= f < Float64(typemax(Int64))

# Exception types `simplify`'s constant-folding step treats as "decline to
# fold" (fall through to the algebraic rules) rather than a bug:
#  - `UnboundVariableError` / `TreeWalkError` — a node `evaluate_expr` cannot
#    compile or evaluate without bindings (e.g. an aggregate whose empty `args`
#    are vacuously "all literal", or a `table_lookup` with no table registry);
#  - `DomainError` (`sqrt`/`log` of a negative literal), `DivideError`,
#    `OverflowError` — literal math outside the reals / machine range;
#  - `InexactError` — the `Int64(result_value)` boundary case admitted by
#    `_int64_maybe_representable` (`f == 2^63`).
_foldable_failure(err) =
    err isa UnboundVariableError || err isa TreeWalkError ||
    err isa DomainError || err isa DivideError ||
    err isa OverflowError || err isa InexactError

function simplify(expr::OpExpr)::ASTExpr
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
               _int64_maybe_representable(result_value)
                return IntExpr(Int64(result_value))
            end
            return NumExpr(result_value)
        catch err
            # An EXPECTED evaluation failure means "decline to fold" — continue
            # with algebraic simplification below. Anything else (including
            # InterruptException) is a real bug/signal and propagates.
            _foldable_failure(err) || rethrow()
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
            return reconstruct(recursed; args=ASTExpr[non_zero_args...])
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
            return reconstruct(recursed; args=ASTExpr[non_one_args...])
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