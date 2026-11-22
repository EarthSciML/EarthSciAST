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

    @testset "a mounted subsystem's definitions stay in its scope (esm-spec §9.6.3 constraint 4)" begin
        leaf = """{"esm": "2.4.0", "metadata": {"name": "leaf"}, "models": {"Leaf": {
        "operators": {
          "scale": {"params": ["x"], "body": {"op": "*", "args": [3, "x"]}},
          "pair": {"params": ["x"], "body": {"op": "*", "args": ["k", "x"]}}},
        "variables": {"c": {"type": "unknown", "units": "1", "default": 1.0},
                      "k": {"type": "parameter", "units": "1", "default": 0.25}},
        "equations": [{"lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                       "rhs": {"op": "-", "args": [{"op": "scale", "args": ["c"]}]}}]}}}"""
        host(call) = """{"esm": "2.4.0", "metadata": {"name": "host"}, "models": {"Host": {
        "variables": {"y": {"type": "unknown", "units": "1", "default": 1.0}},
        "equations": [{"lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                       "rhs": {"op": "-", "args": [$call]}}],
        "subsystems": {"Sub": {"ref": "./leaf.esm"}}}}}"""
        # An authored subsystem's calls still resolve to its own definitions.
        inline = """{"esm": "2.4.0", "metadata": {"name": "inline"}, "models": {"Host": {
        "variables": {"y": {"type": "unknown", "units": "1", "default": 1.0}},
        "equations": [{"lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                       "rhs": {"op": "-", "args": [{"op": "scale", "args": ["y"]}]}}],
        "subsystems": {"Sub": {
          "operators": {"scale": {"params": ["x"], "body": {"op": "*", "args": [3, "x"]}}},
          "variables": {"c": {"type": "unknown", "units": "1", "default": 1.0}},
          "equations": [{"lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                         "rhs": {"op": "-", "args": [{"op": "scale", "args": ["c"]}]}}]}}}}}"""
        mktempdir() do d
            write(joinpath(d, "leaf.esm"), leaf)
            write(joinpath(d, "capture.esm"), host("""{"op": "scale", "args": ["y"]}"""))
            write(joinpath(d, "arity.esm"), host("""{"op": "pair", "args": ["y", "y"]}"""))
            write(joinpath(d, "inline.esm"), inline)
            for (f, op) in (("capture.esm", "scale"), ("arity.esm", "pair"))
                p = joinpath(d, f)
                s = EarthSciAST.serialize_esm_file(load_path(p))
                host_m = s["models"]["Host"]
                # The host's call stays a call, as emit leaves it.
                @test host_m["equations"][1]["rhs"]["args"][1]["op"] == op
                emitted = emit_document(JSON3.read(read(p, String)), d)
                @test emitted["models"]["Host"]["equations"][1]["rhs"]["args"][1]["op"] == op
                # The leaf's definition is written as reached by references only.
                @test host_m["operators"]["scale"]["reference_only"] === true
            end
            p = joinpath(d, "inline.esm")
            m = EarthSciAST.serialize_esm_file(load_path(p))["models"]["Host"]
            @test m["equations"][1]["rhs"]["args"][1]["op"] == "scale"
            @test m["subsystems"]["Sub"]["equations"][1]["rhs"]["args"][1]["op"] == "apply_operator"
            @test m["operators"]["scale"]["reference_only"] === true
            once = _oot_emit(p)
            write(joinpath(d, "e.esm"), once)
            @test _oot_emit(joinpath(d, "e.esm")) == once
            # The only `operators` block sits two subsystems down: the document
            # is still lowered, and that subsystem's call resolves.
            deep = replace(
                inline, "\"subsystems\": {\"Sub\": {" =>
                    "\"subsystems\": {\"Mid\": {\"variables\": {}, \"equations\": [], \"subsystems\": {\"Sub\": {"
            ) * "}}"
            deep = replace(deep, "{\"op\": \"scale\", \"args\": [\"y\"]}" => "\"y\"")
            p = joinpath(d, "deep.esm")
            write(p, deep)
            m = EarthSciAST.serialize_esm_file(load_path(p))["models"]["Host"]
            @test m["subsystems"]["Mid"]["subsystems"]["Sub"]["equations"][1]["rhs"]["args"][1]["op"] ==
                "apply_operator"
        end
    end

    @testset "a fired partial rule is held to partial's fixed unit (esm-spec §4.2, §9.6.12)" begin
        doc = """{"esm": "2.4.0", "metadata": {"name": "fixed_unit"}, "models": {"m": {
        "variables": {"u": {"type": "parameter", "units": "kg", "default": 1.0},
                      "x": {"type": "parameter", "units": "m", "default": 1.0},
                      "k": {"type": "parameter", "units": "1", "default": 1.0},
                      "y": {"type": "unknown", "units": "kg/m"}},
        "equations": [{"lhs": "y", "rhs": {"op": "partial", "args": ["u"], "wrt": "x"}}],
        "operators": {"dd": {"params": ["f", "d"],
          "match": {"op": "partial", "args": ["f"], "wrt": "d"},
          "body": {"op": "*", "args": ["f", "k"]}}}}}}"""
        f = load_string(doc)
        codes = String[e.error_type for e in validate(f).structural_errors]
        @test "definition_unit_mismatch" in codes
        @test !("unit_inconsistency" in codes)
        @test !occursin("__esm", EarthSciAST.to_json(f))
    end

    @testset "unlowered_operator names the operand's declared shape (esm-spec §9.6.6)" begin
        doc = """{"esm": "2.4.0", "metadata": {"name": "shape_msg"},
        "index_sets": {"cells": {"kind": "interval", "size": 3}, "edges": {"kind": "interval", "size": 4}},
        "models": {"m": {
          "variables": {"F": {"type": "parameter", "units": "1", "default": 1.0, "shape": ["edges"]},
                        "G": {"type": "parameter", "units": "1", "default": 2.0, "shape": ["cells"]},
                        "d1": {"type": "unknown", "units": "1", "shape": ["edges"]},
                        "d2": {"type": "unknown", "units": "1", "shape": ["cells"]}},
          "equations": [{"lhs": "d1", "rhs": {"op": "div", "args": ["F"]}},
                        {"lhs": "d2", "rhs": {"op": "div", "args": ["G"]}}],
          "operators": {"fvd": {"params": ["Q"], "defines": "div",
            "where": {"Q": {"shape": ["edges"]}}, "body": {"op": "*", "args": [2, "Q"]}}}}}}"""
        e = _oot_err(() -> esm_problem(load_string(doc), (0.0, 1.0)))
        @test _oot_code(e) == "unlowered_operator"
        msg = sprint(showerror, e)
        @test occursin("Q.shape = [edges] fails", msg)
        @test occursin("has declared shape [cells]", msg)
        @test !occursin("Any[", msg)
    end

    @testset "an operator library is written under 2.4.0 (esm-spec §9.6.5)" begin
        p = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "template_import_lib.esm")
        s = with_logger(NullLogger()) do
            EarthSciAST.serialize_esm_file(load_path(p))
        end
        @test haskey(s, "operators") && s["esm"] == "2.4.0"
        e = with_logger(NullLogger()) do
            emit_document(JSON3.read(read(p, String)), dirname(p))
        end
        @test haskey(e, "operators") && e["esm"] == "2.4.0"
    end

    @testset "a test's imports join a component's old-spelled imports (esm-spec §9.7.10)" begin
        mktempdir() do d
            write(
                joinpath(d, "lib1.esm"), """{"esm": "1.1.0", "metadata": {"name": "lib1"},
                "expression_templates": {"rate": {"params": ["x"], "body": {"op": "*", "args": [2, "x"]}}}}"""
            )
            write(
                joinpath(d, "lib2.esm"), """{"esm": "1.1.0", "metadata": {"name": "lib2"},
                "expression_templates": {"halve": {"params": ["x"],
                  "match": {"op": "halve", "args": ["x"]}, "body": {"op": "/", "args": ["x", 2]}}}}"""
            )
            p = joinpath(d, "model.esm")
            write(
                p, """{"esm": "1.1.0", "metadata": {"name": "inject_both"}, "models": {"M": {
                "expression_template_imports": [{"ref": "./lib1.esm"}],
                "variables": {"c": {"type": "unknown", "units": "1", "default": 1.0}},
                "equations": [{"lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                  "rhs": {"op": "-", "args": [{"op": "apply_expression_template", "args": [],
                          "name": "rate", "bindings": {"x": "c"}}]}}],
                "tests": [{"id": "t1", "time_span": {"start": 0.0, "end": 1.0},
                  "expression_template_imports": [{"ref": "./lib2.esm"}],
                  "assertions": [{"variable": "c", "time": 1.0, "expected": 0.1353352832366127}]}]}}}"""
            )
            with_logger(NullLogger()) do
                f = load_path(p)
                t = f.models["M"].tests[1]
                e = EarthSciAST._ephemeral_injected_file(f, p, "M", t.expression_template_imports, d)
                @test haskey(e.models, "M")
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
