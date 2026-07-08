# Cross-language display conformance.
#
# The pretty-printer (src/display.jl) MUST render the AST to `unicode`/`latex`/
# `ascii` text byte-identically to the other four language bindings. This test
# drives the shared frozen fixtures in tests/display/ (the TypeScript binding
# `pkg/earthsci-ast-ts/src/pretty-print.ts` is the reference) and asserts
# `to_unicode`/`to_latex`/`to_ascii` equal the fixture strings EXACTLY. See
# tests/display/RENDERING_CONTRACT.md for the per-op rules.

using Test
using JSON3
using EarthSciAST
const ESM = EarthSciAST

# `testutils.jl` provides TESTUTILS_REPO_ROOT + `_require_fixture`. `Test` must
# already be imported before it is included (its guard block expands
# `@test_skip` at lowering time). Under runtests.jl it is already loaded.
if !isdefined(Main, :ESM_TESTUTILS_LOADED)
    include("testutils.jl")
end

# Build the typed AST from a fixture `input` object. `apply_expression_template`
# is intentionally rejected by `parse_expression` (it is lowered before typed
# parsing), so construct that node directly from its `name` + `bindings`.
function _build_display_expr(input)
    op = string(get(input, :op, ""))
    if op == "apply_expression_template"
        bindings = Dict{String,ESM.Expr}()
        raw = get(input, :bindings, nothing)
        if raw !== nothing
            for (k, v) in pairs(raw)
                bindings[string(k)] = ESM.parse_expression(v)
            end
        end
        return ESM.OpExpr("apply_expression_template", ESM.Expr[];
            name=string(input.name), bindings=bindings)
    end
    return ESM.parse_expression(input)
end

const _DISPLAY_FMTS = (
    (:unicode, to_unicode),
    (:latex, to_latex),
    (:ascii, to_ascii),
)

function _run_display_fixture(path)
    groups = JSON3.read(read(path, String))
    for group in groups
        gname = string(get(group, :name, "group"))
        @testset "$gname" begin
            for (i, t) in enumerate(group.tests)
                tname = string(get(t, :name, "case $i"))
                expr = _build_display_expr(t.input)
                @testset "$tname" begin
                    for (fmt, fn) in _DISPLAY_FMTS
                        @test fn(expr) == String(t[fmt])
                    end
                end
            end
        end
    end
end

@testset "Display conformance (tests/display fixtures)" begin
    display_dir = joinpath(TESTUTILS_REPO_ROOT, "tests", "display")
    for fixture in ("structural_ops.json", "comprehensive_operators.json")
        path = joinpath(display_dir, fixture)
        @testset "$fixture" begin
            if _require_fixture(path)
                _run_display_fixture(path)
            end
        end
    end
end
