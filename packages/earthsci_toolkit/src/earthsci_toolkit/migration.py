"""
Migration functionality for ESM format version compatibility.

Implements Section 8.3 of the ESM Libraries Specification:
migrate(file: EsmFile, target_version: String) -> EsmFile

Also provides raw-dict migration for v0.1.0 → v0.2.0 per
docs/rfcs/discretization.md §10.1 and §16.1: relocation of
domain-level boundary_conditions to model-level boundary_conditions.
"""

import copy
from typing import Any, Dict, List, Tuple


class MigrationError(Exception):
    """Error raised when migration fails."""

    def __init__(self, message: str, from_version: str = "", to_version: str = ""):
        self.from_version = from_version
        self.to_version = to_version
        super().__init__(
            f"Migration error: {message} ({from_version} -> {to_version})"
            if from_version
            else f"Migration error: {message}"
        )


def _parse_version(version: str) -> Tuple[int, int, int]:
    """Parse a semantic version string into (major, minor, patch)."""
    parts = version.split(".")
    if len(parts) != 3:
        raise MigrationError(f"Invalid version format: {version}", version, "")
    try:
        return (int(parts[0]), int(parts[1]), int(parts[2]))
    except ValueError:
        raise MigrationError(f"Invalid version format: {version}", version, "")


def _compare_versions(a: str, b: str) -> int:
    """Compare two semantic versions. Returns <0 if a<b, 0 if equal, >0 if a>b."""
    va = _parse_version(a)
    vb = _parse_version(b)
    if va < vb:
        return -1
    elif va > vb:
        return 1
    return 0


def _get_version(esm_file) -> str:
    """Get the version string from an ESM file object (supports .esm or .version)."""
    if hasattr(esm_file, "esm"):
        return esm_file.esm
    if hasattr(esm_file, "version"):
        return esm_file.version
    raise MigrationError("File has no version attribute")


def _set_version(esm_file, version: str):
    """Set the version string on an ESM file object."""
    if hasattr(esm_file, "esm"):
        esm_file.esm = version
    elif hasattr(esm_file, "version"):
        esm_file.version = version


def _migrate_species_units(esm_file, from_version: str, to_version: str):
    """Migrate species units from older format (e.g., ppbv) to newer format (mol/mol)."""
    from_ver = _parse_version(from_version)
    to_ver = _parse_version(to_version)

    # Migration from 0.0.x to 0.1.0+: convert ppbv/ppmv to mol/mol
    if from_ver[0] == 0 and from_ver[1] == 0 and to_ver[0] == 0 and to_ver[1] >= 1:
        reaction_systems = getattr(esm_file, "reaction_systems", None)
        if reaction_systems is None:
            return

        # Handle both dict-of-systems and list-of-systems
        systems = (
            reaction_systems.values()
            if isinstance(reaction_systems, dict)
            else reaction_systems
        )

        for system in systems:
            species_coll = getattr(system, "species", None)
            if species_coll is None:
                continue

            # Handle both dict-of-species and list-of-species
            species_iter = (
                species_coll.values()
                if isinstance(species_coll, dict)
                else species_coll
            )

            for species in species_iter:
                units = getattr(species, "units", None)
                default = getattr(species, "default", None)
                if units == "ppbv" and default is not None:
                    species.units = "mol/mol"
                    species.default = default / 1e9
                elif units == "ppmv" and default is not None:
                    species.units = "mol/mol"
                    species.default = default / 1e6


def _add_migration_notes(esm_file, from_version: str, to_version: str):
    """Add migration notes to the file metadata."""
    metadata = getattr(esm_file, "metadata", None)
    if metadata is None:
        return

    migration_note = f"Migrated from version {from_version} to version {to_version}"

    # Try to set migration_notes attribute if metadata supports it
    desc = getattr(metadata, "description", None)
    if desc:
        metadata.description = f"{desc}\nMigration notes: {migration_note}"
    else:
        metadata.description = f"Migration notes: {migration_note}"


def migrate(esm_file, target_version: str):
    """Migrate an ESM file to a target version.

    Args:
        esm_file: An ESM file object (EsmFile or compatible duck-typed object).
        target_version: The target version string (e.g., "0.1.0").

    Returns:
        A new ESM file object migrated to the target version.

    Raises:
        MigrationError: If migration is not possible.
    """
    current_version = _get_version(esm_file)

    current_ver = _parse_version(current_version)
    target_ver = _parse_version(target_version)

    # No migration needed
    if current_version == target_version:
        return copy.deepcopy(esm_file)

    # Cannot migrate across major versions
    if current_ver[0] != target_ver[0]:
        raise MigrationError(
            f"Cannot migrate across major versions: {current_version} to {target_version}",
            current_version,
            target_version,
        )

    # Only support forward migration
    if _compare_versions(current_version, target_version) > 0:
        raise MigrationError(
            f"Backward migration not supported: {current_version} to {target_version}",
            current_version,
            target_version,
        )

    migrated = copy.deepcopy(esm_file)

    # Update version
    _set_version(migrated, target_version)

    # Apply version-specific migrations
    _migrate_species_units(migrated, current_version, target_version)

    # Add migration notes
    _add_migration_notes(migrated, current_version, target_version)

    return migrated


# ---------------------------------------------------------------------------
# v0.1 → v0.2 dict-level migration (RFC §10.1, §16.1)
# ---------------------------------------------------------------------------

# Axes whose closed-vocabulary sides are <axis>min/<axis>max (no underscore,
# matching the schema's primary side vocabulary: xmin, xmax, ymin, ymax, etc.).
_CLOSED_SHORT_AXES = {"x", "y", "z", "t"}


def _axis_to_sides(axis: str, kind: str) -> List[str]:
    """Expand a v0.1 ``dimensions`` entry to v0.2 ``side`` strings.

    ``x``/``y``/``z``/``t`` use the closed-vocabulary ``<axis>min`` /
    ``<axis>max`` naming; other axis names (e.g., ``lon``, ``lev``) are
    preserved with underscore-separated min/max per the spec's "Authors
    MAY introduce additional named sides" allowance.

    ``periodic`` declares once per pair (RFC §9.2.1): only the min side is
    emitted and the max side is implicit.
    """
    if axis in _CLOSED_SHORT_AXES:
        lo, hi = f"{axis}min", f"{axis}max"
    else:
        lo, hi = f"{axis}_min", f"{axis}_max"
    if kind == "periodic":
        return [lo]
    return [lo, hi]


def _iter_state_variable_names(model: Dict[str, Any]) -> List[str]:
    """List state-variable names in a model (skips parameters/observed)."""
    out: List[str] = []
    variables = model.get("variables", {}) or {}
    if isinstance(variables, dict):
        for vname, vdef in variables.items():
            if isinstance(vdef, dict) and vdef.get("type") == "state":
                out.append(vname)
    return out


def _model_matches_domain(model: Dict[str, Any], domain_name: str) -> bool:
    """Return True if ``model`` is associated with ``domain_name``.

    A model explicitly names its domain via ``model.domain``; models with
    no explicit ``domain`` implicitly use the ``default`` domain when one
    exists (this matches the convention in the pre-0.2 fixture corpus).
    """
    mdom = model.get("domain")
    if mdom is not None:
        return mdom == domain_name
    return domain_name == "default"


def _copy_bc_value_fields(src: Dict[str, Any]) -> Dict[str, Any]:
    """Copy value/function/robin_* fields from a v0.1 domain BC."""
    out: Dict[str, Any] = {}
    for key in ("value", "function", "robin_alpha", "robin_beta", "robin_gamma"):
        if key in src:
            out[key] = src[key]
    return out


def migrate_file_0_1_to_0_2(data: Dict[str, Any]) -> Dict[str, Any]:
    """Migrate a parsed ``.esm`` file dict from v0.1.x to v0.2.0.

    Applies the RFC §16.1 ``spec.migrate_0_1_to_0_2`` convention:

    1. For each ``domains.<d>.boundary_conditions[k]`` of the form
       ``{"type": kind, "dimensions": [axis, ...], value?, robin_*?}``, emit
       per model (those whose ``domain`` field matches ``<d>``) and per state
       variable a ``models.<M>.boundary_conditions["<auto-key>"]`` entry
       ``{"variable", "side", "kind", value?, robin_*?}``.
       ``periodic`` produces a single min-side entry per axis (RFC §9.2.1).
    2. Remove ``domains.<d>.boundary_conditions``.
    3. Bump ``esm`` to ``"0.2.0"``.
    4. Record provenance: append ``"migrated_from_v01"`` to ``metadata.tags``
       (top-level schema is closed; tag-based provenance is the available
       channel).

    The migration is pure: the input dict is not mutated; a deep copy is
    returned.
    """
    out = copy.deepcopy(data)

    from_version = out.get("esm")
    domains = out.get("domains")
    models = out.get("models")

    # Relocate domain-level BCs → model-level BCs.
    if isinstance(domains, dict) and isinstance(models, dict):
        for domain_name, domain in list(domains.items()):
            if not isinstance(domain, dict):
                continue
            dom_bcs = domain.get("boundary_conditions")
            if not dom_bcs:
                continue
            # Collect matching models.
            matched_models = [
                (mname, m) for mname, m in models.items()
                if isinstance(m, dict) and _model_matches_domain(m, domain_name)
            ]
            for bc_entry in dom_bcs:
                if not isinstance(bc_entry, dict):
                    continue
                kind = bc_entry.get("type")
                dims = bc_entry.get("dimensions") or []
                if not isinstance(kind, str) or not isinstance(dims, list):
                    continue
                value_fields = _copy_bc_value_fields(bc_entry)
                for axis in dims:
                    if not isinstance(axis, str):
                        continue
                    for side in _axis_to_sides(axis, kind):
                        for mname, model in matched_models:
                            for vname in _iter_state_variable_names(model):
                                bc_key = f"{vname}_{kind}_{side}"
                                model_bcs = model.setdefault(
                                    "boundary_conditions", {}
                                )
                                # Avoid overwriting if an author already
                                # authored a colliding key (rare but possible).
                                final_key = bc_key
                                n = 2
                                while final_key in model_bcs:
                                    final_key = f"{bc_key}_{n}"
                                    n += 1
                                entry: Dict[str, Any] = {
                                    "variable": vname,
                                    "side": side,
                                    "kind": kind,
                                }
                                entry.update(value_fields)
                                model_bcs[final_key] = entry
            # Remove the domain-level list once relocated.
            del domain["boundary_conditions"]

    # Bump version.
    out["esm"] = "0.2.0"

    # Record provenance via metadata tag (top-level schema is closed, so we
    # cannot add a new top-level field; metadata.tags is the available
    # channel — see RFC §16.1 step 3).
    metadata = out.setdefault("metadata", {})
    if isinstance(metadata, dict):
        tags = metadata.get("tags")
        if isinstance(tags, list):
            if "migrated_from_v01" not in tags:
                tags.append("migrated_from_v01")
        else:
            metadata["tags"] = ["migrated_from_v01"]
        # Also record the exact source version in description for provenance.
        if from_version:
            note = f"Migrated from ESM v{from_version} to v0.2.0 via esm-migrate."
            desc = metadata.get("description")
            if isinstance(desc, str) and desc:
                if note not in desc:
                    metadata["description"] = f"{desc}\n{note}"
            else:
                metadata["description"] = note

    return out


def can_migrate(from_version: str, to_version: str) -> bool:
    """Check if migration is supported between two versions.

    Args:
        from_version: Source version string.
        to_version: Target version string.

    Returns:
        True if migration is supported.
    """
    try:
        from_ver = _parse_version(from_version)
        to_ver = _parse_version(to_version)
    except MigrationError:
        return False

    # Only support migration within same major version
    if from_ver[0] != to_ver[0]:
        return False

    # Only support forward migration (or same version)
    return _compare_versions(from_version, to_version) <= 0


def get_supported_migration_targets(from_version: str) -> List[str]:
    """Get supported migration target versions from a given version.

    Args:
        from_version: Source version string.

    Returns:
        List of supported target version strings.
    """
    try:
        from_ver = _parse_version(from_version)
    except MigrationError:
        return []

    targets = []

    if from_ver[0] == 0:
        if from_ver[1] == 0:
            targets.append("0.1.0")
        if from_ver[1] <= 1:
            targets.extend(["0.1.0", "0.1.1", "0.2.0"])

    # Filter to only versions later than from_version, deduplicate
    seen = set()
    result = []
    for target in targets:
        if target not in seen and _compare_versions(from_version, target) < 0:
            seen.add(target)
            result.append(target)

    return result
