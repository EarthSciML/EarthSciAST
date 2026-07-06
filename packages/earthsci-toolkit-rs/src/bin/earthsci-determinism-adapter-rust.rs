//! `earthsci-determinism-adapter-rust` — the Rust producer for the cross-binding
//! determinism conformance harness (`scripts/run-determinism-conformance.py`,
//! CONFORMANCE_SPEC.md §5.5.4).
//!
//! Thin by design (the contract lives in [`earthsci_toolkit::relational`], not
//! here): load the manifest, run the REAL value-invention primitives
//! (`skolem` / `distinct` / `rank`) and group-by aggregate over each fixture's
//! `inputs.canonical` payload AND every adversarial `inputs.variants` payload,
//! and write — per fixture — the canonical serialized index set, its index_set,
//! and the dense-ID array in Rust's native 0-based emission base (the runner
//! normalizes via `rank_base_pin`). The runner asserts byte-identity to the
//! golden and that every variant collapses to it.
//!
//! Invoked as `earthsci-determinism-adapter-rust --manifest <m.json> --output <r.json>`.

use earthsci_toolkit::relational::{
    Key, Num, Ranking, SemiringOp, canonical_index_set_json, distinct, group_aggregate, rank,
    serialize_pairs, skolem, skolem_edge,
};
use earthsci_toolkit::adapter_support::{parse_manifest_output_args, write_report};
use serde_json::{Map, Value, json};
use std::path::Path;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args = match parse_manifest_output_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("determinism-adapter-rust: {e}");
            return ExitCode::FAILURE;
        }
    };
    match run(&args.manifest, &args.output) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("determinism-adapter-rust: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(manifest_path: &Path, output_path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let manifest: Value = serde_json::from_str(&std::fs::read_to_string(manifest_path)?)?;
    let fixtures = manifest
        .get("fixtures")
        .and_then(|v| v.as_array())
        .ok_or("manifest.fixtures must be an array")?;

    let mut out_fixtures = Map::new();
    for fx in fixtures {
        let id = fx.get("id").and_then(|v| v.as_str()).ok_or("fixture.id")?;
        let inputs = fx.get("inputs").ok_or("fixture.inputs")?;

        let canonical = inputs.get("canonical").ok_or("fixture.inputs.canonical")?;
        let mut record = compute_payload(fx, canonical)?;

        // The adversarial variants run through the SAME producers; the runner
        // asserts each collapses to the golden (§5.5.4 order/dup/orientation).
        if let Some(variants) = inputs.get("variants").and_then(|v| v.as_object()) {
            let mut vout = Map::new();
            for (vname, vpayload) in variants {
                vout.insert(vname.clone(), compute_payload(fx, vpayload)?);
            }
            if let Value::Object(ref mut obj) = record {
                obj.insert("variants".to_string(), Value::Object(vout));
            }
        }

        out_fixtures.insert(id.to_string(), record);
    }

    let report = json!({ "binding": "rust", "fixtures": Value::Object(out_fixtures) });
    write_report(output_path, &report)
}

/// Run the primitives for one input payload, returning the conformance record
/// `{index_set, serialized, dense_ids_canonical}`. Dense IDs are emitted in
/// Rust's native 0-based base; the runner base-normalizes before comparison.
fn compute_payload(fx: &Value, payload: &Value) -> Result<Value, Box<dyn std::error::Error>> {
    let primitive = fx
        .get("primitive")
        .and_then(|v| v.as_str())
        .ok_or("fixture.primitive")?;
    match primitive {
        "skolem_distinct_rank" => {
            let mode = fx
                .get("skolem")
                .and_then(|v| v.as_str())
                .ok_or("fixture.skolem")?;
            let edges = edges_from_payload(payload)?;
            let keys: Vec<Key> = match mode {
                "undirected" => edges
                    .into_iter()
                    .map(|mut e| {
                        let b = e.pop().ok_or("edge needs 2 components")?;
                        let a = e.pop().ok_or("edge needs 2 components")?;
                        Ok::<Key, Box<dyn std::error::Error>>(skolem_edge(a, b))
                    })
                    .collect::<Result<_, _>>()?,
                "directed" => edges.into_iter().map(|e| skolem(e, false)).collect(),
                other => return Err(format!("unknown skolem mode {other:?}").into()),
            };
            let index_set = distinct(&keys);
            let serialized = canonical_index_set_json(&keys);
            let ranking: Ranking = rank(&keys); // native 0-based
            let dense: Vec<i64> = index_set.iter().map(|t| ranking.id[t]).collect();
            Ok(json!({
                "index_set": index_set.iter().map(key_to_json).collect::<Vec<_>>(),
                "serialized": serialized,
                "dense_ids_canonical": dense,
            }))
        }
        "group_by_sum" => {
            let rows_json = payload
                .get("rows")
                .and_then(|v| v.as_array())
                .ok_or("payload.rows")?;
            let mut rows: Vec<(Key, Num)> = Vec::with_capacity(rows_json.len());
            for row in rows_json {
                let pair = row
                    .as_array()
                    .ok_or("group row must be a [key,value] array")?;
                let key = Key::try_from_json(pair.first().ok_or("group row needs a key")?)?;
                let val = pair.get(1).ok_or("group row needs a value")?;
                let num = val
                    .as_i64()
                    .map(Num::Int)
                    .ok_or("group_by_sum value must be an integer")?;
                rows.push((key, num));
            }
            let pairs = group_aggregate(&rows, SemiringOp::Sum);
            let serialized = serialize_pairs(&pairs);
            let index_set: Vec<Value> = pairs
                .iter()
                .map(|(k, v)| Value::Array(vec![key_to_json(k), num_to_json(v)]))
                .collect();
            let dense: Vec<i64> = (0..pairs.len() as i64).collect(); // native 0-based
            Ok(json!({
                "index_set": index_set,
                "serialized": serialized,
                "dense_ids_canonical": dense,
            }))
        }
        other => Err(format!("unknown primitive {other:?}").into()),
    }
}

/// Build the directed component lists for one payload: either `faces` (traverse
/// consecutive vertices with wraparound) or pre-built `tuples`.
fn edges_from_payload(payload: &Value) -> Result<Vec<Vec<Key>>, Box<dyn std::error::Error>> {
    if let Some(faces) = payload.get("faces").and_then(|v| v.as_array()) {
        let mut edges = Vec::new();
        for face in faces {
            let verts = face.as_array().ok_or("face must be an array")?;
            let n = verts.len();
            for i in 0..n {
                let a = Key::try_from_json(&verts[i])?;
                let b = Key::try_from_json(&verts[(i + 1) % n])?;
                edges.push(vec![a, b]);
            }
        }
        Ok(edges)
    } else if let Some(tuples) = payload.get("tuples").and_then(|v| v.as_array()) {
        let mut edges = Vec::new();
        for t in tuples {
            let comps = t.as_array().ok_or("tuple must be an array")?;
            let mut row = Vec::with_capacity(comps.len());
            for c in comps {
                row.push(Key::try_from_json(c)?);
            }
            edges.push(row);
        }
        Ok(edges)
    } else {
        Err("payload needs 'faces' or 'tuples'".into())
    }
}

fn key_to_json(k: &Key) -> Value {
    match k {
        Key::Int(i) => json!(i),
        Key::Str(s) => json!(s),
        Key::Bool(b) => json!(b),
        Key::Tuple(items) => Value::Array(items.iter().map(key_to_json).collect()),
    }
}

fn num_to_json(n: &Num) -> Value {
    match n {
        Num::Int(i) => json!(i),
        Num::Float(f) => json!(f),
    }
}
