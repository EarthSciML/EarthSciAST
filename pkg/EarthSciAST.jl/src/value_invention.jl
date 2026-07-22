"""
Build-time value-invention front door
(RFC semiring-faq-unified-ir §6.1 cadence-partition / §5.5 / §7.3).

Replaces the `E_TREEWALK_DERIVED_INDEX_SET` throw (tree_walk.jl). A
`kind:"derived"` index set whose `from_faq` names a value-invention aggregate
(skolem / distinct / rank) is materialised here, ONCE at setup, off the
per-step hot path — the §6.1 CONST/DISCRETE materialisation point. The
aggregate's keys are evaluated over the build-time const-array factors and run
through the `Relational` engine (skolem / distinct / equijoin, §5.5
determinism); the distinct set's cardinality is handed to the tree-walk
index-set resolver as the dense extent `[1, n]` — exactly as
[`_materialize_geometry_rings`](@ref) does for an `intersect_polygon` clip
ring (§8.1), now generalised to the relational engine.

The pass runs on the TYPED IR (`Model` / `ASTExpr`): `OpExpr` carries the full
value-invention vocabulary (`id`, `distinct`, `key`, `arg`, `join`, `label`,
`ranges` — see `OPEXPR_FIELD_TABLE`, types.jl), so no raw-JSON walking is
needed. The document-scoped index-set registry is passed alongside the model
(esm-spec v0.8.0: `EsmFile.index_sets`), since a typed `Model` does not carry
it. The cadence classification the §5.7 guard-2 checks need is derived here
directly on the typed tree (`_vi_class`); the raw-JSON `Cadence` module remains
only for the conformance fixtures, whose `expect_cadence` annotation the typed
IR deliberately does not parse.

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
_vi_ranges(node::OpExpr) = node.ranges === nothing ? Dict{String,Any}() : node.ranges

# The relational body ops that mark a value-invention output (excluded from the ODE).
const _VI_BODY_OPS = ("skolem", "rank", "distinct")

# Arg-witness reducer ops (RFC §5.7 rule 6): a build-time reduction over a
# contracted candidate range that emits the ARG — the witnessing index — rather
# than the reduced value. The nearest-generator INDEX assignment. NET-NEW: the
# closed semiring registry (§5.1) returns values and value-invention
# (distinct/skolem/rank) returns sets — NEITHER returns the arg. Materialised as
# an integer per-element buffer at CONST cadence, exactly like the `:map` skolem
# bin buffers.
const _VI_ARGWITNESS_OPS = ("argmin", "argmax")

"""
    _vi_node_kind(node) -> Symbol

Classify a typed aggregate node's value-invention role:

- `:producer` — `distinct:true` (an index-set-producing aggregate; materialises a
  derived index set via `from_faq`).
- `:map`      — a per-element map whose body is `skolem` (e.g.
  `src_bin[i] = skolem("bin", floor(...), floor(...))`): a value-invention buffer
  the producer's `join`/`key` references; materialised so the join can gate on it.
  Also a per-element map whose body is an arg-witness reducer (`argmin`/`argmax`,
  e.g. `assign[i] = argmin_g dist(point_i, gen_g)`): an integer assignment buffer
  emitted by the inner reduction (§5.7 rule 6).
- `:exclude`  — another value-invention output (e.g. a `rank` dense-id buffer like
  `edge_dense_id`) that is dropped from the ODE but needs no setup materialisation
  (nothing downstream of the front-door consumes its values in v1).
- `:none`     — an ordinary numeric aggregate.
"""
function _vi_node_kind(node)
    node isa OpExpr || return :none
    node.op == "aggregate" || return :none
    node.distinct === true && return :producer
    body = node.expr_body
    if body isa OpExpr
        (body.op == "skolem" || body.op in _VI_ARGWITNESS_OPS) && return :map
        body.op in _VI_BODY_OPS && return :exclude
    end
    key = node.key
    key isa OpExpr && key.op == "skolem" && return :map
    return :none
end

# Every (lhs, rhs) value-expression pair in a typed model: the equation list plus
# the `expression` of each observed variable (lhs then a bare name String).
function _vi_model_assignments(model::Model)
    out = Tuple{Any,ASTExpr}[]
    for eq in model.equations
        push!(out, (eq.lhs, eq.rhs))
    end
    for (vname, v) in model.variables
        v.expression === nothing || push!(out, (vname, v.expression))
    end
    return out
end

# Every `index` target name reachable in a sub-tree (the array a value reads
# from): `index(NAME, …)` → NAME. Walks EVERY expression-bearing `OpExpr` field
# via the generated `foreach_subexpr` walker (expression.jl). A derived buffer
# (`centroid = num/den`) is recognised by its body reading an upstream VI buffer
# name.
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
# (a skolem/arg-witness `:map`, a `:producer`, or a downstream grouped/derived
# `chain` buffer). These are the buffers a value-invention key GATHERS from at
# build time — the coordinate buffers a bin-Skolem broad phase bins on
# (`src_lon`/`tgt_lon`). Used by the build-time binning-coordinate derivation to
# decide which build-time-constant coordinate observeds to materialise into the
# value-invention `const_arrays` so `index(src_lon,i)` resolves (RFC §8.6.1).
# Empty (byte-identical) for a model without value invention.
function _vi_skolem_index_targets(model::Model)
    det = _vi_detect(model)
    refs = Set{String}()
    for (_, node) in det.maps
        _vi_index_targets!(refs, node)
    end
    for (_, node) in det.producers
        _vi_index_targets!(refs, node)
    end
    for (_, node, _) in det.chain
        _vi_index_targets!(refs, node)
    end
    return refs
end

# The group KEY of a GROUPED reduction, or `nothing`. The SCVT group-by signature
# is precise: a single-output-index `aggregate` whose `join` pairs the OUTPUT
# index symbol with an already-known value-invention buffer (`num[g] = … join on
# [["assign","g"]]` ⇒ key `assign`). This is deliberately narrower than "any join
# touching a VI buffer" — a relational gather that joins two VI bin buffers to
# EACH OTHER (`A_j = … join on [["src_bin","tgt_bin"]]`, the conservative
# regridder) pairs neither column with its output index and is NOT a grouped
# value-invention reduction; it stays an ordinary aggregate on the simulate path.
function _vi_grouped_key(node::OpExpr, vi_var_names)
    node.op == "aggregate" || return nothing
    oi = node.output_idx === nothing ? Any[] : node.output_idx
    length(oi) == 1 || return nothing
    gsym = String(oi[1])
    join = node.join
    join === nothing && return nothing
    # Typed join clauses (parse.jl `_coerce_join`): a bin-equality clause is a
    # vector of `(left, right)` key-column pairs (no `on` wrapper); a Phase-2a
    # `overlap` clause is a `_OverlapJoinSpec` (not a pair vector) and never names
    # a grouped output key, so it is skipped.
    for clause in join
        clause isa AbstractVector || continue
        for pair in clause
            length(pair) == 2 || continue
            a, b = String(pair[1]), String(pair[2])
            a == gsym && b in vi_var_names && return b
            b == gsym && a in vi_var_names && return a
        end
    end
    return nothing
end

# True iff `node` is an elementwise DERIVED buffer over known value-invention
# buffers: a single-output-index `aggregate` with NO join and NO contraction (every
# range symbol is the output index) whose body reads an upstream VI buffer
# (`centroid[g] = num[g]/den[g]`). The no-contraction / no-join guard keeps a
# contracted or scalar aggregate (`mass_tgt = …`, output_idx `[]`) from being
# mistaken for the centroid map.
function _vi_is_derived(node::OpExpr, vi_var_names)
    node.op == "aggregate" || return false
    oi = node.output_idx === nothing ? Any[] : node.output_idx
    length(oi) == 1 || return false
    gsym = String(oi[1])
    node.join === nothing || return false
    all(==(gsym), keys(_vi_ranges(node))) || return false
    return !isempty(intersect(_vi_index_targets!(Set{String}(), node.expr_body),
                              vi_var_names))
end

"""
    _vi_detect(model::Model) -> (has_vi, vi_var_names, maps, producers, chain)

Scan a typed model for value-invention assignments. `vi_var_names` is the set of
LHS variables produced by skolem/distinct/rank/argmin (and the downstream grouped
reductions) — all excluded from the ODE state, as the geometry clip-ring vars are.
`maps`/`producers` are `(lhs, node)` pairs to materialise.

`chain` is the ordered list of `(lhs, node, kind)` build-time GROUPED / DERIVED
buffers downstream of an arg-witness assignment — the SCVT centroid step. A plain
numeric `aggregate` becomes value-invention by *data dependency*: if its `join`
names an already-known VI buffer it is a `:grouped` semiring reduction keyed on
that buffer (`num[g] = Σ_{p:assign=g} rho_p·x_p`); if its body merely reads VI
buffers it is a `:derived` elementwise buffer (`centroid[g] = num[g]/den[g]`). The
fixpoint discovery order is a valid materialisation (topological) order.
"""
function _vi_detect(model::Model)
    vi_var_names = Set{String}()
    maps = Tuple{String,OpExpr}[]
    producers = Tuple{String,OpExpr}[]
    candidates = Tuple{String,OpExpr}[]   # plain numeric aggregates — grouped/derived?
    for (lhs, rhs) in _vi_model_assignments(model)
        base = lhs isa AbstractString ? String(lhs) : _vi_typed_lhs_base(lhs)
        base === nothing && continue
        kind = _vi_node_kind(rhs)
        if kind == :none
            rhs isa OpExpr && rhs.op == "aggregate" && push!(candidates, (base, rhs))
            continue
        end
        push!(vi_var_names, base)   # every value-invention output leaves the ODE
        kind == :producer && push!(producers, (base, rhs))
        kind == :map && push!(maps, (base, rhs))
    end
    # Fixpoint over the data-dependency DAG: a candidate that depends on a known VI
    # buffer in the SCVT centroid shape is itself a build-time buffer. A `join`
    # pairing the output index with a VI buffer ⇒ :grouped; an elementwise body
    # reading a VI buffer ⇒ :derived. Both signatures are narrow (see the helpers)
    # so ordinary model aggregates — including the regridder's bin-to-bin gather —
    # are left on the simulate path.
    chain = Tuple{String,OpExpr,Symbol}[]
    changed = true
    while changed
        changed = false
        rest = Tuple{String,OpExpr}[]
        for (base, node) in candidates
            if _vi_grouped_key(node, vi_var_names) !== nothing
                push!(vi_var_names, base); push!(chain, (base, node, :grouped)); changed = true
            elseif _vi_is_derived(node, vi_var_names)
                push!(vi_var_names, base); push!(chain, (base, node, :derived)); changed = true
            else
                push!(rest, (base, node))
            end
        end
        candidates = rest
    end
    has_vi = !isempty(maps) || !isempty(producers) || !isempty(chain)
    return (has_vi=has_vi, vi_var_names=vi_var_names, maps=maps, producers=producers,
            chain=chain)
end

# ---- Build-time evaluation context -----------------------------------------

struct _ViCtx
    const_arrays::Dict{String,Any}
    params::Dict{String,Float64}
    index_sets::Dict{String,IndexSet}
    variables::Dict{String,ModelVariable}
    maps::Dict{String,Dict{Any,Any}}   # materialised map var → (output-index → value)
end

# Coerce a build-time numeric to an exact integer relational key component
# (CONFORMANCE_SPEC.md §5.5.1 rule 1: no floats in keys). A non-integral float is
# a misuse — fail loudly rather than emit a non-deterministic key.
function _vi_key_int(x)
    isa(x, Integer) && return Int(x)
    if isa(x, AbstractFloat)
        isinteger(x) || throw(TreeWalkError("E_TREEWALK_VI_FLOAT_KEY",
            "value-invention key component $(repr(x)) is not integer-valued; relational " *
            "keys must be integer / categorical IDs (CONFORMANCE_SPEC.md §5.5.1 rule 1)"))
        return Int(x)
    end
    throw(TreeWalkError("E_TREEWALK_VI_KEY", "non-numeric key component $(repr(x))"))
end

# Resolve a scalar parameter value (dx/dy/atol …) from overrides-or-default.
function _vi_param(ctx::_ViCtx, name::AbstractString)
    haskey(ctx.params, name) && return ctx.params[name]
    v = get(ctx.variables, name, nothing)
    if v !== nothing && v.default !== nothing
        return Float64(v.default)
    end
    throw(TreeWalkError("E_TREEWALK_VI_PARAM",
        "value-invention scalar parameter '$name' has no override or default"))
end

# Evaluate a value-invention node that MUST reduce to a build-time number.
# `_vi_eval`'s `VarExpr` arm 4 returns an unresolved bare name verbatim; it has
# NO legitimate value context (the former `skolem` relation tag now lives in the
# node's `label` field, not in `args`). Guard arithmetic / index contexts so a
# typo'd range symbol, const-array factor, or scalar-parameter name fails closed
# with a structured code instead of an opaque `Float64("…")` / `Int("…")`
# ArgumentError.
function _vi_num(node, ctx::_ViCtx, bindings::AbstractDict)
    v = _vi_eval(node, ctx, bindings)
    isa(v, Real) && return v
    throw(TreeWalkError("E_TREEWALK_VI_SYMBOL",
        "value-invention expression requires a build-time number here but got " *
        "$(repr(v)); an unresolved name (range symbol, const-array factor, or " *
        "scalar parameter) degraded to a relation tag"))
end

# Evaluate a typed value-invention sub-expression. Returns an Int / Float64 /
# Bool / String tag / Tuple key, depending on the op. Exact-integer semantics
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
        #      legitimate value context — the former `skolem` relation tag now
        #      lives in the node's `label` field, not in `args`.
        # Every downstream context fails closed on such a string: `_vi_num` guards
        # the arithmetic and index arms and `_vi_key_int` guards key components
        # (including EVERY `skolem` arg, now that `args` are pure key components),
        # each raising a structured E_TREEWALK_VI_* code rather than an opaque
        # cast error.
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
        elseif op == "skolem"
            return _vi_skolem(node, ctx, bindings)
        elseif op == "true"
            return true
        elseif op == "false"
            return false
        elseif op == "floor"
            return floor(Int, Float64(_vi_num(args[1], ctx, bindings)))
        elseif op == "ceil"
            return ceil(Int, Float64(_vi_num(args[1], ctx, bindings)))
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
        throw(TreeWalkError("E_TREEWALK_VI_OP",
            "value-invention build-time evaluator does not support op '$op'"))
    end
    throw(TreeWalkError("E_TREEWALK_VI_NODE", "unevaluable value-invention node $(repr(node))"))
end

# index(factor, i, …): gather from a const-array factor (1-based). The factor is
# build-time data supplied in `const_arrays`. A name that resolves to an already-
# materialised value-invention buffer (an arg-witness assignment or an upstream
# grouped/derived buffer in `ctx.maps`) is read from that buffer instead — this is
# what lets a derived buffer read its inputs, e.g. `centroid[g] = num[g]/den[g]`.
function _vi_index(node::OpExpr, ctx::_ViCtx, bindings::AbstractDict)
    args = node.args
    name = !isempty(args) && args[1] isa VarExpr ? args[1].name : nothing
    if name !== nothing && haskey(ctx.maps, name)
        length(args) == 2 || throw(TreeWalkError("E_TREEWALK_VI_INDEX",
            "materialised value-invention buffer '$name' is a 1-D buffer; expected one " *
            "index, got $(length(args) - 1)"))
        idx = _vi_key_int(_vi_eval(args[2], ctx, bindings))
        haskey(ctx.maps[name], idx) || throw(TreeWalkError("E_TREEWALK_VI_INDEX",
            "materialised value-invention buffer '$name' has no entry at index $idx"))
        return ctx.maps[name][idx]
    end
    name !== nothing && haskey(ctx.const_arrays, name) ||
        throw(TreeWalkError("E_TREEWALK_VI_INDEX",
            "value-invention index target '$(repr(name === nothing ? (isempty(args) ? nothing : args[1]) : name))' " *
            "must be a const-array factor or an already-materialised value-invention buffer"))
    arr = ctx.const_arrays[name]
    idxs = Tuple(Int(_vi_num(a, ctx, bindings)) for a in args[2:end])
    # A factor carrying a declared per-dimension boundary policy resolves an
    # out-of-range gather declaratively (periodic-wrap / edge-extend), exactly
    # as the tree_walk const_array gather does (ess-gj4). Plain factors keep the
    # existing behavior, so genuine connectivity OOB still surfaces.
    if isa(arr, BoundedConstArray)
        ndims(arr) == length(idxs) ||
            throw(TreeWalkError("E_TREEWALK_CONSTARRAY_NDIM",
                "const array '$(name)' is $(ndims(arr))D but got $(length(idxs)) indices"))
        idxs = ntuple(d -> _resolve_const_index(arr, String(name), d, idxs[d], size(arr, d)),
                      length(idxs))
    end
    return arr[idxs...]
end

# skolem(c1, c2, …) → the canonical key tuple. The documentary relation tag (the
# "sort"/relation name) lives in the node's optional `label` field, read at parse
# time for provenance ONLY and NEVER part of the emitted key. Every `args` entry
# is a PURE key component, coerced to an exact integer ID via `_vi_key_int` — a
# non-key value (e.g. a mis-placed tag string) fails closed rather than being
# silently stripped (§5.5.1 rule 4). This keeps the materialised set
# byte-identical to the M3 determinism golden (edges `[[1,2],…]`, candidate pairs
# `(i,j)`), which carry no tag (the `Relational.skolem_edge` / projected-pair
# form). A single component degrades to a scalar key.
function _vi_skolem(node::OpExpr, ctx::_ViCtx, bindings::AbstractDict)
    comps = Any[_vi_eval(a, ctx, bindings) for a in node.args]
    key = Tuple(_vi_key_int(c) for c in comps)
    length(key) == 1 && return key[1]
    return key
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
        progressed || throw(TreeWalkError("E_TREEWALK_VI_RANGE_CYCLE",
            "value-invention ranges have a cyclic `of` dependency: $(remaining)"))
    end
    return ordered
end

# The element values a range symbol binds to, given the current bindings.
# interval/categorical → 1-based positions; ragged → the MEMBER values gathered
# from the set's `values` factor sliced by its `offsets` factor (so a range
# symbol over `face_vertices` binds to the vertex IDs of the parent face, §5.2).
function _vi_range_values(spec, ctx::_ViCtx, bindings::AbstractDict)
    spec isa IndexSetRef || throw(TreeWalkError("E_TREEWALK_VI_RANGE",
        "value-invention range must reference a declared index set " *
        "(`{from: <name>}`); got $(repr(spec))"))
    is = get(ctx.index_sets, spec.from, nothing)
    is === nothing && throw(TreeWalkError("E_TREEWALK_VI_RANGE",
        "value-invention range references undeclared index set '$(spec.from)'"))
    if is.kind == "interval"
        return collect(1:Int(is.size))
    elseif is.kind == "categorical"
        return collect(1:length(is.members))
    elseif is.kind == "ragged"
        of = _vi_range_of(spec)
        isempty(of) && throw(TreeWalkError("E_TREEWALK_VI_RANGE",
            "ragged value-invention range '$(spec.from)' needs an `of` parent"))
        parent = Int(bindings[of[1]])
        offs = ctx.const_arrays[is.offsets]
        vals = ctx.const_arrays[is.values]
        nmem = Int(offs[parent])
        return Any[_vi_key_int(vals[parent, l]) for l in 1:nmem]
    end
    throw(TreeWalkError("E_TREEWALK_VI_RANGE",
        "value-invention range over index set kind '$(repr(is.kind))' is unsupported"))
end

# Enumerate every full binding of an aggregate's `ranges`, calling `cb(bindings)`
# at each leaf (bindings is reused — copy if retained).
function _vi_enumerate(ranges, ctx::_ViCtx, cb)
    syms = _vi_order_syms(ranges)
    bindings = Dict{String,Any}()
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
        delete!(bindings, s)
    end
    rec(1)
    return
end

# ---- Materialisation -------------------------------------------------------

# The index range symbol of a join-key variable within the producer's ranges:
# the producer range whose `from` equals the variable's (1-D) shape index set.
function _vi_join_index_sym(vname, producer_ranges, ctx::_ViCtx)
    v = get(ctx.variables, vname, nothing)
    v === nothing && throw(TreeWalkError("E_TREEWALK_VI_JOIN",
        "join references unknown variable '$(vname)'"))
    shape = v.shape === nothing ? String[] : v.shape
    length(shape) == 1 || throw(TreeWalkError("E_TREEWALK_VI_JOIN",
        "value-invention join key '$(vname)' must be a 1-D buffer; shape=$(shape)"))
    target = shape[1]
    for (sym, spec) in producer_ranges
        spec isa IndexSetRef && spec.from == target && return sym
    end
    throw(TreeWalkError("E_TREEWALK_VI_JOIN",
        "no producer range binds the index set '$(target)' of join key '$(vname)'"))
end

# One resolved value-invention join gate (built ONCE per producer/arg-witness,
# not per tuple). A bin-EQUALITY gate carries the two materialised map buffers
# (`map_l`/`map_r`) and admits iff the buffer values are equal; an OVERLAP gate
# (Phase 2a) carries `candidates`, the prebuilt broad-phase `(pos_l,pos_r)` set,
# and admits iff the binding's range positions are a member.
struct _ViJoinGate
    sym_l::String
    sym_r::String
    map_l::Union{Dict{Any,Any},Nothing}
    map_r::Union{Dict{Any,Any},Nothing}
    candidates::Union{Set{Tuple{Int,Int}},Nothing}
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
# factor's 1-D shape index set (`_vi_join_index_sym`, exactly like an `on` key
# column) and builds its candidate set from the const-array envelope factors.
function _vi_resolve_join(join, producer_ranges, ctx::_ViCtx)
    gates = _ViJoinGate[]
    for clause in join
        if clause isa _OverlapJoinSpec
            sym_l = _vi_join_index_sym(clause.src_env[1], producer_ranges, ctx)
            sym_r = _vi_join_index_sym(clause.tgt_env[1], producer_ranges, ctx)
            cands = _overlap_candidate_set(_vi_env_vectors(clause.src_env, ctx),
                                           _vi_env_vectors(clause.tgt_env, ctx);
                                           eps=clause.eps)
            push!(gates, _ViJoinGate(sym_l, sym_r, nothing, nothing, cands))
        else
            for pair in clause
                lname, rname = String(pair[1]), String(pair[2])
                ls = _vi_join_index_sym(lname, producer_ranges, ctx)
                rs = _vi_join_index_sym(rname, producer_ranges, ctx)
                push!(gates, _ViJoinGate(ls, rs, ctx.maps[lname], ctx.maps[rname], nothing))
            end
        end
    end
    return gates
end

# True iff every resolved join gate admits this binding (§5.3 / Phase 2a): a
# bin-equality gate compares materialised buffer values; an overlap gate tests
# membership of the `(pos_l,pos_r)` range positions in the broad-phase set.
function _vi_join_ok(gates::Vector{_ViJoinGate}, bindings::AbstractDict)
    for g in gates
        if g.candidates === nothing
            g.map_l[bindings[g.sym_l]] == g.map_r[bindings[g.sym_r]] || return false
        else
            (bindings[g.sym_l], bindings[g.sym_r]) in g.candidates || return false
        end
    end
    return true
end

# Instrumentation: number of leaf bindings the enumerator VISITED (a tuple the
# callback was invoked on). Reset by callers/tests; proves the overlap-gated
# producer visits O(|candidates|·∏ungated) tuples, NOT the full O(∏ranges)
# product (projection-pushdown Wall #1).
const _VI_ENUM_VISITS = Ref{Int}(0)

# The first OVERLAP join gate (the one carrying a prebuilt `(query_pos, cell_pos)`
# candidate set) among the resolved gates, or `nothing` if none. This is the gate
# whose candidate pairs DRIVE enumeration: an overlap gate resolves its entire
# admissible pair set ONCE (`_vi_resolve_join`), so we can iterate those pairs
# directly instead of testing every product tuple for membership.
function _vi_overlap_driver(gates::Union{Vector{_ViJoinGate},Nothing})
    gates === nothing && return nothing
    for g in gates
        g.candidates === nothing || return g
    end
    return nothing
end

# Enumerate an aggregate's `ranges`, DRIVING from an OVERLAP gate's prebuilt
# candidate pairs when one is present (Wall #1 fix). Instead of building the full
# `Iterators.product` over every range and membership-testing each tuple —
# O(∏ranges), e.g. O(N_query·N_cell) — iterate ONLY the gate's `(query_pos,
# cell_pos)` candidate pairs, bind the two gated range symbols from each pair, and
# take the cartesian product with any OTHER (ungated) ranges. Cost drops to
# O(|candidates|·∏ungated); with both gated symbols the only ranges (the ISRM
# emis×cells producer) that is O(|candidates|).
#
# With NO overlap gate this is EXACTLY `_vi_enumerate` — byte-for-byte identical
# enumeration order and leaf set (bin-equality / ungated producers are untouched).
# The callback is identical in both paths and STILL applies the narrow `filter`
# and the full `_vi_join_ok` re-check downstream, so the overlap-gated leaf set
# differs from the full product only by provably-non-candidate tuples the
# membership test would have rejected anyway — the materialised member SET (after
# `distinct` canonicalises order) is identical to the old full-product path.
function _vi_enumerate_join(ranges, gates::Union{Vector{_ViJoinGate},Nothing},
                            ctx::_ViCtx, cb)
    counted = bindings -> (_VI_ENUM_VISITS[] += 1; cb(bindings))
    ov = _vi_overlap_driver(gates)
    if ov === nothing
        _vi_enumerate(ranges, ctx, counted)   # full product — unchanged behaviour
        return
    end
    sym_l, sym_r = ov.sym_l, ov.sym_r
    # DETERMINISTIC (query_pos, cell_pos)-ascending drive order. The member set is
    # canonicalised downstream (`distinct`/`rank`), but a sorted drive keeps any
    # order-sensitive `⊕` reduction stable.
    pairs = sort!(collect(ov.candidates))
    # The remaining ungated symbols, in the SAME topological order the full product
    # visits them (ragged `of` parents before children), minus the two driven
    # symbols. Overlap-gated symbols index a 1-D buffer (interval/categorical), so
    # they are never ragged `of` parents — pre-binding them is order-safe.
    rest = filter(s -> s != sym_l && s != sym_r, _vi_order_syms(ranges))
    bindings = Dict{String,Any}()
    function rec(k)
        if k > length(rest)
            counted(bindings)
            return
        end
        s = rest[k]
        for v in _vi_range_values(ranges[s], ctx, bindings)
            bindings[s] = v
            rec(k + 1)
        end
        delete!(bindings, s)
    end
    # A candidate pair holds 1-based range POSITIONS; for an interval/categorical
    # range `_vi_range_values` binds position p to the value p, so binding the two
    # gated symbols directly reproduces exactly the tuple the old product bound at
    # those positions (and which `_vi_join_ok` admitted).
    for (pl, pr) in pairs
        bindings[sym_l] = pl
        bindings[sym_r] = pr
        rec(1)
    end
    return
end

# Arg-witness reducer (RFC §5.7 rule 6). Over the inner contracted `ranges`
# (which EXTEND the outer map binding so `value` may read both the point and the
# candidate), evaluate the scalar `value` body at each candidate and return the
# `arg` index symbol's value at the optimum — `argmin` keeps the least value,
# `argmax` the greatest. The NORMATIVE tie-break is the SMALLEST arg (the
# smallest generator ID): equal values resolve to the lower candidate index, so
# the emitted integer buffer is byte-identical across bindings irrespective of
# enumeration order (the §5.7 byte-identical-determinism contract — this op's
# analogue of the `distinct` sorted-order / `rank` numbering rules). An optional
# `join` (a bin-Skolem broad-phase prune, §5.3) and/or `filter` restrict the
# candidate set; an empty candidate set is an error (no index witnesses an empty
# argmin — a point with no candidate generator is undefined).
function _vi_argreduce(node::OpExpr, ctx::_ViCtx, outer_bindings::AbstractDict, outer_ranges)
    op = node.op
    inner_ranges = _vi_ranges(node)
    arg_sym = node.arg
    arg_sym === nothing && throw(TreeWalkError("E_TREEWALK_VI_ARG",
        "arg-witness op '$op' requires an `arg` naming the witnessing index symbol"))
    arg_sym = String(arg_sym)
    value_expr = node.expr_body
    value_expr === nothing && throw(TreeWalkError("E_TREEWALK_VI_ARG",
        "arg-witness op '$op' requires an `expr` body (the scalar to optimise)"))
    haskey(inner_ranges, arg_sym) || throw(TreeWalkError("E_TREEWALK_VI_ARG",
        "arg-witness `arg`='$arg_sym' must name one of the contracted `ranges` symbols"))
    haskey(outer_bindings, arg_sym) && throw(TreeWalkError("E_TREEWALK_VI_ARG",
        "arg-witness `arg`='$arg_sym' shadows an outer index symbol"))
    filt = node.filter
    join = node.join
    # Combined ranges so a `join` column over an OUTER-indexed map buffer (the
    # point's bin) resolves alongside the inner candidate's bin (§5.3 equi-join).
    # `Base.merge` — the module shadows `merge` with an `EsmFile` method.
    combined = Base.merge(Dict{String,Any}(outer_ranges), Dict{String,Any}(inner_ranges))
    # Resolve the join gates ONCE (broad-phase candidate set / buffer bindings are
    # shared across every candidate tuple), not per `rec` leaf.
    join_gates = join === nothing ? nothing : _vi_resolve_join(join, combined, ctx)
    syms = _vi_order_syms(inner_ranges)
    bindings = Dict{String,Any}(outer_bindings)
    best_val = nothing
    best_arg = nothing
    function rec(k)
        if k > length(syms)
            if filt !== nothing
                fv = _vi_eval(filt, ctx, bindings)
                (fv === true || (isa(fv, Real) && fv > 0)) || return
            end
            if join_gates !== nothing && !_vi_join_ok(join_gates, bindings)
                return
            end
            v = Float64(_vi_eval(value_expr, ctx, bindings))
            a = _vi_key_int(bindings[arg_sym])
            if best_arg === nothing
                best_val = v; best_arg = a
            else
                better = op == "argmax" ? (v > best_val) : (v < best_val)
                # Strict improvement OR an exact tie resolved to the smaller arg.
                if better || (v == best_val && a < best_arg)
                    best_val = v; best_arg = a
                end
            end
            return
        end
        s = syms[k]
        for val in _vi_range_values(inner_ranges[s], ctx, bindings)
            bindings[s] = val
            rec(k + 1)
        end
        delete!(bindings, s)
    end
    rec(1)
    best_arg === nothing && throw(TreeWalkError("E_TREEWALK_VI_ARGEMPTY",
        "arg-witness op '$op' has an empty candidate set; no index witnesses the " *
        "optimum (a point with no candidate generator is undefined)"))
    return best_arg
end

# Materialise a per-element value-invention map var → Dict(output-index → value).
function _vi_materialize_map!(ctx::_ViCtx, vname::AbstractString, node::OpExpr)
    output_idx = node.output_idx === nothing ? Any[] : node.output_idx
    length(output_idx) == 1 || throw(TreeWalkError("E_TREEWALK_VI_MAP",
        "value-invention map '$(vname)' must have a single output index; got $(output_idx)"))
    body = node.expr_body
    body === nothing && throw(TreeWalkError("E_TREEWALK_VI_MAP",
        "value-invention map '$(vname)' has no `expr` body"))
    outer_ranges = _vi_ranges(node)
    is_arg = body isa OpExpr && body.op in _VI_ARGWITNESS_OPS
    out = Dict{Any,Any}()
    sym = String(output_idx[1])
    _vi_enumerate(outer_ranges, ctx, bindings -> begin
        # An arg-witness body runs the inner reduction (with the outer point bound)
        # and emits the witnessing INDEX; an ordinary body (skolem) emits its value.
        out[bindings[sym]] = is_arg ? _vi_argreduce(body, ctx, bindings, outer_ranges) :
                                      _vi_eval(body, ctx, bindings)
    end)
    ctx.maps[vname] = out
    return out
end

# Materialise an index-set-producing aggregate → the distinct member set (§5.5
# sorted total order, via the Relational engine). Returns the member vector.
function _vi_materialize_producer(ctx::_ViCtx, node::OpExpr)
    key = node.key
    key === nothing && throw(TreeWalkError("E_TREEWALK_VI_PRODUCER",
        "value-invention producer aggregate requires a `key` (§5.5)"))
    ranges = _vi_ranges(node)
    filt = node.filter
    join = node.join
    # Resolve join gates ONCE (a `join.overlap` broad-phase candidate set is built
    # a single time here). An OVERLAP gate then DRIVES enumeration from its
    # candidate pairs (`_vi_enumerate_join`, Wall #1) — O(|candidates|) rather than
    # O(∏ranges) with a per-tuple membership test; other gate kinds enumerate the
    # full product exactly as before.
    join_gates = join === nothing ? nothing : _vi_resolve_join(join, ranges, ctx)
    members = Any[]
    _vi_enumerate_join(ranges, join_gates, ctx, bindings -> begin
        if filt !== nothing
            fv = _vi_eval(filt, ctx, bindings)
            (fv === true || (isa(fv, Real) && fv > 0)) || return
        end
        if join_gates !== nothing && !_vi_join_ok(join_gates, bindings)
            return
        end
        push!(members, _vi_skolem(key, ctx, bindings))
    end)
    return Relational.distinct(members)
end

# ---- Cadence classification on the typed IR (§5.7 guard 2) ------------------
#
# The lattice `const ⊏ discrete ⊏ continuous` as integer ranks; `class(node) =
# max` over its children's classes, seeded from a leaf's declared variable kind
# (CONFORMANCE_SPEC §5.7.2). This is the value-invention front door's OWN typed
# classifier — the raw-JSON `Cadence` module is conformance-fixture-only (its
# `expect_cadence` vocabulary is deliberately not parsed into the typed IR).
# Only the CONTINUOUS-vs-not distinction is observable here (every check below
# compares against `continuous`), so the loader-temporal `discrete → const`
# refinement of the conformance classifier — which never crosses the continuous
# boundary — is deliberately not replicated.
const _VI_CLASS_CONST = 0
const _VI_CLASS_DISCRETE = 1
const _VI_CLASS_CONTINUOUS = 2
const _VI_NO_OVERRIDES = Dict{String,Int}()

function _vi_seed_class(name::AbstractString,
                        variables::Dict{String,ModelVariable},
                        overrides::Dict{String,Int})
    name == "t" && return _VI_CLASS_CONTINUOUS   # the independent variable
    cls = get(overrides, name, nothing)
    cls === nothing || return cls                # re-typed VI map buffer (§6.1)
    v = get(variables, name, nothing)
    # index-set name, bound index symbol (i, k, e, f), or relation tag — const.
    v === nothing && return _VI_CLASS_CONST
    (v.type == StateVariable || v.type == BrownianVariable) && return _VI_CLASS_CONTINUOUS
    v.type == DiscreteVariable && return _VI_CLASS_DISCRETE
    return _VI_CLASS_CONST                       # parameter / observed
end

# Derive a typed expression's cadence class: max over the generated child walk
# (`foreach_child`, expression.jl — every expression-bearing `OpExpr` field).
function _vi_class(expr::ASTExpr, variables::Dict{String,ModelVariable},
                   overrides::Dict{String,Int})::Int
    expr isa VarExpr && return _vi_seed_class(expr.name, variables, overrides)
    expr isa OpExpr || return _VI_CLASS_CONST    # IntExpr / NumExpr literals
    cls = _VI_CLASS_CONST
    foreach_child(expr) do c
        cls = max(cls, _vi_class(c, variables, overrides))
    end
    return cls
end

# Per-map-var class overrides: a value-invention MAP output (e.g. `src_bin`) is a
# setup-materialised buffer, so its cadence is `class(its definition)` per §6.1
# (max over inputs) — NOT the seed of its declared `state` kind. Each map var is
# re-seeded to its body's class (derived against the UN-overridden variable
# table) so the §5.7 guard 2 below classifies a producer/arg-witness that joins
# on it correctly (a CONST-derived bin map passes; a genuinely state-dependent
# one keeps its declared seed and still classifies CONTINUOUS → reject).
function _vi_map_class_overrides(model::Model, maps)
    overrides = Dict{String,Int}()
    for (vname, node) in maps
        haskey(model.variables, vname) || continue
        body = node.expr_body
        body === nothing && continue
        bcls = _vi_class(body, model.variables, _VI_NO_OVERRIDES)
        bcls == _VI_CLASS_CONTINUOUS && continue   # keep the declared seed
        overrides[vname] = bcls
    end
    return overrides
end

# ---- Grouped / derived build-time buffers (the SCVT centroid step) ----------

# The ⊕ reducing function for a grouped semiring aggregate. `bool_and_or` (⊕=`or`)
# is index-set-producing, not a numeric grouped reduction (mirrors the array path's
# §5.5 reject), so only the four numeric ⊕s are accepted.
function _vi_oplus_fn(spelling::AbstractString)
    spelling == "+"   && return +
    spelling == "*"   && return *
    spelling == "max" && return max
    spelling == "min" && return min
    throw(TreeWalkError("E_TREEWALK_VI_SEMIRING",
        "grouped value-invention reduction ⊕='$spelling' is unsupported; expected one of " *
        "+, *, max, min (a numeric semiring — not the index-set-producing bool_and_or)"))
end

# §5.7 guard 2 for grouped / derived buffers: a build-time reduction may read only
# build-time data — const-array factors (parameters) and already-materialised VI
# buffers. Reading a live ODE `state` variable would make the buffer a per-step
# (continuous) quantity, out of scope for v1 (the Lloyd/SCVT outer loop re-invokes
# the build with updated generators instead of folding it into the hot path).
function _vi_assert_buildtime(ctx::_ViCtx, vname, node, vi_var_names)
    for r in _vi_index_targets!(Set{String}(), node)
        r in vi_var_names && continue            # an already-materialised VI buffer
        haskey(ctx.const_arrays, r) && continue  # a build-time const-array factor
        v = get(ctx.variables, r, nothing)
        v !== nothing && v.type == StateVariable && throw(TreeWalkError(
            "E_TREEWALK_VI_CONTINUOUS",
            "grouped/derived value-invention buffer '$vname' reads live state '$r' — a " *
            "build-time reduction's inputs must be CONST/DISCRETE factors or materialised " *
            "buffers (RFC §5.7 guard 2)"))
    end
    return
end

# Materialise a GROUPED semiring aggregate keyed on a value-invention buffer →
# Dict(output-index → value). For each output `g`, fold (with the semiring ⊕) the
# body over the contracted points whose group KEY (`assign[p]`, the arg-witness
# buffer) equals `g`. The reduction runs through the determinism-correct
# `Relational.group_aggregate` (§5.5 rule 5: bucket by key, sorted by canonical
# key, per-bucket float ⊕ sequential in canonical value order) — the first time
# the front-door calls it (it was a library helper only). Empty groups fold to 0̄.
function _vi_materialize_grouped!(ctx::_ViCtx, vname::AbstractString, node::OpExpr)
    output_idx = node.output_idx === nothing ? Any[] : node.output_idx
    length(output_idx) == 1 || throw(TreeWalkError("E_TREEWALK_VI_GROUP",
        "grouped value-invention aggregate '$vname' must have a single output index; got $(output_idx)"))
    gsym = String(output_idx[1])
    ranges = _vi_ranges(node)
    haskey(ranges, gsym) || throw(TreeWalkError("E_TREEWALK_VI_GROUP",
        "grouped aggregate '$vname' output index '$gsym' is not among its `ranges`"))
    body = node.expr_body
    body === nothing && throw(TreeWalkError("E_TREEWALK_VI_GROUP",
        "grouped aggregate '$vname' has no `expr` body"))
    join = node.join
    join === nothing && throw(TreeWalkError("E_TREEWALK_VI_GROUP",
        "grouped aggregate '$vname' needs a `join` pairing its group-key buffer with '$gsym'"))
    # The group KEY buffer: the join column (paired with the output index `gsym`)
    # that names a materialised VI buffer (`assign`). It is read at the contraction
    # symbol that ranges over its 1-D index set.
    keyvar = nothing
    for clause in join
        clause isa AbstractVector || continue   # a Phase-2a overlap clause pairs no group key
        for pair in clause
            a, b = String(pair[1]), String(pair[2])
            b == gsym && haskey(ctx.maps, a) && (keyvar = a)
            a == gsym && haskey(ctx.maps, b) && (keyvar = b)
        end
    end
    keyvar === nothing && throw(TreeWalkError("E_TREEWALK_VI_GROUP",
        "grouped aggregate '$vname' `join` must pair a materialised value-invention " *
        "buffer with the output index '$gsym'"))
    keysym = _vi_join_index_sym(keyvar, ranges, ctx)
    oplus_str, zerobar = _aggregate_oplus_identity(node.semiring, node.reduce)
    op = _vi_oplus_fn(oplus_str)
    # Contraction ranges: every range symbol except the output index.
    contract = Dict{String,Any}(s => spec for (s, spec) in ranges if s != gsym)
    rows = Tuple{Any,Float64}[]
    _vi_enumerate(contract, ctx, bindings -> push!(rows,
        (ctx.maps[keyvar][bindings[keysym]], Float64(_vi_eval(body, ctx, bindings)))))
    agg = Dict{Any,Any}(Relational.group_aggregate(rows; key=first, value=last, op=op))
    # Densify over the output index set; a generator with no assigned point is 0̄.
    out = Dict{Any,Any}()
    for g in _vi_range_values(ranges[gsym], ctx, Dict{String,Any}())
        out[g] = Float64(get(agg, g, zerobar))
    end
    ctx.maps[vname] = out
    return out
end

# Materialise a DERIVED elementwise buffer (`centroid[g] = num[g]/den[g]`) →
# Dict(output-index → value). A per-output map whose body reads upstream
# materialised buffers (resolved by `_vi_index` from `ctx.maps`).
function _vi_materialize_derived!(ctx::_ViCtx, vname::AbstractString, node::OpExpr)
    output_idx = node.output_idx === nothing ? Any[] : node.output_idx
    length(output_idx) == 1 || throw(TreeWalkError("E_TREEWALK_VI_DERIVED",
        "derived value-invention aggregate '$vname' must have a single output index; got $(output_idx)"))
    gsym = String(output_idx[1])
    ranges = _vi_ranges(node)
    body = node.expr_body
    body === nothing && throw(TreeWalkError("E_TREEWALK_VI_DERIVED",
        "derived value-invention aggregate '$vname' has no `expr` body"))
    out = Dict{Any,Any}()
    _vi_enumerate(ranges, ctx, bindings -> (out[bindings[gsym]] =
        Float64(_vi_eval(body, ctx, bindings))))
    ctx.maps[vname] = out
    return out
end

"""
    materialize_value_invention(model::Model, index_sets, const_arrays, params)
        -> NamedTuple

Run the build-time value-invention engine over a typed model. `index_sets` is
the document-scoped registry (`EsmFile.index_sets`; esm-spec v0.8.0 — a typed
`Model` does not carry it). Returns:

- `extents::Dict{String,Int}` — `from_faq` producer id → derived index-set
  cardinality (the dense extent `[1, n]` the tree-walk resolver consumes).
- `members::Dict{String,Vector}` — `from_faq` producer id → the distinct member
  tuples in §5.5.1 sorted order (for byte-identity assertions).
- `assignments::Dict{String,Vector{Int}}` — arg-witness map var → the integer
  nearest-generator INDEX buffer, dense in output-index order (the SCVT
  assignment; §5.7 rule 6, byte-identical across bindings).
- `groups::Dict{String,Vector{Float64}}` — the downstream GROUPED / DERIVED
  buffers keyed on an arg-witness assignment, dense in output-index order: a
  grouped semiring reduction (`num[g] = Σ_{p:assign=g} rho_p·x_p`, run through
  `Relational.group_aggregate`, §5.5 rule 5) and an elementwise derived buffer
  (`centroid[g] = num[g]/den[g]`) — the SCVT centroid-update step.
- `vi_var_names::Set{String}` — value-invention LHS vars to drop from the ODE.
- `maps::Dict{String,Dict}` — materialised per-element map buffer (e.g. `src_bin`)
  → (1-based output position → bin-key value). A downstream FAQ's
  `join.on [[src_bin, tgt_bin]]` gates on these buffers (§5.3): the broad-phase
  bin key is data-derived, so it cannot be a categorical index-set member — the
  tree-walk join resolver reads the key value per position from here.
- `map_sets::Dict{String,String}` — map buffer → its 1-D shape index-set name,
  so the join resolver can find the range symbol the buffer is indexed by.

`const_arrays` supplies the build-time factor arrays (the connectivity / coords
the keys are computed from); `params` supplies scalar parameter overrides. A
producer (or arg-witness assignment) that classifies CONTINUOUS — or a grouped /
derived buffer reading live state — is rejected (§5.7 guard 2).
"""
function materialize_value_invention(model::Model, index_sets::AbstractDict,
                                     const_arrays::AbstractDict,
                                     params::AbstractDict)
    det = _vi_detect(model)
    extents = Dict{String,Int}()
    members = Dict{String,Vector{Any}}()
    assignments = Dict{String,Vector{Int}}()
    map_sets = Dict{String,String}()
    groups = Dict{String,Vector{Float64}}()
    det.has_vi || return (extents=extents, members=members, assignments=assignments,
                          groups=groups, vi_var_names=det.vi_var_names,
                          maps=Dict{String,Dict{Any,Any}}(), map_sets=map_sets)

    ctx = _ViCtx(
        Dict{String,Any}(String(k) => v for (k, v) in const_arrays),
        Dict{String,Float64}(String(k) => Float64(v) for (k, v) in params),
        Dict{String,IndexSet}(String(k) => v for (k, v) in index_sets),
        model.variables,
        Dict{String,Dict{Any,Any}}())

    # Cadence class overrides for the §5.7 guard-2 checks below (see
    # `_vi_map_class_overrides`): each value-invention MAP var re-seeds to its
    # body's derived class, so a producer/arg-witness joining on it classifies
    # by the buffer's true (input-derived) cadence rather than the seed of its
    # declared `state` kind (§6.1). Depends only on the model structure, so it
    # is built before materialisation.
    overrides = _vi_map_class_overrides(model, det.maps)

    # §5.7 guard 2 for arg-witness assignments: a state-dependent nearest-generator
    # buffer (continuous cadence) may not be materialised at build time — its
    # topology would change every step (out of scope for v1, like a continuous
    # `distinct`). The Lloyd/SCVT outer loop re-invokes the build with updated
    # generators; within one build the assignment is CONST/DISCRETE.
    for (vname, node) in det.maps
        body = node.expr_body
        (body isa OpExpr && body.op in _VI_ARGWITNESS_OPS) || continue
        _vi_class(node, ctx.variables, overrides) == _VI_CLASS_CONTINUOUS &&
            throw(TreeWalkError("E_TREEWALK_VI_CONTINUOUS",
                "arg-witness map '$vname' classifies CONTINUOUS — a build-time assignment " *
                "buffer's inputs must be CONST/DISCRETE (RFC §5.7 guard 2)"))
    end

    # Maps first (a producer's join/key — or an arg-witness `join` — may reference them).
    for (vname, node) in det.maps
        _vi_materialize_map!(ctx, vname, node)
        # Record the buffer's 1-D shape index set so a downstream FAQ's
        # `join.on [[vname, …]]` can find the range symbol it is indexed by.
        v = get(ctx.variables, vname, nothing)
        v === nothing && continue
        shape = v.shape === nothing ? String[] : v.shape
        length(shape) == 1 && (map_sets[vname] = String(shape[1]))
    end

    # Surface the arg-witness buffers (the integer nearest-generator INDEX
    # assignment), dense in output-index order, for byte-identity assertions and
    # the downstream grouped reduction the SCVT step consumes.
    for (vname, node) in det.maps
        body = node.expr_body
        (body isa OpExpr && body.op in _VI_ARGWITNESS_OPS) || continue
        m = ctx.maps[vname]
        assignments[vname] = Int[Int(m[k]) for k in sort!(collect(keys(m)))]
    end

    # The downstream GROUPED / DERIVED chain — the SCVT centroid step. Each buffer
    # is materialised in dependency order (`_vi_detect`'s fixpoint discovery order):
    # a `:grouped` semiring reduction keyed on a now-materialised arg-witness buffer
    # (`num[g]`/`den[g]`, via `Relational.group_aggregate` — the front-door's first
    # call of that previously library-only helper) and an elementwise `:derived`
    # buffer reading upstream buffers (`centroid[g] = num[g]/den[g]`). Each reads
    # only build-time data (guard 2). All are surfaced dense in output-index order.
    for (vname, node, kind) in det.chain
        _vi_assert_buildtime(ctx, vname, node, det.vi_var_names)
        kind == :grouped ? _vi_materialize_grouped!(ctx, vname, node) :
                           _vi_materialize_derived!(ctx, vname, node)
        m = ctx.maps[vname]
        groups[vname] = Float64[Float64(m[k]) for k in sort!(collect(keys(m)))]
    end

    # `from_faq` id → derived index-set name (so we only materialise producers a
    # derived set actually names; geometry producers are handled elsewhere).
    faq_to_set = Dict{String,String}()
    for (sname, is) in ctx.index_sets
        is.kind == "derived" || continue
        is.from_faq === nothing || (faq_to_set[String(is.from_faq)] = String(sname))
    end

    for (_, node) in det.producers
        id = node.id
        id === nothing && throw(TreeWalkError("E_TREEWALK_VI_PRODUCER",
            "value-invention producer aggregate requires an `id` naming it for `from_faq`"))
        id = String(id)
        haskey(faq_to_set, id) || continue   # no derived set names this producer
        # §5.7 guard 2: a relational node may not run on the hot path.
        _vi_class(node, ctx.variables, overrides) == _VI_CLASS_CONTINUOUS &&
            throw(TreeWalkError("E_TREEWALK_VI_CONTINUOUS",
                "value-invention producer '$id' classifies CONTINUOUS — it may not run per " *
                "step (RFC §5.7 guard 2); its inputs must be CONST/DISCRETE"))
        mem = _vi_materialize_producer(ctx, node)
        members[id] = mem
        extents[id] = length(mem)
    end

    return (extents=extents, members=members, assignments=assignments,
            groups=groups, vi_var_names=det.vi_var_names,
            maps=ctx.maps, map_sets=map_sets)
end
