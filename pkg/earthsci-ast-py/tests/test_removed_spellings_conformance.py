"""The `removed_spellings` conformance tier (CONFORMANCE_SPEC §7, `removed_op`).

`aggregate`, the pre-1.1.0 alias of `faq`, is removed at esm 2.0.0 and `arrayop`
at 0.8.0: both are rejected BY NAME with `removed_op`, in the root and in a
`{ref}`-loaded child, never left to the open rewrite-target tier. `faq` itself
arrives at esm 1.1.0. Drives `tests/conformance/removed_spellings/manifest.json`.
See `docs/content/rfcs/faq-node-rename.md`.
"""

import json

import pytest

from earthsci_ast import load_path
from earthsci_ast.errors import ParseError
from earthsci_ast.serialize import to_json

from conftest import CONFORMANCE_DIR

TIER = CONFORMANCE_DIR / "removed_spellings"
MANIFEST = json.loads((TIER / "manifest.json").read_text()) if TIER.is_dir() else {"cases": []}
CASES = {c["id"]: c for c in MANIFEST["cases"]}
REJECTED = [c for c in MANIFEST["cases"] if "removed_op" in c["assert"]]


def test_the_tier_has_its_cases():
    assert set(CASES) == {
        "canonical_loads",
        "aggregate_rejected",
        "arrayop_rejected",
        "aggregate_in_referenced_child",
        "arrayop_in_referenced_child",
        "faq_requires_v11",
    }


def test_the_canonical_document_loads_and_reemits_itself():
    path = TIER / CASES["canonical_loads"]["input"]
    doc = json.loads(path.read_text())
    assert json.loads(to_json(load_path(str(path)))) == doc


@pytest.mark.parametrize("case", REJECTED, ids=[c["id"] for c in REJECTED])
def test_a_removed_spelling_is_removed_op(case):
    with pytest.raises(ParseError, match="removed_op") as excinfo:
        load_path(str(TIER / case["input"]))
    assert excinfo.value.code == "removed_op"
    assert "python -m earthsci_ast.migrate" in str(excinfo.value) or "0.8.0" in str(
        excinfo.value
    )


def test_faq_below_v11_is_faq_version_too_old(tmp_path):
    # Any document spelling `faq` while declaring esm < 1.1.0.
    doc = json.loads((TIER / CASES["canonical_loads"]["input"]).read_text())
    doc["esm"] = "1.0.0"
    out = tmp_path / "v.esm"
    out.write_text(json.dumps(doc), encoding="utf-8")
    with pytest.raises(ParseError, match="faq_version_too_old"):
        load_path(str(out))
