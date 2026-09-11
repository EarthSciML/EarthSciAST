"""The `aggregate` -> `faq` deprecated-op-alias contract (esm 1.1.0).

Gates `tests/conformance/deprecated_op_alias/` and the `removed_op` rejection
of `arrayop`. See CONFORMANCE_SPEC §7 and
`docs/content/rfcs/faq-node-rename.md`.
"""

import json
import warnings

import pytest

from earthsci_ast import load_path
from earthsci_ast.errors import ParseError
from earthsci_ast.serialize import to_json

from conftest import CONFORMANCE_DIR, INVALID_DIR

CONF = CONFORMANCE_DIR / "deprecated_op_alias"


def _ops(node, out=None):
    """Every `op` string in a decoded document, depth-first."""
    out = [] if out is None else out
    if isinstance(node, dict):
        if isinstance(node.get("op"), str):
            out.append(node["op"])
        for v in node.values():
            _ops(v, out)
    elif isinstance(node, list):
        for v in node:
            _ops(v, out)
    return out


def test_the_alias_loads_and_warns_exactly_once_for_the_document():
    # Once per DOCUMENT, not once per node: the fixture carries two aliased
    # nodes and must still produce a single warning, naming the count.
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        load_path(str(CONF / "aliased.esm"))
    alias_warnings = [w for w in caught if "deprecated_op_alias" in str(w.message)]
    assert len(alias_warnings) == 1, [str(w.message) for w in caught]
    assert "2 nodes were normalized" in str(alias_warnings[0].message)


def test_the_alias_never_survives_the_loader():
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        f = load_path(str(CONF / "aliased.esm"))
    emitted = json.loads(to_json(f))
    ops = _ops(emitted)
    assert "aggregate" not in ops, "the deprecated alias reached emit"
    assert "faq" in ops


def test_emitting_the_alias_document_reproduces_the_canonical_one():
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        aliased = load_path(str(CONF / "aliased.esm"))
    canonical = load_path(str(CONF / "canonical.esm"))
    assert json.loads(to_json(aliased)) == json.loads(to_json(canonical))


def test_the_canonical_document_is_quiet():
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        load_path(str(CONF / "canonical.esm"))
    assert not [w for w in caught if "deprecated_op_alias" in str(w.message)]


def test_arrayop_is_rejected_by_name_not_left_to_the_open_tier():
    # `arrayop` matches the `op` pattern, so without a by-name rejection it
    # would load as an OPEN rewrite-target op (esm-spec §4.2) and fail only
    # much later as `unlowered_operator`.
    with pytest.raises(ParseError, match="removed_op"):
        load_path(str(INVALID_DIR / "faq" / "arrayop_op_removed.esm"))
