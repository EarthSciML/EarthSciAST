//! Roundtrip tests for the v0.4.0 function_tables block + table_lookup AST op
//! (esm-spec §9.5).

use earthsci_ast::{EsmFile, Expr, load};

const FIXTURE: &str = r#"{
  "esm": "0.4.0",
  "metadata": {"name": "ft_smoke", "authors": ["test"]},
  "function_tables": {
    "sigma_O3": {
      "description": "1-D linear table",
      "axes": [
        {"name": "lambda_idx", "values": [1, 2, 3, 4]}
      ],
      "interpolation": "linear",
      "out_of_bounds": "clamp",
      "data": [1.1e-17, 1.0e-17, 9.5e-18, 8.7e-18]
    },
    "F_actinic": {
      "axes": [
        {"name": "P", "units": "Pa", "values": [10, 100, 1000]},
        {"name": "cos_sza", "values": [0.1, 0.5, 1.0]}
      ],
      "interpolation": "bilinear",
      "outputs": ["NO2", "O3"],
      "data": [
        [[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]],
        [[2.0, 2.5, 3.0], [2.1, 2.6, 3.1], [2.2, 2.7, 3.2]]
      ]
    }
  },
  "models": {
    "M": {
      "variables": {
        "k_O3":   {"type": "state",     "default": 0.0},
        "j_NO2":  {"type": "state",     "default": 0.0},
        "P_atm":  {"type": "parameter", "default": 101325.0},
        "cos_sza":{"type": "parameter", "default": 0.5}
      },
      "equations": [
        {"lhs": {"op": "D", "args": ["k_O3"], "wrt": "t"}, "rhs": {
          "op": "table_lookup",
          "table": "sigma_O3",
          "axes": {"lambda_idx": 2},
          "args": []
        }},
        {"lhs": {"op": "D", "args": ["j_NO2"], "wrt": "t"}, "rhs": {
          "op": "table_lookup",
          "table": "F_actinic",
          "axes": {"P": "P_atm", "cos_sza": "cos_sza"},
          "output": "NO2",
          "args": []
        }}
      ]
    }
  }
}"#;

#[test]
fn function_tables_block_loads() {
    let file: EsmFile = load(FIXTURE).expect("load function_tables fixture");
    let fts = file
        .function_tables
        .as_ref()
        .expect("function_tables present");
    assert_eq!(fts.len(), 2);
    let sig = &fts["sigma_O3"];
    assert_eq!(sig.axes.len(), 1);
    assert_eq!(sig.axes[0].name, "lambda_idx");
    assert_eq!(sig.axes[0].values, vec![1.0, 2.0, 3.0, 4.0]);
    assert_eq!(sig.interpolation.as_deref(), Some("linear"));
    let fa = &fts["F_actinic"];
    assert_eq!(fa.axes.len(), 2);
    assert_eq!(fa.axes[0].units.as_deref(), Some("Pa"));
    assert_eq!(
        fa.outputs.as_deref(),
        Some(&["NO2".to_string(), "O3".to_string()][..])
    );
}

#[test]
fn table_lookup_node_loads() {
    let file: EsmFile = load(FIXTURE).expect("load function_tables fixture");
    let model = &file.models.as_ref().unwrap()["M"];
    let eqs = &model.equations;
    assert_eq!(eqs.len(), 2);

    let rhs0 = match &eqs[0].rhs {
        Expr::Operator(node) => node,
        _ => panic!("eq0.rhs must be ExpressionNode"),
    };
    assert_eq!(rhs0.op, "table_lookup");
    assert_eq!(rhs0.table.as_deref(), Some("sigma_O3"));
    assert!(rhs0.axes.as_ref().unwrap().contains_key("lambda_idx"));
    assert!(rhs0.args.is_empty());

    let rhs1 = match &eqs[1].rhs {
        Expr::Operator(node) => node,
        _ => panic!("eq1.rhs must be ExpressionNode"),
    };
    assert_eq!(rhs1.op, "table_lookup");
    assert_eq!(rhs1.output.as_ref().unwrap().as_str(), Some("NO2"));
    assert_eq!(rhs1.axes.as_ref().unwrap().len(), 2);
}

#[test]
fn round_trip_preserves_authored_form() {
    let file: EsmFile = load(FIXTURE).expect("load function_tables fixture");
    let out = serde_json::to_string(&file).expect("serialize");
    let reloaded: serde_json::Value = serde_json::from_str(&out).expect("re-parse");
    let fts = reloaded["function_tables"].as_object().unwrap();
    assert!(fts.contains_key("sigma_O3"));
    assert!(fts.contains_key("F_actinic"));
    let rhs0 = &reloaded["models"]["M"]["equations"][0]["rhs"];
    assert_eq!(rhs0["op"], "table_lookup");
    assert_eq!(rhs0["table"], "sigma_O3");
    assert_eq!(rhs0["axes"]["lambda_idx"], 2);
    let rhs1 = &reloaded["models"]["M"]["equations"][1]["rhs"];
    assert_eq!(rhs1["op"], "table_lookup");
    assert_eq!(rhs1["output"], "NO2");

    // Round-trip is a fixed point: re-load and re-save yields the same JSON.
    let file2: EsmFile = load(&out).expect("reload");
    let out2 = serde_json::to_string(&file2).expect("re-serialize");
    let reloaded2: serde_json::Value = serde_json::from_str(&out2).expect("re-parse 2");
    assert_eq!(reloaded2, reloaded);
}
