"""Strip and expose (API_SPEC §5.8, "Strip and expose"; RFC U6, issue #543).

``esm_problem(..., strip=...)`` removes the named construct classes from the
document and builds the rest unchanged; the removed constructs are collected
as a :class:`StrippedConstructs`, whose canonical JSON is byte-identical to
Julia's and Rust's. Python compiles no kernels: :func:`compile_kernels` raises
``compiler_unavailable``.
"""

from __future__ import annotations

import contextvars
import copy
import json
import math
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any

from .classification import is_implicit_lhs
from .compiler import CompilerUnavailableError
from .error_handling import STRIPPED_PROBLEM_NOT_SOLVABLE
from .errors import SimulationError

STRIP_CLASSES = ("algebraic", "continuous_events", "discrete_events", "parameter_updates")

#: The classes the build in progress stripped, so the coupling-level event gate
#: lets through the events it took over.
STRIP_TAKEN: contextvars.ContextVar[tuple[str, ...]] = contextvars.ContextVar(
    "esm_strip_taken", default=()
)


class StrippedProblemNotSolvableError(SimulationError):
    """``stripped_problem_not_solvable``: ``solve`` / ``init`` on a stripped Problem."""

    code = STRIPPED_PROBLEM_NOT_SOLVABLE


@dataclass
class StrippedConstructs:
    """What ``strip`` removed (API_SPEC §5.8, "The stripped object")."""

    strip: list[str] = field(default_factory=list)
    events: list[dict[str, Any]] = field(default_factory=list)
    parameter_updates: list[dict[str, Any]] = field(default_factory=list)
    unknowns: list[str] = field(default_factory=list)
    z_layout: dict[str, dict[str, Any]] = field(default_factory=dict)
    z0: list[float | None] = field(default_factory=list)
    residuals: list[dict[str, Any]] = field(default_factory=list)

    def is_empty(self) -> bool:
        return not (self.events or self.parameter_updates or self.residuals)

    def removed_classes(self) -> list[str]:
        out = set()
        for e in self.events:
            out.add(f"{e['kind']}_events")
        if self.parameter_updates:
            out.add("parameter_updates")
        if self.residuals:
            out.add("algebraic")
        return sorted(out)

    def to_json(self) -> dict[str, Any]:
        return {
            "strip": list(self.strip),
            "events": self.events,
            "parameter_updates": self.parameter_updates,
            "algebraic": {
                "unknowns": list(self.unknowns),
                "z_layout": self.z_layout,
                "z0": list(self.z0),
                "residuals": self.residuals,
            },
        }

    def canonical_json(self) -> str:
        """Compact, keys ascending, numbers in CONFORMANCE_SPEC §5.5.3.1 form."""
        return canonical_json_value(self.to_json())


def strip_classes(strip: Any) -> list[str]:
    out: list[str] = []
    for c in strip or ():
        c = str(c)
        if c not in STRIP_CLASSES:
            raise ValueError(
                f"`strip` names {c!r}, which is not a strippable class; the classes are "
                "algebraic, continuous_events, discrete_events and parameter_updates "
                "(Wiener noise is never strippable)"
            )
        if c not in out:
            out.append(c)
    return sorted(out)


# ---------------------------------------------------------------------------
# Canonical JSON
# ---------------------------------------------------------------------------


def _julia_float(f: float) -> str:
    """``f`` as Julia prints a Float64 (CONFORMANCE_SPEC §5.5.3.1): positional
    for a first-digit exponent in ``-4..=5``, else ``d.ddde<exp>``. Not
    :func:`~earthsci_ast.canonicalize.format_canonical_float`, whose layout
    (the expression canonicalizer's, RFC §5.4.6) switches at ``1e-6`` and
    ``1e21`` and so writes ``1.5e-5`` as ``0.000015``."""
    if not math.isfinite(f):
        raise ValueError("a non-finite number has no canonical JSON form")
    if f == 0.0:
        return "-0.0" if math.copysign(1.0, f) < 0 else "0.0"
    sign, digits, exponent = Decimal(repr(f)).as_tuple()
    ds = "".join(str(d) for d in digits).rstrip("0") or "0"
    e10 = len(digits) + exponent - 1
    out = "-" if sign else ""
    if -4 <= e10 <= 5:
        if e10 < 0:
            out += "0." + "0" * (-e10 - 1) + ds
        else:
            whole = ds[: e10 + 1].ljust(e10 + 1, "0")
            frac = ds[e10 + 1 :] or "0"
            out += whole + "." + frac
    else:
        out += ds[0] + "." + (ds[1:] or "0") + "e" + str(e10)
    return out


def canonical_json_value(v: Any) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v.is_integer() and abs(v) < 9.2e18:
            return str(int(v))
        return _julia_float(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, dict):
        return (
            "{"
            + ",".join(
                json.dumps(str(k), ensure_ascii=False) + ":" + canonical_json_value(v[k])
                for k in sorted(v, key=str)
            )
            + "}"
        )
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(canonical_json_value(x) for x in v) + "]"
    raise TypeError(f"canonical_json: cannot write a {type(v).__name__}")


# ---------------------------------------------------------------------------
# Namespacing (the rule each binding's flatten applies to a component)
# ---------------------------------------------------------------------------

_EXPR_CHILD_KEYS = ("args", "expr", "filter", "lower", "upper", "values", "key")


def _ns_expr(e: Any, prefix: str, local: set[str], subs: set[str], bound: frozenset = frozenset()):
    if isinstance(e, str):
        if e in bound:
            return e
        root = e.split(".", 1)[0]
        if ("." not in e and e in local) or ("." in e and root in subs):
            return f"{prefix}.{e}"
        return e
    if isinstance(e, dict):
        out = dict(e)
        inner = bound
        if e.get("op") in ("faq", "aggregate", "arrayop"):
            names = set(e.get("output_idx") or ()) | set((e.get("ranges") or {}).keys())
            inner = bound | frozenset(str(n) for n in names)
        for k in _EXPR_CHILD_KEYS:
            if k in e:
                v = e[k]
                if isinstance(v, list):
                    out[k] = [_ns_expr(x, prefix, local, subs, inner) for x in v]
                else:
                    out[k] = _ns_expr(v, prefix, local, subs, inner)
        return out
    return e


def _ns_name(name: str, prefix: str, subs: set[str]) -> str:
    """An affect target, namespaced: bare is the component's own, a dotted name
    whose head is one of its subsystem keys is subsystem-local (prefixed, as
    :func:`_ns_expr` prefixes a read of it), any other dotted name is already
    qualified."""
    if name == "_var":
        return name
    if "." in name and name.split(".", 1)[0] not in subs:
        return name
    return f"{prefix}.{name}"


def _affects(affects: list, prefix: str, local: set[str], subs: set[str]) -> list:
    return [
        {"lhs": _ns_name(a["lhs"], prefix, subs), "rhs": _ns_expr(a["rhs"], prefix, local, subs)}
        for a in affects
    ]


def _event_body(ev: dict, prefix: str | None, local: set[str], subs: set[str]) -> dict:
    ns = (lambda x: x) if prefix is None else (lambda x: _ns_expr(x, prefix, local, subs))
    aff = (lambda a: a) if prefix is None else (lambda a: _affects(a, prefix, local, subs))
    body: dict[str, Any] = {}
    if ev.get("name") is not None:
        body["name"] = ev["name"]
    if ev.get("conditions") is not None:
        body["conditions"] = [ns(c) for c in ev["conditions"]]
    if ev.get("trigger") is not None:
        t = dict(ev["trigger"])
        if t.get("type") == "condition":
            t["expression"] = ns(t["expression"])
        if t.get("initial_offset") in (0, 0.0):
            del t["initial_offset"]
        body["trigger"] = t
    body["affects"] = aff(ev.get("affects") or [])
    if ev.get("affect_neg") is not None:
        body["affect_neg"] = aff(ev["affect_neg"])
    if ev.get("root_find") == "right":
        body["root_find"] = "right"
    if ev.get("reinitialize") is True:
        body["reinitialize"] = True
    if ev.get("description") is not None:
        body["description"] = ev["description"]
    return body


def _rules(update: Any) -> list[dict]:
    if update is None:
        return []
    return list(update) if isinstance(update, list) else [update]


def _strips_update(update: Any, classes: list[str]) -> bool:
    if "parameter_updates" not in classes:
        return False
    rules = _rules(update)
    if not rules:
        return False
    for r in rules:
        if r.get("kind") not in ("schedule", "condition", "crossing"):
            return False
        if "expression" not in r or "from" in r or "handler" in r:
            return False
        if r["kind"] == "crossing" and "continuous_events" not in classes:
            return False
    return True


def _ns_rule(rule: dict, prefix: str, local: set[str], subs: set[str]) -> dict:
    out = dict(rule)
    for k in ("expression", "when"):
        if k in out:
            out[k] = _ns_expr(out[k], prefix, local, subs)
    return out


# ---------------------------------------------------------------------------
# Stripping a document
# ---------------------------------------------------------------------------


def _component_walk(comp: Any, prefix: str, classes, s: StrippedConstructs, counters, removed: set):
    """Collect and remove ``comp``'s events and updates (a typed
    :class:`~earthsci_ast.esm_types.Model` or
    :class:`~earthsci_ast.esm_types.ReactionSystem`), recursing into its
    subsystems; ``removed`` gathers the ids of the removed event objects."""
    from .esm_types import Model, ReactionSystem
    from .serialize import (
        _serialize_continuous_event,
        _serialize_discrete_event,
        _serialize_expression,
        _serialize_parameter_update_spec,
    )

    subs_raw = getattr(comp, "subsystems", None) or {}
    subs = set(subs_raw)
    if isinstance(comp, ReactionSystem):
        local = {sp.name for sp in comp.species} | {p.name for p in comp.parameters} | subs
        params = [(p.name, p) for p in comp.parameters]
    else:
        local = set(comp.variables) | subs
        params = [(n, v) for n, v in comp.variables.items() if v.type == "parameter"]
    for attr, evkind, ser in (
        ("continuous_events", "continuous", _serialize_continuous_event),
        ("discrete_events", "discrete", _serialize_discrete_event),
    ):
        if f"{evkind}_events" not in classes:
            continue
        for ev in getattr(comp, attr) or []:
            raw = ser(ev)
            j = counters[(prefix, evkind)] = counters.get((prefix, evkind), 0) + 1
            body = _event_body(raw, prefix, local, subs)
            body["id"] = (
                f"{prefix}.{raw['name']}" if raw.get("name") else f"{prefix}.{evkind}_event[{j}]"
            )
            body["origin"] = {"component": prefix}
            body["kind"] = evkind
            s.events.append(body)
            removed.add(id(ev))
        setattr(comp, attr, [])
    for name, var in params:
        if var.update is None:
            continue
        rules = _rules(_serialize_parameter_update_spec(var.update))
        if _strips_update(rules, classes):
            s.parameter_updates.append(
                {
                    "parameter": f"{prefix}.{name}",
                    "origin": {"component": prefix},
                    "rules": [_ns_rule(r, prefix, local, subs) for r in rules],
                }
            )
            var.update = None
    if "algebraic" in classes and isinstance(comp, Model):
        comp.equations = [
            eq for eq in comp.equations if not _strippable_implicit(_serialize_expression(eq.lhs))
        ]
    for key, sub in subs_raw.items():
        if isinstance(sub, (Model, ReactionSystem)):
            _component_walk(sub, f"{prefix}.{key}", classes, s, counters, removed)


def _strippable_implicit(lhs: Any) -> bool:
    if not is_implicit_lhs(lhs):
        return False
    body = lhs
    while isinstance(body, dict) and body.get("op") == "faq" and body.get("expr") is not None:
        body = body["expr"]
    op = body.get("op") if isinstance(body, dict) else getattr(body, "op", None)
    return op not in ("ic", "D", "grad", "div", "laplacian")


def strip_document(file: Any, classes: list[str]) -> tuple[Any, StrippedConstructs, Any]:
    """The loaded document ``file`` (an :class:`~earthsci_ast.esm_types.EsmFile`,
    its ``{ref}`` mounts resolved) with ``classes``' constructs removed, what was
    removed, and the flattened original. Residuals and ``z`` are filled by
    :func:`collect_algebraic`.

    Coupling-level events are read from the coupling sequence after
    ``coupling_import`` expansion, the one a ``{"coupling": k}`` origin indexes,
    and stay in the document, so the stripped document's coupling indices are
    the original's; the build never lowers one."""
    from .coupling_imports import expand_coupling_imports
    from .esm_types import CouplingType
    from .flatten import flatten
    from .serialize import _serialize_coupling_entry

    flat = flatten(file)
    doc = copy.deepcopy(file)
    s = StrippedConstructs(strip=list(classes))
    counters: dict = {}
    removed: set[int] = set()
    # Order: models (each followed by its subsystems), then reaction systems,
    # then coupling.
    for name, comp in (doc.models or {}).items():
        if not isinstance(comp, dict):
            _component_walk(comp, name, classes, s, counters, removed)
    for name, comp in (doc.reaction_systems or {}).items():
        if not isinstance(comp, dict):
            _component_walk(comp, name, classes, s, counters, removed)
    # The flat view of the components' events holds the same objects.
    doc.events = [ev for ev in (doc.events or []) if id(ev) not in removed]
    for k, entry in enumerate(expand_coupling_imports(file)):
        if getattr(entry, "coupling_type", None) != CouplingType.EVENT:
            continue
        evkind = "continuous" if entry.event_type == "continuous" else "discrete"
        if f"{evkind}_events" not in classes:
            continue
        raw = _serialize_coupling_entry(entry)
        prefix = f"coupling[{k}]"
        j = counters[(prefix, evkind)] = counters.get((prefix, evkind), 0) + 1
        body = _event_body(raw, None, set(), set())
        body["id"] = (
            f"{prefix}.{raw['name']}" if raw.get("name") else f"{prefix}.{evkind}_event[{j}]"
        )
        body["origin"] = {"coupling": k}
        body["kind"] = evkind
        s.events.append(body)
    # Parameter updates are listed in flattened order (API_SPEC §5.8).
    order = {n: i for i, n in enumerate(flat.parameters)}
    s.parameter_updates.sort(key=lambda u: order.get(u["parameter"], len(order)))
    return doc, s, flat


def collect_algebraic(flat: Any, s: StrippedConstructs, t0: float, params: dict) -> None:
    """The residuals of the flattened original's implicit equations, and the
    ``z`` layout of the algebraic unknowns they read."""
    from .expression import free_variables
    from .serialize import _serialize_expression

    counters: dict[str, int] = {}
    read: set[str] = set()
    for eq in flat.equations:
        if not _strippable_implicit(_serialize_expression(eq.lhs)):
            continue
        contribs = getattr(eq, "contributions", None) or []
        origin_obj = contribs[0].origins[0] if contribs and contribs[0].origins else None
        if origin_obj is not None and getattr(origin_obj, "component", None) is not None:
            origin = {"component": origin_obj.component}
            prefix = origin_obj.component
        elif origin_obj is not None:
            origin = {"coupling": origin_obj.coupling}
            prefix = f"coupling[{origin_obj.coupling}]"
        else:
            origin, prefix = {"component": ""}, ""
        j = counters[prefix] = counters.get(prefix, 0) + 1
        expr = {"op": "-", "args": [_serialize_expression(eq.lhs), _serialize_expression(eq.rhs)]}
        sets = _expr_sets(expr, flat)
        read |= set(free_variables(eq.lhs)) | set(free_variables(eq.rhs))
        s.residuals.append(
            {
                "id": f"{prefix}.residual[{j}]",
                "origin": origin,
                "shape": _set_sizes(sets, flat),
                "expr": expr,
            }
        )
    z = [n for n in flat.algebraic_variables if n in read]

    def shaped(n):
        v = flat.state_variables.get(n)
        return bool(getattr(v, "shape", None))

    z.sort(key=lambda n: (shaped(n), n))
    base = 1
    for n in z:
        sets = list(getattr(flat.state_variables[n], "shape", None) or [])
        shape = _set_sizes(sets, flat)
        s.unknowns.append(n)
        s.z_layout[n] = {"base": base, "shape": shape}
        length = max(math.prod(shape), 1) if shape else 1
        s.z0.extend(_z_start(flat, n, length, params, t0))
        base += length


def _set_sizes(sets: list[str], flat: Any) -> list[int]:
    out = []
    for name in sets:
        iset = flat.index_sets.get(name)
        size = iset.get("size") if isinstance(iset, dict) else getattr(iset, "size", None)
        out.append(int(size) if isinstance(size, (int, float)) else 0)
    return out


def _declared_sets(name: str, flat: Any) -> list[str] | None:
    for d in (flat.state_variables, flat.observed_variables, flat.parameters):
        if name in d:
            return list(getattr(d[name], "shape", None) or [])
    return None


def _expr_sets(e: Any, flat: Any) -> list[str]:
    if isinstance(e, str):
        return _declared_sets(e, flat) or []
    if not isinstance(e, dict):
        return []
    op = e.get("op")
    if op == "faq":
        out = []
        for i in e.get("output_idx") or []:
            r = (e.get("ranges") or {}).get(i)
            if not (isinstance(r, dict) and "from" in r):
                raise ValueError(f"the output range `{i}` does not name an index set")
            out.append(r["from"])
        return out
    if op == "index":
        return []
    out: list[str] = []
    for a in e.get("args") or []:
        sub = _expr_sets(a, flat)
        if not sub:
            continue
        if not out:
            out = sub
        elif out != sub:
            raise ValueError(f"operands of `{op}` range over different index sets")
    return out


def _z_start(flat: Any, name: str, length: int, params: dict, t0: float) -> list[float | None]:
    """``name``'s starting values, column-major: its ``ic`` right-hand side
    evaluated at ``t0`` with the build's parameter values, else its declared
    default; ``None`` where neither gives a finite number. Julia and Rust read
    the same values with their own build-time evaluators."""
    import numpy as np

    from .serialize import _serialize_expression
    from .simulation_array import _eval_buildtime_field

    rhs = None
    for eq in flat.equations:
        lhs = _serialize_expression(eq.lhs)
        if isinstance(lhs, dict) and lhs.get("op") == "ic" and lhs.get("args") == [name]:
            rhs = eq.rhs
            break
    if rhs is None:
        for tgt, r in getattr(flat, "field_ics", None) or []:
            if tgt == name:
                rhs = r
                break
    values = None
    if rhs is not None:
        try:
            v = _eval_buildtime_field(rhs, index_sets=flat.index_sets, param_values=params, t=t0)
            values = np.asarray(v, dtype=float).ravel(order="F").tolist()
        except Exception:  # noqa: BLE001 — an unevaluable ic falls back to the default
            values = None
    if values is None:
        d = getattr(flat.state_variables.get(name), "default", None)
        if isinstance(d, bool):
            d = None
        if isinstance(d, (int, float)):
            values = [float(d)]
        elif isinstance(d, (list, tuple)):
            try:
                values = np.asarray(d, dtype=float).ravel(order="F").tolist()
            except (TypeError, ValueError):
                values = None
    if values is None or len(values) not in (1, length):
        return [None] * length
    if len(values) == 1:
        values = values * length
    return [x if math.isfinite(x) else None for x in values]


def refuse_stripped(prob: Any, call: str) -> None:
    s = getattr(prob, "stripped", None)
    if s is not None and not s.is_empty():
        raise StrippedProblemNotSolvableError(
            f"{STRIPPED_PROBLEM_NOT_SOLVABLE}: `{call}` cannot run a Problem `strip` removed "
            f"constructs from ({', '.join(s.removed_classes())}): running it without them "
            "would report a number the document does not describe. Evaluate its right-hand "
            "side and the removed constructs with `compile_kernels`"
        )


def stripped(prob: Any) -> StrippedConstructs:
    """What ``strip`` removed from ``prob`` (API_SPEC §5.8). Empty when nothing was."""
    s = getattr(prob, "stripped", None)
    return s if s is not None else StrippedConstructs()


def is_stripped(prob: Any) -> bool:
    """Whether ``strip`` removed anything from ``prob``."""
    return not stripped(prob).is_empty()


def compile_kernels(prob: Any, specs: Any) -> Any:
    """Standalone kernels (API_SPEC §5.8) are compiled by Julia and Rust only."""
    raise CompilerUnavailableError(
        getattr(prob, "compiler", "native"),
        "`compile_kernels` has no Python implementation; build the kernels with "
        "EarthSciAST.jl or earthsci-ast (Rust)",
    )
