"""Box-specialized source codegen for arrayop bodies (the Tier-1 codegen tier).

The compiled-closure tier (:func:`numpy_interpreter._compile_expr`) still pays,
on EVERY evaluation, for work that is a pure function of the node and its
static index box: one Python closure frame per AST node, a
:func:`_resolve_symbol` lookup per symbol OCCURRENCE, and — inside every
``index`` gather — the subscript arithmetic over the bound ranges plus the
float→intp conversion of the resulting index arrays. This module removes all
three for the whole-box vectorized paths by generating, ONCE per (node, box), a
flat Python function whose lines perform the numpy operations of the closure
tree in the identical order:

* the box's index symbols are baked in as the SAME broadcast arrays
  ``_bound_index_box`` binds, so every subexpression built purely from them
  (subscript arithmetic above all) is CONSTANT-FOLDED at codegen time — by
  evaluating the same compiled closure once — and an ``index`` gather over
  folded subscripts precomputes its 0-based intp index tuple outright
  (:func:`_gather_hoisted`);
* each remaining (state-dependent) node becomes one generated line calling the
  very same ``_apply_*`` kernel / :func:`_gather_index` the closure tier calls
  (plain ``+``/``-``/``*``/``**`` chains are inlined — those helpers ARE the
  left-associated operator chains), so the numerics are bit-for-bit identical;
* a bare symbol resolves through :func:`_resolve_symbol` once per evaluation
  instead of once per occurrence. That is safe because ``ctx`` cannot change
  between the lines of one body evaluation — every construct that binds
  ``ctx.locals`` restores it — EXCEPT across a delegated ``eval_expr`` line
  (a geometry leaf may register a derived ring), so the occurrence-cache is
  invalidated at every delegation.

Anything the emitter does not lower — an op outside ``_COMPILED_OPS``, a
wrong-arity node — becomes a delegated ``eval_expr(node, ctx)`` line, exactly
like the closure tier's ``_compile_delegate``. Any failure ANYWHERE at codegen
time (including a constant subtree that raises) declines the WHOLE body:
:func:`compile_box_body` returns ``None`` and the caller falls back to the
compiled closure, which reproduces today's behaviour — including the error —
at evaluation time.

Kill switch (oracle): ``ESS_NP_CODEGEN_DISABLE=1`` routes every body back to
the compiled-closure tier (checked at the call sites in
:mod:`numpy_interpreter`), so the two tiers can be diffed bitwise on any model.
"""

from __future__ import annotations

from typing import Any, Callable

import numpy as np

from .esm_types import ExprNode
from .numpy_interpreter import (
    _CMP_UFUNCS,
    _COMPILED_OPS,
    _SCALAR_FUNCS,
    EvalContext,
    NumpyInterpreterError,
    _apply_atan2,
    _apply_bool_reduce,
    _apply_cmp,
    _apply_div,
    _apply_ifelse,
    _apply_minmax,
    _apply_not,
    _compile_expr,
    _gather_index,
    _resolve_symbol,
    eval_expr,
)

#: Safety cap on generated statements per body; over it the body declines to
#: the closure tier (no semantic difference — codegen is purely an optimization).
_MAX_LINES = 20000


def _gather_hoisted(arr_val: Any, zi: tuple[np.ndarray, ...]) -> np.ndarray:
    """The vectorized branch of :func:`_gather_index` with the 0-based intp
    index tuple ``zi`` precomputed at codegen time (every subscript was
    constant-folded, and at least one is an ndarray). Identical values and
    identical errors: ``zi`` was produced by the same rint → intp → −1
    conversion the per-call branch performs."""
    if not isinstance(arr_val, np.ndarray):
        # _gather_index's scalar branch with a non-empty subscript list.
        raise NumpyInterpreterError("index applied to scalar value")
    if len(zi) != arr_val.ndim:
        raise NumpyInterpreterError(
            f"index got {len(zi)} indices for array of shape {arr_val.shape}"
        )
    return arr_val[zi]


#: Names every generated function body may reference. Copied per function (the
#: constants join the copy), so one body's constants never leak into another's.
_BASE_NS: dict[str, Any] = {
    "np": np,
    "eval_expr": eval_expr,
    "_resolve_symbol": _resolve_symbol,
    "_gather_index": _gather_index,
    "_gather_hoisted": _gather_hoisted,
    "_apply_div": _apply_div,
    "_apply_atan2": _apply_atan2,
    "_apply_cmp": _apply_cmp,
    "_apply_bool_reduce": _apply_bool_reduce,
    "_apply_not": _apply_not,
    "_apply_minmax": _apply_minmax,
    "_apply_ifelse": _apply_ifelse,
}


class _Decline(Exception):
    """Internal: abort codegen; the caller falls back to the closure tier."""


class _Emitter:
    """One body's code emission state: the generated lines, the exec namespace
    (helpers + interned constants + delegated nodes), the per-symbol occurrence
    cache, and the fold context whose ``locals`` are the baked box bindings."""

    def __init__(self, env: dict[str, np.ndarray]) -> None:
        self.env = env
        self.lines: list[str] = []
        self.ns: dict[str, Any] = dict(_BASE_NS)
        self.n = 0
        self.sym_vars: dict[str, str] = {}
        self.const_names: dict[int, str] = {}
        self.static_memo: dict[int, bool] = {}
        # Constant folding evaluates the SAME compiled closures the interpreter
        # runs, once, against a context whose only content is the box binding —
        # a static subtree by construction touches nothing else.
        self.fold_ctx = EvalContext(
            state_layout={},
            state_shapes={},
            param_values={},
            observed_values={},
            y=np.empty(0),
            t=0.0,
            locals=dict(env),
        )

    def fresh(self, prefix: str) -> str:
        self.n += 1
        return f"{prefix}{self.n}"

    def intern(self, value: Any) -> str:
        """Bind ``value`` into the namespace under a stable name (per object)."""
        name = self.const_names.get(id(value))
        if name is None:
            name = self.fresh("c")
            self.ns[name] = value
            self.const_names[id(value)] = name
        return name

    def line(self, text: str) -> None:
        if len(self.lines) >= _MAX_LINES:
            raise _Decline
        self.lines.append(text)

    def ref(self, part: tuple[str, Any]) -> str:
        kind, v = part
        return v if kind == "dyn" else self.intern(v)

    def is_static(self, expr: Any) -> bool:
        """True iff ``expr`` is a pure function of the baked box bindings — a
        literal, a box symbol, or a lowerable op over static children — so its
        value is the same on every evaluation and may be folded once."""
        if isinstance(expr, str):
            return expr in self.env
        if isinstance(expr, (bool, int, float)):
            return True
        if not isinstance(expr, ExprNode):
            return False
        got = self.static_memo.get(id(expr))
        if got is not None:
            return got
        ok = expr.op in _COMPILED_OPS and all(self.is_static(a) for a in (expr.args or []))
        self.static_memo[id(expr)] = ok
        return ok

    def delegate(self, node: Any) -> str:
        var = self.fresh("d")
        self.line(f"{var} = eval_expr({self.intern(node)}, ctx)")
        # eval_expr may register state on ctx that a bare symbol resolves
        # through (a geometry leaf's derived ring), so the per-symbol
        # occurrence cache must not cross a delegated line.
        self.sym_vars.clear()
        return var

    def emit(self, expr: Any) -> tuple[str, Any]:
        """Emit code evaluating ``expr``; returns ``("const", value)`` for a
        folded subtree or ``("dyn", varname)`` for an emitted line. Child
        emission order is the closure tier's evaluation order (depth-first,
        left-to-right), so delegated side effects interleave identically."""
        if isinstance(expr, str):
            v = self.env.get(expr)
            if v is not None:
                return ("const", v)
            var = self.sym_vars.get(expr)
            if var is None:
                var = self.fresh("s")
                self.line(f"{var} = _resolve_symbol({expr!r}, ctx)")
                self.sym_vars[expr] = var
            return ("dyn", var)
        if isinstance(expr, bool):
            return ("const", float(expr))
        if isinstance(expr, (int, float)):
            return ("const", float(expr))
        if not isinstance(expr, ExprNode):
            # Unknown leaf: the closure tier delegates it so eval_expr raises
            # its error; reproduce that per call.
            return ("dyn", self.delegate(expr))
        if self.is_static(expr):
            # Fold by running the identical compiled closure once. A raise here
            # propagates to compile_box_body's decline, and the closure-tier
            # fallback then raises the identical error per call.
            return ("const", _compile_expr(expr)(self.fold_ctx))
        op = expr.op
        if op not in _COMPILED_OPS:
            return ("dyn", self.delegate(expr))
        args = expr.args or []

        # Every branch below mirrors the corresponding _build_compiled_node
        # branch; wrong-arity nodes delegate so eval_expr raises the identical
        # error. All-static nodes were folded above, so at least one child of
        # each emitted node is dynamic.
        if op == "index":
            if not args:
                return ("dyn", self.delegate(expr))
            arr = self.emit(args[0])
            subs = [self.emit(a) for a in args[1:]]
            var = self.fresh("t")
            if not subs:
                self.line(f"{var} = _gather_index({self.ref(arr)}, [])")
            elif all(k == "const" for k, _ in subs):
                vals = [v for _, v in subs]
                if any(isinstance(x, np.ndarray) for x in vals):
                    # Hoist the vectorized branch's conversion: the same
                    # rint → intp → in-place −1 _gather_index performs, once.
                    zi = []
                    for i in vals:
                        if not (isinstance(i, np.ndarray) and i.dtype == np.float64):
                            i = np.asarray(i, dtype=float)
                        z = np.rint(i).astype(np.intp)
                        z -= 1
                        zi.append(z)
                    self.line(f"{var} = _gather_hoisted({self.ref(arr)}, {self.intern(tuple(zi))})")
                else:
                    # All-scalar constant subscripts: the scalar branch (with
                    # its partial-index semantics) is cheap; keep it verbatim.
                    self.line(f"{var} = _gather_index({self.ref(arr)}, {self.intern(list(vals))})")
            else:
                items = ", ".join(self.ref(p) for p in subs)
                self.line(f"{var} = _gather_index({self.ref(arr)}, [{items}])")
            return ("dyn", var)

        if op in _SCALAR_FUNCS:
            if len(args) != 1:
                return ("dyn", self.delegate(expr))
            a = self.emit(args[0])
            var = self.fresh("t")
            self.line(f"{var} = {self.intern(_SCALAR_FUNCS[op])}({self.ref(a)})")
            return ("dyn", var)

        if op in _CMP_UFUNCS:
            if len(args) != 2:
                return ("dyn", self.delegate(expr))
            a = self.emit(args[0])
            b = self.emit(args[1])
            var = self.fresh("t")
            self.line(
                f"{var} = _apply_cmp({self.ref(a)}, {self.ref(b)}, {self.intern(_CMP_UFUNCS[op])})"
            )
            return ("dyn", var)

        if op in ("+", "*"):
            parts = [self.emit(a) for a in args]
            var = self.fresh("t")
            joiner = " + " if op == "+" else " * "
            self.line(f"{var} = " + joiner.join(self.ref(p) for p in parts))
            return ("dyn", var)

        if op == "-":
            parts = [self.emit(a) for a in args]
            var = self.fresh("t")
            if len(parts) == 1:
                self.line(f"{var} = -{self.ref(parts[0])}")
            else:
                self.line(f"{var} = " + " - ".join(self.ref(p) for p in parts))
            return ("dyn", var)

        if op == "neg":
            if len(args) != 1:
                return ("dyn", self.delegate(expr))
            a = self.emit(args[0])
            var = self.fresh("t")
            self.line(f"{var} = -{self.ref(a)}")
            return ("dyn", var)

        if op == "/":
            if len(args) != 2:
                return ("dyn", self.delegate(expr))
            a = self.emit(args[0])
            b = self.emit(args[1])
            var = self.fresh("t")
            self.line(f"{var} = _apply_div({self.ref(a)}, {self.ref(b)})")
            return ("dyn", var)

        if op in ("^", "**", "pow"):
            if len(args) != 2:
                return ("dyn", self.delegate(expr))
            a = self.emit(args[0])
            b = self.emit(args[1])
            var = self.fresh("t")
            self.line(f"{var} = {self.ref(a)} ** {self.ref(b)}")
            return ("dyn", var)

        if op == "atan2":
            if len(args) != 2:
                return ("dyn", self.delegate(expr))
            a = self.emit(args[0])
            b = self.emit(args[1])
            var = self.fresh("t")
            self.line(f"{var} = _apply_atan2({self.ref(a)}, {self.ref(b)})")
            return ("dyn", var)

        if op in ("and", "or"):
            if len(args) < 2:
                return ("dyn", self.delegate(expr))
            uf = np.logical_and if op == "and" else np.logical_or
            parts = [self.emit(a) for a in args]
            var = self.fresh("t")
            items = ", ".join(self.ref(p) for p in parts)
            self.line(f"{var} = _apply_bool_reduce([{items}], {self.intern(uf)})")
            return ("dyn", var)

        if op == "not":
            if len(args) != 1:
                return ("dyn", self.delegate(expr))
            a = self.emit(args[0])
            var = self.fresh("t")
            self.line(f"{var} = _apply_not({self.ref(a)})")
            return ("dyn", var)

        if op in ("min", "max"):
            uf = np.minimum if op == "min" else np.maximum
            parts = [self.emit(a) for a in args]
            var = self.fresh("t")
            items = ", ".join(self.ref(p) for p in parts)
            self.line(f"{var} = _apply_minmax([{items}], {self.intern(uf)})")
            return ("dyn", var)

        if op == "ifelse":
            if len(args) != 3:
                return ("dyn", self.delegate(expr))
            c = self.emit(args[0])
            a = self.emit(args[1])
            b = self.emit(args[2])
            var = self.fresh("t")
            self.line(f"{var} = _apply_ifelse({self.ref(c)}, {self.ref(a)}, {self.ref(b)})")
            return ("dyn", var)

        # "true"/"false" (no args) are static and folded above; anything else
        # in _COMPILED_OPS that reaches here delegates, like the closure tier's
        # unreachable fallback.
        return ("dyn", self.delegate(expr))


def compile_box_body(
    body: Any, static_env: dict[str, np.ndarray]
) -> Callable[[EvalContext], Any] | None:
    """Generate the flat evaluator for ``body`` under the baked box bindings
    ``static_env`` (symbol → the exact broadcast ndarray the caller binds into
    ``ctx.locals``). Returns ``None`` to decline — the caller must fall back to
    ``_compile_expr(body)``, which reproduces today's behaviour exactly."""
    try:
        em = _Emitter(static_env)
        kind, ref = em.emit(body)
        if kind == "const":
            if isinstance(ref, np.ndarray):
                const_arr = ref
                # Fresh copy per evaluation: the interpreter computes a fresh
                # array each call, so the result must not alias the fold.
                return lambda ctx: const_arr.copy()
            const_val = ref
            return lambda ctx: const_val
        src = (
            "def _boxfn(ctx):\n" + "".join(f"    {ln}\n" for ln in em.lines) + f"    return {ref}\n"
        )
        code = compile(src, "<ess-numpy-codegen>", "exec")
        exec(code, em.ns)
        return em.ns["_boxfn"]
    except Exception:
        # Decline on ANY codegen-time failure (a folding subtree that raises,
        # recursion depth, the line cap): the closure-tier fallback reproduces
        # the interpreter's behaviour — including any error — per call.
        return None
