using Test
using EarthSciAST
using JSON3
using OrderedCollections: OrderedDict
include("testutils.jl")   # TESTUTILS_REPO_ROOT

# esm-spec §4.7 "Binding a data source's location at the mount"
# (`url_substitutions`), against the SHARED pin
# `tests/conformance/url_substitutions/manifest.json`, which every binding's own
# suite reads.
#
# `cases` pin the edge rule as a document normalization: apply the edge with the
# MOUNTING document's directory (`binder_dir`), then ordinary §8.2.1 resolution
# with the DECLARING document's (`declaring_dir`). `fixtures` pin it through a
# real load; this binding merges a mounted document's `data_sources` into the
# mounting document at both mount forms (esm-spec §4.7 "A mounted document's
# data sources"), so every fixture's `hoisted_sources` is checked.
@testset "esm-spec §4.7 mount-edge url_substitutions" begin
    suite = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "url_substitutions")
    manifest = JSON3.read(read(joinpath(suite, "manifest.json"), String))
    declaring = joinpath(TESTUTILS_REPO_ROOT, String(manifest.declaring_dir))
    binder = joinpath(TESTUTILS_REPO_ROOT, String(manifest.binder_dir))

    _expected(pin) = haskey(pin, :verbatim) ? String(pin.verbatim) :
        "file://" * normpath(joinpath(TESTUTILS_REPO_ROOT, String(pin.repo_path)))

    _caught(f) = try
        f()
        nothing
    catch e
        e
    end

    @testset "cases: $(c.id)" for c in manifest.cases
        source = OrderedDict{String, Any}("url_template" => String(c.url_template))
        haskey(c, :mirrors) && (source["mirrors"] = Any[String(m) for m in c.mirrors])
        doc = OrderedDict{String, Any}(
            "data_sources" => OrderedDict{String, Any}(
                "s" => OrderedDict{String, Any}("kind" => "static", "source" => source)
            )
        )
        subs = EarthSciAST._to_native_json(c.url_substitutions)
        run() = begin
            # A `binder_url` case mounts from a URL-valued directory (a document
            # loaded from a URL): a leading relative value joins by RFC 3986.
            dir = haskey(c, :binder_url) ? String(c.binder_url) : binder
            EarthSciAST.apply_mount_url_substitutions!(doc, subs, dir, "case")
            something(EarthSciAST._resolve_data_source_urls(doc, declaring), doc)
        end
        expect = c.expect
        if haskey(expect, :error_code)
            e = _caught(run)
            @test e isa EarthSciAST.ExpressionTemplateError
            if e isa EarthSciAST.ExpressionTemplateError
                @test e.code == String(expect.error_code)
                for needle in expect.message_contains
                    @test occursin(String(needle), e.message)
                end
            end
        else
            got = run()["data_sources"]["s"]["source"]
            @test got["url_template"] == _expected(expect.url_template)
            if haskey(expect, :mirrors)
                @test collect(got["mirrors"]) == [_expected(m) for m in expect.mirrors]
            end
        end
    end

    # Every fixture twice: through `load_path` (the native mount walk), and
    # through the TYPED subsystem walk — the path URL refs take, forced here
    # with `native_subsystem_refs = false` — so the rule holds on both.
    _load_typed(path) = EarthSciAST._load_document(
        EarthSciAST._read_json_document(read(path, String)), dirname(abspath(path));
        native_subsystem_refs = false
    )
    @testset "fixtures ($(walk)): $(f.id)" for walk in ("native", "typed"),
            f in manifest.fixtures

        path = normpath(joinpath(suite, String(f.path)))
        load = walk == "native" ? EarthSciAST.load_path : _load_typed
        if String(f.expect) == "refused"
            e = _caught(() -> load(path))
            @test e isa EarthSciAST.ExpressionTemplateError
            if e isa EarthSciAST.ExpressionTemplateError
                @test e.code == String(f.error_code)
                for needle in f.message_contains
                    @test occursin(String(needle), e.message)
                end
            end
        else
            loaded = load(path)
            @test loaded isa EarthSciAST.EsmFile
            pins = haskey(f, :hoisted_sources) ? pairs(f.hoisted_sources) : ()
            for (name, pin) in pins
                have = loaded.data_sources !== nothing &&
                    haskey(loaded.data_sources, String(name))
                @test have
                have || continue
                ds = loaded.data_sources[String(name)]
                @test ds.source.url_template == _expected(pin.url_template)
                if haskey(pin, :mirrors)
                    @test collect(something(ds.source.mirrors, String[])) ==
                        [_expected(m) for m in pin.mirrors]
                end
            end
            sizes = haskey(f, :index_set_sizes) ? pairs(f.index_set_sizes) : ()
            for (axis, size) in sizes
                @test loaded.index_sets[String(axis)].size == size
            end
        end
    end

    @testset "the edge is consumed at load and does not survive emit" begin
        loaded = EarthSciAST.load_path(joinpath(suite, "mount_toplevel.esm"))
        mktempdir() do dir
            out = joinpath(dir, "emitted.esm")
            EarthSciAST.write_path(loaded, out)
            @test !occursin("\"url_substitutions\"", read(out, String))
            again = EarthSciAST.load_path(out)
            for (name, ds) in pairs(loaded.data_sources)
                @test again.data_sources[name].source.url_template == ds.source.url_template
            end
        end
    end

    @testset "placeholders are bare identifiers only" begin
        names(t) = [n for (_, _, n) in EarthSciAST._url_placeholders(t)]
        @test names("{a}/{b_1}/{date:%Y}/{1x}/{}/{a") == ["a", "b_1"]
        @test names("x{snapshot}y") == ["snapshot"]
    end

    @testset "an edge with no url_substitutions leaves the document alone" begin
        doc = OrderedDict{String, Any}(
            "data_sources" => OrderedDict{String, Any}(
                "s" => OrderedDict{String, Any}(
                    "source" => OrderedDict{String, Any}("url_template" => "{x}/t.nc")
                )
            )
        )
        before = deepcopy(doc)
        EarthSciAST.apply_mount_url_substitutions!(doc, nothing, "/a", "e")
        @test doc == before
    end
end
