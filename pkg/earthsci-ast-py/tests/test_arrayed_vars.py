"""Tests for arrayed-variable shape/location fields (discretization RFC §10.2)."""

from __future__ import annotations

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast import load_path, load_string, to_json

FIXTURES = FIXTURES_ROOT / "fixtures" / "arrayed_vars"


def _load(name: str):
    return load_path(FIXTURES / name)


def _roundtrip(name: str):
    first = _load(name)
    reserialized = to_json(first)
    second = load_string(reserialized)
    return first, second


def test_scalar_no_shape_regression():
    """Pre-0.2 scalar variables (no shape/location) must still parse."""
    esm = _load("scalar_no_shape.esm")
    v = esm.models["Scalar0D"].variables["x"]
    assert v.shape is None
    assert v.location is None


def test_scalar_explicit_empty_shape():
    """Explicit empty-list shape parses as zero dimensions."""
    first, second = _roundtrip("scalar_explicit.esm")
    for esm in (first, second):
        v = esm.models["ScalarExplicit"].variables["mass"]
        # Empty list and None are both valid "scalar" forms; we just
        # require zero dimensions after parse.
        assert not v.shape, f"expected zero-dim shape, got {v.shape!r}"
        assert v.location is None


def test_one_d_cell_center():
    first, second = _roundtrip("one_d.esm")
    for esm in (first, second):
        c = esm.models["Diffusion1D"].variables["c"]
        assert c.shape == ["x"]
        assert c.location == "cell_center"
        d = esm.models["Diffusion1D"].variables["D"]
        assert d.shape is None
        assert d.location is None


def test_two_d_staggered_faces():
    first, second = _roundtrip("two_d_faces.esm")
    for esm in (first, second):
        p = esm.models["StaggeredFlow2D"].variables["p"]
        u = esm.models["StaggeredFlow2D"].variables["u"]
        assert p.shape == ["x", "y"]
        assert p.location == "cell_center"
        assert u.shape == ["x", "y"]
        assert u.location == "x_face"


def test_vertex_located_roundtrip():
    first, second = _roundtrip("vertex_located.esm")
    for esm in (first, second):
        phi = esm.models["VertexScalar2D"].variables["phi"]
        assert phi.shape == ["x", "y"]
        assert phi.location == "vertex"


@pytest.mark.parametrize(
    "fixture",
    [
        "scalar_no_shape.esm",
        "scalar_explicit.esm",
        "one_d.esm",
        "two_d_faces.esm",
        "vertex_located.esm",
    ],
)
def test_roundtrip_preserves_shape_and_location(fixture: str):
    """shape and location values are stable under parse -> serialize -> parse."""
    first, second = _roundtrip(fixture)
    model_names = list(first.models.keys())
    assert model_names == list(second.models.keys())
    for mname in model_names:
        orig = first.models[mname].variables
        rt = second.models[mname].variables
        assert set(orig.keys()) == set(rt.keys())
        for name, v in orig.items():
            assert bool(v.shape) == bool(rt[name].shape), (
                f"{mname}.{name}: shape truthiness changed"
            )
            if v.shape:
                assert v.shape == rt[name].shape, f"{mname}.{name}: shape list changed"
            assert v.location == rt[name].location, f"{mname}.{name}: location changed"


# --- a shape naming an undeclared index set (issue #249) --------------------

_FIXTURES_ROOT_DIR = FIXTURES_ROOT


@pytest.mark.parametrize("name", ["two_d_faces.esm", "vertex_located.esm"])
def test_undeclared_shape_axis_is_refused_at_build(name):
    """A state shaped over index sets the document never declares, and indexed by
    no equation, has no extent. It must be refused at build, as Julia and Rust do,
    rather than integrated as one scalar slot per state."""
    from earthsci_ast.problem import esm_problem
    from earthsci_ast.sympy_bridge import SimulationError

    with pytest.raises(SimulationError, match="E_REF_UNDECLARED_INDEX_SET"):
        esm_problem(_load(name), (0.0, 1.0))


def test_undeclared_ranges_from_is_refused_at_build_not_at_solve():
    """The §9.7.10 agnostic leaf ranges over and is shaped over `cells`, which only
    an injected grid declares. Standalone it must fail at build, as in Julia and
    Rust, not build and then fail on the first right-hand-side evaluation."""
    from earthsci_ast.problem import esm_problem
    from earthsci_ast.sympy_bridge import SimulationError

    path = _FIXTURES_ROOT_DIR / "conformance" / "expression_templates"
    path = path / "inject_agnostic_faq" / "fixture.esm"
    with pytest.raises(SimulationError, match="E_REF_UNDECLARED_INDEX_SET"):
        esm_problem(load_path(path), (0.0, 1.0))


def test_undeclared_shape_axis_with_indexed_equations_still_builds():
    """The refusal is scoped to a state with NO extent. A state whose equations
    index it over literal ranges is sized by them even though its declared axis
    names no registry entry, and it builds in Julia too."""
    from earthsci_ast.problem import esm_problem

    path = _FIXTURES_ROOT_DIR / "conformance" / "pde_simulation" / "fixtures"
    prob = esm_problem(load_path(path / "diffusion_1d_periodic_n4.esm"), (0.0, 1.0))
    assert prob.pathway == "array"
