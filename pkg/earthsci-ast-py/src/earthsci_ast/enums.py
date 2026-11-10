"""Enum lowering — esm-spec §9.3.

Resolves every ``enum`` op to a ``const`` integer against the ``enums`` block of
the file that wrote it:

- :func:`lower_enums` / :func:`lower_enums_mut` — the load-time pass over an
  :class:`EsmFile` (pure / in-place).
- :func:`lower_enum_ops_for_file` and :func:`lower_mounted_document_enums` — the
  raw-JSON passes at a file boundary (template import, §4.7 mount).
- :func:`check_enum_block` — the ``enum_duplicate_value`` block check.
- :class:`EnumLoweringError` — carries ``unknown_enum`` / ``unknown_enum_symbol``
  / ``enum_duplicate_value``.
"""

from __future__ import annotations

from dataclasses import replace
from typing import Any

from .error_handling import (
    ENUM_DUPLICATE_VALUE,
    UNKNOWN_ENUM,
    UNKNOWN_ENUM_SYMBOL,
)
from .errors import EarthSciAstError
from .esm_types import Equation, EsmFile, ExprNode, Model, ReactionSystem
from .expr_walk import iter_children, map_children


class EnumLoweringError(EarthSciAstError, ValueError):
    """Raised when enum lowering (esm-spec §9.3) fails.

    Carries the stable diagnostic ``code`` (``unknown_enum`` /
    ``unknown_enum_symbol`` / ``enum_duplicate_value``) as a structured attribute
    instead of interpolating it into the message text. Also subclasses :class:`ValueError`, so ``except ValueError`` catches
    it.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


def check_enum_block(enums: Any) -> None:
    """Reject an ``enums`` block in which two symbols of ONE enum map to the
    same integer, ``0`` included (esm-spec §9.3), with
    :class:`EnumLoweringError` ``enum_duplicate_value``.

    A defect of the block itself: it is raised whether or not any ``enum`` op
    names either symbol, and before any op resolves. Values may coincide across
    enums. Entries that are not objects, or values that are not integers, are
    left to the parser's own type checks.
    """
    if not isinstance(enums, dict):
        return
    for enum_name, mapping in enums.items():
        if not isinstance(mapping, dict):
            continue
        seen: dict[int, str] = {}
        for sym, val in mapping.items():
            if not isinstance(val, int) or isinstance(val, bool):
                continue
            if val in seen:
                raise EnumLoweringError(
                    ENUM_DUPLICATE_VALUE,
                    f"enums/{enum_name}: symbols `{seen[val]}` and `{sym}` both map to "
                    f"{val}; values must be unique within an enum (esm-spec §9.3)",
                )
            seen[val] = sym


def lower_enum_ops_for_file(
    document: Any, target: Any, open_names: frozenset[str] | set[str] = frozenset()
) -> Any:
    """Return raw-JSON ``target`` with its ``enum`` ops lowered against the
    ``enums`` block of ``document``, the file that wrote ``target``.

    An ``enum`` op is file-local (esm-spec §9.3): it resolves against the block
    of the file it is written in. :func:`lower_enums` runs once over the root
    document, so a tree that crosses a file boundary before that pass (a
    template-library body reaching an importer, §9.7.5) is lowered here, at the
    edge, while its own file's block is still at hand.

    An op with an argument spelled by a name in ``open_names`` is left in place:
    a template parameter substitutes position-blind (§9.6.3 constraint 5), so
    the call site decides what it spells and the op resolves there. An op whose
    arguments are not two strings is left for :func:`lower_enums`.

    Raises :class:`EnumLoweringError` (``enum_duplicate_value`` /
    ``unknown_enum`` / ``unknown_enum_symbol``). ``target`` is not modified.
    """
    enums = document.get("enums") if isinstance(document, dict) else None
    if not isinstance(enums, dict):
        enums = {}
    check_enum_block(enums)

    def walk(node: Any) -> Any:
        if isinstance(node, list):
            return [walk(v) for v in node]
        if not isinstance(node, dict):
            return node
        if node.get("op") == "enum":
            args = node.get("args")
            if (
                not isinstance(args, list)
                or len(args) != 2
                or not all(isinstance(a, str) for a in args)
                or any(a in open_names for a in args)
            ):
                return node
            enum_name, symbol = args
            mapping = enums.get(enum_name)
            if not isinstance(mapping, dict):
                raise EnumLoweringError(
                    UNKNOWN_ENUM,
                    f"enum `{enum_name}` is not declared in the file's `enums` block",
                )
            if symbol not in mapping:
                raise EnumLoweringError(
                    UNKNOWN_ENUM_SYMBOL,
                    f"symbol `{symbol}` is not declared under enum `{enum_name}`",
                )
            return {"op": "const", "args": [], "value": mapping[symbol]}
        return {k: walk(v) for k, v in node.items()}

    return walk(target)


def lower_mounted_document_enums(document: dict[str, Any]) -> dict[str, Any]:
    """Return raw ``document``, mounted at a §4.7 edge, with its ``enum`` ops
    lowered against its own ``enums`` block (esm-spec §9.3).

    Called once the document has resolved in its own scope and before its
    component is spliced into the mounting document, whose block is a different
    one. ``enums`` do not merge across a mount, so this is the only block those
    ops can name.

    A template declaration's body is lowered with that template's ``params``
    left open, as at the import edge: an op spelled with a parameter resolves at
    the call site. Everything else is lowered with no open names. Raises
    :class:`EnumLoweringError`. ``document`` is not modified.
    """

    def lower_templates(templates: dict[str, Any]) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for name, decl in templates.items():
            if isinstance(decl, dict) and "body" in decl:
                params = decl.get("params")
                open_names = (
                    frozenset(p for p in params if isinstance(p, str))
                    if isinstance(params, list)
                    else frozenset()
                )
                decl = {**decl, "body": lower_enum_ops_for_file(document, decl["body"], open_names)}
            out[name] = decl
        return out

    def walk(node: Any) -> Any:
        if isinstance(node, list):
            return [walk(v) for v in node]
        if not isinstance(node, dict):
            return node
        if node.get("op") == "enum":
            return lower_enum_ops_for_file(document, node)
        return {
            k: lower_templates(v)
            if k == "expression_templates" and isinstance(v, dict)
            else walk(v)
            for k, v in node.items()
        }

    return walk(document)


def lower_enums(file: EsmFile) -> EsmFile:
    """Return ``file`` with every ``enum`` op replaced by a ``const`` integer
    per the file's ``enums`` block (esm-spec §9.3).

    **Pure**: ``file`` is not modified. The canonical name carries the pure
    form in every binding (API_SPEC.md §8 item 15); the in-place twin is
    :func:`lower_enums_mut` (Julia spells it ``lower_enums!``). Node identity
    is preserved wherever nothing lowered, so a document with no ``enum`` ops
    comes back as the very same object.

    After this pass runs, no ``enum``-op nodes remain in the returned document.

    Validation (esm-spec §9.3):

    - An ``enum`` op naming an undeclared enum raises
      :class:`EnumLoweringError` with ``code == "unknown_enum"``.
    - An ``enum`` op naming a symbol not declared under that enum raises
      :class:`EnumLoweringError` with ``code == "unknown_enum_symbol"``.

    :class:`EnumLoweringError` subclasses :class:`ValueError`, so existing
    ``except ValueError`` callers continue to catch these.
    """
    enums: dict[str, dict[str, int]] = file.enums or {}
    # One identity memo for the whole file: lowering is a pure function of the
    # node given `enums`, and template expansion splices subtrees by reference
    # (a shared DAG), so a subtree aliased under many parents must be lowered
    # once — not once per path (exponential in the template-nesting depth).
    # Entries are (node, result) so the keyed node stays alive alongside the
    # memo and its id cannot be recycled.
    memo: dict[int, tuple[Any, Any]] = {}
    models = {k: _lower_model(m, enums, memo) for k, m in file.models.items()}
    systems = {
        k: _lower_reaction_system(rs, enums, memo) for k, rs in file.reaction_systems.items()
    }
    unchanged = all(models[k] is v for k, v in file.models.items()) and all(
        systems[k] is v for k, v in file.reaction_systems.items()
    )
    if unchanged:
        return file
    return replace(file, models=models, reaction_systems=systems)


def lower_enums_mut(file: EsmFile) -> EsmFile:
    """In-place twin of :func:`lower_enums`: lower every ``enum`` op in ``file``
    itself, and return it (API_SPEC.md §8 item 15).

    The `_mut` suffix is the cross-binding spelling for a mutating variant whose
    canonical name is pure — Julia writes the same thing as ``lower_enums!``.
    Use this when a caller elsewhere already holds a reference to ``file`` (or
    to one of its models) and must see the lowered trees; the load path in
    :mod:`earthsci_ast.parse` is exactly that case.

    Raises the same :class:`EnumLoweringError` as :func:`lower_enums`, and
    raises it BEFORE grafting anything, so a document that fails to lower is
    left untouched rather than half-lowered.
    """
    lowered = lower_enums(file)
    if lowered is not file:
        _graft_file(file, lowered)
    return file


# ---------------------------------------------------------------------------
# Grafting: copy a purely-lowered result back into the original objects.
#
# `lower_enums` rebuilds containers rather than assigning into them, so the
# mutating twin needs to write the new contents back into the ORIGINAL model /
# reaction-system objects -- not just the top-level EsmFile -- or a caller
# holding a nested Model would keep seeing un-lowered trees.
# ---------------------------------------------------------------------------


def _graft_file(dst: EsmFile, src: EsmFile) -> None:
    for name, model in src.models.items():
        if model is not dst.models[name]:
            _graft_model(dst.models[name], model)
    for name, rs in src.reaction_systems.items():
        if rs is not dst.reaction_systems[name]:
            _graft_reaction_system(dst.reaction_systems[name], rs)


def _graft_model(dst: Model, src: Model) -> None:
    for vname, var in src.variables.items():
        if var is not dst.variables[vname]:
            dst.variables[vname] = var
    dst.equations[:] = src.equations
    dst.initialization_equations[:] = src.initialization_equations
    for sname, sub in src.subsystems.items():
        if sub is not dst.subsystems[sname]:
            _graft_model(dst.subsystems[sname], sub)


def _graft_reaction_system(dst: ReactionSystem, src: ReactionSystem) -> None:
    for d, sreac in zip(dst.reactions, src.reactions):
        if sreac is not d:
            d.rate_constant = sreac.rate_constant
    for sname, sub in src.subsystems.items():
        if sub is not dst.subsystems[sname]:
            _graft_reaction_system(dst.subsystems[sname], sub)


def _lower_parameter_update(update: Any, enums, memo):
    """Lower `enum` nodes inside a parameter's update rules (esm-spec §5.4): the
    `condition`/`crossing` trigger, the `expression` value form, and the `from`
    binding's `unit_conversion`. Returns ``update`` unchanged when nothing
    lowered, so an untouched model keeps object identity."""
    if update is None:
        return update
    if isinstance(update, list):
        lowered = [_lower_parameter_update(rule, enums, memo) for rule in update]
        return update if all(a is b for a, b in zip(lowered, update)) else lowered
    changes = {}
    if update.when is not None:
        new_when = _lower_expr(update.when, enums, memo)
        if new_when is not update.when:
            changes["when"] = new_when
    if update.expression is not None:
        new_expr = _lower_expr(update.expression, enums, memo)
        if new_expr is not update.expression:
            changes["expression"] = new_expr
    binding = update.from_source
    if binding is not None and binding.unit_conversion is not None:
        new_conv = _lower_expr(binding.unit_conversion, enums, memo)
        if new_conv is not binding.unit_conversion:
            changes["from_source"] = replace(binding, unit_conversion=new_conv)
    return replace(update, **changes) if changes else update


def _lower_equations(
    eqs: list[Equation],
    enums: dict[str, dict[str, int]],
    memo: dict[int, tuple[Any, Any]] | None,
) -> list[Equation]:
    """Lower an equation list, returning the SAME list object when nothing in it
    changed so an untouched model keeps object identity."""
    out: list[Equation] = []
    changed = False
    for eq in eqs:
        lhs = _lower_expr(eq.lhs, enums, memo)
        rhs = _lower_expr(eq.rhs, enums, memo)
        if lhs is eq.lhs and rhs is eq.rhs:
            out.append(eq)
        else:
            out.append(Equation(lhs=lhs, rhs=rhs, _comment=eq._comment))
            changed = True
    return out if changed else eqs


def _lower_model(
    model: Model,
    enums: dict[str, dict[str, int]],
    memo: dict[int, tuple[Any, Any]] | None = None,
) -> Model:
    """Pure: return the lowered model, or ``model`` itself when nothing
    lowered."""
    # A variable carries no `expression` from 1.0.0; the enum-lowering that used
    # to walk it is subsumed by the equation walk below, since an observed
    # unknown's definition IS an equation. The remaining variable-level
    # expression positions are a parameter's `update` (§5.4), lowered here.
    variables = model.variables
    for vname, var in model.variables.items():
        new_update = _lower_parameter_update(var.update, enums, memo)
        if new_update is not var.update:
            if variables is model.variables:
                variables = dict(model.variables)
            variables[vname] = replace(var, update=new_update)

    equations = _lower_equations(model.equations, enums, memo)
    init_equations = _lower_equations(model.initialization_equations, enums, memo)

    subsystems = model.subsystems
    for sname, sub in model.subsystems.items():
        new_sub = _lower_model(sub, enums, memo)
        if new_sub is not sub:
            if subsystems is model.subsystems:
                subsystems = dict(model.subsystems)
            subsystems[sname] = new_sub

    if (
        variables is model.variables
        and equations is model.equations
        and init_equations is model.initialization_equations
        and subsystems is model.subsystems
    ):
        return model
    return replace(
        model,
        variables=variables,
        equations=equations,
        initialization_equations=init_equations,
        subsystems=subsystems,
    )


def _lower_reaction_system(
    rs: ReactionSystem,
    enums: dict[str, dict[str, int]],
    memo: dict[int, tuple[Any, Any]] | None = None,
) -> ReactionSystem:
    """Pure: return the lowered reaction system, or ``rs`` itself when nothing
    lowered."""
    reactions = rs.reactions
    for i, r in enumerate(rs.reactions):
        if r.rate_constant is None:
            continue
        new_rate = _lower_expr(r.rate_constant, enums, memo)
        if new_rate is not r.rate_constant:
            if reactions is rs.reactions:
                reactions = list(rs.reactions)
            reactions[i] = replace(r, rate_constant=new_rate)

    subsystems = rs.subsystems
    for sname, sub in rs.subsystems.items():
        new_sub = _lower_reaction_system(sub, enums, memo)
        if new_sub is not sub:
            if subsystems is rs.subsystems:
                subsystems = dict(rs.subsystems)
            subsystems[sname] = new_sub

    if reactions is rs.reactions and subsystems is rs.subsystems:
        return rs
    return replace(rs, reactions=reactions, subsystems=subsystems)


def _lower_expr(
    node: Any,
    enums: dict[str, dict[str, int]],
    memo: dict[int, tuple[Any, Any]] | None = None,
) -> Any:
    if not isinstance(node, ExprNode):
        return node
    if memo is not None:
        hit = memo.get(id(node))
        if hit is not None:
            return hit[1]
    if node.op == "enum":
        if len(node.args) != 2 or not all(isinstance(a, str) for a in node.args):
            raise ValueError(
                f"`enum` op expects exactly 2 string args (enum_name, symbol_name); "
                f"got {len(node.args)}: {node.args}"
            )
        enum_name, symbol_name = node.args[0], node.args[1]
        if enum_name not in enums:
            raise EnumLoweringError(
                UNKNOWN_ENUM,
                f"enum `{enum_name}` is not declared in the file's `enums` block",
            )
        mapping = enums[enum_name]
        if symbol_name not in mapping:
            raise EnumLoweringError(
                UNKNOWN_ENUM_SYMBOL,
                f"symbol `{symbol_name}` is not declared under enum `{enum_name}`",
            )
        lowered = ExprNode(op="const", args=[], value=mapping[symbol_name])
        if memo is not None:
            memo[id(node)] = (node, lowered)
        return lowered
    # Recurse through the FULL canonical child set (args, lower, upper, expr,
    # filter, key, values) via expr_walk.map_children so this cannot drift from
    # the canonical child slots and skip an `enum` hidden in an integral bound,
    # faq filter, or distinct key.
    # Rebuild only when a child actually changed, preserving node identity.
    rebuilt = map_children(node, lambda c: _lower_expr(c, enums, memo))
    result = rebuilt
    if all(a is b for a, b in zip(iter_children(node), iter_children(rebuilt))):
        result = node
    if memo is not None:
        memo[id(node)] = (node, result)
    return result
