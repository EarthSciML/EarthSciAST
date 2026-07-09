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
    Assertion,
    CallbackCoupling,
    ContinuousEvent,
    CouplingCouple,
    CouplingEntry,
    DataLoader,
    DataLoaderDeterminism,
    DataLoaderSource,
    DataLoaderTemporal,
    DataLoaderVariable,
    DiscreteEvent,
    DiscreteEventTrigger,
    Domain,
    Equation,
    EsmFile,
    EventCoupling,
    Example,
    Expr,
    ExprNode,
    FunctionalAffect,
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


def _serialize_expression(expr: Expr) -> int | float | str | dict[str, Any]:
    """Serialize an expression to JSON-compatible format."""
    if isinstance(expr, (int, float, str)):
        return expr
    if isinstance(expr, ExprNode):
        result = {"op": expr.op, "args": [_serialize_expression(arg) for arg in expr.args]}
        if expr.wrt is not None:
            result["wrt"] = expr.wrt
        if expr.dim is not None:
            result["dim"] = expr.dim
        # Array-op fields (schema §ExpressionNode). Mirrors _parse_expression.
        if expr.output_idx is not None:
            result["output_idx"] = expr.output_idx
        if expr.expr is not None:
            result["expr"] = _serialize_expression(expr.expr)
        if expr.reduce is not None:
            result["reduce"] = expr.reduce
        if getattr(expr, "semiring", None) is not None:
            result["semiring"] = expr.semiring
        if expr.ranges is not None:
            result["ranges"] = expr.ranges
        # M2 value-equality join + filter predicate (RFC §5.3) and the §5.5
        # index-set-producing fields. Mirrors _parse_expression: ``join``/
        # ``distinct`` are plain data; ``filter``/``key`` are nested Expressions.
        if expr.join is not None:
            result["join"] = expr.join
        if expr.filter is not None:
            result["filter"] = _serialize_expression(expr.filter)
        if expr.distinct is not None:
            result["distinct"] = expr.distinct
        if expr.key is not None:
            result["key"] = _serialize_expression(expr.key)
        if expr.regions is not None:
            result["regions"] = expr.regions
        if expr.values is not None:
            result["values"] = [_serialize_expression(v) for v in expr.values]
        if expr.shape is not None:
            result["shape"] = expr.shape
        if expr.perm is not None:
            result["perm"] = expr.perm
        if expr.axis is not None:
            result["axis"] = expr.axis
        if expr.fn is not None:
            result["fn"] = expr.fn
        # Node id (RFC §6.1) + intersect_polygon manifold (RFC §8.1) — emitted
        # only when present so non-geometry nodes round-trip byte-identically.
        if getattr(expr, "id", None) is not None:
            result["id"] = expr.id
        if getattr(expr, "manifold", None) is not None:
            result["manifold"] = expr.manifold
        if expr.handler_id is not None:
            result["handler_id"] = expr.handler_id
        if expr.name is not None:
            result["name"] = expr.name
        if expr.value is not None:
            result["value"] = expr.value
        # table_lookup (esm-spec §9.5, v0.4.0). Stored under JSON key "axes"
        # on the wire; the per-axis input expressions are serialized
        # recursively. ``output`` is preserved verbatim (int or string).
        if expr.table is not None:
            result["table"] = expr.table
        if expr.table_axes is not None:
            result["axes"] = {k: _serialize_expression(v) for k, v in expr.table_axes.items()}
        if expr.output is not None:
            result["output"] = expr.output
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
    """Serialize an affect equation or functional affect to JSON-compatible format."""
    if isinstance(affect, FunctionalAffect):
        result = {"handler_id": affect.handler_id}
        if affect.read_vars:
            result["read_vars"] = affect.read_vars
        if affect.read_params:
            result["read_params"] = affect.read_params
        if affect.modified_params:
            result["modified_params"] = affect.modified_params
        if affect.config:
            result["config"] = affect.config
        return result
    return {"lhs": affect.lhs, "rhs": _serialize_expression(affect.rhs)}


def _serialize_model_variable(variable: ModelVariable) -> dict[str, Any]:
    """Serialize a model variable to JSON-compatible format."""
    result = {"type": variable.type}
    if variable.units is not None:
        result["units"] = variable.units
    if variable.default is not None:
        result["default"] = variable.default
    if variable.default_units is not None:
        result["default_units"] = variable.default_units
    if variable.description is not None:
        result["description"] = variable.description
    if variable.expression is not None:
        result["expression"] = _serialize_expression(variable.expression)
    if variable.shape is not None:
        result["shape"] = list(variable.shape)
    if variable.location is not None:
        result["location"] = variable.location
    if variable.noise_kind is not None:
        result["noise_kind"] = variable.noise_kind
    if variable.correlation_group is not None:
        result["correlation_group"] = variable.correlation_group
    return result


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


def _split_affects(affects) -> tuple:
    """Split an event's affects into (symbolic equations, functional affect).

    Parsing folds a schema ``functional_affect`` into the event's ``affects``
    list; on the way out it must be re-emitted under the singular
    ``functional_affect`` key the schema defines (an event carries at most one).
    """
    equations = [a for a in affects if not isinstance(a, FunctionalAffect)]
    functional = [a for a in affects if isinstance(a, FunctionalAffect)]
    return equations, (functional[0] if functional else None)


def _serialize_continuous_event(event: ContinuousEvent) -> dict[str, Any]:
    """Serialize a continuous event to JSON-compatible format."""
    equations, functional = _split_affects(event.affects)
    result = {
        "conditions": [_serialize_expression(cond) for cond in event.conditions],
    }
    if event.name:
        result["name"] = event.name
    if equations or functional is None:
        result["affects"] = [_serialize_affect_equation(a) for a in equations]
    if functional is not None:
        result["functional_affect"] = _serialize_affect_equation(functional)
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
    equations, functional = _split_affects(event.affects)
    result = {
        "trigger": _serialize_discrete_event_trigger(event.trigger),
    }
    if event.name:
        result["name"] = event.name
    if equations or functional is None:
        result["affects"] = [_serialize_affect_equation(a) for a in equations]
    if functional is not None:
        result["functional_affect"] = _serialize_affect_equation(functional)
    if event.priority != 0:
        result["priority"] = event.priority
    if event.discrete_parameters:
        result["discrete_parameters"] = list(event.discrete_parameters)
    if event.reinitialize:
        result["reinitialize"] = event.reinitialize
    if event.description:
        result["description"] = event.description

    return result


def _serialize_tolerance(t: Tolerance) -> dict[str, Any]:
    result: dict[str, Any] = {}
    if t.abs is not None:
        result["abs"] = t.abs
    if t.rel is not None:
        result["rel"] = t.rel
    return result


def _serialize_time_span(ts: TimeSpan) -> dict[str, Any]:
    return {"start": ts.start, "end": ts.end}


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


def _serialize_test(t: Test) -> dict[str, Any]:
    result: dict[str, Any] = {"id": t.id}
    if t.description is not None:
        result["description"] = t.description
    if t.initial_conditions:
        result["initial_conditions"] = dict(t.initial_conditions)
    if t.parameter_overrides:
        result["parameter_overrides"] = dict(t.parameter_overrides)
    result["time_span"] = _serialize_time_span(t.time_span)
    if t.tolerance is not None:
        result["tolerance"] = _serialize_tolerance(t.tolerance)
    # esm-spec §9.7.10 form C: a test's injected imports are authored per-run
    # config and DO survive parse → emit (unlike a component's own imports,
    # which are consumed by the fixpoint at load).
    if t.expression_template_imports:
        result["expression_template_imports"] = json.loads(
            json.dumps(t.expression_template_imports)
        )
    result["assertions"] = [_serialize_assertion(a) for a in t.assertions]
    return result


def _serialize_plot_axis(axis: PlotAxis) -> dict[str, Any]:
    result: dict[str, Any] = {"variable": axis.variable}
    if axis.label is not None:
        result["label"] = axis.label
    return result


def _serialize_plot_value(v: PlotValue) -> dict[str, Any]:
    result: dict[str, Any] = {"variable": v.variable}
    if v.at_time is not None:
        result["at_time"] = v.at_time
    if v.reduce is not None:
        result["reduce"] = v.reduce
    return result


def _serialize_plot_series(s: PlotSeries) -> dict[str, Any]:
    return {"name": s.name, "variable": s.variable}


def _serialize_plot(p: Plot) -> dict[str, Any]:
    result: dict[str, Any] = {
        "id": p.id,
        "type": p.type,
    }
    if p.description is not None:
        result["description"] = p.description
    result["x"] = _serialize_plot_axis(p.x)
    result["y"] = _serialize_plot_axis(p.y)
    if p.value is not None:
        result["value"] = _serialize_plot_value(p.value)
    if p.series:
        result["series"] = [_serialize_plot_series(s) for s in p.series]
    return result


def _serialize_sweep_range(r: SweepRange) -> dict[str, Any]:
    result: dict[str, Any] = {"start": r.start, "stop": r.stop, "count": r.count}
    if r.scale is not None:
        result["scale"] = r.scale
    return result


def _serialize_sweep_dimension(d: SweepDimension) -> dict[str, Any]:
    result: dict[str, Any] = {"parameter": d.parameter}
    if d.values is not None:
        result["values"] = list(d.values)
    if d.range is not None:
        result["range"] = _serialize_sweep_range(d.range)
    return result


def _serialize_parameter_sweep(ps: ParameterSweep) -> dict[str, Any]:
    return {
        "type": ps.type,
        "dimensions": [_serialize_sweep_dimension(d) for d in ps.dimensions],
    }


def _serialize_example(e: Example) -> dict[str, Any]:
    result: dict[str, Any] = {"id": e.id}
    if e.description is not None:
        result["description"] = e.description
    if e.initial_state is not None:
        # Scalar initial-value override map {var: number} (v0.8.0).
        result["initial_state"] = dict(e.initial_state)
    if e.parameters:
        result["parameters"] = dict(e.parameters)
    result["time_span"] = _serialize_time_span(e.time_span)
    if e.parameter_sweep is not None:
        result["parameter_sweep"] = _serialize_parameter_sweep(e.parameter_sweep)
    if e.plots:
        result["plots"] = [_serialize_plot(p) for p in e.plots]
    # esm-spec §9.7.10 form C: an example's injected imports are authored per-run
    # config and DO survive parse → emit (unlike a component's own imports,
    # which are consumed by the fixpoint at load). Mirrors _serialize_test.
    if e.expression_template_imports:
        result["expression_template_imports"] = json.loads(
            json.dumps(e.expression_template_imports)
        )
    return result


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

    # Inline tests, examples, and model-level tolerance (esm-spec §6.6 / §6.7).
    if model.tolerance is not None:
        tol = _serialize_tolerance(model.tolerance)
        if tol:
            result["tolerance"] = tol
    if model.tests:
        result["tests"] = [_serialize_test(t) for t in model.tests]
    if model.examples:
        result["examples"] = [_serialize_example(e) for e in model.examples]

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
    ReactionSystem / DataLoader, or an unresolved ``{ref, bindings?}`` dict
    carried verbatim (deep-copied)."""
    if isinstance(sub, dict):
        return json.loads(json.dumps(sub))
    if isinstance(sub, Model):
        return _serialize_model(sub)
    if isinstance(sub, ReactionSystem):
        return _serialize_reaction_system(sub)
    if isinstance(sub, DataLoader):
        return _serialize_data_loader(sub)
    raise ValueError(f"Invalid subsystem type: {type(sub)}")


def _serialize_species(species: Species) -> dict[str, Any]:
    """Serialize a species to JSON-compatible format."""
    result = {}
    if species.units is not None:
        result["units"] = species.units
    if species.default is not None:
        result["default"] = species.default
    if species.default_units is not None:
        result["default_units"] = species.default_units
    if species.description is not None:
        result["description"] = species.description
    if species.constant is not None:
        result["constant"] = species.constant
    return result


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

    # Inline tests, examples, and component-level tolerance (esm-spec §6.6 / §6.7).
    if rs.tolerance is not None:
        tol = _serialize_tolerance(rs.tolerance)
        if tol:
            result["tolerance"] = tol
    if rs.tests:
        result["tests"] = [_serialize_test(t) for t in rs.tests]
    if rs.examples:
        result["examples"] = [_serialize_example(e) for e in rs.examples]

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


def _serialize_reference(reference: Reference) -> dict[str, Any]:
    """Serialize a reference to JSON-compatible format."""
    result = {}
    if reference.title:
        result["citation"] = reference.title
    if reference.doi is not None:
        result["doi"] = reference.doi
    if reference.url is not None:
        result["url"] = reference.url
    return result


def _serialize_metadata(metadata: Metadata) -> dict[str, Any]:
    """Serialize metadata to JSON-compatible format."""
    result = {"name": metadata.title}

    if metadata.description is not None:
        result["description"] = metadata.description
    if metadata.authors:
        result["authors"] = metadata.authors
    if metadata.created is not None:
        result["created"] = metadata.created
    if metadata.modified is not None:
        result["modified"] = metadata.modified
    if metadata.keywords:
        result["tags"] = metadata.keywords
    if metadata.references:
        result["references"] = [_serialize_reference(ref) for ref in metadata.references]

    return result


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


def _serialize_data_loader_source(source: DataLoaderSource) -> dict[str, Any]:
    result: dict[str, Any] = {"url_template": source.url_template}
    if source.mirrors:
        result["mirrors"] = list(source.mirrors)
    return result


def _serialize_data_loader_temporal(temporal: DataLoaderTemporal) -> dict[str, Any]:
    result: dict[str, Any] = {}
    if temporal.start is not None:
        result["start"] = temporal.start
    if temporal.end is not None:
        result["end"] = temporal.end
    if temporal.file_period is not None:
        result["file_period"] = temporal.file_period
    if temporal.frequency is not None:
        result["frequency"] = temporal.frequency
    if temporal.records_per_file is not None:
        result["records_per_file"] = temporal.records_per_file
    if temporal.time_variable is not None:
        result["time_variable"] = temporal.time_variable
    return result


def _serialize_data_loader_variable(variable: DataLoaderVariable) -> dict[str, Any]:
    result: dict[str, Any] = {
        "file_variable": variable.file_variable,
        "units": variable.units,
    }
    if variable.unit_conversion is not None:
        if isinstance(variable.unit_conversion, (int, float)):
            result["unit_conversion"] = variable.unit_conversion
        else:
            result["unit_conversion"] = _serialize_expression(variable.unit_conversion)
    if variable.description is not None:
        result["description"] = variable.description
    if variable.reference is not None:
        result["reference"] = _serialize_reference(variable.reference)
    return result


def _serialize_data_loader_determinism(det: DataLoaderDeterminism) -> dict[str, Any]:
    """Serialize a determinism block (esm-spec §8.9.2)."""
    result: dict[str, Any] = {}
    if det.endian is not None:
        result["endian"] = det.endian
    if det.float_format is not None:
        result["float_format"] = det.float_format
    if det.integer_width is not None:
        result["integer_width"] = det.integer_width
    return result


def _serialize_data_loader(loader: DataLoader) -> dict[str, Any]:
    """Serialize a data loader to JSON-compatible format."""
    result: dict[str, Any] = {
        "kind": loader.kind.value,
        "source": _serialize_data_loader_source(loader.source),
        "variables": {
            vname: _serialize_data_loader_variable(vdef) for vname, vdef in loader.variables.items()
        },
    }
    if loader.temporal is not None:
        temporal_dict = _serialize_data_loader_temporal(loader.temporal)
        if temporal_dict:
            result["temporal"] = temporal_dict
    if loader.determinism is not None:
        det_dict = _serialize_data_loader_determinism(loader.determinism)
        if det_dict:
            result["determinism"] = det_dict
    if loader.reference is not None:
        result["reference"] = _serialize_reference(loader.reference)
    if loader.metadata:
        result["metadata"] = dict(loader.metadata)

    return result


def _serialize_operator(operator: Operator) -> dict[str, Any]:
    """Serialize an operator to JSON-compatible format."""
    result = {}

    # Schema requires operator_id
    result["operator_id"] = operator.operator_id

    # Schema requires needed_vars
    result["needed_vars"] = operator.needed_vars

    # Optional fields
    if operator.modifies is not None:
        result["modifies"] = operator.modifies

    if operator.config:
        result["config"] = operator.config

    if operator.description:
        result["description"] = operator.description

    if operator.reference:
        result["reference"] = _serialize_reference(operator.reference)

    return result


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
            result["affects"] = [_serialize_affect_equation(affect) for affect in coupling.affects]
        if coupling.affect_neg:
            result["affect_neg"] = [
                _serialize_affect_equation(affect) for affect in coupling.affect_neg
            ]
        if coupling.discrete_parameters:
            result["discrete_parameters"] = coupling.discrete_parameters
        if coupling.root_find:
            result["root_find"] = coupling.root_find
        if coupling.reinitialize is not None:
            result["reinitialize"] = coupling.reinitialize

    return result


def _serialize_esm_file(esm_file: EsmFile) -> dict[str, Any]:
    """Serialize an ESM file to JSON-compatible format."""
    result = {"esm": esm_file.version, "metadata": _serialize_metadata(esm_file.metadata)}

    # Serialize models
    if esm_file.models:
        if isinstance(esm_file.models, dict):
            result["models"] = {
                model_name: _serialize_model(model) for model_name, model in esm_file.models.items()
            }
        elif isinstance(esm_file.models, list):
            result["models"] = {model.name: _serialize_model(model) for model in esm_file.models}

    # Serialize reaction systems
    if esm_file.reaction_systems:
        if isinstance(esm_file.reaction_systems, dict):
            result["reaction_systems"] = {
                rs_name: _serialize_reaction_system(rs)
                for rs_name, rs in esm_file.reaction_systems.items()
            }
        elif isinstance(esm_file.reaction_systems, list):
            result["reaction_systems"] = {
                rs.name: _serialize_reaction_system(rs) for rs in esm_file.reaction_systems
            }

    # Serialize the single shared domain (v0.8.0).
    if esm_file.domain is not None:
        result["domain"] = _serialize_domain(esm_file.domain)

    # Serialize the document-scoped index-set registry (RFC
    # semiring-faq-unified-ir §5.2). Top-level in v0.8.0 — shared by all models.
    if getattr(esm_file, "index_sets", None):
        result["index_sets"] = esm_file.index_sets

    # Serialize data loaders
    if esm_file.data_loaders:
        result["data_loaders"] = {
            name: _serialize_data_loader(loader) for name, loader in esm_file.data_loaders.items()
        }

    # Serialize operators
    if esm_file.operators:
        result["operators"] = {
            getattr(operator, "name", operator.operator_id): _serialize_operator(operator)
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
