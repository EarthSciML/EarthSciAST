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
# kernel's own emitted body, `_cg_emit_kernel_nest!` with a scan store), converts
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

# ---- Threading the folds ------------------------------------------------------
# A lane's running accumulation is sequential, but lanes are independent of
# each other — within one fold and across folds (each state slot belongs to
# exactly one equation, so no two lanes share a slot). A `_ScanSection` numbers
# every lane of its folds globally and runs them as static chunks of that
# numbering: a lane is folded whole, ascending, by whichever thread owns it, so
# each slot gets the same value as the serial fold.
# `fused` holds the section's fused scans (scan_fused.jl), a tuple of
# `_FusedScan`s, each its own generated function that computes its terms too.
struct _ScanSection{FS}
    folds::Vector{_ScanFold}
    lanecum::Vector{Int}      # lanes before fold f; the last entry is the total
    tcache::_SecTCache
    fused::FS
end

function _make_scan_section(folds::AbstractVector{_ScanFold}, fused::Tuple = ())
    lanecum = Vector{Int}(undef, length(folds) + 1)
    lanecum[1] = 0
    nslots = 0
    for (k, S) in enumerate(folds)
        nl = S.len >= 1 ? div(length(S.slots), S.len) : 0
        lanecum[k + 1] = lanecum[k] + nl
        nslots += length(S.slots)
    end
    # Fewer than two lanes leave nothing to split; the verdict sees no cells.
    return _ScanSection(
        collect(folds), lanecum,
        _SecTCache(lanecum[end] >= 2 ? nslots : 0, true), fused
    )
end

Base.isempty(s::_ScanSection) = isempty(s.folds) && isempty(s.fused)

struct _ScanChunk
    folds::Vector{_ScanFold}
    lanecum::Vector{Int}
end
function (b::_ScanChunk)(args, c::Int, nchunks::Int)
    du = args[1]
    a, z = _chunk_ordinals(b.lanecum[end], c, nchunks)   # global lanes [a, z)
    @inbounds for f in eachindex(b.folds)
        lo = max(a, b.lanecum[f])
        hi = min(z, b.lanecum[f + 1])
        lo < hi && _apply_scan_fold!(
            du, b.folds[f], lo - b.lanecum[f] + 1,
            hi - b.lanecum[f]
        )
    end
    return nothing
end

# The section's unfused folds, over the terms already in `du`.
function _apply_scan_folds!(du, s::_ScanSection)
    isempty(s.folds) && return nothing
    _run_section!(s.tcache, _ScanChunk(s.folds, s.lanecum), (du,), s.lanecum[end])
    return nothing
end

# The whole section: the fused scans (which compute their own terms from
# `u`), then the unfused folds. They write disjoint slots and read none the
# other writes, so the order between them is free.
function _apply_scan_folds!(du, u, p, t, s::_ScanSection)
    _run_fused_scans!(s.fused, du, u, p, t)
    _apply_scan_folds!(du, s)
    return nothing
end

# One fused scan: the generated function `f(du, u, p, t, tabs, ci, nc)`, which
# runs lanes `[a, b)` of chunk `ci` of `nc`, its tables, and the most chunks its
# lanes split into (its lane count; fewer for a column scan).
struct _FusedScan{F, TB}
    f::F
    tabs::TB
    nlanes::Int
    tcache::_SecTCache
end

# The fold's slots are the kernel's output slots, in the kernel's own cell
# order (the order every nest emits a chunk's cells in).
_scan_fusable(K::_AccKernel, S::_ScanFold) =
    S.len >= 1 && _cellset_is_shifted(K.cells, S.slots, 0)

# Whether a cell set's slots, in its cell order, are `slots .- delta`.
function _cellset_is_shifted(cs::_CellSet, slots::Vector{Int}, delta::Int)
    _cellset_ncells(cs) == length(slots) || return false
    if _is_outs(cs)
        return all(k -> cs.outs[k] + delta == slots[k], eachindex(slots))
    elseif _is_cellless(cs)
        return isempty(slots)
    end
    return _box_is_shifted(cs.base, Tuple(cs.strides), Tuple(cs.ranges), slots, delta)
end
function _box_is_shifted(
        base::Int, st::NTuple{N, Int}, rs::NTuple{N, UnitRange{Int}},
        slots::Vector{Int}, delta::Int
    ) where {N}
    k = 0
    @inbounds for I in CartesianIndices(rs)
        o = base
        for d in 1:N
            o += I[d] * st[d]
        end
        k += 1
        o + delta == slots[k] || return false
    end
    return true
end

# ---- The consumer of a fused scan ---------------------------------------------
# A consumer is `(K, ix, delta, store)`: the state kernel, the index of its one
# descriptor that reads the scanned observed (`u[oln + delta]`), and whether the
# observed is still stored.

# The descriptor kinds a consumer's body may read: each is addressed by `oln`
# (or nothing), so the body can run at the scan's cell with `oln` = the scan's
# slot minus `delta`.
const _SCAN_CONSUMER_KINDS = (_AK_STATE_AFFINE, _AK_STATE_FIXED, _AK_ARR_FIXED)

# Whether a consumer's spine (or recipe) uses only leaves and plain operators:
# nothing addressed by the loop index, no reduction.
function _scan_consumer_node_ok(nd::_Node)
    k = nd.kind
    if k === _NK_OP
        nd.payload === nothing || return false
    elseif !(
            k === _NK_ACCESS || k === _NK_LITERAL || k === _NK_PARAM ||
                k === _NK_TIME || k === _NK_CACHED
        )
        return false
    end
    return _allof(_scan_consumer_node_ok, nd.children)
end
_scan_node_reads(nd::_Node, ix::Int) =
    (nd.kind === _NK_ACCESS && nd.idx == ix) || _anyof(c -> _scan_node_reads(c, ix), nd.children)

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
    elseif k === _AK_STATE_TBL_BOX
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

# Whether any descriptor of `K` other than `K.acc[skip]`
# may read a slot in `lo:hi`.
function _scan_kernel_reads(
        K::_AccKernel, lo::Int, hi::Int, skip::Int = 0,
        olnext = _cg_oln_extent(K.cells)
    )
    for (j, a) in enumerate(K.acc)
        j == skip && continue
        _scan_overlaps(_scan_desc_extent(a, olnext), lo, hi) && return true
    end
    return false
end

# A state kernel that computes its cells from an observed's values as a
# generated section produces them, instead of reading them back from the
# observed buffer: `K` reads the section's value through the descriptors in
# `reads` (descriptor index => level offset, 0 for one that reads the cell
# itself), at the state slot the section's slot minus `delta`; `store` is
# whether the section still stores the observed (see `_scan_consumer_plan`).
struct _ScanConsumer
    K::_AccKernel
    reads::Dict{Int, Int}
    delta::Int
    store::Bool
end
_with_store(c::_ScanConsumer, store::Bool) = _ScanConsumer(c.K, c.reads, c.delta, store)
# The one descriptor a plain consumer reads the section's value through.
_consumer_ix(c::_ScanConsumer) = only(keys(c.reads))

# A plain state consumer taken into a generated section, as the emitter reads
# it: the kernel, the descriptor it reads the section's value through, the
# slot offset, whether the value is still stored, and the consumer's invariant
# symbols (registered with the function's prologue).
_cg_consumer(ctx::_CGFunction, ::Nothing) = nothing
function _cg_consumer(ctx::_CGFunction, c::_ScanConsumer)
    _cg_note_nest!(ctx, c.K)
    ix = _consumer_ix(c)
    return _CGConsumer(c.K, ix, c.delta, c.store, _cg_inv!(ctx, c.K))
end

# The one kernel among `Ks` that may read a slot in
# `lo:hi`, or `nothing` when none or several do.
function _find_scan_reader(lo::Int, hi::Int, Ks::AbstractVector{_AccKernel})
    found = nothing
    for K in Ks
        _scan_kernel_reads(K, lo, hi) || continue
        found === nothing || return nothing          # two readers
        found = K
    end
    return found
end

# The consumer of fold `S` among the state kernels `Ks`, or `nothing`: the one
# kernel that reads the observed's slots, through one affine descriptor that
# maps its cells onto the fold's slots one to one and in order, with a body
# `_scan_consumer_node_ok` accepts.
_scan_consumer(S::_ScanFold, Ks::AbstractVector{_AccKernel}, nst::Int) =
    _scan_consumer(S.slots, Ks, nst)
function _scan_consumer(slots::Vector{Int}, Ks::AbstractVector{_AccKernel}, nst::Int)
    isempty(slots) && return nothing
    lo, hi = extrema(slots)
    K = _find_scan_reader(lo, hi, Ks)
    K === nothing && return nothing
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
    (
        _scan_consumer_node_ok(K.spine) &&
            all(_scan_consumer_node_ok, K.cse.recipes) &&
            all(_scan_consumer_node_ok, K.cse.inv_recipes)
    ) || return nothing
    any(r -> _scan_node_reads(r, ix), K.cse.inv_recipes) && return nothing
    delta = K.acc[ix].delta
    _cellset_is_shifted(K.cells, slots, delta) || return nothing
    return _ScanConsumer(K, Dict(ix => 0), delta, true)
end

# The consumers of the in-place build's observed scans: fold → its
# `_ScanConsumer`. `levels` are the pending observed levels (`_LevelParts`),
# whose `owner` names the observed each fold fills; `Ks` the state kernels; `nst` the state length.
# Only a scan of a level filled on every call takes a consumer, since the
# consumer's `du` must be written on every call.
#
# The store is dropped when nothing but the consumer can read the observed:
# no observed definition names it (so no fill reads it), no scalar state
# equation names it, the state equations have no per-cell scalar entries and
# no contraction nests (whose reads are not checked here), and the consumer is
# the only state kernel any of whose reads can reach its slots.
function _scan_consumer_plan(
        levels, Ks::AbstractVector{_AccKernel}, nst::Int,
        scalar_entries, percell, contractions, defsets
    )
    plan = IdDict{Any, Any}()
    _codegen_disabled() && return plan
    for (li, lv) in enumerate(levels)
        owner, kernels, scans = lv.owner, lv.kernels, lv.scans
        lv.cadence === :dynamic || continue
        for S in scans
            length(S.terms) == 1 || continue
            Kt = S.terms[1]
            (Kt isa _AccKernel && _anyof(k -> k === Kt, kernels)) || continue
            sh = _scan_fusable(Kt, S) ? nothing : _colscan_shape(S, Kt)
            c = if sh !== nothing
                _colscan_consumer(S, Kt, sh, Ks, nst, levels, li)
            elseif _scan_fusable(Kt, S)
                _scan_consumer(S, Ks, nst)
            else
                nothing
            end
            c === nothing && continue
            name = get(owner, S, nothing)
            store = !(
                name !== nothing && isempty(percell) && isempty(contractions) &&
                    !_anyof(e -> name in _referenced_var_names(e[2]), scalar_entries) &&
                    !_anyof(
                    d -> _anyof(ex -> name in _referenced_var_names(ex), values(d)),
                    defsets
                )
            )
            plan[S] = _with_store(c, store)
        end
    end
    return plan
end

# Emit and compile the fused scan of fold `S` over its term kernel `K`, or
# return `nothing` when the emitter declines the kernel. `consumer` is
# `nothing` or a `_ScanConsumer` (see above).
# The fold's ⊕ as the emitted call's function symbol, or `nothing` for a
# reducer the scans do not emit.
_scan_opsym(S::_ScanFold) = _is_numeric_reducer(S.oplus) ? _reducer_fnsym(S.oplus) : nothing

# A scan section's generated function: the invariant prologue, then the nest
# `blk`, under `@inbounds` and with no alias scope, as in the kernel section
# (JuliaLang/julia#63129). With a consumer the section writes the state part
# of `du`, so the two-buffer bindings are off. `file` names the section in
# the emitted line numbers.
function _scan_section_fn(ctx::_CGFunction, K::_AccKernel, blk, consumer, nst::Int, file::Symbol)
    ln = LineNumberNode(0, file)
    run = Expr(
        :let, _cg_section_bindings(consumer === nothing ? nst : 0, _AccKernel[K]),
        Expr(
            :block,
            Expr(:macrocall, Symbol("@inbounds"), ln, Expr(:block, ctx.prologue.stmts...)),
            Expr(:macrocall, Symbol("@inbounds"), ln, blk)
        )
    )
    f, fns = _cg_finish(ctx, _CG_SECTION_ARGS, run)
    return f, _cg_tabpack(ctx, fns)
end

function _build_fused_scan(S::_ScanFold, K::_AccKernel; nst::Int = 0, consumer = nothing)
    opsym = _scan_opsym(S)
    opsym === nothing && return nothing
    ctx = _CGFunction(_codegen_node_budget(); nst = nst)
    acc = _cg_name(ctx, "acc")
    av = _cg_name(ctx, "a")
    bv = _cg_name(ctx, "b")
    lv = _cg_name(ctx, "l")
    lr = _cg_name(ctx, "lr")
    blk = try
        invsyms = _cg_inv!(ctx, K)
        cons = consumer === nothing ? nothing : _cg_consumer(ctx, consumer)
        store = _CGStoreScan(acc, av, bv, opsym, S.inclusive, cons)
        geo = Any[]
        nest = _cg_with_geosink(ctx, geo) do
            _cg_tbl_versions(() -> _cg_emit_kernel_nest!(ctx, K, invsyms, store), ctx)
        end
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
        err isa _Decline || rethrow()
        _tally_cascade!(Symbol(:scan_fused_decline_, err.reason))
        return nothing
    end
    # The term reads no slot the scan writes (a level's `(ue, ue)` call included).
    f, tabpack = _scan_section_fn(ctx, K, blk, consumer, nst, Symbol("ess-scan-fused"))
    nlanes = div(length(S.slots), S.len)
    _tally_cascade!(:scan_fused)
    if consumer !== nothing
        _tally_cascade!(:scan_fused_consumer)
        consumer.store || _tally_cascade!(:scan_fused_store_dropped)
    end
    # Fewer than two lanes leave nothing to split; the verdict sees no cells.
    # Each slot computes its term as well as folding it.
    nsl = nlanes >= 2 ? length(S.slots) : 0
    return _FusedScan(
        f, tabpack, nlanes,
        _SecTCache(nsl, true, nsl * (1 + _acc_kernel_work(K)))
    )
end

# Split the in-place build's prefix scans into the fused ones and the rest.
# Returns the kernel list without the fused scans' term kernels, the folds
# that stay two-pass, and the fused scans as a tuple.
# `consumers` maps a fold (by identity) to its `_ScanConsumer`;
# `consumed` collects each consumer kernel whose fused scan was emitted, for
# the caller to take out of the state kernels.
function _detach_fused_scans(
        kernels::Vector{_AccKernel}, folds::Vector{_ScanFold};
        nst::Int = 0, consumers::IdDict{Any, Any} = IdDict{Any, Any}(),
        consumed::IdDict{Any, Bool} = IdDict{Any, Bool}()
    )
    (isempty(folds) || _codegen_disabled()) && return kernels, folds, ()
    gens = Any[]
    plain = _ScanFold[]
    drop = IdDict{Any, Bool}()
    for S in folds
        g = nothing
        if length(S.terms) == 1
            K = S.terms[1]
            if K isa _AccKernel && any(k -> k === K, kernels) && _scan_fusable(K, S)
                cons = get(consumers, S, nothing)
                g = _build_fused_scan(S, K; nst = nst, consumer = cons)
                if g === nothing && cons !== nothing
                    g = _build_fused_scan(S, K; nst = nst)
                elseif g !== nothing && cons !== nothing
                    consumed[cons.K] = true
                end
                g === nothing || (drop[K] = true)
            elseif K isa _AccKernel && any(k -> k === K, kernels) &&
                    (sh = _colscan_shape(S, K)) !== nothing
                cons = get(consumers, S, nothing)
                g = _build_colscan(S, K, sh; nst = nst, consumer = cons)
                if g === nothing && cons !== nothing
                    g = _build_colscan(S, K, sh; nst = nst)
                elseif g !== nothing && cons !== nothing
                    consumed[cons.K] = true
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
    _run_section!(g.tcache, _CGChunk(g.f, g.tabs), (du, u, p, t), g.nlanes)
    return _run_fused_scans!(Base.tail(fs), du, u, p, t)
end

# ---- The column scan ------------------------------------------------------------
# A scan along the SLOW axis of a rank-2 box whose fast axis is the lanes (a
# column scan over levels with the columns fastest, the layout native gives a
# `[col, lev]` field) cannot take the fused nest above: a lane is not a run of
# the kernel's cell ordinals. Here the nest is built the other way round,
# level by level with the lanes inner, the way a person writes the loop: each
# lane's running value lives in a per-lane buffer, every cell computes its term,
# folds it into its lane's value and stores the result, all in one pass.
#
#   strict, forward  F[l] = acc;  acc = acc ⊕ term_l     (F[l+1] = acc, staggered)
#   inclusive        acc = acc ⊕ term_l;  F[l] = acc
#
# with `acc` seeded at 0̄ per lane and a reverse scan's levels walked from the
# top (its fold slots run down the axis). Per lane the values and their order
# are `_scan_lanes!`'s exactly. The per-lane buffer is a `Float64` vector the
# function owns, so it is used when the call's values are `Float64`; any other
# value type (a ForwardDiff call) runs the same cells lane by lane with a local
# accumulator, the same values in the same order.
#
# A CONSUMER here is a state kernel over the same box that reads the scanned
# observed at a level next to the cell's own (`F[c,l+1] - F[c,l]`, a flux
# divergence): at each cell the two values it can read are the lane's value
# before and after the fold (`_colscan_offsets`), so it is computed from them
# right there. A read that falls outside the scan's own levels at the first
# level (the value below the first, or above the top) is read from the buffer,
# where another kernel of the level has written it before the scan runs.

# `(r1, r2, S2, rev)`: the term kernel's lane and level ranges, its level
# stride and whether the scan runs down the axis; `nothing` when the fold is
# not a column scan of this kernel.
function _colscan_shape(S::_ScanFold, K::_AccKernel)
    cs = K.cells
    (_is_outs(cs) || _is_cellless(cs) || length(cs.strides) != 2) && return nothing
    (cs.strides[1] == 1 && S.lstride == 1 && S.kstride != 0) || return nothing
    r1, r2 = cs.ranges
    S2 = cs.strides[2]
    nl = length(r1)
    (
        nl >= 2 && S.len >= 1 && div(length(S.slots), S.len) == nl &&
            abs(S.kstride) == S2 && S2 >= nl
    ) || return nothing
    rev = S.kstride < 0
    nt = length(r2)
    (S.len == nt || (S.len == nt + 1 && !S.inclusive && !rev)) || return nothing
    cs.base + first(r1) + (rev ? last(r2) : first(r2)) * S2 == S.slots[1] || return nothing
    return (r1 = r1, r2 = r2, S2 = S2, rev = rev)
end

# The level offsets, from the cell's own level, of the lane's value before the
# fold and after it.
_colscan_offsets(inclusive::Bool, rev::Bool) =
    inclusive ? (rev ? (1, 0) : (-1, 0)) : (rev ? (0, -1) : (0, 1))

# The levels the fold writes.
_colscan_levels(S::_ScanFold, sh) =
    sh.rev ? ((last(sh.r2) - S.len + 1):last(sh.r2)) : (first(sh.r2):(first(sh.r2) + S.len - 1))

# The slot extents a level writes, and whether it writes slots not known here
# (a contraction nest or a recurrence).
function _level_write_extents(level)
    ext = Tuple{Int, Int}[]
    for (slot, _) in level.scalars
        push!(ext, (slot, slot))
    end
    for K in level.kernels
        push!(ext, _cg_oln_extent(K.cells))
    end
    for S in level.scans
        isempty(S.slots) || push!(ext, extrema(S.slots))
    end
    return ext, !(isempty(level.contractions) && isempty(level.recurrences))
end

# The consumer of column scan `S` (term kernel `K`, shape `sh`) among the state
# kernels `Ks`, or `nothing`: a `_ScanConsumer` whose `reads` give each
# descriptor's level offset.
# `levels` / `li` are the pending observed levels and the scan's, for which
# other observed slots the consumer may read (those no level from the scan's on
# writes).
function _colscan_consumer(
        S::_ScanFold, K::_AccKernel, sh, Ks::AbstractVector{_AccKernel},
        nst::Int, levels, li::Int
    )
    isempty(S.slots) && return nothing
    lo, hi = extrema(S.slots)
    Kc = _find_scan_reader(lo, hi, Ks)
    Kc === nothing && return nothing
    cc = Kc.cells
    (_is_outs(cc) || _is_cellless(cc) || length(cc.strides) != 2) && return nothing
    (cc.strides == K.cells.strides && cc.ranges == K.cells.ranges) || return nothing
    olnext = _cg_oln_extent(cc)
    (1 <= olnext[1] && olnext[2] <= nst) || return nothing
    later = Tuple{Int, Int}[]
    opaque = false
    for k in li:length(levels)
        e, o = _level_write_extents(levels[k])
        append!(later, e)
        opaque |= o
    end
    # Slots the scan's own level writes in its kernel section, before the scan
    # (only from kernels that reach the scanned observed's slots).
    before = Set{Int}()
    for K2 in levels[li].kernels
        K2 === K && continue
        _scan_overlaps(_cg_oln_extent(K2.cells), lo - abs(S.kstride), hi + abs(S.kstride)) ||
            continue
        _cellset_foreach_slot(s -> push!(before, s), K2.cells)
    end
    po, no = _colscan_offsets(S.inclusive, sh.rev)
    lv = _colscan_levels(S, sh)
    j1 = sh.rev ? last(sh.r2) : first(sh.r2)
    S2 = sh.S2
    reads = Dict{Int, Int}()
    for (j, a) in enumerate(Kc.acc)
        e = _scan_desc_extent(a, olnext)
        e === nothing && continue
        if _scan_overlaps(e, lo, hi)
            a.kind === _AK_STATE_AFFINE || return nothing
            d = cc.base + a.delta - K.cells.base
            rem(d, S2) == 0 || return nothing
            off = div(d, S2)
            (off == po || off == no) || return nothing
            for jj in sh.r2
                (jj + off) in lv && continue
                # Outside the scan's levels: only the value before the first
                # level's fold, read from what the level wrote there already.
                (jj == j1 && off == po) || return nothing
                all(i -> (K.cells.base + i + (jj + off) * S2) in before, sh.r1) ||
                    return nothing
            end
            reads[j] = off
        else
            (1 <= e[1] && e[2] <= nst) ||
                (!opaque && e[1] > nst && !any(x -> _scan_overlaps(e, x[1], x[2]), later)) ||
                return nothing
        end
    end
    isempty(reads) && return nothing
    any(r -> any(ix -> _scan_node_reads(r, ix), keys(reads)), Kc.cse.inv_recipes) &&
        return nothing
    return _ScanConsumer(Kc, reads, 0, true)
end

function _cellset_foreach_slot(f, cs::_CellSet)
    if _is_outs(cs)
        foreach(f, cs.outs)
    elseif !_is_cellless(cs)
        _box_foreach_slot(f, cs.base, Tuple(cs.strides), Tuple(cs.ranges))
    end
    return nothing
end
function _box_foreach_slot(
        f, base::Int, st::NTuple{N, Int},
        rs::NTuple{N, UnitRange{Int}}
    ) where {N}
    for I in CartesianIndices(rs)
        o = base
        for d in 1:N
            o += I[d] * st[d]
        end
        f(o)
    end
    return nothing
end

# Emit and compile the column scan of fold `S` over its term kernel `K`, or
# `nothing` when the emitter declines a kernel. `consumer` is `nothing` or
# `(K, reads, store)` from `_colscan_consumer`.
function _build_colscan(S::_ScanFold, K::_AccKernel, sh; nst::Int = 0, consumer = nothing)
    opsym = _scan_opsym(S)
    opsym === nothing && return nothing
    ctx = _CGFunction(_codegen_node_budget(); nst = nst)
    nlanes = length(sh.r1)
    blk = try
        invsyms = _cg_inv!(ctx, K)
        _cg_note_nest!(ctx, K)
        cinv = Symbol[]
        if consumer !== nothing
            _cg_note_nest!(ctx, consumer.K)
            cinv = _cg_inv!(ctx, consumer.K)
        end
        geo = Any[]
        nest = _cg_with_geosink(ctx, geo) do
            _cg_tbl_versions(
                () -> _colscan_nest(
                    ctx, S, K, sh, invsyms, opsym,
                    consumer, cinv
                ), ctx
            )
        end
        quote
            $(geo...)
            $nest
        end
    catch err
        err isa _Decline || rethrow()
        _tally_cascade!(Symbol(:scan_colscan_decline_, err.reason))
        return nothing
    end
    # The per-lane buffer is stored and read back level after level.
    f, tabpack = _scan_section_fn(ctx, K, blk, consumer, nst, Symbol("ess-scan-column"))
    _tally_cascade!(:scan_colscan)
    if consumer !== nothing
        _tally_cascade!(:scan_colscan_consumer)
        consumer.store || _tally_cascade!(:scan_colscan_store_dropped)
    end
    nsl = length(S.slots)
    work = nsl * (1 + _acc_kernel_work(K)) +
        (consumer === nothing ? 0 : nsl * _acc_kernel_work(consumer.K))
    # Threads split the lanes, at least `_COLSCAN_MIN_LANES` to a chunk.
    return _FusedScan(
        f, tabpack, max(1, div(nlanes, _COLSCAN_MIN_LANES)),
        _SecTCache(nsl, true, work)
    )
end

# The lanes a chunk runs are blocked by this many, so a block's running values
# and the level it reads stay in cache.
const _COLSCAN_BLOCK = 4096

# The least lanes per chunk of a threaded column scan. Its cells are a vector
# loop across the lanes of one level, far cheaper per node than the loops the
# work floor (`_Tuning.thread_min_work`) is set for, so a chunk is held to a whole
# vector row of this many lanes per level instead, the same kind of floor as
# `_THREAD_MIN_RMW_CELLS`.
const _COLSCAN_MIN_LANES = 1024

function _colscan_nest(
        ctx::_CGFunction, S::_ScanFold, K::_AccKernel, sh, invsyms, opsym,
        consumer, cinv
    )
    cs = K.cells
    po, no = _colscan_offsets(S.inclusive, sh.rev)
    lv = _colscan_levels(S, sh)
    store = consumer === nothing || consumer.store
    geo(v, f) = _cg_geo!(ctx, v, (cs, :colscan, f))
    base = geo(cs.base, :base)
    S2 = geo(sh.S2, :S2)
    i0 = geo(first(sh.r1) - 1, :i0)
    nl = geo(length(sh.r1), :nl)
    nt = length(sh.r2)
    ntg = geo(nt, :nt)
    j1v = sh.rev ? last(sh.r2) : first(sh.r2)
    j1 = geo(j1v, :j1)
    dir = sh.rev ? -1 : 1
    z = S.zerobar
    accv = _cg_tabh!(ctx, _ws_scratch!(zeros(Float64, length(sh.r1))))
    basec = consumer === nothing ? nothing : geo(consumer.K.cells.base, :basec)
    # The strict scan stores its value at the next level (staggered or not);
    # at the last level of a same-range scan that level is not the scan's.
    nextoff = S.inclusive ? 0 : dir
    last_out = !S.inclusive && !((j1v + (nt - 1) * dir + nextoff) in lv)
    jl = geo(j1v + (nt - 1) * dir, :jl)
    q = _cg_name(ctx, "q")
    iv = _cg_name(ctx, "i")
    jv = _cg_name(ctx, "j")
    acc = _cg_name(ctx, "acc")
    function cell(first::Bool, f64::Bool)
        oln = _cg_name(ctx, "o")
        kc = _CGKernCtx(K, oln, iv, jv, 1, Symbol[], invsyms)
        st = Any[:(local $oln = $base + $iv + $jv * $S2)]
        _cg_emit_recipes!(st, ctx, kc)
        val = _cg_bound_body!(ctx, _cg_emit(ctx, kc, K.spine))
        tv = _cg_name(ctx, "term")
        pv = _cg_name(ctx, "pv")
        nv = _cg_name(ctx, "nv")
        push!(st, :(local $tv = convert(eltype(du), $val)))
        push!(st, :(local $pv = $(f64 ? :($accv[$q]) : acc)))
        push!(st, :(local $nv = $opsym($pv, $tv)))
        if store
            if S.inclusive
                push!(st, :(_cg_oview(du)[$oln] = $nv))
            elseif last_out
                push!(st, :($jv == $jl || (_cg_oview(du)[$oln + $(dir) * $S2] = $nv)))
            else
                push!(st, :(_cg_oview(du)[$oln + $(dir) * $S2] = $nv))
            end
        end
        if consumer !== nothing
            Kc = consumer.K
            xp = _cg_name(ctx, "xp")
            xn = _cg_name(ctx, "xn")
            push!(st, :(local $xp = convert(eltype(du), $pv)))
            push!(st, :(local $xn = convert(eltype(du), $nv)))
            sub = Dict{Int, Any}()
            for (ix, off) in consumer.reads
                (first && off == po && !((j1v + off) in lv)) && continue
                sub[ix] = off == po ? xp : xn
            end
            oc = _cg_name(ctx, "oc")
            kcc = _CGKernCtx(Kc, oc, iv, jv, 1, Symbol[], cinv, Any[], sub)
            push!(st, :(local $oc = $basec + $iv + $jv * $S2))
            _cg_emit_recipes!(st, ctx, kcc)
            cval = _cg_bound_body!(ctx, _cg_emit(ctx, kcc, Kc.spine))
            push!(st, :(_cg_bufS(du)[$oc] = $cval))
        end
        push!(st, f64 ? :($accv[$q] = $nv) : :($acc = $nv))
        return st
    end
    seed = store && !S.inclusive ?
        Any[:(_cg_oview(du)[$base + $iv + $j1 * $S2] = convert(eltype(du), $z))] : Any[]
    ctx.nest.tblread = false
    c1f = cell(true, true)
    cnf = cell(false, true)
    tvf = _cg_tblread!(ctx)
    c1g = cell(true, false)
    cng = cell(false, false)
    _cg_tblread!(ctx)
    lr = _cg_name(ctx, "lr")
    blo = _cg_name(ctx, "blo")
    bhi = _cg_name(ctx, "bhi")
    s = _cg_name(ctx, "s")
    return quote
        local $lr = _chunk_ordinals($nl, _cgci, _cgnc)
        if _cgT === Float64 && eltype(du) === Float64
            for $blo in ($lr[1] + 1):$(_COLSCAN_BLOCK):$lr[2]
                local $bhi = min($blo + $(_COLSCAN_BLOCK - 1), $lr[2])
                for $q in $blo:$bhi
                    local $iv = $i0 + $q
                    $accv[$q] = $z
                    $(seed...)
                end
                let $jv = $j1
                    for $q in $blo:$bhi
                        local $iv = $i0 + $q
                        $(c1f...)
                        $(tvf...)
                    end
                end
                for $s in 1:($ntg - 1)
                    local $jv = $j1 + $s * $(dir)
                    for $q in $blo:$bhi
                        local $iv = $i0 + $q
                        $(cnf...)
                        $(tvf...)
                    end
                end
            end
        else
            for $q in ($lr[1] + 1):$lr[2]
                local $iv = $i0 + $q
                local $acc = $z
                $(seed...)
                let $jv = $j1
                    $(c1g...)
                end
                for $s in 1:($ntg - 1)
                    local $jv = $j1 + $s * $(dir)
                    $(cng...)
                end
            end
        end
    end
end
