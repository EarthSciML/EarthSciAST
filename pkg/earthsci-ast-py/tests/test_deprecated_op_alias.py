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


# --- the wire boundary covers REFERENCED documents, not just the root ---------
#
# Every fixture above is a single self-contained document. That is exactly why
# five green binding suites missed the leak: the normalizer ran on the root's
# bytes and ref resolution then parsed child files raw, so a child's alias (and
# `arrayop`) reached `emit` untouched.


def test_the_alias_is_normalized_inside_a_referenced_child():
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        f = load_path(str(CONF / "ref_parent_aliased.esm"))
    emitted = json.loads(to_json(f))
    assert "aggregate" not in _ops(emitted), "the alias survived a {ref} into emit"
    assert [w for w in caught if "deprecated_op_alias" in str(w.message)]


def test_arrayop_in_a_referenced_child_is_rejected():
    with pytest.raises(ParseError, match="removed_op"):
        load_path(str(CONF / "ref_parent_arrayop.esm"))


# --- the esm 1.1.0 version gate ----------------------------------------------


def _at_version(tmp_path, src, version):
    doc = json.loads(open(src, encoding="utf-8").read())
    doc["esm"] = version
    out = tmp_path / "v.esm"
    out.write_text(json.dumps(doc), encoding="utf-8")
    return str(out)


def test_faq_below_v11_is_rejected(tmp_path):
    # `faq` arrives at 1.1.0, the same gate the top-level `solver` block uses.
    with pytest.raises(ParseError, match="faq_version_too_old"):
        load_path(_at_version(tmp_path, CONF / "canonical.esm", "1.0.0"))


def test_the_alias_below_v11_is_legal_and_raises_the_floor(tmp_path):
    # `aggregate` IS the pre-1.1.0 spelling, so the gate must NOT catch it. The
    # gate reads the AUTHORED form, before normalization; the document is then
    # normalized AND its declared version raised, so the upgrade is
    # self-consistent rather than spelling a 1.1.0 construct under 1.0.0.
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        f = load_path(_at_version(tmp_path, CONF / "aliased.esm", "1.0.0"))
    assert f.esm == "1.1.0"
