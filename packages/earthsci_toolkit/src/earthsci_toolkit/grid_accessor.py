"""Grid accessor ABC and registry (ESS-side contract for ESD impls).

Per the 2026-04-22 grid-inversion decision, concrete grid-family
implementations live in EarthSciDiscretizations (ESD). ESS owns the
cross-binding interface contract; ESD implementations register
themselves against it at import time.

Signatures follow ``EarthSciDiscretizations/docs/GRIDS_API.md`` §7 (common
minimum grid-object fields) and the bead gt-6trd surface:

- ``cell_centers(i, j)`` → coordinates of cell (i, j)
- ``neighbors(cell)``    → adjacent cell identifiers
- ``metric_eval(name, i, j)`` → scalar metric field value at cell (i, j)

The registry keys on ``Grid.family`` (e.g. ``"cartesian"``,
``"unstructured"``, ``"lat_lon"``, …). A factory
takes a parsed :class:`earthsci_toolkit.esm_types.Grid` and returns a
:class:`GridAccessor` bound to it.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, Callable, Dict, Iterable, List, Tuple

from .esm_types import Grid


CellCoord = Tuple[float, ...]
CellId = Any


class GridAccessorError(Exception):
    """Base exception for grid-accessor registry and dispatch errors."""


class UnknownGridFamilyError(GridAccessorError):
    """Raised when no accessor factory is registered for a grid family."""


class GridAccessorRegistrationError(GridAccessorError):
    """Raised when registration is rejected (duplicate, bad factory, …)."""


class GridAccessor(ABC):
    """Abstract read-only accessor over a parsed :class:`Grid`.

    Concrete subclasses live in EarthSciDiscretizations (one per grid
    family). They are constructed from a :class:`Grid` instance via a
    factory registered through :func:`register_grid_accessor`.
    """

    @property
    @abstractmethod
    def family(self) -> str:
        """Grid family name this accessor handles (matches ``Grid.family``)."""

    @abstractmethod
    def cell_centers(self, i: int, j: int) -> CellCoord:
        """Return the geometric center of cell ``(i, j)``.

        Coordinate tuple layout is family-defined: e.g. ``(lon, lat)`` for
        spherical families, ``(x, y)`` or ``(x, y, z)`` for Cartesian.
        """

    @abstractmethod
    def neighbors(self, cell: CellId) -> List[CellId]:
        """Return cells adjacent to ``cell``, in family-defined order.

        ``cell`` is the family's native cell identifier — a ``(i, j)``
        tuple for block-structured families, an integer index for
        unstructured families. Order is stable and deterministic so that
        downstream stencils can rely on it.
        """

    @abstractmethod
    def metric_eval(self, name: str, i: int, j: int) -> float:
        """Evaluate metric field ``name`` at cell ``(i, j)``.

        ``name`` selects among the grid's ``metric_arrays`` entries
        (e.g. ``"dx"``, ``"areaCell"``). Raises ``KeyError`` if the
        metric is not defined on this grid.
        """


GridAccessorFactory = Callable[[Grid], GridAccessor]


_REGISTRY: Dict[str, GridAccessorFactory] = {}


def register_grid_accessor(
    family: str,
    factory: GridAccessorFactory,
    *,
    overwrite: bool = False,
) -> None:
    """Register ``factory`` as the accessor constructor for ``family``.

    Called by ESD at import time, once per grid family. Pass
    ``overwrite=True`` to replace an existing registration (intended for
    tests and monkey-patching, not production use).
    """
    if not isinstance(family, str) or not family:
        raise GridAccessorRegistrationError(
            f"family must be a non-empty string, got {family!r}"
        )
    if not callable(factory):
        raise GridAccessorRegistrationError(
            f"factory for family {family!r} is not callable: {factory!r}"
        )
    if family in _REGISTRY and not overwrite:
        raise GridAccessorRegistrationError(
            f"grid family {family!r} is already registered; "
            f"pass overwrite=True to replace"
        )
    _REGISTRY[family] = factory


def unregister_grid_accessor(family: str) -> None:
    """Remove the registration for ``family`` (no-op if absent)."""
    _REGISTRY.pop(family, None)


def has_grid_accessor(family: str) -> bool:
    """Return ``True`` iff a factory is registered for ``family``."""
    return family in _REGISTRY


def registered_grid_families() -> List[str]:
    """Return the sorted list of currently-registered grid families."""
    return sorted(_REGISTRY)


def get_grid_accessor(grid: Grid) -> GridAccessor:
    """Build an accessor for ``grid`` via the registered factory.

    Raises :class:`UnknownGridFamilyError` if ``grid.family`` has no
    registered factory — typically meaning ESD (or an equivalent
    provider) has not been imported.
    """
    if not isinstance(grid, Grid):
        raise TypeError(f"expected Grid, got {type(grid).__name__}")
    try:
        factory = _REGISTRY[grid.family]
    except KeyError:
        raise UnknownGridFamilyError(
            f"no GridAccessor registered for family {grid.family!r}; "
            f"registered: {registered_grid_families()}"
        ) from None
    return factory(grid)


def _clear_registry_for_tests() -> None:
    """Test-only: wipe the registry. Not part of the public API."""
    _REGISTRY.clear()


__all__ = [
    "GridAccessor",
    "GridAccessorError",
    "UnknownGridFamilyError",
    "GridAccessorRegistrationError",
    "GridAccessorFactory",
    "register_grid_accessor",
    "unregister_grid_accessor",
    "has_grid_accessor",
    "registered_grid_families",
    "get_grid_accessor",
]
