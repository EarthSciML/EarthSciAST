"""
ESM Format parsing module.

This module provides functions to parse JSON data into ESM format objects,
with schema validation using the bundled esm-schema.json file.
"""

import copy
import json
import os
from pathlib import Path
from typing import Union, Dict, Any, List, Optional, TYPE_CHECKING
from dataclasses import fields
from enum import Enum
try:
    # Python 3.9+
    from importlib.resources import files
    _RESOURCES_AVAILABLE = True
except ImportError:
    try:
        # Python 3.7-3.8 fallback
        from importlib_resources import files
        _RESOURCES_AVAILABLE = True
    except ImportError:
        # No importlib resources available, will use fallback
        _RESOURCES_AVAILABLE = False
        files = None

if TYPE_CHECKING:
    from .esm_types import DataLoader, RegisteredFunction

import jsonschema
from jsonschema import validate

from ._monitoring import track_performance
from .esm_types import (
    EsmFile, Metadata, Model, ReactionSystem, ModelVariable, Equation,
    Species, Parameter, Reaction, ExprNode, Expr, AffectEquation,
    ContinuousEvent, DiscreteEvent, DiscreteEventTrigger, FunctionalAffect,
    DataLoader, DataLoaderKind, DataLoaderSource, DataLoaderTemporal,
    DataLoaderVariable,
    DataLoaderDeterminism, Operator,
    CouplingEntry, CouplingType, ConnectorEquation, Connector, Domain,
    OperatorComposeCoupling, CouplingCouple, VariableMapCoupling,
    OperatorApplyCoupling, CallbackCoupling, EventCoupling,
    Reference, TemporalDomain,
    Tolerance, TimeSpan, Assertion, Test,
    PlotAxis, PlotValue, PlotSeries, Plot,
    SweepRange, SweepDimension, ParameterSweep, Example,
    FunctionTable, FunctionTableAxis,
)


class SchemaValidationError(Exception):
    """Exception raised when schema validation fails."""
    pass


class UnsupportedVersionError(Exception):
    """Exception raised when ESM version is not supported."""
    pass


class CircularReferenceError(Exception):
    """Exception raised when circular subsystem references are detected."""
    pass


class SubsystemRefError(Exception):
    """Exception raised when a subsystem reference cannot be resolved."""
    pass


# Current library version for compatibility checking. Bumped to 0.8.0 with the
# clean break that removed the bespoke spatial-grid / discretization / regrid
# machinery in favour of `aggregate` Functional Aggregate Query nodes; legacy
# loader files are now rejected by the schema's `additionalProperties: false`.
# Prior steps: 0.4.0 added the sampled-function-tables block + `table_lookup`;
# 0.5.0 widened `plots.y`; 0.6.0 added the `integral` AST op.
_CURRENT_VERSION = (0, 8, 0)


def _check_version_compatibility(version_string: str) -> None:
    """Check ESM version compatibility, raising errors or warnings as appropriate."""
    import re
    import warnings

    match = re.match(r'^(\d+)\.(\d+)\.(\d+)$', version_string)
    if not match:
        return  # Schema validation should catch invalid formats

    major = int(match.group(1))
    minor = int(match.group(2))

    # Reject unsupported major versions
    if major != _CURRENT_VERSION[0]:
        raise UnsupportedVersionError(
            f"Unsupported major version {major}. "
            f"This library supports major version {_CURRENT_VERSION[0]}."
        )

    # Warn about newer minor versions
    if minor > _CURRENT_VERSION[1]:
        warnings.warn(
            f"{version_string} is newer than the current library version "
            f"{'.'.join(str(v) for v in _CURRENT_VERSION)}. "
            f"Some features may not be supported.",
            UserWarning,
            stacklevel=3
        )


def _get_schema() -> Dict[str, Any]:
    """Load the bundled ESM schema."""
    if _RESOURCES_AVAILABLE:
        try:
            # Use importlib.resources to locate the schema file within the package
            schema_files = files("earthsci_toolkit") / "data"
            schema_path = schema_files / "esm-schema.json"

            # Read the schema content using the modern resource API
            with schema_path.open('r', encoding='utf-8') as f:
                return json.load(f)
        except (FileNotFoundError, AttributeError, TypeError) as e:
            # Fall through to the legacy path approach
            pass

    # Fallback to the original method if resources approach fails or is unavailable
    schema_path = Path(__file__).parent / "data" / "esm-schema.json"
    if not schema_path.exists():
        raise FileNotFoundError(f"ESM schema not found at {schema_path}")

    with open(schema_path, 'r') as f:
        return json.load(f)


def _parse_expression(expr_data: Union[int, float, str, Dict[str, Any]]) -> Expr:
    """Parse an expression from JSON data."""
    if isinstance(expr_data, (int, float, str)):
        return expr_data
    elif isinstance(expr_data, dict):
        # Parse ExprNode
        op = expr_data["op"]
        args = [_parse_expression(arg) for arg in expr_data["args"]]
        wrt = expr_data.get("wrt")
        dim = expr_data.get("dim")

        # Validate operator-specific field requirements
        if op == "D" and wrt is None:
            raise ValueError(f"Operator 'D' requires 'wrt' field to be specified")
        if op == "grad" and dim is None:
            raise ValueError(f"Operator 'grad' requires 'dim' field to be specified")

        # Array-op fields (schema §ExpressionNode).
        output_idx = expr_data.get("output_idx")
        body_expr = _parse_expression(expr_data["expr"]) if "expr" in expr_data else None
        reduce = expr_data.get("reduce")
        semiring = expr_data.get("semiring")
        ranges = expr_data.get("ranges")
        # M2 value-equality join + filter predicate (RFC §5.3) and the §5.5
        # index-set-producing fields. ``join``/``distinct`` are plain data;
        # ``filter``/``key`` are nested Expressions.
        join = expr_data.get("join")
        filter_expr = _parse_expression(expr_data["filter"]) if "filter" in expr_data else None
        distinct = expr_data.get("distinct")
        key_expr = _parse_expression(expr_data["key"]) if "key" in expr_data else None
        regions = expr_data.get("regions")
        values = None
        if "values" in expr_data:
            values = [_parse_expression(v) for v in expr_data["values"]]
        shape = expr_data.get("shape")
        perm = expr_data.get("perm")
        axis = expr_data.get("axis")
        fn = expr_data.get("fn")
        handler_id = expr_data.get("handler_id")
        name = expr_data.get("name")
        value = expr_data.get("value")
        # Node id (RFC §6.1) + geometry-kernel manifold (RFC §8.1, esm-spec.md
        # §8.6.1). Both geometry leaves — the array-valued `intersect_polygon`
        # clip and the fused scalar `polygon_intersection_area` — are strictly
        # binary with a required manifold (the schema enforces both); fail fast
        # here so a hand-built node mirrors that.
        node_id = expr_data.get("id")
        manifold = expr_data.get("manifold")
        if op in ("intersect_polygon", "polygon_intersection_area") and manifold is None:
            raise ValueError(
                f"Operator {op!r} requires a 'manifold' field "
                "(planar / spherical / geodesic); it carries no default"
            )

        if op == "call" and handler_id is None:
            raise ValueError("Operator 'call' requires 'handler_id' field to be specified")
        if op == "fn" and name is None:
            raise ValueError("Operator 'fn' requires 'name' field to be specified")
        if op == "const" and "value" not in expr_data:
            raise ValueError("Operator 'const' requires 'value' field to be specified")

        # table_lookup (esm-spec §9.5, v0.4.0): table id, per-axis input
        # expression map (carried under JSON key "axes"), optional output
        # selector. ``args`` MUST be empty for a table_lookup node.
        table = expr_data.get("table")
        table_axes_raw = expr_data.get("axes") if op == "table_lookup" else None
        table_axes = None
        if op == "table_lookup":
            if table is None:
                raise ValueError("Operator 'table_lookup' requires 'table' field to be specified")
            if not isinstance(table_axes_raw, dict):
                raise ValueError("Operator 'table_lookup' requires 'axes' to be an object mapping axis names to input expressions")
            table_axes = {k: _parse_expression(v) for k, v in table_axes_raw.items()}
            if args:
                raise ValueError("Operator 'table_lookup' must have empty 'args' (per-axis inputs live under 'axes')")
        output = expr_data.get("output")

        return ExprNode(
            op=op,
            args=args,
            wrt=wrt,
            dim=dim,
            output_idx=output_idx,
            expr=body_expr,
            reduce=reduce,
            semiring=semiring,
            ranges=ranges,
            join=join,
            filter=filter_expr,
            distinct=distinct,
            key=key_expr,
            regions=regions,
            values=values,
            shape=shape,
            perm=perm,
            axis=axis,
            fn=fn,
            handler_id=handler_id,
            name=name,
            value=value,
            id=node_id,
            manifold=manifold,
            table=table,
            table_axes=table_axes,
            output=output,
        )
    else:
        raise ValueError(f"Invalid expression data: {expr_data}")


def _parse_equation(eq_data: Dict[str, Any]) -> Equation:
    """Parse an equation from JSON data."""
    lhs = _parse_expression(eq_data["lhs"])
    rhs = _parse_expression(eq_data["rhs"])
    comment = eq_data.get("_comment")
    return Equation(lhs=lhs, rhs=rhs, _comment=comment)


def _parse_affect_equation(affect_data: Dict[str, Any]) -> AffectEquation:
    """Parse an affect equation from JSON data."""
    lhs = affect_data["lhs"]  # string
    rhs = _parse_expression(affect_data["rhs"])
    return AffectEquation(lhs=lhs, rhs=rhs)


def _parse_functional_affect(functional_affect_data: Dict[str, Any]) -> FunctionalAffect:
    """Parse a functional affect from JSON data."""
    handler_id = functional_affect_data["handler_id"]
    read_vars = functional_affect_data.get("read_vars", [])
    read_params = functional_affect_data.get("read_params", [])
    modified_params = functional_affect_data.get("modified_params", [])
    config = functional_affect_data.get("config", {})

    return FunctionalAffect(
        handler_id=handler_id,
        read_vars=read_vars,
        read_params=read_params,
        modified_params=modified_params,
        config=config
    )


def _parse_model_variable(var_data: Dict[str, Any]) -> ModelVariable:
    """Parse a model variable from JSON data."""
    var_type = var_data["type"]
    units = var_data.get("units")
    default = var_data.get("default")
    default_units = var_data.get("default_units")
    description = var_data.get("description")
    expression = None
    if "expression" in var_data:
        expression = _parse_expression(var_data["expression"])
    shape = var_data.get("shape")
    if shape is not None:
        shape = list(shape)
    location = var_data.get("location")

    noise_kind = var_data.get("noise_kind")
    correlation_group = var_data.get("correlation_group")

    return ModelVariable(
        type=var_type,
        units=units,
        default=default,
        default_units=default_units,
        description=description,
        expression=expression,
        shape=shape,
        location=location,
        noise_kind=noise_kind,
        correlation_group=correlation_group,
    )


def _parse_discrete_event_trigger(trigger_data: Dict[str, Any]) -> DiscreteEventTrigger:
    """Parse a discrete event trigger from JSON data."""
    trigger_type = trigger_data["type"]

    if trigger_type == "condition":
        expression = _parse_expression(trigger_data["expression"])
        return DiscreteEventTrigger(type=trigger_type, value=expression)
    elif trigger_type == "periodic":
        interval = trigger_data["interval"]
        return DiscreteEventTrigger(type=trigger_type, value=interval)
    elif trigger_type == "preset_times":
        times = trigger_data["times"]
        return DiscreteEventTrigger(type=trigger_type, value=times)
    else:
        raise ValueError(f"Unknown trigger type: {trigger_type}")


def _parse_continuous_event(event_data: Dict[str, Any]) -> ContinuousEvent:
    """Parse a continuous event from JSON data."""
    name = event_data.get("name", "")
    conditions = [_parse_expression(cond) for cond in event_data["conditions"]]
    affects = []

    # Parse affects: distinguish AffectEquation from FunctionalAffect
    if "affects" in event_data:
        for affect in event_data["affects"]:
            if isinstance(affect, dict) and "handler_id" in affect:
                affects.append(_parse_functional_affect(affect))
            else:
                affects.append(_parse_affect_equation(affect))

    # Parse functional_affect (FunctionalAffect object)
    if "functional_affect" in event_data:
        functional_affect = _parse_functional_affect(event_data["functional_affect"])
        affects.append(functional_affect)

    priority = event_data.get("priority", 0)

    # Parse new fields
    affect_neg = None
    if "affect_neg" in event_data:
        affect_neg_list = []
        for affect in event_data["affect_neg"]:
            if isinstance(affect, dict) and "handler_id" in affect:
                # This is a functional affect
                affect_neg_list.append(_parse_functional_affect(affect))
            else:
                # This is a regular affect equation
                affect_neg_list.append(_parse_affect_equation(affect))
        affect_neg = affect_neg_list

    root_find = event_data.get("root_find", "left")
    reinitialize = event_data.get("reinitialize", False)
    description = event_data.get("description")

    return ContinuousEvent(
        name=name,
        conditions=conditions,  # Fixed: use plural conditions
        affects=affects,
        affect_neg=affect_neg,
        root_find=root_find,
        reinitialize=reinitialize,
        priority=priority,
        description=description
    )


def _parse_discrete_event(event_data: Dict[str, Any]) -> DiscreteEvent:
    """Parse a discrete event from JSON data."""
    name = event_data.get("name", "")
    trigger = _parse_discrete_event_trigger(event_data["trigger"])
    affects = []

    # Parse affects: distinguish AffectEquation from FunctionalAffect
    if "affects" in event_data:
        for affect in event_data["affects"]:
            if isinstance(affect, dict) and "handler_id" in affect:
                affects.append(_parse_functional_affect(affect))
            else:
                affects.append(_parse_affect_equation(affect))

    # Parse functional_affect (FunctionalAffect object)
    if "functional_affect" in event_data:
        functional_affect = _parse_functional_affect(event_data["functional_affect"])
        affects.append(functional_affect)

    priority = event_data.get("priority", 0)

    return DiscreteEvent(
        name=name,
        trigger=trigger,
        affects=affects,
        priority=priority
    )


def _parse_tolerance(data: Dict[str, Any]) -> Tolerance:
    return Tolerance(abs=data.get("abs"), rel=data.get("rel"))


def _parse_time_span(data: Dict[str, Any]) -> TimeSpan:
    return TimeSpan(start=float(data["start"]), end=float(data["end"]))


def _parse_assertion(data: Dict[str, Any]) -> Assertion:
    tol = _parse_tolerance(data["tolerance"]) if "tolerance" in data else None
    coords = None
    if data.get("coords") is not None:
        coords = {str(k): float(v) for k, v in data["coords"].items()}
    reduce_val = data.get("reduce")
    reference: Any = None
    ref = data.get("reference")
    if ref is not None:
        # The from_file shape is a JSON object whose `type` is the literal
        # string "from_file" and is carried verbatim; everything else is an
        # Expression AST (mirrors the Julia binding's coerce_assertion).
        if isinstance(ref, dict) and ref.get("type") == "from_file":
            reference = dict(ref)
        else:
            reference = _parse_expression(ref)
    return Assertion(
        variable=data["variable"],
        time=float(data["time"]),
        expected=float(data["expected"]),
        tolerance=tol,
        coords=coords,
        reduce=str(reduce_val) if reduce_val is not None else None,
        reference=reference,
    )


def _parse_test(data: Dict[str, Any]) -> Test:
    return Test(
        id=data["id"],
        time_span=_parse_time_span(data["time_span"]),
        assertions=[_parse_assertion(a) for a in data.get("assertions", [])],
        description=data.get("description"),
        initial_conditions=dict(data.get("initial_conditions", {})),
        parameter_overrides=dict(data.get("parameter_overrides", {})),
        tolerance=_parse_tolerance(data["tolerance"]) if "tolerance" in data else None,
    )


def _parse_plot_axis(data: Dict[str, Any]) -> PlotAxis:
    return PlotAxis(variable=data["variable"], label=data.get("label"))


def _parse_plot_value(data: Dict[str, Any]) -> PlotValue:
    return PlotValue(
        variable=data["variable"],
        at_time=data.get("at_time"),
        reduce=data.get("reduce"),
    )


def _parse_plot_series(data: Dict[str, Any]) -> PlotSeries:
    return PlotSeries(name=data["name"], variable=data["variable"])


def _parse_plot(data: Dict[str, Any]) -> Plot:
    raw_y = data["y"]
    explicit_series = [_parse_plot_series(s) for s in data.get("series", [])]
    if isinstance(raw_y, list):
        axes = [_parse_plot_axis(item) for item in raw_y]
        y_axis = axes[0]
        inline_series = [
            PlotSeries(name=axis.label or axis.variable, variable=axis.variable)
            for axis in axes
        ]
        series = explicit_series or inline_series
    else:
        y_axis = _parse_plot_axis(raw_y)
        series = explicit_series
    return Plot(
        id=data["id"],
        type=data["type"],
        x=_parse_plot_axis(data["x"]),
        y=y_axis,
        description=data.get("description"),
        value=_parse_plot_value(data["value"]) if "value" in data else None,
        series=series,
    )


def _parse_sweep_range(data: Dict[str, Any]) -> SweepRange:
    return SweepRange(
        start=float(data["start"]),
        stop=float(data["stop"]),
        count=int(data["count"]),
        scale=data.get("scale"),
    )


def _parse_sweep_dimension(data: Dict[str, Any]) -> SweepDimension:
    return SweepDimension(
        parameter=data["parameter"],
        values=list(data["values"]) if "values" in data else None,
        range=_parse_sweep_range(data["range"]) if "range" in data else None,
    )


def _parse_parameter_sweep(data: Dict[str, Any]) -> ParameterSweep:
    return ParameterSweep(
        type=data["type"],
        dimensions=[_parse_sweep_dimension(d) for d in data.get("dimensions", [])],
    )


def _parse_example(data: Dict[str, Any]) -> Example:
    # ``initial_state`` is a plain scalar-override map {var: number} (v0.8.0);
    # initial fields themselves are declared with `ic` op equations in the model.
    initial_state = None
    if "initial_state" in data:
        initial_state = dict(data["initial_state"])
    sweep = None
    if "parameter_sweep" in data:
        sweep = _parse_parameter_sweep(data["parameter_sweep"])
    return Example(
        id=data["id"],
        time_span=_parse_time_span(data["time_span"]),
        description=data.get("description"),
        initial_state=initial_state,
        parameters=dict(data.get("parameters", {})),
        parameter_sweep=sweep,
        plots=[_parse_plot(p) for p in data.get("plots", [])],
    )


def _parse_model(model_data: Dict[str, Any]) -> Model:
    """Parse a model from JSON data."""
    # Extract variables
    variables = {}
    if "variables" in model_data:
        for var_name, var_data in model_data["variables"].items():
            variables[var_name] = _parse_model_variable(var_data)

    # Extract equations
    equations = []
    if "equations" in model_data:
        for eq_data in model_data["equations"]:
            equations.append(_parse_equation(eq_data))

    # Extract subsystems. Each entry is either a parsed Model, a parsed
    # data loader (RFC pure-io-data-loaders §4.3), or a raw dict carrying a
    # "ref" field to be resolved later by resolve_subsystem_refs.
    subsystems: Dict[str, Any] = {}
    if "subsystems" in model_data:
        for sub_name, sub_data in model_data["subsystems"].items():
            if isinstance(sub_data, dict) and "ref" in sub_data:
                subsystems[sub_name] = sub_data
            elif isinstance(sub_data, dict) and "kind" in sub_data and "source" in sub_data:
                # Inline data-loader subsystem: discriminated from a Model by
                # the loader-only required fields (kind + source); a Model has
                # equations instead. Schema oneOf [Model, DataLoader, SubsystemRef].
                sub_loader = _parse_data_loader(sub_data)
                sub_loader.name = sub_name
                subsystems[sub_name] = sub_loader
            else:
                sub_model = _parse_model(sub_data)
                sub_model.name = sub_name
                subsystems[sub_name] = sub_model

    # Boundary conditions are not a declared model concern (no `bc` op, no
    # `boundary_conditions` field); they are baked into discretization rewrite
    # rules (esm-spec §9.6.8). Nothing to parse here.

    model = Model(name="", variables=variables, equations=equations,
                  subsystems=subsystems)

    if "tolerance" in model_data:
        model.tolerance = _parse_tolerance(model_data["tolerance"])
    if "tests" in model_data:
        model.tests = [_parse_test(t) for t in model_data["tests"]]
    if "examples" in model_data:
        model.examples = [_parse_example(e) for e in model_data["examples"]]

    if "initialization_equations" in model_data and model_data["initialization_equations"] is not None:
        model.initialization_equations = [
            _parse_equation(eq) for eq in model_data["initialization_equations"]
        ]
    if "guesses" in model_data and model_data["guesses"] is not None:
        guesses: Dict[str, Any] = {}
        for var_name, seed in model_data["guesses"].items():
            if isinstance(seed, (int, float)) and not isinstance(seed, bool):
                guesses[var_name] = float(seed)
            else:
                guesses[var_name] = _parse_expression(seed)
        model.guesses = guesses
    if "system_kind" in model_data and model_data["system_kind"] is not None:
        model.system_kind = model_data["system_kind"]

    return model




def _parse_species(species_data: Dict[str, Any]) -> Species:
    """Parse a species from JSON data."""
    return Species(
        name="",  # Name comes from the key
        units=species_data.get("units"),
        default=species_data.get("default"),
        default_units=species_data.get("default_units"),
        description=species_data.get("description"),
        constant=species_data.get("constant"),
    )


def _parse_parameter(param_data: Dict[str, Any]) -> Parameter:
    """Parse a parameter from JSON data."""
    # ``default`` is optional (e.g. grid extent counts resolved from the source
    # at load time). Preserve its absence as ``None`` so a parse/re-emit cycle
    # does not synthesise a spurious ``default: 0.0`` — the serializer only
    # emits ``default`` when ``value`` is numeric.
    value = param_data.get("default")
    return Parameter(
        name="",  # Name comes from the key
        value=value,
        units=param_data.get("units"),
        default_units=param_data.get("default_units"),
        description=param_data.get("description")
    )


def _parse_reaction(reaction_data: Dict[str, Any]) -> Reaction:
    """Parse a reaction from JSON data."""
    rxn_id = reaction_data.get("id")
    name = reaction_data.get("name", rxn_id)

    # Parse reactants (substrates in schema). Preserve `int` vs `float` so a
    # parse/re-emit cycle stays byte-identical for integer-only fixtures and
    # round-trips fractional stoichiometries untouched.
    reactants = {}
    if reaction_data.get("substrates"):
        for substrate in reaction_data["substrates"]:
            species = substrate["species"]
            reactants[species] = substrate["stoichiometry"]

    products = {}
    if reaction_data.get("products"):
        for product in reaction_data["products"]:
            species = product["species"]
            products[species] = product["stoichiometry"]

    # Parse rate
    rate_constant = None
    if "rate" in reaction_data:
        rate_constant = _parse_expression(reaction_data["rate"])

    return Reaction(
        name=name,
        id=rxn_id,
        reactants=reactants,
        products=products,
        rate_constant=rate_constant
    )


def _parse_reaction_system(rs_data: Dict[str, Any]) -> ReactionSystem:
    """Parse a reaction system from JSON data."""
    # Parse species
    species = []
    if "species" in rs_data:
        for species_name, species_data in rs_data["species"].items():
            sp = _parse_species(species_data)
            sp.name = species_name
            species.append(sp)

    # Parse parameters
    parameters = []
    if "parameters" in rs_data:
        for param_name, param_data in rs_data["parameters"].items():
            param = _parse_parameter(param_data)
            param.name = param_name
            parameters.append(param)

    # Parse reactions
    reactions = []
    if "reactions" in rs_data:
        for reaction_data in rs_data["reactions"]:
            reactions.append(_parse_reaction(reaction_data))

    # Parse constraint equations
    constraint_equations = []
    if "constraint_equations" in rs_data:
        for eq_data in rs_data["constraint_equations"]:
            constraint_equations.append(_parse_equation(eq_data))

    # Extract subsystems. Each entry is either a parsed ReactionSystem or a raw
    # dict with a "ref" field to be resolved later by resolve_subsystem_refs.
    subsystems: Dict[str, Any] = {}
    if "subsystems" in rs_data:
        for sub_name, sub_data in rs_data["subsystems"].items():
            if isinstance(sub_data, dict) and "ref" in sub_data:
                subsystems[sub_name] = sub_data
            else:
                sub_rs = _parse_reaction_system(sub_data)
                sub_rs.name = sub_name
                subsystems[sub_name] = sub_rs

    rs = ReactionSystem(
        name="",  # Name comes from the key
        species=species,
        parameters=parameters,
        reactions=reactions,
        constraint_equations=constraint_equations,
        subsystems=subsystems,
    )

    if "tolerance" in rs_data:
        rs.tolerance = _parse_tolerance(rs_data["tolerance"])
    if "tests" in rs_data:
        rs.tests = [_parse_test(t) for t in rs_data["tests"]]
    if "examples" in rs_data:
        rs.examples = [_parse_example(e) for e in rs_data["examples"]]

    return rs


def _parse_reference(ref_data: Dict[str, Any]) -> Reference:
    """Parse a reference from JSON data."""
    return Reference(
        title=ref_data.get("citation", ""),
        authors=[],  # Schema doesn't have authors field
        journal=None,
        year=None,
        doi=ref_data.get("doi"),
        url=ref_data.get("url")
    )


def _parse_metadata(metadata_data: Dict[str, Any]) -> Metadata:
    """Parse metadata from JSON data."""
    references = []
    if "references" in metadata_data:
        for ref_data in metadata_data["references"]:
            references.append(_parse_reference(ref_data))

    return Metadata(
        title=metadata_data["name"],  # Schema uses "name" not "title"
        description=metadata_data.get("description"),
        authors=metadata_data.get("authors", []),
        created=metadata_data.get("created"),
        modified=metadata_data.get("modified"),
        version="1.0",  # Default version
        references=references,
        keywords=metadata_data.get("tags", [])  # Schema uses "tags" not "keywords"
    )


def _parse_data_loader_source(src_data: Dict[str, Any]) -> DataLoaderSource:
    return DataLoaderSource(
        url_template=src_data["url_template"],
        mirrors=list(src_data.get("mirrors", [])),
    )


def _parse_data_loader_temporal(tmp_data: Dict[str, Any]) -> DataLoaderTemporal:
    return DataLoaderTemporal(
        start=tmp_data.get("start"),
        end=tmp_data.get("end"),
        file_period=tmp_data.get("file_period"),
        frequency=tmp_data.get("frequency"),
        records_per_file=tmp_data.get("records_per_file"),
        time_variable=tmp_data.get("time_variable"),
    )


def _parse_data_loader_variable(var_data: Dict[str, Any]) -> DataLoaderVariable:
    unit_conversion = var_data.get("unit_conversion")
    if isinstance(unit_conversion, dict):
        unit_conversion = _parse_expression(unit_conversion)
    reference = None
    if "reference" in var_data:
        reference = _parse_reference(var_data["reference"])
    return DataLoaderVariable(
        file_variable=var_data["file_variable"],
        units=var_data["units"],
        unit_conversion=unit_conversion,
        description=var_data.get("description"),
        reference=reference,
    )


def _parse_data_loader_determinism(det_data: Dict[str, Any]) -> DataLoaderDeterminism:
    """Parse a determinism block from JSON data (esm-spec §8.9.2)."""
    return DataLoaderDeterminism(
        endian=det_data.get("endian"),
        float_format=det_data.get("float_format"),
        integer_width=det_data.get("integer_width"),
    )


def _parse_data_loader(loader_data: Dict[str, Any]) -> DataLoader:
    """Parse a data loader from JSON data."""
    kind = DataLoaderKind(loader_data["kind"])
    source = _parse_data_loader_source(loader_data["source"])

    variables = {
        vname: _parse_data_loader_variable(vdef)
        for vname, vdef in loader_data["variables"].items()
    }

    temporal = None
    if "temporal" in loader_data:
        temporal = _parse_data_loader_temporal(loader_data["temporal"])

    determinism = None
    if "determinism" in loader_data:
        determinism = _parse_data_loader_determinism(loader_data["determinism"])

    reference = None
    if "reference" in loader_data:
        reference = _parse_reference(loader_data["reference"])

    metadata = dict(loader_data.get("metadata", {}))

    return DataLoader(
        name="",  # Name comes from the key
        kind=kind,
        source=source,
        variables=variables,
        temporal=temporal,
        determinism=determinism,
        reference=reference,
        metadata=metadata,
    )


def _parse_operator(operator_data: Dict[str, Any]) -> Operator:
    """Parse an operator from JSON data."""
    # Use schema fields directly
    operator_id = operator_data.get("operator_id", "")
    needed_vars = operator_data.get("needed_vars", [])
    modifies = operator_data.get("modifies")
    config = operator_data.get("config", {})
    description = operator_data.get("description")
    reference = None
    if "reference" in operator_data:
        reference = _parse_reference(operator_data["reference"])

    return Operator(
        operator_id=operator_id,
        needed_vars=needed_vars,
        modifies=modifies,
        reference=reference,
        config=config,
        description=description
    )


def _parse_registered_function(rf_data: Dict[str, Any]) -> 'RegisteredFunction':
    """Parse a registered_functions entry from JSON data (esm-spec §9.2)."""
    from .esm_types import RegisteredFunction, RegisteredFunctionSignature

    sig_data = rf_data.get("signature", {})
    signature = RegisteredFunctionSignature(
        arg_count=sig_data.get("arg_count", 0),
        arg_types=sig_data.get("arg_types"),
        return_type=sig_data.get("return_type"),
    )

    references = []
    for ref_data in rf_data.get("references", []) or []:
        references.append(_parse_reference(ref_data))

    return RegisteredFunction(
        id=rf_data.get("id", ""),
        signature=signature,
        units=rf_data.get("units"),
        arg_units=rf_data.get("arg_units"),
        description=rf_data.get("description"),
        references=references,
        config=rf_data.get("config", {}) or {},
    )


def _parse_coupling_entry(coupling_data: Dict[str, Any]) -> CouplingEntry:
    """Parse a coupling entry from JSON data."""
    # Get coupling type from schema
    schema_type = coupling_data["type"]

    # Map schema types to our enum
    type_mapping = {
        "operator_compose": CouplingType.OPERATOR_COMPOSE,
        "couple": CouplingType.COUPLE,
        "variable_map": CouplingType.VARIABLE_MAP,
        "operator_apply": CouplingType.OPERATOR_APPLY,
        "callback": CouplingType.CALLBACK,
        "event": CouplingType.EVENT,
    }

    if schema_type not in type_mapping:
        raise ValueError(f"Unknown coupling type: {schema_type}")

    coupling_type = type_mapping[schema_type]
    description = coupling_data.get("description")

    # Create appropriate coupling entry based on type
    if coupling_type == CouplingType.OPERATOR_COMPOSE:
        return OperatorComposeCoupling(
            description=description,
            systems=coupling_data.get("systems", []),
            translate=coupling_data.get("translate", {}),
            lifting=coupling_data.get("lifting"),
        )

    elif coupling_type == CouplingType.COUPLE:
        # Parse connector if present
        connector = None
        if "connector" in coupling_data:
            connector_data = coupling_data["connector"]
            equations = []
            for eq_data in connector_data.get("equations", []):
                equation = ConnectorEquation(
                    from_var=eq_data["from"],
                    to_var=eq_data["to"],
                    transform=eq_data["transform"],
                    expression=_parse_expression(eq_data["expression"]) if "expression" in eq_data else None
                )
                equations.append(equation)
            connector = Connector(equations=equations)

        return CouplingCouple(
            description=description,
            systems=coupling_data.get("systems", []),
            connector=connector
        )

    elif coupling_type == CouplingType.VARIABLE_MAP:
        return VariableMapCoupling(
            description=description,
            from_var=coupling_data.get("from"),
            to_var=coupling_data.get("to"),
            transform=coupling_data.get("transform"),
            factor=coupling_data.get("factor")
        )

    elif coupling_type == CouplingType.OPERATOR_APPLY:
        return OperatorApplyCoupling(
            description=description,
            operator=coupling_data.get("operator")
        )

    elif coupling_type == CouplingType.CALLBACK:
        return CallbackCoupling(
            description=description,
            callback_id=coupling_data.get("callback_id"),
            config=coupling_data.get("config", {})
        )

    elif coupling_type == CouplingType.EVENT:
        # Parse conditions
        conditions = []
        if "conditions" in coupling_data:
            conditions = [_parse_expression(cond) for cond in coupling_data["conditions"]]

        # Parse trigger for discrete events
        trigger = None
        if "trigger" in coupling_data:
            trigger = _parse_discrete_event_trigger(coupling_data["trigger"])

        # Parse affects
        affects = []
        if "affects" in coupling_data:
            affects = [_parse_affect_equation(affect) for affect in coupling_data["affects"]]

        # Parse functional_affect (FunctionalAffect object)
        if "functional_affect" in coupling_data:
            functional_affect = _parse_functional_affect(coupling_data["functional_affect"])
            affects.append(functional_affect)

        # Parse affect_neg
        affect_neg = []
        if "affect_neg" in coupling_data and coupling_data["affect_neg"] is not None:
            for affect in coupling_data["affect_neg"]:
                if isinstance(affect, dict) and "handler_id" in affect:
                    # This is a functional affect
                    affect_neg.append(_parse_functional_affect(affect))
                else:
                    # This is a regular affect equation
                    affect_neg.append(_parse_affect_equation(affect))

        return EventCoupling(
            description=description,
            event_type=coupling_data.get("event_type"),
            conditions=conditions,
            trigger=trigger,
            affects=affects,
            affect_neg=affect_neg,
            discrete_parameters=coupling_data.get("discrete_parameters", []),
            root_find=coupling_data.get("root_find"),
            reinitialize=coupling_data.get("reinitialize")
        )

    else:
        raise ValueError(f"Unknown coupling type: {coupling_type}")


def _parse_domain(domain_data: Dict[str, Any]) -> Domain:
    """Parse domain configuration from JSON data."""
    domain = Domain()

    if "independent_variable" in domain_data:
        domain.independent_variable = domain_data["independent_variable"]

    # Parse temporal domain
    if "temporal" in domain_data:
        temporal_data = domain_data["temporal"]
        domain.temporal = TemporalDomain(
            start=temporal_data.get("start"),
            end=temporal_data.get("end"),
            reference_time=temporal_data.get("reference_time")
        )

    # Initial conditions are no longer a domain-level concept (v0.8.0): they are
    # declared with `ic` op equations in the model (esm-spec §11.4).

    return domain


def _validate_domain(domain: Domain) -> None:
    """Validate domain configuration for consistency and semantic correctness."""
    errors = []

    # Validate temporal domain
    if domain.temporal and domain.temporal.start is not None and domain.temporal.end is not None:
        try:
            from datetime import datetime
            start_dt = datetime.fromisoformat(domain.temporal.start.replace('Z', '+00:00'))
            end_dt = datetime.fromisoformat(domain.temporal.end.replace('Z', '+00:00'))

            if start_dt >= end_dt:
                errors.append("Temporal domain: start time must be before end time")

            if domain.temporal.reference_time:
                ref_dt = datetime.fromisoformat(domain.temporal.reference_time.replace('Z', '+00:00'))
                if ref_dt < start_dt or ref_dt > end_dt:
                    errors.append("Temporal domain: reference time must be within start and end times")
        except ValueError as e:
            errors.append(f"Temporal domain: invalid datetime format - {e}")

    if errors:
        raise ValueError("Domain validation failed:\n" + "\n".join(f"  - {error}" for error in errors))


def _parse_esm_data(data: Dict[str, Any]) -> EsmFile:
    """Parse ESM data from validated JSON."""
    # Parse metadata
    metadata = _parse_metadata(data["metadata"])

    # Parse models
    models = {}
    if "models" in data:
        for model_name, model_data in data["models"].items():
            # A top-level model included by reference (schema top-level
            # `models` oneOf[Model, SubsystemRef]) is carried verbatim as a
            # {"ref": ...} dict and spliced later by resolve_model_refs —
            # mirroring how subsystem refs are carried in Model.subsystems.
            # Resolution is deferred because it needs base_path, which is not
            # available here.
            if isinstance(model_data, dict) and "ref" in model_data:
                models[model_name] = model_data
                continue
            model = _parse_model(model_data)
            model.name = model_name
            models[model_name] = model

    # Parse reaction systems
    reaction_systems = {}
    if "reaction_systems" in data:
        for rs_name, rs_data in data["reaction_systems"].items():
            rs = _parse_reaction_system(rs_data)
            rs.name = rs_name
            reaction_systems[rs_name] = rs

    # Parse the single shared domain if present (v0.8.0: one `domain` object,
    # not a map of named domains).
    domain = None
    if "domain" in data and data["domain"] is not None:
        domain = _parse_domain(data["domain"])
        _validate_domain(domain)

    # Parse the document-scoped index-set registry (RFC semiring-faq-unified-ir
    # §5.2). As of v0.8.0 this is a single, top-level registry shared by every
    # model — a sibling of ``models`` / ``domain`` — not a per-Model field.
    # Carried through verbatim as IndexSet dicts; the schema validates shape and
    # the aggregate evaluator resolves {"from": <name>} references.
    index_sets: Dict[str, Any] = {}
    if "index_sets" in data and data["index_sets"] is not None:
        index_sets = dict(data["index_sets"])

    # Parse data loaders
    data_loaders: Dict[str, DataLoader] = {}
    if "data_loaders" in data:
        for loader_name, loader_data in data["data_loaders"].items():
            loader = _parse_data_loader(loader_data)
            loader.name = loader_name
            data_loaders[loader_name] = loader

    # Parse operators
    operators = []
    if "operators" in data:
        for op_name, op_data in data["operators"].items():
            operator = _parse_operator(op_data)
            operator.name = op_name
            operators.append(operator)

    # Parse registered_functions (esm-spec §9.2 — DEPRECATED in v0.3.0)
    registered_functions = {}
    if "registered_functions" in data:
        for rf_name, rf_data in data["registered_functions"].items():
            registered_functions[rf_name] = _parse_registered_function(rf_data)

    # Parse top-level enums block (esm-spec §9.3). Values are validated to be
    # positive integers by the schema; unique-within-enum is also enforced.
    enums: Dict[str, Dict[str, int]] = {}
    if "enums" in data and data["enums"] is not None:
        for enum_name, mapping in data["enums"].items():
            if not isinstance(mapping, dict):
                raise ValueError(
                    f"enums/{enum_name}: must be an object mapping symbol names "
                    f"to positive integers (esm-spec §9.3)"
                )
            seen_values: Dict[int, str] = {}
            decoded: Dict[str, int] = {}
            for sym, val in mapping.items():
                if not isinstance(val, int) or isinstance(val, bool) or val < 1:
                    raise ValueError(
                        f"enums/{enum_name}/{sym}: value must be a positive "
                        f"integer (got {val!r})"
                    )
                if val in seen_values:
                    raise ValueError(
                        f"enums/{enum_name}: duplicate value {val} for symbols "
                        f"`{seen_values[val]}` and `{sym}` (values must be unique "
                        f"within an enum, esm-spec §9.3)"
                    )
                seen_values[val] = sym
                decoded[sym] = val
            enums[enum_name] = decoded

    # Parse coupling entries
    coupling = []
    if "coupling" in data:
        for coupling_data in data["coupling"]:
            coupling.append(_parse_coupling_entry(coupling_data))

    # Parse function_tables (esm-spec §9.5, v0.4.0). Each entry is a
    # FunctionTable carrying named axes plus literal nested-array data,
    # referenced by table_lookup AST nodes.
    function_tables: Dict[str, FunctionTable] = {}
    if "function_tables" in data and data["function_tables"] is not None:
        ft_map = data["function_tables"]
        if not isinstance(ft_map, dict):
            raise ValueError(
                "Top-level 'function_tables' must be an object keyed by table id "
                f"(esm-spec §9.5). Got: {type(ft_map).__name__}"
            )
        for ft_name, ft_data in ft_map.items():
            axes_raw = ft_data.get("axes")
            if not isinstance(axes_raw, list):
                raise ValueError(
                    f"function_tables['{ft_name}']: 'axes' must be a list "
                    f"(esm-spec §9.5)"
                )
            axes = [
                FunctionTableAxis(
                    name=a["name"],
                    values=list(a["values"]),
                    units=a.get("units"),
                )
                for a in axes_raw
            ]
            if "data" not in ft_data:
                raise ValueError(
                    f"function_tables['{ft_name}']: 'data' is required "
                    f"(esm-spec §9.5)"
                )
            function_tables[ft_name] = FunctionTable(
                axes=axes,
                data=copy.deepcopy(ft_data["data"]),
                description=ft_data.get("description"),
                interpolation=ft_data.get("interpolation"),
                out_of_bounds=ft_data.get("out_of_bounds"),
                outputs=list(ft_data["outputs"]) if "outputs" in ft_data else None,
                shape=list(ft_data["shape"]) if "shape" in ft_data else None,
                schema_version=ft_data.get("schema_version"),
            )

    # Collect events from models and reaction systems
    events = []

    # Collect events from models
    if "models" in data:
        for model_name, model_data in data["models"].items():
            if "discrete_events" in model_data:
                for event_data in model_data["discrete_events"]:
                    events.append(_parse_discrete_event(event_data))
            if "continuous_events" in model_data:
                for event_data in model_data["continuous_events"]:
                    events.append(_parse_continuous_event(event_data))

    # Collect events from reaction systems
    if "reaction_systems" in data:
        for rs_name, rs_data in data["reaction_systems"].items():
            if "discrete_events" in rs_data:
                for event_data in rs_data["discrete_events"]:
                    events.append(_parse_discrete_event(event_data))
            if "continuous_events" in rs_data:
                for event_data in rs_data["continuous_events"]:
                    events.append(_parse_continuous_event(event_data))

    return EsmFile(
        version=data["esm"],
        metadata=metadata,
        models=models,
        reaction_systems=reaction_systems,
        events=events,
        data_loaders=data_loaders,
        operators=operators,
        registered_functions=registered_functions,
        enums=enums,
        function_tables=function_tables,
        coupling=coupling,
        domain=domain,
        index_sets=index_sets,
    )


def _fetch_ref_content(ref: str, base_path: str) -> str:
    """Fetch content from a subsystem ref (URL or file path).

    Args:
        ref: The reference string (URL or relative file path)
        base_path: The base directory for resolving relative paths

    Returns:
        The file content as a string

    Raises:
        SubsystemRefError: If the reference cannot be fetched or read
    """
    if ref.startswith("http://") or ref.startswith("https://"):
        import urllib.request
        import urllib.error
        try:
            with urllib.request.urlopen(ref) as response:
                return response.read().decode("utf-8")
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            raise SubsystemRefError(
                f"Failed to fetch subsystem ref URL '{ref}': {e}"
            )
    else:
        resolved = os.path.normpath(os.path.join(base_path, ref))
        if not os.path.exists(resolved):
            raise SubsystemRefError(
                f"Subsystem ref file not found: '{resolved}' "
                f"(resolved from '{ref}' relative to '{base_path}')"
            )
        with open(resolved, "r") as f:
            return f.read()


def _subsystem_ref_bindings(sub_value: Dict[str, Any], where: str) -> Dict[str, int]:
    """Extract the optional metaparameter ``bindings`` of a §4.7 subsystem
    ref (esm-spec §9.7.6 binding site 3), validating integer values."""
    from .lower_expression_templates import ExpressionTemplateError

    bindings: Dict[str, int] = {}
    raw = sub_value.get("bindings")
    if isinstance(raw, dict):
        for bk, bv in raw.items():
            if not isinstance(bv, int) or isinstance(bv, bool):
                raise ExpressionTemplateError(
                    "metaparameter_type_error",
                    f"{where}: binding '{bk}' is not an integer "
                    "(esm-spec §9.7.6)",
                )
            bindings[str(bk)] = bv
    return bindings


def _load_ref_data(
    ref_str: str,
    base_path: str,
    bindings: Dict[str, int],
    kind: str,
) -> tuple:
    """Fetch, gate, schema-validate, §9.7-resolve, and template-lower a
    referenced ESM document (esm-spec §4.7 / §9.7.6 binding site 3).

    Returns ``(ref_data, new_base)`` where ``ref_data`` is the resolved,
    lowered raw dict (ready for ``_parse_esm_data``) and ``new_base`` the
    directory anchoring the referenced file's own nested refs. A ref that
    targets a template-library file is rejected with the stable
    ``subsystem_ref_is_template_library`` diagnostic (esm-spec §9.7.1): the
    two reference mechanisms are disjoint.
    """
    from .lower_expression_templates import (
        ExpressionTemplateError,
        lower_expression_templates,
        reject_expression_templates_pre_v04,
    )
    from .template_imports import (
        _is_template_library_doc,
        reject_template_imports_pre_v08,
        resolve_template_machinery,
    )

    content = _fetch_ref_content(ref_str, base_path)
    ref_data = json.loads(content)

    # Determine the new base_path for nested refs (and template imports).
    if ref_str.startswith("http://") or ref_str.startswith("https://"):
        new_base = ref_str.rsplit("/", 1)[0] if "/" in ref_str else base_path
    else:
        resolved_path = os.path.normpath(os.path.join(base_path, ref_str))
        new_base = os.path.dirname(resolved_path)

    reject_expression_templates_pre_v04(ref_data)
    reject_template_imports_pre_v08(ref_data)

    # A §4.7 subsystem ref MUST NOT target a template-library file — the two
    # reference mechanisms are disjoint (esm-spec §9.7.1).
    if _is_template_library_doc(ref_data):
        raise ExpressionTemplateError(
            "subsystem_ref_is_template_library",
            f"Subsystem ref '{ref_str}' targets a template-library file; "
            "libraries are imported via expression_template_imports "
            "(esm-spec §9.7.1)",
        )

    # Validate the referenced file against the schema.
    schema = _get_schema()
    try:
        validate(ref_data, schema)
    except jsonschema.ValidationError as e:
        raise SubsystemRefError(
            f"Schema validation failed for {kind} ref '{ref_str}': {e.message}"
        )

    # Resolve the referenced document's §9.7 machinery with this edge's
    # metaparameter bindings (esm-spec §9.7.6 binding site 3), then run the
    # §9.6.3 rewrite fixpoint so the inlined component carries only normal
    # Expression ASTs (Option A round-trip).
    resolved = resolve_template_machinery(
        ref_data, new_base, metaparameters=bindings)
    if resolved is not None:
        ref_data = resolved
    ref_data = lower_expression_templates(ref_data)

    return ref_data, new_base


def _resolve_model_subsystems(
    model: Model,
    base_path: str,
    seen_refs: set,
) -> None:
    """Recursively resolve subsystem refs within a Model.

    Args:
        model: The model whose subsystems should be resolved
        base_path: The base directory for resolving relative paths
        seen_refs: Set of already-seen ref strings for circular detection
    """
    if not model.subsystems:
        return

    resolved_subsystems: Dict[str, Any] = {}
    for sub_name, sub_value in model.subsystems.items():
        # During parsing, a ref object comes through as a dict with a "ref" key
        # before being coerced to a Model.
        if isinstance(sub_value, dict) and "ref" in sub_value:
            ref_str = sub_value["ref"]

            # Circular reference detection
            canonical = os.path.normpath(os.path.join(base_path, ref_str)) \
                if not ref_str.startswith("http") else ref_str
            if canonical in seen_refs:
                raise CircularReferenceError(
                    f"Circular subsystem reference detected: '{ref_str}' "
                    f"(chain: {' -> '.join(seen_refs)} -> {canonical})"
                )
            new_seen = seen_refs | {canonical}

            # Optional `bindings` close the referenced document's open
            # metaparameters at this edge (esm-spec §9.7.6 binding site 3).
            bindings = _subsystem_ref_bindings(sub_value, f"subsystems.{sub_name}")
            ref_data, new_base = _load_ref_data(
                ref_str, base_path, bindings, "subsystem")

            parsed = _parse_esm_data(ref_data)

            # Extract the single top-level model or data loader. A referenced
            # file with exactly one top-level data loader (RFC pure-io-data-loaders
            # §4.4) resolves to that loader, named by the parent subsystem key.
            if parsed.models:
                # Take the first (and expected-only) model
                sub_model = next(iter(parsed.models.values()))
                sub_model.name = sub_name
                # Recursively resolve nested subsystem refs
                _resolve_model_subsystems(sub_model, new_base, new_seen)
                resolved_subsystems[sub_name] = sub_model
            elif parsed.data_loaders:
                # Single-loader file: a data loader has no subsystems, so there
                # is nothing further to resolve.
                sub_loader = next(iter(parsed.data_loaders.values()))
                sub_loader.name = sub_name
                resolved_subsystems[sub_name] = sub_loader
            else:
                raise SubsystemRefError(
                    f"Subsystem ref '{ref_str}' does not contain a model or data loader"
                )
        else:
            # Already a Model object, just recurse into it
            if isinstance(sub_value, Model):
                _resolve_model_subsystems(sub_value, base_path, seen_refs)
            resolved_subsystems[sub_name] = sub_value

    model.subsystems = resolved_subsystems


def _resolve_reaction_system_subsystems(
    rs: ReactionSystem,
    base_path: str,
    seen_refs: set,
) -> None:
    """Recursively resolve subsystem refs within a ReactionSystem.

    Args:
        rs: The reaction system whose subsystems should be resolved
        base_path: The base directory for resolving relative paths
        seen_refs: Set of already-seen ref strings for circular detection
    """
    if not rs.subsystems:
        return

    resolved_subsystems: Dict[str, Any] = {}
    for sub_name, sub_value in rs.subsystems.items():
        if isinstance(sub_value, dict) and "ref" in sub_value:
            ref_str = sub_value["ref"]

            canonical = os.path.normpath(os.path.join(base_path, ref_str)) \
                if not ref_str.startswith("http") else ref_str
            if canonical in seen_refs:
                raise CircularReferenceError(
                    f"Circular subsystem reference detected: '{ref_str}' "
                    f"(chain: {' -> '.join(seen_refs)} -> {canonical})"
                )
            new_seen = seen_refs | {canonical}

            bindings = _subsystem_ref_bindings(sub_value, f"subsystems.{sub_name}")
            ref_data, new_base = _load_ref_data(
                ref_str, base_path, bindings, "subsystem")

            parsed = _parse_esm_data(ref_data)

            # Extract the single top-level reaction system
            if parsed.reaction_systems:
                sub_rs = next(iter(parsed.reaction_systems.values()))
                sub_rs.name = sub_name
                _resolve_reaction_system_subsystems(sub_rs, new_base, new_seen)
                resolved_subsystems[sub_name] = sub_rs
            else:
                raise SubsystemRefError(
                    f"Subsystem ref '{ref_str}' does not contain a reaction system"
                )
        else:
            if isinstance(sub_value, ReactionSystem):
                _resolve_reaction_system_subsystems(sub_value, base_path, seen_refs)
            resolved_subsystems[sub_name] = sub_value

    rs.subsystems = resolved_subsystems


def resolve_subsystem_refs(esm_file: EsmFile, base_path: str) -> None:
    """Resolve all subsystem references in an ESM file.

    Walks all subsystems in models and reaction_systems. For each subsystem
    value with a ``ref`` field:

    - If the ref starts with ``http://`` or ``https://``, the content is
      fetched via urllib.
    - Otherwise the ref is resolved relative to *base_path* and read from
      the filesystem.

    The referenced file is parsed, the single top-level model or reaction
    system is extracted, and the reference is replaced with the resolved
    content. Resolution is recursive, and circular references are detected.

    Args:
        esm_file: The parsed ESM file to resolve references in (modified in place)
        base_path: The base directory for resolving relative file paths

    Raises:
        CircularReferenceError: If circular subsystem references are detected
        SubsystemRefError: If a reference cannot be resolved or is invalid
    """
    seen: set = set()

    for model in esm_file.models.values():
        _resolve_model_subsystems(model, base_path, seen)

    for rs in esm_file.reaction_systems.values():
        _resolve_reaction_system_subsystems(rs, base_path, seen)


def resolve_model_refs(esm_file: EsmFile, base_path: str) -> None:
    """Resolve all top-level model references in an ESM file.

    The top-level analog of :func:`resolve_subsystem_refs`. Walks
    ``esm_file.models``; any entry whose value is an unresolved
    ``{"ref": "<file|url>"}`` dict — carried verbatim by ``_parse_esm_data``
    and permitted by the schema's top-level ``models``
    ``oneOf[Model, SubsystemRef]`` — is fetched, schema-validated, and its
    single top-level model is spliced into ``models[X]`` under the SAME key
    ``X`` with ``name = X``.

    Because flatten collects the spliced model with prefix ``X``, its flat
    variable names ``X.<var>`` already equal the coupling-edge endpoint names —
    a coupled document that imports its components by name assembles with zero
    coupling-edge rewrites. This generalizes the existing ref mechanism to the
    top-level ``models`` map; it introduces no new primitive.

    Resolution reuses ``_fetch_ref_content`` + ``_parse_esm_data`` and then
    recursively resolves the spliced model's own subsystem refs (relative to
    the referenced file's directory) via ``_resolve_model_subsystems``.

    Must run BEFORE :func:`resolve_subsystem_refs` so that every top-level
    entry is a concrete ``Model`` before the subsystem walk — which assumes
    ``model.subsystems`` exists — visits it.

    Args:
        esm_file: The parsed ESM file to resolve references in (modified in place)
        base_path: The base directory for resolving relative file paths

    Raises:
        CircularReferenceError: If circular references are detected
        SubsystemRefError: If a reference cannot be resolved or does not
            contain a top-level model
    """
    resolved_models: Dict[str, Any] = {}
    for model_name, model_value in esm_file.models.items():
        # An already-parsed Model (inline definition) passes through unchanged.
        if not (isinstance(model_value, dict) and "ref" in model_value):
            resolved_models[model_name] = model_value
            continue

        ref_str = model_value["ref"]

        # Circular reference detection. Seed the chain with this ref so a
        # subsystem inside the referenced file that points back is caught.
        canonical = os.path.normpath(os.path.join(base_path, ref_str)) \
            if not ref_str.startswith("http") else ref_str
        seen = {canonical}

        bindings = _subsystem_ref_bindings(model_value, f"models.{model_name}")
        ref_data, new_base = _load_ref_data(ref_str, base_path, bindings, "model")

        parsed = _parse_esm_data(ref_data)

        # A top-level model ref must resolve to exactly one model. Unlike a
        # subsystem ref, a data loader or reaction system is not a valid
        # top-level model component.
        if not parsed.models:
            raise SubsystemRefError(
                f"Model ref '{ref_str}' does not contain a top-level model"
            )

        sub_model = next(iter(parsed.models.values()))
        sub_model.name = model_name
        # Recursively resolve the spliced model's own subsystem refs, relative
        # to the referenced file's directory.
        _resolve_model_subsystems(sub_model, new_base, seen)
        resolved_models[model_name] = sub_model

    esm_file.models = resolved_models


# Operator arity requirements: (min_args, max_args). None = unlimited.
_OPERATOR_ARITY = {
    "+": (2, None), "-": (1, None), "*": (2, None), "/": (2, 2),
    # `grad`/`div` accept an optional second operand: a per-field boundary
    # (Dirichlet inflow) metavariable bound by a two-arg `grad(f, inflow, dim)`
    # expression-template `match` (esm-spec §9.6; the schema does not constrain
    # grad/div arity — the second arg supplies that field's own loaded BC).
    "^": (2, 2), "D": (1, 1), "ic": (1, 1), "grad": (1, 2), "div": (1, 2),
    "laplacian": (1, 1), "exp": (1, 1), "log": (1, 1), "log10": (1, 1),
    "sqrt": (1, 1), "abs": (1, 1), "sin": (1, 1), "cos": (1, 1),
    "tan": (1, 1), "asin": (1, 1), "acos": (1, 1), "atan": (1, 1),
    "atan2": (2, 2),
    "sinh": (1, 1), "cosh": (1, 1), "tanh": (1, 1),
    "asinh": (1, 1), "acosh": (1, 1), "atanh": (1, 1),
    "min": (2, None), "max": (2, None),
    "floor": (1, 1), "ceil": (1, 1), "ifelse": (3, 3),
    ">": (2, 2), "<": (2, 2), ">=": (2, 2), "<=": (2, 2),
    "==": (2, 2), "!=": (2, 2), "and": (2, None), "or": (2, None),
    "not": (1, 1), "Pre": (1, 1), "sign": (1, 1),
    # Closed function registry (esm-spec §9.2 / §9.3). `fn` arity is checked
    # by the dispatcher (1 for datetime.*, 2 for interp.searchsorted).
    "enum": (2, 2),
    "const": (0, 0),
}

# Built-in symbols always available in expressions
_BUILTIN_SYMBOLS = frozenset({
    "t", "pi", "e", "true", "false",
    "x", "y", "z", "lon", "lat", "lev", "longitude", "latitude", "level",
})

# Pint-compatible unit aliases for normalizing
_UNIT_ALIASES = {
    "1": "dimensionless", "": "dimensionless", "dimensionless": "dimensionless",
}


def _walk_expression_strings(expr) -> List[str]:
    """Recursively collect string args from inside op-expression nodes only."""
    result = []
    if isinstance(expr, dict) and "op" in expr and "args" in expr:
        for arg in expr["args"]:
            if isinstance(arg, str):
                result.append(arg)
            elif isinstance(arg, dict):
                result.extend(_walk_expression_strings(arg))
    return result


def _check_expression_arity(expr, errors: List[str], path: str) -> None:
    """Walk an expression tree and check operator arity."""
    if isinstance(expr, dict) and "op" in expr and "args" in expr:
        op = expr["op"]
        args = expr["args"]
        if op in _OPERATOR_ARITY:
            min_args, max_args = _OPERATOR_ARITY[op]
            n = len(args)
            if n < min_args:
                errors.append(
                    f"{path}: operator '{op}' requires at least {min_args} args, got {n}"
                )
            elif max_args is not None and n > max_args:
                errors.append(
                    f"{path}: operator '{op}' accepts at most {max_args} args, got {n}"
                )
        for i, arg in enumerate(args):
            _check_expression_arity(arg, errors, f"{path}/args[{i}]")


def _normalize_unit(unit: str) -> str:
    """Normalize a unit string for compatibility comparison."""
    if unit is None:
        return "dimensionless"
    return _UNIT_ALIASES.get(unit.strip(), unit.strip())


def _units_compatible(u1: str, u2: str) -> bool:
    """Check if two unit strings represent compatible (same dimension) quantities."""
    n1 = _normalize_unit(u1)
    n2 = _normalize_unit(u2)
    if n1 == n2:
        return True
    try:
        import pint
        ureg = pint.UnitRegistry()
        q1 = ureg(n1) if n1 != "dimensionless" else ureg("dimensionless")
        q2 = ureg(n2) if n2 != "dimensionless" else ureg("dimensionless")
        return q1.dimensionality == q2.dimensionality
    except Exception:
        return n1 == n2


def _build_symbol_tables(data: Dict[str, Any]) -> Dict[str, Any]:
    """Build symbol tables for all systems and global symbols in the file."""
    models = {}
    # Top-level models included by reference (schema `models`
    # oneOf[Model, SubsystemRef]). Their variables live in the referenced file,
    # which is not loaded during structural validation, so they are registered
    # as known systems with no known variables and var-existence checks against
    # them are skipped (see _resolve_scoped_ref) — mirroring the leniency
    # already applied to subsystem-nested refs.
    ref_systems = set()
    for mname, m in data.get("models", {}).items():
        if isinstance(m, dict) and "ref" in m:
            ref_systems.add(mname)
            models[mname] = {}
            continue
        var_info = {}
        for vname, vdef in m.get("variables", {}).items():
            var_info[vname] = vdef
        models[mname] = var_info

    reaction_systems = {}
    for rsname, rs in data.get("reaction_systems", {}).items():
        sym_info = {}
        for sname, sdef in rs.get("species", {}).items():
            sym_info[sname] = {"type": "species", **sdef}
        for pname, pdef in rs.get("parameters", {}).items():
            sym_info[pname] = {"type": "parameter", **pdef}
        reaction_systems[rsname] = sym_info

    data_loaders = {}
    for dname, d in data.get("data_loaders", {}).items():
        loader_info = {}
        for vname, vdef in d.get("variables", {}).items():
            loader_info[vname] = vdef
        data_loaders[dname] = loader_info

    # Global symbol set: all variable/species/parameter names anywhere
    global_symbols = set(_BUILTIN_SYMBOLS)
    for m in models.values():
        global_symbols.update(m.keys())
    for rs in reaction_systems.values():
        global_symbols.update(rs.keys())
    for d in data_loaders.values():
        global_symbols.update(d.keys())
    # Add spatial dim names from the single shared domain, if it declares any.
    dom = data.get("domain")
    if isinstance(dom, dict):
        global_symbols.update(dom.get("spatial", {}).keys())

    return {
        "models": models,
        "reaction_systems": reaction_systems,
        "data_loaders": data_loaders,
        "global_symbols": global_symbols,
        "all_systems": set(models.keys()) | set(reaction_systems.keys()) | set(data_loaders.keys()),
        "ref_systems": ref_systems,
    }


def _resolve_scoped_ref(ref: str, tables: Dict[str, Any]) -> tuple:
    """
    Try to resolve a 'System.var' style reference.
    Returns (system_name, var_name, status) where status is one of:
    - 'ok': resolved successfully
    - 'no_system': system not found
    - 'no_var': system found but variable not in it
    - 'not_scoped': ref doesn't have a dot
    """
    if "." not in ref:
        return (None, None, "not_scoped")
    parts = ref.split(".")
    system = parts[0]
    var = parts[-1]
    if system not in tables["all_systems"]:
        return (system, var, "no_system")
    # A model included by reference has its variables in another file not
    # available during structural validation — accept any var against it
    # (deferred to resolve_model_refs, which schema-validates the referenced
    # file, and to coupling/flatten resolution). Mirrors the leniency for
    # subsystem-nested (3+ part) refs.
    if system in tables.get("ref_systems", set()):
        return (system, var, "ok")
    # Check if var exists in that system
    if system in tables["models"]:
        if var in tables["models"][system]:
            return (system, var, "ok")
    if system in tables["reaction_systems"]:
        if var in tables["reaction_systems"][system]:
            return (system, var, "ok")
    if system in tables["data_loaders"]:
        if var in tables["data_loaders"][system]:
            return (system, var, "ok")
    return (system, var, "no_var")


def _check_variable_references(data: Dict[str, Any], tables: Dict[str, Any], errors: List[str]) -> None:
    """
    Check variable references in equations.

    Two flavors of check:
    1. Scoped refs (Model.var): system must exist; for 2-part refs the var must exist
       in the named system.
    2. Bare-string refs in the RHS of D() (derivative) equations: every ref must
       resolve to a symbol declared somewhere in the file. Plain assignment-style
       equations are not checked because they often use coupled-in vars.
    """
    global_symbols = tables["global_symbols"]
    for mname, m in data.get("models", {}).items():
        for i, eq in enumerate(m.get("equations", [])):
            lhs_is_derivative = (
                isinstance(eq.get("lhs"), dict) and eq["lhs"].get("op") == "D"
            )
            for side in ("lhs", "rhs"):
                if side not in eq:
                    continue
                refs = _walk_expression_strings(eq[side])
                for ref in refs:
                    # `_var` is the reserved operator placeholder (spec §6.4):
                    # in an operator-style model it is substituted with each
                    # matching state variable of the target system at
                    # operator_compose time. It is never a declared symbol, so
                    # it is a valid reference at ANY nesting depth — not merely
                    # in the top-level `D(_var)` derivative position, but also
                    # when nested inside an operator, e.g. the canonical
                    # advection idiom `grad(_var, dim)`. Skip it so it is not
                    # flagged as an undefined variable reference.
                    if ref == "_var":
                        continue
                    if "." in ref:
                        # 3+ part refs may use subsystem nesting; only check top-level system
                        if ref.count(".") > 1:
                            top_system = ref.split(".")[0]
                            if top_system not in tables["all_systems"]:
                                errors.append(
                                    f"models/{mname}/equations[{i}]: reference '{ref}' to undefined system '{top_system}'"
                                )
                            continue
                        system, var, status = _resolve_scoped_ref(ref, tables)
                        if status == "no_system":
                            errors.append(
                                f"models/{mname}/equations[{i}]: reference '{ref}' to undefined system '{system}'"
                            )
                        elif status == "no_var":
                            errors.append(
                                f"models/{mname}/equations[{i}]: reference '{ref}' — variable '{var}' not found in system '{system}'"
                            )
                    else:
                        # Bare-string refs only checked inside derivative equations
                        if lhs_is_derivative and side == "rhs":
                            if ref not in global_symbols:
                                errors.append(
                                    f"models/{mname}/equations[{i}]: undefined variable reference '{ref}'"
                                )


def _check_coupling_references(data: Dict[str, Any], tables: Dict[str, Any], errors: List[str]) -> None:
    """Check that coupling 'from' references resolve to valid scoped refs.
    'to' is intentionally lenient since variable_map can introduce new target vars."""
    for i, c in enumerate(data.get("coupling", [])):
        ref = c.get("from")
        if not isinstance(ref, str) or "." not in ref:
            continue
        # For 3+ part refs (subsystem nesting), only verify the top-level system exists
        if ref.count(".") > 1:
            top_system = ref.split(".")[0]
            if top_system not in tables["all_systems"]:
                errors.append(
                    f"coupling[{i}]/from: reference '{ref}' to undefined system '{top_system}'"
                )
            continue
        system, var, status = _resolve_scoped_ref(ref, tables)
        if status == "no_system":
            errors.append(
                f"coupling[{i}]/from: reference '{ref}' to undefined system '{system}'"
            )
        elif status == "no_var":
            errors.append(
                f"coupling[{i}]/from: reference '{ref}' — variable '{var}' not provided by '{system}'"
            )


def _check_circular_references(data: Dict[str, Any], tables: Dict[str, Any], errors: List[str]) -> None:
    """Detect cycles in cross-system dependencies introduced by equation references."""
    # Build system -> set of systems it depends on
    deps = {name: set() for name in data.get("models", {})}
    for mname, m in data.get("models", {}).items():
        for eq in m.get("equations", []):
            for side in ("lhs", "rhs"):
                if side not in eq:
                    continue
                for ref in _walk_expression_strings(eq[side]):
                    if "." in ref:
                        target_system = ref.split(".")[0]
                        if target_system != mname and target_system in deps:
                            deps[mname].add(target_system)

    # DFS cycle detection
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {n: WHITE for n in deps}

    def dfs(node, path):
        color[node] = GRAY
        for nxt in deps.get(node, ()):
            if color.get(nxt) == GRAY:
                cycle_start = path.index(nxt) if nxt in path else 0
                cycle = path[cycle_start:] + [nxt]
                errors.append(f"circular reference (cycle) detected: {' -> '.join(cycle)}")
                return True
            elif color.get(nxt) == WHITE:
                if dfs(nxt, path + [nxt]):
                    return True
        color[node] = BLACK
        return False

    for n in deps:
        if color[n] == WHITE:
            if dfs(n, [n]):
                break


def _check_data_loader_variables(data: Dict[str, Any], errors: List[str]) -> None:
    """Each variable in data_loader.variables must declare file_variable and units."""
    for dname, d in data.get("data_loaders", {}).items():
        variables = d.get("variables", {})
        if not variables:
            errors.append(f"data_loaders/{dname}/variables: must declare at least one variable")
        for vname, vdef in variables.items():
            if not isinstance(vdef, dict):
                continue
            if "file_variable" not in vdef:
                errors.append(
                    f"data_loaders/{dname}/variables/{vname}: missing required 'file_variable' field"
                )
            if "units" not in vdef:
                errors.append(
                    f"data_loaders/{dname}/variables/{vname}: missing required 'units' field"
                )


def _check_discrete_parameters(data: Dict[str, Any], errors: List[str]) -> None:
    """discrete_parameters list must reference variables of type 'parameter'."""
    for mname, m in data.get("models", {}).items():
        var_types = {n: v.get("type") for n, v in m.get("variables", {}).items()}
        for ei, event in enumerate(m.get("discrete_events", [])):
            for dp in event.get("discrete_parameters", []) or []:
                if dp not in var_types:
                    errors.append(
                        f"models/{mname}/discrete_events[{ei}]: discrete_parameter '{dp}' not declared in model"
                    )
                elif var_types[dp] != "parameter":
                    errors.append(
                        f"models/{mname}/discrete_events[{ei}]: discrete_parameter '{dp}' references variable of type '{var_types[dp]}', expected 'parameter'"
                    )


_DATE_RE = __import__("re").compile(
    r'^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?$'
)
_URL_RE = __import__("re").compile(r'^https?://[^\s/$.?#].[^\s]*$')
_DOI_RE = __import__("re").compile(r'^10\.\d{4,9}/[^\s]+$')
_DURATION_RE = __import__("re").compile(
    r'^P(?:\d+Y)?(?:\d+M)?(?:\d+W)?(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$'
)


def _check_metadata_formats(data: Dict[str, Any], errors: List[str]) -> None:
    """Validate ISO 8601 dates, URLs, and DOIs in metadata."""
    md = data.get("metadata", {})
    for field in ("created", "modified"):
        val = md.get(field)
        if isinstance(val, str) and not _DATE_RE.match(val):
            errors.append(f"metadata/{field}: '{val}' is not a valid ISO 8601 date")
    for ri, ref in enumerate(md.get("references", []) or []):
        url = ref.get("url")
        if isinstance(url, str) and not _URL_RE.match(url):
            errors.append(f"metadata/references[{ri}]/url: '{url}' is not a valid URL")
        doi = ref.get("doi")
        if isinstance(doi, str) and not _DOI_RE.match(doi):
            errors.append(f"metadata/references[{ri}]/doi: '{doi}' is not a valid DOI format")


def _check_temporal_resolution(data: Dict[str, Any], errors: List[str]) -> None:
    """Validate ISO 8601 duration strings in data_loader.temporal fields."""
    for dname, d in data.get("data_loaders", {}).items():
        temporal = d.get("temporal", {})
        if not isinstance(temporal, dict):
            continue
        for field_name in ("file_period", "frequency"):
            res = temporal.get(field_name)
            if isinstance(res, str) and res and not _DURATION_RE.match(res):
                errors.append(
                    f"data_loaders/{dname}/temporal/{field_name}: '{res}' is not a valid ISO 8601 duration"
                )


def _check_subsystem_refs(data: Dict[str, Any], errors: List[str], file_path) -> None:
    """Check that subsystem ref points to an existing file with a single top-level system."""
    base_dirs = []
    if file_path is not None:
        base = Path(file_path).parent if not isinstance(file_path, Path) else file_path.parent
        base_dirs.append(base)
    # Always include CWD as a fallback
    base_dirs.append(Path.cwd())

    def check_subsystems(parent_path, subsystems):
        for sname, sub in subsystems.items():
            ref = sub.get("ref") if isinstance(sub, dict) else None
            if not ref:
                continue
            # Try to resolve against any base dir
            target = None
            for bd in base_dirs:
                candidate = (bd / ref).resolve()
                if candidate.exists():
                    target = candidate
                    break
            if target is None:
                errors.append(
                    f"{parent_path}/subsystems/{sname}: ref '{ref}' file not found"
                )
                continue
            try:
                with open(target) as f:
                    sub_data = json.load(f)
            except Exception as e:
                errors.append(f"{parent_path}/subsystems/{sname}: cannot parse ref '{ref}': {e}")
                continue
            top_systems = list(sub_data.get("models", {}).keys()) + list(
                sub_data.get("reaction_systems", {}).keys()
            )
            if len(top_systems) != 1:
                errors.append(
                    f"{parent_path}/subsystems/{sname}: ref '{ref}' is ambiguous — expected exactly one top-level system, found {len(top_systems)}"
                )

    for mname, m in data.get("models", {}).items():
        if "subsystems" in m:
            check_subsystems(f"models/{mname}", m["subsystems"])
    for rsname, rs in data.get("reaction_systems", {}).items():
        if "subsystems" in rs:
            check_subsystems(f"reaction_systems/{rsname}", rs["subsystems"])


def _collect_var_units(tables: Dict[str, Any]) -> Dict[str, str]:
    """Build {var_name: units} map for plain (unscoped) variable refs."""
    var_units = {}
    for m in tables["models"].values():
        for vname, vdef in m.items():
            if vdef.get("units") is not None:
                var_units[vname] = vdef["units"]
    for rs in tables["reaction_systems"].values():
        for vname, vdef in rs.items():
            if vdef.get("units") is not None:
                var_units[vname] = vdef["units"]
    for d in tables["data_loaders"].values():
        for vname, vdef in d.items():
            if vdef.get("units") is not None:
                var_units[vname] = vdef["units"]
    return var_units


def _infer_expression_units(expr, var_units: Dict[str, str]):
    """
    Best-effort inference of expression units. Returns the unit string,
    None if can't infer, or special tag '<incompatible>' if a unit conflict was found inside.
    """
    if isinstance(expr, (int, float)):
        return "dimensionless"
    if isinstance(expr, str):
        return var_units.get(expr)
    if not isinstance(expr, dict):
        return None
    op = expr.get("op")
    args = expr.get("args", [])
    if op in ("+", "-"):
        # All args must share units
        sub_units = [_infer_expression_units(a, var_units) for a in args]
        non_none = [u for u in sub_units if u is not None]
        if len(non_none) >= 2:
            ref = non_none[0]
            for u in non_none[1:]:
                if not _units_compatible(ref, u):
                    return "<incompatible>"
        return non_none[0] if non_none else None
    if op == "*":
        return None  # multiplication can have varied units
    return None


def _is_derivative_compatible(lhs_var_units: str, rhs_units: str) -> bool:
    """
    Check whether rhs_units could be the time derivative of lhs_var_units.
    True if (rhs * second) is dimensionally equal to lhs_var.
    Also accepts the case where both are dimensionless (decay-style equations).
    """
    n_lhs = _normalize_unit(lhs_var_units)
    n_rhs = _normalize_unit(rhs_units)
    if n_lhs == "dimensionless" and n_rhs == "dimensionless":
        return True
    try:
        import pint
        ureg = pint.UnitRegistry()
        lhs_q = ureg(n_lhs)
        rhs_q = ureg(n_rhs)
        ratio = (rhs_q * ureg("second")) / lhs_q
        return ratio.dimensionless
    except Exception:
        return True  # If pint can't parse, don't flag


def _is_dimensionless_unit(unit: Optional[str]) -> bool:
    """Return True if a unit string represents a dimensionless quantity."""
    if unit is None:
        return True
    normalized = _normalize_unit(unit)
    if normalized in ("dimensionless", "1", ""):
        return True
    try:
        import pint
        ureg = pint.UnitRegistry()
        return ureg(normalized).dimensionless
    except Exception:
        return False


def _model_coordinate_units(
    data: Dict[str, Any], model: Dict[str, Any]
) -> Optional[Dict[str, Optional[str]]]:
    """
    Resolve the enclosing model's domain coordinate units.

    Returns a {dim_name: units_str_or_None} map — units is None when the
    coordinate is declared without a `units` field. Returns None when the
    model has no domain reference or the domain/spatial block is missing,
    so callers can distinguish "no info" from "coord declared, units absent".
    """
    domain_name = model.get("domain")
    if not domain_name:
        return None
    domain = (data.get("domains") or {}).get(domain_name)
    if not isinstance(domain, dict):
        return None
    spatial = domain.get("spatial")
    if not isinstance(spatial, dict):
        return None
    coords: Dict[str, Optional[str]] = {}
    for dim_name, dim_def in spatial.items():
        if isinstance(dim_def, dict):
            coords[dim_name] = dim_def.get("units")
        else:
            coords[dim_name] = None
    return coords


def _walk_expression_for_spatial_operator_checks(
    expr: Any,
    coord_units: Optional[Dict[str, Optional[str]]],
    path: str,
    errors: List[str],
) -> None:
    """
    Walk an expression tree and flag grad/div/laplacian whose spatial
    coordinate has no declared units (or is not present in the model's
    domain at all), which leaves the operator's result dimensionally
    unresolvable. Matches the TypeScript validator's behaviour.
    """
    if not isinstance(expr, dict):
        return
    op = expr.get("op")
    args = expr.get("args", []) or []
    if op in ("grad", "div", "laplacian"):
        dim_name = expr.get("dim")
        # Only enforce when the enclosing model has a declared domain —
        # coord_units is None means "no info", so skip. This matches the
        # Python Model type lacking a persisted `domain` field on round-trip
        # and keeps the check aligned with when the author has opted in by
        # declaring domain + spatial coordinates.
        if dim_name is not None and coord_units is not None:
            if dim_name not in coord_units:
                errors.append(
                    f"{path}: operator '{op}' references coordinate '{dim_name}' "
                    f"not declared in model's domain (unit_inconsistency)"
                )
            else:
                coord_u = coord_units[dim_name]
                if coord_u is None or _is_dimensionless_unit(coord_u):
                    errors.append(
                        f"{path}: {op.capitalize()} operator applied to variable "
                        f"with incompatible spatial units: coordinate '{dim_name}' "
                        f"has no declared units (unit_inconsistency)"
                    )
    for i, arg in enumerate(args):
        _walk_expression_for_spatial_operator_checks(
            arg, coord_units, f"{path}/args[{i}]", errors
        )
    if "expr" in expr:
        _walk_expression_for_spatial_operator_checks(
            expr["expr"], coord_units, f"{path}/expr", errors
        )


def _walk_expression_for_exponent_checks(
    expr: Any,
    var_units: Dict[str, str],
    path: str,
    errors: List[str],
) -> None:
    """Walk an expression tree and flag any '^' whose exponent has dimensions."""
    if not isinstance(expr, dict):
        return
    op = expr.get("op")
    args = expr.get("args", []) or []
    if op == "^" and len(args) >= 2:
        base_arg, exp_arg = args[0], args[1]
        if isinstance(exp_arg, str):
            exp_units = var_units.get(exp_arg)
            if exp_units is not None and not _is_dimensionless_unit(exp_units):
                base_units = var_units.get(base_arg) if isinstance(base_arg, str) else None
                errors.append(
                    f"{path}: exponent must be dimensionless, got '{exp_units}'"
                    + (f" for base with units '{base_units}'" if base_units else "")
                )
    for i, arg in enumerate(args):
        _walk_expression_for_exponent_checks(arg, var_units, f"{path}/args[{i}]", errors)
    # Also walk arrayop sub-expressions that live outside args.
    if "expr" in expr:
        _walk_expression_for_exponent_checks(expr["expr"], var_units, f"{path}/expr", errors)


def _check_default_units_consistency(data: Dict[str, Any], errors: List[str]) -> None:
    """
    Flag variables whose `default_units` disagrees with the declared `units`.

    Emits `unit_inconsistency` when the two unit strings resolve to different
    pint units — covering both dimensionally incompatible cases (e.g., K vs kg)
    and same-dimension mismatches (e.g., K vs degC). Absent default_units is a
    no-op: a default value is presumed to share the declared units.
    """
    try:
        import pint
        ureg = pint.UnitRegistry()
    except Exception:
        return

    def units_match(declared: str, provided: str) -> bool:
        try:
            declared_u = ureg(_normalize_unit(declared)).units
            provided_u = ureg(_normalize_unit(provided)).units
            return declared_u == provided_u
        except Exception:
            # If pint can't parse, fall back to string compare on normalized form
            return _normalize_unit(declared) == _normalize_unit(provided)

    def check_entry(path: str, declared_units, default_value, provided_default_units):
        if provided_default_units is None:
            return
        if declared_units is None:
            return
        if units_match(declared_units, provided_default_units):
            return
        errors.append(
            f"{path}: Parameter default value units do not match declared units "
            f"(declared='{declared_units}', default={default_value}, default_units='{provided_default_units}')"
        )

    for mname, m in data.get("models", {}).items():
        for vname, vdef in m.get("variables", {}).items():
            check_entry(
                f"models/{mname}/variables/{vname}",
                vdef.get("units"),
                vdef.get("default"),
                vdef.get("default_units"),
            )

    for rsname, rs in data.get("reaction_systems", {}).items():
        for sname, sdef in (rs.get("species") or {}).items():
            check_entry(
                f"reaction_systems/{rsname}/species/{sname}",
                sdef.get("units"),
                sdef.get("default"),
                sdef.get("default_units"),
            )
        for pname, pdef in (rs.get("parameters") or {}).items():
            check_entry(
                f"reaction_systems/{rsname}/parameters/{pname}",
                pdef.get("units"),
                pdef.get("default"),
                pdef.get("default_units"),
            )


def _check_conversion_factor_consistency(data: Dict[str, Any], errors: List[str]) -> None:
    """
    Flag observed expressions of the form `<numeric> * <var>` (or `<var> * <numeric>`)
    where the declared output units and the source variable's units are
    dimensionally compatible but the numeric literal disagrees with the correct
    linear scale factor (e.g., assigning `50000 * p_atm` to a Pa variable when
    the correct factor is 101325 Pa/atm).

    Emits `unit_inconsistency` with `declared_factor` and `expected_factor` in
    the error text. Only linear (non-affine) scale conversions are checked —
    affine conversions like degC→K require an offset and are skipped.
    Compound expressions, matching units, and unparseable units are silently
    ignored to stay conservative.
    """
    try:
        import pint
        ureg = pint.UnitRegistry()
    except Exception:
        return

    def linear_factor(from_unit: str, to_unit: str):
        try:
            q0 = ureg.Quantity(0.0, from_unit).to(to_unit).magnitude
            q1 = ureg.Quantity(1.0, from_unit).to(to_unit).magnitude
        except Exception:
            return None
        if abs(q0) > 1e-12:
            return None  # affine (e.g., degC -> K)
        return q1

    for mname, m in data.get("models", {}).items():
        var_units_map = {
            vname: vdef.get("units")
            for vname, vdef in m.get("variables", {}).items()
        }
        for vname, vdef in m.get("variables", {}).items():
            if vdef.get("type") != "observed":
                continue
            lhs_units = vdef.get("units")
            if not lhs_units:
                continue
            expr = vdef.get("expression")
            if not isinstance(expr, dict) or expr.get("op") != "*":
                continue
            args = expr.get("args") or []
            if len(args) != 2:
                continue
            numeric = None
            var_ref = None
            for a in args:
                if isinstance(a, bool):
                    continue
                if isinstance(a, (int, float)):
                    numeric = float(a)
                elif isinstance(a, str):
                    var_ref = a
            if numeric is None or var_ref is None:
                continue
            src_units = var_units_map.get(var_ref)
            if not src_units:
                continue
            n_src = _normalize_unit(src_units)
            n_lhs = _normalize_unit(lhs_units)
            if n_src == n_lhs:
                continue  # identical — no conversion to check
            try:
                if ureg(n_src).dimensionality != ureg(n_lhs).dimensionality:
                    continue  # dimensional mismatch — handled by other checks
            except Exception:
                continue
            factor = linear_factor(n_src, n_lhs)
            if factor is None or factor == 0:
                continue
            if abs(numeric - factor) <= 1e-9 * max(abs(factor), 1.0):
                continue  # matches within tolerance
            errors.append(
                f"models/{mname}/variables/{vname}: Unit conversion factor is incorrect "
                f"for specified unit transformation "
                f"(declared_factor={numeric}, expected_factor={factor}, "
                f"source_units='{src_units}', declared_units='{lhs_units}')"
            )


# Registry of well-known physical constants mapped by parameter name.
# Each entry maps: name -> (canonical_units, description).
# Pattern-matched by exact variable name; dimensional compatibility is checked
# (not numerical equivalence — kcal/(mol*K) vs J/(mol*K) both pass this check).
# Intentionally conservative — names chosen to minimize collision with common
# non-constant uses (e.g., no 'c' for speed of light, which conflicts with
# 'concentration'; no 'e' for elementary charge, which conflicts with Euler).
_KNOWN_PHYSICAL_CONSTANTS = {
    "R": ("J/(mol*K)", "ideal gas constant"),
    "k_B": ("J/K", "Boltzmann constant"),
    "N_A": ("1/mol", "Avogadro constant"),
}


def _expr_references_name(expr: Any, name: str) -> bool:
    """Return True if the expression tree references a variable by exact name."""
    if isinstance(expr, str):
        return expr == name
    if isinstance(expr, dict):
        for arg in expr.get("args", []) or []:
            if _expr_references_name(arg, name):
                return True
        inner = expr.get("expr")
        if inner is not None and _expr_references_name(inner, name):
            return True
    return False


def _check_physical_constant_units(data: Dict[str, Any], errors: List[str]) -> None:
    """
    Flag well-known physical constants declared with dimensionally incompatible units.

    Uses a conservative registry (R, k_B, N_A) of pattern-matched names. A
    parameter whose name exactly matches a known constant and whose declared
    units are dimensionally different from the canonical form (e.g., R declared
    as 'kcal/mol' — missing temperature — instead of 'J/(mol*K)') is flagged
    as ``unit_inconsistency``. When an observed variable in the same model
    references the constant, the error is reported at the usage site (where
    the dimensional analysis error propagates); otherwise at the declaration.

    Same-dimension numerical mismatches (e.g., R in 'kcal/(mol*K)' vs 'J/(mol*K)')
    are not flagged — those require a numerical scale registry, which is
    out of scope for this check.
    """
    for mname, m in data.get("models", {}).items():
        variables = m.get("variables", {}) or {}
        for vname, vdef in variables.items():
            if vdef.get("type") != "parameter":
                continue
            if vname not in _KNOWN_PHYSICAL_CONSTANTS:
                continue
            declared = vdef.get("units")
            if not declared:
                continue
            canonical, description = _KNOWN_PHYSICAL_CONSTANTS[vname]
            if _units_compatible(declared, canonical):
                continue
            usage_vname = None
            for other_vname, other_vdef in variables.items():
                if other_vdef.get("type") != "observed":
                    continue
                if _expr_references_name(other_vdef.get("expression"), vname):
                    usage_vname = other_vname
                    break
            target = f"models/{mname}/variables/{usage_vname or vname}"
            errors.append(
                f"{target}: Physical constant used with incorrect dimensional analysis "
                f"(constant '{vname}' ({description}) declared with units '{declared}', "
                f"expected dimensions compatible with '{canonical}')"
            )


def _check_unit_consistency(data: Dict[str, Any], tables: Dict[str, Any], errors: List[str]) -> None:
    """
    Check unit compatibility in equations.

    Conservative: only flags
    1. Equations of the form D(x)/dt = bare_var where bare_var has dimensions
       clearly incompatible with x/time (e.g., velocity-rate set to mass).
    2. Observed variable expressions whose top-level + or - has incompatible operands.
    3. '^' operators whose right operand has non-dimensionless units.
    4. grad/div/laplacian operators whose referenced coordinate is not
       declared in the model's domain, or is declared without units — the
       result's dimension cannot be resolved, matching the TypeScript
       validator's behaviour.
    """
    var_units = _collect_var_units(tables)

    for mname, m in data.get("models", {}).items():
        coord_units = _model_coordinate_units(data, m)
        # Observed variables: check direct addition/subtraction operand compatibility
        for vname, vdef in m.get("variables", {}).items():
            if vdef.get("type") == "observed" and "expression" in vdef:
                expr = vdef["expression"]
                if isinstance(expr, dict) and expr.get("op") in ("+", "-"):
                    sub_units = []
                    for arg in expr.get("args", []):
                        if isinstance(arg, str):
                            sub_units.append(var_units.get(arg))
                    non_none = [u for u in sub_units if u is not None]
                    if len(non_none) >= 2:
                        ref = non_none[0]
                        for u in non_none[1:]:
                            if not _units_compatible(ref, u):
                                errors.append(
                                    f"models/{mname}/variables/{vname}: expression has incompatible units in addition/subtraction"
                                )
                                break
                # Check '^' exponents anywhere within the observed expression tree
                _walk_expression_for_exponent_checks(
                    expr, var_units, f"models/{mname}/variables/{vname}/expression", errors
                )
                _walk_expression_for_spatial_operator_checks(
                    expr, coord_units, f"models/{mname}/variables/{vname}/expression", errors
                )

        # Check '^' exponents and grad/div/laplacian coordinate resolution
        # in equation rhs/lhs expressions as well
        for ei, eq in enumerate(m.get("equations", [])):
            for side in ("lhs", "rhs"):
                if side in eq:
                    _walk_expression_for_exponent_checks(
                        eq[side], var_units, f"models/{mname}/equations[{ei}]/{side}", errors
                    )
                    _walk_expression_for_spatial_operator_checks(
                        eq[side], coord_units, f"models/{mname}/equations[{ei}]/{side}", errors
                    )

        # Equations: only check D(x)/dt = bare_var case
        for i, eq in enumerate(m.get("equations", [])):
            lhs = eq.get("lhs")
            rhs = eq.get("rhs")
            if not (isinstance(lhs, dict) and lhs.get("op") == "D"):
                continue
            inner = lhs.get("args", [None])[0]
            if not isinstance(inner, str):
                continue
            lhs_var_units = var_units.get(inner)
            if not lhs_var_units:
                continue
            if not isinstance(rhs, str):
                continue
            rhs_units = var_units.get(rhs)
            if not rhs_units:
                continue
            if not _is_derivative_compatible(lhs_var_units, rhs_units):
                errors.append(
                    f"models/{mname}/equations[{i}]: rhs '{rhs}' units '{rhs_units}' incompatible with time derivative of '{lhs_var_units}'"
                )


def _check_equation_balance(data: Dict[str, Any], errors: List[str]) -> None:
    """
    Check for clearly broken equation/state-variable patterns.

    Flags only the unambiguous cases (no operators/coupling/data_loaders to disambiguate):
    1. Model has state variables but zero equations.
    2. Total equations < state variables AND no observed variables provide algebraic
       relations (under-determined with no compensating relations).
    3. ODE equations > state variables (over-determined).
    """
    has_operators = bool(data.get("operators"))
    has_coupling = bool(data.get("coupling"))
    has_loaders = bool(data.get("data_loaders"))
    has_external = has_operators or has_coupling or has_loaders

    for mname, m in data.get("models", {}).items():
        state_vars = {n for n, v in m.get("variables", {}).items() if v.get("type") == "state"}
        observed_vars = {n for n, v in m.get("variables", {}).items() if v.get("type") == "observed"}
        eqs = m.get("equations", [])
        ode_lhs_vars = []
        for eq in eqs:
            lhs = eq.get("lhs")
            if isinstance(lhs, dict) and lhs.get("op") == "D":
                args = lhs.get("args", [])
                if args and isinstance(args[0], str):
                    ode_lhs_vars.append(args[0])

        if has_external:
            continue

        # Case 1: state vars but zero equations
        if state_vars and not eqs:
            errors.append(
                f"models/{mname}: has {len(state_vars)} state variables but no equations"
            )
            continue

        # Case 2: more ODE equations than state variables (over-determined)
        if len(ode_lhs_vars) > len(state_vars):
            errors.append(
                f"models/{mname}: equation count mismatch — {len(ode_lhs_vars)} ODE equations for {len(state_vars)} state variables (over-determined)"
            )
            continue

        # Case 3: total equations less than state variables AND no observed vars
        # to provide algebraic relations
        if len(eqs) < len(state_vars) and not observed_vars:
            errors.append(
                f"models/{mname}: equation count mismatch — {len(eqs)} equations for {len(state_vars)} state variables (under-determined, no algebraic relations)"
            )


def _check_operator_state_coverage(data: Dict[str, Any], errors: List[str]) -> None:
    """
    When a file declares operators, every state variable in each model must be
    covered by either an equation (ODE or assignment) or an operator's modifies list.
    """
    if not data.get("operators"):
        return
    op_modifies = set()
    for op in data.get("operators", {}).values():
        op_modifies.update(op.get("modifies", []) or [])
    for mname, m in data.get("models", {}).items():
        state_vars = [n for n, v in m.get("variables", {}).items() if v.get("type") == "state"]
        eq_lhs_vars = set()
        for eq in m.get("equations", []):
            lhs = eq.get("lhs")
            if isinstance(lhs, dict) and lhs.get("op") == "D":
                args = lhs.get("args", [])
                if args and isinstance(args[0], str):
                    eq_lhs_vars.add(args[0])
            elif isinstance(lhs, str):
                eq_lhs_vars.add(lhs)
        uncovered = [s for s in state_vars if s not in eq_lhs_vars and s not in op_modifies]
        if uncovered:
            errors.append(
                f"models/{mname}: state variables {uncovered} are not covered by any equation or operator's modifies list"
            )


def _check_reaction_systems(data: Dict[str, Any], errors: List[str]) -> None:
    """Validate reaction system: substrates/products are declared species, rate refs valid."""
    for rsname, rs in data.get("reaction_systems", {}).items():
        species = set(rs.get("species", {}).keys())
        params = set(rs.get("parameters", {}).keys())
        valid_rate_syms = species | params | _BUILTIN_SYMBOLS
        for ri, reaction in enumerate(rs.get("reactions", [])):
            substrates = reaction.get("substrates")
            products = reaction.get("products")
            # Reaction has both substrates and products explicitly null is invalid
            if "substrates" in reaction and "products" in reaction \
                    and substrates is None and products is None:
                errors.append(
                    f"reaction_systems/{rsname}/reactions[{ri}]: reaction has both substrates and products as null"
                )
                continue
            # Check substrate/product species are declared
            for s in substrates or []:
                if isinstance(s, dict):
                    sp = s.get("species")
                    if sp and sp not in species:
                        errors.append(
                            f"reaction_systems/{rsname}/reactions[{ri}]: substrate species '{sp}' not declared"
                        )
            for p in products or []:
                if isinstance(p, dict):
                    sp = p.get("species")
                    if sp and sp not in species:
                        errors.append(
                            f"reaction_systems/{rsname}/reactions[{ri}]: product species '{sp}' not declared"
                        )
            # Check rate expression references valid symbols
            rate = reaction.get("rate")
            if rate is not None:
                refs = []
                if isinstance(rate, str):
                    refs = [rate]
                elif isinstance(rate, dict):
                    refs = _walk_expression_strings(rate)
                for ref in refs:
                    if "." in ref:
                        continue  # Scoped refs handled elsewhere
                    if ref not in valid_rate_syms:
                        errors.append(
                            f"reaction_systems/{rsname}/reactions[{ri}]/rate: undefined reference '{ref}'"
                        )


def _check_event_references(data: Dict[str, Any], tables: Dict[str, Any], errors: List[str]) -> None:
    """Check that event affects/conditions reference declared variables."""
    for mname, m in data.get("models", {}).items():
        local_vars = set(m.get("variables", {}).keys())
        for ei, event in enumerate(m.get("discrete_events", []) + m.get("continuous_events", [])):
            for ai, affect in enumerate(event.get("affects", []) or []):
                if isinstance(affect, dict) and "lhs" in affect and isinstance(affect["lhs"], str):
                    name = affect["lhs"]
                    # Underscore-prefixed names are conventional placeholders
                    if name.startswith("_"):
                        continue
                    if name not in local_vars and name not in tables["global_symbols"]:
                        errors.append(
                            f"models/{mname}/events[{ei}]/affects[{ai}]: undefined variable '{name}'"
                        )


def _check_registered_function_calls(data: Dict[str, Any], errors: List[str]) -> None:
    """Emit missing_registered_function diagnostics for 'call' ops whose
    handler_id does not appear in the top-level registered_functions map
    (esm-spec §4.4 / §9.2). Also checks arg_count against signature when declared.
    """
    registry = data.get("registered_functions") or {}

    def walk(obj, path):
        if isinstance(obj, dict):
            if obj.get("op") == "call":
                handler_id = obj.get("handler_id")
                if handler_id is None:
                    errors.append(f"{path}: 'call' op is missing required 'handler_id' field")
                elif handler_id not in registry:
                    errors.append(
                        f"{path}: missing_registered_function — 'call' references handler_id "
                        f"'{handler_id}' but no such entry exists in registered_functions"
                    )
                else:
                    entry = registry[handler_id] or {}
                    sig = entry.get("signature") or {}
                    declared = sig.get("arg_count")
                    args = obj.get("args") or []
                    if declared is not None and len(args) != declared:
                        errors.append(
                            f"{path}: 'call' to '{handler_id}' has {len(args)} args but "
                            f"signature declares arg_count={declared}"
                        )
            for k, v in obj.items():
                walk(v, f"{path}/{k}")
        elif isinstance(obj, list):
            for i, v in enumerate(obj):
                walk(v, f"{path}[{i}]")

    # Also sanity-check that each registered_functions entry's id matches its key
    # and its arg_units length agrees with signature.arg_count when both are present.
    for key, entry in registry.items():
        if not isinstance(entry, dict):
            continue
        entry_id = entry.get("id")
        if entry_id is not None and entry_id != key:
            errors.append(
                f"registered_functions/{key}: entry id '{entry_id}' does not match map key '{key}'"
            )
        sig = entry.get("signature") or {}
        arg_count = sig.get("arg_count")
        arg_units = entry.get("arg_units")
        if arg_units is not None and arg_count is not None and len(arg_units) != arg_count:
            errors.append(
                f"registered_functions/{key}: arg_units length {len(arg_units)} != signature.arg_count {arg_count}"
            )
        arg_types = sig.get("arg_types")
        if arg_types is not None and arg_count is not None and len(arg_types) != arg_count:
            errors.append(
                f"registered_functions/{key}: signature.arg_types length {len(arg_types)} != arg_count {arg_count}"
            )

    walk(data, "")


def _validate_structural(data: Dict[str, Any], file_path=None) -> None:
    """
    Perform post-schema structural validation.

    Raises SchemaValidationError if any structural problems are found.
    """
    errors: List[str] = []

    # Operator arity check (walk all expressions)
    def walk_for_arity(obj, path):
        if isinstance(obj, dict):
            if "op" in obj and "args" in obj:
                _check_expression_arity(obj, errors, path)
                return
            for k, v in obj.items():
                walk_for_arity(v, f"{path}/{k}")
        elif isinstance(obj, list):
            for i, v in enumerate(obj):
                walk_for_arity(v, f"{path}[{i}]")

    walk_for_arity(data, "")

    tables = _build_symbol_tables(data)

    _check_variable_references(data, tables, errors)
    _check_coupling_references(data, tables, errors)
    _check_circular_references(data, tables, errors)
    _check_data_loader_variables(data, errors)
    _check_discrete_parameters(data, errors)
    _check_metadata_formats(data, errors)
    _check_temporal_resolution(data, errors)
    # Subsystem ref existence/parse is checked by resolve_subsystem_refs after
    # structural validation, which raises SubsystemRefError with richer context.
    _check_unit_consistency(data, tables, errors)
    _check_default_units_consistency(data, errors)
    _check_conversion_factor_consistency(data, errors)
    _check_physical_constant_units(data, errors)
    _check_event_references(data, tables, errors)
    _check_equation_balance(data, errors)
    _check_operator_state_coverage(data, errors)
    _check_reaction_systems(data, errors)
    # Reaction rate/stoichiometry dimensional consistency is now enforced in
    # ``earthsci_toolkit.validation._validate_reaction_rate_dimensions`` with a
    # structured ``unit_inconsistency`` payload matching the cross-language
    # contract in ``tests/invalid/expected_errors.json``.
    _check_registered_function_calls(data, errors)

    if errors:
        raise SchemaValidationError(
            "Structural validation failed:\n" + "\n".join(f"  - {e}" for e in errors)
        )


@track_performance("parse", track_file_size=True)
def load(
    path_or_string: Union[str, Path, dict],
    *,
    metaparameters: Optional[Dict[str, int]] = None,
    base_path: Optional[str] = None,
) -> EsmFile:
    """
    Load an ESM file from a file path, JSON string, or dict.

    Args:
        path_or_string: File path to JSON file, JSON string, or parsed dict
        metaparameters: Optional name → integer bindings closing the ROOT
            document's open metaparameters at the loader API (esm-spec §9.7.6
            binding site 4): already-closed edge bindings win, API bindings
            beat ``default``\\ s. Binding a name the document does not declare
            raises ``template_import_unknown_name``.
        base_path: Optional directory anchoring relative
            ``expression_template_imports`` refs (esm-spec §9.7.2) for JSON
            string / dict input. Defaults to the file's directory for path
            input, the current working directory otherwise.

    Returns:
        EsmFile object with parsed data

    Raises:
        json.JSONDecodeError: If the JSON is malformed
        jsonschema.ValidationError: If the JSON doesn't match the schema
        FileNotFoundError: If the file path doesn't exist
    """
    # Handle dict input directly
    resolved_base = base_path if base_path is not None else os.getcwd()
    file_path = None
    if isinstance(path_or_string, dict):
        data = path_or_string
    elif isinstance(path_or_string, Path) or (isinstance(path_or_string, str) and os.path.exists(path_or_string)):
        # It's a file path
        file_path = Path(path_or_string)
        if base_path is None:
            resolved_base = str(file_path.parent.resolve())
        with open(path_or_string, 'r') as f:
            data = json.load(f)
    else:
        # It's a JSON string
        data = json.loads(path_or_string)
    base_path = resolved_base

    # Strip top-level events (not allowed by schema, but accepted for tooling roundtrip)
    top_continuous_events = data.pop("continuous_events", None) if isinstance(data, dict) else None
    top_discrete_events = data.pop("discrete_events", None) if isinstance(data, dict) else None

    # v0.4.0 expression_templates / apply_expression_template are rejected
    # when the file declares esm < 0.4.0 (RFC §5.4 spec-version gate).
    # Surfaced before schema validation so the user sees the version hint
    # instead of a generic schema error.
    from .lower_expression_templates import (
        reject_expression_templates_pre_v04,
        lower_expression_templates,
    )
    from .template_imports import (
        reject_template_imports_pre_v08,
        resolve_template_machinery,
    )
    reject_expression_templates_pre_v04(data)

    # v0.8.0 §9.7 constructs (expression_template_imports, top-level
    # expression_templates, metaparameters) are rejected when the file
    # declares esm < 0.8.0 (esm-spec §9.6.5).
    reject_template_imports_pre_v08(data)

    # Load and validate against schema
    schema = _get_schema()
    try:
        validate(data, schema)
    except jsonschema.ValidationError as e:
        raise SchemaValidationError(str(e)) from e

    # Check version compatibility
    _check_version_compatibility(data.get("esm", ""))

    # Resolve esm-spec §9.7 machinery — template-library imports (depth-first
    # post-order, per-edge metaparameter instantiation), index_sets merge,
    # metaparameter close+fold — BEFORE any validator sees the tree (esm-spec
    # §9.7: "All resolution happens at load, before validation and before the
    # §9.6.3 fixpoint"). Returns None for documents without §9.7 machinery.
    resolved = resolve_template_machinery(
        data, base_path, metaparameters=metaparameters)
    if resolved is not None:
        data = resolved

    # Structural validation (runs on the resolved, folded form — §9.6.4)
    _validate_structural(data, file_path=file_path)

    # Expand `apply_expression_template` ops at load time (esm-spec §9.6 /
    # docs/rfcs/ast-expression-templates.md). After this pass, the data dict
    # carries no apply_expression_template nodes and no expression_templates
    # blocks — _parse_esm_data sees only normal Expression ASTs (Option A
    # round-trip).
    data = lower_expression_templates(data)

    # Parse into ESM objects
    esm_file = _parse_esm_data(data)

    # Resolve top-level model references first so every entry in
    # esm_file.models is a concrete Model (rather than a `{ref: ...}` dict)
    # before resolve_subsystem_refs — which assumes `model.subsystems` exists
    # — walks them. A model imported by reference splices in under its own key,
    # so its flat names `X.<var>` already equal the coupling-edge names.
    resolve_model_refs(esm_file, base_path)

    # Resolve subsystem references so subsystems land as concrete Model
    # / ReactionSystem objects (rather than `{ref: ...}` dicts) before the
    # enum-lowering pass walks their expression trees.
    resolve_subsystem_refs(esm_file, base_path)

    # Lower `enum` op nodes to `const` integers using the file's `enums` block
    # (esm-spec §9.3). Runs after subsystem resolution so every expression
    # tree — including those in resolved subsystems — sees the integer values.
    from .registered_functions import lower_enums
    lower_enums(esm_file)

    # Append top-level events that were stripped earlier
    if top_continuous_events:
        for ev in top_continuous_events:
            esm_file.events.append(_parse_continuous_event(ev))
    if top_discrete_events:
        for ev in top_discrete_events:
            esm_file.events.append(_parse_discrete_event(ev))

    return esm_file


