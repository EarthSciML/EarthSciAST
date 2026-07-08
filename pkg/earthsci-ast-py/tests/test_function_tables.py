"""Roundtrip tests for the v0.4.0 function_tables block + table_lookup AST op
(esm-spec §9.5).

Coverage:
- 1-axis linear, single-output table
- 2-axis bilinear, multi-output table with named outputs
- table_lookup with int output index
- table_lookup with string output name
- axes (object, per-axis input expression map) preserved across load/save
"""

import json

from earthsci_ast import (
    EsmFile,
    ExprNode,
    FunctionTable,
    FunctionTableAxis,
    load,
    save,
)


FIXTURE = {
    "esm": "0.4.0",
    "metadata": {"name": "ft_smoke", "authors": ["test"]},
    "function_tables": {
        "sigma_O3": {
            "description": "1-D linear table",
            "axes": [{"name": "lambda_idx", "values": [1, 2, 3, 4]}],
            "interpolation": "linear",
            "out_of_bounds": "clamp",
            "data": [1.1e-17, 1.0e-17, 9.5e-18, 8.7e-18],
        },
        "F_actinic": {
            "axes": [
                {"name": "P", "units": "Pa", "values": [10, 100, 1000]},
                {"name": "cos_sza", "values": [0.1, 0.5, 1.0]},
            ],
            "interpolation": "bilinear",
            "outputs": ["NO2", "O3"],
            "data": [
                [[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]],
                [[2.0, 2.5, 3.0], [2.1, 2.6, 3.1], [2.2, 2.7, 3.2]],
            ],
        },
    },
    "models": {
        "M": {
            "variables": {
                "k_O3": {"type": "state", "default": 0.0},
                "j_NO2": {"type": "state", "default": 0.0},
                "P_atm": {"type": "parameter", "default": 101325.0},
                "cos_sza": {"type": "parameter", "default": 0.5},
            },
            "equations": [
                {
                    "lhs": {"op": "D", "args": ["k_O3"], "wrt": "t"},
                    "rhs": {
                        "op": "table_lookup",
                        "table": "sigma_O3",
                        "axes": {"lambda_idx": 2},
                        "args": [],
                    },
                },
                {
                    "lhs": {"op": "D", "args": ["j_NO2"], "wrt": "t"},
                    "rhs": {
                        "op": "table_lookup",
                        "table": "F_actinic",
                        "axes": {"P": "P_atm", "cos_sza": "cos_sza"},
                        "output": "NO2",
                        "args": [],
                    },
                },
            ],
        }
    },
}


def test_function_tables_load():
    ef = load(FIXTURE)
    assert isinstance(ef, EsmFile)
    assert set(ef.function_tables.keys()) == {"sigma_O3", "F_actinic"}

    sig = ef.function_tables["sigma_O3"]
    assert isinstance(sig, FunctionTable)
    assert len(sig.axes) == 1
    assert isinstance(sig.axes[0], FunctionTableAxis)
    assert sig.axes[0].name == "lambda_idx"
    assert sig.axes[0].values == [1, 2, 3, 4]
    assert sig.interpolation == "linear"

    fa = ef.function_tables["F_actinic"]
    assert len(fa.axes) == 2
    assert fa.outputs == ["NO2", "O3"]
    assert fa.axes[0].units == "Pa"


def test_table_lookup_node_load():
    ef = load(FIXTURE)
    eqs = ef.models["M"].equations
    assert len(eqs) == 2

    rhs0 = eqs[0].rhs
    assert isinstance(rhs0, ExprNode)
    assert rhs0.op == "table_lookup"
    assert rhs0.table == "sigma_O3"
    assert "lambda_idx" in (rhs0.table_axes or {})
    assert rhs0.args == []

    rhs1 = eqs[1].rhs
    assert isinstance(rhs1, ExprNode)
    assert rhs1.op == "table_lookup"
    assert rhs1.table == "F_actinic"
    assert rhs1.output == "NO2"
    assert set((rhs1.table_axes or {}).keys()) == {"P", "cos_sza"}


def test_function_tables_roundtrip():
    ef = load(FIXTURE)
    out = save(ef)
    reloaded = json.loads(out)
    # function_tables block survives.
    assert set(reloaded["function_tables"].keys()) == {"sigma_O3", "F_actinic"}
    assert reloaded["function_tables"]["F_actinic"]["outputs"] == ["NO2", "O3"]
    # table_lookup nodes survive (not lowered to inline-const on save).
    rhs0 = reloaded["models"]["M"]["equations"][0]["rhs"]
    assert rhs0["op"] == "table_lookup"
    assert rhs0["table"] == "sigma_O3"
    assert rhs0["axes"] == {"lambda_idx": 2}
    rhs1 = reloaded["models"]["M"]["equations"][1]["rhs"]
    assert rhs1["op"] == "table_lookup"
    assert rhs1["output"] == "NO2"
    # Round-trip is a fixed point: re-load and re-save yields the same dict.
    ef2 = load(reloaded)
    out2 = save(ef2)
    assert json.loads(out2) == reloaded
