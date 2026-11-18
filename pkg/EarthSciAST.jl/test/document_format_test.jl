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
                    # ... and `parse_math`, its inverse, reads the math back to
                    # the equation in canonical form.
                    eq = canonicalize_document(eqs[1])
                    try
                        read = parse_math(want, names, format)
                        _docfmt_jeq(read, eq) ||
                            push!(failures, "$id: parse_math $key = $(repr(read)), want $(repr(eq))")
                    catch e
                        e isa ParseError || rethrow()
                        push!(failures, "$id: parse_math $key refused: $(e.message)")
                    end
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

    @testset "parse_math reads an expression or an equation" begin
        names = ["RT", "k", "y"]
        e = parse_math("RT + k", names, :markdown)
        @test _docfmt_jeq(e, Dict("op" => "+", "args" => Any["RT", "k"]))
        # With its letters declared instead, a run of letters in LaTeX is their
        # product; with neither, it is not read.
        e = parse_math("RT", ["R", "T"], :markdown)
        @test _docfmt_jeq(e, Dict("op" => "*", "args" => Any["R", "T"]))
        @test_throws ParseError parse_math("RT", String[], :markdown)
        e = parse_math("y = 2 k", names, :typst)
        @test _docfmt_jeq(
            e, Dict("lhs" => "y", "rhs" => Dict("op" => "*", "args" => Any[2, "k"]))
        )
        for (text, format) in (("y = k", :markdown), ("(dif y)/(dif t) = -k y", :typst))
            @test print_math(parse_math(text, names, format), names, format) == text
        end
        @test expression_names(Dict("lhs" => "y", "rhs" => Dict("op" => "*", "args" => Any["k", "y"]))) ==
            ["y", "k"]
        @test_throws ArgumentError parse_math("k", ["k"], :latex)
    end

    @testset "parse_math refuses as a document read does" begin
        code(f) = try
            f()
            nothing
        catch e
            e isa ParseError || rethrow()
            e.code
        end
        names = ["k"]
        @test code(() -> parse_math("k +", names, :markdown)) == "parse_error"
        @test code(() -> parse_math("1.0e400 k", names, :typst)) == "parse_error"
        @test code(() -> parse_math("\\operatorname{arrayop}(k)", names, :markdown)) == "removed_op"
        deep = "("^50_000 * "k" * ")"^50_000
        @test code(() -> parse_math(deep, names, :typst)) == "parse_error"
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

    # Array notation: each spelling reads back only as the printer writes it.
    @testset "array notation: canonical-only reads" begin
        DF = EarthSciAST.DocumentFormats
        DJ = DF.DJson
        DM = DF.DMath
        NoT = Tuple{String, Vector{String}}[]
        dj(x) = DJ.sort_keys(DJ.from_value(x))
        sym(names, ts = NoT) = DF.MExpr.Sym(String.(names), ts)
        function rd(sf, s, text)
            j = DF.DLimits.reading() do
                sf === :latex ? DM.parse_latex(s, text) : DM.parse_typst(s, text)
            end[1]
            return j === nothing ? nothing : DJ.to_value(j)
        end
        pr(sf, s, e) = sf === :latex ? DM.print_latex(s, dj(e)) : DM.print_typst(s, dj(e))
        reads(sf, s, text, e) = (r = rd(sf, s, text); r !== nothing && _docfmt_jeq(r, e))
        round_trips(s, e) = all(sf -> reads(sf, s, pr(sf, s, e), e), (:latex, :typst))
        idx(a, is...) = Dict("op" => "index", "args" => Any[a, is...])
        S = sym(["x", "f", "g", "i", "j", "a", "b", "delim", "augment", "t"])

        # A `\limits` reduction's `args` are its body's arrays: a superscript
        # set on it is refused, on the operator or on the output bracket.
        withset = Dict(
            "op" => "faq", "args" => Any["f"], "expr" => idx("x", "i"),
            "output_idx" => Any[], "ranges" => Dict("i" => Any[1, 3]),
        )
        @test pr(:latex, S, withset) == "\\sum_{1 \\le i \\le 3}^{\\{f\\}} x_{i}"
        @test round_trips(S, withset)
        @test rd(:latex, S, "\\sum\\limits_{1 \\le i \\le 3}^{\\{f\\}} x_{i}") === nothing
        @test rd(:typst, S, "limits(sum)_(1 <= i <= 3)^({f}) x_i") === nothing
        @test rd(:latex, S, "\\left[\\sum\\limits_{j = 1}^{3} x_{i, j}\\right]^{\\{f\\}}_{i}") === nothing
        @test rd(:typst, S, "lr([limits(sum)_(1 <= j <= 3) x_(i, j)])^({f})_(i)") === nothing

        # A wrapped reduction carries its set on the bracket only.
        out = Dict(
            "op" => "faq", "args" => Any["f"], "expr" => idx("x", "i", "j"),
            "output_idx" => Any["i"], "ranges" => Dict("j" => Any[1, 3]),
        )
        @test pr(:latex, S, out) == "\\left[\\sum_{1 \\le j \\le 3} x_{i, j}\\right]^{\\{f\\}}_{i}"
        @test pr(:typst, S, out) == "lr([sum_(1 <= j <= 3) x_(i, j)])^({f})_(i)"
        @test round_trips(S, out)
        @test rd(:latex, S, "\\left[\\sum_{1 \\le j \\le 3}^{\\{f\\}} x_{i, j}\\right]_{i}") === nothing
        @test rd(:latex, S, "\\left[\\sum_{1 \\le j \\le 3}^{\\{g\\}} x_{i, j}\\right]^{\\{f\\}}_{i}") === nothing
        @test rd(:typst, S, "lr([sum_(1 <= j <= 3)^({f}) x_(i, j)])_(i)") === nothing
        @test rd(:typst, S, "lr([sum_(1 <= j <= 3)^({g}) x_(i, j)])^({f})_(i)") === nothing

        # `delim` and `augment` are words: names everywhere but the head of a
        # makearray table.
        @test reads(:typst, S, "delim + 1", Dict("op" => "+", "args" => Any["delim", 1]))
        @test reads(:typst, S, "augment", "augment")
        @test reads(
            :typst, S, "(dif augment)/(dif t)",
            Dict("op" => "D", "args" => Any["augment"], "wrt" => "t"),
        )
        mk = Dict(
            "op" => "makearray", "args" => Any[], "regions" => Any[Any[Any[1, 2], Any[3, 4]]],
            "values" => Any["a"],
        )
        @test pr(:latex, S, mk) ==
            "\\left[\\begin{array}{l|l} a & [1, 2] \\times [3, 4] \\end{array}\\right]"
        @test pr(:typst, S, mk) == "mat(delim: \"[\", augment: #1, a, [1, 2] times [3, 4])"
        @test round_trips(S, mk)
        mk3 = Dict(
            "op" => "makearray", "args" => Any[],
            "regions" => Any[Any[Any[1, 2], Any["a", "b"], Any[0, 5]]], "values" => Any["x"],
        )
        @test round_trips(S, mk3)

        # `\times [` outside a region is a product with a bracketed operand.
        prod_ab = Dict("op" => "*", "args" => Any["a", "b"])
        @test reads(:latex, S, "a \\times [b]", prod_ab)
        @test reads(:typst, S, "a times [b]", prod_ab)

        # The `;` call form reads only a node the printer writes that way.
        ann = Dict("op" => "myop", "args" => Any["x"], "id" => "n1", "shape" => Any[2])
        for sf in (:latex, :typst)
            text = pr(sf, S, ann)
            # an open operator keeps its annotation fields in the call form
            @test occursin(sf === :latex ? "\\operatorname{myop}(x;" : "op(\"myop\")(x;", text)
            @test reads(sf, S, text, ann)
            # a core operator with one is written in the escape form instead
            @test rd(sf, S, replace(text, "myop" => "reshape")) === nothing
        end
        nat = Dict("op" => "myconst", "args" => Any[], "value" => Any[1, 2])
        for sf in (:latex, :typst)
            # a const with a native spelling is refused in the call form
            @test rd(sf, S, replace(pr(sf, S, nat), "myconst" => "const")) === nothing
        end
        empty_const = Dict("op" => "const", "args" => Any[], "value" => Any[])
        @test occursin("\\operatorname{const}", pr(:latex, S, empty_const))
        @test round_trips(S, empty_const)
        @test rd(:latex, S, "\\operatorname{myop}(x; \\mathrm{k} = 1, \\mathrm{k} = 2)") === nothing
        @test rd(:latex, S, "\\operatorname{myop}(x; \\mathrm{op} = 1)") === nothing
        @test rd(:latex, S, "\\operatorname{myop}(x; \\mathrm{args} = 1)") === nothing
        @test reads(
            :latex, S, "\\operatorname{myop}(x; \\mathrm{k} = 1)",
            Dict("op" => "myop", "args" => Any["x"], "k" => 1),
        )

        # A bare `\operatorname{n}` is a template applied with no bindings,
        # except for a template in scope with no parameters (printed `n()`).
        tpl(n) = Dict("op" => "apply_expression_template", "args" => Any[], "name" => n, "bindings" => Dict())
        T = sym(["x"], [("g0", String[]), ("h1", ["p"])])
        @test pr(:latex, T, tpl("g0")) == "\\operatorname{g0}()"
        @test round_trips(T, tpl("g0"))
        @test rd(:latex, T, "\\operatorname{g0}") === nothing
        @test rd(:latex, T, "\\operatorname{g0} + x") === nothing
        @test rd(:typst, T, "op(\"g0\")") === nothing
        @test pr(:latex, T, tpl("h1")) == "\\operatorname{h1}"
        @test round_trips(T, tpl("h1"))
        @test pr(:latex, T, tpl("out")) == "\\operatorname{out}"
        @test round_trips(T, tpl("out"))
        @test reads(:latex, T, "\\operatorname{out} + x", Dict("op" => "+", "args" => Any[tpl("out"), "x"]))

        # A matrix wider than `bmatrix` allows is an `array` with one `c` per
        # column; only that spelling reads it back.
        wide = Dict("op" => "const", "args" => Any[], "value" => Any[collect(1:11), collect(12:22)])
        @test pr(:latex, S, wide) ==
            "\\left[\\begin{array}{ccccccccccc}1 & 2 & 3 & 4 & 5 & 6 & 7 & 8 & 9 & 10 & 11 \\\\ " *
            "12 & 13 & 14 & 15 & 16 & 17 & 18 & 19 & 20 & 21 & 22 \\end{array}\\right]"
        @test pr(:typst, S, wide) ==
            "mat(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11; 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22)"
        @test round_trips(S, wide)
        narrow = Dict("op" => "const", "args" => Any[], "value" => Any[collect(1:10), collect(11:20)])
        @test startswith(pr(:latex, S, narrow), "\\begin{bmatrix}")
        @test round_trips(S, narrow)
        col = Dict("op" => "const", "args" => Any[], "value" => collect(1:12))
        @test startswith(pr(:latex, S, col), "\\begin{bmatrix}")
        @test round_trips(S, col)
        row11 = join(1:11, " & ")
        row10 = join(1:10, " & ")
        @test rd(:latex, S, "\\begin{bmatrix}$row11 \\\\ $row11\\end{bmatrix}") === nothing
        @test rd(:latex, S, "\\left[\\begin{array}{ccccccccccc}$row10 \\\\ $row10 \\end{array}\\right]") === nothing
        @test rd(:latex, S, "\\left[\\begin{array}{cccccccccc}$row10 \\\\ $row10 \\end{array}\\right]") === nothing
        @test rd(:latex, S, "\\left[\\begin{array}{ccccccccccc}$row11 \\\\ $row11 \\end{array}\\right]") !== nothing

        # One list of annotation fields, shared with metaparameter substitution.
        @test DF.MPrint.ANNOT_KEYS === EarthSciAST.EXPRESSION_NODE_ANNOTATIONS
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

@testset "printing leaves no reader state in the caller's task" begin
    # A template with parameters makes the Markdown printer try the math parser
    # on its header; that trial read must not leave its state behind.
    path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "expression_templates_arrhenius.esm")
    doc = JSON.parse(read(path, String))
    key = EarthSciAST.DocumentFormats.DLimits.KEY
    for print_fn in (print_markdown, print_typst)
        haskey(task_local_storage(), key) && delete!(task_local_storage(), key)
        @test !isempty(print_fn(doc))
        @test !haskey(task_local_storage(), key)
    end
    print_math(Dict("op" => "+", "args" => Any["a", 1]), ["a"], :markdown)
    @test !haskey(task_local_storage(), key)
end

@testset "math keyword lists agree with the surfaces' spellings" begin
    # Each list below ports one Lean definition (Math.atomStart, Latex.atomEnd,
    # Math.isBin, Source.delta), so they stay separate; these checks keep them
    # consistent with the spellings the lexers are derived from.
    DF = EarthSciAST.DocumentFormats
    MT = DF.MToken
    spelled(k) = haskey(DF.MLatex.KW_CHARS, k) || haskey(DF.MTypst.KW_CHARS, k)
    @test all(spelled, instances(MT.Kw))
    @test all(spelled, DF.MParse.ATOM_KWS)
    @test all(spelled, DF.MLatex.ATOM_END_KWS)
    @test all(spelled, DF.MSurface.BIN_KWS)
    @test length(DF.SMultiLine.OPENS) == length(DF.SMultiLine.CLOSES)
    @test isempty(intersect(DF.SMultiLine.OPENS, DF.SMultiLine.CLOSES))
    @test all(spelled, DF.SMultiLine.OPENS) && all(spelled, DF.SMultiLine.CLOSES)
    # A keyword that starts an operand never ends one, and no binary operator
    # is either.
    @test isempty(intersect(DF.MParse.ATOM_KWS, DF.MLatex.ATOM_END_KWS))
    @test isempty(intersect(DF.MSurface.BIN_KWS, DF.MParse.ATOM_KWS))
end

@testset "print_math takes a typed expression or equation" begin
    E = EarthSciAST
    e = E.OpExpr("+", E.ASTExpr[E.VarExpr("a"), E.IntExpr(1)])
    raw = Dict("op" => "+", "args" => Any["a", 1])
    for f in (:markdown, :typst)
        @test print_math(e, ["a"], f) == print_math(raw, ["a"], f)
        eq = E.Equation(E.VarExpr("y"), e)
        @test print_math(eq, ["a", "y"], f) ==
            print_math(Dict("lhs" => "y", "rhs" => raw), ["a", "y"], f)
    end
    @test sprint(show, e) == print_math(e, expression_names(e), :typst)
    @test_throws ArgumentError print_math(raw, ["a"], :latex)
end

@testset "a refused document says where" begin
    path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "expression_templates_arrhenius.esm")
    doc = JSON.parse(read(path, String))
    for (fmt, decls) in ((:markdown, (":var[", ":param[")), (:typst, ("#var(", "#param(")))
        lines = split(print_document(doc, fmt), '\n')
        i = findfirst(l -> any(d -> startswith(l, d), decls), lines)
        @test i !== nothing
        decl = decls[findfirst(d -> startswith(lines[i], d), decls)]
        bad = copy(lines)
        bad[i] = replace(bad[i], decl => decl * "\"")
        err = try
            parse_document(join(bad, '\n'), fmt)
            nothing
        catch e
            e
        end
        @test err isa EarthSciAST.ParseError
        @test err.code == "parse_error"
        @test get(err.details, "line", nothing) == i
        @test occursin("line $i:", sprint(showerror, err))
        # CRLF line ends and a byte-order mark move no line.
        err2 = try
            parse_document("\ufeff" * join(bad, "\r\n"), fmt)
            nothing
        catch e
            e
        end
        @test get(err2.details, "line", nothing) == i
    end
    # A refusal past the constructs (math that does not read) names the math.
    err = try
        parse_markdown("---\nesm: \"2.3.0\"\n---\n\n\$\$\n\\frac{\n\$\$\n")
        nothing
    catch e
        e
    end
    @test err isa EarthSciAST.ParseError && err.code == "parse_error"
end
