# Tests for esm-spec §4.7 standard-library refs: `esm:std/<file>.esm` resolves
# to the package's bundled copy of lib/ (pkg/EarthSciAST.jl/data/lib/). Drives
# the cross-binding fixtures under tests/conformance/stdlib_refs/, then checks
# the bundle-internal rules against a substitute bundle.

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

# Run `f` with the environment variables in `env` set, restoring them after.
function _with_env(f, env)
    old = Dict(k => get(ENV, k, nothing) for k in keys(env))
    try
        for (k, v) in env
            ENV[k] = v
        end
        return f()
    finally
        for (k, v) in old
            v === nothing ? delete!(ENV, k) : (ENV[k] = v)
        end
    end
end

_stdref_errcode(f) =
try
    f()
    nothing
catch e
    hasproperty(e, :code) ? String(e.code) : sprint(showerror, e)
end

# Every string value of a `ref` key replaced by one placeholder: the authored
# ref round-trips verbatim, so the spelling is the one expected difference.
_mask_refs(x::AbstractDict) = Dict{String, Any}(
    String(k) => (String(k) == "ref" && v isa AbstractString ? "<ref>" : _mask_refs(v))
        for (k, v) in x
)
_mask_refs(x::AbstractVector) = Any[_mask_refs(v) for v in x]
_mask_refs(x) = x

# The loaded form keeps template references (esm-spec §9.6.4 Option B); this
# expands them, so a test can see the imported template was resolved.
# Only the equations: the emitted template registry keeps its own references.
function _stdref_expanded_json(file)
    doc = EarthSciAST.serialize_esm_file(EarthSciAST._expand_refs!(deepcopy(file)))
    eqs(m) = Any[get(m, "equations", Any[]); [eqs(s) for s in values(get(m, "subsystems", Dict()))]...]
    return JSON3.write(Any[eqs(m) for m in values(doc["models"])])
end

_stdref_doc(path) =
    _mask_refs(JSON3.read(JSON3.write(EarthSciAST.serialize_esm_file(load_path(path))), Dict{String, Any}))

@testset "standard-library refs (esm-spec §4.7)" begin
    root = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "stdlib_refs")
    manifest = JSON3.read(read(joinpath(root, "manifest.json"), String))

    @testset "bundle matches lib/" begin
        lib = joinpath(TESTUTILS_REPO_ROOT, "lib")
        names = sort(filter(endswith(".esm"), readdir(lib)))
        bundle = EarthSciAST._STDLIB_DIR[]
        @test sort(filter(endswith(".esm"), readdir(bundle))) == names
        for n in names
            @test read(joinpath(bundle, n), String) == read(joinpath(lib, n), String)
        end
    end

    @testset "the bundle is located when the package loads" begin
        # A relocated depot or system image moves the bundle: `__init__`
        # re-derives the directory from where the package is loaded.
        saved = EarthSciAST._STDLIB_DIR[]
        try
            EarthSciAST._STDLIB_DIR[] = joinpath(tempdir(), "moved-depot", "lib")
            EarthSciAST.__init__()
            @test EarthSciAST._STDLIB_DIR[] == joinpath(pkgdir(EarthSciAST), "data", "lib")
            path = EarthSciAST._expand_ref_env("esm:std/interp.esm")
            @test isfile(path) && EarthSciAST._is_bundled_path(path)
        finally
            EarthSciAST._STDLIB_DIR[] = saved
        end
    end

    @testset "conformance case $(c.id)" for c in manifest.cases
        env = Dict{String, String}(String(k) => String(v) for (k, v) in get(c, :env, Dict()))
        fixture = joinpath(root, c.fixture)
        _with_env(env) do
            if c.expect == "same_as_twin"
                @test _stdref_doc(fixture) == _stdref_doc(joinpath(root, c.twin))
            else
                run = c.driver == "flatten" ? (() -> flatten(load_path(fixture))) :
                    (() -> load_path(fixture))
                @test _stdref_errcode(run) == c.code
            end
        end
    end

    @testset "a document loaded from a string reaches the bundle" begin
        text = read(joinpath(root, "import_interp.esm"), String)
        file = load_string(text)
        @test !occursin("apply_expression_template", _stdref_expanded_json(file))
    end

    @testset "spelling rules" begin
        bundle = EarthSciAST._STDLIB_DIR[]
        @test EarthSciAST._expand_ref_env("esm:std/interp.esm") == joinpath(bundle, "interp.esm")
        @test EarthSciAST._expand_ref_env("esm:std/./interp.esm") == joinpath(bundle, "interp.esm")
        for bad in (
                "esm:std/nope.esm", "esm:std/../lib/interp.esm", "esm:std/sub/interp.esm",
                "esm:other/interp.esm", "esm:interp.esm", "esm:std/interp",
            )
            @test !isfile(EarthSciAST._expand_ref_env(bad))
        end
        # Plain refs are untouched: `${VAR}` still expands, URLs pass through.
        _with_env(Dict("ESM_STDLIB_UNIT_DIR" => "/x/y")) do
            @test EarthSciAST._expand_ref_env("\${ESM_STDLIB_UNIT_DIR}/a.esm") == "/x/y/a.esm"
            @test EarthSciAST._expand_ref_env("esm:std/\${ESM_STDLIB_UNIT_DIR}") ==
                joinpath(bundle, "unresolved", "esm:std%2F\${ESM_STDLIB_UNIT_DIR}")
        end
        @test EarthSciAST._expand_ref_env("https://example.com/a.esm") == "https://example.com/a.esm"
        @test EarthSciAST._expand_ref_env("./a.esm", "/somewhere") == "./a.esm"
        # A std ref is never URL-joined against a URL-loaded document's base.
        @test EarthSciAST._canonical_ref(
            EarthSciAST._expand_ref_env("esm:std/interp.esm", "https://example.com/m"),
            "https://example.com/m"
        ) == joinpath(bundle, "interp.esm")
    end

    @testset "refs inside a bundled file resolve among the bundled files" begin
        twice = Dict(
            "params" => ["x"],
            "body" => Dict("op" => "*", "args" => Any[2, "x"])
        )
        quad(name) = Dict(
            "params" => ["x"],
            "body" => Dict(
                "op" => "apply_expression_template", "args" => Any[], "name" => "twice",
                "bindings" => Dict(
                    "x" => Dict(
                        "op" => "apply_expression_template", "args" => Any[],
                        "name" => "twice", "bindings" => Dict("x" => "x")
                    )
                )
            )
        )
        lib(name, imports, templates) = Dict(
            "esm" => "1.1.0", "metadata" => Dict("name" => name),
            "expression_template_imports" => [Dict("ref" => r) for r in imports],
            "expression_templates" => templates
        )
        bundle_files = Dict(
            "b.esm" => Dict(
                "esm" => "1.1.0", "metadata" => Dict("name" => "b"),
                "expression_templates" => Dict("twice" => twice)
            ),
            "a.esm" => lib("a", ["b.esm"], Dict("quad" => quad("a"))),
            "a_dot.esm" => lib("a_dot", ["./b.esm"], Dict("quad" => quad("a_dot"))),
            "a_std.esm" => lib("a_std", ["esm:std/b.esm"], Dict("quad" => quad("a_std"))),
            "up.esm" => lib("up", ["../b.esm"], Dict("quad" => quad("up"))),
            "c1.esm" => lib("c1", ["esm:std/c2.esm"], Dict("one" => Dict("params" => [], "body" => 1))),
            "c2.esm" => lib("c2", ["c1.esm"], Dict("two" => Dict("params" => [], "body" => 2))),
            "sub.esm" => Dict(
                "esm" => "1.1.0", "metadata" => Dict("name" => "sub"),
                "models" => Dict(
                    "Sub" => Dict(
                        "expression_template_imports" => [Dict("ref" => "b.esm")],
                        "variables" => Dict(
                            "u" => Dict("type" => "parameter", "units" => "1", "default" => 3.0),
                            "w" => Dict("type" => "unknown", "units" => "1")
                        ),
                        "equations" => [
                            Dict(
                                "lhs" => "w", "rhs" => Dict(
                                    "op" => "apply_expression_template", "args" => Any[],
                                    "name" => "twice", "bindings" => Dict("x" => "u")
                                )
                            ),
                        ]
                    )
                )
            )
        )
        consumer(ref, tmpl) = JSON3.write(
            Dict(
                "esm" => "1.1.0", "metadata" => Dict("name" => "consumer"),
                "models" => Dict(
                    "M" => Dict(
                        "expression_template_imports" => [Dict("ref" => ref)],
                        "variables" => Dict(
                            "x" => Dict("type" => "parameter", "units" => "1", "default" => 1.0),
                            "y" => Dict("type" => "unknown", "units" => "1")
                        ),
                        "equations" => [
                            Dict(
                                "lhs" => "y", "rhs" => Dict(
                                    "op" => "apply_expression_template", "args" => Any[],
                                    "name" => tmpl, "bindings" => Dict("x" => "x")
                                )
                            ),
                        ]
                    )
                )
            )
        )
        mktempdir() do dir
            bundle = joinpath(dir, "lib")
            mkpath(bundle)
            # A sibling of the bundle directory, which `../b.esm` would reach as a path.
            write(joinpath(dir, "b.esm"), JSON3.write(bundle_files["b.esm"]))
            for (n, d) in bundle_files
                write(joinpath(bundle, n), JSON3.write(d))
            end
            elsewhere = joinpath(dir, "elsewhere")
            mkpath(elsewhere)
            saved = EarthSciAST._STDLIB_DIR[]
            EarthSciAST._STDLIB_DIR[] = bundle
            try
                for lib_name in ("a", "a_dot", "a_std")
                    f = load_string(consumer("esm:std/$(lib_name).esm", "quad"); base_path = elsewhere)
                    @test !occursin("apply_expression_template", _stdref_expanded_json(f))
                end
                @test _stdref_errcode(
                    () -> load_string(consumer("esm:std/up.esm", "quad"); base_path = elsewhere)
                ) == "template_import_unresolved"
                @test _stdref_errcode(
                    () -> load_string(consumer("esm:std/c1.esm", "one"); base_path = elsewhere)
                ) == "template_import_cycle"
                mount = JSON3.write(
                    Dict(
                        "esm" => "1.1.0", "metadata" => Dict("name" => "mount"),
                        "models" => Dict(
                            "Top" => Dict(
                                "subsystems" => Dict("S" => Dict("ref" => "esm:std/sub.esm")),
                                "variables" => Dict("z" => Dict("type" => "unknown", "units" => "1")),
                                "equations" => [Dict("lhs" => "z", "rhs" => "S.w")]
                            )
                        )
                    )
                )
                f = load_string(mount; base_path = elsewhere)
                @test haskey(f.models["Top"].subsystems, "S")
                @test !occursin("apply_expression_template", _stdref_expanded_json(f))
            finally
                EarthSciAST._STDLIB_DIR[] = saved
            end
        end
    end
end
