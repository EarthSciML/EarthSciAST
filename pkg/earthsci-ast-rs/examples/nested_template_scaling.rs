//! Scaling probe / reproducer for §9.7.3 nested-template body composition.
//!
//! Builds a document with a chain of match-less templates T0..T{depth} where
//! each T_i body references T_{i-1} TWICE, plus a single call site
//! `apply_expression_template(T{depth})`. The logically expanded tree has
//! 2^depth copies of the T0 leaf, so a naive deep-copy expansion is
//! exponential in time and memory while respecting every documented limit
//! (chain depth <= MAX_TEMPLATE_EXPANSION_DEPTH = 32). The expansion pipeline
//! must therefore compose and rewrite with structural sharing; the owned
//! `serde_json::Value` document is materialized once at the end (that final
//! materialization is inherently proportional to the expanded size).
//!
//! Usage: `cargo run --example nested_template_scaling -- [depth] [--load]`
//! Prints wall time for `lower_expression_templates`, the expanded node
//! count, and peak RSS. `--load` additionally drives the full public
//! `parse::load` API (schema validation + typed deserialization), which
//! walks/owns the materialized tree.

use serde_json::{Map, Value, json};
use std::time::Instant;

fn apply(name: &str) -> Value {
    json!({"op": "apply_expression_template", "args": [], "name": name, "bindings": {}})
}

fn doc(depth: usize) -> Value {
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
    for i in 1..=depth {
        let prev = format!("T{}", i - 1);
        templates.insert(
            format!("T{i}"),
            json!({"params": [], "body": {"op": "+", "args": [apply(&prev), apply(&prev)]}}),
        );
    }
    json!({
        "esm": "0.4.0",
        "metadata": {"name": "nested_template_scaling", "authors": ["repro"]},
        "reaction_systems": {
            "chem": {
                "species": {"A": {"default": 1.0}, "B": {"default": 0.5}},
                "parameters": {"T": {"default": 298.15}},
                "expression_templates": Value::Object(templates),
                "reactions": [{
                    "id": "R1",
                    "substrates": [{"species": "A", "stoichiometry": 1}],
                    "products": [{"species": "B", "stoichiometry": 1}],
                    "rate": apply(&format!("T{depth}"))
                }]
            }
        }
    })
}

fn count_nodes(v: &Value) -> usize {
    match v {
        Value::Array(a) => 1 + a.iter().map(count_nodes).sum::<usize>(),
        Value::Object(o) => 1 + o.values().map(count_nodes).sum::<usize>(),
        _ => 1,
    }
}

fn peak_rss_mib() -> Option<f64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|l| l.starts_with("VmHWM:"))?;
    let kb: f64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kb / 1024.0)
}

fn main() {
    let mut args = std::env::args().skip(1);
    let depth: usize = args
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);
    let run_load = std::env::args().any(|a| a == "--load");

    let mut v = doc(depth);
    let src = if run_load {
        Some(serde_json::to_string(&v).expect("serialize"))
    } else {
        None
    };

    let t0 = Instant::now();
    earthsci_ast::lower_expression_templates::lower_expression_templates(&mut v)
        .expect("lower_expression_templates");
    let lower_time = t0.elapsed();
    let nodes = count_nodes(&v["reaction_systems"]["chem"]["reactions"][0]["rate"]);
    println!(
        "depth={depth} lower_expression_templates={lower_time:?} expanded_rate_nodes={nodes}"
    );

    if let Some(src) = src {
        let t1 = Instant::now();
        let file = earthsci_ast::parse::load(&src).expect("public load API");
        println!(
            "depth={depth} parse::load={:?} reactions={}",
            t1.elapsed(),
            file.reaction_systems
                .as_ref()
                .map(|r| r.len())
                .unwrap_or(0)
        );
    }

    if let Some(mib) = peak_rss_mib() {
        println!("peak_rss_mib={mib:.1}");
    }
}
