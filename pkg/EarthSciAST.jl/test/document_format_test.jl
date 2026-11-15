# The document source formats (CONFORMANCE_SPEC §5.58): the golden set in
# `tests/conformance/document_format/`, and the whole-corpus round trip.
#
# The fixture contract is the README of that directory:
#
# * `print`: `print(esm) == text` byte for byte and `parse(text) == esm` as a
#   JSON value, in both formats (and `canonicalize(written) == esm` when the
#   case is about the canonical form);
# * `variant`: `parse(surface, input) == esm` and `print(surface, esm) == canonical`;
# * `refusal`: `parse(surface, input)` fails with the diagnostic code `error`.
#
# `limits.json` (README, section Limits) holds the bounds of the readers: each
# case's text is built from its recipe and must read as `esm_json` or be
# refused with the code `error`, without exhausting the stack.
#
# The corpus round trip is computed here from the corpus itself, never stored:
# every `.esm` under `tests/` that is a JSON object (the corpus of
# `formal/scripts/doc-corpus.py`), canonicalized, printed in each format and
# read back, must give its canonical form again.
#
# With `ESM_LEAN` naming a built `esm-lean` (formal/.lake/build/bin/esm-lean),
# the corpus is also checked against the Lean model: the canonical forms, the
# printed texts, and what the readers make of the Lean-printed texts. A self
# round trip alone cannot see a printer and a reader that drift together.
# `ESM_LEAN_SCRATCH` names the directory for its files (default: a temporary
# directory).

using Test
using JSON
using EarthSciAST
include("testutils.jl")

const DOCFMT_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "document_format")
const DOCFMT_FILES = (
    "operators.json", "names.json", "variants.json", "documents.json", "units.json",
    "refusals.json",
)

# JSON values compared as JSON: objects by key regardless of order, numbers by
# type and value (`2` and `2.0` differ), `true` never equal to `1`.
_docfmt_jeq(a::AbstractDict, b::AbstractDict) =
    length(a) == length(b) && all(pairs(a)) do (k, v)
    key = String(k)
    found = false
    for (k2, v2) in pairs(b)
        if String(k2) == key
            found = _docfmt_jeq(v, v2)
            break
        end
    end
    found
end
_docfmt_jeq(a::AbstractVector, b::AbstractVector) =
    length(a) == length(b) && all(_docfmt_jeq(x, y) for (x, y) in zip(a, b))
_docfmt_jeq(a::Bool, b::Bool) = a == b
_docfmt_jeq(a::Integer, b::Integer) = !(a isa Bool) && !(b isa Bool) && a == b
_docfmt_jeq(a::AbstractFloat, b::AbstractFloat) = a == b
_docfmt_jeq(a::AbstractString, b::AbstractString) = a == b
_docfmt_jeq(::Nothing, ::Nothing) = true
_docfmt_jeq(a, b) = false

_docfmt_format(name) = name == "markdown" ? :markdown :
    name == "typst" ? :typst : error("unknown surface $name")

# Run one case; the failures, as messages.
function _docfmt_case(case)
    id = String(case["id"])
    out = String[]
    check(ok, what) = ok || push!(out, "$id: $what")
    kind = String(case["kind"])
    if kind == "print"
        esm = case["esm"]
        if haskey(case, "written")
            check(
                _docfmt_jeq(canonicalize_document(case["written"]), esm),
                "canonicalize(written) != esm"
            )
        end
        for (key, format) in (("markdown", :markdown), ("typst", :typst))
            text = String(case[key])
            printed = print_document(esm, format)
            check(printed == text, "print $key differs:\n--- got\n$printed\n--- want\n$text")
            try
                back = parse_document(text, format)
                check(_docfmt_jeq(back, esm), "parse $key differs:\n--- got\n$(JSON.json(back))")
            catch e
                check(false, "parse $key refused: $(sprint(showerror, e))")
            end
        end
    elseif kind == "variant"
        format = _docfmt_format(String(case["surface"]))
        esm = case["esm"]
        try
            back = parse_document(String(case["input"]), format)
            check(_docfmt_jeq(back, esm), "parse differs:\n--- got\n$(JSON.json(back))")
        catch e
            check(false, "parse refused: $(sprint(showerror, e))")
        end
        canonical = String(case["canonical"])
        printed = print_document(esm, format)
        check(printed == canonical, "print differs:\n--- got\n$printed\n--- want\n$canonical")
    elseif kind == "refusal"
        format = _docfmt_format(String(case["surface"]))
        want = String(case["error"])
        try
            v = parse_document(String(case["input"]), format)
            check(false, "expected `$want`, read $(JSON.json(v))")
        catch e
            check(e isa EarthSciAST.ParseError && e.code == want, "expected `$want`, got $(sprint(showerror, e))")
        end
    else
        error("$id: unknown kind $kind")
    end
    return out
end

# The text of a `limits.json` case, built from its recipe (README, section
# Limits).
function _docfmt_limit_input(heads, case)
    input = case["input"]
    head = String(heads[String(case["surface"])])
    if haskey(input, "yaml_levels")
        io = IOBuffer()
        print(io, head, "```esm:metaparameters\nx:\n")
        for i in 1:(Int(input["yaml_levels"]) - 1)
            print(io, " "^(2i), "-\n")
        end
        print(io, "```\n")
        return String(take!(io))
    end
    field(k) = String(get(input, k, ""))
    n = Int(get(input, "n", 0))
    return head * field("prefix") * field("open")^n * field("middle") * field("close")^n *
        field("suffix")
end

# Run one `limits.json` case; the failure, as a message, or `nothing`.
function _docfmt_limit_case(heads, case)
    id = String(case["id"])
    format = _docfmt_format(String(case["surface"]))
    text = _docfmt_limit_input(heads, case)
    got = try
        parse_document(text, format)
    catch e
        e
    end
    if haskey(case, "esm_json")
        want = JSON.parse(String(case["esm_json"]))
        got isa Exception && return "$id: refused: $(sprint(showerror, got))"
        return _docfmt_jeq(got, want) ? nothing : "$id: read differently:\n$(JSON.json(got))"
    end
    code = String(case["error"])
    got isa EarthSciAST.ParseError && got.code == code && return nothing
    return got isa Exception ? "$id: expected `$code`, got $(sprint(showerror, got))" :
        "$id: expected `$code`, read $(JSON.json(got))"
end

# The `.esm` files under `tests/` that are JSON objects, the corpus
# `formal/scripts/doc-corpus.py` reads: (path, decoded document) pairs.
function _docfmt_corpus()
    docs = Tuple{String, Any}[]
    root = joinpath(TESTUTILS_REPO_ROOT, "tests")
    for (dir, _, files) in walkdir(root)
        for f in files
            endswith(f, ".esm") || continue
            path = joinpath(dir, f)
            doc = try
                JSON.parse(read(path, String))
            catch
                continue
            end
            doc isa AbstractDict && push!(docs, (path, doc))
        end
    end
    sort!(docs; by = first)
    return docs
end

@testset "document source formats (CONFORMANCE §5.58)" begin
    @testset "golden set: $file" for file in DOCFMT_FILES
        fixture = JSON.parse(read(joinpath(DOCFMT_DIR, file), String))
        failures = String[]
        for case in fixture["cases"]
            append!(failures, _docfmt_case(case))
        end
        isempty(failures) || @info "document_format/$file failures" n = length(failures) first =
            join(first(failures, 5), "\n\n")
        @test isempty(failures)
        @test !isempty(fixture["cases"])
    end

    # The `math` field of a case is the math of the case's one equation display,
    # so `print_math` of that equation under the names its model declares (the
    # keys of its variables, species and parameters, and the document's index
    # sets) gives it in both formats. A case whose model or document declares
    # expression templates is skipped: no template is in scope for `print_math`.
    @testset "print_math reproduces the math of a display" begin
        failures = String[]
        checked = skipped = 0
        for file in DOCFMT_FILES
            fixture = JSON.parse(read(joinpath(DOCFMT_DIR, file), String))
            for case in fixture["cases"]
                haskey(case, "math") || continue
                id = String(case["id"])
                esm = case["esm"]
                models = get(esm, "models", Dict())
                @test length(models) == 1
                model = first(values(models))
                if haskey(model, "expression_templates") || haskey(esm, "expression_templates")
                    skipped += 1
                    continue
                end
                eqs = model["equations"]
                @test length(eqs) == 1
                names = String[]
                for field in ("variables", "species", "parameters")
                    append!(names, String.(collect(keys(get(model, field, Dict())))))
                end
                append!(names, String.(collect(keys(get(esm, "index_sets", Dict())))))
                for (key, format) in (("latex", :markdown), ("typst", :typst))
                    got = print_math(eqs[1], names, format)
                    want = String(case["math"][key])
                    got == want || push!(failures, "$id: print_math $key = $(repr(got)), want $(repr(want))")
                end
                checked += 1
            end
        end
        @info "print_math: $checked math cases checked, $skipped skipped (a template in scope)"
        isempty(failures) || @info "print_math failures" n = length(failures) first =
            join(first(failures, 5), "\n")
        @test isempty(failures)
        @test checked > 0
        @test_throws ArgumentError print_math("x", String[], :latex)
    end

    @testset "reader limits (limits.json)" begin
        limits = JSON.parsefile(joinpath(DOCFMT_DIR, "limits.json"))
        cases = limits["cases"]
        @test length(cases) > 30
        failures = String[]
        for case in cases
            msg = _docfmt_limit_case(limits["heads"], case)
            msg === nothing || push!(failures, msg)
        end
        isempty(failures) || @info "limits.json failures" count = length(failures) first =
            join(first(failures, 10), "\n")
        @test isempty(failures)
    end

    @testset "format selector" begin
        doc = Dict("esm" => "2.3.0", "metadata" => Dict("name" => "x"))
        @test print_document(doc, :markdown) == print_markdown(doc)
        @test print_document(doc, :typst) == print_typst(doc)
        @test_throws ArgumentError print_document(doc, :latex)
        @test_throws ArgumentError parse_document("", :latex)
        err = try
            parse_markdown("not a document")
        catch e
            e
        end
        @test err isa EarthSciAST.ParseError && err.code == ERROR_CODES.PARSE_ERROR
    end

    @testset "invalid UTF-8" begin
        bad = "fix\xffture"
        @test !isvalid(bad)
        doc = Dict("esm" => "2.3.0", "metadata" => Dict("name" => "fixture"))
        for format in (:markdown, :typst)
            text = print_document(doc, format)
            @test occursin("fixture", text)
            err = try
                parse_document(replace(text, "fixture" => bad), format)
            catch e
                e
            end
            @test err isa EarthSciAST.ParseError && err.code == ERROR_CODES.PARSE_ERROR
            bad_doc = Dict("esm" => "2.3.0", "metadata" => Dict("name" => bad))
            @test_throws ArgumentError print_document(bad_doc, format)
            bad_key = Dict("esm" => "2.3.0", "metadata" => Dict("name" => "x", "attrs" => Dict(bad => 1)))
            @test_throws ArgumentError print_document(bad_key, format)
        end
        @test_throws ArgumentError print_math(bad, String[], :markdown)
    end

    corpus = _docfmt_corpus()

    @testset "whole-corpus round trip" begin
        @test length(corpus) > 100
        failures = String[]
        for (path, doc) in corpus
            canon = canonicalize_document(doc)
            for format in (:markdown, :typst)
                what = try
                    back = parse_document(print_document(canon, format), format)
                    _docfmt_jeq(back, canon) ? nothing : "reads back differently"
                catch e
                    e isa EarthSciAST.ParseError ? "does not read back" :
                        "throws $(sprint(showerror, e))"
                end
                what === nothing || push!(failures, "$path ($format): $what")
            end
        end
        @info "corpus round trip" documents = length(corpus) failures = length(failures) first =
            join(first(failures, 20), "\n")
        @test isempty(failures)
    end

    lean = get(ENV, "ESM_LEAN", "")
    if !isempty(lean)
        @testset "agreement with the Lean model (esm-lean)" begin
            scratch = get(ENV, "ESM_LEAN_SCRATCH", "")
            scratch = isempty(scratch) ? mktempdir() : mkpath(scratch)
            run_lean(mode, path) = try
                read(pipeline(`$lean $mode $path`; stderr = devnull), String)
            catch
                nothing
            end
            results = asyncmap(enumerate(corpus); ntasks = 8) do (i, (path, doc))
                diffs = String[]
                stem = joinpath(scratch, string(i))
                lean_canon = run_lean("canon", path)
                if lean_canon === nothing
                    return ["$path: esm-lean canon refused"]
                end
                canon_path = stem * ".canon.json"
                write(canon_path, lean_canon)
                canon = canonicalize_document(doc)
                if !_docfmt_jeq(JSON.parse(lean_canon), canon)
                    return ["$path: canonical forms differ"]
                end
                for (format, pmode, rmode, ext) in (
                        (:markdown, "print-md", "parse-md", ".md"),
                        (:typst, "print-typ", "parse-typ", ".typ"),
                    )
                    lean_text = run_lean(pmode, canon_path)
                    if lean_text === nothing
                        push!(diffs, "$path: esm-lean $pmode refused")
                        continue
                    end
                    ours = try
                        print_document(canon, format)
                    catch
                        nothing
                    end
                    ours == lean_text || push!(diffs, "$path: $pmode differs")
                    text_path = stem * ext
                    write(text_path, lean_text)
                    lean_back = run_lean(rmode, text_path)
                    our_back = try
                        parse_document(lean_text, format)
                    catch
                        nothing
                    end
                    agree = if lean_back === nothing || our_back === nothing
                        lean_back === our_back
                    else
                        _docfmt_jeq(JSON.parse(lean_back), our_back)
                    end
                    agree || push!(diffs, "$path: $rmode differs")
                end
                return diffs
            end
            diffs = reduce(vcat, results; init = String[])
            write(joinpath(scratch, "differences.txt"), join(diffs, "\n"))
            @info "esm-lean comparison" documents = length(corpus) differences = length(diffs) first =
                join(first(diffs, 20), "\n")
            @test isempty(diffs)
        end
    end
end
