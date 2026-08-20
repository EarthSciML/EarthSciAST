"""
ESM Format serialization module.

This module provides functions to serialize ESM format objects to JSON,
with optional file writing capability.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

from .esm_types import (
    EXPR_WIRE_SPEC,
    Analysis,
    Assertion,
    CallbackCoupling,
    ContinuousEvent,
    CouplingCouple,
    CouplingEntry,
    CouplingImport,
    DataSource,
    DataSourceBinding,
    DataSourceDeterminism,
    DataSourceLocation,
    DataSourceTemporal,
    Distribution,
    DiscreteEvent,
    DiscreteEventTrigger,
    Domain,
    Equation,
    EsmFile,
    EventCoupling,
    Expr,
    ExprNode,
    Metadata,
    Model,
    ModelVariable,
    Operator,
    OperatorApplyCoupling,
    OperatorComposeCoupling,
    Parameter,
    ParameterSweep,
    Plot,
    PlotAxis,
    PlotSeries,
    PlotValue,
    Reaction,
    ReactionSystem,
    Reference,
    Species,
    SweepDimension,
    SweepRange,
    Test,
    TimeSpan,
    Tolerance,
    VariableMapCoupling,
)
from .json_walk import _is_array, _is_object


def _emit_stoich(coeff: int | float) -> int | float:
    """Emit a stoichiometric coefficient preserving integer-vs-float distinction.

    Integer values (either `int` or integer-valued `float`) are emitted as `int`
    so existing integer-only fixtures stay byte-identical through a parse /
    re-emit cycle. Fractional coefficients like `0.87` are emitted as `float`.
    """
    if isinstance(coeff, bool):
        return int(coeff)
    if isinstance(coeff, int):
        return coeff
    if isinstance(coeff, float) and math.isfinite(coeff) and coeff.is_integer():
        return int(coeff)
    return float(coeff)


#: JSON canonical-number contract (CONFORMANCE_SPEC §5.5.3.1): an integral value
#: is emitted as an integer literal only when it fits a signed 64-bit integer.
_INT64_MIN = -(2**63)
_INT64_MAX = 2**63 - 1


def _canonical_number(value: Any) -> Any:
    """Canonicalize a JSON scalar per CONFORMANCE_SPEC §5.5.3.1.

    A number whose value is integral and fits Int64 serializes as an INTEGER
    literal — no trailing ``.0`` — regardless of how it was spelled (``0.0`` ->
    ``0``, ``-696723.0`` -> ``-696723``), so every binding re-serializes it
    byte-identically. Non-integral floats, out-of-range magnitudes, non-finite
    values, strings and ``bool`` pass through unchanged (a ``bool`` is not a JSON
    number here).
    """
    if isinstance(value, bool) or not isinstance(value, float):
        return value
    if math.isfinite(value) and value.is_integer() and _INT64_MIN <= value <= _INT64_MAX:
        return int(value)
    return value


def _canonical_nested(value: Any) -> Any:
    """Apply :func:`_canonical_number` to every scalar in a (possibly nested)
    list — the integer descriptor arrays of array ops (``shape`` / ``regions`` /
    ``ranges`` / ``perm``), i.e. the reshape / makearray / aggregate bodies the
    §5.5.3.1 rule applies inside. Strings (e.g. a metaparameter symbol in an
    unresolved library range) are left untouched.
    """
    if isinstance(value, list):
        return [_canonical_nested(v) for v in value]
    return _canonical_number(value)


# ---------------------------------------------------------------------------
# Spec-driven driver for the purely-mechanical per-type serializers (field-copy
# + omit-if-None/falsy mirrors). Each such type declares ONE authored ordered
# ``(attr, wire_key, omit, codec)`` spec — the pinned wire key ORDER and omit
# policy — and delegates to :func:`_serialize_by_spec`. Genuinely-bespoke
# serializers (discriminated unions, reactions, coupling entries, the event
# affect folders, the esm_file orchestration, and the few types with per-field
# branch logic) stay hand-written.
# ---------------------------------------------------------------------------

#: Always emit the field (even when its value is None / empty).
_KEEP = "keep"
#: Omit the field when its value is exactly ``None``.
_OMIT_NONE = "none"
#: Omit the field when its value is falsy (empty list/dict/str, 0, None).
_OMIT_FALSY = "falsy"


def _serialize_by_spec(obj: Any, spec: tuple) -> dict[str, Any]:
    """Serialize ``obj`` to a dict from an authored ordered field ``spec``.

    ``spec`` is an ordered sequence of ``(attr, wire_key, omit, codec)`` tuples;
    keys are inserted in list order (the byte-pinned wire order). ``codec`` (or
    ``None`` for identity) maps the raw attribute value to its JSON form. ``omit``
    is one of :data:`_KEEP` / :data:`_OMIT_NONE` / :data:`_OMIT_FALSY`.
    """
    result: dict[str, Any] = {}
    for attr, wire, omit, codec in spec:
        value = getattr(obj, attr)
        if omit == _OMIT_NONE and value is None:
            continue
        if omit == _OMIT_FALSY and not value:
            continue
        result[wire] = codec(value) if codec is not None else value
    return result


def _json_deepcopy(value: Any) -> Any:
    """Deep-copy an authored passthrough blob by round-tripping through JSON —
    the emit form the hand-written serializers used for
    ``expression_template_imports``."""
    return json.loads(json.dumps(value))


def _serialize_expression(expr: Expr) -> int | float | str | dict[str, Any]:
    """Serialize an expression to JSON-compatible format.

    ExprNode fields are emitted in the authored wire order pinned by
    :data:`~earthsci_ast.esm_types.EXPR_WIRE_SPEC` — the single declaration site
    — applying each field's codec: ``scalar`` passthrough, ``canonical_nested``
    integer-array canonicalization (``shape`` / ``regions`` / ``ranges`` /
    ``perm``, per CONFORMANCE_SPEC §5.5.3.1), and recursive serialization for the
    ``expr`` / ``expr_list`` / ``expr_dict`` child slots (``lower``/``upper``/
    ``expr``/``filter``/``key``; ``args``/``values``; ``table_axes`` under wire
    key ``axes``). ``op``/``args`` are always emitted; every other field is
    omitted when None so nodes round-trip byte-identically.
    """
    if isinstance(expr, (int, float, str)):
        return _canonical_number(expr)
    if isinstance(expr, ExprNode):
        result: dict[str, Any] = {}
        for name, wire, kind, required in EXPR_WIRE_SPEC:
            value = getattr(expr, name)
            if value is None and not required:
                continue
            if kind == "scalar":
                result[wire] = value
            elif kind == "canonical_nested":
                result[wire] = _canonical_nested(value)
            elif kind == "expr":
                result[wire] = _serialize_expression(value)
            elif kind == "expr_list":
                result[wire] = [_serialize_expression(v) for v in value]
            elif kind == "expr_dict":
                result[wire] = {k: _serialize_expression(v) for k, v in value.items()}
            else:  # pragma: no cover - guarded by the esm_types wire-spec build
                raise ValueError(f"unknown ExprNode codec kind {kind!r} for field {name!r}")
        return result
    raise ValueError(f"Invalid expression type: {type(expr)}")


def _serialize_equation(equation: Equation) -> dict[str, Any]:
    """Serialize an equation to JSON-compatible format."""
    result = {
        "lhs": _serialize_expression(equation.lhs),
        "rhs": _serialize_expression(equation.rhs),
    }
    if equation._comment is not None:
        result["_comment"] = equation._comment
    return result


def _serialize_affect_equation(affect) -> dict[str, Any]:
    """Serialize an affect equation. From 1.0.0 an event affects UNKNOWNS ONLY,
    so there is no functional-affect branch: a handler lives on the parameter it
    writes, as that parameter's ``update.handler``."""
    return {"lhs": affect.lhs, "rhs": _serialize_expression(affect.rhs)}


#: Per-kind wire order for a `distribution`. Only the slots belonging to the
#: declared kind are emitted, so a normal never grows a `low` on the way out.
_DISTRIBUTION_SPEC_BY_KIND = {
    "normal": ("mean", "std", "cov"),
    "lognormal": ("mu", "sigma", "cov"),
    "uniform": ("low", "high"),
}


def _serialize_distribution(distribution: Distribution) -> dict[str, Any]:
    """Serialize a parameter's `distribution` (esm-spec §5.4)."""
    result: dict[str, Any] = {"kind": distribution.kind}
    for attr in _DISTRIBUTION_SPEC_BY_KIND.get(distribution.kind, ()):
        value = getattr(distribution, attr, None)
        if value is not None:
            result[attr] = value
    return result


_DATA_SOURCE_BINDING_SPEC = (
    ("file_variable", "file_variable", _KEEP, None),
    ("unit_conversion", "unit_conversion", _OMIT_NONE, _serialize_expression),
    ("codes", "codes", _OMIT_NONE, None),
    ("select", "select", _OMIT_NONE, None),
    ("description", "description", _OMIT_NONE, None),
    ("reference", "reference", _OMIT_NONE, None),  # codec patched in below
)


def _serialize_data_source_binding(binding: DataSourceBinding) -> dict[str, Any]:
    """Serialize an update's `from` binding (esm-spec §8.5). `unit_conversion`
    goes through the ordinary Expression codec, which renders a bare number as
    a number and an operator node as a node."""
    result = _serialize_by_spec(binding, _DATA_SOURCE_BINDING_SPEC)
    if binding.reference is not None:
        result["reference"] = _serialize_reference(binding.reference)
    return result


_FUNCTIONAL_UPDATE_SPEC = (
    ("handler_id", "handler_id", _KEEP, None),
    ("read_vars", "read_vars", _OMIT_FALSY, list),
    ("read_params", "read_params", _OMIT_FALSY, list),
    ("config", "config", _OMIT_FALSY, dict),
)


def _serialize_functional_update(handler) -> dict[str, Any]:
    """Serialize an update's registered `handler` (esm-spec §5.4)."""
    return _serialize_by_spec(handler, _FUNCTIONAL_UPDATE_SPEC)


#: Per-kind wire order for a `ParameterUpdate`, as (attr, wire key, codec).
#: The trailing value form (expression / from / handler) is common to every kind
#: but `wiener`, which takes none, so it is emitted separately below. `when` is
#: an EXPRESSION, not a scalar -- emitting it verbatim leaves an ExprNode in the
#: dict and `json.dumps` fails on the way out.
_UPDATE_SPEC_BY_KIND = {
    "wiener": (),
    "schedule": (
        ("times", "times", None),
        ("interval", "interval", None),
        ("initial_offset", "initial_offset", None),
    ),
    "condition": (("when", "when", _serialize_expression),),
    "crossing": (
        ("when", "when", _serialize_expression),
        ("direction", "direction", None),
    ),
    "data": (("source", "source", None),),
    "remesh": (("hook", "hook", None),),
}


def _serialize_parameter_update(update) -> dict[str, Any]:
    """Serialize ONE parameter update rule (esm-spec §5.4)."""
    result: dict[str, Any] = {"kind": update.kind}
    for attr, wire, codec in _UPDATE_SPEC_BY_KIND.get(update.kind, ()):
        value = getattr(update, attr, None)
        if value is not None:
            result[wire] = codec(value) if codec is not None else value
    if update.kind == "wiener":
        return result
    if update.expression is not None:
        result["expression"] = _serialize_expression(update.expression)
    if update.from_source is not None:
        result["from"] = _serialize_data_source_binding(update.from_source)
    if update.handler is not None:
        result["handler"] = _serialize_functional_update(update.handler)
    return result


def _serialize_parameter_update_spec(update) -> Any:
    """Serialize a parameter's `update`: one rule, or an ordered list of >= 2.
    The two spellings stay distinct — a one-element list is not a legal
    document, so round-tripping a single rule must not produce one."""
    if isinstance(update, list):
        return [_serialize_parameter_update(rule) for rule in update]
    return _serialize_parameter_update(update)


_MODEL_VARIABLE_SPEC = (
    ("type", "type", _KEEP, None),
    ("units", "units", _OMIT_NONE, None),
    ("default", "default", _OMIT_NONE, None),
    ("default_units", "default_units", _OMIT_NONE, None),
    ("description", "description", _OMIT_NONE, None),
    ("shape", "shape", _OMIT_NONE, list),
    ("location", "location", _OMIT_NONE, None),
    ("distribution", "distribution", _OMIT_NONE, _serialize_distribution),
    ("update", "update", _OMIT_NONE, _serialize_parameter_update_spec),
)


def _serialize_model_variable(variable: ModelVariable) -> dict[str, Any]:
    """Serialize a model variable to JSON-compatible format."""
    return _serialize_by_spec(variable, _MODEL_VARIABLE_SPEC)


def _serialize_discrete_event_trigger(trigger: DiscreteEventTrigger) -> dict[str, Any]:
    """Serialize a discrete event trigger to JSON-compatible format."""
    result = {"type": trigger.type}

    if trigger.type == "condition":
        result["expression"] = _serialize_expression(trigger.value)
    elif trigger.type == "periodic":
        result["interval"] = trigger.value
    elif trigger.type == "preset_times":
        result["times"] = trigger.value

    return result


def _serialize_continuous_event(event: ContinuousEvent) -> dict[str, Any]:
    """Serialize a continuous event to JSON-compatible format."""
    result = {
        "conditions": [_serialize_expression(cond) for cond in event.conditions],
    }
    if event.name:
        result["name"] = event.name
    result["affects"] = [_serialize_affect_equation(a) for a in event.affects]
    if event.priority != 0:
        result["priority"] = event.priority

    if event.affect_neg is not None:
        result["affect_neg"] = [_serialize_affect_equation(affect) for affect in event.affect_neg]
    if event.root_find and event.root_find != "left":  # Only include if not default
        result["root_find"] = event.root_find
    if event.reinitialize:  # Only include if True (not default False)
        result["reinitialize"] = event.reinitialize
    if event.description:
        result["description"] = event.description

    return result


def _serialize_discrete_event(event: DiscreteEvent) -> dict[str, Any]:
    """Serialize a discrete event to JSON-compatible format."""
    result = {
        "trigger": _serialize_discrete_event_trigger(event.trigger),
    }
    if event.name:
        result["name"] = event.name
    result["affects"] = [_serialize_affect_equation(a) for a in event.affects]
    if event.priority != 0:
        result["priority"] = event.priority
    if event.reinitialize:
        result["reinitialize"] = event.reinitialize
    if event.description:
        result["description"] = event.description

    return result


_TOLERANCE_SPEC = (
    ("abs", "abs", _OMIT_NONE, None),
    ("rel", "rel", _OMIT_NONE, None),
)


def _serialize_tolerance(t: Tolerance) -> dict[str, Any]:
    return _serialize_by_spec(t, _TOLERANCE_SPEC)


_TIME_SPAN_SPEC = (
    ("start", "start", _KEEP, None),
    ("end", "end", _KEEP, None),
)


def _serialize_time_span(ts: TimeSpan) -> dict[str, Any]:
    return _serialize_by_spec(ts, _TIME_SPAN_SPEC)


def _serialize_assertion(a: Assertion) -> dict[str, Any]:
    result: dict[str, Any] = {
        "variable": a.variable,
        "time": a.time,
        "expected": a.expected,
    }
    if a.tolerance is not None:
        result["tolerance"] = _serialize_tolerance(a.tolerance)
    if a.coords is not None:
        result["coords"] = dict(a.coords)
    if a.reduce is not None:
        result["reduce"] = a.reduce
    if a.reference is not None:
        # from_file dicts round-trip verbatim; anything else is an Expression
        # AST (mirrors the Julia binding's serialize_assertion).
        if isinstance(a.reference, dict):
            result["reference"] = dict(a.reference)
        else:
            result["reference"] = _serialize_expression(a.reference)
    return result


# Authored WIRE ORDER (differs from dataclass field order): id, description,
# initial_conditions, parameter_overrides, time_span, tolerance,
# expression_template_imports, assertions. ``expression_template_imports``
# (esm-spec §9.7.10 form C) are authored per-run config that DO survive parse →
# emit, deep-copied via JSON; ``assertions`` is always emitted.
_TEST_SPEC = (
    ("id", "id", _KEEP, None),
    ("description", "description", _OMIT_NONE, None),
    ("initial_conditions", "initial_conditions", _OMIT_FALSY, dict),
    ("parameter_overrides", "parameter_overrides", _OMIT_FALSY, dict),
    ("time_span", "time_span", _KEEP, _serialize_time_span),
    ("tolerance", "tolerance", _OMIT_NONE, _serialize_tolerance),
    ("expression_template_imports", "expression_template_imports", _OMIT_FALSY, _json_deepcopy),
    ("assertions", "assertions", _KEEP, lambda a: [_serialize_assertion(x) for x in a]),
)


def _serialize_test(t: Test) -> dict[str, Any]:
    return _serialize_by_spec(t, _TEST_SPEC)


_PLOT_AXIS_SPEC = (
    ("variable", "variable", _KEEP, None),
    ("label", "label", _OMIT_NONE, None),
)


def _serialize_plot_axis(axis: PlotAxis) -> dict[str, Any]:
    return _serialize_by_spec(axis, _PLOT_AXIS_SPEC)


_PLOT_VALUE_SPEC = (
    ("variable", "variable", _KEEP, None),
    ("at_time", "at_time", _OMIT_NONE, None),
    ("reduce", "reduce", _OMIT_NONE, None),
)


def _serialize_plot_value(v: PlotValue) -> dict[str, Any]:
    return _serialize_by_spec(v, _PLOT_VALUE_SPEC)


_PLOT_SERIES_SPEC = (
    ("name", "name", _KEEP, None),
    ("variable", "variable", _KEEP, None),
)


def _serialize_plot_series(s: PlotSeries) -> dict[str, Any]:
    return _serialize_by_spec(s, _PLOT_SERIES_SPEC)


_PLOT_SPEC = (
    ("id", "id", _KEEP, None),
    ("type", "type", _KEEP, None),
    ("description", "description", _OMIT_NONE, None),
    ("x", "x", _KEEP, _serialize_plot_axis),
    ("y", "y", _KEEP, _serialize_plot_axis),
    ("value", "value", _OMIT_NONE, _serialize_plot_value),
    ("series", "series", _OMIT_FALSY, lambda ss: [_serialize_plot_series(s) for s in ss]),
)


def _serialize_plot(p: Plot) -> dict[str, Any]:
    return _serialize_by_spec(p, _PLOT_SPEC)


_SWEEP_RANGE_SPEC = (
    ("start", "start", _KEEP, None),
    ("stop", "stop", _KEEP, None),
    ("count", "count", _KEEP, None),
    ("scale", "scale", _OMIT_NONE, None),
)


def _serialize_sweep_range(r: SweepRange) -> dict[str, Any]:
    return _serialize_by_spec(r, _SWEEP_RANGE_SPEC)


_SWEEP_DIMENSION_SPEC = (
    ("parameter", "parameter", _KEEP, None),
    ("values", "values", _OMIT_NONE, list),
    ("range", "range", _OMIT_NONE, _serialize_sweep_range),
)


def _serialize_sweep_dimension(d: SweepDimension) -> dict[str, Any]:
    return _serialize_by_spec(d, _SWEEP_DIMENSION_SPEC)


_PARAMETER_SWEEP_SPEC = (
    ("type", "type", _KEEP, None),
    ("dimensions", "dimensions", _KEEP, lambda ds: [_serialize_sweep_dimension(d) for d in ds]),
)


def _serialize_parameter_sweep(ps: ParameterSweep) -> dict[str, Any]:
    return _serialize_by_spec(ps, _PARAMETER_SWEEP_SPEC)


# Authored WIRE ORDER: id, description, initial_state, parameters, time_span,
# parameter_sweep, plots, expression_template_imports. ``initial_state`` is a
# scalar override map {var: number} (v0.8.0); ``expression_template_imports``
# (esm-spec §9.7.10 form C) survive parse → emit, deep-copied via JSON.
_ANALYSIS_SPEC = (
    ("id", "id", _KEEP, None),
    ("description", "description", _OMIT_NONE, None),
    ("initial_state", "initial_state", _OMIT_NONE, dict),
    ("parameters", "parameters", _OMIT_FALSY, dict),
    ("time_span", "time_span", _KEEP, _serialize_time_span),
    ("parameter_sweep", "parameter_sweep", _OMIT_NONE, _serialize_parameter_sweep),
    ("plots", "plots", _OMIT_FALSY, lambda ps: [_serialize_plot(p) for p in ps]),
    ("expression_template_imports", "expression_template_imports", _OMIT_FALSY, _json_deepcopy),
)


def _serialize_analysis(a: Analysis) -> dict[str, Any]:
    return _serialize_by_spec(a, _ANALYSIS_SPEC)


def _serialize_model(model: Model) -> dict[str, Any]:
    """Serialize a model to JSON-compatible format."""
    result = {}

    # Serialize variables (required by schema)
    result["variables"] = {}
    if model.variables:
        result["variables"] = {
            name: _serialize_model_variable(var) for name, var in model.variables.items()
        }

    # Serialize equations (required by schema)
    result["equations"] = []
    if model.equations:
        result["equations"] = [_serialize_equation(eq) for eq in model.equations]

    # Boundary conditions are not a declared model concern (no `bc` op, no
    # `boundary_conditions` field); they live in discretization rewrite rules
    # (esm-spec §9.6.8). Nothing to serialize here.

    # Inline tests, analyses, and model-level tolerance (esm-spec §6.6 / §6.7).
    if model.tolerance is not None:
        tol = _serialize_tolerance(model.tolerance)
        if tol:
            result["tolerance"] = tol
    if model.tests:
        result["tests"] = [_serialize_test(t) for t in model.tests]
    if model.analyses:
        result["analyses"] = [_serialize_analysis(a) for a in model.analyses]

    # Initialization-only equations and solver guesses (gt-ebuq).
    if model.initialization_equations:
        result["initialization_equations"] = [
            _serialize_equation(eq) for eq in model.initialization_equations
        ]
    if model.guesses:
        guesses_out: dict[str, Any] = {}
        for var_name, seed in model.guesses.items():
            if isinstance(seed, (int, float)) and not isinstance(seed, bool):
                guesses_out[var_name] = seed
            else:
                guesses_out[var_name] = _serialize_expression(seed)
        result["guesses"] = guesses_out
    if model.system_kind is not None:
        result["system_kind"] = model.system_kind

    # Component-owned events (the schema nests events inside components).
    if model.continuous_events:
        result["continuous_events"] = [
            _serialize_continuous_event(ev) for ev in model.continuous_events
        ]
    if model.discrete_events:
        result["discrete_events"] = [_serialize_discrete_event(ev) for ev in model.discrete_events]

    # Subsystems (esm-spec §4.7). A resolved subsystem round-trips as the
    # instantiated inline component; an unresolved `{ref, bindings?}` dict
    # round-trips verbatim — metaparameter bindings at the subsystem edge
    # (esm-spec §9.7.6 site 3) survive only while the ref is unresolved.
    if model.subsystems:
        result["subsystems"] = {
            name: _serialize_subsystem(sub) for name, sub in model.subsystems.items()
        }

    return result


def _serialize_subsystem(sub: Any) -> dict[str, Any]:
    """Serialize one entry of a ``subsystems`` map: an inline Model /
    ReactionSystem, or an unresolved ``{ref, bindings?}`` dict carried verbatim
    (deep-copied). A data source is not a component and cannot appear here."""
    if isinstance(sub, dict):
        return json.loads(json.dumps(sub))
    if isinstance(sub, Model):
        return _serialize_model(sub)
    if isinstance(sub, ReactionSystem):
        return _serialize_reaction_system(sub)
    raise ValueError(f"Invalid subsystem type: {type(sub)}")


# ``name`` is not emitted — it is the map key in the enclosing reaction system.
_SPECIES_SPEC = (
    ("units", "units", _OMIT_NONE, None),
    ("default", "default", _OMIT_NONE, None),
    ("default_units", "default_units", _OMIT_NONE, None),
    ("description", "description", _OMIT_NONE, None),
    ("constant", "constant", _OMIT_NONE, None),
)


def _serialize_species(species: Species) -> dict[str, Any]:
    """Serialize a species to JSON-compatible format."""
    return _serialize_by_spec(species, _SPECIES_SPEC)


def _serialize_parameter(parameter: Parameter) -> dict[str, Any]:
    """Serialize a parameter to JSON-compatible format."""
    result = {}
    if parameter.units is not None:
        result["units"] = parameter.units
    if parameter.default_units is not None:
        result["default_units"] = parameter.default_units
    if parameter.description is not None:
        result["description"] = parameter.description
    if isinstance(parameter.value, (int, float)):
        result["default"] = parameter.value
    return result


def _serialize_reaction(reaction: Reaction) -> dict[str, Any]:
    """Serialize a reaction to JSON-compatible format."""
    result = {"id": reaction.id if reaction.id is not None else reaction.name}

    if reaction.name:
        result["name"] = reaction.name

    # Serialize substrates (reactants). Emit integer-valued coefficients as
    # `int` and fractional coefficients as `float` so the schema's numeric
    # stoichiometry field survives a round trip (integer fixtures stay
    # byte-identical; fractional ones like `0.87 CH2O` are preserved exactly).
    if reaction.reactants:
        result["substrates"] = [
            {"species": species, "stoichiometry": _emit_stoich(coeff)}
            for species, coeff in reaction.reactants.items()
        ]
    else:
        result["substrates"] = None

    if reaction.products:
        result["products"] = [
            {"species": species, "stoichiometry": _emit_stoich(coeff)}
            for species, coeff in reaction.products.items()
        ]
    else:
        result["products"] = None

    # Serialize rate
    if reaction.rate_constant is not None:
        result["rate"] = _serialize_expression(reaction.rate_constant)

    return result


def _serialize_reaction_system(rs: ReactionSystem) -> dict[str, Any]:
    """Serialize a reaction system to JSON-compatible format."""
    result = {}

    # Serialize species
    if rs.species:
        result["species"] = {sp.name: _serialize_species(sp) for sp in rs.species}
    else:
        result["species"] = {}

    # Serialize parameters
    if rs.parameters:
        result["parameters"] = {param.name: _serialize_parameter(param) for param in rs.parameters}
    else:
        result["parameters"] = {}

    # Serialize reactions
    if rs.reactions:
        result["reactions"] = [_serialize_reaction(reaction) for reaction in rs.reactions]
    else:
        result["reactions"] = []

    # Constraint equations (esm-spec §11.4) — mirrors _parse_reaction_system.
    if rs.constraint_equations:
        result["constraint_equations"] = [_serialize_equation(eq) for eq in rs.constraint_equations]

    # Inline tests, analyses, and component-level tolerance (esm-spec §6.6 / §6.7).
    if rs.tolerance is not None:
        tol = _serialize_tolerance(rs.tolerance)
        if tol:
            result["tolerance"] = tol
    if rs.tests:
        result["tests"] = [_serialize_test(t) for t in rs.tests]
    if rs.analyses:
        result["analyses"] = [_serialize_analysis(a) for a in rs.analyses]

    # Component-owned events (the schema nests events inside components).
    if rs.continuous_events:
        result["continuous_events"] = [
            _serialize_continuous_event(ev) for ev in rs.continuous_events
        ]
    if rs.discrete_events:
        result["discrete_events"] = [_serialize_discrete_event(ev) for ev in rs.discrete_events]

    # Subsystems (esm-spec §4.7) — see _serialize_subsystem.
    if rs.subsystems:
        result["subsystems"] = {
            name: _serialize_subsystem(sub) for name, sub in rs.subsystems.items()
        }

    return result


# ``title`` maps to wire key ``citation`` and is emitted only when truthy.
_REFERENCE_SPEC = (
    ("title", "citation", _OMIT_FALSY, None),
    ("doi", "doi", _OMIT_NONE, None),
    ("url", "url", _OMIT_NONE, None),
)


def _serialize_reference(reference: Reference) -> dict[str, Any]:
    """Serialize a reference to JSON-compatible format."""
    return _serialize_by_spec(reference, _REFERENCE_SPEC)


# ``title`` -> wire key ``name``; ``keywords`` -> wire key ``tags``.
_METADATA_SPEC = (
    ("title", "name", _KEEP, None),
    ("description", "description", _OMIT_NONE, None),
    ("authors", "authors", _OMIT_FALSY, None),
    ("created", "created", _OMIT_NONE, None),
    ("modified", "modified", _OMIT_NONE, None),
    ("keywords", "tags", _OMIT_FALSY, None),
    ("references", "references", _OMIT_FALSY, lambda rs: [_serialize_reference(r) for r in rs]),
)


def _serialize_metadata(metadata: Metadata) -> dict[str, Any]:
    """Serialize metadata to JSON-compatible format."""
    return _serialize_by_spec(metadata, _METADATA_SPEC)


def _serialize_domain(domain: Domain) -> dict[str, Any]:
    """Serialize a domain to JSON-compatible format."""
    result = {}

    if domain.independent_variable:
        result["independent_variable"] = domain.independent_variable

    # Serialize temporal domain
    if domain.temporal:
        temporal_data: dict[str, Any] = {}
        if domain.temporal.start is not None:
            temporal_data["start"] = domain.temporal.start
        if domain.temporal.end is not None:
            temporal_data["end"] = domain.temporal.end
        if domain.temporal.reference_time:
            temporal_data["reference_time"] = domain.temporal.reference_time
        result["temporal"] = temporal_data

    # Initial conditions are no longer a domain-level concept (v0.8.0): they are
    # declared with `ic` op equations in the model (esm-spec §11.4).

    return result


_DATA_SOURCE_LOCATION_SPEC = (
    ("url_template", "url_template", _KEEP, None),
    ("mirrors", "mirrors", _OMIT_FALSY, list),
)


def _serialize_data_source_location(source: DataSourceLocation) -> dict[str, Any]:
    return _serialize_by_spec(source, _DATA_SOURCE_LOCATION_SPEC)


_DATA_SOURCE_TEMPORAL_SPEC = (
    ("start", "start", _OMIT_NONE, None),
    ("end", "end", _OMIT_NONE, None),
    ("file_period", "file_period", _OMIT_NONE, None),
    ("frequency", "frequency", _OMIT_NONE, None),
    ("records_per_file", "records_per_file", _OMIT_NONE, None),
    ("time_variable", "time_variable", _OMIT_NONE, None),
)


def _serialize_data_source_temporal(temporal: DataSourceTemporal) -> dict[str, Any]:
    return _serialize_by_spec(temporal, _DATA_SOURCE_TEMPORAL_SPEC)


_DATA_SOURCE_DETERMINISM_SPEC = (
    ("endian", "endian", _OMIT_NONE, None),
    ("float_format", "float_format", _OMIT_NONE, None),
    ("integer_width", "integer_width", _OMIT_NONE, None),
)


def _serialize_data_source_determinism(det: DataSourceDeterminism) -> dict[str, Any]:
    """Serialize a determinism block (esm-spec §8.9.2)."""
    return _serialize_by_spec(det, _DATA_SOURCE_DETERMINISM_SPEC)


def _serialize_data_source(source: DataSource) -> dict[str, Any]:
    """Serialize a `data_sources` entry (esm-spec §8).

    A source emits NO `variables` map: from 1.0.0 the per-variable binding lives
    on the consuming parameter's `update.from`.
    """
    result: dict[str, Any] = {
        "kind": source.kind.value,
        "source": _serialize_data_source_location(source.source),
    }
    if source.temporal is not None:
        temporal_dict = _serialize_data_source_temporal(source.temporal)
        if temporal_dict:
            result["temporal"] = temporal_dict
    if source.determinism is not None:
        det_dict = _serialize_data_source_determinism(source.determinism)
        if det_dict:
            result["determinism"] = det_dict
    if source.reader_options is not None:
        result["reader_options"] = _json_deepcopy(source.reader_options)
    if source.select is not None:
        result["select"] = _json_deepcopy(source.select)
    if source.record_filter is not None:
        result["record_filter"] = _json_deepcopy(source.record_filter)
    if source.extent is not None:
        result["extent"] = _json_deepcopy(source.extent)
    if source.reference is not None:
        result["reference"] = _serialize_reference(source.reference)
    if source.metadata:
        result["metadata"] = dict(source.metadata)

    return result


# ``operator_id`` / ``needed_vars`` are schema-required (always emitted).
_OPERATOR_SPEC = (
    ("operator_id", "operator_id", _KEEP, None),
    ("needed_vars", "needed_vars", _KEEP, None),
    ("modifies", "modifies", _OMIT_NONE, None),
    ("config", "config", _OMIT_FALSY, None),
    ("description", "description", _OMIT_FALSY, None),
    ("reference", "reference", _OMIT_FALSY, _serialize_reference),
)


def _serialize_operator(operator: Operator) -> dict[str, Any]:
    """Serialize an operator to JSON-compatible format."""
    return _serialize_by_spec(operator, _OPERATOR_SPEC)


def _serialize_registered_function(rf) -> dict[str, Any]:
    """Serialize a RegisteredFunction entry (esm-spec §9.2)."""
    sig: dict[str, Any] = {"arg_count": rf.signature.arg_count}
    if rf.signature.arg_types is not None:
        sig["arg_types"] = list(rf.signature.arg_types)
    if rf.signature.return_type is not None:
        sig["return_type"] = rf.signature.return_type

    result: dict[str, Any] = {
        "id": rf.id,
        "signature": sig,
    }
    if rf.units is not None:
        result["units"] = rf.units
    if rf.arg_units is not None:
        result["arg_units"] = list(rf.arg_units)
    if rf.description is not None:
        result["description"] = rf.description
    if rf.references:
        result["references"] = [_serialize_reference(r) for r in rf.references]
    if rf.config:
        result["config"] = dict(rf.config)
    return result


def _serialize_coupling_entry(coupling: CouplingEntry) -> dict[str, Any]:
    """Serialize a coupling entry to JSON-compatible format."""
    result = {}

    # Add description if present
    if coupling.description:
        result["description"] = coupling.description

    # Handle different coupling types
    if isinstance(coupling, OperatorComposeCoupling):
        result["type"] = "operator_compose"
        if coupling.systems:
            result["systems"] = coupling.systems
        if coupling.translate:
            result["translate"] = coupling.translate
        if coupling.lifting is not None:
            result["lifting"] = coupling.lifting

    elif isinstance(coupling, CouplingCouple):
        result["type"] = "couple"
        if coupling.systems:
            result["systems"] = coupling.systems
        if coupling.connector:
            result["connector"] = {
                "equations": [
                    {
                        "from": eq.from_var,
                        "to": eq.to_var,
                        "transform": eq.transform,
                        **(
                            {"expression": _serialize_expression(eq.expression)}
                            if eq.expression
                            else {}
                        ),
                    }
                    for eq in coupling.connector.equations
                ]
            }

    elif isinstance(coupling, VariableMapCoupling):
        result["type"] = "variable_map"
        if coupling.from_var:
            result["from"] = coupling.from_var
        if coupling.to_var:
            result["to"] = coupling.to_var
        if coupling.transform is not None:
            # Expression transform (in-progress-0.8.0 widening): re-emit the
            # ExpressionNode losslessly; legacy enum strings pass through.
            if isinstance(coupling.transform, ExprNode):
                result["transform"] = _serialize_expression(coupling.transform)
            elif coupling.transform:
                result["transform"] = coupling.transform
        if coupling.factor is not None:
            result["factor"] = coupling.factor

    elif isinstance(coupling, CouplingImport):
        # Round-trip the source entry verbatim (esm-spec §10.10.3): only the
        # flattened system carries the expanded edges.
        result["type"] = "coupling_import"
        if coupling.ref is not None:
            result["ref"] = coupling.ref
        if coupling.bind:
            result["bind"] = dict(coupling.bind)

    elif isinstance(coupling, OperatorApplyCoupling):
        result["type"] = "operator_apply"
        if coupling.operator:
            result["operator"] = coupling.operator

    elif isinstance(coupling, CallbackCoupling):
        result["type"] = "callback"
        if coupling.callback_id:
            result["callback_id"] = coupling.callback_id
        if coupling.config:
            result["config"] = coupling.config

    elif isinstance(coupling, EventCoupling):
        result["type"] = "event"
        if coupling.event_type:
            result["event_type"] = coupling.event_type
        if coupling.conditions:
            result["conditions"] = [_serialize_expression(cond) for cond in coupling.conditions]
        if coupling.trigger:
            result["trigger"] = _serialize_discrete_event_trigger(coupling.trigger)
        if coupling.affects:
            result["affects"] = [
                _serialize_affect_equation(affect) for affect in coupling.affects
            ]
        if coupling.affect_neg:
            result["affect_neg"] = [
                _serialize_affect_equation(affect) for affect in coupling.affect_neg
            ]
        if coupling.root_find:
            result["root_find"] = coupling.root_find
        if coupling.reinitialize is not None:
            result["reinitialize"] = coupling.reinitialize

    return result


def _serialize_esm_file(esm_file: EsmFile) -> dict[str, Any]:
    """Serialize an ESM file to JSON-compatible format."""
    result = {"esm": esm_file.version, "metadata": _serialize_metadata(esm_file.metadata)}

    # Serialize models. A value may be a concrete Model or, when a top-level
    # model ref was never resolved (parse carries it verbatim as {"ref": ...},
    # schema top-level `models` oneOf[Model, SubsystemRef]), a raw dict — pass
    # the latter through verbatim, mirroring _serialize_subsystem.
    if esm_file.models:
        result["models"] = {
            model_name: (
                json.loads(json.dumps(model))
                if isinstance(model, dict)
                else _serialize_model(model)
            )
            for model_name, model in esm_file.models.items()
        }

    # Serialize reaction systems (dict-passthrough of an unresolved ref for
    # symmetry with models, though top-level RS refs are not carried today).
    if esm_file.reaction_systems:
        result["reaction_systems"] = {
            rs_name: (
                json.loads(json.dumps(rs))
                if isinstance(rs, dict)
                else _serialize_reaction_system(rs)
            )
            for rs_name, rs in esm_file.reaction_systems.items()
        }

    # Serialize the single shared domain (v0.8.0).
    if esm_file.domain is not None:
        result["domain"] = _serialize_domain(esm_file.domain)

    # Serialize the document-scoped index-set registry (RFC
    # semiring-faq-unified-ir §5.2). Top-level in v0.8.0 — shared by all models.
    if getattr(esm_file, "index_sets", None):
        result["index_sets"] = esm_file.index_sets

    # Serialize the top-level DECLARATIONS (esm-spec §9.7.1) — peers of
    # `index_sets`. Option A expands `apply_expression_template` CALL SITES; it
    # does NOT delete these declarations (§9.6.4 rule 5), so they round-trip
    # VERBATIM. Dropping them emitted a pure template-library file as
    # `{esm, metadata, index_sets}` — none of the five top-level payload keys —
    # which the schema's top-level `anyOf` rejects, making a conforming library
    # file unrepresentable: legal on disk, illegal once loaded and re-emitted.
    if getattr(esm_file, "metaparameters", None):
        result["metaparameters"] = esm_file.metaparameters
    if getattr(esm_file, "expression_templates", None):
        result["expression_templates"] = esm_file.expression_templates

    # Serialize the document-scoped data-source ingest registry (esm-spec §8)
    if esm_file.data_sources:
        result["data_sources"] = {
            name: _serialize_data_source(source) for name, source in esm_file.data_sources.items()
        }

    # Serialize operators
    if esm_file.operators:
        result["operators"] = {
            (operator.name or operator.operator_id): _serialize_operator(operator)
            for operator in esm_file.operators
        }

    # Serialize registered_functions (esm-spec §9.2 — DEPRECATED in v0.3.0)
    if esm_file.registered_functions:
        result["registered_functions"] = {
            name: _serialize_registered_function(rf)
            for name, rf in esm_file.registered_functions.items()
        }

    # Serialize top-level enums block (esm-spec §9.3).
    if getattr(esm_file, "enums", None):
        result["enums"] = {
            enum_name: dict(mapping) for enum_name, mapping in esm_file.enums.items()
        }

    # Serialize top-level function_tables block (esm-spec §9.5, v0.4.0).
    # Tables are first-class authored constructs — round-trip MUST preserve
    # the authored form (no auto-promotion of inline-const lookups).
    if getattr(esm_file, "function_tables", None):
        import copy as _copy_ft

        ft_out = {}
        for ft_name, ft in esm_file.function_tables.items():
            entry: dict[str, Any] = {
                "axes": [
                    {
                        "name": a.name,
                        "values": list(a.values),
                        **({"units": a.units} if a.units is not None else {}),
                    }
                    for a in ft.axes
                ],
                "data": _copy_ft.deepcopy(ft.data),
            }
            if ft.description is not None:
                entry["description"] = ft.description
            if ft.interpolation is not None:
                entry["interpolation"] = ft.interpolation
            if ft.out_of_bounds is not None:
                entry["out_of_bounds"] = ft.out_of_bounds
            if ft.outputs is not None:
                entry["outputs"] = list(ft.outputs)
            if ft.shape is not None:
                entry["shape"] = list(ft.shape)
            if ft.schema_version is not None:
                entry["schema_version"] = ft.schema_version
            ft_out[ft_name] = entry
        result["function_tables"] = ft_out

    # Serialize coupling
    if esm_file.coupling:
        result["coupling"] = [_serialize_coupling_entry(coupling) for coupling in esm_file.coupling]

    # Component-owned events serialize inside their model/reaction system
    # (see _serialize_model/_serialize_reaction_system); EsmFile.events holds
    # those same objects, so they must not be re-emitted here. Only ORPHAN
    # events — attached directly to EsmFile.events by tooling, never parsed
    # from a schema-valid file — fall back to the top-level keys the schema
    # forbids; load() strips and reattaches them on round-trip.
    owned = set()
    for component in list(esm_file.models.values()) + list(esm_file.reaction_systems.values()):
        owned.update(id(ev) for ev in component.continuous_events)
        owned.update(id(ev) for ev in component.discrete_events)
    orphan_events = [ev for ev in esm_file.events if id(ev) not in owned]
    if orphan_events:
        continuous_events = []
        discrete_events = []
        for event in orphan_events:
            if isinstance(event, ContinuousEvent):
                continuous_events.append(_serialize_continuous_event(event))
            elif isinstance(event, DiscreteEvent):
                discrete_events.append(_serialize_discrete_event(event))
        if continuous_events:
            result["continuous_events"] = continuous_events
        if discrete_events:
            result["discrete_events"] = discrete_events

    return result


def save(esm_file: EsmFile, path: str | Path | None = None) -> str:
    """
    Serialize an ESM file to JSON string, optionally writing to file.

    Args:
        esm_file: The EsmFile object to serialize
        path: Optional file path to write the JSON to

    Returns:
        JSON string representation of the ESM file

    Raises:
        IOError: If writing to file fails
    """
    # Serialize to dictionary
    data = _serialize_esm_file(esm_file)

    # Convert to JSON string with nice formatting
    json_str = json.dumps(data, indent=2, ensure_ascii=False)

    # Write to file if path provided
    if path is not None:
        with open(path, "w") as f:
            f.write(json_str)

    return json_str


# ---------------------------------------------------------------------------
# Canonical byte writer for the Option-B *emitted* form (esm-spec §9.6.4 rule 5).
# Co-located with :func:`save` (the document write-back writer) so both hand-off
# JSON writers live together. Unlike :func:`save` (``json.dumps(indent=2,
# sort_keys=False)`` over the wire dict), this writer sorts object keys
# lexicographically EXCEPT the entries of an ``expression_templates`` object,
# which keep their authored-first / materialized-sorted insertion order — the
# ``preserve`` flag threaded through :func:`_emit_write`. It shares the
# :func:`_canonical_number` integral-float rule with the rest of the package.
# Used by :func:`earthsci_ast.lower_expression_templates.emit_document` callers
# (re-exported there for the historical import path).
# ---------------------------------------------------------------------------


def _emit_scalar(x: Any) -> str:
    """Render one JSON scalar for the canonical emit form. Integral finite
    floats render as integer literals (mirroring JSON3's read-normalization in
    the Julia reference: an integral number is written without a decimal point,
    uniformly), so the emitted bytes are cross-binding-identical; non-integral
    floats and strings render via ``json.dumps`` (``ensure_ascii=False`` keeps
    UTF-8 literals, matching JSON3's writer).

    The integral-float → integer-literal decision is the shared canonical-number
    rule (:func:`_canonical_number`, CONFORMANCE_SPEC §5.5.3.1) — the single
    implementation every binding re-serializes through."""
    if isinstance(x, bool):
        return "true" if x else "false"
    x = _canonical_number(x)
    if isinstance(x, int):
        return str(x)
    if isinstance(x, float):
        return json.dumps(x, ensure_ascii=False)
    return json.dumps(x, ensure_ascii=False)


def _emit_write(buf: list[str], x: Any, indent: int, preserve: bool = False) -> None:
    pad = "  " * indent
    pad1 = "  " * (indent + 1)
    if _is_object(x):
        if not x:
            buf.append("{}")
            return
        keys = list(x.keys()) if preserve else sorted(x.keys())
        buf.append("{\n")
        for i, k in enumerate(keys):
            buf.append(pad1)
            buf.append(json.dumps(str(k), ensure_ascii=False))
            buf.append(": ")
            _emit_write(buf, x[k], indent + 1, preserve=(str(k) == "expression_templates"))
            if i < len(keys) - 1:
                buf.append(",")
            buf.append("\n")
        buf.append(pad)
        buf.append("}")
    elif _is_array(x):
        if not x:
            buf.append("[]")
            return
        buf.append("[\n")
        for i, v in enumerate(x):
            buf.append(pad1)
            _emit_write(buf, v, indent + 1)
            if i < len(x) - 1:
                buf.append(",")
            buf.append("\n")
        buf.append(pad)
        buf.append("]")
    else:
        buf.append(_emit_scalar(x))


def emit_esm_string(doc: Any) -> str:
    """Canonical byte serialization of an emitted document (esm-spec §9.6.4
    rule 5): 2-space indent, object keys sorted lexicographically EXCEPT the
    entries of an ``expression_templates`` object, which preserve their
    authored-first / materialized-sorted order. The cross-binding byte-identity
    surface for the Option-B emitted form and the target of the ``emitted.esm``
    goldens."""
    buf: list[str] = []
    _emit_write(buf, doc, 0)
    buf.append("\n")
    return "".join(buf)
