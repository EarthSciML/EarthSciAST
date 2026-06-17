"""Tests for the GridAccessor ABC and registry (gt-6trd)."""

import pytest

from earthsci_toolkit import (
    GridAccessor,
    GridAccessorRegistrationError,
    UnknownGridFamilyError,
    get_grid_accessor,
    has_grid_accessor,
    register_grid_accessor,
    registered_grid_families,
    unregister_grid_accessor,
)
from earthsci_toolkit.esm_types import Grid
from earthsci_toolkit.grid_accessor import _clear_registry_for_tests


class _FakeAccessor(GridAccessor):
    def __init__(self, grid: Grid) -> None:
        self._grid = grid

    @property
    def family(self) -> str:
        return self._grid.family

    def cell_centers(self, i, j):
        return (float(i), float(j))

    def neighbors(self, cell):
        i, j = cell
        return [(i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)]

    def metric_eval(self, name, i, j):
        if name not in self._grid.metric_arrays:
            raise KeyError(name)
        return float(i + j)


@pytest.fixture(autouse=True)
def _isolate_registry():
    _clear_registry_for_tests()
    yield
    _clear_registry_for_tests()


def _make_grid(family: str = "cartesian") -> Grid:
    return Grid(family=family, dimensions=["x", "y"], name="g")


def test_abstract_cannot_instantiate():
    with pytest.raises(TypeError):
        GridAccessor()


def test_register_and_dispatch():
    register_grid_accessor("cartesian", _FakeAccessor)
    assert has_grid_accessor("cartesian")
    assert registered_grid_families() == ["cartesian"]

    acc = get_grid_accessor(_make_grid("cartesian"))
    assert isinstance(acc, GridAccessor)
    assert acc.family == "cartesian"
    assert acc.cell_centers(3, 4) == (3.0, 4.0)
    assert acc.neighbors((1, 1)) == [(0, 1), (2, 1), (1, 0), (1, 2)]


def test_unknown_family_raises():
    with pytest.raises(UnknownGridFamilyError):
        get_grid_accessor(_make_grid("nonexistent"))


def test_duplicate_registration_rejected():
    register_grid_accessor("cartesian", _FakeAccessor)
    with pytest.raises(GridAccessorRegistrationError):
        register_grid_accessor("cartesian", _FakeAccessor)


def test_duplicate_registration_overwrite_allowed():
    register_grid_accessor("cartesian", _FakeAccessor)
    register_grid_accessor("cartesian", _FakeAccessor, overwrite=True)


def test_unregister_is_idempotent():
    register_grid_accessor("cartesian", _FakeAccessor)
    unregister_grid_accessor("cartesian")
    unregister_grid_accessor("cartesian")
    assert not has_grid_accessor("cartesian")


def test_register_rejects_non_callable():
    with pytest.raises(GridAccessorRegistrationError):
        register_grid_accessor("cartesian", "not-a-factory")  # type: ignore[arg-type]


def test_register_rejects_empty_family():
    with pytest.raises(GridAccessorRegistrationError):
        register_grid_accessor("", _FakeAccessor)


def test_get_rejects_non_grid():
    with pytest.raises(TypeError):
        get_grid_accessor({"family": "cartesian"})  # type: ignore[arg-type]


def test_registered_families_sorted():
    register_grid_accessor("unstructured", _FakeAccessor)
    register_grid_accessor("cartesian", _FakeAccessor)
    assert registered_grid_families() == ["cartesian", "unstructured"]
