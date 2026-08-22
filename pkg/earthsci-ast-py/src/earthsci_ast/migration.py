"""Version migration for ESM documents (esm-libraries-spec §8.3).

A migration here is a pure version-MARKER bump: it changes the ``esm`` field
and touches nothing else. That is only ever sound along an ADDITIVE line — a
run of schema releases each of which introduced its changes as additive,
backward-compatible fields, so an older file already loads under the newer
schema without any mechanical transform.

The current additive line is ``1.0.0 … <current schema version>``.

**There is no migration across the 1.0.0 boundary.** esm 1.0.0 is a clean break
with no deprecation path: the five declared variable types collapse to two, an
observed variable's ``expression`` becomes an equation, ``data_loaders`` becomes
a non-component ``data_sources`` registry, and parameter mutation moves off
events onto the parameter. None of that is a marker bump — every one of them
RESHAPES the document, and several need information (which unknowns are ODE
states) that only the equations carry. A 0.x source therefore yields no
supported targets rather than a bump that would produce a file claiming 1.0.0
while still carrying 0.x shapes. Converting a 0.x document is a rewrite, and
deliberately not offered as an automated one — which is exactly what
``tests/version_compatibility/`` pins: its migration pair's SOURCE
(``migration_test_from_0_0_5.esm``) is unloadable by a 1.x library and only the
TARGET loads.

The single supported target for an additive-line source is the CURRENT schema
version; arbitrary intermediate targets are deliberately NOT offered — there is
no per-minor transform to encode, only "bring this file up to current". Sources
outside that line (newer than current, a different major, or malformed) yield no
supported targets.

This is a port of the TypeScript ``src/migration.ts``, which is the only
implementation that has been rebased onto the 1.0.0 break. Rust's
``src/migration.rs`` still carries the PRE-1.0.0 table (a 0.0.5 → 0.1.x
species-unit conversion, ppbv → mol/mol) and disagrees with both the TypeScript
implementation and the shared fixtures; it is not followed here.
"""

from __future__ import annotations

import re
from dataclasses import replace

from .errors import EarthSciAstError
from .esm_types import EsmFile
from .parse import _CURRENT_VERSION

__all__ = [
    "MigrationError",
    "SCHEMA_VERSION",
    "can_migrate",
    "migrate",
    "supported_migration_targets",
]

#: The schema version this library implements, as a string. Derived from
#: :data:`earthsci_ast.parse._CURRENT_VERSION` so it cannot hand-drift.
SCHEMA_VERSION: str = ".".join(str(part) for part in _CURRENT_VERSION)

# The additive line runs from 1.0.0 up to (and including) the current schema
# version.
#
# The floor is 1.0.0, not 0.1.0: the 0.x line ended at a clean break, so no 0.x
# version can be carried forward by a marker bump. `_on_additive_line` already
# requires the majors to agree, which makes a 0.x source ineligible on its own;
# the floor is stated at 1.0.0 as well so the intent survives the next major.
_ADDITIVE_FLOOR = (1, 0, 0)

_SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


class MigrationError(EarthSciAstError):
    """Raised when an ESM document cannot be migrated to the requested version.

    Derives from :class:`~earthsci_ast.errors.EarthSciAstError` like every other
    exception in this package, so ``except EarthSciAstError`` catches it.
    """


def _parse_version(version: str) -> tuple[int, int, int] | None:
    """Parse ``major.minor.patch``; ``None`` for anything else.

    The pattern admits ``major.minor.patch`` only — a prerelease suffix or a
    two-component string is malformed, matching the schema's own semver pattern.
    """
    if not isinstance(version, str):
        return None
    match = _SEMVER_RE.match(version)
    if match is None:
        return None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)))


def _on_additive_line(version: tuple[int, int, int]) -> bool:
    """True when ``version`` can be carried to the current schema by a no-op bump."""
    current = _CURRENT_VERSION
    return version[0] == current[0] and _ADDITIVE_FLOOR <= version <= current


def supported_migration_targets(from_version: str) -> list[str]:
    """The schema versions ``from_version`` can migrate to.

    * a version on the additive line ``1.0.0 … <current schema version>`` →
      ``[SCHEMA_VERSION]`` (a no-op marker bump to the current schema);
    * everything else — including EVERY 0.x version, which 1.0.0's clean break
      puts out of reach of a marker bump — → ``[]``.

    The canonical name of TypeScript's ``getSupportedMigrationTargets``: the
    harmonized API drops the ``get`` prefix.
    """
    parsed = _parse_version(from_version)
    if parsed is not None and _on_additive_line(parsed):
        return [SCHEMA_VERSION]
    return []


def can_migrate(from_version: str, to_version: str) -> bool:
    """True when :func:`migrate` would succeed for this version pair."""
    return to_version in supported_migration_targets(from_version)


def migrate(file: EsmFile, target_version: str) -> EsmFile:
    """Migrate ``file`` to ``target_version``.

    Every supported step is a pure version-marker bump with no structural
    transform: an additive-line source (``1.0.0 … <current>``) advanced to the
    current schema version (see the module docstring). Any other version pair —
    a 0.x source included — raises :class:`MigrationError`. Content-level
    changes are not performed; they are modeling decisions, not mechanical
    migrations.

    The input file is never mutated: a new :class:`~earthsci_ast.esm_types.EsmFile`
    carrying the updated marker is returned, sharing the original's sub-objects
    (a shallow copy, matching TypeScript's object spread).
    """
    source_version = getattr(file, "version", None)
    if not source_version:
        raise MigrationError("Source file has no 'esm' version field")

    if not can_migrate(source_version, target_version):
        raise MigrationError(
            f"Migration from {source_version} to {target_version} is not supported"
        )

    return replace(file, version=target_version)
