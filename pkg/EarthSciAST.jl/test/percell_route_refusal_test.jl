# Per-cell routes under a strict `compiler = :native` (esm-libraries-spec §2.5.10).
#
# §2.5.10 puts EVERY evaluation a compiler performs for a problem under its
# refusal rule: the right-hand side, the construction-time materializations and
# seeds, and the observeds read at output time. Each testset below takes one
# route that used to walk the tree per cell under `native` with nothing to show
# for it, and pins what `native` does with it now:
#
#   * a route that stays per cell REFUSES with `compiler_refused_rule`, naming
#     the rule, at construction — and `compiler = :interpreter` still runs the
#     same document, so the refusal is a statement about the compiler and not
#     about the document;
#   * a route that gained a compile-once or whole-field form takes it, is
#     reported under a tier that says so, and agrees with the interpreter bit
#     for bit.
#
# Every refusal subject is a small synthetic document built for the purpose, so
# the construct under test is the only one `native` could decline.
using Test
using EarthSciAST
using OrdinaryDiffEqTsit5
include("testutils.jl")

const _PR = EarthSciAST

# True when `f()` throws `compiler_refused_rule` whose message names `needle`.
function _pr_refuses(f, needle::AbstractString)
    try
        f()
    catch err
        err isa _PR.TreeWalkError || rethrow()
        return err.code == _PR.ERROR_CODES.COMPILER_REFUSED_RULE &&
               occursin(needle, err.detail)
    end
    return false
end

_pr_rows(rep, tier) = [r for r in rep.rules if r.tier === tier]

@testset "per-cell routes under strict native" begin

    # ── The short-contraction route (#479) ────────────────────────────────────
    # `D(out[a,b,c,d]) = Σ_k W[k]·F[a,b,c,d]`: a constant-bound contraction the
    # per-cell contraction loop's gate admits, whose body reads a LIVE forcing
    # buffer `F` at the output index. The whole-array nest cannot keep that
    # read symbolic, and the affine tier does not model a rank-4 output, so the
    # only tier left is the per-cell loop — whose cells the in-place `f!` walks
    # as trees on every call.
    @testset "a contraction left to the per-cell loop refuses" begin
        W = Float64[1, 2, 3, 4, 5, 6, 7, 8]
        rng = Dict{String,Any}(n => Any[1, 1] for n in ("a", "b", "c", "d"))
        agg = Dict{String,Any}("op" => "faq", "semiring" => "sum_product",
            "args" => Any[], "output_idx" => Any["a", "b", "c", "d"],
            "ranges" => merge(rng, Dict{String,Any}("k" => Any[1, length(W)])),
            "expr" => Dict("op" => "*", "args" => Any[
                Dict("op" => "index", "args" => Any[
                    Dict("op" => "const", "args" => Any[], "value" => W), "k"]),
                Dict("op" => "index", "args" => Any["F", "a", "b", "c", "d"])]))
        doc = Dict{String,Any}("esm" => "1.1.0",
            "metadata" => Dict("name" => "pr_short_contraction"),
            "models" => Dict("R" => Dict{String,Any}(
                "variables" => Dict(
                    "F" => Dict("type" => "parameter", "shape" => Any["a", "b", "c", "d"]),
                    "out" => Dict("type" => "unknown", "shape" => Any["a", "b", "c", "d"])),
                "equations" => Any[Dict(
                    "lhs" => Dict("op" => "faq", "args" => Any[],
                        "output_idx" => Any["a", "b", "c", "d"], "ranges" => rng,
                        "expr" => Dict("op" => "D", "args" => Any[Dict("op" => "index",
                            "args" => Any["out", "a", "b", "c", "d"])], "wrt" => "t")),
                    "rhs" => agg)])))
        build(compiler) = withenv("ESS_CONTRACTION_LOOP_MIN" => "8") do
            _PR._build_evaluator(doc;
                initial_conditions = Dict("out[1,1,1,1]" => 0.0),
                param_arrays = Dict("F" => fill(3.0, 1, 1, 1, 1)),
                compiler = compiler)
        end
        @test _pr_refuses(() -> build(:native), "per-cell contraction loop")
        f!, u0, p, _, vm = build(:interpreter)
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vm["out[1,1,1,1]"]] == 3.0 * sum(W)
    end

    # ── The discrete-cadence materializer (#480) ──────────────────────────────
    # `g[j] = Σ_i W[i,j]·src[i]` over a live buffer `src` is state-free and
    # forcing-derived, so the materializer cuts it into a cache filled per cell
    # at build and at every refresh.
    @testset "the discrete-cadence materializer refuses, and is reported" begin
        file = _PR.load_path(joinpath(@__DIR__, "fixtures", "discrete_materialize.esm"))
        W = [1.0 2.0 3.0; 4.0 5.0 6.0]
        ics = Dict{String,Float64}("c[1]" => 0.0, "c[2]" => 0.0, "c[3]" => 0.0)
        build(compiler, dm, insp) = _PR._build_evaluator(file; initial_conditions = ics,
            const_arrays = Dict("W" => W), param_arrays = Dict("src" => [1.0, 1.0]),
            materialize_out = dm, inspect = insp, compiler = compiler)
        @test _pr_refuses(() -> build(:native, _PR.DiscreteMaterializer(),
                                      _PR.BuildInspection()),
                          "the discrete-cadence materializer")
        dm = _PR.DiscreteMaterializer()
        insp = _PR.BuildInspection()
        build(:interpreter, dm, insp)
        @test dm.caches["g"] == [5.0, 7.0, 9.0]
        @test [r.rule for r in _pr_rows(insp.compiler_report, :discrete_percell)] ==
              ["g"]
        # No sink, no cut: the field is inlined into the compiled right-hand side
        # and `native` builds it.
        f!, u0, p, _, vm = _PR._build_evaluator(file; initial_conditions = ics,
            const_arrays = Dict("W" => W), param_arrays = Dict("src" => [1.0, 1.0]))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isfinite(du[vm["c[1]"]])
    end

    # ── faq-valued initialization equations (#482) ────────────────────────────
    iset = Dict("x" => _PR.IndexSet("interval"; size = 5))
    uvar() = Dict("u" => _PR.ModelVariable(_PR.UnknownVariable; shape = ["x"]))
    faq1(body) = _PR.OpExpr("faq", _PR.ASTExpr[]; output_idx = Any["i"],
                            ranges = Dict("i" => Any[1, 5]), expr_body = body)
    zero_eq() = _PR.Equation(faq1(_Didx("u", _v("i"))), faq1(_n(0.0)))
    seed(model, compiler; kw...) = begin
        insp = _PR.BuildInspection()
        r = _PR._build_evaluator_impl(model; compiler = compiler, index_sets = iset,
                                      inspect = insp, kw...)
        (r[2], r[5], insp.compiler_report)
    end

    @testset "a faq initialization equation compiles once, bit-identically" begin
        body = _op("+", _op("*", _n(0.37), _v("i")), _op("/", _n(1.0), _op("+", _v("i"), _n(2.0))))
        m = _PR.Model(uvar(), [zero_eq()];
                      initialization_equations = [_PR.Equation(_v("u"), faq1(body))])
        un, vn, rn = seed(m, :native)
        ui, vi, ri = seed(m, :interpreter)
        @test all(un[vn["u[$i]"]] === ui[vi["u[$i]"]] for i in 1:5)
        @test all(un[vn["u[$i]"]] == 0.37 * i + 1.0 / (i + 2.0) for i in 1:5)
        @test [r.rule for r in _pr_rows(rn, :setup_compiled)] == ["init(u)"]
        @test [r.rule for r in _pr_rows(ri, :setup_percell)] == ["init(u)"]
    end

    @testset "a faq initialization equation left per cell refuses" begin
        # A live forcing buffer read at the output index does not resolve with
        # that index symbolic.
        m = _PR.Model(merge(uvar(), Dict("F" => _PR.ModelVariable(
                          _PR.ParameterVariable; shape = ["x"]))), [zero_eq()];
                      initialization_equations = [_PR.Equation(_v("u"),
                          faq1(_op("*", _n(2.0), _idx("F", _v("i")))))])
        F = collect(1.0:5.0)
        @test _pr_refuses(() -> seed(m, :native; param_arrays = Dict("F" => F)),
                          "init(u)")
        ui, vi, _ = seed(m, :interpreter; param_arrays = Dict("F" => F))
        @test [ui[vi["u[$i]"]] for i in 1:5] == 2.0 .* F
    end

    # ── Field initial conditions answered once per field (#482) ───────────────
    @testset "a broadcast-constant field ic is evaluated once and filled" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "scalar_ic",
                        "fixtures", "scalar_ic_in_array_model.esm")
        pn = esm_problem(path, (0.0, 1.0))
        pi_ = esm_problem(path, (0.0, 1.0); compiler = :interpreter)
        @test pn.u0 == pi_.u0
        rows = [r for r in compiler_report(pn).rules if startswith(r.rule, "ic(")]
        @test any(r -> r.tier === :setup_constant, rows)
        @test !any(r -> r.tier === :setup_percell, rows)
    end

    # ── Output-time observeds and inline-test assertions (#481, #482) ─────────
    # `h` is a makearray observed: the compile-once cellwise sweep cannot keep a
    # region choice symbolic, so reading it takes the per-cell resolve-and-compile
    # fallback. `k[i] = 2·i` is an ordinary compile-once observed.
    mk_doc() = Dict{String,Any}("esm" => "1.1.0",
        "metadata" => Dict("name" => "pr_observed_routes"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => 3)),
        "models" => Dict("M" => Dict{String,Any}(
            "variables" => Dict(
                "c" => Dict("type" => "unknown", "default" => 1.0),
                "h" => Dict("type" => "unknown", "shape" => Any["x"]),
                "k" => Dict("type" => "unknown", "shape" => Any["x"])),
            "equations" => Any[
                Dict("lhs" => Dict("op" => "D", "args" => Any["c"], "wrt" => "t"),
                     "rhs" => 0.0),
                Dict("lhs" => "h", "rhs" => Dict("op" => "makearray", "args" => Any[],
                    "regions" => Any[Any[Any[1, 1]], Any[Any[2, 3]]],
                    "values" => Any[5.0, 7.0])),
                Dict("lhs" => "k", "rhs" => Dict("op" => "faq", "args" => Any[],
                    "output_idx" => Any["i"],
                    "ranges" => Dict("i" => Dict("from" => "x")),
                    "expr" => Dict("op" => "*", "args" => Any[2.0, "i"])))],
            "tests" => Any[Dict("id" => "h_cell",
                "time_span" => Dict("start" => 0.0, "end" => 1.0),
                "assertions" => Any[Dict("variable" => "h", "time" => 0.0,
                    "coords" => Dict("x" => 2), "expected" => 7.0)])])))

    @testset "observed_field: the per-cell fallback refuses under native" begin
        pn = esm_problem(mk_doc(), (0.0, 1.0))
        @test _pr_refuses(() -> observed_field(pn, "h"),
                          "the build-time cellwise evaluator")
        pi_ = esm_problem(mk_doc(), (0.0, 1.0); compiler = :interpreter)
        @test observed_field(pi_, "h") == [5.0, 7.0, 7.0]
    end

    @testset "observed_field: compiled once, memoized, and reported" begin
        pn = esm_problem(mk_doc(), (0.0, 1.0))
        hits0 = _PR._CELLWISE_FASTPATH_HITS[]
        @test observed_field(pn, "k") == [2.0, 4.0, 6.0]
        hits1 = _PR._CELLWISE_FASTPATH_HITS[]
        @test hits1 > hits0
        # The second read evaluates nothing.
        @test observed_field(pn, "k") == [2.0, 4.0, 6.0]
        @test _PR._CELLWISE_FASTPATH_HITS[] == hits1
        rows = [r for r in compiler_report(pn).rules if r.kind === :observed]
        @test [(r.rule, r.tier) for r in rows] == [("k", :output_compiled_once)]
        # …until a live buffer is refreshed in place.
        _PR.notify_forcing_refresh!()
        @test observed_field(pn, "k") == [2.0, 4.0, 6.0]
        @test _PR._CELLWISE_FASTPATH_HITS[] > hits1
    end

    @testset "inline-test assertions run under the problem's compiler" begin
        f = _PR.load_string(JSON3.write(mk_doc()))
        rn = run_inline_tests(f)
        @test length(rn) == 1
        @test rn[1].status == _PR.ERROR
        @test occursin("compiler_refused_rule", rn[1].message)
        ri = run_inline_tests(f; compiler = :interpreter)
        @test ri[1].status == _PR.PASS
        @test ri[1].actual == 7.0
    end

    # ── seed_expression_ic! (#482) ─────────────────────────────────────────────
    @testset "seed_expression_ic! compiles once and agrees with the per-cell walk" begin
        vm = Dict("M.u[$i,$j]" => (j - 1) * 3 + i for i in 1:3, j in 1:2)
        vm = Dict{String,Int}(vm)
        expr = _PR.expression_from_json(Dict{String,Any}("op" => "+", "args" => Any[
            Dict{String,Any}("op" => "*", "args" => Any["x", "x"]),
            Dict{String,Any}("op" => "sin", "args" => Any["y"])]))
        coords = ["x" => [0.1, 0.2, 0.3], "y" => [1.0, 2.0]]
        uc = seed_expression_ic!(zeros(6), vm, "M.u", expr, coords)
        ur = _PR._with_compiler_plan(_PR._compiler_plan(:interpreter)) do
            seed_expression_ic!(zeros(6), vm, "M.u", expr, coords)
        end
        @test all(uc[k] === ur[k] for k in 1:6)
        @test uc[vm["M.u[2,2]"]] == 0.2 * 0.2 + sin(2.0)
    end
end
