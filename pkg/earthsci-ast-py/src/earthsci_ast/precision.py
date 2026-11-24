"""Declared working precision of ESM variables (esm-spec §11.3.3)."""

from __future__ import annotations

from typing import Any, Literal

from .esm_types import EsmFile, ExprNode, Model, ModelVariable, ReactionSystem
from .expr_walk import iter_children
from .solver import _declared_minor

# The first esm version at which a root that declares no `domain.element_type`
# leaves its precision unspecified (esm-spec §11.3.3). An older root that omits
# it declares binary64.
UNSPECIFIED_PRECISION_SINCE = (2, 4)


def _omitted_precision(version: str | None) -> Literal["Float64", "unspecified"]:
    parts = _declared_minor({"esm": version})
    return "Float64" if parts is None or parts < UNSPECIFIED_PRECISION_SINCE else "unspecified"


def precision_source(document: EsmFile, variable: ModelVariable | None = None) -> str:
    """Return the declared element type, or `unspecified` for eligible omission.

    Pass no variable to query the document default (also used by species and
    reaction-system parameters).
    """
    if variable is not None and variable.element_type is not None:
        return variable.element_type
    if document.domain is not None and document.domain.element_type is not None:
        return document.domain.element_type
    return _omitted_precision(document.esm)


def _pointer_token(name: str) -> str:
    return name.replace("~", "~0").replace("/", "~1")


def unspecified_keys(document: EsmFile) -> list[tuple[str, str]]:
    """``(pointer, message)`` for every unspecified variable used directly as
    an operand of ``==`` / ``!=`` or as a ``join.on`` key (esm-spec §11.3.3 P8).

    Empty unless the document's own precision is unspecified. An indexed read
    is its array; a loop or binder symbol is not a variable.
    """
    if precision_source(document) != "unspecified":
        return []
    unspecified: dict[str, bool] = {}
    expressions: list[tuple[str, str, Any]] = []

    def equations(scope: str, pointer: str, block: str, eqs) -> None:
        for i, eq in enumerate(eqs or []):
            for side in ("lhs", "rhs"):
                expressions.append((scope, f"{pointer}/{block}/{i}/{side}", getattr(eq, side)))

    def model(scope: str, pointer: str, m: Model) -> None:
        for name, var in m.variables.items():
            unspecified[f"{scope}.{name}"] = var.element_type is None
        equations(scope, pointer, "equations", m.equations)
        equations(scope, pointer, "initialization_equations", m.initialization_equations)
        for key, sub in (m.subsystems or {}).items():
            if isinstance(sub, Model):
                model(f"{scope}.{key}", f"{pointer}/subsystems/{key}", sub)

    def reaction_system(scope: str, pointer: str, rs: ReactionSystem) -> None:
        for entry in list(rs.species) + list(rs.parameters):
            unspecified[f"{scope}.{entry.name}"] = True
        for i, reaction in enumerate(rs.reactions):
            expressions.append((scope, f"{pointer}/reactions/{i}/rate", reaction.rate_constant))
        equations(scope, pointer, "constraint_equations", rs.constraint_equations)
        for key, sub in (rs.subsystems or {}).items():
            if isinstance(sub, ReactionSystem):
                reaction_system(f"{scope}.{key}", f"{pointer}/subsystems/{key}", sub)

    for name, m in (document.models or {}).items():
        if isinstance(m, Model):
            model(name, f"/models/{_pointer_token(name)}", m)
    for name, rs in (document.reaction_systems or {}).items():
        if isinstance(rs, ReactionSystem):
            reaction_system(name, f"/reaction_systems/{_pointer_token(name)}", rs)

    sites: list[tuple[str, str]] = []
    for scope, pointer, expr in expressions:

        def found(key: str, op: str, scope=scope, pointer=pointer) -> None:
            for variable in (f"{scope}.{key}", key):
                if variable in unspecified:
                    if unspecified[variable]:
                        sites.append(
                            (
                                pointer,
                                f"{variable} has unspecified precision in {op} at {pointer}",
                            )
                        )
                    return

        _visit_keys(expr, [], found)
    return sites


def _visit_keys(expr: Any, bound: list[str], found) -> None:
    if not isinstance(expr, ExprNode):
        return
    outer = len(bound)
    bound.extend((expr.ranges or {}).keys())
    bound.extend(i for i in (expr.output_idx or []) if isinstance(i, str))
    if isinstance(expr.var, str):
        bound.append(expr.var)
    if expr.op in ("==", "!="):
        for arg in expr.args:
            while isinstance(arg, ExprNode) and arg.op == "index" and arg.args:
                arg = arg.args[0]
            if isinstance(arg, str) and arg not in bound:
                found(arg, expr.op)
    for clause in expr.join or []:
        for pair in clause.get("on") or []:
            for name in pair:
                found(name, "join.on")
    for child in iter_children(expr):
        _visit_keys(child, bound, found)
    del bound[outer:]
