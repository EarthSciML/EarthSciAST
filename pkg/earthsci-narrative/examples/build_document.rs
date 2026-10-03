//! Build an element document from stdin and print the build output as JSON.
//!
//! ```sh
//! cargo run --example build_document < document.json > output.json
//! ```

use std::io::Read;

use earthsci_narrative::build::{BuildOptions, build_json};

fn main() {
    let mut text = String::new();
    std::io::stdin()
        .read_to_string(&mut text)
        .expect("stdin is readable");
    let out = build_json(&text, &BuildOptions::default());
    println!(
        "{}",
        serde_json::to_string_pretty(&out).expect("the output serializes")
    );
}
