"""The esm 1.0.0 classification API — esm-spec §6.3.1.

The format declares exactly **two** variable types, ``unknown`` and
``parameter``. Everything finer that a solver needs is **derived**, never
declared: whether an unknown is an ODE state, an observed quantity or an
algebraic one follows from the model's ``equations``; whether a parameter is
Brownian, discrete, sampled or constant follows from its ``distribution`` and
``update``.

esm-spec §6.3.1 therefore requires every binding to expose the *same* pure
functions of a model, spelled in the language's idiom (snake_case here). This
module is that surface for the Python binding, and it is the **only** sanctioned
way to ask these questions. A site that used to branch on
``variable.type == "state"`` calls :func:`is_ode_state`; one that branched on
``"observed"`` calls :func:`observed_unknowns`; ``"brownian"`` /
``"discrete"`` call :func:`brownian_parameters` / :func:`discrete_parameters`.
Reading a declared type to answer a derived question is precisely what 1.0.0
removes.

Partitions
==========

The three unknown sets partition the model's unknowns, and the four parameter
sets partition its parameters. :func:`assert_partitions` checks both; the
package's conformance suite runs it over the whole corpus.

============================  ==========================================
``ode_states``                unknowns under ``D(·, t)`` on some equation LHS
``observed_unknowns``         unknowns defined by a bare-variable LHS
``algebraic_unknowns``        unknowns constrained only implicitly
============================  ==========================================

============================  ==========================================
``brownian_parameters``       ``update.kind == "wiener"``
``discrete_parameters``       any OTHER update
``sampled_parameters``        a ``distribution`` and no ``update``
``constant_parameters``       neither
============================  ==========================================

:func:`system_kind` derives what the optional ``system_kind`` FIELD declares,
by a four-row table tested IN ORDER, first match wins (esm-spec §6.3.1):

1. any Brownian parameter → ``"sde"``;
2. any equation contains a **spatial derivative** → ``"pde"``;
3. no time-derivative equation at all → ``"nonlinear"``;
4. otherwise → ``"ode"``.

The order is normative. ``pde`` precedes ``nonlinear`` so a steady-state PDE
(``laplacian(phi) ~ f``) is a PDE and not a nonlinear system; ``sde`` precedes
``pde`` because there is no SPDESystem constructor to select. A spatial
derivative is a ``D`` whose ``wrt`` is present and is not ``"t"``, **or** one of
the ``grad`` / ``div`` / ``laplacian`` sugar ops — both spellings count, since
neither is canonical (they are open-tier rewrite targets).

Dual representation
===================

Every function accepts EITHER a parsed :class:`~.esm_types.Model` dataclass or
the raw ``dict`` form of a model node (what ``json.load`` on a ``.esm`` yields).
The binding carries both: :mod:`.flatten` / :mod:`.validation` work on
dataclasses, :mod:`.structural_checks` / :mod:`.cadence` / :mod:`.prepare` work
on raw dicts. One derivation serving both is the point — two would be two
chances to disagree.

The cross-language oracle is ``tests/conformance/classification/``.
"""

from __future__ import annotations

from collections.abc import Iterator, Mapping
from typing import Any

from .esm_types import EXPR_WIRE_SPEC, ExprNode

__all__ = [
    "SPATIAL_DERIVATIVE_OPS",
    "SYSTEM_KINDS",
    "ClassificationError",
    "algebraic_unknowns",
    "assert_partitions",
    "brownian_parameters",
    "constant_parameters",
    "declared_system_kind",
    "discrete_parameters",
    "inlined_unknowns",
    "is_brownian_parameter",
    "is_discrete_parameter",
    "is_observed_unknown",
    "is_ode_state",
    "model_nodes",
    "observed_definitions",
    "observed_unknowns",
    "ode_states",
    "parameters",
    "sampled_parameters",
    "system_kind",
    "unknowns",
]


#: The differential-operator sugar ops that mark an equation spatial. ``D`` with
#: a non-``t`` ``wrt`` is the other spelling; both are recognized because neither
#: is canonical — the sugar ops are open-tier rewrite targets that lower to ``D``
#: only once a discretization rule fires.
#:
#: esm-spec §6.3.1 names EXACTLY these three. ``curl`` is spatial sugar too by
#: §4.2, but §6.3.1 omits it, and this set is a cross-binding contract: adding a
#: fourth op here would classify a curl-only model ``pde`` where every other
#: binding says otherwise. Matching the spec exactly is what keeps the five
#: bindings' answers identical; the omission is a question for the spec, not
#: something to paper over locally.
SPATIAL_DERIVATIVE_OPS = frozenset({"grad", "div", "laplacian"})

#: The closed set of derived system kinds (esm-spec §6.3).
SYSTEM_KINDS = ("ode", "nonlinear", "sde", "pde")

#: The independent variable a time derivative is taken with respect to. ``D``
#: with no ``wrt`` at all is read as a time derivative (the common shorthand).
_TIME = "t"

# The child-bearing ExprNode fields, as (dataclass field name, wire key, kind),
# in canonical visit order. Derived from the ONE wire-codec declaration in
# esm_types so a newly added expression-bearing field is walked automatically.
_CHILD_SPEC: tuple[tuple[str, str, str], ...] = tuple(
    (name, wire, kind)
    for name, wire, kind, _req in EXPR_WIRE_SPEC
    if kind in ("expr", "expr_list", "expr_dict")
)


class ClassificationError(Exception):
    """A model that cannot be classified (e.g. a cycle among observed
    definitions, which the DAE contract forbids)."""


# === Dual-representation accessors =========================================


def _field(obj: Any, name: str, default: Any = None) -> Any:
    """Read ``name`` off either a Mapping (raw JSON) or a dataclass."""
    if isinstance(obj, Mapping):
        return obj.get(name, default)
    value = getattr(obj, name, default)
    return default if value is None else value


def _op(node: Any) -> str | None:
    """The operator tag of an expression node, or None for a leaf."""
    if isinstance(node, Mapping):
        op = node.get("op")
        return op if isinstance(op, str) else None
    if isinstance(node, ExprNode):
        return node.op
    return None


def _args(node: Any) -> list:
    if isinstance(node, Mapping):
        args = node.get("args")
        return list(args) if isinstance(args, (list, tuple)) else []
    if isinstance(node, ExprNode):
        return list(node.args or [])
    return []


def _slot(node: Any, field_name: str, wire_key: str) -> Any:
    if isinstance(node, Mapping):
        return node.get(wire_key)
    return getattr(node, field_name, None)


def children(node: Any) -> Iterator[Any]:
    """Yield every expression-bearing child of ``node``, in canonical order,
    for BOTH the dict and the :class:`~.esm_types.ExprNode` spellings.

    This descends every Expression child — ``args``, the integral bounds, an
    aggregate ``expr`` / ``filter`` / ``key``, ``makearray`` ``values``, and the
    ``table_lookup`` axis map — not just ``args``. A spatial derivative buried in
    an aggregate body is still a spatial derivative.
    """
    if not isinstance(node, (Mapping, ExprNode)):
        return
    for name, wire, kind in _CHILD_SPEC:
        child = _slot(node, name, wire)
        if child is None:
            continue
        if kind == "expr":
            yield child
        elif kind == "expr_list":
            if isinstance(child, (list, tuple)):
                yield from child
        elif kind == "expr_dict":
            if isinstance(child, Mapping):
                for key in sorted(child):
                    yield child[key]


def walk(node: Any) -> Iterator[Any]:
    """Yield ``node`` and every descendant expression, depth first."""
    yield node
    for child in children(node):
        yield from walk(child)


def _variables(model: Any) -> dict[str, Any]:
    """The model node's ``variables`` map (name → variable, dict or dataclass)."""
    variables = _field(model, "variables", {}) or {}
    return dict(variables) if isinstance(variables, Mapping) else {}


def _equations(model: Any) -> list:
    equations = _field(model, "equations", []) or []
    return list(equations) if isinstance(equations, (list, tuple)) else []


def _var_type(var: Any) -> str | None:
    kind = _field(var, "type")
    return kind if isinstance(kind, str) else None


def _update(var: Any) -> Any:
    """A parameter's ``update``: one rule (Mapping / ``ParameterUpdate``), an
    ordered list of ≥2 rules, or None."""
    return _field(var, "update")


def _distribution(var: Any) -> Any:
    return _field(var, "distribution")


# === Unknowns ==============================================================


def unknowns(model: Any) -> list[str]:
    """Every variable declared ``type: "unknown"``, sorted."""
    return sorted(n for n, v in _variables(model).items() if _var_type(v) == "unknown")


def parameters(model: Any) -> list[str]:
    """Every variable declared ``type: "parameter"``, sorted."""
    return sorted(n for n, v in _variables(model).items() if _var_type(v) == "parameter")


def _base_name(expr: Any) -> str | None:
    """The variable an LHS position ultimately names: a bare string is itself,
    ``index(u, …)`` is ``u``. Anything else has no single base name."""
    if isinstance(expr, str):
        return expr
    op = _op(expr)
    if op == "index":
        args = _args(expr)
        return _base_name(args[0]) if args else None
    return None


def _is_time_derivative(node: Any) -> bool:
    """``D(·)`` with no ``wrt``, or ``wrt == "t"``."""
    if _op(node) != "D":
        return False
    wrt = _slot(node, "wrt", "wrt")
    return wrt is None or wrt == _TIME


def _is_spatial_derivative(node: Any) -> bool:
    """A spatial differential operator in either admissible spelling: a ``D``
    whose ``wrt`` is PRESENT and is not ``"t"``, or one of the ``grad`` / ``div``
    / ``laplacian`` sugar ops (esm-spec §6.3.1)."""
    op = _op(node)
    if op in SPATIAL_DERIVATIVE_OPS:
        return True
    if op != "D":
        return False
    wrt = _slot(node, "wrt", "wrt")
    return wrt is not None and wrt != _TIME


def _derivative_targets(lhs: Any) -> set[str]:
    """The base variables credited as ODE states by one equation LHS.

    A derivative LHS may be wrapped: ``D(u)``, ``D(u[i])``, and an ``aggregate``
    whose ``expr`` is a ``D(...)`` (the arrayed per-cell ODE form) all credit the
    base variable.
    """
    if _is_time_derivative(lhs):
        return {name for name in (_base_name(a) for a in _args(lhs)) if name}
    if _op(lhs) == "aggregate":
        inner = _slot(lhs, "expr", "expr")
        return _derivative_targets(inner) if inner is not None else set()
    return set()


def _lhs(equation: Any) -> Any:
    return _field(equation, "lhs")


def _rhs(equation: Any) -> Any:
    return _field(equation, "rhs")


def is_initial_condition(equation: Any) -> bool:
    """True for an ``ic(x) ~ v`` equation. An initial condition pins a value at
    t=0; it neither defines an unknown nor participates in the §4.9.4 balance."""
    return _op(_lhs(equation)) == "ic"


def ode_states(model: Any) -> list[str]:
    """Unknowns appearing under ``D(·, t)`` on some equation LHS (esm-spec
    §6.3.1), sorted."""
    declared = set(unknowns(model))
    found: set[str] = set()
    for equation in _equations(model):
        found |= _derivative_targets(_lhs(equation))
    return sorted(found & declared)


def is_ode_state(model: Any, name: str) -> bool:
    """Membership test for :func:`ode_states` — the replacement for every
    ``variable.type == "state"`` branch."""
    declared = _variables(model).get(name)
    if declared is None or _var_type(declared) != "unknown":
        return False
    return any(name in _derivative_targets(_lhs(eq)) for eq in _equations(model))


def observed_definitions(model: Any, bare_only: bool = False) -> dict[str, Any]:
    """Map each observed unknown to its DEFINING equation's RHS.

    An observed unknown is one an equation defines with a bare-variable LHS.
    Before 1.0.0 this lived in ``variables[v].expression``; it now lives in the
    model's ``equations``, and this function is where the binding follows that
    relocation. The FIRST defining equation wins, so classification does not
    depend on equation order for the *set* it returns.

    An indexed LHS (``y[i] ~ f(i)``, the arrayed-observed form) defines its base
    array, so it is credited here too: its cadence must resolve through its RHS
    exactly as a scalar observed's does, and refusing to credit it would seed a
    const-backed geometry array CONTINUOUS and stop it folding. Pass
    ``bare_only`` to restrict to the strict ``y ~ f(…)`` form — see
    :func:`inlined_unknowns` for what that distinction is for.
    """
    declared = set(unknowns(model))
    states = set(ode_states(model))
    definitions: dict[str, Any] = {}
    for equation in _equations(model):
        if is_initial_condition(equation):
            continue
        lhs = _lhs(equation)
        if bare_only and not isinstance(lhs, str):
            continue
        name = _base_name(lhs)
        if name is None or name not in declared or name in states:
            continue
        definitions.setdefault(name, _rhs(equation))
    return definitions


def inlined_unknowns(model: Any) -> list[str]:
    """The observed unknowns whose defining LHS is a BARE VARIABLE, sorted.

    This is the strict ``y ~ f(…)`` form of esm-spec §6.3.1, and it is the one
    that is *eliminable by inlining*: the definition is substituted into its
    consumers and the unknown contributes no output of its own. An ARRAYED
    definition (``y[i] ~ f(i)``) is observed too — :func:`observed_definitions`
    credits it, so its cadence still resolves through its RHS — but it
    materializes into a buffer its consumers index rather than being inlined,
    which is why the cadence pass reports it as an output buffer and this set
    does not include it.
    """
    return sorted(n for n, _rhs in observed_definitions(model, bare_only=True).items())


def observed_unknowns(model: Any) -> list[str]:
    """Unknowns defined by a bare-variable LHS (``y ~ f(…)``) — eliminable,
    materializable (esm-spec §6.3.1), sorted."""
    return sorted(observed_definitions(model))


def is_observed_unknown(model: Any, name: str) -> bool:
    """Membership test for :func:`observed_unknowns`."""
    return name in observed_definitions(model)


def algebraic_unknowns(model: Any) -> list[str]:
    """Unknowns constrained only implicitly (``H*H*SO4 ~ Ksp``), sorted.

    Defined as the complement, which is what makes the three sets a partition by
    construction rather than by coincidence.
    """
    return sorted(set(unknowns(model)) - set(ode_states(model)) - set(observed_definitions(model)))


# === Parameters ============================================================


def _update_rules(var: Any) -> list[Any]:
    """A parameter's update rules as a list: ``[]`` for no update, ``[rule]`` for
    the single-rule object form, and the rules themselves for the array form."""
    update = _update(var)
    if update is None:
        return []
    if isinstance(update, (list, tuple)):
        return list(update)
    return [update]


def _update_kind(rule: Any) -> str | None:
    kind = _field(rule, "kind")
    return kind if isinstance(kind, str) else None


def _is_parameter(model: Any, name: str) -> bool:
    var = _variables(model).get(name)
    return var is not None and _var_type(var) == "parameter"


def is_brownian_parameter(model: Any, name: str) -> bool:
    """Membership test for :func:`brownian_parameters`."""
    if not _is_parameter(model, name):
        return False
    return any(_update_kind(r) == "wiener" for r in _update_rules(_variables(model)[name]))


def brownian_parameters(model: Any) -> list[str]:
    """Parameters whose ``update.kind`` is ``"wiener"`` — the SDE noise sources
    (esm-spec §6.3.1), sorted.

    With an update ARRAY a parameter is Brownian iff ANY rule is ``wiener``. The
    schema forbids ``wiener`` inside an array (a driving noise process is the
    parameter's whole value), so in practice an array means discrete; the test is
    written over all the rules anyway rather than assuming the schema held.
    """
    return sorted(n for n in parameters(model) if is_brownian_parameter(model, n))


def is_discrete_parameter(model: Any, name: str) -> bool:
    """Membership test for :func:`discrete_parameters`."""
    if not _is_parameter(model, name):
        return False
    rules = _update_rules(_variables(model)[name])
    return bool(rules) and not any(_update_kind(r) == "wiener" for r in rules)


def discrete_parameters(model: Any) -> list[str]:
    """Parameters carrying any update OTHER than ``wiener`` — piecewise-constant
    between refreshes (esm-spec §6.3.1), sorted."""
    return sorted(n for n in parameters(model) if is_discrete_parameter(model, n))


def sampled_parameters(model: Any) -> list[str]:
    """Parameters with a ``distribution`` and no ``update`` — drawn once at
    setup (esm-spec §6.3.1), sorted."""
    variables = _variables(model)
    return sorted(
        n
        for n in parameters(model)
        if _distribution(variables[n]) is not None and not _update_rules(variables[n])
    )


def constant_parameters(model: Any) -> list[str]:
    """Parameters with neither a ``distribution`` nor an ``update`` — plain
    constants (esm-spec §6.3.1), sorted."""
    variables = _variables(model)
    return sorted(
        n
        for n in parameters(model)
        if _distribution(variables[n]) is None and not _update_rules(variables[n])
    )


# === System kind ===========================================================


def _has_time_derivative_equation(model: Any) -> bool:
    return any(_derivative_targets(_lhs(eq)) for eq in _equations(model))


def _has_spatial_derivative(model: Any) -> bool:
    """True if ANY equation contains a spatial derivative anywhere in its LHS or
    RHS, descending every Expression child."""
    for equation in _equations(model):
        for side in (_lhs(equation), _rhs(equation)):
            if any(_is_spatial_derivative(node) for node in walk(side)):
                return True
    return False


def system_kind(model: Any) -> str:
    """Derive the model's MTK system kind (esm-spec §6.3.1).

    Four rows tested IN ORDER, first match wins — the order is normative:

    1. any Brownian parameter → ``"sde"`` (there is no SPDESystem, so this wins
       even over a spatial derivative);
    2. any spatial derivative in any equation → ``"pde"``;
    3. no time-derivative equation at all → ``"nonlinear"``;
    4. otherwise → ``"ode"``.

    A binding uses this derivation whenever the ``system_kind`` FIELD is absent,
    and reports ``system_kind_mismatch`` when a present field contradicts it.
    """
    if brownian_parameters(model):
        return "sde"
    if _has_spatial_derivative(model):
        return "pde"
    if not _has_time_derivative_equation(model):
        return "nonlinear"
    return "ode"


def declared_system_kind(model: Any) -> str | None:
    """The model's explicit ``system_kind`` field, or None when absent. Compare
    against :func:`system_kind` to detect ``system_kind_mismatch``."""
    declared = _field(model, "system_kind")
    return declared if isinstance(declared, str) else None


# === Partition assertion + document traversal ==============================


def assert_partitions(model: Any) -> None:
    """Assert the §6.3.1 invariant: the three unknown sets partition the
    unknowns and the four parameter sets partition the parameters, disjointly
    and exhaustively. Raises :class:`ClassificationError` otherwise.

    The spec states these ARE partitions; a binding that derives rather than
    declares them can break the property silently, so it is checked rather than
    assumed.
    """
    for label, whole, parts in (
        (
            "unknowns",
            set(unknowns(model)),
            (ode_states(model), observed_unknowns(model), algebraic_unknowns(model)),
        ),
        (
            "parameters",
            set(parameters(model)),
            (
                brownian_parameters(model),
                discrete_parameters(model),
                sampled_parameters(model),
                constant_parameters(model),
            ),
        ),
    ):
        seen: set[str] = set()
        for part in parts:
            overlap = seen & set(part)
            if overlap:
                raise ClassificationError(
                    f"the {label} sets are not disjoint: {sorted(overlap)} appears twice"
                )
            seen |= set(part)
        if seen != whole:
            raise ClassificationError(
                f"the {label} sets do not cover the {label}: "
                f"missing={sorted(whole - seen)}, extra={sorted(seen - whole)}"
            )


def model_nodes(document: Any, _prefix: str = "") -> Iterator[tuple[str, Any]]:
    """Yield ``(dot_path, model_node)`` for every model in a document, INCLUDING
    nested subsystems, so classification can be reported per model node.

    Classification is a property of one model node. A binding that flattens the
    document first and classifies once returns a single merged answer, which the
    ``subsystem_scope`` conformance fixture rejects.
    """
    models = _field(document, "models", {}) or {}
    if isinstance(models, Mapping):
        for name, model in models.items():
            path = f"{_prefix}{name}"
            yield path, model
            yield from _subsystem_nodes(model, f"{path}.")


def _subsystem_nodes(model: Any, prefix: str) -> Iterator[tuple[str, Any]]:
    subsystems = _field(model, "subsystems", {}) or {}
    if not isinstance(subsystems, Mapping):
        return
    for name, sub in subsystems.items():
        # A `{"ref": ...}` placeholder is not a model node until it is resolved,
        # and a data source is not a component at all from 1.0.0.
        if isinstance(sub, Mapping) and set(sub) <= {"ref"}:
            continue
        if not (_field(sub, "variables") or _field(sub, "equations")):
            continue
        path = f"{prefix}{name}"
        yield path, sub
        yield from _subsystem_nodes(sub, f"{path}.")
