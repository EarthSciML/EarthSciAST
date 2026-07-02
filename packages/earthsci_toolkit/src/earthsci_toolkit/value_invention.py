"""Build-time value-invention front-door (Python binding).

Port of the Julia reference ``value_invention.jl`` (bead ess-3lj.1 → ess-3lj.2);
RFC ``semiring-faq-unified-ir`` §6.1 (cadence-partition) / §5.5 (determinism) /
§7.3 (edge enumeration); ``CONFORMANCE_SPEC.md`` §5.5 / §5.7.

A ``kind:"derived"`` index set whose ``from_faq`` names a value-invention
aggregate (an ``aggregate`` with ``distinct:true``, or whose body / ``key`` is
``skolem`` / ``rank``) is materialised here, ONCE at setup, off the per-step hot
path — the §6.1 CONST/DISCRETE materialisation point. The aggregate's keys are
evaluated over the build-time const-array factors and run through the
:mod:`earthsci_toolkit.relational` engine (skolem / distinct, §5.5 determinism);
the distinct set's cardinality is handed to the index-set resolver as the dense
extent ``[1, n]`` — exactly as the ``intersect_polygon`` clip-ring case resolves
a derived set from its materialised ring (§8.1), now generalised to the
relational engine. The value-invention outputs run off the per-step hot path and
are dropped from the ODE.

The pass runs on the RAW JSON model document (``model["models"][name]``), not the
typed IR: the value-invention vocabulary (the aggregate ``key``, the ``distinct``
flag) lives in fields the typed ``ExprNode`` does not consume (mirrors
:mod:`earthsci_toolkit.cadence`, which walks raw JSON for the same reason). The
materialised members are **byte-identical** across the Julia / Rust / Python
bindings (the M3 determinism goldens) because every emitted key is the canonical
Skolem tuple in §5.5.1 sorted total order.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple

import numpy as np

from . import cadence
from . import relational


class ValueInventionError(Exception):
    """A value-invention build-time materialisation error (the Python analog of
    Julia's ``TreeWalkError`` value-invention codes)."""


# The relational body ops that mark a value-invention output (excluded from the
# ODE): mirrors Julia ``_VI_BODY_OPS``.
_VI_BODY_OPS = ("skolem", "rank", "distinct")

# Arg-witness reducer ops (RFC §5.7 rule 6): a build-time reduction over a
# contracted candidate range that emits the ARG — the witnessing index — rather
# than the reduced value (the nearest-generator INDEX). NET-NEW: the closed
# semiring registry returns values and value-invention (distinct/skolem/rank)
# returns sets; neither returns the arg. Materialised as an integer per-element
# buffer at CONST cadence, like the ``:map`` skolem bin buffers. Mirrors Julia
# ``_VI_ARGWITNESS_OPS``.
_VI_ARGWITNESS_OPS = ("argmin", "argmax")


# --------------------------------------------------------------------------- #
# Detection — classify raw aggregate nodes (mirror of _vi_node_kind / _vi_detect)
# --------------------------------------------------------------------------- #


def _vi_node_kind(node: Any) -> str:
    """Classify a raw aggregate node's value-invention role.

    - ``"producer"`` — ``distinct:true`` (an index-set-producing aggregate;
      materialises a derived index set via ``from_faq``).
    - ``"map"``      — a per-element map whose body / key is ``skolem`` (e.g.
      ``src_bin[i] = skolem("bin", floor(...), floor(...))``): a value-invention
      buffer the producer's ``join`` / ``key`` references. Also a per-element map
      whose body is an arg-witness reducer (``argmin`` / ``argmax``, e.g.
      ``assign[i] = argmin_g dist(point_i, gen_g)``): an integer assignment
      buffer emitted by the inner reduction (§5.7 rule 6).
    - ``"exclude"``  — another value-invention output (e.g. a ``rank`` dense-id
      buffer) dropped from the ODE but needing no setup materialisation.
    - ``"none"``     — an ordinary numeric aggregate.
    """
    if not isinstance(node, Mapping):
        return "none"
    if node.get("op") != "aggregate":
        return "none"
    if node.get("distinct", False) is True:
        return "producer"
    body = node.get("expr")
    if isinstance(body, Mapping):
        bop = body.get("op")
        if bop == "skolem" or bop in _VI_ARGWITNESS_OPS:
            return "map"
        if bop in _VI_BODY_OPS:
            return "exclude"
    key = node.get("key")
    if isinstance(key, Mapping) and key.get("op") == "skolem":
        return "map"
    return "none"


def _vi_lhs_base(lhs: Any) -> Optional[str]:
    """Base variable name written by a raw LHS node: ``name``,
    ``{op:index,args:[name,…]}`` or ``{op:D,args:[name,…]}``. ``None`` if
    unrecognised."""
    if isinstance(lhs, str):
        return lhs
    if isinstance(lhs, Mapping):
        op = lhs.get("op")
        if op in ("index", "D"):
            args = lhs.get("args") or []
            if args:
                return _vi_lhs_base(args[0])
    return None


def _vi_model_assignments(model_json: Mapping[str, Any]) -> List[Tuple[Any, Any]]:
    """Every (lhs, rhs) value-expression pair in a raw model: the equation list
    plus the ``expression`` of each observed variable."""
    out: List[Tuple[Any, Any]] = []
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
    vi_var_names: Set[str]
    maps: List[Tuple[str, Any]]
    producers: List[Tuple[str, Any]]
    # The grouped/derived chain in materialisation (fixpoint discovery) order:
    # ``(lhs_base, node, "grouped" | "derived")``.
    chain: List[Tuple[str, Any, str]]


def _vi_index_targets(node: Any, out: Set[str]) -> Set[str]:
    """Every ``index`` target name (the array a value reads from) reachable in a
    subtree: ``{op:"index", args:[NAME, …]}`` → NAME."""
    if isinstance(node, Mapping):
        if node.get("op") == "index":
            args = node.get("args") or []
            if args and isinstance(args[0], str):
                out.add(args[0])
        for v in node.values():
            _vi_index_targets(v, out)
    elif isinstance(node, (list, tuple)):
        for v in node:
            _vi_index_targets(v, out)
    return out


def _vi_grouped_key(node: Any, vi_var_names: Set[str]) -> Optional[str]:
    """The group KEY of a GROUPED reduction, or ``None``. The SCVT group-by
    signature is precise (mirror of Julia ``_vi_grouped_key``): a single-output-
    index ``aggregate`` whose ``join.on`` pairs the OUTPUT index symbol with a
    known value-invention buffer. Deliberately narrower than "any join touching a
    VI buffer" so a bin-to-bin gather (the conservative regridder's ``A_j``) is
    left on the simulate path."""
    if not isinstance(node, Mapping) or node.get("op") != "aggregate":
        return None
    oi = node.get("output_idx") or []
    if len(oi) != 1:
        return None
    gsym = oi[0]
    join = node.get("join")
    if not isinstance(join, (list, tuple)):
        return None
    for clause in join:
        if not isinstance(clause, Mapping):
            continue
        for pair in clause.get("on", []):
            if isinstance(pair, (list, tuple)) and len(pair) == 2:
                a, b = pair[0], pair[1]
                if a == gsym and b in vi_var_names:
                    return b
                if b == gsym and a in vi_var_names:
                    return a
    return None


def _vi_is_derived(node: Any, vi_var_names: Set[str]) -> bool:
    """True iff ``node`` is an elementwise DERIVED buffer over known VI buffers
    (mirror of Julia ``_vi_is_derived``): a single-output-index ``aggregate`` with
    NO join and NO contraction whose body reads an upstream VI buffer."""
    if not isinstance(node, Mapping) or node.get("op") != "aggregate":
        return False
    oi = node.get("output_idx") or []
    if len(oi) != 1:
        return False
    gsym = oi[0]
    if node.get("join") is not None:
        return False
    ranges = node.get("ranges") or {}
    if any(k != gsym for k in ranges.keys()):
        return False
    return bool(_vi_index_targets(node.get("expr"), set()) & vi_var_names)


def _vi_detect(model_json: Mapping[str, Any]) -> _Detection:
    """Scan a raw model for value-invention assignments. ``vi_var_names`` is the
    set of LHS variables produced by skolem/distinct/rank/argmin (and the
    downstream grouped chain), all excluded from the ODE as the geometry clip-ring
    vars are; ``maps`` / ``producers`` are ``(lhs_base, node)`` pairs to
    materialise; ``chain`` is the grouped/derived SCVT centroid buffers."""
    vi_var_names: Set[str] = set()
    maps: List[Tuple[str, Any]] = []
    producers: List[Tuple[str, Any]] = []
    candidates: List[Tuple[str, Any]] = []  # plain numeric aggregates — grouped/derived?
    for lhs, rhs in _vi_model_assignments(model_json):
        base = _vi_lhs_base(lhs)
        if base is None:
            continue
        kind = _vi_node_kind(rhs)
        if kind == "none":
            if isinstance(rhs, Mapping) and rhs.get("op") == "aggregate":
                candidates.append((base, rhs))
            continue
        vi_var_names.add(base)  # every value-invention output leaves the ODE
        if kind == "producer":
            producers.append((base, rhs))
        elif kind == "map":
            maps.append((base, rhs))
    # Fixpoint over the data-dependency DAG: a candidate that depends on a known VI
    # buffer in the SCVT centroid shape is itself a build-time buffer. The
    # signatures are narrow (see the helpers) so ordinary model aggregates —
    # including the regridder's bin-to-bin gather — are left on the simulate path.
    chain: List[Tuple[str, Any, str]] = []
    changed = True
    while changed:
        changed = False
        rest: List[Tuple[str, Any]] = []
        for base, node in candidates:
            if _vi_grouped_key(node, vi_var_names) is not None:
                vi_var_names.add(base)
                chain.append((base, node, "grouped"))
                changed = True
            elif _vi_is_derived(node, vi_var_names):
                vi_var_names.add(base)
                chain.append((base, node, "derived"))
                changed = True
            else:
                rest.append((base, node))
        candidates = rest
    has_vi = bool(maps) or bool(producers) or bool(chain)
    return _Detection(
        has_vi=has_vi, vi_var_names=vi_var_names, maps=maps, producers=producers, chain=chain
    )


# --------------------------------------------------------------------------- #
# Build-time evaluation context (mirror of _ViCtx)
# --------------------------------------------------------------------------- #


@dataclass
class _ViCtx:
    const_arrays: Dict[str, np.ndarray]
    params: Dict[str, float]
    index_sets: Dict[str, Any]
    variables: Dict[str, Any]
    # Per-const-array boundary policy (ess-gj4): array name → per-dimension policy
    # strings (each one of "periodic" | "clamp" | "error"). An array absent from
    # this map keeps the strict default ("error" in every dim), so genuine
    # out-of-bounds bugs in connectivity / stencil-weight factors stay caught.
    const_array_boundaries: Dict[str, List[str]] = field(default_factory=dict)
    # materialised map var → {output-index value → key value}
    maps: Dict[str, Dict[Any, Any]] = field(default_factory=dict)


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


def _vi_eval(node: Any, ctx: _ViCtx, bindings: Dict[str, Any]) -> Any:
    """Evaluate a raw value-invention sub-expression. Returns an int / float /
    bool / str tag / tuple key, depending on the op."""
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
        return node  # relation tag ("edge"/"bin"/"pair")
    if isinstance(node, Mapping):
        op = node.get("op")
        args = node.get("args") or []
        if op == "index":
            return _vi_index(node, ctx, bindings)
        if op == "skolem":
            return _vi_skolem(node, ctx, bindings)
        if op == "true":
            return True
        if op == "false":
            return False
        if op == "floor":
            return int(np.floor(float(_vi_eval(args[0], ctx, bindings))))
        if op == "ceil":
            return int(np.ceil(float(_vi_eval(args[0], ctx, bindings))))
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
    raise ValueInventionError(
        f"const array '{name}' index {i} out of range 1..{n} in dim {d}"
    )


def _vi_index(node: Mapping[str, Any], ctx: _ViCtx, bindings: Dict[str, Any]) -> float:
    """``index(factor, i, …)``: gather from a const-array factor (1-based). The
    factor is build-time data supplied in ``const_arrays``. A name that resolves
    to an already-materialised value-invention buffer (an arg-witness assignment
    or an upstream grouped/derived buffer) is read from that buffer — this is what
    lets ``centroid[g] = num[g]/den[g]`` read its inputs. For a genuine const-array
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


def _vi_skolem(node: Mapping[str, Any], ctx: _ViCtx, bindings: Dict[str, Any]) -> Any:
    """``skolem(tag?, c1, c2, …)`` → the canonical key tuple. A leading STRING
    literal is the relation tag (the relation name) and is NOT part of the
    emitted key — this is what makes the materialised set byte-identical to the
    M3 determinism golden (edges ``[[1,2],…]``, candidate pairs ``(i,j)``), which
    carry no tag. The remaining components are exact integer IDs (§5.5.1 rule 4).
    A single component degrades to a scalar key."""
    comps = [_vi_eval(a, ctx, bindings) for a in (node.get("args") or [])]
    if comps and isinstance(comps[0], str):
        comps = comps[1:]  # strip the relation tag
    key = tuple(_vi_key_int(c) for c in comps)
    if len(key) == 1:
        return key[0]
    return key


# --------------------------------------------------------------------------- #
# Range resolution (mirror of _vi_order_syms / _vi_range_values / _vi_enumerate)
# --------------------------------------------------------------------------- #


def _vi_order_syms(ranges: Mapping[str, Any]) -> List[str]:
    """Order range symbols so a ragged range's ``of`` parents precede it (a stable
    topological order over the per-symbol ``of`` dependency)."""
    syms = list(ranges.keys())
    ordered: List[str] = []
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


def _vi_range_values(spec: Mapping[str, Any], ctx: _ViCtx, bindings: Dict[str, Any]) -> List[Any]:
    """The element values a range symbol binds to. interval/categorical → 1-based
    positions; ragged → the MEMBER values gathered from the set's ``values``
    factor sliced by its ``offsets`` factor (so a range symbol over
    ``face_vertices`` binds to the vertex IDs of the parent face, §5.2)."""
    frm = spec.get("from")
    iset = ctx.index_sets.get(frm)
    if iset is None:
        raise ValueInventionError(
            f"value-invention range references undeclared index set {frm!r}"
        )
    kind = iset.get("kind")
    if kind == "interval":
        return list(range(1, int(iset["size"]) + 1))
    if kind == "categorical":
        return list(range(1, len(iset.get("members") or []) + 1))
    if kind == "ragged":
        of = spec.get("of") or []
        if not of:
            raise ValueInventionError(
                f"ragged value-invention range {frm!r} needs an `of` parent"
            )
        parent = int(bindings[of[0]])
        offs = _vi_keyed_factor(ctx, iset["offsets"])
        vals = _vi_keyed_factor(ctx, iset["values"])
        nmem = int(offs[parent - 1])
        return [_vi_key_int(vals[parent - 1, l - 1]) for l in range(1, nmem + 1)]
    raise ValueInventionError(
        f"value-invention range over index set kind {kind!r} is unsupported"
    )


def _vi_enumerate(ranges: Mapping[str, Any], ctx: _ViCtx, cb) -> None:
    """Enumerate every full binding of an aggregate's ``ranges``, calling
    ``cb(bindings)`` at each leaf (bindings is reused — copy if retained)."""
    syms = _vi_order_syms(ranges)
    bindings: Dict[str, Any] = {}

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
    v = ctx.variables.get(vname)
    if v is None:
        raise ValueInventionError(f"join references unknown variable {vname!r}")
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


def _vi_join_ok(join: Sequence[Any], producer_ranges: Mapping[str, Any],
                ctx: _ViCtx, bindings: Dict[str, Any]) -> bool:
    """True iff every ``join.on`` key-column pair compares equal at this binding
    (the value-equality equi-join gate, §5.3); each key is a materialised map
    buffer."""
    for clause in join:
        for pair in (clause.get("on") or []):
            lname, rname = pair[0], pair[1]
            ls = _vi_join_index_sym(lname, producer_ranges, ctx)
            rs = _vi_join_index_sym(rname, producer_ranges, ctx)
            lval = ctx.maps[lname][bindings[ls]]
            rval = ctx.maps[rname][bindings[rs]]
            if lval != rval:
                return False
    return True


def _vi_argreduce(node: Mapping[str, Any], ctx: _ViCtx,
                  outer_bindings: Dict[str, Any], outer_ranges: Mapping[str, Any]) -> int:
    """Arg-witness reducer (RFC §5.7 rule 6). Over the inner contracted ``ranges``
    (which EXTEND the outer map binding so ``expr`` may read both the point and
    the candidate), evaluate the scalar ``expr`` body at each candidate and return
    the ``arg`` index symbol's value at the optimum — ``argmin`` keeps the least
    value, ``argmax`` the greatest. The NORMATIVE tie-break is the SMALLEST arg
    (the smallest generator id): equal values resolve to the lower candidate
    index, so the emitted integer buffer is byte-identical across bindings
    irrespective of enumeration order. Optional ``join`` (a bin-Skolem prune,
    §5.3) / ``filter`` restrict the candidate set; an empty candidate set is an
    error (no index witnesses an empty argmin)."""
    op = node.get("op")
    inner_ranges = node.get("ranges") or {}
    arg_sym = node.get("arg")
    if arg_sym is None:
        raise ValueInventionError(
            f"arg-witness op {op!r} requires an `arg` naming the witnessing index symbol"
        )
    arg_sym = str(arg_sym)
    value_expr = node.get("expr")
    if value_expr is None:
        raise ValueInventionError(
            f"arg-witness op {op!r} requires an `expr` body (the scalar to optimise)"
        )
    if arg_sym not in inner_ranges:
        raise ValueInventionError(
            f"arg-witness `arg`={arg_sym!r} must name one of the contracted `ranges` symbols"
        )
    if arg_sym in outer_bindings:
        raise ValueInventionError(
            f"arg-witness `arg`={arg_sym!r} shadows an outer index symbol"
        )
    filt = node.get("filter")
    join = node.get("join")
    # Combined ranges so a ``join`` column over an OUTER-indexed map buffer (the
    # point's bin) resolves alongside the inner candidate's bin (§5.3 equi-join).
    combined: Dict[str, Any] = {**outer_ranges, **inner_ranges}
    syms = _vi_order_syms(inner_ranges)
    bindings: Dict[str, Any] = dict(outer_bindings)
    is_max = op == "argmax"
    best: Optional[Tuple[float, int]] = None

    def consider() -> None:
        nonlocal best
        if filt is not None:
            fv = _vi_eval(filt, ctx, bindings)
            if not (fv is True or (isinstance(fv, (int, float)) and not isinstance(fv, bool) and fv > 0)):
                return
        if join is not None and not _vi_join_ok(join, combined, ctx, bindings):
            return
        v = float(_vi_eval(value_expr, ctx, bindings))
        a = _vi_key_int(bindings[arg_sym])
        if best is None:
            best = (v, a)
        else:
            bv, ba = best
            better = v > bv if is_max else v < bv
            # Strict improvement OR an exact tie resolved to the smaller arg.
            if better or (v == bv and a < ba):
                best = (v, a)

    def rec(k: int) -> None:
        if k >= len(syms):
            consider()
            return
        s = syms[k]
        for val in _vi_range_values(inner_ranges[s], ctx, bindings):
            bindings[s] = val
            rec(k + 1)
        bindings.pop(s, None)

    rec(0)
    if best is None:
        raise ValueInventionError(
            f"arg-witness op {op!r} has an empty candidate set; no index witnesses the "
            f"optimum (a point with no candidate generator is undefined)"
        )
    return best[1]


def _vi_materialize_map(ctx: _ViCtx, vname: str, node: Mapping[str, Any]) -> Dict[Any, Any]:
    """Materialise a per-element value-invention map var → {output-index → value}."""
    output_idx = node.get("output_idx") or []
    if len(output_idx) != 1:
        raise ValueInventionError(
            f"value-invention map {vname!r} must have a single output index; got {output_idx}"
        )
    body = node.get("expr")
    if body is None:
        raise ValueInventionError(f"value-invention map {vname!r} has no `expr` body")
    outer_ranges = node.get("ranges") or {}
    is_arg = isinstance(body, Mapping) and body.get("op") in _VI_ARGWITNESS_OPS
    out: Dict[Any, Any] = {}
    sym = str(output_idx[0])

    def visit(bindings: Dict[str, Any]) -> None:
        # An arg-witness body runs the inner reduction (with the outer point bound)
        # and emits the witnessing INDEX; an ordinary body (skolem) emits its value.
        out[bindings[sym]] = (
            _vi_argreduce(body, ctx, bindings, outer_ranges) if is_arg
            else _vi_eval(body, ctx, bindings)
        )

    _vi_enumerate(outer_ranges, ctx, visit)
    ctx.maps[vname] = out
    return out


def _vi_materialize_producer(ctx: _ViCtx, node: Mapping[str, Any]) -> List[Any]:
    """Materialise an index-set-producing aggregate → the distinct member set
    (§5.5 sorted total order, via the relational engine). Returns the member
    list."""
    key = node.get("key")
    if key is None:
        raise ValueInventionError(
            "value-invention producer aggregate requires a `key` (§5.5)"
        )
    ranges = node.get("ranges") or {}
    filt = node.get("filter")
    join = node.get("join")
    members: List[Any] = []

    def visit(bindings: Dict[str, Any]) -> None:
        if filt is not None:
            fv = _vi_eval(filt, ctx, bindings)
            if not (fv is True or (isinstance(fv, (int, float)) and not isinstance(fv, bool) and fv > 0)):
                return
        if join is not None and not _vi_join_ok(join, ranges, ctx, bindings):
            return
        members.append(_vi_skolem(key, ctx, bindings))

    _vi_enumerate(ranges, ctx, visit)
    return relational.distinct(members)


# --------------------------------------------------------------------------- #
# Grouped / derived build-time buffers (the SCVT centroid step)
# --------------------------------------------------------------------------- #

_VI_OPLUS_FUNS = {"+": lambda a, b: a + b, "*": lambda a, b: a * b, "max": max, "min": min}
_VI_SEMIRING_OPLUS = {
    "sum_product": ("+", 0.0),
    "max_product": ("max", float("-inf")),
    "min_sum": ("min", float("inf")),
    "max_sum": ("max", float("-inf")),
    "bool_and_or": ("or", 0.0),
}
_VI_REDUCE_IDENTITY = {"+": 0.0, "*": 1.0, "max": float("-inf"), "min": float("inf")}


def _vi_oplus(node: Mapping[str, Any]):
    """The ``(⊕ function, 0̄ identity)`` for a grouped semiring aggregate.
    ``bool_and_or`` (⊕=``or``) is index-set-producing, not a numeric grouped
    reduction (mirrors the array path's §5.5 reject), so only the four numeric ⊕s
    are accepted. ``semiring`` (if present) supersedes ``reduce``."""
    semiring = node.get("semiring")
    if semiring is not None:
        sr = _VI_SEMIRING_OPLUS.get(semiring)
        if sr is None:
            raise ValueInventionError(
                f"unknown semiring {semiring!r}; the closed registry is "
                f"{sorted(_VI_SEMIRING_OPLUS)}"
            )
        spelling, zerobar = sr
    else:
        spelling = node.get("reduce") or "+"
        if spelling not in _VI_REDUCE_IDENTITY:
            raise ValueInventionError(
                f"unsupported reduce={spelling!r}; expected +, *, max, min (or set `semiring`)"
            )
        zerobar = _VI_REDUCE_IDENTITY[spelling]
    op = _VI_OPLUS_FUNS.get(spelling)
    if op is None:
        raise ValueInventionError(
            f"grouped value-invention reduction ⊕={spelling!r} is unsupported; expected one of "
            f"+, *, max, min (a numeric semiring — not the index-set-producing bool_and_or)"
        )
    return op, zerobar


def _vi_assert_buildtime(ctx: _ViCtx, vname: str, node: Mapping[str, Any],
                         vi_var_names: Set[str]) -> None:
    """§5.7 guard 2 for grouped / derived buffers: a build-time reduction may read
    only build-time data — const-array factors and already-materialised VI
    buffers. Reading a live ODE ``state`` variable would make it a per-step
    quantity, out of scope for v1 (the Lloyd/SCVT outer loop re-invokes the
    build)."""
    for r in _vi_index_targets(node, set()):
        if r in vi_var_names or r in ctx.const_arrays:
            continue
        v = ctx.variables.get(r)
        if isinstance(v, Mapping) and v.get("type") == "state":
            raise ValueInventionError(
                f"grouped/derived value-invention buffer {vname!r} reads live state {r!r} — a "
                f"build-time reduction's inputs must be CONST/DISCRETE factors or materialised "
                f"buffers (RFC §5.7 guard 2)"
            )


def _vi_materialize_grouped(ctx: _ViCtx, vname: str, node: Mapping[str, Any]) -> Dict[Any, Any]:
    """Materialise a GROUPED semiring aggregate keyed on a value-invention buffer
    → ``{output-index → value}``. For each output ``g``, fold (with the semiring
    ⊕) the body over the contracted points whose group KEY (``assign[p]``) equals
    ``g``. The reduction runs through the determinism-correct
    :func:`relational.group_aggregate` (§5.5 rule 5) — the first time the
    front-door calls it (a library helper only). Empty groups fold to 0̄."""
    output_idx = node.get("output_idx") or []
    if len(output_idx) != 1:
        raise ValueInventionError(
            f"grouped value-invention aggregate {vname!r} must have a single output index; "
            f"got {output_idx}"
        )
    gsym = str(output_idx[0])
    ranges = node.get("ranges") or {}
    if gsym not in ranges:
        raise ValueInventionError(
            f"grouped aggregate {vname!r} output index {gsym!r} is not among its ranges"
        )
    body = node.get("expr")
    if body is None:
        raise ValueInventionError(f"grouped aggregate {vname!r} has no `expr` body")
    join = node.get("join")
    if join is None:
        raise ValueInventionError(
            f"grouped aggregate {vname!r} needs a `join` pairing its group-key buffer with {gsym!r}"
        )
    # The group KEY buffer: the join column paired with the output index that names
    # a materialised VI buffer (`assign`).
    keyvar: Optional[str] = None
    for clause in join:
        if not isinstance(clause, Mapping):
            continue
        for pair in clause.get("on", []):
            if isinstance(pair, (list, tuple)) and len(pair) == 2:
                a, b = pair[0], pair[1]
                if b == gsym and a in ctx.maps:
                    keyvar = a
                if a == gsym and b in ctx.maps:
                    keyvar = b
    if keyvar is None:
        raise ValueInventionError(
            f"grouped aggregate {vname!r} `join.on` must pair a materialised value-invention "
            f"buffer with the output index {gsym!r}"
        )
    keysym = _vi_join_index_sym(keyvar, ranges, ctx)
    op, zerobar = _vi_oplus(node)
    contract = {s: spec for s, spec in ranges.items() if s != gsym}
    rows: List[Tuple[int, float]] = []

    def visit(bindings: Dict[str, Any]) -> None:
        k = _vi_key_int(ctx.maps[keyvar][bindings[keysym]])
        rows.append((k, float(_vi_eval(body, ctx, bindings))))

    _vi_enumerate(contract, ctx, visit)
    agg = dict(relational.group_aggregate(rows, key=lambda r: r[0], value=lambda r: r[1], op=op))
    # Densify over the output index set; a generator with no assigned point is 0̄.
    out: Dict[Any, Any] = {}
    for g in _vi_range_values(ranges[gsym], ctx, {}):
        out[g] = float(agg.get(g, zerobar))
    ctx.maps[vname] = out
    return out


def _vi_materialize_derived(ctx: _ViCtx, vname: str, node: Mapping[str, Any]) -> Dict[Any, Any]:
    """Materialise a DERIVED elementwise buffer (``centroid[g] = num[g]/den[g]``)
    → ``{output-index → value}``. A per-output map whose body reads upstream
    materialised buffers (resolved by :func:`_vi_index` from ``ctx.maps``)."""
    output_idx = node.get("output_idx") or []
    if len(output_idx) != 1:
        raise ValueInventionError(
            f"derived value-invention aggregate {vname!r} must have a single output index; "
            f"got {output_idx}"
        )
    gsym = str(output_idx[0])
    ranges = node.get("ranges") or {}
    body = node.get("expr")
    if body is None:
        raise ValueInventionError(f"derived value-invention aggregate {vname!r} has no `expr` body")
    out: Dict[Any, Any] = {}

    def visit(bindings: Dict[str, Any]) -> None:
        out[bindings[gsym]] = float(_vi_eval(body, ctx, bindings))

    _vi_enumerate(ranges, ctx, visit)
    ctx.maps[vname] = out
    return out


def _vi_classification_model(model_json: Mapping[str, Any],
                             maps: Sequence[Tuple[str, Any]]) -> Mapping[str, Any]:
    """A model copy whose value-invention MAP vars are re-typed to their body's
    cadence class (``const``→parameter, ``discrete``→discrete), so a producer
    joining on a map buffer classifies by the buffer's true (input-derived)
    cadence rather than the seed of its declared ``state`` kind (§6.1). A
    ``continuous`` body is left unchanged so the §5.7 guard still rejects
    state-dependent topology."""
    if not maps:
        return model_json
    variables = dict(model_json.get("variables", {}) or {})
    for vname, node in maps:
        if vname not in variables:
            continue
        body = node.get("expr")
        if body is None:
            continue
        bcls = cadence.classify(body, model_json)
        newtype = "parameter" if bcls == "const" else ("discrete" if bcls == "discrete" else None)
        if newtype is None:
            continue
        v = dict(variables[vname])
        v["type"] = newtype
        variables[vname] = v
    out = dict(model_json)
    out["variables"] = variables
    return out


# --------------------------------------------------------------------------- #
# Public entrypoint
# --------------------------------------------------------------------------- #


@dataclass
class ValueInventionResult:
    """Result of :func:`materialize_value_invention`.

    - ``extents`` — ``from_faq`` producer id → derived index-set cardinality (the
      dense extent ``[1, n]`` the resolver consumes).
    - ``members`` — ``from_faq`` producer id → the distinct member tuples in
      §5.5.1 sorted order (for byte-identity assertions).
    - ``assignments`` — arg-witness map var → the integer nearest-generator INDEX
      buffer, dense in output-index order (the SCVT assignment; §5.7 rule 6,
      byte-identical across bindings).
    - ``groups`` — the downstream GROUPED / DERIVED buffers keyed on an arg-witness
      assignment, dense in output-index order: a grouped semiring reduction
      (``num[g] = Σ_{p:assign=g} rho_p·x_p``, run through
      :func:`relational.group_aggregate`, §5.5 rule 5) and an elementwise derived
      buffer (``centroid[g] = num[g]/den[g]``) — the SCVT centroid-update step.
    - ``vi_var_names`` — value-invention LHS vars to drop from the ODE.
    """

    extents: Dict[str, int] = field(default_factory=dict)
    members: Dict[str, List[Any]] = field(default_factory=dict)
    assignments: Dict[str, List[int]] = field(default_factory=dict)
    groups: Dict[str, List[float]] = field(default_factory=dict)
    vi_var_names: Set[str] = field(default_factory=set)


def materialize_value_invention(
    model_json: Mapping[str, Any],
    const_arrays: Optional[Mapping[str, Any]] = None,
    params: Optional[Mapping[str, Any]] = None,
    const_array_boundaries: Optional[Mapping[str, Sequence[str]]] = None,
) -> ValueInventionResult:
    """Run the build-time value-invention engine over a raw model document.

    ``const_arrays`` supplies the build-time factor arrays (the connectivity /
    coordinates the keys are computed from); ``params`` supplies scalar parameter
    overrides. A producer that classifies CONTINUOUS is rejected (§5.7 guard 2).

    ``const_array_boundaries`` (ess-gj4) optionally declares a per-const-array,
    per-dimension out-of-range gather policy: a mapping of array name → an
    iterable of per-dimension policy strings, each one of "periodic" | "clamp" |
    "error". A const-array gather at an out-of-range 1-based index then resolves
    declaratively ("periodic" wraps via 1-based modulo, "clamp" edge-extends);
    any array WITHOUT a declared policy (or one with "error") keeps raising a
    structured :class:`ValueInventionError`, so genuine out-of-bounds bugs in
    connectivity / stencil-weight factors stay caught.

    A no-op (empty result) for a model with no skolem/distinct/rank node — the
    evaluator front-door then behaves byte-identically to before.
    """
    const_arrays = const_arrays or {}
    params = params or {}
    const_array_boundaries = const_array_boundaries or {}
    det = _vi_detect(model_json)
    result = ValueInventionResult(vi_var_names=set(det.vi_var_names))
    if not det.has_vi:
        return result

    ctx = _ViCtx(
        const_arrays={str(k): np.asarray(v, dtype=float) for k, v in const_arrays.items()},
        params={str(k): float(v) for k, v in params.items()},
        index_sets=dict(model_json.get("index_sets", {}) or {}),
        variables=dict(model_json.get("variables", {}) or {}),
        const_array_boundaries={
            str(k): [str(p) for p in v] for k, v in const_array_boundaries.items()
        },
    )

    # Cadence classification model (built before materialisation — it depends only
    # on model structure, not materialized values): re-type each map var to its
    # body's class so the §5.7 guard 2 classifies a producer / arg-witness that
    # joins on it correctly (a CONST-derived bin map passes; a genuinely
    # state-dependent one still classifies CONTINUOUS → reject).
    cls_model = _vi_classification_model(model_json, det.maps)

    # §5.7 guard 2 for arg-witness assignments: a state-dependent nearest-generator
    # buffer (continuous cadence) may not be materialised at build time — its
    # topology would change every step (out of scope for v1, like a continuous
    # `distinct`).
    for vname, node in det.maps:
        body = node.get("expr")
        if not (isinstance(body, Mapping) and body.get("op") in _VI_ARGWITNESS_OPS):
            continue
        if cadence.classify(node, cls_model) == "continuous":
            raise ValueInventionError(
                f"arg-witness map {vname!r} classifies CONTINUOUS — a build-time assignment "
                f"buffer's inputs must be CONST/DISCRETE (RFC §5.7 guard 2)"
            )

    # Maps first (a producer's join / key — or an arg-witness `join` — may reference them).
    for vname, node in det.maps:
        _vi_materialize_map(ctx, vname, node)

    # Surface the arg-witness buffers (the integer nearest-generator INDEX
    # assignment), dense in output-index order, for byte-identity assertions and
    # the downstream grouped reduction the SCVT step consumes.
    for vname, node in det.maps:
        body = node.get("expr")
        if not (isinstance(body, Mapping) and body.get("op") in _VI_ARGWITNESS_OPS):
            continue
        m = ctx.maps[vname]
        result.assignments[vname] = [int(m[k]) for k in sorted(m.keys())]

    # The downstream GROUPED / DERIVED chain — the SCVT centroid step. Each buffer
    # is materialised in dependency (fixpoint discovery) order: a grouped semiring
    # reduction keyed on a now-materialised arg-witness buffer (``num[g]``/``den[g]``,
    # through ``relational.group_aggregate`` — the front-door's first call of that
    # previously library-only helper) and an elementwise derived buffer reading
    # upstream buffers (``centroid[g] = num[g]/den[g]``). Each reads only build-time
    # data (guard 2). All are surfaced dense in output-index order.
    for vname, node, kind in det.chain:
        _vi_assert_buildtime(ctx, vname, node, det.vi_var_names)
        if kind == "grouped":
            _vi_materialize_grouped(ctx, vname, node)
        else:
            _vi_materialize_derived(ctx, vname, node)
        m = ctx.maps[vname]
        result.groups[vname] = [float(m[k]) for k in sorted(m.keys())]

    # ``from_faq`` id → derived index-set name (so we only materialise producers a
    # derived set actually names; geometry producers are handled elsewhere).
    faq_to_set: Dict[str, str] = {}
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
        cls = cadence.classify(node, cls_model)
        if cls == "continuous":
            raise ValueInventionError(
                f"value-invention producer {node_id!r} classifies CONTINUOUS — it may not "
                f"run per step (RFC §5.7 guard 2); its inputs must be CONST/DISCRETE"
            )
        mem = _vi_materialize_producer(ctx, node)
        result.members[node_id] = mem
        result.extents[node_id] = len(mem)

    return result
