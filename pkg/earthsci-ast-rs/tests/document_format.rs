//! The document source formats (CONFORMANCE_SPEC §5.58): the golden set in
//! `tests/conformance/document_format/`, and the whole-corpus round trip.
//!
//! The fixture contract is the README of that directory:
//!
//! * `print`: `print(esm) == text` byte for byte and `parse(text) == esm` as a
//!   JSON value, in both formats (and `canonicalize(written) == esm` when the
//!   case is about the canonical form);
//! * `variant`: `parse(surface, input) == esm` and `print(surface, esm) == canonical`;
//! * `refusal`: `parse(surface, input)` fails with the diagnostic code `error`.
//!
//! The corpus round trip is computed here from the corpus itself, never stored:
//! every `.esm` under `tests/` that is a JSON object (the corpus of
//! `formal/scripts/doc-corpus.py`), canonicalized, printed in
//! each format and read back, must give its canonical form again.

use crate::common::repo_tests_dir;
use earthsci_ast::{DocumentFormat, canonicalize_document, parse_document, print_document};
use serde_json::Value;
use std::path::{Path, PathBuf};

const FILES: &[&str] = &[
    "operators.json",
    "names.json",
    "variants.json",
    "documents.json",
    "units.json",
    "refusals.json",
];

fn surface(name: &str) -> DocumentFormat {
    match name {
        "markdown" => DocumentFormat::Markdown,
        "typst" => DocumentFormat::Typst,
        other => panic!("unknown surface {other}"),
    }
}

fn object(v: &Value) -> &serde_json::Map<String, Value> {
    v.as_object().expect("a document is a JSON object")
}

/// Run one case; the failures, as messages.
fn run_case(case: &Value) -> Vec<String> {
    let id = case["id"].as_str().expect("case id");
    let mut out = Vec::new();
    let mut check = |ok: bool, what: String| {
        if !ok {
            out.push(format!("{id}: {what}"));
        }
    };
    match case["kind"].as_str().expect("case kind") {
        "print" => {
            let esm = &case["esm"];
            if let Some(written) = case.get("written") {
                check(
                    canonicalize_document(written) == *esm,
                    "canonicalize(written) != esm".into(),
                );
            }
            for (key, format) in [
                ("markdown", DocumentFormat::Markdown),
                ("typst", DocumentFormat::Typst),
            ] {
                let text = case[key].as_str().expect("printed text");
                let printed = print_document(object(esm), format);
                check(
                    printed == text,
                    format!("print {key} differs:\n--- got\n{printed}\n--- want\n{text}"),
                );
                match parse_document(text, format) {
                    Ok(back) => check(
                        back == *esm,
                        format!("parse {key} differs:\n--- got\n{back}\n--- want\n{esm}"),
                    ),
                    Err(e) => check(false, format!("parse {key} refused: {e}")),
                }
            }
        }
        "variant" => {
            let format = surface(case["surface"].as_str().expect("surface"));
            let esm = &case["esm"];
            let input = case["input"].as_str().expect("input");
            match parse_document(input, format) {
                Ok(back) => check(
                    back == *esm,
                    format!("parse differs:\n--- got\n{back}\n--- want\n{esm}"),
                ),
                Err(e) => check(false, format!("parse refused: {e}")),
            }
            let canonical = case["canonical"].as_str().expect("canonical");
            let printed = print_document(object(esm), format);
            check(
                printed == canonical,
                format!("print differs:\n--- got\n{printed}\n--- want\n{canonical}"),
            );
        }
        "refusal" => {
            let format = surface(case["surface"].as_str().expect("surface"));
            let input = case["input"].as_str().expect("input");
            let want = case["error"].as_str().expect("error code");
            match parse_document(input, format) {
                Ok(v) => check(false, format!("expected `{want}`, read {v}")),
                Err(e) => check(
                    e.code == want,
                    format!("expected `{want}`, got `{}`", e.code),
                ),
            }
        }
        other => panic!("{id}: unknown kind {other}"),
    }
    out
}

#[test]
fn document_format_fixtures() {
    let dir = repo_tests_dir().join("conformance/document_format");
    let mut failures = Vec::new();
    let mut n = 0;
    for file in FILES {
        let path = dir.join(file);
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
        let doc: Value = serde_json::from_str(&text).expect("fixture JSON");
        for case in doc["cases"].as_array().expect("cases") {
            n += 1;
            let result = std::panic::catch_unwind(|| run_case(case));
            match result {
                Ok(fs) => failures.extend(fs),
                Err(_) => failures.push(format!("{}: panicked", case["id"])),
            }
        }
    }
    assert!(n > 0, "no fixture cases");
    assert!(
        failures.is_empty(),
        "{} of {n} cases failed:\n\n{}",
        failures.len(),
        failures.join("\n\n")
    );
}

/// The `.esm` files under `tests/`; the callers keep those that are JSON
/// objects, the corpus `formal/scripts/doc-corpus.py` reads.
fn corpus() -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(rd) = std::fs::read_dir(dir) else {
            return;
        };
        let mut entries: Vec<_> = rd.flatten().map(|e| e.path()).collect();
        entries.sort();
        for p in entries {
            if p.is_dir() {
                walk(&p, out);
            } else if p.extension().is_some_and(|e| e == "esm") {
                out.push(p);
            }
        }
    }
    let root = repo_tests_dir();
    let mut files = Vec::new();
    walk(&root, &mut files);
    files
}

#[test]
fn document_format_corpus_round_trip() {
    let mut checked = 0;
    let mut failures = Vec::new();
    for path in corpus() {
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(doc) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        if !doc.is_object() {
            continue;
        }
        checked += 1;
        let canon = canonicalize_document(&doc);
        for format in [DocumentFormat::Markdown, DocumentFormat::Typst] {
            let result = std::panic::catch_unwind(|| {
                let printed = print_document(object(&canon), format);
                parse_document(&printed, format)
            });
            let what = match result {
                Ok(Ok(back)) if back == canon => continue,
                Ok(Ok(_)) => "reads back differently",
                Ok(Err(_)) => "does not read back",
                Err(_) => "panicked",
            };
            failures.push(format!("{} ({format:?}): {what}", path.display()));
        }
    }
    assert!(checked > 100, "only {checked} corpus documents found");
    assert!(
        failures.is_empty(),
        "{} of {} round trips failed:\n{}",
        failures.len(),
        2 * checked,
        failures.join("\n")
    );
}

/// Run `esm-lean <mode> <path>`; its stdout, or `None` when it refuses.
fn esm_lean(binary: &Path, mode: &str, path: &Path) -> Option<String> {
    let out = std::process::Command::new(binary)
        .arg(mode)
        .arg(path)
        .output()
        .expect("esm-lean runs");
    out.status
        .success()
        .then(|| String::from_utf8(out.stdout).expect("UTF-8 output"))
}

/// The cross-check against the Lean model, run by hand where `esm-lean` is
/// built (`ESM_LEAN=formal/.lake/build/bin/esm-lean cargo test --test
/// integration document_format_matches_lean -- --ignored`): over the whole
/// corpus, the Rust printers write exactly what `esm-lean print-md` /
/// `print-typ` write for the canonical document, and the Rust readers read the
/// Lean-printed texts exactly as `esm-lean parse-md` / `parse-typ` do. A self
/// round trip alone cannot see a printer and a reader that drift together.
#[test]
#[ignore = "needs the esm-lean executable (ESM_LEAN)"]
fn document_format_matches_lean() {
    let binary = PathBuf::from(std::env::var("ESM_LEAN").expect("ESM_LEAN names esm-lean"));
    let scratch = PathBuf::from(
        std::env::var("ESM_LEAN_SCRATCH").unwrap_or_else(|_| "target/esm-lean-check".into()),
    );
    std::fs::create_dir_all(&scratch).expect("scratch directory");
    let mut checked = 0;
    let mut failures = Vec::new();
    for path in corpus() {
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(doc) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        if !doc.is_object() {
            continue;
        }
        checked += 1;
        let name = path.display().to_string();
        let stem = scratch.join(name.replace('/', "__"));
        let canon_path = stem.with_extension("canon.json");
        let lean_canon = esm_lean(&binary, "canon", &path).expect("esm-lean canon");
        std::fs::write(&canon_path, &lean_canon).expect("write canon");
        let rust_canon = canonicalize_document(&doc);
        let lean_canon_v: Value = serde_json::from_str(&lean_canon).expect("canon JSON");
        if lean_canon_v != rust_canon {
            failures.push(format!("{name}: canonical forms differ"));
            continue;
        }
        for (format, print_mode, parse_mode, ext) in [
            (DocumentFormat::Markdown, "print-md", "parse-md", "md"),
            (DocumentFormat::Typst, "print-typ", "parse-typ", "typ"),
        ] {
            let lean_text = esm_lean(&binary, print_mode, &canon_path);
            let rust_text =
                std::panic::catch_unwind(|| print_document(object(&rust_canon), format)).ok();
            let Some(lean_text) = lean_text else {
                failures.push(format!("{name}: esm-lean {print_mode} refused"));
                continue;
            };
            if rust_text.as_deref() != Some(lean_text.as_str()) {
                failures.push(format!("{name}: {print_mode} differs"));
                if let Some(t) = &rust_text {
                    std::fs::write(stem.with_extension(format!("rust.{ext}")), t).ok();
                }
            }
            let text_path = stem.with_extension(ext);
            std::fs::write(&text_path, &lean_text).expect("write text");
            let lean_back = esm_lean(&binary, parse_mode, &text_path)
                .map(|s| serde_json::from_str::<Value>(&s).expect("parse JSON"));
            let rust_back = std::panic::catch_unwind(|| parse_document(&lean_text, format).ok())
                .ok()
                .flatten();
            if lean_back != rust_back {
                failures.push(format!("{name}: {parse_mode} differs"));
            }
        }
    }
    assert!(checked > 100, "only {checked} corpus documents found");
    assert!(
        failures.is_empty(),
        "{} differences over {checked} documents:\n{}",
        failures.len(),
        failures.join("\n")
    );
}
