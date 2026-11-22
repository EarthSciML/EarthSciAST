"""Tests for esm-spec §9.7.10 — scope-directed template injection
(docs/content/rfcs/scoped-template-injection.md): the assembler- or test-chosen
discretization for a discretization-agnostic PDE leaf, via
``expression_template_imports`` on a §4.7 subsystem-ref edge (form A), a §10
coupling entry (form B), or a §6.6/§6.7 test/analysis (form C). Drives the shared
conformance fixtures under ``tests/conformance/expression_templates/``, mirroring
the Julia reference testset ``EarthSciAST.jl/test/scope_injection_test.jl``.
"""

from __future__ import annotations

import json
import os
import shutil
import warnings

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast.esm_types import Model
from earthsci_ast.inline_tests import _ephemeral_injected_file
from earthsci_ast.lower_expression_templates import ExpressionTemplateError
from earthsci_ast.parse import _absolutize_injected_imports, load_path
from earthsci_ast.serialize import _serialize_esm_file
from earthsci_ast.stdlib import std_ref_path

CONF = str(CONFORMANCE_DIR / "expression_templates")


def _conf(*parts: str) -> str:
    return os.path.join(CONF, *parts)


def _read_json(path: str) -> dict:
    with open(path) as fh:
        return json.load(fh)


def _err_code(fn) -> str | None:
    try:
        fn()
        return None
    except ExpressionTemplateError as e:
        return e.code


# ---------------------------------------------------------------------------
# Form A — subsystem-ref injection (§4.7 / §9.7.10)
# ---------------------------------------------------------------------------


def test_form_a_subsystem_ref_injection():
    f = load_path(_conf("inject_subsystem_ref", "fixture.esm"))
    # The mounted, agnostic leaf's D(c, wrt: lon) is lowered by the injected
    # rule at the mount; the subsystem resolves to a Model (not a ref).
    runoff = f.models["Assembly"].subsystems["Runoff"]
    assert isinstance(runoff, Model)
    assert runoff.equations[0].rhs.args[1].op == "makearray"
    # Injected library brought its grid into the importing registry.
    assert f.index_sets["lon"]["size"] == 288
    assert f.index_sets["lat"]["size"] == 181
    # Round-trip golden: the resolved+lowered assembly; the injection field is
    # gone (form A does not survive parse → emit).
    assert _serialize_esm_file(f) == _read_json(_conf("inject_subsystem_ref", "expanded.esm"))


@pytest.mark.parametrize("fname", ["subsystem_form.esm", "toplevel_form.esm"])
def test_form_a_injected_ref_resolves_against_the_mounting_directory(fname):
    # esm-spec §4.7 / §9.7.10: the edge's injected import ref is written by the
    # mounting document, so it resolves against THAT document's directory at
    # both mount forms. The leaf sits in leaves/, where the ref names nothing.
    f = load_path(_conf("inject_mounting_directory", fname))
    if fname == "subsystem_form.esm":
        runoff = f.models["Assembly"].subsystems["Runoff"]
    else:
        runoff = f.models["Runoff"]
    assert isinstance(runoff, Model)
    assert runoff.equations[0].rhs.args[1].op == "makearray"
    assert f.index_sets["lon"]["size"] == 288


def test_form_a_leaf_loads_standalone_with_d_intact():
    # The leaf loads standalone with its D intact (agnostic; unlowered).
    leaf = load_path(_conf("inject_subsystem_ref", "leaf.esm"))
    assert leaf.models["Advection"].equations[0].rhs.args[1].op == "partial"


def test_form_a_no_inject_negative_twin_loads_clean():
    # Mounting WITHOUT injection loads cleanly (the D survives — the op
    # namespace is open); the unlowered_operator gate is an evaluation-time
    # concern, not a load error.
    ni = load_path(_conf("inject_subsystem_ref", "no_inject.esm"))
    runoff = ni.models["Assembly"].subsystems["Runoff"]
    assert isinstance(runoff, Model)
    assert runoff.equations[0].rhs.args[1].op == "partial"


# ---------------------------------------------------------------------------
# Form B — coupling-entry injection (§10.8 / §9.7.10)
# ---------------------------------------------------------------------------


def test_form_b_coupling_entry_injection():
    f = load_path(_conf("inject_coupling_entry", "fixture.esm"))
    # Advection is discretized by name; its lon-derivative is lowered.
    assert f.models["Advection"].equations[0].rhs.args[1].op == "makearray"
    assert f.index_sets["lon"]["size"] == 288
    # Emit (the 0-D partner) named no key and stays untouched.
    assert f.models["Emit"].equations[0].lhs.op == "D"
    # The injection map is consumed — form B does not survive parse → emit.
    ser = _serialize_esm_file(f)
    assert "operator_imports" not in ser["coupling"][0]
    assert ser == _read_json(_conf("inject_coupling_entry", "expanded.esm"))


def test_form_b_diagnostics():
    assert (
        _err_code(lambda: load_path(_conf("inject_coupling_entry", "neg_target_unknown.esm")))
        == "operator_inject_target_unknown"
    )
    # From 1.0.0 a data source is not a component, so a key naming a
    # `data_sources` entry is reported by the general not-a-component code —
    # the separate `operator_inject_target_is_loader` diagnostic is retired.
    assert (
        _err_code(lambda: load_path(_conf("inject_coupling_entry", "neg_target_is_loader.esm")))
        == "operator_inject_target_not_component"
    )


# ---------------------------------------------------------------------------
# Form C — test/analysis injection (§6.6.6 / §9.7.10)
# ---------------------------------------------------------------------------


def test_form_c_round_trip_keeps_component_and_test_imports():
    f = load_path(_conf("inject_test_block", "fixture.esm"))
    adv = f.models["Advection"]
    # The enclosing component round-trips with its D INTACT (form C does not
    # lower it at load) and each test keeps its import field (survives emit).
    assert adv.equations[0].rhs.args[1].op == "partial"
    assert len(adv.tests) == 2
    assert all(t.expression_template_imports for t in adv.tests)
    assert _serialize_esm_file(f) == _read_json(_conf("inject_test_block", "roundtrip.esm"))


def test_form_c_ephemeral_builds_lower_independently():
    f = load_path(_conf("inject_test_block", "fixture.esm"))
    adv = f.models["Advection"]
    # One suite, many schemes: each test builds an INDEPENDENT ephemeral
    # instance with its own grid, with the D lowered in that build only — the
    # persisted component is never mutated.
    e1 = _ephemeral_injected_file(
        f,
        _conf("inject_test_block", "fixture.esm"),
        "Advection",
        adv.tests[0].expression_template_imports,
        _conf("inject_test_block"),
    )
    e2 = _ephemeral_injected_file(
        f,
        _conf("inject_test_block", "fixture.esm"),
        "Advection",
        adv.tests[1].expression_template_imports,
        _conf("inject_test_block"),
    )
    assert e1.models["Advection"].equations[0].rhs.args[1].op == "makearray"
    assert e2.models["Advection"].equations[0].rhs.args[1].op == "makearray"
    assert e1.index_sets["lon"]["size"] == 288
    assert e2.index_sets["lon"]["size"] == 144
    # The persisted file is untouched by the ephemeral builds.
    assert f.models["Advection"].equations[0].rhs.args[1].op == "partial"


def test_form_a_injected_import_ref_expands_env_var(tmp_path, monkeypatch):
    """esm-spec §4.7: a ``${VAR}`` in a form-A injected import expands, and it
    expands BEFORE the ref is anchored at the assembler's directory — so a
    variable holding an ABSOLUTE path is used as-is rather than joined onto it.
    """
    var = "ESM_PY_ENVREF_INJECTED_LIB_DIR"
    conf = _conf("inject_subsystem_ref")
    shutil.copy(os.path.join(conf, "leaf.esm"), tmp_path / "leaf.esm")
    fixture = open(os.path.join(conf, "fixture.esm")).read()
    doc = tmp_path / "fixture.esm"
    doc.write_text(
        fixture.replace(
            '"./central_D_lon_zero_grad_bc.esm"',
            f'"${{{var}}}/central_D_lon_zero_grad_bc.esm"',
        )
    )

    # Unset: the token stays literal, so the injected import fails to resolve.
    monkeypatch.delenv(var, raising=False)
    assert _err_code(lambda: load_path(str(doc))) == "operator_import_unresolved"

    # Negative control: the injected import is load-bearing.
    monkeypatch.setenv(var, str(tmp_path))
    assert _err_code(lambda: load_path(str(doc))) == "operator_import_unresolved"

    monkeypatch.setenv(var, conf)
    f = load_path(str(doc))
    assert f.index_sets["lon"]["size"] == 288


def test_form_a_injected_std_ref_is_not_anchored_at_the_mounting_directory():
    # esm-spec §4.7 "Standard-library references": an `esm:` ref is never a
    # relative path, so absolutizing the edge's injected imports maps it to
    # the bundled file instead of joining it onto the mounting directory.
    # Every other field of the entry is kept.
    entry = {"ref": "esm:std/calendar.esm", "only": ["hour"], "as": {"hour": "hr"}}
    (out,) = _absolutize_injected_imports([entry], "/nowhere/assembly")
    assert out == {**entry, "ref": std_ref_path("esm:std/calendar.esm")}
    assert os.path.isfile(out["ref"])
    assert entry["ref"] == "esm:std/calendar.esm"


def test_form_a_injected_std_ref_resolves_at_load(tmp_path):
    # End to end: a leaf in leaves/ calls `hour`, which only the mounting
    # edge's injected `esm:std/calendar.esm` import supplies.
    (tmp_path / "leaves").mkdir()
    leaf = {
        "esm": "2.0.0",
        "metadata": {"name": "clock_leaf"},
        "models": {
            "Clock": {
                "variables": {"h": {"type": "unknown", "units": "1"}},
                "equations": [
                    {
                        "lhs": "h",
                        "rhs": {
                            "op": "apply_operator",
                            "args": [],
                            "name": "hour",
                            "bindings": {"t": "t"},
                        },
                    }
                ],
            }
        },
    }
    (tmp_path / "leaves" / "leaf.esm").write_text(json.dumps(leaf))
    root = {
        "esm": "2.0.0",
        "metadata": {"name": "clock_assembly"},
        "models": {
            "Assembly": {
                "variables": {"h_reading": {"type": "unknown", "units": "1"}},
                "equations": [{"lhs": "h_reading", "rhs": "Clock.h"}],
                "subsystems": {
                    "Clock": {
                        "ref": "./leaves/leaf.esm",
                        "operator_imports": [{"ref": "esm:std/calendar.esm", "only": ["hour"]}],
                    }
                },
            }
        },
    }
    (tmp_path / "root.esm").write_text(json.dumps(root))
    f = load_path(str(tmp_path / "root.esm"))
    clock = f.models["Assembly"].subsystems["Clock"]
    assert isinstance(clock, Model)
    assert clock.equations[0].rhs.op != "apply_operator"


def test_form_c_injection_reads_the_component_old_spelling(tmp_path):
    """A component that wrote ``expression_template_imports`` (esm-spec
    §9.6.12) and a test that carries imports: the re-read source is read in the
    esm-2.4.0 spelling before the test's imports join it, so the component
    holds one import list, not both spellings."""
    conf = _conf("inject_test_block")
    for name in os.listdir(conf):
        shutil.copy(os.path.join(conf, name), tmp_path / name)
    (tmp_path / "trivial.esm").write_text(
        json.dumps(
            {
                "esm": "2.4.0",
                "metadata": {"name": "Trivial"},
                "operators": {"two_c": {"params": [], "body": 2.0}},
            }
        )
    )
    src = tmp_path / "fixture.esm"
    doc = _read_json(str(src))
    doc["models"]["Advection"]["expression_template_imports"] = [{"ref": "./trivial.esm"}]
    src.write_text(json.dumps(doc))
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        f = load_path(str(src))
        adv = f.models["Advection"]
        e = _ephemeral_injected_file(
            f, str(src), "Advection", adv.tests[0].expression_template_imports, str(tmp_path)
        )
    assert e.models["Advection"].equations[0].rhs.args[1].op == "makearray"
