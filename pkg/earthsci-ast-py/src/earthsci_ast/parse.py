"""
ESM Format parsing module.

This module provides functions to parse JSON data into ESM format objects,
with schema validation using the bundled esm-schema.json file.
"""
from __future__ import annotations

import copy
import json
import os
import re
from pathlib import Path
from typing import TYPE_CHECKING, Any

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

from .diagnostics import (
    SUBSYSTEM_REF_IS_COUPLING_LIBRARY,
    SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY,
)
from .errors import EarthSciAstError, ParseError
from .esm_types import (
    AffectEquation,
    Assertion,
    CallbackCoupling,
    Connector,
    ConnectorEquation,
    ContinuousEvent,
    CouplingCouple,
    CouplingEntry,
    CouplingImport,
    CouplingType,
    DataLoader,
    DataLoaderDeterminism,
    DataLoaderKind,
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
    FunctionTable,
    FunctionTableAxis,
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
    TemporalDomain,
    Test,
    TimeSpan,
    Tolerance,
    VariableMapCoupling,
)


class SchemaValidationError(EarthSciAstError):
    """Exception raised when schema validation fails."""

    pass


class UnsupportedVersionError(EarthSciAstError):
    """Exception raised when ESM version is not supported."""

    pass


class CircularReferenceError(EarthSciAstError):
    """Exception raised when circular subsystem references are detected."""

    pass


class SubsystemRefError(EarthSciAstError):
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

    match = re.match(r"^(\d+)\.(\d+)\.(\d+)$", version_string)
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
            stacklevel=3,
        )


def _get_schema() -> dict[str, Any]:
    """Load the bundled ESM schema."""
    if _RESOURCES_AVAILABLE:
        try:
            # Use importlib.resources to locate the schema file within the package
            schema_files = files("earthsci_ast") / "data"
            schema_path = schema_files / "esm-schema.json"

            # Read the schema content using the modern resource API
            with schema_path.open("r", encoding="utf-8") as f:
                return json.load(f)
        except (FileNotFoundError, AttributeError, TypeError):
            # Fall through to the legacy path approach
            pass

    # Fallback to the original method if resources approach fails or is unavailable
    schema_path = Path(__file__).parent / "data" / "esm-schema.json"
    if not schema_path.exists():
        raise FileNotFoundError(f"ESM schema not found at {schema_path}")

    with open(schema_path) as f:
        return json.load(f)


def _parse_expression(expr_data: int | float | str | dict[str, Any]) -> Expr:
    """Parse an expression from JSON data."""
    if isinstance(expr_data, (int, float, str)):
        return expr_data
    if isinstance(expr_data, dict):
        # Parse ExprNode
        op = expr_data["op"]
        args = [_parse_expression(arg) for arg in expr_data["args"]]
        wrt = expr_data.get("wrt")
        dim = expr_data.get("dim")

        # integral op (schema §ExpressionNode `integral`): the integration
        # variable name (`var`, a string) plus lower/upper bounds which are
        # themselves Expressions (numeric literal, parameter ref, or subtree).
        var = expr_data.get("var")
        lower = _parse_expression(expr_data["lower"]) if "lower" in expr_data else None
        upper = _parse_expression(expr_data["upper"]) if "upper" in expr_data else None

        # Validate operator-specific field requirements
        if op == "D" and wrt is None:
            raise ParseError("Operator 'D' requires 'wrt' field to be specified")
        if op == "grad" and dim is None:
            raise ParseError("Operator 'grad' requires 'dim' field to be specified")

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
            raise ParseError(
                f"Operator {op!r} requires a 'manifold' field "
                "(planar / spherical / geodesic); it carries no default"
            )

        if op == "call" and handler_id is None:
            raise ParseError("Operator 'call' requires 'handler_id' field to be specified")
        if op == "fn" and name is None:
            raise ParseError("Operator 'fn' requires 'name' field to be specified")
        if op == "const" and "value" not in expr_data:
            raise ParseError("Operator 'const' requires 'value' field to be specified")

        # table_lookup (esm-spec §9.5, v0.4.0): table id, per-axis input
        # expression map (carried under JSON key "axes"), optional output
        # selector. ``args`` MUST be empty for a table_lookup node.
        table = expr_data.get("table")
        table_axes_raw = expr_data.get("axes") if op == "table_lookup" else None
        table_axes = None
        if op == "table_lookup":
            if table is None:
                raise ParseError("Operator 'table_lookup' requires 'table' field to be specified")
            if not isinstance(table_axes_raw, dict):
                raise ParseError(
                    "Operator 'table_lookup' requires 'axes' to be an object mapping axis names to input expressions"
                )
            table_axes = {k: _parse_expression(v) for k, v in table_axes_raw.items()}
            if args:
                raise ParseError(
                    "Operator 'table_lookup' must have empty 'args' (per-axis inputs live under 'axes')"
                )
        output = expr_data.get("output")

        return ExprNode(
            op=op,
            args=args,
            wrt=wrt,
            dim=dim,
            var=var,
            lower=lower,
            upper=upper,
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
    raise ParseError(f"Invalid expression data: {expr_data}")


def _parse_equation(eq_data: dict[str, Any]) -> Equation:
    """Parse an equation from JSON data."""
    lhs = _parse_expression(eq_data["lhs"])
    rhs = _parse_expression(eq_data["rhs"])
    comment = eq_data.get("_comment")
    return Equation(lhs=lhs, rhs=rhs, _comment=comment)


def _parse_affect_equation(affect_data: dict[str, Any]) -> AffectEquation:
    """Parse an affect equation from JSON data."""
    lhs = affect_data["lhs"]  # string
    rhs = _parse_expression(affect_data["rhs"])
    return AffectEquation(lhs=lhs, rhs=rhs)


def _parse_functional_affect(functional_affect_data: dict[str, Any]) -> FunctionalAffect:
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
        config=config,
    )


def _parse_affect(affect: Any):
    """Parse one affect entry from an event's ``affects`` / ``affect_neg`` list.

    A dict carrying a ``handler_id`` is a :class:`FunctionalAffect`; anything
    else is an :class:`AffectEquation`.
    """
    if isinstance(affect, dict) and "handler_id" in affect:
        return _parse_functional_affect(affect)
    return _parse_affect_equation(affect)


def _parse_model_variable(var_data: dict[str, Any]) -> ModelVariable:
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


def _parse_discrete_event_trigger(trigger_data: dict[str, Any]) -> DiscreteEventTrigger:
    """Parse a discrete event trigger from JSON data."""
    trigger_type = trigger_data["type"]

    if trigger_type == "condition":
        expression = _parse_expression(trigger_data["expression"])
        return DiscreteEventTrigger(type=trigger_type, value=expression)
    if trigger_type == "periodic":
        interval = trigger_data["interval"]
        return DiscreteEventTrigger(type=trigger_type, value=interval)
    if trigger_type == "preset_times":
        times = trigger_data["times"]
        return DiscreteEventTrigger(type=trigger_type, value=times)
    raise ParseError(f"Unknown trigger type: {trigger_type}")


def _parse_continuous_event(event_data: dict[str, Any]) -> ContinuousEvent:
    """Parse a continuous event from JSON data."""
    name = event_data.get("name", "")
    conditions = [_parse_expression(cond) for cond in event_data["conditions"]]
    affects = []

    # Parse affects: distinguish AffectEquation from FunctionalAffect
    if "affects" in event_data:
        affects = [_parse_affect(affect) for affect in event_data["affects"]]

    # Parse functional_affect (FunctionalAffect object)
    if "functional_affect" in event_data:
        functional_affect = _parse_functional_affect(event_data["functional_affect"])
        affects.append(functional_affect)

    priority = event_data.get("priority", 0)

    # Parse new fields
    affect_neg = None
    if "affect_neg" in event_data:
        affect_neg = [_parse_affect(affect) for affect in event_data["affect_neg"]]

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
        description=description,
    )


def _parse_discrete_event(event_data: dict[str, Any]) -> DiscreteEvent:
    """Parse a discrete event from JSON data."""
    name = event_data.get("name", "")
    trigger = _parse_discrete_event_trigger(event_data["trigger"])
    affects = []

    # Parse affects: distinguish AffectEquation from FunctionalAffect
    if "affects" in event_data:
        affects = [_parse_affect(affect) for affect in event_data["affects"]]

    # Parse functional_affect (FunctionalAffect object)
    if "functional_affect" in event_data:
        functional_affect = _parse_functional_affect(event_data["functional_affect"])
        affects.append(functional_affect)

    priority = event_data.get("priority", 0)

    return DiscreteEvent(
        name=name,
        trigger=trigger,
        affects=affects,
        priority=priority,
        discrete_parameters=event_data.get("discrete_parameters", []),
        reinitialize=event_data.get("reinitialize", False),
        description=event_data.get("description"),
    )


def _parse_tolerance(data: dict[str, Any]) -> Tolerance:
    return Tolerance(abs=data.get("abs"), rel=data.get("rel"))


def _parse_time_span(data: dict[str, Any]) -> TimeSpan:
    return TimeSpan(start=float(data["start"]), end=float(data["end"]))


def _parse_assertion(data: dict[str, Any]) -> Assertion:
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


def _parse_test(data: dict[str, Any]) -> Test:
    return Test(
        id=data["id"],
        time_span=_parse_time_span(data["time_span"]),
        assertions=[_parse_assertion(a) for a in data.get("assertions", [])],
        description=data.get("description"),
        initial_conditions=dict(data.get("initial_conditions", {})),
        parameter_overrides=dict(data.get("parameter_overrides", {})),
        tolerance=_parse_tolerance(data["tolerance"]) if "tolerance" in data else None,
        # esm-spec §9.7.10 form C / §6.6.6: raw §9.7.2 import entries naming the
        # discretization this test runs under. Retained (not consumed at load)
        # so the PDE runner can build a per-test ephemeral instance and so the
        # field survives round-trip.
        expression_template_imports=copy.deepcopy(
            data.get("expression_template_imports", []) or []
        ),
    )


def _parse_plot_axis(data: dict[str, Any]) -> PlotAxis:
    return PlotAxis(variable=data["variable"], label=data.get("label"))


def _parse_plot_value(data: dict[str, Any]) -> PlotValue:
    return PlotValue(
        variable=data["variable"],
        at_time=data.get("at_time"),
        reduce=data.get("reduce"),
    )


def _parse_plot_series(data: dict[str, Any]) -> PlotSeries:
    return PlotSeries(name=data["name"], variable=data["variable"])


def _parse_plot(data: dict[str, Any]) -> Plot:
    raw_y = data["y"]
    explicit_series = [_parse_plot_series(s) for s in data.get("series", [])]
    if isinstance(raw_y, list):
        axes = [_parse_plot_axis(item) for item in raw_y]
        y_axis = axes[0]
        inline_series = [
            PlotSeries(name=axis.label or axis.variable, variable=axis.variable) for axis in axes
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


def _parse_sweep_range(data: dict[str, Any]) -> SweepRange:
    return SweepRange(
        start=float(data["start"]),
        stop=float(data["stop"]),
        count=int(data["count"]),
        scale=data.get("scale"),
    )


def _parse_sweep_dimension(data: dict[str, Any]) -> SweepDimension:
    return SweepDimension(
        parameter=data["parameter"],
        values=list(data["values"]) if "values" in data else None,
        range=_parse_sweep_range(data["range"]) if "range" in data else None,
    )


def _parse_parameter_sweep(data: dict[str, Any]) -> ParameterSweep:
    return ParameterSweep(
        type=data["type"],
        dimensions=[_parse_sweep_dimension(d) for d in data.get("dimensions", [])],
    )


def _parse_example(data: dict[str, Any]) -> Example:
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
        # esm-spec §9.7.10 form C / §6.6.6: raw §9.7.2 import entries naming the
        # discretization this example runs under. Retained (not consumed at load)
        # so the field survives round-trip, mirroring _parse_test above.
        expression_template_imports=copy.deepcopy(
            data.get("expression_template_imports", []) or []
        ),
    )


def _parse_model(model_data: dict[str, Any]) -> Model:
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
    subsystems: dict[str, Any] = {}
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

    model = Model(name="", variables=variables, equations=equations, subsystems=subsystems)

    if "tolerance" in model_data:
        model.tolerance = _parse_tolerance(model_data["tolerance"])
    if "tests" in model_data:
        model.tests = [_parse_test(t) for t in model_data["tests"]]
    if "examples" in model_data:
        model.examples = [_parse_example(e) for e in model_data["examples"]]

    if (
        "initialization_equations" in model_data
        and model_data["initialization_equations"] is not None
    ):
        model.initialization_equations = [
            _parse_equation(eq) for eq in model_data["initialization_equations"]
        ]
    if "guesses" in model_data and model_data["guesses"] is not None:
        guesses: dict[str, Any] = {}
        for var_name, seed in model_data["guesses"].items():
            if isinstance(seed, (int, float)) and not isinstance(seed, bool):
                guesses[var_name] = float(seed)
            else:
                guesses[var_name] = _parse_expression(seed)
        model.guesses = guesses
    if "system_kind" in model_data and model_data["system_kind"] is not None:
        model.system_kind = model_data["system_kind"]

    # Events are owned by the component that declares them (the schema only
    # allows events nested inside models/reaction_systems); the flat
    # EsmFile.events view aggregates these same objects in _parse_esm_data.
    if "continuous_events" in model_data:
        model.continuous_events = [
            _parse_continuous_event(ev) for ev in model_data["continuous_events"]
        ]
    if "discrete_events" in model_data:
        model.discrete_events = [_parse_discrete_event(ev) for ev in model_data["discrete_events"]]

    return model


def _parse_species(species_data: dict[str, Any]) -> Species:
    """Parse a species from JSON data."""
    return Species(
        name="",  # Name comes from the key
        units=species_data.get("units"),
        default=species_data.get("default"),
        default_units=species_data.get("default_units"),
        description=species_data.get("description"),
        constant=species_data.get("constant"),
    )


def _parse_parameter(param_data: dict[str, Any]) -> Parameter:
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
        description=param_data.get("description"),
    )


def _parse_stoichiometry(entries: Any) -> dict[str, Any]:
    """Build a ``{species: stoichiometry}`` map from substrate/product entries.

    Preserves `int` vs `float` coefficients so a parse/re-emit cycle stays
    byte-identical for integer-only fixtures and round-trips fractional
    stoichiometries untouched.
    """
    return {e["species"]: e["stoichiometry"] for e in entries or []}


def _parse_reaction(reaction_data: dict[str, Any]) -> Reaction:
    """Parse a reaction from JSON data."""
    rxn_id = reaction_data.get("id")
    name = reaction_data.get("name", rxn_id)

    # Substrates in the schema become reactants in the model.
    reactants = _parse_stoichiometry(reaction_data.get("substrates"))
    products = _parse_stoichiometry(reaction_data.get("products"))

    # Parse rate
    rate_constant = None
    if "rate" in reaction_data:
        rate_constant = _parse_expression(reaction_data["rate"])

    return Reaction(
        name=name, id=rxn_id, reactants=reactants, products=products, rate_constant=rate_constant
    )


def _parse_reaction_system(rs_data: dict[str, Any]) -> ReactionSystem:
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
    subsystems: dict[str, Any] = {}
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

    # Events are owned by the component that declares them; see _parse_model.
    if "continuous_events" in rs_data:
        rs.continuous_events = [_parse_continuous_event(ev) for ev in rs_data["continuous_events"]]
    if "discrete_events" in rs_data:
        rs.discrete_events = [_parse_discrete_event(ev) for ev in rs_data["discrete_events"]]

    return rs


def _parse_reference(ref_data: dict[str, Any]) -> Reference:
    """Parse a reference from JSON data."""
    return Reference(
        title=ref_data.get("citation", ""),
        authors=[],  # Schema doesn't have authors field
        journal=None,
        year=None,
        doi=ref_data.get("doi"),
        url=ref_data.get("url"),
    )


def _parse_metadata(metadata_data: dict[str, Any]) -> Metadata:
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
        keywords=metadata_data.get("tags", []),  # Schema uses "tags" not "keywords"
    )


def _parse_data_loader_source(src_data: dict[str, Any]) -> DataLoaderSource:
    return DataLoaderSource(
        url_template=src_data["url_template"],
        mirrors=list(src_data.get("mirrors", [])),
    )


def _parse_data_loader_temporal(tmp_data: dict[str, Any]) -> DataLoaderTemporal:
    return DataLoaderTemporal(
        start=tmp_data.get("start"),
        end=tmp_data.get("end"),
        file_period=tmp_data.get("file_period"),
        frequency=tmp_data.get("frequency"),
        records_per_file=tmp_data.get("records_per_file"),
        time_variable=tmp_data.get("time_variable"),
    )


def _parse_data_loader_variable(var_data: dict[str, Any]) -> DataLoaderVariable:
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


def _parse_data_loader_determinism(det_data: dict[str, Any]) -> DataLoaderDeterminism:
    """Parse a determinism block from JSON data (esm-spec §8.9.2)."""
    return DataLoaderDeterminism(
        endian=det_data.get("endian"),
        float_format=det_data.get("float_format"),
        integer_width=det_data.get("integer_width"),
    )


def _parse_data_loader(loader_data: dict[str, Any]) -> DataLoader:
    """Parse a data loader from JSON data."""
    kind = DataLoaderKind(loader_data["kind"])
    source = _parse_data_loader_source(loader_data["source"])

    variables = {
        vname: _parse_data_loader_variable(vdef) for vname, vdef in loader_data["variables"].items()
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


def _parse_operator(operator_data: dict[str, Any], name: str = "") -> Operator:
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
        name=name,
        modifies=modifies,
        reference=reference,
        config=config,
        description=description,
    )


def _parse_registered_function(rf_data: dict[str, Any]) -> RegisteredFunction:
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


def _parse_coupling_entry(coupling_data: dict[str, Any]) -> CouplingEntry:
    """Parse a coupling entry from JSON data."""
    # Get coupling type from schema. Map straight onto the CouplingType enum
    # (whose values ARE the schema type strings) so this can't drift when a new
    # coupling type is added — an unknown value raises a clear ParseError.
    schema_type = coupling_data["type"]
    try:
        coupling_type = CouplingType(schema_type)
    except ValueError as e:
        raise ParseError(f"Unknown coupling type: {schema_type}") from e

    description = coupling_data.get("description")

    # Create appropriate coupling entry based on type
    if coupling_type == CouplingType.OPERATOR_COMPOSE:
        return OperatorComposeCoupling(
            description=description,
            systems=coupling_data.get("systems", []),
            translate=coupling_data.get("translate", {}),
            lifting=coupling_data.get("lifting"),
        )

    if coupling_type == CouplingType.COUPLE:
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
                    expression=_parse_expression(eq_data["expression"])
                    if "expression" in eq_data
                    else None,
                )
                equations.append(equation)
            connector = Connector(equations=equations)

        return CouplingCouple(
            description=description, systems=coupling_data.get("systems", []), connector=connector
        )

    if coupling_type == CouplingType.VARIABLE_MAP:
        # `transform` is EITHER one of the legacy enum strings OR an
        # ExpressionNode object (in-progress-0.8.0 widening). The expression
        # form computes the mapped value itself, so it admits no separate
        # `factor` scaling slot.
        transform_data = coupling_data.get("transform")
        if isinstance(transform_data, dict):
            if "factor" in coupling_data:
                raise ParseError(
                    "variable_map coupling: an expression 'transform' takes no "
                    "'factor' (the expression computes the mapped value itself)"
                )
            transform = _parse_expression(transform_data)
        else:
            transform = transform_data
        return VariableMapCoupling(
            description=description,
            from_var=coupling_data.get("from"),
            to_var=coupling_data.get("to"),
            transform=transform,
            factor=coupling_data.get("factor"),
        )

    if coupling_type == CouplingType.COUPLING_IMPORT:
        # A `coupling_import` (esm-spec §10.10) carries only a `ref` to a
        # coupling-library file and a role->component `bind` map. Expansion is
        # deferred to flatten (earthsci_ast.coupling_imports); the source entry
        # is preserved here for round-trip.
        bind_raw = coupling_data.get("bind", {})
        bind = dict(bind_raw) if isinstance(bind_raw, dict) else {}
        return CouplingImport(
            description=description,
            ref=coupling_data.get("ref"),
            bind=bind,
        )

    if coupling_type == CouplingType.OPERATOR_APPLY:
        return OperatorApplyCoupling(
            description=description, operator=coupling_data.get("operator")
        )

    if coupling_type == CouplingType.CALLBACK:
        return CallbackCoupling(
            description=description,
            callback_id=coupling_data.get("callback_id"),
            config=coupling_data.get("config", {}),
        )

    if coupling_type == CouplingType.EVENT:
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
            affect_neg = [_parse_affect(affect) for affect in coupling_data["affect_neg"]]

        return EventCoupling(
            description=description,
            event_type=coupling_data.get("event_type"),
            conditions=conditions,
            trigger=trigger,
            affects=affects,
            affect_neg=affect_neg,
            discrete_parameters=coupling_data.get("discrete_parameters", []),
            root_find=coupling_data.get("root_find"),
            reinitialize=coupling_data.get("reinitialize"),
        )

    raise ParseError(f"Unknown coupling type: {coupling_type}")


def _parse_domain(domain_data: dict[str, Any]) -> Domain:
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
            reference_time=temporal_data.get("reference_time"),
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

            start_dt = datetime.fromisoformat(domain.temporal.start.replace("Z", "+00:00"))
            end_dt = datetime.fromisoformat(domain.temporal.end.replace("Z", "+00:00"))

            if start_dt >= end_dt:
                errors.append("Temporal domain: start time must be before end time")

            if domain.temporal.reference_time:
                ref_dt = datetime.fromisoformat(
                    domain.temporal.reference_time.replace("Z", "+00:00")
                )
                if ref_dt < start_dt or ref_dt > end_dt:
                    errors.append(
                        "Temporal domain: reference time must be within start and end times"
                    )
        except ValueError as e:
            errors.append(f"Temporal domain: invalid datetime format - {e}")

    if errors:
        raise ParseError(
            "Domain validation failed:\n" + "\n".join(f"  - {error}" for error in errors)
        )


def _parse_esm_data(data: dict[str, Any]) -> EsmFile:
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
    index_sets: dict[str, Any] = {}
    if "index_sets" in data and data["index_sets"] is not None:
        index_sets = dict(data["index_sets"])

    # Parse data loaders
    data_loaders: dict[str, DataLoader] = {}
    if "data_loaders" in data:
        for loader_name, loader_data in data["data_loaders"].items():
            loader = _parse_data_loader(loader_data)
            loader.name = loader_name
            data_loaders[loader_name] = loader

    # Parse operators
    operators = []
    if "operators" in data:
        for op_name, op_data in data["operators"].items():
            operators.append(_parse_operator(op_data, op_name))

    # Parse registered_functions (esm-spec §9.2 — DEPRECATED in v0.3.0)
    registered_functions = {}
    if "registered_functions" in data:
        for rf_name, rf_data in data["registered_functions"].items():
            registered_functions[rf_name] = _parse_registered_function(rf_data)

    # Parse top-level enums block (esm-spec §9.3). Values are validated to be
    # positive integers by the schema; unique-within-enum is also enforced.
    enums: dict[str, dict[str, int]] = {}
    if "enums" in data and data["enums"] is not None:
        for enum_name, mapping in data["enums"].items():
            if not isinstance(mapping, dict):
                raise ParseError(
                    f"enums/{enum_name}: must be an object mapping symbol names "
                    f"to positive integers (esm-spec §9.3)"
                )
            seen_values: dict[int, str] = {}
            decoded: dict[str, int] = {}
            for sym, val in mapping.items():
                if not isinstance(val, int) or isinstance(val, bool) or val < 1:
                    raise ParseError(
                        f"enums/{enum_name}/{sym}: value must be a positive integer (got {val!r})"
                    )
                if val in seen_values:
                    raise ParseError(
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
    function_tables: dict[str, FunctionTable] = {}
    if "function_tables" in data and data["function_tables"] is not None:
        ft_map = data["function_tables"]
        if not isinstance(ft_map, dict):
            raise ParseError(
                "Top-level 'function_tables' must be an object keyed by table id "
                f"(esm-spec §9.5). Got: {type(ft_map).__name__}"
            )
        for ft_name, ft_data in ft_map.items():
            axes_raw = ft_data.get("axes")
            if not isinstance(axes_raw, list):
                raise ParseError(
                    f"function_tables['{ft_name}']: 'axes' must be a list (esm-spec §9.5)"
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
                raise ParseError(
                    f"function_tables['{ft_name}']: 'data' is required (esm-spec §9.5)"
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

    # EsmFile.events is a flat aggregation of the component-owned events (the
    # SAME objects as model/rs .discrete_events/.continuous_events, so
    # ownership is preserved for serialization while flat consumers —
    # flatten, validation, simulation — keep their simple iteration).
    events = []
    for component in list(models.values()) + list(reaction_systems.values()):
        if isinstance(component, dict):
            # Unresolved {"ref": ...} entry (resolve_model_refs runs later).
            continue
        events.extend(component.discrete_events)
        events.extend(component.continuous_events)

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


_ENV_REF_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def _expand_ref_env(ref: str) -> str:
    """Expand ``${VAR}`` tokens in a §4.7 ref from the environment.

    esm-spec §4.7: OPTIONAL loader capability; an unset variable is left literal
    (so the ref fails to resolve rather than misresolving). Only the braced
    ``${VAR}`` form is expanded, matching the Julia binding.
    """
    return _ENV_REF_RE.sub(lambda m: os.environ.get(m.group(1), m.group(0)), ref)


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
    ref = _expand_ref_env(ref)  # esm-spec §4.7 ${VAR} expansion
    if ref.startswith("http://") or ref.startswith("https://"):
        import urllib.error
        import urllib.request

        try:
            with urllib.request.urlopen(ref) as response:
                return response.read().decode("utf-8")
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            raise SubsystemRefError(f"Failed to fetch subsystem ref URL '{ref}': {e}") from e
    else:
        resolved = os.path.normpath(os.path.join(base_path, ref))
        if not os.path.exists(resolved):
            raise SubsystemRefError(
                f"Subsystem ref file not found: '{resolved}' "
                f"(resolved from '{ref}' relative to '{base_path}')"
            )
        with open(resolved) as f:
            return f.read()


def _subsystem_ref_bindings(sub_value: dict[str, Any], where: str) -> dict[str, Any]:
    """Extract the optional metaparameter ``bindings`` of a §4.7 subsystem
    ref (esm-spec §9.7.6 binding site 3). A value may be a *metaparameter
    expression* — an integer literal, a name in the MOUNTING document's
    metaparameter scope, or a ``{op: +|-|*|/, args}`` tree over the same (e.g.
    ``NTGT = NX*NY``). Values are returned UNFOLDED; :func:`_load_ref_data` folds
    them against the mounting document's closed environment before closing the
    referenced document's metaparameters."""
    from .template_imports import require_meta_expr

    bindings: dict[str, Any] = {}
    raw = sub_value.get("bindings")
    if isinstance(raw, dict):
        for bk, bv in raw.items():
            bindings[str(bk)] = require_meta_expr(bv, f"{where}: binding '{bk}'")
    return bindings


def _subsystem_ref_injected_imports(sub_value: dict[str, Any]) -> list[Any]:
    """The optional ``expression_template_imports`` of a §4.7 subsystem-ref edge
    (esm-spec §9.7.10 form A): raw §9.7.2 import entries the mounting document
    injects into the REFERENCED component's own template scope. Returned as a
    list of raw dicts (empty when absent); schema-validated as an array of
    TemplateImport before this runs."""
    raw = sub_value.get("expression_template_imports")
    if isinstance(raw, list):
        return list(raw)
    return []


def _absolutize_injected_imports(
    injected_imports: list[Any] | None,
    mount_base: str,
) -> list[Any]:
    """Rewrite each §9.7.10 form-A injected import entry's relative ``ref`` to an
    absolute path anchored at the MOUNTING document's directory (``mount_base``).

    The ref edge's ``expression_template_imports`` are authored relative to the
    document that CARRIES the edge (the assembler), but they are folded into the
    REFERENCED component's own scope and then resolved relative to THAT
    component's directory (``new_base``). Without this rewrite an injected rule
    ``../earthscidiscretizations/...`` would resolve under the leaf's directory
    (``…/earthscimodels/components/…/earthscidiscretizations/…``) and 404.
    Absolutizing here — mirroring the Julia reference, which absolutizes the edge
    imports against the assembler dir before splicing — makes each injected
    library resolve from the assembler regardless of where the leaf lives;
    absolute refs bypass the per-component ``base_dir`` in ``_load_import_raw``.
    URLs and already-absolute refs pass through unchanged, and every other field
    on the entry (``bindings`` / ``only`` / ``as``) is preserved."""
    if not injected_imports:
        return []
    out: list[Any] = []
    for entry in injected_imports:
        e = copy.deepcopy(entry)
        if isinstance(e, dict):
            ref = e.get("ref")
            if (
                isinstance(ref, str)
                and ref
                and not ref.startswith(("http://", "https://"))
                and not os.path.isabs(ref)
            ):
                e["ref"] = os.path.abspath(os.path.join(mount_base, ref))
        out.append(e)
    return out


def _load_ref_data(
    ref_str: str,
    base_path: str,
    bindings: dict[str, Any],
    kind: str,
    injected_imports: list[Any] | None = None,
    loader_metaparameters: dict[str, int] | None = None,
    parent_metaparameters: dict[str, int] | None = None,
) -> tuple:
    """Fetch, gate, schema-validate, §9.7-resolve, and template-lower a
    referenced ESM document (esm-spec §4.7 / §9.7.6 binding site 3).

    Returns ``(ref_data, new_base)`` where ``ref_data`` is the resolved,
    lowered raw dict (ready for ``_parse_esm_data``) and ``new_base`` the
    directory anchoring the referenced file's own nested refs. A ref that
    targets a template-library file is rejected with the stable
    ``subsystem_ref_is_template_library`` diagnostic (esm-spec §9.7.1): the
    two reference mechanisms are disjoint.

    ``injected_imports`` are the §4.7 ref edge's
    ``expression_template_imports`` (esm-spec §9.7.10 form A): they are
    appended to the referenced document's single component's own scope BEFORE
    resolution, so the §9.6.3 fixpoint lowers its rewrite-targets at the mount
    under the assembler-chosen discretization. Their relative refs are
    absolutized against ``base_path`` (the MOUNTING document's dir) first — they
    are authored relative to the assembler that carries the edge, not the leaf
    they land in.

    ``loader_metaparameters`` are the top-level ``load()`` API bindings (esm-spec
    §9.7.6 binding site 4). Those the referenced document DECLARES are propagated
    into its close so a leaf mounted with no explicit edge ``bindings`` still
    resolves under the loader's grid (e.g. NX/NY), matching the Julia/Rust
    single-root-resolve semantics; explicit edge ``bindings`` (site 3) win over
    them, and names the leaf does not declare are dropped (never forwarded, so
    they cannot raise ``template_import_unknown_name`` against the leaf).
    """
    from .lower_expression_templates import (
        ExpressionTemplateError,
        lower_expression_templates,
        reject_expression_templates_pre_v04,
    )
    from .template_imports import (
        _is_template_library_doc,
        apply_scope_injections,
        reject_template_imports_pre_v08,
        resolve_template_machinery,
    )

    ref_str = _expand_ref_env(ref_str)  # esm-spec §4.7 ${VAR} expansion
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
            SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY,
            f"Subsystem ref '{ref_str}' targets a template-library file; "
            "libraries are imported via expression_template_imports "
            "(esm-spec §9.7.1)",
        )

    # A §4.7 subsystem ref MUST NOT target a coupling-library file either —
    # a coupling library is imported via a coupling_import coupling entry, not
    # mounted as a subsystem (esm-spec §10.9).
    from .coupling_imports import is_coupling_library_doc

    if is_coupling_library_doc(ref_data):
        raise ExpressionTemplateError(
            SUBSYSTEM_REF_IS_COUPLING_LIBRARY,
            f"Subsystem ref '{ref_str}' targets a coupling-library file; "
            "libraries are imported via a coupling_import coupling entry "
            "(esm-spec §10.9)",
        )

    # Validate the referenced file against the schema.
    schema = _get_schema()
    try:
        validate(ref_data, schema)
    except jsonschema.ValidationError as e:
        raise SubsystemRefError(
            f"Schema validation failed for {kind} ref '{ref_str}': {e.message}"
        ) from e

    # esm-spec §9.7.10 form A: fold the ref edge's injected imports into the
    # referenced document's single component's own `expression_template_imports`
    # before resolution (returns None when there is nothing to inject, keeping
    # the fast path). The injected refs are absolutized against the MOUNTING
    # document's dir (`base_path`) first, so they resolve from the assembler that
    # authored them rather than from the leaf they are folded into.
    injected_abs = _absolutize_injected_imports(injected_imports, base_path)
    injected_root = apply_scope_injections(ref_data, injected_abs)
    if injected_root is not None:
        ref_data = injected_root

    # Close the referenced document's metaparameters (esm-spec §9.7.6): explicit
    # edge `bindings` (site 3) take precedence, backfilled by the loader-API
    # bindings (site 4) for names the leaf declares — so a leaf mounted with no
    # edge bindings still inherits the loader's grid instead of falling to its
    # own defaults. Names the leaf does not declare are never forwarded.
    leaf_decls = set((ref_data.get("metaparameters") or {}).keys())
    effective_bindings: dict[str, int] = {
        k: v for k, v in (loader_metaparameters or {}).items() if k in leaf_decls
    }
    # Fold each edge binding VALUE (a metaparameter expression, esm-spec §9.7.6)
    # to a concrete integer against the MOUNTING document's closed metaparameter
    # environment. A subsystem ref is resolved as a complete document and folded
    # to concrete integers at the mount, so — unlike an import edge — its binding
    # values cannot be carried symbolically; they fold here against the parent's
    # already-closed metaparameters (the parent closes before its refs resolve).
    from .template_imports import eval_meta_expr

    for bk, bv in (bindings or {}).items():
        effective_bindings[bk] = eval_meta_expr(
            bv, parent_metaparameters or {}, f"mount of '{ref_str}', binding '{bk}'"
        )

    # Resolve the referenced document's §9.7 machinery under the effective
    # metaparameter close, then run the §9.6.3 rewrite fixpoint so the inlined
    # component carries only normal Expression ASTs (Option A round-trip).
    resolved = resolve_template_machinery(ref_data, new_base, metaparameters=effective_bindings)
    if resolved is not None:
        ref_data = resolved
    ref_data = lower_expression_templates(ref_data)

    return ref_data, new_base


# Index-set declaration fields compared by the §4.7 / §9.7.5 deep-equal test
# (the semantic shape of an axis; description / metadata are ignored, mirroring
# the Julia reference's field-wise `_index_set_deep_equal`).
_ISET_SEMANTIC_KEYS = (
    "kind",
    "size",
    "members",
    "of",
    "offsets",
    "values",
    "from_faq",
)


def _index_set_deep_equal(a: Any, b: Any) -> bool:
    """Structural equality of two index-set declarations (esm-spec §4.7 /
    §9.7.5): equal ``kind`` / ``size`` / ``members`` / ``of`` / ``offsets`` /
    ``values`` / ``from_faq``. Non-semantic fields (``description``) do not
    affect the judgment, matching the Julia reference."""
    if not (isinstance(a, dict) and isinstance(b, dict)):
        return a == b
    return all(a.get(k) == b.get(k) for k in _ISET_SEMANTIC_KEYS)


def _index_set_show(s: Any) -> str:
    if not isinstance(s, dict):
        return repr(s)
    parts = []
    for k in ("kind", "size", "members", "of", "from_faq"):
        if s.get(k) is not None:
            parts.append(f"{k}={s[k]}")
    return ", ".join(parts)


def _merge_subsystem_index_sets(
    registry: dict[str, Any],
    loaded_index_sets: dict[str, Any],
    ref: str,
) -> None:
    """Merge a referenced subsystem file's top-level ``index_sets`` into the
    importing document's registry (esm-spec §4.7, mirroring the §9.7.5
    template-import merge). Deep-equal redeclaration is idempotent; a non-equal
    collision raises ``subsystem_index_set_conflict`` (§9.6.6) — the mounted-mesh
    failure mode this makes loud: a mesh file whose axis size disagrees with the
    importer's declaration must fail at load, not silently resolve against the
    importer."""
    if not isinstance(loaded_index_sets, dict):
        return
    from .lower_expression_templates import ExpressionTemplateError

    for n, decl in loaded_index_sets.items():
        if n in registry:
            if not _index_set_deep_equal(registry[n], decl):
                raise ExpressionTemplateError(
                    "subsystem_index_set_conflict",
                    f"index set '{n}' from subsystem ref '{ref}' "
                    f"({_index_set_show(decl)}) collides with a non-deep-equal "
                    "declaration in the importing document "
                    f"({_index_set_show(registry[n])}). A referenced subsystem "
                    "file's top-level index_sets merge into the importing "
                    "document's registry; deep-equal redeclaration is "
                    "idempotent, a size/kind disagreement is a load-time error "
                    "(esm-spec §4.7).",
                )
        else:
            registry[n] = decl


def _resolve_model_subsystems(
    model: Model,
    base_path: str,
    seen_refs: set,
    registry: dict[str, Any],
    chain: tuple[str, ...] = (),
) -> None:
    """Recursively resolve subsystem refs within a Model.

    Args:
        model: The model whose subsystems should be resolved
        base_path: The base directory for resolving relative paths
        seen_refs: Set of already-seen ref strings for circular detection
        registry: The importing document's index-set registry
            (``EsmFile.index_sets``); every referenced subsystem file's
            top-level ``index_sets`` merge into it at resolution time
            (esm-spec §4.7).
        chain: The already-seen refs in resolution order (parallel to
            ``seen_refs``, which is unordered); used only to print a
            deterministic chain in the circular-reference error.
    """
    if not model.subsystems:
        return

    resolved_subsystems: dict[str, Any] = {}
    for sub_name, sub_value in model.subsystems.items():
        # During parsing, a ref object comes through as a dict with a "ref" key
        # before being coerced to a Model.
        if isinstance(sub_value, dict) and "ref" in sub_value:
            ref_str = sub_value["ref"]

            # Circular reference detection
            canonical = (
                os.path.normpath(os.path.join(base_path, ref_str))
                if not ref_str.startswith("http")
                else ref_str
            )
            if canonical in seen_refs:
                raise CircularReferenceError(
                    f"Circular subsystem reference detected: '{ref_str}' "
                    f"(chain: {' -> '.join((*chain, canonical))})"
                )
            new_seen = seen_refs | {canonical}
            new_chain = (*chain, canonical)

            # Optional `bindings` close the referenced document's open
            # metaparameters at this edge (esm-spec §9.7.6 binding site 3);
            # optional `expression_template_imports` inject a discretization
            # into the referenced component's scope (esm-spec §9.7.10 form A).
            bindings = _subsystem_ref_bindings(sub_value, f"subsystems.{sub_name}")
            injected = _subsystem_ref_injected_imports(sub_value)
            ref_data, new_base = _load_ref_data(ref_str, base_path, bindings, "subsystem", injected)

            parsed = _parse_esm_data(ref_data)

            # esm-spec §4.7: the mounted file's document-scoped index sets
            # (already metaparameter-folded) join the importing document's
            # registry, so the importer's variables may be shaped over the mesh
            # file's axes and a disagreement fails loudly (deep-equal-or-error).
            _merge_subsystem_index_sets(registry, parsed.index_sets, ref_str)

            # Extract the single top-level model or data loader. A referenced
            # file with exactly one top-level data loader (RFC pure-io-data-loaders
            # §4.4) resolves to that loader, named by the parent subsystem key.
            if parsed.models:
                # Take the first (and expected-only) model
                sub_model = next(iter(parsed.models.values()))
                sub_model.name = sub_name
                # Recursively resolve nested subsystem refs; nested subsystem
                # index sets merge into the SAME (top document) registry.
                _resolve_model_subsystems(sub_model, new_base, new_seen, registry, new_chain)
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
                _resolve_model_subsystems(sub_value, base_path, seen_refs, registry, chain)
            resolved_subsystems[sub_name] = sub_value

    model.subsystems = resolved_subsystems


def _resolve_reaction_system_subsystems(
    rs: ReactionSystem,
    base_path: str,
    seen_refs: set,
    chain: tuple[str, ...] = (),
) -> None:
    """Recursively resolve subsystem refs within a ReactionSystem.

    Args:
        rs: The reaction system whose subsystems should be resolved
        base_path: The base directory for resolving relative paths
        seen_refs: Set of already-seen ref strings for circular detection
        chain: The already-seen refs in resolution order (parallel to
            ``seen_refs``); used only to print a deterministic chain in the
            circular-reference error.
    """
    if not rs.subsystems:
        return

    resolved_subsystems: dict[str, Any] = {}
    for sub_name, sub_value in rs.subsystems.items():
        if isinstance(sub_value, dict) and "ref" in sub_value:
            ref_str = sub_value["ref"]

            canonical = (
                os.path.normpath(os.path.join(base_path, ref_str))
                if not ref_str.startswith("http")
                else ref_str
            )
            if canonical in seen_refs:
                raise CircularReferenceError(
                    f"Circular subsystem reference detected: '{ref_str}' "
                    f"(chain: {' -> '.join((*chain, canonical))})"
                )
            new_seen = seen_refs | {canonical}
            new_chain = (*chain, canonical)

            bindings = _subsystem_ref_bindings(sub_value, f"subsystems.{sub_name}")
            injected = _subsystem_ref_injected_imports(sub_value)
            ref_data, new_base = _load_ref_data(ref_str, base_path, bindings, "subsystem", injected)

            parsed = _parse_esm_data(ref_data)

            # Extract the single top-level reaction system
            if parsed.reaction_systems:
                sub_rs = next(iter(parsed.reaction_systems.values()))
                sub_rs.name = sub_name
                _resolve_reaction_system_subsystems(sub_rs, new_base, new_seen, new_chain)
                resolved_subsystems[sub_name] = sub_rs
            else:
                raise SubsystemRefError(
                    f"Subsystem ref '{ref_str}' does not contain a reaction system"
                )
        else:
            if isinstance(sub_value, ReactionSystem):
                _resolve_reaction_system_subsystems(sub_value, base_path, seen_refs, chain)
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

    # The importing document's index-set registry (esm-spec §4.7): threaded
    # down the model subsystem walk so every referenced subsystem file's
    # top-level index_sets merge into it (deep-equal-or-error). Reaction-system
    # subsystems do not merge (matching the Julia reference).
    registry = esm_file.index_sets
    if not isinstance(registry, dict):
        registry = {}
        esm_file.index_sets = registry

    for model in esm_file.models.values():
        _resolve_model_subsystems(model, base_path, seen, registry)

    for rs in esm_file.reaction_systems.values():
        _resolve_reaction_system_subsystems(rs, base_path, seen)


def resolve_model_refs(
    esm_file: EsmFile,
    base_path: str,
    loader_metaparameters: dict[str, int] | None = None,
    parent_metaparameters: dict[str, int] | None = None,
) -> None:
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
        loader_metaparameters: The top-level ``load()`` API metaparameter
            bindings (esm-spec §9.7.6 binding site 4). Forwarded to each mounted
            leaf's resolution so a §9.7.10 form-A mount edge closes the leaf's
            declared metaparameters (e.g. NX/NY) under the loader's grid when the
            edge itself carries no explicit ``bindings``.

    Raises:
        CircularReferenceError: If circular references are detected
        SubsystemRefError: If a reference cannot be resolved or does not
            contain a top-level model
    """
    registry = esm_file.index_sets
    if not isinstance(registry, dict):
        registry = {}
        esm_file.index_sets = registry
    resolved_models: dict[str, Any] = {}
    for model_name, model_value in esm_file.models.items():
        # An already-parsed Model (inline definition) passes through unchanged.
        if not (isinstance(model_value, dict) and "ref" in model_value):
            resolved_models[model_name] = model_value
            continue

        ref_str = model_value["ref"]

        # Circular reference detection. Seed the chain with this ref so a
        # subsystem inside the referenced file that points back is caught.
        canonical = (
            os.path.normpath(os.path.join(base_path, ref_str))
            if not ref_str.startswith("http")
            else ref_str
        )
        seen = {canonical}

        bindings = _subsystem_ref_bindings(model_value, f"models.{model_name}")
        injected = _subsystem_ref_injected_imports(model_value)
        ref_data, new_base = _load_ref_data(
            ref_str,
            base_path,
            bindings,
            "model",
            injected,
            loader_metaparameters=loader_metaparameters,
            parent_metaparameters=parent_metaparameters,
        )

        parsed = _parse_esm_data(ref_data)

        # esm-spec §4.7: the referenced file's document-scoped index sets — now
        # metaparameter-folded and, for a §9.7.10 form-A mount edge, carrying the
        # grid axes SYNTHESIZED by the injected discretization's grid contract
        # (e.g. `x`/`y` intervals of size NX/NY imported transitively via the
        # rules' `grid.esm`) — join the importing document's registry. Without
        # this the leaf's array states (psi shaped `[x, y]`) and any aggregate
        # `ic` ranging `from x` have no index sets to resolve against and the
        # flattened system is grid-less. Mirrors the subsystem-ref path's merge
        # (`_resolve_model_subsystems`) and the Julia/Rust single-root resolve,
        # which keep these axes in the flattened system.
        _merge_subsystem_index_sets(registry, parsed.index_sets, ref_str)

        # A top-level model ref must resolve to exactly one model. Unlike a
        # subsystem ref, a data loader or reaction system is not a valid
        # top-level model component.
        if not parsed.models:
            raise SubsystemRefError(f"Model ref '{ref_str}' does not contain a top-level model")

        sub_model = next(iter(parsed.models.values()))
        sub_model.name = model_name
        # Recursively resolve the spliced model's own subsystem refs, relative
        # to the referenced file's directory; nested subsystem index sets merge
        # into the importing document's registry (esm-spec §4.7).
        _resolve_model_subsystems(sub_model, new_base, seen, registry, (canonical,))
        resolved_models[model_name] = sub_model

    esm_file.models = resolved_models


# Operator arity requirements: (min_args, max_args). None = unlimited.
# ---------------------------------------------------------------------------
# The raw-dict structural-validation suite (operator arity, symbol tables,
# scoped-reference resolution, unit/dimension consistency, metadata formats,
# and the other _check_* passes) lives in structural_checks.py.
# ---------------------------------------------------------------------------
from .structural_checks import (  # noqa: E402
    _validate_structural,  # used by load(); re-exported for compatibility
)


def load(
    path_or_string: str | Path | dict,
    *,
    metaparameters: dict[str, int] | None = None,
    base_path: str | None = None,
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
        SchemaValidationError: If the JSON doesn't match the schema (raised in
            place of the underlying ``jsonschema.ValidationError``)
        FileNotFoundError: If the file path doesn't exist
    """
    # Handle dict input directly
    resolved_base = base_path if base_path is not None else os.getcwd()
    file_path = None
    if isinstance(path_or_string, dict):
        # Shallow-copy so the top-level ``data.pop(...)`` of the schema-forbidden
        # ``continuous_events`` / ``discrete_events`` keys below does not mutate a
        # caller's dict as a side effect.
        data = dict(path_or_string)
    elif isinstance(path_or_string, Path) or (
        isinstance(path_or_string, str) and os.path.exists(path_or_string)
    ):
        # It's a file path
        file_path = Path(path_or_string)
        if base_path is None:
            resolved_base = str(file_path.parent.resolve())
        with open(path_or_string) as f:
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
        lower_expression_templates,
        reject_expression_templates_pre_v04,
    )
    from .template_imports import (
        apply_scope_injections,
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

    # esm-spec §9.7.10 form B: fold any coupling-entry injection map into the
    # named target components' own `expression_template_imports` BEFORE
    # resolution, so the ordinary import resolver + §9.6.3 fixpoint lower the
    # target under the assembler-chosen discretization. The injection map is
    # consumed (does not survive parse → emit). Returns None (fast path) when
    # no coupling entry carries an injection. Form A (subsystem-ref edge) is
    # threaded through subsystem resolution; form C (test) is applied per-run
    # by the PDE runner.
    injected_root = apply_scope_injections(data, [])
    if injected_root is not None:
        data = injected_root

    # Capture the ROOT document's closed metaparameter environment (declared
    # defaults overlaid with the loader-API bindings) BEFORE resolution consumes
    # the `metaparameters` block. This is the scope against which a §4.7 mount
    # edge's binding EXPRESSIONS fold (e.g. `NTGT = NX*NY`, esm-spec §9.7.6).
    root_meta_env: dict[str, int] = {}
    _root_meta_decls = data.get("metaparameters")
    if isinstance(_root_meta_decls, dict):
        for _mn, _md in _root_meta_decls.items():
            if isinstance(_md, dict) and isinstance(_md.get("default"), int) and not isinstance(
                _md.get("default"), bool
            ):
                root_meta_env[str(_mn)] = _md["default"]
    if metaparameters:
        root_meta_env.update({str(k): v for k, v in metaparameters.items()})

    # Resolve esm-spec §9.7 machinery — template-library imports (depth-first
    # post-order, per-edge metaparameter instantiation), index_sets merge,
    # metaparameter close+fold — BEFORE any validator sees the tree (esm-spec
    # §9.7: "All resolution happens at load, before validation and before the
    # §9.6.3 fixpoint"). Returns None for documents without §9.7 machinery.
    resolved = resolve_template_machinery(data, base_path, metaparameters=metaparameters)
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
    # so its flat names `X.<var>` already equal the coupling-edge names. The
    # loader-API metaparameters are threaded in so a §9.7.10 form-A mount edge
    # resolves its leaf's discretization under the loader's grid (NX/NY) even
    # when the edge carries no explicit `bindings` — matching the Julia/Rust
    # single-root-resolve semantics so the SAME file runs identically.
    resolve_model_refs(
        esm_file,
        base_path,
        loader_metaparameters=metaparameters,
        parent_metaparameters=root_meta_env,
    )

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
