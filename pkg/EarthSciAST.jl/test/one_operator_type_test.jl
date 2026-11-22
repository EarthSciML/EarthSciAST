# esm 2.4.0 "one operator type" (esm-spec §4.2, §4.8.3, §9.6.1–9.6.3, §9.6.6,
# §9.6.12; CONFORMANCE_SPEC §5.61): calls of defined operators resolve to
# definitions and become references, old spellings are read at the wire
# boundary, core names are reserved, arity is checked at load, unit
# expressions type a call. Fixtures under tests/conformance/expression_templates/.

using Test
using JSON3
using Logging
using EarthSciAST
using EarthSciAST: lower_expression_templates, resolve_template_machinery,
    Expand, emit_document, emit_esm_string, ExpressionTemplateError

include("testutils.jl")

const _OOT = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "expression_templates")
_oot(parts...) = joinpath(_OOT, parts...)
_oot_emit(p) = emit_esm_string(emit_document(JSON3.read(read(p, String)), dirname(p)))
function _oot_load(p)
    raw = JSON3.read(read(p, String))
    resolved = resolve_template_machinery(raw, dirname(p))
    return lower_expression_templates(resolved === nothing ? raw : resolved)
end
_oot_core(d) = Dict(k => _normj(get(d, k, nothing)) for k in ("models", "reaction_systems", "coupling", "index_sets") if haskey(d, k))
function _oot_err(f)
    try
        f()
        return nothing
    catch e
        return e
    end
end
_oot_code(e) = e === nothing ? nothing : (hasproperty(e, :code) ? String(e.code) : string(typeof(e)))

@testset "one operator type (esm 2.4.0, esm-spec §9.6.12)" begin
    @testset "emitted goldens, byte for byte, and emit ∘ load is a fixed point" begin
        for (dir, fix, gold) in [
                ("operator_call_by_name", "fixture.esm", "emitted.esm"),
                ("placeholder_call", "fixture.esm", "emitted.esm"),
                ("partial_wrt_param_instance", "fixture.esm", "emitted.esm"),
                ("old_names", "fixture.esm", "emitted.esm"),
                ("reference_only_round_trip", "fixture.esm", "emitted.esm"),
                ("independent_variable_wrt", "fixture.esm", "emitted.esm"),
                ("vector_calculus_import", "fixture.esm", "emitted.esm"),
            ]
            out = _oot_emit(_oot(dir, fix))
            @test out == read(_oot(dir, gold), String)
            mktempdir() do d
                p = joinpath(d, "e.esm")
                write(p, out)
                @test _oot_emit(p) == out
            end
        end
    end

    @testset "old spellings emit exactly as the new ones (metadata aside)" begin
        strip_meta(t) = (d = JSON3.read(t, Dict{String, Any}); delete!(d, "metadata"); d)
        @test strip_meta(_oot_emit(_oot("old_names", "fixture.esm"))) ==
            strip_meta(_oot_emit(_oot("old_names", "new_names.esm")))
    end

    @testset "expanded goldens, structurally" begin
        for dir in ("operator_call_by_name", "partial_wrt_param_instance")
            got = _oot_core(Expand(_oot_load(_oot(dir, "fixture.esm"))))
            want = _oot_core(JSON3.read(read(_oot(dir, "expanded.esm"), String)))
            @test got == want
        end
    end

    @testset "load errors by code" begin
        for (dir, fix, errf) in [
                ("operator_arity_mismatch", "fixture.esm", "error.json"),
                ("operator_defines_core_op", "fixture.esm", "error.json"),
                ("operator_defines_core_op", "explicit_defines.esm", "error_explicit_defines.json"),
            ]
            want = JSON3.read(read(_oot(dir, errf), String))
            err = _oot_err(() -> load_path(_oot(dir, fix)))
            @test _oot_code(err) == String(want.code)
        end
        @test load_path(_oot("operator_defines_core_op", "compound_rule_exempt.esm")) isa EsmFile
    end

    @testset "old spellings warn; new spellings do not" begin
        @test_logs (:warn, r"deprecated_field") (:warn, r"deprecated_op") (:warn, r"deprecated_field") match_mode = :any load_path(_oot("old_names", "fixture.esm"))
        @test_logs min_level = Logging.Warn load_path(_oot("old_names", "new_names.esm"))
    end

    @testset "a placeholder loads and is refused only if evaluated" begin
        f = load_path(_oot("placeholder_call", "fixture.esm"))
        @test f isa EsmFile
        err = _oot_err(() -> esm_problem(f, (0.0, 1.0)))
        @test _oot_code(err) == "unlowered_operator"
        @test err !== nothing && occursin("placeholder", sprint(showerror, err))
    end

    @testset "unit expressions (esm-spec §9.6.12 'Units')" begin
        exp = JSON3.read(read(_oot("definition_units", "expected.json"), String))
        for f in ("fixture.esm", "body_mismatch.esm", "call_unit_from_expression.esm")
            r = validate(load_path(_oot("definition_units", f)))
            want = exp[Symbol(f)]
            @test sort!(unique(String[e.error_type for e in r.structural_errors])) == sort!(String.(collect(want.errors)))
            got_w = sort!(unique(String[w.code for w in r.unit_warnings if w.code == "definition_unit_mismatch"]))
            @test got_w == sort!(String.(collect(want.warnings)))
        end
    end

    @testset "emitted rules are reference-only (esm-spec §9.6.1, §9.6.4 rule 5)" begin
        out = read(_oot("reference_only_round_trip", "emitted.esm"), String)
        reg = JSON3.read(out).models.m.operators
        @test reg.fv_div_edges.reference_only === true && reg.exp.reference_only === true
        @test !haskey(reg.fv_div_edges, :where)
        # div(G) stayed a call; reloading does not turn it into a reference.
        @test occursin("\"op\": \"div\"", out)
        # emit → load → emit is exact (also for constrained_match_scope).
        for (dir, fix) in (("reference_only_round_trip", "fixture.esm"), ("constrained_match_scope", "fixture.esm"))
            once = _oot_emit(_oot(dir, fix))
            mktempdir() do d
                p = joinpath(d, "e.esm")
                write(p, once)
                twice = _oot_emit(p)
                @test twice == once
                write(p, twice)
                @test _oot_emit(p) == once
            end
        end
    end

    @testset "old codes are aliases of the new ones (esm-spec §9.6.6)" begin
        @test EarthSciAST.canonical_error_code("template_import_cycle") == "operator_import_cycle"
        @test EarthSciAST.canonical_error_code("apply_expression_template_unknown_template") ==
            "operator_unknown_definition"
        @test EarthSciAST.canonical_error_code("operator_import_cycle") == "operator_import_cycle"
    end
end
