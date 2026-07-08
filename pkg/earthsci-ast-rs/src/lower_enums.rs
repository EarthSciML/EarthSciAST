//! Load-time `enum`-op lowering pass — esm-spec §4.5, §9.3.
//!
//! Walks every expression tree in the file and replaces each
//! `{op: "enum", args: [enum_name, symbol]}` node with a
//! `{op: "const", args: [], value: <integer>}` node, using the file's
//! top-level `enums` block. After this pass, no `enum`-op nodes remain in
//! the in-memory representation — downstream consumers (evaluators,
//! canonicalize, codegen) only ever see resolved integer constants.
//!
//! Mirrors the Python (`registered_functions.lower_enums`) and Julia
//! (`lower_enums!`) passes for cross-binding parity, with the same
//! diagnostic codes (`unknown_enum`, `unknown_enum_symbol`).
//!
//! Operates on the pre-deserialization `serde_json::Value` view so that
//! it covers both top-level components and JSON-typed subsystem blobs in
//! a single walk.

use serde_json::{Map, Value};
use std::collections::HashMap;

const ENUM_OP: &str = "enum";

/// Stable diagnostic codes raised by the enum-lowering pass. Mirrors the
/// codes emitted by the TS / Python / Julia / Go bindings.
pub type EnumLoweringError = crate::diagnostic::DiagnosticError;

use crate::diagnostic::err;

fn parse_enums_block(
    value: &Value,
) -> Result<HashMap<String, HashMap<String, i64>>, EnumLoweringError> {
    let Some(root) = value.as_object() else {
        return Ok(HashMap::new());
    };
    let Some(enums_value) = root.get("enums") else {
        return Ok(HashMap::new());
    };
    let Some(enums_obj) = enums_value.as_object() else {
        return Err(err(
            "invalid_enums_block",
            "top-level `enums` must be an object",
        ));
    };
    let mut out = HashMap::new();
    for (enum_name, mapping) in enums_obj {
        let Some(map_obj) = mapping.as_object() else {
            return Err(err(
                "invalid_enums_block",
                format!("enums.{enum_name}: entry must be an object"),
            ));
        };
        let mut m = HashMap::new();
        for (sym, intval) in map_obj {
            let Some(n) = intval.as_i64() else {
                return Err(err(
                    "invalid_enums_block",
                    format!("enums.{enum_name}.{sym}: value must be an integer"),
                ));
            };
            m.insert(sym.clone(), n);
        }
        out.insert(enum_name.clone(), m);
    }
    Ok(out)
}

fn lower_enum_node(
    node: &Map<String, Value>,
    enums: &HashMap<String, HashMap<String, i64>>,
) -> Result<Value, EnumLoweringError> {
    let args = node.get("args").and_then(|v| v.as_array()).ok_or_else(|| {
        err(
            "enum_invalid_args",
            "`enum` op requires an `args` array of length 2",
        )
    })?;
    if args.len() != 2 {
        return Err(err(
            "enum_invalid_args",
            format!(
                "`enum` op expects 2 args (enum_name, symbol_name), got {}",
                args.len()
            ),
        ));
    }
    let enum_name = args[0].as_str().ok_or_else(|| {
        err(
            "enum_invalid_args",
            "`enum` op: first arg must be a string (enum name)",
        )
    })?;
    let symbol_name = args[1].as_str().ok_or_else(|| {
        err(
            "enum_invalid_args",
            "`enum` op: second arg must be a string (symbol name)",
        )
    })?;
    let mapping = enums.get(enum_name).ok_or_else(|| {
        err(
            "unknown_enum",
            format!(
                "unknown_enum: enum `{enum_name}` is not declared in the file's \
                 `enums` block"
            ),
        )
    })?;
    let int_value = mapping.get(symbol_name).ok_or_else(|| {
        err(
            "unknown_enum_symbol",
            format!(
                "unknown_enum_symbol: symbol `{symbol_name}` is not declared \
                 under enum `{enum_name}`"
            ),
        )
    })?;

    let mut out = Map::new();
    out.insert("op".to_string(), Value::String("const".to_string()));
    out.insert("args".to_string(), Value::Array(Vec::new()));
    out.insert("value".to_string(), Value::Number((*int_value).into()));
    Ok(Value::Object(out))
}

fn walk(
    node: &Value,
    enums: &HashMap<String, HashMap<String, i64>>,
) -> Result<Value, EnumLoweringError> {
    match node {
        Value::Array(arr) => {
            let mut out = Vec::with_capacity(arr.len());
            for c in arr {
                out.push(walk(c, enums)?);
            }
            Ok(Value::Array(out))
        }
        Value::Object(obj) => {
            if obj.get("op").and_then(|v| v.as_str()) == Some(ENUM_OP) {
                lower_enum_node(obj, enums)
            } else {
                let mut out = Map::new();
                for (k, v) in obj {
                    out.insert(k.clone(), walk(v, enums)?);
                }
                Ok(Value::Object(out))
            }
        }
        _ => Ok(node.clone()),
    }
}

fn find_enum_paths(view: &Value, path: &str, hits: &mut Vec<String>) {
    match view {
        Value::Array(arr) => {
            for (i, child) in arr.iter().enumerate() {
                find_enum_paths(child, &format!("{path}/{i}"), hits);
            }
        }
        Value::Object(obj) => {
            if obj.get("op").and_then(|v| v.as_str()) == Some(ENUM_OP) {
                hits.push(path.to_string());
                for (k, v) in obj {
                    find_enum_paths(v, &format!("{path}/{k}"), hits);
                }
            } else {
                for (k, v) in obj {
                    find_enum_paths(v, &format!("{path}/{k}"), hits);
                }
            }
        }
        _ => {}
    }
}

/// Lower every `enum`-op node in `value` to a `{op: "const", value: <int>}`
/// node using the file's top-level `enums` block. Mutates `value` in place.
///
/// Pre-condition: the input has been schema-validated and any
/// `apply_expression_template` ops have already been expanded.
///
/// Errors with diagnostic codes:
/// - `unknown_enum` — `enum` op references an undeclared enum name
/// - `unknown_enum_symbol` — `enum` op references an undeclared symbol
/// - `enum_invalid_args` — `enum` op has a non-positional or wrong-arity body
/// - `invalid_enums_block` — top-level `enums` block is malformed
pub fn lower_enums(value: &mut Value) -> Result<(), EnumLoweringError> {
    let enums = parse_enums_block(value)?;

    // Fast path: no enum-op nodes anywhere; skip the rebuild.
    let mut paths: Vec<String> = Vec::new();
    find_enum_paths(value, "", &mut paths);
    if paths.is_empty() {
        return Ok(());
    }

    let walked = walk(value, &enums)?;
    *value = walked;

    // Defensive: assert no enum nodes remain.
    let mut leftover: Vec<String> = Vec::new();
    find_enum_paths(value, "", &mut leftover);
    if !leftover.is_empty() {
        return Err(err(
            "enum_lowering_residual",
            format!(
                "enum-op nodes remain after lowering at: {}",
                leftover.join(", ")
            ),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn lowered(input: Value) -> Value {
        let mut v = input;
        lower_enums(&mut v).expect("lowering should succeed");
        v
    }

    #[test]
    fn basic_enum_replaced_with_const() {
        let input = json!({
            "enums": {
                "season": {"winter": 1, "spring": 2, "summer": 3, "autumn": 4}
            },
            "models": {
                "M": {
                    "variables": {
                        "s": {
                            "type": "observed",
                            "expression": {
                                "op": "enum",
                                "args": ["season", "summer"]
                            }
                        }
                    },
                    "equations": []
                }
            }
        });
        let out = lowered(input);
        let expr = &out["models"]["M"]["variables"]["s"]["expression"];
        assert_eq!(expr["op"], "const");
        assert_eq!(expr["value"], 3);
        assert_eq!(expr["args"], json!([]));
    }

    #[test]
    fn nested_enum_in_index_op() {
        let input = json!({
            "enums": {
                "season": {"summer": 3},
                "land_use": {"forest": 5}
            },
            "models": {
                "M": {
                    "variables": {
                        "r": {
                            "type": "observed",
                            "expression": {
                                "op": "index",
                                "args": [
                                    {"op": "const", "args": [], "value": [[1, 2, 3]]},
                                    {"op": "enum", "args": ["season", "summer"]},
                                    {"op": "enum", "args": ["land_use", "forest"]}
                                ]
                            }
                        }
                    },
                    "equations": []
                }
            }
        });
        let out = lowered(input);
        let expr = &out["models"]["M"]["variables"]["r"]["expression"];
        assert_eq!(expr["op"], "index");
        assert_eq!(expr["args"][1]["op"], "const");
        assert_eq!(expr["args"][1]["value"], 3);
        assert_eq!(expr["args"][2]["op"], "const");
        assert_eq!(expr["args"][2]["value"], 5);
    }

    #[test]
    fn unknown_enum_rejected() {
        let mut v = json!({
            "enums": {"season": {"summer": 3}},
            "models": {"M": {
                "variables": {"x": {
                    "type": "observed",
                    "expression": {"op": "enum", "args": ["weekday", "monday"]}
                }},
                "equations": []
            }}
        });
        let err = lower_enums(&mut v).unwrap_err();
        assert_eq!(err.code, "unknown_enum");
        assert!(err.message.contains("weekday"));
    }

    #[test]
    fn unknown_enum_symbol_rejected() {
        let mut v = json!({
            "enums": {"season": {"summer": 3}},
            "models": {"M": {
                "variables": {"x": {
                    "type": "observed",
                    "expression": {"op": "enum", "args": ["season", "winter"]}
                }},
                "equations": []
            }}
        });
        let err = lower_enums(&mut v).unwrap_err();
        assert_eq!(err.code, "unknown_enum_symbol");
        assert!(err.message.contains("winter"));
        assert!(err.message.contains("season"));
    }

    #[test]
    fn missing_enums_block_rejects_enum_op() {
        let mut v = json!({
            "models": {"M": {
                "variables": {"x": {
                    "type": "observed",
                    "expression": {"op": "enum", "args": ["season", "summer"]}
                }},
                "equations": []
            }}
        });
        let err = lower_enums(&mut v).unwrap_err();
        assert_eq!(err.code, "unknown_enum");
    }

    #[test]
    fn wrong_arity_rejected() {
        let mut v = json!({
            "enums": {"season": {"summer": 3}},
            "models": {"M": {
                "variables": {"x": {
                    "type": "observed",
                    "expression": {"op": "enum", "args": ["season"]}
                }},
                "equations": []
            }}
        });
        let err = lower_enums(&mut v).unwrap_err();
        assert_eq!(err.code, "enum_invalid_args");
    }

    #[test]
    fn no_enums_no_change() {
        let input = json!({
            "models": {"M": {
                "variables": {"x": {"type": "state", "default": 0.0}},
                "equations": [{
                    "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                    "rhs": {"op": "*", "args": [0.1, "x"]}
                }]
            }}
        });
        let out = lowered(input.clone());
        assert_eq!(out, input);
    }

    #[test]
    fn enum_op_in_reaction_rate() {
        let input = json!({
            "enums": {"phase": {"day": 1, "night": 2}},
            "reaction_systems": {
                "RS": {
                    "species": [],
                    "reactions": [{
                        "id": "r1",
                        "substrates": {},
                        "products": {},
                        "rate": {
                            "op": "*",
                            "args": [1.0, {"op": "enum", "args": ["phase", "day"]}]
                        }
                    }]
                }
            }
        });
        let out = lowered(input);
        let rate = &out["reaction_systems"]["RS"]["reactions"][0]["rate"];
        assert_eq!(rate["args"][1]["op"], "const");
        assert_eq!(rate["args"][1]["value"], 1);
    }

    #[test]
    fn enum_op_in_subsystem_blob() {
        // Subsystems land as raw JSON in the Rust types, so the JSON walk
        // must descend through them too.
        let input = json!({
            "enums": {"season": {"summer": 3}},
            "models": {"Outer": {
                "variables": {},
                "equations": [],
                "subsystems": {
                    "Inner": {
                        "variables": {"y": {
                            "type": "observed",
                            "expression": {"op": "enum", "args": ["season", "summer"]}
                        }},
                        "equations": []
                    }
                }
            }}
        });
        let out = lowered(input);
        let expr = &out["models"]["Outer"]["subsystems"]["Inner"]["variables"]["y"]["expression"];
        assert_eq!(expr["op"], "const");
        assert_eq!(expr["value"], 3);
    }
}
