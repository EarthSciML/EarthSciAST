"""Tests for esm-spec §9.7 — template-library files,
``expression_template_imports``, and load-time ``metaparameters``
(docs/content/rfcs/template-library-imports.md; esm-libraries-spec §2.1c).

Drives the shared conformance fixtures under
``tests/conformance/expression_templates/`` and the resolver-level invalid
fixtures under ``tests/invalid/template_imports/``, mirroring the Julia
reference testset ``EarthSciSerialization.jl/test/template_imports_test.jl``.
"""
from __future__ import annotations

import copy
import json
import os

import pytest

from earthsci_toolkit.lower_expression_templates import (
    ExpressionTemplateError,
    lower_expression_templates,
)
from earthsci_toolkit.parse import SchemaValidationError, load
from earthsci_toolkit.serialize import _serialize_esm_file, save
from earthsci_toolkit.template_imports import (
    MAX_TEMPLATE_EXPANSION_DEPTH,
    reject_template_imports_pre_v08,
    resolve_template_machinery,
)

# tests/test_template_imports.py → packages/earthsci_toolkit/tests →
# packages/earthsci_toolkit → packages → repo root.
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
CONF = os.path.join(REPO_ROOT, "tests", "conformance", "expression_templates")
INVALID_DIR = os.path.join(REPO_ROOT, "tests", "invalid", "template_imports")
VALID_DIR = os.path.join(REPO_ROOT, "tests", "valid")


def _read_json(path: str) -> dict:
    with open(path) as fh:
        return json.load(fh)


def _expand_raw(path: str) -> dict:
    """The raw §9.7 pipeline (resolve → lower), mirroring the Julia golden
    generator ``scripts/generate-template-import-goldens.jl``."""
    raw = _read_json(path)
    resolved = resolve_template_machinery(raw, os.path.dirname(path))
    return lower_expression_templates(resolved if resolved is not None else raw)


def _err_code(fn) -> str | None:
    try:
        fn()
        return None
    except ExpressionTemplateError as e:
        return e.code


# ---------------------------------------------------------------------------
# Conformance fixture groups vs the committed Julia goldens
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "group,fixture,golden",
    [
        ("import_smoke", "fixture.esm", "expanded.esm"),
        ("import_diamond", "fixture.esm", "expanded.esm"),
        ("import_order_determinism", "fixture_import_order.esm",
         "expanded_import_order.esm"),
        ("import_order_determinism", "fixture_priority_override.esm",
         "expanded_priority_override.esm"),
    ],
)
def test_import_conformance_matches_golden(group, fixture, golden):
    """The raw pipeline (resolve → lower) must match the Julia-generated
    golden structurally, for the whole document."""
    got = _expand_raw(os.path.join(CONF, group, fixture))
    want = _read_json(os.path.join(CONF, group, golden))
    assert got == want


def test_import_smoke_typed_load():
    """§9.7.7 four-file layering: index sets merged and folded at the edge
    bindings; D(c, wrt: lon) lowered to the makearray rule body."""
    f = load(os.path.join(CONF, "import_smoke", "fixture.esm"))
    assert f.index_sets["lon"]["size"] == 288
    assert f.index_sets["lat"]["size"] == 181
    eq = f.models["Advection"].equations[0]
    assert eq.lhs.op == "D"
    assert eq.rhs.args[1].op == "makearray"


def test_import_diamond_dedups_at_first_occurrence():
    f = load(os.path.join(CONF, "import_diamond", "fixture.esm"))
    assert f.index_sets["cells"]["size"] == 10  # NC default, deduped once


def test_effective_order_pins_tie_break_and_priority_flips_it():
    """Winner sanity, independent of the goldens: earlier import wins the
    equal-priority tie (2*x); explicit priority 10 out-ranks it (5*x)."""
    d1 = _expand_raw(os.path.join(CONF, "import_order_determinism",
                                  "fixture_import_order.esm"))
    assert d1["models"]["M"]["variables"]["y"]["expression"]["args"][0] == 2
    d2 = _expand_raw(os.path.join(CONF, "import_order_determinism",
                                  "fixture_priority_override.esm"))
    assert d2["models"]["M"]["variables"]["y"]["expression"]["args"][0] == 5


# ---------------------------------------------------------------------------
# Valid suite: library file + minimal consumer
# ---------------------------------------------------------------------------


def test_valid_suite_library_file_loads_clean():
    """A model-less template-library document loads (esm-spec §9.7.1);
    round-trip strips every §9.7 construct, leaving the folded registry."""
    lib = load(os.path.join(VALID_DIR, "template_import_lib.esm"))
    assert not lib.models
    assert lib.index_sets["cells"]["size"] == 8  # size "N" folded by default
    # Loader-API binding overrides the default on the library itself.
    lib12 = load(os.path.join(VALID_DIR, "template_import_lib.esm"),
                 metaparameters={"N": 12})
    assert lib12.index_sets["cells"]["size"] == 12


def test_valid_suite_minimal_consumer():
    m = load(os.path.join(VALID_DIR, "template_import_minimal.esm"))
    assert m.index_sets["cells"]["size"] == 8  # §9.7.5 merge into consumer
    y = m.models["M"].variables["y"].expression
    assert y.op == "*"
    assert y.args == ["x", 8]


# ---------------------------------------------------------------------------
# metaparameter_resolutions: subsystem-ref bindings (§9.7.6 site 3)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "wrapper,golden,n",
    [("wrapper_n4.esm", "expanded_n4.esm", 4),
     ("wrapper_n8.esm", "expanded_n8.esm", 8)],
)
def test_metaparameter_resolutions_subsystem_bindings(wrapper, golden, n):
    f = load(os.path.join(CONF, "metaparameter_resolutions", wrapper))
    sub = f.models["Sweep"].subsystems["Problem"]
    # Expression position: bare "N" substituted as an integer literal.
    assert sub.variables["npts"].expression == n
    # Expression-position division stays an AST division (no folding).
    half = sub.variables["half"].expression
    assert half.op == "/"
    assert half.args == [n, 2]
    # Structural site: the aggregate dense range folded exactly.
    ramp = sub.variables["ramp"].expression
    assert ramp.op == "aggregate"
    assert ramp.ranges == {"i": [1, n // 2]}
    # Typed round-trip matches the golden, fully structurally.
    got = _serialize_esm_file(f)
    want = _read_json(os.path.join(CONF, "metaparameter_resolutions", golden))
    assert got == want


def test_loader_api_bindings_and_defaults():
    """§9.7.6 binding sites 4 (loader API) and 5 (defaults, last)."""
    problem = os.path.join(CONF, "metaparameter_resolutions", "problem.esm")
    fdef = load(problem)
    assert fdef.models["Problem"].variables["npts"].expression == 2  # default
    fapi = load(problem, metaparameters={"N": 6})
    assert fapi.models["Problem"].variables["npts"].expression == 6  # API > default
    assert fapi.models["Problem"].variables["ramp"].expression.ranges == {"i": [1, 3]}
    # Binding a name the document does not declare is an error.
    assert _err_code(lambda: load(problem, metaparameters={"Q": 1})) == \
        "template_import_unknown_name"


def test_round_trip_emits_expanded_folded_form():
    """§9.7.6: no §9.7 construct survives parse → emit."""
    f = load(os.path.join(CONF, "import_smoke", "fixture.esm"))
    text = save(f)
    assert "expression_template_imports" not in text
    assert "metaparameters" not in text
    assert "expression_templates" not in text
    assert "apply_expression_template" not in text
    reloaded = load(text)
    assert reloaded.index_sets["lon"]["size"] == 288
    assert reloaded.models["Advection"].equations[0].rhs.args[1].op == "makearray"


# ---------------------------------------------------------------------------
# Invalid fixtures: every §9.7 diagnostic code, machine-checked
# ---------------------------------------------------------------------------


def _invalid_fixture_names():
    return sorted(f for f in os.listdir(INVALID_DIR) if f.endswith(".esm"))


@pytest.mark.parametrize("fname", _invalid_fixture_names())
def test_invalid_template_import_fixture(fname):
    expected = _read_json(os.path.join(REPO_ROOT, "tests", "invalid",
                                       "expected_errors.json"))
    entry = expected[fname]
    assert entry["resolver_only"] is True
    want = entry["resolver_error_code"]
    with pytest.raises(ExpressionTemplateError) as excinfo:
        load(os.path.join(INVALID_DIR, fname))
    assert excinfo.value.code == want


def test_invalid_fixture_set_covers_all_12_codes():
    """The fixture set exercises the full §9.6.6 §9.7 code table (the 12th,
    template_import_unresolved, is exercised by the unit tests below — a
    missing file is not representable as a fixture)."""
    expected = _read_json(os.path.join(REPO_ROOT, "tests", "invalid",
                                       "expected_errors.json"))
    seen = {expected[f]["resolver_error_code"] for f in _invalid_fixture_names()}
    for code in [
        "template_import_version_too_old", "template_import_not_library",
        "subsystem_ref_is_template_library", "template_import_cycle",
        "template_import_name_conflict", "template_import_unknown_name",
        "template_import_index_set_conflict",
        "apply_expression_template_recursive_body",
        "template_body_expansion_too_deep", "metaparameter_unbound",
        "metaparameter_type_error", "metaparameter_name_conflict",
    ]:
        assert code in seen


# ---------------------------------------------------------------------------
# Unit-level behavior over generated files
# ---------------------------------------------------------------------------


def _model_json(extra_model_fields: str = "", top_fields: str = "") -> str:
    return f"""
    {{
      "esm": "0.8.0",
      "metadata": {{"name": "t"}},{top_fields}
      "models": {{
        "M": {{{extra_model_fields}
          "variables": {{"x": {{"type": "state", "units": "1", "default": 0.5}}}},
          "equations": [{{"lhs": {{"op": "D", "args": ["x"], "wrt": "t"}},
                         "rhs": {{"op": "-", "args": ["x"]}}}}]
        }}
      }}
    }}
    """


def test_template_import_unresolved_missing_and_unparsable_ref(tmp_path):
    p = tmp_path / "m.esm"
    p.write_text(_model_json(
        '\n"expression_template_imports": [{"ref": "./nope.esm"}],'))
    assert _err_code(lambda: load(str(p))) == "template_import_unresolved"
    (tmp_path / "junk.esm").write_text("{not json")
    p.write_text(_model_json(
        '\n"expression_template_imports": [{"ref": "./junk.esm"}],'))
    assert _err_code(lambda: load(str(p))) == "template_import_unresolved"


def test_only_filters_visibility_not_internal_wiring(tmp_path):
    (tmp_path / "lib.esm").write_text(json.dumps({
        "esm": "0.8.0",
        "metadata": {"name": "lib"},
        "expression_templates": {
            "t_inner": {"params": [], "body": 7},
            "t_keep": {"params": [], "body": {"op": "*", "args": [2,
                {"op": "apply_expression_template", "args": [],
                 "name": "t_inner", "bindings": {}}]}},
            "t_drop": {"params": [], "body": 9},
        },
    }))
    # t_keep's body reference to t_inner resolved in the LIBRARY's own scope,
    # so importing only t_keep still yields 2 * 7.
    p = tmp_path / "m.esm"
    p.write_text(_model_json(
        '\n"expression_template_imports": [{"ref": "./lib.esm", "only": ["t_keep"]}],'))
    raw = json.loads(p.read_text())
    resolved = resolve_template_machinery(raw, str(tmp_path))
    tpl = resolved["models"]["M"]["expression_templates"]
    assert list(tpl.keys()) == ["t_keep"]
    assert tpl["t_keep"]["body"] == {"op": "*", "args": [2, 7]}
    # Referencing a filtered-out name from an expression position fails.
    p2 = tmp_path / "m2.esm"
    p2.write_text(_model_json(
        '\n"expression_template_imports": [{"ref": "./lib.esm", "only": ["t_keep"]}],\n'
        '"expression_templates": {"local_uses_drop": {"params": [],\n'
        '  "body": {"op": "apply_expression_template", "args": [], '
        '"name": "t_drop", "bindings": {}}}},'))
    assert _err_code(lambda: load(str(p2))) == \
        "apply_expression_template_unknown_template"


def test_diamond_with_conflicting_edge_bindings_rejected(tmp_path):
    (tmp_path / "grid.esm").write_text(json.dumps({
        "esm": "0.8.0", "metadata": {"name": "grid"},
        "metaparameters": {"NC": {"type": "integer"}},
        "index_sets": {"cells": {"kind": "interval", "size": "NC"}},
        "expression_templates": {"nc": {"params": [], "body": "NC"}},
    }))
    p = tmp_path / "m.esm"
    p.write_text(_model_json(
        '\n"expression_template_imports": ['
        '{"ref": "./grid.esm", "bindings": {"NC": 4}},'
        '{"ref": "./grid.esm", "bindings": {"NC": 8}}],'))
    assert _err_code(lambda: load(str(p))) in (
        "template_import_name_conflict", "template_import_index_set_conflict")
    # Equal instantiation on both edges dedups cleanly.
    p.write_text(_model_json(
        '\n"expression_template_imports": ['
        '{"ref": "./grid.esm", "bindings": {"NC": 4}},'
        '{"ref": "./grid.esm", "bindings": {"NC": 4}}],'))
    f = load(str(p))
    assert f.index_sets["cells"]["size"] == 4


def test_edge_bindings_unknown_names_and_non_integers(tmp_path):
    (tmp_path / "lib.esm").write_text(json.dumps({
        "esm": "0.8.0", "metadata": {"name": "lib"},
        "metaparameters": {"N": {"type": "integer", "default": 8}},
        "expression_templates": {"n": {"params": [], "body": "N"}},
    }))
    p = tmp_path / "m.esm"
    p.write_text(_model_json(
        '\n"expression_template_imports": [{"ref": "./lib.esm", "bindings": {"Q": 1}}],'))
    assert _err_code(lambda: load(str(p))) == "template_import_unknown_name"
    # A non-integer binding is schema-invalid (TemplateImport.bindings is
    # integer-typed), so `load` rejects at schema validation; the
    # resolver-level backstop still reports metaparameter_type_error.
    p.write_text(_model_json(
        '\n"expression_template_imports": [{"ref": "./lib.esm", "bindings": {"N": 2.5}}],'))
    with pytest.raises(SchemaValidationError):
        load(str(p))
    raw = json.loads(p.read_text())
    assert _err_code(lambda: resolve_template_machinery(raw, str(tmp_path))) == \
        "metaparameter_type_error"


def test_metaparameter_fold_ranges_regions_size_exact(tmp_path):
    p = tmp_path / "m.esm"
    p.write_text(json.dumps({
        "esm": "0.8.0",
        "metadata": {"name": "fold"},
        "metaparameters": {"N": {"type": "integer", "default": 6}},
        "index_sets": {"cells": {"kind": "interval",
                                 "size": {"op": "*", "args": ["N", 2]}}},
        "models": {
            "M": {
                "variables": {
                    "x": {"type": "state", "units": "1", "default": 0.5},
                    "agg": {"type": "observed", "units": "1",
                            "expression": {"op": "aggregate",
                                           "output_idx": ["i"], "args": ["x"],
                                           "ranges": {"i": [1, {"op": "-", "args": ["N", 1]}]},
                                           "expr": {"op": "*", "args": ["x", "i"]}}},
                    "ma": {"type": "observed", "units": "1",
                           "expression": {"op": "makearray", "args": [],
                                          "regions": [[[{"op": "/", "args": ["N", 2]}, "N"]]],
                                          "values": [1.5]}},
                },
                "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                               "rhs": {"op": "-", "args": ["x"]}}],
            }
        },
    }))
    f = load(str(p))
    assert f.index_sets["cells"]["size"] == 12
    m = f.models["M"]
    assert m.variables["agg"].expression.ranges == {"i": [1, 5]}
    assert m.variables["ma"].expression.regions == [[[3, 6]]]


def test_expression_position_substitution_never_folds(tmp_path):
    p = tmp_path / "m.esm"
    p.write_text(json.dumps({
        "esm": "0.8.0",
        "metadata": {"name": "subst"},
        "metaparameters": {"N": {"type": "integer", "default": 144}},
        "models": {
            "M": {
                "variables": {
                    "x": {"type": "state", "units": "1", "default": 0.5},
                    "dlon": {"type": "observed", "units": "1",
                             "expression": {"op": "/", "args": [360, "N"]}},
                },
                "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                               "rhs": {"op": "-", "args": ["x"]}}],
            }
        },
    }))
    f = load(str(p))
    dlon = f.models["M"].variables["dlon"].expression
    assert dlon.op == "/"
    assert dlon.args == [360, 144]


def _chain_doc(n: int) -> dict:
    """An n-template body-reference chain c_01 -> ... -> c_<n>."""
    tpl = {}
    for i in range(1, n + 1):
        name = f"c_{i:02d}"
        if i == n:
            tpl[name] = {"params": [], "body": 1}
        else:
            tpl[name] = {"params": [],
                         "body": {"op": "apply_expression_template",
                                  "args": [], "name": f"c_{i + 1:02d}",
                                  "bindings": {}}}
    return {
        "esm": "0.8.0", "metadata": {"name": "chain"},
        "models": {"M": {
            "expression_templates": tpl,
            "variables": {"x": {"type": "state", "default": 0.5}},
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                           "rhs": {"op": "-", "args": ["x"]}}],
        }},
    }


def test_body_composition_inlines_acyclic_dag_and_depth_bound_is_exact():
    # A 3-deep local chain inlines through the §9.6.3 fixpoint untouched.
    doc = {
        "esm": "0.8.0",
        "metadata": {"name": "chain3"},
        "models": {
            "M": {
                "expression_templates": {
                    "c1": {"params": [], "body": {"op": "+", "args": [1,
                        {"op": "apply_expression_template", "args": [],
                         "name": "c2", "bindings": {}}]}},
                    "c2": {"params": [], "body": {"op": "+", "args": [2,
                        {"op": "apply_expression_template", "args": [],
                         "name": "c3", "bindings": {}}]}},
                    "c3": {"params": [], "body": 3},
                },
                "variables": {"x": {"type": "state", "units": "1", "default": 0.5},
                              "y": {"type": "observed", "units": "1",
                                    "expression": {"op": "apply_expression_template",
                                                   "args": [], "name": "c1",
                                                   "bindings": {}}}},
                "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                               "rhs": {"op": "-", "args": ["x"]}}],
            }
        },
    }
    out = lower_expression_templates(copy.deepcopy(doc))
    assert out["models"]["M"]["variables"]["y"]["expression"] == \
        {"op": "+", "args": [1, {"op": "+", "args": [2, 3]}]}

    # Exactly MAX_TEMPLATE_EXPANSION_DEPTH templates chain: accepted; one
    # more: template_body_expansion_too_deep. The depth counts TEMPLATES on
    # the longest chain — a 33-template chain is rejected, 32 accepted (the
    # shared generated fixture pins the reject side; this pins the boundary).
    assert lower_expression_templates(
        _chain_doc(MAX_TEMPLATE_EXPANSION_DEPTH)) is not None
    assert _err_code(lambda: lower_expression_templates(
        _chain_doc(MAX_TEMPLATE_EXPANSION_DEPTH + 1))) == \
        "template_body_expansion_too_deep"


def test_cross_file_chains_do_not_accumulate_depth(tmp_path):
    """The 32-template depth bound applies per composition scope: an imported
    library's bodies arrive already CLOSED (composed in the library's own
    scope, §9.7.3), so they count as depth-1 leaves in the importer — a
    32-deep chain in a library plus a consumer template referencing its head
    is legal, not a 33-deep chain."""
    lib = _chain_doc(MAX_TEMPLATE_EXPANSION_DEPTH)
    lib_doc = {
        "esm": "0.8.0", "metadata": {"name": "chainlib"},
        "expression_templates": lib["models"]["M"]["expression_templates"],
    }
    (tmp_path / "chainlib.esm").write_text(json.dumps(lib_doc))
    consumer = tmp_path / "m.esm"
    consumer.write_text(_model_json(
        '\n"expression_template_imports": [{"ref": "./chainlib.esm"}],\n'
        '"expression_templates": {"uses_head": {"params": [],\n'
        '  "body": {"op": "apply_expression_template", "args": [], '
        '"name": "c_01", "bindings": {}}}},'))
    f = load(str(consumer))  # must not raise template_body_expansion_too_deep
    assert "M" in f.models


def test_effective_order_beats_sorted_name_order(tmp_path):
    """§9.7.4: the effective declaration order is imports (array order) then
    locals — NOT sorted template names. The first import's rule name sorts
    AFTER the second's, so a name-sorted tie-break would pick the wrong
    winner; the effective sequence must pin z_rule (2*x)."""
    (tmp_path / "lib_first.esm").write_text(json.dumps({
        "esm": "0.8.0", "metadata": {"name": "lib_first"},
        "expression_templates": {
            "z_rule": {"params": ["f"], "match": {"op": "lowerme", "args": ["f"]},
                       "body": {"op": "*", "args": [2, "f"]}}},
    }))
    (tmp_path / "lib_second.esm").write_text(json.dumps({
        "esm": "0.8.0", "metadata": {"name": "lib_second"},
        "expression_templates": {
            "a_rule": {"params": ["f"], "match": {"op": "lowerme", "args": ["f"]},
                       "body": {"op": "*", "args": [3, "f"]}}},
    }))
    p = tmp_path / "m.esm"
    p.write_text(json.dumps({
        "esm": "0.8.0", "metadata": {"name": "order"},
        "models": {"M": {
            "expression_template_imports": [
                {"ref": "./lib_first.esm"}, {"ref": "./lib_second.esm"}],
            "variables": {"x": {"type": "state", "units": "1", "default": 1.5},
                          "y": {"type": "observed", "units": "1",
                                "expression": {"op": "lowerme", "args": ["x"]}}},
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                           "rhs": {"op": "-", "args": ["x"]}}],
        }},
    }))
    f = load(str(p))
    y = f.models["M"].variables["y"].expression
    assert y.op == "*"
    assert y.args == [2, "x"]  # the FIRST import's rule wins the tie


def test_body_may_not_reference_match_rule():
    doc = json.loads(_model_json(
        '\n"expression_templates": {'
        '"rule": {"params": ["f"], "match": {"op": "lowerme", "args": ["f"]},'
        ' "body": {"op": "*", "args": [2, "f"]}},'
        '"uses_rule": {"params": [], "body": {"op": "apply_expression_template",'
        ' "args": [], "name": "rule", "bindings": {"f": 1}}}},'))
    assert _err_code(lambda: lower_expression_templates(doc)) == \
        "apply_expression_template_unknown_template"


def test_match_pattern_may_not_contain_apply_node():
    """esm-spec §9.7.3: match patterns MUST NOT reference templates — the
    match-with-apply rejection is now apply_expression_template_invalid_declaration."""
    doc = json.loads(_model_json(
        '\n"expression_templates": {'
        '"frag": {"params": [], "body": 1},'
        '"rule": {"params": ["f"],'
        ' "match": {"op": "lowerme", "args": [{"op": "apply_expression_template",'
        ' "args": [], "name": "frag", "bindings": {}}]},'
        ' "body": {"op": "*", "args": [2, "f"]}}},'))
    assert _err_code(lambda: lower_expression_templates(doc)) == \
        "apply_expression_template_invalid_declaration"


def test_version_gate_flags_every_v097_construct():
    for snippet in [
        '"metaparameters": {"N": {"type": "integer"}},',
        '"expression_templates": {"t": {"params": [], "body": 1}},',
    ]:
        doc = json.loads(f"""
        {{"esm": "0.7.0", "metadata": {{"name": "old"}},{snippet}
         "models": {{"M": {{"variables": {{"x": {{"type": "state", "default": 0.5}}}},
                          "equations": []}}}}}}""")
        assert _err_code(lambda: reject_template_imports_pre_v08(doc)) == \
            "template_import_version_too_old"
    # 0.8.0 files pass the gate.
    ok = json.loads("""
    {"esm": "0.8.0", "metadata": {"name": "new"},
     "metaparameters": {"N": {"type": "integer", "default": 1}},
     "expression_templates": {"t": {"params": [], "body": 1}}}""")
    assert reject_template_imports_pre_v08(ok) is None


def test_zero_parameter_templates_are_legal():
    """esm-spec §9.6.1 (0.8.0): params MAY be empty — a zero-parameter
    template is a named constant fragment."""
    doc = json.loads(_model_json(
        '\n"expression_templates": {"two": {"params": [], "body": 2}},'
        '"initialization_equations": [],'))
    doc["models"]["M"]["variables"]["y"] = {
        "type": "observed", "units": "1",
        "expression": {"op": "apply_expression_template", "args": [],
                       "name": "two", "bindings": {}},
    }
    out = lower_expression_templates(doc)
    assert out["models"]["M"]["variables"]["y"]["expression"] == 2
