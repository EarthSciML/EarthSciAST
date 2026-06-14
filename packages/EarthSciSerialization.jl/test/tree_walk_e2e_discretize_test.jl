# End-to-end pathway test for tree_walk simulation runner (esm-qrj).
#
# Asserts tree_walk works as an OFFICIAL ESS Julia simulation runner:
# the model travels parse → discretize → build_evaluator → solve.

using Test
using JSON3
using EarthSciSerialization
import OrdinaryDiffEqTsit5

const _E2E_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))

@testset "tree_walk e2e: parse → discretize → build_evaluator → solve (esm-qrj)" begin
    fixture = joinpath(_E2E_REPO_ROOT, "tests", "conformance", "discretize",
                       "inputs", "scalar_ode.esm")
    @test isfile(fixture)

    esm = JSON3.read(read(fixture, String))
    discretized = discretize(esm)
    @test discretized isa Dict{String,Any}
    @test discretized["metadata"]["system_class"] == "ode"

    f!, u0, p, tspan_default, var_map = build_evaluator(discretized)
    @test haskey(var_map, "x")
    @test length(u0) == 1
    @test u0[var_map["x"]] == 1.0
    @test p.k == 0.5
    @test tspan_default == (0.0, 1.0)

    prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, (0.0, 4.0), p)
    sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                    reltol=1e-9, abstol=1e-11)
    @test isapprox(sol.u[end][var_map["x"]], exp(-2.0); rtol=1e-7)
end

@testset "tree_walk e2e: 1D PDE → discretize(lift_1d_arrayop=true) → build_evaluator" begin
    # A 1D periodic advection document whose grad op is rewritten by a
    # centered-difference rule with the 1/(2·dx) coefficient. With
    # lift_1d_arrayop=true the equation lifts to arrayop form and the
    # tree-walk evaluator expands it per cell, so one f! evaluation must
    # reproduce the centered stencil exactly.
    n = 8
    dx = 1.0 / n
    esm = Dict{String,Any}(
        "esm"      => "0.4.0",
        "metadata" => Dict{String,Any}("name" => "advection_1d_lift"),
        "grids"    => Dict{String,Any}(
            "gx" => Dict{String,Any}(
                "family"     => "cartesian",
                "dimensions" => Any[
                    Dict{String,Any}("name" => "i", "size" => n,
                                      "periodic" => true, "spacing" => "uniform"),
                ],
            ),
        ),
        "rules" => Any[
            Dict{String,Any}(
                "name"    => "centered_grad",
                "pattern" => Dict{String,Any}("op" => "grad", "args" => Any["\$u"], "dim" => "\$x"),
                "replacement" => Dict{String,Any}(
                    "op"   => "/",
                    "args" => Any[
                        Dict{String,Any}("op" => "-", "args" => Any[
                            Dict{String,Any}("op" => "index", "args" => Any[
                                "\$u", Dict{String,Any}("op" => "+", "args" => Any["\$x", 1])]),
                            Dict{String,Any}("op" => "index", "args" => Any[
                                "\$u", Dict{String,Any}("op" => "-", "args" => Any["\$x", 1])]),
                        ]),
                        Dict{String,Any}("op" => "*", "args" => Any[2, "dx"]),
                    ],
                ),
            ),
        ],
        "models" => Dict{String,Any}(
            "M" => Dict{String,Any}(
                "grid" => "gx",
                "variables" => Dict{String,Any}(
                    "u" => Dict{String,Any}(
                        "type" => "state", "default" => 0.0, "units" => "1",
                        "shape" => Any["i"], "location" => "cell_center",
                    ),
                    "dx" => Dict{String,Any}(
                        "type" => "parameter", "default" => dx, "units" => "1",
                    ),
                ),
                "equations" => Any[
                    Dict{String,Any}(
                        "lhs" => Dict{String,Any}("op" => "D", "args" => Any["u"], "wrt" => "t"),
                        "rhs" => Dict{String,Any}("op" => "grad", "args" => Any["u"], "dim" => "i"),
                    ),
                ],
            ),
        ),
    )

    discretized = discretize(esm; lift_1d_arrayop=true)
    @test discretized["models"]["M"]["equations"][1]["lhs"]["op"] == "arrayop"

    f!, u0, p, _tspan, var_map = build_evaluator(discretized)
    @test length(u0) == n
    cell_x(i) = (i - 0.5) * dx
    for i in 1:n
        u0[var_map["u[$i]"]] = sin(2π * cell_x(i))
    end
    du = similar(u0)
    f!(du, u0, p, 0.0)

    wrap(i) = mod(i - 1, n) + 1
    for i in 1:n
        expected = (sin(2π * cell_x(wrap(i + 1))) - sin(2π * cell_x(wrap(i - 1)))) / (2 * dx)
        @test isapprox(du[var_map["u[$i]"]], expected; rtol=1e-12, atol=1e-12)
    end
end

@testset "tree_walk e2e: bounded 1D with dirichlet + neumann BCs (ess-gp3)" begin
    # D(u) = grad(u) → -u[i-1] + u[i+1]; dirichlet 3 at imin, zero-flux at
    # imax. One f! evaluation must show the ghost-value substitution at the
    # left boundary and the zero-flux mirror at the right, exactly.
    n = 8
    esm = Dict{String,Any}(
        "esm"      => "0.4.0",
        "metadata" => Dict{String,Any}("name" => "bounded_1d_bc"),
        "grids"    => Dict{String,Any}(
            "gx" => Dict{String,Any}(
                "family"     => "cartesian",
                "dimensions" => Any[Dict{String,Any}(
                    "name" => "i", "size" => n,
                    "periodic" => false, "spacing" => "uniform")],
            ),
        ),
        "rules" => Any[Dict{String,Any}(
            "name"    => "centered_grad",
            "pattern" => Dict{String,Any}("op" => "grad", "args" => Any["\$u"], "dim" => "\$x"),
            "replacement" => Dict{String,Any}("op" => "+", "args" => Any[
                Dict{String,Any}("op" => "-", "args" => Any[
                    Dict{String,Any}("op" => "index", "args" => Any[
                        "\$u", Dict{String,Any}("op" => "-", "args" => Any["\$x", 1])])]),
                Dict{String,Any}("op" => "index", "args" => Any[
                    "\$u", Dict{String,Any}("op" => "+", "args" => Any["\$x", 1])]),
            ]),
        )],
        "models" => Dict{String,Any}(
            "M" => Dict{String,Any}(
                "grid" => "gx",
                "variables" => Dict{String,Any}(
                    "u" => Dict{String,Any}(
                        "type" => "state", "default" => 0.0, "units" => "1",
                        "shape" => Any["i"], "location" => "cell_center")),
                "equations" => Any[Dict{String,Any}(
                    "lhs" => Dict{String,Any}("op" => "D", "args" => Any["u"], "wrt" => "t"),
                    "rhs" => Dict{String,Any}("op" => "grad", "args" => Any["u"], "dim" => "i"))],
                "boundary_conditions" => Dict{String,Any}(
                    "left"  => Dict{String,Any}("variable" => "u", "kind" => "dirichlet",
                                                 "side" => "imin", "value" => 3),
                    "right" => Dict{String,Any}("variable" => "u", "kind" => "neumann",
                                                 "side" => "imax", "value" => 0)),
            ),
        ),
    )

    d = discretize(esm; lift_1d_arrayop=true)
    f!, u0, p, _ts, vm = build_evaluator(d)
    for i in 1:n
        u0[vm["u[$i]"]] = Float64(i)^2
    end
    du = similar(u0)
    f!(du, u0, p, 0.0)
    u(i) = Float64(i)^2
    expect(i) = i == 1 ? -3.0 + u(2) :
                i == n ? -u(n - 1) + u(n) :
                -u(i - 1) + u(i + 1)
    for i in 1:n
        @test du[vm["u[$i]"]] == expect(i)
    end
end

@testset "tree_walk: expression IC for 2D diffusion — u0 matches hand-built field (ess-zb1)" begin
    # Build a 4×4 Cartesian diffusion ESM with variables shaped ["x","y"].
    # The expression IC sin(π*(x-0.5)/2) * sin(π*(y-0.5)/2) should produce
    # u0 that matches the hand-built field to machine precision.
    N = 4
    dx = 1.0

    coeff_x_pos  = Dict("op" => "/", "args" => Any[1,  Dict("op" => "*", "args" => Any["dx", "dx"])])
    coeff_x_zero = Dict("op" => "/", "args" => Any[-2, Dict("op" => "*", "args" => Any["dx", "dx"])])
    coeff_y_pos  = Dict("op" => "/", "args" => Any[1,  Dict("op" => "*", "args" => Any["dy", "dy"])])
    coeff_y_zero = Dict("op" => "/", "args" => Any[-2, Dict("op" => "*", "args" => Any["dy", "dy"])])

    mk_idx(u, di, dj) = begin
        xi = di == 0 ? "i" : Dict("op" => "+", "args" => Any["i", di])
        yj = dj == 0 ? "j" : Dict("op" => "+", "args" => Any["j", dj])
        Dict("op" => "index", "args" => Any[u, xi, yj])
    end

    pvar = "\$u"
    stencil_terms = Any[
        Dict("op" => "*", "args" => Any[coeff_x_pos,  mk_idx(pvar, -1,  0)]),
        Dict("op" => "*", "args" => Any[coeff_x_zero, mk_idx(pvar,  0,  0)]),
        Dict("op" => "*", "args" => Any[coeff_x_pos,  mk_idx(pvar,  1,  0)]),
        Dict("op" => "*", "args" => Any[coeff_y_pos,  mk_idx(pvar,  0, -1)]),
        Dict("op" => "*", "args" => Any[coeff_y_zero, mk_idx(pvar,  0,  0)]),
        Dict("op" => "*", "args" => Any[coeff_y_pos,  mk_idx(pvar,  0,  1)]),
    ]
    laplacian_rule = Dict{String,Any}(
        "name"    => "laplacian_2nd_cartesian",
        "pattern" => Dict("op" => "laplacian", "args" => Any[pvar]),
        "replacement" => Dict("op" => "+", "args" => stencil_terms),
    )

    pde_esm = Dict{String,Any}(
        "esm"      => "0.2.0",
        "metadata" => Dict{String,Any}("name" => "diffusion_2d_expr_ic"),
        "grids"    => Dict{String,Any}(
            "g" => Dict{String,Any}(
                "family"     => "cartesian",
                "dimensions" => Any[
                    Dict{String,Any}("name" => "x", "size" => N, "periodic" => true, "spacing" => "uniform"),
                    Dict{String,Any}("name" => "y", "size" => N, "periodic" => true, "spacing" => "uniform"),
                ],
            ),
        ),
        "models" => Dict{String,Any}(
            "diffusion" => Dict{String,Any}(
                "grid" => "g",
                "variables" => Dict{String,Any}(
                    "u"       => Dict{String,Any}("type" => "state", "shape" => Any["x", "y"],
                                                   "location" => "cell_center"),
                    "D_coeff" => Dict{String,Any}("type" => "parameter", "default" => 1.0),
                    "dx"      => Dict{String,Any}("type" => "parameter", "default" => dx),
                    "dy"      => Dict{String,Any}("type" => "parameter", "default" => dx),
                ),
                "equations" => Any[
                    Dict{String,Any}(
                        "lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
                        "rhs" => Dict("op" => "*", "args" => Any[
                            "D_coeff",
                            Dict("op" => "laplacian", "args" => Any["u"]),
                        ]),
                    ),
                ],
            ),
        ),
        "rules" => Any[laplacian_rule],
    )

    ode_esm = @test_nowarn discretize(pde_esm)

    # Author the IC as ESS expression: sin(π*(x-0.5)/2) * sin(π*(y-0.5)/2)
    # where x and y are the integer 1-based cell indices bound to shape dims.
    # Use EarthSciSerialization.Expr to avoid conflict with Core.Expr.
    _E = EarthSciSerialization.Expr
    pi_val = Float64(π)
    ic_expr = OpExpr("*", _E[
        OpExpr("sin", _E[
            OpExpr("*", _E[
                NumExpr(pi_val),
                OpExpr("/", _E[
                    OpExpr("-", _E[VarExpr("x"), NumExpr(0.5)]),
                    NumExpr(Float64(N) / 2),
                ]),
            ]),
        ]),
        OpExpr("sin", _E[
            OpExpr("*", _E[
                NumExpr(pi_val),
                OpExpr("/", _E[
                    OpExpr("-", _E[VarExpr("y"), NumExpr(0.5)]),
                    NumExpr(Float64(N) / 2),
                ]),
            ]),
        ]),
    ])

    f!, u0, p, _tspan, var_map = @test_nowarn build_evaluator(ode_esm;
        expression_initial_conditions=Dict("u" => ic_expr))

    @test length(u0) == N * N

    # Verify u0 matches the hand-built reference field to machine precision.
    for i in 1:N, j in 1:N
        expected = sin(π * (i - 0.5) / 2) * sin(π * (j - 0.5) / 2)
        @test u0[var_map["u[$i,$j]"]] ≈ expected  rtol=1e-15
    end

    # E2e: simulate and verify analytic decay. λ = -4 for this 4×4 periodic grid.
    T = 0.1
    prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, (0.0, T), p)
    sol  = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                     reltol=1e-10, abstol=1e-12)
    @test sol.t[end] ≈ T
    decay_factor = exp(-4.0 * T)
    u_final = sol.u[end]
    max_err = 0.0
    for i in 1:N, j in 1:N
        u0_ij   = sin(π * (i - 0.5) / 2) * sin(π * (j - 0.5) / 2)
        u_exact = u0_ij * decay_factor
        u_sim   = u_final[var_map["u[$i,$j]"]]
        max_err = max(max_err, abs(u_sim - u_exact))
    end
    @info "expression IC diffusion max error vs analytic" max_err decay_factor
    @test max_err < 1e-6
end
