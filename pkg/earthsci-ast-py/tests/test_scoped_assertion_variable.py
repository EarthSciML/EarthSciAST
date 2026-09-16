"""An assertion's ``variable`` may be a SCOPED reference (issue #263).

The schema documents ``Assertion.variable`` as "the local name (e.g. ``"O3"``)
or a scoped reference relative to this component (e.g. ``"subsystem.X"``)", and
the same string already resolves as an equation operand. The runner looked the
name up in the asserting component's own ``variables`` only, so a ``coords`` or
``reduce`` assertion on a mounted leaf's field errored with
``variable 'Leaf.key' is not declared in model 'Host'``, and with two components
answering to ``Leaf`` a pointwise one read the wrong one.

The fixtures are shared with the Julia and Rust bindings
(``tests/conformance/scoped_assertion_variable/``), which pin the same rule.
"""

from __future__ import annotations

import math

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast.inline_tests import run_inline_tests
from earthsci_ast.parse import load_path

FIXTURES = FIXTURES_ROOT / "conformance" / "scoped_assertion_variable" / "fixtures"


def _run(name: str):
    return run_inline_tests(load_path(str(FIXTURES / name)), base_dir=str(FIXTURES))


def _actuals(results):
    for r in results:
        assert r.passed, f"{r.variable} (assertion {r.assertion_idx}): {r.message}"
    return [r.actual for r in results]


def test_the_leaf_alone_passes():
    results = _run("leaf.esm")
    assert [r.model for r in results] == ["Leaf", "Leaf"]
    _actuals(results)


@pytest.mark.parametrize("name", ["top_level_mount.esm", "nested_mount.esm"])
def test_a_mounted_leaf_is_assertable_by_scoped_name(name):
    """Both mount forms: a sibling top-level ``{ref}`` (document-absolute) and
    the asserting model's own ``subsystems`` mount (component-relative)."""
    results = _run(name)
    assert [r.model for r in results] == ["Host"] * 5
    assert [r.variable for r in results] == ["w", "Leaf.u", "Leaf.v", "Leaf.key", "Leaf.key"]
    e = math.exp(-1)
    assert _actuals(results) == pytest.approx([3 * e, e, 2 * e, 7.0, 9.0], rel=1e-4)


def test_a_subsystem_shadows_a_top_level_component_of_the_same_name():
    """The equation binder reads ``Leaf.u`` in ``Host`` as ``Host``'s own
    subsystem when it has one; an assertion must read the same component."""
    results = _run("shadowed_mount.esm")
    assert _actuals(results) == pytest.approx([6.0, 2.0, 1.0, 3.0], rel=1e-4)


def test_a_leaf_two_mounts_down_is_assertable_by_scoped_name():
    """THREE levels: the owner path runs two mounts below the root, which a
    runner that strips only one level of it cannot address."""
    results = _run("deep_mount.esm")
    assert [r.variable for r in results] == [
        "w",
        "Mid.Leaf.u",
        "Mid.Leaf.v",
        "Mid.Leaf.key",
        "Mid.Leaf.key",
    ]
    e = math.exp(-1)
    assert _actuals(results) == pytest.approx([3 * e, e, 2 * e, 7.0, 9.0], rel=1e-4)


def test_a_scoped_field_is_never_read_from_another_component():
    """Only the WRONG component's field is a build product, so a runner that
    answers a scoped name from the closest materialized field reports the
    top-level leaf's ``[7, 9, 4]`` where the subsystem owns ``[5, 10, 15]``."""
    results = _run("shadowed_dynamic_field.esm")
    assert _actuals(results) == pytest.approx([15.0, 15.0, 5.0], rel=1e-4)
