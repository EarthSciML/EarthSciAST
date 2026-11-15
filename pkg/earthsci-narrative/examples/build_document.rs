//! Build an `.esm` document from stdin and print the build output as JSON:
//! validation, the results of its tests, and its figures.
//!
//! The document is read by the core in the format the argument names:
//! `markdown` (the default), `typst`, or `json`.
//!
//! ```sh
//! cargo run --example build_document -- markdown < decay.md > output.json
//! ```

use std::io::Read;

use earthsci_ast::DocumentFormat;
use earthsci_narrative::build::{BuildOptions, build_document, build_text};

fn main() {
    let mut text = String::new();
    std::io::stdin()
        .read_to_string(&mut text)
        .expect("stdin is readable");
    let opts = BuildOptions::default();
    let out = match std::env::args().nth(1).as_deref().unwrap_or("markdown") {
        "markdown" => build_text(&text, DocumentFormat::Markdown, &opts),
        "typst" => build_text(&text, DocumentFormat::Typst, &opts),
        "json" => build_document(
            serde_json::from_str(&text).expect("the document is JSON"),
            &opts,
        ),
        other => panic!("unknown format `{other}` (expected markdown, typst or json)"),
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&out).expect("the output serializes")
    );
}
