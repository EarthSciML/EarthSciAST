"""``table_lookup`` -> ``interp.linear`` / ``interp.bilinear`` / ``index``
lowering (esm-spec §9.5.3).

A ``table_lookup`` node is SUGAR. It names a ``function_tables`` entry plus one
input expression per declared axis, and §9.5.3 gives the exact §9.2
closed-function tree it stands for. Nothing downstream of the loader evaluates
``table_lookup`` itself -- the interpreter refuses the op outright ("Unsupported
operation: table_lookup") -- and until this module the lowering existed only
inside a test harness (``tests/test_function_tables_lowering.py``). A document
whose observed was defined by a ``table_lookup`` therefore validated, and then
could not evaluate a single inline-test assertion that depended on it, while the
same lookup written out by hand worked (issue #188).

**This runs at BUILD, not at load, and that is the point.** §9.5.4 makes
``function_tables`` / ``table_lookup`` first-class AUTHORED constructs that must
survive a round trip, and this binding serializes the typed
:class:`~earthsci_ast.esm_types.EsmFile` it loaded (``load_document`` ->
``to_json`` is a fixed point, pinned by ``tests/test_function_tables.py``) -- so
rewriting in :mod:`earthsci_ast.parse` would emit the lowered ``fn`` form and
break §9.5.4. §9.5.3 admits either an in-memory transformation or a direct
evaluator dispatch; lowering the typed document on its way into a build
satisfies the first while leaving the loaded image (and therefore ``to_json``)
authored-as-written.

Bit-equivalence with the hand-written inline-``const`` lookup (§9.5's central
promise) comes for free: the lowered tree drives the very same
:mod:`earthsci_ast.registered_functions` ``interp.linear`` / ``interp.bilinear``
implementations an author would have invoked by hand.

**``out_of_bounds: "error"`` is REFUSED, not silently clamped.** ``"clamp"`` is
required of every binding and ``"error"`` is "conformant when implemented"
(§9.5.1); this binding does not implement it, so §9.5.3a makes the lookup a
``table_out_of_bounds_unsupported`` error here rather than an ``interp.*`` tree
that answers in a mode the author did not ask for. That would be the same defect
this module exists to fix: a wrong number with nothing in the result to say so.
The refusal is raised where the node would otherwise lower, so such a document
still LOADS and still round-trips.
"""

from __future__ import annotations

import copy
import math
from dataclasses import replace
from typing import Any

from .error_handling import ErrorCode
from .errors import EarthSciAstError
from .esm_types import (
    Equation,
    EsmFile,
    Expr,
    ExprNode,
    FunctionTable,
    FunctionTableAxis,
    Model,
    ReactionSystem,
)
from .expr_walk import any_child, map_children

__all__ = ["TableLookupError", "lower_table_lookups"]

#: The op this pass consumes.
_TABLE_LOOKUP = "table_lookup"


class TableLookupError(EarthSciAstError, ValueError):
    """Raised when the esm-spec §9.5.3 ``table_lookup`` lowering fails.

    Carries one of the §9.5.5 diagnostic codes as a structured ``code``
    attribute -- like :class:`~earthsci_ast.registered_functions.EnumLoweringError`,
    the other load/build-time lowering pass -- rather than only in the message
    text. Also subclasses :class:`ValueError`, so a caller wrapping a build in
    ``except ValueError`` still catches it.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


def _err(code: ErrorCode, message: str) -> TableLookupError:
    return TableLookupError(code.value, message)


def lower_table_lookups(file: EsmFile) -> EsmFile:
    """Return ``file`` with every ``table_lookup`` op replaced by its §9.5.3
    ``interp.linear`` / ``interp.bilinear`` / ``index`` form.

    **Pure**: ``file`` is not modified, so the caller's document keeps the
    authored form §9.5.4 requires it to serialize. Node and container identity
    are preserved wherever nothing lowered, and a document that declares no
    ``function_tables`` comes back as the very same object without being walked
    at all -- which is nearly every document.

    Idempotent: after one pass no ``table_lookup`` node survives, so a second
    finds nothing to do. That matters because
    :func:`earthsci_ast.problem.esm_problem` lowers whatever document it is
    handed, including one an inline-test runner already lowered.

    Raises :class:`TableLookupError` carrying one of the esm-spec §9.5.5 codes
    (``table_lookup_unknown_table``, ``table_lookup_axis_name_mismatch``,
    ``table_lookup_output_out_of_range``, ``table_interpolation_axes_mismatch``,
    ``table_data_shape_mismatch``, ``table_axis_nan``), or
    ``table_out_of_bounds_unsupported`` for the §9.5.1 ``out_of_bounds:
    "error"`` mode this binding does not implement (§9.5.3a).
    """
    tables = file.function_tables or {}
    if not tables:
        return file

    # An event object is shared BY REFERENCE between its owning component and
    # the flat `EsmFile.events` view (see `parse._parse_esm_file`), and
    # `flatten` reads the flat view. Rebuilding one without the other would
    # hand the build the un-lowered copy, so every rebuilt event is recorded
    # here and `EsmFile.events` is re-pointed through it below -- which keeps
    # the aggregation the file actually has, rather than re-deriving one.
    rebuilt_events: dict[int, Any] = {}

    models = {name: _lower_model(m, tables, rebuilt_events) for name, m in file.models.items()}
    systems = {
        name: _lower_reaction_system(rs, tables, rebuilt_events)
        for name, rs in file.reaction_systems.items()
    }
    if all(models[k] is v for k, v in file.models.items()) and all(
        systems[k] is v for k, v in file.reaction_systems.items()
    ):
        return file
    events = [rebuilt_events.get(id(e), e) for e in file.events] if rebuilt_events else file.events
    return replace(file, models=models, reaction_systems=systems, events=events)


# ---------------------------------------------------------------------------
# Component walks. Each returns its input UNCHANGED when nothing lowered, so an
# untouched component keeps object identity (the shape `lower_enums` uses).
# ---------------------------------------------------------------------------


def _lower_model(model: Any, tables: dict[str, FunctionTable], events: dict[int, Any]) -> Any:
    """Lower every expression position of one model: equations, initialization
    equations, solver guesses, a parameter's ``update`` rules, the events it
    owns, its inline tests' §6.6.5 analytic ``reference`` expressions, and its
    subsystems."""
    if not isinstance(model, Model):
        # An unresolved `{"ref": ...}` subsystem entry; `resolve_subsystem_refs`
        # replaces it with a Model before anything evaluates it.
        return model

    variables = model.variables
    for vname, var in model.variables.items():
        new_update = _lower_update(var.update, tables)
        if new_update is not var.update:
            if variables is model.variables:
                variables = dict(model.variables)
            variables[vname] = replace(var, update=new_update)

    equations = _lower_equations(model.equations, tables)
    init_equations = _lower_equations(model.initialization_equations, tables)
    guesses = _lower_mapping(model.guesses, tables)
    continuous = _lower_continuous_events(model.continuous_events, tables, events)
    discrete = _lower_discrete_events(model.discrete_events, tables, events)
    tests = _lower_tests(model.tests, tables)

    subsystems = model.subsystems
    for sname, sub in model.subsystems.items():
        new_sub = _lower_model(sub, tables, events)
        if new_sub is not sub:
            if subsystems is model.subsystems:
                subsystems = dict(model.subsystems)
            subsystems[sname] = new_sub

    if (
        variables is model.variables
        and equations is model.equations
        and init_equations is model.initialization_equations
        and guesses is model.guesses
        and continuous is model.continuous_events
        and discrete is model.discrete_events
        and tests is model.tests
        and subsystems is model.subsystems
    ):
        return model
    return replace(
        model,
        variables=variables,
        equations=equations,
        initialization_equations=init_equations,
        guesses=guesses,
        continuous_events=continuous,
        discrete_events=discrete,
        tests=tests,
        subsystems=subsystems,
    )


def _lower_reaction_system(
    rs: Any, tables: dict[str, FunctionTable], events: dict[int, Any]
) -> Any:
    """Lower every expression position of one reaction system: parameter value
    expressions, reaction rate constants, constraint equations, the events it
    owns, its inline tests' references, and its subsystems."""
    if not isinstance(rs, ReactionSystem):
        return rs

    parameters = rs.parameters
    for i, param in enumerate(rs.parameters):
        new_value = _lower_expr(param.value, tables)
        if new_value is not param.value:
            if parameters is rs.parameters:
                parameters = list(rs.parameters)
            parameters[i] = replace(param, value=new_value)

    reactions = rs.reactions
    for i, r in enumerate(rs.reactions):
        new_rate = _lower_expr(r.rate_constant, tables)
        if new_rate is not r.rate_constant:
            if reactions is rs.reactions:
                reactions = list(rs.reactions)
            reactions[i] = replace(r, rate_constant=new_rate)

    constraints = _lower_equations(rs.constraint_equations, tables)
    continuous = _lower_continuous_events(rs.continuous_events, tables, events)
    discrete = _lower_discrete_events(rs.discrete_events, tables, events)
    tests = _lower_tests(rs.tests, tables)

    subsystems = rs.subsystems
    for sname, sub in rs.subsystems.items():
        new_sub = _lower_reaction_system(sub, tables, events)
        if new_sub is not sub:
            if subsystems is rs.subsystems:
                subsystems = dict(rs.subsystems)
            subsystems[sname] = new_sub

    if (
        parameters is rs.parameters
        and reactions is rs.reactions
        and constraints is rs.constraint_equations
        and continuous is rs.continuous_events
        and discrete is rs.discrete_events
        and tests is rs.tests
        and subsystems is rs.subsystems
    ):
        return rs
    return replace(
        rs,
        parameters=parameters,
        reactions=reactions,
        constraint_equations=constraints,
        continuous_events=continuous,
        discrete_events=discrete,
        tests=tests,
        subsystems=subsystems,
    )


def _lower_equations(eqs: list[Equation], tables: dict[str, FunctionTable]) -> list[Equation]:
    out: list[Equation] = []
    changed = False
    for eq in eqs:
        lhs = _lower_expr(eq.lhs, tables)
        rhs = _lower_expr(eq.rhs, tables)
        if lhs is eq.lhs and rhs is eq.rhs:
            out.append(eq)
        else:
            out.append(replace(eq, lhs=lhs, rhs=rhs))
            changed = True
    return out if changed else eqs


def _lower_mapping(mapping: dict[str, Any], tables: dict[str, FunctionTable]) -> dict[str, Any]:
    out = mapping
    for key, value in mapping.items():
        new_value = _lower_expr(value, tables)
        if new_value is not value:
            if out is mapping:
                out = dict(mapping)
            out[key] = new_value
    return out


def _lower_update(update: Any, tables: dict[str, FunctionTable]) -> Any:
    """Lower the expression positions of a parameter's update rules (esm-spec
    §5.4): the ``condition``/``crossing`` trigger, the ``expression`` value
    form, and the ``from`` binding's ``unit_conversion``."""
    if update is None:
        return update
    if isinstance(update, list):
        lowered = [_lower_update(rule, tables) for rule in update]
        return update if all(a is b for a, b in zip(lowered, update)) else lowered
    changes: dict[str, Any] = {}
    new_when = _lower_expr(update.when, tables)
    if new_when is not update.when:
        changes["when"] = new_when
    new_expression = _lower_expr(update.expression, tables)
    if new_expression is not update.expression:
        changes["expression"] = new_expression
    binding = update.from_source
    if binding is not None:
        new_conv = _lower_expr(binding.unit_conversion, tables)
        if new_conv is not binding.unit_conversion:
            changes["from_source"] = replace(binding, unit_conversion=new_conv)
    return replace(update, **changes) if changes else update


def _lower_affects(affects: Any, tables: dict[str, FunctionTable]) -> Any:
    if not affects:
        return affects
    out = affects
    for i, affect in enumerate(affects):
        new_rhs = _lower_expr(affect.rhs, tables)
        if new_rhs is not affect.rhs:
            if out is affects:
                out = list(affects)
            out[i] = replace(affect, rhs=new_rhs)
    return out


def _lower_continuous_events(
    evts: list[Any], tables: dict[str, FunctionTable], rebuilt: dict[int, Any]
) -> list[Any]:
    out = evts
    for i, ev in enumerate(evts):
        conditions = [_lower_expr(c, tables) for c in ev.conditions]
        if all(a is b for a, b in zip(conditions, ev.conditions)):
            conditions = ev.conditions
        affects = _lower_affects(ev.affects, tables)
        affect_neg = _lower_affects(ev.affect_neg, tables)
        if conditions is ev.conditions and affects is ev.affects and affect_neg is ev.affect_neg:
            continue
        new_ev = replace(ev, conditions=conditions, affects=affects, affect_neg=affect_neg)
        rebuilt[id(ev)] = new_ev
        if out is evts:
            out = list(evts)
        out[i] = new_ev
    return out


def _lower_discrete_events(
    evts: list[Any], tables: dict[str, FunctionTable], rebuilt: dict[int, Any]
) -> list[Any]:
    out = evts
    for i, ev in enumerate(evts):
        # `trigger.value` is a time, an external identifier, or -- for a
        # `condition` trigger -- an expression. `_lower_expr` passes the first
        # two straight through, so no discrimination on `trigger.type` is needed.
        trigger = ev.trigger
        new_value = _lower_expr(trigger.value, tables)
        affects = _lower_affects(ev.affects, tables)
        if new_value is trigger.value and affects is ev.affects:
            continue
        new_ev = replace(ev, trigger=replace(trigger, value=new_value), affects=affects)
        rebuilt[id(ev)] = new_ev
        if out is evts:
            out = list(evts)
        out[i] = new_ev
    return out


def _lower_tests(tests: list[Any], tables: dict[str, FunctionTable]) -> list[Any]:
    """Lower the analytic ``reference`` of every §6.6.5 assertion -- the one
    inline-test expression the runner evaluates itself, off the build path a
    ``table_lookup`` would otherwise be lowered on."""
    out = tests
    for i, test in enumerate(tests):
        assertions = test.assertions
        for j, a in enumerate(test.assertions):
            # A `{"type": "from_file", ...}` reference is carried verbatim.
            if isinstance(a.reference, dict):
                continue
            new_reference = _lower_expr(a.reference, tables)
            if new_reference is not a.reference:
                if assertions is test.assertions:
                    assertions = list(test.assertions)
                assertions[j] = replace(a, reference=new_reference)
        if assertions is test.assertions:
            continue
        if out is tests:
            out = list(tests)
        out[i] = replace(test, assertions=assertions)
    return out


# ---------------------------------------------------------------------------
# The expression rewrite itself.
# ---------------------------------------------------------------------------


def _has_table_lookup(expr: Expr) -> bool:
    """Whether ``expr`` carries a ``table_lookup`` anywhere. The guard that
    keeps a document whose tables are used in one equation from having its
    entire AST rebuilt equation by equation."""
    return isinstance(expr, ExprNode) and (
        expr.op == _TABLE_LOOKUP or any_child(expr, _has_table_lookup)
    )


def _lower_expr(expr: Expr, tables: dict[str, FunctionTable]) -> Expr:
    """Lower ``expr`` BOTTOM-UP: children first, so a ``table_lookup`` nested
    inside another node's axis input (or body, or filter, ...) is already an
    ``interp.*`` tree by the time its parent is rewritten. Returns ``expr``
    itself when it carries no lookup."""
    if not _has_table_lookup(expr):
        return expr
    node = map_children(expr, lambda child: _lower_expr(child, tables))
    if node.op != _TABLE_LOOKUP:
        return node
    return _lower_node(node, tables)


def _lower_node(node: ExprNode, tables: dict[str, FunctionTable]) -> ExprNode:
    """The §9.5.3 lowering of one ``table_lookup`` node."""
    table_id = node.table
    if not table_id:
        raise _err(
            ErrorCode.TABLE_LOOKUP_UNKNOWN_TABLE,
            "a `table_lookup` node carries no `table` id (esm-spec §9.5.2)",
        )
    table = tables.get(table_id)
    if table is None:
        raise _err(
            ErrorCode.TABLE_LOOKUP_UNKNOWN_TABLE,
            f"`table_lookup` references table `{table_id}`, which the document's "
            f"`function_tables` block does not declare",
        )
    if table.out_of_bounds == "error":
        raise _err(
            ErrorCode.TABLE_OUT_OF_BOUNDS_UNSUPPORTED,
            f'table `{table_id}` declares `out_of_bounds: "error"`, which this binding '
            f'does not implement — only the required "clamp" mode (esm-spec §9.5.1). '
            f"§9.5.3a: the lookup is refused rather than lowered to the clamping "
            f"`interp.*` form, because answering in a mode the author did not ask for "
            f"is a wrong number with nothing in the result to say so",
        )

    inputs = _axis_inputs(node, table, table_id)
    data = _output_slice(table, _output_index(node, table, table_id), table_id)
    kind = table.interpolation or "linear"
    axes = table.axes

    if kind == "linear" and len(axes) == 1:
        return _closed_fn(
            "interp.linear", [_const(data), _axis_const(axes[0], table_id), inputs[0]]
        )
    if kind == "bilinear" and len(axes) == 2:
        return _closed_fn(
            "interp.bilinear",
            [
                _const(data),
                _axis_const(axes[0], table_id),
                _axis_const(axes[1], table_id),
                inputs[0],
                inputs[1],
            ],
        )
    if kind == "nearest" and len(axes) == 1:
        # `nearest` is an `index` of the table slice at the searchsorted
        # position, not an `interp` blend.
        return ExprNode(
            op="index",
            args=[
                _const(data),
                _closed_fn("interp.searchsorted", [inputs[0], _axis_const(axes[0], table_id)]),
            ],
        )
    raise _err(
        ErrorCode.TABLE_INTERPOLATION_AXES_MISMATCH,
        f'table `{table_id}` declares `interpolation: "{kind}"` over {len(axes)} axes; '
        f"`linear` and `nearest` require 1, `bilinear` requires 2 (esm-spec §9.5.1)",
    )


def _axis_inputs(node: ExprNode, table: FunctionTable, table_id: str) -> list[Expr]:
    """The node's per-axis input expressions, in the table's DECLARED axis order
    (which is the order of ``data``'s inner dimensions, and therefore the
    argument order of ``interp.bilinear``)."""
    if node.args:
        raise _err(
            ErrorCode.TABLE_LOOKUP_AXIS_NAME_MISMATCH,
            f"`table_lookup` on table `{table_id}` carries {len(node.args)} positional "
            f"`args`; the per-axis inputs live under `axes` and `args` MUST be empty "
            f"(esm-spec §9.5.2)",
        )
    supplied = node.table_axes or {}
    inputs: list[Expr] = []
    for axis in table.axes:
        if axis.name not in supplied:
            raise _err(
                ErrorCode.TABLE_LOOKUP_AXIS_NAME_MISMATCH,
                f"`table_lookup` on table `{table_id}` supplies no input for its "
                f"declared axis `{axis.name}`",
            )
        inputs.append(supplied[axis.name])
    if len(supplied) != len(table.axes):
        declared = ", ".join(axis.name for axis in table.axes)
        raise _err(
            ErrorCode.TABLE_LOOKUP_AXIS_NAME_MISMATCH,
            f"`table_lookup` on table `{table_id}` supplies {len(supplied)} axis inputs "
            f"but the table declares {len(table.axes)} ({declared}); the key sets must "
            f"match exactly (esm-spec §9.5.2)",
        )
    return inputs


def _output_index(node: ExprNode, table: FunctionTable, table_id: str) -> int:
    """Resolve ``output`` (absent, integer index, or name) to a 0-based row
    index into ``data``'s leading dimension."""
    output = node.output
    outputs = table.outputs
    if output is None:
        return 0
    if isinstance(output, bool) or not isinstance(output, (int, str)):
        raise _err(
            ErrorCode.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
            f"`table_lookup.output` on table `{table_id}` must be a non-negative integer "
            f"or an output name, not {output!r}",
        )
    if isinstance(output, int):
        if output < 0:
            raise _err(
                ErrorCode.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
                f"`table_lookup.output` on table `{table_id}` is {output}; an integer "
                f"output index must be >= 0",
            )
        if outputs is None:
            # No `outputs` list means the table is single-output and `data` has
            # no leading output dimension at all (§9.5.1), so 0 is the only
            # index that names anything.
            if output != 0:
                raise _err(
                    ErrorCode.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
                    f"`table_lookup.output` {output} on table `{table_id}`, which "
                    f"declares no `outputs` and is therefore single-output",
                )
            return 0
        if output >= len(outputs):
            raise _err(
                ErrorCode.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
                f"`table_lookup.output` {output} on table `{table_id}` is out of range: "
                f"the table declares {len(outputs)} outputs",
            )
        return output
    if outputs is None:
        raise _err(
            ErrorCode.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
            f'`table_lookup.output` "{output}" names an output, but table `{table_id}` '
            f"declares no `outputs` list",
        )
    if output not in outputs:
        raise _err(
            ErrorCode.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
            f'`table_lookup.output` "{output}" is not one of table `{table_id}`\'s '
            f"outputs ({', '.join(outputs)})",
        )
    return outputs.index(output)


def _output_slice(table: FunctionTable, output: int, table_id: str) -> Any:
    """The ``data`` sub-array the lowered ``const`` carries: row ``output`` of
    the leading dimension for a multi-output table, and the whole literal for a
    single-output one (which has no leading output dimension, §9.5.1)."""
    if table.outputs is None:
        return table.data
    if not isinstance(table.data, list) or output >= len(table.data):
        raise _err(
            ErrorCode.TABLE_DATA_SHAPE_MISMATCH,
            f"table `{table_id}`: `data` has no row {output} for the selected output — "
            f"its leading dimension must equal `len(outputs)` (esm-spec §9.5.1)",
        )
    return table.data[output]


def _axis_const(axis: FunctionTableAxis, table_id: str) -> ExprNode:
    """``{"op": "const", "value": <axis values>}`` for one declared axis."""
    for value in axis.values:
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            raise _err(
                ErrorCode.TABLE_AXIS_NAN,
                f"table `{table_id}`: axis `{axis.name}` carries the non-numeric value "
                f"{value!r}; axis `values` must be strictly-increasing finite floats "
                f"(esm-spec §9.5.1)",
            )
        if not math.isfinite(value):
            raise _err(
                ErrorCode.TABLE_AXIS_NAN,
                f"table `{table_id}`: axis `{axis.name}` carries the non-finite value "
                f"{value!r}; axis `values` must be strictly-increasing finite floats "
                f"(esm-spec §9.5.1)",
            )
    return _const(axis.values)


def _const(value: Any) -> ExprNode:
    # Copied, not aliased: the lowered tree outlives this pass and must not
    # share mutable list structure with the document's `function_tables` block.
    return ExprNode(op="const", args=[], value=copy.deepcopy(value))


def _closed_fn(name: str, args: list[Expr]) -> ExprNode:
    return ExprNode(op="fn", args=args, name=name)
