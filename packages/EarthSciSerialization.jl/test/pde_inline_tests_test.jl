# pde_inline_tests — §6.6.5 coords point-sampling, integral reduce, and
# from_file reference evaluation (the three formerly-unsupported features),
# pinned to the cross-binding conventions shared 1:1 with the Python
# (tests/test_pde_inline_tests.py) and Rust (src/pde_inline_tests.rs) suites:
#
# 1. `coords` values are positions in 1-based INDEX space (fractional
#    allowed); sampling = nearest grid index, exact half-way ties round DOWN.
# 2. `integral` = uniform-cell Riemann sum under a UNIT total domain measure
#    per axis: Σ field / N_cells == mean.
# 3. `from_file` paths resolve relative to the .esm file's directory; v1
#    format is "json" (row-major nested array matching the field's shape).
#
# The shared executable fixture tests/spatial/pde_inline_assertions_exec.esm
# is consumed by all three binding suites on identical input.

using Test
using EarthSciSerialization
import JSON3
import OrdinaryDiffEqTsit5
const _PIT_ESS = EarthSciSerialization

const _PIT_N = 8

# Cell-center coordinates x_i = (i - 1/2)/N over the `x` index set — the
# §9.7 grid-geometry aggregate shape (post-import expansion).
_pit_x_coord_aggregate() = Dict{String,Any}(
    "op" => "aggregate", "args" => Any[], "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict("from" => "x")),
    "expr" => Dict{String,Any}("op" => "*",
        "args" => Any[Dict("op" => "-", "args" => Any["i", 0.5]),
                      Dict("op" => "/", "args" => Any[1, _PIT_N])]))

_pit_cos_pi_x() = Dict{String,Any}(
    "op" => "cos",
    "args" => Any[Dict{String,Any}("op" => "*",
        "args" => Any[Float64(pi), _pit_x_coord_aggregate()])])

# A lifted field decay model du_i/dt = -u_i seeded by the coordinate
# expression ic(u) = cos(pi x_i); exact solution e^{-t} cos(pi x_i). The
# same document the Python / Rust suites are built on; `assertions` is
# spliced into the single inline test.
function _pit_decay_doc(assertions::Vector)
    idx = Dict{String,Any}("op" => "index", "args" => Any["u", "i"])
    Dict{String,Any}(
        "esm" => "0.8.0",
        "metadata" => Dict("name" => "pde_inline_decay"),
        "index_sets" => Dict{String,Any}(
            "x" => Dict("kind" => "interval", "size" => _PIT_N)),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "u" => Dict("type" => "state", "units" => "1",
                            "shape" => Any["x"])),
            "equations" => Any[
                Dict{String,Any}("lhs" => Dict("op" => "ic", "args" => Any["u"]),
                                 "rhs" => _pit_cos_pi_x()),
                Dict{String,Any}(
                    "lhs" => Dict{String,Any}("op" => "aggregate", "args" => Any[],
                        "output_idx" => Any["i"],
                        "ranges" => Dict{String,Any}("i" => Any[1, _PIT_N]),
                        "expr" => Dict{String,Any}("op" => "D", "args" => Any[idx],
                                                   "wrt" => "t")),
                    "rhs" => Dict{String,Any}("op" => "aggregate", "args" => Any[],
                        "output_idx" => Any["i"],
                        "ranges" => Dict{String,Any}("i" => Any[1, _PIT_N]),
                        "expr" => Dict{String,Any}("op" => "*",
                                                   "args" => Any[-1, idx])))],
            "tests" => Any[Dict{String,Any}(
                "id" => "decay",
                "time_span" => Dict("start" => 0.0, "end" => 1.0),
                "assertions" => Any[assertions...])])))
end

_pit_load(doc) = _PIT_ESS.load(IOBuffer(JSON3.write(doc)))

_pit_run(file; kwargs...) = run_pde_tests(file; model_name="M",
    alg=OrdinaryDiffEqTsit5.Tsit5(), reltol=1e-12, abstol=1e-14, kwargs...)

_pit_coords_assert(coords; time=0.0, expected=0.0, abs_tol=1e-9, var="u") =
    Dict{String,Any}("variable" => var, "time" => time, "expected" => expected,
                     "tolerance" => Dict("abs" => abs_tol),
                     "coords" => Dict{String,Any}(coords...))

@testset "field_reduce integral — unit-measure Riemann sum (== mean)" begin
    f = [1.0, 2.0, 3.0]
    @test field_reduce("integral", f) == 2.0
    @test field_reduce("integral", f) == field_reduce("mean", f)
    # Non-symmetric field: Σ/N, NOT the bare sum.
    g = [(i - 0.5) / 8 for i in 1:8]
    @test field_reduce("integral", g) == 0.5
    @test_throws ArgumentError field_reduce("integral", Float64[])
end

@testset "coords sampling — nearest index, exact ties round DOWN" begin
    u3 = cos(pi * 2.5 / _PIT_N)
    u6 = cos(pi * 5.5 / _PIT_N)
    u8 = cos(pi * 7.5 / _PIT_N)
    file = _pit_load(_pit_decay_doc(Any[
        _pit_coords_assert(["x" => 3]; expected=u3),
        _pit_coords_assert(["x" => 3.5]; expected=u3),   # tie → lower index 3
        _pit_coords_assert(["x" => 2.5]; expected=cos(pi * 1.5 / _PIT_N)), # tie → 2
        _pit_coords_assert(["x" => 5.6]; expected=u6),   # nearest → 6
        _pit_coords_assert(["x" => 8.5]; expected=u8),   # tie at top edge → 8
        _pit_coords_assert(["x" => 3]; time=1.0, expected=exp(-1.0) * u3,
                           abs_tol=1e-8),
    ]))
    results = _pit_run(file)
    @test length(results) == 6
    for r in results
        @test r.passed
        @test r.reduce === nothing
    end
    @test results[1].actual == results[2].actual
end

@testset "coords validation rejections" begin
    file = _pit_load(_pit_decay_doc(Any[
        _pit_coords_assert(["y" => 1.0]),
        _pit_coords_assert(["x" => 0.4]),   # → index 0
        _pit_coords_assert(["x" => 8.6]),   # → index 9
    ]))
    results = _pit_run(file)
    @test length(results) == 3
    @test all(r -> !r.passed && r.actual === nothing, results)
    @test occursin("names unknown dimension 'y'", results[1].message)
    @test occursin("outside 1..8", results[2].message)
    @test occursin("resolves to index 0", results[2].message)
    @test occursin("resolves to index 9", results[3].message)

    # coords on a scalar (0-D) variable is ill-formed per §6.6.5.
    scalar_doc = Dict{String,Any}(
        "esm" => "0.8.0",
        "metadata" => Dict("name" => "scalar_coords"),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "z" => Dict("type" => "state", "units" => "1",
                            "default" => 1.0)),
            "equations" => Any[Dict{String,Any}(
                "lhs" => Dict("op" => "D", "args" => Any["z"], "wrt" => "t"),
                "rhs" => 0.0)],
            "tests" => Any[Dict{String,Any}(
                "id" => "scalar",
                "time_span" => Dict("start" => 0.0, "end" => 1.0),
                "assertions" => Any[_pit_coords_assert(["x" => 1.0];
                                                       time=1.0, var="z")])])))
    sres = _pit_run(_pit_load(scalar_doc))
    @test length(sres) == 1
    @test !sres[1].passed
    @test occursin("requires a spatially-shaped variable", sres[1].message)

    # coords + reduce is rejected at load (Assertion constructor).
    bad = _pit_decay_doc(Any[Dict{String,Any}(
        "variable" => "u", "time" => 0.0, "expected" => 0.0,
        "coords" => Dict("x" => 1), "reduce" => "mean")])
    @test_throws Exception _pit_load(bad)
end

# A 2-D doc du_ij/dt = 1 with u(0) = 0, so u(t) = t everywhere: pins the
# strict-subset rule — pinning only `x` is legal iff `y` is singleton.
function _pit_2d_doc(ny::Int)
    idx = Dict{String,Any}("op" => "index", "args" => Any["u", "i", "j"])
    ranges = Dict{String,Any}("i" => Any[1, 4], "j" => Any[1, ny])
    Dict{String,Any}(
        "esm" => "0.8.0",
        "metadata" => Dict("name" => "pde_inline_2d"),
        "index_sets" => Dict{String,Any}(
            "x" => Dict("kind" => "interval", "size" => 4),
            "y" => Dict("kind" => "interval", "size" => ny)),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "u" => Dict("type" => "state", "units" => "1",
                            "shape" => Any["x", "y"])),
            "equations" => Any[
                Dict{String,Any}("lhs" => Dict("op" => "ic", "args" => Any["u"]),
                                 "rhs" => 0.0),
                Dict{String,Any}(
                    "lhs" => Dict{String,Any}("op" => "aggregate", "args" => Any[],
                        "output_idx" => Any["i", "j"], "ranges" => ranges,
                        "expr" => Dict{String,Any}("op" => "D", "args" => Any[idx],
                                                   "wrt" => "t")),
                    "rhs" => Dict{String,Any}("op" => "aggregate", "args" => Any[],
                        "output_idx" => Any["i", "j"], "ranges" => ranges,
                        "expr" => 1.0))],
            "tests" => Any[Dict{String,Any}(
                "id" => "subset",
                "time_span" => Dict("start" => 0.0, "end" => 1.0),
                "assertions" => Any[_pit_coords_assert(["x" => 2];
                                                       time=1.0, expected=1.0,
                                                       abs_tol=1e-8)])])))
end

@testset "coords strict-subset pinning — singleton remainder only" begin
    ok = _pit_run(_pit_load(_pit_2d_doc(1)))
    @test length(ok) == 1
    @test ok[1].passed
    @test ok[1].actual ≈ 1.0 atol = 1e-8

    bad = _pit_run(_pit_load(_pit_2d_doc(3)))
    @test length(bad) == 1
    @test !bad[1].passed
    @test occursin("leaves dimension 'y' unpinned with 3 samples", bad[1].message)
end

_pit_from_file_assert(refdict; reduce="L2_error", abs_tol=1e-12) =
    Dict{String,Any}("variable" => "u", "time" => 0.0, "expected" => 0.0,
                     "tolerance" => Dict("abs" => abs_tol), "reduce" => reduce,
                     "reference" => Dict{String,Any}(refdict...))

@testset "from_file references — JSON snapshot relative to the .esm dir" begin
    mktempdir() do dir
        vals = [cos(pi * (i - 0.5) / _PIT_N) for i in 1:_PIT_N]
        write(joinpath(dir, "ref.json"), JSON3.write(vals))
        doc = _pit_decay_doc(Any[
            _pit_from_file_assert(["type" => "from_file", "path" => "ref.json"]),
            _pit_from_file_assert(["type" => "from_file", "path" => "ref.json",
                                   "format" => "json"]; reduce="Linf_error"),
        ])
        prob = joinpath(dir, "prob.esm")
        write(prob, JSON3.write(doc))

        # Path input: base_dir defaults to the .esm file's directory.
        results = run_pde_tests(prob; model_name="M",
                                alg=OrdinaryDiffEqTsit5.Tsit5(),
                                reltol=1e-12, abstol=1e-14)
        @test length(results) == 2
        # Identical evaluation machinery seeded the ic, so the diff is 0.
        for r in results
            @test r.passed
            @test r.actual == 0.0
        end

        # EsmFile input: explicit base_dir resolves the same way.
        results2 = _pit_run(_pit_load(doc); base_dir=dir)
        @test all(r -> r.passed, results2)

        # Shape mismatch: 7 values for an 8-cell field.
        write(joinpath(dir, "short.json"), JSON3.write(vals[1:7]))
        short = _pit_run(_pit_load(_pit_decay_doc(Any[_pit_from_file_assert(
            ["type" => "from_file", "path" => "short.json"])])); base_dir=dir)
        @test !short[1].passed
        @test occursin("shape mismatch along dimension 1: expected length 8, found 7",
                       short[1].message)

        # Deeper nesting than the field's rank.
        write(joinpath(dir, "deep.json"), JSON3.write([[v] for v in vals]))
        deep = _pit_run(_pit_load(_pit_decay_doc(Any[_pit_from_file_assert(
            ["type" => "from_file", "path" => "deep.json"])])); base_dir=dir)
        @test !deep[1].passed
        @test occursin("expected a number", deep[1].message)

        # Missing file.
        missing_ = _pit_run(_pit_load(_pit_decay_doc(Any[_pit_from_file_assert(
            ["type" => "from_file", "path" => "nope.json"])])); base_dir=dir)
        @test !missing_[1].passed
        @test occursin("file not found", missing_[1].message)

        # v1 supports json only.
        nc = _pit_run(_pit_load(_pit_decay_doc(Any[_pit_from_file_assert(
            ["type" => "from_file", "path" => "ref.json",
             "format" => "netcdf"])])); base_dir=dir)
        @test !nc[1].passed
        @test occursin("format 'netcdf' is not supported", nc[1].message)
    end
end

# A COMPUTED array observed `scaled = mult * base` of arbitrary rank over a
# const `base`, plus a trivial state `u` (D(u) = scaled) so `simulate` runs.
# Asserting DIRECTLY on `scaled` drives `_observed_field`, whose cell sweep is
# a `CartesianIndices` comprehension: rank≥2 yields a Matrix, and the pre-fix
# `sort!` on it threw `UndefKeywordError: dims`. Pins the `vec()` fix and the
# row-major (lexicographic) cell mapping that pairs with the value layout.
function _pit_observed_doc(sizes::Vector{Int}, mult::Float64, base_nested,
                           assertions::Vector)
    R = length(sizes)
    dims = ["d$(k)" for k in 1:R]
    idxs = ["i$(k)" for k in 1:R]
    ranges = Dict{String,Any}(idxs[k] => Any[1, sizes[k]] for k in 1:R)
    index_base = Dict{String,Any}("op" => "index", "args" => Any["base", idxs...])
    scaled_expr = Dict{String,Any}("op" => "aggregate", "semiring" => "sum_product",
        "output_idx" => Any[idxs...], "ranges" => ranges, "args" => Any["base"],
        "expr" => Dict{String,Any}("op" => "*", "args" => Any[mult, index_base]))
    Dict{String,Any}(
        "esm" => "0.8.0",
        "metadata" => Dict("name" => "pde_inline_observed_rankN"),
        "index_sets" => Dict{String,Any}(
            dims[k] => Dict("kind" => "interval", "size" => sizes[k]) for k in 1:R),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "base" => Dict("type" => "observed", "shape" => Any[dims...],
                    "expression" => Dict("op" => "const", "args" => Any[],
                                         "value" => base_nested)),
                "scaled" => Dict("type" => "observed", "shape" => Any[dims...],
                    "expression" => scaled_expr),
                "u" => Dict("type" => "state", "shape" => Any[dims...],
                            "default" => 0.5)),
            "equations" => Any[Dict{String,Any}(
                "lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
                "rhs" => "scaled")],
            "tests" => Any[Dict{String,Any}(
                "id" => "observed_rankN",
                "time_span" => Dict("start" => 0.0, "end" => 1.0),
                "assertions" => Any[assertions...])])))
end

_pit_obs_reduce(kind, expected; var="scaled", time=0.5, abs_tol=1e-9) =
    Dict{String,Any}("variable" => var, "time" => time, "reduce" => kind,
                     "expected" => expected, "tolerance" => Dict("abs" => abs_tol))
_pit_obs_coords(coords, expected; var="scaled", time=0.5, abs_tol=1e-9) =
    Dict{String,Any}("variable" => var, "time" => time,
                     "coords" => Dict{String,Any}(coords...),
                     "expected" => expected, "tolerance" => Dict("abs" => abs_tol))

@testset "rank-2 array observed — §6.6.5 materialization (regression: sort! dims)" begin
    # base[i,j] row-major; scaled = 1.5 * base.
    base = Any[Any[0.5, 1.5, 2.5], Any[3.5, 4.5, 5.5]]
    doc = _pit_observed_doc([2, 3], 1.5, base, Any[
        _pit_obs_reduce("max", 8.25),                    # 1.5 * 5.5
        _pit_obs_reduce("min", 0.75),                    # 1.5 * 0.5
        _pit_obs_coords(["d1" => 2, "d2" => 1], 5.25),   # 1.5 * base[2,1]=3.5
        _pit_obs_coords(["d1" => 1, "d2" => 3], 3.75),   # 1.5 * base[1,3]=2.5
        _pit_obs_coords(["d1" => 2, "d2" => 3], 8.25),   # top corner
        _pit_obs_coords(["d1" => 1, "d2" => 1], 0.75),   # first cell
    ])
    results = _pit_run(_pit_load(doc))
    @test length(results) == 6
    for r in results
        @test r.passed
        @test r.message == ""
    end
    # coords row-major mapping is exact (not merely within tolerance).
    @test results[3].actual == 5.25
    @test results[4].actual == 3.75
end

@testset "rank-3 array observed — vec() fix is rank-agnostic" begin
    # base[i,j,k] row-major over a 2x2x2 cube; scaled = 1.5 * base.
    base = Any[Any[Any[0.5, 1.5], Any[2.5, 3.5]],
               Any[Any[4.5, 5.5], Any[6.5, 7.5]]]
    doc = _pit_observed_doc([2, 2, 2], 1.5, base, Any[
        _pit_obs_reduce("max", 11.25),                              # 1.5 * 7.5
        _pit_obs_reduce("min", 0.75),                               # 1.5 * 0.5
        _pit_obs_coords(["d1" => 2, "d2" => 1, "d3" => 2], 8.25),   # base[2,1,2]=5.5
        _pit_obs_coords(["d1" => 1, "d2" => 2, "d3" => 1], 3.75),   # base[1,2,1]=2.5
    ])
    results = _pit_run(_pit_load(doc))
    @test length(results) == 4
    for r in results
        @test r.passed
    end
    @test results[3].actual == 8.25
    @test results[4].actual == 3.75
end

# A parameter-dependent array observed `scaled = k * base` (k a PARAMETER,
# default 1.5) asserted DIRECTLY. Before the build-time cellwise parameter
# binding, `_observed_field` re-evaluated `scaled` with only the const-array
# registry in scope, so the bare `k` raised E_TREEWALK_UNBOUND_VARIABLE — a
# rank-2 parameter-dependent observed could not be asserted at all. STATE stays
# out of scope (an observed that reads a state still errors). Mirrors the
# tests/conformance/pde_inline_observed_param_rank2 fixture.
function _pit_param_observed_doc(assertions::Vector)
    idx = Dict{String,Any}("op" => "index", "args" => Any["base", "i", "j"])
    scaled_expr = Dict{String,Any}("op" => "aggregate", "semiring" => "sum_product",
        "output_idx" => Any["i", "j"],
        "ranges" => Dict{String,Any}("i" => Any[1, 2], "j" => Any[1, 3]),
        "args" => Any["base"],
        "expr" => Dict{String,Any}("op" => "*", "args" => Any["k", idx]))
    Dict{String,Any}(
        "esm" => "0.8.0",
        "metadata" => Dict("name" => "pde_inline_param_observed"),
        "index_sets" => Dict{String,Any}(
            "d1" => Dict("kind" => "interval", "size" => 2),
            "d2" => Dict("kind" => "interval", "size" => 3)),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "k" => Dict("type" => "parameter", "default" => 1.5),
                "base" => Dict("type" => "observed", "shape" => Any["d1", "d2"],
                    "expression" => Dict("op" => "const", "args" => Any[],
                        "value" => Any[Any[0.5, 1.5, 2.5], Any[3.5, 4.5, 5.5]])),
                "scaled" => Dict("type" => "observed", "shape" => Any["d1", "d2"],
                    "expression" => scaled_expr),
                "u" => Dict("type" => "state", "shape" => Any["d1", "d2"],
                            "default" => 0.5)),
            "equations" => Any[Dict{String,Any}(
                "lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
                "rhs" => "scaled")],
            "tests" => Any[Dict{String,Any}(
                "id" => "param_observed",
                "time_span" => Dict("start" => 0.0, "end" => 1.0),
                "assertions" => Any[assertions...])])))
end

@testset "parameter-dependent array observed asserted directly (§6.6.5 param scope)" begin
    doc = _pit_param_observed_doc(Any[
        _pit_obs_reduce("max", 8.25),                    # 1.5 * 5.5
        _pit_obs_reduce("min", 0.75),                    # 1.5 * 0.5
        _pit_obs_coords(["d1" => 2, "d2" => 1], 5.25),   # 1.5 * base[2,1]=3.5
        _pit_obs_coords(["d1" => 1, "d2" => 3], 3.75),   # 1.5 * base[1,3]=2.5
    ])
    results = _pit_run(_pit_load(doc))
    @test length(results) == 4
    for r in results
        @test r.passed
        @test r.message == ""
    end
    @test results[3].actual == 5.25
    @test results[4].actual == 3.75
end

@testset "inline-Expression §6.6.5 reference loaded from file (parse fix)" begin
    # A JSON3-loaded inline reference is an `AbstractDict`; the pre-fix
    # `coerce_assertion` misclassified it as `from_file` and `run_pde_tests`
    # rejected it ("unsupported `reference` shape Dict"). At t=0 the cos(pi x)
    # ic exactly equals the cos(pi x) analytic reference → relative L2 ≈ 0.
    file = _pit_load(_pit_decay_doc(Any[
        Dict{String,Any}("variable" => "u", "time" => 0.0, "expected" => 0.0,
            "tolerance" => Dict("abs" => 1e-12), "reduce" => "L2_error",
            "reference" => _pit_cos_pi_x())]))
    results = _pit_run(file)
    @test length(results) == 1
    @test results[1].passed
    @test results[1].actual < 1e-12
end

@testset "shared fixture — tests/spatial/pde_inline_assertions_exec.esm" begin
    fixture = joinpath(@__DIR__, "..", "..", "..", "tests", "spatial",
                       "pde_inline_assertions_exec.esm")
    @test isfile(fixture)
    results = run_pde_tests(fixture; model_name="M",
                            alg=OrdinaryDiffEqTsit5.Tsit5(),
                            reltol=1e-12, abstol=1e-14)
    @test length(results) == 7
    for r in results
        @test r.passed
    end
    # The two tie-sampling coords assertions hit the SAME cell.
    @test results[1].actual == results[2].actual
    # integral == mean == 0 for the symmetric cosine field.
    @test abs(results[5].actual) < 1e-12
    # from_file error norms are ~0 against the committed exact snapshot.
    @test results[6].actual < 1e-12
    @test results[7].actual < 1e-12
end
