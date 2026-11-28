"""Reading a deprecated ``initialization_equations`` block, and the shape of
``ic`` (esm 2.5.0; esm-spec §4.2 ``ic``, §11.4.4).

Both run at the wire boundary, on the raw JSON of every document a load
touches (:func:`earthsci_ast.parse.prepare_document_ops`), after the esm-2.3
old spellings are read:

* :func:`migrate_initialization_equations` rewrites each model's
  ``initialization_equations`` into ``ic`` equations appended to its
  ``equations`` — every reference to an unknown ``w`` becomes ``ic(w)`` and every
  time derivative ``D(w)`` becomes ``ic(D(w))`` — or, for a model with no time
  derivative, into ``guesses`` entries. The field does not survive.
* :func:`check_ic_arguments` refuses an ``ic`` whose argument is neither a
  variable reference nor ``D`` of one (``ic(index(u, i))``, ``ic(a + b)``), or
  names a declared parameter (``ic(k)``).

This module imports nothing from the package beyond the error leaf, so the
parser can import it at module load.
"""

from __future__ import annotations

from typing import Any

from .errors import ParseError

__all__ = [
    "DeprecatedFieldError",
    "IcInvalidArgumentError",
    "check_ic_arguments",
    "migrate_initialization_equations",
]

_FIELD = "initialization_equations"
# The raw-dict child slots of an expression node (mirrors ``json_walk``).
_LIST_CHILDREN = ("args", "values")
_SINGLE_CHILDREN = ("lower", "upper", "expr", "filter", "key")
_MAP_CHILDREN = ("bindings",)


class DeprecatedFieldError(ParseError):
    """``deprecated_field`` reported as an ERROR (esm-spec §11.4.4): an
    initialization equation of a model with no time derivative whose left-hand
    side is not a bare unknown has no reading as a starting point."""

    code = "deprecated_field"


class IcInvalidArgumentError(ParseError):
    """``ic_invalid_argument`` (esm-spec §4.2 ``ic``): the argument of an
    ``ic`` is neither a variable reference nor ``D`` of one."""

    code = "ic_invalid_argument"


def _token(s: str) -> str:
    return s.replace("~", "~0").replace("/", "~1")


def _is_node(x: Any) -> bool:
    return isinstance(x, dict) and isinstance(x.get("op"), str)


def _local_of_type(model: dict, kind: str) -> set[str]:
    out: set[str] = set()
    for name, var in (model.get("variables") or {}).items():
        if isinstance(var, dict) and var.get("type") == kind:
            out.add(name)
    return out


def _local_unknowns(model: dict) -> set[str]:
    return _local_of_type(model, "unknown")


def _resolve_scoped(root: dict, model: dict, name: str, kind: str = "unknown") -> bool:
    """Whether the scoped reference ``name`` (``A.B.x``) names a variable of
    type ``kind``: relative to ``model``'s subsystems first, then from the
    document root (a model's variable, or a reaction system's species for an
    unknown)."""
    parts = name.split(".")
    if len(parts) < 2:
        return False

    def through_subsystems(m: Any, segs: list[str]) -> bool:
        for seg in segs[:-1]:
            subs = m.get("subsystems") if isinstance(m, dict) else None
            if not isinstance(subs, dict) or not isinstance(subs.get(seg), dict):
                return False
            m = subs[seg]
        return isinstance(m, dict) and segs[-1] in _local_of_type(m, kind)

    if through_subsystems(model, parts):
        return True
    head, rest = parts[0], parts[1:]
    models = root.get("models") if isinstance(root, dict) else None
    if isinstance(models, dict) and isinstance(models.get(head), dict):
        if through_subsystems(models[head], rest):
            return True
    if kind != "unknown":
        return False
    systems = root.get("reaction_systems") if isinstance(root, dict) else None
    if len(rest) == 1 and isinstance(systems, dict) and isinstance(systems.get(head), dict):
        species = systems[head].get("species")
        if isinstance(species, dict) and rest[0] in species:
            return True
    return False


def _lhs_has_time_derivative(e: Any) -> bool:
    if _is_node(e):
        if e["op"] == "D":
            return True
        return any(_lhs_has_time_derivative(c) for c in _children(e))
    return False


def _children(e: dict) -> list[Any]:
    out: list[Any] = []
    for k in _LIST_CHILDREN:
        v = e.get(k)
        if isinstance(v, list):
            out.extend(v)
    for k in _SINGLE_CHILDREN:
        if k in e:
            out.append(e[k])
    for k in _MAP_CHILDREN:
        v = e.get(k)
        if isinstance(v, dict):
            out.extend(v.values())
    return out


def _rewrite(e: Any, is_unknown) -> Any:
    """``e`` with every unknown ``w`` read as ``ic(w)`` and every ``D(w)`` as
    ``ic(D(w))`` (esm-spec §11.4.4). Every other key is kept verbatim."""
    if isinstance(e, str):
        return {"op": "ic", "args": [e]} if is_unknown(e) else e
    if not _is_node(e):
        return e
    if e["op"] == "D":
        args = e.get("args")
        if isinstance(args, list) and len(args) == 1 and isinstance(args[0], str):
            if is_unknown(args[0]):
                return {"op": "ic", "args": [dict(e)]}
            return e
    out = dict(e)
    for k in _LIST_CHILDREN:
        if isinstance(out.get(k), list):
            out[k] = [_rewrite(c, is_unknown) for c in out[k]]
    for k in _SINGLE_CHILDREN:
        if k in out:
            out[k] = _rewrite(out[k], is_unknown)
    for k in _MAP_CHILDREN:
        if isinstance(out.get(k), dict):
            out[k] = {n: _rewrite(c, is_unknown) for n, c in out[k].items()}
    return out


def _migrate_model(root: dict, model: dict, at: str, sites: list[str]) -> None:
    subs = model.get("subsystems")
    if isinstance(subs, dict):
        for name, sub in subs.items():
            if isinstance(sub, dict) and "ref" not in sub:
                _migrate_model(root, sub, f"{at}/subsystems/{_token(name)}", sites)
    if _FIELD not in model:
        return
    block = model.pop(_FIELD)
    if not isinstance(block, list) or not block:
        return
    sites.append(f"{at}/{_FIELD} ({_FIELD})")
    equations = model.get("equations")
    if not isinstance(equations, list):
        equations = []
    local = _local_unknowns(model)
    if any(isinstance(eq, dict) and _lhs_has_time_derivative(eq.get("lhs")) for eq in equations):

        def is_unknown(name: str) -> bool:
            return name in local or ("." in name and _resolve_scoped(root, model, name))

        for eq in block:
            if not isinstance(eq, dict):
                continue
            new = dict(eq)
            new["lhs"] = _rewrite(eq.get("lhs"), is_unknown)
            new["rhs"] = _rewrite(eq.get("rhs"), is_unknown)
            equations.append(new)
        model["equations"] = equations
        return
    # A model with no time derivative (esm-spec §11.4.4): each `v ~ e` is a
    # starting point for its solve, `guesses[v] = e`; an existing guess wins.
    guesses = model.get("guesses")
    if not isinstance(guesses, dict):
        guesses = {}
    for k, eq in enumerate(block):
        lhs = eq.get("lhs") if isinstance(eq, dict) else None
        if not (isinstance(lhs, str) and lhs in local):
            raise DeprecatedFieldError(
                f"deprecated_field: {at}/{_FIELD}/{k}: the model has no time derivative, so "
                "its initialization equations are read as `guesses` entries (esm-spec "
                "§11.4.4), and this one's left-hand side is not a bare unknown of the model; "
                "it has no meaning as a starting point. Write it as a `guesses` entry, or "
                "as an equation of the model."
            )
        guesses.setdefault(lhs, eq.get("rhs"))
    model["guesses"] = guesses


def migrate_initialization_equations(doc: Any) -> list[str]:
    """Rewrite every model's deprecated ``initialization_equations`` IN PLACE
    (esm-spec §11.4.4) and return one site per model that carried a non-empty
    block, as ``<pointer> (initialization_equations)``, for the document's
    ``deprecated_field`` warning. Raises :class:`DeprecatedFieldError` for an
    equation of a model with no time derivative that is not ``v ~ e``.
    Idempotent: a second pass finds nothing."""
    sites: list[str] = []
    if not isinstance(doc, dict):
        return sites
    models = doc.get("models")
    if isinstance(models, dict):
        for name, model in models.items():
            if isinstance(model, dict) and "ref" not in model:
                _migrate_model(doc, model, f"/models/{_token(name)}", sites)
    return sites


def _check(e: Any, at: str) -> None:
    if isinstance(e, dict):
        if e.get("op") == "ic":
            args = e.get("args")
            ok = isinstance(args, list) and len(args) == 1
            if ok:
                a = args[0]
                ok = isinstance(a, str) or (
                    _is_node(a)
                    and a["op"] == "D"
                    and isinstance(a.get("args"), list)
                    and len(a["args"]) == 1
                    and isinstance(a["args"][0], str)
                )
            if not ok:
                raise IcInvalidArgumentError(
                    f"ic_invalid_argument: {at}: malformed `ic`: its argument must be a variable reference, bare "
                    "or scoped, or `D` of one (esm-spec §4.2 `ic`). An element of an array "
                    "unknown's starting value is written `index(ic(u), i)`, not "
                    "`ic(index(u, i))`."
                )
        for k, v in e.items():
            if isinstance(v, (dict, list)):
                _check(v, f"{at}/{_token(str(k))}")
    elif isinstance(e, list):
        for i, v in enumerate(e):
            if isinstance(v, (dict, list)):
                _check(v, f"{at}/{i}")


def _ic_parameters(root: dict, model: dict, e: Any, at: str) -> None:
    """Refuse an ``ic`` in ``model`` (its subsystems excluded) whose argument
    names a declared parameter, bare or scoped (esm-spec §4.2 ``ic``)."""
    if isinstance(e, dict):
        if e.get("op") == "ic" and isinstance(e.get("args"), list) and len(e["args"]) == 1:
            a = e["args"][0]
            if _is_node(a) and a["op"] == "D" and isinstance(a.get("args"), list) and a["args"]:
                a = a["args"][0]
            if isinstance(a, str) and (
                a in _local_of_type(model, "parameter")
                or ("." in a and _resolve_scoped(root, model, a, "parameter"))
            ):
                raise IcInvalidArgumentError(
                    f"ic_invalid_argument: {at}: `ic({a})` names a declared parameter. A "
                    "parameter has no starting value of its own; its value is read as "
                    f"`{a}` (esm-spec §4.2 `ic`)."
                )
        for k, v in e.items():
            if isinstance(v, (dict, list)):
                _ic_parameters(root, model, v, f"{at}/{_token(str(k))}")
    elif isinstance(e, list):
        for i, v in enumerate(e):
            if isinstance(v, (dict, list)):
                _ic_parameters(root, model, v, f"{at}/{i}")


def _check_model_parameters(root: dict, model: dict, at: str) -> None:
    for k, v in model.items():
        if k == "subsystems" and isinstance(v, dict):
            for name, sub in v.items():
                if isinstance(sub, dict) and "ref" not in sub:
                    _check_model_parameters(root, sub, f"{at}/subsystems/{_token(name)}")
        elif isinstance(v, (dict, list)):
            _ic_parameters(root, model, v, f"{at}/{_token(str(k))}")


def check_ic_arguments(doc: Any) -> None:
    """Refuse at load, with ``ic_invalid_argument`` naming the node's location
    (esm-spec §4.2 ``ic``), an ``ic`` whose argument is not a variable
    reference or ``D`` of one, and one whose argument names a declared
    parameter of the model it is written in (``ic(k)``, ``ic(D(k))``)."""
    _check(doc, "")
    models = doc.get("models") if isinstance(doc, dict) else None
    if isinstance(models, dict):
        for name, model in models.items():
            if isinstance(model, dict) and "ref" not in model:
                _check_model_parameters(doc, model, f"/models/{_token(name)}")
