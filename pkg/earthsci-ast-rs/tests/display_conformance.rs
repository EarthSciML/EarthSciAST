//! Cross-language display conformance for the Rust binding.
//!
//! Every binding must render a given AST identically in ascii, unicode and
//! LaTeX (esm-libraries-spec §6). Julia, Python, Go and TypeScript each have a
//! test asserting that against the shared `tests/display/*.json` fixtures;
//! Rust did NOT, and that gap is why three separate parenthesization
//! divergences survived in `display.rs` until the expression-text-parser corpus
//! happened to trip over two of them:
//!
//!   * the right operand of a binary `-` was rendered at `op_prec + 1`, which
//!     against a contiguous precedence table parenthesized every TIGHTER child
//!     (`a - (b * c)`);
//!   * unary minus parenthesized any operand at its own precedence
//!     (`-(a + b)`);
//!   * `+` and `*` parenthesized a same-precedence operand (`(a - b) + c`), and
//!     the LaTeX `\frac` early-return bypassed the parent's parenthesization
//!     entirely, emitting `\frac{b}{c}^{d}` where the reference prints
//!     `(\frac{b}{c})^{d}` — an UNDER-parenthesization that changes meaning.
//!
//! This test closes the gap: it is the same corpus the other four bindings
//! already check, so a future divergence fails here rather than surviving.

use earthsci_ast::{to_ascii, to_latex, to_unicode, types::Expr};

/// Repo-root-relative path to the shared display fixtures.
fn fixture_path(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/display")
        .join(name)
}

#[test]
fn all_operators_fixtures_render_identically() {
    let raw = std::fs::read_to_string(fixture_path("all_operators.json"))
        .expect("shared display fixture is readable");
    let cases: Vec<serde_json::Value> =
        serde_json::from_str(&raw).expect("shared display fixture parses");
    assert!(
        cases.len() >= 91,
        "fixture shrank unexpectedly: {} entries",
        cases.len()
    );

    let mut failures = Vec::new();
    for case in &cases {
        let expr: Expr = match serde_json::from_value(case["input"].clone()) {
            Ok(e) => e,
            Err(e) => {
                failures.push(format!("{}: input did not deserialize: {e}", case["input"]));
                continue;
            }
        };
        for (key, got) in [
            ("ascii", to_ascii(&expr)),
            ("unicode", to_unicode(&expr)),
            ("latex", to_latex(&expr)),
        ] {
            let Some(want) = case[key].as_str() else {
                continue; // not every fixture pins every format
            };
            if got != want {
                failures.push(format!("{key}: want {want:?}, got {got:?}"));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {} display fixtures diverge:\n  {}",
        failures.len(),
        cases.len(),
        failures.join("\n  ")
    );
}
