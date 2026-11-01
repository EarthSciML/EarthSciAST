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

    # `mount_subsystem_through_stops` over http(s): the typed walk is the only one
    # that resolves URL refs, so a forwarded binding must stop there too. The
    # catalogue mounts `outer` as a SUBSYSTEM (an assembly reached over http(s)
    # inlines no top-level `{ref}`), and its relative refs join onto its URL
    # directory — which the mount-declared walk must follow, or `n_rows` would
    # be `template_import_unknown_name` at the root edge.
    @testset "a forwarded binding stops at the first declarer, over a URL" begin
        sized(name, axis, default, sub) = JSON3.write(
            OrderedDict{String, Any}(
                "esm" => "1.0.0", "metadata" => Dict("name" => name),
                "metaparameters" => Dict(
                    "n_rows" => Dict("type" => "integer", "default" => default)
                ),
                "index_sets" => Dict(axis => Dict("kind" => "interval", "size" => "n_rows")),
                "models" => Dict(
                    name => merge(
                        Dict{String, Any}(
                            "variables" => Dict(
                                "v" => Dict(
                                    "type" => "parameter", "units" => "1",
                                    "shape" => [axis], "default" => 0.0
                                )
                            ),
                            "equations" => Any[]
                        ),
                        sub === nothing ? Dict{String, Any}() :
                            Dict{String, Any}("subsystems" => Dict("Deep" => Dict("ref" => sub)))
                    )
                )
            )
        )
        docs = Dict(
            "https://example.org/lib/cat.esm" => JSON3.write(
                OrderedDict{String, Any}(
                    "esm" => "1.0.0", "metadata" => Dict("name" => "cat"),
                    "models" => Dict(
                        "Cat" => Dict(
                            "variables" => Dict(), "equations" => Any[],
                            "subsystems" => Dict("Outer" => Dict("ref" => "./deep/outer.esm"))
                        )
                    )
                )
            ),
            "https://example.org/lib/deep/outer.esm" => sized("Outer", "rows", 2, "../inner.esm"),
            "https://example.org/lib/inner.esm" => sized("Inner", "inner_rows", 10, nothing),
        )
        root = JSON3.write(
            OrderedDict{String, Any}(
                "esm" => "1.0.0", "metadata" => Dict("name" => "run"),
                "models" => Dict(
                    "Run" => Dict(
                        "variables" => Dict(), "equations" => Any[],
                        "subsystems" => Dict(
                            "Snap" => Dict(
                                "ref" => "https://example.org/lib/cat.esm",
                                "bindings" => Dict("n_rows" => 4)
                            )
                        )
                    )
                )
            )
        )
        old = EarthSciAST._URL_FETCHER[]
        EarthSciAST._URL_FETCHER[] = url -> haskey(docs, url) ? docs[url] :
            error("no such test URL: $url")
        try
            loaded = EarthSciAST.load_string(root; base_path = binder)
            @test loaded.index_sets["rows"].size == 4
            @test loaded.index_sets["inner_rows"].size == 10
        finally
            EarthSciAST._URL_FETCHER[] = old
        end
    end

    # `resolve_subsystem_refs!` called directly on a typed file that declares NO
    # `data_sources`: `EsmFile` is immutable, so the mounted leaf's sources reach
    # the caller only through the RETURNED file (esm-spec §4.7 "A mounted
    # document's data sources").
    _snap_edge() = EarthSciAST.SubsystemRef(
        "catalogue/catalogue.esm", Dict{String, Int}(), Any[], nothing,
        Dict{String, Any}("snapshot" => "b")
    )
    _outer(edge) = EarthSciAST.Model(
        Dict{String, EarthSciAST.ModelVariable}(), EarthSciAST.Equation[];
        subsystems = OrderedDict{String, EarthSciAST.SubsystemNode}("Snap" => edge)
    )
    @testset "resolve_subsystem_refs! returns the mounted data sources" begin
        file = EarthSciAST.EsmFile(
            "1.0.0", EarthSciAST.Metadata("no_sources");
            models = Dict{String, EarthSciAST.Model}("Outer" => _outer(_snap_edge()))
        )
        @test file.data_sources === nothing
        resolved = EarthSciAST.resolve_subsystem_refs!(file, binder)
        @test resolved isa EarthSciAST.EsmFile
        @test resolved.data_sources !== nothing
        @test resolved.data_sources["segment"].source.url_template == _expected(
            (; repo_path = "tests/conformance/url_substitutions/snapshots/b/t.parquet")
        )
        @test haskey(resolved.data_sources, "fixed")
        @test !(resolved.models["Outer"].subsystems["Snap"] isa EarthSciAST.SubsystemRef)

        # A file that DOES declare a registry gets them merged in place, and the
        # returned file is that same file; its own entry wins a clash.
        own = EarthSciAST.DataSource(
            "static", EarthSciAST.DataSourceLocation("file:///own/t.parquet")
        )
        file2 = EarthSciAST.EsmFile(
            "1.0.0", EarthSciAST.Metadata("own_sources");
            models = Dict{String, EarthSciAST.Model}("Outer" => _outer(_snap_edge())),
            data_sources = Dict{String, EarthSciAST.DataSource}("segment" => own)
        )
        @test EarthSciAST.resolve_subsystem_refs!(file2, binder) === file2
        @test file2.data_sources["segment"].source.url_template == "file:///own/t.parquet"
        @test haskey(file2.data_sources, "fixed")
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
