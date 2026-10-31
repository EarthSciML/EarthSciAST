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
    # The §2.2.6 percent-encoding, written out here rather than borrowed.
    _safe(b) = UInt8('A') <= b <= UInt8('Z') || UInt8('a') <= b <= UInt8('z') ||
        UInt8('0') <= b <= UInt8('9') || b in codeunits("-._~/:")
    _url(p) = "file://" * join(
        _safe(b) ? string(Char(b)) : "%" * uppercase(string(b; base = 16, pad = 2))
            for b in codeunits(normpath(p))
    )
    _expected(::Nothing) = nothing
    _expected(pin) = haskey(pin, :verbatim) ? String(pin.verbatim) :
        haskey(pin, :repo_path) ? _url(_repo(pin.repo_path)) :
        _url(joinpath(pwd(), String(pin.cwd_path)))
    _load(f) = begin
        path = joinpath(suite, String(f.path))
        f.load == "path" ? EarthSciAST.load_path(path) :
            EarthSciAST.load_string(read(path, String))
    end
    _emitted_solver(file) =
        get(JSON3.read(EarthSciAST.to_json(file), Dict{String, Any}), "solver", nothing)
    _pinned_solver(::Nothing) = nothing
    _pinned_solver(s) = JSON3.read(JSON3.write(s), Dict{String, Any})

    @test Set(String.(manifest.bindings_required)) ⊇ Set(["julia"])

    @testset "resolution: $(f.id)" for f in manifest.fixtures
        f.expect == "accepted" || continue
        file = _load(f)
        authored = file.solver === nothing ? nothing : file.solver.external
        @test authored == f.external
        base = f.base === nothing ? nothing : _repo(f.base.repo_path)
        @test EarthSciAST.solver_external_location(file; base_path = base) ==
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
                _url(joinpath(abspath(dir), "..", "runs", "probe.run.json"))
        end
    end

    @testset "resolution is lexical, with a relative explicit base taken against the working directory" begin
        file = EarthSciAST.load_path(joinpath(suite, "fixtures", "bare_relative.esm"))
        @test EarthSciAST.solver_external_location(file; base_path = "/x/./y/../z") ==
            "file:///x/z/runs/probe.run.json"
        @test EarthSciAST.solver_external_location(file; base_path = "rel/dir") ==
            _url(joinpath(pwd(), "rel", "dir", "runs", "probe.run.json"))
        # Built in memory, with no recorded directory: the working directory.
        mem = EarthSciAST.coerce_esm_file(
            JSON3.read(
                read(
                    joinpath(suite, "fixtures", "bare_relative.esm"), String
                )
            )
        )
        @test mem.document_base === nothing
        @test EarthSciAST.solver_external_location(mem) ==
            _url(joinpath(pwd(), "runs", "probe.run.json"))
        # The recorded directory lives on the document, beside the block.
        @test mem.solver == file.solver
        @test hash(mem.solver) == hash(file.solver)
        @test file.document_base == normpath(joinpath(suite, "fixtures"))
    end

    @testset "the directory is recorded at load and never serialized" begin
        text = read(joinpath(suite, "fixtures", "bare_relative.esm"), String)
        loaded = EarthSciAST.load_string(text)
        @test loaded.document_base == rstrip(normpath(pwd()), '/')
        @test !occursin("document_base", EarthSciAST.to_json(loaded))
        # Rebuilds carry it across.
        @test EarthSciAST.migrate(loaded, loaded.esm).document_base == loaded.document_base
    end

    @testset "a drive-letter path is absolute, for `external` and for the base" begin
        mem(external) = EarthSciAST.EsmFile(
            "1.3.0", EarthSciAST.Metadata("m");
            solver = EarthSciAST.Solver(external = external)
        )
        for (external, base, want) in (
                ("C:/proj/./runs/../x.json", nothing, "file:///C:/proj/x.json"),
                ("c:\\proj\\runs\\x.json", nothing, "file:///c:/proj/runs/x.json"),
                ("C:/../../x.json", nothing, "file:///C:/x.json"),
                ("runs/x.json", "C:/proj/sub/..", "file:///C:/proj/runs/x.json"),
                ("runs/x.json", "D:\\proj", "file:///D:/proj/runs/x.json"),
                ("../../../x.json", "C:/proj", "file:///C:/x.json"),
                ("/srv/x.json", "C:/proj", "file:///srv/x.json"),
            )
            @test EarthSciAST.solver_external_location(mem(external); base_path = base) == want
        end
        text = read(joinpath(suite, "fixtures", "bare_relative.esm"), String)
        loaded = EarthSciAST.load_string(text; base_path = "C:/proj/sub")
        @test loaded.document_base == "C:/proj/sub"
        @test EarthSciAST.solver_external_location(loaded) ==
            "file:///C:/proj/sub/runs/probe.run.json"
    end

    @testset "solver_external_unresolved" begin
        doc = JSON3.read(
            read(joinpath(suite, "fixtures", "env_var.esm"), String),
            Dict{String, Any}
        )
        _code_and_message(d) = try
            EarthSciAST.load_string(JSON3.write(d))
            (nothing, "")
        catch err
            (hasproperty(err, :code) ? err.code : string(typeof(err)), sprint(showerror, err))
        end
        # The message quotes the string exactly as authored.
        authored = "a\\b \"c\" \${X}/y.json"
        doc["solver"] = Dict{String, Any}("external" => authored)
        code, msg = _code_and_message(doc)
        @test code == EarthSciAST.ERROR_CODES.SOLVER_EXTERNAL_UNRESOLVED
        @test occursin("\"" * authored * "\"", msg)
        # Checked before schema validation.
        doc["solver"] = Dict{String, Any}("external" => "\${X}/y.json", "not_a_solver_key" => true)
        @test first(_code_and_message(doc)) == EarthSciAST.ERROR_CODES.SOLVER_EXTERNAL_UNRESOLVED
    end

    @testset "version gate" begin
        doc = JSON3.read(
            read(joinpath(suite, "fixtures", "bare_relative.esm"), String),
            Dict{String, Any}
        )
        for (version, code) in (
                ("1.2.0", EarthSciAST.ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD),
                ("1.1.0", EarthSciAST.ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD),
                ("1.0.0", EarthSciAST.ERROR_CODES.SOLVER_VERSION_TOO_OLD),
            )
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
        older = merge(
            doc, Dict(
                "esm" => "1.2.0",
                "solver" => Dict{String, Any}("reltol" => 1.0e-6)
            )
        )
        @test EarthSciAST.load_string(JSON3.write(older)).solver.reltol == 1.0e-6
    end

    @testset "invariance: flatten does not read `external`" begin
        with = EarthSciAST.load_path(joinpath(suite, String(manifest.invariance.with)))
        without = EarthSciAST.load_path(joinpath(suite, String(manifest.invariance.without)))
        @test with.solver.external !== nothing
        @test without.solver.external === nothing
        _flat_doc(flat) = JSON3.read(
            JSON3.write(EarthSciAST.flattened_to_esm(flat)),
            Dict{String, Any}
        )
        @test _flat_doc(EarthSciAST.flatten(with)) == _flat_doc(EarthSciAST.flatten(without))
        @test collect(keys(with.models)) == collect(keys(without.models))
        for (name, model) in with.models
            @test _flat_doc(EarthSciAST.flatten(model; name = name)) ==
                _flat_doc(EarthSciAST.flatten(without.models[name]; name = name))
        end
    end
end
