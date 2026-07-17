"""Conformance tests for the out-of-line-expression-templates RFC (Option B,
reference-preserving expression templates): esm-spec §9.6.4 (rules 1-8),
§9.6.7 (new fixtures), §9.6.9 (validation discharge), §10.7 (flatten registry
merge). Mirrors pkg/EarthSciAST.jl/test/out_of_line_templates_test.jl and drives
tests/conformance/expression_templates/{emit_*, eager_*, opacity_*,
per_instantiation_validation, flatten_registry_merge}.
"""

from __future__ import annotations

import json
import os

import pytest

from earthsci_ast import (
    ExpressionTemplateError,
    emit_document,
    emit_esm_string,
    expand_document,
    flatten_template_registries,
    lower_expression_templates,
)
from earthsci_ast.template_imports import resolve_template_machinery

from conftest import CONFORMANCE_DIR

CONF = CONFORMANCE_DIR / "expression_templates"


def _conf(*parts: str) -> str:
    return str(CONF.joinpath(*parts))


def _load(dir_: str, fixture: str = "fixture.esm"):
    """Load a fixture under Option B (references preserved), returning the raw
    loaded document view."""
    fp = _conf(dir_, fixture)
    raw = json.loads(open(fp, encoding="utf-8").read())
    resolved = resolve_template_machinery(raw, os.path.dirname(fp))
    return lower_expression_templates(raw if resolved is None else resolved)


def _emit(dir_: str, fixture: str = "fixture.esm") -> str:
    fp = _conf(dir_, fixture)
    return emit_esm_string(emit_document(json.loads(open(fp, encoding="utf-8").read()), os.path.dirname(fp)))


def _isapply(x) -> bool:
    return isinstance(x, dict) and x.get("op") == "apply_expression_template"


# ---------------------------------------------------------------------------
# BRIDGE GATE (esm-spec §9.6.7, RFC §12 gate 1): expand_document(load(fixture))
# is structurally equal to the existing expanded*.esm oracle. The 17 raw-pipeline
# goldens are NOT regenerated — they are the Option-A image Expand must reproduce.
# ---------------------------------------------------------------------------

_BRIDGE_CASES = [
    ("aggregate_int_ratio_golden", "fixture.esm", "expanded.esm"),
    ("arrhenius_smoke", "fixture.esm", "expanded.esm"),
    ("constrained_match_scope", "fixture.esm", "expanded.esm"),
    ("coupling_transform_expression", "fixture.esm", "expanded.esm"),
    ("fixpoint_nested_deriv", "fixture.esm", "expanded.esm"),
    ("godunov_beats_inner_deriv", "fixture.esm", "expanded.esm"),
    ("import_diamond", "fixture.esm", "expanded.esm"),
    ("import_order_determinism", "fixture_import_order.esm", "expanded_import_order.esm"),
    ("import_order_determinism", "fixture_priority_override.esm", "expanded_priority_override.esm"),
    ("import_rebind_keyed_factors", "fixture.esm", "expanded.esm"),
    ("import_rename_diamond", "fixture.esm", "expanded.esm"),
    ("import_rename_two_instances", "fixture.esm", "expanded.esm"),
    ("import_smoke", "fixture.esm", "expanded.esm"),
    ("import_where_rename_two_instances", "fixture.esm", "expanded.esm"),
    ("per_variable_scheme_literal_args", "fixture.esm", "expanded.esm"),
    ("scalar_field_param", "fixture.esm", "expanded.esm"),
    ("two_div_two_meshes", "fixture.esm", "expanded.esm"),
]


def _core(d: dict) -> dict:
    return {
        k: d[k]
        for k in ("models", "reaction_systems", "coupling", "index_sets")
        if k in d
    }


@pytest.mark.parametrize("dir_,fix,gold", _BRIDGE_CASES)
def test_bridge_expand_equals_expanded_oracle(dir_, fix, gold):
    got = _core(expand_document(_load(dir_, fix)))
    want = _core(json.loads(open(_conf(dir_, gold), encoding="utf-8").read()))
    assert got == want


# ---------------------------------------------------------------------------
# Expand determinism (§9.6.4 rule 2): two expansions of the same document
# produce structurally identical ASTs; the load view is non-destructive.
# ---------------------------------------------------------------------------
def test_expand_is_deterministic_and_load_is_nondestructive():
    loaded = _load("import_smoke")
    assert expand_document(loaded) == expand_document(loaded)
    # non-destructive: the loaded view still carries surviving references.
    mk = loaded["models"]["Advection"]["equations"][0]["rhs"]["args"][1]
    assert mk["op"] == "makearray"


# ---------------------------------------------------------------------------
# emit_materialized_registry (§9.6.4 rule 5, §9.6.7)
# ---------------------------------------------------------------------------
def test_emit_materialized_registry():
    s = _emit("emit_materialized_registry")
    assert s == open(_conf("emit_materialized_registry", "emitted.esm"), encoding="utf-8").read()
    doc = json.loads(s)
    adv = doc["models"]["Advection"]
    assert doc["esm"] == "0.9.0"  # rule 8 version stamp
    assert "expression_template_imports" not in adv  # imports consumed
    reg = adv["expression_templates"]
    assert set(reg.keys()) == {"central_D_lon_interior", "dlon_deg"}  # match-less only
    assert "central_D_lon_zero_grad_bc" not in reg  # match rule not materialized
    # Call site intact: the makearray interior region is a surviving ref.
    interior = adv["equations"][0]["rhs"]["args"][1]["values"][0]
    assert _isapply(interior) and interior["name"] == "central_D_lon_interior"
    # idempotency (§9.6.4 rule 5 / RFC gate 2)
    s2 = emit_esm_string(emit_document(json.loads(s), _conf("emit_materialized_registry")))
    assert s2 == s


# ---------------------------------------------------------------------------
# emit_rename_dotted_keys (§9.6.4 rule 5, §7.5.6 dotted keys)
# ---------------------------------------------------------------------------
def test_emit_rename_dotted_keys():
    s = _emit("emit_rename_dotted_keys")
    assert s == open(_conf("emit_rename_dotted_keys", "emitted.esm"), encoding="utf-8").read()
    doc = json.loads(s)
    reg = doc["models"]["TwoGrids"]["expression_templates"]
    assert set(reg.keys()) == {"fine.dx", "coarse.dx"}  # dotted keys
    assert set(doc["index_sets"].keys()) == {"fine.x", "coarse.x"}


# ---------------------------------------------------------------------------
# eager_target_bearing (§9.6.4 rule 3, §9.6.7): positive + negative.
# ---------------------------------------------------------------------------
def test_eager_target_bearing():
    loaded = _load("eager_target_bearing")
    vars_ = loaded["models"]["m"]["variables"]
    # POSITIVE: deriv_c (D-bearing) reference eagerly expanded, then the D
    # lowered by the `central` rule → an aggregate. No surviving ref.
    deager = vars_["d_eager"]["expression"]
    assert deager["op"] == "index"
    assert deager["args"][0]["op"] == "aggregate"
    # NEGATIVE: scale_c (target-free) reference SURVIVES.
    dsurv = vars_["d_survive"]["expression"]
    assert _isapply(dsurv["args"][0]) and dsurv["args"][0]["name"] == "scale_c"
    # Emit golden.
    assert _emit("eager_target_bearing") == open(
        _conf("eager_target_bearing", "emitted.esm"), encoding="utf-8"
    ).read()


# ---------------------------------------------------------------------------
# opacity_negative (§9.6.4 rule 4): the compound pattern MUST NOT fire across a
# surviving-reference boundary.
# ---------------------------------------------------------------------------
def test_opacity_negative():
    loaded = _load("opacity_negative")
    flux = loaded["models"]["m"]["variables"]["flux"]["expression"]
    assert flux["op"] == "D"  # compound did NOT fire (no marker 999)
    assert _isapply(flux["args"][0])  # its arg is the surviving reference
    assert flux["args"][0]["name"] == "flux_prod"
    assert _emit("opacity_negative") == open(
        _conf("opacity_negative", "emitted.esm"), encoding="utf-8"
    ).read()


# ---------------------------------------------------------------------------
# opacity_priority_shadowing (§9.6.4 rule 4): the silent divergence — the
# high-priority compound rule does NOT fire; a lower-priority generic rule DOES,
# binding the surviving reference whole.
# ---------------------------------------------------------------------------
def test_opacity_priority_shadowing():
    loaded = _load("opacity_priority_shadowing")
    flux = loaded["models"]["m"]["variables"]["flux"]["expression"]
    assert flux["op"] == "*"
    assert flux["args"][0] == 1  # generic marker (NOT compound 999)
    assert _isapply(flux["args"][1])  # reference bound WHOLE by metavariable f
    assert flux["args"][1]["name"] == "flux_prod"
    assert _emit("opacity_priority_shadowing") == open(
        _conf("opacity_priority_shadowing", "emitted.esm"), encoding="utf-8"
    ).read()


# ---------------------------------------------------------------------------
# per_instantiation_validation (§9.6.9): manifold param, two call sites, one
# inadmissible → geometry_manifold_invalid naming the call site.
# ---------------------------------------------------------------------------
def test_per_instantiation_validation():
    with pytest.raises(ExpressionTemplateError) as ei:
        _load("per_instantiation_validation")
    assert ei.value.code == "geometry_manifold_invalid"
    assert "area_bad" in str(ei.value)  # offending call site named
    assert "overlap" in str(ei.value)  # template name named


# ---------------------------------------------------------------------------
# flatten_registry_merge (§9.6.4 rule 7, §10.7): dedup + owner-path rename.
# ---------------------------------------------------------------------------
def test_flatten_registry_merge():
    loaded = _load("flatten_registry_merge")
    root, merged = flatten_template_registries(loaded)
    assert set(merged.keys()) == {"sten", "A.s", "B.s"}  # dedup + rename
    assert merged["sten"]["body"] == {"op": "*", "args": [2, "f"]}
    # references rewritten in lockstep
    assert root["models"]["A"]["variables"]["za"]["expression"]["name"] == "A.s"
    assert root["models"]["B"]["variables"]["zb"]["expression"]["name"] == "B.s"
    assert root["models"]["A"]["variables"]["ya"]["expression"]["name"] == "sten"
    assert root["models"]["B"]["variables"]["yb"]["expression"]["name"] == "sten"
    # per-component blocks surrendered to the merged registry
    assert "expression_templates" not in root["models"]["A"]
    assert "expression_templates" not in root["models"]["B"]


# ---------------------------------------------------------------------------
# Idempotency property over every new emit fixture (RFC §12 gate 2).
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "dir_",
    [
        "emit_materialized_registry",
        "emit_rename_dotted_keys",
        "eager_target_bearing",
        "opacity_negative",
        "opacity_priority_shadowing",
    ],
)
def test_emit_load_byte_wise_fixed_point(dir_):
    s1 = _emit(dir_)
    s2 = emit_esm_string(emit_document(json.loads(s1), _conf(dir_)))
    assert s1 == s2
