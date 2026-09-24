//! `Rhs::Auto` decides whether a document has anything to integrate by the
//! esm-spec §6.3.1 derivation — a TIME derivative anywhere in an equation's
//! left-hand side — and not by the top-level operator alone (issue #476).
//!
//! The arrayed spelling `faq{expr: D(index(u, i))}` is how every array-op PDE
//! is written and what the pointwise lift produces, so it must make the
//! document dynamic: on the static backend `solve` answers `NotDynamic` for a
//! model that plainly integrates.

use std::path::Path;

use earthsci_ast::{
    CompileError, Compiler, ProblemOptions, Rhs, SimulateError, SolveOptions, esm_problem,
    load_string, solve,
};

const PDE_FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../tests/conformance/pde_simulation/fixtures/diffusion_1d_periodic_n4.esm"
);

fn auto(compiler: Compiler) -> ProblemOptions {
    ProblemOptions {
        rhs: Rhs::Auto,
        compiler: Some(compiler),
        ..Default::default()
    }
}

/// The fixture carries no initial state; the conformance tier supplies one.
fn seeded(compiler: Compiler) -> ProblemOptions {
    let mut o = auto(compiler);
    o.u0 = (1..=4).map(|i| (format!("u[{i}]"), i as f64)).collect();
    o
}

/// A `pde_simulation` fixture, whose only equation is
/// `faq{D(index(u, i))} = faq{…}`, builds a right-hand side under the default
/// options and integrates, under both compilers.
#[test]
fn an_faq_derivative_routes_dynamic_under_auto() {
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let prob = esm_problem(Path::new(PDE_FIXTURE), (0.0, 0.01), seeded(compiler))
            .unwrap_or_else(|e| panic!("[{compiler}] esm_problem: {e}"));
        assert!(prob.is_dynamic(), "[{compiler}] routed static");
        assert_eq!(prob.backend_kind(), "array", "[{compiler}]");
        assert_eq!(prob.state_variable_names().len(), 4, "[{compiler}]");
        let derivatives: Vec<_> = prob
            .compiler_report()
            .rules()
            .iter()
            .filter(|r| r.kind == "state derivative")
            .collect();
        assert!(
            !derivatives.is_empty(),
            "[{compiler}] the report names no state derivative: {}",
            prob.compiler_report()
        );
        let sol = solve(&prob, &SolveOptions::default())
            .unwrap_or_else(|e| panic!("[{compiler}] solve: {e}"));
        assert!(sol.retcode.is_success(), "[{compiler}] {}", sol.retcode);
    }
    // The default compiler is native, and the default options are `Auto`.
    let prob = esm_problem(
        Path::new(PDE_FIXTURE),
        (0.0, 0.01),
        ProblemOptions {
            u0: seeded(Compiler::Native).u0,
            ..Default::default()
        },
    )
    .expect("default build");
    assert!(prob.is_dynamic());
}

/// `index(D(u), i)` names a derivative too. The array runtime does not accept
/// that spelling, so the build refuses it by name — rather than routing the
/// document static and letting `solve` claim it has no differential
/// equations.
#[test]
fn an_indexed_derivative_is_not_called_static() {
    const DOC: &str = r#"{
      "esm": "1.1.0",
      "metadata": { "name": "indexed_derivative_lhs" },
      "index_sets": { "i": { "kind": "interval", "size": 3 } },
      "models": {
        "M": {
          "variables": {
            "u": { "type": "unknown", "shape": ["i"], "default": 1.0 }
          },
          "equations": [
            {
              "lhs": { "op": "index", "args": [ { "op": "D", "args": ["u"], "wrt": "t" }, "i" ] },
              "rhs": { "op": "-", "args": [ { "op": "index", "args": ["u", "i"] } ] }
            }
          ]
        }
      }
    }"#;
    let file = load_string(DOC).expect("load");
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        match esm_problem(&file, (0.0, 1.0), auto(compiler)) {
            Ok(prob) => assert!(
                prob.is_dynamic(),
                "[{compiler}] a derivative equation routed static"
            ),
            Err(SimulateError::Compile(CompileError::UnsupportedConstruct { .. })) => {}
            Err(e) => panic!("[{compiler}] expected a dynamic build or a named refusal, got {e}"),
        }
    }
}

/// A document whose every equation is algebraic still routes static: the
/// derivation has to see through wrappers, not invent derivatives.
#[test]
fn an_algebraic_faq_stays_static() {
    const DOC: &str = r#"{
      "esm": "1.1.0",
      "metadata": { "name": "algebraic_faq_lhs" },
      "index_sets": { "i": { "kind": "interval", "size": 3 } },
      "models": {
        "M": {
          "variables": {
            "k": { "type": "parameter", "default": 2.0 },
            "y": { "type": "unknown", "shape": ["i"] }
          },
          "equations": [
            {
              "lhs": { "op": "faq", "args": [], "output_idx": ["i"],
                       "expr": { "op": "index", "args": ["y", "i"] },
                       "ranges": { "i": [1, 3] } },
              "rhs": { "op": "faq", "args": [], "output_idx": ["i"],
                       "expr": { "op": "*", "args": ["k", "i"] },
                       "ranges": { "i": [1, 3] } }
            }
          ]
        }
      }
    }"#;
    let file = load_string(DOC).expect("load");
    let prob = esm_problem(&file, (0.0, 1.0), auto(Compiler::Native)).expect("build");
    assert!(!prob.is_dynamic());
    assert_eq!(prob.backend_kind(), "static");
}
