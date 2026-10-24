using Test
using EarthSciAST
using JSON3
include("testutils.jl")   # TESTUTILS_REPO_ROOT

# esm-spec §2.2.6 `solver.external` resolution, against the SHARED pin.
#
# Reads `tests/conformance/solver_external/manifest.json` and asserts this
# binding against it: what the typed document holds, what the accessor returns,
# and what `emit` writes back. Every binding's own suite reads the same file.
#
# Nothing a fixture names exists on disk, and this test creates none of it:
# resolution is lexical, so a binding that stat-ed a target would fail here.
@testset "esm-spec §2.2.6 solver.external resolution" begin
    suite = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "solver_external")
    manifest = JSON3.read(read(joinpath(suite, "manifest.json"), String))

    _repo(p) = normpath(joinpath(TESTUTILS_REPO_ROOT, String(p)))
    _expected(::Nothing) = nothing
    _expected(pin) = haskey(pin, :verbatim) ? String(pin.verbatim) :
                     haskey(pin, :repo_path) ? "file://" * _repo(pin.repo_path) :
                     "file://" * normpath(joinpath(pwd(), String(pin.cwd_path)))
    _load(f) = begin
        path = joinpath(suite, String(f.path))
        f.load == "path" ? EarthSciAST.load_path(path) :
                           EarthSciAST.load_string(read(path, String))
    end
    _emitted_solver(file) =
        get(JSON3.read(EarthSciAST.to_json(file), Dict{String,Any}), "solver", nothing)
    _pinned_solver(::Nothing) = nothing
    _pinned_solver(s) = JSON3.read(JSON3.write(s), Dict{String,Any})

    @test Set(String.(manifest.bindings_required)) ⊇ Set(["julia"])

    @testset "resolution: $(f.id)" for f in manifest.fixtures
        f.expect == "accepted" || continue
        file = _load(f)
        authored = file.solver === nothing ? nothing : file.solver.external
        @test authored == f.external
        base = f.base === nothing ? nothing : _repo(f.base.repo_path)
        @test EarthSciAST.solver_external_location(file; base_path=base) ==
              _expected(f.location)
        @test _emitted_solver(file) == _pinned_solver(f.solver)
    end

    @testset "refusal: $(f.id)" for f in manifest.fixtures
        f.expect == "refused" || continue
        e = try
            _load(f)
            nothing
        catch err
            err
        end
        @test e isa EarthSciAST.ExpressionTemplateError
        e isa EarthSciAST.ExpressionTemplateError || continue
        @test e.code == String(f.error_code)
        @test e.code == EarthSciAST.ERROR_CODES.SOLVER_EXTERNAL_UNRESOLVED
        for needle in f.message_contains
            @test occursin(String(needle), e.message)
        end
    end

    @testset "the resolved form is never written back" begin
        # Emitted into a DIFFERENT directory and reloaded: the document still
        # holds the authored string, so only the accessor's answer moves.
        src = joinpath(suite, "fixtures", "parent_relative.esm")
        first = EarthSciAST.load_path(src)
        mktempdir() do dir
            out = joinpath(dir, "emitted.esm")
            EarthSciAST.write_path(first, out)
            second = EarthSciAST.load_path(out)
            @test second.solver.external == first.solver.external == "../runs/probe.run.json"
            @test EarthSciAST.solver_external_location(second) ==
                  "file://" * normpath(joinpath(abspath(dir), "..", "runs", "probe.run.json"))
        end
    end

    @testset "resolution is lexical, with a relative explicit base taken against the working directory" begin
        file = EarthSciAST.load_path(joinpath(suite, "fixtures", "bare_relative.esm"))
        @test EarthSciAST.solver_external_location(file; base_path="/x/./y/../z") ==
              "file:///x/z/runs/probe.run.json"
        @test EarthSciAST.solver_external_location(file; base_path="rel/dir") ==
              "file://" * normpath(joinpath(pwd(), "rel", "dir", "runs", "probe.run.json"))
        # Built in memory, with no recorded directory: the working directory.
        mem = EarthSciAST.coerce_esm_file(JSON3.read(read(
            joinpath(suite, "fixtures", "bare_relative.esm"), String)))
        @test EarthSciAST.solver_external_location(mem) ==
              "file://" * normpath(joinpath(pwd(), "runs", "probe.run.json"))
        # The recorded directory takes no part in equality.
        @test mem.solver == file.solver
        @test hash(mem.solver) == hash(file.solver)
    end

    @testset "version gate" begin
        doc = JSON3.read(read(joinpath(suite, "fixtures", "bare_relative.esm"), String),
                         Dict{String,Any})
        for (version, code) in (("1.2.0", EarthSciAST.ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD),
                                ("1.1.0", EarthSciAST.ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD),
                                ("1.0.0", EarthSciAST.ERROR_CODES.SOLVER_VERSION_TOO_OLD))
            e = try
                EarthSciAST.load_string(JSON3.write(merge(doc, Dict("esm" => version))))
                nothing
            catch err
                err
            end
            @test e isa EarthSciAST.ExpressionTemplateError
            e isa EarthSciAST.ExpressionTemplateError || continue
            @test e.code == code
            code == EarthSciAST.ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD &&
                @test occursin("/solver/external", e.message)
        end
        # A 1.2.0 block without `external` stays valid.
        older = merge(doc, Dict("esm" => "1.2.0",
                                "solver" => Dict{String,Any}("reltol" => 1e-6)))
        @test EarthSciAST.load_string(JSON3.write(older)).solver.reltol == 1e-6
    end

    @testset "invariance: flatten does not read `external`" begin
        with = EarthSciAST.load_path(joinpath(suite, String(manifest.invariance.with)))
        without = EarthSciAST.load_path(joinpath(suite, String(manifest.invariance.without)))
        @test with.solver.external !== nothing
        @test without.solver.external === nothing
        _flat_doc(flat) = JSON3.read(JSON3.write(EarthSciAST.flattened_to_esm(flat)),
                                     Dict{String,Any})
        @test _flat_doc(EarthSciAST.flatten(with)) == _flat_doc(EarthSciAST.flatten(without))
        @test collect(keys(with.models)) == collect(keys(without.models))
        for (name, model) in with.models
            @test _flat_doc(EarthSciAST.flatten(model; name=name)) ==
                  _flat_doc(EarthSciAST.flatten(without.models[name]; name=name))
        end
    end
end
