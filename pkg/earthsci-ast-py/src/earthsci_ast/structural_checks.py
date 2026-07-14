"""
Layer 1 of 2: raw-dict structural validation (post-schema, pre-parse).

This module hosts the raw-dict structural-validation suite that
``earthsci_ast.parse.load`` runs after JSON-schema validation and template
resolution but before JSON→dataclass parsing: operator arity, symbol tables
and scoped-reference resolution, unit/dimension consistency, metadata formats,
data-loader/reaction-system/event checks, and the registered-function call
audit — everything invoked from :func:`_validate_structural`.

Layer boundary (what lives where):

* THIS module operates on the raw ``dict`` decoded from JSON, BEFORE the
  document is parsed into :mod:`earthsci_ast.esm_types` dataclasses. It is a
  load-time gate: any finding aborts ``load()`` by raising
  :class:`StructuralValidationError` (a :class:`SchemaValidationError`
  subclass) whose human-readable ``str()`` is a collapsed blob of all
  findings and whose ``.findings`` list carries the same findings as
  machine-readable ``(code, message)`` records. Rules that need only the raw
  shape of the document (arity, reference resolution, metadata/temporal
  string formats, the registered-function-call audit) belong here.

* :mod:`earthsci_ast.validation` is Layer 2: dataclass-level *semantic*
  validation. It runs later, on a parsed :class:`~earthsci_ast.esm_types.EsmFile`,
  is invoked explicitly via ``validation.validate()`` (not by ``load()``),
  collects structured :class:`~earthsci_ast.error_handling.ErrorCode` records
  into a ``ValidationResult`` instead of raising, and owns the semantic rules
  (equation-unknown balance, reaction consistency, event consistency, unit
  warnings). New semantic rules should go THERE, in the coded channel — not
  here. See that module's docstring for the reciprocal note. The two layers
  historically grew overlapping copies of a few rules; where a rule is owned
  by ``validation.py`` the local twin here is annotated with a cross-reference.

Split out of ``parse.py`` so raw-dict validation and dataclass parsing stay
separate concerns. ``parse`` imports from this module at module top; this
module only imports from ``parse`` lazily inside :func:`_validate_structural`
and :func:`_structural_validation_error_cls` (for
:class:`~earthsci_ast.parse.SchemaValidationError`), keeping the
module-import graph acyclic.
"""
from __future__ import annotations

import re
from typing import Any

# StructuralValidationError is built lazily (and cached) so that its base class,
# ``earthsci_ast.parse.SchemaValidationError``, can be imported without
# reintroducing the parse<->structural_checks import cycle this module's
# docstring documents. It subclasses SchemaValidationError so existing
# ``except SchemaValidationError`` / ``pytest.raises(SchemaValidationError)``
# callers keep catching structural failures unchanged, while carrying the
# findings additionally as machine-readable ``(code, message)`` records on
# ``.findings`` — the counterpart to validation.py's structured ErrorCode
# records. Exposed as the module attribute ``StructuralValidationError`` via
# the PEP 562 ``__getattr__`` below.
_STRUCTURAL_VALIDATION_ERROR_CLS: type | None = None


def _structural_validation_error_cls() -> type:
    """Return the cached :class:`StructuralValidationError` class, building it
    (and lazily importing its ``SchemaValidationError`` base) on first use."""
    global _STRUCTURAL_VALIDATION_ERROR_CLS
    if _STRUCTURAL_VALIDATION_ERROR_CLS is None:
        from .parse import SchemaValidationError

        class StructuralValidationError(SchemaValidationError):
            """Raised by :func:`_validate_structural` when raw-dict structural
            checks find problems.

            ``str(err)`` is the same collapsed human-readable blob the raw
            structural pass has always produced (so message-matching callers are
            unchanged); ``err.findings`` is the same set of problems as a list of
            ``(code, message)`` tuples, giving the stable diagnostic codes a
            machine-readable home alongside the prose blob.

            ``err.records`` carries the same findings with a JSON-Pointer
            ``path`` and a ``details`` payload — the shape
            ``tests/invalid/expected_errors.json`` pins for every binding.
            ``validation.validate()`` re-emits these as structured
            ``ValidationError``s so a caller sees ``code`` + ``path`` instead of
            a single opaque prose blob."""

            def __init__(
                self,
                message: str,
                findings: list[tuple[str, str]] | None = None,
                records: list[dict] | None = None,
            ):
                super().__init__(message)
                self.findings: list[tuple[str, str]] = list(findings or [])
                self.records: list[dict] = list(records or [])

        _STRUCTURAL_VALIDATION_ERROR_CLS = StructuralValidationError
    return _STRUCTURAL_VALIDATION_ERROR_CLS


def __getattr__(name: str):  # PEP 562: lazy module-level attribute.
    if name == "StructuralValidationError":
        return _structural_validation_error_cls()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


# The ONE unit registry. It is built in ``earthsci_ast.units``, which layers the
# shared ESM unit contract (docs/content/units-standard.md) on top of pint:
# ppb/ppt and the *v aliases, the dimensionless count nouns
# (molec/individuals/vehicles/units/count), Dobson/DU, Ohm, Torr — and, crucially,
# the OVERRIDES where a vanilla pint registry silently disagrees with the
# contract (`units` parses as MICRO-NIT, a luminance; `molec` as [substance]).
#
# This module used to build its own bare ``pint.UnitRegistry()``, which knew none
# of that: `ppb`, `ppbv`, `individuals`, `vehicles`, `Dobson`, `Torr` were simply
# UNDEFINED here, and `molec`/`units` carried the wrong dimension. Every unit
# check below therefore ran against a registry that disagreed with the one
# ``units.py`` uses — tolerable while the findings were advisory, a
# false-rejection factory now that they are hard errors.
def _get_unit_registry():
    """Return the shared ESM pint ``UnitRegistry`` (see ``earthsci_ast.units``)."""
    from .units import PINT_AVAILABLE, ureg

    if not PINT_AVAILABLE:
        raise ImportError("pint library is required for unit validation")
    return ureg


def _unit_dimensionality(unit: str | None):
    """Dimensionality of a declared unit string, via the shared ESM registry.

    Raises ``UnparseableUnitError`` (a ``ValueError``) when the string does not
    denote a unit, and ``ImportError`` when pint is absent.
    """
    from .units import unit_dimensionality

    return unit_dimensionality(unit)


# Exception types that mean "cannot verify these units", never "genuinely
# inconsistent": either pint is unavailable (``ImportError``) or the string does
# not denote a unit (``UnparseableUnitError``). An unparseable unit is now
# reported ONCE, as a hard error, by :func:`_check_unparseable_units`; the
# helpers below therefore keep treating it as unverifiable so that a single
# malformed unit string produces a single finding instead of an avalanche of
# derived mismatches. Narrowing these ``except`` clauses to this tuple (instead
# of a blanket ``except Exception``) lets a genuine, unexpected bug propagate.
_PINT_UNVERIFIABLE_ERRORS = None


def _pint_unverifiable_errors():
    """Return the tuple of exception types treated as "unit unparseable / pint
    unavailable" by the unit-consistency helpers (see the note above)."""
    global _PINT_UNVERIFIABLE_ERRORS
    if _PINT_UNVERIFIABLE_ERRORS is None:
        try:
            import pint

            from .units import UnparseableUnitError

            _PINT_UNVERIFIABLE_ERRORS = (
                ImportError,
                UnparseableUnitError,
                pint.errors.PintError,
            )
        except ImportError:
            _PINT_UNVERIFIABLE_ERRORS = (ImportError,)
    return _PINT_UNVERIFIABLE_ERRORS


_OPERATOR_ARITY = {
    "+": (2, None),
    "-": (1, None),
    "*": (2, None),
    "/": (2, 2),
    # `grad`/`div` accept an optional second operand: a per-field boundary
    # (Dirichlet inflow) metavariable bound by a two-arg `grad(f, inflow, dim)`
    # expression-template `match` (esm-spec §9.6; the schema does not constrain
    # grad/div arity — the second arg supplies that field's own loaded BC).
    "^": (2, 2),
    "D": (1, 1),
    "ic": (1, 1),
    "grad": (1, 2),
    "div": (1, 2),
    "laplacian": (1, 1),
    "exp": (1, 1),
    "log": (1, 1),
    "log10": (1, 1),
    "sqrt": (1, 1),
    "abs": (1, 1),
    "sin": (1, 1),
    "cos": (1, 1),
    "tan": (1, 1),
    "asin": (1, 1),
    "acos": (1, 1),
    "atan": (1, 1),
    "atan2": (2, 2),
    "sinh": (1, 1),
    "cosh": (1, 1),
    "tanh": (1, 1),
    "asinh": (1, 1),
    "acosh": (1, 1),
    "atanh": (1, 1),
    "min": (2, None),
    "max": (2, None),
    "floor": (1, 1),
    "ceil": (1, 1),
    "ifelse": (3, 3),
    ">": (2, 2),
    "<": (2, 2),
    ">=": (2, 2),
    "<=": (2, 2),
    "==": (2, 2),
    "!=": (2, 2),
    "and": (2, None),
    "or": (2, None),
    "not": (1, 1),
    "Pre": (1, 1),
    "sign": (1, 1),
    # Closed function registry (esm-spec §9.2 / §9.3). `fn` arity is checked
    # by the dispatcher (1 for datetime.*, 2 for interp.searchsorted).
    "enum": (2, 2),
    "const": (0, 0),
}

# Built-in symbols always available in expressions
_BUILTIN_SYMBOLS = frozenset(
    {
        "t",
        "pi",
        "e",
        "true",
        "false",
        "x",
        "y",
        "z",
        "lon",
        "lat",
        "lev",
        "longitude",
        "latitude",
        "level",
    }
)

# Pint-compatible unit aliases for normalizing
_UNIT_ALIASES = {
    "1": "dimensionless",
    "": "dimensionless",
    "dimensionless": "dimensionless",
}


# Nested single-expression child slots of a raw-dict ExprNode, in the canonical
# order used by ``expr_walk._SINGLE_CHILD_FIELDS`` (the one true child-field
# set). ``args``/``values`` are expression LISTS and ``axes`` is a
# ``{name: expr}`` MAP (the dataclass ``table_axes``; its raw JSON key is
# ``axes``), so they are walked separately below.
_EXPR_STRING_CHILD_FIELDS = ("lower", "upper", "expr", "filter", "key")

# Fields that BIND index/integration symbols for a node's body (esm-spec §5;
# expr_walk.py's module docstring). A symbol introduced here is a bound
# variable of the aggregate/makearray/integral, not a reference to a declared
# model symbol, so reference checks must not flag it as undefined.
def _bare_string_leaves(expr) -> set[str]:
    """Collect every bare-string leaf reachable from ``expr`` across the full
    child-field set (used to pull loop symbols out of index-coordinate
    sub-expressions like ``i + 1``)."""
    out: set[str] = set()
    if isinstance(expr, str):
        out.add(expr)
    elif isinstance(expr, dict):
        for arg in expr.get("args", []) or []:
            out |= _bare_string_leaves(arg)
        for field_name in _EXPR_STRING_CHILD_FIELDS:
            out |= _bare_string_leaves(expr.get(field_name))
        for val in expr.get("values", []) or []:
            out |= _bare_string_leaves(val)
        axes = expr.get("axes")
        if isinstance(axes, dict):
            for child in axes.values():
                out |= _bare_string_leaves(child)
        bindings = expr.get("bindings")
        if isinstance(bindings, dict):
            for child in bindings.values():
                out |= _bare_string_leaves(child)
    return out


def _expression_bound_symbols(expr) -> set[str]:
    """Collect every index/integration symbol BOUND anywhere in ``expr``.

    Explicit binders live in ``ranges`` (dict keys), ``output_idx`` (string
    entries), ``wrt`` (derivative variable) and ``var`` (integral variable).
    A ``makearray`` stencil lowered from a grad/div template, however, carries
    NO explicit binder field once round-tripped — its loop symbols (``i``/``j``)
    appear only as the COORDINATE arguments of the ``index`` ops in its region
    bodies (``index(field, i + 1, j)``). Those coordinate symbols are therefore
    also treated as bound. Used by :func:`_check_variable_references` to avoid
    flagging a contracted/loop index symbol as an undefined variable once the
    walker descends into aggregate/makearray bodies."""
    bound: set[str] = set()
    if not isinstance(expr, dict):
        return bound
    ranges = expr.get("ranges")
    if isinstance(ranges, dict):
        bound.update(ranges.keys())
    output_idx = expr.get("output_idx")
    if isinstance(output_idx, list):
        bound.update(s for s in output_idx if isinstance(s, str))
    for binder_field in ("wrt", "var"):
        sym = expr.get(binder_field)
        if isinstance(sym, str):
            bound.add(sym)
    if expr.get("op") == "index":
        # Coordinate positions (everything after the indexed field) are index
        # expressions over loop symbols, never top-level declared references.
        for coord in (expr.get("args", []) or [])[1:]:
            bound |= _bare_string_leaves(coord)
    for field_name in _EXPR_STRING_CHILD_FIELDS:
        bound |= _expression_bound_symbols(expr.get(field_name))
    for arg in expr.get("args", []) or []:
        bound |= _expression_bound_symbols(arg)
    for val in expr.get("values", []) or []:
        bound |= _expression_bound_symbols(val)
    axes = expr.get("axes")
    if isinstance(axes, dict):
        for child in axes.values():
            bound |= _expression_bound_symbols(child)
    # `apply_expression_template` bindings values are free-variable TARGETS
    # (esm-spec §10.10.2): bound symbols hidden in a binding value must stay
    # visible so the reference walker below can filter them consistently.
    bindings = expr.get("bindings")
    if isinstance(bindings, dict):
        for child in bindings.values():
            bound |= _expression_bound_symbols(child)
    return bound


def _walk_expression_strings(expr) -> list[str]:
    """Recursively collect string leaves from EVERY child-expression slot of an
    op-expression node, not just ``args``.

    Earlier this descended only ``args`` and silently skipped the nested
    single-expression fields (``expr``/``filter``/``key``/``lower``/``upper``),
    the ``values`` list, and the ``axes`` map — so references hidden in
    aggregate bodies, ``filter`` predicates, integral bounds, Skolem ``key``
    terms, ``makearray`` value lists, and ``table_lookup`` axis expressions were
    invisible to the reference checks. It now visits the full child-field set
    the sibling walkers (and :mod:`earthsci_ast.expr_walk`) use. Bound index
    symbols surfaced from aggregate bodies are filtered by the caller via
    :func:`_expression_bound_symbols`."""
    result: list[str] = []
    if not (isinstance(expr, dict) and "op" in expr):
        return result

    def descend(child) -> None:
        if isinstance(child, str):
            result.append(child)
        elif isinstance(child, dict):
            result.extend(_walk_expression_strings(child))

    for arg in expr.get("args", []) or []:
        descend(arg)
    for field_name in _EXPR_STRING_CHILD_FIELDS:
        child = expr.get(field_name)
        if child is not None:
            descend(child)
    for val in expr.get("values", []) or []:
        descend(val)
    axes = expr.get("axes")
    if isinstance(axes, dict):
        for child in axes.values():
            descend(child)
    # `apply_expression_template` bindings values are free-variable targets
    # (esm-spec §10.10.2); an undefined variable hidden in a binding value
    # would otherwise escape the undefined-reference check.
    bindings = expr.get("bindings")
    if isinstance(bindings, dict):
        for child in bindings.values():
            descend(child)
    return result


def _check_expression_arity(expr, errors: list[str], path: str) -> None:
    """Walk an expression tree and check operator arity."""
    if isinstance(expr, dict) and "op" in expr and "args" in expr:
        op = expr["op"]
        args = expr["args"]
        if op in _OPERATOR_ARITY:
            min_args, max_args = _OPERATOR_ARITY[op]
            n = len(args)
            if n < min_args:
                errors.append(f"{path}: operator '{op}' requires at least {min_args} args, got {n}")
            elif max_args is not None and n > max_args:
                errors.append(f"{path}: operator '{op}' accepts at most {max_args} args, got {n}")
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
        return _unit_dimensionality(n1) == _unit_dimensionality(n2)
    except _pint_unverifiable_errors():
        # unparseable unit (or pint unavailable): cannot verify, fall back to
        # a plain string comparison rather than blocking. The unparseable string
        # is reported once, on its own, by _check_unparseable_units.
        return n1 == n2


def _build_symbol_tables(data: dict[str, Any]) -> dict[str, Any]:
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

    return {
        "models": models,
        "reaction_systems": reaction_systems,
        "data_loaders": data_loaders,
        "global_symbols": global_symbols,
        "all_systems": set(models.keys()) | set(reaction_systems.keys()) | set(data_loaders.keys()),
        "ref_systems": ref_systems,
    }


def _resolve_scoped_ref(ref: str, tables: dict[str, Any]) -> tuple:
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


def _check_variable_references(
    data: dict[str, Any], tables: dict[str, Any], errors: list[str]
) -> None:
    """
    Check variable references in equations.

    Two flavors of check:
    1. Scoped refs (Model.var): system must exist; for 2-part refs the var must exist
       in the named system.
    2. Bare-string refs in the RHS of D() (derivative) equations: every ref must
       resolve to a symbol declared somewhere in the file. Plain assignment-style
       equations are not checked because they often use coupled-in vars.

    The walker (:func:`_walk_expression_strings`) now descends the full child
    set, so refs hidden in aggregate bodies are visible here. Index/integration
    symbols bound by the equation's own aggregate/makearray/integral nodes are
    collected via :func:`_expression_bound_symbols` and skipped — they are bound
    variables, not references to declared symbols.
    """
    global_symbols = tables["global_symbols"]
    for mname, m in data.get("models", {}).items():
        for i, eq in enumerate(m.get("equations", [])):
            lhs_is_derivative = isinstance(eq.get("lhs"), dict) and eq["lhs"].get("op") == "D"
            bound_symbols = _expression_bound_symbols(eq.get("lhs")) | _expression_bound_symbols(
                eq.get("rhs")
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
                    # A symbol bound by an aggregate/makearray/integral in this
                    # equation (a contracted index like `i`/`j`/`e`, or an
                    # integration variable) is not a declared-symbol reference.
                    if ref in bound_symbols:
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
                        # A 2-part ref whose first component is a SUBSYSTEM of the
                        # current model is subsystem-LOCAL dot-notation, not a
                        # `System.var` reference. A pure-I/O data-loader mounted as
                        # a subsystem (RFC pure-io-data-loaders §4.3) is consumed by
                        # the owning model's own equations this way — `raw.elevation`
                        # for `models.<mname>.subsystems.raw` — and flatten lowers it
                        # to the observed `<mname>.raw.elevation`. Defer it exactly as
                        # the 3+ part subsystem-nested refs are deferred (the
                        # subsystem's variables are resolved at flatten time).
                        if ref.split(".")[0] in (m.get("subsystems") or {}):
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


def _check_coupling_references(
    data: dict[str, Any], tables: dict[str, Any], errors: list[str]
) -> None:
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
            errors.append(f"coupling[{i}]/from: reference '{ref}' to undefined system '{system}'")
        elif status == "no_var":
            errors.append(
                f"coupling[{i}]/from: reference '{ref}' — variable '{var}' not provided by '{system}'"
            )


def _check_circular_references(
    data: dict[str, Any], tables: dict[str, Any], errors: list[str]
) -> None:
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
    color = dict.fromkeys(deps, WHITE)

    def dfs(node, path):
        color[node] = GRAY
        for nxt in deps.get(node, ()):
            if color.get(nxt) == GRAY:
                cycle_start = path.index(nxt) if nxt in path else 0
                cycle = path[cycle_start:] + [nxt]
                errors.append(f"circular reference (cycle) detected: {' -> '.join(cycle)}")
                return True
            if color.get(nxt) == WHITE:
                if dfs(nxt, path + [nxt]):
                    return True
        color[node] = BLACK
        return False

    for n in deps:
        if color[n] == WHITE:
            if dfs(n, [n]):
                break


def _check_data_loader_variables(data: dict[str, Any], errors: list[str]) -> None:
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


def _check_discrete_parameters(data: dict[str, Any], errors: list[str]) -> None:
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


_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?$")
_URL_RE = re.compile(r"^https?://[^\s/$.?#].[^\s]*$")
_DOI_RE = re.compile(r"^10\.\d{4,9}/[^\s]+$")
_DURATION_RE = re.compile(
    r"^P(?:\d+Y)?(?:\d+M)?(?:\d+W)?(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$"
)


def _check_metadata_formats(data: dict[str, Any], errors: list[str]) -> None:
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


def _check_temporal_resolution(data: dict[str, Any], errors: list[str]) -> None:
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


def _collect_var_units(tables: dict[str, Any]) -> dict[str, str]:
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


def _is_derivative_compatible(
    lhs_var_units: str, rhs_units: str, wrt_units: str | None = None
) -> bool:
    """Can ``rhs_units`` be the derivative of ``lhs_var_units`` w.r.t. the
    independent variable?

    When the independent variable IS declared (``wrt_units``), the answer is
    exact: ``dim(rhs) == dim(state)/dim(wrt)``.

    When it is NOT declared — the ordinary case, since ``t`` is rarely given
    units — its dimension is UNKNOWN, and assuming seconds is a fabrication.
    This function used to do exactly that (``(rhs * second) / lhs`` must be
    dimensionless), which rejects a perfectly ordinary acceleration equation
    (``x`` in ``m``, RHS in ``m/s^2``: the ratio is ``s^2``, a pure power of
    time, so *some* time unit reconciles them — and the fabricated one-second
    denominator says otherwise). Under a hard-error policy that is a false
    rejection.

    The defensible test is the one Go uses (``derivativeTimeMismatch``): the
    time exponent is free, but the NON-time dimensions cannot move. If
    ``dim(state)/dim(rhs)`` has any nonzero exponent outside ``[time]``, no
    choice of time unit reconciles the two sides and the equation is provably
    wrong. That still rejects what the invalid corpus pins (an ``m`` state
    assigned a ``kg`` expression) while accepting ``D(x) = -x`` and the
    acceleration case above.
    """
    n_lhs = _normalize_unit(lhs_var_units)
    n_rhs = _normalize_unit(rhs_units)
    if n_lhs == n_rhs == "dimensionless":
        return True
    try:
        lhs_dim = _unit_dimensionality(n_lhs)
        rhs_dim = _unit_dimensionality(n_rhs)
        if wrt_units:
            return rhs_dim == lhs_dim / _unit_dimensionality(_normalize_unit(wrt_units))
        # Undeclared independent variable: only the time exponent is free.
        ratio = lhs_dim / rhs_dim
        # A pint dimensionality container drops zero exponents, so any surviving
        # key other than [time] is a dimension no time unit can cancel.
        return set(ratio.keys()) <= {"[time]"}
    except _pint_unverifiable_errors():
        # unparseable unit (or pint unavailable): cannot verify, do not block.
        return True


def _is_dimensionless_unit(unit: str | None) -> bool:
    """Return True if a unit string represents a dimensionless quantity."""
    if unit is None:
        return True
    normalized = _normalize_unit(unit)
    if normalized in ("dimensionless", "1", ""):
        return True
    try:
        return not _unit_dimensionality(normalized)
    except _pint_unverifiable_errors():
        # unparseable unit (or pint unavailable): cannot verify, treat as
        # not-dimensionless (do not assert dimensionlessness we can't confirm).
        # The unparseable string is reported separately by
        # _check_unparseable_units, so nothing is lost by staying silent here.
        return False


def _is_angle_unit(unit: str | None) -> bool:
    """Return True if a unit string denotes an ANGLE (the `rad` axis).

    `rad` is one of the eight canonical dimension axes (esm-spec §4.8.1), so
    `rad`/`deg` are NOT dimensionless — which is precisely why a circular
    function's argument needs its own predicate rather than reusing
    :func:`_is_dimensionless_unit`.
    """
    if unit is None:
        return False
    try:
        return _unit_dimensionality(_normalize_unit(unit)) == _unit_dimensionality("rad")
    except _pint_unverifiable_errors():
        return False


def _walk_expression_for_exponent_checks(
    expr: Any,
    var_units: dict[str, str],
    node_path: str,
    report_path: str,
    variable: str | None,
    errors: list,
) -> None:
    """Walk an expression tree and flag any '^' whose exponent has dimensions.

    ``node_path`` locates the visited node (used only for recursion bookkeeping);
    ``report_path`` is the JSON Pointer the finding is REPORTED at — the owning
    variable or equation, which is what the shared corpus pins.
    """
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
                    (
                        report_path,
                        f"Exponent must be dimensionless, got '{exp_units}'"
                        + (f" for base with units '{base_units}'" if base_units else ""),
                        {
                            "operation": "exponentiation",
                            "base_units": base_units,
                            "exponent_units": exp_units,
                            **({"variable": variable} if variable else {}),
                        },
                    )
                )
    for i, arg in enumerate(args):
        _walk_expression_for_exponent_checks(
            arg, var_units, f"{node_path}/args[{i}]", report_path, variable, errors
        )
    # Also walk arrayop sub-expressions that live outside args.
    if "expr" in expr:
        _walk_expression_for_exponent_checks(
            expr["expr"], var_units, f"{node_path}/expr", report_path, variable, errors
        )


def _check_default_units_consistency(data: dict[str, Any], errors: list[str]) -> None:
    """
    Flag variables whose `default_units` disagrees with the declared `units`.

    Emits `unit_inconsistency` when the two unit strings resolve to different
    pint units — covering both dimensionally incompatible cases (e.g., K vs kg)
    and same-dimension mismatches (e.g., K vs degC). Absent default_units is a
    no-op: a default value is presumed to share the declared units.
    """
    try:
        _get_unit_registry()
        from .units import parse_unit
    except ImportError:
        # pint not installed: cannot verify units, do not block.
        return

    def units_match(declared: str, provided: str) -> bool:
        try:
            return parse_unit(_normalize_unit(declared)) == parse_unit(_normalize_unit(provided))
        except _pint_unverifiable_errors():
            # unparseable unit: cannot verify, fall back to a string compare on
            # the normalized form rather than blocking.
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


def _check_conversion_factor_consistency(data: dict[str, Any], errors: list[str]) -> None:
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
        ureg = _get_unit_registry()
    except ImportError:
        # pint not installed: cannot verify units, do not block.
        return

    from .units import has_affine_unit

    def linear_factor(from_unit: str, to_unit: str):
        # An affine conversion (degC -> K) has no single multiplicative factor.
        # The ESM registry does not model the offset at all (esm-spec §4.8.1:
        # degC carries the Kelvin dimension and its scale, never its zero
        # point), so probing `Quantity(0, degC).to(K)` now returns 0.0 and can
        # no longer detect affineness on its own — the unit names must be
        # checked directly, or a `<factor> * T_degC` expression assigned to a
        # kelvin variable would be "checked" against a fabricated factor of 1.
        if has_affine_unit(from_unit) or has_affine_unit(to_unit):
            return None
        try:
            q0 = ureg.Quantity(0.0, from_unit).to(to_unit).magnitude
            q1 = ureg.Quantity(1.0, from_unit).to(to_unit).magnitude
        except _pint_unverifiable_errors():
            # unparseable or inconvertible unit: cannot verify, skip.
            return None
        if abs(q0) > 1e-12:
            return None  # affine
        return q1

    for mname, m in data.get("models", {}).items():
        var_units_map = {vname: vdef.get("units") for vname, vdef in m.get("variables", {}).items()}
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
                if _unit_dimensionality(n_src) != _unit_dimensionality(n_lhs):
                    continue  # dimensional mismatch — handled by other checks
            except _pint_unverifiable_errors():
                # unparseable unit: cannot verify, skip.
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


def _check_physical_constant_units(data: dict[str, Any], errors: list[str]) -> None:
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


#: Elementary functions whose dimensional ARGUMENT is a hard STRUCTURAL error
#: (it fails the file), keyed op -> (operation label, human-readable subject) so
#: the diagnostic names the operation the way the cross-language corpus does
#: (``tests/invalid/expected_errors.json``: "Logarithm argument must be
#: dimensionless…", "Exponential argument must be dimensionless…").
#:
#: This is the FULL mathematical rule: a transcendental function is defined by a
#: power series, so every term of ``1 + x + x^2/2 + …`` must be addable, which
#: forces ``x`` to be dimensionless. ``sqrt`` is deliberately absent — it halves
#: a dimension rather than requiring none.
#:
#: The set was previously narrowed to ``{ln, exp}`` because the shared corpus
#: contradicted itself — ``tests/invalid/units_invalid_logarithm.esm`` pinned
#: ``ln(mass)`` as INVALID while ``tests/valid/units_dimensional_analysis.esm``
#: pinned ``S = n*R*log(V)`` (V in m^3) as VALID. That contradiction is a defect
#: in the VALID fixture (entropy is ``log(V/V0)``, a ratio) and is being repaired
#: in the corpus, so the checker now states the rule it actually believes.
#: Functions whose ARGUMENT must be strictly dimensionless.
#:
#: The CIRCULAR functions (`sin`/`cos`/`tan`) are deliberately ABSENT: `rad` is a
#: canonical dimension axis (esm-spec §4.8.1), so their argument is an ANGLE, and
#: requiring it to be dimensionless falsely rejects `cos(gamma)` with `gamma` in
#: `rad` — i.e. every line of the shipped `lib/solar.esm`. Their (looser) rule
#: lives in ``units.UnitValidator``, which can actually compute the dimension of
#: a compound argument; this walker only inspects a BARE declared variable, so
#: admitting angles here would be its whole contribution anyway.
#:
#: The INVERSE circular functions (`asin`/`acos`/`atan`) do take a dimensionless
#: argument, so they stay.
_DIMENSIONLESS_ARG_FUNCS: dict[str, tuple[str, str]] = {
    "ln": ("logarithm", "Logarithm"),
    "log": ("logarithm", "Logarithm"),
    "log10": ("logarithm", "Logarithm"),
    "exp": ("exponential", "Exponential"),
    "asin": ("trigonometric", "Inverse trigonometric function"),
    "acos": ("trigonometric", "Inverse trigonometric function"),
    "atan": ("trigonometric", "Inverse trigonometric function"),
    "sinh": ("hyperbolic", "Hyperbolic function"),
    "cosh": ("hyperbolic", "Hyperbolic function"),
    "tanh": ("hyperbolic", "Hyperbolic function"),
    "asinh": ("hyperbolic", "Inverse hyperbolic function"),
    "acosh": ("hyperbolic", "Inverse hyperbolic function"),
    "atanh": ("hyperbolic", "Inverse hyperbolic function"),
}

#: Circular functions: the argument is an ANGLE or dimensionless. Flagged here
#: only when a bare declared variable is provably NEITHER (e.g. `sin(mass)`).
_CIRCULAR_ARG_FUNCS: dict[str, tuple[str, str]] = {
    "sin": ("trigonometric", "Trigonometric function"),
    "cos": ("trigonometric", "Trigonometric function"),
    "tan": ("trigonometric", "Trigonometric function"),
}


#: JSON-Pointer templates for every place a DECLARED unit string can appear,
#: as ``(container-key-path, pointer-prefix)``. Mirrors Go's BuildUnitEnv
#: coverage (model variables + reaction-system species + parameters).
_DECLARED_UNIT_SITES = (
    ("models", "variables"),
    ("reaction_systems", "species"),
    ("reaction_systems", "parameters"),
)


def _check_unparseable_units(data: dict[str, Any], errors: list) -> None:
    """Flag every DECLARED unit string that does not denote a real unit.

    This is a HARD ERROR, not a warning. The severity follows from what the
    finding means: ``"not_a_unit"`` or ``"1/time"`` in a ``units`` field is a
    defect in the FILE — the declaration is simply false — whereas "I cannot
    determine this dimension" (a symbolic exponent, an op with no dimensional
    rule, an undeclared variable) is a statement about the CHECKER and stays a
    warning. Downgrading the former to a warning means a document can name a
    unit that does not exist and still be pronounced valid, which is exactly the
    hole the 2026-07-14 audit found.

    Reported once per declaration site, at the ``units`` pointer. The dimensional
    helpers all treat an unparseable unit as "unverifiable" (see
    ``_pint_unverifiable_errors``), so a single bad string yields exactly one
    finding rather than an avalanche of derived mismatches.
    """
    try:
        from .units import UnparseableUnitError, parse_unit
    except ImportError:
        # pint not installed: cannot verify units, do not block.
        return

    def check(pointer: str, units: Any) -> None:
        if not isinstance(units, str) or not units.strip():
            return
        try:
            parse_unit(units)
        except UnparseableUnitError as exc:
            errors.append(
                (
                    pointer,
                    f"Unit '{units}' is not a known unit: {exc}",
                    {"units": units, "reason": "unparseable_unit"},
                )
            )
        except ImportError:
            return

    for container, member in _DECLARED_UNIT_SITES:
        for sys_name, system in (data.get(container) or {}).items():
            if not isinstance(system, dict):
                continue
            for name, definition in (system.get(member) or {}).items():
                if not isinstance(definition, dict):
                    continue
                base = f"/{container}/{sys_name}/{member}/{name}"
                check(f"{base}/units", definition.get("units"))
                check(f"{base}/default_units", definition.get("default_units"))


def _json_pointer_from_message(msg: str) -> str:
    """Recover a JSON-Pointer path from a legacy ``"a/b/c: message"`` finding.

    The raw structural checks have always prefixed their prose with a
    slash-delimited location (``models/M/variables/v: ...``,
    ``models/M/equations[0]: ...``). This turns that prefix into the
    JSON-Pointer form the shared corpus pins (``/models/M/equations/0``) so
    every legacy check gets a usable path for free. Returns ``"$"`` when the
    message carries no recognizable location.
    """
    head = msg.split(": ", 1)[0].strip()
    if not head or "/" not in head or " " in head:
        return "$"
    # `equations[0]` -> `equations/0`
    head = head.replace("[", "/").replace("]", "")
    return "/" + head.strip("/")


def _walk_expression_for_dimensionless_arg_checks(
    expr: Any,
    var_units: dict[str, str],
    node_path: str,
    report_path: str,
    variable: str | None,
    errors: list,
) -> None:
    """Flag ``log``/``exp``/``sin``/… applied to a DIMENSIONAL argument.

    Conservative by construction: only a bare declared-variable argument is
    checked. A numeric literal is dimension-polymorphic in this format (the
    valid corpus writes Arrhenius as ``exp(-1370 / T)``, where the literal
    carries kelvin), and a compound subtree is left to the dimensional engine
    in ``units.py``, so neither is flagged here.
    """
    if not isinstance(expr, dict):
        return
    op = expr.get("op")
    args = expr.get("args", []) or []
    if op in _DIMENSIONLESS_ARG_FUNCS and len(args) >= 1:
        arg = args[0]
        if isinstance(arg, str):
            arg_units = var_units.get(arg)
            if arg_units is not None and not _is_dimensionless_unit(arg_units):
                operation, subject = _DIMENSIONLESS_ARG_FUNCS[op]
                errors.append(
                    (
                        report_path,
                        f"{subject} argument must be dimensionless, got units '{arg_units}'",
                        {
                            "operation": operation,
                            "function": op,
                            "argument_units": arg_units,
                            **({"variable": variable} if variable else {}),
                        },
                    )
                )
    elif op in _CIRCULAR_ARG_FUNCS and len(args) >= 1:
        # sin/cos/tan accept an ANGLE (`rad`, `deg`) or a dimensionless number;
        # anything else (`sin(mass)`) is a provable inconsistency.
        arg = args[0]
        if isinstance(arg, str):
            arg_units = var_units.get(arg)
            if (
                arg_units is not None
                and not _is_dimensionless_unit(arg_units)
                and not _is_angle_unit(arg_units)
            ):
                operation, subject = _CIRCULAR_ARG_FUNCS[op]
                errors.append(
                    (
                        report_path,
                        f"{subject} argument must be an angle or dimensionless, "
                        f"got units '{arg_units}'",
                        {
                            "operation": operation,
                            "function": op,
                            "argument_units": arg_units,
                            **({"variable": variable} if variable else {}),
                        },
                    )
                )
    for i, arg in enumerate(args):
        _walk_expression_for_dimensionless_arg_checks(
            arg, var_units, f"{node_path}/args[{i}]", report_path, variable, errors
        )
    if "expr" in expr:
        _walk_expression_for_dimensionless_arg_checks(
            expr["expr"], var_units, f"{node_path}/expr", report_path, variable, errors
        )


def _check_unit_consistency(
    data: dict[str, Any], tables: dict[str, Any], errors: list
) -> None:
    """
    Check unit compatibility in equations.

    Conservative: only flags
    1. Equations of the form D(x)/dt = bare_var where bare_var has dimensions
       clearly incompatible with x/time (e.g., velocity-rate set to mass).
    2. Observed variable expressions whose top-level + or - has incompatible operands.
    3. '^' operators whose right operand has non-dimensionless units.
    4. log/exp/trig/hyperbolic applied to a dimensional bare variable.

    Findings are emitted as ``(json_pointer, message, details)`` triples so the
    ``unit_inconsistency`` code lands at the path
    ``tests/invalid/expected_errors.json`` pins for it.

    (A former check for grad/div/laplacian spatial-coordinate units was
    removed with the v0.8.0 geometry rewrite: it read the deleted
    ``Domain.spatial`` / per-model ``domain`` / top-level ``domains`` schema
    constructs and could never fire.)
    """
    var_units = _collect_var_units(tables)

    for mname, m in data.get("models", {}).items():
        # Observed variables: check direct addition/subtraction operand compatibility
        for vname, vdef in m.get("variables", {}).items():
            if vdef.get("type") == "observed" and "expression" in vdef:
                expr = vdef["expression"]
                var_pointer = f"/models/{mname}/variables/{vname}"
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
                                op_name = (
                                    "addition" if expr.get("op") == "+" else "subtraction"
                                )
                                verb = "add" if expr.get("op") == "+" else "subtract"
                                errors.append(
                                    (
                                        var_pointer,
                                        f"Cannot {verb} quantities with different units: "
                                        f"'{ref}' {expr.get('op')} '{u}'",
                                        {
                                            "operation": op_name,
                                            "left_units": ref,
                                            "right_units": u,
                                            "variable": vname,
                                        },
                                    )
                                )
                                break
                # Check '^' exponents anywhere within the observed expression tree
                _walk_expression_for_exponent_checks(
                    expr,
                    var_units,
                    f"models/{mname}/variables/{vname}/expression",
                    var_pointer,
                    vname,
                    errors,
                )
                # log/exp/trig applied to a dimensional argument (esm-spec §4.2:
                # the argument of a transcendental function is dimensionless).
                _walk_expression_for_dimensionless_arg_checks(
                    expr,
                    var_units,
                    f"models/{mname}/variables/{vname}/expression",
                    var_pointer,
                    vname,
                    errors,
                )

        # Check '^' exponents and transcendental arguments in equation sides too.
        for ei, eq in enumerate(m.get("equations", [])):
            eq_pointer = f"/models/{mname}/equations/{ei}"
            for side in ("lhs", "rhs"):
                if side in eq:
                    _walk_expression_for_exponent_checks(
                        eq[side],
                        var_units,
                        f"models/{mname}/equations[{ei}]/{side}",
                        eq_pointer,
                        None,
                        errors,
                    )
                    _walk_expression_for_dimensionless_arg_checks(
                        eq[side],
                        var_units,
                        f"models/{mname}/equations[{ei}]/{side}",
                        eq_pointer,
                        None,
                        errors,
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
            wrt = lhs.get("wrt") or "t"
            # `t` is almost never declared; when it IS, its units make the
            # comparison exact instead of "only the time exponent is free".
            if not _is_derivative_compatible(lhs_var_units, rhs_units, var_units.get(wrt)):
                errors.append(
                    (
                        f"/models/{mname}/equations/{i}",
                        f"Derivative d({inner})/d{wrt} is incompatible with the units of "
                        f"'{rhs}': '{rhs_units}' is not the time derivative of '{lhs_var_units}'",
                        {
                            "derivative_variable": inner,
                            "derivative_variable_units": lhs_var_units,
                            "wrt_variable": wrt,
                            "actual_units": rhs_units,
                            "equation_index": i,
                        },
                    )
                )


def _check_operator_state_coverage(data: dict[str, Any], errors: list[str]) -> None:
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


def _check_reaction_systems(data: dict[str, Any], errors: list[str]) -> None:
    """Validate reaction system rate references (raw-dict, load-time).

    Undeclared-species detection (substrates/products referencing a species not
    in the ``species`` map) is OWNED by the dataclass/coded layer —
    :func:`earthsci_ast.validation._validate_reaction_consistency` via
    ``_validate_stoich`` (code ``undeclared_species``). It formerly had a
    string-blob twin here; that duplicate was removed so the rule has one owner
    (finding: duplicated-rule dedup). The null-null and rate-reference checks
    below have coded twins there too, but are kept here as the raw-dict
    load-time gate.
    """
    for rsname, rs in data.get("reaction_systems", {}).items():
        species = set(rs.get("species", {}).keys())
        params = set(rs.get("parameters", {}).keys())
        valid_rate_syms = species | params | _BUILTIN_SYMBOLS
        for ri, reaction in enumerate(rs.get("reactions", [])):
            substrates = reaction.get("substrates")
            products = reaction.get("products")
            # Reaction has both substrates and products explicitly null is invalid
            if (
                "substrates" in reaction
                and "products" in reaction
                and substrates is None
                and products is None
            ):
                errors.append(
                    f"reaction_systems/{rsname}/reactions[{ri}]: reaction has both substrates and products as null"
                )
                continue
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


def _check_event_references(
    data: dict[str, Any], tables: dict[str, Any], errors: list[str]
) -> None:
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


def _check_registered_function_calls(data: dict[str, Any], errors: list[str]) -> None:
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


def _validate_structural(data: dict[str, Any], file_path=None) -> None:
    """
    Perform post-schema structural validation.

    Raises :class:`StructuralValidationError` (a ``SchemaValidationError``
    subclass) if any structural problems are found. Each check contributes its
    findings under a stable diagnostic code, collected onto the raised error's
    ``.findings`` list as ``(code, message)`` pairs; the raised error's
    ``str()`` is the same collapsed prose blob as before.
    """
    findings: list[tuple[str, str]] = []
    records: list[dict] = []

    def collect(code: str, run) -> None:
        """Run ``run(sub)`` and tag everything it produced with ``code``.

        A check appends either a bare prose message (legacy form — the
        JSON-Pointer path is then recovered from the conventional
        ``"a/b/c: message"`` prefix) or an explicit
        ``(json_pointer, message, details)`` triple.
        """
        sub: list = []
        run(sub)
        for item in sub:
            if isinstance(item, tuple):
                path, msg, details = item
            else:
                msg = item
                path = _json_pointer_from_message(msg)
                details = {}
            findings.append((code, msg))
            records.append({"code": code, "path": path, "message": msg, "details": details})

    # Operator arity check (walk all expressions)
    def walk_for_arity(errors, obj, path):
        if isinstance(obj, dict):
            if "op" in obj and "args" in obj:
                _check_expression_arity(obj, errors, path)
                return
            for k, v in obj.items():
                walk_for_arity(errors, v, f"{path}/{k}")
        elif isinstance(obj, list):
            for i, v in enumerate(obj):
                walk_for_arity(errors, v, f"{path}[{i}]")

    collect("operator_arity", lambda sub: walk_for_arity(sub, data, ""))

    tables = _build_symbol_tables(data)

    collect("undefined_reference", lambda sub: _check_variable_references(data, tables, sub))
    collect("undefined_reference", lambda sub: _check_coupling_references(data, tables, sub))
    collect("circular_reference", lambda sub: _check_circular_references(data, tables, sub))
    collect("data_loader_config", lambda sub: _check_data_loader_variables(data, sub))
    collect("invalid_discrete_param", lambda sub: _check_discrete_parameters(data, sub))
    collect("invalid_metadata_format", lambda sub: _check_metadata_formats(data, sub))
    collect("invalid_temporal_resolution", lambda sub: _check_temporal_resolution(data, sub))
    # Subsystem ref existence/parse is checked by resolve_subsystem_refs after
    # structural validation, which raises SubsystemRefError with richer context.
    collect("unit_inconsistency", lambda sub: _check_unparseable_units(data, sub))
    collect("unit_inconsistency", lambda sub: _check_unit_consistency(data, tables, sub))
    collect("unit_inconsistency", lambda sub: _check_default_units_consistency(data, sub))
    collect("unit_inconsistency", lambda sub: _check_conversion_factor_consistency(data, sub))
    collect("unit_inconsistency", lambda sub: _check_physical_constant_units(data, sub))
    collect("event_var_undeclared", lambda sub: _check_event_references(data, tables, sub))
    # Equation-unknown balance is OWNED by the dataclass/coded layer,
    # ``earthsci_ast.validation._validate_equation_balance_enhanced`` (code
    # ``equation_count_mismatch``), which correctly EXCLUDES ``ic`` equations
    # from the count. The former raw-dict twin ``_check_equation_balance``
    # counted ``ic`` equations and could disagree with it on the same file; it
    # was removed so the rule has a single owner (finding: duplicated-rule
    # dedup). Operator-state coverage below is a DISTINCT check with no coded
    # twin, so it stays here.
    collect("uncovered_state_variable", lambda sub: _check_operator_state_coverage(data, sub))
    collect("reaction_consistency", lambda sub: _check_reaction_systems(data, sub))
    # Reaction rate/stoichiometry dimensional consistency is now enforced in
    # ``earthsci_ast.validation._validate_reaction_rate_dimensions`` with a
    # structured ``unit_inconsistency`` payload matching the cross-language
    # contract in ``tests/invalid/expected_errors.json``.
    collect(
        "missing_registered_function",
        lambda sub: _check_registered_function_calls(data, sub),
    )

    if findings:
        blob = "Structural validation failed:\n" + "\n".join(
            f"  - {msg}" for _code, msg in findings
        )
        raise _structural_validation_error_cls()(blob, findings=findings, records=records)
