# Unit tests for expression_templates / apply_expression_template
# (esm-spec §9.6, docs/rfcs/ast-expression-templates.md, esm-giy).

using Test
using JSON3
using EarthSciSerialization
using EarthSciSerialization: lower_expression_templates,
    reject_expression_templates_pre_v04, ExpressionTemplateError, OpExpr,
    NumExpr, IntExpr, VarExpr

const ARRHENIUS_FIXTURE_JSON = """
{
  "esm": "0.4.0",
  "metadata": {"name": "expr_template_smoke", "authors": ["esm-giy"]},
  "reaction_systems": {
    "chem": {
      "species": {"A": {"default": 1.0}, "B": {"default": 0.5}, "C": {"default": 0.0}},
      "parameters": {"T": {"default": 298.15}, "num_density": {"default": 2.5e19}},
      "expression_templates": {
        "arrhenius": {
          "params": ["A_pre", "Ea"],
          "body": {
            "op": "*",
            "args": [
              "A_pre",
              {"op": "exp", "args": [
                {"op": "/", "args": [{"op": "-", "args": ["Ea"]}, "T"]}
              ]},
              "num_density"
            ]
          }
        }
      },
      "reactions": [
        {"id": "R1",
         "substrates": [{"species": "A", "stoichiometry": 1}],
         "products": [{"species": "B", "stoichiometry": 1}],
         "rate": {"op": "apply_expression_template", "args": [],
                  "name": "arrhenius",
                  "bindings": {"A_pre": 1.8e-12, "Ea": 1500}}},
        {"id": "R2",
         "substrates": [{"species": "B", "stoichiometry": 1}],
         "products": [{"species": "C", "stoichiometry": 1}],
         "rate": {"op": "apply_expression_template", "args": [],
                  "name": "arrhenius",
                  "bindings": {"A_pre": 3.4e-13, "Ea": 800}}}
      ]
    }
  }
}
"""

@testset "expression_templates / apply_expression_template (esm-giy)" begin
    @testset "expansion at load time strips templates and produces inline AST" begin
        io = IOBuffer(ARRHENIUS_FIXTURE_JSON)
        file = EarthSciSerialization.load(io)
        rs = file.reaction_systems["chem"]
        # Sanity: expanded rate is a `*` with three args.
        rate1 = rs.reactions[1].rate
        @test rate1 isa OpExpr
        @test rate1.op == "*"
        @test length(rate1.args) == 3
        # First arg: scalar 1.8e-12
        @test rate1.args[1] isa NumExpr
        @test rate1.args[1].value ≈ 1.8e-12
        # Second arg: exp((-1500)/T)
        exp_node = rate1.args[2]
        @test exp_node isa OpExpr
        @test exp_node.op == "exp"
        # Third arg: variable "num_density"
        @test rate1.args[3] isa VarExpr
        @test rate1.args[3].name == "num_density"
    end

    @testset "files without templates parse unchanged" begin
        no_templates = """
        {
          "esm": "0.4.0",
          "metadata": {"name": "no_templates", "authors": ["t"]},
          "reaction_systems": {
            "chem": {
              "species": {"A": {}},
              "parameters": {"k": {"default": 1.0}},
              "reactions": [{
                "id": "R1",
                "substrates": [{"species": "A", "stoichiometry": 1}],
                "products": null,
                "rate": "k"
              }]
            }
          }
        }
        """
        io = IOBuffer(no_templates)
        file = EarthSciSerialization.load(io)
        @test file.reaction_systems["chem"].reactions[1].rate.name == "k"
    end

    @testset "rejects apply_expression_template when esm < 0.4.0" begin
        old_version = replace(ARRHENIUS_FIXTURE_JSON, "\"esm\": \"0.4.0\"" => "\"esm\": \"0.3.5\"")
        io = IOBuffer(old_version)
        @test_throws ExpressionTemplateError EarthSciSerialization.load(io)
    end

    @testset "rejects unknown template name" begin
        bad = replace(ARRHENIUS_FIXTURE_JSON, "\"name\": \"arrhenius\"" => "\"name\": \"unknown_form\"", count=1)
        io = IOBuffer(bad)
        err = nothing
        try
            EarthSciSerialization.load(io)
        catch e
            err = e
        end
        @test err isa ExpressionTemplateError
        @test err.code == "apply_expression_template_unknown_template"
    end

    @testset "rejects bindings missing a param" begin
        # Drop Ea from the first reaction's bindings.
        bad = replace(ARRHENIUS_FIXTURE_JSON,
            "\"bindings\": {\"A_pre\": 1.8e-12, \"Ea\": 1500}" => "\"bindings\": {\"A_pre\": 1.8e-12}")
        io = IOBuffer(bad)
        err = nothing
        try
            EarthSciSerialization.load(io)
        catch e
            err = e
        end
        @test err isa ExpressionTemplateError
        @test err.code == "apply_expression_template_bindings_mismatch"
    end

    @testset "rejects extra bindings entries" begin
        bad = replace(ARRHENIUS_FIXTURE_JSON,
            "\"bindings\": {\"A_pre\": 1.8e-12, \"Ea\": 1500}" =>
            "\"bindings\": {\"A_pre\": 1.8e-12, \"Ea\": 1500, \"bogus\": 99}")
        io = IOBuffer(bad)
        err = nothing
        try
            EarthSciSerialization.load(io)
        catch e
            err = e
        end
        @test err isa ExpressionTemplateError
        @test err.code == "apply_expression_template_bindings_mismatch"
    end

    @testset "rejects nested apply_expression_template inside template body" begin
        bad = replace(ARRHENIUS_FIXTURE_JSON,
            "\"body\": {\n            \"op\": \"*\"" =>
            "\"body\": {\n            \"op\": \"apply_expression_template\", \"args\": [], \"name\": \"arrhenius\", \"bindings\": {\"A_pre\": 1, \"Ea\": 1}, \"_dummy\": {\"op\": \"*\"")
        # Above injection is too messy — use a cleaner fixture.
        nested = """
        {
          "esm": "0.4.0",
          "metadata": {"name": "nested", "authors": ["t"]},
          "reaction_systems": {
            "chem": {
              "species": {"A": {}, "B": {}},
              "parameters": {"T": {"default": 1.0}},
              "expression_templates": {
                "outer": {
                  "params": ["x"],
                  "body": {"op": "apply_expression_template", "args": [],
                           "name": "outer",
                           "bindings": {"x": "T"}}
                }
              },
              "reactions": [{
                "id": "R1",
                "substrates": [{"species": "A", "stoichiometry": 1}],
                "products": [{"species": "B", "stoichiometry": 1}],
                "rate": {"op": "apply_expression_template", "args": [],
                         "name": "outer",
                         "bindings": {"x": 1.0}}
              }]
            }
          }
        }
        """
        io = IOBuffer(nested)
        err = nothing
        try
            EarthSciSerialization.load(io)
        catch e
            err = e
        end
        @test err isa ExpressionTemplateError
        @test err.code == "apply_expression_template_recursive_body"
    end

    @testset "conformance fixture matches the canonical expanded form" begin
        # Drives the cross-binding `tests/conformance/expression_templates/`
        # arrhenius_smoke fixture against its pinned expanded.esm form.
        repo_root = abspath(joinpath(@__DIR__, "..", "..", ".."))
        fixture_path = joinpath(repo_root, "tests", "conformance",
            "expression_templates", "arrhenius_smoke", "fixture.esm")
        expanded_path = joinpath(repo_root, "tests", "conformance",
            "expression_templates", "arrhenius_smoke", "expanded.esm")
        raw = JSON3.read(read(fixture_path, String))
        expanded_via_pass = lower_expression_templates(raw)
        expanded_dict = JSON3.read(read(expanded_path, String))
        # Compare reactions arrays as JSON-normalised strings.
        function _norm(x)
            if x isa AbstractDict || x isa JSON3.Object
                return Dict{String,Any}(string(k) => _norm(v) for (k, v) in pairs(x))
            elseif x isa AbstractVector || x isa JSON3.Array
                return Any[_norm(v) for v in x]
            else
                return x
            end
        end
        got = _norm(expanded_via_pass.data["reaction_systems"]["chem"]["reactions"])
        want = _norm(expanded_dict.reaction_systems.chem.reactions)
        @test got == want
    end

    @testset "coupling_transform_expression conformance fixture matches expanded form" begin
        # The v0.8.0 variable_map expression-transform widening (esm-spec
        # §10.4/§10.5): a coupling `transform` invoking a template declared by
        # the RECEIVING component expands at load against that component's
        # registry (§9.6.4).
        repo_root = abspath(joinpath(@__DIR__, "..", "..", ".."))
        case = joinpath(repo_root, "tests", "conformance",
            "expression_templates", "coupling_transform_expression")
        raw = JSON3.read(read(joinpath(case, "fixture.esm"), String))
        expanded_via_pass = lower_expression_templates(raw)
        expanded_dict = JSON3.read(read(joinpath(case, "expanded.esm"), String))
        function _norm2(x)
            if x isa AbstractDict || x isa JSON3.Object
                return Dict{String,Any}(string(k) => _norm2(v) for (k, v) in pairs(x))
            elseif x isa AbstractVector || x isa JSON3.Array
                return Any[_norm2(v) for v in x]
            else
                return x
            end
        end
        @test _norm2(expanded_via_pass.data["coupling"]) ==
              _norm2(expanded_dict.coupling)
        @test _norm2(expanded_via_pass.data["models"]) ==
              _norm2(expanded_dict.models)
        # Typed load: the expanded transform arrives as an Expr operator node.
        f = EarthSciSerialization.load(joinpath(case, "fixture.esm"))
        entry = f.coupling[1]
        @test entry isa CouplingVariableMap
        @test entry.transform isa OpExpr
        @test (entry.transform::OpExpr).op == "+"
    end

    @testset "AST-valued bindings are accepted and substituted" begin
        # Bind `Ea` to an expression `(3 * T)` rather than a scalar.
        ast_bound = replace(ARRHENIUS_FIXTURE_JSON,
            "\"bindings\": {\"A_pre\": 1.8e-12, \"Ea\": 1500}" =>
            "\"bindings\": {\"A_pre\": 1.8e-12, \"Ea\": {\"op\": \"*\", \"args\": [3, \"T\"]}}")
        io = IOBuffer(ast_bound)
        file = EarthSciSerialization.load(io)
        rate = file.reaction_systems["chem"].reactions[1].rate
        @test rate isa OpExpr
        @test rate.op == "*"
        # The exp(...) sub-AST should now contain a (3*T) inside the negation.
        exp_node = rate.args[2]
        @test exp_node.op == "exp"
        # Drill into exp(-Ea/T) to find the substituted multiplication.
        div_node = exp_node.args[1]
        @test div_node.op == "/"
        neg_node = div_node.args[1]
        @test neg_node.op == "-"
        mul_node = neg_node.args[1]
        @test mul_node isa OpExpr
        @test mul_node.op == "*"
    end
end

@testset "expression_templates rewrite engine — 0.8.0 outermost-first + fixpoint" begin
    _repo_root() = abspath(joinpath(@__DIR__, "..", "..", ".."))
    _conf(fix) = joinpath(_repo_root(), "tests", "conformance",
                          "expression_templates", fix)
    _normj(x) =
        (x isa AbstractDict || x isa JSON3.Object) ?
            Dict{String,Any}(string(k) => _normj(v) for (k, v) in pairs(x)) :
        (x isa AbstractVector || x isa JSON3.Array) ?
            Any[_normj(v) for v in x] : x

    function _lower_conf(fix)
        raw = JSON3.read(read(joinpath(_conf(fix), "fixture.esm"), String))
        return lower_expression_templates(raw)
    end
    function _expanded_vars(fix)
        exp = JSON3.read(read(joinpath(_conf(fix), "expanded.esm"), String))
        return _normj(exp.models.m.variables)
    end

    @testset "godunov compound rule beats inner derivative (priority + outermost-first)" begin
        # Anti-regression for the old innermost-first/bottom-up single pass:
        # the priority:100 compound rule must fire on the WHOLE
        # sqrt(D(u,x)^2 + D(u,y)^2) before the priority:0 central-difference D
        # rule can lower either inner D. The expanded form is `godunov_coef * u`
        # — crucially with NO `inv_dx` (which only the per-derivative rule emits).
        out = _lower_conf("godunov_beats_inner_deriv")
        got = _normj(out.data["models"]["m"]["variables"])
        @test got == _expanded_vars("godunov_beats_inner_deriv")
        # Guard the rewritten EXPRESSION subtree only (the variables dict still
        # declares an `inv_dx` parameter): the compound rule's product appears,
        # the per-derivative rule's `inv_dx` product does not.
        expr_json = JSON3.write(got["grad_mag"]["expression"])
        @test !occursin("inv_dx", expr_json)
        @test occursin("godunov_coef", expr_json)
    end

    @testset "nested-derivative fixpoint converges across passes" begin
        # laplacian -> D(D(u,x),x)+D(D(u,y),y) (pass 1), then each nested D ->
        # stencil (pass 2). Exercises the bounded fixpoint: a produced body is
        # re-scanned only in a SUBSEQUENT pass.
        out = _lower_conf("fixpoint_nested_deriv")
        got = _normj(out.data["models"]["m"]["variables"])
        @test got == _expanded_vars("fixpoint_nested_deriv")
        expr_json = JSON3.write(got["lap"]["expression"])
        @test !occursin("laplacian", expr_json)
        @test !occursin("\"D\"", expr_json)
    end

    @testset "self-reintroducing rule rejected by the pass bound" begin
        err = try
            _lower_conf("nonterminating_rewrite")
            nothing
        catch e
            e
        end
        @test err isa ExpressionTemplateError
        @test err.code == "rewrite_rule_nonterminating"
    end

    @testset "unlowered spatial D loads under the open namespace" begin
        # The op namespace is open (esm-spec §4.2): a spatial D with no rule is
        # tolerated at LOAD. It is rejected with `unlowered_operator` only when
        # it reaches evaluation/compilation — the `_compile` gate proven in
        # tree_walk_test.jl ("unlowered rewrite-target op surfaced before
        # evaluation") and driven end-to-end for this fixture by the simulate
        # conformance harness.
        io = IOBuffer(read(joinpath(_conf("unlowered_operator"), "fixture.esm")))
        f = EarthSciSerialization.load(io)
        @test f isa EarthSciSerialization.EsmFile
    end

    @testset "attrs on a rewrite-target op bind as scalar metavariables" begin
        # esm-spec §4.2 open tier / RFC Change A: a custom op carries scheme
        # params in `attrs`; a `match` pattern's `attrs.<key>` set to a bare
        # param binds it to the matched literal. This falls out of generic
        # structural matching — no special-casing in the engine.
        src = """
        {
          "esm": "0.8.0",
          "metadata": {"name": "attrs_match", "authors": ["t"]},
          "models": {"m": {
            "variables": {
              "u": {"type": "state", "units": "1", "default": 0.0},
              "y": {"type": "observed", "units": "1",
                "expression": {"op": "custom_scheme", "args": ["u"], "attrs": {"gamma": 1.4}}}
            },
            "equations": [],
            "expression_templates": {
              "lower_custom": {
                "params": ["f", "g"],
                "match": {"op": "custom_scheme", "args": ["f"], "attrs": {"gamma": "g"}},
                "body": {"op": "*", "args": ["g", "f"]}
              }
            }
          }}
        }
        """
        out = lower_expression_templates(JSON3.read(src))
        expr = _normj(out.data["models"]["m"]["variables"]["y"]["expression"])
        @test expr == Dict{String,Any}("op" => "*", "args" => Any[1.4, "u"])
    end
end
