"""Tests for esm-spec §9.7.10 — scope-directed template injection
(docs/content/rfcs/scoped-template-injection.md): the assembler- or test-chosen
discretization for a discretization-agnostic PDE leaf, via
``expression_template_imports`` on a §4.7 subsystem-ref edge (form A), a §10
coupling entry (form B), or a §6.6/§6.7 test/example (form C). Drives the shared
conformance fixtures under ``tests/conformance/expression_templates/``, mirroring
the Julia reference testset ``EarthSciAST.jl/test/scope_injection_test.jl``.
"""

from __future__ import annotations

import json
import os

from conftest import CONFORMANCE_DIR

from earthsci_ast.esm_types import Model
from earthsci_ast.lower_expression_templates import ExpressionTemplateError
from earthsci_ast.parse import load
from earthsci_ast.pde_inline_tests import _ephemeral_injected_file
from earthsci_ast.serialize import _serialize_esm_file

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
    f = load(_conf("inject_subsystem_ref", "fixture.esm"))
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


def test_form_a_leaf_loads_standalone_with_d_intact():
    # The leaf loads standalone with its D intact (agnostic; unlowered).
    leaf = load(_conf("inject_subsystem_ref", "leaf.esm"))
    assert leaf.models["Advection"].equations[0].rhs.args[1].op == "D"


def test_form_a_no_inject_negative_twin_loads_clean():
    # Mounting WITHOUT injection loads cleanly (the D survives — the op
    # namespace is open); the unlowered_operator gate is an evaluation-time
    # concern, not a load error.
    ni = load(_conf("inject_subsystem_ref", "no_inject.esm"))
    runoff = ni.models["Assembly"].subsystems["Runoff"]
    assert isinstance(runoff, Model)
    assert runoff.equations[0].rhs.args[1].op == "D"


# ---------------------------------------------------------------------------
# Form B — coupling-entry injection (§10.8 / §9.7.10)
# ---------------------------------------------------------------------------


def test_form_b_coupling_entry_injection():
    f = load(_conf("inject_coupling_entry", "fixture.esm"))
    # Advection is discretized by name; its lon-derivative is lowered.
    assert f.models["Advection"].equations[0].rhs.args[1].op == "makearray"
    assert f.index_sets["lon"]["size"] == 288
    # Emit (the 0-D partner) named no key and stays untouched.
    assert f.models["Emit"].equations[0].lhs.op == "D"
    # The injection map is consumed — form B does not survive parse → emit.
    ser = _serialize_esm_file(f)
    assert "expression_template_imports" not in ser["coupling"][0]
    assert ser == _read_json(_conf("inject_coupling_entry", "expanded.esm"))


def test_form_b_diagnostics():
    assert (
        _err_code(lambda: load(_conf("inject_coupling_entry", "neg_target_unknown.esm")))
        == "template_inject_target_unknown"
    )
    assert (
        _err_code(lambda: load(_conf("inject_coupling_entry", "neg_target_is_loader.esm")))
        == "template_inject_target_is_loader"
    )


# ---------------------------------------------------------------------------
# Form C — test/example injection (§6.6.6 / §9.7.10)
# ---------------------------------------------------------------------------


def test_form_c_round_trip_keeps_component_and_test_imports():
    f = load(_conf("inject_test_block", "fixture.esm"))
    adv = f.models["Advection"]
    # The enclosing component round-trips with its D INTACT (form C does not
    # lower it at load) and each test keeps its import field (survives emit).
    assert adv.equations[0].rhs.args[1].op == "D"
    assert len(adv.tests) == 2
    assert all(t.expression_template_imports for t in adv.tests)
    assert _serialize_esm_file(f) == _read_json(_conf("inject_test_block", "roundtrip.esm"))


def test_form_c_ephemeral_builds_lower_independently():
    f = load(_conf("inject_test_block", "fixture.esm"))
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
    assert f.models["Advection"].equations[0].rhs.args[1].op == "D"
