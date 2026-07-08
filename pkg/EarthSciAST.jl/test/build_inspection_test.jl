# BuildInspection (build-time observability) + ragged / keyed-factor evaluation.
#
# Two capability seams landed together and are pinned here:
#
# 1. `build_evaluator(...; inspect=BuildInspection())` exposes the materialized
#    SETUP-TIME geometry arrays (RFC §8.1 / esm-spec §8.6.1), the const-array
#    registry, and the resolved observed map — the official surface the ESD
#    conformance runner reads the per-pair regrid A_ij / A_j / W_ij from
#    (CONFORMANCE_SPEC §5.8). The 3x3 → 2x2 uniform planar coarsening has
#    EXACT rational expectations (hand geometry, no evaluator): every interior
#    1.5° target edge splits a 1° source cell at its midpoint, so each target
#    cell overlaps its corner source cell fully (1.0 deg²), two edge cells by
#    half (0.5), and the shared center cell by a quarter (0.25); the row-sum is
#    A_j = 2.25 = 1.5² exactly and the weights are the exact rationals
#    4/9 / 2/9 / 1/9 (all representable-quotient divisions, so the Float64
#    results are bit-exact).
#
# 2. Ragged evaluation for the MPAS-style keyed-factor wiring (esm-spec §4.3.1
#    / §4.6; RFC semiring-faq-unified-ir §5.2): a general array-shaped
#    aggregate OBSERVED is inlined into its readers, `const`-op mesh factors
#    and their bare-name observed ALIASES materialize as const arrays, a
#    ragged `{from, of}` contracted range expands per output cell from the CSR
#    offsets factor in EXPRESSION position (`index(aggregate, i)`), and the
#    registry's bare offsets name resolves against namespaced (flattened)
#    variables via the model-scope suffix match. §6.6.5 inline tests may
#    assert directly on such an array observed (`run_pde_tests` evaluates it
#    through the inspection surface).

using Test
using EarthSciAST
import JSON3
import OrdinaryDiffEqTsit5
const _BI_ESS = EarthSciAST

_bi_rect(x0, x1, y0, y1) = Any[Any[x0, y0], Any[x1, y0], Any[x1, y1], Any[x0, y1]]

# Nine 1x1° source cells tiling [0,3]², row-major from the southwest; four
# 1.5x1.5° target cells tiling the same domain.
const _BI_SRC = Any[_bi_rect(Float64(c - 1), Float64(c), Float64(r - 1), Float64(r))
                    for r in 1:3 for c in 1:3]
const _BI_TGT = Any[_bi_rect(1.5 * (C - 1), 1.5 * C, 1.5 * (R - 1), 1.5 * R)
                    for R in 1:2 for C in 1:2]

_bi_agg(output_idx, ranges, expr; filter=nothing, args=Any[]) = begin
    d = Dict{String,Any}("op" => "aggregate", "semiring" => "sum_product",
                         "output_idx" => output_idx, "ranges" => ranges,
                         "args" => args, "expr" => expr)
    filter === nothing || (d["filter"] = filter)
    d
end

_bi_index(args...) = Dict{String,Any}("op" => "index", "args" => Any[args...])

function _bi_regrid_doc()
    sliver = Dict{String,Any}("op" => ">", "args" => Any[_bi_index("A_ij", "i", "j"), "atol"])
    ranges_ij = Dict{String,Any}("i" => Dict("from" => "src_cells"),
                                 "j" => Dict("from" => "tgt_cells"))
    Dict{String,Any}(
        "esm" => "0.8.0",
        "metadata" => Dict("name" => "build_inspection_regrid",
                           "description" => "3x3 -> 2x2 exact-rational overlap regrid"),
        "index_sets" => Dict{String,Any}(
            "src_cells" => Dict("kind" => "interval", "size" => 9),
            "tgt_cells" => Dict("kind" => "interval", "size" => 4),
            "verts" => Dict("kind" => "interval", "size" => 4),
            "coord" => Dict("kind" => "interval", "size" => 2)),
        "models" => Dict{String,Any}("Regrid" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "atol" => Dict("type" => "parameter", "units" => "1", "default" => 1e-12),
                "src_poly" => Dict("type" => "observed",
                    "shape" => Any["src_cells", "verts", "coord"],
                    "expression" => Dict("op" => "const", "args" => Any[], "value" => _BI_SRC)),
                "tgt_poly" => Dict("type" => "observed",
                    "shape" => Any["tgt_cells", "verts", "coord"],
                    "expression" => Dict("op" => "const", "args" => Any[], "value" => _BI_TGT)),
                "A_ij" => Dict("type" => "observed",
                    "shape" => Any["src_cells", "tgt_cells"],
                    "expression" => _bi_agg(Any["i", "j"], ranges_ij,
                        Dict{String,Any}("op" => "polygon_intersection_area",
                            "manifold" => "planar",
                            "args" => Any[_bi_index("src_poly", "i"),
                                          _bi_index("tgt_poly", "j")]);
                        args=Any["src_poly", "tgt_poly"])),
                "A_j" => Dict("type" => "observed", "shape" => Any["tgt_cells"],
                    "expression" => _bi_agg(Any["j"], ranges_ij,
                        _bi_index("A_ij", "i", "j"); filter=sliver, args=Any["A_ij"])),
                "W_ij" => Dict("type" => "observed",
                    "shape" => Any["src_cells", "tgt_cells"],
                    "expression" => _bi_agg(Any["i", "j"], ranges_ij,
                        Dict{String,Any}("op" => "/",
                            "args" => Any[_bi_index("A_ij", "i", "j"),
                                          _bi_index("A_j", "j")]);
                        filter=sliver, args=Any["A_ij", "A_j"])),
                "x" => Dict("type" => "state", "default" => 0.0)),
            "equations" => Any[Dict{String,Any}(
                "lhs" => Dict("op" => "D", "args" => Any["x"], "wrt" => "t"),
                "rhs" => 0.0)])))
end

@testset "BuildInspection — per-pair regrid setup arrays (exact rationals)" begin
    doc = _bi_regrid_doc()
    insp = BuildInspection()
    f!, u0, p, tspan, var_map = build_evaluator(doc; inspect=insp)

    @test issubset(Set(["A_ij", "A_j", "W_ij"]), Set(keys(insp.setup_arrays)))
    A = insp.setup_arrays["A_ij"]
    Aj = insp.setup_arrays["A_j"]
    W = insp.setup_arrays["W_ij"]
    @test size(A) == (9, 4) && size(W) == (9, 4) && size(Aj) == (4,)

    # Hand-derived exact expectation (the ESD manifest reference_weights
    # triples): [i, j, area] with corner 1.0 / edge 0.5 / center 0.25.
    expected_A = zeros(9, 4)
    for (i, j, a) in [(1, 1, 1.0), (2, 1, 0.5), (4, 1, 0.5), (5, 1, 0.25),
                      (3, 2, 1.0), (2, 2, 0.5), (6, 2, 0.5), (5, 2, 0.25),
                      (7, 3, 1.0), (4, 3, 0.5), (8, 3, 0.5), (5, 3, 0.25),
                      (9, 4, 1.0), (6, 4, 0.5), (8, 4, 0.5), (5, 4, 0.25)]
        expected_A[i, j] = a
    end
    @test A == expected_A                       # planar clip of exact rectangles
    @test all(Aj .== 2.25)                      # 1 + 0.5 + 0.5 + 0.25, exact
    # Exact rational weights: representable-quotient divisions, so bit-exact.
    @test W == expected_A ./ 2.25
    @test W[1, 1] == 4 / 9 && W[2, 1] == 2 / 9 && W[5, 1] == 1 / 9
    # Partition of unity from the exposed matrix itself.
    @test all(j -> isapprox(sum(W[:, j]), 1.0; atol=4eps()), 1:4)

    # The registry + observed map are exposed too.
    @test haskey(insp.const_arrays, "src_poly")
    @test haskey(insp.const_arrays, "A_ij")     # setup arrays register as const arrays
    @test insp.observed_exprs isa Dict{String,EarthSciAST.Expr}

    # Observability is inert: the build without `inspect` is identical.
    f2!, u02, p2, tspan2, var_map2 = build_evaluator(_bi_regrid_doc())
    @test u02 == u0 && var_map2 == var_map && tspan2 == tspan
    du = similar(u0); du2 = similar(u02)
    f!(du, u0, p, 0.0); f2!(du2, u02, p2, 0.0)
    @test du == du2
end

# ---------------------------------------------------------------------------
# Ragged keyed-factor evaluation (MPAS miniature): 2 cells, 3 edges, CSR
# valences [2, 3]. div_c = Σ_k sgn(c,k) * F(edgesOnCell(c,k)) with F = 10·e:
#   div_1 = F1 - F2 = -10;  div_2 = F3 + F1 - F2 = 20.
# `F` is a bare-name ALIAS of the const-op `F0` (the mesh re-exposure contract);
# `D(u) = div` exercises the whole-array lift → index(aggregate, cell) →
# ragged expression-position expansion; the tests block asserts DIRECTLY on
# the `div` observed (§6.6.5 observed assertion) and on u(1).
# ---------------------------------------------------------------------------
function _bi_ragged_doc()
    csr = Dict{String,Any}("c" => Dict("from" => "cells"),
                           "k" => Dict{String,Any}("from" => "edges_of_cell", "of" => Any["c"]))
    div_expr = _bi_agg(Any["c"], csr,
        Dict{String,Any}("op" => "*", "args" => Any[
            _bi_index("sgn", "c", "k"),
            _bi_index("F", _bi_index("edgesOnCell", "c", "k"))]);
        args=Any["sgn", "edgesOnCell", "F"])
    Dict{String,Any}(
        "esm" => "0.8.0",
        "metadata" => Dict("name" => "build_inspection_ragged",
                           "description" => "2-cell ragged CSR contraction miniature"),
        "index_sets" => Dict{String,Any}(
            "cells" => Dict("kind" => "interval", "size" => 2),
            "edges" => Dict("kind" => "interval", "size" => 3),
            "maxE" => Dict("kind" => "interval", "size" => 3),
            "edges_of_cell" => Dict{String,Any}("kind" => "ragged", "of" => Any["cells"],
                "offsets" => "nEdgesOnCell", "values" => "edgesOnCell")),
        "models" => Dict{String,Any}("Div" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "nEdgesOnCell" => Dict("type" => "observed", "shape" => Any["cells"],
                    "expression" => Dict("op" => "const", "args" => Any[], "value" => Any[2, 3])),
                "edgesOnCell" => Dict("type" => "observed", "shape" => Any["cells", "maxE"],
                    "expression" => Dict("op" => "const", "args" => Any[],
                                         "value" => Any[Any[1, 2, 0], Any[3, 1, 2]])),
                "sgn" => Dict("type" => "observed", "shape" => Any["cells", "maxE"],
                    "expression" => Dict("op" => "const", "args" => Any[],
                                         "value" => Any[Any[1, -1, 0], Any[1, 1, -1]])),
                "F0" => Dict("type" => "observed", "shape" => Any["edges"],
                    "expression" => Dict("op" => "const", "args" => Any[],
                                         "value" => Any[10.0, 20.0, 30.0])),
                "F" => Dict("type" => "observed", "shape" => Any["edges"],
                    "description" => "bare-name alias of the const factor (keyed-factor re-exposure)",
                    "expression" => "F0"),
                "div" => Dict("type" => "observed", "shape" => Any["cells"],
                    "expression" => div_expr),
                "u" => Dict("type" => "state", "shape" => Any["cells"], "default" => 0.0)),
            "equations" => Any[Dict{String,Any}(
                "lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
                "rhs" => "div")],
            "tests" => Any[Dict{String,Any}(
                "id" => "ragged_gather",
                "time_span" => Dict("start" => 0.0, "end" => 1.0),
                "assertions" => Any[
                    Dict{String,Any}("variable" => "div", "time" => 1.0, "expected" => 20.0,
                                     "tolerance" => Dict("abs" => 1e-9), "reduce" => "max"),
                    Dict{String,Any}("variable" => "div", "time" => 1.0, "expected" => -10.0,
                                     "tolerance" => Dict("abs" => 1e-9), "reduce" => "min"),
                    Dict{String,Any}("variable" => "u", "time" => 1.0, "expected" => 5.0,
                                     "tolerance" => Dict("abs" => 1e-6), "reduce" => "mean")])])))
end

@testset "ragged CSR contraction — expression position + observed assertion" begin
    doc = _bi_ragged_doc()

    # Direct build: du at the zero IC IS the ragged divergence.
    f!, u0, p, tspan, var_map = build_evaluator(doc)
    @test haskey(var_map, "u[1]") && haskey(var_map, "u[2]")
    du = similar(u0)
    f!(du, u0, p, 0.0)
    @test du[var_map["u[1]"]] == -10.0
    @test du[var_map["u[2]"]] == 20.0

    # Inspection: the const-op factors AND the bare alias are registered.
    insp = BuildInspection()
    build_evaluator(doc; inspect=insp)
    @test insp.const_arrays["F"] == [10.0, 20.0, 30.0]
    @test insp.const_arrays["nEdgesOnCell"] == [2.0, 3.0]
    @test haskey(insp.observed_exprs, "div")

    # §6.6.5 end to end (flatten prefixes every name with "Div.", so this also
    # exercises the model-scope suffix resolution of the registry's bare
    # "nEdgesOnCell" offsets factor) — including the DIRECT observed assertion.
    file = EarthSciAST.load(IOBuffer(JSON3.write(doc)))
    results = run_pde_tests(file; model_name="Div", alg=OrdinaryDiffEqTsit5.Tsit5(),
                            reltol=1e-10, abstol=1e-12)
    @test length(results) == 3
    for r in results
        @test r.passed
    end
    div_max = only(r for r in results if r.reduce == "max")
    div_min = only(r for r in results if r.reduce == "min")
    @test div_max.actual == 20.0
    @test div_min.actual == -10.0
end
