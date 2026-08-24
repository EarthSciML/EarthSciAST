//! Example demonstrating unit validation functionality

use earthsci_ast::{load_string, validate};

fn main() {
    // Test data with dimensional inconsistency
    let test_data_inconsistent = r#"
        {
          "esm": "1.0.0",
          "metadata": {
            "name": "Unit Validation Test - Inconsistent"
          },
          "models": {
            "test_model": {
              "variables": {
                "x": {
                  "type": "unknown",
                  "units": "m",
                  "default": 1.0
                },
                "k": {
                  "type": "parameter",
                  "units": "kg",
                  "default": 0.5
                }
              },
              "equations": [
                {
                  "lhs": {
                    "op": "D",
                    "args": [
                      "x"
                    ],
                    "wrt": "t"
                  },
                  "rhs": "k"
                }
              ]
            }
          }
        }
        "#;

    println!("Testing dimensionally inconsistent model...");
    let esm_file = load_string(test_data_inconsistent).expect("Should parse successfully");
    let result = validate(&esm_file);

    println!("Validation result:");
    println!("  Valid: {}", result.is_valid);
    println!("  Schema errors: {}", result.schema_errors.len());
    println!("  Structural errors: {}", result.structural_errors.len());
    println!("  Unit warnings: {}", result.unit_warnings.len());

    if !result.unit_warnings.is_empty() {
        println!("Unit warnings:");
        for warning in &result.unit_warnings {
            println!("  - {}", warning.message);
        }
    }

    println!();

    // Test data with dimensional consistency
    let test_data_consistent = r#"
        {
          "esm": "1.0.0",
          "metadata": {
            "name": "Unit Validation Test - Consistent"
          },
          "models": {
            "test_model": {
              "variables": {
                "x": {
                  "type": "unknown",
                  "units": "m",
                  "default": 1.0
                },
                "k": {
                  "type": "parameter",
                  "units": "1/s",
                  "default": 0.5
                }
              },
              "equations": [
                {
                  "lhs": {
                    "op": "D",
                    "args": [
                      "x"
                    ],
                    "wrt": "t"
                  },
                  "rhs": {
                    "op": "*",
                    "args": [
                      "k",
                      "x"
                    ]
                  }
                }
              ]
            }
          }
        }
        "#;

    println!("Testing dimensionally consistent model...");
    let esm_file = load_string(test_data_consistent).expect("Should parse successfully");
    let result = validate(&esm_file);

    println!("Validation result:");
    println!("  Valid: {}", result.is_valid);
    println!("  Schema errors: {}", result.schema_errors.len());
    println!("  Structural errors: {}", result.structural_errors.len());
    println!("  Unit warnings: {}", result.unit_warnings.len());

    if !result.unit_warnings.is_empty() {
        println!("Unit warnings:");
        for warning in &result.unit_warnings {
            println!("  - {}", warning.message);
        }
    } else {
        println!("No unit warnings - model is dimensionally consistent!");
    }
}
