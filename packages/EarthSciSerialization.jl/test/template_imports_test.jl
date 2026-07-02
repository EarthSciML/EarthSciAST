# Tests for esm-spec §9.7 — template-library files, expression_template_imports,
# and load-time metaparameters (docs/content/rfcs/template-library-imports.md;
# esm-libraries-spec §2.1c). Drives the shared conformance fixtures under
# tests/conformance/expression_templates/ and the resolver-level invalid
# fixtures under tests/invalid/template_imports/.

using Test
using JSON3
using EarthSciSerialization
using EarthSciSerialization: lower_expression_templates, resolve_template_machinery,
    reject_template_imports_pre_v08, ExpressionTemplateError, JSONLikeDict,
    MAX_TEMPLATE_EXPANSION_DEPTH, serialize_esm_file, IntExpr, OpExpr

@testset "template-library imports + metaparameters (esm-spec §9.7)" begin
    repo_root = abspath(joinpath(@__DIR__, "..", "..", ".."))
    conf(parts...) = joinpath(repo_root, "tests", "conformance",
                              "expression_templates", parts...)
    invalid_dir = joinpath(repo_root, "tests", "invalid", "template_imports")

    _normj(x) =
        (x isa AbstractDict || x isa JSON3.Object) ?
            Dict{String,Any}(string(k) => _normj(v) for (k, v) in pairs(x)) :
        (x isa AbstractVector || x isa JSON3.Array) ? Any[_normj(v) for v in x] : x

    # Raw §9.7 pipeline (resolve → lower), mirroring the golden generator.
    function _expand_raw(path)
        raw = JSON3.read(read(path, String))
        resolved = resolve_template_machinery(raw, dirname(path))
        out = lower_expression_templates(resolved === nothing ? raw : resolved)
        return _normj(out isa JSONLikeDict ? out.data : out)
    end
    _golden(path) = _normj(JSON3.read(read(path, String)))

    _err_code(f) = try
        f()
        nothing
    catch e
        e isa ExpressionTemplateError ? e.code : rethrow(e)
    end

    @testset "import_smoke: the §9.7.7 four-file layering" begin
        # Raw pipeline matches the golden byte-for-byte structurally.
        @test _expand_raw(conf("import_smoke", "fixture.esm")) ==
              _golden(conf("import_smoke", "expanded.esm"))

        # Typed happy path: index sets merged and folded at the edge bindings.
        f = EarthSciSerialization.load(conf("import_smoke", "fixture.esm"))
        @test f isa EarthSciSerialization.EsmFile
        @test f.index_sets["lon"].size == 288
        @test f.index_sets["lat"].size == 181
        # D(c, wrt: lon) lowered to the makearray rule body; D(c, wrt: t) not.
        eq = f.models["Advection"].equations[1]
        @test eq.lhs.op == "D"
        @test eq.rhs.args[2].op == "makearray"
    end

    @testset "import_diamond: deep-equal dedup at first occurrence" begin
        @test _expand_raw(conf("import_diamond", "fixture.esm")) ==
              _golden(conf("import_diamond", "expanded.esm"))
        f = EarthSciSerialization.load(conf("import_diamond", "fixture.esm"))
        @test f.index_sets["cells"].size == 10   # NC default, deduped once
    end

    @testset "effective order: import order pins the tie-break, priority flips it" begin
        @test _expand_raw(conf("import_order_determinism", "fixture_import_order.esm")) ==
              _golden(conf("import_order_determinism", "expanded_import_order.esm"))
        @test _expand_raw(conf("import_order_determinism", "fixture_priority_override.esm")) ==
              _golden(conf("import_order_determinism", "expanded_priority_override.esm"))
        # Winner sanity, independent of the goldens: earlier import wins the
        # equal-priority tie (2*x); explicit priority 10 out-ranks it (5*x).
        d1 = _expand_raw(conf("import_order_determinism", "fixture_import_order.esm"))
        @test d1["models"]["M"]["variables"]["y"]["expression"]["args"][1] == 2
        d2 = _expand_raw(conf("import_order_determinism", "fixture_priority_override.esm"))
        @test d2["models"]["M"]["variables"]["y"]["expression"]["args"][1] == 5
    end

    @testset "valid suite: library file + minimal consumer" begin
        # A model-less template-library document loads (esm-spec §9.7.1);
        # round-trip strips every §9.7 construct, leaving the folded registry.
        lib = EarthSciSerialization.load(joinpath(repo_root, "tests", "valid",
                                                  "template_import_lib.esm"))
        @test lib.models === nothing
        @test lib.index_sets["cells"].size == 8   # size "N" folded by default
        # Loader-API binding overrides the default on the library itself.
        lib12 = EarthSciSerialization.load(
            joinpath(repo_root, "tests", "valid", "template_import_lib.esm");
            metaparameters=Dict("N" => 12))
        @test lib12.index_sets["cells"].size == 12

        m = EarthSciSerialization.load(joinpath(repo_root, "tests", "valid",
                                                "template_import_minimal.esm"))
        @test m.index_sets["cells"].size == 8     # §9.7.5 merge into consumer
        y = m.models["M"].variables["y"].expression
        @test y isa OpExpr && y.op == "*"
        @test y.args[2] isa IntExpr && y.args[2].value == 8
    end

    @testset "metaparameter_resolutions: subsystem-ref bindings (§9.7.6 site 3)" begin
        for (wrapper, golden, n) in [("wrapper_n4.esm", "expanded_n4.esm", 4),
                                     ("wrapper_n8.esm", "expanded_n8.esm", 8)]
            f = EarthSciSerialization.load(conf("metaparameter_resolutions", wrapper))
            sub = f.models["Sweep"].subsystems["Problem"]
            # Expression position: bare "N" substituted as an integer literal.
            @test sub.variables["npts"].expression isa IntExpr
            @test sub.variables["npts"].expression.value == n
            # Expression-position division stays an AST division (no folding).
            half = sub.variables["half"].expression
            @test half isa OpExpr && half.op == "/"
            @test half.args[1].value == n
            # Structural site: the aggregate dense range folded exactly.
            ramp = sub.variables["ramp"].expression
            @test ramp.op == "aggregate"
            @test ramp.ranges["i"] == [1, div(n, 2)]
            # Typed round-trip matches the golden.
            @test _normj(serialize_esm_file(f)) ==
                  _golden(conf("metaparameter_resolutions", golden))
        end
    end

    @testset "loader-API bindings (§9.7.6 site 4) and defaults (site 5)" begin
        problem = conf("metaparameter_resolutions", "problem.esm")
        fdef = EarthSciSerialization.load(problem)
        @test fdef.models["Problem"].variables["npts"].expression.value == 2  # default
        fapi = EarthSciSerialization.load(problem; metaparameters=Dict("N" => 6))
        @test fapi.models["Problem"].variables["npts"].expression.value == 6  # API > default
        @test fapi.models["Problem"].variables["ramp"].expression.ranges["i"] == [1, 3]
        # Binding a name the document does not declare is an error.
        @test _err_code(() -> EarthSciSerialization.load(problem;
            metaparameters=Dict("Q" => 1))) == "template_import_unknown_name"
    end

    @testset "round-trip emits the expanded, folded form (§9.7.6)" begin
        f = EarthSciSerialization.load(conf("import_smoke", "fixture.esm"))
        tmp = tempname() * ".esm"
        try
            EarthSciSerialization.save(f, tmp)
            text = read(tmp, String)
            @test !occursin("expression_template_imports", text)
            @test !occursin("metaparameters", text)
            @test !occursin("expression_templates", text)
            @test !occursin("apply_expression_template", text)
            reloaded = EarthSciSerialization.load(tmp)
            @test reloaded.index_sets["lon"].size == 288
            @test reloaded.models["Advection"].equations[1].rhs.args[2].op == "makearray"
        finally
            isfile(tmp) && rm(tmp, force=true)
        end
    end

    @testset "invalid fixtures: every §9.7 diagnostic code, machine-checked" begin
        expected = JSON3.read(read(joinpath(repo_root, "tests", "invalid",
                                            "expected_errors.json"), String))
        fixtures = sort(filter(f -> endswith(f, ".esm"), readdir(invalid_dir)))
        @test !isempty(fixtures)
        seen_codes = Set{String}()
        for fname in fixtures
            entry = get(expected, Symbol(fname), nothing)
            @test entry !== nothing  # every fixture has an expected_errors entry
            entry === nothing && continue
            @test entry.resolver_only === true
            want = string(entry.resolver_error_code)
            got = _err_code(() -> EarthSciSerialization.load(joinpath(invalid_dir, fname)))
            @test got == want
            got == want && push!(seen_codes, want)
        end
        # The fixture set exercises the full §9.6.6 §9.7 code table (the 12th,
        # template_import_unresolved, is exercised below — a missing file is
        # not representable as a fixture).
        for code in ["template_import_version_too_old", "template_import_not_library",
                     "subsystem_ref_is_template_library", "template_import_cycle",
                     "template_import_name_conflict", "template_import_unknown_name",
                     "template_import_index_set_conflict",
                     "apply_expression_template_recursive_body",
                     "template_body_expansion_too_deep", "metaparameter_unbound",
                     "metaparameter_type_error", "metaparameter_name_conflict"]
            @test code in seen_codes
        end
    end

    # ------------------------------------------------------------------
    # Unit-level behavior over generated files
    # ------------------------------------------------------------------

    _model_json(extra_model_fields, top_fields="") = """
    {
      "esm": "0.8.0",
      "metadata": {"name": "t"},$top_fields
      "models": {
        "M": {$extra_model_fields
          "variables": {"x": {"type": "state", "units": "1", "default": 0.5}},
          "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                         "rhs": {"op": "-", "args": ["x"]}}]
        }
      }
    }
    """

    @testset "template_import_unresolved: missing / unparsable ref" begin
        mktempdir() do dir
            p = joinpath(dir, "m.esm")
            write(p, _model_json(
                """
                "expression_template_imports": [{"ref": "./nope.esm"}],"""))
            @test _err_code(() -> EarthSciSerialization.load(p)) == "template_import_unresolved"
            write(joinpath(dir, "junk.esm"), "{not json")
            write(p, _model_json(
                """
                "expression_template_imports": [{"ref": "./junk.esm"}],"""))
            @test _err_code(() -> EarthSciSerialization.load(p)) == "template_import_unresolved"
        end
    end

    @testset "`only` filters visibility, not the target's internal wiring" begin
        mktempdir() do dir
            write(joinpath(dir, "lib.esm"), """
            {
              "esm": "0.8.0",
              "metadata": {"name": "lib"},
              "expression_templates": {
                "t_inner": {"params": [], "body": 7},
                "t_keep": {"params": [], "body": {"op": "*", "args": [2,
                  {"op": "apply_expression_template", "args": [], "name": "t_inner", "bindings": {}}]}},
                "t_drop": {"params": [], "body": 9}
              }
            }
            """)
            # t_keep's body reference to t_inner resolved in the LIBRARY's own
            # scope, so importing only t_keep still yields 2 * 7.
            p = joinpath(dir, "m.esm")
            write(p, _model_json(
                """
                "expression_template_imports": [{"ref": "./lib.esm", "only": ["t_keep"]}],"""))
            raw = JSON3.read(read(p, String))
            resolved = resolve_template_machinery(raw, dir)
            tpl = resolved["models"]["M"]["expression_templates"]
            @test collect(keys(tpl)) == ["t_keep"]
            @test _normj(tpl["t_keep"]["body"]) ==
                  Dict{String,Any}("op" => "*", "args" => Any[2, 7])
            # Referencing a filtered-out name from an expression position fails.
            p2 = joinpath(dir, "m2.esm")
            write(p2, _model_json(
                """
                "expression_template_imports": [{"ref": "./lib.esm", "only": ["t_keep"]}],
                "expression_templates": {"local_uses_drop": {"params": [],
                  "body": {"op": "apply_expression_template", "args": [], "name": "t_drop", "bindings": {}}}},"""))
            @test _err_code(() -> EarthSciSerialization.load(p2)) ==
                  "apply_expression_template_unknown_template"
        end
    end

    @testset "diamond with conflicting edge bindings is rejected (§9.7.6)" begin
        mktempdir() do dir
            write(joinpath(dir, "grid.esm"), """
            {"esm": "0.8.0", "metadata": {"name": "grid"},
             "metaparameters": {"NC": {"type": "integer"}},
             "index_sets": {"cells": {"kind": "interval", "size": "NC"}},
             "expression_templates": {"nc": {"params": [], "body": "NC"}}}
            """)
            p = joinpath(dir, "m.esm")
            write(p, _model_json(
                """
                "expression_template_imports": [
                  {"ref": "./grid.esm", "bindings": {"NC": 4}},
                  {"ref": "./grid.esm", "bindings": {"NC": 8}}],"""))
            @test _err_code(() -> EarthSciSerialization.load(p)) in
                  ("template_import_name_conflict", "template_import_index_set_conflict")
            # Equal instantiation on both edges dedups cleanly.
            write(p, _model_json(
                """
                "expression_template_imports": [
                  {"ref": "./grid.esm", "bindings": {"NC": 4}},
                  {"ref": "./grid.esm", "bindings": {"NC": 4}}],"""))
            f = EarthSciSerialization.load(p)
            @test f.index_sets["cells"].size == 4
        end
    end

    @testset "edge bindings: unknown names and non-integer values" begin
        mktempdir() do dir
            write(joinpath(dir, "lib.esm"), """
            {"esm": "0.8.0", "metadata": {"name": "lib"},
             "metaparameters": {"N": {"type": "integer", "default": 8}},
             "expression_templates": {"n": {"params": [], "body": "N"}}}
            """)
            p = joinpath(dir, "m.esm")
            write(p, _model_json(
                """
                "expression_template_imports": [{"ref": "./lib.esm", "bindings": {"Q": 1}}],"""))
            @test _err_code(() -> EarthSciSerialization.load(p)) == "template_import_unknown_name"
            # A non-integer binding is schema-invalid (TemplateImport.bindings
            # is integer-typed), so `load` rejects at schema validation; the
            # resolver-level backstop still reports metaparameter_type_error.
            write(p, _model_json(
                """
                "expression_template_imports": [{"ref": "./lib.esm", "bindings": {"N": 2.5}}],"""))
            @test_throws EarthSciSerialization.SchemaValidationError EarthSciSerialization.load(p)
            raw = JSON3.read(read(p, String))
            @test _err_code(() -> resolve_template_machinery(raw, dir)) ==
                  "metaparameter_type_error"
        end
    end

    @testset "metaparameter fold: ranges / regions / size, exact arithmetic" begin
        mktempdir() do dir
            p = joinpath(dir, "m.esm")
            write(p, """
            {
              "esm": "0.8.0",
              "metadata": {"name": "fold"},
              "metaparameters": {"N": {"type": "integer", "default": 6}},
              "index_sets": {"cells": {"kind": "interval", "size": {"op": "*", "args": ["N", 2]}}},
              "models": {
                "M": {
                  "variables": {
                    "x": {"type": "state", "units": "1", "default": 0.5},
                    "agg": {"type": "observed", "units": "1",
                      "expression": {"op": "aggregate", "output_idx": ["i"], "args": ["x"],
                        "ranges": {"i": [1, {"op": "-", "args": ["N", 1]}]},
                        "expr": {"op": "*", "args": ["x", "i"]}}},
                    "ma": {"type": "observed", "units": "1",
                      "expression": {"op": "makearray", "args": [],
                        "regions": [[[{"op": "/", "args": ["N", 2]}, "N"]]],
                        "values": [1.5]}}
                  },
                  "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                                 "rhs": {"op": "-", "args": ["x"]}}]
                }
              }
            }
            """)
            f = EarthSciSerialization.load(p)
            @test f.index_sets["cells"].size == 12
            m = f.models["M"]
            @test m.variables["agg"].expression.ranges["i"] == [1, 5]
            ma = m.variables["ma"].expression
            @test ma.regions == [[[3, 6]]]
        end
    end

    @testset "expression-position substitution never folds" begin
        mktempdir() do dir
            p = joinpath(dir, "m.esm")
            write(p, """
            {
              "esm": "0.8.0",
              "metadata": {"name": "subst"},
              "metaparameters": {"N": {"type": "integer", "default": 144}},
              "models": {
                "M": {
                  "variables": {
                    "x": {"type": "state", "units": "1", "default": 0.5},
                    "dlon": {"type": "observed", "units": "1",
                             "expression": {"op": "/", "args": [360, "N"]}}
                  },
                  "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                                 "rhs": {"op": "-", "args": ["x"]}}]
                }
              }
            }
            """)
            f = EarthSciSerialization.load(p)
            dlon = f.models["M"].variables["dlon"].expression
            @test dlon isa OpExpr && dlon.op == "/"
            @test dlon.args[1].value == 360
            @test dlon.args[2] isa IntExpr && dlon.args[2].value == 144
        end
    end

    @testset "body composition: acyclic DAG inlines; depth bound is exact" begin
        # A 3-deep local chain inlines through the §9.6.3 fixpoint untouched.
        doc = JSON3.read("""
        {
          "esm": "0.8.0",
          "metadata": {"name": "chain3"},
          "models": {
            "M": {
              "expression_templates": {
                "c1": {"params": [], "body": {"op": "+", "args": [1,
                  {"op": "apply_expression_template", "args": [], "name": "c2", "bindings": {}}]}},
                "c2": {"params": [], "body": {"op": "+", "args": [2,
                  {"op": "apply_expression_template", "args": [], "name": "c3", "bindings": {}}]}},
                "c3": {"params": [], "body": 3}
              },
              "variables": {"x": {"type": "state", "units": "1", "default": 0.5},
                            "y": {"type": "observed", "units": "1",
                                  "expression": {"op": "apply_expression_template",
                                                 "args": [], "name": "c1", "bindings": {}}}},
              "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                             "rhs": {"op": "-", "args": ["x"]}}]
            }
          }
        }
        """)
        out = lower_expression_templates(doc)
        y = _normj(out.data["models"]["M"]["variables"]["y"]["expression"])
        @test y == Dict{String,Any}("op" => "+", "args" => Any[1,
                     Dict{String,Any}("op" => "+", "args" => Any[2, 3])])

        # Exactly MAX_TEMPLATE_EXPANSION_DEPTH templates chain: accepted;
        # one more: template_body_expansion_too_deep (the shared generated
        # fixture pins the reject side; this pins the boundary).
        function chain_doc(n)
            tpl = Dict{String,Any}()
            for i in 1:n
                name = "c_" * lpad(i, 2, '0')
                tpl[name] = i == n ? Dict("params" => [], "body" => 1) :
                    Dict("params" => [],
                         "body" => Dict("op" => "apply_expression_template",
                                        "args" => [], "name" => "c_" * lpad(i + 1, 2, '0'),
                                        "bindings" => Dict()))
            end
            Dict("esm" => "0.8.0", "metadata" => Dict("name" => "chain"),
                 "models" => Dict("M" => Dict(
                     "expression_templates" => tpl,
                     "variables" => Dict("x" => Dict("type" => "state", "default" => 0.5)),
                     "equations" => [Dict(
                         "lhs" => Dict("op" => "D", "args" => ["x"], "wrt" => "t"),
                         "rhs" => Dict("op" => "-", "args" => ["x"]))])))
        end
        @test lower_expression_templates(chain_doc(MAX_TEMPLATE_EXPANSION_DEPTH)) isa JSONLikeDict
        @test _err_code(() ->
            lower_expression_templates(chain_doc(MAX_TEMPLATE_EXPANSION_DEPTH + 1))) ==
            "template_body_expansion_too_deep"

        # A body may not reference a `match` rule by name.
        matchref = JSON3.read(_model_json(
            """
            "expression_templates": {
              "rule": {"params": ["f"], "match": {"op": "lowerme", "args": ["f"]},
                       "body": {"op": "*", "args": [2, "f"]}},
              "uses_rule": {"params": [], "body": {"op": "apply_expression_template",
                            "args": [], "name": "rule", "bindings": {"f": 1}}}
            },"""))
        @test _err_code(() -> lower_expression_templates(matchref)) ==
              "apply_expression_template_unknown_template"
    end

    @testset "version gate helper flags every §9.7 construct" begin
        for snippet in [
            "\"metaparameters\": {\"N\": {\"type\": \"integer\"}},",
            "\"expression_templates\": {\"t\": {\"params\": [], \"body\": 1}},",
        ]
            doc = JSON3.read("""
            {"esm": "0.7.0", "metadata": {"name": "old"},$snippet
             "models": {"M": {"variables": {"x": {"type": "state", "default": 0.5}},
                              "equations": []}}}""")
            @test _err_code(() -> reject_template_imports_pre_v08(doc)) ==
                  "template_import_version_too_old"
        end
        # 0.8.0 files pass the gate.
        ok = JSON3.read("""
        {"esm": "0.8.0", "metadata": {"name": "new"},
         "metaparameters": {"N": {"type": "integer", "default": 1}},
         "expression_templates": {"t": {"params": [], "body": 1}}}""")
        @test reject_template_imports_pre_v08(ok) === nothing
    end
end
