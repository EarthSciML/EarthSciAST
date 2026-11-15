//! `earthsci-document-format-adapter-rust` — the Rust batch driver of the
//! document-format gate (`scripts/run-document-format-gate.py`,
//! CONFORMANCE_SPEC.md §5.59).
//!
//! Invoked as `earthsci-document-format-adapter-rust print|parse <manifest> <out>`.
//! `print` writes each corpus document's canonical form and both printed texts;
//! `parse` reads each printed text back. The manifest and output layout are
//! described in the gate script.

use earthsci_ast::{DocumentFormat, canonicalize_document, parse_document, print_document};
use serde_json::Value;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::process::ExitCode;

const FORMATS: [(&str, DocumentFormat, &str); 2] = [
    ("markdown", DocumentFormat::Markdown, "md"),
    ("typst", DocumentFormat::Typst, "typ"),
];

/// `f`, with a panic turned into an error message.
fn guarded<T>(f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(p) => Err(format!(
            "panic: {}",
            p.downcast_ref::<&str>()
                .map(|s| (*s).to_string())
                .or_else(|| p.downcast_ref::<String>().cloned())
                .unwrap_or_default()
        )),
    }
}

fn field<'a>(item: &'a Value, key: &str) -> Result<&'a str, String> {
    item.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("manifest item without `{key}`"))
}

fn print_one(item: &Value, out: &Path) -> Result<(), String> {
    let stem = out.join(field(item, "id")?).display().to_string();
    let path = field(item, "path")?;
    let canon = guarded(|| {
        let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
        let doc: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        Ok(canonicalize_document(&doc))
    });
    let canon = match canon.and_then(|c| match c {
        Value::Object(m) => Ok(m),
        _ => Err("the canonical form is not an object".to_string()),
    }) {
        Ok(c) => c,
        Err(e) => return write(Path::new(&format!("{stem}.canon.error")), &e),
    };
    write(
        Path::new(&format!("{stem}.canon.json")),
        &serde_json::to_string(&canon).map_err(|e| e.to_string())?,
    )?;
    for (_, format, ext) in FORMATS {
        match guarded(|| Ok(print_document(&canon, format))) {
            Ok(text) => write(Path::new(&format!("{stem}.{ext}")), &text)?,
            Err(e) => write(Path::new(&format!("{stem}.{ext}.error")), &e)?,
        }
    }
    Ok(())
}

fn parse_one(item: &Value, out: &Path) -> Result<(), String> {
    let stem = out.join(field(item, "id")?).display().to_string();
    let path = field(item, "path")?;
    let name = field(item, "format")?;
    let format = FORMATS
        .iter()
        .find(|(n, _, _)| *n == name)
        .map(|(_, f, _)| *f)
        .ok_or_else(|| format!("unknown format `{name}`"))?;
    let doc = guarded(|| {
        let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
        parse_document(&text, format).map_err(|e| format!("{}: {}", e.code, e.message))
    });
    match doc {
        Ok(d) => write(
            Path::new(&format!("{stem}.json")),
            &serde_json::to_string(&d).map_err(|e| e.to_string())?,
        ),
        Err(e) => write(Path::new(&format!("{stem}.error")), &e),
    }
}

fn write(path: &Path, text: &str) -> Result<(), String> {
    std::fs::write(path, text).map_err(|e| format!("{}: {e}", path.display()))
}

fn run(args: &[String]) -> Result<(), String> {
    let [mode, manifest, out] = args else {
        return Err("usage: print|parse <manifest> <out>".to_string());
    };
    let text = std::fs::read_to_string(manifest).map_err(|e| format!("{manifest}: {e}"))?;
    let items: Vec<Value> = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let one = match mode.as_str() {
        "print" => print_one,
        "parse" => parse_one,
        _ => return Err(format!("unknown mode `{mode}`")),
    };
    // A panic is caught and recorded per item; keep the default hook quiet.
    std::panic::set_hook(Box::new(|_| {}));
    for item in &items {
        one(item, Path::new(out))?;
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("document-format-adapter-rust: {e}");
            ExitCode::FAILURE
        }
    }
}
