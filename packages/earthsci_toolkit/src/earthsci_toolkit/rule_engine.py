"""Rule engine per discretization RFC §5.2.

Pattern-match rewriting over the ESM expression AST with typed pattern
variables, guards, non-linear matching (via canonical equality), and a
top-down fixed-point loop with per-pass sealing of rewritten subtrees.

Mirrors ``packages/EarthSciSerialization.jl/src/rule_engine.jl`` and
``packages/earthsci-toolkit-rs/src/rule_engine.rs``; byte-identical
output on the cross-binding rule-engine conformance fixtures is the
acceptance criterion.

The MVP supports only the inline ``replacement`` form; ``use:<scheme>``
(RFC §7.2.1) is deferred.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from typing import Any, Dict, List, Mapping, Optional, Sequence, Union

from .canonicalize import canonical_json, CanonicalizeError
from .esm_types import Expr, ExprNode


class RuleEngineError(Exception):
    """Error raised by the rule engine.

    ``code`` carries one of the RFC §5.2 / §11 stable error codes:

    - ``E_RULES_NOT_CONVERGED`` — fixed-point loop exceeded ``max_passes``.
    - ``E_UNREWRITTEN_PDE_OP`` — a PDE op remained after rewriting on an
      equation not annotated ``passthrough: true``.
    - ``E_SCHEME_MISMATCH`` — reserved for the ``use:`` form (not emitted
      in the MVP).
    """

    def __init__(self, code: str, message: str):
        super().__init__(f"RuleEngineError({code}): {message}")
        self.code = code
        self.message = message


@dataclass
class Guard:
    """A single constraint on pattern-variable bindings (RFC §5.2.4)."""

    name: str
    params: Dict[str, Any] = field(default_factory=dict)


# Closed set of policy kinds accepted in either the string-form
# ``boundary_policy`` or in :class:`BoundaryPolicySpec.kind`
# (RFC §5.2.8 / §7).
_BOUNDARY_POLICY_KIND_VALUES = (
    "periodic", "reflecting", "one_sided_extrapolation", "prescribed",
    # v0.3.x backwards-compatible aliases
    "ghosted", "neumann_zero", "extrapolate",
)

_BOUNDARY_POLICY_STRING_VALUES = (
    "periodic", "reflecting", "one_sided_extrapolation", "prescribed",
    "ghosted", "neumann_zero", "extrapolate",
)

_BINDING_KIND_VALUES = ("static", "per_step", "per_cell")


@dataclass
class BoundaryPolicySpec:
    """A single per-axis boundary-policy entry (RFC §5.2.8 / §7).

    ``kind`` is one of the closed-set tags listed in
    :data:`_BOUNDARY_POLICY_KIND_VALUES`; the remaining fields are
    kind-specific:

    - ``degree``: ``one_sided_extrapolation`` / ``extrapolate`` —
      extrapolation order (0..3). ``None`` means default (linear).
    - ``description``: free-form authorial note.
    """

    kind: str
    degree: Optional[int] = None
    description: Optional[str] = None


# Type alias documenting the closed set of authorial forms for a rule's
# ``boundary_policy`` (RFC §5.2.8 / §7): ``None`` (omitted, equivalent to
# ``"periodic"``), a string from the closed set (uniform across axes), or
# a ``{by_axis: {<axis>: BoundaryPolicySpec}}`` dict (per-axis form).
BoundaryPolicy = Union[str, Dict[str, Any], None]
GhostWidth = Union[int, Dict[str, Any], None]


@dataclass
class RuleBinding:
    """A single rule binding declaration (RFC §5.2.8).

    ``kind`` is one of ``"static"``, ``"per_step"``, ``"per_cell"`` and
    declares the rate at which the host runtime updates the binding's
    value. ``default`` is an optional default-value expression. ``description``
    is an optional authorial note. The Python binding preserves
    ``RuleBinding`` entries across parse/serialize roundtrips; the rule
    engine itself does not consult them during pattern matching or expansion.
    """

    kind: str
    default: Optional[Expr] = None
    description: Optional[str] = None


@dataclass
class Rule:
    """A rewrite rule (RFC §5.2, §5.2.7, §5.2.8).

    ``region`` may be ``None``, a legacy advisory ``str``, or a ``dict``
    representing an object scope variant (``{kind: "boundary"
    /"mask_field"/"index_range", ...}``). ``where_expr`` is an optional
    per-query-point predicate ``Expr`` — mutually exclusive with the
    ``where`` guard list at the author level, structurally discriminated
    by JSON shape at parse time.

    The Python binding evaluates ``region.index_range``, ``region.boundary``,
    and the ``where_expr`` predicate per query point. ``region.mask_field``
    parses and round-trips but does not evaluate (conservative fall-through,
    equivalent to RFC §5.2.7's W_UNEVAL_SCOPE).

    ``boundary_policy`` declares behavior at domain edges (RFC §5.2.8 / §7).
    It is one of: ``None`` (default — equivalent to ``"periodic"``), a
    ``str`` from the closed set (uniform across all axes), or a
    ``Dict[str, BoundaryPolicySpec]`` (per-axis form, required for
    axis-heterogeneous policies). Stored
    verbatim; the rule engine does not branch on it.

    ``ghost_width`` declares per-axis ghost-cell padding the rule's stencil
    reaches (RFC §5.2.8 / §7). It is one of: ``None`` (default — 0), an
    ``int`` (uniform across all axes), or a ``Dict[str, int]`` (per-axis
    form). Stored verbatim.

    ``bindings`` is an optional mapping from bare identifier name to a
    :class:`RuleBinding` declaration (RFC §5.2.8). Stored verbatim.
    """

    name: str
    pattern: Expr
    replacement: Expr
    where: List[Guard] = field(default_factory=list)
    region: Optional[Any] = None
    where_expr: Optional[Expr] = None
    boundary_policy: Union[str, Dict[str, BoundaryPolicySpec], None] = None
    ghost_width: Union[int, Dict[str, int], None] = None
    bindings: Optional[Dict[str, RuleBinding]] = None


@dataclass
class RuleContext:
    """Context supplied to guard and scope evaluation (RFC §5.2.4, §5.2.7).

    - ``grids``: per-grid metadata. Each entry may carry ``spatial_dims``,
      ``periodic_dims``, ``nonuniform_dims`` (lists of strings) and
      ``dim_bounds`` (dict mapping dim name to ``[lo, hi]``).
    - ``variables``: per-variable metadata. Each entry may carry ``grid``,
      ``location``, ``shape``.
    - ``query_point``: per-query-point index bindings used to evaluate
      RFC §5.2.7 region / where-expression scopes. Empty for ordinary
      tree rewriting (scope-bearing rules then fall through).
    - ``grid_name``: name of the grid the ``query_point`` refers to
      (used to resolve ``region.boundary.side`` against
      ``dim_bounds``).
    """

    grids: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    variables: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    query_point: Dict[str, int] = field(default_factory=dict)
    grid_name: Optional[str] = None
    mask_fields: Dict[str, List[Dict[str, int]]] = field(default_factory=dict)


# ============================================================================
# Pattern variable detection
# ============================================================================


def _is_pvar_string(x: Any) -> bool:
    return isinstance(x, str) and len(x) >= 2 and x[0] == "$"


# ============================================================================
# Match
# ============================================================================


Bindings = Dict[str, Expr]


def match_pattern(pattern: Expr, expr: Expr) -> Optional[Bindings]:
    """Attempt to match ``pattern`` against ``expr``.

    On success returns a substitution mapping each pattern-variable name
    (including the leading ``$``) to the bound value. Bare-name bindings
    (for sibling fields like ``wrt`` or ``dim``) are stored as plain
    strings. On failure returns ``None``.
    """
    return _match(pattern, expr, {})


def _match(pat: Expr, expr: Expr, b: Bindings) -> Optional[Bindings]:
    if _is_pvar_string(pat):
        return _unify(pat, expr, b)  # type: ignore[arg-type]
    if isinstance(pat, bool):
        # Python bool is an int subclass; the AST does not carry booleans.
        return None
    if isinstance(pat, int):
        return b if (isinstance(expr, int) and not isinstance(expr, bool) and expr == pat) else None
    if isinstance(pat, float):
        return b if (isinstance(expr, float) and expr == pat) else None
    if isinstance(pat, str):
        return b if (isinstance(expr, str) and expr == pat) else None
    if isinstance(pat, ExprNode):
        if not isinstance(expr, ExprNode):
            return None
        if pat.op != expr.op:
            return None
        if len(pat.args) != len(expr.args):
            return None
        b2 = _match_sibling_name(pat.wrt, expr.wrt, b)
        if b2 is None:
            return None
        b2 = _match_sibling_name(pat.dim, expr.dim, b2)
        if b2 is None:
            return None
        b2 = _match_sibling_name(pat.fn, expr.fn, b2)
        if b2 is None:
            return None
        for pa, ea in zip(pat.args, expr.args):
            b2 = _match(pa, ea, b2)
            if b2 is None:
                return None
        return b2
    return None


def _match_sibling_name(
    pat: Optional[str], val: Optional[str], b: Bindings
) -> Optional[Bindings]:
    if pat is None:
        return b if val is None else None
    if _is_pvar_string(pat):
        if val is None:
            return None
        return _unify(pat, val, b)
    return b if (val is not None and val == pat) else None


def _unify(pname: str, candidate: Expr, b: Bindings) -> Optional[Bindings]:
    if pname in b:
        try:
            prev_json = canonical_json(b[pname])
            new_json = canonical_json(candidate)
        except CanonicalizeError:
            return None
        return b if prev_json == new_json else None
    nb = dict(b)
    nb[pname] = candidate
    return nb


# ============================================================================
# Apply bindings
# ============================================================================


def apply_bindings(template: Expr, b: Bindings) -> Expr:
    """Substitute pattern variables in ``template`` with their bound values."""
    if _is_pvar_string(template):
        if template not in b:
            raise RuleEngineError(
                "E_PATTERN_VAR_UNBOUND",
                f"pattern variable {template} is not bound",
            )
        return b[template]
    if isinstance(template, ExprNode):
        new_args = [apply_bindings(a, b) for a in template.args]
        new_wrt = _apply_name_field(template.wrt, b)
        new_dim = _apply_name_field(template.dim, b)
        new_fn = _apply_name_field(template.fn, b)
        return replace(template, args=new_args, wrt=new_wrt, dim=new_dim, fn=new_fn)
    return template


def _apply_name_field(field_val: Optional[str], b: Bindings) -> Optional[str]:
    if field_val is None:
        return None
    if _is_pvar_string(field_val):
        if field_val not in b:
            raise RuleEngineError(
                "E_PATTERN_VAR_UNBOUND",
                f"pattern variable {field_val} is not bound",
            )
        v = b[field_val]
        if not isinstance(v, str):
            raise RuleEngineError(
                "E_PATTERN_VAR_TYPE",
                f"pattern variable {field_val} used in name-class field must "
                f"bind a bare name",
            )
        return v
    return field_val


# ============================================================================
# Guards (§5.2.4)
# ============================================================================


def check_guards(
    guards: Sequence[Guard], bindings: Bindings, ctx: RuleContext
) -> Optional[Bindings]:
    """Evaluate a guard list left-to-right, threading bindings."""
    b: Optional[Bindings] = bindings
    for g in guards:
        b = check_guard(g, b, ctx)  # type: ignore[arg-type]
        if b is None:
            return None
    return b


def check_guard(g: Guard, b: Bindings, ctx: RuleContext) -> Optional[Bindings]:
    """Evaluate a single guard per §5.2.4."""
    name = g.name
    if name == "var_has_grid":
        return _guard_var_has_grid(g, b, ctx)
    if name == "dim_is_spatial_dim_of":
        return _guard_dim_is_spatial_dim_of(g, b, ctx)
    if name == "dim_is_periodic":
        return _guard_dim_is_periodic(g, b, ctx)
    if name == "dim_is_nonuniform":
        return _guard_dim_is_nonuniform(g, b, ctx)
    if name == "var_location_is":
        return _guard_var_location_is(g, b, ctx)
    if name == "var_shape_rank":
        return _guard_var_shape_rank(g, b, ctx)
    if name == "bind_side_axis":
        return _guard_bind_side_axis(g, b)
    if name == "bind_side_spacing":
        return _guard_bind_side_spacing(g, b, ctx)
    if name == "bind_side_dim_size":
        return _guard_bind_side_dim_size(g, b, ctx)
    raise RuleEngineError(
        "E_UNKNOWN_GUARD",
        f"unknown guard: {name} (§5.2.4 closed set)",
    )


def _resolve_name(b: Bindings, key: str) -> Optional[str]:
    v = b.get(key)
    return v if isinstance(v, str) else None


def _resolve_or_mark(g: Guard, b: Bindings, field_name: str):
    """Return (value, need_bind, pvar_name)."""
    v = g.params.get(field_name)
    if v is None:
        return (None, False, None)
    s = str(v)
    if _is_pvar_string(s):
        bound = _resolve_name(b, s)
        return (bound, bound is None, s)
    return (s, False, None)


def _bind_pvar_name(b: Bindings, pvar: str, name: str) -> Bindings:
    nb = dict(b)
    nb[pvar] = name
    return nb


def _guard_var_has_grid(g: Guard, b: Bindings, ctx: RuleContext) -> Optional[Bindings]:
    pvar = str(g.params["pvar"])
    var_name = _resolve_name(b, pvar)
    if var_name is None:
        return None
    meta = ctx.variables.get(var_name)
    if meta is None:
        return None
    actual = meta.get("grid")
    if actual is None:
        return None
    wanted, need_bind, pname = _resolve_or_mark(g, b, "grid")
    if need_bind:
        return _bind_pvar_name(b, pname, actual)  # type: ignore[arg-type]
    return b if wanted == actual else None


def _dim_name_from_pvar_or_literal(g: Guard, b: Bindings) -> Optional[str]:
    pvar = str(g.params["pvar"])
    name = _resolve_name(b, pvar)
    if name is not None:
        return name
    # §9.2.1 accepts a bare string in pvar (e.g. "x") — treat as literal.
    return None if _is_pvar_string(pvar) else pvar


def _guard_dim_is_spatial_dim_of(
    g: Guard, b: Bindings, ctx: RuleContext
) -> Optional[Bindings]:
    pvar = str(g.params["pvar"])
    dim_name = _resolve_name(b, pvar)
    if dim_name is None:
        return None
    grid, _, _ = _resolve_or_mark(g, b, "grid")
    if grid is None:
        return None
    meta = ctx.grids.get(grid)
    if meta is None:
        return None
    return b if dim_name in meta.get("spatial_dims", []) else None


def _guard_dim_is_periodic(
    g: Guard, b: Bindings, ctx: RuleContext
) -> Optional[Bindings]:
    dim_name = _dim_name_from_pvar_or_literal(g, b)
    if dim_name is None:
        return None
    grid, _, _ = _resolve_or_mark(g, b, "grid")
    if grid is None:
        return None
    meta = ctx.grids.get(grid)
    if meta is None:
        return None
    return b if dim_name in meta.get("periodic_dims", []) else None


def _guard_dim_is_nonuniform(
    g: Guard, b: Bindings, ctx: RuleContext
) -> Optional[Bindings]:
    dim_name = _dim_name_from_pvar_or_literal(g, b)
    if dim_name is None:
        return None
    grid, _, _ = _resolve_or_mark(g, b, "grid")
    if grid is None:
        return None
    meta = ctx.grids.get(grid)
    if meta is None:
        return None
    return b if dim_name in meta.get("nonuniform_dims", []) else None


def _guard_var_location_is(
    g: Guard, b: Bindings, ctx: RuleContext
) -> Optional[Bindings]:
    pvar = str(g.params["pvar"])
    var_name = _resolve_name(b, pvar)
    if var_name is None:
        return None
    target = str(g.params["location"])
    meta = ctx.variables.get(var_name)
    if meta is None:
        return None
    return b if meta.get("location") == target else None


def _guard_var_shape_rank(
    g: Guard, b: Bindings, ctx: RuleContext
) -> Optional[Bindings]:
    pvar = str(g.params["pvar"])
    var_name = _resolve_name(b, pvar)
    if var_name is None:
        return None
    want = int(g.params["rank"])
    meta = ctx.variables.get(var_name)
    if meta is None:
        return None
    shape = meta.get("shape")
    if shape is None:
        return None
    return b if len(shape) == want else None


_SIDE_TO_AXIS: Dict[str, str] = {
    "xmin": "x", "xmax": "x", "west": "x", "east": "x",
    "ymin": "y", "ymax": "y", "south": "y", "north": "y",
    "zmin": "z", "zmax": "z", "bottom": "z", "top": "z",
}

_SIDE_TO_AXIS_IDX: Dict[str, int] = {
    "xmin": 0, "xmax": 0, "west": 0, "east": 0,
    "ymin": 1, "ymax": 1, "south": 1, "north": 1,
    "zmin": 2, "zmax": 2, "bottom": 2, "top": 2,
}


def _resolve_side_or_literal(g: Guard, b: Bindings, field: str) -> Optional[str]:
    raw = g.params.get(field)
    if raw is None:
        return None
    s = str(raw)
    if _is_pvar_string(s):
        return _resolve_name(b, s)
    return s


def _guard_bind_side_axis(g: Guard, b: Bindings) -> Optional[Bindings]:
    pvar = str(g.params["pvar"])
    side_name = _resolve_side_or_literal(g, b, "side")
    if side_name is None:
        return None
    axis = _SIDE_TO_AXIS.get(side_name)
    if axis is None:
        return None
    return _bind_pvar_name(b, pvar, axis)


def _guard_bind_side_spacing(
    g: Guard, b: Bindings, ctx: RuleContext
) -> Optional[Bindings]:
    pvar = str(g.params["pvar"])
    side_name = _resolve_side_or_literal(g, b, "side")
    if side_name is None:
        return None
    grid_raw = str(g.params["grid"])
    grid_name = _resolve_name(b, grid_raw) if _is_pvar_string(grid_raw) else grid_raw
    if grid_name is None:
        return None
    meta = ctx.grids.get(grid_name)
    if meta is None:
        return None
    axis_idx = _SIDE_TO_AXIS_IDX.get(side_name)
    if axis_idx is None:
        return None
    spatial = meta.get("spatial_dims", [])
    if axis_idx >= len(spatial):
        return None
    dim_name = spatial[axis_idx]
    dim_sizes = meta.get("dim_sizes", {})
    n_val = dim_sizes.get(dim_name)
    if n_val is None:
        return None
    nb = dict(b)
    nb[pvar] = 1.0 / int(n_val)
    return nb


def _guard_bind_side_dim_size(
    g: Guard, b: Bindings, ctx: RuleContext
) -> Optional[Bindings]:
    pvar = str(g.params["pvar"])
    side_name = _resolve_side_or_literal(g, b, "side")
    if side_name is None:
        return None
    grid_raw = str(g.params["grid"])
    grid_name = _resolve_name(b, grid_raw) if _is_pvar_string(grid_raw) else grid_raw
    if grid_name is None:
        return None
    meta = ctx.grids.get(grid_name)
    if meta is None:
        return None
    axis_idx = _SIDE_TO_AXIS_IDX.get(side_name)
    if axis_idx is None:
        return None
    spatial = meta.get("spatial_dims", [])
    if axis_idx >= len(spatial):
        return None
    dim_name = spatial[axis_idx]
    dim_sizes = meta.get("dim_sizes", {})
    n_val = dim_sizes.get(dim_name)
    if n_val is None:
        return None
    nb = dict(b)
    nb[pvar] = int(n_val)
    return nb


# ============================================================================
# Rewriter (§5.2.5)
# ============================================================================


def rewrite(
    expr: Expr,
    rules: Sequence[Rule],
    ctx: Optional[RuleContext] = None,
    max_passes: int = 32,
) -> Expr:
    """Run the rule engine on ``expr`` per RFC §5.2.5.

    Each pass walks top-down, the first rule whose pattern matches fires,
    the rewritten subtree is sealed for the remainder of that pass, then
    walking continues with siblings. A pass that produces no rewrites
    terminates the loop. If ``max_passes`` is reached without convergence
    the engine raises ``RuleEngineError(E_RULES_NOT_CONVERGED)``.
    """
    if ctx is None:
        ctx = RuleContext()
    current = expr
    for _ in range(max_passes):
        state = {"changed": False}
        current = _rewrite_pass(current, rules, ctx, state)
        if not state["changed"]:
            return current
    raise RuleEngineError(
        "E_RULES_NOT_CONVERGED",
        f"rule engine did not converge within {max_passes} passes",
    )


def _rewrite_pass(
    expr: Expr,
    rules: Sequence[Rule],
    ctx: RuleContext,
    state: Dict[str, bool],
) -> Expr:
    for rule in rules:
        m = match_pattern(rule.pattern, expr)
        if m is None:
            continue
        m2 = check_guards(rule.where, m, ctx)
        if m2 is None:
            continue
        if not check_scope(rule, m2, ctx):
            continue
        new_expr = apply_bindings(rule.replacement, m2)
        state["changed"] = True
        return new_expr
    if isinstance(expr, ExprNode):
        new_args = [_rewrite_pass(a, rules, ctx, state) for a in expr.args]
        return replace(expr, args=new_args)
    return expr


# ============================================================================
# Scope evaluation — region object + where expression (RFC §5.2.7)
# ============================================================================


def check_scope(rule: Rule, bindings: Bindings, ctx: RuleContext) -> bool:
    """Evaluate a rule's per-query-point scope.

    Returns ``True`` when the rule should fire at the current query
    point, ``False`` otherwise (conservative fall-through). A legacy
    string ``region`` and a missing ``where_expr`` pass
    unconditionally, preserving v0.2 semantics.
    """
    region = rule.region
    if isinstance(region, Mapping) and not _eval_region(region, ctx):
        return False
    if rule.where_expr is not None and not _eval_where_expr(
        rule.where_expr, bindings, ctx
    ):
        return False
    return True


_CANONICAL_INDEX_NAMES = ("i", "j", "k", "l", "m")


def _eval_region(region: Mapping[str, Any], ctx: RuleContext) -> bool:
    kind = region.get("kind")
    if kind == "index_range":
        axis = region.get("axis")
        if not isinstance(axis, str):
            return False
        v = ctx.query_point.get(axis)
        if v is None:
            return False
        lo = region.get("lo")
        hi = region.get("hi")
        if not isinstance(lo, int) or not isinstance(hi, int):
            return False
        return lo <= v <= hi
    if kind == "boundary":
        side = region.get("side")
        return isinstance(side, str) and _eval_boundary(side, ctx)
    if kind == "mask_field":
        return _eval_mask_field(region, ctx)
    return False


def _eval_mask_field(region: Mapping[str, Any], ctx: RuleContext) -> bool:
    field_name = region.get("field")
    if not isinstance(field_name, str):
        return False
    mask = ctx.mask_fields.get(field_name)
    if mask is None:
        return False
    return ctx.query_point in mask


def _eval_boundary(side: str, ctx: RuleContext) -> bool:
    grid_name = ctx.grid_name
    if grid_name is None:
        return False
    meta = ctx.grids.get(grid_name)
    if meta is None:
        return False
    sides = {
        "xmin": ("x", False), "west": ("x", False),
        "xmax": ("x", True), "east": ("x", True),
        "ymin": ("y", False), "south": ("y", False),
        "ymax": ("y", True), "north": ("y", True),
        "zmin": ("z", False), "bottom": ("z", False),
        "zmax": ("z", True), "top": ("z", True),
    }
    if side not in sides:
        return False
    dim, which_hi = sides[side]
    bounds = meta.get("dim_bounds", {}).get(dim)
    if not isinstance(bounds, (list, tuple)) or len(bounds) != 2:
        return False
    spatial_dims = meta.get("spatial_dims", [])
    try:
        idx_pos = list(spatial_dims).index(dim)
    except ValueError:
        return False
    if idx_pos >= len(_CANONICAL_INDEX_NAMES):
        return False
    idx_name = _CANONICAL_INDEX_NAMES[idx_pos]
    v = ctx.query_point.get(idx_name)
    if v is None:
        return False
    target = bounds[1] if which_hi else bounds[0]
    return v == target


def _eval_where_expr(expr: Expr, bindings: Bindings, ctx: RuleContext) -> bool:
    if not ctx.query_point:
        return False
    val = _eval_scalar(expr, bindings, ctx)
    if val is None:
        return False
    return bool(val)


def _eval_scalar(e: Expr, b: Bindings, ctx: RuleContext):
    if isinstance(e, bool):
        return e
    if isinstance(e, int):
        return e
    if isinstance(e, float):
        return e
    if isinstance(e, str):
        if _is_pvar_string(e):
            bound = b.get(e)
            if bound is None:
                return None
            return _eval_scalar(bound, b, ctx)
        v = ctx.query_point.get(e)
        if v is None:
            return None
        return v
    if isinstance(e, ExprNode):
        return _eval_op(e, b, ctx)
    return None


def _eval_op(node: ExprNode, b: Bindings, ctx: RuleContext):
    op = node.op
    args = [_eval_scalar(a, b, ctx) for a in node.args]
    if any(a is None for a in args):
        return None
    if op in ("==", "!=", "<", "<=", ">", ">="):
        if len(args) != 2:
            return None
        left, right = float(args[0]), float(args[1])
        return {
            "==": left == right,
            "!=": left != right,
            "<": left < right,
            "<=": left <= right,
            ">": left > right,
            ">=": left >= right,
        }[op]
    if op == "+":
        if all(isinstance(a, int) and not isinstance(a, bool) for a in args):
            return sum(args)
        return sum(float(a) for a in args)
    if op == "-":
        if len(args) == 1:
            return -args[0]
        if len(args) != 2:
            return None
        left, right = args
        if isinstance(left, int) and isinstance(right, int) and not isinstance(
            left, bool
        ) and not isinstance(right, bool):
            return left - right
        return float(left) - float(right)
    if op == "*":
        if all(isinstance(a, int) and not isinstance(a, bool) for a in args):
            result = 1
            for a in args:
                result *= a
            return result
        result = 1.0
        for a in args:
            result *= float(a)
        return result
    if op == "and":
        return all(bool(a) for a in args)
    if op == "or":
        return any(bool(a) for a in args)
    if op == "not":
        if len(args) != 1:
            return None
        return not bool(args[0])
    return None


# ============================================================================
# JSON loading
# ============================================================================


def _parse_expr(v: Any) -> Expr:
    if isinstance(v, ExprNode):
        return v
    if isinstance(v, bool):
        raise RuleEngineError(
            "E_RULE_PARSE",
            "booleans are not valid in expression position",
        )
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return v
    if isinstance(v, str):
        return v
    if isinstance(v, Mapping):
        if "op" not in v:
            raise RuleEngineError(
                "E_RULE_PARSE", "expression object missing 'op' field"
            )
        op = str(v["op"])
        args_raw = v.get("args", [])
        args = [_parse_expr(a) for a in args_raw]
        wrt = v.get("wrt")
        dim = v.get("dim")
        fn = v.get("fn")
        return ExprNode(
            op=op,
            args=args,
            wrt=None if wrt is None else str(wrt),
            dim=None if dim is None else str(dim),
            fn=None if fn is None else str(fn),
        )
    raise RuleEngineError(
        "E_RULE_PARSE", f"cannot parse expression of type {type(v).__name__}"
    )


def _parse_guard(obj: Mapping[str, Any]) -> Guard:
    if "guard" not in obj:
        raise RuleEngineError("E_RULE_PARSE", "guard object missing 'guard' field")
    name = str(obj["guard"])
    params: Dict[str, Any] = {}
    for k, v in obj.items():
        if k == "guard":
            continue
        params[str(k)] = v
    return Guard(name=name, params=params)


def parse_rule(obj: Mapping[str, Any], name: Optional[str] = None) -> Rule:
    """Build a :class:`Rule` from a decoded JSON object."""
    if name is None:
        if "name" not in obj:
            raise RuleEngineError("E_RULE_PARSE", "rule object missing 'name'")
        name = str(obj["name"])
    if "pattern" not in obj:
        raise RuleEngineError(
            "E_RULE_PARSE", f"rule {name}: missing 'pattern' field"
        )
    pat = _parse_expr(obj["pattern"])
    if "replacement" not in obj:
        raise RuleEngineError(
            "E_RULE_REPLACEMENT_MISSING",
            f"rule {name}: MVP supports only the 'replacement' form; "
            f"'use:' rules are deferred",
        )
    repl = _parse_expr(obj["replacement"])
    where_raw = obj.get("where")
    guards: List[Guard] = []
    where_expr: Optional[Expr] = None
    if where_raw is not None:
        if isinstance(where_raw, list):
            guards = [_parse_guard(g) for g in where_raw]
        elif isinstance(where_raw, Mapping):
            if "op" not in where_raw:
                raise RuleEngineError(
                    "E_RULE_PARSE",
                    f"rule {name}: 'where' object must be an expression node with an 'op' field",
                )
            where_expr = _parse_expr(where_raw)
        else:
            raise RuleEngineError(
                "E_RULE_PARSE",
                f"rule {name}: 'where' must be an array of guards or an expression object",
            )
    region_raw = obj.get("region")
    region: Optional[Any]
    if region_raw is None:
        region = None
    elif isinstance(region_raw, str):
        region = region_raw  # legacy advisory tag
    elif isinstance(region_raw, Mapping):
        kind = region_raw.get("kind")
        if kind not in ("boundary", "mask_field", "index_range"):
            raise RuleEngineError(
                "E_RULE_PARSE",
                f"rule {name}: unknown region.kind `{kind}` "
                f"(closed set: boundary, mask_field, index_range)",
            )
        region = dict(region_raw)
    else:
        raise RuleEngineError(
            "E_RULE_PARSE",
            f"rule {name}: 'region' must be a string (legacy) or object (scope)",
        )
    boundary_policy = _parse_boundary_policy(name, obj.get("boundary_policy"))
    ghost_width = _parse_ghost_width(name, obj.get("ghost_width"))
    bindings_raw = obj.get("bindings")
    bindings: Optional[Dict[str, RuleBinding]]
    if bindings_raw is None:
        bindings = None
    elif isinstance(bindings_raw, Mapping):
        bindings = {}
        for bname, bval in bindings_raw.items():
            bindings[str(bname)] = _parse_rule_binding(name, str(bname), bval)
    else:
        raise RuleEngineError(
            "E_RULE_PARSE",
            f"rule {name}: `bindings` must be an object",
        )
    return Rule(
        name=name,
        pattern=pat,
        replacement=repl,
        where=guards,
        region=region,
        where_expr=where_expr,
        boundary_policy=boundary_policy,
        ghost_width=ghost_width,
        bindings=bindings,
    )


def _parse_boundary_policy(
    name: str, raw: Any
) -> Union[str, Dict[str, BoundaryPolicySpec], None]:
    if raw is None:
        return None
    if isinstance(raw, str):
        if raw not in _BOUNDARY_POLICY_STRING_VALUES:
            valid = ", ".join(_BOUNDARY_POLICY_STRING_VALUES)
            raise RuleEngineError(
                "E_RULE_PARSE",
                f"rule {name}: unknown boundary_policy `{raw}` (closed set: {valid})",
            )
        return raw
    if isinstance(raw, Mapping):
        by_axis_raw = raw.get("by_axis")
        if by_axis_raw is None:
            raise RuleEngineError(
                "E_RULE_PARSE",
                f"rule {name}: `boundary_policy` object must have a `by_axis` field",
            )
        if not isinstance(by_axis_raw, Mapping):
            raise RuleEngineError(
                "E_RULE_PARSE",
                f"rule {name}: `boundary_policy.by_axis` must be an object",
            )
        out: Dict[str, BoundaryPolicySpec] = {}
        for axis, spec in by_axis_raw.items():
            saxis = str(axis)
            out[saxis] = _parse_boundary_policy_spec(name, saxis, spec)
        return out
    raise RuleEngineError(
        "E_RULE_PARSE",
        f"rule {name}: `boundary_policy` must be a string or an object with a `by_axis` field",
    )


def _parse_boundary_policy_spec(
    rule_name: str, axis: str, raw: Any
) -> BoundaryPolicySpec:
    if not isinstance(raw, Mapping):
        raise RuleEngineError(
            "E_RULE_PARSE",
            f"rule {rule_name}: boundary_policy.by_axis.{axis} must be an object",
        )
    kind = raw.get("kind")
    if not isinstance(kind, str):
        raise RuleEngineError(
            "E_RULE_PARSE",
            f"rule {rule_name}: boundary_policy.by_axis.{axis} missing required string `kind`",
        )
    if kind not in _BOUNDARY_POLICY_KIND_VALUES:
        valid = ", ".join(_BOUNDARY_POLICY_KIND_VALUES)
        raise RuleEngineError(
            "E_RULE_PARSE",
            f"rule {rule_name}: boundary_policy.by_axis.{axis}: unknown kind `{kind}` "
            f"(closed set: {valid})",
        )
    degree = raw.get("degree")
    degree_val: Optional[int] = None
    if degree is not None:
        if not isinstance(degree, int) or isinstance(degree, bool):
            raise RuleEngineError(
                "E_RULE_PARSE",
                f"rule {rule_name}: boundary_policy.by_axis.{axis}.degree must be an integer",
            )
        if not (0 <= degree <= 3):
            raise RuleEngineError(
                "E_RULE_PARSE",
                f"rule {rule_name}: boundary_policy.by_axis.{axis}.degree must be between 0 and 3, got {degree}",
            )
        degree_val = degree
    desc = raw.get("description")
    if desc is not None and not isinstance(desc, str):
        raise RuleEngineError(
            "E_RULE_PARSE",
            f"rule {rule_name}: boundary_policy.by_axis.{axis}.description must be a string",
        )
    return BoundaryPolicySpec(
        kind=kind,
        degree=degree_val,
        description=desc,
    )


def _parse_ghost_width(
    name: str, raw: Any
) -> Union[int, Dict[str, int], None]:
    if raw is None:
        return None
    if isinstance(raw, bool):
        # Reject bool before int catches it (bool is an int subclass).
        raise RuleEngineError(
            "E_RULE_PARSE",
            f"rule {name}: `ghost_width` must be a non-negative integer or an object with a `by_axis` field",
        )
    if isinstance(raw, int):
        if raw < 0:
            raise RuleEngineError(
                "E_RULE_PARSE",
                f"rule {name}: `ghost_width` must be non-negative, got {raw}",
            )
        return raw
    if isinstance(raw, Mapping):
        by_axis_raw = raw.get("by_axis")
        if by_axis_raw is None:
            raise RuleEngineError(
                "E_RULE_PARSE",
                f"rule {name}: `ghost_width` object must have a `by_axis` field",
            )
        if not isinstance(by_axis_raw, Mapping):
            raise RuleEngineError(
                "E_RULE_PARSE",
                f"rule {name}: `ghost_width.by_axis` must be an object",
            )
        out: Dict[str, int] = {}
        for axis, w in by_axis_raw.items():
            saxis = str(axis)
            if isinstance(w, bool) or not isinstance(w, int):
                raise RuleEngineError(
                    "E_RULE_PARSE",
                    f"rule {name}: ghost_width.by_axis.{saxis} must be an integer",
                )
            if w < 0:
                raise RuleEngineError(
                    "E_RULE_PARSE",
                    f"rule {name}: ghost_width.by_axis.{saxis} must be non-negative, got {w}",
                )
            out[saxis] = w
        return out
    raise RuleEngineError(
        "E_RULE_PARSE",
        f"rule {name}: `ghost_width` must be a non-negative integer or an object with a `by_axis` field",
    )


def _parse_rule_binding(rule_name: str, binding_name: str, v: Any) -> RuleBinding:
    if not isinstance(v, Mapping):
        raise RuleEngineError(
            "E_RULE_PARSE",
            f"rule {rule_name}: bindings.{binding_name} must be an object",
        )
    kind = v.get("kind")
    if not isinstance(kind, str):
        raise RuleEngineError(
            "E_RULE_PARSE",
            f"rule {rule_name}: bindings.{binding_name} missing required string `kind`",
        )
    if kind not in _BINDING_KIND_VALUES:
        valid = ", ".join(_BINDING_KIND_VALUES)
        raise RuleEngineError(
            "E_RULE_PARSE",
            f"rule {rule_name}: bindings.{binding_name}: unknown kind `{kind}` "
            f"(closed set: {valid})",
        )
    default_raw = v.get("default")
    default_expr = None if default_raw is None else _parse_expr(default_raw)
    desc_raw = v.get("description")
    if desc_raw is not None and not isinstance(desc_raw, str):
        raise RuleEngineError(
            "E_RULE_PARSE",
            f"rule {rule_name}: bindings.{binding_name}.description must be a string",
        )
    return RuleBinding(kind=kind, default=default_expr, description=desc_raw)


def parse_rules(obj: Any) -> List[Rule]:
    """Parse the ``rules`` section of a model into an ordered list.

    Accepts either the JSON-object-keyed-by-name form or the JSON-array
    form per RFC §5.2.5.
    """
    if isinstance(obj, list):
        return [parse_rule(r) for r in obj]
    if isinstance(obj, Mapping):
        return [parse_rule(v, name=str(k)) for k, v in obj.items()]
    raise RuleEngineError(
        "E_RULE_PARSE",
        f"cannot parse rules section of type {type(obj).__name__}",
    )


# ============================================================================
# Unrewritten PDE op check (§11 Step 7)
# ============================================================================


_PDE_OPS = frozenset({"grad", "div", "laplacian", "D", "bc"})


def check_unrewritten_pde_ops(expr: Expr) -> None:
    """Scan for leftover PDE ops and raise if any are found."""
    found = _find_pde_op(expr)
    if found is not None:
        raise RuleEngineError(
            "E_UNREWRITTEN_PDE_OP",
            f"equation still contains PDE op '{found}' after rewrite; "
            f"annotate the equation with 'passthrough: true' to opt out",
        )


def _find_pde_op(e: Expr) -> Optional[str]:
    if isinstance(e, ExprNode):
        if e.op in _PDE_OPS:
            return e.op
        for a in e.args:
            r = _find_pde_op(a)
            if r is not None:
                return r
    return None
