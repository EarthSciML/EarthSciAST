# Hand-written reference kernel: monotone-PPM zonal (lon) face-flux + divergence,
# CW84 eq (1.6)/(1.8)/(1.10) on a uniform periodic lon row, applied over a full
# (NLON, NLAT, NLEV) grid. Structurally mirrors
# EarthSciDiscretizations/grids/latlon3d/stencils/ppmflux_D_lon_interior.esm
# (limited parabola endpoints of the two cells straddling each face; branch-free
# donor selection F = max(w,0)*aR_west + min(w,0)*aL_east; divergence weight per
# lat row) — but it is a COST YARDSTICK, not a conformance artifact: uniform-mesh
# PPM, plain loops, no region classes.
#
# This is the denominator for the perf plan's "RHS within 2-3x of hand-written"
# gate. One call to `ppm_lon_sweep!` advects ONE tracer along ONE axis over the
# whole grid; the bench driver reports both the raw sweep time and a
# "per-RHS-equivalent" time (sweep x 9: three axes x three advected fields,
# matching the m/mq/dev transport structure).

module BenchRefKernel

struct PPMWork{T}
    dqm::Vector{T}   # limited slopes, per cell
    ae::Vector{T}    # edge value at the west face of each cell (CW84 eq 1.6)
    aL::Vector{T}    # monotonized parabola endpoint, west
    aR::Vector{T}    # monotonized parabola endpoint, east
    F::Vector{T}     # face flux at the west face of each cell
end
PPMWork{T}(nlon::Int) where {T} =
    PPMWork{T}(zeros(T, nlon), zeros(T, nlon), zeros(T, nlon), zeros(T, nlon), zeros(T, nlon))

@inline _wrap(i, N) = i < 1 ? i + N : (i > N ? i - N : i)

"""
    ppm_lon_sweep!(du, q, U, w, ws)

du[i,j,k] -= w[j] * (F[i+1] - F[i]) with monotone-PPM face fluxes F from tracer
`q` and face-staggered zonal wind `U` (face i = west edge of cell i, periodic).
`w` is the per-lat divergence weight (dphi/(dlam*dS)); `ws` is scratch.
"""
function ppm_lon_sweep!(du::AbstractArray{T,3}, q::AbstractArray{T,3},
                        U::AbstractArray{T,3}, w::AbstractVector{T},
                        ws::PPMWork{T}) where {T}
    NLON, NLAT, NLEV = size(q)
    dqm, ae, aL, aR, F = ws.dqm, ws.ae, ws.aL, ws.aR, ws.F
    sixth = T(1) / T(6)
    @inbounds for k in 1:NLEV, j in 1:NLAT
        # 1. van-Leer limited slopes (CW84 eq 1.7/1.8, uniform mesh)
        for i in 1:NLON
            qm = q[_wrap(i - 1, NLON), j, k]; qc = q[i, j, k]; qp = q[_wrap(i + 1, NLON), j, k]
            dl = qc - qm; dr = qp - qc
            if dl * dr > zero(T)
                dq = (qp - qm) / 2
                dqm[i] = copysign(min(abs(dq), 2 * abs(dl), 2 * abs(dr)), dq)
            else
                dqm[i] = zero(T)
            end
        end
        # 2. edge interpolant at the west face of cell i (CW84 eq 1.6, uniform mesh)
        for i in 1:NLON
            im = _wrap(i - 1, NLON)
            ae[i] = (q[im, j, k] + q[i, j, k]) / 2 - sixth * (dqm[i] - dqm[im])
        end
        # 3. limited parabola endpoints per cell (CW84 eq 1.10 monotonization)
        for i in 1:NLON
            l = ae[i]; r = ae[_wrap(i + 1, NLON)]; qc = q[i, j, k]
            if (r - qc) * (qc - l) <= zero(T)
                l = qc; r = qc
            else
                d = r - l; c6 = d * (qc - (l + r) / 2)
                if c6 > d * d * sixth
                    l = 3 * qc - 2 * r
                elseif c6 < -(d * d * sixth)
                    r = 3 * qc - 2 * l
                end
            end
            aL[i] = l; aR[i] = r
        end
        # 4. branch-free donor face flux at the west face of cell i:
        #    F = max(U,0)*aR_{west cell} + min(U,0)*aL_{east cell}
        for i in 1:NLON
            Uf = U[i, j, k]
            F[i] = max(Uf, zero(T)) * aR[_wrap(i - 1, NLON)] + min(Uf, zero(T)) * aL[i]
        end
        # 5. flux divergence (periodic: east face of cell NLON is face 1)
        for i in 1:NLON
            du[i, j, k] -= w[j] * (F[_wrap(i + 1, NLON)] - F[i])
        end
    end
    return du
end

"Allocate inputs and sanity-check conservation (periodic row sums telescope to ~0)."
function setup(nlon::Int, nlat::Int, nlev::Int; T = Float64)
    q = [T(1 + 0.3 * sin(0.9i + 0.7j + 0.4k)) for i in 1:nlon, j in 1:nlat, k in 1:nlev]
    U = [T(0.2 * cos(0.5i + 0.3j) + 0.05 * sin(0.8k)) for i in 1:nlon, j in 1:nlat, k in 1:nlev]
    w = [T(1 / (110.0 + j)) for j in 1:nlat]
    du = zeros(T, nlon, nlat, nlev)
    ws = PPMWork{T}(nlon)
    ppm_lon_sweep!(du, q, U, w, ws)
    for k in 1:nlev, j in 1:nlat   # conservation gate: the periodic sum telescopes
        s = sum(@view du[:, j, k])
        abs(s) < 1e-12 * nlon || error("reference kernel row sum $s not ~0 (j=$j k=$k)")
    end
    fill!(du, zero(T))
    return (; du, q, U, w, ws)
end

end # module
