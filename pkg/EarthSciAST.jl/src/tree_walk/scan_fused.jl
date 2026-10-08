# ========================================================================
# tree_walk/scan_fused.jl — a prefix scan's term and fold in one pass
#
# scan.jl splits a forward prefix reduction into a term pass (ordinary kernels
# that write each cell's term into its output slot) and a fold that walks the
# slots again and accumulates in place. In the in-place build that is two
# passes over the scan's slots, plus the kernel section's own pass, where a
# hand-written loop makes one: compute the term, add it to the running value,
# store. The fold is a chain of dependent operations and the term pass streams
# memory, so the extra pass is not hidden behind the fold; it costs its whole
# memory traffic.
#
# When a fold's terms come from ONE kernel whose cells are the fold's slots in
# the fold's own order (lane by lane, ascending along the scanned axis), the
# build compiles that kernel's loop nest with the fold inside it instead: per
# lane the nest runs the lane's cells, and each cell computes its term (the
# kernel's own emitted body, `_cg_emit_kernel_nest!` in scan mode), converts
# it as the store into `du` would, and folds it into the lane's running value
# in exactly `_scan_lanes!`'s order:
#
#   inclusive  acc = acc ⊕ term;  du[s] = acc
#   strict     du[s] = acc;       acc = acc ⊕ term
#
# with `acc` seeded at 0̄ at the start of each lane. The first cell of an
# inclusive lane is therefore `0̄ ⊕ term_1` and the first of a strict lane
# stores 0̄, as `_scan_lanes!` does; every value is the same bits.
#
# Threads split the lanes, as `_ScanChunk` does for an unfused fold: a lane is
# run whole, ascending, by one thread. A rank-1 scan is one lane and runs on
# one thread.
#
# The term kernel leaves the build's kernel list (so the kernel section does
# not also write the terms) only once its fused function has been emitted; a
# fold whose kernel the emitter declines keeps the two-pass form. The interpreter
# (`compiler = :interpreter`) and the out-of-place product never fuse.
#
# A CONSUMER. When the scan fills a materialized observed and a state equation
# reads that observed cell by cell (`du[i] = f(X[i], …)` with `f` reading
# nothing that depends on the cell's position but `oln`), the observed's fill
# level runs that state kernel too: right after the value of a cell is folded
# (where it is stored), the nest computes the consumer's cell from the value
# itself and stores it into the state `du` (the level writes through the
# two-buffer view, `_ObsSplitVec`). Each consumer cell is computed once, from
# the bits the store would have written, by the same emitted expression, so the
# values do not change. When nothing else in the build can read the observed,
# its store is dropped (`_scan_consumer_plan`).
# ========================================================================

# One fused scan: the generated function `f(du, u, p, t, tabs, ci, nc)`, which
# runs lanes `[a, b)` of chunk `ci` of `nc`, its tables, and its lane count.
struct _FusedScan{F,TB}
    f::F
    tabs::TB
    nlanes::Int
    tcache::_SecTCache
end

# The fold's slots are the kernel's output slots, in the kernel's own cell
# order (the order every nest emits a chunk's cells in).
function _scan_fusable(K::_AccKernel, S::_ScanFold)
    S.len >= 1 || return false
    cs = K.cells
    _cellset_ncells(cs) == length(S.slots) || return false
    slots = S.slots
    if _is_outs(cs)
        return cs.outs == slots
    elseif _is_contig(cs)
        return collect(cs.ranges[1]) == slots
    end
    k = 0
    for I in CartesianIndices(Tuple(cs.ranges))
        o = cs.base
        for d in eachindex(cs.strides)
            o += I[d] * cs.strides[d]
        end
        k += 1
        slots[k] == o || return false
    end
    return true
end

# The slots a cell set writes, in its cell order.
function _cellset_slots(cs::_CellSet)
    _is_outs(cs) && return copy(cs.outs)
    _is_contig(cs) && return collect(cs.ranges[1])
    out = Int[]
    for I in CartesianIndices(Tuple(cs.ranges))
        o = cs.base
        for d in eachindex(cs.strides)
            o += I[d] * cs.strides[d]
        end
        push!(out, o)
    end
    return out
end

# ---- The consumer of a fused scan ---------------------------------------------
# A consumer is `(K, ix, delta, store)`: the state kernel, the index of its one
# descriptor that reads the scanned observed (`u[oln + delta]`), and whether the
# observed is still stored.

# The descriptor kinds a consumer's body may read: each is addressed by `oln`
# (or nothing), so the body can run at the scan's cell with `oln` = the scan's
# slot minus `delta`.
const _SCAN_CONSUMER_KINDS = (_AK_SCALAR, _AK_STATE_AFFINE, _AK_CONST_AFFINE,
                              _AK_STATE_FIXED, _AK_ARR_FIXED)

# Whether a consumer's spine (or recipe) uses only leaves and plain operators:
# nothing addressed by the cell ordinal or the loop index, no reduction, no
# sub-kernel, no per-lane spec table.
function _scan_consumer_node_ok(nd::_Node)
    k = nd.kind
    if k === _NK_OP
        nd.payload === nothing || return false
    elseif !(k === _NK_ACCESS || k === _NK_LITERAL || k === _NK_PARAM ||
             k === _NK_TIME || k === _NK_CACHED)
        return false
    end
    return all(_scan_consumer_node_ok, nd.children)
end
_scan_node_reads(nd::_Node, ix::Int) =
    (nd.kind === _NK_ACCESS && nd.idx == ix) || any(c -> _scan_node_reads(c, ix), nd.children)

# The slot extent a state-reading descriptor of a kernel whose cells span
# `olnext` can read; `nothing` for one that reads no state, `(typemin, typemax)`
# when it is not known.
function _scan_desc_extent(a::_AccDesc, olnext)
    k = a.kind
    if k === _AK_STATE_AFFINE
        olnext === nothing && return (typemin(Int), typemax(Int))
        return (olnext[1] + a.delta, olnext[2] + a.delta)
    elseif k === _AK_STATE_FIXED
        return (a.idx, a.idx)
    elseif k === _AK_STATE_INDIRECT || k === _AK_STATE_INDIRECT_COL ||
           k === _AK_STATE_TBL_BOX
        isempty(a.conn) && return nothing
        lo, hi = typemax(Int), typemin(Int)
        for s in a.conn
            s == 0 && continue
            lo = min(lo, s); hi = max(hi, s)
        end
        return lo > hi ? nothing : (lo, hi)
    end
    return nothing
end
_scan_overlaps(e, lo::Int, hi::Int) = e !== nothing && e[1] <= hi && e[2] >= lo

# Whether any descriptor of `K` (sub-kernels included) other than `K.acc[skip]`
# may read a slot in `lo:hi`.
function _scan_kernel_reads(K::_AccKernel, lo::Int, hi::Int, skip::Int = 0,
                            olnext = _cg_oln_extent(K.cells))
    for (j, a) in enumerate(K.acc)
        j == skip && continue
        _scan_overlaps(_scan_desc_extent(a, olnext), lo, hi) && return true
    end
    # A sub-kernel runs at its parent's `oln`, which its own cells do not give.
    return any(S -> _scan_kernel_reads(S, lo, hi, 0, nothing), K.subs)
end

# The consumer of fold `S` among the state kernels `Ks`, or `nothing`: the one
# kernel that reads the observed's slots, through one affine descriptor that
# maps its cells onto the fold's slots one to one, with a body
# `_scan_consumer_node_ok` accepts.
function _scan_consumer(S::_ScanFold, Ks::AbstractVector{_AccKernel}, nst::Int)
    isempty(S.slots) && return nothing
    lo, hi = extrema(S.slots)
    found = nothing
    for K in Ks
        _scan_kernel_reads(K, lo, hi) || continue
        found === nothing || return nothing          # two readers
        found = K
    end
    found === nothing && return nothing
    K = found
    isempty(K.subs) || return nothing
    all(a -> a.kind in _SCAN_CONSUMER_KINDS, K.acc) || return nothing
    olnext = _cg_oln_extent(K.cells)
    # Its other reads are of the state: the consumer runs at the scan's level,
    # before any other observed is certain to be filled.
    ix = 0
    for (j, a) in enumerate(K.acc)
        e = _scan_desc_extent(a, olnext)
        e === nothing && continue
        if _scan_overlaps(e, lo, hi)
            (ix == 0 && a.kind === _AK_STATE_AFFINE && lo <= e[1] && e[2] <= hi) ||
                return nothing
            ix = j
        else
            (1 <= e[1] && e[2] <= nst) || return nothing
        end
    end
    ix == 0 && return nothing
    _scan_node_reads(K.spine, ix) || return nothing
    (_scan_consumer_node_ok(K.spine) &&
     all(_scan_consumer_node_ok, K.cse.recipes) &&
     all(_scan_consumer_node_ok, K.cse.inv_recipes)) || return nothing
    any(r -> _scan_node_reads(r, ix), K.cse.inv_recipes) && return nothing
    delta = K.acc[ix].delta
    sort!(_cellset_slots(K.cells) .+ delta) == sort(S.slots) || return nothing
    return (K, ix, delta)
end

# The consumers of the in-place build's observed scans: fold → `(Kc, ix,
# delta, store)`. `levels` are the pending observed levels `(owner, cadence,
# scalars, kernels, scans, contractions, recurrences)`, `owner` naming the
# observed each fold fills; `Ks` the state kernels; `nst` the state length.
# Only a scan of a level filled on every call takes a consumer, since the
# consumer's `du` must be written on every call.
#
# The store is dropped when nothing but the consumer can read the observed:
# no observed definition names it (so no fill reads it), no scalar state
# equation names it, the state equations have no per-cell scalar entries and
# no contraction nests (whose reads are not checked here), and the consumer is
# the only state kernel any of whose reads can reach its slots.
function _scan_consumer_plan(levels, Ks::AbstractVector{_AccKernel}, nst::Int,
                             scalar_entries, percell, contractions, defsets)
    plan = IdDict{Any,Any}()
    _codegen_disabled() && return plan
    for (owner, cadence, _, kernels, scans, _, _) in levels
        cadence === :dynamic || continue
        for S in scans
            length(S.terms) == 1 || continue
            Kt = S.terms[1]
            (Kt isa _AccKernel && any(k -> k === Kt, kernels) && _scan_fusable(Kt, S)) ||
                continue
            c = _scan_consumer(S, Ks, nst)
            c === nothing && continue
            name = get(owner, S, nothing)
            store = !(name !== nothing && isempty(percell) && isempty(contractions) &&
                      !any(e -> name in _referenced_var_names(e[2]), scalar_entries) &&
                      !any(d -> any(ex -> name in _referenced_var_names(ex), values(d)),
                           defsets))
            plan[S] = (c..., store)
        end
    end
    return plan
end

# Emit and compile the fused scan of fold `S` over its term kernel `K`, or
# return `nothing` when the emitter declines the kernel. `consumer` is
# `nothing` or `(Kc, ix, delta, store)` (see above).
function _build_fused_scan(S::_ScanFold, K::_AccKernel; nst::Int=0, consumer=nothing)
    op = S.oplus
    opsym = op === :+ ? :+ : op === :* ? :* : op === :max ? :max :
            op === :min ? :min : nothing
    opsym === nothing && return nothing
    ctx = _CGCtx(_codegen_node_budget(); nst=nst)
    acc = _cg_name(ctx, "acc")
    av = _cg_name(ctx, "a")
    bv = _cg_name(ctx, "b")
    lv = _cg_name(ctx, "l")
    lr = _cg_name(ctx, "lr")
    blk = try
        for Sub in K.subs
            _cg_inv!(ctx, Sub)
        end
        invsyms = _cg_inv!(ctx, K)
        cons = nothing
        if consumer !== nothing
            Kc, ix, delta, store = consumer
            _cg_note_nest!(ctx, Kc)
            cons = (K = Kc, ix = ix, delta = delta, store = store,
                    invsyms = _cg_inv!(ctx, Kc))
        end
        ctx.scanmode = (acc = acc, a = av, b = bv, op = opsym, inclusive = S.inclusive,
                        cons = cons)
        geo = Any[]
        nest = _cg_with_geosink(ctx, geo) do
            _cg_tbl_versions(() -> _cg_emit_kernel_nest!(ctx, K, invsyms), ctx)
        end
        ctx.scanmode = nothing
        nl = _cg_with_geosink(() -> _cg_geo!(ctx, div(length(S.slots), S.len)), ctx, geo)
        len = _cg_with_geosink(() -> _cg_geo!(ctx, S.len), ctx, geo)
        quote
            $(geo...)
            local $lr = _chunk_ordinals($nl, _cgci, _cgnc)
            for $lv in $lr[1]:($lr[2] - 1)
                local $av = $lv * $len
                local $bv = $av + $len
                local $acc = $(S.zerobar)
                $nest
            end
        end
    catch err
        err isa _CodegenDecline || rethrow()
        _tally_cascade!(Symbol(:scan_fused_decline_, err.reason))
        return nothing
    end
    ln = LineNumberNode(0, Symbol("ess-scan-fused"))
    ngrp = length(ctx.tab_types)
    grpstmts = Any[:(local $(_cg_grp_sym(g)) = tabs[$g]) for g in 1:ngrp]
    byval = _cg_split_by_value()
    fnstmts = byval && !isempty(ctx.helpers) ?
              Any[:(local $(_CG_FNS) = tabs[$(ngrp + 1)])] : Any[]
    helperdefs = byval ? Any[] : ctx.helpers
    # `u` read-only in an alias scope, as in the kernel section: the term
    # reads no slot the scan writes (a level's `(ue, ue)` call included).
    run = Expr(:macrocall, GlobalRef(Base.Experimental, Symbol("@aliasscope")), ln,
               Expr(:let, _cg_section_bindings(consumer === nothing ? nst : 0,
                                               _AccKernel[K]),
                    Expr(:block,
                         Expr(:macrocall, Symbol("@inbounds"), ln,
                              Expr(:block, ctx.prologue...)),
                         Expr(:macrocall, Symbol("@inbounds"), ln, blk))))
    body = Expr(:block, grpstmts..., fnstmts...,
                :(local _cgT = _rhs_value_type(u, p, t)),
                helperdefs...,
                run,
                :(return nothing))
    ex = Expr(:function, Expr(:tuple, :du, :u, :p, :t, :tabs, :_cgci, :_cgnc), body)
    f = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(@__MODULE__, @__MODULE__, ex)
    tabpack = ntuple(g -> Vector{ctx.tab_types[g]}(ctx.tab_objs[g]), ngrp)
    if byval && !isempty(ctx.helpers)
        tabpack = (tabpack...,
                   Tuple(RuntimeGeneratedFunctions.RuntimeGeneratedFunction(
                             @__MODULE__, @__MODULE__, h) for h in ctx.helpers))
    end
    nlanes = div(length(S.slots), S.len)
    _tally_cascade!(:scan_fused)
    if consumer !== nothing
        _tally_cascade!(:scan_fused_consumer)
        consumer[4] || _tally_cascade!(:scan_fused_store_dropped)
    end
    # Fewer than two lanes leave nothing to split; the verdict sees no cells.
    return _FusedScan(f, tabpack, nlanes,
                      _SecTCache(nlanes >= 2 ? length(S.slots) : 0, true))
end

# Split the in-place build's prefix scans into the fused ones and the rest.
# Returns the kernel list without the fused scans' term kernels, the folds
# that stay two-pass, and the fused scans as a tuple.
# `consumers` maps a fold (by identity) to its consumer `(Kc, ix, delta, store)`;
# `consumed` collects each consumer kernel whose fused scan was emitted, for
# the caller to take out of the state kernels.
function _detach_fused_scans(kernels::Vector{_AccKernel}, folds::Vector{_ScanFold};
                             nst::Int=0, consumers::IdDict{Any,Any}=IdDict{Any,Any}(),
                             consumed::IdDict{Any,Bool}=IdDict{Any,Bool}())
    (isempty(folds) || _codegen_disabled()) && return kernels, folds, ()
    gens = Any[]
    plain = _ScanFold[]
    drop = IdDict{Any,Bool}()
    for S in folds
        g = nothing
        if length(S.terms) == 1
            K = S.terms[1]
            if K isa _AccKernel && any(k -> k === K, kernels) && _scan_fusable(K, S)
                cons = get(consumers, S, nothing)
                g = _build_fused_scan(S, K; nst=nst, consumer=cons)
                if g === nothing && cons !== nothing
                    g = _build_fused_scan(S, K; nst=nst)
                elseif g !== nothing && cons !== nothing
                    consumed[cons[1]] = true
                end
                g === nothing || (drop[K] = true)
            end
        end
        g === nothing ? push!(plain, S) : push!(gens, g)
    end
    isempty(gens) && return kernels, folds, ()
    return _AccKernel[K for K in kernels if !haskey(drop, K)], plain, Tuple(gens)
end

# Run every fused scan, each threaded across its lanes when it has several.
@inline _run_fused_scans!(::Tuple{}, du, u, p, t) = nothing
@inline function _run_fused_scans!(fs::Tuple, du, u, p, t)
    g = fs[1]
    tc = g.tcache
    if _threads_available() && _sec_prep_threads!(tc).state == 1
        tc.nchunks = min(tc.nchunks, g.nlanes)
        _run_chunked!(tc, _CGChunk(g.f, g.tabs), (du, u, p, t))
    else
        g.f(du, u, p, t, g.tabs, 1, 1)
    end
    return _run_fused_scans!(Base.tail(fs), du, u, p, t)
end
