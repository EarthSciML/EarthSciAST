"""CROSS-BINDING conformance for §5.5.6 join-name namespacing under flattening.

A relational ``join`` carries its references as plain STRINGS — an ``on`` key
column, and an ``overlap`` clause's ``src_env`` / ``tgt_env`` envelope factors —
rather than as child expressions. That is an ENCODING choice, not a scoping one:
the value-invention materializer resolves every one of those names against the
variable registry (``value_invention._vi_join_index_sym`` -> ``ctx.variables``,
``broad_phase.envelope_vectors`` -> ``const_arrays``), and after flattening that
registry is the dot-namespaced one. So they are namespaced with everything else,
under the same declared-local gate: a loop symbol or a document-scoped index set
named by an ``on`` column is not a local variable and passes through untouched.

Python previously namespaced nothing in ``join`` at all, on the stated ground
that the pass "has no index-set registry to tell the two apart". It does not
need one — it needs the declared-LOCAL set, which it has. Mirrors
``earthsci-ast-rs/tests/join_namespacing.rs`` and the Julia
``join_namespacing_test.jl`` case for case.
"""

from __future__ import annotations

import copy
import json
import os

import numpy as np

from earthsci_ast.flatten import flatten
from earthsci_ast.parse import load
from earthsci_ast.value_invention import materialize_value_invention

FIXTURE = os.path.normpath(
    os.path.join(
        os.path.dirname(__file__),
        "..",
        "..",
        "earthsci-ast-rs",
        "tests",
        "fixtures",
        "pushdown",
        "overlap_gate_point_in_rect.esm",
    )
)

JOIN_FILTER_FIXTURE = os.path.normpath(
    os.path.join(
        os.path.dirname(__file__),
        "..",
        "..",
        "..",
        "tests",
        "valid",
        "aggregate",
        "join_filter.esm",
    )
)


def l1_geometry(prefix: str = "") -> dict[str, np.ndarray]:
    """The ISRM L1 geometry, keyed under ``prefix`` (``"ISRM."`` once flat)."""
    return {
        prefix + "W": np.array([0.0, 2.0, 4.0, 0.0, 2.0, 4.0, 0.0, 2.0, 4.0]),
        prefix + "E": np.array([2.0, 4.0, 6.0, 2.0, 4.0, 6.0, 2.0, 4.0, 6.0]),
        prefix + "S": np.array([0.0, 0.0, 0.0, 2.0, 2.0, 2.0, 4.0, 4.0, 4.0]),
        prefix + "N": np.array([2.0, 2.0, 2.0, 4.0, 4.0, 4.0, 6.0, 6.0, 6.0]),
        prefix + "X": np.array([1.0, 3.0, 1.0, 5.0, 1.5]),
        prefix + "Y": np.array([1.0, 1.0, 3.0, 5.0, 1.5]),
    }


def flatten_doc(doc: dict):
    return flatten(load(doc))


def producer(flat):
    """The one flattened equation whose RHS carries a ``join``."""
    for eq in flat.equations:
        rhs = eq.rhs
        if getattr(rhs, "join", None):
            return rhs
    raise AssertionError("no join-bearing equation in the flattened system")


def flattened_model(doc: dict, flat) -> dict:
    """The raw-JSON model view the value-invention engine consumes, rebuilt from
    the flattened system (variables + equations + document-scoped index sets)."""
    from earthsci_ast.serialize import _serialize_expression as expr_to_dict

    variables = {}
    for table in (flat.state_variables, flat.parameters, flat.observed_variables):
        for name, var in table.items():
            entry: dict = {"type": "parameter" if var.type == "parameter" else "state"}
            if var.shape:
                entry["shape"] = list(var.shape)
            variables[name] = entry
    equations = [
        {"lhs": expr_to_dict(eq.lhs), "rhs": expr_to_dict(eq.rhs)} for eq in flat.equations
    ]
    return {
        "variables": variables,
        "equations": equations,
        "index_sets": doc.get("index_sets", {}),
    }


# --------------------------------------------------------------------------- #
# The overlap envelope factors
# --------------------------------------------------------------------------- #


def test_flatten_namespaces_overlap_envelope_factors():
    """``src_env`` / ``tgt_env`` name variables, so flattening namespaces them —
    and the SAME six names appear in the node's ``args`` as expression children,
    so the two spellings must agree."""
    with open(FIXTURE) as fh:
        doc = json.load(fh)
    flat = flatten_doc(doc)
    node = producer(flat)

    overlap = node.join[0]["overlap"]
    assert overlap["src_env"] == ["ISRM.X", "ISRM.Y"]
    assert overlap["tgt_env"] == ["ISRM.W", "ISRM.S", "ISRM.E", "ISRM.N"]

    args = [a for a in node.args if isinstance(a, str)]
    assert sorted(args) == sorted(overlap["src_env"] + overlap["tgt_env"]), (
        f"a node must not spell the same factor two ways: args={args}"
    )
    for name in overlap["src_env"] + overlap["tgt_env"]:
        assert name in flat.parameters, f"{name} is not in the flattened registry"


def test_flattened_overlap_producer_materializes_the_golden_support_set():
    """End-to-end: the FLATTENED model materialises the Julia golden
    ``[1,2,4,9]``. Before the fix the envelope names stayed bare while the
    registry was namespaced, so nothing resolved."""
    with open(FIXTURE) as fh:
        doc = json.load(fh)
    flat = flatten_doc(doc)
    vi = materialize_value_invention(
        flattened_model(doc, flat), const_arrays=l1_geometry("ISRM.")
    )
    assert vi.members["emis_src_cells_faq"] == [1, 2, 4, 9], (
        "flattening must not change the support set (§5.5.6: integer keys)"
    )


# --------------------------------------------------------------------------- #
# The declared-local gate
# --------------------------------------------------------------------------- #


def test_join_on_loop_symbols_and_index_sets_are_left_alone():
    """The gate is the declared-local set, not "every bare string". The
    committed M2 fixture joins two LOOP SYMBOLS against two document-scoped
    INDEX SETS; none is a component-local variable."""
    with open(JOIN_FILTER_FIXTURE) as fh:
        doc = json.load(fh)
    node = producer(flatten_doc(doc))
    assert node.join[0]["on"] == [["src", "sourceType"], ["fuel", "fuelType"]]


def test_join_on_key_column_naming_a_local_buffer_is_namespaced():
    """...and the positive half: a key column naming a component-local
    value-invention bin buffer follows the registry."""
    with open(JOIN_FILTER_FIXTURE) as fh:
        doc = json.load(fh)
    model = doc["models"]["EmissionsAggregate"]
    model["variables"]["src_bin"] = {"type": "parameter"}
    model["variables"]["tgt_bin"] = {"type": "parameter"}
    model["equations"][0]["rhs"]["join"] = [
        {"on": [["src_bin", "tgt_bin"], ["src", "sourceType"]]}
    ]
    node = producer(flatten_doc(doc))
    assert node.join[0]["on"] == [
        ["EmissionsAggregate.src_bin", "EmissionsAggregate.tgt_bin"],
        ["src", "sourceType"],
    ]


# --------------------------------------------------------------------------- #
# The variable_map consequence
# --------------------------------------------------------------------------- #


def test_variable_map_removal_renames_join_envelope_names():
    """A ``variable_map`` that REMOVES the mapped parameter must carry the join
    names with it, or the join points at a variable the flattened system no
    longer declares."""
    with open(FIXTURE) as fh:
        doc = copy.deepcopy(json.load(fh))
    doc["models"]["EDGE"] = {
        "variables": {"src_W": {"type": "parameter", "shape": ["pop_cells"]}},
        "equations": [],
    }
    doc["coupling"] = [
        {
            "type": "variable_map",
            "from": "EDGE.src_W",
            "to": "ISRM.W",
            "transform": "param_to_var",
        }
    ]
    flat = flatten_doc(doc)
    assert "ISRM.W" not in flat.parameters, "param_to_var removes the mapped parameter"

    overlap = producer(flat).join[0]["overlap"]
    assert overlap["tgt_env"][0] == "EDGE.src_W", (
        "the join must follow the variable_map, not the removed parameter"
    )
