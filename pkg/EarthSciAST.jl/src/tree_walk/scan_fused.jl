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

# Emit and compile the fused scan of fold `S` over its term kernel `K`, or
# return `nothing` when the emitter declines the kernel.
function _build_fused_scan(S::_ScanFold, K::_AccKernel)
    op = S.oplus
    opsym = op === :+ ? :+ : op === :* ? :* : op === :max ? :max :
            op === :min ? :min : nothing
    opsym === nothing && return nothing
    ctx = _CGCtx(_codegen_node_budget())
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
        ctx.scanmode = (acc = acc, a = av, b = bv, op = opsym, inclusive = S.inclusive)
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
               Expr(:let, Expr(:block, :(u = _cg_readonly(u))),
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
    # Fewer than two lanes leave nothing to split; the verdict sees no cells.
    return _FusedScan(f, tabpack, nlanes,
                      _SecTCache(nlanes >= 2 ? length(S.slots) : 0, true))
end

# Split the in-place build's prefix scans into the fused ones and the rest.
# Returns the kernel list without the fused scans' term kernels, the folds
# that stay two-pass, and the fused scans as a tuple.
function _detach_fused_scans(kernels::Vector{_AccKernel}, folds::Vector{_ScanFold})
    (isempty(folds) || _codegen_disabled()) && return kernels, folds, ()
    gens = Any[]
    plain = _ScanFold[]
    drop = IdDict{Any,Bool}()
    for S in folds
        g = nothing
        if length(S.terms) == 1
            K = S.terms[1]
            if K isa _AccKernel && any(k -> k === K, kernels) && _scan_fusable(K, S)
                g = _build_fused_scan(S, K)
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
