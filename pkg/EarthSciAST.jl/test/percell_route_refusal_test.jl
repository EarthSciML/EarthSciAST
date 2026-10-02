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

# True when `f()` throws `compiler_refused_rule` whose message names `needle`
# (and, with `one_cell`, says that only one cell was evaluated before it).
function _pr_refuses(f, needle::AbstractString; one_cell::Bool = false)
    try
        f()
    catch err
        err isa _PR.TreeWalkError || rethrow()
        return err.code == _PR.ERROR_CODES.COMPILER_REFUSED_RULE &&
               occursin(needle, err.detail) &&
               (!one_cell || occursin(_PR._ONE_CELL_NOTE, err.detail))
    end
    return false
end

_pr_rows(rep, tier) = [r for r in rep.rules if r.tier === tier]

# `D(out[a,b,c,d]) = Σ_k W[k]·F[a,b,c,d]` over a single output cell: `W` an
# inline `const` read at the contracted index `k` (which runs `past` terms beyond
# it), `F` a live forcing buffer read at the output index; with `filt`, only
# the terms `k ≥ 2`.
function _pr_rank4_doc(W::Vector{Float64}; past::Int = 0, filt::Bool = false)
    rng = Dict{String,Any}(n => Any[1, 1] for n in ("a", "b", "c", "d"))
    agg = Dict{String,Any}("op" => "faq", "semiring" => "sum_product",
        "args" => Any[], "output_idx" => Any["a", "b", "c", "d"],
        "ranges" => merge(rng, Dict{String,Any}("k" => Any[1, length(W) + past])),
        "expr" => Dict("op" => "*", "args" => Any[
            Dict("op" => "index", "args" => Any[
                Dict("op" => "const", "args" => Any[], "value" => W), "k"]),
            Dict("op" => "index", "args" => Any["F", "a", "b", "c", "d"])]))
    filt && (agg["filter"] = Dict("op" => ">=", "args" => Any["k", 2]))
    Dict{String,Any}("esm" => "1.1.0",
        "metadata" => Dict("name" => "pr_rank4_contraction"),
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
end
_pr_rank4_build(doc, compiler; kw...) =
    withenv("ESS_CONTRACTION_LOOP_MIN" => "8") do
        _PR._build_evaluator(doc; initial_conditions = Dict("out[1,1,1,1]" => 0.0),
            param_arrays = Dict("F" => fill(3.0, 1, 1, 1, 1)), compiler = compiler, kw...)
    end

@testset "per-cell routes under strict native" begin

    # ── The short-contraction route (#479) ────────────────────────────────────
    # `D(out[a,b,c,d]) = Σ_k W[k]·F[a,b,c,d]`: a constant-bound contraction whose
    # body reads an inline `const` at the contracted index and a LIVE forcing
    # buffer `F` at the output index. The whole-array nest cannot keep that
    # forcing read symbolic; the affine tier's run-time fold reads both, the
    # inline `const` as a const lane, so it compiles the equation once.
    @testset "a short contraction over a live forcing read compiles once" begin
        W = Float64[1, 2, 3, 4, 5, 6, 7, 8]
        doc = _pr_rank4_doc(W)
        insp = _PR.BuildInspection()
        f!, u0, p, _, vm = _pr_rank4_build(doc, :native; inspect = insp)
        fi!, ui, pi_, _, vi = _pr_rank4_build(doc, :interpreter)
        du = similar(u0); f!(du, u0, p, 0.0)
        di = similar(ui); fi!(di, ui, pi_, 0.0)
        @test du[vm["out[1,1,1,1]"]] === di[vi["out[1,1,1,1]"]] == 3.0 * sum(W)
        @test length(_pr_rows(_PR.compiler_report(insp), :affine)) == 1
    end

    # ── The discrete-cadence materializer (#480) ──────────────────────────────
    # `g[j] = Σ_i W[i,j]·src[i]` over a live buffer `src` is state-free and
    # forcing-derived, so the materializer cuts it into a cache filled at build
    # and at every refresh: one compiled whole-array kernel under `native`, a
    # per-cell walk under `interpreter`, bit for bit the same cache.
    @testset "the discrete-cadence materializer compiles once, and is reported" begin
        file = _PR.load_path(joinpath(@__DIR__, "fixtures", "discrete_materialize.esm"))
        W = [1.0 2.0 3.0; 4.0 5.0 6.0]
        ics = Dict{String,Float64}("c[1]" => 0.0, "c[2]" => 0.0, "c[3]" => 0.0)
        function build(compiler)
            dm = _PR.DiscreteMaterializer(); insp = _PR.BuildInspection()
            src = [0.3, 1.7]
            r = _PR._build_evaluator(file; initial_conditions = ics,
                const_arrays = Dict("W" => W), param_arrays = Dict("src" => src),
                materialize_out = dm, inspect = insp, compiler = compiler)
            (dm = dm, src = src, report = insp.compiler_report, r = r)
        end
        n, i = build(:native), build(:interpreter)
        g0 = [W[1, j] * 0.3 + W[2, j] * 1.7 for j in 1:3]
        @test n.dm.caches["g"] == g0
        @test all(n.dm.caches["g"] .=== i.dm.caches["g"])
        # A refill after an in-place refresh of the live buffer: the same bits again.
        n.src .= [2.5, -0.1]; i.src .= [2.5, -0.1]
        n.dm.materialize!(); i.dm.materialize!()
        @test all(n.dm.caches["g"] .=== i.dm.caches["g"])
        @test n.dm.caches["g"] == [W[1, j] * 2.5 + W[2, j] * -0.1 for j in 1:3]
        g_rows(rep) = [(r.kind, r.tier) for r in rep.rules if r.rule == "g"]
        @test g_rows(n.report) == [(:observed, :affine)]
        @test g_rows(i.report) == [(:observed, :discrete_percell)]
        # The right-hand side reads the refreshed cache under both compilers.
        for b in (n, i)
            f!, u0, p, _, vm = b.r
            du = similar(u0); f!(du, u0, p, 0.0)
            @test du[vm["c[1]"]] == b.dm.caches["g"][1] + (W[1, 1] + W[2, 1]) * 1.0
        end
    end

    # A discrete-cadence fill goes through the right-hand side's cascade. The
    # rank-4 contraction of the short-contraction route above, as a
    # discrete-cadence field instead of a derivative, compiles once there (the
    # affine tier's run-time fold), bit for bit with the interpreter's per-cell
    # walk; a fill the cascade cannot compile, a RAGGED contraction over the live
    # forcing read (see "a contraction no compile-once form takes" below), is
    # refused, naming the field.
    @testset "a discrete-cadence fill compiles once, or refuses by name" begin
        W = Float64[1, 2, 3, 4, 5, 6, 7, 8]
        rng = Dict{String,Any}(n => Any[1, 2] for n in ("a", "b", "c", "d"))
        agg = Dict{String,Any}("op" => "faq", "semiring" => "sum_product",
            "args" => Any[], "output_idx" => Any["a", "b", "c", "d"],
            "ranges" => merge(rng, Dict{String,Any}("k" => Any[1, length(W)])),
            "expr" => Dict("op" => "*", "args" => Any[
                Dict("op" => "index", "args" => Any[
                    Dict("op" => "const", "args" => Any[], "value" => W), "k"]),
                Dict("op" => "index", "args" => Any["F", "a", "b", "c", "d"])]))
        doc = Dict{String,Any}("esm" => "1.1.0",
            "metadata" => Dict("name" => "pr_discrete_rank4"),
            "models" => Dict("R" => Dict{String,Any}(
                "variables" => Dict(
                    "F" => Dict("type" => "parameter", "shape" => Any["a", "b", "c", "d"]),
                    "g" => Dict("type" => "unknown", "shape" => Any["a", "b", "c", "d"]),
                    "out" => Dict("type" => "unknown", "shape" => Any["a", "b", "c", "d"])),
                "equations" => Any[
                    Dict("lhs" => "g", "rhs" => agg),
                    Dict("lhs" => Dict("op" => "faq", "args" => Any[],
                            "output_idx" => Any["a", "b", "c", "d"], "ranges" => rng,
                            "expr" => Dict("op" => "D", "args" => Any[Dict("op" => "index",
                                "args" => Any["out", "a", "b", "c", "d"])], "wrt" => "t")),
                         "rhs" => Dict("op" => "faq", "args" => Any[],
                            "output_idx" => Any["a", "b", "c", "d"], "ranges" => rng,
                            "expr" => Dict("op" => "index",
                                "args" => Any["g", "a", "b", "c", "d"])))])))
        ics = Dict("out[$a,$b,$c,$d]" => 0.0 for a in 1:2, b in 1:2, c in 1:2, d in 1:2)
        F = reshape(collect(1.0:16.0), 2, 2, 2, 2)
        build(compiler) = withenv("ESS_CONTRACTION_LOOP_MIN" => "8") do
            dm = _PR.DiscreteMaterializer(); insp = _PR.BuildInspection()
            _PR._build_evaluator(doc; initial_conditions = ics,
                param_arrays = Dict("F" => copy(F)), materialize_out = dm,
                inspect = insp, compiler = compiler)
            (dm, insp.compiler_report)
        end
        (dn, rn), (di, _) = build(:native), build(:interpreter)
        @test vec(di.caches["g"]) == sum(W) .* vec(F)
        @test all(dn.caches["g"] .=== di.caches["g"])
        @test [r.tier for r in rn.rules if r.rule == "g"] == [:affine]

        N = 3
        ragged = deepcopy(doc)
        m = ragged["models"]["R"]
        m["variables"] = Dict(n => Dict(v..., "shape" => Any["a"]) for (n, v) in m["variables"])
        m["equations"][1]["rhs"] = Dict{String,Any}("op" => "faq", "semiring" => "sum_product",
            "args" => Any[], "output_idx" => Any["a"],
            "ranges" => Dict{String,Any}("a" => Any[1, N], "k" => Any[1,
                Dict("op" => "-", "args" => Any[Dict("op" => "+", "args" => Any["a", 4]), "a"])]),
            "expr" => Dict("op" => "*", "args" => Any[
                Dict("op" => "index", "args" => Any["F", "a"]), "k"]))
        m["equations"][2] = Dict("lhs" => Dict("op" => "faq", "args" => Any[],
                "output_idx" => Any["a"], "ranges" => Dict("a" => Any[1, N]),
                "expr" => Dict("op" => "D", "wrt" => "t", "args" => Any[
                    Dict("op" => "index", "args" => Any["out", "a"])])),
            "rhs" => Dict("op" => "faq", "args" => Any[], "output_idx" => Any["a"],
                "ranges" => Dict("a" => Any[1, N]),
                "expr" => Dict("op" => "index", "args" => Any["g", "a"])))
        build_r(compiler) = (dm = _PR.DiscreteMaterializer();
            _PR._build_evaluator(ragged; initial_conditions = Dict("out[$a]" => 0.0 for a in 1:N),
                param_arrays = Dict("F" => collect(1.0:N)), materialize_out = dm,
                compiler = compiler); dm)
        @test _pr_refuses(() -> build_r(:native), "refuses 'g'"; one_cell = true)
        @test build_r(:interpreter).caches["g"] == [10.0 * a for a in 1:N]
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

    @testset "a faq initialization equation is a compiled fill, bit-identically" begin
        body = _op("+", _op("*", _n(0.37), _v("i")), _op("/", _n(1.0), _op("+", _v("i"), _n(2.0))))
        m = _PR.Model(uvar(), [zero_eq()];
                      initialization_equations = [_PR.Equation(_v("u"), faq1(body))])
        un, vn, rn = seed(m, :native)
        ui, vi, ri = seed(m, :interpreter)
        @test all(un[vn["u[$i]"]] === ui[vi["u[$i]"]] for i in 1:5)
        @test all(un[vn["u[$i]"]] == 0.37 * i + 1.0 / (i + 2.0) for i in 1:5)
        @test [r.rule for r in _pr_rows(rn, :setup_codegen)] == ["init(u)"]
        @test [r.rule for r in _pr_rows(ri, :setup_percell)] == ["init(u)"]
    end

    # A pointwise filter: a cell whose predicate is false is the semiring's 0̄
    # (esm-schema `filter`), in the compiled fill and in the per-cell reference
    # alike. `max_sum`'s 0̄ is -Inf, so a filter read as 0.0 would show.
    @testset "a faq initialization equation with a pointwise filter" begin
        for (sr, zb) in (("sum_product", 0.0), ("max_sum", -Inf))
            agg = _PR.OpExpr("faq", _PR.ASTExpr[]; output_idx = Any["i"],
                             ranges = Dict("i" => Any[1, 5]), semiring = sr,
                             expr_body = _op("*", _n(10.0), _v("i")),
                             filter = _op("<=", _v("i"), _n(2.0)))
            m = _PR.Model(uvar(), [zero_eq()];
                          initialization_equations = [_PR.Equation(_v("u"), agg)])
            un, vn, rn = seed(m, :native)
            ui, vi, _ = seed(m, :interpreter)
            @test [ui[vi["u[$i]"]] for i in 1:5] == [10.0, 20.0, zb, zb, zb]
            @test all(un[vn["u[$i]"]] === ui[vi["u[$i]"]] for i in 1:5)
            @test [r.rule for r in _pr_rows(rn, :setup_codegen)] == ["init(u)"]
        end
    end

    # A live forcing buffer read at the output index: the fill reads the buffer
    # the way the right-hand side does.
    Fvar() = Dict("F" => _PR.ModelVariable(_PR.ParameterVariable; shape = ["x"]))
    @testset "a faq initialization equation reading a forcing buffer is a compiled fill" begin
        m = _PR.Model(merge(uvar(), Fvar()), [zero_eq()];
                      initialization_equations = [_PR.Equation(_v("u"),
                          faq1(_op("*", _n(2.0), _idx("F", _v("i")))))])
        F = collect(1.0:5.0)
        un, vn, rn = seed(m, :native; param_arrays = Dict("F" => F))
        ui, vi, _ = seed(m, :interpreter; param_arrays = Dict("F" => F))
        @test [ui[vi["u[$i]"]] for i in 1:5] == 2.0 .* F
        @test all(un[vn["u[$i]"]] === ui[vi["u[$i]"]] for i in 1:5)
        @test [r.rule for r in _pr_rows(rn, :setup_codegen)] == ["init(u)"]
    end

    # A body that reads ANOTHER state reads the initial state seeded so far, and
    # the compiled fill takes that state as a snapshot of its current values,
    # beside a live forcing buffer read at the output index.
    @testset "a faq initialization equation reading another state is a compiled fill" begin
        vvar = Dict("v" => _PR.ModelVariable(_PR.UnknownVariable; shape = ["x"],
                                             default = 0.5))
        vzero = _PR.Equation(faq1(_Didx("v", _v("i"))), faq1(_n(0.0)))
        m = _PR.Model(merge(uvar(), Fvar(), vvar), [zero_eq(), vzero];
                      initialization_equations = [_PR.Equation(_v("u"),
                          faq1(_op("+", _op("*", _n(2.0), _idx("F", _v("i"))),
                                   _idx("v", _v("i")))))])
        F = collect(1.0:5.0)
        un, vn, rn = seed(m, :native; param_arrays = Dict("F" => F))
        ui, vi, _ = seed(m, :interpreter; param_arrays = Dict("F" => F))
        @test [ui[vi["u[$i]"]] for i in 1:5] == 2.0 .* F .+ 0.5
        @test all(un[vn["u[$i]"]] === ui[vi["u[$i]"]] for i in 1:5)
        @test [r.rule for r in _pr_rows(rn, :setup_codegen)] == ["init(u)"]
    end

    # A body that reads its OWN target has only the per-cell forms, which walk a
    # tree at every cell against the state as it is being written. A strict
    # compiler refuses that by name; the interpreter takes it.
    @testset "a self-reading faq initialization equation refuses under native" begin
        m = _PR.Model(uvar(), [zero_eq()];
                      initialization_equations = [_PR.Equation(_v("u"),
                          faq1(_op("+", _op("*", _n(2.0), _v("i")), _idx("u", _v("i")))))])
        e = try
            seed(m, :native); nothing
        catch err
            err
        end
        @test e isa _PR.TreeWalkError && e.code == _PR.ERROR_CODES.COMPILER_REFUSED_RULE
        @test occursin("init(u)", e.detail) && occursin("tree walk per cell", e.detail)
        @test occursin(_PR._ONE_CELL_NOTE, e.detail)
        ui, vi, ri = seed(m, :interpreter)
        @test [ui[vi["u[$i]"]] for i in 1:5] == 2.0 .* (1:5)
        @test !isempty(_pr_rows(ri, :setup_percell)) || !isempty(_pr_rows(ri, :setup_compiled))
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
    # `h` is a makearray observed: the build-time cellwise sweep cannot keep a
    # region choice symbolic, so under `interpreter` reading it takes the
    # per-cell resolve-and-compile route. Under `native` both it and the
    # ordinary `k[i] = 2·i` are read through the compiled observed program,
    # and with both code-generation budgets at zero (refusal boundaries under
    # `native`) that program cannot be built — which is how a read native
    # cannot compile is provoked here. The document's right-hand side is
    # scalar, so the budgets refuse nothing else.
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

    no_codegen(f) = withenv(f, "ESS_CODEGEN_NODE_BUDGET" => "0",
                            "ESS_DUAL_CODEGEN_NODE_BUDGET" => "0")

    @testset "observed_field: a read native cannot compile refuses" begin
        @test _pr_refuses(() -> no_codegen() do
                              observed_field(esm_problem(mk_doc(), (0.0, 1.0)), "h")
                          end, "refuses 'M.h'")
        pn = esm_problem(mk_doc(), (0.0, 1.0))
        pi_ = esm_problem(mk_doc(), (0.0, 1.0); compiler = :interpreter)
        @test observed_field(pn, "h") == observed_field(pi_, "h") == [5.0, 7.0, 7.0]
    end

    @testset "observed_field: compiled once, memoized, and reported" begin
        pn = esm_problem(mk_doc(), (0.0, 1.0))
        read_k() = _PR._counting_program_reads(() -> observed_field(pn, "k"))
        v, n = read_k()
        @test v == [2.0, 4.0, 6.0] && n == 1
        # The second read evaluates nothing.
        v, n = read_k()
        @test v == [2.0, 4.0, 6.0] && n == 0
        rows = [r for r in compiler_report(pn).rules if r.kind === :observed]
        @test [(r.rule, r.tier) for r in rows] == [("k", :output_compiled)]
        # …until a live buffer is refreshed in place.
        _PR.notify_forcing_refresh!()
        v, n = read_k()
        @test v == [2.0, 4.0, 6.0] && n == 1
        @test count(r -> r.kind === :observed, compiler_report(pn).rules) == 1
        # Under `interpreter` the same read is the build-time cellwise sweep.
        pi_ = esm_problem(mk_doc(), (0.0, 1.0); compiler = :interpreter)
        hits0 = _PR._CELLWISE_FASTPATH_HITS[]
        @test observed_field(pi_, "k") == [2.0, 4.0, 6.0]
        @test _PR._CELLWISE_FASTPATH_HITS[] > hits0
        @test [r.tier for r in compiler_report(pi_).rules if r.kind === :observed] ==
              [:output_compiled_once]
    end

    @testset "inline-test assertions run under the problem's compiler" begin
        f = _PR.load_string(JSON3.write(mk_doc()))
        rn = no_codegen(() -> run_inline_tests(f))
        @test length(rn) == 1
        @test rn[1].status == _PR.ERROR
        @test occursin("compiler_refused_rule", rn[1].message)
        ri = run_inline_tests(f; compiler = :interpreter)
        @test ri[1].status == _PR.PASS
        @test ri[1].actual == 7.0
        rc = run_inline_tests(f)
        @test rc[1].status == _PR.PASS
        @test rc[1].actual === ri[1].actual
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

    # ── observed_field's memo and report row (review of #485) ────────────────
    # `y[i] = s·i` reads the parameter `s`, which the right-hand side reads
    # too. `T[i] = h[1]·i` names the makearray observed `h`: under `native` the
    # compiled program materializes `h` as a level of its own, and under
    # `interpreter` the build-time route materializes it per cell.
    obs_doc() = Dict{String,Any}("esm" => "1.1.0",
        "metadata" => Dict("name" => "pr_observed_memo"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => 3)),
        "models" => Dict("M" => Dict{String,Any}(
            "variables" => Dict(
                "c" => Dict("type" => "unknown", "default" => 1.0),
                "s" => Dict("type" => "parameter", "default" => 1.0),
                "y" => Dict("type" => "unknown", "shape" => Any["x"]),
                "h" => Dict("type" => "unknown", "shape" => Any["x"]),
                "T" => Dict("type" => "unknown", "shape" => Any["x"])),
            "equations" => Any[
                Dict("lhs" => Dict("op" => "D", "args" => Any["c"], "wrt" => "t"),
                     "rhs" => Dict("op" => "*", "args" => Any[
                         Dict("op" => "neg", "args" => Any["s"]), "c"])),
                Dict("lhs" => "y", "rhs" => Dict("op" => "faq", "args" => Any[],
                    "output_idx" => Any["i"],
                    "ranges" => Dict("i" => Dict("from" => "x")),
                    "expr" => Dict("op" => "*", "args" => Any["s", "i"]))),
                Dict("lhs" => "h", "rhs" => Dict("op" => "makearray", "args" => Any[],
                    "regions" => Any[Any[Any[1, 1]], Any[Any[2, 3]]],
                    "values" => Any[5.0, 7.0])),
                Dict("lhs" => "T", "rhs" => Dict("op" => "faq", "args" => Any[],
                    "output_idx" => Any["i"],
                    "ranges" => Dict("i" => Dict("from" => "x")),
                    "expr" => Dict("op" => "*", "args" => Any[
                        Dict("op" => "index", "args" => Any["h", 1]), "i"])))])))
    obs_rows(prob, name) = [r for r in compiler_report(prob).rules
                            if r.kind === :observed && r.rule == name]

    @testset "observed_field: a reused BuildInspection answers for its own build" begin
        insp = _PR.BuildInspection()
        p1 = esm_problem(obs_doc(), (0.0, 1.0); inspect = insp)
        @test observed_field(p1, "y") == [1.0, 2.0, 3.0]
        p2 = esm_problem(obs_doc(), (0.0, 1.0); p = Dict("s" => 2.0), inspect = insp)
        @test observed_field(p2, "y") == [2.0, 4.0, 6.0]
        @test length(obs_rows(p2, "y")) == 1
    end

    @testset "observed_field: a record shared by two problems files the latest build's row" begin
        # The record describes its latest build, so its report is p2's. A read
        # through the earlier p1 files no row there, and neither problem's read
        # evicts the other's memo entry or decides whether p2's row is filed.
        insp = _PR.BuildInspection()
        p1 = esm_problem(obs_doc(), (0.0, 1.0); inspect = insp)
        p2 = esm_problem(obs_doc(), (0.0, 1.0); p = Dict("s" => 2.0), inspect = insp)
        y1 = observed_field(p1, "y")
        @test y1 == [1.0, 2.0, 3.0]          # p1's own build, not the record's latest
        @test isempty(obs_rows(p2, "y"))
        @test observed_field(p2, "y") == [2.0, 4.0, 6.0]
        @test [r.tier for r in obs_rows(p2, "y")] == [:output_compiled]
        hits = _PR._CELLWISE_FASTPATH_HITS[]
        @test observed_field(p1, "y") == y1
        @test observed_field(p2, "y") == [2.0, 4.0, 6.0]
        @test _PR._CELLWISE_FASTPATH_HITS[] == hits
        @test length(obs_rows(p2, "y")) == 1
    end

    @testset "observed_field: a remade problem reads its build's field" begin
        # `observed_field` reports what the BUILD materialized (API_SPEC §5.8),
        # and `remake` shares the build, so a `p` or `u0` swap does not move it.
        # What the memo must never do is answer with anything other than what
        # the unmemoized read of the same problem would.
        p2 = esm_problem(obs_doc(), (0.0, 1.0); p = Dict("s" => 2.0))
        @test observed_field(p2, "y") == [2.0, 4.0, 6.0]
        for pr in (remake(p2; p = Dict("s" => 5.0)), remake(p2; u0 = Dict("c" => 9.0)))
            @test observed_field(pr, "y") == _PR._observed_field_impl(pr, "y") ==
                  [2.0, 4.0, 6.0]
        end
        @test length(obs_rows(p2, "y")) == 1
    end

    @testset "observed_field: the report row says what this read did" begin
        # Under `native` the compiled program served it, `h` included.
        pn = esm_problem(obs_doc(), (0.0, 1.0))
        @test observed_field(pn, "T") == [5.0, 10.0, 15.0]
        @test [r.tier for r in obs_rows(pn, "T")] == [:output_compiled]
        # Under `interpreter` `h` IS materialized per cell and served the value.
        pi_ = esm_problem(obs_doc(), (0.0, 1.0); compiler = :interpreter)
        @test observed_field(pi_, "T") == [5.0, 10.0, 15.0]
        @test [r.tier for r in obs_rows(pi_, "T")] == [:output_percell]
    end

    @testset "the per-cell signal counts this task's evaluations only" begin
        h = _PR.expression_from_json(Dict{String,Any}("op" => "makearray",
            "args" => Any[], "regions" => Any[Any[Any[1, 1]], Any[Any[2, 3]]],
            "values" => Any[5.0, 7.0]))
        cells = [[1], [2], [3]]
        v, n = _PR._counting_percell() do
            fetch(Threads.@spawn _PR.evaluate_cellwise(h, cells))
        end
        @test v == [5.0, 7.0, 7.0]
        @test n == 0
        v, n = _PR._counting_percell(() -> _PR.evaluate_cellwise(h, cells))
        @test v == [5.0, 7.0, 7.0]
        @test n == 1
    end

    # ── A document's own error comes before a per-cell refusal ────────────────
    # Each route below refuses under `native` only once the per-cell reference
    # has been shown to evaluate; a construct no form can evaluate raises the
    # error the interpreter raises.
    err_of(f) = try
        f(); nothing
    catch e
        e
    end
    code_of(e) = e isa _PR.TreeWalkError ? e.code : nothing

    @testset "seed_expression_ic!: an undeclared name is the caller's error" begin
        vm = Dict{String,Int}("M.u[$i]" => i for i in 1:3)
        bad = _PR.expression_from_json(Dict{String,Any}("op" => "*",
                                                        "args" => Any["x", "q"]))
        native(f) = _PR._with_compiler_plan(f, _PR._compiler_plan(:native))
        @test err_of(() -> native(() -> seed_expression_ic!(zeros(3), vm, "M.u", bad,
                                                            ["x" => [1.0, 2.0, 3.0]]))) isa
              _PR.UnboundVariableError
        # …and one that evaluates per cell but not once still refuses.
        tx = _PR.expression_from_json(Dict{String,Any}("op" => "*", "args" => Any["t", 2.0]))
        @test _pr_refuses(() -> native(() -> seed_expression_ic!(zeros(3), vm, "M.u", tx,
                                                                 ["t" => [1.0, 2.0, 3.0]])),
                          "seed_expression_ic!(M.u)"; one_cell = true)
        # Over no cell at all (a variable the map does not hold), nothing is
        # evaluated first, and the refusal does not say one cell was.
        e = err_of(() -> native(() -> seed_expression_ic!(zeros(3), vm, "M.v", tx,
                                                          ["t" => [1.0, 2.0, 3.0]])))
        @test code_of(e) == _PR.ERROR_CODES.COMPILER_REFUSED_RULE
        @test occursin("over 0 cells", e.detail)
        @test !occursin(_PR._ONE_CELL_NOTE, e.detail)
    end

    @testset "faq initialization equation: an undeclared name, an out-of-range gather" begin
        cvar = Dict("C" => _PR.ModelVariable(_PR.ParameterVariable; shape = ["x"]))
        for (body, code) in (
                (_op("*", _n(2.0), _v("q")), "E_TREEWALK_UNBOUND_VARIABLE"),
                (_op("*", _v("i"), _idx("C", _PR.IntExpr(11))), "E_TREEWALK_CONSTARRAY_OOB"))
            m = _PR.Model(merge(uvar(), cvar), [zero_eq()];
                          initialization_equations = [_PR.Equation(_v("u"), faq1(body))])
            for c in (:native, :interpreter)
                e = err_of(() -> seed(m, c; const_arrays = Dict("C" => collect(1.0:5.0))))
                @test code_of(e) == code
            end
        end
    end

    @testset "discrete-cadence materializer: an out-of-range gather, an undeclared name" begin
        W = [1.0 2.0 3.0; 4.0 5.0 6.0]
        ics = Dict{String,Float64}("c[1]" => 0.0, "c[2]" => 0.0, "c[3]" => 0.0)
        raw() = JSON3.read(read(joinpath(@__DIR__, "fixtures", "discrete_materialize.esm"),
                                String), Dict{String,Any})
        oob = raw(); oob["models"]["M"]["equations"][2]["rhs"]["ranges"]["i"] = Any[1, 3]
        unb = raw()
        unb["models"]["M"]["equations"][2]["rhs"]["expr"]["args"][1] =
            Dict("op" => "index", "args" => Any["Wq", "i", "j"])
        for (doc, code) in ((oob, "E_TREEWALK_CONSTARRAY_OOB"),
                            (unb, "E_TREEWALK_UNBOUND_VARIABLE"))
            file = _PR.load_string(JSON3.write(doc))
            for c in (:native, :interpreter)
                e = err_of(() -> _PR._build_evaluator(file; initial_conditions = ics,
                    const_arrays = Dict("W" => W), param_arrays = Dict("src" => [1.0, 1.0]),
                    materialize_out = _PR.DiscreteMaterializer(), compiler = c))
                @test code_of(e) == code
            end
        end
    end

    @testset "a contraction's out-of-range gather is the document's error" begin
        # One term past the end of `W`, under both compilers.
        W = Float64[1, 2, 3, 4, 5, 6, 7, 8]
        for c in (:native, :interpreter)
            e = err_of(() -> _pr_rank4_build(_pr_rank4_doc(W; past = 1), c))
            @test code_of(e) == "E_TREEWALK_CONSTARRAY_OOB"
        end
    end

    # A long contraction is the affine tier's run-time fold at any length: its
    # build lowers no more at 10^5 terms than at 8, and a gather out of range at
    # the far end is still the document's error. With a filter too.
    @testset "a long contraction compiles once$(filt ? ", filtered" : "")" for filt in (false, true)
        function lowerings(K, past)
            _PR._bench_reset!()
            _PR._BENCH_ON[] = true
            r = try
                _pr_rank4_build(_pr_rank4_doc(collect(1.0:K); past, filt), :native)
            catch e
                e
            finally
                _PR._BENCH_ON[] = false
            end
            return r, _PR._BENCH_COMPILE_CALLS[]
        end
        want(K) = 3.0 * sum(filt ? (2.0:K) : (1.0:K))
        for K in (8, 100_000)
            (f!, u0, p, _, vm), _ = lowerings(K, 0)
            du = similar(u0); f!(du, u0, p, 0.0)
            @test du[vm["out[1,1,1,1]"]] == want(K)
        end
        _, n_short = lowerings(8, 0)
        _, n_long = lowerings(100_000, 0)
        @test n_long == n_short
        e_oob, _ = lowerings(100_000, 1)
        @test code_of(e_oob) == "E_TREEWALK_CONSTARRAY_OOB"
        fi!, ui, pi_, _, vi = _pr_rank4_build(_pr_rank4_doc(collect(1.0:8.0); filt),
                                              :interpreter)
        di = similar(ui); fi!(di, ui, pi_, 0.0)
        @test di[vi["out[1,1,1,1]"]] == want(8)
    end

    # What no compile-once form takes. A RAGGED contraction (its bound an
    # expression of the output index) is not the affine tier's, and the nest
    # cannot keep its live forcing read symbolic, so the only form left is the
    # per-cell build: a strict compiler refuses it by name, naming the tier that
    # was offered it and declined, and not claiming a decline from one that was
    # not. Its one cell is evaluated first, in full when it is short, and only
    # at the ends of its contracted range when it is long, which the note says.
    @testset "a contraction no compile-once form takes is refused by name" begin
        N = 3
        rag(len) = Dict{String,Any}("esm" => "1.1.0",
            "metadata" => Dict("name" => "pr_ragged_forcing"),
            "models" => Dict("R" => Dict{String,Any}(
                "variables" => Dict(
                    "F" => Dict("type" => "parameter", "shape" => Any["i"]),
                    "u" => Dict("type" => "unknown", "shape" => Any["i"])),
                "equations" => Any[Dict(
                    "lhs" => Dict("op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                        "ranges" => Dict("i" => Any[1, N]),
                        "expr" => Dict("op" => "D", "wrt" => "t", "args" => Any[
                            Dict("op" => "index", "args" => Any["u", "i"])])),
                    "rhs" => Dict("op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                        "ranges" => Dict("i" => Any[1, N], "k" => Any[1,
                            Dict("op" => "-", "args" => Any[
                                Dict("op" => "+", "args" => Any["i", len]), "i"])]),
                        "expr" => Dict("op" => "*", "args" => Any[
                            Dict("op" => "index", "args" => Any["F", "i"]), "k"])))])))
        build(len, c) = _PR._build_evaluator(rag(len);
            initial_conditions = Dict("u[$i]" => 0.0 for i in 1:N),
            param_arrays = Dict("F" => collect(1.0:N)), compiler = c)
        e = err_of(() -> build(4, :native))
        @test code_of(e) == _PR.ERROR_CODES.COMPILER_REFUSED_RULE
        @test occursin("declined by the whole-array contraction tier", e.detail)
        @test occursin("takes no ragged contraction", e.detail)
        @test !occursin("declined by the affine", e.detail)
        @test occursin("per-cell build", e.detail)
        @test occursin(_PR._ONE_CELL_NOTE, e.detail)
        e_long = err_of(() -> build(5000, :native))
        @test code_of(e_long) == _PR.ERROR_CODES.COMPILER_REFUSED_RULE
        @test occursin(_PR._PART_CELL_NOTE, e_long.detail)
        f!, u0, p, _, vm = build(4, :interpreter)
        du = similar(u0); f!(du, u0, p, 0.0)
        @test [du[vm["u[$i]"]] for i in 1:N] == [i * 10.0 for i in 1:N]
    end

    # The diagnostic reports what it evaluated. A join gate that admits none of
    # the tuples tried (here the ends of a range too long to build in full)
    # leaves no term built, and the refusal says so rather than the one-cell
    # note, which would claim a document error could have surfaced.
    @testset "the refusal diagnostic says how much of the cell it evaluated" begin
        body = _PR.OpExpr("*", _PR.ASTExpr[_PR.VarExpr("k"),
            _PR.OpExpr("index", _PR.ASTExpr[_PR.VarExpr("u"), _PR.VarExpr("i")])])
        lhs = _PR.OpExpr("D", _PR.ASTExpr[
            _PR.OpExpr("index", _PR.ASTExpr[_PR.VarExpr("u"), _PR.VarExpr("i")])])
        K = 2000
        gate = [_PR._JoinGate("i", "k", Dict(1 => 7),
                              Dict(k => (k == K ÷ 2 ? 7 : 0) for k in 1:K))]
        diag(gates, n) = _PR._faq_diagnostic_cell(lhs, body;
            idx_names = ["i"], range_iters = [[1]], contract_names = ["k"],
            contract_ranges = [Any[1, n]], contract_const = [collect(1:n)],
            rhs_zerobar = 0.0, agg_gates = gates, agg_filter = nothing,
            resolved_obs = Dict{String,_PR.ASTExpr}(),
            array_var_info = Dict("u" => ([1], [1])),
            var_map = Dict("u[1]" => 1), const_registry = Dict{String,Any}(),
            pgather = Dict{String,Any}(), param_sym_set = Dict{Symbol,Int}(),
            reg_funcs = Dict{String,Any}())
        @test diag(nothing, 8) === :cell
        @test diag(nothing, K) === :part
        @test diag(gate, K) === :none
    end

    @testset "setup materializers: an out-of-range gather, an undeclared name" begin
        native(f) = _PR._with_compiler_plan(f, _PR._compiler_plan(:native))
        interp(f) = _PR._with_compiler_plan(f, _PR._compiler_plan(:interpreter))
        env = Dict{String,Any}("B" => reshape(collect(1.0:20.0), 5, 4))
        idx = Dict{String,Int}("X" => 5)
        # A MAP whose last cell reads past the end of `B`'s first axis: the
        # compiled-once sweep fails there, and so does the per-cell reference.
        map_oob = _PR.expression_from_json(Dict{String,Any}("op" => "faq",
            "args" => Any[], "output_idx" => Any["x"],
            "ranges" => Dict{String,Any}("x" => Dict{String,Any}("from" => "X")),
            "expr" => Dict{String,Any}("op" => "index", "args" => Any["B",
                Dict{String,Any}("op" => "+", "args" => Any["x", 1]), 1])))
        for run in (native, interp)
            e = err_of(() -> run(() -> _PR._materialize_setup_general_map(map_oob,
                copy(env), nothing, idx, Dict{String,Function}())))
            @test code_of(e) == "E_TREEWALK_CONSTARRAY_OOB"
        end
        # A makearray stencil (no compiled-once form at all) naming an undeclared
        # array.
        mk = _PR.expression_from_json(Dict{String,Any}("op" => "makearray",
            "args" => Any[], "regions" => Any[Any[Any[1, 5]]],
            "values" => Any[Dict{String,Any}("op" => "index", "args" => Any["Bq", 1, 1])]))
        for run in (native, interp)
            e = err_of(() -> run(() -> _PR._materialize_setup_wholearray(mk, copy(env),
                nothing, idx, ["X"], Dict{String,Function}())))
            @test code_of(e) == "E_TREEWALK_UNBOUND_VARIABLE"
        end
        # …and a makearray that evaluates is a compiled fill under native, equal
        # to the interpreter's per-cell materialization bit for bit.
        ok = _PR.expression_from_json(Dict{String,Any}("op" => "makearray",
            "args" => Any[], "regions" => Any[Any[Any[1, 2]], Any[Any[3, 5]]],
            "values" => Any[Dict{String,Any}("op" => "index", "args" => Any["B", 1, 1]),
                            Dict{String,Any}("op" => "*", "args" => Any[
                                Dict{String,Any}("op" => "index", "args" => Any["B", 2, 3]),
                                0.5])]))
        mat() = _PR._materialize_setup_wholearray(ok, copy(env), nothing, idx, ["X"],
                                                  Dict{String,Function}())
        insp = _PR._BuildRecord(_PR._compiler_plan(:native))
        an = native(() -> _PR._with_build_record(mat, insp))
        ai = interp(mat)
        @test isequal(an, ai)
        @test an == [1.0, 1.0, 6.0, 6.0, 6.0]
        @test [r.tier for r in insp.rules] == [:setup_codegen]
    end

    # ── Field initial conditions: the cell-independent forms, once ────────────
    @testset "a broadcast-constant field ic under the interpreter" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "scalar_ic",
                        "fixtures", "scalar_ic_in_array_model.esm")
        pi_ = esm_problem(path, (0.0, 1.0); compiler = :interpreter)
        rows = [r for r in compiler_report(pi_).rules if startswith(r.rule, "ic(")]
        @test !isempty(rows)
        @test all(r -> r.tier === :setup_constant, rows)
    end

    @testset "the per-cell field ic step does not re-run the constant step" begin
        # Every form fails for this RHS. Handed the cell-independent verdict
        # computed once, the per-cell resolve reports THAT attempt rather than
        # evaluating the constant again at this cell.
        rhs = _op("+", _v("nope"), _n(1.0))
        e = err_of(() -> _PR._resolve_field_ic("u", rhs, [1], Dict{String,Any}(),
                                               Dict{String,Any}();
                                               uniform = (nothing, ["as constant: SENTINEL"])))
        @test code_of(e) == "E_TREEWALK_UNSUPPORTED_EQUATION"
        @test occursin("SENTINEL", e.detail)
        @test count("as constant:", e.detail) == 1
    end
end

# A caller's u0 override is part of the state an initialization equation reads
# (user ruling; the Rust and Python front doors seed the same way), and a cell
# the caller names keeps the caller's value.
@testset "esm_problem: an initialization equation reads the caller's u0" begin
    faqx(body) = Dict{String,Any}("op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                                  "ranges" => Dict("i" => Dict("from" => "x")), "expr" => body)
    ixd(v) = Dict{String,Any}("op" => "index", "args" => Any[v, "i"])
    Dd(x) = Dict{String,Any}("op" => "D", "args" => Any[x], "wrt" => "t")
    doc = Dict{String,Any}("esm" => "1.1.0", "metadata" => Dict("name" => "init_reads_u0"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => 3)),
        "models" => Dict("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "u" => Dict{String,Any}("type" => "unknown", "shape" => Any["x"], "default" => 1.0),
                "w" => Dict{String,Any}("type" => "unknown", "shape" => Any["x"], "default" => 0.0)),
            "equations" => Any[Dict("lhs" => faqx(Dd(ixd("u"))), "rhs" => faqx(0.0)),
                               Dict("lhs" => faqx(Dd(ixd("w"))), "rhs" => faqx(0.0))],
            "initialization_equations" => Any[Dict("lhs" => "w",
                "rhs" => faqx(Dict{String,Any}("op" => "*", "args" => Any[2.0, ixd("u")])))])))
    cells(prob, v) = [prob.u0[prob.var_map["M.$v[$i]"]] for i in 1:3]
    for compiler in (:interpreter, :native)
        p1 = _PR.esm_problem(doc, (0.0, 1.0); compiler = compiler, u0 = Dict("u[2]" => 7.0))
        @test cells(p1, "u") == [1.0, 7.0, 1.0]
        @test cells(p1, "w") == [2.0, 14.0, 2.0]
        p2 = _PR.esm_problem(doc, (0.0, 1.0); compiler = compiler, u0 = Dict("u" => 4.0))
        @test cells(p2, "w") == [8.0, 8.0, 8.0]
        p3 = _PR.esm_problem(doc, (0.0, 1.0); compiler = compiler, u0 = Dict("M.w[2]" => -1.0))
        @test cells(p3, "w") == [2.0, -1.0, 2.0]
    end
end

# esm-spec §6.3.1 (user ruling): an equation whose left-hand side names a
# parameter is refused at build by name, under every compiler, never dropped.
@testset "esm_problem refuses an equation that defines a parameter" begin
    path = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "equation_defines_parameter.esm")
    for compiler in (:interpreter, :native)
        e = try
            _PR.esm_problem(path, (0.0, 1.0); compiler = compiler); nothing
        catch err
            err
        end
        @test e isa _PR.TreeWalkError &&
              e.code == _PR.ERROR_CODES.EQUATION_DEFINES_PARAMETER
    end
end
