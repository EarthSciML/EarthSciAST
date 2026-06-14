"""
Tree-walk evaluator for discretized `.esm` models (gt-e8yw).

Compiles the canonical-form equations of a `Model` into a plain
`f!(du, u, p, t)` by walking the expression AST at every RHS call.
Bypasses ModelingToolkit entirely, so compile time is independent of
the system size — the path is intended for discretized PDEs whose
scalar count exceeds MTK's tearing/codegen ceiling.

Public API:

    build_evaluator(model::Model; kwargs...)
        → (f!, u0::Vector{Float64}, p::NamedTuple, tspan::Tuple{Float64,Float64},
           var_map::Dict{String,Int})

The returned tuple plugs straight into `ODEProblem(f!, u0, tspan, p)`.
`var_map` is the state-name → index lookup so callers can probe the
solution at specific variables.

Dict and EsmFile convenience entry points select a model by name (or
the single model, if the file carries only one).
"""

# ============================================================
# 1. Error type
# ============================================================

"""
    TreeWalkError

Raised when the walker encounters an operator or construct it cannot
evaluate. `code` is always one of the `E_TREEWALK_*` codes from the
bead's acceptance criterion; `detail` carries op name or variable name
for diagnostics.
"""
struct TreeWalkError <: Exception
    code::String
    detail::String
end

Base.showerror(io::IO, e::TreeWalkError) =
    print(io, "$(e.code): $(e.detail)")

# ============================================================
# 2. Build — entry points
# ============================================================

"""
    build_evaluator(model::Model; initial_conditions=Dict(),
                    expression_initial_conditions=Dict(),
                    parameter_overrides=Dict(), tspan=nothing,
                    registered_functions=Dict())

Build a tree-walk ODE RHS evaluator for `model`.

All state variables must be scalar (shape === nothing) — the walker
assumes equations have already been scalarized by the discretize
pipeline. Array-typed ops (`arrayop`, `makearray`, `broadcast`,
`reshape`, `transpose`, `concat`) therefore raise
`E_TREEWALK_UNSUPPORTED_OP` if they appear in an RHS.

The returned `f!` closure reads `u`, the captured parameter vector
`p` (a NamedTuple keyed by parameter name), and `t`, and writes
time-derivatives into `du`. Observed variables are substituted into
RHS expressions at build time.

Keyword arguments:

* `initial_conditions::Dict{String,<:Real}` — override the default
  values in `model.variables` for specific state variables. Keyed by
  variable name (scalar) or cell key such as `"u[1,2]"` (array cell).
  Takes precedence over `expression_initial_conditions`.
* `expression_initial_conditions::Dict{String,<:Expr}` — per-variable
  closed-form initial fields for array state variables (ESM §11.4
  `expression` IC type). Each value is an `Expr` AST whose free symbols
  MUST be the variable's declared dimension names (from `shape`). The
  expression is evaluated at each grid cell by binding the integer
  1-based index of dimension `d` to `shape[d]`. Cell-specific entries
  in `initial_conditions` take precedence.
* `parameter_overrides::Dict{String,<:Real}` — override the default
  values for specific parameters.
* `tspan::Union{Nothing,Tuple{Real,Real}}` — explicit time span. If
  `nothing`, the first inline `tests` block's `time_span` is used; if
  the model has no tests, the null default `(0.0, 1.0)` is returned.
* `registered_functions::Dict{String,<:Function}` — handlers for
  `call` ops, keyed by `handler_id`.
"""
function build_evaluator(model::Model;
                         initial_conditions::AbstractDict=Dict{String,Float64}(),
                         expression_initial_conditions::AbstractDict=Dict{String,Expr}(),
                         parameter_overrides::AbstractDict=Dict{String,Float64}(),
                         tspan::Union{Nothing,Tuple{<:Real,<:Real}}=nothing,
                         registered_functions::AbstractDict=Dict{String,Function}())
    # ---- Partition variables ----
    scalar_state_names = String[]
    param_names = String[]
    observed_names = String[]
    state_var_names = Set{String}()
    for (name, v) in model.variables
        if v.type == StateVariable
            push!(state_var_names, name)
        elseif v.type == ParameterVariable
            v.shape !== nothing &&
                throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_SHAPE", name))
            push!(param_names, name)
        elseif v.type == ObservedVariable
            v.shape !== nothing &&
                throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_SHAPE", name))
            push!(observed_names, name)
        elseif v.type == BrownianVariable
            throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_BROWNIAN", name))
        end
    end
    sort!(param_names)

    # ---- Discover array cells from equations and initial conditions ----
    # Array variable detection: a variable is treated as an array if it has
    # an explicit non-nothing shape, OR if it appears inside index(var, k...)
    # in an equation LHS. This handles both declared-shape variables and the
    # common pattern where shape=nothing but equations use D(index(var, k)).
    array_var_names_declared = Set{String}(n for (n, v) in model.variables
                                           if v.type == StateVariable &&
                                              v.shape !== nothing)
    # Detect array usage from equations even when shape is not declared.
    array_var_names = _detect_array_vars(model.equations, state_var_names,
                                         initial_conditions)
    union!(array_var_names, array_var_names_declared)

    # array_cells: var_name → sorted list of index-tuples (1-based)
    array_cells = _discover_array_cells(model.equations, initial_conditions,
                                        array_var_names)

    # Scalar state variables: all state vars not treated as arrays.
    for name in state_var_names
        name in array_var_names || push!(scalar_state_names, name)
    end
    sort!(scalar_state_names)

    # Build per-var bounds for in-bounds / ghost-cell checks.
    # array_var_info: var_name → (lo::Vector{Int}, hi::Vector{Int})
    array_var_info = Dict{String, Tuple{Vector{Int},Vector{Int}}}()
    for (vname, cells) in array_cells
        isempty(cells) && continue
        ndim = length(cells[1])
        lo = [minimum(c[d] for c in cells) for d in 1:ndim]
        hi = [maximum(c[d] for c in cells) for d in 1:ndim]
        array_var_info[vname] = (lo, hi)
    end

    # ---- Build flat state vector: scalars first, then array cells ----
    # Array cells are enumerated in column-major order (first index fastest,
    # consistent with Julia's native array layout and the Rust/Python runtimes).
    array_cell_names = String[]
    for vname in sort(collect(keys(array_cells)))
        haskey(array_var_info, vname) || continue
        lo, hi = array_var_info[vname]
        shape = hi .- lo .+ 1
        ndim = length(lo)
        for linear in 0:prod(shape)-1
            indices = Vector{Int}(undef, ndim)
            r = linear
            for d in 1:ndim
                indices[d] = lo[d] + (r % shape[d])
                r = r ÷ shape[d]
            end
            push!(array_cell_names, _cell_key(vname, indices))
        end
    end

    all_state_names = vcat(scalar_state_names, array_cell_names)
    var_map = Dict{String,Int}(name => i for (i, name) in enumerate(all_state_names))

    # ---- Initial condition vector ----
    u0 = Vector{Float64}(undef, length(all_state_names))
    for (i, name) in enumerate(scalar_state_names)
        if haskey(initial_conditions, name)
            u0[i] = Float64(initial_conditions[name])
        else
            d = model.variables[name].default
            u0[i] = d === nothing ? 0.0 : Float64(d)
        end
    end
    # Precompile expression ICs once per variable to avoid recompiling per cell.
    # Maps vname → (_Node, shape::Vector{String}) where shape gives dimension names.
    ic_expr_compiled = Dict{String,Tuple{_Node,Vector{String}}}()
    for (vname, ic_expr) in expression_initial_conditions
        if haskey(model.variables, vname)
            shape = model.variables[vname].shape
            if shape !== nothing && !isempty(shape)
                dim_var_map = Dict{String,Int}(shape[d] => d for d in 1:length(shape))
                node = _compile(ic_expr, dim_var_map, Set{Symbol}(), Dict{String,Any}())
                ic_expr_compiled[vname] = (node, shape)
            end
        end
    end

    n_scalar = length(scalar_state_names)
    for (i_rel, cname) in enumerate(array_cell_names)
        i_abs = n_scalar + i_rel
        if haskey(initial_conditions, cname)
            u0[i_abs] = Float64(initial_conditions[cname])
        else
            m = match(r"^([^\[]+)\[", cname)
            vname = m === nothing ? "" : m.captures[1]
            if haskey(ic_expr_compiled, vname)
                # Evaluate expression at this cell's integer index coordinates.
                node, _ = ic_expr_compiled[vname]
                m2 = match(r"\[([^\]]+)\]$", cname)
                if m2 !== nothing
                    cell_idxs = parse.(Int, split(m2.captures[1], ","))
                    u_ic = Float64[Float64(x) for x in cell_idxs]
                    u0[i_abs] = _eval_node(node, u_ic, NamedTuple(), 0.0)
                else
                    u0[i_abs] = 0.0
                end
            elseif haskey(model.variables, vname)
                # Fall back to the parent variable's scalar default.
                d = model.variables[vname].default
                u0[i_abs] = d === nothing ? 0.0 : Float64(d)
            else
                u0[i_abs] = 0.0
            end
        end
    end

    # ---- Parameter NamedTuple ----
    p_vals = Float64[]
    p_syms = Symbol[]
    for name in param_names
        push!(p_syms, Symbol(name))
        if haskey(parameter_overrides, name)
            push!(p_vals, Float64(parameter_overrides[name]))
        else
            d = model.variables[name].default
            push!(p_vals, d === nothing ? 0.0 : Float64(d))
        end
    end
    # Use `nothing` for parameter-free models: some SciMLBase versions enter
    # an infinite recursion in SymbolicIndexingInterface when the problem
    # carries an empty NamedTuple{(),()} as `p`. `nothing` is SciMLBase's
    # canonical "no parameters" sentinel and avoids the dispatch loop.
    p = isempty(p_syms) ? nothing :
        NamedTuple{Tuple(p_syms)}(Tuple(p_vals))

    # ---- Observed substitution ----
    observed_exprs = Dict{String,Expr}()
    derivative_eqs = Equation[]
    for eq in model.equations
        if _is_scalar_D_lhs(eq.lhs)
            push!(derivative_eqs, eq)
        elseif _is_indexed_D_lhs(eq.lhs) || _is_arrayop_D_lhs(eq.lhs)
            push!(derivative_eqs, eq)
        elseif isa(eq.lhs, VarExpr) && eq.lhs.name in observed_names
            observed_exprs[eq.lhs.name] = eq.rhs
        else
            # Algebraic constraint / unsupported equation form.
            # The tree-walk path is ODE-only; see bead's "Not in scope".
            throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_EQUATION",
                                _equation_tag(eq)))
        end
    end
    resolved_obs = _resolve_observed(observed_exprs)

    # ---- Registered-function handlers ----
    reg_funcs = Dict{String,Any}(String(k) => v
                                 for (k, v) in registered_functions)

    # ---- Build per-derivative compiled-IR list ----
    # Each entry is (state_index, compiled-node). The RHS is inlined with
    # observed variables, index ops are resolved to flat-slot references,
    # then compiled to the compact `_Node` form.
    param_sym_set = Set(p_syms)
    rhs_list = Tuple{Int,_Node}[]
    covered = falses(length(all_state_names))

    for eq in derivative_eqs
        if _is_scalar_D_lhs(eq.lhs)
            # D(scalar_var) = expr
            state_name = (eq.lhs::OpExpr).args[1]::VarExpr
            idx = get(var_map, state_name.name, 0)
            idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", state_name.name))
            covered[idx] &&
                throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", state_name.name))
            covered[idx] = true
            rhs = isempty(resolved_obs) ? eq.rhs :
                  _sub_preserving(eq.rhs, resolved_obs)
            rhs_r = _resolve_indices(rhs, array_var_info, var_map)
            push!(rhs_list, (idx, _compile(rhs_r, var_map, param_sym_set, reg_funcs)))

        elseif _is_indexed_D_lhs(eq.lhs)
            # D(index(var, k...)) = expr  — indexed scalar derivative
            lhs_op = eq.lhs::OpExpr
            inner  = lhs_op.args[1]::OpExpr   # the index node
            var_expr = inner.args[1]
            var_expr isa VarExpr ||
                throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_LHS",
                                    "index first arg must be a variable name"))
            concrete_idxs = [_eval_const_int(a, Dict{String,Int}())
                             for a in inner.args[2:end]]
            cname = _cell_key(var_expr.name, concrete_idxs)
            idx = get(var_map, cname, 0)
            idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", cname))
            covered[idx] &&
                throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", cname))
            covered[idx] = true
            rhs = isempty(resolved_obs) ? eq.rhs :
                  _sub_preserving(eq.rhs, resolved_obs)
            rhs_r = _resolve_indices(rhs, array_var_info, var_map)
            push!(rhs_list, (idx, _compile(rhs_r, var_map, param_sym_set, reg_funcs)))

        elseif _is_arrayop_D_lhs(eq.lhs)
            # arrayop(expr=D(index(var, ...)), output_idx=[...], ranges={...}) = rhs_arrayop(...)
            # Expand by iterating the Cartesian product of output_ranges.
            lhs_op = eq.lhs::OpExpr
            idx_names = String[]
            for sym in (lhs_op.output_idx === nothing ? Any[] : lhs_op.output_idx)
                (sym isa String || sym isa AbstractString) &&
                    push!(idx_names, String(sym))
            end
            ranges_dict = lhs_op.ranges === nothing ?
                          Dict{String,Vector{Int}}() : lhs_op.ranges
            lhs_body = lhs_op.expr_body::OpExpr  # D(index(var, ...))
            rhs_body = _extract_arrayop_body(eq.rhs)

            range_iters = [collect(_expand_int_range(ranges_dict[n])) for n in idx_names]
            for idx_tuple in Iterators.product(range_iters...)
                idx_env  = Dict{String,Int}(idx_names[d] => idx_tuple[d]
                                            for d in 1:length(idx_names))
                idx_exprs = Dict{String,Expr}(k => IntExpr(Int64(v))
                                              for (k, v) in idx_env)
                # Determine which cell the LHS writes to.
                sub_lhs = _sub_preserving(lhs_body, idx_exprs)
                sub_lhs isa OpExpr && sub_lhs.op == "D" ||
                    throw(TreeWalkError("E_TREEWALK_ARRAYOP_MALFORMED_LHS",
                                        "expected D(index(...)) in arrayop body"))
                inner = sub_lhs.args[1]
                inner isa OpExpr && inner.op == "index" ||
                    throw(TreeWalkError("E_TREEWALK_ARRAYOP_MALFORMED_LHS",
                                        "expected index(var,...) inside D"))
                ve = inner.args[1]
                ve isa VarExpr ||
                    throw(TreeWalkError("E_TREEWALK_ARRAYOP_MALFORMED_LHS",
                                        "index first arg must be a variable name"))
                concrete_idxs = [_eval_const_int(a, Dict{String,Int}())
                                 for a in inner.args[2:end]]
                cname = _cell_key(ve.name, concrete_idxs)
                idx = get(var_map, cname, 0)
                idx == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", cname))
                covered[idx] &&
                    throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", cname))
                covered[idx] = true

                # Substitute loop vars into RHS body, inline observed, resolve indices.
                sub_rhs = _sub_preserving(rhs_body, idx_exprs)
                sub_rhs = isempty(resolved_obs) ? sub_rhs :
                          _sub_preserving(sub_rhs, resolved_obs)
                rhs_r = _resolve_indices(sub_rhs, array_var_info, var_map)
                push!(rhs_list, (idx, _compile(rhs_r, var_map, param_sym_set, reg_funcs)))
            end
        end
    end
    # States without a D(...) equation get du=0 (integrator leaves them
    # at their initial value — a common pattern for reified constants).

    # ---- Default tspan ----
    tspan_default = _pick_tspan(tspan, model)

    # ---- Closure ----
    f! = _make_rhs(rhs_list)

    return f!, u0, p, tspan_default, var_map
end

# (scalar_state_names is populated after array detection — see build_evaluator body)
# The helper is defined here since it must precede its call site.

"""
    build_evaluator(file::EsmFile; model_name=nothing, kwargs...)

Delegate to the typed entry point after selecting the model.
"""
function build_evaluator(file::EsmFile;
                         model_name::Union{Nothing,AbstractString}=nothing,
                         kwargs...)
    model = _select_model(file, model_name)
    return build_evaluator(model; kwargs...)
end

"""
    build_evaluator(esm::AbstractDict; model_name=nothing, kwargs...)

Parse a raw ESM dict, then delegate. This is the signature from the
bead description; the typed entry point is faster for callers that
already have a parsed `Model`.
"""
function build_evaluator(esm::AbstractDict;
                         model_name::Union{Nothing,AbstractString}=nothing,
                         kwargs...)
    # `coerce_esm_file` expects a JSON3-style object (property-access
    # getters). Round-trip through JSON3 so raw Julia Dict inputs — the
    # signature from the bead description — work.
    file = coerce_esm_file(JSON3.read(JSON3.write(esm)))
    return build_evaluator(file; model_name=model_name, kwargs...)
end

"""
    evaluate_expr(expr::Expr, bindings::AbstractDict;
                  registered_functions::AbstractDict=Dict{String,Function}())::Float64

Evaluate a single AST expression at the supplied numeric `bindings` by
running it through the same compile + walker pipeline as
[`build_evaluator`](@ref). All keys of `bindings` are exposed as readable
state variables; the special name `"t"` (if present) is bound to the
walker's time argument as well. Adding an op to the tree-walk evaluator
transparently extends this entry point — there is no separate dispatch
table.

Throws `UnboundVariableError` when `expr` references a name that is not
in `bindings` and is not the time variable; other failures surface as
[`TreeWalkError`](@ref).
"""
function evaluate_expr(expr::Expr, bindings::AbstractDict;
                       registered_functions::AbstractDict=Dict{String,Function}())::Float64
    var_map = Dict{String,Int}()
    u = Vector{Float64}(undef, length(bindings))
    i = 0
    for (name, _) in bindings
        i += 1
        sname = String(name)
        var_map[sname] = i
        u[i] = Float64(bindings[name])
    end
    reg_funcs = Dict{String,Any}(String(k) => v for (k, v) in registered_functions)
    node = try
        _compile(expr, var_map, Set{Symbol}(), reg_funcs)
    catch e
        if e isa TreeWalkError && e.code == "E_TREEWALK_UNBOUND_VARIABLE"
            throw(UnboundVariableError(e.detail,
                  "Variable '$(e.detail)' not found in bindings"))
        end
        rethrow(e)
    end
    t = haskey(bindings, "t") ? Float64(bindings["t"]) : 0.0
    return _eval_node(node, u, NamedTuple(), t)
end

# ============================================================
# 3. Compiled-IR — one-shot compilation to a compact, type-stable tree
# ============================================================
#
# `_eval` below walks the raw `OpExpr` tree. That's correct but every
# op dispatch is an O(N) chain of String comparisons, and every
# VarExpr lookup does a Dict probe. For 4096-equation models the
# overhead dominates. `_compile` walks the expression once at build
# time and produces `_Node` trees where:
#
#   * op is a `Symbol` (pointer compare, not byte compare)
#   * state refs have their u-index baked in
#   * parameter refs have their `Val{sym}` type param baked in for
#     `getfield(p, Val)` — monomorphic NamedTuple access
#   * literals are pre-promoted to Float64
#   * registered-function handlers are looked up and captured once
#
# The compiled tree keeps semantics identical to walking `OpExpr`
# directly; `_eval` stays available for the unit-test helper which
# exercises the fallback path.

# _NKind encodes what a node is. Keeping it as a Bare integer (UInt8)
# gives a fast `kind === K_*` dispatch inside `_eval_node`.
const _NK_LITERAL = UInt8(1)
const _NK_STATE   = UInt8(2)   # read u[idx]
const _NK_PARAM   = UInt8(3)   # read p.<sym>
const _NK_TIME    = UInt8(4)   # return t
const _NK_OP      = UInt8(5)   # apply op to children

struct _Node
    kind::UInt8
    op::Symbol
    literal::Float64
    idx::Int
    sym::Symbol
    handler::Any
    children::Vector{_Node}
end

function _mknode(; kind::UInt8, op::Symbol=Symbol(""),
                 literal::Float64=0.0, idx::Int=0,
                 sym::Symbol=Symbol(""), handler=nothing,
                 children::Vector{_Node}=_Node[])
    return _Node(kind, op, literal, idx, sym, handler, children)
end

# `param_syms` is a `Set{Symbol}` so parameters can be distinguished
# from unbound-variable errors without another pass.
function _compile(expr::NumExpr, var_map, param_syms, reg_funcs)
    return _mknode(kind=_NK_LITERAL, literal=expr.value)
end
function _compile(expr::IntExpr, var_map, param_syms, reg_funcs)
    return _mknode(kind=_NK_LITERAL, literal=Float64(expr.value))
end
function _compile(expr::VarExpr, var_map, param_syms, reg_funcs)
    name = expr.name
    if name == "t"
        return _mknode(kind=_NK_TIME)
    end
    idx = get(var_map, name, 0)
    if idx != 0
        return _mknode(kind=_NK_STATE, idx=idx)
    end
    sym = Symbol(name)
    if sym in param_syms
        return _mknode(kind=_NK_PARAM, sym=sym)
    end
    throw(TreeWalkError("E_TREEWALK_UNBOUND_VARIABLE", name))
end
function _compile(expr::OpExpr, var_map, param_syms, reg_funcs)
    op_sym = Symbol(expr.op)
    handler = nothing
    if op_sym === :fn
        # Closed function registry (esm-spec §9.2 / esm-tzp). The function
        # name is captured in the node's `handler` slot as a tuple of
        # (name::String, const_array_or_nothing). For
        # `interp.searchsorted` the second arg is a const-op array which
        # we pre-extract so the runtime hot path doesn't walk the AST.
        fname = expr.name
        fname === nothing &&
            throw(TreeWalkError("E_TREEWALK_FN_MISSING_NAME", expr.op))
        if !(fname in _CLOSED_FUNCTION_NAMES)
            throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION", fname))
        end
        if fname == "interp.searchsorted"
            length(expr.args) == 2 ||
                throw(TreeWalkError("E_TREEWALK_FN_ARITY",
                    "interp.searchsorted expects 2 args, got $(length(expr.args))"))
            tab = expr.args[2]
            if !(tab isa OpExpr && tab.op == "const" && tab.value isa AbstractVector)
                throw(TreeWalkError("E_TREEWALK_FN_ARG_NOT_CONST",
                    "interp.searchsorted: 2nd arg must be a `const`-op array"))
            end
            # Compile only the scalar first arg as a child; carry the
            # constant array on the node so the runtime call is one
            # _eval_node + one closed-function dispatch.
            children = _Node[_compile(expr.args[1], var_map, param_syms, reg_funcs)]
            handler = (fname, Any[tab.value])
        elseif fname == "interp.linear"
            # Args = (table, axis, x). Const arrays at positions [1, 2];
            # scalar query at [3]. Pre-extract the const arrays so the
            # runtime hot path skips AST traversal.
            length(expr.args) == 3 ||
                throw(TreeWalkError("E_TREEWALK_FN_ARITY",
                    "interp.linear expects 3 args, got $(length(expr.args))"))
            tbl  = _require_const_array(expr.args[1], "interp.linear", "table")
            axs  = _require_const_array(expr.args[2], "interp.linear", "axis")
            children = _Node[_compile(expr.args[3], var_map, param_syms, reg_funcs)]
            handler = (fname, Any[tbl, axs])
        elseif fname == "interp.bilinear"
            # Args = (table, axis_x, axis_y, x, y). Const arrays at [1, 2, 3];
            # scalar queries at [4, 5].
            length(expr.args) == 5 ||
                throw(TreeWalkError("E_TREEWALK_FN_ARITY",
                    "interp.bilinear expects 5 args, got $(length(expr.args))"))
            tbl  = _require_const_array(expr.args[1], "interp.bilinear", "table")
            axx  = _require_const_array(expr.args[2], "interp.bilinear", "axis_x")
            axy  = _require_const_array(expr.args[3], "interp.bilinear", "axis_y")
            children = _Node[
                _compile(expr.args[4], var_map, param_syms, reg_funcs),
                _compile(expr.args[5], var_map, param_syms, reg_funcs),
            ]
            handler = (fname, Any[tbl, axx, axy])
        else
            children = _Node[_compile(a, var_map, param_syms, reg_funcs)
                             for a in expr.args]
            handler = (fname, nothing)
        end
        return _mknode(kind=_NK_OP, op=op_sym, children=children, handler=handler)
    end

    children = _Node[_compile(a, var_map, param_syms, reg_funcs)
                     for a in expr.args]
    if op_sym === :const
        # Scalar `const` ops fold to a literal at compile time. Non-scalar
        # `const` only ever appears as an argument to ops that consume
        # arrays (handled in their respective compile paths above).
        v = expr.value
        if v isa Real && !(v isa Bool)
            return _mknode(kind=_NK_LITERAL, literal=Float64(v))
        end
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
            "non-scalar `const` op outside an array-consuming position"))
    elseif op_sym === :enum
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
            "`enum` op encountered after lowering — call `lower_enums!` before compile"))
    elseif op_sym === :call
        # Removed in v0.3.0 (esm-spec §9 closure). `parse_expression` already
        # rejects file-loaded `call` ops; reaching this arm means a caller
        # constructed a `call` OpExpr programmatically.
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
            "`call` op was removed in v0.3.0 — migrate to `fn` ops " *
            "or AST equations (esm-spec §9 closure, RFC closed-function-registry)"))
    elseif op_sym === :D
        throw(TreeWalkError("E_TREEWALK_D_IN_RHS",
                            "D(...) only allowed in equation LHS"))
    elseif op_sym === :grad || op_sym === :div || op_sym === :laplacian
        # esm-i7b: spatial differential operators MUST be rewritten by ESD
        # discretization rules into `arrayop` AST before reaching the
        # simulator. Encountering one here means the canonical pipeline
        # broke; surface the violation rather than substituting zero (the
        # historical stub behaviour in other bindings).
        throw(TreeWalkError("E_TREEWALK_UNREACHABLE_SPATIAL_OP",
            "UnreachableSpatialOperatorError: encountered '$(expr.op)' node " *
            "in simulation evaluation. Spatial operators must be rewritten " *
            "by ESD discretization rules before reaching the simulator. " *
            "Pipeline contract violated."))
    elseif op_sym === :arrayop
        # arrayop is valid as a top-level equation LHS/RHS pair but must
        # never appear as a sub-expression inside a compiled body. If we
        # reach here the caller likely passed an arrayop in a non-equation
        # context (e.g. bare RHS on a scalar equation) — that is an error.
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "arrayop node in expression position — " *
                            "only valid as an equation-level LHS/RHS pair"))
    elseif op_sym === :makearray || op_sym === :broadcast || op_sym === :reshape ||
           op_sym === :transpose || op_sym === :concat
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "$(expr.op) (not yet supported in tree-walk path)"))
    elseif op_sym === :index || op_sym === :bc
        # index ops must be resolved to state-slot references by
        # _resolve_indices before reaching _compile; encountering one here
        # means the caller skipped that pass.
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP",
                            "$(expr.op) reached _compile unresolved — " *
                            "_resolve_indices must run first"))
    end
    return _mknode(kind=_NK_OP, op=op_sym, children=children, handler=handler)
end

# ============================================================
# 4. Compiled walker
# ============================================================

@inline function _eval_node(n::_Node, u, p, t)
    k = n.kind
    if k === _NK_LITERAL
        return n.literal
    elseif k === _NK_STATE
        @inbounds return u[n.idx]
    elseif k === _NK_PARAM
        return getfield(p, n.sym)
    elseif k === _NK_TIME
        return t
    else
        return _eval_node_op(n, u, p, t)
    end
end

function _eval_node_op(n::_Node, u, p, t)
    op = n.op
    c = n.children

    # Arithmetic — the hot paths.
    if op === :+
        length(c) == 1 && return _eval_node(c[1], u, p, t)
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c)
            acc += _eval_node(c[i], u, p, t)
        end
        return acc
    elseif op === :*
        length(c) == 1 && return _eval_node(c[1], u, p, t)
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c)
            acc *= _eval_node(c[i], u, p, t)
        end
        return acc
    elseif op === :-
        if length(c) == 1
            return -_eval_node(c[1], u, p, t)
        elseif length(c) == 2
            return _eval_node(c[1], u, p, t) - _eval_node(c[2], u, p, t)
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "- expects 1 or 2 args"))
    elseif op === :neg
        # Canonical-form unary negation. `canonicalize` rewrites unary
        # `-x` to `neg(x)`, so any AST that has been through `discretize`
        # may carry `neg` ops where the source had `-x`.
        _expect_arity_n(op, c, 1)
        return -_eval_node(c[1], u, p, t)
    elseif op === :/
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) / _eval_node(c[2], u, p, t)
    elseif op === :^ || op === :pow
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) ^ _eval_node(c[2], u, p, t)

    # Comparisons → 1.0/0.0 (match `evaluate` semantics)
    elseif op === :<
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) <  _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol("<=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) <= _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === :>
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) >  _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol(">=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) >= _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol("==")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) == _eval_node(c[2], u, p, t) ? 1.0 : 0.0
    elseif op === Symbol("!=")
        _expect_arity_n(op, c, 2)
        return _eval_node(c[1], u, p, t) != _eval_node(c[2], u, p, t) ? 1.0 : 0.0

    # Logical
    elseif op === :and
        for child in c
            _eval_node(child, u, p, t) == 0 && return 0.0
        end
        return 1.0
    elseif op === :or
        for child in c
            _eval_node(child, u, p, t) != 0 && return 1.0
        end
        return 0.0
    elseif op === :not
        _expect_arity_n(op, c, 1)
        return _eval_node(c[1], u, p, t) == 0 ? 1.0 : 0.0

    elseif op === :ifelse
        _expect_arity_n(op, c, 3)
        return _eval_node(c[1], u, p, t) != 0 ?
               _eval_node(c[2], u, p, t) :
               _eval_node(c[3], u, p, t)

    # Elementary functions
    elseif op === :sin;   _expect_arity_n(op, c, 1); return sin(_eval_node(c[1], u, p, t))
    elseif op === :cos;   _expect_arity_n(op, c, 1); return cos(_eval_node(c[1], u, p, t))
    elseif op === :tan;   _expect_arity_n(op, c, 1); return tan(_eval_node(c[1], u, p, t))
    elseif op === :asin;  _expect_arity_n(op, c, 1); return asin(_eval_node(c[1], u, p, t))
    elseif op === :acos;  _expect_arity_n(op, c, 1); return acos(_eval_node(c[1], u, p, t))
    elseif op === :atan
        if length(c) == 1
            return atan(_eval_node(c[1], u, p, t))
        elseif length(c) == 2
            return atan(_eval_node(c[1], u, p, t), _eval_node(c[2], u, p, t))
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "atan expects 1 or 2 args"))
    elseif op === :atan2
        _expect_arity_n(op, c, 2)
        return atan(_eval_node(c[1], u, p, t), _eval_node(c[2], u, p, t))
    elseif op === :exp;   _expect_arity_n(op, c, 1); return exp(_eval_node(c[1], u, p, t))
    elseif op === :log;   _expect_arity_n(op, c, 1); return log(_eval_node(c[1], u, p, t))
    elseif op === :log10; _expect_arity_n(op, c, 1); return log10(_eval_node(c[1], u, p, t))
    elseif op === :sqrt;  _expect_arity_n(op, c, 1); return sqrt(_eval_node(c[1], u, p, t))
    elseif op === :abs;   _expect_arity_n(op, c, 1); return abs(_eval_node(c[1], u, p, t))
    elseif op === :sign;  _expect_arity_n(op, c, 1); return sign(_eval_node(c[1], u, p, t))
    elseif op === :floor; _expect_arity_n(op, c, 1); return floor(_eval_node(c[1], u, p, t))
    elseif op === :ceil;  _expect_arity_n(op, c, 1); return ceil(_eval_node(c[1], u, p, t))
    elseif op === :min
        # n-ary min (esm-spec §4.2 — arity ≥ 2)
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "min needs ≥2 args"))
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c); acc = min(acc, _eval_node(c[i], u, p, t)); end
        return acc
    elseif op === :max
        # n-ary max (esm-spec §4.2 — arity ≥ 2)
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "max needs ≥2 args"))
        acc = _eval_node(c[1], u, p, t)
        @inbounds for i in 2:length(c); acc = max(acc, _eval_node(c[i], u, p, t)); end
        return acc

    elseif op === :pi || op === :π
        return Float64(pi)
    elseif op === :e
        return Float64(ℯ)

    elseif op === :Pre
        _expect_arity_n(op, c, 1)
        return _eval_node(c[1], u, p, t)

    elseif op === :fn
        # `n.handler` is `(fname::String, const_args_or_nothing)`. The
        # tuple's second slot is `nothing` for closed functions whose args
        # are all scalar (e.g. `datetime.*`). For closed functions with
        # const-array args (`interp.searchsorted`, `interp.linear`,
        # `interp.bilinear`) it is a `Vector{Any}` carrying the pre-extracted
        # arrays in spec arg-position order; the remaining scalar args are
        # the node's children, also in spec order.
        fname, const_args = n.handler::Tuple{String,Any}
        if const_args === nothing
            args_evaluated = Any[_eval_node(ci, u, p, t) for ci in c]
            return Float64(evaluate_closed_function(fname, args_evaluated))
        elseif fname == "interp.searchsorted"
            # Spec arg order: (x, xs); xs is const, x is the only child.
            x = _eval_node(c[1], u, p, t)
            return Float64(evaluate_closed_function(fname, Any[x, const_args[1]]))
        elseif fname == "interp.linear"
            # Spec arg order: (table, axis, x); table & axis are const; x is the only child.
            x = _eval_node(c[1], u, p, t)
            return Float64(evaluate_closed_function(fname,
                Any[const_args[1], const_args[2], x]))
        elseif fname == "interp.bilinear"
            # Spec arg order: (table, axis_x, axis_y, x, y); first three are
            # const; x and y are children in order.
            x = _eval_node(c[1], u, p, t)
            y = _eval_node(c[2], u, p, t)
            return Float64(evaluate_closed_function(fname,
                Any[const_args[1], const_args[2], const_args[3], x, y]))
        end

    else
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP", String(op)))
    end
end

@inline function _require_const_array(arg, fname::String, arg_label::String)
    if arg isa OpExpr && arg.op == "const" && arg.value isa AbstractVector
        return arg.value
    end
    throw(TreeWalkError("E_TREEWALK_FN_ARG_NOT_CONST",
        "$(fname): `$(arg_label)` argument must be a `const`-op array node"))
end

@inline function _expect_arity_n(op::Symbol, c::Vector{_Node}, n::Int)
    length(c) == n ||
        throw(TreeWalkError("E_TREEWALK_ARITY",
                            "$op expects $n args, got $(length(c))"))
    return nothing
end

# Inner closure generator — separated so the closure's body is small
# enough to stay inferable. `rhs_list` is captured by the closure;
# Julia specializes the generated method to the captured types.
# Accepts any AbstractVector so both the pre-allocated and the
# dynamically-grown forms produced by build_evaluator work.
function _make_rhs(rhs_list::AbstractVector{Tuple{Int,_Node}})
    function f!(du, u, p, t)
        @inbounds for k in 1:length(rhs_list)
            idx_and_node = rhs_list[k]
            du[idx_and_node[1]] = _eval_node(idx_and_node[2], u, p, t)
        end
        return nothing
    end
    return f!
end

# ============================================================
# 5. Misc helpers
# ============================================================

function _is_time_derivative_lhs(lhs)
    return isa(lhs, OpExpr) && lhs.op == "D" && lhs.wrt == "t" &&
           length(lhs.args) == 1
end

# _is_scalar_D_lhs is defined in the array helpers section (5b).

function _equation_tag(eq::Equation)
    if eq._comment !== nothing
        return eq._comment
    end
    return string(typeof(eq.lhs))
end

# Variable substitution that preserves every OpExpr field — the
# package-level `substitute` only carries `wrt`/`dim` and drops
# `handler_id`, `fn`, etc., which would corrupt `call`/`broadcast`
# nodes on their way through. Scoped here because this module is the
# only caller that needs the full preservation.
function _sub_preserving(expr::NumExpr, bindings::Dict{String,Expr})
    return expr
end
function _sub_preserving(expr::IntExpr, bindings::Dict{String,Expr})
    return expr
end
function _sub_preserving(expr::VarExpr, bindings::Dict{String,Expr})
    return get(bindings, expr.name, expr)
end
function _sub_preserving(expr::OpExpr, bindings::Dict{String,Expr})
    new_args = Expr[_sub_preserving(a, bindings) for a in expr.args]
    new_body = expr.expr_body === nothing ?
               nothing : _sub_preserving(expr.expr_body, bindings)
    new_values = expr.values === nothing ?
                 nothing : Expr[_sub_preserving(v, bindings) for v in expr.values]
    return OpExpr(expr.op, new_args;
                  wrt=expr.wrt, dim=expr.dim,
                  output_idx=expr.output_idx, expr_body=new_body,
                  reduce=expr.reduce, ranges=expr.ranges,
                  regions=expr.regions, values=new_values,
                  shape=expr.shape, perm=expr.perm, axis=expr.axis,
                  fn=expr.fn, name=expr.name, value=expr.value)
end

# Resolve observed-into-observed substitutions to a fixed point. After
# this runs, no RHS in the returned dict contains another observed
# variable as a free variable — so inlining observed names into a
# model equation is a single `_sub_preserving` call. Iteration cap =
# depth of the longest valid chain; exceeding it means there's a cycle.
function _resolve_observed(obs::Dict{String,Expr})
    resolved = Dict{String,Expr}()
    for (k, v) in obs
        resolved[k] = v
    end
    names = Set(keys(obs))
    # Max chain depth before we call it a cycle. One pass per observer
    # is always enough to collapse any acyclic chain.
    for _ in 1:(length(obs) + 1)
        any_change = false
        for (k, v) in resolved
            fv = free_variables(v)
            if any(n -> n in names, fv)
                resolved[k] = _sub_preserving(v, resolved)
                any_change = true
            end
        end
        any_change || return resolved
    end
    throw(TreeWalkError("E_TREEWALK_OBSERVED_CYCLE",
                        join(sort(collect(keys(obs))), ",")))
end

function _pick_tspan(tspan, model::Model)
    tspan === nothing || return (Float64(tspan[1]), Float64(tspan[2]))
    if !isempty(model.tests)
        ts = model.tests[1].time_span
        return (Float64(ts.start), Float64(ts.stop))
    end
    return (0.0, 1.0)
end

# ============================================================
# 5b. Array-variable helpers (arrayop evaluation support)
# ============================================================

# Format an array-cell key like "u[3]" (1D) or "u[2,3]" (2D).
function _cell_key(var_name::String, indices)
    return "$(var_name)[$(join(indices, ","))]"
end

# Expand a ranges entry to the concrete list of integer values.
# `r` is [lo, hi] or [lo, step, hi].
function _expand_int_range(r::Vector{Int})
    length(r) == 2 && return r[1]:r[2]
    length(r) == 3 && return r[1]:r[2]:r[3]
    throw(TreeWalkError("E_TREEWALK_RANGE_ARITY",
          "range entry must have 2 or 3 entries, got $(length(r))"))
end

# Evaluate a purely-arithmetic expression (literals + idx_env bindings)
# to a concrete Int. Used to resolve index(u, i+1) after loop-var substitution.
function _eval_const_int(expr::NumExpr, idx_env::Dict{String,Int})
    return Int(expr.value)
end
function _eval_const_int(expr::IntExpr, idx_env::Dict{String,Int})
    return expr.value
end
function _eval_const_int(expr::VarExpr, idx_env::Dict{String,Int})
    haskey(idx_env, expr.name) ||
        throw(TreeWalkError("E_TREEWALK_UNBOUND_LOOP_VAR", expr.name))
    return idx_env[expr.name]
end
function _eval_const_int(expr::OpExpr, idx_env::Dict{String,Int})
    op = expr.op
    c = expr.args
    if op == "+"
        return sum(_eval_const_int(a, idx_env) for a in c)
    elseif op == "-"
        length(c) == 1 && return -_eval_const_int(c[1], idx_env)
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "- in index needs 1-2 args"))
        return _eval_const_int(c[1], idx_env) - _eval_const_int(c[2], idx_env)
    elseif op == "*"
        return prod(_eval_const_int(a, idx_env) for a in c)
    elseif op == "/"
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "/ in index needs 2 args"))
        return div(_eval_const_int(c[1], idx_env), _eval_const_int(c[2], idx_env))
    elseif op == "ifelse"
        length(c) == 3 || throw(TreeWalkError("E_TREEWALK_ARITY", "ifelse in index needs 3 args"))
        cond = _eval_const_int(c[1], idx_env)
        return cond != 0 ? _eval_const_int(c[2], idx_env) : _eval_const_int(c[3], idx_env)
    elseif op == "<"
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "< needs 2 args"))
        return _eval_const_int(c[1], idx_env) < _eval_const_int(c[2], idx_env) ? 1 : 0
    elseif op == "<="
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "<= needs 2 args"))
        return _eval_const_int(c[1], idx_env) <= _eval_const_int(c[2], idx_env) ? 1 : 0
    elseif op == ">"
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "> needs 2 args"))
        return _eval_const_int(c[1], idx_env) > _eval_const_int(c[2], idx_env) ? 1 : 0
    elseif op == ">="
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", ">= needs 2 args"))
        return _eval_const_int(c[1], idx_env) >= _eval_const_int(c[2], idx_env) ? 1 : 0
    elseif op == "=="
        length(c) == 2 || throw(TreeWalkError("E_TREEWALK_ARITY", "== needs 2 args"))
        return _eval_const_int(c[1], idx_env) == _eval_const_int(c[2], idx_env) ? 1 : 0
    elseif op == "neg"
        length(c) == 1 || throw(TreeWalkError("E_TREEWALK_ARITY", "neg needs 1 arg"))
        return -_eval_const_int(c[1], idx_env)
    end
    throw(TreeWalkError("E_TREEWALK_INDEX_NOT_CONST",
          "cannot evaluate '$(op)' as a constant integer index"))
end

# Replace index(var, k1, k2, ...) nodes:
#   - In-bounds → VarExpr(cell_key) referencing the flat state slot.
#   - Out-of-bounds → NumExpr(0.0) (ghost-cell convention).
# array_var_info: var_name → (lo::Vector{Int}, hi::Vector{Int})
function _resolve_indices(expr::NumExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int})
    return expr
end
function _resolve_indices(expr::IntExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int})
    return expr
end
function _resolve_indices(expr::VarExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int})
    return expr
end
function _resolve_indices(expr::OpExpr,
                          array_var_info::Dict{String,Tuple{Vector{Int},Vector{Int}}},
                          var_map::Dict{String,Int})
    if expr.op == "index"
        isempty(expr.args) &&
            throw(TreeWalkError("E_TREEWALK_INDEX_EMPTY", "index op requires at least one arg"))
        first_arg = expr.args[1]
        if first_arg isa VarExpr && haskey(array_var_info, first_arg.name)
            vname = first_arg.name
            lo, hi = array_var_info[vname]
            idx_args = expr.args[2:end]
            length(idx_args) == length(lo) ||
                throw(TreeWalkError("E_TREEWALK_INDEX_NDIM",
                      "$(vname) has $(length(lo))D but got $(length(idx_args)) index args"))
            indices = [_eval_const_int(a, Dict{String,Int}()) for a in idx_args]
            for d in 1:length(indices)
                if indices[d] < lo[d] || indices[d] > hi[d]
                    return NumExpr(0.0)  # ghost cell
                end
            end
            cname = _cell_key(vname, indices)
            haskey(var_map, cname) ||
                throw(TreeWalkError("E_TREEWALK_MISSING_CELL", cname))
            return VarExpr(cname)
        end
        # scalar or unknown variable inside index — recurse on sub-exprs only
        new_args = Expr[_resolve_indices(a, array_var_info, var_map) for a in expr.args]
        return OpExpr(expr.op, new_args;
                      wrt=expr.wrt, dim=expr.dim, int_var=expr.int_var,
                      lower=expr.lower, upper=expr.upper,
                      output_idx=expr.output_idx, expr_body=expr.expr_body,
                      reduce=expr.reduce, ranges=expr.ranges,
                      regions=expr.regions, values=expr.values,
                      shape=expr.shape, perm=expr.perm, axis=expr.axis,
                      fn=expr.fn, name=expr.name, value=expr.value)
    end
    new_args = Expr[_resolve_indices(a, array_var_info, var_map) for a in expr.args]
    new_body = expr.expr_body === nothing ? nothing :
               _resolve_indices(expr.expr_body, array_var_info, var_map)
    new_values = expr.values === nothing ? nothing :
                 Expr[_resolve_indices(v, array_var_info, var_map) for v in expr.values]
    return OpExpr(expr.op, new_args;
                  wrt=expr.wrt, dim=expr.dim, int_var=expr.int_var,
                  lower=expr.lower, upper=expr.upper,
                  output_idx=expr.output_idx, expr_body=new_body,
                  reduce=expr.reduce, ranges=expr.ranges,
                  regions=expr.regions, values=new_values,
                  shape=expr.shape, perm=expr.perm, axis=expr.axis,
                  fn=expr.fn, name=expr.name, value=expr.value)
end

# Detect which state variables are used in array context (inside index ops)
# by scanning equation LHS patterns and initial_condition keys.
function _detect_array_vars(equations::Vector{Equation},
                             state_var_names::Set{String},
                             initial_conditions::AbstractDict)
    detected = Set{String}()
    # From initial conditions: "u[3]" style keys imply array usage.
    for (key, _) in initial_conditions
        skey = String(key)
        m = match(r"^([^\[]+)\[([0-9,]+)\]$", skey)
        m === nothing && continue
        vname = m.captures[1]
        vname in state_var_names && push!(detected, vname)
    end
    # From equation LHS patterns.
    for eq in equations
        lhs = eq.lhs
        if _is_indexed_D_lhs(lhs)
            inner = (lhs::OpExpr).args[1]::OpExpr
            first_arg = inner.args[1]
            if first_arg isa VarExpr && first_arg.name in state_var_names
                push!(detected, first_arg.name)
            end
        elseif lhs isa OpExpr && lhs.op == "arrayop"
            body = lhs.expr_body
            if body isa OpExpr && body.op == "D" && !isempty(body.args)
                inner = body.args[1]
                if inner isa OpExpr && inner.op == "index" && !isempty(inner.args)
                    fa = inner.args[1]
                    if fa isa VarExpr && fa.name in state_var_names
                        push!(detected, fa.name)
                    end
                end
            end
        end
    end
    return detected
end

# Scan equations and initial_conditions to discover all array cells.
# Returns Dict{String, Vector{Vector{Int}}} — var_name → sorted list of index tuples.
function _discover_array_cells(
        equations::Vector{Equation},
        initial_conditions::AbstractDict,
        array_var_names::Set{String})
    cells = Dict{String, Set{Vector{Int}}}()

    # From initial conditions: parse "u[3]" or "u[2,3]" style keys.
    for (key, _) in initial_conditions
        skey = String(key)
        m = match(r"^([^\[]+)\[([0-9,]+)\]$", skey)
        m === nothing && continue
        vname = m.captures[1]
        vname in array_var_names || continue
        indices = parse.(Int, split(m.captures[2], ","))
        if !haskey(cells, vname); cells[vname] = Set{Vector{Int}}(); end
        push!(cells[vname], indices)
    end

    # From equation LHS.
    for eq in equations
        _scan_lhs_cells!(cells, eq.lhs, array_var_names)
    end

    # Sort each var's cells and return as Vector{Vector{Int}}.
    return Dict{String, Vector{Vector{Int}}}(
        vname => sort(collect(cset)) for (vname, cset) in cells)
end

function _scan_lhs_cells!(cells, lhs::Expr, array_var_names::Set{String})
    if lhs isa OpExpr && lhs.op == "D" && lhs.wrt == "t" &&
           length(lhs.args) == 1 && lhs.args[1] isa OpExpr &&
           lhs.args[1].op == "index"
        # D(index(var, k...))
        inner = lhs.args[1]
        first_arg = inner.args[1]
        first_arg isa VarExpr || return
        first_arg.name in array_var_names || return
        idx_args = inner.args[2:end]
        try
            indices = [_eval_const_int(a, Dict{String,Int}()) for a in idx_args]
            vname = first_arg.name
            if !haskey(cells, vname); cells[vname] = Set{Vector{Int}}(); end
            push!(cells[vname], indices)
        catch; end
        return
    end
    if lhs isa OpExpr && lhs.op == "arrayop"
        # arrayop(expr=D(index(var, idx_exprs...)), output_idx=[...], ranges={...})
        lhs_body = lhs.expr_body
        lhs_body === nothing && return
        lhs_body isa OpExpr && lhs_body.op == "D" && lhs_body.wrt == "t" &&
            length(lhs_body.args) == 1 && lhs_body.args[1] isa OpExpr &&
            lhs_body.args[1].op == "index" || return
        inner = lhs_body.args[1]
        first_arg = inner.args[1]
        first_arg isa VarExpr || return
        first_arg.name in array_var_names || return
        vname = first_arg.name

        idx_names = String[]
        for sym in (lhs.output_idx === nothing ? Any[] : lhs.output_idx)
            (sym isa String || sym isa AbstractString) && push!(idx_names, String(sym))
        end
        ranges_dict = lhs.ranges === nothing ? Dict{String,Vector{Int}}() : lhs.ranges
        range_iters = [collect(_expand_int_range(ranges_dict[n])) for n in idx_names]

        if !haskey(cells, vname); cells[vname] = Set{Vector{Int}}(); end
        idx_args = inner.args[2:end]
        try
            for idx_tuple in Iterators.product(range_iters...)
                idx_env = Dict{String,Int}(idx_names[d] => idx_tuple[d]
                                           for d in 1:length(idx_names))
                indices = [_eval_const_int(a, idx_env) for a in idx_args]
                push!(cells[vname], indices)
            end
        catch; end
        return
    end
end

# Identify D(scalar_var) — the classic scalar ODE LHS.
function _is_scalar_D_lhs(lhs)
    return isa(lhs, OpExpr) && lhs.op == "D" && lhs.wrt == "t" &&
           length(lhs.args) == 1 && isa(lhs.args[1], VarExpr)
end

# Identify D(index(var, k...)) — indexed scalar derivative.
function _is_indexed_D_lhs(lhs)
    return isa(lhs, OpExpr) && lhs.op == "D" && lhs.wrt == "t" &&
           length(lhs.args) == 1 &&
           isa(lhs.args[1], OpExpr) && lhs.args[1].op == "index"
end

# Identify arrayop(D(index(var, ...)), ...) — array-loop derivative LHS.
function _is_arrayop_D_lhs(lhs)
    lhs isa OpExpr && lhs.op == "arrayop" || return false
    body = lhs.expr_body
    body === nothing && return false
    return body isa OpExpr && body.op == "D" && body.wrt == "t" &&
           length(body.args) == 1 &&
           body.args[1] isa OpExpr && body.args[1].op == "index"
end

# Extract the scalar body from an arrayop node (or return expr unchanged).
# Used to unwrap the RHS of an arrayop equation.
function _extract_arrayop_body(expr::Expr)
    if expr isa OpExpr && expr.op == "arrayop"
        expr.expr_body !== nothing && return expr.expr_body
    end
    return expr
end

function _select_model(file::EsmFile, name::Union{Nothing,AbstractString})
    file.models === nothing &&
        throw(TreeWalkError("E_TREEWALK_NO_MODEL", "EsmFile.models is nothing"))
    models = file.models
    if name !== nothing
        haskey(models, String(name)) ||
            throw(TreeWalkError("E_TREEWALK_NO_MODEL", String(name)))
        return models[String(name)]
    end
    length(models) == 1 ||
        throw(TreeWalkError("E_TREEWALK_AMBIGUOUS_MODEL",
                            "specify model_name; have: " *
                            join(collect(keys(models)), ", ")))
    return first(values(models))
end
