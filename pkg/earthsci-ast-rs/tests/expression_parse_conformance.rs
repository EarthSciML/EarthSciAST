//! Cross-language conformance for the expression TEXT parser
//! ([`earthsci_ast::parse_expression`]).
//!
//! The corpus `tests/conformance/expression_parse/cases.json` (repo root) was
//! generated from the TypeScript oracle `@earthsciml/ast`'s `parseExpression` /
//! `parseEquation`. Every binding must satisfy, for each `expressions[]` entry:
//!
//! 1. `parse_expression(text)` serializes to the recorded `ast`;
//! 2. `to_ascii(parse_expression(text))` equals `reprint`;
//! 3. `parse_expression(reprint)` serializes to the same `ast` (the printer /
//!    parser pair round-trips).
//!
//! `expression_errors[]` and `equation_errors[]` MUST be refused; their `reason`
//! is prose and is deliberately not asserted.
//!
//! ASTs are compared as `serde_json::Value`, not as strings: that is the
//! language-neutral check, and `Value` map equality is key-order insensitive
//! (this crate builds `serde_json` with `preserve_order`, so a string compare
//! would spuriously depend on struct field order).

use earthsci_ast::display::to_ascii;
use earthsci_ast::parse_expression::{parse_equation, parse_expression};
use serde_json::Value;

const CORPUS: &str = "../../tests/conformance/expression_parse/cases.json";

fn corpus() -> Value {
    let content = std::fs::read_to_string(CORPUS)
        .unwrap_or_else(|e| panic!("cannot read required corpus {CORPUS}: {e}"));
    serde_json::from_str(&content).unwrap_or_else(|e| panic!("invalid JSON in {CORPUS}: {e}"))
}

fn section<'a>(root: &'a Value, key: &str) -> &'a Vec<Value> {
    root.get(key)
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("{CORPUS}: missing array section `{key}`"))
}

fn text_of(case: &Value) -> &str {
    case.get("text")
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("{CORPUS}: a case is missing `text`"))
}

#[test]
fn expression_corpus_parses_to_the_oracle_ast() {
    let root = corpus();
    let cases = section(&root, "expressions");
    assert_eq!(cases.len(), 184, "corpus expression count changed");

    let mut failures: Vec<String> = Vec::new();

    for case in cases {
        let text = text_of(case);
        let tier = case.get("tier").and_then(Value::as_str).unwrap_or("?");
        let want_ast = case
            .get("ast")
            .unwrap_or_else(|| panic!("{text}: case is missing `ast`"));
        let want_reprint = case
            .get("reprint")
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("{text}: case is missing `reprint`"));

        // 1. parse(text) == ast
        let parsed = match parse_expression(text) {
            Ok(e) => e,
            Err(e) => {
                failures.push(format!("[{tier}] {text:?}: parse failed: {e}"));
                continue;
            }
        };
        let got_ast = serde_json::to_value(&parsed).expect("Expr serializes");
        if &got_ast != want_ast {
            failures.push(format!(
                "[{tier}] {text:?}: ast mismatch\n    want {want_ast}\n    got  {got_ast}"
            ));
        }

        // 2. to_ascii(parse(text)) == reprint
        let got_reprint = to_ascii(&parsed);
        if got_reprint != want_reprint {
            failures.push(format!(
                "[{tier}] {text:?}: reprint mismatch\n    want {want_reprint:?}\n    got  {got_reprint:?}"
            ));
        }

        // 3. parse(reprint) == ast  (the printer/parser pair round-trips)
        match parse_expression(want_reprint) {
            Ok(e) => {
                let round = serde_json::to_value(&e).expect("Expr serializes");
                if &round != want_ast {
                    failures.push(format!(
                        "[{tier}] {text:?}: reparse of reprint {want_reprint:?} mismatch\n    want {want_ast}\n    got  {round}"
                    ));
                }
            }
            Err(e) => failures.push(format!(
                "[{tier}] {text:?}: reparse of reprint {want_reprint:?} failed: {e}"
            )),
        }
    }

    assert!(
        failures.is_empty(),
        "{} of {} expression cases failed:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
}

#[test]
fn expression_error_corpus_is_refused() {
    let root = corpus();
    let cases = section(&root, "expression_errors");
    assert_eq!(cases.len(), 12, "corpus expression_errors count changed");

    let mut failures: Vec<String> = Vec::new();
    for case in cases {
        let text = text_of(case);
        let reason = case.get("reason").and_then(Value::as_str).unwrap_or("?");
        if let Ok(e) = parse_expression(text) {
            let got = serde_json::to_value(&e).expect("Expr serializes");
            failures.push(format!(
                "{text:?} must be refused ({reason}), but parsed to {got}"
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {} refusal cases were accepted:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
}

#[test]
fn equation_corpus_splits_on_the_top_level_lone_equals() {
    let root = corpus();
    let cases = section(&root, "equations");
    assert_eq!(cases.len(), 3, "corpus equation count changed");

    let mut failures: Vec<String> = Vec::new();
    for case in cases {
        let text = text_of(case);
        let want_lhs = case
            .get("lhs")
            .unwrap_or_else(|| panic!("{text}: case is missing `lhs`"));
        let want_rhs = case
            .get("rhs")
            .unwrap_or_else(|| panic!("{text}: case is missing `rhs`"));
        match parse_equation(text) {
            Ok(eq) => {
                let got_lhs = serde_json::to_value(&eq.lhs).expect("Expr serializes");
                let got_rhs = serde_json::to_value(&eq.rhs).expect("Expr serializes");
                if &got_lhs != want_lhs {
                    failures.push(format!(
                        "{text:?}: lhs mismatch\n    want {want_lhs}\n    got  {got_lhs}"
                    ));
                }
                if &got_rhs != want_rhs {
                    failures.push(format!(
                        "{text:?}: rhs mismatch\n    want {want_rhs}\n    got  {got_rhs}"
                    ));
                }
            }
            Err(e) => failures.push(format!("{text:?}: parse_equation failed: {e}")),
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {} equation cases failed:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
}

#[test]
fn equation_error_corpus_is_refused() {
    let root = corpus();
    let cases = section(&root, "equation_errors");
    assert_eq!(cases.len(), 2, "corpus equation_errors count changed");

    let mut failures: Vec<String> = Vec::new();
    for case in cases {
        let text = text_of(case);
        if let Ok(eq) = parse_equation(text) {
            failures.push(format!(
                "{text:?} must be refused, but parsed to {} = {}",
                to_ascii(&eq.lhs),
                to_ascii(&eq.rhs)
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {} equation refusal cases were accepted:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
}

/// The reported position is a 0-based CHARACTER offset, not a byte offset —
/// the corpus carries names built from multi-byte constituents (`∂u_∂z`,
/// `∇phi`), and every binding reports character offsets.
#[test]
fn error_position_is_a_character_offset() {
    // `∇phi` is 4 characters but 6 bytes; the stray `@` is at character 7.
    let err = parse_expression("∇phi + @").expect_err("`@` is not a token");
    assert_eq!(err.pos, 7, "position must count characters, not bytes");

    // A unicode big-operator display form is refused at its character offset.
    let err = parse_expression("∂u_∂z + ∑").expect_err("`∑` is display-only syntax");
    assert_eq!(err.pos, 8);
}
