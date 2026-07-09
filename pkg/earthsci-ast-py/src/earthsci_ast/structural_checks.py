"""
Structural validation of raw ESM JSON documents (post-schema, pre-parse).

This module hosts the raw-dict structural-validation suite that
``earthsci_ast.parse.load`` runs after JSON-schema validation and template
resolution but before JSON→dataclass parsing: operator arity, symbol tables
and scoped-reference resolution, unit/dimension consistency, metadata formats,
data-loader/reaction-system/event checks, and the registered-function call
audit — everything invoked from :func:`_validate_structural`.

Split out of ``parse.py`` so raw-dict validation and dataclass parsing stay
separate concerns. ``parse`` imports from this module at module top; this
module only imports from ``parse`` lazily inside :func:`_validate_structural`
(for :class:`~earthsci_ast.parse.SchemaValidationError`), keeping the
module-import graph acyclic.
"""
from __future__ import annotations

import re
from typing import Any

# Shared pint unit registry, constructed lazily on first use. Unit parsing is
# hot (per-variable / per-equation checks) and ``pint.UnitRegistry()`` is
# expensive, so the suite reuses one module-level registry instead of building
# a fresh one per call. Callers keep the same try/except guards that
# previously wrapped ``import pint``, so environments without pint behave
# identically.
_UREG = None


def _get_unit_registry():
    """Return the module-level pint ``UnitRegistry``, creating it on first use."""
    global _UREG
    if _UREG is None:
        import pint

        _UREG = pint.UnitRegistry()
    return _UREG


# Exception types that mean "cannot verify these units", never "genuinely
# inconsistent": either pint is unavailable (``ImportError`` from the lazy
# ``import pint``) or pint could not parse/convert a unit string. The latter is
# pint's own error hierarchy — ``UndefinedUnitError``, ``DimensionalityError``,
# ``DefinitionSyntaxError``, ``OffsetUnitCalculusError``, … — all subclasses of
# ``pint.errors.PintError``. Narrowing the unit-helper ``except`` clauses to
# this tuple (instead of a blanket ``except Exception``) keeps the permissive
# fallback for unparseable units while letting a genuine, unexpected bug
# propagate instead of being silently swallowed as a spurious pass.
_PINT_UNVERIFIABLE_ERRORS = None


def _pint_unverifiable_errors():
    """Return the tuple of exception types treated as "unit unparseable / pint
    unavailable" by the unit-consistency helpers (see the note above)."""
    global _PINT_UNVERIFIABLE_ERRORS
    if _PINT_UNVERIFIABLE_ERRORS is None:
        try:
            import pint

            _PINT_UNVERIFIABLE_ERRORS = (ImportError, pint.errors.PintError)
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


def _walk_expression_strings(expr) -> list[str]:
    """Recursively collect string args from inside op-expression nodes only."""
    result = []
    if isinstance(expr, dict) and "op" in expr and "args" in expr:
        for arg in expr["args"]:
            if isinstance(arg, str):
                result.append(arg)
            elif isinstance(arg, dict):
                result.extend(_walk_expression_strings(arg))
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
        ureg = _get_unit_registry()
        q1 = ureg(n1) if n1 != "dimensionless" else ureg("dimensionless")
        q2 = ureg(n2) if n2 != "dimensionless" else ureg("dimensionless")
        return q1.dimensionality == q2.dimensionality
    except _pint_unverifiable_errors():
        # unparseable unit (or pint unavailable): cannot verify, fall back to
        # a plain string comparison rather than blocking.
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
    """
    global_symbols = tables["global_symbols"]
    for mname, m in data.get("models", {}).items():
        for i, eq in enumerate(m.get("equations", [])):
            lhs_is_derivative = isinstance(eq.get("lhs"), dict) and eq["lhs"].get("op") == "D"
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


def _infer_expression_units(expr, var_units: dict[str, str]):
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
        ureg = _get_unit_registry()
        lhs_q = ureg(n_lhs)
        rhs_q = ureg(n_rhs)
        ratio = (rhs_q * ureg("second")) / lhs_q
        return ratio.dimensionless
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
        ureg = _get_unit_registry()
        return ureg(normalized).dimensionless
    except _pint_unverifiable_errors():
        # unparseable unit (or pint unavailable): cannot verify, treat as
        # not-dimensionless (do not assert dimensionlessness we can't confirm).
        return False


def _model_coordinate_units(
    data: dict[str, Any], model: dict[str, Any]
) -> dict[str, str | None] | None:
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
    coords: dict[str, str | None] = {}
    for dim_name, dim_def in spatial.items():
        if isinstance(dim_def, dict):
            coords[dim_name] = dim_def.get("units")
        else:
            coords[dim_name] = None
    return coords


def _walk_expression_for_spatial_operator_checks(
    expr: Any,
    coord_units: dict[str, str | None] | None,
    path: str,
    errors: list[str],
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
        _walk_expression_for_spatial_operator_checks(arg, coord_units, f"{path}/args[{i}]", errors)
    if "expr" in expr:
        _walk_expression_for_spatial_operator_checks(
            expr["expr"], coord_units, f"{path}/expr", errors
        )


def _walk_expression_for_exponent_checks(
    expr: Any,
    var_units: dict[str, str],
    path: str,
    errors: list[str],
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


def _check_default_units_consistency(data: dict[str, Any], errors: list[str]) -> None:
    """
    Flag variables whose `default_units` disagrees with the declared `units`.

    Emits `unit_inconsistency` when the two unit strings resolve to different
    pint units — covering both dimensionally incompatible cases (e.g., K vs kg)
    and same-dimension mismatches (e.g., K vs degC). Absent default_units is a
    no-op: a default value is presumed to share the declared units.
    """
    try:
        ureg = _get_unit_registry()
    except ImportError:
        # pint not installed: cannot verify units, do not block.
        return

    def units_match(declared: str, provided: str) -> bool:
        try:
            declared_u = ureg(_normalize_unit(declared)).units
            provided_u = ureg(_normalize_unit(provided)).units
            return declared_u == provided_u
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

    def linear_factor(from_unit: str, to_unit: str):
        try:
            q0 = ureg.Quantity(0.0, from_unit).to(to_unit).magnitude
            q1 = ureg.Quantity(1.0, from_unit).to(to_unit).magnitude
        except _pint_unverifiable_errors():
            # unparseable or inconvertible unit: cannot verify, skip.
            return None
        if abs(q0) > 1e-12:
            return None  # affine (e.g., degC -> K)
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
                if ureg(n_src).dimensionality != ureg(n_lhs).dimensionality:
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


def _check_unit_consistency(
    data: dict[str, Any], tables: dict[str, Any], errors: list[str]
) -> None:
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


def _check_equation_balance(data: dict[str, Any], errors: list[str]) -> None:
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
        observed_vars = {
            n for n, v in m.get("variables", {}).items() if v.get("type") == "observed"
        }
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
            errors.append(f"models/{mname}: has {len(state_vars)} state variables but no equations")
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
    """Validate reaction system: substrates/products are declared species, rate refs valid."""
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

    Raises SchemaValidationError if any structural problems are found.
    """
    # Function-level import: ``parse`` imports this module at module top, so
    # the exception class is imported lazily here to keep the module-level
    # import graph acyclic.
    from .parse import SchemaValidationError

    errors: list[str] = []

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
    # ``earthsci_ast.validation._validate_reaction_rate_dimensions`` with a
    # structured ``unit_inconsistency`` payload matching the cross-language
    # contract in ``tests/invalid/expected_errors.json``.
    _check_registered_function_calls(data, errors)

    if errors:
        raise SchemaValidationError(
            "Structural validation failed:\n" + "\n".join(f"  - {e}" for e in errors)
        )
