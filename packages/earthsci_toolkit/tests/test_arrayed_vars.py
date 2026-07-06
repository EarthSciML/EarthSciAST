"""Tests for arrayed-variable shape/location fields (discretization RFC §10.2)."""

from __future__ import annotations

import pytest
from conftest import FIXTURES_ROOT

from earthsci_toolkit import load, save

FIXTURES = FIXTURES_ROOT / "fixtures" / "arrayed_vars"


def _load(name: str):
    return load(FIXTURES / name)


def _roundtrip(name: str):
    first = _load(name)
    reserialized = save(first)
    second = load(reserialized)
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
            assert bool(v.shape) == bool(rt[name].shape), f"{mname}.{name}: shape truthiness changed"
            if v.shape:
                assert v.shape == rt[name].shape, f"{mname}.{name}: shape list changed"
            assert v.location == rt[name].location, f"{mname}.{name}: location changed"
