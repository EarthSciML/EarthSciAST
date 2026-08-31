//! Load-time rewrite engine for `expression_templates` (esm-spec §9.6 /
//! §9.6.3, docs/content/rfcs/open-op-namespace-fixpoint-rewrite.md).
//!
//! Each `expression_templates` entry is a rewrite rule with `params`
//! (metavariables) and a `body` (the replacement Expression), applied in one of
//! two ways: WITHOUT a `match` field it is invoked explicitly by an
//! `apply_expression_template` node; WITH a `match` field it is an auto-applied
//! rewrite rule fired wherever the pattern structurally matches a node.
//!
//! Rewriting is an OUTERMOST-FIRST, PRIORITY-ORDERED, BOUNDED-FIXPOINT process
//! (esm-spec §9.6.3). One pass (`rewrite_pass`) is a single pre-order
//! (outermost-first) walk: at each node the engine first tries to fire a rule
//! AT that node before descending — an `apply_expression_template` op is
//! expanded, otherwise the `match` rules are consulted and the winner is
//! selected deterministically (highest `priority`, ties broken by declaration
//! order). The winner's body replaces the node and the walk does NOT descend
//! into that freshly-produced body during the current pass. Passes repeat until
//! a pass performs zero rewrites (the fixpoint) or until `MAX_REWRITE_PASSES`
//! productive passes have run without converging, in which case the file is
//! rejected with `rewrite_rule_nonterminating` (the pass bound — not a static
//! check — is the authoritative termination guard). Because selection and
//! traversal are fully deterministic, all bindings produce byte-identical
//! fixpoints. After convergence the tree contains no `apply_expression_template`
//! ops and no `expression_templates` blocks — downstream consumers see only
//! normal Expression ASTs (Option A round-trip). Any rewrite-target op (e.g. a
//! spatial `D`) that survives the fixpoint into an evaluation position is caught
//! later by the `unlowered_operator` gate, not here.
//!
//! Operates on the pre-deserialization `serde_json::Value` view, so it must
//! run after schema validation but before deserializing into typed structs.

use serde_json::{Map, Value};
use std::rc::Rc;

const APPLY_OP: &str = "apply_expression_template";

/// Stable diagnostic codes raised by the expression-template expansion
/// pass. Mirrors the codes emitted by the TS / Python / Julia / Go bindings.
pub type ExpressionTemplateError = crate::diagnostic::DiagnosticError;

use crate::diagnostic::{codes, err};

mod emit;
mod expand;
mod mirror;
mod refaware;
mod rewrite;

pub use emit::*;
pub use expand::*;
pub use mirror::*;
use refaware::*;
pub use rewrite::*;

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn arrhenius_fixture() -> Value {
        json!({
          "esm": "1.0.0",
          "metadata": {"name": "expr_template_smoke", "authors": ["esm-giy"]},
          "reaction_systems": {
            "chem": {
              "species": {"A": {"default": 1.0}, "B": {"default": 0.5}},
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
                          "bindings": {"A_pre": 1.8e-12, "Ea": 1500}}}
              ]
            }
          }
        })
    }

    #[test]
    fn expansion_strips_templates_block_and_replaces_apply_node() {
        let mut v = arrhenius_fixture();
        // Option B: `arrhenius`'s body is pure evaluable-core, so its reference
        // SURVIVES load; `expand` produces the Option-A image (block stripped,
        // reference expanded) that the build path sees.
        lower_expression_templates(&mut v).expect("expansion");
        expand(&mut v).expect("expand");
        let chem = &v["reaction_systems"]["chem"];
        assert!(chem.get("expression_templates").is_none());
        let rate = &chem["reactions"][0]["rate"];
        assert_eq!(rate["op"], json!("*"));
        // First arg: the scalar 1.8e-12.
        assert_eq!(rate["args"][0], json!(1.8e-12));
    }

    #[test]
    fn rejects_unknown_template_name() {
        let mut v = arrhenius_fixture();
        v["reaction_systems"]["chem"]["reactions"][0]["rate"]["name"] = json!("missing");
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "apply_expression_template_unknown_template");
    }

    #[test]
    fn rejects_missing_binding() {
        let mut v = arrhenius_fixture();
        v["reaction_systems"]["chem"]["reactions"][0]["rate"]["bindings"]
            .as_object_mut()
            .unwrap()
            .remove("Ea");
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "apply_expression_template_bindings_mismatch");
    }

    #[test]
    fn rejects_extra_binding() {
        let mut v = arrhenius_fixture();
        v["reaction_systems"]["chem"]["reactions"][0]["rate"]["bindings"]["bogus"] = json!(99);
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "apply_expression_template_bindings_mismatch");
    }

    #[test]
    fn rejects_recursive_body() {
        let mut v = arrhenius_fixture();
        v["reaction_systems"]["chem"]["expression_templates"]["arrhenius"]["body"] = json!({
            "op": "apply_expression_template",
            "args": [],
            "name": "arrhenius",
            "bindings": {"A_pre": 1, "Ea": 1}
        });
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "apply_expression_template_recursive_body");
    }

    /// A chain of match-less templates T0..T12 where each T_i's body
    /// references T_{i-1} TWICE (esm-spec §9.7.3) logically expands to 2^12
    /// copies of the T0 leaf. Composition and call-site expansion must build
    /// this with structural sharing (shared DAGs, materialized into the owned
    /// document once): the old deep-copy substitution was exponential in time
    /// and memory across every intermediate — composed bodies, per-pass tree
    /// rebuilds, registry clones — and OOMed real ~4KB documents at depth 19
    /// while respecting every documented limit (chain depth <= 32). The
    /// expanded document itself is byte-identical either way; this pins the
    /// expansion's correctness at a depth where the pre-fix pipeline was
    /// already pathological.
    #[test]
    fn deep_double_reference_chain_expands_correctly() {
        const DEPTH: usize = 12;
        let apply = |name: &str| -> Value {
            json!({"op": APPLY_OP, "args": [], "name": name, "bindings": {}})
        };
        let mut templates = Map::new();
        templates.insert(
            "T0".to_string(),
            json!({"params": [], "body": {"op": "*", "args": [
                1.8e-12,
                {"op": "exp", "args": [
                    {"op": "/", "args": [{"op": "-", "args": [1500.0]}, "T"]}
                ]}
            ]}}),
        );
        for i in 1..=DEPTH {
            let prev = format!("T{}", i - 1);
            templates.insert(
                format!("T{i}"),
                json!({"params": [], "body": {"op": "+", "args": [apply(&prev), apply(&prev)]}}),
            );
        }
        let mut v = json!({
            "esm": "1.0.0",
            "metadata": {"name": "deep_chain", "authors": ["t"]},
            "reaction_systems": {"chem": {
                "species": {"A": {"default": 1.0}, "B": {"default": 0.5}},
                "parameters": {"T": {"default": 298.15}},
                "expression_templates": Value::Object(templates),
                "reactions": [{
                    "id": "R1",
                    "substrates": [{"species": "A", "stoichiometry": 1}],
                    "products": [{"species": "B", "stoichiometry": 1}],
                    "rate": apply(&format!("T{DEPTH}"))
                }]
            }}
        });
        lower_expression_templates(&mut v).expect("expansion");
        expand(&mut v).expect("expand");
        let chem = &v["reaction_systems"]["chem"];
        assert!(chem.get("expression_templates").is_none());
        let rate = &chem["reactions"][0]["rate"];
        assert_eq!(rate["op"], json!("+"));
        // Leftmost leaf: the T0 Arrhenius-style body, fully closed.
        let mut leaf = rate;
        while leaf["op"] == json!("+") {
            leaf = &leaf["args"][0];
        }
        assert_eq!(leaf["op"], json!("*"));
        assert_eq!(leaf["args"][0], json!(1.8e-12));
        // Node count of the materialized tree: the T0 body has 15 JSON values
        // and each `+` level contributes 3 (object + "op" string + args
        // array) plus its two children -> nodes(d) = 2^d * 18 - 3.
        fn count(v: &Value) -> usize {
            match v {
                Value::Array(a) => 1 + a.iter().map(count).sum::<usize>(),
                Value::Object(o) => 1 + o.values().map(count).sum::<usize>(),
                _ => 1,
            }
        }
        assert_eq!(count(rate), (1usize << DEPTH) * 18 - 3);
    }

    #[test]
    fn rejects_pre_v04_files_using_templates() {
        let mut v = arrhenius_fixture();
        v["esm"] = json!("0.3.5");
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "apply_expression_template_version_too_old");
    }

    #[test]
    fn ast_valued_bindings_substitute_into_body() {
        let mut v = arrhenius_fixture();
        v["reaction_systems"]["chem"]["reactions"][0]["rate"]["bindings"]["Ea"] = json!({
            "op": "*", "args": [3, "T"]
        });
        lower_expression_templates(&mut v).expect("expansion");
        expand(&mut v).expect("expand");
        let rate = &v["reaction_systems"]["chem"]["reactions"][0]["rate"];
        let exp_node = &rate["args"][1];
        assert_eq!(exp_node["op"], json!("exp"));
        let div_node = &exp_node["args"][0];
        assert_eq!(div_node["op"], json!("/"));
        let neg_node = &div_node["args"][0];
        assert_eq!(neg_node["op"], json!("-"));
        let inner = &neg_node["args"][0];
        assert_eq!(inner["op"], json!("*"));
    }

    #[test]
    fn conformance_fixture_matches_expanded_form() {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let repo_root = manifest_dir
            .parent()
            .and_then(|p| p.parent())
            .expect("repo_root from CARGO_MANIFEST_DIR")
            .to_path_buf();
        let fixture_path =
            repo_root.join("tests/conformance/expression_templates/arrhenius_smoke/fixture.esm");
        let expanded_path =
            repo_root.join("tests/conformance/expression_templates/arrhenius_smoke/expanded.esm");
        let src = std::fs::read_to_string(&fixture_path).expect("read fixture.esm");
        let mut got: Value = serde_json::from_str(&src).expect("parse fixture");
        lower_expression_templates(&mut got).expect("expansion");
        expand(&mut got).expect("expand");
        let expanded_src = std::fs::read_to_string(&expanded_path).expect("read expanded.esm");
        let want: Value = serde_json::from_str(&expanded_src).expect("parse expanded");
        let got_reactions = &got["reaction_systems"]["chem"]["reactions"];
        let want_reactions = &want["reaction_systems"]["chem"]["reactions"];
        assert_eq!(got_reactions, want_reactions);
    }

    /// The v0.8.0 variable_map expression-transform widening (esm-spec
    /// §10.4/§10.5): a coupling `transform` invoking a template declared by the
    /// RECEIVING component expands at load against that component's registry
    /// (§9.6.4). Cross-binding golden: expanded.esm.
    #[test]
    fn coupling_transform_expression_conformance_fixture_matches_expanded_form() {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let repo_root = manifest_dir
            .parent()
            .and_then(|p| p.parent())
            .expect("repo_root from CARGO_MANIFEST_DIR")
            .to_path_buf();
        let case =
            repo_root.join("tests/conformance/expression_templates/coupling_transform_expression");
        let src = std::fs::read_to_string(case.join("fixture.esm")).expect("read fixture.esm");
        let mut got: Value = serde_json::from_str(&src).expect("parse fixture");
        lower_expression_templates(&mut got).expect("expansion");
        expand(&mut got).expect("expand");
        let expanded_src =
            std::fs::read_to_string(case.join("expanded.esm")).expect("read expanded.esm");
        let want: Value = serde_json::from_str(&expanded_src).expect("parse expanded");
        assert_eq!(&got["coupling"], &want["coupling"]);
        assert_eq!(&got["models"], &want["models"]);
    }

    #[test]
    fn no_templates_block_is_a_noop() {
        let mut v = json!({
            "esm": "1.0.0",
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
        });
        lower_expression_templates(&mut v).expect("expansion");
        assert_eq!(
            v["reaction_systems"]["chem"]["reactions"][0]["rate"],
            json!("k")
        );
    }

    /// A `match` rule (esm-spec §9.6) auto-applies wherever its operator pattern
    /// matches — no `apply_expression_template` node required — binding an
    /// operand metavariable to the matched sub-AST. Non-matching siblings (the
    /// equation LHS) are left untouched.
    #[test]
    fn match_rule_lowers_grad_operator() {
        let mut v = json!({
          "esm": "1.0.0",
          "metadata": {"name": "grad_lowering", "authors": ["t"]},
          "models": {
            "Diff": {
              "variables": {"u": {"type": "unknown"}},
              "expression_templates": {
                "central_grad_x": {
                  "params": ["f"],
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {
                    "op": "-",
                    "args": [
                      {"op": "index", "args": ["f", {"op": "+", "args": ["i", 1]}]},
                      {"op": "index", "args": ["f", {"op": "-", "args": ["i", 1]}]}
                    ]
                  }
                }
              },
              "equations": [
                {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                 "rhs": {"op": "grad", "args": ["u"], "dim": "x"}}
              ]
            }
          }
        });
        lower_expression_templates(&mut v).expect("rewrite");
        expand(&mut v).expect("expand");
        let model = &v["models"]["Diff"];
        assert!(model.get("expression_templates").is_none());
        let rhs = &model["equations"][0]["rhs"];
        // grad(u, dim=x) lowered to the finite-difference body, f -> "u".
        assert_eq!(rhs["op"], json!("-"));
        assert_eq!(rhs["args"][0]["op"], json!("index"));
        assert_eq!(rhs["args"][0]["args"][0], json!("u"));
        assert_eq!(rhs["args"][1]["args"][0], json!("u"));
        // The non-matching LHS is left untouched.
        assert_eq!(model["equations"][0]["lhs"]["op"], json!("D"));
    }

    /// A metavariable appearing in a scalar field (`dim`) binds the matched
    /// literal, while one in `args` binds the matched sub-AST.
    #[test]
    fn match_rule_binds_scalar_field_metavariable() {
        let mut v = json!({
          "esm": "1.0.0",
          "metadata": {"name": "scalar_meta", "authors": ["t"]},
          "models": {
            "M": {
              "variables": {"u": {"type": "unknown"}},
              "expression_templates": {
                "grad_to_deriv": {
                  "params": ["f", "d"],
                  "match": {"op": "grad", "args": ["f"], "dim": "d"},
                  "body": {"op": "deriv", "args": ["f"], "wrt": "d"}
                }
              },
              "equations": [
                {"lhs": "u", "rhs": {"op": "grad", "args": ["u"], "dim": "y"}}
              ]
            }
          }
        });
        lower_expression_templates(&mut v).expect("rewrite");
        let rhs = &v["models"]["M"]["equations"][0]["rhs"];
        assert_eq!(rhs["op"], json!("deriv"));
        assert_eq!(rhs["args"][0], json!("u")); // operand metavar f -> "u"
        assert_eq!(rhs["wrt"], json!("y")); // scalar metavar d -> literal "y"
    }

    /// A `match` rule whose `body` re-introduces its own pattern never reaches a
    /// fixpoint. There is no static pre-check any more (esm-spec §9.6.3): the
    /// bounded fixpoint runs `MAX_REWRITE_PASSES` productive passes without
    /// converging and then rejects the file with `rewrite_rule_nonterminating`.
    #[test]
    fn rejects_nonterminating_match_rule() {
        let mut v = json!({
          "esm": "1.0.0",
          "metadata": {"name": "nonterm", "authors": ["t"]},
          "models": {
            "M": {
              "variables": {"u": {"type": "unknown"}},
              "expression_templates": {
                "loop_rule": {
                  "params": ["f"],
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {"op": "+", "args": [
                    {"op": "grad", "args": ["f"], "dim": "x"}, 1]}
                }
              },
              "equations": [
                {"lhs": "u", "rhs": {"op": "grad", "args": ["u"], "dim": "x"}}
              ]
            }
          }
        });
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "rewrite_rule_nonterminating");
    }

    /// Rules are applied in template *declaration order* (not the alphabetical
    /// key order of an unordered map): the first declared rule whose pattern
    /// matches wins. `z_rule` is declared before `a_rule`, so it must fire.
    #[test]
    fn match_rules_apply_in_declaration_order() {
        let mut v = json!({
          "esm": "1.0.0",
          "metadata": {"name": "order", "authors": ["t"]},
          "models": {
            "M": {
              "variables": {"u": {"type": "unknown"}},
              "expression_templates": {
                "z_rule": {
                  "params": ["f"],
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {"op": "winner", "args": ["f"]}
                },
                "a_rule": {
                  "params": ["f"],
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {"op": "loser", "args": ["f"]}
                }
              },
              "equations": [
                {"lhs": "u", "rhs": {"op": "grad", "args": ["u"], "dim": "x"}}
              ]
            }
          }
        });
        lower_expression_templates(&mut v).expect("rewrite");
        let rhs = &v["models"]["M"]["equations"][0]["rhs"];
        assert_eq!(rhs["op"], json!("winner"));
    }

    /// `priority` out-ranks declaration order (esm-spec §9.6.3): a
    /// later-declared rule with higher `priority` fires over an earlier-declared
    /// default-priority rule matching the same node.
    #[test]
    fn higher_priority_rule_wins_over_earlier_declared() {
        let mut v = json!({
          "esm": "1.0.0",
          "metadata": {"name": "prio", "authors": ["t"]},
          "models": {
            "M": {
              "variables": {"u": {"type": "unknown"}},
              "expression_templates": {
                "low": {
                  "params": ["f"],
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {"op": "loser", "args": ["f"]}
                },
                "high": {
                  "params": ["f"],
                  "priority": 100,
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {"op": "winner", "args": ["f"]}
                }
              },
              "equations": [
                {"lhs": "u", "rhs": {"op": "grad", "args": ["u"], "dim": "x"}}
              ]
            }
          }
        });
        lower_expression_templates(&mut v).expect("rewrite");
        assert_eq!(
            v["models"]["M"]["equations"][0]["rhs"]["op"],
            json!("winner")
        );
    }

    /// The bounded fixpoint re-scans a freshly-produced body only in a SUBSEQUENT
    /// pass (esm-spec §9.6.3): a sugar rule emits a nested op that a second rule
    /// lowers on the next pass, converging to a fully-lowered tree.
    #[test]
    fn produced_body_is_rescanned_in_a_later_pass() {
        let mut v = json!({
          "esm": "1.0.0",
          "metadata": {"name": "fixpoint", "authors": ["t"]},
          "models": {
            "M": {
              "variables": {"u": {"type": "unknown"}},
              "expression_templates": {
                "sugar": {
                  "params": ["f"],
                  "match": {"op": "sugar", "args": ["f"]},
                  "body": {"op": "inner", "args": ["f"]}
                },
                "inner_to_leaf": {
                  "params": ["f"],
                  "match": {"op": "inner", "args": ["f"]},
                  "body": {"op": "*", "args": ["k", "f"]}
                }
              },
              "equations": [
                {"lhs": "u", "rhs": {"op": "sugar", "args": ["u"]}}
              ]
            }
          }
        });
        lower_expression_templates(&mut v).expect("rewrite");
        let rhs = &v["models"]["M"]["equations"][0]["rhs"];
        // sugar(u) -> inner(u) (pass 1) -> k * u (pass 2).
        assert_eq!(*rhs, json!({"op": "*", "args": ["k", "u"]}));
    }
    // -----------------------------------------------------------------------
    // Scalar-field template-parameter substitution
    // (esm-spec §9.6.1 / §9.6.3 constraint 5; mirrors the other bindings 1:1)
    // -----------------------------------------------------------------------

    fn scalar_field_doc(templates: Value, bindings: Value, name: &str) -> Value {
        json!({
          "esm": "1.0.0",
          "metadata": {"name": "scalar_field_param_unit", "authors": ["t"]},
          "models": {"M": {
            "variables": {
              "pa": {"type": "parameter"},
              "pb": {"type": "parameter"},
              "area": {"type": "unknown"}
            },
            "equations": [
                {"lhs": "area", "rhs": {"op": "apply_expression_template", "args": [],
                  "name": name, "bindings": bindings}}],
            "expression_templates": templates
          }}
        })
    }

    /// A parameter name appearing as the string value of a scalar
    /// Expression-node field in `body` is a substitution site (the mirror of
    /// the match-side scalar-field binding rule, esm-spec §9.6.1).
    #[test]
    fn scalar_field_substitution_happy_path() {
        let mut v = scalar_field_doc(
            json!({"overlap_area": {
              "params": ["K_manifold", "a", "b"],
              "body": {"op": "polygon_intersection_area",
                       "manifold": "K_manifold", "args": ["a", "b"]}}}),
            json!({"K_manifold": "planar", "a": "pa", "b": "pb"}),
            "overlap_area",
        );
        lower_expression_templates(&mut v).expect("rewrite");
        expand(&mut v).expect("expand");
        assert_eq!(
            *crate::classification::observed_definition_json(&v["models"]["M"], "area")
                .expect("area defining equation"),
            json!({"op": "polygon_intersection_area", "manifold": "planar",
                   "args": ["pa", "pb"]})
        );
    }

    /// A scalar-field param passed through a §9.7.3 registration-time body
    /// composition (outer body applies inner, forwarding its own param into
    /// the inner manifold slot) substitutes end-to-end.
    #[test]
    fn scalar_field_param_threads_through_body_composition() {
        let mut v = scalar_field_doc(
            json!({
              "inner": {
                "params": ["m", "x", "y"],
                "body": {"op": "polygon_intersection_area", "manifold": "m",
                         "args": ["x", "y"]}},
              "outer": {
                "params": ["K", "p", "q"],
                "body": {"op": "*", "args": [
                  {"op": "apply_expression_template", "args": [], "name": "inner",
                   "bindings": {"m": "K", "x": "p", "y": "q"}},
                  2.0]}}
            }),
            json!({"K": "spherical", "p": "pa", "q": "pb"}),
            "outer",
        );
        lower_expression_templates(&mut v).expect("rewrite");
        expand(&mut v).expect("expand");
        assert_eq!(
            *crate::classification::observed_definition_json(&v["models"]["M"], "area")
                .expect("area defining equation"),
            json!({"op": "*", "args": [
              {"op": "polygon_intersection_area", "manifold": "spherical",
               "args": ["pa", "pb"]},
              2.0]})
        );
    }

    /// Validators run on the expanded form (esm-spec §9.6.4): a template
    /// invocation binding the manifold parameter to a non-member literal is
    /// rejected with `geometry_manifold_invalid`.
    #[test]
    fn scalar_field_invalid_substituted_manifold_rejected() {
        let mut v = scalar_field_doc(
            json!({"overlap_area": {
              "params": ["K_manifold", "a", "b"],
              "body": {"op": "polygon_intersection_area",
                       "manifold": "K_manifold", "args": ["a", "b"]}}}),
            json!({"K_manifold": "bogus", "a": "pa", "b": "pb"}),
            "overlap_area",
        );
        let err = lower_expression_templates(&mut v).expect_err("must reject");
        assert_eq!(err.code, "geometry_manifold_invalid");
    }

    /// Pinned shadowing resolution (esm-spec §9.6.1): a declared param name
    /// shadows a coincident field literal inside `body` — the param wins.
    /// Authors must not name params after field literals; the engine
    /// substitutes anyway.
    #[test]
    fn scalar_field_params_shadow_literals() {
        let mut v = scalar_field_doc(
            json!({"shadowed": {
              "params": ["planar", "x", "y"],
              "body": {"op": "polygon_intersection_area",
                       "manifold": "planar", "args": ["x", "y"]}}}),
            json!({"planar": "spherical", "x": "pa", "y": "pb"}),
            "shadowed",
        );
        lower_expression_templates(&mut v).expect("rewrite");
        expand(&mut v).expect("expand");
        assert_eq!(
            crate::classification::observed_definition_json(&v["models"]["M"], "area")
                .expect("area defining equation")["manifold"],
            json!("spherical")
        );
    }
}
