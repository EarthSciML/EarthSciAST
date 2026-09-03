using Test
using EarthSciAST
using JSON3

# esm-spec §8.2.1 data-source location resolution, against the SHARED pin.
#
# Reads `tests/conformance/data_source_url/manifest.json` -- the one place the
# expected resolution is written down -- and asserts this binding against it.
# Every binding's own suite reads the same file, so a path rule that differed
# between bindings (which would silently make documents non-portable, the defect
# §8.2.1 closes) fails here rather than downstream.
#
# Expectations are repo-relative paths, not literal URLs: the resolved form is a
# machine-specific absolute `file://` URL and a golden holding one would only
# pass on the machine that wrote it.
@testset "esm-spec §8.2.1 data-source location resolution" begin
    suite = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "data_source_url")
    manifest = JSON3.read(read(joinpath(suite, "manifest.json"), String))

    _fixture(id) = begin
        hit = findfirst(f -> f.id == id, manifest.fixtures)
        @assert hit !== nothing "no fixture $(id) in the shared manifest"
        manifest.fixtures[hit]
    end
    _expected(pin) = haskey(pin, :verbatim) ? String(pin.verbatim) :
                     "file://" * normpath(joinpath(TESTUTILS_REPO_ROOT, String(pin.repo_path)))

    @testset "every pinned form resolves as the shared manifest says" begin
        f = _fixture("relative_catalog")
        loaded = EarthSciAST.load_path(joinpath(suite, String(f.path)))
        for (name, pin) in pairs(f.sources)
            src = loaded.data_sources[String(name)].source
            @test src.url_template == _expected(pin.url_template)
            if haskey(pin, :mirrors)
                @test collect(something(src.mirrors, String[])) ==
                      [_expected(m) for m in pin.mirrors]
            end
        end
    end

    @testset "resolution is idempotent, so parse -> emit -> parse is stable" begin
        # Re-loaded from a DIFFERENT directory, so a template that had somehow
        # stayed relative would resolve somewhere else and be caught, rather
        # than resolving to the same place by accident.
        f = _fixture("relative_catalog")
        first = EarthSciAST.load_path(joinpath(suite, String(f.path)))
        mktempdir() do dir
            out = joinpath(dir, "emitted.esm")
            EarthSciAST.write_path(first, out)
            second = EarthSciAST.load_path(out)
            for (name, ds) in pairs(first.data_sources)
                @test second.data_sources[name].source.url_template == ds.source.url_template
                @test collect(something(second.data_sources[name].source.mirrors, String[])) ==
                      collect(something(ds.source.mirrors, String[]))
            end
        end
    end

    @testset "an unresolvable template is refused, naming it" begin
        # Not merely "it does not resolve": the diagnostic has to NAME the entry
        # and the template. Treating `${MOVES_SNAPSHOTS}` as a directory name
        # yields an I/O error about a path nobody wrote, one step away from a
        # source that delivers a consuming parameter's default and compares
        # nothing.
        for id in ("env_var_catalog", "env_var_mirror_catalog")
            f = _fixture(id)
            path = joinpath(suite, String(f.path))
            e = try
                EarthSciAST.load_path(path)
                nothing
            catch err
                err
            end
            @test e isa EarthSciAST.ExpressionTemplateError
            e isa EarthSciAST.ExpressionTemplateError || continue
            @test e.code == String(f.error_code)
            @test e.code == EarthSciAST.ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED
            for needle in f.message_contains
                @test occursin(String(needle), e.message)
            end
        end
    end

    @testset "dot segments go lexically, never by realpath" begin
        # §8.2.1: a template carrying a `{date:...}` substitution names a file
        # per timestep, none of which exists at load time, so resolution cannot
        # touch the filesystem.
        @test EarthSciAST.resolve_source_url("./a/../b/./c.nc", "/x/y") == "file:///x/y/b/c.nc"
        @test EarthSciAST.resolve_source_url("/../c.nc", "/x/y") == "file:///c.nc"
        @test EarthSciAST.resolve_source_url("{archive_root}/x.nc", "/x/y") ==
              "{archive_root}/x.nc"
    end
end
