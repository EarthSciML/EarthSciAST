# The document-scoped `solver` block (esm-spec §2.2).

using EarthSciAST, Test, JSON3
include("testutils.jl")

const _SOLVER_FIXTURE = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "solver_block.esm")

_solver_base() = JSON3.read(read(_SOLVER_FIXTURE, String), Dict{String,Any})

function _solver_load(doc)
    path = tempname() * ".esm"
    write(path, JSON3.write(doc))
    return EarthSciAST.load_path(path)
end

_solver_emit(f) = JSON3.read(EarthSciAST.to_json(f), Dict{String,Any})

@testset "solver block (esm-spec §2.2)" begin
    if !_require_fixture(_SOLVER_FIXTURE)
        return
    end
    base = _solver_base()

    @testset "a declared block round-trips verbatim" begin
        f = EarthSciAST.load_path(_SOLVER_FIXTURE)
        @test f.solver !== nothing
        @test f.solver.stiffness == "high"
        @test f.solver.abstol == 1e-8
        @test _solver_emit(f)["solver"] == base["solver"]
    end

    @testset "an empty block normalizes to absence at load" begin
        # `{}` is legal — every other optional top-level container admits one —
        # but it means what omitting the block means, so it is dropped at load
        # and never reaches emit. That is what keeps the five bindings from
        # disagreeing about whether `{}` survives `parse -> emit`.
        f = _solver_load(merge(base, Dict("solver" => Dict{String,Any}())))
        @test f.solver === nothing
        @test !haskey(_solver_emit(f), "solver")
    end

    @testset "the block is rejected below esm 1.1.0" begin
        doc = merge(base, Dict("esm" => "1.0.0",
                               "solver" => Dict{String,Any}("stiffness" => "high")))
        err = try
            _solver_load(doc); nothing
        catch e
            e
        end
        @test err isa EarthSciAST.ExpressionTemplateError
        @test err.code == EarthSciAST.ERROR_CODES.SOLVER_VERSION_TOO_OLD
    end

    @testset "tolerances resolve most-specific first (§2.2.2)" begin
        s = EarthSciAST.load_path(_SOLVER_FIXTURE).solver
        @test EarthSciAST.resolve_tolerances(s; abstol=1e-12, reltol=1e-11) == (1e-12, 1e-11)
        @test EarthSciAST.resolve_tolerances(s) == (1e-8, 1e-6)
        @test EarthSciAST.resolve_tolerances(nothing) ==
              (EarthSciAST.DEFAULT_SIM_ABSTOL, EarthSciAST.DEFAULT_SIM_RELTOL)
        # Per field: a document declaring only `reltol` leaves `abstol` on the default.
        only_reltol = _solver_load(merge(base,
            Dict("solver" => Dict{String,Any}("reltol" => 1e-9)))).solver
        @test EarthSciAST.resolve_tolerances(only_reltol) ==
              (EarthSciAST.DEFAULT_SIM_ABSTOL, 1e-9)
    end

    @testset "the block reaches the RUN DOCUMENT (§2.2.2 is not dead code)" begin
        # Regression: `_document_solver` reads the problem's run doc, but the run
        # doc is `flattened_to_esm` output — a fresh dict of
        # esm/metadata/models/index_sets/function_tables/domain — so the key was
        # never there and the whole §2.2.2 chain silently reduced to the binding
        # defaults. The block is captured pre-flatten and re-attached, exactly
        # like the `coordinates` registry beside it.
        f = EarthSciAST.load_path(_SOLVER_FIXTURE)
        doc = EarthSciAST._prepare_run_doc(f)
        @test haskey(doc, "solver")
        @test doc["solver"]["abstol"] == 1e-8
        @test doc["solver"]["reltol"] == 1e-6
        # And what `_document_solver` coerces back out of it is the same block.
        recovered = EarthSciAST.coerce_solver(doc["solver"])
        @test recovered !== nothing
        @test EarthSciAST.resolve_tolerances(recovered) == (1e-8, 1e-6)

        # A document with no block leaves the key off entirely, which is what
        # keeps absence distinguishable from a declared default.
        no_block = _solver_load(Dict(k => v for (k, v) in base if k != "solver"))
        @test !haskey(EarthSciAST._prepare_run_doc(no_block), "solver")
    end

    @testset "inline-test integration tolerances come from the document (§2.2.2)" begin
        # The runner's own DEFAULT_TEST_* sit at LEVEL 3 — they are binding
        # defaults, not a caller's opinion — so a document that declares
        # `solver.reltol` displaces them, and each field falls through
        # independently. Without this, Julia integrated `solver_block.esm`'s
        # inline tests at 1e-10/1e-12 while Python and the Rust CLI used the
        # document's 1e-6/1e-8: three bindings, two integration tolerances, one
        # document.
        f = EarthSciAST.load_path(_SOLVER_FIXTURE)
        @test EarthSciAST._test_integration_tolerances(f.solver) == (1e-6, 1e-8)
        @test EarthSciAST._test_integration_tolerances(nothing) ==
              (EarthSciAST.DEFAULT_TEST_RELTOL, EarthSciAST.DEFAULT_TEST_ABSTOL)
        only_reltol = _solver_load(merge(base,
            Dict("solver" => Dict{String,Any}("reltol" => 1e-9)))).solver
        @test EarthSciAST._test_integration_tolerances(only_reltol) ==
              (1e-9, EarthSciAST.DEFAULT_TEST_ABSTOL)
    end

    @testset "stiffness picks the stiff solver, and only for `high`" begin
        # A portable declaration mapped to THIS binding's integrator. The
        # document never carries `Rosenbrock23` — an algorithm name would not
        # travel (§2.2.3). `low`/`moderate` are ignored: they say nothing the
        # default does not already handle.
        rb = EarthSciAST._try_require(EarthSciAST._ROSENBROCK_PKGID)
        if rb === nothing
            @test_skip "OrdinaryDiffEqRosenbrock not loaded"
        else
            @test EarthSciAST._pick_solver(""; stiffness="high")[2] === :rosenbrock23
            for declared in ("moderate", "low", nothing)
                @test EarthSciAST._pick_solver(""; stiffness=declared)[2] !== :rosenbrock23
            end
            # The basename fallback still works for documents that declare nothing.
            @test EarthSciAST._pick_solver("pollu.esm")[2] === :rosenbrock23
        end
    end
end
