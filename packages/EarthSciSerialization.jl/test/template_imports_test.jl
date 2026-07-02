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
    MAX_TEMPLATE_EXPANSION_DEPTH, serialize_esm_file, IntExpr, OpExpr,
    _url_join, _url_normalize, _url_dirname, _remove_dot_segments,
    _canonical_ref, _URL_FETCHER

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

    @testset "import_smoke: the §9.7.8 four-file layering" begin
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

    @testset "import_rename_two_instances: one library, two prefixed instances (§9.7.7)" begin
        @test _expand_raw(conf("import_rename_two_instances", "fixture.esm")) ==
              _golden(conf("import_rename_two_instances", "expanded.esm"))
        f = EarthSciSerialization.load(conf("import_rename_two_instances", "fixture.esm"))
        # Transitive rename: the index set arrives per instance and the sizes
        # come from each edge's own bindings.
        @test f.index_sets["fine.x"].size == 16
        @test f.index_sets["coarse.x"].size == 8
        # Each renamed rule instance fired only on its own axis (`wrt` in the
        # match pattern followed the index-set rename).
        eqf = f.models["TwoGrids"].equations[1]
        @test eqf.rhs.op == "aggregate"
        @test eqf.rhs.ranges["i"] == [2, 15]      # N=16 instance
        eqc = f.models["TwoGrids"].equations[2]
        @test eqc.rhs.op == "aggregate"
        @test eqc.rhs.ranges["i"] == [2, 7]       # N=8 instance
    end

    @testset "import_rebind_keyed_factors: MPAS-style free-name rebinding (§9.7.7)" begin
        @test _expand_raw(conf("import_rebind_keyed_factors", "fixture.esm")) ==
              _golden(conf("import_rebind_keyed_factors", "expanded.esm"))
        f = EarthSciSerialization.load(conf("import_rebind_keyed_factors", "fixture.esm"))
        # The ragged set's keyed factors were rebound in the merged registry...
        @test f.index_sets["nz_of_row"].offsets == "meshA_count"
        @test f.index_sets["nz_of_row"].values == "meshA_cols"
        # ...and in the rule body (args and index gathers alike).
        total = f.models["Sparse"].variables["total"].expression
        @test total.op == "aggregate"
        argnames = String[a.name for a in total.args]   # typed VarExpr leaves
        @test "meshA_cols" in argnames && "meshA_w" in argnames
        @test !("row_cols" in argnames)
        # Rebinding un-reserves the factor names: the consumer's own unrelated
        # `row_count` parameter coexists.
        @test f.models["Sparse"].variables["row_count"].default == 7.5
    end

    @testset "import_rename_diamond: distinct instances vs dedupe (§9.7.4 + §9.7.7)" begin
        @test _expand_raw(conf("import_rename_diamond", "fixture.esm")) ==
              _golden(conf("import_rename_diamond", "expanded.esm"))
        # Effective order = DFS post-order over the edges; the identical
        # (prefix a, NC 6) edges deduped at first occurrence, the (prefix b,
        # NC 9) edge registered as a DISTINCT instance.
        raw = JSON3.read(read(conf("import_rename_diamond", "fixture.esm"), String))
        res = resolve_template_machinery(raw, conf("import_rename_diamond"))
        @test collect(keys(res["models"]["Diamond"]["expression_templates"])) ==
              ["a.n_cells", "a.scale_by_cells", "b.n_cells", "b.scale_by_cells"]
        # Both renamed rule instances match the axis-less scale_by_cells node;
        # the §9.6.3 equal-priority tie breaks by that order, so instance a
        # (NC = 6) wins: y = 6 * x, not 9 * x.
        d = _expand_raw(conf("import_rename_diamond", "fixture.esm"))
        @test d["models"]["Diamond"]["variables"]["y"]["expression"]["args"][1] == 6
        f = EarthSciSerialization.load(conf("import_rename_diamond", "fixture.esm"))
        @test f.index_sets["a.cells"].size == 6
        @test f.index_sets["b.cells"].size == 9
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
                     "metaparameter_type_error", "metaparameter_name_conflict",
                     "template_import_rename_unknown_name",
                     "template_import_rebind_unknown_name",
                     "template_import_rename_collision",
                     "template_import_rename_invalid"]
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

    @testset "renaming/rebinding unit behavior (§9.7.7)" begin
        _grid_lib = """
        {"esm": "0.8.0", "metadata": {"name": "grid"},
         "metaparameters": {"N": {"type": "integer"}},
         "index_sets": {"x": {"kind": "interval", "size": "N"}},
         "expression_templates": {"dx": {"params": [], "body": {"op": "/", "args": [1, "N"]}}}}
        """

        @testset "re-export renaming composes through chains; dotted binding keys" begin
            mktempdir() do dir
                write(joinpath(dir, "grid.esm"), _grid_lib)
                # Mid-layer library mounts the grid under prefix g, leaves g.N
                # open (re-exported), and composes g.dx into its own template.
                write(joinpath(dir, "layer.esm"), """
                {"esm": "0.8.0", "metadata": {"name": "layer"},
                 "expression_template_imports": [{"ref": "./grid.esm", "prefix": "g"}],
                 "expression_templates": {"two_dx": {"params": [], "body": {"op": "*", "args": [2,
                    {"op": "apply_expression_template", "args": [], "name": "g.dx", "bindings": {}}]}}}}
                """)
                p = joinpath(dir, "m.esm")
                write(p, _model_json(
                    """
                    "expression_template_imports": [{"ref": "./layer.esm", "prefix": "l", "bindings": {"g.N": 5}}],"""))
                # The consumer edge binds the RE-EXPORTED (already-renamed)
                # name g.N, then mounts everything under l.*: prefixes nest.
                f = EarthSciSerialization.load(p)
                @test f.index_sets["l.g.x"].size == 5
                raw = JSON3.read(read(p, String))
                res = resolve_template_machinery(raw, dir)
                @test collect(keys(res["models"]["M"]["expression_templates"])) ==
                      ["l.g.dx", "l.two_dx"]
                # Loader-API binding site also speaks the renamed name: leave
                # g.N open through both edges and close it at the root.
                write(p, _model_json(
                    """
                    "expression_template_imports": [{"ref": "./layer.esm", "prefix": "l"}],"""))
                f7 = EarthSciSerialization.load(p; metaparameters=Dict("l.g.N" => 7))
                @test f7.index_sets["l.g.x"].size == 7
            end
        end

        @testset "identity rename is a no-op; renaming a bound metaparameter is unknown" begin
            mktempdir() do dir
                write(joinpath(dir, "grid.esm"), _grid_lib)
                p = joinpath(dir, "m.esm")
                write(p, _model_json(
                    """
                    "expression_template_imports": [{"ref": "./grid.esm",
                       "bindings": {"N": 4}, "rename": {"dx": "dx"}}],"""))
                f = EarthSciSerialization.load(p)
                @test f.index_sets["x"].size == 4
                # A metaparameter closed by this edge's `bindings` is no longer
                # exported, so renaming it is a loud unknown-name error.
                write(p, _model_json(
                    """
                    "expression_template_imports": [{"ref": "./grid.esm",
                       "bindings": {"N": 4}, "rename": {"N": "M"}}],"""))
                @test _err_code(() -> EarthSciSerialization.load(p)) ==
                      "template_import_rename_unknown_name"
                # `rename` keys live in the post-`only` surviving export set.
                write(joinpath(dir, "two.esm"), """
                {"esm": "0.8.0", "metadata": {"name": "two"},
                 "expression_templates": {"keep": {"params": [], "body": 1},
                                          "drop": {"params": [], "body": 2}}}
                """)
                write(p, _model_json(
                    """
                    "expression_template_imports": [{"ref": "./two.esm",
                       "only": ["keep"], "rename": {"drop": "d2"}}],"""))
                @test _err_code(() -> EarthSciSerialization.load(p)) ==
                      "template_import_rename_unknown_name"
            end
        end

        @testset "rebind guards: declared names, bound indices, target capture" begin
            mktempdir() do dir
                write(joinpath(dir, "ragged.esm"), """
                {"esm": "0.8.0", "metadata": {"name": "ragged"},
                 "metaparameters": {"NR": {"type": "integer", "default": 2}},
                 "index_sets": {"rows": {"kind": "interval", "size": "NR"},
                                "nz": {"kind": "ragged", "of": ["rows"],
                                       "offsets": "cnt", "values": "cols"}},
                 "expression_templates": {"rsum": {"params": ["F"],
                   "match": {"op": "rsum", "args": ["F"]},
                   "body": {"op": "aggregate", "args": ["F", "cols", "wgt"],
                     "output_idx": ["i"], "semiring": "sum_product",
                     "ranges": {"i": {"from": "rows"}, "k": {"from": "nz", "of": ["i"]}},
                     "expr": {"op": "*", "args": [
                       {"op": "index", "args": ["wgt", "i", "k"]},
                       {"op": "index", "args": ["F", {"op": "index", "args": ["cols", "i", "k"]}]}]}}}}}
                """)
                p = joinpath(dir, "m.esm")
                imp(extra) = _model_json(
                    """
                    "expression_template_imports": [{"ref": "./ragged.esm", $extra}],""")
                # Rebinding a DECLARED name (metaparameter) is not a rebind.
                write(p, imp("\"rebind\": {\"NR\": \"n\"}"))
                @test _err_code(() -> EarthSciSerialization.load(p)) ==
                      "template_import_rebind_unknown_name"
                # Rebinding a bound index symbol is invalid outright.
                write(p, imp("\"rebind\": {\"k\": \"kk\"}"))
                @test _err_code(() -> EarthSciSerialization.load(p)) ==
                      "template_import_rename_invalid"
                # A rebind target must be fresh: colliding with a remaining
                # free name would silently merge two factors.
                write(p, imp("\"rebind\": {\"cnt\": \"wgt\"}"))
                @test _err_code(() -> EarthSciSerialization.load(p)) ==
                      "template_import_rename_collision"
                # ...as must two rebind entries mapping onto one target.
                write(p, imp("\"rebind\": {\"cnt\": \"z\", \"wgt\": \"z\"}"))
                @test _err_code(() -> EarthSciSerialization.load(p)) ==
                      "template_import_rename_collision"
                # Dot-scoped rebind targets (the MPAS mounted-subsystem shape)
                # are legal identifiers and land in registry + body alike.
                write(p, imp("\"rebind\": {\"cnt\": \"meshA.cnt\", \"cols\": \"meshA.cols\", \"wgt\": \"meshA.wgt\"}"))
                raw = JSON3.read(read(p, String))
                res = resolve_template_machinery(raw, dir)
                @test _normj(res["index_sets"]["nz"])["offsets"] == "meshA.cnt"
                body = _normj(res["models"]["M"]["expression_templates"]["rsum"]["body"])
                @test body["args"] == Any["F", "meshA.cols", "meshA.wgt"]
            end
        end

        @testset "prefix grammar and rename-map shape" begin
            mktempdir() do dir
                write(joinpath(dir, "grid.esm"), _grid_lib)
                p = joinpath(dir, "m.esm")
                for bad in ["\"prefix\": \"a..b\"", "\"prefix\": \".a\"",
                            "\"rename\": {\"dx\": \"has space\"}",
                            "\"rebind\": {\"q\": \"9bad\"}"]
                    write(p, _model_json(
                        """
                        "expression_template_imports": [{"ref": "./grid.esm", $bad}],"""))
                    @test _err_code(() -> EarthSciSerialization.load(p)) ==
                          "template_import_rename_invalid"
                end
            end
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

    @testset "URL-base joining for remote references (§4.7 / §9.7.2)" begin
        @testset "joining / canonicalization units" begin
            @test _url_join("https://h/a/b", "c.esm") == "https://h/a/b/c.esm"
            @test _url_join("https://h/a/b", "../c.esm") == "https://h/a/c.esm"
            @test _url_join("https://h/a/b", "./c/./d.esm") == "https://h/a/b/c/d.esm"
            # `..` never climbs above the authority root.
            @test _url_join("https://h/a", "../../c.esm") == "https://h/c.esm"
            @test _url_join("https://h", "x.esm") == "https://h/x.esm"
            # A `/`-rooted ref is authority-rooted (RFC 3986 §5.2).
            @test _url_join("https://h/a/b", "/rooted.esm") == "https://h/rooted.esm"
            # An absolute URL ref ignores the base entirely.
            @test _url_join("https://h/a", "https://other/x.esm") == "https://other/x.esm"

            @test _url_normalize("https://h/a/../b.esm") == "https://h/b.esm"
            @test _url_normalize("https://h/a/./b.esm?q=1") == "https://h/a/b.esm?q=1"
            @test _remove_dot_segments("/a/b/../c/./d.esm") == "/a/c/d.esm"
            @test _remove_dot_segments("/a/b/..") == "/a/"

            @test _url_dirname("https://h/lib/a.esm") == "https://h/lib"
            @test _url_dirname("https://h/a.esm") == "https://h"
            @test _url_dirname("https://h") == "https://h"

            # Cycle-detection keys: URL identity is canonical. A relative ref
            # inside a URL-loaded document joins against the URL base; two
            # spellings of the same target collapse to one key.
            @test _canonical_ref("../x.esm", "https://h/a/b") == "https://h/a/x.esm"
            @test _canonical_ref("https://h/a/../x.esm", "/tmp") == "https://h/x.esm"
            @test _canonical_ref("sub/model.esm", "/tmp/base") ==
                  abspath(joinpath("/tmp/base", "sub/model.esm"))
        end

        # Offline integration: substitute the URL fetcher (no live network) and
        # drive the real resolvers over a fake https host.
        _hosted = Dict{String,String}(
            # Template libraries: stencil.esm's OWN relative import must join
            # against ITS URL base -> https://esm.invalid/shared/grid.esm.
            "https://esm.invalid/shared/grid.esm" => """
            {"esm": "0.8.0", "metadata": {"name": "url_grid"},
             "metaparameters": {"N": {"type": "integer", "default": 8}},
             "index_sets": {"cells": {"kind": "interval", "size": "N"}},
             "expression_templates": {"n_cells": {"params": [], "body": "N"}}}""",
            "https://esm.invalid/lib/stencil.esm" => """
            {"esm": "0.8.0", "metadata": {"name": "url_stencil"},
             "expression_template_imports": [{"ref": "../shared/grid.esm"}],
             "expression_templates": {
               "scale_by_n": {"params": ["f"],
                 "match": {"op": "scale_by_n", "args": ["f"]},
                 "body": {"op": "*", "args": ["f",
                   {"op": "apply_expression_template", "args": [],
                    "name": "n_cells", "bindings": {}}]}}}}""",
            # Self-import through a dot-segment spelling: canonical URL
            # identity must detect the cycle.
            "https://esm.invalid/cyc/a.esm" => """
            {"esm": "0.8.0", "metadata": {"name": "url_cycle"},
             "expression_template_imports": [{"ref": "b/../a.esm"}],
             "expression_templates": {"t": {"params": [], "body": 1}}}""",
            # Subsystem refs: outer.esm's template import AND nested subsystem
            # ref are both relative to ITS OWN URL directory.
            "https://esm.invalid/models/outer.esm" => """
            {"esm": "0.8.0", "metadata": {"name": "url_outer"},
             "models": {"Outer": {
               "expression_template_imports": [{"ref": "tpl/lib.esm"}],
               "variables": {
                 "u": {"type": "state", "units": "1", "default": 1.5},
                 "w": {"type": "observed", "units": "1",
                       "expression": {"op": "scale_by_n", "args": ["u"]}}},
               "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                              "rhs": {"op": "-", "args": ["u"]}}],
               "subsystems": {"Inner": {"ref": "inner.esm"}}}}}""",
            "https://esm.invalid/models/tpl/lib.esm" => """
            {"esm": "0.8.0", "metadata": {"name": "url_outer_lib"},
             "expression_templates": {
               "scale_by_n": {"params": ["f"],
                 "match": {"op": "scale_by_n", "args": ["f"]},
                 "body": {"op": "*", "args": ["f", 8]}}}}""",
            "https://esm.invalid/models/inner.esm" => """
            {"esm": "0.8.0", "metadata": {"name": "url_inner"},
             "models": {"Inner": {
               "variables": {"v": {"type": "state", "units": "1", "default": 0.5}},
               "equations": []}}}""",
        )
        _fetched = String[]
        _old_fetcher = _URL_FETCHER[]
        _URL_FETCHER[] = url -> begin
            push!(_fetched, String(url))
            haskey(_hosted, url) || error("offline test host has no '$url'")
            _hosted[url]
        end
        try
            mktempdir() do dir
                # (1) Template-library import: relative refs INSIDE the
                # URL-loaded library resolve against the URL base.
                consumer = joinpath(dir, "consumer.esm")
                write(consumer, """
                {"esm": "0.8.0", "metadata": {"name": "url_consumer"},
                 "models": {"M": {
                   "expression_template_imports":
                     [{"ref": "https://esm.invalid/lib/stencil.esm"}],
                   "variables": {
                     "x": {"type": "state", "units": "1", "default": 1.5},
                     "y": {"type": "observed", "units": "1",
                           "expression": {"op": "scale_by_n", "args": ["x"]}}},
                   "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                                  "rhs": {"op": "-", "args": ["x"]}}]}}}""")
                f = EarthSciSerialization.load(consumer)
                @test f.index_sets["cells"].size == 8
                y = f.models["M"].variables["y"].expression
                @test y isa OpExpr && y.op == "*"
                @test "https://esm.invalid/shared/grid.esm" in _fetched

                # (2) Cycle detection over canonical URL identity: the
                # dot-segment self-import collapses to the same key.
                cyc = joinpath(dir, "cyc.esm")
                write(cyc, """
                {"esm": "0.8.0", "metadata": {"name": "url_cyc_consumer"},
                 "models": {"M": {
                   "expression_template_imports":
                     [{"ref": "https://esm.invalid/cyc/a.esm"}],
                   "variables": {"x": {"type": "state", "units": "1", "default": 1.5}},
                   "equations": []}}}""")
                @test _err_code(() -> EarthSciSerialization.load(cyc)) ==
                      "template_import_cycle"

                # (3) Subsystem ref to a URL: the remote document's own
                # template import and nested subsystem ref join its URL base.
                wrapper = joinpath(dir, "wrapper.esm")
                write(wrapper, """
                {"esm": "0.8.0", "metadata": {"name": "url_wrapper"},
                 "models": {"Top": {
                   "variables": {"z": {"type": "state", "units": "1", "default": 2.5}},
                   "equations": [],
                   "subsystems": {"S": {"ref": "https://esm.invalid/models/outer.esm"}}}}}""")
                fw = EarthSciSerialization.load(wrapper)
                sub = fw.models["Top"].subsystems["S"]
                @test sub isa EarthSciSerialization.Model
                w = sub.variables["w"].expression
                @test w isa OpExpr && w.op == "*"   # template lowered via URL base
                inner = sub.subsystems["Inner"]
                @test inner isa EarthSciSerialization.Model
                @test haskey(inner.variables, "v")
                @test "https://esm.invalid/models/tpl/lib.esm" in _fetched
                @test "https://esm.invalid/models/inner.esm" in _fetched
            end
        finally
            _URL_FETCHER[] = _old_fetcher
        end
    end
end
