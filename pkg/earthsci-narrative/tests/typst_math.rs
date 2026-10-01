//! Golden and validity tests for the Typst math printer.
//!
//! `tests/typst_math/cases.json` pins exact output, in the group layout of the
//! repo's `tests/display` corpus. Each case gives exactly one input:
//!
//! - `name`: a variable name, through `name_to_typst`;
//! - `expression` / `equation`: the text syntax, parsed by the core;
//! - `input`: an expression's JSON AST, for what the text syntax can't say.
//!
//! To regenerate the expected output after a deliberate change, run with
//! `BLESS_TYPST_GOLDENS=1` and review the diff.
//!
//! The validity test renders every golden case and every expression in the
//! repo's `tests/display` corpus, and compiles them all with the `typst` CLI.
//! It is skipped, with a note, where `typst` is not installed.

use std::path::{Path, PathBuf};
use std::process::Command;

use earthsci_ast::{Expr, parse_equation, parse_expression};
use earthsci_narrative::typst_math::{equation_to_typst, expr_to_typst, name_to_typst};
use serde_json::Value;

fn manifest_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn golden_path() -> PathBuf {
    manifest_dir().join("tests/typst_math/cases.json")
}

fn load_json(path: &Path) -> Value {
    let text =
        std::fs::read_to_string(path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parsing {}: {e}", path.display()))
}

/// Render one golden case, or say why it can't be.
fn render_case(case: &Value) -> Result<String, String> {
    let inputs: Vec<&str> = ["name", "expression", "equation", "input"]
        .into_iter()
        .filter(|k| case.get(*k).is_some())
        .collect();
    match inputs.as_slice() {
        ["name"] => Ok(name_to_typst(
            case["name"].as_str().ok_or("`name` is not a string")?,
        )),
        ["expression"] => {
            let text = case["expression"]
                .as_str()
                .ok_or("`expression` is not a string")?;
            let expr = parse_expression(text).map_err(|e| e.to_string())?;
            Ok(expr_to_typst(&expr))
        }
        ["equation"] => {
            let text = case["equation"]
                .as_str()
                .ok_or("`equation` is not a string")?;
            let eq = parse_equation(text).map_err(|e| e.to_string())?;
            Ok(equation_to_typst(&eq))
        }
        ["input"] => {
            let expr: Expr =
                serde_json::from_value(case["input"].clone()).map_err(|e| e.to_string())?;
            Ok(expr_to_typst(&expr))
        }
        other => Err(format!("expected exactly one input field, found {other:?}")),
    }
}

/// Every golden case, with its group and position, for messages.
fn golden_cases(doc: &Value) -> Vec<(String, Value)> {
    let mut cases = Vec::new();
    for group in doc
        .as_array()
        .expect("the golden file is an array of groups")
    {
        let group_name = group["description"].as_str().unwrap_or("?");
        for (i, case) in group["test_cases"]
            .as_array()
            .expect("each group has `test_cases`")
            .iter()
            .enumerate()
        {
            cases.push((format!("{group_name} #{i}"), case.clone()));
        }
    }
    cases
}

#[test]
fn golden_cases_match() {
    let path = golden_path();
    let mut doc = load_json(&path);

    if std::env::var_os("BLESS_TYPST_GOLDENS").is_some() {
        for group in doc.as_array_mut().unwrap() {
            for case in group["test_cases"].as_array_mut().unwrap() {
                let out = render_case(case).unwrap_or_else(|e| panic!("{case}: {e}"));
                case["typst"] = Value::String(out);
            }
        }
        let text = serde_json::to_string_pretty(&doc).unwrap() + "\n";
        std::fs::write(&path, text).unwrap();
        return;
    }

    let mut failures = Vec::new();
    for (where_, case) in golden_cases(&doc) {
        let expected = case["typst"].as_str().unwrap_or_default();
        match render_case(&case) {
            Ok(actual) if actual == expected => {}
            Ok(actual) => failures.push(format!("{where_}: expected {expected:?}, got {actual:?}")),
            Err(e) => failures.push(format!("{where_}: {e}")),
        }
    }
    assert!(
        failures.is_empty(),
        "{} golden case(s) differ:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

/// Every `input` expression in the repo's `tests/display` corpus.
fn display_corpus_expressions() -> Vec<(String, Expr)> {
    fn walk(v: &Value, file: &str, out: &mut Vec<(String, Expr)>) {
        match v {
            Value::Object(map) => {
                if let Some(input) = map.get("input")
                    && let Ok(expr) = serde_json::from_value::<Expr>(input.clone())
                {
                    out.push((format!("{file}: {input}"), expr));
                }
                map.values().for_each(|x| walk(x, file, out));
            }
            Value::Array(items) => items.iter().for_each(|x| walk(x, file, out)),
            _ => {}
        }
    }
    let dir = manifest_dir().join("../../tests/display");
    let mut paths: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()))
        .map(|entry| entry.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .collect();
    paths.sort();
    let mut out = Vec::new();
    for path in paths {
        let file = path.file_name().unwrap().to_string_lossy().into_owned();
        walk(&load_json(&path), &file, &mut out);
    }
    out
}

#[test]
fn every_rendering_compiles_in_typst() {
    if Command::new("typst").arg("--version").output().is_err() {
        eprintln!("skipping: the `typst` CLI is not on PATH");
        return;
    }

    let mut cases: Vec<(String, String)> = Vec::new();
    for (where_, case) in golden_cases(&load_json(&golden_path())) {
        let out = render_case(&case).unwrap_or_else(|e| panic!("{where_}: {e}"));
        cases.push((where_, out));
    }
    let corpus = display_corpus_expressions();
    assert!(
        corpus.len() > 100,
        "found only {} display-corpus expressions",
        corpus.len()
    );
    for (where_, expr) in corpus {
        cases.push((where_, expr_to_typst(&expr)));
    }

    // One case per line, so a compile error's line number names the case.
    const PREAMBLE_LINES: usize = 1;
    let mut doc = String::from("#set page(width: 20cm, height: auto)\n");
    for (_, typst) in &cases {
        doc.push_str(&format!("$ {typst} $\n"));
    }

    let dir = std::env::temp_dir().join(format!("earthsci-typst-math-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let source = dir.join("cases.typ");
    std::fs::write(&source, &doc).unwrap();
    let output = Command::new("typst")
        .arg("compile")
        .arg(&source)
        .arg(dir.join("cases.pdf"))
        .output()
        .expect("running typst");
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let _ = std::fs::remove_dir_all(&dir);

    if !output.status.success() {
        // Typst reports `┌─ cases.typ:LINE:COLUMN`; name the cases.
        let mut named = Vec::new();
        for line in stderr.lines() {
            if let Some(rest) = line.split("cases.typ:").nth(1)
                && let Some(n) = rest.split(':').next().and_then(|n| n.parse::<usize>().ok())
                && let Some((where_, typst)) =
                    n.checked_sub(PREAMBLE_LINES + 1).and_then(|i| cases.get(i))
            {
                named.push(format!(
                    "case {} ({where_}): {typst}",
                    n - PREAMBLE_LINES - 1
                ));
            }
        }
        panic!(
            "typst rejected the rendered math:\n{stderr}\n{}",
            named.join("\n")
        );
    }
}
