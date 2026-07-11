# Unit tests for expression_templates / apply_expression_template
# (esm-spec §9.6, docs/rfcs/ast-expression-templates.md, esm-giy).

using Test
using JSON3
using EarthSciAST
using EarthSciAST: lower_expression_templates,
    reject_expression_templates_pre_v04, ExpressionTemplateError, OpExpr,
    NumExpr, IntExpr, VarExpr

include("testutils.jl")  # TESTUTILS_REPO_ROOT + _normj

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
        file = EarthSciAST.load(io)
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
        file = EarthSciAST.load(io)
        @test file.reaction_systems["chem"].reactions[1].rate.name == "k"
    end

    @testset "rejects apply_expression_template when esm < 0.4.0" begin
        old_version = replace(ARRHENIUS_FIXTURE_JSON, "\"esm\": \"0.4.0\"" => "\"esm\": \"0.3.5\"")
        io = IOBuffer(old_version)
        @test_throws ExpressionTemplateError EarthSciAST.load(io)
    end

    @testset "rejects unknown template name" begin
        bad = replace(ARRHENIUS_FIXTURE_JSON, "\"name\": \"arrhenius\"" => "\"name\": \"unknown_form\"", count=1)
        io = IOBuffer(bad)
        err = nothing
        try
            EarthSciAST.load(io)
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
            EarthSciAST.load(io)
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
            EarthSciAST.load(io)
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
            EarthSciAST.load(io)
        catch e
            err = e
        end
        @test err isa ExpressionTemplateError
        @test err.code == "apply_expression_template_recursive_body"
    end

    @testset "conformance fixture matches the canonical expanded form" begin
        # Drives the cross-binding `tests/conformance/expression_templates/`
        # arrhenius_smoke fixture against its pinned expanded.esm form.
        repo_root = TESTUTILS_REPO_ROOT
        fixture_path = joinpath(repo_root, "tests", "conformance",
            "expression_templates", "arrhenius_smoke", "fixture.esm")
        expanded_path = joinpath(repo_root, "tests", "conformance",
            "expression_templates", "arrhenius_smoke", "expanded.esm")
        raw = JSON3.read(read(fixture_path, String))
        expanded_via_pass = lower_expression_templates(raw)
        expanded_dict = JSON3.read(read(expanded_path, String))
        # Compare reactions arrays in JSON-normalised (testutils.jl _normj) form.
        got = _normj(expanded_via_pass.data["reaction_systems"]["chem"]["reactions"])
        want = _normj(expanded_dict.reaction_systems.chem.reactions)
        @test got == want
    end

    @testset "coupling_transform_expression conformance fixture matches expanded form" begin
        # The v0.8.0 variable_map expression-transform widening (esm-spec
        # §10.4/§10.5): a coupling `transform` invoking a template declared by
        # the RECEIVING component expands at load against that component's
        # registry (§9.6.4).
        repo_root = TESTUTILS_REPO_ROOT
        case = joinpath(repo_root, "tests", "conformance",
            "expression_templates", "coupling_transform_expression")
        raw = JSON3.read(read(joinpath(case, "fixture.esm"), String))
        expanded_via_pass = lower_expression_templates(raw)
        expanded_dict = JSON3.read(read(joinpath(case, "expanded.esm"), String))
        @test _normj(expanded_via_pass.data["coupling"]) ==
              _normj(expanded_dict.coupling)
        @test _normj(expanded_via_pass.data["models"]) ==
              _normj(expanded_dict.models)
        # Typed load: the expanded transform arrives as an ASTExpr operator node.
        f = EarthSciAST.load(joinpath(case, "fixture.esm"))
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
        file = EarthSciAST.load(io)
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
    _conf(fix) = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                          "expression_templates", fix)

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
        f = EarthSciAST.load(io)
        @test f isa EarthSciAST.EsmFile
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

@testset "scalar-field template-parameter substitution (esm-spec §9.6.1 / §9.6.3 constraint 5)" begin
    # A parameter name appearing as the string value of a scalar Expression-node
    # field in `body` is a substitution site (the mirror of the match-side
    # scalar-field binding rule). `manifold` is the exemplar field: the document
    # schema admits any string there; the closed set {planar, spherical,
    # geodesic} is enforced on the EXPANDED form (§9.6.4).
    @testset "scalar-field substitution happy path" begin
        src = """
        {
          "esm": "0.8.0",
          "metadata": {"name": "scalar_field_param_unit", "authors": ["t"]},
          "models": {"M": {
            "variables": {
              "pa": {"type": "parameter"},
              "pb": {"type": "parameter"},
              "area": {"type": "observed",
                "expression": {"op": "apply_expression_template", "args": [],
                  "name": "overlap_area",
                  "bindings": {"K_manifold": "planar", "a": "pa", "b": "pb"}}}
            },
            "equations": [],
            "expression_templates": {
              "overlap_area": {
                "params": ["K_manifold", "a", "b"],
                "body": {"op": "polygon_intersection_area",
                         "manifold": "K_manifold", "args": ["a", "b"]}
              }
            }
          }}
        }
        """
        out = lower_expression_templates(JSON3.read(src))
        expr = _normj(out.data["models"]["M"]["variables"]["area"]["expression"])
        @test expr == Dict{String,Any}(
            "op" => "polygon_intersection_area",
            "manifold" => "planar",
            "args" => Any["pa", "pb"])
    end

    @testset "scalar-field param threads through registration-time body composition (§9.7.3)" begin
        src = """
        {
          "esm": "0.8.0",
          "metadata": {"name": "scalar_field_param_nested", "authors": ["t"]},
          "models": {"M": {
            "variables": {
              "pa": {"type": "parameter"},
              "pb": {"type": "parameter"},
              "scaled": {"type": "observed",
                "expression": {"op": "apply_expression_template", "args": [],
                  "name": "outer",
                  "bindings": {"K": "spherical", "p": "pa", "q": "pb"}}}
            },
            "equations": [],
            "expression_templates": {
              "inner": {
                "params": ["m", "x", "y"],
                "body": {"op": "polygon_intersection_area", "manifold": "m",
                         "args": ["x", "y"]}
              },
              "outer": {
                "params": ["K", "p", "q"],
                "body": {"op": "*", "args": [
                  {"op": "apply_expression_template", "args": [], "name": "inner",
                   "bindings": {"m": "K", "x": "p", "y": "q"}},
                  2.0]}
              }
            }
          }}
        }
        """
        out = lower_expression_templates(JSON3.read(src))
        expr = _normj(out.data["models"]["M"]["variables"]["scaled"]["expression"])
        @test expr == Dict{String,Any}("op" => "*", "args" => Any[
            Dict{String,Any}("op" => "polygon_intersection_area",
                             "manifold" => "spherical",
                             "args" => Any["pa", "pb"]),
            2.0])
    end

    @testset "invalid substituted manifold rejected post-expansion (§9.6.4)" begin
        src = """
        {
          "esm": "0.8.0",
          "metadata": {"name": "scalar_field_param_bogus", "authors": ["t"]},
          "models": {"M": {
            "variables": {
              "pa": {"type": "parameter"},
              "pb": {"type": "parameter"},
              "area": {"type": "observed",
                "expression": {"op": "apply_expression_template", "args": [],
                  "name": "overlap_area",
                  "bindings": {"K_manifold": "bogus", "a": "pa", "b": "pb"}}}
            },
            "equations": [],
            "expression_templates": {
              "overlap_area": {
                "params": ["K_manifold", "a", "b"],
                "body": {"op": "polygon_intersection_area",
                         "manifold": "K_manifold", "args": ["a", "b"]}
              }
            }
          }}
        }
        """
        err = try
            lower_expression_templates(JSON3.read(src))
            nothing
        catch e
            e
        end
        @test err isa ExpressionTemplateError
        @test err.code == "geometry_manifold_invalid"
    end

    @testset "params shadow literals: a param named after a field literal substitutes" begin
        # Authoring guidance says don't do this (esm-spec §9.6.1) — but when an
        # author does, the pinned resolution is that the param WINS: every
        # string value equal to a declared param name is a substitution site.
        src = """
        {
          "esm": "0.8.0",
          "metadata": {"name": "scalar_field_param_shadow", "authors": ["t"]},
          "models": {"M": {
            "variables": {
              "pa": {"type": "parameter"},
              "pb": {"type": "parameter"},
              "area": {"type": "observed",
                "expression": {"op": "apply_expression_template", "args": [],
                  "name": "shadowed",
                  "bindings": {"planar": "spherical", "x": "pa", "y": "pb"}}}
            },
            "equations": [],
            "expression_templates": {
              "shadowed": {
                "params": ["planar", "x", "y"],
                "body": {"op": "polygon_intersection_area",
                         "manifold": "planar", "args": ["x", "y"]}
              }
            }
          }}
        }
        """
        out = lower_expression_templates(JSON3.read(src))
        expr = _normj(out.data["models"]["M"]["variables"]["area"]["expression"])
        @test expr["manifold"] == "spherical"
    end
end

@testset "scalar_field_param conformance fixture matches the canonical expanded form" begin
    # Drives tests/conformance/expression_templates/scalar_field_param — the
    # scalar-field substitution site rule (esm-spec §9.6.1) instantiated twice
    # (planar / spherical) — against its pinned Julia-generated expanded.esm.
    case = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
        "expression_templates", "scalar_field_param")
    raw = JSON3.read(read(joinpath(case, "fixture.esm"), String))
    out = lower_expression_templates(raw)
    expanded = JSON3.read(read(joinpath(case, "expanded.esm"), String))
    @test _normj(out.data["models"]) == _normj(expanded.models)
    vars = _normj(out.data["models"]["Overlap"]["variables"])
    @test vars["area_planar"]["expression"]["manifold"] == "planar"
    @test vars["area_spherical"]["expression"]["manifold"] == "spherical"
end

@testset "match-pattern scoping constraints (where, esm-spec §9.6.1)" begin
    # docs/content/rfcs/match-pattern-scoping-constraints.md: static
    # index-set/shape scoping of `match` rules. Constraint evaluation reads
    # declared variable shapes only and filters BEFORE the §9.6.3
    # priority/declaration-order selection.
    _conf2(fix) = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                           "expression_templates", fix)
    _nw(x) =
        (x isa AbstractDict || x isa JSON3.Object) ?
            Dict{String,Any}(string(k) => _nw(v) for (k, v) in pairs(x)) :
        (x isa AbstractVector || x isa JSON3.Array) ?
            Any[_nw(v) for v in x] : x
    function _lower2(fix)
        raw = JSON3.read(read(joinpath(_conf2(fix), "fixture.esm"), String))
        return lower_expression_templates(raw)
    end
    _golden_vars(fix) = _nw(JSON3.read(read(joinpath(_conf2(fix), "expanded.esm"),
                                            String)).models.m.variables)

    @testset "constrained_match_scope: positive + negative in one document" begin
        out = _lower2("constrained_match_scope")
        got = _nw(out.data["models"]["m"]["variables"])
        @test got == _golden_vars("constrained_match_scope")
        # div(F_edge) rewritten; div(F_cell) constraint-excluded, survives.
        @test got["div_edge"]["expression"]["op"] == "*"
        @test got["div_cell"]["expression"]["op"] == "div"
    end

    @testset "two_div_two_meshes: identical patterns, disjoint shape scopes" begin
        out = _lower2("two_div_two_meshes")
        got = _nw(out.data["models"]["m"]["variables"])
        @test got == _golden_vars("two_div_two_meshes")
        # Each div lowered by ITS mesh's rule — not both by the
        # first-declared rule (the pre-`where` declaration-order behavior).
        @test got["div_a"]["expression"]["args"][1] == "inv_area_a"
        @test got["div_b"]["expression"]["args"][1] == "inv_area_b"
    end

    @testset "per-variable selectivity via ground args (sanctioned mechanism)" begin
        out = _lower2("per_variable_scheme_literal_args")
        got = _nw(out.data["models"]["m"]["variables"])
        @test got == _golden_vars("per_variable_scheme_literal_args")
        @test got["du"]["expression"]["args"][1] == "upwind_coef"
        @test got["dv"]["expression"]["args"][1] == "central_coef"
    end

    @testset "unknown index set in a constraint rejected at registration" begin
        err = try
            _lower2("constraint_unknown_index_set")
            nothing
        catch e
            e
        end
        @test err isa ExpressionTemplateError
        @test err.code == "template_constraint_unknown_index_set"
        @test occursin("edges", err.message)
    end

    _scoped_doc(templates_json) = """
    {
      "esm": "0.8.0",
      "metadata": {"name": "where_unit"},
      "index_sets": {
        "cells": {"kind": "interval", "size": 4},
        "edges": {"kind": "interval", "size": 6}
      },
      "models": {
        "m": {
          "variables": {
            "F_edge": {"type": "state", "units": "1", "default": 1.5, "shape": ["edges"]},
            "F_cell": {"type": "state", "units": "1", "default": 2.5, "shape": ["cells"]},
            "s": {"type": "parameter", "units": "1", "default": 0.5},
            "d": {"type": "observed", "units": "1",
                  "expression": {"op": "div", "args": ["F_cell"]}}
          },
          "equations": [],
          "expression_templates": $templates_json
        }
      }
    }
    """

    @testset "constraints filter BEFORE priority selection" begin
        # A priority-10 constraint-excluded rule must NOT shadow the
        # priority-0 unconstrained rule (esm-spec §9.6.3 constraint 2).
        src = _scoped_doc("""
        {
          "fancy_edges_only": {
            "params": ["F"], "priority": 10,
            "match": {"op": "div", "args": ["F"]},
            "where": {"F": {"shape": ["edges"]}},
            "body": {"op": "*", "args": [1.5, "F"]}
          },
          "plain_any": {
            "params": ["F"], "priority": 0,
            "match": {"op": "div", "args": ["F"]},
            "body": {"op": "*", "args": ["s", "F"]}
          }
        }
        """)
        out = lower_expression_templates(JSON3.read(src))
        expr = _nw(out.data["models"]["m"]["variables"]["d"]["expression"])
        @test expr["op"] == "*"
        @test expr["args"][1] == "s"   # plain rule fired, not the fancy one
    end

    @testset "compound argument fails a shape constraint (conservative judgment)" begin
        # div(2.5 * F_edge): the bound sub-AST is not a bare variable
        # reference, so the constraint fails and the node survives.
        src = replace(_scoped_doc("""
        {
          "edges_only": {
            "params": ["F"],
            "match": {"op": "div", "args": ["F"]},
            "where": {"F": {"shape": ["edges"]}},
            "body": {"op": "*", "args": ["s", "F"]}
          }
        }
        """), "{\"op\": \"div\", \"args\": [\"F_cell\"]}" =>
              "{\"op\": \"div\", \"args\": [{\"op\": \"*\", \"args\": [2.5, \"F_edge\"]}]}")
        out = lower_expression_templates(JSON3.read(src))
        expr = _nw(out.data["models"]["m"]["variables"]["d"]["expression"])
        @test expr["op"] == "div"   # never rewritten; not an error
    end

    @testset "where without match is an invalid declaration" begin
        src = _scoped_doc("""
        {
          "broken": {
            "params": ["F"],
            "where": {"F": {"shape": ["edges"]}},
            "body": {"op": "*", "args": ["s", "F"]}
          }
        }
        """)
        err = try lower_expression_templates(JSON3.read(src)); nothing catch e; e end
        @test err isa ExpressionTemplateError
        @test err.code == "apply_expression_template_invalid_declaration"
    end

    @testset "where key must be a declared param" begin
        src = _scoped_doc("""
        {
          "broken": {
            "params": ["F"],
            "match": {"op": "div", "args": ["F"]},
            "where": {"G": {"shape": ["edges"]}},
            "body": {"op": "*", "args": ["s", "F"]}
          }
        }
        """)
        err = try lower_expression_templates(JSON3.read(src)); nothing catch e; e end
        @test err isa ExpressionTemplateError
        @test err.code == "apply_expression_template_invalid_declaration"
    end

    @testset "unknown constraint kind rejected (v1 vocabulary is exactly shape)" begin
        src = _scoped_doc("""
        {
          "broken": {
            "params": ["F"],
            "match": {"op": "div", "args": ["F"]},
            "where": {"F": {"units": "m"}},
            "body": {"op": "*", "args": ["s", "F"]}
          }
        }
        """)
        err = try lower_expression_templates(JSON3.read(src)); nothing catch e; e end
        @test err isa ExpressionTemplateError
        @test err.code == "apply_expression_template_invalid_declaration"
    end

    @testset "shape must match exactly (names AND order)" begin
        # F_cell is over [cells]; a constraint over [cells, edges] fails.
        src = _scoped_doc("""
        {
          "two_axes_only": {
            "params": ["F"],
            "match": {"op": "div", "args": ["F"]},
            "where": {"F": {"shape": ["cells", "edges"]}},
            "body": {"op": "*", "args": ["s", "F"]}
          }
        }
        """)
        out = lower_expression_templates(JSON3.read(src))
        expr = _nw(out.data["models"]["m"]["variables"]["d"]["expression"])
        @test expr["op"] == "div"   # constraint unsatisfied; rule never fires
    end
end

@testset "where constraints on rules arriving via §9.7 library import" begin
    # A shape-constrained rule declared in a template-library file: the
    # library's index_sets merge into the consuming document's registry
    # (§9.7.5) BEFORE rule registration, so the constraint's names resolve
    # there (esm-spec §9.6.1) — and the constraint scopes the imported rule
    # inside the consuming component.
    mktempdir() do dir
        write(joinpath(dir, "meshlib.esm"), """
        {
          "esm": "0.8.0",
          "metadata": {"name": "meshlib"},
          "index_sets": {
            "cells": {"kind": "interval", "size": 4},
            "edges": {"kind": "interval", "size": 6}
          },
          "expression_templates": {
            "fv_div_edges": {
              "params": ["F"],
              "match": {"op": "div", "args": ["F"]},
              "where": {"F": {"shape": ["edges"]}},
              "body": {"op": "*", "args": [0.5, "F"]}
            }
          }
        }
        """)
        model_path = joinpath(dir, "consumer.esm")
        write(model_path, """
        {
          "esm": "0.8.0",
          "metadata": {"name": "consumer"},
          "models": {
            "m": {
              "expression_template_imports": [{"ref": "meshlib.esm"}],
              "variables": {
                "F_edge": {"type": "state", "units": "1", "default": 1.5, "shape": ["edges"]},
                "F_cell": {"type": "state", "units": "1", "default": 2.5, "shape": ["cells"]},
                "d_edge": {"type": "observed", "units": "1",
                           "expression": {"op": "div", "args": ["F_edge"]}},
                "d_cell": {"type": "observed", "units": "1",
                           "expression": {"op": "div", "args": ["F_cell"]}}
              },
              "equations": []
            }
          }
        }
        """)
        f = EarthSciAST.load(model_path)
        vars = f.models["m"].variables
        @test (vars["d_edge"].expression::OpExpr).op == "*"     # constrained rule fired
        @test (vars["d_cell"].expression::OpExpr).op == "div"   # excluded, survives load
        @test f.index_sets["edges"].size == 6                   # merged registry
    end
end

# ---------------------------------------------------------------------------
# Diagnostic-code registry coverage (src/lower_expression_templates.jl).
# `_KNOWN_DIAGNOSTIC_CODES` documents itself as "the single registry of every
# code this exception is raised with" — hold src/ to that: scan every source
# file for `ExpressionTemplateError("<code>", …)` raise sites and assert the
# raised codes are a subset of the registry.
# ---------------------------------------------------------------------------
@testset "every raised ExpressionTemplateError code is registered" begin
    src_dir = normpath(joinpath(@__DIR__, "..", "src"))
    raised = Set{String}()
    for (root, _, files) in walkdir(src_dir), file in files
        endswith(file, ".jl") || continue
        text = read(joinpath(root, file), String)
        # First string-literal argument of each raise site (the code). The two
        # sites in template_imports.jl `_merge_named!` pass the code through a
        # variable (template_import_name_conflict /
        # template_import_index_set_conflict — asserted registered below) and
        # are deliberately not matched by this literal-only pattern.
        for m in eachmatch(r"ExpressionTemplateError\(\s*\"([^\"]+)\"", text)
            push!(raised, m.captures[1])
        end
    end
    # Guard the scan itself: a pattern/layout drift that matched nothing would
    # pass the subset check vacuously.
    @test length(raised) >= 30
    registry = Set{String}(EarthSciAST._KNOWN_DIAGNOSTIC_CODES)
    @test isempty(setdiff(raised, registry))
    # The variable-code sites' codes are registered too.
    @test "template_import_name_conflict" in registry
    @test "template_import_index_set_conflict" in registry
end
