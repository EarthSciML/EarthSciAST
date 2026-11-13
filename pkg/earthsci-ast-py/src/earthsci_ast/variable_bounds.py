"""Variable bounds ``lb`` / ``ub`` (esm-spec §6.3.2).

Two passes live here. :func:`reject_variable_bounds_pre_v21` is the load-time
version gate, run on each file's raw JSON before schema validation.
:func:`variable_bound_findings` is the structural check, run on the raw dict by
the load-time structural pass and on the parsed :class:`~.esm_types.EsmFile` by
``validate``; it reads either spelling through the classification accessors.

A reference bound is resolved exactly as a free variable reference in an
expression of the owning model node: by the §4.9.7 resolution
:func:`~.structural_checks._resolve_scoped_name` that the
``circular_dependency`` check uses, against the same declared-name table.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from .classification import _field, _variables, model_nodes
from .error_handling import (
    VARIABLE_BOUND_CIRCULAR,
    VARIABLE_BOUND_SHAPE_MISMATCH,
    VARIABLE_BOUNDS_INVERTED,
    VARIABLE_BOUNDS_VERSION_TOO_OLD,
    ErrorCode,
)
from .solver import _declared_minor
from .structural_checks import (
    _pointer_token,
    _resolve_scoped_name,
    declared_scoped_members,
    observed_graph_nodes,
    observed_reads,
)

_BOUNDS = ("lb", "ub")


class VariableBoundsError(Exception):
    """Raised for ``lb`` / ``ub`` in a file whose declared ``esm`` predates
    them. Carries the stable diagnostic ``code`` alongside the message, like
    ``ConstUnitsError``."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _first_bound_pointer(view: dict[str, Any]) -> str | None:
    """The JSON Pointer of the first ``lb`` / ``ub`` on a model variable, in
    document order: a model's own variables before its subsystems'."""

    def walk(pointer: str, model: Any) -> str | None:
        if not isinstance(model, Mapping) or "ref" in model:
            return None
        variables = model.get("variables")
        if isinstance(variables, Mapping):
            for name, var in variables.items():
                if not isinstance(var, Mapping):
                    continue
                for bound in _BOUNDS:
                    if bound in var:
                        return f"{pointer}/variables/{_pointer_token(name)}/{bound}"
        subsystems = model.get("subsystems")
        if isinstance(subsystems, Mapping):
            for name, sub in subsystems.items():
                hit = walk(f"{pointer}/subsystems/{_pointer_token(name)}", sub)
                if hit is not None:
                    return hit
        return None

    models = view.get("models")
    if isinstance(models, Mapping):
        for name, model in models.items():
            hit = walk(f"/models/{_pointer_token(name)}", model)
            if hit is not None:
                return hit
    return None


def reject_variable_bounds_pre_v21(view: Any) -> None:
    """Reject ``lb`` / ``ub`` on any model variable of a file declaring esm
    < 2.1.0, at the pointer of the first one (esm-spec §6.3.2 "Version gate").
    Runs before schema validation so the author sees the version hint rather
    than an unknown-property error. Each file is held to its own declared
    version, so the loader runs it on the root and on every mounted leaf."""
    if not isinstance(view, dict):
        return
    version = _declared_minor(view)
    if version is None or version >= (2, 1):
        return
    pointer = _first_bound_pointer(view)
    if pointer is None:
        return
    raise VariableBoundsError(
        VARIABLE_BOUNDS_VERSION_TOO_OLD,
        f"variable bounds `lb` / `ub` require esm >= 2.1.0; file declares {view['esm']}. "
        f"Offending path: {pointer}",
    )


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _declared_shape(decl: Any) -> list[str] | None:
    """A declaration's ``shape`` as an index-set name list; None is scalar
    (``shape`` omitted, null or empty)."""
    shape = _field(decl, "shape")
    return list(shape) if shape else None


def _shape_text(shape: list[str] | None) -> str:
    return f"[{', '.join(shape)}]" if shape else "(scalar)"


def _unmounted_prefixes(document: Any) -> set[str]:
    """The scoped paths of every ``{"ref"}`` mount not yet resolved: a name
    under one of them lives in another file and cannot be decided here."""
    out: set[str] = set()

    def walk(prefix: str, component: Any) -> None:
        if isinstance(component, Mapping) and "ref" in component:
            out.add(prefix)
            return
        subsystems = _field(component, "subsystems") or {}
        if isinstance(subsystems, Mapping):
            for name, sub in subsystems.items():
                walk(f"{prefix}.{name}", sub)

    for section in ("models", "reaction_systems"):
        components = _field(document, section) or {}
        if isinstance(components, Mapping):
            for name, component in components.items():
                walk(name, component)
    return out


def _under(name: str, prefixes: set[str]) -> bool:
    return any(name.startswith(f"{p}.") for p in prefixes)


def _relative(name: str, scope: str) -> str:
    """``name`` spelled relative to the model node ``scope`` when it is in it."""
    return name[len(scope) + 1 :] if name.startswith(f"{scope}.") else name


def _dependency_chain(
    start: str,
    target: str,
    definitions: dict[str, tuple[str, Any, dict[str, Any]]],
    declared: set[str],
    nodes: set[str],
) -> list[str] | None:
    """The shortest chain ``start -> ... -> target`` through observed
    definitions, or None. Only an observed is expanded: the walk stops at an
    ODE state, a parameter, an algebraic unknown and a species, whose values
    evaluating a right-hand side does not compute (esm-spec §6.3.2 rule 3)."""
    parent: dict[str, str | None] = {start: None}
    queue = [start]
    for current in queue:
        for read in sorted(observed_reads(current, definitions, declared)):
            if read == target:
                chain = [target, current]
                while parent[chain[-1]] is not None:
                    chain.append(parent[chain[-1]])
                return chain[::-1]
            if read in nodes and read not in parent:
                parent[read] = current
                queue.append(read)
    return None


def variable_bound_findings(document: Any) -> list[tuple[str, str, str, dict[str, Any]]]:
    """Every §6.3.2 validity finding of ``document`` as ``(code, pointer,
    message, details)``, models and inline subsystems at every depth, in
    document order. Rules 2 and 3 are skipped for an unresolved reference, and a
    reference into a mount not yet resolved is left to the pass over the
    resolved tree."""
    declared_members = declared_scoped_members(document)
    declared = set(declared_members)
    unmounted = _unmounted_prefixes(document)
    graph: tuple | None = None
    findings: list[tuple[str, str, str, dict[str, Any]]] = []

    for path, model in model_nodes(document):
        if isinstance(model, Mapping) and "ref" in model:
            continue
        pointer = "/models/" + "/subsystems/".join(_pointer_token(p) for p in path.split("."))
        for vname, var in _variables(model).items():
            var_pointer = f"{pointer}/variables/{_pointer_token(vname)}"
            target = f"{path}.{vname}"
            own_shape = _declared_shape(var)
            for bound in _BOUNDS:
                ref = _field(var, bound)
                if not isinstance(ref, str) or not ref:
                    continue
                at = f"{var_pointer}/{bound}"
                resolved = _resolve_scoped_name(path, ref, declared)
                if resolved not in declared:
                    if _under(resolved, unmounted) or _under(f"{path}.{ref}", unmounted):
                        continue
                    findings.append(
                        (
                            ErrorCode.UNDEFINED_VARIABLE.value,
                            at,
                            f'Variable "{ref}" referenced as the {bound} of '
                            f"'{vname}' but not declared",
                            {"variable": ref, "bound": bound},
                        )
                    )
                    continue
                details = {"variable": vname, "bound": bound, "reference": ref}
                ref_shape = _declared_shape(declared_members[resolved])
                if ref_shape is not None and ref_shape != own_shape:
                    findings.append(
                        (
                            VARIABLE_BOUND_SHAPE_MISMATCH,
                            at,
                            f"The {bound} of '{vname}' references '{ref}', shaped "
                            f"{_shape_text(ref_shape)}; a bound must be scalar or the "
                            f"bounded variable's shape {_shape_text(own_shape)}",
                            details,
                        )
                    )
                if resolved == target:
                    findings.append(
                        (
                            VARIABLE_BOUND_CIRCULAR,
                            at,
                            f"The {bound} of '{vname}' refers to '{vname}' itself",
                            details,
                        )
                    )
                    continue
                if graph is None:
                    graph = observed_graph_nodes(document)
                definitions, graph_declared, nodes = graph
                if resolved not in nodes:
                    continue
                chain = _dependency_chain(resolved, target, definitions, graph_declared, nodes)
                if chain is not None:
                    findings.append(
                        (
                            VARIABLE_BOUND_CIRCULAR,
                            at,
                            f"The {bound} of '{vname}' refers to '{ref}', whose definition "
                            f"depends on '{vname}' "
                            f"({' -> '.join(_relative(n, path) for n in chain)})",
                            details,
                        )
                    )
            lb, ub = _field(var, "lb"), _field(var, "ub")
            if _is_number(lb) and _is_number(ub) and lb > ub:
                findings.append(
                    (
                        VARIABLE_BOUNDS_INVERTED,
                        var_pointer,
                        f"'{vname}' has lb {lb} greater than ub {ub}",
                        {"variable": vname, "lb": lb, "ub": ub},
                    )
                )
    return findings
