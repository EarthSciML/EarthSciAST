"""
Migration functionality for ESM format version compatibility.

Provides raw-dict migration for v0.1.0 → v0.2.0 per
docs/rfcs/discretization.md §10.1 and §16.1: relocation of
domain-level boundary_conditions to model-level boundary_conditions.
This is the transform behind the ``esm-migrate`` CLI
(:mod:`earthsci_toolkit.cli.migrate`).
"""

import copy
from typing import Any, Dict, List


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

