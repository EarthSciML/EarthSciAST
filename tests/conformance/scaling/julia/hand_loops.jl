# Hand-written reference right-hand sides for the scaling tier (Julia).
#
# One per family. Each computes the same dy as the generated document at the
# same size, as the plain loop someone would write for that document in Julia:
# `@inbounds`, boundary cases peeled out of the innermost loop, no `@simd`, no
# intrinsics, no reassociated reductions. The adapter checks every loop against
# native's dy at the same (u, p, t), so a wrong reference cannot make a slow
# compiler look fast.
#
# SHAPE. Every loop is written as `row!(du, u, t, st, r)` over its OUTERMOST
# index `r in 1:st.nrows`. The serial reference runs the rows in order; the
# threaded reference is the same rows under `Threads.@threads :static`. A row
# writes only its own `du` slots, so the two agree bit for bit. The one family
# whose outermost index carries a dependence (the prefix scan) has a single
# row, so its threaded reference is its serial loop; the README says so.
#
# LAYOUT. `setup` reads the state layout off `prob.var_map` (the public
# name → slot map) and the parameter values off `prob.p`, once, outside the
# timed call. A variable whose cells native lays out as one contiguous
# column-major block is addressed by offset; the scalar chemistry boxes, which
# have no array structure, go through a slot table. The document itself is read
# for its inline data (the mesh neighbour table, the regrid polygons).

struct HandLoop
    setup::Function      # (prob, doc, entry) -> st, st.nrows the outermost extent
    row!::Function       # (du, u, t, st, r) -> nothing
end

const HAND_LOOPS = Dict{String,HandLoop}()

function hand_serial!(row!::F, du, u, t, st) where {F}
    for r in 1:st.nrows
        row!(du, u, t, st, r)
    end
    return nothing
end

function hand_threaded!(row!::F, du, u, t, st) where {F}
    Threads.@threads :static for r in 1:st.nrows
        row!(du, u, t, st, r)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Layout helpers
# ---------------------------------------------------------------------------

_cell_key(name, I) = string(name, "[", join(Tuple(I), ","), "]")

# The slots of array variable `name` (component-qualified), shaped `dims`.
function _slots(vm::AbstractDict, name::AbstractString, dims::Tuple)
    S = Array{Int}(undef, dims)
    for I in CartesianIndices(S)
        k = _cell_key(name, I)
        haskey(vm, k) || error("the state layout has no slot for $k")
        S[I] = vm[k]
    end
    return S
end

# The offset `o` with `S == o+1:o+length(S)` in column-major order, or an error:
# every array loop below addresses its variable as one contiguous block.
function _block_offset(vm, name, dims)
    S = _slots(vm, name, dims)
    o = S[1] - 1
    for (c, s) in enumerate(S)
        s == o + c || error("$name is not one contiguous column-major block in the state " *
                            "vector, which this hand loop assumes")
    end
    return o
end

_param(p, name) = Float64(getfield(p, Symbol(name)))

_shape(entry, key) = Int(entry["shape"][key])

# Rows of a one-axis loop: blocks of this many cells.
const _BLOCK = 4096

# ---------------------------------------------------------------------------
# Stencils (rank 1-4): kappa * (sum of the 2*rank neighbours - 2*rank*u)
# ---------------------------------------------------------------------------
#
# Out-of-range neighbours read the zero ghost `Z`. The sum runs axis by axis in
# declaration order, +1 neighbour then -1 neighbour, left to right, which is the
# document's order. The innermost axis is peeled at its two ends; an outer
# axis's missing neighbour is a test that does not change along the row.

const Z = 0.0

function _stencil_setup(rank)
    return function (prob, doc, entry)
        s = _shape(entry, "side")
        o = _block_offset(prob.var_map, "Diffusion.u", ntuple(_ -> s, rank))
        kappa = _param(prob.p, "Diffusion.kappa")
        nrows = rank == 1 ? cld(s, _BLOCK) : s
        return (; o, s, kappa, c = Float64(2 * rank), nrows)
    end
end

# One cell of an innermost row whose cell i is slot `b + i`, given its two
# inner-axis neighbours. `outer` holds, per outer axis in order, (stride, has a
# +1 neighbour, has a -1 neighbour).
@inline function _stencil_cell!(du, u, b, i, ip, im, kappa, c, outer)
    acc = ip + im
    @inbounds begin
        for (st, hp, hm) in outer
            acc = (acc + (hp ? u[b+st+i] : Z)) + (hm ? u[b-st+i] : Z)
        end
        du[b+i] = kappa * (acc - c * u[b+i])
    end
    return nothing
end

# Cells lo:hi of one innermost row, its two ends peeled.
@inline function _stencil_inner!(du, u, b, s, lo, hi, kappa, c, outer)
    @inbounds begin
        if lo == 1
            _stencil_cell!(du, u, b, 1, s > 1 ? u[b+2] : Z, Z, kappa, c, outer)
            lo = 2
        end
        if hi == s && s > 1
            _stencil_cell!(du, u, b, s, Z, u[b+s-1], kappa, c, outer)
            hi = s - 1
        end
        for i in lo:hi
            _stencil_cell!(du, u, b, i, u[b+i+1], u[b+i-1], kappa, c, outer)
        end
    end
    return nothing
end

@inline function _st1_row!(du, u, t, st, r)
    (; o, s, kappa, c) = st
    _stencil_inner!(du, u, o, s, (r - 1) * _BLOCK + 1, min(r * _BLOCK, s), kappa, c, ())
end

@inline function _st2_row!(du, u, t, st, r)
    (; o, s, kappa, c) = st
    j = r
    _stencil_inner!(du, u, o + (j - 1) * s, s, 1, s, kappa, c, ((s, j < s, j > 1),))
end

@inline function _st3_row!(du, u, t, st, r)
    (; o, s, kappa, c) = st
    k = r
    s2 = s * s
    for j in 1:s
        _stencil_inner!(du, u, o + (j - 1) * s + (k - 1) * s2, s, 1, s, kappa, c,
                        ((s, j < s, j > 1), (s2, k < s, k > 1)))
    end
end

@inline function _st4_row!(du, u, t, st, r)
    (; o, s, kappa, c) = st
    l = r
    s2 = s * s
    s3 = s2 * s
    for k in 1:s, j in 1:s
        _stencil_inner!(du, u, o + (j - 1) * s + (k - 1) * s2 + (l - 1) * s3, s, 1, s, kappa, c,
                        ((s, j < s, j > 1), (s2, k < s, k > 1), (s3, l < s, l > 1)))
    end
end

HAND_LOOPS["stencil_1d"] = HandLoop(_stencil_setup(1), _st1_row!)
HAND_LOOPS["stencil_2d"] = HandLoop(_stencil_setup(2), _st2_row!)
HAND_LOOPS["stencil_3d"] = HandLoop(_stencil_setup(3), _st3_row!)
HAND_LOOPS["stencil_4d"] = HandLoop(_stencil_setup(4), _st4_row!)

# ---------------------------------------------------------------------------
# Transport: -((Dx(q) + Dy(q)) + Dz(q)), each a five-class limited derivative
# ---------------------------------------------------------------------------
#
# Per axis, with f(n) the value n cells along it: two one-sided faces (classes
# 1 and 7), two near-face centred classes (2 and 6), and the limited interior.
# A row (fixed j, k) is written in four passes over its cells: Dx, + Dy, + Dz,
# then the sign. That is the same arithmetic in the same order as one
# expression per cell, and it keeps every inner loop free of a class test: the
# x class is peeled, and the y and z classes are fixed along the row.

@inline _tr_c1(f1, f2, f3) = 1.5 * (f2 - f1) - 0.5 * (f3 - f2)
@inline _tr_c2(fm, fp) = 0.5 * (fp - fm)
@inline _tr_c7(fs, fs1, fs2) = 1.5 * (fs - fs1) - 0.5 * (fs1 - fs2)
@inline function _tr_int(m2, m1, c, p1, p2)
    return ((0.6666666666666666 * (p1 - m1) + -0.08333333333333333 * (p2 - m2)) +
            0.05 * (min(p1, c) - max(m1, c))) + 0.025 * (min(p2, p1) - max(m2, m1))
end

function _transport_setup(prob, doc, entry)
    s = _shape(entry, "side")
    o = _block_offset(prob.var_map, "Transport.q", (s, s, s))
    return (; o, s, nrows = s)
end

# du[b+i] = Dx at (i, j, k) for the row whose cell i is slot b + i.
@inline function _tr_dx!(du, u, b, s)
    @inbounds begin
        du[b+1] = _tr_c1(u[b+1], u[b+2], u[b+3])
        du[b+2] = _tr_c2(u[b+1], u[b+3])
        for i in 3:s-2
            du[b+i] = _tr_int(u[b+i-2], u[b+i-1], u[b+i], u[b+i+1], u[b+i+2])
        end
        du[b+s-1] = _tr_c2(u[b+s-2], u[b+s])
        du[b+s] = _tr_c7(u[b+s], u[b+s-1], u[b+s-2])
    end
    return nothing
end

# du[b+i] += the derivative along an outer axis of stride `st`, at position n.
@inline function _tr_add!(du, u, b, s, st, n)
    @inbounds begin
        f0 = b - (n - 1) * st            # f(m) is u[f0 + (m-1)*st + i]
        if n == 1
            for i in 1:s
                du[b+i] += _tr_c1(u[f0+i], u[f0+st+i], u[f0+2st+i])
            end
        elseif n == 2 || n == s - 1
            for i in 1:s
                du[b+i] += _tr_c2(u[b-st+i], u[b+st+i])
            end
        elseif n == s
            for i in 1:s
                du[b+i] += _tr_c7(u[b+i], u[b-st+i], u[b-2st+i])
            end
        else
            for i in 1:s
                du[b+i] += _tr_int(u[b-2st+i], u[b-st+i], u[b+i], u[b+st+i], u[b+2st+i])
            end
        end
    end
    return nothing
end

@inline function _tr_row!(du, u, t, st, r)
    (; o, s) = st
    k = r
    s2 = s * s
    @inbounds for j in 1:s
        b = o + (j - 1) * s + (k - 1) * s2
        _tr_dx!(du, u, b, s)
        _tr_add!(du, u, b, s, s, j)
        _tr_add!(du, u, b, s, s2, k)
        for i in 1:s
            du[b+i] = -du[b+i]
        end
    end
    return nothing
end

HAND_LOOPS["transport_3d"] = HandLoop(_transport_setup, _tr_row!)

# ---------------------------------------------------------------------------
# Pollu (20 species, 25 reactions): mass action, shared by the two chemistry
# families
# ---------------------------------------------------------------------------

const POLLU_SPECIES = ("NO2", "NO", "O3P", "O3", "HO2", "OH", "CH2O", "CO", "ALD", "MEO2",
                       "C2O3", "CO2", "PAN", "CH3O", "HNO3", "O1D", "SO2", "SO4", "NO3", "N2O5")
const POLLU_RATES = ("jNO2_O3P", "k2", "k3", "jH2COa", "jH2COb", "k6", "jALD", "k8", "k9", "k10",
                     "jPAN", "k12", "k13", "k14", "k15", "jO3_O1D", "jO3_O3P", "k18", "k19", "k20",
                     "jNO3_NO", "jNO3_NO2", "k23", "k24", "jN2O5")

_pollu_rates(p, prefix) = ntuple(r -> _param(p, prefix * POLLU_RATES[r]), Val(25))

# Species tendencies, in POLLU_SPECIES order, from the 20 concentrations `c`
# (same order) and the 25 rate constants `k`.
@inline function _pollu(c, k)
    NO2, NO, O3P, O3, HO2, OH, CH2O, CO, ALD, MEO2, C2O3, CO2, PAN, CH3O, HNO3, O1D, SO2, SO4, NO3, N2O5 = c
    r1 = k[1] * NO2
    r2 = k[2] * NO * O3
    r3 = k[3] * HO2 * NO
    r4 = k[4] * CH2O
    r5 = k[5] * CH2O
    r6 = k[6] * CH2O * OH
    r7 = k[7] * ALD
    r8 = k[8] * ALD * OH
    r9 = k[9] * C2O3 * NO
    r10 = k[10] * C2O3 * NO2
    r11 = k[11] * PAN
    r12 = k[12] * MEO2 * NO
    r13 = k[13] * CH3O
    r14 = k[14] * NO2 * OH
    r15 = k[15] * O3P
    r16 = k[16] * O3
    r17 = k[17] * O3
    r18 = k[18] * O1D
    r19 = k[19] * O1D
    r20 = k[20] * SO2 * OH
    r21 = k[21] * NO3
    r22 = k[22] * NO3
    r23 = k[23] * NO2 * O3
    r24 = k[24] * NO3 * NO2
    r25 = k[25] * N2O5
    return (-r1 + r2 + r3 + r9 - r10 + r11 + r12 - r14 + r22 - r23 - r24 + r25,   # NO2
            r1 - r2 - r3 - r9 - r12 + r21,                                    # NO
            r1 - r15 + r17 + r19 + r22,                                       # O3P
            -r2 + r15 - r16 - r17 - r23,                                      # O3
            -r3 + 2 * r4 + r6 + r7 + r13 + r20,                               # HO2
            r3 - r6 - r8 - r14 + 2 * r18 - r20,                               # OH
            -r4 - r5 - r6 + r13,                                              # CH2O
            r4 + r5 + r6 + r7,                                                # CO
            -r7 - r8,                                                         # ALD
            r7 + r9 - r12,                                                    # MEO2
            r8 - r9 - r10 + r11,                                              # C2O3
            r9,                                                               # CO2
            r10 - r11,                                                        # PAN
            r12 - r13,                                                        # CH3O
            r14,                                                              # HNO3
            r16 - r18 - r19,                                                  # O1D
            -r20,                                                             # SO2
            r20,                                                              # SO4
            -r21 - r22 + r23 - r24 + r25,                                     # NO3
            r24 - r25)                                                        # N2O5
end

# Chemistry on a lon x lat grid plus -u_wind * grad_lon(species): centred in
# the interior, one-sided at the two lon faces.
function _chemgrid_setup(prob, doc, entry)
    nlon = _shape(entry, "nlon")
    nlat = _shape(entry, "nlat")
    offs = ntuple(q -> _block_offset(prob.var_map, "Pollu." * POLLU_SPECIES[q], (nlon, nlat)), Val(20))
    k = _pollu_rates(prob.p, "Pollu.")
    uw = _param(prob.p, "Advection.u_wind")
    dx = _param(prob.p, "Advection.dx")
    return (; nlon, nlat, offs, k, uw, dx, nrows = nlat)
end

# One loop over the row per species, as the document has one equation per
# species. `_pollu` is inlined with its species fixed, so each loop computes
# only the rates that species reads. The lon faces are peeled.
@inline function _chemgrid_species!(du, u, st, b, ::Val{q}) where {q}
    (; nlon, offs, k, uw, dx) = st
    o = offs[q] + b
    @inbounds begin
        du[o+1] = _pollu(ntuple(s -> u[offs[s]+b+1], Val(20)), k)[q] + -uw * ((u[o+2] - u[o+1]) / dx)
        for i in 2:nlon-1
            dc = _pollu(ntuple(s -> u[offs[s]+b+i], Val(20)), k)[q]
            du[o+i] = dc + -uw * ((u[o+i+1] - u[o+i-1]) / (2 * dx))
        end
        du[o+nlon] = _pollu(ntuple(s -> u[offs[s]+b+nlon], Val(20)), k)[q] +
                     -uw * ((u[o+nlon] - u[o+nlon-1]) / dx)
    end
    return nothing
end

@inline function _chemgrid_row!(du, u, t, st, r)
    b = (r - 1) * st.nlon
    Base.Cartesian.@nexprs 20 q -> _chemgrid_species!(du, u, st, b, Val(q))
    return nothing
end

HAND_LOOPS["chemistry_grid"] = HandLoop(_chemgrid_setup, _chemgrid_row!)

# Independent scalar boxes: box b's species `<name>_<b>` sit wherever the
# layout put them, so they are read through a 20 x boxes slot table.
function _scalarchem_setup(prob, doc, entry)
    boxes = _shape(entry, "boxes")
    vm = prob.var_map
    S = Matrix{Int}(undef, 20, boxes)
    for b in 1:boxes, q in 1:20
        S[q, b] = vm["Boxes." * POLLU_SPECIES[q] * "_" * string(b)]
    end
    k = _pollu_rates(prob.p, "Boxes.")
    return (; S, k, nrows = boxes)
end

@inline function _scalarchem_row!(du, u, t, st, r)
    (; S, k) = st
    @inbounds begin
        c = ntuple(q -> u[S[q, r]], Val(20))
        dc = _pollu(c, k)
        for q in 1:20
            du[S[q, r]] = dc[q]
        end
    end
    return nothing
end

HAND_LOOPS["scalar_chemistry"] = HandLoop(_scalarchem_setup, _scalarchem_row!)

# ---------------------------------------------------------------------------
# Prefix scan: D(u[i]) = -0.001 * sum_{j <= i} u[j] * dz[j]
# ---------------------------------------------------------------------------
#
# A running sum: each row depends on the one before, so there is one row.

function _scan_setup(prob, doc, entry)
    n = Int(entry["n_cells"])
    o = _block_offset(prob.var_map, "Column.u", (n,))
    dz = Float64(doc["models"]["Column"]["variables"]["dz"]["default"])
    return (; o, n, dz, nrows = 1)
end

@inline function _scan_row!(du, u, t, st, r)
    (; o, n, dz) = st
    acc = 0.0
    @inbounds for i in 1:n
        acc += u[o+i] * dz
        du[o+i] = -0.001 * acc
    end
    return nothing
end

HAND_LOOPS["prefix_scan"] = HandLoop(_scan_setup, _scan_row!)

# ---------------------------------------------------------------------------
# Dense source-receptor: D(c[i]) = sum_j K[i,j] * e[j], D(e[j]) = -kd * e[j]
# ---------------------------------------------------------------------------
#
# K is stored transposed so a receptor's row is contiguous, the layout a
# hand-written matrix-vector product would choose; the sum over j keeps its
# order.

function _sr_setup(prob, doc, entry)
    n = Int(entry["n_cells"])
    oc = _block_offset(prob.var_map, "SourceReceptor.c", (n,))
    oe = _block_offset(prob.var_map, "SourceReceptor.e", (n,))
    Kd = Float64(doc["models"]["SourceReceptor"]["variables"]["K"]["default"])
    KT = fill(Kd, n, n)
    kd = _param(prob.p, "SourceReceptor.kd")
    return (; n, oc, oe, KT, kd, nrows = n)
end

@inline function _sr_row!(du, u, t, st, r)
    (; n, oc, oe, KT, kd) = st
    i = r
    acc = 0.0
    @inbounds begin
        for j in 1:n
            acc += KT[j, i] * u[oe+j]
        end
        du[oc+i] = acc
        du[oe+i] = -kd * u[oe+i]
    end
    return nothing
end

HAND_LOOPS["source_receptor"] = HandLoop(_sr_setup, _sr_row!)

# ---------------------------------------------------------------------------
# Conservative regrid: D(F_src[i]) = -kd F_src[i];
# D(F_tgt[j]) = sum_i W[i,j] F_src[i] - F_tgt[j]
# ---------------------------------------------------------------------------
#
# The weights are the document's: a pair (i, j) is admitted when the two
# cells' bin keys (floor of the polygon's minimum lon / dx and lat / dy) are
# equal, it is alive when its overlap area exceeds atol, and W = A_ij / A_j with
# A_j the alive row sum. The cells are axis-aligned rectangles, so the overlap
# is the product of the two interval overlaps. Setup builds the sparse rows
# once; the call is the sparse apply.

function _rect(poly)
    xs = [Float64(v[1]) for v in poly]
    ys = [Float64(v[2]) for v in poly]
    return (minimum(xs), maximum(xs), minimum(ys), maximum(ys))
end

function _regrid_setup(prob, doc, entry)
    n = Int(entry["n_cells"])
    vm = prob.var_map
    os = _block_offset(vm, "Regrid.F_src", (n,))
    ot = _block_offset(vm, "Regrid.F_tgt", (n,))
    eqs = doc["models"]["Regrid"]["equations"]
    poly(name) = only(e["rhs"]["value"] for e in eqs if e["lhs"] == name)
    src = [_rect(c) for c in poly("src_poly")]
    tgt = [_rect(c) for c in poly("tgt_poly")]
    p = prob.p
    bdx, bdy = _param(p, "Regrid.dx"), _param(p, "Regrid.dy")
    atol = _param(p, "Regrid.atol")
    kd = _param(p, "Regrid.kd")
    bin(r) = (floor(r[1] / bdx), floor(r[3] / bdy))
    bysrc = Dict{Tuple{Float64,Float64},Vector{Int}}()
    for (i, r) in enumerate(src)
        push!(get!(bysrc, bin(r), Int[]), i)
    end
    rowptr = Int[1]
    cols = Int[]
    wts = Float64[]
    for (j, rt) in enumerate(tgt)
        cand = sort!(copy(get(bysrc, bin(rt), Int[])))
        areas = Float64[]
        alive = Int[]
        for i in cand
            rs = src[i]
            a = max(0.0, min(rs[2], rt[2]) - max(rs[1], rt[1])) *
                max(0.0, min(rs[4], rt[4]) - max(rs[3], rt[3]))
            a > atol && (push!(alive, i); push!(areas, a))
        end
        Aj = 0.0
        for a in areas
            Aj += a
        end
        append!(cols, alive)
        append!(wts, areas ./ Aj)
        push!(rowptr, length(cols) + 1)
    end
    return (; n, os, ot, kd, rowptr, cols, wts, nrows = n)
end

@inline function _regrid_row!(du, u, t, st, r)
    (; os, ot, kd, rowptr, cols, wts) = st
    j = r
    acc = 0.0
    @inbounds begin
        for q in rowptr[j]:(rowptr[j+1]-1)
            acc += wts[q] * u[os+cols[q]]
        end
        du[ot+j] = acc - u[ot+j]
        du[os+j] = -kd * u[os+j]
    end
    return nothing
end

HAND_LOOPS["regrid"] = HandLoop(_regrid_setup, _regrid_row!)

# ---------------------------------------------------------------------------
# Unstructured gather: D(u[c]) = sum_k kappa * (u[nbr[c,k]] - u[c])
# ---------------------------------------------------------------------------
#
# The neighbour table is the document's: the const equation that defines `nbr`.

function _gather_setup(prob, doc, entry)
    m = Int(entry["n_cells"])
    o = _block_offset(prob.var_map, "Mesh.u", (m,))
    eqs = doc["models"]["Mesh"]["equations"]
    tbl = only(e["rhs"]["value"] for e in eqs if e["lhs"] == "nbr")
    nbr = Matrix{Int}(undef, 4, m)          # nbr[k, c]: a cell's four neighbours together
    for c in 1:m, k in 1:4
        nbr[k, c] = Int(tbl[c][k])
    end
    kappa = _param(prob.p, "Mesh.kappa")
    return (; m, o, nbr, kappa, nrows = cld(m, _BLOCK))
end

@inline function _gather_row!(du, u, t, st, r)
    (; m, o, nbr, kappa) = st
    @inbounds for c in ((r-1)*_BLOCK+1):min(r * _BLOCK, m)
        uc = u[o+c]
        acc = kappa * (u[o+nbr[1, c]] - uc)
        acc += kappa * (u[o+nbr[2, c]] - uc)
        acc += kappa * (u[o+nbr[3, c]] - uc)
        acc += kappa * (u[o+nbr[4, c]] - uc)
        du[o+c] = acc
    end
    return nothing
end

HAND_LOOPS["unstructured_gather"] = HandLoop(_gather_setup, _gather_row!)
