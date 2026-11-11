"""Build-time value-invention front-door (Python binding).

Port of the Julia reference ``value_invention.jl`` (bead ess-3lj.1 → ess-3lj.2);
RFC ``semiring-faq-unified-ir`` §6.1 (cadence-partition) / §5.5 (determinism) /
§7.3 (edge enumeration); ``CONFORMANCE_SPEC.md`` §5.5 / §5.7.

A ``kind:"derived"`` index set whose ``from_faq`` names a value-invention
aggregate (an ``faq`` with ``distinct:true``) is materialised here, ONCE at
setup, off the per-step hot path — the §6.1 CONST/DISCRETE materialisation
point. The aggregate's scalar integer keys are evaluated over the build-time
const-array factors and run through the :mod:`earthsci_ast.relational` engine
(``distinct``, §5.5 determinism); the distinct set's cardinality is handed to
the index-set resolver as the dense extent ``[1, n]``. The value-invention
outputs run off the per-step hot path and are dropped from the ODE.

The pass runs on the RAW JSON model document (``model["models"][name]``), not the
typed IR: the value-invention vocabulary (the aggregate ``key``, the ``distinct``
flag) lives in fields the typed ``ExprNode`` does not consume (mirrors
:mod:`earthsci_ast.cadence`, which walks raw JSON for the same reason). The
materialised members are **byte-identical** across the Julia / Rust / Python
bindings (the M3 determinism goldens) because every emitted key is an exact
integer in §5.5.1 sorted total order.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from . import broad_phase, cadence, relational
from .errors import EarthSciAstError
from .esm_types import ExprNode


class ValueInventionError(EarthSciAstError):
    """A value-invention build-time materialisation error. ``code`` is the
    diagnostic code when the error carries one (``KEY_OUT_OF_RANGE``)."""

    def __init__(self, message: str, code: str | None = None) -> None:
        super().__init__(message)
        self.code = code


#: esm-spec §9.6.6: a `distinct` key or `join` column value is NaN.
KEY_OUT_OF_RANGE = "value_invention_key_out_of_range"


# The relational body ops that mark a value-invention output (excluded from the
# ODE): mirrors Julia ``_VI_BODY_OPS``.
_VI_BODY_OPS = ("distinct",)


# --------------------------------------------------------------------------- #
# Detection — classify raw aggregate nodes (mirror of _vi_node_kind / _vi_detect)
# --------------------------------------------------------------------------- #


def _vi_node_kind(node: Any) -> str:
    """Classify a raw aggregate node's value-invention role.

    - ``"producer"`` — ``distinct:true`` (an index-set-producing aggregate;
      materialises a derived index set via ``from_faq``).
    - ``"exclude"``  — another value-invention output (a ``distinct`` body)
      dropped from the ODE but needing no setup materialisation.
    - ``"none"``     — an ordinary numeric aggregate.
    """
    if not isinstance(node, Mapping):
        return "none"
    if node.get("op") != "faq":
        return "none"
    if node.get("distinct", False) is True:
        return "producer"
    body = node.get("expr")
    if isinstance(body, Mapping) and body.get("op") in _VI_BODY_OPS:
        return "exclude"
    return "none"


def _vi_lhs_base(lhs: Any) -> str | None:
    """Base variable name written by a LHS node — the SINGLE shared definition.

    Handles all three LHS spellings so both front-doors reuse one function: a
    bare ``name`` string, a raw-JSON ``{op:index|D, args:[name,…]}`` Mapping (the
    :func:`_vi_detect` path), and the typed :class:`ExprNode` equivalent (the
    :mod:`earthsci_ast.simulation_array` simulate-build detector imports this).
    ``None`` if unrecognised."""
    if isinstance(lhs, str):
        return lhs
    if isinstance(lhs, ExprNode):
        if lhs.op in ("index", "D") and lhs.args:
            return _vi_lhs_base(lhs.args[0])
        return None
    if isinstance(lhs, Mapping):
        op = lhs.get("op")
        if op in ("index", "D"):
            args = lhs.get("args") or []
            if args:
                return _vi_lhs_base(args[0])
    return None


def _vi_scope_get(mapping: Mapping[str, Any], name: Any) -> tuple[str, Any] | None:
    """Resolve ``name`` against a possibly flattening-namespaced ``mapping``.

    An exact key wins; otherwise the UNIQUE dot-suffix (``*.name``) match at the
    shallowest namespace depth — the identical scope rule
    :func:`_vi_keyed_factor` / :func:`numpy_interpreter.ragged_factor_scope`
    already use. Returns ``(resolved_key, value)`` or ``None``.

    This lets the front-door resolve a producer join column named by its
    BARE authored name (``rg_src_bin``) against the namespaced variable and map
    registries a FLATTENED simulate build carries (``OceanDynamics.rg_src_bin``),
    while a raw per-model document (bare names throughout) always takes the
    exact-match branch — byte-identical, and only the LOOKUP is affected, never a
    computed key / member / extent."""
    if name in mapping:
        return name, mapping[name]
    suffix = "." + str(name)
    cands = [k for k in mapping if isinstance(k, str) and k.endswith(suffix)]
    if not cands:
        return None
    mindepth = min(k.count(".") for k in cands)
    best = [k for k in cands if k.count(".") == mindepth]
    if len(best) == 1:
        return best[0], mapping[best[0]]
    return None


def _vi_model_assignments(model_json: Mapping[str, Any]) -> list[tuple[Any, Any]]:
    """Every (lhs, rhs) value-expression pair in a raw model: the equation list
    plus the ``expression`` of each observed variable."""
    out: list[tuple[Any, Any]] = []
    for eq in model_json.get("equations", []) or []:
        out.append((eq.get("lhs"), eq.get("rhs")))
    for vname, v in (model_json.get("variables", {}) or {}).items():
        if isinstance(v, Mapping):
            expr = v.get("expression")
            if expr is not None:
                out.append((vname, expr))
    return out


@dataclass
class _Detection:
    has_vi: bool
    vi_var_names: set[str]
    producers: list[tuple[str, Any]]
    # Plain per-element columns a value-invention `join` reads (an integer bin
    # column such as ``src_bx[i] = floor(lon[i] / dx)``): materialised for the
    # join, but NOT value-invention outputs -- they stay ordinary observeds.
    columns: list[tuple[str, Any]] = field(default_factory=list)


def _vi_detect(model_json: Mapping[str, Any]) -> _Detection:
    """Scan a raw model for value-invention assignments. ``vi_var_names`` is the
    set of LHS variables produced by a ``distinct`` aggregate, all excluded from
    the ODE; ``producers`` are ``(lhs_base, node)`` pairs to materialise."""
    vi_var_names: set[str] = set()
    producers: list[tuple[str, Any]] = []
    candidates: list[tuple[str, Any]] = []  # plain numeric aggregates — join columns?
    for lhs, rhs in _vi_model_assignments(model_json):
        base = _vi_lhs_base(lhs)
        if base is None:
            continue
        kind = _vi_node_kind(rhs)
        if kind == "none":
            if isinstance(rhs, Mapping) and rhs.get("op") == "faq":
                candidates.append((base, rhs))
            continue
        vi_var_names.add(base)  # every value-invention output leaves the ODE
        if kind == "producer":
            producers.append((base, rhs))
    # The `join.on` key columns a producer reads: plain per-element aggregates
    # over constant factors.
    join_names: set[str] = set()
    for _, node in producers:
        _vi_join_on_names(node.get("join"), join_names)
    columns = [
        (base, node)
        for base, node in candidates
        if base in join_names and len(node.get("output_idx") or []) == 1
    ]
    return _Detection(
        has_vi=bool(producers),
        vi_var_names=vi_var_names,
        producers=producers,
        columns=columns,
    )


def _vi_join_on_names(join: Any, out: set[str]) -> None:
    """Every key-column name of a ``join``'s ``on`` clauses."""
    if not isinstance(join, (list, tuple)):
        return
    for clause in join:
        if isinstance(clause, Mapping):
            for pair in clause.get("on") or []:
                if isinstance(pair, (list, tuple)):
                    out.update(str(x) for x in pair)


# --------------------------------------------------------------------------- #
# Build-time evaluation context (mirror of _ViCtx)
# --------------------------------------------------------------------------- #


@dataclass
class _ViCtx:
    const_arrays: dict[str, np.ndarray]
    params: dict[str, float]
    index_sets: dict[str, Any]
    variables: dict[str, Any]
    # Per-const-array boundary policy (ess-gj4): array name → per-dimension policy
    # strings (each one of "periodic" | "clamp" | "error"). An array absent from
    # this map keeps the strict default ("error" in every dim), so genuine
    # out-of-bounds bugs in connectivity / stencil-weight factors stay caught.
    const_array_boundaries: dict[str, list[str]] = field(default_factory=dict)
    # materialised join column var → {output-index value → key value}
    maps: dict[str, dict[Any, Any]] = field(default_factory=dict)


def _vi_key_int(x: Any) -> int:
    """Coerce a build-time numeric to an exact integer relational key component
    (§5.5.1 rule 1: no floats in keys). A non-integral float is a misuse — fail
    loudly rather than emit a non-deterministic key."""
    if isinstance(x, bool):
        # ``bool`` is an ``int`` subclass; a boolean key component is 0/1.
        return int(x)
    if isinstance(x, (int, np.integer)):
        return int(x)
    if isinstance(x, (float, np.floating)):
        if not float(x).is_integer():
            raise ValueInventionError(
                f"value-invention key component {x!r} is not integer-valued; "
                f"relational keys must be integer / categorical IDs "
                f"(CONFORMANCE_SPEC.md §5.5.1 rule 1)"
            )
        return int(x)
    raise ValueInventionError(f"non-numeric key component {x!r}")


def _vi_param(ctx: _ViCtx, name: str) -> float:
    """Resolve a scalar parameter value (dx/dy/atol …) from overrides-or-default."""
    if name in ctx.params:
        return ctx.params[name]
    v = ctx.variables.get(name)
    if isinstance(v, Mapping):
        d = v.get("default")
        if d is not None:
            return float(d)
    raise ValueInventionError(
        f"value-invention scalar parameter {name!r} has no override or default"
    )


def _vi_eval(node: Any, ctx: _ViCtx, bindings: dict[str, Any]) -> Any:
    """Evaluate a raw value-invention sub-expression. Returns an int / float /
    bool / str, depending on the op."""
    if isinstance(node, bool):
        return node
    if isinstance(node, (int, np.integer)):
        return int(node)
    if isinstance(node, (float, np.floating)):
        return float(node)
    if isinstance(node, str):
        if node in bindings:
            return bindings[node]  # bound range symbol
        if node in ctx.const_arrays:
            return node  # bare factor name (used by index)
        v = ctx.variables.get(node)
        if isinstance(v, Mapping) and v.get("type") == "parameter":
            return _vi_param(ctx, node)  # scalar parameter
        return node  # unresolved name; a key read of it fails in `_vi_key_int`
    if isinstance(node, Mapping):
        op = node.get("op")
        args = node.get("args") or []
        if op == "index":
            return _vi_index(node, ctx, bindings)
        if op == "true":
            return True
        if op == "false":
            return False
        if op in ("floor", "ceil"):
            x = float(_vi_eval(args[0], ctx, bindings))
            r = np.floor(x) if op == "floor" else np.ceil(x)
            # A non-finite value (a NaN component of a key template) stays a float.
            return int(r) if np.isfinite(r) else float(r)
        if op == "const":
            v = node.get("value")
            if isinstance(v, (list, tuple)):
                raise ValueInventionError("an array `const` is not a value-invention scalar")
            return float(v)
        if op == "ifelse":
            c = _vi_eval(args[0], ctx, bindings)
            return _vi_eval(args[1] if _vi_truthy(c) else args[2], ctx, bindings)
        if op == "and":
            return all(_vi_truthy(_vi_eval(a, ctx, bindings)) for a in args)
        if op == "or":
            return any(_vi_truthy(_vi_eval(a, ctx, bindings)) for a in args)
        if op == "not":
            return not _vi_truthy(_vi_eval(args[0], ctx, bindings))
        if op in ("min", "max"):
            vals = [float(_vi_eval(a, ctx, bindings)) for a in args]
            # NaN propagates (esm-spec §4.2), unlike Python's built-ins.
            if any(np.isnan(v) for v in vals):
                return float("nan")
            return min(vals) if op == "min" else max(vals)
        if op == "/":
            # IEEE 754 division (matches Julia / Rust f64): x/0 → ±inf, 0/0 → nan,
            # never a ZeroDivisionError — an empty grouped denominator yields a NaN
            # centroid the caller detects, not an exception. np.float64 is the same
            # IEEE double as the other bindings, so finite results are bit-identical.
            num = float(_vi_eval(args[0], ctx, bindings))
            den = float(_vi_eval(args[1], ctx, bindings))
            with np.errstate(divide="ignore", invalid="ignore"):
                return float(np.float64(num) / np.float64(den))
        if op == "*":
            acc = 1.0
            for a in args:
                acc *= float(_vi_eval(a, ctx, bindings))
            return acc
        if op == "+":
            return sum(float(_vi_eval(a, ctx, bindings)) for a in args)
        if op == "-":
            if len(args) == 1:
                return -float(_vi_eval(args[0], ctx, bindings))
            return float(_vi_eval(args[0], ctx, bindings)) - float(_vi_eval(args[1], ctx, bindings))
        if op in ("<", ">", "<=", ">=", "==", "!="):
            a = float(_vi_eval(args[0], ctx, bindings))
            b = float(_vi_eval(args[1], ctx, bindings))
            if op == "<":
                return a < b
            if op == ">":
                return a > b
            if op == "<=":
                return a <= b
            if op == ">=":
                return a >= b
            if op == "==":
                return a == b
            return a != b
        raise ValueInventionError(
            f"value-invention build-time evaluator does not support op {op!r}"
        )
    raise ValueInventionError(f"unevaluable value-invention node {node!r}")


# Per-dimension const-array boundary policy (ess-gj4), mirror of the Julia
# reference ``_CONST_BOUNDARY_KINDS`` / ``_resolve_const_index`` in tree_walk.jl:
#   "periodic" — wrap the 1-based index into 1..n via 1-based modulo (== Julia
#                ``mod1``); correct for a periodic axis.
#   "clamp"    — edge-extend (clamp to 1..n); the correct finite policy for a
#                metric/geometry factor at a non-periodic boundary (NOT zero-ghost).
#   "error"    — raise (the default for any array WITHOUT a declared policy, so
#                genuine out-of-bounds bugs are never masked).
_CONST_BOUNDARY_KINDS = ("periodic", "clamp", "error")


def _resolve_const_index(ctx: _ViCtx, name: str, d: int, i: int, n: int) -> int:
    """Resolve a possibly-out-of-range 1-based index ``i`` in dimension ``d``
    (size ``n``) of const array ``name`` per its boundary policy, returning a
    1-based index. In-range indices pass through; an out-of-range index resolves
    via the declared per-dimension policy or raises (mirror of Julia
    ``_resolve_const_index``)."""
    if 1 <= i <= n:
        return i
    pol = "error"
    dims = ctx.const_array_boundaries.get(name)
    if dims is not None and 0 <= d < len(dims):
        pol = dims[d]
    if n >= 1:
        if pol == "periodic":
            return ((i - 1) % n) + 1  # 1-based modulo == Julia mod1(i, n)
        if pol == "clamp":
            return min(max(i, 1), n)
    raise ValueInventionError(f"const array '{name}' index {i} out of range 1..{n} in dim {d}")


def _vi_index(node: Mapping[str, Any], ctx: _ViCtx, bindings: dict[str, Any]) -> float:
    """``index(factor, i, …)``: gather from a const-array factor (1-based). The
    factor is build-time data supplied in ``const_arrays``. A name that resolves
    to an already-materialised join column is read from that buffer. For a
    genuine const-array
    factor, an out-of-range index resolves per the array's declared per-dimension
    boundary policy (ess-gj4): "periodic" wraps, "clamp" edge-extends, absent/"error"
    raises a structured :class:`ValueInventionError` (so genuine OOB connectivity
    bugs stay caught)."""
    args = node.get("args") or []
    name = args[0]
    if isinstance(name, str) and name in ctx.maps:
        if len(args) != 2:
            raise ValueInventionError(
                f"materialised value-invention buffer {name!r} is a 1-D buffer; expected one "
                f"index, got {len(args) - 1}"
            )
        idx = _vi_key_int(_vi_eval(args[1], ctx, bindings))
        buf = ctx.maps[name]
        if idx not in buf:
            raise ValueInventionError(
                f"materialised value-invention buffer {name!r} has no entry at index {idx}"
            )
        return buf[idx]
    if not isinstance(name, str) or name not in ctx.const_arrays:
        raise ValueInventionError(
            f"value-invention index target {name!r} must be a const-array factor "
            f"or an already-materialised value-invention buffer"
        )
    arr = ctx.const_arrays[name]
    zero_idx = []
    for d, a in enumerate(args[1:]):
        i = int(_vi_eval(a, ctx, bindings))  # 1-based subscript
        n = arr.shape[d]
        zero_idx.append(_resolve_const_index(ctx, name, d, i, n) - 1)
    return arr[tuple(zero_idx)]


def _vi_truthy(v: Any) -> bool:
    """A build-time condition value: a boolean, or a number > 0 (NaN is false)."""
    if isinstance(v, (bool, np.bool_)):
        return bool(v)
    return float(v) > 0


def _vi_key(node: Any, ctx: _ViCtx, bindings: dict[str, Any], column: str) -> Any:
    """A `distinct` key or `join` column value: the expression's exact integer
    (a lib/relational.esm key template, a bare range symbol or `index`,
    `floor(...)`). A NaN value -- a key template's out-of-range, non-integral or
    NaN component -- is ``value_invention_key_out_of_range`` naming ``column``
    (esm-spec §9.6.6)."""
    v = _vi_eval(node, ctx, bindings)
    if isinstance(v, (float, np.floating)) and np.isnan(v):
        where = ", ".join(f"{k}={bindings[k]}" for k in sorted(bindings))
        raise ValueInventionError(
            f"{KEY_OUT_OF_RANGE}: {column} is NaN at ({where}); a key component is out of "
            f"its declared range, non-integral or NaN",
            code=KEY_OUT_OF_RANGE,
        )
    return _vi_key_int(v)


# --------------------------------------------------------------------------- #
# Range resolution (mirror of _vi_order_syms / _vi_range_values / _vi_enumerate)
# --------------------------------------------------------------------------- #


def _vi_order_syms(ranges: Mapping[str, Any]) -> list[str]:
    """Order range symbols so a ragged range's ``of`` parents precede it (a stable
    topological order over the per-symbol ``of`` dependency)."""
    syms = list(ranges.keys())
    ordered: list[str] = []
    remaining = list(syms)
    while remaining:
        progressed = False
        for s in list(remaining):
            of = (ranges[s] or {}).get("of") or []
            if all((p in ordered) or (p not in syms) for p in of):
                ordered.append(s)
                remaining.remove(s)
                progressed = True
        if not progressed:
            raise ValueInventionError(
                f"value-invention ranges have a cyclic `of` dependency: {remaining}"
            )
    return ordered


def _vi_keyed_factor(ctx: _ViCtx, name: str) -> np.ndarray:
    """Resolve a ragged set's keyed factor (``offsets`` / ``values``, §5.4)
    against the build-time const-array registry by BARE name in the model
    scope: an exact key wins; otherwise the unique dot-suffix match at the
    shallowest namespace depth (flattening prefixes variables with their
    owning component path while the index-set registry keeps the authored
    bare name — same rule as :func:`numpy_interpreter.ragged_factor_scope` /
    the Julia tree-walk ``_factor_scope``). A genuine ambiguity (two
    candidates at the shallowest depth) or no match is a hard error."""
    fname = str(name)
    if fname in ctx.const_arrays:
        return ctx.const_arrays[fname]
    cands = [k for k in ctx.const_arrays if k.endswith("." + fname)]
    if cands:
        mindepth = min(k.count(".") for k in cands)
        best = [k for k in cands if k.count(".") == mindepth]
        if len(best) == 1:
            return ctx.const_arrays[best[0]]
        raise ValueInventionError(
            f"ragged keyed factor {fname!r} is ambiguous in the model scope: "
            f"{sorted(best)} all match at namespace depth {mindepth}"
        )
    raise ValueInventionError(
        f"ragged keyed factor {fname!r} is not bound in const_arrays "
        f"(have: {sorted(ctx.const_arrays)})"
    )


def _vi_range_values(spec: Mapping[str, Any], ctx: _ViCtx, bindings: dict[str, Any]) -> list[Any]:
    """The element values a range symbol binds to. interval/categorical → 1-based
    positions; ragged → the MEMBER values gathered from the set's ``values``
    factor sliced by its ``offsets`` factor (so a range symbol over
    ``face_vertices`` binds to the vertex IDs of the parent face, §5.2)."""
    frm = spec.get("from")
    iset = ctx.index_sets.get(frm)
    if iset is None:
        raise ValueInventionError(f"value-invention range references undeclared index set {frm!r}")
    kind = iset.get("kind")
    if kind == "interval":
        return list(range(1, int(iset["size"]) + 1))
    if kind == "categorical":
        return list(range(1, len(iset.get("members") or []) + 1))
    if kind == "ragged":
        of = spec.get("of") or []
        if not of:
            raise ValueInventionError(f"ragged value-invention range {frm!r} needs an `of` parent")
        parent = int(bindings[of[0]])
        offs = _vi_keyed_factor(ctx, iset["offsets"])
        vals = _vi_keyed_factor(ctx, iset["values"])
        nmem = int(offs[parent - 1])
        return [_vi_key_int(vals[parent - 1, m - 1]) for m in range(1, nmem + 1)]
    raise ValueInventionError(f"value-invention range over index set kind {kind!r} is unsupported")


def _vi_enumerate(ranges: Mapping[str, Any], ctx: _ViCtx, cb) -> None:
    """Enumerate every full binding of an aggregate's ``ranges``, calling
    ``cb(bindings)`` at each leaf (bindings is reused — copy if retained)."""
    syms = _vi_order_syms(ranges)
    bindings: dict[str, Any] = {}

    def rec(k: int) -> None:
        if k >= len(syms):
            cb(bindings)
            return
        s = syms[k]
        for v in _vi_range_values(ranges[s], ctx, bindings):
            bindings[s] = v
            rec(k + 1)
        bindings.pop(s, None)

    rec(0)


# --------------------------------------------------------------------------- #
# Materialisation (mirror of _vi_join_* / _vi_materialize_* )
# --------------------------------------------------------------------------- #


def _vi_join_index_sym(vname: str, producer_ranges: Mapping[str, Any], ctx: _ViCtx) -> str:
    """The index range symbol of a join-key variable within the producer's
    ranges: the producer range whose ``from`` equals the variable's (1-D) shape
    index set."""
    got = _vi_scope_get(ctx.variables, vname)
    if got is None:
        raise ValueInventionError(f"join references unknown variable {vname!r}")
    v = got[1]
    shape = v.get("shape") or []
    if len(shape) != 1:
        raise ValueInventionError(
            f"value-invention join key {vname!r} must be a 1-D buffer; shape={shape}"
        )
    target = shape[0]
    for sym, spec in producer_ranges.items():
        if (spec or {}).get("from") == target:
            return sym
    raise ValueInventionError(
        f"no producer range binds the index set {target!r} of join key {vname!r}"
    )


@dataclass
class _ViJoinGate:
    """One RESOLVED join gate (§5.3 bin-equality or §5.5.6 spatial overlap).

    Both flavours admit on a pair of range SYMBOLS; they differ only in what
    they consult. A bin-equality gate compares two materialised map buffers
    (``map_l``/``map_r``) at the bound positions. An OVERLAP gate tests
    membership of the ``(pos_l, pos_r)`` pair in a broad-phase ``candidates``
    set built ONCE per node from the const-array envelope factors — never per
    tuple, which is the whole point of the pushdown.
    """

    sym_l: str
    sym_r: str
    map_l: Mapping[Any, Any] | None = None
    map_r: Mapping[Any, Any] | None = None
    candidates: broad_phase.OverlapIndex | None = None


def _vi_overlap_spec(clause: Any) -> Mapping[str, Any] | None:
    """The ``overlap`` payload of a join clause, or ``None`` for an ``on`` clause.

    A clause is one or the other (esm-schema.json pins this with a ``oneOf``);
    a clause carrying BOTH is a malformed gate and is rejected rather than
    silently resolved by precedence.
    """
    if not isinstance(clause, Mapping):
        return None
    ov = clause.get("overlap")
    if ov is None:
        return None
    if clause.get("on") is not None:
        raise ValueInventionError(
            "a join clause is either an `on` equi-join or an `overlap` spatial gate, not both"
        )
    if not isinstance(ov, Mapping):
        raise ValueInventionError(f"join `overlap` must be an object; got {type(ov).__name__}")
    return ov


def _vi_resolve_join(
    join: Sequence[Any], producer_ranges: Mapping[str, Any], ctx: _ViCtx
) -> list[_ViJoinGate]:
    """Resolve an aggregate's ``join`` clauses into :class:`_ViJoinGate`s ONCE —
    the candidate set / buffer bindings are shared across every contracted tuple.

    An ``overlap`` clause maps ``src_env`` -> ``sym_l`` and ``tgt_env`` -> ``sym_r``
    via each factor's 1-D shape index set (:func:`_vi_join_index_sym`, exactly as
    an ``on`` key column does) and builds its candidate set from the const-array
    envelope factors (CONFORMANCE_SPEC §5.5.6).
    """
    gates: list[_ViJoinGate] = []
    for clause in join:
        ov = _vi_overlap_spec(clause)
        if ov is not None:
            src_env = list(ov.get("src_env") or [])
            tgt_env = list(ov.get("tgt_env") or [])
            if not src_env or not tgt_env:
                raise ValueInventionError(
                    "join `overlap` requires both `src_env` (query side) and `tgt_env` "
                    "(indexed side) envelope factor lists"
                )
            eps = float(ov.get("eps") or 0.0)
            if eps < 0.0:
                raise ValueInventionError(
                    f"join `overlap` eps must be >= 0 (it inflates both envelopes "
                    f"OUTWARD and so grows the candidate set monotonically); got {eps}"
                )
            sym_l = _vi_join_index_sym(str(src_env[0]), producer_ranges, ctx)
            sym_r = _vi_join_index_sym(str(tgt_env[0]), producer_ranges, ctx)
            cands = broad_phase.overlap_candidate_index(
                broad_phase.envelope_vectors(src_env, ctx.const_arrays),
                broad_phase.envelope_vectors(tgt_env, ctx.const_arrays),
                eps=eps,
            )
            gates.append(_ViJoinGate(sym_l, sym_r, candidates=cands))
            continue
        for pair in (clause.get("on") if isinstance(clause, Mapping) else None) or []:
            lname, rname = str(pair[0]), str(pair[1])
            ls = _vi_join_index_sym(lname, producer_ranges, ctx)
            rs = _vi_join_index_sym(rname, producer_ranges, ctx)
            lbuf = _vi_scope_get(ctx.maps, lname)
            rbuf = _vi_scope_get(ctx.maps, rname)
            if lbuf is None:
                raise ValueInventionError(f"join key buffer {lname!r} is not materialised")
            if rbuf is None:
                raise ValueInventionError(f"join key buffer {rname!r} is not materialised")
            gates.append(_ViJoinGate(ls, rs, map_l=lbuf[1], map_r=rbuf[1]))
    return gates


def _vi_join_ok(gates: Sequence[_ViJoinGate], bindings: Mapping[str, Any]) -> bool:
    """True iff every resolved gate admits this binding (§5.3 / §5.5.6): a
    bin-equality gate compares materialised buffer values; an overlap gate tests
    membership of the ``(pos_l, pos_r)`` range positions in the broad-phase set."""
    for g in gates:
        if g.candidates is None:
            if g.map_l[bindings[g.sym_l]] != g.map_r[bindings[g.sym_r]]:
                return False
        elif (int(bindings[g.sym_l]), int(bindings[g.sym_r])) not in g.candidates:
            return False
    return True


# Instrumentation: number of leaf bindings the enumerator VISITED (a tuple the
# callback was invoked on). Reset by callers / tests; this is what proves an
# overlap-gated walk visits O(|candidates| * PROD ungated) tuples rather than the
# full O(PROD ranges) product (projection-pushdown Wall #1).
#
# The SAME list object as :data:`broad_phase.ENUM_VISITS` — the counter is shared
# with the dense-aggregate expansion (numpy_interpreter), which is gated by the
# same policy; mirrors the Julia reference, where `_VI_ENUM_VISITS` moved into
# broad_phase.jl for exactly this reason. Aliased (not re-exported) so the
# existing `from earthsci_ast.value_invention import _VI_ENUM_VISITS` use sites
# keep reading and resetting the one counter.
_VI_ENUM_VISITS = broad_phase.ENUM_VISITS

#: The first OVERLAP gate among the resolved gates — the shared policy helper.
_vi_overlap_driver = broad_phase.overlap_driver


def _vi_enumerate_join(
    ranges: Mapping[str, Any],
    gates: Sequence[_ViJoinGate] | None,
    ctx: _ViCtx,
    cb,
) -> None:
    """Enumerate an aggregate's ``ranges``, DRIVING from an OVERLAP gate's
    prebuilt candidate pairs when one is present (§5.5.6).

    Instead of building the full product over every range and membership-testing
    each tuple — ``O(PROD ranges)``, e.g. ``O(N_query * N_cell)`` — iterate ONLY
    the gate's ``(query_pos, cell_pos)`` candidate pairs, bind the two gated range
    symbols from each pair, and take the cartesian product with any OTHER (ungated)
    ranges. Cost drops to ``O(|candidates| * PROD ungated)``.

    With NO overlap gate this is EXACTLY :func:`_vi_enumerate` — identical
    enumeration order and leaf set, so bin-equality / ungated producers are
    untouched. The callback is identical on both paths and STILL applies the
    narrow ``filter`` and the full :func:`_vi_join_ok` re-check downstream, so the
    gated leaf set differs from the full product only by provably-non-candidate
    tuples the membership test would have rejected anyway — the materialised
    member SET (after ``distinct`` canonicalises order) is identical.
    """

    def counted(bindings: dict[str, Any]) -> None:
        _VI_ENUM_VISITS[0] += 1
        cb(bindings)

    ov = broad_phase.overlap_driver(gates)
    if ov is None:
        _vi_enumerate(ranges, ctx, counted)  # full product — unchanged behaviour
        return

    # Every producer range symbol is FREE here (a producer binds nothing up
    # front), in the SAME topological order the full product visits them (ragged
    # `of` parents before children).
    syms = _vi_order_syms(ranges)
    bindings: dict[str, Any] = {}
    plan = broad_phase.overlap_drive_plan(
        ov, syms, bindings, lambda s: _vi_range_values(ranges[s], ctx, bindings)
    )
    if plan[0] == "reject":
        return
    if plan[0] == "none":
        _vi_enumerate(ranges, ctx, counted)
        return

    # The remaining ungated symbols, minus whatever the plan drives. Overlap-gated
    # symbols index a 1-D buffer (interval / categorical), so they are never ragged
    # `of` parents — pre-binding them is order-safe.
    driven = (plan[1], plan[2]) if plan[0] == "pairs" else (plan[1],)
    rest = [s for s in syms if s not in driven]

    def rec(k: int) -> None:
        if k >= len(rest):
            counted(bindings)
            return
        s = rest[k]
        for v in _vi_range_values(ranges[s], ctx, bindings):
            bindings[s] = v
            rec(k + 1)
        bindings.pop(s, None)

    if plan[0] == "pairs":
        # A candidate pair holds 1-based range POSITIONS; for an interval /
        # categorical range `_vi_range_values` binds position p to the value p, so
        # binding the two gated symbols directly reproduces exactly the tuple the
        # full product bound at those positions (and which `_vi_join_ok` admitted).
        # DETERMINISTIC (query_pos, cell_pos)-ascending drive order: the member set
        # is canonicalised downstream (`distinct` / `rank`), but a sorted drive
        # keeps any order-sensitive reduction stable.
        sym_l, sym_r = plan[1], plan[2]
        for pos_l, pos_r in plan[3]:
            bindings[sym_l] = pos_l
            bindings[sym_r] = pos_r
            rec(0)
        bindings.pop(sym_l, None)
        bindings.pop(sym_r, None)
    else:  # ("restrict", sym, vals)
        sym = plan[1]
        for v in plan[2]:
            bindings[sym] = v
            rec(0)
        bindings.pop(sym, None)


def _vi_materialize_column(ctx: _ViCtx, vname: str, node: Mapping[str, Any]) -> None:
    """Materialise a plain per-element `join` column (see ``_Detection.columns``):
    each value an exact integer, a NaN value ``value_invention_key_out_of_range``."""
    sym = str((node.get("output_idx") or [])[0])
    body = node.get("expr")
    out: dict[Any, Any] = {}

    def visit(bindings: dict[str, Any]) -> None:
        out[bindings[sym]] = _vi_key(body, ctx, bindings, f"join column {vname!r}")

    _vi_enumerate(node.get("ranges") or {}, ctx, visit)
    ctx.maps[vname] = out


def _vi_materialize_producer(ctx: _ViCtx, node: Mapping[str, Any]) -> list[Any]:
    """Materialise an index-set-producing aggregate → the distinct member set
    (§5.5 sorted total order, via the relational engine). Returns the member
    list."""
    key = node.get("key")
    if key is None:
        raise ValueInventionError("value-invention producer aggregate requires a `key` (§5.5)")
    ranges = node.get("ranges") or {}
    filt = node.get("filter")
    join = node.get("join")
    gates = _vi_resolve_join(join, ranges, ctx) if join is not None else None
    members: list[Any] = []

    def visit(bindings: dict[str, Any]) -> None:
        if filt is not None:
            fv = _vi_eval(filt, ctx, bindings)
            if not (
                fv is True or (isinstance(fv, (int, float)) and not isinstance(fv, bool) and fv > 0)
            ):
                return
        if gates is not None and not _vi_join_ok(gates, bindings):
            return
        members.append(_vi_key(key, ctx, bindings, f"the `key` of producer {node.get('id')!r}"))

    # An overlap-gated producer DRIVES enumeration from its candidate pairs
    # (§5.5.6); every other producer takes the unchanged full-product path.
    _vi_enumerate_join(ranges, gates, ctx, visit)
    return relational.distinct(members)


# --------------------------------------------------------------------------- #
# Public entrypoint
# --------------------------------------------------------------------------- #


@dataclass
class ValueInventionResult:
    """Result of :func:`materialize_value_invention`.

    - ``extents`` — ``from_faq`` producer id → derived index-set cardinality (the
      dense extent ``[1, n]`` the resolver consumes).
    - ``members`` — ``from_faq`` producer id → the distinct member keys in
      §5.5.1 sorted order (for byte-identity assertions).
    - ``vi_var_names`` — value-invention LHS vars to drop from the ODE.
    """

    extents: dict[str, int] = field(default_factory=dict)
    members: dict[str, list[Any]] = field(default_factory=dict)
    vi_var_names: set[str] = field(default_factory=set)


def materialize_value_invention(
    model_json: Mapping[str, Any],
    const_arrays: Mapping[str, Any] | None = None,
    params: Mapping[str, Any] | None = None,
    const_array_boundaries: Mapping[str, Sequence[str]] | None = None,
    index_sets: Mapping[str, Any] | None = None,
) -> ValueInventionResult:
    """Run the build-time value-invention engine over a raw model document.

    ``const_arrays`` supplies the build-time factor arrays (the connectivity /
    coordinates the keys are computed from); ``params`` supplies scalar parameter
    overrides. A producer that classifies CONTINUOUS is rejected (§5.7 guard 2).

    ``index_sets`` is the document-scoped index-set registry (RFC §5.2), which
    lives at the top level of the document rather than on each model — mirrors
    :func:`reference_resolution.build_reference_graph`. When omitted it falls
    back to a model-local ``model_json["index_sets"]`` key, so a caller need not splice the document registry
    onto the model dict before calling.

    ``const_array_boundaries`` optionally declares a per-const-array,
    per-dimension out-of-range gather policy: a mapping of array name → an
    iterable of per-dimension policy strings, each one of "periodic" | "clamp" |
    "error". A const-array gather at an out-of-range 1-based index then resolves
    declaratively ("periodic" wraps via 1-based modulo, "clamp" edge-extends);
    any array WITHOUT a declared policy (or one with "error") keeps raising a
    structured :class:`ValueInventionError`, so genuine out-of-bounds bugs in
    connectivity / stencil-weight factors stay caught.

    A no-op (empty result) for a model with no ``distinct`` producer — the
    evaluator front-door then behaves byte-identically to before.
    """
    const_arrays = const_arrays or {}
    params = params or {}
    const_array_boundaries = const_array_boundaries or {}
    # Prefer the document-scoped registry (v0.8.0); fall back to a model-local
    # ``index_sets`` key when the caller does not supply one.
    if index_sets is None:
        index_sets = model_json.get("index_sets", {}) or {}
    det = _vi_detect(model_json)
    result = ValueInventionResult(vi_var_names=set(det.vi_var_names))
    if not det.has_vi:
        return result

    ctx = _ViCtx(
        const_arrays={str(k): np.asarray(v, dtype=float) for k, v in const_arrays.items()},
        params={str(k): float(v) for k, v in params.items()},
        index_sets=dict(index_sets or {}),
        variables=dict(model_json.get("variables", {}) or {}),
        const_array_boundaries={
            str(k): [str(p) for p in v] for k, v in const_array_boundaries.items()
        },
    )

    # The plain per-element join columns a producer reads.
    for vname, node in det.columns:
        _vi_materialize_column(ctx, vname, node)

    # ``from_faq`` id → derived index-set name (so we only materialise producers a
    # derived set actually names).
    faq_to_set: dict[str, str] = {}
    for sname, iset in ctx.index_sets.items():
        if not isinstance(iset, Mapping) or iset.get("kind") != "derived":
            continue
        faq = iset.get("from_faq")
        if faq is not None:
            faq_to_set[str(faq)] = str(sname)

    for _, node in det.producers:
        node_id = node.get("id")
        if node_id is None:
            raise ValueInventionError(
                "value-invention producer aggregate requires an `id` naming it for `from_faq`"
            )
        node_id = str(node_id)
        if node_id not in faq_to_set:
            continue  # no derived set names this producer
        # §5.7 guard 2: a relational node may not run on the hot path.
        cls = cadence.classify(node, model_json)
        if cls == "continuous":
            raise ValueInventionError(
                f"value-invention producer {node_id!r} classifies CONTINUOUS — it may not "
                f"run per step (RFC §5.7 guard 2); its inputs must be CONST/DISCRETE"
            )
        mem = _vi_materialize_producer(ctx, node)
        result.members[node_id] = mem
        result.extents[node_id] = len(mem)

    return result
