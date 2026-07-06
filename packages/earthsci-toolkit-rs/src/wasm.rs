//! WASM bindings for earthsci-toolkit
//!
//! This module provides WebAssembly bindings for use with TypeScript/JavaScript.

#[cfg(feature = "wasm")]
use crate::{
    EsmFile, graph::component_graph as rust_component_graph, load as rust_load,
    performance::CompactExpr, save as rust_save, stoichiometric_matrix, substitute_in_model,
    substitute_in_reaction_system, validate as rust_validate,
};
#[cfg(feature = "wasm")]
use wasm_bindgen::prelude::*;

/// Serialize any `Serialize` value to a plain JS object (never an ES `Map`),
/// so JS callers get uniform dot-access across every export. All exports go
/// through this one helper — previously some returned `Map`s and some plain
/// objects depending on which serializer they used.
#[cfg(feature = "wasm")]
fn to_js<T: serde::Serialize>(value: &T) -> Result<JsValue, JsValue> {
    let serializer = serde_wasm_bindgen::Serializer::new().serialize_maps_as_objects(true);
    value
        .serialize(&serializer)
        .map_err(|e| JsValue::from_str(&format!("Serialization error: {e}")))
}

/// Render every model equation and reaction rate of a loaded file with one of
/// the real expression pretty-printers from [`crate::display`] (the same ones
/// the CLI `pretty` command uses).
#[cfg(feature = "wasm")]
fn render_expressions(esm_file: &EsmFile, render: fn(&crate::Expr) -> String) -> String {
    let mut out = String::new();
    if let Some(models) = &esm_file.models {
        let mut ids: Vec<&String> = models.keys().collect();
        ids.sort();
        for model_id in ids {
            out.push_str(&format!("Model: {model_id}\n"));
            for (i, eq) in models[model_id].equations.iter().enumerate() {
                out.push_str(&format!(
                    "  Eq {}: {} = {}\n",
                    i + 1,
                    render(&eq.lhs),
                    render(&eq.rhs)
                ));
            }
        }
    }
    if let Some(reaction_systems) = &esm_file.reaction_systems {
        let mut ids: Vec<&String> = reaction_systems.keys().collect();
        ids.sort();
        for rs_id in ids {
            out.push_str(&format!("Reaction System: {rs_id}\n"));
            for (i, reaction) in reaction_systems[rs_id].reactions.iter().enumerate() {
                out.push_str(&format!(
                    "  Reaction {}: rate = {}\n",
                    i + 1,
                    render(&reaction.rate)
                ));
            }
        }
    }
    out
}

/// Load an ESM file from JSON string (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn load(json_str: &str) -> Result<JsValue, JsValue> {
    let esm_file =
        rust_load(json_str).map_err(|e| JsValue::from_str(&format!("Load error: {e}")))?;
    to_js(&esm_file)
}

/// Save an ESM file to JSON string (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn save(esm_file_js: &JsValue) -> Result<String, JsValue> {
    let esm_file: EsmFile = serde_wasm_bindgen::from_value(esm_file_js.clone())
        .map_err(|e| JsValue::from_str(&format!("Deserialization error: {e}")))?;

    match rust_save(&esm_file) {
        Ok(json) => Ok(json),
        Err(e) => Err(JsValue::from_str(&format!("Save error: {e}"))),
    }
}

/// Validate an ESM file (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn validate(json_str: &str) -> Result<JsValue, JsValue> {
    let esm_file =
        rust_load(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    let result = rust_validate(&esm_file);
    to_js(&result)
}

/// Pretty-print every equation and reaction rate with the Unicode expression
/// printer ([`crate::display::to_unicode`]) — the same renderer the CLI's
/// `pretty` command uses. (Earlier versions returned a metadata summary
/// instead of rendered math.)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn to_unicode(json_str: &str) -> Result<String, JsValue> {
    let esm_file =
        rust_load(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
    Ok(render_expressions(&esm_file, crate::display::to_unicode))
}

/// Pretty-print every equation and reaction rate with the LaTeX expression
/// printer ([`crate::display::to_latex`]).
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn to_latex(json_str: &str) -> Result<String, JsValue> {
    let esm_file =
        rust_load(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
    Ok(render_expressions(&esm_file, crate::display::to_latex))
}

/// Pretty-print every equation and reaction rate with the ASCII expression
/// printer ([`crate::display::to_ascii`]) — pure-ASCII output, unlike the
/// Unicode renderer.
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn to_ascii(json_str: &str) -> Result<String, JsValue> {
    let esm_file =
        rust_load(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
    Ok(render_expressions(&esm_file, crate::display::to_ascii))
}

/// Substitute expressions in ESM file (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn substitute(json_str: &str, bindings_str: &str) -> Result<String, JsValue> {
    use crate::Expr;

    let esm_file =
        rust_load(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    // Parse bindings as JSON object
    let bindings: serde_json::Value = serde_json::from_str(bindings_str)
        .map_err(|e| JsValue::from_str(&format!("Bindings parse error: {e}")))?;

    // Convert bindings to Expr objects
    let mut expr_bindings = std::collections::HashMap::new();
    if let serde_json::Value::Object(obj) = bindings {
        for (key, value) in obj {
            let expr = match value {
                serde_json::Value::Number(n) => {
                    if let Some(f) = n.as_f64() {
                        Expr::Number(f)
                    } else {
                        return Err(JsValue::from_str(&format!(
                            "Invalid number in bindings: {n}"
                        )));
                    }
                }
                serde_json::Value::String(s) => {
                    // Try to parse as number first, otherwise treat as variable
                    if let Ok(f) = s.parse::<f64>() {
                        Expr::Number(f)
                    } else {
                        Expr::Variable(s)
                    }
                }
                _ => {
                    return Err(JsValue::from_str(&format!(
                        "Unsupported binding type for key '{key}': {value:?}"
                    )));
                }
            };
            expr_bindings.insert(key, expr);
        }
    }

    let mut result_file = esm_file.clone();

    // Apply substitutions to all models
    if let Some(ref mut models) = result_file.models {
        for model in models.values_mut() {
            *model = substitute_in_model(model, &expr_bindings);
        }
    }

    // Apply substitutions to reaction systems if present
    if let Some(ref mut reactions) = result_file.reaction_systems {
        for reaction_system in reactions.values_mut() {
            *reaction_system = substitute_in_reaction_system(reaction_system, &expr_bindings);
        }
    }

    // Convert back to JSON string
    match rust_save(&result_file) {
        Ok(json) => Ok(json),
        Err(e) => Err(JsValue::from_str(&format!("Save error: {e}"))),
    }
}

/// Create a compact expression for fast evaluation (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn create_compact_expression(expr_str: &str) -> Result<JsValue, JsValue> {
    // Parse expression from JSON string
    let expr: crate::Expr = serde_json::from_str(expr_str)
        .map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    let compact = CompactExpr::from_expr(&expr);
    to_js(&compact)
}

/// Compute stoichiometric matrix (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn compute_stoichiometric_matrix(reaction_system_str: &str) -> Result<JsValue, JsValue> {
    let reaction_system: crate::ReactionSystem = serde_json::from_str(reaction_system_str)
        .map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    let matrix = stoichiometric_matrix(&reaction_system);
    to_js(&matrix)
}

/// Introspect the **flattened** simulation inputs of an `.esm` file (gt-5ws).
///
/// Runs the same `flatten` pass [`simulate`] uses, then reports the exact
/// parameter and state names it will accept — already namespaced — together
/// with their defaults and units, plus the system's independent variables. Use
/// this to build a Run UI without guessing the flattened names: the keys
/// returned here are exactly the keys to pass back in `params` / `ic`.
///
/// Returns `{ parameters: Var[], states: Var[], independentVariables: string[] }`
/// where `Var = { name: string, default: number | null, units: string | null }`.
/// A system whose `independentVariables` is not `["t"]` still has an
/// undiscretized spatial operator; discretized (array-op) PDEs report `["t"]`
/// here and run in the browser like any other file (EarthSciSerialization-akz).
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn simulate_inputs(json_str: &str) -> Result<JsValue, JsValue> {
    use crate::types::ModelVariable;
    use indexmap::IndexMap;

    let esm_file =
        rust_load(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
    let flat =
        crate::flatten(&esm_file).map_err(|e| JsValue::from_str(&format!("Flatten error: {e}")))?;

    let to_vars = |vars: &IndexMap<String, ModelVariable>| -> Vec<serde_json::Value> {
        vars.iter()
            .map(|(name, mv)| {
                serde_json::json!({ "name": name, "default": mv.default, "units": mv.units })
            })
            .collect()
    };

    let out = serde_json::json!({
        "parameters": to_vars(&flat.parameters),
        "states": to_vars(&flat.state_variables),
        "independentVariables": flat.independent_variables,
    });

    to_js(&out)
}

/// Run a simulation in the browser (WASM version, gt-5ws / spike S1).
///
/// Flattens and solves the `.esm` file through diffsol's Faer backend, entirely
/// client-side. Pure-ODE / 0-D box models and — since the `simulate_array` wasm
/// gate was lifted (EarthSciSerialization-akz) — array-op and discretized-PDE
/// files both run here through the same dispatch the native backend uses. The
/// one remaining wasm limitation is **spherical/geodesic
/// geometry** (conservative regridding via s2geometry): those leaf ops hit the
/// `crate::geometry` wasm stub and return a runtime `GeometryError`, since the
/// s2bindings C++ kernel is not linked into this `wasm32-unknown-unknown` build.
/// Planar-grid and geometry-free PDEs are unaffected.
///
/// Arguments:
/// - `json_str`: the `.esm` file as a JSON string.
/// - `t0`, `t_end`: the integration interval.
/// - `params_str`: JSON object mapping parameter name → value (`{}` for none).
/// - `ic_str`: JSON object mapping state name → initial value (`{}` to use the
///   model's `default`s).
/// - `opts_str`: JSON object, all fields optional —
///   `{ "solver": "bdf"|"sdirk"|"erk", "abstol": f64, "reltol": f64,
///      "maxSteps": u32, "outputPoints": u32 }`. `outputPoints` samples the
///   solution at that many evenly spaced times in `[t0, t_end]` (nice for
///   plotting); omit it to get the solver's natural step grid.
///
/// Returns a JS object `{ time: number[], state: number[][],
/// stateVariableNames: string[], metadata: {...} }` where
/// `state[i][k]` is variable `stateVariableNames[i]` at `time[k]`.
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn simulate(
    json_str: &str,
    t0: f64,
    t_end: f64,
    params_str: &str,
    ic_str: &str,
    opts_str: &str,
) -> Result<JsValue, JsValue> {
    use crate::simulate::{SimulateOptions, SolverChoice, simulate as rust_simulate};
    use std::collections::HashMap;

    let esm_file =
        rust_load(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    let parse_map = |s: &str, what: &str| -> Result<HashMap<String, f64>, JsValue> {
        let s = s.trim();
        if s.is_empty() {
            return Ok(HashMap::new());
        }
        serde_json::from_str(s).map_err(|e| JsValue::from_str(&format!("{what} parse error: {e}")))
    };
    let params = parse_map(params_str, "Params")?;
    let initial_conditions = parse_map(ic_str, "Initial-conditions")?;

    let opts_json: serde_json::Value = {
        let s = opts_str.trim();
        if s.is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(s)
                .map_err(|e| JsValue::from_str(&format!("Options parse error: {e}")))?
        }
    };

    let mut opts = SimulateOptions::default();
    if let Some(s) = opts_json.get("solver").and_then(|v| v.as_str()) {
        opts.solver = match s.to_ascii_lowercase().as_str() {
            "bdf" => SolverChoice::Bdf,
            "sdirk" => SolverChoice::Sdirk,
            "erk" => SolverChoice::Erk,
            other => return Err(JsValue::from_str(&format!("Unknown solver '{other}'"))),
        };
    }
    if let Some(v) = opts_json.get("abstol").and_then(|v| v.as_f64()) {
        opts.abstol = v;
    }
    if let Some(v) = opts_json.get("reltol").and_then(|v| v.as_f64()) {
        opts.reltol = v;
    }
    if let Some(v) = opts_json.get("maxSteps").and_then(|v| v.as_u64()) {
        opts.max_steps = v as usize;
    }
    if let Some(n) = opts_json.get("outputPoints").and_then(|v| v.as_u64()) {
        let n = (n as usize).max(2);
        let span = t_end - t0;
        opts.output_times = Some(
            (0..n)
                .map(|i| t0 + span * (i as f64) / ((n - 1) as f64))
                .collect(),
        );
    }

    let sol = rust_simulate(&esm_file, (t0, t_end), &params, &initial_conditions, &opts)
        .map_err(|e| JsValue::from_str(&format!("Simulation error: {e}")))?;

    let out = serde_json::json!({
        "time": sol.time,
        "state": sol.state,
        "stateVariableNames": sol.state_variable_names,
        "metadata": {
            "solver": sol.metadata.solver,
            "nRhsCalls": sol.metadata.n_rhs_calls,
            "nJacobianCalls": sol.metadata.n_jacobian_calls,
            "nAcceptedSteps": sol.metadata.n_accepted_steps,
            "nRejectedSteps": sol.metadata.n_rejected_steps,
        }
    });

    to_js(&out)
}

/// Generate component graph for ESM file (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn component_graph(json_str: &str) -> Result<JsValue, JsValue> {
    let esm_file =
        rust_load(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;

    let graph = rust_component_graph(&esm_file);
    to_js(&graph)
}

/// Report the crate and supported-schema versions. (The native performance
/// feature flags were dropped from this report: they are never enabled in a
/// wasm build, so advertising them here was misleading.)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn get_version_info() -> JsValue {
    let info = serde_json::json!({
        "version": crate::VERSION,
        "schema_version": crate::SCHEMA_VERSION,
    });
    to_js(&info).unwrap_or(JsValue::NULL)
}

/// Benchmark parsing performance (WASM version)
#[cfg(feature = "wasm")]
#[wasm_bindgen]
pub fn benchmark_parsing(json_str: &str, iterations: u32) -> Result<f64, JsValue> {
    let start = js_sys::Date::now();

    for _ in 0..iterations {
        rust_load(json_str).map_err(|e| JsValue::from_str(&format!("Parse error: {e}")))?;
    }

    let end = js_sys::Date::now();
    let total_time = end - start;

    Ok(total_time / iterations as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_wasm_exports_compile() {
        let json = r#"{
            "esm": "0.1.0",
            "metadata": {
                "name": "Test Model",
                "description": "A simple test model for WASM exports"
            },
            "models": {
                "SimpleModel": {
                    "variables": {
                        "x": {"type": "state", "units": "m", "default": 1.0},
                        "k": {"type": "parameter", "default": 0.5}
                    },
                    "equations": [
                        {"lhs": {"op": "D", "args": ["x"]}, "rhs": {"op": "*", "args": ["k", "x"]}}
                    ]
                }
            }
        }"#;

        // Test that the core functions work (without WASM feature for regular tests)
        let esm_file = rust_load(json).expect("Should load valid ESM file");
        let graph = rust_component_graph(&esm_file);

        assert_eq!(graph.nodes.len(), 1, "Should have 1 model node");
        assert_eq!(graph.edges.len(), 0, "Should have no edges");
        assert_eq!(graph.nodes[0].id, "SimpleModel");

        println!("✓ New WASM export functions compile and core functionality works");
    }
}
