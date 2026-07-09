"""Canonical AST form per discretization RFC §5.4.

Implements ``canonicalize(expr)`` and ``canonical_json(expr)`` such that two
ASTs are canonically equal iff their ``canonical_json`` outputs are
byte-identical.

See ``docs/rfcs/discretization.md`` §5.4.1–§5.4.7 for the normative rules.
"""

from __future__ import annotations

import math
from dataclasses import replace
from typing import Any

from .errors import EarthSciAstError
from .esm_types import Expr, ExprNode


class CanonicalizeError(EarthSciAstError):
    """Base class for canonicalization errors (RFC §5.4.6 / §5.4.7)."""

    code: str = ""


class NonFiniteError(CanonicalizeError):
    """``E_CANONICAL_NONFINITE`` — NaN or ±Inf encountered (§5.4.6)."""

    code = "E_CANONICAL_NONFINITE"

    def __init__(self, message: str = "E_CANONICAL_NONFINITE"):
        super().__init__(message)


class DivByZeroError(CanonicalizeError):
    """``E_CANONICAL_DIVBY_ZERO`` — ``/(0, 0)`` encountered (§5.4.7)."""

    code = "E_CANONICAL_DIVBY_ZERO"

    def __init__(self, message: str = "E_CANONICAL_DIVBY_ZERO"):
        super().__init__(message)


def canonicalize(expr: Expr) -> Expr:
    """Canonicalize an expression tree per RFC §5.4. Input is not mutated."""
    if isinstance(expr, bool):
        # Treat booleans as integers in JSON terms — but ESM expressions
        # don't legitimately carry booleans; surface as int for safety.
        return int(expr)
    if isinstance(expr, int):
        return expr
    if isinstance(expr, float):
        if not math.isfinite(expr):
            raise NonFiniteError()
        return expr
    if isinstance(expr, str):
        return expr
    if isinstance(expr, ExprNode):
        return _canon_op(expr)
    raise TypeError(f"unknown expression type: {type(expr).__name__}")


def canonical_json(expr: Expr) -> str:
    """Emit canonical on-wire JSON (sorted keys, no whitespace, §5.4.6 numbers)."""
    c = canonicalize(expr)
    return _emit_json(c)


def _canon_op(node: ExprNode) -> Expr:
    new_args: list[Expr] = [canonicalize(a) for a in node.args]
    work = replace(node, args=new_args)
    if work.op == "+":
        return _canon_add(work)
    if work.op == "*":
        return _canon_mul(work)
    if work.op == "-":
        return _canon_sub(work)
    if work.op == "/":
        return _canon_div(work)
    if work.op == "neg":
        return _canon_neg(work)
    return work


def _canon_add(node: ExprNode) -> Expr:
    flat = _flatten_same_op(node.args, "+")
    others, _had_int_zero, had_float_zero = _partition_identity(flat, 0)
    if had_float_zero and not _all_float_literals(others):
        others.append(0.0)
    if not others:
        return 0.0 if had_float_zero else 0
    if len(others) == 1:
        return others[0]
    _sort_args(others)
    return replace(node, op="+", args=others)


def _canon_mul(node: ExprNode) -> Expr:
    flat = _flatten_same_op(node.args, "*")
    for a in flat:
        if isinstance(a, int) and not isinstance(a, bool) and a == 0:
            return 0
        if isinstance(a, float) and a == 0.0:
            # Preserve signbit (multiplying by 0.0 does not flip sign).
            return a * 0.0
    others, _had_int_one, had_float_one = _partition_identity(flat, 1)
    if had_float_one and not _all_float_literals(others):
        others.append(1.0)
    if not others:
        return 1.0 if had_float_one else 1
    if len(others) == 1:
        return others[0]
    _sort_args(others)
    return replace(node, op="*", args=others)


def _canon_sub(node: ExprNode) -> Expr:
    if len(node.args) == 1:
        return _canon_neg_value(node.args[0])
    if len(node.args) == 2:
        a, b = node.args[0], node.args[1]
        if _is_zero_any(a):
            return _canon_neg_value(b)
        if _is_zero_any(b):
            if isinstance(b, float) and isinstance(a, int) and not isinstance(a, bool):
                return float(a)
            return a
    return node


def _canon_div(node: ExprNode) -> Expr:
    if len(node.args) != 2:
        return node
    a, b = node.args[0], node.args[1]
    if _is_zero_any(a) and _is_zero_any(b):
        raise DivByZeroError()
    if _is_one_any(b):
        if isinstance(b, float) and isinstance(a, int) and not isinstance(a, bool):
            return float(a)
        return a
    if _is_zero_any(a):
        return 0.0 if isinstance(a, float) else 0
    return node


def _canon_neg(node: ExprNode) -> Expr:
    if len(node.args) != 1:
        return node
    return _canon_neg_value(node.args[0])


def _canon_neg_value(arg: Expr) -> Expr:
    if isinstance(arg, bool):
        arg = int(arg)
    if isinstance(arg, int):
        return -arg
    if isinstance(arg, float):
        return -arg
    if isinstance(arg, ExprNode) and arg.op == "neg" and len(arg.args) == 1:
        return arg.args[0]
    return ExprNode(op="neg", args=[arg])


def _flatten_same_op(args: list[Expr], op: str) -> list[Expr]:
    out: list[Expr] = []
    for a in args:
        if isinstance(a, ExprNode) and a.op == op:
            out.extend(a.args)
        else:
            out.append(a)
    return out


def _partition_identity(args: list[Expr], identity: int):
    others: list[Expr] = []
    had_int = False
    had_float = False
    for a in args:
        if isinstance(a, bool):
            others.append(int(a))
            continue
        if isinstance(a, int) and a == identity:
            had_int = True
            continue
        if isinstance(a, float) and a == float(identity):
            had_float = True
            continue
        others.append(a)
    return others, had_int, had_float


def _all_float_literals(args: list[Expr]) -> bool:
    return bool(args) and all(isinstance(a, float) for a in args)


def _is_zero_any(e: Expr) -> bool:
    if isinstance(e, bool):
        return False
    return (isinstance(e, int) and e == 0) or (isinstance(e, float) and e == 0.0)


def _is_one_any(e: Expr) -> bool:
    if isinstance(e, bool):
        return False
    return (isinstance(e, int) and e == 1) or (isinstance(e, float) and e == 1.0)


def _arg_tier(e: Expr) -> int:
    if isinstance(e, (int, float)) and not isinstance(e, bool):
        return 0
    if isinstance(e, str):
        return 1
    if isinstance(e, ExprNode):
        return 2
    return 3


def _numeric_key(e: Expr) -> float:
    if isinstance(e, bool):
        return 0.0
    if isinstance(e, int):
        return float(e)
    if isinstance(e, float):
        return e
    return 0.0


def _sort_args(args: list[Expr]) -> None:
    # Memoize canonical JSON for non-leaf nodes (§5.4.9).
    cache: dict[int, str] = {}

    def get_json(idx: int, e: Expr) -> str:
        if idx not in cache:
            cache[idx] = _emit_json(e)
        return cache[idx]

    indices = list(range(len(args)))

    def sort_key(idx: int):
        e = args[idx]
        tier = _arg_tier(e)
        if tier == 0:
            return (tier, _numeric_key(e), isinstance(e, float))
        if tier == 1:
            return (tier, e)
        return (tier, get_json(idx, e))

    indices.sort(key=sort_key)
    snap = [args[i] for i in indices]
    for i, v in enumerate(snap):
        args[i] = v


def _emit_json(e: Expr) -> str:
    if isinstance(e, bool):
        return "true" if e else "false"
    if isinstance(e, int):
        return str(e)
    if isinstance(e, float):
        if not math.isfinite(e):
            raise NonFiniteError()
        return format_canonical_float(e)
    if isinstance(e, str):
        return _json_string(e)
    if isinstance(e, ExprNode):
        return _emit_node_json(e)
    if e is None:
        return "null"
    raise TypeError(f"cannot canonicalize value of type {type(e).__name__}")


def _emit_node_json(n: ExprNode) -> str:
    entries: list[tuple[str, str]] = []
    entries.append(("op", _json_string(n.op)))
    args_str = "[" + ",".join(_emit_json(a) for a in n.args) + "]"
    entries.append(("args", args_str))
    if n.wrt is not None:
        entries.append(("wrt", _json_string(n.wrt)))
    if n.dim is not None:
        entries.append(("dim", _json_string(n.dim)))
    if getattr(n, "fn", None) is not None:
        # `fn` carries the boundary-condition kind on synthetic `bc` nodes
        # (esm-spec §9.2). Emit it symmetrically with `dim`/`wrt` so the kind is
        # preserved in the canonical form — otherwise bc(u,dirichlet,xmin) and
        # bc(u,neumann,xmin) collapse to the same canonical JSON, making the
        # kind/side matcher's canonical equality kind-blind (ess-tox / G8).
        entries.append(("fn", _json_string(n.fn)))
    if getattr(n, "handler_id", None) is not None:
        entries.append(("handler_id", _json_string(n.handler_id)))
    if getattr(n, "name", None) is not None:
        entries.append(("name", _json_string(n.name)))
    if getattr(n, "value", None) is not None:
        entries.append(("value", _emit_value_json(n.value)))
    entries.sort(key=lambda kv: kv[0])
    body = ",".join(f"{_json_string(k)}:{v}" for k, v in entries)
    return "{" + body + "}"


def _json_string(s: str) -> str:
    # Use json.dumps for proper string escaping (ensures \uXXXX where needed).
    import json

    return json.dumps(s, ensure_ascii=False)


def _emit_value_json(v: Any) -> str:
    """Emit a `const` op `value` payload (scalar or nested-array literal).

    The `value` field carries an inline literal — a number, integer, or
    nested list thereof — that does NOT recurse through the expression
    canonicalizer (it is data, not AST). Floats are emitted via the same
    canonical-float formatter so a const-array of floats round-trips
    byte-identically across bindings.
    """
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if not math.isfinite(v):
            raise NonFiniteError()
        return format_canonical_float(v)
    if isinstance(v, str):
        return _json_string(v)
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(_emit_value_json(x) for x in v) + "]"
    if v is None:
        return "null"
    raise TypeError(f"cannot canonicalize const value of type {type(v).__name__}")


def format_canonical_float(f: float) -> str:
    """Format a finite ``float`` per RFC §5.4.6."""
    if not math.isfinite(f):
        raise NonFiniteError()
    if f == 0.0:
        return "-0.0" if math.copysign(1.0, f) < 0 else "0.0"
    abs_f = abs(f)
    use_exp = abs_f < 1e-6 or abs_f >= 1e21
    if use_exp:
        # Python's repr() picks shortest round-trip and may use exponent form
        # already; format with %e and re-normalize.
        # Get shortest round-trip mantissa and exponent.
        s = f"{f!r}"
        if "e" not in s and "E" not in s:
            # Force exponent form.
            s = f"{f:.17e}"
            s = _trim_mantissa(s)
        else:
            s = s.lower().replace("e+", "e")
        return _normalize_exponent(s)
    # Plain decimal range.
    s = f"{f!r}"
    if "e" in s or "E" in s:
        # Convert exponent form to plain decimal.
        s = _expand_to_plain(f)
    if "." not in s:
        s += ".0"
    return s


def _trim_mantissa(s: str) -> str:
    """Trim trailing zeros in the mantissa of an exponent-form string."""
    if "e" not in s and "E" not in s:
        return s
    s = s.lower()
    mant, exp = s.split("e", 1)
    if "." in mant:
        mant = mant.rstrip("0").rstrip(".")
    return f"{mant}e{exp}"


def _expand_to_plain(f: float) -> str:
    # Use Python's ``f`` format and rstrip useless zeros while preserving precision.
    # Determine number of decimals needed via repr.
    s = f"{f!r}"
    if "e" not in s.lower():
        return s
    # Use general format with high precision and strip.
    # Prefer Decimal for clean conversion.
    from decimal import Decimal

    d = Decimal(repr(f))
    txt = format(d, "f")
    # Trim trailing zeros after decimal but keep at least "X.0".
    if "." in txt:
        txt = txt.rstrip("0").rstrip(".")
    return txt


def _normalize_exponent(s: str) -> str:
    if "e" not in s:
        return s
    mant, exp = s.split("e", 1)
    if exp.startswith("+"):
        exp = exp[1:]
    sign = ""
    if exp.startswith("-"):
        sign = "-"
        exp = exp[1:]
    exp = exp.lstrip("0") or "0"
    return f"{mant}e{sign}{exp}"
