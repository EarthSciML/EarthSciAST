//! Cross-language SPECIES ORDER conformance for the two Analysis-tier reaction
//! operations, `derive_odes` and `stoichiometric_matrix` (API_SPEC.md §5.10).
//!
//! Drives every case in the shared, HAND-WRITTEN corpus at
//! `tests/conformance/reactions/species_order.json`. Canonical order is
//! DECLARATION order — the order the document writes the `species` object's
//! keys in — in both operations, in all five bindings. Species order is
//! observable (it *is* the matrix's ROW order and the derived model's EQUATION
//! order), so it is a contract, not an implementation detail; nothing in
//! `tests/` pinned it, which is exactly why Rust sorted in
//! `stoichiometric_matrix` but not in `derive_odes` for the length of the
//! project.
//!
//! Every case declares its species in an order that is NOT their sorted order,
//! so a sorting binding fails rather than passing by coincidence; the driver
//! asserts that anti-vacuity property per case rather than trusting it.
//!
//! `ode_states` is deliberately NOT used: it sorts its result by design
//! (esm-spec §6.3.1), so an assertion built on it passes vacuously.

use earthsci_ast::{Expr, ReactionSystem, derive_odes, load_document, stoichiometric_matrix};
use serde::Deserialize;
use serde_json::Value;
use std::path::{Path, PathBuf};

// --- corpus shapes ----------------------------------------------------------

#[derive(Debug, Deserialize)]
struct Case {
    name: String,
    /// The reaction system within `document` to drive.
    system: String,
    /// The order the document declares the species in.
    species_declaration_order: Vec<String>,
    /// The same names sorted — carried so the driver can prove the two differ.
    species_sorted_order: Vec<String>,
    /// The species of each derived equation's LHS `D(<species>, t)`, in order.
    derive_odes_equation_species: Vec<String>,
    /// Rows are species in declaration order, columns reactions in declaration
    /// order, entries `products - substrates`.
    stoichiometric_matrix: Vec<Vec<f64>>,
    /// The ESM document itself, inline.
    document: Value,
}

#[derive(Debug, Deserialize)]
struct Corpus {
    cases: Vec<Case>,
}

// --- fixtures ---------------------------------------------------------------

/// The repository root — `pkg/earthsci-ast-rs/..`/`..`.
fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .canonicalize()
        .expect("repository root")
}

fn corpus() -> Corpus {
    let path = repo_root().join("tests/conformance/reactions/species_order.json");
    let json = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    serde_json::from_str(&json).unwrap_or_else(|e| panic!("parsing {}: {e}", path.display()))
}

/// The case's inline document, through the package's own loader — the same
/// door every binding's driver goes through.
fn system_of(case: &Case) -> ReactionSystem {
    let file = load_document(&case.document)
        .unwrap_or_else(|e| panic!("{}: loading document: {e}", case.name));
    file.reaction_systems
        .as_ref()
        .and_then(|systems| systems.get(&case.system))
        .unwrap_or_else(|| panic!("{}: no reaction system `{}`", case.name, case.system))
        .clone()
}

/// The species an equation's LHS differentiates: the first argument of its
/// `D(<species>, t)` node.
fn lhs_species(case: &str, index: usize, lhs: &Expr) -> String {
    match lhs {
        Expr::Operator(node) if node.op == "D" => match node.args.first() {
            Some(Expr::Variable(name)) => name.clone(),
            other => panic!(
                "{case}: equation {index} LHS `D` first argument is {other:?}, not a variable"
            ),
        },
        other => panic!("{case}: equation {index} LHS is {other:?}, not a `D(<species>, t)` node"),
    }
}

/// Values in the corpus are exact binary fractions (±1, ±0.5, 0), so an
/// epsilon this tight is still a total comparison.
const EPS: f64 = 1e-12;

// --- the pins ---------------------------------------------------------------

/// Anti-vacuity: a corpus that shrank to one case, or whose species happened to
/// be declared in sorted order, would let a sorting binding pass. Assert both
/// properties instead of trusting the corpus file.
#[test]
fn corpus_is_not_vacuous() {
    let cases = corpus().cases;
    assert!(
        cases.len() >= 2,
        "the species-order corpus must carry at least 2 cases, found {}",
        cases.len()
    );

    for case in &cases {
        assert_ne!(
            case.species_declaration_order, case.species_sorted_order,
            "{}: declares its species in sorted order, so a sorting binding would pass vacuously",
            case.name
        );

        let mut sorted = case.species_declaration_order.clone();
        sorted.sort();
        assert_eq!(
            sorted, case.species_sorted_order,
            "{}: `species_sorted_order` is not `species_declaration_order` sorted",
            case.name
        );
    }
}

/// ROW order of the stoichiometric matrix is declaration order. Reservoir
/// species (`constant: true`) still occupy a row.
#[test]
fn stoichiometric_matrix_rows_are_declaration_order() {
    for case in corpus().cases {
        let system = system_of(&case);

        // The loader must have preserved declaration order in the first place;
        // otherwise the matrix assertion below would pin nothing.
        let declared: Vec<String> = system.species.keys().cloned().collect();
        assert_eq!(
            declared, case.species_declaration_order,
            "{}: the loader did not preserve the document's species declaration order",
            case.name
        );

        let matrix = stoichiometric_matrix(&system);
        assert_eq!(
            matrix.len(),
            case.stoichiometric_matrix.len(),
            "{}: stoichiometric_matrix has {} rows, corpus has {}",
            case.name,
            matrix.len(),
            case.stoichiometric_matrix.len()
        );

        for (row, (got, want)) in matrix.iter().zip(&case.stoichiometric_matrix).enumerate() {
            assert_eq!(
                got.len(),
                want.len(),
                "{}: row {row} ({}) has {} columns, corpus has {}",
                case.name,
                case.species_declaration_order[row],
                got.len(),
                want.len()
            );
            for (col, (g, w)) in got.iter().zip(want).enumerate() {
                assert!(
                    (g - w).abs() <= EPS,
                    "{}: stoichiometric_matrix[{row}][{col}] (species `{}`) is {g}, corpus has {w}\n\
                     got:    {matrix:?}\n\
                     corpus: {:?}",
                    case.name,
                    case.species_declaration_order[row],
                    case.stoichiometric_matrix
                );
            }
        }
    }
}

/// EQUATION order of the model `derive_odes` returns is declaration order,
/// skipping reservoir species (which lower to parameters, not ODEs).
#[test]
fn derive_odes_equation_order_is_declaration_order() {
    for case in corpus().cases {
        let system = system_of(&case);
        let model = derive_odes(&system)
            .unwrap_or_else(|e| panic!("{}: derive_odes failed: {e}", case.name));

        let got: Vec<String> = model
            .equations
            .iter()
            .enumerate()
            .map(|(i, eq)| lhs_species(&case.name, i, &eq.lhs))
            .collect();

        assert_eq!(
            got, case.derive_odes_equation_species,
            "{}: derived equation order diverges from the corpus",
            case.name
        );
    }
}
