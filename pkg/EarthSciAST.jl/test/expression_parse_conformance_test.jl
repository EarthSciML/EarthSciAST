# Cross-language expression-TEXT-parser conformance.
#
# `parse_expression` (src/parse_expression_text.jl) is the inverse of `to_ascii`
# and MUST agree with the other bindings node-for-node. This test drives the
# shared frozen corpus in tests/conformance/expression_parse/cases.json, which
# was GENERATED from the TypeScript oracle
# (`pkg/earthsci-ast-ts/src/parse-expression.ts`), and asserts the three
# contract properties on every entry:
#
#   1. serialize_expression(parse_expression(text))    deep-equals `ast`
#   2. to_ascii(parse_expression(text))                     equals `reprint`
#   3. serialize_expression(parse_expression(reprint)) deep-equals `ast`
#
# plus that every `expression_errors` / `equation_errors` entry is REFUSED with
# `ExpressionParseError` (the corpus `reason` is prose and is NOT asserted).
#
# The comparison is done on the SERIALIZED (wire) form rather than on typed
# nodes so the check is language-neutral: it is the same JSON the other four
# bindings compare.

using Test
using JSON3
using EarthSciAST
const ESMP = EarthSciAST

# `testutils.jl` provides TESTUTILS_REPO_ROOT + `_require_fixture`. `Test` must
# already be imported before it is included (its guard block expands
# `@test_skip` at lowering time). Under runtests.jl it is already loaded.
if !isdefined(Main, :ESM_TESTUTILS_LOADED)
    include("testutils.jl")
end

# Deep JSON equality with NUMERIC (not type-wise) comparison of numbers.
#
# The corpus is emitted by a JavaScript oracle, where every number is a double
# and an integral double serializes as a JSON integer token. Julia's AST keeps a
# genuine `IntExpr`/`NumExpr` distinction (CONFORMANCE_SPEC §5.5.3.1), and a
# magnitude past `typemax(Int64)` (`2.46e19`, which the corpus spells as the
# integer 24600000000000000000) can only be a `Float64` here. Comparing numbers
# by VALUE is therefore the language-neutral check; every other JSON shape
# (objects, arrays, strings, booleans, null) is compared structurally.
function _epc_eq(a, b)
    if a isa AbstractDict && b isa AbstractDict
        Set(keys(a)) == Set(keys(b)) || return false
        for k in keys(a)
            _epc_eq(a[k], b[k]) || return false
        end
        return true
    end
    if a isa AbstractVector && b isa AbstractVector
        length(a) == length(b) || return false
        return all(((x, y),) -> _epc_eq(x, y), zip(a, b))
    end
    if a isa Bool || b isa Bool
        return a === b
    end
    if a isa Real && b isa Real
        (isnan(a) && isnan(b)) && return true
        return a == b
    end
    if a isa AbstractString && b isa AbstractString
        return String(a) == String(b)
    end
    return a === b
end

# `JSON3.Object` indexes by Symbol; a plain `Dict` by String. Normalize both
# sides through `_normj` (testutils) so `_epc_eq` only ever sees plain
# containers.
_epc_norm(x) = _normj(x)

const _EPC_CORPUS = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
    "expression_parse", "cases.json")

@testset "Expression text-parser conformance" begin
    if _require_fixture(_EPC_CORPUS)
        corpus = JSON3.read(read(_EPC_CORPUS, String))

        @testset "expressions" begin
            for (i, case) in enumerate(corpus.expressions)
                text = String(case.text)
                want = _epc_norm(case.ast)
                reprint = String(case.reprint)
                @testset "[$i] $(text)" begin
                    parsed = ESMP.parse_expression(text)
                    got = _epc_norm(ESMP.serialize_expression(parsed))
                    @test _epc_eq(got, want)
                    @test ESMP.to_ascii(parsed) == reprint
                    reparsed = ESMP.parse_expression(reprint)
                    @test _epc_eq(_epc_norm(ESMP.serialize_expression(reparsed)), want)
                end
            end
        end

        @testset "expression_errors" begin
            for (i, case) in enumerate(corpus.expression_errors)
                text = String(case.text)
                @testset "[$i] $(text)" begin
                    @test_throws ESMP.ExpressionParseError ESMP.parse_expression(text)
                end
            end
        end

        @testset "equations" begin
            for (i, case) in enumerate(corpus.equations)
                text = String(case.text)
                @testset "[$i] $(text)" begin
                    eq = ESMP.parse_equation(text)
                    @test _epc_eq(_epc_norm(ESMP.serialize_expression(eq.lhs)),
                        _epc_norm(case.lhs))
                    @test _epc_eq(_epc_norm(ESMP.serialize_expression(eq.rhs)),
                        _epc_norm(case.rhs))
                end
            end
        end

        @testset "equation_errors" begin
            for (i, case) in enumerate(corpus.equation_errors)
                text = String(case.text)
                @testset "[$i] $(text)" begin
                    @test_throws ESMP.ExpressionParseError ESMP.parse_equation(text)
                end
            end
        end
    end

    # The error type's public shape: a message and a 0-based CHARACTER offset
    # (the same `pos` the TypeScript reference reports).
    @testset "ExpressionParseError shape" begin
        err = try
            ESMP.parse_expression("a + ")
            nothing
        catch e
            e
        end
        @test err isa ESMP.ExpressionParseError
        @test err.msg isa String
        @test err.pos isa Int
        @test err.pos >= 0
        # `∑` is one character in, so the refusal must report offset 1 — a byte
        # offset would report 2 (the `a` before it is 1 byte, `∑` is 3).
        uerr = try
            ESMP.parse_expression("a∑")
            nothing
        catch e
            e
        end
        @test uerr isa ESMP.ExpressionParseError
        @test uerr.pos == 1
    end

    # `parse_expression` (text) and `expression_from_json` (wire) are distinct
    # entry points; the JSON decoder keeps its own name after the rename.
    @testset "text and JSON entry points are distinct" begin
        from_text = ESMP.parse_expression("k * A")
        from_json = ESMP.expression_from_json(
            Dict{String,Any}("op" => "*", "args" => Any["k", "A"]))
        @test ESMP.serialize_expression(from_text) ==
              ESMP.serialize_expression(from_json)
    end
end
