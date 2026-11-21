# Tests for esm-spec §1.2.1: a document read from a path or a URL is read in
# the format its extension names (`.md` Markdown, `.typ` Typst, anything else
# JSON), at the root and at every ref site. Drives the cross-binding fixtures
# under tests/conformance/source_documents/.

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

_srcdoc_errcode(f) =
try
    f()
    nothing
catch e
    hasproperty(e, :code) ? String(e.code) : sprint(showerror, e)
end

# Every string value of a `ref` key replaced by one placeholder: the authored
# ref round-trips verbatim, so the spelling is the one expected difference.
_srcdoc_mask_refs(x::AbstractDict) = Dict{String, Any}(
    String(k) => (String(k) == "ref" && v isa AbstractString ? "<ref>" : _srcdoc_mask_refs(v))
        for (k, v) in x
)
_srcdoc_mask_refs(x::AbstractVector) = Any[_srcdoc_mask_refs(v) for v in x]
_srcdoc_mask_refs(x) = x

_srcdoc_doc(path) = _srcdoc_mask_refs(
    JSON3.read(JSON3.write(EarthSciAST.serialize_esm_file(load_path(path))), Dict{String, Any})
)

@testset "source documents loaded from files (esm-spec §1.2.1)" begin
    root = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "source_documents")
    manifest = JSON3.read(read(joinpath(root, "manifest.json"), String))

    @testset "conformance case $(c.id)" for c in manifest.cases
        fixture = joinpath(root, c.fixture)
        run = c.driver == "flatten" ? (() -> flatten(load_path(fixture))) :
            (() -> load_path(fixture))
        if c.expect == "same_as_twin"
            @test _srcdoc_doc(fixture) == _srcdoc_doc(joinpath(root, c.twin))
        elseif c.expect == "ok"
            @test _srcdoc_errcode(run) === nothing
        else
            @test _srcdoc_errcode(run) == c.code
        end
    end

    @testset "the format is the extension of a URL's path" begin
        md = read(joinpath(root, "leaf.md"), String)
        json = read(joinpath(root, "twins", "leaf.esm"), String)
        read_as(loc, text) = EarthSciAST._parse_document_text(text, loc)
        @test read_as("https://example.com/lib/leaf.md?v=1#top", md) == parse_markdown(md)
        @test read_as("https://example.com/lib/leaf.esm?f=x.md", json) isa JSON3.Object
        @test read_as("https://example.com/lib/leaf.esm#x.typ", json) isa JSON3.Object
        # Exact, case-sensitive suffix: `.MD` is JSON.
        @test _srcdoc_errcode(() -> read_as("/x/leaf.MD", md)) !== nothing
        @test read_as("/x/leaf.MD", json) isa JSON3.Object
    end
end
