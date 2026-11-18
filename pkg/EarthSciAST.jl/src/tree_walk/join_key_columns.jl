# tree_walk/join_key_columns.jl — the key columns a join compares: document
# literals, data columns, and computed columns evaluated at build time.

# The empty value-invention map registry: no materialised buffers. A join over
# categorical / interval members never consults it, so join resolution stays
# byte-identical for every non-value-invention document. Read-only sentinel —
# see the `_EMPTY_*` invariant block next to `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_VI_MAPS = (maps = Dict{String, Any}(), map_sets = Dict{String, String}())

# The aggregate range symbol a 1-D DATA COLUMN runs over (CONFORMANCE_SPEC
# §5.5.8 case 2): the column's single declared shape index set names one of the
# node's ranges. `vi_maps.map_sets` records the same fact for a materialised
# value-invention buffer, which has no `variables` entry to read a shape from.
# `_overlap_env_sym` below is NOT the same rule: an envelope factor may also be
# a 3-D `[pos, verts, coord]` ring stack (`_overlap_env_rank`), read by its first
# axis, and an unresolvable one is an OVERLAP diagnostic rather than an
# UNKNOWN_KEY one. Do not merge the two.
function _join_key_column_sym(
        col::String, ranges::AbstractDict,
        sym_to_set::AbstractDict, var_shapes::AbstractDict,
        vi_maps, pick = :left,
        order::Union{Nothing, Vector{String}} = nothing
    )
    setn = get(vi_maps.map_sets, col, nothing)
    if setn === nothing
        shape = get(var_shapes, col, nothing)
        (shape === nothing || length(shape) != 1) && throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_UNKNOWN_KEY",
                "join key '$col' is neither a loop symbol / index set of this " *
                    "aggregate's ranges nor a declared 1-D data column (its shape is " *
                    "$(shape === nothing ? "<undeclared>" : shape); §5.5.8 requires a " *
                    "single shape index set naming one of the node's ranges)"
            )
        )
        setn = String(shape[1])
    end
    return _join_sym_for_key(setn, ranges, sym_to_set, pick, order, :column_axis)
end

# The build-time VALUES of a data-column key at each of `positions`. §5.5.8
# requires the column to be build-time constant by the time the gate is built,
# and there are three storages it can already be constant in:
#   * a value-invention MAP buffer (`vi_maps.maps`) — the data-derived bin key;
#   * a const array (`const_arrays`) — host-supplied, derived at the front door,
#     or a `const`-op array observed registered there;
#   * a document-LITERAL array observed still carrying its defining expression
#     (`const` / `makearray`), materialised here through the SAME
#     `_resolve_index_of_makearray` the body's own `index(col, l)` would use, so
#     the gate and the lowered body cannot disagree about the column;
#   * a CONST-CADENCE computed observed: one whose value depends only on index
#     symbols, inline constants, build-time data (const arrays, ingested
#     columns) and scalar parameters — never on a state or `t` — so it is as
#     constant at build time as the storages above
#     (`_const_cadence_column_values`). A parameter it reads is baked: its
#     value at the build is folded into the gate, and the parameter is
#     recorded as read at build, so a `remake` that changes it is refused.
# Anything else (a live state, a time-dependent observed) is a build error
# rather than a silently ungated product.
function _join_key_column_values(
        col::String, positions::Vector{Int}, vi_maps,
        const_arrays::AbstractDict, obs_defs::AbstractDict,
        index_sets::AbstractDict = Dict{String, Any}(),
        var_shapes::AbstractDict = Dict{String, Vector{String}}()
    )
    if haskey(vi_maps.maps, col)
        # Deliberately UNVALIDATED: a bin id is whatever the value-invention
        # front door minted (an integer), it is only ever compared against
        # another buffer minted the same way.
        buf = vi_maps.maps[col]
        return Any[buf[p] for p in positions]
    end
    arr = get(const_arrays, col, nothing)
    if arr === nothing
        defn = get(obs_defs, col, nothing)
        if defn isa OpExpr && (defn::OpExpr).op == "const"
            arr = _const_op_to_array((defn::OpExpr).value)
        elseif defn isa OpExpr && (defn::OpExpr).op == "makearray" &&
                all(
                p -> _join_literal_cell(defn::OpExpr, p, const_arrays) !== nothing,
                positions
            )
            return Any[_join_literal_cell(defn::OpExpr, p, const_arrays) for p in positions]
        elseif defn !== nothing
            vals = _const_cadence_column_values(
                col, defn, positions, const_arrays,
                obs_defs, index_sets, vi_maps, var_shapes
            )
            vals === nothing || return vals
        end
    end
    arr === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_JOIN_UNKNOWN_KEY",
            "join key column '$col' has no build-time data: §5.5.8 requires a key " *
                "column to be build-time constant by the time the gate is built (a " *
                "const array, a document-literal array observed, a value-invention " *
                "map buffer, or an observed computed from those alone) — it is none of " *
                "those"
        )
    )
    ndims(arr) == 1 || throw(
        TreeWalkError(
            "E_TREEWALK_JOIN_UNKNOWN_KEY",
            "join key column '$col' is $(ndims(arr))-D; §5.5.8 admits a 1-D column"
        )
    )
    for p in positions
        checkbounds(Bool, arr, p) || throw(
            TreeWalkError(
                "E_TREEWALK_JOIN_UNKNOWN_KEY",
                "join key column '$col' has $(length(arr)) rows but its range runs " *
                    "to position $(maximum(positions))"
            )
        )
    end
    return Any[arr[p] for p in positions]
end

# The values of key column `col` at `positions` when its definition `defn` is a
# const-cadence computed observed, or `nothing` when it is not one. The
# definition is closed over the observeds it reads (inlined, as the right-hand
# side would), its index-set ranges resolved, and then it must reference
# nothing but its own binders, build-time arrays and scalar parameters — the
# test the affine tier's value-table lane applies (`_exprtbl_evaluable`), with
# the parameters admitted as build-time values. It is
# compiled ONCE with its output index bound and read at each position, the
# compile-once evaluator `observed_field` uses, so the gate holds exactly the
# values the column reads elsewhere. The gate is built from these values like
# any other key column, so it still drives the enumeration.
function _const_cadence_column_values(
        col::String, defn::ASTExpr, positions::Vector{Int},
        const_arrays::AbstractDict, obs_defs::AbstractDict,
        index_sets::AbstractDict, vi_maps = _EMPTY_VI_MAPS,
        var_shapes::AbstractDict = Dict{String, Vector{String}}()
    )
    (isempty(positions) || minimum(positions) < 1) && return nothing
    ca = Dict{String, Any}(String(k) => v for (k, v) in const_arrays)
    vals = _cc_values(
        col, defn, [maximum(positions)], ca, obs_defs, index_sets, vi_maps,
        var_shapes, Set{String}([col])
    )
    vals === nothing && return nothing
    return _computed_keys(Any[vals[p] for p in positions])
end

# The extents of an observed's declared shape, or `nothing` when a set's size
# is not known here.
function _cc_extents(n::String, index_sets::AbstractDict, var_shapes::AbstractDict)
    shape = get(var_shapes, n, nothing)
    (shape === nothing || isempty(shape)) && return nothing
    ext = Int[]
    for sname in shape
        is = get(index_sets, String(sname), nothing)
        is isa IndexSet || return nothing
        sz = is.kind == "categorical" ?
            (is.members === nothing ? nothing : length(is.members)) : is.size
        (sz isa Int && sz > 0) || return nothing
        push!(ext, sz)
    end
    return ext
end

# Observed `name`'s value over `1:ext`, as a column-major array, from its
# definition `def`, or `nothing` when it is not build-time data. Every array
# observed the definition reads is computed the same way FIRST, over its own
# declared cells, and put in `ca` (its producer evaluated once, not once per
# reader cell); a scalar one is inlined. Then, in order: the compile-once
# evaluator; compiled through the right-hand side's cascade into a buffer and
# run once (setup_fill.jl) where the plan compiles construction-time fills (a
# join-gated reduction, a `makearray` read at the cell); and only under a plan
# that licenses it, a resolution at each cell. Scalar parameters read are
# baked (recorded as read at build).
function _cc_values(
        name::String, def::ASTExpr, ext::Vector{Int}, ca::Dict{String, Any},
        obs_defs::AbstractDict, index_sets::AbstractDict, vi_maps,
        var_shapes::AbstractDict, stack::Set{String}
    )
    # A document-literal array is its value.
    if def isa OpExpr && (def::OpExpr).op == "const" && (def::OpExpr).value isa AbstractVector
        a = _const_op_to_array((def::OpExpr).value)
        return size(a) == Tuple(ext) ? Array{Float64}(a) : nothing
    end
    e = def
    for _ in 0:length(obs_defs)
        subs = Dict{String, ASTExpr}()
        for n in _referenced_var_names(e)
            (haskey(ca, n) || !haskey(obs_defs, n)) && continue
            n in stack && return nothing                    # a cycle through observeds
            d = obs_defs[n]::ASTExpr
            next = _cc_extents(n, index_sets, var_shapes)
            if next === nothing
                subs[n] = d
            else
                arr = _cc_values(
                    n, d, next, ca, obs_defs, index_sets, vi_maps, var_shapes,
                    union(stack, (n,))
                )
                arr === nothing && return nothing
                ca[n] = arr
            end
        end
        isempty(subs) && break
        e = _sub_preserving(e, subs)
    end
    any(n -> haskey(obs_defs, n) && !haskey(ca, n), _referenced_var_names(e)) &&
        return nothing
    # A materialized observed named bare reads its own cell (§4.3.4, the
    # name-aligned elementwise case): it becomes the producer that reads it
    # there, which every route below indexes at the cell.
    aligned = Dict{String, ASTExpr}()
    for n in _referenced_var_names(e)
        (haskey(obs_defs, n) && haskey(ca, n)) || continue
        a = ca[n]
        (a isa AbstractArray && ndims(a) == length(ext)) || continue
        ks = String["\0cc\0$d" for d in 1:length(ext)]
        aligned[n] = OpExpr(
            "faq", ASTExpr[]; output_idx = Any[ks...],
            ranges = Dict{String, Any}(ks[d] => Any[1, size(a, d)] for d in eachindex(ks)),
            expr_body = OpExpr("index", ASTExpr[VarExpr(n), (VarExpr(k) for k in ks)...])
        )
    end
    isempty(aligned) || (e = _sub_preserving(e, aligned))
    # Joins of its own (a MOVES key that is the latest year at or before the run
    # year): their gates are built first, by this same resolution.
    e isa OpExpr && _expr_has_join(e::OpExpr) &&
        (e = _resolve_join_in_expr(e, index_sets, vi_maps, ca, var_shapes, obs_defs))
    e = _resolve_isr(e, index_sets)
    params = _join_params()
    used = Dict{String, Float64}(
        n => params[n] for n in _referenced_var_names(e)
            if haskey(params, n) && !haskey(ca, n)
    )
    _exprtbl_evaluable(e, Set{String}(keys(used)), ca) || return nothing
    # The compile-once evaluator first: a key column is a small table, and
    # its one compiled tree costs no code generation, where a fill emits and
    # compiles a function of its own.
    cells = _row_major_cells(ext)
    out = Array{Float64}(undef, ext...)
    ce = _cell_evaluator(e, _cell_oidx_syms(length(ext)), ca, used; index_outputs = true)
    if ce !== nothing
        for c in cells
            out[c...] = ce(c)
        end
    else
        fill = _setup_fill_array(
            e, ext; const_arrays = ca, params = used
        )
        if fill !== nothing
            out = fill
        else
            # A gated reduction, or a `makearray` read at the cell, with no
            # symbolic compile-once form: resolved at each cell, under license.
            _percell_evaluation_license(
                "join key column $name",
                "the join gate's key column", length(cells)
            )
            psyms = Set{Symbol}(Symbol(k) for k in keys(used))
            pnt = NamedTuple{Tuple(Symbol(k) for k in keys(used))}(Tuple(values(used)))
            for c in cells
                v = try
                    r = _resolve_indices(
                        _key_at_cell(e, c),
                        Dict{String, Tuple{Vector{Int}, Vector{Int}}}(),
                        Dict{String, Int}(), ca
                    )
                    _eval_node(
                        _compile(r, Dict{String, Int}(), psyms),
                        Float64[], pnt, 0.0
                    )
                catch err
                    err isa EarthSciASTError || rethrow()
                    return nothing
                end
                out[c...] = v
            end
        end
    end
    foreach(_record_param_read, keys(used))
    return out
end

# An array-valued key definition read at cell `c`: every array producer and
# inline array `const` it combines elementwise is indexed there
# (`_index_at_cell`, extended to the inline literal).
function _key_at_cell(e::ASTExpr, c::Vector{Int})
    e isa OpExpr || return e
    o = e::OpExpr
    (_is_array_producer(o) || (o.op == "const" && o.value isa AbstractVector)) &&
        return OpExpr("index", ASTExpr[o, (IntExpr(Int64(x)) for x in c)...])
    _is_self_indexed_op(o.op) && return o
    return reconstruct(o; args = ASTExpr[_key_at_cell(a, c) for a in o.args])
end

# The build's scalar parameter values while its join gates resolve
# (`_with_join_params`), on the build state; empty outside one.
_join_params()::Dict{String, Float64} = _build_state().join_params
function _with_join_params(f, params::AbstractDict)
    st = _build_state()
    saved = st.join_params
    st.join_params = Dict{String, Float64}(params)
    try
        return f()
    finally
        st.join_params = saved
    end
end

# One cell of a document-literal `makearray` key column, as a raw value, or
# `nothing` when the cell is not a literal (a computed column, which
# `_const_cadence_column_values` then evaluates whole).
function _join_literal_cell(mk::OpExpr, p::Int, const_arrays::AbstractDict)
    r = _resolve_index_of_makearray(
        mk, ASTExpr[IntExpr(Int64(p))],
        _ResolveCtx(Dict{String, Tuple{Vector{Int}, Vector{Int}}}(), Dict{String, Int}(), const_arrays)
    )
    r isa NumExpr && return (r::NumExpr).value
    r isa IntExpr && return (r::IntExpr).value
    # A scalar `const` literal (what an `enum` lowers to) is a literal too.
    (
        r isa OpExpr && (r::OpExpr).op == "const" && (r::OpExpr).value isa Real &&
            !((r::OpExpr).value isa Bool)
    ) && return (r::OpExpr).value
    return nothing
end

# Resolve one join-key name to `(sym, positions, values)` — the range symbol it
# denotes, the 1-based positions iterated for it, and the key VALUE at each
# position. Two cases, in the §5.5.8 precedence order (which is §5.5.6's
# "binders shadow declarations" order):
#  1. a BINDER: a loop symbol of this node, or the index set one of its ranges
#     draws `{from}`. The key values are that set's declared members (a
#     categorical set) or its integer IDs (an interval), known from the
#     document registry. Tested FIRST, so a variable that happens to share a
#     name with one of the node's range symbols cannot shadow the loop symbol.
#  2. otherwise a DATA COLUMN: a declared 1-D variable — or the materialised
#     value-invention map buffer that is the special case of one — whose single
#     shape index set names one of this node's ranges. Its values ARE the key
#     values, read as data. This is how a relational port (EPA MOVES/NONROAD)
#     spells every join: one table's `sourceTypeID` column against another's.
function _join_key_sym_pos_vals(
        key::String, ranges::AbstractDict,
        index_sets::AbstractDict, sym_to_set::AbstractDict,
        vi_maps, const_arrays::AbstractDict = Dict{String, Any}(),
        var_shapes::AbstractDict = Dict{String, Vector{String}}(),
        obs_defs::AbstractDict = Dict{String, ASTExpr}(),
        pick = :left,
        order::Union{Nothing, Vector{String}} = nothing
    )
    if haskey(ranges, key) || any(==(key), values(sym_to_set))
        sym = _join_sym_for_key(key, ranges, sym_to_set, pick, order)
        positions = _join_key_positions(sym, ranges, index_sets)
        return (sym, positions, _key_member_values(sym, ranges, positions, index_sets))
    end
    sym = _join_key_column_sym(key, ranges, sym_to_set, var_shapes, vi_maps, pick, order)
    positions = _join_key_positions(sym, ranges, index_sets)
    raw = _join_key_column_values(
        key, positions, vi_maps, const_arrays, obs_defs,
        index_sets, var_shapes
    )
    haskey(vi_maps.maps, key) && return (sym, positions, raw)
    raw isa _ComputedKeys && return (sym, positions, raw.vals)
    return (sym, positions, Any[_validated_key_datum(v, key) for v in raw])
end

# The values of a COMPUTED key column (`_const_cadence_column_values`). A
# computed value need not be an integer ID: a reduction over no rows gives its
# identity (a min over nothing is +Inf, a MOVES "earliest year after" that has
# none). Such a value is a key that equals what it equals as a number — the
# equality the per-pair test of the dense evaluators applies — so it matches
# nothing that is an ID; an integral value is the ID it names.
struct _ComputedKeys
    vals::Vector{Any}
end
_computed_keys(vals) = _ComputedKeys(
    Any[
        (
                v isa Real && isfinite(v) && v == round(v) &&
                abs(v) < 9.0e15
            ) ? Int(v) : Float64(v)
            for v in vals
    ]
)
