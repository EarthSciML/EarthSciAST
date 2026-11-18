# The reverse (Symbolics → ESM ASTExpr) walk, shared by EarthSciASTMTKExt
# (`mtk2esm`, `_symbolic_to_esm_export`) and EarthSciASTCatalystExt (rate
# expressions). Included by both; each extension compiles its own copy. The two
# callers differ only by policy (`_symbolic_to_esm`'s keywords): whether a
# callable symbol is a variable by name (`known_vars`) or always (a Catalyst
# species `S(t)`), and whether derivatives are walked.

"""
    _number_to_esm_literal(x) -> Union{EsmExpr,Nothing}

The scalar fast-path shared by both reverse walks: plain Julia numbers map
to ESM literals (`Bool`/`Integer` → `IntExpr`, floats and other `Real`s →
`NumExpr`); anything non-numeric returns `nothing` for the caller to keep
walking.
"""
function _number_to_esm_literal(x)
    if x isa Bool
        return IntExpr(Int64(x))
    elseif x isa Integer
        return IntExpr(Int64(x))
    elseif x isa AbstractFloat
        return NumExpr(Float64(x))
    elseif x isa Real
        return NumExpr(Float64(x))
    end
    return nothing
end

"""
    _symbolic_const_to_esm(raw) -> Union{EsmExpr,Nothing}

Const-node branch shared by both reverse walks: numeric values (including
those introduced by MTK Constants substitution, e.g. the `-1` produced by
SymbolicUtils' multiplication simplification `-k*x`) appear in the symbolic
tree as BasicSymbolic Const nodes for which `issym`/`iscall` are both false.
`Symbolics.value` extracts the underlying Julia number without touching
variable paths; a non-numeric extraction returns `nothing`.
"""
_symbolic_const_to_esm(raw) = _number_to_esm_literal(Symbolics.value(raw))

# The operator table of the reverse walk: the inverse of the registry's scalar
# functions (`fn => name`), in registry order, with a deprecated spelling never
# emitted and a function shared by two rows (`atan`/`atan2`) named by the first.
const _REVERSE_OP_TABLE = let t = Tuple{Any, String}[], seen = Any[]
    for s in EarthSciAST._OP_TABLE
        fn = s.scalar_fn
        (fn === nothing || haskey(EarthSciAST._DEPRECATED_OPS, s.name)) && continue
        any(f -> f === fn, seen) && continue
        push!(seen, fn)
        push!(t, (fn, s.name))
    end
    push!(t, (ifelse, "ifelse"))
    Tuple(t)
end

# Op equality, tolerating SymbolicUtils-wrapped forms of the same function. An
# operation with no name (a callable object) matches only itself.
function _op_matches(op, target)
    op == target && return true
    name = try
        nameof(op)
    catch err
        EarthSciAST._is_resource_error(err) && rethrow()
        return false
    end
    return string(name) == string(nameof(target))
end

# The ESM name of a symbolic call operation, or `nothing` outside the table.
function _call_op_to_esm_name(op)
    for (fn, name) in _REVERSE_OP_TABLE
        _op_matches(op, fn) && return name
    end
    return nothing
end

"""
    _symbolic_to_esm(expr; known_vars = nothing, strip_ns = identity,
                     derivatives = true) -> EsmExpr

Convert a Symbolics expression to an ESM expression. Numbers become literals;
a symbol becomes a `VarExpr` (time suffix stripped, then `strip_ns`); a call
whose operation is in the registry's reverse table becomes that operator, any
other call an `OpExpr` named by the function.

A callable symbol applied to arguments (`x(t)`) is a variable, not a call: with
`known_vars` a set of names, when its name is in the set (an MTK state or
observed); with `known_vars = nothing`, always (a Catalyst species `S(t)`).
With `derivatives`, an order-`n` `Differential` becomes `n` nested `D`s.
"""
function _symbolic_to_esm(
        expr; known_vars::Union{Nothing, Set{String}} = nothing,
        strip_ns::Function = identity, derivatives::Bool = true
    )
    rec(x) = _symbolic_to_esm(x; known_vars, strip_ns, derivatives)
    lit = _number_to_esm_literal(expr)
    lit === nothing || return lit
    raw = Symbolics.unwrap(expr)
    if !Symbolics.issym(raw) && !Symbolics.iscall(raw)
        # Symbolic constants (e.g. the `-1` SymbolicUtils' multiplication
        # simplification produces for `-k*x`) are neither symbols nor calls.
        const_lit = try
            _symbolic_const_to_esm(raw)
        catch err
            EarthSciAST._is_resource_error(err) && rethrow()
            nothing
        end
        const_lit === nothing || return const_lit
    end
    if Symbolics.issym(raw)
        return VarExpr(strip_ns(_strip_time(string(Symbolics.getname(raw)))))
    end
    if derivatives && Symbolics.is_derivative(raw)
        d = Symbolics.operation(raw)
        wrt = _strip_time(string(Symbolics.getname(d.x)))
        out = rec(Symbolics.arguments(raw)[1])
        for _ in 1:(hasproperty(d, :order) ? d.order : 1)
            out = OpExpr("D", EsmExpr[out], wrt = wrt)
        end
        return out
    end
    if Symbolics.iscall(raw)
        op = Symbolics.operation(raw)
        args = Symbolics.arguments(raw)
        if !isempty(args)
            if known_vars === nothing
                Symbolics.issym(op) &&
                    return VarExpr(strip_ns(_strip_time(string(Symbolics.getname(op)))))
            else
                opname = try
                    strip_ns(_strip_time(string(Symbolics.getname(op))))
                catch err
                    EarthSciAST._is_resource_error(err) && rethrow()
                    ""
                end
                !isempty(opname) && opname in known_vars && return VarExpr(opname)
            end
        end
        esm_args = EsmExpr[rec(a) for a in args]
        esm_op = _call_op_to_esm_name(op)
        esm_op === nothing || return OpExpr(esm_op, esm_args)
        opname = try
            string(nameof(op))
        catch err
            EarthSciAST._is_resource_error(err) && rethrow()
            string(op)
        end
        return OpExpr(opname, esm_args)
    end
    return VarExpr(string(expr))
end
