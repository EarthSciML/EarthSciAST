# Conformance: range-restricted, operator-restricted right-hand sides
# (CONFORMANCE_SPEC §5.49; API_SPEC §5.8; issue #540).
#
# Consumes tests/conformance/range_restricted_rhs/manifest.json case by case,
# as its README specifies. Every check is BITWISE against this binding's own
# whole-domain evaluation of the same selected program under `compiler =
# :native`. `RANGE_RHS_CASES` (comma-separated case ids) narrows the run.

using Test
using JSON3
using EarthSciAST

const RRC = EarthSciAST

const _RRC_DIR = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance",
                          "range_restricted_rhs")

# ---- the generated state (README "The state") ----

function _rrc_fnv1a32(s::AbstractString)
    h = 0x811c9dc5
    for b in codeunits(s)
        h = (h ⊻ UInt32(b)) * 0x01000193
    end
    return h
end

function _rrc_h(v::AbstractString, k::Integer)
    x = _rrc_fnv1a32(v) + 0x9e3779b1 * UInt32(k % UInt32)
    x ⊻= x >> 16
    x *= 0x85ebca6b
    x ⊻= x >> 13
    x *= 0xc2b2ae35
    x ⊻= x >> 16
    return Float64(x) / 2.0^32
end

# The global value of element `g` (global indices) of `v`, whose full shape has
# the extents `ext`.
function _rrc_value(v::String, g, ext::Vector{Int})
    k = 1
    stride = 1
    for d in eachindex(ext)
        k += (g[d] - 1) * stride
        stride *= ext[d]
    end
    return 0.5 + _rrc_h(v, k)
end

# The global extents of every block of a whole-domain program.
_rrc_extents(op) = Dict{String,Vector{Int}}(
    b.name => Int[last(r) for r in b.storage] for b in vcat(RRC.tile_layout(op).u,
                                                            RRC.tile_layout(op).aux))

# A buffer in `blocks`' layout holding the global state; a storage cell outside
# the domain takes its periodic image or NaN.
function _rrc_fill(blocks, n::Int, ext, wrap)
    buf = fill(NaN, n)
    for b in blocks
        if isempty(b.storage)
            buf[b.base] = _rrc_value(b.name, Int[], Int[])
            continue
        end
        for c in CartesianIndices(Tuple(b.storage))
            g = wrap(b, Tuple(c))
            g === nothing && continue
            buf[RRC._tile_slot(b, Tuple(c))] = _rrc_value(b.name, g, ext[b.name])
        end
    end
    return buf
end

_rrc_bits(x::Float64) = reinterpret(UInt64, x)

function _rrc_dec(d)
    RRC.Decomposition(
        axes = [String(a.index_set) => (period = a.period === nothing ? nothing : Int(a.period),)
                for a in d.axes],
        faces = [String(f[1]) => String(f[2]) for f in d.faces])
end

_rrc_terms(t) = t == "all" ? :all :
    [haskey(o, :component) ? RRC.TermOrigin(component = String(o.component)) :
                             RRC.TermOrigin(coupling = Int(o.coupling)) for o in t]
_rrc_writes(w) = w == "all" ? :all : String[String(x) for x in w]
_rrc_box(b) = [String(k) => Int(v[1]):Int(v[2]) for (k, v) in pairs(b)]

function _rrc_problem(c)
    mp = haskey(c, :metaparameters) ?
         Dict{String,Int}(String(k) => Int(v) for (k, v) in pairs(c.metaparameters)) :
         Dict{String,Int}()
    return RRC.esm_problem(joinpath(_RRC_DIR, c.document), (0.0, 1.0);
                           metaparameters = mp, compiler = :native)
end

function _rrc_op(c, prob)
    prog = RRC.rhs_program(prob)
    return prog, RRC.select(prog; writes = _rrc_writes(c.selection.writes),
                            terms = _rrc_terms(c.selection.terms))
end

# G: the whole-domain evaluation at the generated state.
function _rrc_whole(op, p)
    L = RRC.tile_layout(op)
    ext = _rrc_extents(op)
    id = (b, g) -> g
    u = _rrc_fill(L.u, L.n_u, ext, id)
    aux = _rrc_fill(L.aux, L.n_aux, ext, id)
    du = fill(NaN, L.n_u)
    RRC.rhs!(du, op, RRC.rhs_workspace(op), u, aux, p, 0.0, RRC.default_forcing_set(op))
    return du, ext
end

# The global coordinates of storage cell `c` of block `b` of a tile, or
# `nothing` for a dead halo cell.
function _rrc_tile_wrap(m, b, c)
    g = collect(c)
    for d in eachindex(b.sets)
        cut = get(m.cut, b.sets[d], nothing)
        cut === nothing && continue
        axis, face = cut
        dom = RRC._axis_domain(m, axis, face)
        g[d] in dom && continue
        P = m.period[axis]
        P === nothing && return nothing
        g[d] += P * cld(first(dom) - g[d], P)
        g[d] in dom || return nothing
    end
    return g
end

# Run one tile against G; return the G slots its owned rows covered.
function _rrc_check_tile!(op, dec, t, G, ext, p; du_shared = nothing)
    tile = RRC.restrict(op, dec; owned = _rrc_box(t.owned), storage = _rrc_box(t.storage))
    L = RRC.tile_layout(tile)
    m = RRC._axis_model(op, dec)
    wrap = (b, c) -> _rrc_tile_wrap(m, b, c)
    u = _rrc_fill(L.u, L.n_u, ext, wrap)
    aux = _rrc_fill(L.aux, L.n_aux, ext, wrap)
    u0, aux0 = copy(u), copy(aux)
    du = du_shared === nothing ? fill(NaN, L.n_u) : du_shared
    RRC.rhs!(du, tile, RRC.rhs_workspace(tile), u, aux, p, 0.0, RRC.default_forcing_set(tile))
    @test isequal(u, u0)
    @test isequal(aux, aux0)
    # §5 layout: contiguous bases, column-major strides over storage.
    for (blocks, n) in ((L.u, L.n_u), (L.aux, L.n_aux))
        base = 1
        for b in blocks
            @test b.base == base
            s, len = RRC._box_strides(b.storage)
            @test b.strides == s
            base += isempty(b.storage) ? 1 : len
        end
        @test base - 1 == n
    end
    W = Dict(b.name => b for b in RRC.tile_layout(op).u)
    owned_slots = Set{Int}()
    covered = Int[]
    for b in L.u
        wb = W[b.name]
        cells = isempty(b.storage) ? [()] : CartesianIndices(Tuple(b.owned))
        for c in cells
            s = isempty(b.storage) ? b.base : RRC._tile_slot(b, Tuple(c))
            gs = isempty(b.storage) ? wb.base : RRC._tile_slot(wb, Tuple(c))
            push!(owned_slots, s)
            push!(covered, gs)
            @test _rrc_bits(du[s]) == _rrc_bits(G[gs])
        end
    end
    if du_shared === nothing
        @test all(k -> k in owned_slots || isnan(du[k]), eachindex(du))
    end
    return covered, owned_slots, L
end

# Julia runs two tiles of this case, the narrow boundary-band tile and an
# interior one, for the JIT cost of its template-heavy document; Rust runs
# every tiling.
const _RRC_JULIA_TILES = Dict("esd_latlon3d_regional_inflow" => [("narrow", 1), ("narrow", 2)])

function _rrc_tile_partition(c, prob)
    _, op = _rrc_op(c, prob)
    dec = _rrc_dec(c.decomposition)
    want = Dict((String(r.variable), String(r.index_set)) => (Int(r.lo), Int(r.hi)) for r in c.halo)
    @test RRC.halo(op, dec) == want
    G, ext = _rrc_whole(op, prob.p)
    @test all(isfinite, G)
    picks = get(_RRC_JULIA_TILES, String(c.id), nothing)
    if picks !== nothing
        for (tid, k) in picks
            tiling = only(t for t in c.tilings if String(t.id) == tid)
            @testset "tiling $tid tile $k" begin
                _rrc_check_tile!(op, dec, tiling.tiles[k], G, ext, prob.p)
            end
        end
        return
    end
    for tiling in c.tilings
        @testset "tiling $(tiling.id)" begin
            shared = get(tiling, :shared_storage, false) === true
            counts = zeros(Int, length(G))
            du_shared = nothing
            owned_all = Set{Int}()
            for t in tiling.tiles
                if shared && du_shared === nothing
                    tile0 = RRC.restrict(op, dec; owned = _rrc_box(t.owned),
                                         storage = _rrc_box(t.storage))
                    du_shared = fill(NaN, RRC.tile_layout(tile0).n_u)
                end
                cov, os, _ = _rrc_check_tile!(op, dec, t, G, ext, prob.p; du_shared = du_shared)
                union!(owned_all, os)
                for gs in cov
                    counts[gs] += 1
                end
            end
            shared && @test all(k -> k in owned_all || isnan(du_shared[k]), eachindex(du_shared))
            @test all(==(1), counts)
        end
    end
end

function _rrc_expect_error(f, c)
    err = try
        f()
        nothing
    catch e
        e
    end
    # `compiler_refused_rule` is a TreeWalkError, the range_* codes SimulateErrors.
    @test err isa RRC.EarthSciASTError && hasproperty(err, :code)
    (err isa RRC.EarthSciASTError && hasproperty(err, :code)) || return
    @test err.code == String(c.expect_error.code)
    msg = sprint(showerror, err)
    for k in (:variable, :index_set)
        haskey(c.expect_error, k) && @test occursin(String(c.expect_error[k]), msg)
    end
end

_rrc_lane_kind(c) = Symbol(String(c.lane_kind))

function _rrc_lanes(c, prob)
    _, op = _rrc_op(c, prob)
    G, ext = _rrc_whole(op, prob.p)
    W = Dict(b.name => b for b in RRC.tile_layout(op).u)
    sets = String[String(s) for s in c.lane_sets]
    lp = RRC.lanes(op, _rrc_lane_kind(c), sets)
    LL = RRC.lane_layout(lp)
    cap = Int(c.capacity)
    ws = RRC.rhs_workspace(lp)
    fs = RRC.default_forcing_set(lp)
    whole = Dict(b.name => b for b in vcat(RRC.tile_layout(op).u, RRC.tile_layout(op).aux))
    # The lane buffer of `blocks` gathered at `cells`.
    function gather(blocks, nper, cells)
        L = size(cells, 2)
        buf = fill(NaN, nper * L)
        for b in blocks
            wb = whole[b.name]
            for l in 1:L
                for (e, rest) in enumerate(CartesianIndices(Tuple(1:x for x in b.extents)))
                    g = _rrc_lane_cell(wb.sets, sets, cells[:, l], b.sets, Tuple(rest))
                    buf[(b.offset + e - 1) * L + l] = _rrc_value(b.name, g, ext[b.name])
                end
            end
        end
        return buf
    end
    function check(du, cells, n; expect = true)
        L = size(cells, 2)
        ok = true
        for b in LL.u
            wb = W[b.name]
            for l in 1:n
                for (e, rest) in enumerate(CartesianIndices(Tuple(1:x for x in b.extents)))
                    g = _rrc_lane_cell(wb.sets, sets, cells[:, l], b.sets, Tuple(rest))
                    gs = RRC._tile_slot(wb, Tuple(g))
                    ok &= _rrc_bits(du[(b.offset + e - 1) * L + l]) == _rrc_bits(G[gs])
                end
            end
        end
        return ok
    end
    for batch in c.batches
        @testset "batch $(batch.id)" begin
            cells = Int32[Int32(x[d]) for d in eachindex(sets), x in batch.cells]
            n = Int(batch.n)
            u = gather(LL.u, LL.n_u, cells)
            aux = gather(LL.aux, LL.n_aux, cells)
            du = fill(NaN, LL.n_u * size(cells, 2))
            RRC.rhs!(du, lp, ws, u, aux, prob.p, 0.0, fs, cells, n)
            @test check(du, cells, n)
            li = RRC.lane_inputs(lp, size(cells, 2))
            RRC.gather_lane_inputs!(li, lp, prob.p, 0.0, fs, cells, n)
            du2 = fill(NaN, LL.n_u * size(cells, 2))
            RRC.rhs!(du2, lp, ws, u, aux, prob.p, 0.0, li, cells, n)
            @test check(du2, cells, n)
            if String(batch.id) == String(c.negative_control.batch)
                a, b = Int.(c.negative_control.swap_lanes)
                L = size(cells, 2)
                swap!(buf, nper) = for e in 0:(nper - 1)
                    buf[e * L + a], buf[e * L + b] = buf[e * L + b], buf[e * L + a]
                end
                u2, aux2 = copy(u), copy(aux)
                swap!(u2, LL.n_u)
                swap!(aux2, LL.n_aux)
                du3 = fill(NaN, LL.n_u * L)
                RRC.rhs!(du3, lp, ws, u2, aux2, prob.p, 0.0, fs, cells, n)
                @test !check(du3, cells, n)
            end
        end
    end
end

# The global cell of a lane element: the lane sets from `cell`, the others from
# `rest` (in the variable's own set order).
function _rrc_lane_cell(vsets, lane_sets, cell, rest_sets, rest)
    g = Vector{Int}(undef, length(vsets))
    for d in eachindex(vsets)
        k = findfirst(==(vsets[d]), lane_sets)
        if k === nothing
            g[d] = rest[findfirst(==(vsets[d]), rest_sets)]
        else
            g[d] = Int(cell[k])
        end
    end
    return g
end

function _rrc_selection_sum(c, prob)
    prog = RRC.rhs_program(prob)
    F, ext = _rrc_whole(prog, prob.p)
    Wf = Dict(b.name => b for b in RRC.tile_layout(prog).u)
    sumG = zeros(length(F))
    sumA = zeros(length(F))
    for o in c.operators
        op = RRC.select(prog; writes = _rrc_writes(o.writes), terms = _rrc_terms(o.terms))
        @test [b.name for b in RRC.tile_layout(op).aux] == String[String(x) for x in o.aux]
        G, _ = _rrc_whole(op, prob.p)
        for b in RRC.tile_layout(op).u
            fb = Wf[b.name]
            for cc in (isempty(b.storage) ? [()] : CartesianIndices(Tuple(b.storage)))
                s = isempty(b.storage) ? b.base : RRC._tile_slot(b, Tuple(cc))
                fs = isempty(b.storage) ? fb.base : RRC._tile_slot(fb, Tuple(cc))
                sumG[fs] += G[s]
                sumA[fs] += abs(G[s])
            end
        end
    end
    rel = Float64(c.tolerance.rel)
    @test all(k -> abs(sumG[k] - F[k]) <= rel * sumA[k], eachindex(F))
end

function _rrc_selection_ok(c, prob)
    _, op = _rrc_op(c, prob)
    @test [b.name for b in RRC.tile_layout(op).aux] == String[String(x) for x in c.aux]
    G, _ = _rrc_whole(op, prob.p)
    for b in RRC.tile_layout(op).u
        String(b.name) in String.(c.zero_rows) || continue
        n = isempty(b.storage) ? 1 : prod(length, b.storage)
        @test all(==(0.0), G[b.base:(b.base + n - 1)])
    end
end

const _RRC_SUBCALL_DOC = "fixtures/esd/problems/latlon3d_transport_cwc_regional_inflow.esm"

@testset "range_restricted_rhs conformance (§5.49)" begin
    manifest = JSON3.read(read(joinpath(_RRC_DIR, "manifest.json"), String))
    @test manifest.compiler == "native"
    only = get(ENV, "RANGE_RHS_CASES", "")
    pick = isempty(only) ? nothing : Set(split(only, ","))
    for c in manifest.cases
        pick === nothing || String(c.id) in pick || continue
        # This template-heavy document's kernels compile far faster with each
        # template body emitted once as its own function (the value-exact,
        # opt-in `ESS_CG_SUBCALL_FN` tier); its whole-domain reference and its
        # tiles are all built under it. Rust runs the default lowering.
        knob = String(c.document) == _RRC_SUBCALL_DOC ? "1" : get(ENV, "ESS_CG_SUBCALL_FN", nothing)
        withenv("ESS_CG_SUBCALL_FN" => knob) do
        @testset "$(c.id)" begin
            prob = _rrc_problem(c)
            k = String(c.kind)
            if k == "tile_partition"
                _rrc_tile_partition(c, prob)
            elseif k == "tile_ok"
                _, op = _rrc_op(c, prob)
                G, ext = _rrc_whole(op, prob.p)
                _rrc_check_tile!(op, _rrc_dec(c.decomposition), c.tile, G, ext, prob.p)
            elseif k == "tile_error"
                _, op = _rrc_op(c, prob)
                _rrc_expect_error(c) do
                    RRC.restrict(op, _rrc_dec(c.decomposition); owned = _rrc_box(c.tile.owned),
                                 storage = _rrc_box(c.tile.storage))
                end
            elseif k == "halo_ok"
                _, op = _rrc_op(c, prob)
                want = Dict((String(r.variable), String(r.index_set)) => (Int(r.lo), Int(r.hi))
                            for r in c.halo)
                @test RRC.halo(op, _rrc_dec(c.decomposition)) == want
            elseif k == "halo_error"
                _, op = _rrc_op(c, prob)
                _rrc_expect_error(() -> RRC.halo(op, _rrc_dec(c.decomposition)), c)
            elseif k == "selection_sum"
                _rrc_selection_sum(c, prob)
            elseif k == "selection_error"
                _rrc_expect_error(() -> _rrc_op(c, prob), c)
            elseif k == "selection_ok"
                _rrc_selection_ok(c, prob)
            elseif k == "lanes"
                _rrc_lanes(c, prob)
            elseif k == "lanes_error"
                _, op = _rrc_op(c, prob)
                _rrc_expect_error(c) do
                    RRC.lanes(op, _rrc_lane_kind(c), String[String(s) for s in c.lane_sets])
                end
            else
                @test k == "a case kind this binding recognizes"
            end
        end
        end
    end
end
