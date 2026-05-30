# End-to-end test: lat-lon diffusion PDE .esm → discretize → arrayop ODE .esm → Julia simulate.
#
# Bead: ess-m1e — Lat-lon grid support: periodic lon, non-periodic lat
#
# Setup:
#   Grid 4×2 (Nlon=4, Nlat=2), dlon=π/2, non-periodic lat (j passive)
#   PDE: ∂u/∂t = a·(1/dlon²)·[u[i-1,j] - 2u[i,j] + u[i+1,j]]
#   IC:  u[i,j] = sin(2·lon_i) where lon_i = -π + (i-0.5)·dlon
#          = [1.0, -1.0, 1.0, -1.0] for all j
#   FD eigenvalue for mode k=2 on periodic grid of size Nlon=4 with spacing dlon=π/2:
#     λ = (1/dlon²)·2·(cos(2π·k/Nlon) - 1) = (4/π²)·2·(cos(π) - 1) = (4/π²)·(-4) = -16/π²
#   Analytic solution: u(t) = u₀·exp(λ·t)  with  λ ≈ -1.6211
#   Verified at T=0.25: decay_factor = exp(-4/π²) ≈ 0.6668

using Test
using EarthSciSerialization
using JSON3
import ModelingToolkit
import OrdinaryDiffEqTsit5

const _MTK = ModelingToolkit
const _ESS = EarthSciSerialization

# ---------------------------------------------------------------------------
# Build PDE ESM as a Dict
# ---------------------------------------------------------------------------

function _build_latlon_diffusion_pde_esm(; Nlon=4, Nlat=2, dlon=π/2)
    # Stencil rule: lon-only finite difference (j is passive/unchanged).
    # Terms: (1/dlon²)·u[$u,i-1,j] + (-2/dlon²)·u[$u,i,j] + (1/dlon²)·u[$u,i+1,j]
    coeff_pos  = Dict("op" => "/", "args" => Any[1,  Dict("op" => "*", "args" => Any["dlon", "dlon"])])
    coeff_zero = Dict("op" => "/", "args" => Any[-2, Dict("op" => "*", "args" => Any["dlon", "dlon"])])

    mk_idx(u, di) = begin
        xi = di == 0 ? "i" : Dict("op" => "+", "args" => Any["i", di])
        Dict("op" => "index", "args" => Any[u, xi, "j"])
    end

    pvar = "\$u"  # ESS pattern variable — dollar sign must be literal, not interpolated
    stencil_terms = Any[
        Dict("op" => "*", "args" => Any[coeff_pos,  mk_idx(pvar, -1)]),
        Dict("op" => "*", "args" => Any[coeff_zero, mk_idx(pvar,  0)]),
        Dict("op" => "*", "args" => Any[coeff_pos,  mk_idx(pvar,  1)]),
    ]

    laplacian_rule = Dict{String,Any}(
        "name"    => "laplacian_2nd_lon",
        "pattern" => Dict("op" => "laplacian", "args" => Any[pvar]),
        "replacement" => Dict("op" => "+", "args" => stencil_terms),
    )

    return Dict{String,Any}(
        "esm"      => "0.2.0",
        "metadata" => Dict{String,Any}("name" => "diffusion_latlon_pde"),
        "grids"    => Dict{String,Any}(
            "g" => Dict{String,Any}(
                "family"     => "lat_lon",
                "dimensions" => Any[
                    Dict{String,Any}("name" => "lon", "size" => Nlon, "periodic" => true,  "spacing" => "uniform"),
                    Dict{String,Any}("name" => "lat", "size" => Nlat, "periodic" => false, "spacing" => "uniform"),
                ],
            ),
        ),
        "models" => Dict{String,Any}(
            "diffusion" => Dict{String,Any}(
                "grid" => "g",
                "variables" => Dict{String,Any}(
                    "u"    => Dict{String,Any}("type" => "state",     "shape" => Any["lon", "lat"],
                                               "location" => "cell_center"),
                    "a"    => Dict{String,Any}("type" => "parameter", "default" => 1.0),
                    "dlon" => Dict{String,Any}("type" => "parameter", "default" => dlon),
                ),
                "equations" => Any[
                    Dict{String,Any}(
                        "lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
                        "rhs" => Dict("op" => "*", "args" => Any[
                            "a",
                            Dict("op" => "laplacian", "args" => Any["u"]),
                        ]),
                    ),
                ],
            ),
        ),
        "rules" => Any[laplacian_rule],
    )
end

# ---------------------------------------------------------------------------
# Build a Model struct from the discretized output dict (bypasses load())
# ---------------------------------------------------------------------------

function _model_from_dict(model_dict::Dict{String,Any})
    vars = Dict{String,ModelVariable}()
    for (vname, vraw) in model_dict["variables"]
        vtype = get(vraw, "type", "state")
        mvtype = vtype == "parameter" ? ParameterVariable :
                 vtype == "observed"  ? ObservedVariable  : StateVariable
        default_val = get(vraw, "default", nothing)
        mv = default_val === nothing ? ModelVariable(mvtype) :
                                       ModelVariable(mvtype; default=Float64(default_val))
        vars[vname] = mv
    end

    eqs = _ESS.Equation[]
    for eq_raw in model_dict["equations"]
        lhs = _ESS.parse_expression(eq_raw["lhs"])
        rhs = _ESS.parse_expression(eq_raw["rhs"])
        push!(eqs, _ESS.Equation(lhs, rhs))
    end

    return Model(vars, eqs)
end

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@testset "Lat-lon diffusion PDE .esm → arrayop ODE .esm → Julia simulate (ess-m1e)" begin

    Nlon = 4
    Nlat = 2
    dlon = π / 2
    pde_esm = _build_latlon_diffusion_pde_esm(Nlon=Nlon, Nlat=Nlat, dlon=dlon)

    # ------------------------------------------------------------------
    # Step 1: discretize() must succeed and produce a valid ODE .esm dict
    # ------------------------------------------------------------------
    ode_esm = @test_nowarn discretize(pde_esm)
    @test ode_esm isa Dict{String,Any}
    @test get(ode_esm["metadata"], "system_class", nothing) == "ode"

    # ------------------------------------------------------------------
    # Step 2: The discretized equation must have arrayop LHS and RHS
    # ------------------------------------------------------------------
    diff_model = ode_esm["models"]["diffusion"]
    eqns = diff_model["equations"]
    @test length(eqns) == 1

    eq = eqns[1]
    lhs_raw = eq["lhs"]
    rhs_raw = eq["rhs"]

    @test lhs_raw isa AbstractDict
    @test rhs_raw isa AbstractDict

    lhs_expr = parse_expression(lhs_raw)
    rhs_expr = parse_expression(rhs_raw)

    @test lhs_expr isa OpExpr
    @test lhs_expr.op == "arrayop"
    @test rhs_expr isa OpExpr
    @test rhs_expr.op == "arrayop"

    # LHS body must be D(index(u, i, j), wrt="t")
    lhs_body = lhs_expr.expr_body
    @test lhs_body isa OpExpr
    @test lhs_body.op == "D"
    @test lhs_body.wrt == "t"

    # arrayop ranges cover the full Nlon×Nlat grid
    @test haskey(lhs_expr.ranges, "i")
    @test haskey(lhs_expr.ranges, "j")
    @test lhs_expr.ranges["i"] == [1, Nlon]
    @test lhs_expr.ranges["j"] == [1, Nlat]

    # RHS must reference index ops and contain periodic folding (ifelse) but no laplacian
    rhs_json = JSON3.write(rhs_raw)
    @test occursin("\"index\"", rhs_json)
    @test occursin("\"ifelse\"", rhs_json)
    @test !occursin("\"laplacian\"", rhs_json)

    # ------------------------------------------------------------------
    # Step 3: Simulate via Julia MTK path
    # ------------------------------------------------------------------
    model = _model_from_dict(diff_model)
    sys   = _MTK.System(model; name=:diffusion)
    simp  = _MTK.mtkcompile(sys)

    @test length(_MTK.unknowns(simp)) == Nlon * Nlat

    # Build initial condition: u[i,j] = sin(2·lon_i)
    # where lon_i = -π + (i - 0.5)·dlon
    #   i=1: lon=-3π/4, sin(-3π/2)... actually lon_1 = -π + 0.5·(π/2) = -π + π/4 = -3π/4
    #   sin(2·(-3π/4)) = sin(-3π/2) = 1.0  (sin wraps: sin(-3π/2)=sin(π/2)=1)
    #   More directly: the four values cycle as [1,-1,1,-1] for the k=2 mode on 4 points.
    u_arr = _MTK.getproperty(simp, :diffusion_u)
    u0 = Dict{Any,Float64}()
    for i in 1:Nlon, j in 1:Nlat
        lon_i = -π + (i - 0.5) * dlon
        u0[u_arr[i, j]] = sin(2 * lon_i)
    end

    # Confirm IC has the expected [1,-1,1,-1] pattern across lon
    for j in 1:Nlat
        @test u0[u_arr[1, j]] ≈  1.0  atol=1e-12
        @test u0[u_arr[2, j]] ≈ -1.0  atol=1e-12
        @test u0[u_arr[3, j]] ≈  1.0  atol=1e-12
        @test u0[u_arr[4, j]] ≈ -1.0  atol=1e-12
    end

    T = 0.25
    prob = _MTK.ODEProblem(simp, u0, (0.0, T))
    sol  = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                     reltol=1e-10, abstol=1e-12)
    @test sol.retcode == _MTK.SciMLBase.ReturnCode.Success

    # Analytic FD eigenvalue for mode k=2, Nlon=4, dlon=π/2:
    #   λ = (1/dlon²)·2·(cos(2π·2/4) − 1) = (4/π²)·2·(−1 − 1) = −16/π²
    lambda = -16.0 / π^2
    decay_factor = exp(lambda * T)   # exp(-4/π²) ≈ 0.6668
    @test decay_factor ≈ exp(-4.0 / π^2)  rtol=1e-10

    max_err = 0.0
    for i in 1:Nlon, j in 1:Nlat
        lon_i   = -π + (i - 0.5) * dlon
        u0_ij   = sin(2 * lon_i)
        u_exact = u0_ij * decay_factor
        u_sim   = sol(T; idxs=u_arr[i, j])
        max_err = max(max_err, abs(u_sim - u_exact))
    end
    @info "Lat-lon diffusion max error vs analytic FD decay" max_err decay_factor lambda

    @test max_err < 1e-6

    # Sign pattern: cells 1,3 positive; cells 2,4 negative
    for j in 1:Nlat
        @test sol(T; idxs=u_arr[1, j]) > 0
        @test sol(T; idxs=u_arr[2, j]) < 0
        @test sol(T; idxs=u_arr[3, j]) > 0
        @test sol(T; idxs=u_arr[4, j]) < 0
    end
end
