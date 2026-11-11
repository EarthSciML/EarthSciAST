"""
Build-time value-invention front door
(RFC semiring-faq-unified-ir §6.1 cadence-partition / §5.5 / §7.3).

Sizes what the index-set resolver would otherwise refuse with
`derived_index_set_unmaterialized` (tree_walk/resolve.jl). A
`kind:"derived"` index set whose `from_faq` names a `distinct` producer is
materialised here, ONCE at setup, off the per-step hot path — the §6.1
CONST/DISCRETE materialisation point. The producer's integer keys are evaluated
over the build-time const-array factors and run through the `Relational` engine
(distinct / equijoin, §5.5 determinism); the distinct set's cardinality is
handed to the tree-walk index-set resolver as the dense extent `[1, n]`.

The pass runs on the TYPED IR (`Model` / `ASTExpr`): `OpExpr` carries the full
value-invention vocabulary (`id`, `distinct`, `key`, `join`, `ranges` — see
`OPEXPR_FIELD_TABLE`, types.jl), so no raw-JSON walking is
needed. The document-scoped index-set registry is passed alongside the model
(esm-spec v0.8.0: `EsmFile.index_sets`), since a typed `Model` does not carry
it. The cadence classification the §5.7 guard-2 checks need is derived here
directly on the typed tree (`_vi_class`); the raw-JSON `Cadence` module remains
only for the conformance fixtures, whose whole-document surroundings
(`data_sources`, `index_sets`) never reach a typed expression. The
`expect_cadence` annotation those fixtures assert against IS carried by the
typed IR; it is simply not consulted here, because this classifier DERIVES a
class rather than checking a declaration.

All diagnostics are raised as [`TreeWalkError`](@ref) carrying stable
`E_TREEWALK_*` codes (`E_TREEWALK_VI_*` for the value-invention-specific
failures) so they are machine-checkable across bindings.
"""

# Base variable name of a typed-IR LHS (`VarExpr` / `index` / `D`), used by
# build_evaluator to drop value-invention equations from the ODE and by
# `_vi_detect` below.
function _vi_typed_lhs_base(expr)
    expr isa VarExpr && return expr.name
    if expr isa OpExpr && (expr.op == "index" || expr.op == "D")
        isempty(expr.args) || return _vi_typed_lhs_base(expr.args[1])
    end
    return nothing
end

# The aggregate's `ranges` map, empty when absent.
_vi_ranges(node::OpExpr) = node.ranges === nothing ? Dict{String, Any}() : node.ranges

"""
    _vi_node_kind(node) -> Symbol

Classify a typed aggregate node's value-invention role:

- `:producer` — `distinct:true` (an index-set-producing aggregate; materialises a
  derived index set via `from_faq`).
- `:none`     — an ordinary numeric aggregate.
"""
function _vi_node_kind(node)
    node isa OpExpr || return :none
    node.op == "faq" || return :none
    node.distinct === true && return :producer
    return :none
end

# Every (lhs, rhs) value-expression pair in a typed model. From esm 1.0.0 that
# is exactly the equation list: an observed unknown's defining right-hand side
# IS an equation, so there is no variable-level `expression` to append.
_vi_model_assignments(model::Model) =
    Tuple{Any, ASTExpr}[(eq.lhs, eq.rhs) for eq in model.equations]

# Every `index` target name reachable in a sub-tree (the array a value reads
# from): `index(NAME, …)` → NAME. Walks EVERY expression-bearing `OpExpr` field
# via the generated `foreach_subexpr` walker (expression.jl).
function _vi_index_targets!(refs, node)
    node isa ASTExpr || return refs
    foreach_subexpr(node) do n
        if n isa OpExpr && n.op == "index" && !isempty(n.args) && n.args[1] isa VarExpr
            push!(refs, n.args[1].name)
        end
        nothing
    end
    return refs
end

# The set of `index(NAME, …)` target names read by any value-invention aggregate
# (a `:producer` or a join column it gates on). These are the buffers a
# value-invention key GATHERS from at build time — the coordinate buffers a
# binned broad phase bins on (`src_lon`/`tgt_lon`). Used by the build-time
# binning-coordinate derivation to decide which build-time-constant coordinate
# observeds to materialise into the value-invention `const_arrays` so
# `index(src_lon,i)` resolves (RFC §8.6.1). Empty (byte-identical) for a model
# without value invention.
function _vi_index_targets(model::Model)
    det = _vi_detect(model)
    refs = Set{String}()
    for (_, node) in det.producers
        _vi_index_targets!(refs, node)
    end
    for (_, node) in det.columns
        _vi_index_targets!(refs, node)
    end
    return refs
end

"""
    _vi_detect(model::Model) -> (has_vi, vi_var_names, producers, columns)

Scan a typed model for value-invention assignments. `vi_var_names` is the set of
LHS variables produced by `distinct` producers — excluded from the ODE state.
`producers` are `(lhs, node)` pairs to materialise.

`columns` are the plain per-element `faq`s (one output index) a producer's
`join` names as a key column: the per-component integer bin columns of a
lib/relational.esm key (`src_bx[i] = floor(lon[i] / dx)`). They are materialised
for the join but are NOT value-invention outputs: they stay ordinary observeds
of the ODE.
"""
function _vi_detect(model::Model)
    vi_var_names = Set{String}()
    producers = Tuple{String, OpExpr}[]
    candidates = Tuple{String, OpExpr}[]   # plain numeric aggregates — join columns?
    for (lhs, rhs) in _vi_model_assignments(model)
        base = lhs isa AbstractString ? String(lhs) : _vi_typed_lhs_base(lhs)
        base === nothing && continue
        kind = _vi_node_kind(rhs)
        if kind == :none
            rhs isa OpExpr && rhs.op == "faq" && push!(candidates, (base, rhs))
            continue
        end
        push!(vi_var_names, base)   # every value-invention output leaves the ODE
        push!(producers, (base, rhs))
    end
    join_names = Set{String}()
    for (_, node) in producers
        _vi_join_on_names!(join_names, node.join)
    end
    columns = Tuple{String, OpExpr}[
        (base, node) for (base, node) in candidates
            if base in join_names && node.output_idx !== nothing && length(node.output_idx) == 1
    ]
    has_vi = !isempty(producers)
    return (
        has_vi = has_vi, vi_var_names = vi_var_names, producers = producers,
        columns = columns,
    )
end

# Every key-column name of a typed `join`'s bin-equality clauses (a vector of
# `(left, right)` pairs; an overlap clause names envelope factors, not columns).
function _vi_join_on_names!(out::Set{String}, join)
    join === nothing && return out
    for clause in join
        clause isa AbstractVector || continue
        for pair in clause
            length(pair) == 2 || continue
            push!(out, String(pair[1]), String(pair[2]))
        end
    end
    return out
end

# ---- Build-time evaluation context -----------------------------------------

struct _ViCtx
    const_arrays::Dict{String, Any}
    params::Dict{String, Float64}
    index_sets::Dict{String, IndexSet}
    variables::OrderedDict{String, ModelVariable}
    maps::Dict{String, Dict{Any, Any}}   # materialised join column → (output-index → value)
    # Per-name cadence SEED, derived once from the model (esm-spec §6.3.1 /
    # CONFORMANCE_SPEC §5.7.2). From esm 1.0.0 the seed cannot be read off a
    # declared type, so it is computed by `_vi_seed_map` and carried here rather
    # than re-derived at every leaf.
    seeds::Dict{String, Int}
end

# Coerce a build-time numeric to an exact integer relational key component
# (CONFORMANCE_SPEC.md §5.5.1 rule 1: no floats in keys). A non-integral float is
# a misuse — fail loudly rather than emit a non-deterministic key.
function _vi_key_int(x)
    isa(x, Integer) && return Int(x)
    if isa(x, AbstractFloat)
        isinteger(x) || throw(
            TreeWalkError(
                "E_TREEWALK_VI_FLOAT_KEY",
                "value-invention key component $(repr(x)) is not integer-valued; relational " *
                    "keys must be integer / categorical IDs (CONFORMANCE_SPEC.md §5.5.1 rule 1)"
            )
        )
        return Int(x)
    end
    throw(TreeWalkError("E_TREEWALK_VI_KEY", "non-numeric key component $(repr(x))"))
end

# Resolve a scalar parameter value (dx/dy/atol …) from overrides-or-default.
function _vi_param(ctx::_ViCtx, name::AbstractString)
    # The sharpest structural read there is: a scalar parameter consumed HERE
    # decides an invented index set's EXTENT, i.e. `length(u)`. Record it (see
    # `_PARAM_READS`, build.jl) before resolving — override or default, either
    # way the value is baked into the materialized extent.
    _PARAM_READS[] === nothing || _record_param_read(name)
    haskey(ctx.params, name) && return ctx.params[name]
    v = get(ctx.variables, name, nothing)
    if v !== nothing && v.default !== nothing
        return Float64(v.default)
    end
    throw(
        TreeWalkError(
            "E_TREEWALK_VI_PARAM",
            "value-invention scalar parameter '$name' has no override or default"
        )
    )
end

# Evaluate a value-invention node that MUST reduce to a build-time number.
# `_vi_eval`'s `VarExpr` arm 4 returns an unresolved bare name verbatim; it has
# NO legitimate value context. Guard arithmetic / index contexts so a
# typo'd range symbol, const-array factor, or scalar-parameter name fails closed
# with a structured code instead of an opaque `Float64("…")` / `Int("…")`
# ArgumentError.
function _vi_num(node, ctx::_ViCtx, bindings::AbstractDict)
    v = _vi_eval(node, ctx, bindings)
    isa(v, Real) && return v
    throw(
        TreeWalkError(
            "E_TREEWALK_VI_SYMBOL",
            "value-invention expression requires a build-time number here but got " *
                "$(repr(v)); an unresolved name (range symbol, const-array factor, or " *
                "scalar parameter)"
        )
    )
end

# Evaluate a typed value-invention sub-expression. Returns an Int / Float64 /
# Bool / unresolved name, depending on the op. Exact-integer semantics
# are pinned by the M3 determinism goldens: an `IntExpr` yields an `Int`, a
# `NumExpr` a `Float64` (the typed parser already canonicalises an
# integral-spelled JSON number to `IntExpr`, matching `_vi_key_int`'s exact
# coercion).
function _vi_eval(node, ctx::_ViCtx, bindings::AbstractDict)
    if node isa IntExpr
        return Int(node.value)
    elseif node isa NumExpr
        return Float64(node.value)
    elseif node isa VarExpr
        # Four-way bare-name resolution, in precedence order:
        #   1. a bound range symbol (the enumeration binding wins);
        #   2. a const-array factor name — returned AS the name; only `index`
        #      consumes it, gathering from `ctx.const_arrays`;
        #   3. a scalar `parameter` variable — its override-or-default value;
        #   4. FALLTHROUGH: an unresolved name, returned verbatim. It has NO
        #      legitimate value context.
        # Every downstream context fails closed on such a string: `_vi_num` guards
        # the arithmetic and index arms and `_vi_key_int` guards keys, each
        # raising a structured E_TREEWALK_VI_* code rather than an opaque cast
        # error.
        name = node.name
        haskey(bindings, name) && return bindings[name]   # bound range symbol
        haskey(ctx.const_arrays, name) && return name     # bare factor name (used by index)
        v = get(ctx.variables, name, nothing)
        v !== nothing && v.type == ParameterVariable &&
            return _vi_param(ctx, name)                    # scalar parameter
        return name                                        # unresolved name (fails closed downstream)
    elseif node isa OpExpr
        op = node.op
        args = node.args
        if op == "index"
            return _vi_index(node, ctx, bindings)
        elseif op == "true"
            return true
        elseif op == "false"
            return false
        elseif op == "floor" || op == "ceil"
            return _vi_round(op == "floor" ? floor : ceil, Float64(_vi_num(args[1], ctx, bindings)))
        elseif op == "const"
            v = node.value
            v isa Real || throw(
                TreeWalkError(
                    "E_TREEWALK_VI_OP",
                    "an array `const` is not a value-invention build-time scalar"
                )
            )
            return Float64(v)
        elseif op == "ifelse"
            c = _vi_eval(args[1], ctx, bindings)
            return _vi_eval(_vi_truthy(c) ? args[2] : args[3], ctx, bindings)
        elseif op == "and"
            return all(a -> _vi_truthy(_vi_eval(a, ctx, bindings)), args)
        elseif op == "or"
            return any(a -> _vi_truthy(_vi_eval(a, ctx, bindings)), args)
        elseif op == "not"
            return !_vi_truthy(_vi_eval(args[1], ctx, bindings))
        elseif op == "min" || op == "max"
            # NaN propagates (esm-spec §4.2), as Base `min`/`max` already do on floats.
            vals = Float64[Float64(_vi_num(a, ctx, bindings)) for a in args]
            return op == "min" ? minimum(vals) : maximum(vals)
        elseif op == "/"
            return Float64(_vi_num(args[1], ctx, bindings)) / Float64(_vi_num(args[2], ctx, bindings))
        elseif op == "*"
            return prod(Float64(_vi_num(a, ctx, bindings)) for a in args)
        elseif op == "+"
            return sum(Float64(_vi_num(a, ctx, bindings)) for a in args)
        elseif op == "-"
            return length(args) == 1 ? -Float64(_vi_num(args[1], ctx, bindings)) :
                Float64(_vi_num(args[1], ctx, bindings)) - Float64(_vi_num(args[2], ctx, bindings))
        elseif op in ("<", ">", "<=", ">=", "==", "!=")
            a = Float64(_vi_num(args[1], ctx, bindings))
            b = Float64(_vi_num(args[2], ctx, bindings))
            op == "<"  && return a < b
            op == ">"  && return a > b
            op == "<=" && return a <= b
            op == ">=" && return a >= b
            op == "==" && return a == b
            return a != b
        end
        throw(
            TreeWalkError(
                "E_TREEWALK_VI_OP",
                "value-invention build-time evaluator does not support op '$op'"
            )
        )
    end
    throw(TreeWalkError("E_TREEWALK_VI_NODE", "unevaluable value-invention node $(repr(node))"))
end

# `floor`/`ceil` to an exact integer; a non-finite value (a NaN component of a
# key template) stays a float so the key test downstream can name it.
_vi_round(f, x::Float64) = isfinite(x) ? f(Int, x) : x

# A build-time condition value: a Bool, or a number > 0 (NaN is false).
_vi_truthy(v) = v isa Bool ? v : (v isa Real ? v > 0 : _vi_num_fail(v))
_vi_num_fail(v) = throw(
    TreeWalkError(
        "E_TREEWALK_VI_SYMBOL",
        "value-invention expression requires a build-time number here but got $(repr(v))"
    )
)

# A `distinct` key or `join` column value: an expression's exact integer (a
# lib/relational.esm `pair_key`/`edge_key`, a bare `index`, `floor(...)`).
# `column` names the value for the diagnostic.
function _vi_key(node, ctx::_ViCtx, bindings::AbstractDict, column::AbstractString)
    return _vi_key_checked(_vi_eval(node, ctx, bindings), column, bindings)
end

# A NaN key — a key template's out-of-range, non-integral or NaN component — is
# `value_invention_key_out_of_range` naming the column and the loop indices
# (esm-spec §9.6.6); any other value must be an exact integer (`_vi_key_int`).
function _vi_key_checked(v, column::AbstractString, bindings::AbstractDict)
    if v isa AbstractFloat && isnan(v)
        at = join(("$k=$(bindings[k])" for k in sort!(collect(String, keys(bindings)))), ", ")
        throw(
            TreeWalkError(
                ERROR_CODES.VALUE_INVENTION_KEY_OUT_OF_RANGE,
                "$column is NaN at ($at); a key component is outside its declared " *
                    "range, non-integral or NaN (esm-spec §9.6.6)"
            )
        )
    end
    return _vi_key_int(v)
end

# index(factor, i, …): gather from a const-array factor (1-based). The factor is
# build-time data supplied in `const_arrays`. A name that resolves to an already-
# materialised join column (in `ctx.maps`) is read from that buffer instead.
function _vi_index(node::OpExpr, ctx::_ViCtx, bindings::AbstractDict)
    args = node.args
    name = !isempty(args) && args[1] isa VarExpr ? args[1].name : nothing
    if name !== nothing && haskey(ctx.maps, name)
        length(args) == 2 || throw(
            TreeWalkError(
                "E_TREEWALK_VI_INDEX",
                "materialised value-invention buffer '$name' is a 1-D buffer; expected one " *
                    "index, got $(length(args) - 1)"
            )
        )
        idx = _vi_key_int(_vi_eval(args[2], ctx, bindings))
        haskey(ctx.maps[name], idx) || throw(
            TreeWalkError(
                "E_TREEWALK_VI_INDEX",
                "materialised value-invention buffer '$name' has no entry at index $idx"
            )
        )
        return ctx.maps[name][idx]
    end
    name !== nothing && haskey(ctx.const_arrays, name) ||
        throw(
        TreeWalkError(
            "E_TREEWALK_VI_INDEX",
            "value-invention index target '$(repr(name === nothing ? (isempty(args) ? nothing : args[1]) : name))' " *
                "must be a const-array factor or an already-materialised value-invention buffer"
        )
    )
    arr = ctx.const_arrays[name]
    idxs = Tuple(Int(_vi_num(a, ctx, bindings)) for a in args[2:end])
    # A factor carrying a declared per-dimension boundary policy resolves an
    # out-of-range gather declaratively (periodic-wrap / edge-extend), exactly
    # as the tree_walk const_array gather does (ess-gj4). Plain factors keep the
    # existing behavior, so genuine connectivity OOB still surfaces.
    if isa(arr, BoundedConstArray)
        ndims(arr) == length(idxs) ||
            throw(
            TreeWalkError(
                "E_TREEWALK_CONSTARRAY_NDIM",
                "const array '$(name)' is $(ndims(arr))D but got $(length(idxs)) indices"
            )
        )
        idxs = ntuple(
            d -> _resolve_const_index(arr, String(name), d, idxs[d], size(arr, d)),
            length(idxs)
        )
    end
    return arr[idxs...]
end

# ---- Range resolution ------------------------------------------------------

# The `of` parent symbols of a range spec (only an `IndexSetRef` declares them).
_vi_range_of(spec) = spec isa IndexSetRef ? spec.of : String[]

# Order range symbols so a ragged range's `of` parents precede it (a stable
# topological order over the per-symbol `of` dependency).
function _vi_order_syms(ranges)
    syms = collect(keys(ranges))
    ordered = String[]
    remaining = copy(syms)
    while !isempty(remaining)
        progressed = false
        for s in copy(remaining)
            of = _vi_range_of(ranges[s])
            if all(p -> p in ordered || !(p in syms), of)
                push!(ordered, s)
                deleteat!(remaining, findfirst(==(s), remaining))
                progressed = true
            end
        end
        progressed || throw(
            TreeWalkError(
                "E_TREEWALK_VI_RANGE_CYCLE",
                "value-invention ranges have a cyclic `of` dependency: $(remaining)"
            )
        )
    end
    return ordered
end

# The element values a range symbol binds to, given the current bindings.
# interval/categorical → 1-based positions, as the lazy range `1:n` (the driven
# walk narrows it without materialising it); ragged → the MEMBER values gathered
# from the set's `values` factor sliced by its `offsets` factor (so a range
# symbol over `face_vertices` binds to the vertex IDs of the parent face, §5.2).
function _vi_range_values(spec, ctx::_ViCtx, bindings::AbstractDict)
    spec isa IndexSetRef || throw(
        TreeWalkError(
            "E_TREEWALK_VI_RANGE",
            "value-invention range must reference a declared index set " *
                "(`{from: <name>}`); got $(repr(spec))"
        )
    )
    is = get(ctx.index_sets, spec.from, nothing)
    is === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_VI_RANGE",
            "value-invention range references undeclared index set '$(spec.from)'"
        )
    )
    if is.kind == "interval"
        return 1:Int(is.size)
    elseif is.kind == "categorical"
        return 1:length(is.members)
    elseif is.kind == "ragged"
        of = _vi_range_of(spec)
        isempty(of) && throw(
            TreeWalkError(
                "E_TREEWALK_VI_RANGE",
                "ragged value-invention range '$(spec.from)' needs an `of` parent"
            )
        )
        parent = Int(bindings[of[1]])
        for f in (is.offsets, is.values)
            haskey(ctx.const_arrays, f) || throw(
                TreeWalkError(
                    "E_TREEWALK_VI_INDEX",
                    "ragged keyed factor '$f' of index set '$(spec.from)' is not bound in " *
                        "const_arrays: it must be a constant factor (esm-spec §4.2)"
                )
            )
        end
        offs = ctx.const_arrays[is.offsets]
        vals = ctx.const_arrays[is.values]
        nmem = Int(offs[parent])
        return Any[_vi_key_int(vals[parent, l]) for l in 1:nmem]
    end
    throw(
        TreeWalkError(
            "E_TREEWALK_VI_RANGE",
            "value-invention range over index set kind '$(repr(is.kind))' is unsupported"
        )
    )
end

# Enumerate every full binding of an aggregate's `ranges`, calling `cb(bindings)`
# at each leaf (bindings is reused — copy if retained).
function _vi_enumerate(ranges, ctx::_ViCtx, cb)
    syms = _vi_order_syms(ranges)
    bindings = Dict{String, Any}()
    function rec(k)
        if k > length(syms)
            cb(bindings)
            return
        end
        s = syms[k]
        for v in _vi_range_values(ranges[s], ctx, bindings)
            bindings[s] = v
            rec(k + 1)
        end
        return delete!(bindings, s)
    end
    rec(1)
    return
end

# ---- Materialisation -------------------------------------------------------

# The declared shape of a join-referenced variable (index-set names).
function _vi_join_var_shape(vname, ctx::_ViCtx)
    v = get(ctx.variables, vname, nothing)
    v === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_VI_JOIN",
            "join references unknown variable '$(vname)'"
        )
    )
    return v.shape === nothing ? String[] : v.shape
end

# The index range symbol of a join-key variable within the producer's ranges:
# the producer range whose `from` equals the variable's (1-D) shape index set.
function _vi_join_index_sym(vname, producer_ranges, ctx::_ViCtx)
    shape = _vi_join_var_shape(vname, ctx)
    length(shape) == 1 || throw(
        TreeWalkError(
            "E_TREEWALK_VI_JOIN",
            "value-invention join key '$(vname)' must be a 1-D buffer; shape=$(shape)"
        )
    )
    return _vi_range_sym_for_set(shape[1], vname, producer_ranges)
end

# The range symbol an OVERLAP gate's env-factor list runs over. The list's
# length fixes every factor's rank (`_overlap_env_rank`, CONFORMANCE_SPEC
# §5.5.6): 2 or 4 names are 1-D columns, 1 name a `[pos, verts, coord]` ring
# stack. A factor's first axis is its position axis in every form, so the first
# factor's first shape index set names the range, as in the tree-walk's
# `_overlap_env_sym`.
function _vi_overlap_env_sym(env_names::AbstractVector, producer_ranges, ctx::_ViCtx)
    rank = _overlap_env_rank(length(env_names))
    rank === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_VI_JOIN",
            "value-invention overlap env must name 1 (a [pos, verts, coord] ring " *
                "stack), 2 (point [x, y]) or 4 (rect [xmin, ymin, xmax, ymax]) " *
                "factors; got $(length(env_names)) (CONFORMANCE_SPEC §5.5.6)"
        )
    )
    for f in env_names
        fname = String(f)
        shape = _vi_join_var_shape(fname, ctx)
        length(shape) == rank || throw(
            TreeWalkError(
                "E_TREEWALK_VI_JOIN",
                "value-invention overlap env factor '$(fname)' must be " *
                    (rank == 1 ? "a 1-D buffer" : "a [pos, verts, coord] 3-D ring stack") *
                    "; shape=$(shape)"
            )
        )
        haskey(ctx.const_arrays, fname) || throw(
            TreeWalkError(
                "E_TREEWALK_VI_JOIN",
                "value-invention overlap env factor '$(fname)' is not a const array: " *
                    "an envelope factor must be build-time const-array data when " *
                    "value invention runs (CONFORMANCE_SPEC §5.5.6)"
            )
        )
    end
    fname = String(env_names[1])
    return _vi_range_sym_for_set(_vi_join_var_shape(fname, ctx)[1], fname, producer_ranges)
end

# The producer range whose `from` is index set `target`.
function _vi_range_sym_for_set(target, vname, producer_ranges)
    for (sym, spec) in producer_ranges
        spec isa IndexSetRef && spec.from == target && return sym
    end
    throw(
        TreeWalkError(
            "E_TREEWALK_VI_JOIN",
            "no producer range binds the index set '$(target)' of join key '$(vname)'"
        )
    )
end

# One resolved value-invention join gate (built ONCE per producer, not per
# tuple). A bin-EQUALITY gate carries the two materialised column buffers
# (`map_l`/`map_r`) and admits iff the buffer values are equal; an OVERLAP gate
# (Phase 2a) carries `candidates`, the prebuilt broad-phase `(pos_l,pos_r)` set,
# and admits iff the binding's range positions are a member. A bin-equality
# gate may carry `candidates` too: its key-equality match pairs
# (`_vi_equality_candidates`), which only drive enumeration — admission still
# compares the buffers.
struct _ViJoinGate
    sym_l::String
    sym_r::String
    map_l::Union{Dict{Any, Any}, Nothing}
    map_r::Union{Dict{Any, Any}, Nothing}
    candidates::Union{_OverlapIndex, Nothing}
end

# Envelope vectors for a value-invention OVERLAP gate: look each env-factor name
# up in `ctx.const_arrays` and coerce to `(xmin,ymin,xmax,ymax)` 4-tuples (shared
# `_envelope_vectors_from_cols`: 4 names→rect, 2→point, 1→ring-AABB).
function _vi_env_vectors(env_names::AbstractVector, ctx::_ViCtx)
    cols = Any[ctx.const_arrays[String(n)] for n in env_names]
    return _envelope_vectors_from_cols(env_names, cols)
end

# Resolve an aggregate's `join` clauses into `_ViJoinGate`s ONCE (the candidate
# set / buffer bindings are shared across every contracted tuple). A
# `_OverlapJoinSpec` clause maps `src_env`→sym_l and `tgt_env`→sym_r via each
# first factor's first shape index set (`_vi_overlap_env_sym`; a 1-D column or
# a `[pos, verts, coord]` ring stack) and builds its candidate set from the
# const-array envelope factors.
function _vi_resolve_join(join, producer_ranges, ctx::_ViCtx)
    gates = _ViJoinGate[]
    for clause in join
        if clause isa _OverlapJoinSpec
            sym_l = _vi_overlap_env_sym(clause.src_env, producer_ranges, ctx)
            sym_r = _vi_overlap_env_sym(clause.tgt_env, producer_ranges, ctx)
            cands = _overlap_candidate_set(
                _vi_env_vectors(clause.src_env, ctx),
                _vi_env_vectors(clause.tgt_env, ctx);
                eps = clause.eps
            )
            push!(gates, _ViJoinGate(sym_l, sym_r, nothing, nothing, _OverlapIndex(cands)))
        else
            for pair in clause
                lname, rname = String(pair[1]), String(pair[2])
                ls = _vi_join_index_sym(lname, producer_ranges, ctx)
                rs = _vi_join_index_sym(rname, producer_ranges, ctx)
                ml, mr = ctx.maps[lname], ctx.maps[rname]
                cands = _vi_equality_candidates(ls, ml, rs, mr, producer_ranges, ctx)
                push!(gates, _ViJoinGate(ls, rs, ml, mr, cands))
            end
        end
    end
    return gates
end

# The key-equality match pairs of a bin-equality gate, as the drive index for
# `_vi_enumerate_join`, or `nothing` (the gate then filters the full product as
# before). Built only where the driven walk provably visits a subset of what
# the product visits and skips only tuples the gate rejects: both gated ranges
# are interval or categorical (their values are the positions `1:n`), and each
# buffer holds every one of those positions, so the product would never have
# raised a missing-key error the driven walk skips. Off with the plan's
# `join_on_gate`, the switch for every `on`-gate driver.
function _vi_equality_candidates(ls, ml, rs, mr, ranges, ctx::_ViCtx)
    (ls == rs || _join_on_gate_disabled()) && return nothing
    n_l = _vi_position_extent(get(ranges, ls, nothing), ctx)
    n_r = _vi_position_extent(get(ranges, rs, nothing), ctx)
    (n_l === nothing || n_r === nothing) && return nothing
    all(p -> haskey(ml, p), 1:n_l) || return nothing
    all(p -> haskey(mr, p), 1:n_r) || return nothing
    return _equality_match_index(1:n_l, p -> ml[p], 1:n_r, p -> mr[p])
end

# The size of a range whose values are the positions `1:n`, or `nothing`.
function _vi_position_extent(spec, ctx::_ViCtx)
    spec isa IndexSetRef || return nothing
    is = get(ctx.index_sets, spec.from, nothing)
    is === nothing && return nothing
    is.kind == "interval" && return Int(is.size)
    is.kind == "categorical" && return length(is.members)
    return nothing
end

# True iff every resolved join gate admits this binding (§5.3 / Phase 2a): a
# bin-equality gate compares materialised buffer values; an overlap gate tests
# membership of the `(pos_l,pos_r)` range positions in the broad-phase set.
function _vi_join_ok(gates::Vector{_ViJoinGate}, bindings::AbstractDict)
    for g in gates
        if g.map_l !== nothing
            g.map_l[bindings[g.sym_l]] == g.map_r[bindings[g.sym_r]] || return false
        else
            (bindings[g.sym_l], bindings[g.sym_r]) in g.candidates || return false
        end
    end
    return true
end

# Enumerate an aggregate's `ranges`, DRIVING from a gate's prebuilt candidate
# pairs when one carries them (Wall #1 fix): an OVERLAP gate's broad-phase set,
# or a bin-equality gate's key-equality matches (`_vi_equality_candidates`).
# Instead of walking the full product over every range and testing each tuple —
# O(∏ranges), e.g. O(N_query·N_cell) — the walk visits the ranges in the SAME
# topological order the full product does, and when it reaches the second of
# the two gated symbols (the first already bound), it enumerates only that
# binding's candidate partners. Cost drops to O(N_first + |candidates|) times
# the ungated ranges, in time and in allocation: an interval or categorical
# range is the lazy `1:n` (`_vi_range_values`), so the first gated symbol walks
# it without a list and the second's restriction costs O(its partners)
# (`_overlap_restrict` on a unit range).
#
# The DRIVE DECISION is `_overlap_drive_plan` (broad_phase.jl) — the same policy
# the dense-aggregate expansion applies (`_foreach_aggregate_term`); only the loop
# shape differs, because a value-invention range may be RAGGED and therefore
# resolvable only against its parent binding. A symbol whose restriction the
# planner cannot prove order-preserving enumerates its full range.
#
# The visited leaves are exactly the full product's, in the same order, minus
# tuples the gate rejects: the restriction is an ascending subsequence of the
# range. With NO drivable gate this is `_vi_enumerate` itself. The callback is
# identical in both paths and STILL applies the narrow `filter` and the full
# `_vi_join_ok` re-check downstream.
function _vi_enumerate_join(
        ranges, gates::Union{Vector{_ViJoinGate}, Nothing},
        ctx::_ViCtx, cb
    )
    counted = bindings -> (_VI_ENUM_VISITS[] += 1; cb(bindings))
    ov = _drivable_gate(gates)
    ov === nothing && return _vi_enumerate(ranges, ctx, counted)   # full product
    _vi_enumerate_driven(
        _vi_order_syms(ranges), ranges, ctx, Dict{String, Any}(), ov,
        counted
    )
    return
end

# The driven walk of `_vi_enumerate_join`, over `syms` in order, starting from
# `bindings` (which it restores on return).
function _vi_enumerate_driven(syms, ranges, ctx::_ViCtx, bindings::AbstractDict, ov, cb)
    function rec(k)
        if k > length(syms)
            cb(bindings)
            return
        end
        s = syms[k]
        vals = _vi_range_values(ranges[s], ctx, bindings)
        if s == ov.sym_l || s == ov.sym_r
            plan = _overlap_drive_plan(ov, (s,), bindings, _ -> vals)
            plan[1] === :restrict && (vals = plan[3])
        end
        for v in vals
            bindings[s] = v
            rec(k + 1)
        end
        return delete!(bindings, s)
    end
    rec(1)
    return
end

# ---- Compiled column bodies -------------------------------------------------
# A join column whose body is build-time arithmetic over its one range symbol
# (the bin column `floor(lon[i] / dx)`) is evaluated once per cell. `_vi_eval` resolves every name through the bindings
# dictionary and the const-array registry at each cell; this lowers the body
# once into a small node tree whose names are already resolved (the range
# symbol to the loop value, a parameter to its value, a gather to its array),
# then evaluates it per cell with the same arms in the same order, so every key
# is the one `_vi_eval` computes. A body with anything else (a ragged range, a
# gather from a bounded or non-Float64 array or from an upstream buffer, an
# unresolved name) returns `nothing` and keeps `_vi_eval`. A producer's key
# and filter over several interval / categorical ranges compile the same way
# (`_vi_producer_compiled`), each range symbol a slot of the binding vector.
const _VIC_INT = 1      # Int literal (`ival`)
const _VIC_NUM = 2      # Float64 literal or resolved parameter (`fval`)
const _VIC_SYM = 3      # a range symbol's value (slot `ival`)
const _VIC_GATHER = 4   # `arr[Int(args)...]`
const _VIC_OP = 5       # an arithmetic / comparison / rounding op (`op`)

struct _ViC
    kind::Int
    op::Symbol
    ival::Int
    fval::Float64
    arr::Array{Float64}
    args::Vector{_ViC}
end
const _VIC_NOARR = Float64[]
_ViC(
    kind::Int; op::Symbol = :none, ival::Int = 0, fval::Float64 = 0.0,
    arr::Array{Float64} = _VIC_NOARR, args::Vector{_ViC} = _ViC[]
) =
    _ViC(kind, op, ival, fval, arr, args)

const _VIC_OPS = Dict{String, Symbol}(
    "floor" => :floor, "ceil" => :ceil, "/" => :/,
    "*" => :*, "+" => :+, "-" => :-, "<" => :<, ">" => :>, "<=" => :<=,
    ">=" => :>=, "==" => :(==), "!=" => :!=,
    "ifelse" => :ifelse, "and" => :and, "or" => :or, "not" => :not,
    "min" => :min, "max" => :max, "true" => :vtrue, "false" => :vfalse
)

_vi_compile_node(node, ctx::_ViCtx, sym::String) = _vi_compile_node(node, ctx, String[sym])

function _vi_compile_node(node, ctx::_ViCtx, syms::Vector{String})
    if node isa IntExpr
        return _ViC(_VIC_INT; ival = Int(node.value))
    elseif node isa NumExpr
        return _ViC(_VIC_NUM; fval = Float64(node.value))
    elseif node isa VarExpr
        name = node.name
        slot = findfirst(==(name), syms)
        slot === nothing || return _ViC(_VIC_SYM; ival = slot)
        haskey(ctx.const_arrays, name) && return nothing
        v = get(ctx.variables, name, nothing)
        (v !== nothing && v.type == ParameterVariable) || return nothing
        return _ViC(_VIC_NUM; fval = Float64(_vi_param(ctx, name)))
    elseif node isa OpExpr
        args = node.args
        if node.op == "index"
            (length(args) >= 2 && args[1] isa VarExpr) || return nothing
            name = args[1].name
            haskey(ctx.maps, name) && return nothing
            arr = get(ctx.const_arrays, name, nothing)
            (arr isa Array{Float64} && ndims(arr) == length(args) - 1) || return nothing
            sub = _ViC[]
            for a in args[2:end]
                c = _vi_compile_node(a, ctx, syms)
                c === nothing && return nothing
                push!(sub, c)
            end
            return _ViC(_VIC_GATHER; arr = arr, args = sub)
        end
        op = get(_VIC_OPS, node.op, nothing)
        op === nothing && return nothing
        nargs = length(args)
        if op in (:vtrue, :vfalse)
            nargs == 0 || return nothing
        elseif op === :ifelse
            nargs == 3 || return nothing
        elseif op === :not
            nargs == 1 || return nothing
        elseif op in (:floor, :ceil, :-, :*, :+, :and, :or, :min, :max)
            nargs >= 1 || return nothing
        else
            nargs >= 2 || return nothing
        end
        sub = _ViC[]
        for a in args
            c = _vi_compile_node(a, ctx, syms)
            c === nothing && return nothing
            push!(sub, c)
        end
        return _ViC(_VIC_OP; op = op, args = sub)
    end
    return nothing
end

# A range symbol's value: `v` is the one symbol's value, or the binding vector.
@inline _vic_sym(v::Int, ::Int) = v
@inline _vic_sym(v::Vector{Int}, slot::Int) = @inbounds v[slot]

# `_vi_eval` arm for arm (the `_vi_num` guards cannot fire: every compiled
# value is a number or a Bool).
function _vic_eval(n::_ViC, v::Union{Int, Vector{Int}})::Union{Int, Float64, Bool}
    k = n.kind
    k == _VIC_INT && return n.ival
    k == _VIC_NUM && return n.fval
    k == _VIC_SYM && return _vic_sym(v, n.ival)
    a = n.args
    if k == _VIC_GATHER
        if length(a) == 1
            return n.arr[Int(_vic_eval(a[1], v))]
        end
        return n.arr[(Int(_vic_eval(x, v)) for x in a)...]
    end
    op = n.op
    if op === :vtrue
        return true
    elseif op === :vfalse
        return false
    elseif op === :ifelse
        return _vic_eval(_vi_truthy(_vic_eval(a[1], v)) ? a[2] : a[3], v)
    elseif op === :and
        for x in a
            _vi_truthy(_vic_eval(x, v)) || return false
        end
        return true
    elseif op === :or
        for x in a
            _vi_truthy(_vic_eval(x, v)) && return true
        end
        return false
    elseif op === :not
        return !_vi_truthy(_vic_eval(a[1], v))
    elseif op === :min || op === :max
        # `minimum` / `maximum` of the operands: NaN wins, -0.0 < +0.0, in
        # any order.
        acc = Float64(_vic_eval(a[1], v))
        for j in 2:length(a)
            x = Float64(_vic_eval(a[j], v))
            acc = op === :min ? min(acc, x) : max(acc, x)
        end
        return acc
    elseif op === :floor
        return _vi_round(floor, Float64(_vic_eval(a[1], v)))
    elseif op === :ceil
        return _vi_round(ceil, Float64(_vic_eval(a[1], v)))
    elseif op === :/
        return Float64(_vic_eval(a[1], v)) / Float64(_vic_eval(a[2], v))
    elseif op === :* || op === :+
        acc = Float64(_vic_eval(a[1], v))
        for j in 2:length(a)
            x = Float64(_vic_eval(a[j], v))
            acc = op === :* ? acc * x : acc + x
        end
        return acc
    elseif op === :-
        return length(a) == 1 ? -Float64(_vic_eval(a[1], v)) :
            Float64(_vic_eval(a[1], v)) - Float64(_vic_eval(a[2], v))
    end
    x = Float64(_vic_eval(a[1], v))
    y = Float64(_vic_eval(a[2], v))
    op === :< && return x < y
    op === :> && return x > y
    op === :<= && return x <= y
    op === :>= && return x >= y
    op === :(==) && return x == y
    return x != y
end

# Materialise a plain per-element `join` column (see `_vi_detect`'s `columns`)
# → Dict(output-index → exact integer). A NaN value is
# `value_invention_key_out_of_range` naming the column. A body over one interval
# or categorical range is compiled once (`_vi_compile_node`).
function _vi_materialize_column!(ctx::_ViCtx, vname::AbstractString, node::OpExpr)
    sym = String(only(node.output_idx))
    body = node.expr_body
    body === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_VI_MAP",
            "value-invention join column '$(vname)' has no `expr` body"
        )
    )
    column = "join column '$(vname)'"
    ranges = _vi_ranges(node)
    out = Dict{Any, Any}()
    if length(ranges) == 1 && haskey(ranges, sym)
        spec = ranges[sym]
        is = spec isa IndexSetRef ? get(ctx.index_sets, spec.from, nothing) : nothing
        compiled = is !== nothing && is.kind in ("interval", "categorical") ?
            _vi_compile_node(body, ctx, sym) : nothing
        if compiled !== nothing
            for v in _vi_range_values(spec, ctx, Dict{String, Any}())
                x = _vic_eval(compiled, v)
                out[v] = x isa AbstractFloat && isnan(x) ?
                    _vi_key_checked(x, column, Dict{String, Any}(sym => v)) : _vi_key_int(x)
            end
            ctx.maps[vname] = out
            return out
        end
    end
    _vi_enumerate(ranges, ctx, bindings -> (out[bindings[sym]] = _vi_key(body, ctx, bindings, column)))
    ctx.maps[vname] = out
    return out
end

# Materialise an index-set-producing aggregate → the distinct member set (§5.5
# sorted total order, via the Relational engine). Returns the member vector.
function _vi_materialize_producer(ctx::_ViCtx, node::OpExpr)
    key = node.key
    key === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_VI_PRODUCER",
            "value-invention producer aggregate requires a `key` (§5.5)"
        )
    )
    ranges = _vi_ranges(node)
    filt = node.filter
    join = node.join
    # Resolve join gates ONCE (a `join.overlap` broad-phase candidate set is built
    # a single time here). An OVERLAP gate then DRIVES enumeration from its
    # candidate pairs (`_vi_enumerate_join`, Wall #1) — O(|candidates|) rather than
    # O(∏ranges) with a per-tuple membership test; other gate kinds enumerate the
    # full product exactly as before.
    join_gates = join === nothing ? nothing : _vi_resolve_join(join, ranges, ctx)
    column = "the `key` of producer '$(something(node.id, ""))'"
    if join_gates === nothing && _setup_compile_once_enabled()
        members = _vi_producer_compiled(ctx, ranges, filt, key, column)
        members === nothing || return Relational.distinct(members)
    end
    members = Any[]
    _vi_enumerate_join(
        ranges, join_gates, ctx, bindings -> begin
            if filt !== nothing
                fv = _vi_eval(filt, ctx, bindings)
                (fv === true || (isa(fv, Real) && fv > 0)) || return
            end
            if join_gates !== nothing && !_vi_join_ok(join_gates, bindings)
                return
            end
            push!(members, _vi_key(key, ctx, bindings, column))
        end
    )
    return Relational.distinct(members)
end

# The un-gated producer over interval / categorical ranges with its `key` and
# `filter` compiled once (`_vi_compile_node`, each range symbol a slot): the
# keys `_vi_enumerate` would push, in its order (the first symbol outermost),
# as a concretely typed vector. `nothing` when a range, the filter or the key
# has no compiled form; the caller then enumerates as before.
function _vi_producer_compiled(ctx::_ViCtx, ranges, filt, key, column)
    syms = _vi_order_syms(ranges)
    lens = Int[]
    for s in syms
        spec = ranges[s]
        spec isa IndexSetRef && isempty(_vi_range_of(spec)) || return nothing
        is = get(ctx.index_sets, spec.from, nothing)
        (is !== nothing && is.kind in ("interval", "categorical")) || return nothing
        push!(lens, length(_vi_range_values(spec, ctx, Dict{String, Any}())))
    end
    cf = filt === nothing ? nothing : _vi_compile_node(filt, ctx, syms)
    filt === nothing || cf !== nothing || return nothing
    ck = _vi_compile_node(key, ctx, syms)
    ck === nothing && return nothing
    ff = cf === nothing ? nothing : _vic_kernel(cf)
    return _vic_produce(lens, ff, _vic_kernel(ck), syms, column)
end

# A compiled node as Julia code, compiled once through RuntimeGeneratedFunctions
# and called per binding as `k(v)`: `_vic_eval` arm for arm, the same
# operations in the same order on the same value types (an `Int` literal or
# range symbol stays an `Int`, a `floor` keeps `_vi_round`'s result, a
# comparison is a `Bool`), so every value is the walker's.
struct _ViCKernel{F, S}
    f::F
    srcs::S
end
@inline (k::_ViCKernel)(v::Vector{Int}) = k.f(v, k.srcs)

function _vic_kernel(n::_ViC)
    srcs = Any[]
    ix = IdDict{Any, Int}()
    body = _vic_expr(n, srcs, ix)
    ex = Expr(:function, Expr(:tuple, :v, :srcs), Expr(:block, :(return $body)))
    f = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(@__MODULE__, @__MODULE__, ex)
    return _ViCKernel(f, Tuple(srcs))
end

function _vic_expr(n::_ViC, srcs::Vector{Any}, ix::IdDict{Any, Int})
    k = n.kind
    k == _VIC_INT && return n.ival
    k == _VIC_NUM && return n.fval
    k == _VIC_SYM && return :(@inbounds v[$(n.ival)])
    a = n.args
    em(x) = _vic_expr(x, srcs, ix)
    if k == _VIC_GATHER
        j = get!(ix, n.arr) do
            push!(srcs, n.arr)
            length(srcs)
        end
        return :(srcs[$j][$((:(Int($(em(x)))) for x in a)...)])
    end
    op = n.op
    f64(x) = :(Float64($(em(x))))
    if op === :vtrue
        return true
    elseif op === :vfalse
        return false
    elseif op === :ifelse
        return :(_vi_truthy($(em(a[1]))) ? $(em(a[2])) : $(em(a[3])))
    elseif op === :and || op === :or
        e = :(_vi_truthy($(em(a[end]))))
        for j in (length(a) - 1):-1:1
            c = :(_vi_truthy($(em(a[j]))))
            e = op === :and ? :($c && $e) : :($c || $e)
        end
        return e
    elseif op === :not
        return :(!_vi_truthy($(em(a[1]))))
    elseif op === :min || op === :max || op === :* || op === :+
        acc = f64(a[1])
        for j in 2:length(a)
            acc = Expr(:call, op, acc, f64(a[j]))
        end
        return acc
    elseif op === :floor || op === :ceil
        return :(_vi_round($op, $(f64(a[1]))))
    elseif op === :/
        return :($(f64(a[1])) / $(f64(a[2])))
    elseif op === :-
        return length(a) == 1 ? :(-$(f64(a[1]))) : :($(f64(a[1])) - $(f64(a[2])))
    end
    return Expr(:call, op, f64(a[1]), f64(a[2]))
end

# A key as `_vi_key` makes it (NaN is `value_invention_key_out_of_range`).
@inline function _vic_key(k, v, syms, column)
    x = k(v)
    x isa AbstractFloat && isnan(x) && _vi_key_checked(
        x, column, Dict{String, Any}(syms[d] => v[d] for d in eachindex(syms))
    )
    return _vi_key_int(x)::Int
end

function _vic_produce(lens::Vector{Int}, cf, k, syms, column)
    out = Int[]
    n = prod(lens; init = 1)
    n == 0 && return out
    sizehint!(out, n)
    v = ones(Int, length(lens))
    for _ in 1:n
        _VI_ENUM_VISITS[] += 1
        keep = true
        if cf !== nothing
            fv = cf(v)
            keep = fv === true || (isa(fv, Real) && fv > 0)
        end
        keep && push!(out, _vic_key(k, v, syms, column))
        # The last symbol runs fastest, as `_vi_enumerate`'s innermost loop.
        d = length(v)
        while d >= 1
            v[d] += 1
            v[d] <= lens[d] && break
            v[d] = 1
            d -= 1
        end
    end
    return out
end

# ---- Cadence classification on the typed IR (§5.7 guard 2) ------------------
#
# The lattice `const ⊏ discrete ⊏ continuous` as integer ranks; `class(node) =
# max` over its children's classes, seeded from a leaf's declared variable kind
# (CONFORMANCE_SPEC §5.7.2). This is the value-invention front door's OWN typed
# classifier — the raw-JSON `Cadence` module is conformance-fixture-only. It
# never consults `expect_cadence` (which the typed IR does carry): an assertion
# is something to CHECK, and checking it is the conformance pass's job, not a
# guard's.
# Only the CONTINUOUS-vs-not distinction is observable here (every check below
# compares against `continuous`), so the loader-temporal `discrete → const`
# refinement of the conformance classifier — which never crosses the continuous
# boundary — is deliberately not replicated.
const _VI_CLASS_CONST = 0
const _VI_CLASS_DISCRETE = 1
const _VI_CLASS_CONTINUOUS = 2

"""
    _vi_seed_map(model::Model) -> Dict{String,Int}

The per-name cadence SEED of every variable in `model`, derived from the
esm-spec §6.3.1 classification rather than from a declared type — the typed-IR
twin of `Cadence.seed_leaf` (CONFORMANCE_SPEC §5.7.2):

| Derived category | Seed |
|---|---|
| `ode_states`, `algebraic_unknowns` | CONTINUOUS |
| `brownian_parameters` | CONTINUOUS (resampled every step) |
| `observed_unknowns` | the class of its defining equation's RHS, transitively |
| `discrete_parameters` | DISCRETE |
| `sampled_parameters`, `constant_parameters` | CONST |

The observed rule is the one that must not be shortcut: seeding every unknown
CONTINUOUS would stop a state-free observed folding at bind — which is exactly
what this build-time value-invention pass relies on — while seeding it CONST
(the 0.x shortcut) would fold a value that reads a live state.
"""
function _vi_seed_map(model::Model)::Dict{String, Int}
    seeds = Dict{String, Int}()
    for n in ode_states(model)
        seeds[n] = _VI_CLASS_CONTINUOUS
    end
    for n in algebraic_unknowns(model)
        seeds[n] = _VI_CLASS_CONTINUOUS
    end
    for n in brownian_parameters(model)
        seeds[n] = _VI_CLASS_CONTINUOUS
    end
    for n in discrete_parameters(model)
        seeds[n] = _VI_CLASS_DISCRETE
    end
    for n in sampled_parameters(model)
        seeds[n] = _VI_CLASS_CONST
    end
    for n in constant_parameters(model)
        seeds[n] = _VI_CLASS_CONST
    end
    # Observed unknowns resolve through their defining equations, memoised, with
    # a cycle guard (a cycle is a defect; it seeds CONTINUOUS, the conservative
    # answer, and the acyclicity guard reports it).
    defs = observed_definitions(model)
    resolving = Set{String}()
    function resolve(name)
        haskey(seeds, name) && return seeds[name]
        e = get(defs, name, nothing)
        e === nothing && return _VI_CLASS_CONST
        name in resolving && return _VI_CLASS_CONTINUOUS
        push!(resolving, name)
        cls = _VI_CLASS_CONST
        for r in free_variables(e)
            cls = max(cls, r == "t" ? _VI_CLASS_CONTINUOUS : resolve(r))
        end
        delete!(resolving, name)
        seeds[name] = cls
        return cls
    end
    for name in keys(defs)
        resolve(name)
    end
    return seeds
end

function _vi_seed_class(name::AbstractString, seeds::Dict{String, Int})
    name == "t" && return _VI_CLASS_CONTINUOUS   # the independent variable
    # An unknown name is an index-set name or a bound index symbol (i, k, e,
    # f) — const.
    return get(seeds, name, _VI_CLASS_CONST)
end

# Derive a typed expression's cadence class: max over the generated child walk
# (`foreach_child`, expression.jl — every expression-bearing `OpExpr` field).
function _vi_class(expr::ASTExpr, seeds::Dict{String, Int})::Int
    expr isa VarExpr && return _vi_seed_class(expr.name, seeds)
    expr isa OpExpr || return _VI_CLASS_CONST    # IntExpr / NumExpr literals
    cls = _VI_CLASS_CONST
    foreach_child(expr) do c
        cls = max(cls, _vi_class(c, seeds))
    end
    return cls
end

"""
    materialize_value_invention(model::Model, index_sets, const_arrays, params)
        -> NamedTuple

Run the build-time value-invention engine over a typed model. `index_sets` is
the document-scoped registry (`EsmFile.index_sets`; esm-spec v0.8.0 — a typed
`Model` does not carry it). Returns:

- `extents::Dict{String,Int}` — `from_faq` producer id → derived index-set
  cardinality (the dense extent `[1, n]` the tree-walk resolver consumes).
- `members::Dict{String,Vector}` — `from_faq` producer id → the distinct integer
  keys in §5.5.1 sorted order (for byte-identity assertions).
- `vi_var_names::Set{String}` — value-invention LHS vars to drop from the ODE.
- `maps::Dict{String,Dict}` — materialised per-element join column (e.g.
  `src_bx`) → (1-based output position → integer key). A downstream FAQ's
  `join.on [[src_bx, tgt_bx]]` gates on these buffers (§5.3): the broad-phase
  bin key is data-derived, so it cannot be a categorical index-set member — the
  tree-walk join resolver reads the key value per position from here.
- `map_sets::Dict{String,String}` — column → its 1-D shape index-set name, so
  the join resolver can find the range symbol the column is indexed by.

`const_arrays` supplies the build-time factor arrays (the connectivity / coords
the keys are computed from); `params` supplies scalar parameter overrides. A
producer that classifies CONTINUOUS is rejected (§5.7 guard 2).
"""
function materialize_value_invention(
        model::Model, index_sets::AbstractDict,
        const_arrays::AbstractDict,
        params::AbstractDict
    )
    det = _vi_detect(model)
    extents = Dict{String, Int}()
    members = Dict{String, Vector{Any}}()
    map_sets = Dict{String, String}()
    det.has_vi || return (
        extents = extents, members = members, vi_var_names = det.vi_var_names,
        maps = Dict{String, Dict{Any, Any}}(), map_sets = map_sets,
    )

    ca = Dict{String, Any}(String(k) => v for (k, v) in const_arrays)
    # A ragged range binds its members through keyed factors named by BARE name;
    # a const-backed factor may be registered under its in-scope (flattened) name.
    for (bare, scoped) in _ragged_factor_scope(index_sets, model.variables)
        !haskey(ca, bare) && haskey(ca, scoped) && (ca[bare] = ca[scoped])
    end
    ctx = _ViCtx(
        ca,
        Dict{String, Float64}(String(k) => Float64(v) for (k, v) in params),
        Dict{String, IndexSet}(String(k) => v for (k, v) in index_sets),
        model.variables,
        Dict{String, Dict{Any, Any}}(),
        _vi_seed_map(model)
    )

    # Plain join columns first (a producer's join may reference them). A column
    # is recorded in `maps`/`map_sets` so a simulate-time join reads the same
    # integers, but it is not in `vi_var_names`: it stays an ordinary observed.
    for (vname, node) in det.columns
        _vi_materialize_column!(ctx, vname, node)
        v = get(ctx.variables, vname, nothing)
        v === nothing && continue
        shape = v.shape === nothing ? String[] : v.shape
        length(shape) == 1 && (map_sets[vname] = String(shape[1]))
    end
    # `from_faq` id → derived index-set name (so we only materialise producers a
    # derived set actually names; geometry producers are handled elsewhere).
    faq_to_set = Dict{String, String}()
    for (sname, is) in ctx.index_sets
        is.kind == "derived" || continue
        is.from_faq === nothing || (faq_to_set[String(is.from_faq)] = String(sname))
    end

    for (_, node) in det.producers
        id = node.id
        id === nothing && throw(
            TreeWalkError(
                "E_TREEWALK_VI_PRODUCER",
                "value-invention producer aggregate requires an `id` naming it for `from_faq`"
            )
        )
        id = String(id)
        haskey(faq_to_set, id) || continue   # no derived set names this producer
        # §5.7 guard 2: a relational node may not run on the hot path. The code is
        # the one structural validation reports for the same document.
        _vi_class(node, ctx.seeds) == _VI_CLASS_CONTINUOUS &&
            throw(
            TreeWalkError(
                "relational_node_in_continuous",
                "value-invention producer '$id' classifies CONTINUOUS — it may not run per " *
                    "step (RFC §5.7 guard 2); its inputs must be CONST/DISCRETE"
            )
        )
        # Any other failure leaves the derived set with no members to count, so it
        # is refused under the set's name rather than surfaced as an engine detail.
        mem = try
            _vi_materialize_producer(ctx, node)
        catch err
            err isa TreeWalkError || rethrow()
            # A NaN key already names its column; the producer ran.
            err.code == ERROR_CODES.VALUE_INVENTION_KEY_OUT_OF_RANGE && rethrow()
            throw(
                TreeWalkError(
                    "derived_index_set_unmaterialized",
                    "derived index set '$(faq_to_set[id])' (from_faq '$id') cannot be " *
                        "materialized: $(err.code): $(err.detail)"
                )
            )
        end
        members[id] = mem
        extents[id] = length(mem)
    end

    return (
        extents = extents, members = members, vi_var_names = det.vi_var_names,
        maps = ctx.maps, map_sets = map_sets,
    )
end
