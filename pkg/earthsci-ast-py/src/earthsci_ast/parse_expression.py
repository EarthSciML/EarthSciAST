"""parse_expression — the INVERSE of :func:`~earthsci_ast.display.to_ascii` for
authoring EarthSciAST expressions (esm-spec §4.2) as text.

The concrete syntax IS what ``to_ascii`` emits, so the pair round-trips:
``to_ascii(parse_expression(s)) == s``. Precedence is sourced from the printer's
own table (``display._get_operator_precedence``) so the parser can never drift
from the printer. This parser RECONSTRUCTS existing AST node shapes; it never
invents new ones, and it requires no change to ``to_ascii``.

Coverage:
 - scalar tier: arithmetic, powers, comparisons, boolean logic, elementary
   functions, derivatives (``D(x)/Dt`` and ``D(x, t)``), open/user function calls;
 - array & call-shaped tier: array literals ``[…]`` (``const``), indexing
   ``a[i, j]`` (``index``), dotted closed-function calls ``datetime.year(t)``
   (``fn``), the ``true`` literal, and ``integral`` / ``reshape`` / ``transpose`` /
   ``concat``;
 - reduction & array-query tier: ``aggregate`` reductions
   ``sum[i] (expr) where {i in set, j in lo:hi} join(a=b) if pred distinct
   key=k [semiring=…]`` (all clause shapes), the ``argmin``/``argmax``
   arg-witnesses ``argmin[g] (expr) where {…}``, template application
   ``name<binding = value, …>`` (``apply_expression_template``),
   ``polygon_intersection_area(a, b, manifold=…)``, and the piecewise-region
   array ``makearray([lo:hi, …] = value, …)``.

Aggregate ``args`` is a derived operand cache the printer doesn't emit; it's
reconstructed best-effort (see :func:`_derive_aggregate_args`) and is
reprint-neutral. ``sum`` with neither an explicit ``[semiring=…]`` nor a ``join``
reconstructs as a plain ``+`` reduction — the join-less ``sum_product``
annotation (semantically identical there) is not recovered; both reprint
identically.

Still deferred (need dedicated surface syntax — a later pass): ``table_lookup``,
``broadcast``, ``enum``, and ``intersect_polygon`` (its ``id`` field is not
printed, so it can't round-trip). Those are refused with an
:class:`ExpressionParseError`.

Design rules: multiplication is ALWAYS explicit (``k * A``) — no implicit
juxtaposition, because identifiers are multi-letter (``NO2``, ``O3``,
``k_photo``). Two known non-exactnesses trace to ``to_ascii``, not the parser:
float serialization, and unary-minus operands being under-parenthesized
(``-(a+b)`` and ``(-a)+b`` both print ``-a + b``) — the parser matches the
printer's loose convention. Because the printer is not injective,
``parse_expression(to_ascii(ast))`` is a faithful SEMANTIC round-trip but may
normalize structure (flat vs. nested ``+``; a scalar ``const``/``fn`` with a
non-dotted name reprints identically to a plain number/op). Editors should treat
text as a derived view and re-parse only dirtied expressions.

**Node form.** Operator nodes come back as JSON-shaped ``dict``s
(``{"op": …, "args": [...]}``) rather than :class:`~earthsci_ast.esm_types.ExprNode`
instances — the raw-JSON surface of an expression that ``to_ascii``,
:mod:`earthsci_ast.json_walk`, :mod:`earthsci_ast.value_invention` and the
document writers all accept. Two ops in the text surface carry fields the typed
``ExprNode`` has no slot for (``argmin``/``argmax``'s ``arg`` and
``apply_expression_template``'s ``bindings``; see
``canonicalize._CANONICAL_IGNORED_FIELDS``), so the dict form is the only
representation that can carry the whole grammar losslessly.

NOTE: this is the TEXT parser. The private JSON decoder
``earthsci_ast.parse._parse_expression`` (raw ESM JSON -> typed ``ExprNode``) is
a different, unrelated function and is unaffected.
"""

from __future__ import annotations

import json
import re
import unicodedata
from typing import Any, NoReturn, Union

from .display import _get_operator_precedence as _op_precedence
from .errors import EarthSciAstError
from .esm_types import Equation, Expr  # noqa: F401  (Expr documents the return type)
from .serialize import _canonical_number

__all__ = ["ExpressionParseError", "ParsedExpr", "parse_equation", "parse_expression"]

#: What the text parser actually returns: a number, a bare reference, or a
#: JSON-shaped operator node. Spelled out for callers that want to annotate a
#: variable holding a parse result — the public signatures below say ``Expr``,
#: the package-wide expression type, of which this is the raw-JSON surface (see
#: the module docstring on why nodes are dicts, not typed ``ExprNode``s).
ParsedExpr = Union[int, float, str, "dict[str, Any]"]


class ExpressionParseError(EarthSciAstError, ValueError):
    """Raised when an expression string cannot be parsed.

    Subclasses ``ValueError`` as well as :class:`~earthsci_ast.errors.EarthSciAstError`,
    matching the convention of :class:`~earthsci_ast.errors.ParseError`, so callers
    that ``except ValueError`` around an authoring call still catch it.

    :ivar pos: 0-based character offset into the source where parsing failed.
    """

    def __init__(self, message: str, pos: int) -> None:
        super().__init__(message)
        self.pos = pos


# --- operator tables ---------------------------------------------------------

# Binary infix operators the parser recognizes. Each one's precedence comes from
# the printer's table at parse time, so it tracks display.py; only the token set
# and associativity live here. `^` is the sole right-associative operator
# (mirrors the printer's right-associative power handling).
_INFIX: frozenset[str] = frozenset(
    {"or", "and", "==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "^"}
)
_RIGHT_ASSOC: frozenset[str] = frozenset({"^"})

# Prefix operand minimum-precedences, sourced from the printer's table:
#  - unary `-` binds LOOSELY (precedence of `-`, = additive), so it swallows a
#    whole additive/multiplicative operand, matching how the printer renders
#    `-(Ea/(R*T))` as `-Ea / (R * T)` with no inner parens.
#  - `not` binds TIGHTLY at its own precedence (`not p and q` = `(not p) and q`).
_UMINUS_MIN = _op_precedence("-")
_NOT_MIN = _op_precedence("not")
# Template binding values (`name<k = value, …>`) bind at additive precedence so
# the closing `>` — a comparison operator — is never swallowed as `value > …`.
_TEMPLATE_ARG_MIN = _op_precedence("+")

# Structural ops whose defining data lives OUTSIDE `args` AND which have no text
# surface yet — refused, pending a dedicated syntax pass. (`integral`, `reshape`,
# `transpose`, `concat`, `fn`, `const`, `index`, `true`, `aggregate`,
# `apply_expression_template`, `polygon_intersection_area`, `makearray` DO have a
# surface and are reconstructed below; they are intentionally absent here.
# `intersect_polygon` stays refused: its `id` field is not printed, so it can't
# round-trip.)
_STRUCTURAL_OPS: frozenset[str] = frozenset(
    {"table_lookup", "broadcast", "enum", "intersect_polygon"}
)

# The aggregate reduction symbols `to_ascii` emits. Each maps to a default
# `reduce` when no explicit `[semiring=…]` supersedes it; `sum` and `any` carry
# no `reduce` field (plain `+` / semiring-only).
_AGG_SYMS: frozenset[str] = frozenset({"sum", "prod", "max", "min", "any"})
# Arg-witness reductions: `argmin[g] (expr) where {…}`.
_ARGWITNESS_SYMS: frozenset[str] = frozenset({"argmin", "argmax"})
_REDUCE_BY_SYM: dict[str, str | None] = {
    "sum": None,
    "prod": "*",
    "max": "max",
    "min": "min",
    "any": None,
}


# --- tokenizer ---------------------------------------------------------------


#: One token: ``k`` is the kind, ``v`` the payload (number / name / op spelling),
#: ``pos`` the 0-based source offset.
class _Tok:
    __slots__ = ("k", "pos", "v")

    def __init__(self, k: str, v: Any, pos: int) -> None:
        self.k = k
        self.v = v
        self.pos = pos

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"_Tok({self.k!r}, {self.v!r}, {self.pos})"


# Longest-match-first so `>=`/`<=`/`==`/`!=` beat `>`/`<`/`=`.
_MULTI_OPS = (">=", "<=", "==", "!=")
_SINGLE_OPS = frozenset("+-*/^><")
_PUNCT = {c: c for c in "()[]{}:;,"}
# ASCII digits only (JS `\d` is ASCII even under /u); Python's `\d` would also
# match Unicode decimal digits, which belong to identifiers here, not numbers.
_NUM_RE = re.compile(r"(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")
_WORD_OPS = frozenset({"and", "or", "not"})

# Identifiers allow Unicode letters (Greek variables like `ΔF_net`, `Φ`),
# Unicode numbers (subscript/superscript digits in names like `k₀`, `M₁`), and
# dots (qualified refs like `Emissions.NO`, and dotted closed-function names like
# `datetime.year`, which _make_call turns into `fn` nodes). A leading digit still
# can't start an identifier (numbers lex first).
#
# `∂` (U+2202) and `∇` (U+2207) are also name-constituents: source variables are
# sometimes named with them (`∂u_∂z`, a discretized ∂u/∂z shear field), and
# `to_ascii` prints such names verbatim. Those glyphs are NOT ascii operators —
# the ascii derivative surface is `D(x)/Dt`, so `∂`/`∇` appear in `to_ascii`
# output ONLY inside a name, and accepting them keeps the parser its exact
# inverse. (The unicode big-operator display forms `∑ ∫ ∈ ⟨⟩` remain refused;
# they're to_unicode/to_latex forms, not the ascii surface — see _tokenize().)
_NAME_GLYPHS = "∂∇"


def _is_name_start(c: str) -> bool:
    """True for ``[_∂∇\\p{L}]`` — what may open an identifier."""
    return c == "_" or c in _NAME_GLYPHS or c.isalpha()


def _is_name_part(c: str) -> bool:
    """True for ``[\\w.∂∇\\p{L}\\p{N}]`` — what may continue an identifier."""
    if c in "._" or c in _NAME_GLYPHS:
        return True
    if c.isascii():
        return c.isalnum()
    # \p{L} (str.isalpha is exactly the Unicode Letter categories) or \p{N}.
    return c.isalpha() or unicodedata.category(c).startswith("N")


def _tokenize(src: str) -> list[_Tok]:
    """Lex ``src`` into the token stream the Pratt parser consumes."""
    toks: list[_Tok] = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c in " \t\n\r":
            i += 1
            continue
        punct = _PUNCT.get(c)
        if punct is not None:
            toks.append(_Tok(punct, None, i))
            i += 1
            continue
        if src[i : i + 2] in _MULTI_OPS:
            toks.append(_Tok("op", src[i : i + 2], i))
            i += 2
            continue
        if c == "=":
            # lone '=' (the '==' case was handled just above)
            toks.append(_Tok("eq", None, i))
            i += 1
            continue
        if c in _SINGLE_OPS:
            toks.append(_Tok("op", c, i))
            i += 1
            continue
        if c == "." or ("0" <= c <= "9"):
            m = _NUM_RE.match(src, i)
            if m is not None:
                # Canonicalize per CONFORMANCE_SPEC §5.5.3.1 so an integral
                # literal (`1.0e4`) lands as an integer, exactly as the JS
                # oracle's double does when serialized.
                toks.append(_Tok("num", _canonical_number(float(m.group(0))), i))
                i = m.end()
                continue
        if _is_name_start(c):
            j = i + 1
            while j < n and _is_name_part(src[j]):
                j += 1
            v = src[i:j]
            toks.append(_Tok("op", v, i) if v in _WORD_OPS else _Tok("name", v, i))
            i = j
            continue
        # The big-operator / unicode display forms (∑ ∫ ∈ ⟨⟩ …) are rendered by
        # to_unicode/to_latex, not the ascii form this parser inverts; refuse them
        # so a caller routes such input elsewhere. (The ascii aggregate surface
        # uses the words `sum`/`where`/`in`/`join`/`if` and `{ }` `:` `;`, all
        # handled above; the name-constituents `∂`/`∇` matched just above.)
        if ord(c) > 127:
            raise ExpressionParseError(
                f"unicode operator syntax ({json.dumps(c)}) — use the ascii text form", i
            )
        raise ExpressionParseError(f"Unexpected character {json.dumps(c)}", i)
    toks.append(_Tok("eof", None, n))
    return toks


def _is_expr_node(e: Any) -> bool:
    """True for a JSON-shaped operator node (a dict carrying ``op`` and ``args``)."""
    return isinstance(e, dict) and "op" in e and "args" in e


def _is_set_name(op: Any) -> bool:
    """True when ``op`` looks like an index-set name (``/^[_\\p{L}]/``) — i.e. the
    generic call `set(of…)` a `k in set(a, b)` range clause reprints as, rather
    than an operator symbol."""
    return isinstance(op, str) and op != "" and (op[0] == "_" or op[0].isalpha())


# --- parser (Pratt / precedence-climbing) ------------------------------------


class _Parser:
    def __init__(self, toks: list[_Tok]) -> None:
        self._toks = toks
        self._p = 0

    def _peek(self, k: int = 0) -> _Tok:
        return self._toks[min(self._p + k, len(self._toks) - 1)]

    def _next(self) -> _Tok:
        t = self._toks[min(self._p, len(self._toks) - 1)]
        self._p += 1
        return t

    def _expect(self, k: str, what: str) -> None:
        if self._peek().k != k:
            self._fail(f"Expected {what}")
        self._next()

    def _expect_op(self, v: str, what: str) -> None:
        t = self._peek()
        if t.k != "op" or t.v != v:
            self._fail(f"Expected {what}")
        self._next()

    def _fail(self, msg: str, tok: _Tok | None = None) -> NoReturn:
        raise ExpressionParseError(msg, (tok if tok is not None else self._peek()).pos)

    def _at_word(self, v: str) -> bool:
        """True when the next token is the contextual keyword name ``v``."""
        t = self._peek()
        return t.k == "name" and t.v == v

    # --- entry ---------------------------------------------------------------

    def parse_entry(self) -> Any:
        e = self._parse_expr(0)
        if self._peek().k != "eof":
            self._fail("Unexpected trailing input")
        return _flatten(e)

    def _parse_expr(self, min_prec: int) -> Any:
        left = self._parse_prefix()
        while True:
            t = self._peek()
            if t.k != "op" or t.v not in _INFIX:
                break
            prec = _op_precedence(t.v)
            if prec < min_prec:
                break
            self._next()
            rhs = self._parse_expr(prec if t.v in _RIGHT_ASSOC else prec + 1)
            left = {"op": t.v, "args": [left, rhs]}
        return left

    def _parse_prefix(self) -> Any:
        t = self._peek()
        # `-` directly before a number is a NEGATIVE LITERAL, not a unary-minus
        # node. Both print as `-1.3`, but only a literal reprints WITHOUT parens
        # as an operand (`x^-1.3`, not `x^(-1.3)`) — matching how `to_ascii`
        # emits negative constants (e.g. Arrhenius `(300/T)^-1.3`).
        if t.k == "op" and t.v == "-" and self._peek(1).k == "num":
            self._next()
            return -self._next().v
        if t.k == "op" and t.v in ("-", "not"):
            self._next()
            operand = self._parse_expr(_NOT_MIN if t.v == "not" else _UMINUS_MIN)
            return {"op": t.v, "args": [operand]}
        return self._parse_postfix()

    def _parse_postfix(self) -> Any:
        """Atom, then postfix ``[…]`` indexing, then the derivative sugar
        ``D(expr)/D<name>``."""
        node = self._parse_atom()
        while self._peek().k == "[":
            # A trailing `[semiring=…]` is an aggregate suffix, never an index —
            # leave it for _parse_aggregate's tail (it can follow a `key=`/`if`
            # expression).
            nxt = self._peek(1)
            if nxt.k == "name" and nxt.v == "semiring":
                break
            self._next()  # '['
            idx = [self._parse_expr(0)]
            while self._peek().k == ",":
                self._next()
                idx.append(self._parse_expr(0))
            self._expect("]", "']'")
            node = {"op": "index", "args": [node, *idx]}
        slash = self._peek()
        if _is_expr_node(node) and node["op"] == "D" and slash.k == "op" and slash.v == "/":
            name_tok = self._peek(1)
            if name_tok.k == "name" and len(name_tok.v) > 1 and name_tok.v[0] == "D":
                self._next()  # '/'
                self._next()  # 'D<var>'
                return {"op": "D", "wrt": name_tok.v[1:], "args": node["args"]}
        return node

    def _parse_atom(self) -> Any:
        t = self._next()
        if t.k == "num":
            return t.v
        if t.k == "(":
            e = self._parse_expr(0)
            self._expect(")", "')'")
            return e
        # A leading `[` is a const array literal (`[1, 2, 3]`, `[[1, 2], [3, 4]]`).
        if t.k == "[":
            return {"op": "const", "value": self._parse_array_rest(), "args": []}
        if t.k == "name":
            if t.v == "true":
                return {"op": "true", "args": []}
            # `makearray(region = value, …)` — a piecewise-region array. Its
            # arguments are `[lo:hi, …] = value` pairs, not plain call args, so it
            # needs its own parse rather than the generic _parse_call path.
            if t.v == "makearray" and self._peek().k == "(":
                return self._parse_makearray()
            if self._peek().k == "(":
                return self._parse_call(t.v)
            # Template application `name<binding = value, …>` (or empty `name<>`)
            # -> apply_expression_template. The `< NAME =` / `< >` lookahead
            # distinguishes it from a `<` comparison (whose RHS is never a lone
            # `=` nor an empty `>`).
            lt = self._peek()
            lt1 = self._peek(1)
            if (
                lt.k == "op"
                and lt.v == "<"
                and (
                    (lt1.k == "op" and lt1.v == ">")
                    or (lt1.k == "name" and self._peek(2).k == "eq")
                )
            ):
                return self._parse_template(t.v)
            # Aggregate reduction `sym[out_idx] (expr) where {…} …`. Only when the
            # bracket is followed (past its match) by `(` — otherwise `sym[i]` is
            # an ordinary index into a variable that happens to be named
            # `sum`/`max`/….
            if t.v in _AGG_SYMS and self._peek().k == "[" and self._aggregate_ahead():
                return self._parse_aggregate(t.v)
            # Arg-witness reduction `argmin[g] (expr) where {…}` (same `[…] (` shape).
            if t.v in _ARGWITNESS_SYMS and self._peek().k == "[" and self._aggregate_ahead():
                return self._parse_arg_witness(t.v)
            return t.v  # bare variable / species / qualified reference
        return self._fail("Expected a number, name, '(', or '['", t)

    def _parse_array_rest(self) -> list[Any]:
        """Parse the elements of an array literal after ``[`` up to and including ``]``."""
        els: list[Any] = []
        if self._peek().k != "]":
            while True:
                if self._peek().k == "[":
                    self._next()
                    els.append(self._parse_array_rest())  # nested raw array
                else:
                    els.append(self._parse_expr(0))  # number / name / expression element
                if self._peek().k == ",":
                    self._next()
                    continue
                break
        self._expect("]", "']'")
        return els

    def _parse_call(self, name: str) -> Any:
        self._next()  # '('
        args: list[Any] = []
        named: dict[str, Any] = {}
        if self._peek().k != ")":
            while True:
                # A `key = value` argument (e.g. concat `axis=0`); a lone `=` (not
                # `==`) after a bare name marks it.
                if self._peek().k == "name" and self._peek(1).k == "eq":
                    key = self._next().v
                    self._next()  # '='
                    named[key] = self._parse_expr(0)
                else:
                    args.append(self._parse_expr(0))
                if self._peek().k == ",":
                    self._next()
                    continue
                break
        self._expect(")", f"',' or ')' in call to {name}(...)")
        return _make_call(name, args, named, self._peek().pos)

    # --- aggregate / template (the reduction & array-query tier) --------------

    def _aggregate_ahead(self) -> bool:
        """True when the ``[`` at the current position closes with a ``]``
        immediately followed by ``(`` — the signature of an aggregate
        ``sym[…] (expr)``, as opposed to plain indexing ``sym[i]``. Scans balanced
        brackets, consumes nothing."""
        depth = 0
        for i in range(self._p, len(self._toks)):
            k = self._toks[i].k
            if k == "[":
                depth += 1
            elif k == "]":
                depth -= 1
                if depth == 0:
                    return i + 1 < len(self._toks) and self._toks[i + 1].k == "("
        return False

    def _parse_aggregate(self, sym: str) -> Any:
        """Parse an ``aggregate`` reduction (esm-spec §4.2) — the inverse of the
        printer's aggregate rendering::

            sym '[' out_idx ']' '(' expr ')' ('where' '{' ranges '}')?
            ('join' '(' … ')')? ('if' filter)? 'distinct'? ('key' '=' expr)?
            ('[' 'semiring' '=' name ']')?

        ``sym`` selects the default ``reduce``; an explicit ``[semiring=…]``
        supersedes it, as does a ``join`` (which implies ``sum_product``). ``args``
        is a derived dependency cache (see :func:`_derive_aggregate_args`); the
        printer doesn't emit it, so its exact value is reprint-neutral.
        """
        self._next()  # '['
        output_idx: list[str] = []
        if self._peek().k != "]":
            while True:
                t = self._next()
                if t.k != "name":
                    self._fail("Expected an output index name", t)
                output_idx.append(t.v)
                if self._peek().k == ",":
                    self._next()
                    continue
                break
        self._expect("]", "']' after aggregate output indices")
        self._expect("(", "'(' before the aggregate body")
        expr = self._parse_expr(0)
        self._expect(")", "')' after the aggregate body")

        ranges: dict[str, Any] = {}
        if self._at_word("where"):
            self._next()
            ranges = self._parse_ranges()
        join: list[dict[str, Any]] = []
        if self._at_word("join"):
            self._next()
            join.extend(self._parse_join())
        filter_: Any = _MISSING
        if self._at_word("if"):
            self._next()
            filter_ = self._parse_expr(0)
        distinct = False
        if self._at_word("distinct"):
            self._next()
            distinct = True
        key: Any = _MISSING
        if self._at_word("key") and self._peek(1).k == "eq":
            self._next()  # 'key'
            self._next()  # '='
            key = self._parse_expr(0)
        semiring: str | None = None
        if self._peek().k == "[" and self._peek(1).k == "name" and self._peek(1).v == "semiring":
            self._next()  # '['
            self._next()  # 'semiring'
            self._expect("eq", "'=' in [semiring=…]")
            nm = self._next()
            if nm.k != "name":
                self._fail("Expected a semiring name", nm)
            semiring = nm.v
            self._expect("]", "']' after [semiring=…]")
        # A join with no explicit semiring is the sum-of-products contraction.
        if semiring is None and join:
            semiring = "sum_product"

        node: dict[str, Any] = {"op": "aggregate", "output_idx": output_idx}
        if semiring is not None:
            node["semiring"] = semiring
        else:
            red = _REDUCE_BY_SYM.get(sym)
            if red is not None:
                node["reduce"] = red
        node["ranges"] = ranges
        if join:
            node["join"] = join
        if filter_ is not _MISSING:
            node["filter"] = filter_
        if distinct:
            node["distinct"] = True
        if key is not _MISSING:
            node["key"] = key
        node["expr"] = expr
        node["args"] = _derive_aggregate_args(
            expr,
            join,
            None if filter_ is _MISSING else filter_,
            None if key is _MISSING else key,
        )
        return node

    def _parse_arg_witness(self, op: str) -> Any:
        """Parse an ``argmin`` / ``argmax`` arg-witness (esm-spec §4.2):
        ``op '[' arg ']' '(' expr ')' ('where' '{' ranges '}')?``. Like aggregate,
        its ``args`` operand cache isn't printed and is derived."""
        self._next()  # '['
        at = self._next()
        if at.k != "name":
            self._fail("Expected the arg-witness index name", at)
        self._expect("]", "']' after the arg-witness index")
        self._expect("(", "'(' before the arg-witness body")
        expr = self._parse_expr(0)
        self._expect(")", "')' after the arg-witness body")
        ranges: dict[str, Any] = {}
        if self._at_word("where"):
            self._next()
            ranges = self._parse_ranges()
        return {
            "op": op,
            "args": _derive_aggregate_args(expr, [], None, None),
            "arg": at.v,
            "ranges": ranges,
            "expr": expr,
        }

    def _parse_ranges(self) -> dict[str, Any]:
        """Parse a ``{ k in <rhs>, … }`` where-body into a ranges object."""
        self._expect("{", "'{' after where")
        ranges: dict[str, Any] = {}
        if self._peek().k != "}":
            while True:
                kt = self._next()
                if kt.k != "name":
                    self._fail("Expected a range index name", kt)
                if not self._at_word("in"):
                    self._fail("Expected 'in' in a range clause")
                self._next()  # 'in'
                ranges[kt.v] = self._parse_range_rhs()
                if self._peek().k == ",":
                    self._next()
                    continue
                break
        self._expect("}", "'}' to close the where clause")
        return ranges

    def _parse_range_rhs(self) -> Any:
        """One range RHS: ``set`` -> {from}; ``set(a, b)`` -> {from, of};
        ``lo:hi`` -> [lo, hi]."""
        bound = self._parse_expr(0)
        if self._peek().k == ":":
            self._next()
            return [bound, self._parse_expr(0)]
        if isinstance(bound, str):
            return {"from": bound}
        # `k in set(of1, of2)` prints as a generic call -> {from, of}.
        if _is_expr_node(bound) and _is_set_name(bound["op"]) and isinstance(bound["args"], list):
            of: list[str] = []
            for a in bound["args"]:
                if not isinstance(a, str):
                    self._fail("range set arguments must be names")
                of.append(a)
            return {"from": bound["op"], "of": of}
        return self._fail("malformed range (expected a set name, set(of…), or lo:hi)")

    def _parse_join(self) -> list[dict[str, Any]]:
        """Parse ``( a=b, c=d ; e=f )`` -> ``[{on:[[a,b],[c,d]]}, {on:[[e,f]]}]``."""
        self._expect("(", "'(' after join")
        clauses: list[dict[str, Any]] = []
        cur: list[list[str]] = []
        if self._peek().k != ")":
            while True:
                a = self._next()
                if a.k != "name":
                    self._fail("Expected a join key name", a)
                self._expect("eq", "'=' in a join pair")
                b = self._next()
                if b.k != "name":
                    self._fail("Expected a join key name", b)
                cur.append([a.v, b.v])
                if self._peek().k == ",":
                    self._next()
                    continue
                if self._peek().k == ";":
                    self._next()
                    clauses.append({"on": cur})
                    cur = []
                    continue
                break
        clauses.append({"on": cur})
        self._expect(")", "')' to close join(…)")
        return clauses

    def _parse_template(self, name: str) -> Any:
        """Parse ``name<binding = value, …>`` (or empty ``name<>``) ->
        apply_expression_template."""
        self._next()  # '<'
        bindings: dict[str, Any] = {}
        while not (self._peek().k == "op" and self._peek().v == ">"):
            kt = self._next()
            if kt.k != "name":
                self._fail("Expected a binding name in <…>", kt)
            self._expect("eq", "'=' in a template binding")
            bindings[kt.v] = self._parse_expr(_TEMPLATE_ARG_MIN)
            if self._peek().k == ",":
                self._next()
                continue
            break
        self._expect_op(">", "'>' to close a template application")
        return {
            "op": "apply_expression_template",
            "args": [],
            "name": name,
            "bindings": bindings,
        }

    def _parse_makearray(self) -> Any:
        """Parse a ``makearray`` piecewise-region array (esm-spec §4.2)::

            'makearray' '(' region '=' value ( ',' region '=' value )* ')'
            region := '[' bound ':' bound ( ',' bound ':' bound )* ']'

        Each region is a list of per-dimension ``lo:hi`` bounds, and ``value`` is
        the expression that region evaluates to. A bound is any expression (a
        number, a name like ``NLON``, or e.g. ``NLON - 1``). ``args`` is always
        ``[]`` (the printer emits none); ``regions`` and ``values`` are
        positionally paired. Values are flattened to the canonical n-ary ``+``/``*``
        form, like the top-level parse.
        """
        self._next()  # '('
        regions: list[list[list[Any]]] = []
        values: list[Any] = []
        if self._peek().k != ")":
            while True:
                self._expect("[", "'[' to open a makearray region")
                region: list[list[Any]] = []
                if self._peek().k != "]":
                    while True:
                        lo = self._parse_expr(0)
                        self._expect(":", "':' between a region's lo:hi bounds")
                        hi = self._parse_expr(0)
                        region.append([_flatten(lo), _flatten(hi)])
                        if self._peek().k == ",":
                            self._next()
                            continue
                        break
                self._expect("]", "']' to close a makearray region")
                self._expect("eq", "'=' after a makearray region")
                regions.append(region)
                values.append(_flatten(self._parse_expr(0)))
                if self._peek().k == ",":
                    self._next()
                    continue
                break
        self._expect(")", "')' to close makearray(...)")
        return {"op": "makearray", "args": [], "regions": regions, "values": values}


#: Sentinel distinguishing "clause absent" from a parsed value that is falsy.
_MISSING = object()


# --- call reconstruction -----------------------------------------------------


def _as_array_literal(e: Any, pos: int) -> list[Any]:
    """Extract the raw element list of a parsed ``const`` array literal, or fail."""
    if _is_expr_node(e) and e["op"] == "const" and isinstance(e.get("value"), list):
        return e["value"]
    raise ExpressionParseError("expected an array literal [ ... ]", pos)


def _no_named(named: dict[str, Any], name: str, pos: int) -> None:
    if named:
        raise ExpressionParseError(f"unexpected {next(iter(named))}=… in {name}(...)", pos)


def _make_call(name: str, args: list[Any], named: dict[str, Any], pos: int) -> Any:
    # A dotted callee is a closed function — an `fn` node carrying the name.
    if "." in name:
        _no_named(named, name, pos)
        return {"op": "fn", "name": name, "args": args}
    # Call-shaped structural ops: reconstruct their non-`args` fields from the
    # positional / named arguments `to_ascii` renders.
    if name == "integral" and len(args) == 4 and isinstance(args[1], str):
        _no_named(named, name, pos)
        return {
            "op": "integral",
            "args": [args[0]],
            "var": args[1],
            "lower": args[2],
            "upper": args[3],
        }
    if name == "reshape" and len(args) == 2:
        _no_named(named, name, pos)
        return {"op": "reshape", "args": [args[0]], "shape": _as_array_literal(args[1], pos)}
    if name == "transpose" and len(args) in (1, 2):
        _no_named(named, name, pos)
        if len(args) == 1:
            return {"op": "transpose", "args": [args[0]]}
        return {"op": "transpose", "args": [args[0]], "perm": _as_array_literal(args[1], pos)}
    if name == "concat":
        if "axis" not in named:
            raise ExpressionParseError("concat(...) requires axis=<n>", pos)
        return {"op": "concat", "args": args, "axis": named["axis"]}
    # Geometry area query `polygon_intersection_area(a, b, manifold=<name>)`. (Its
    # sibling `intersect_polygon` stays refused: its `id` field isn't printed.)
    if name == "polygon_intersection_area":
        manifold = named.get("manifold")
        if not isinstance(manifold, str):
            raise ExpressionParseError(f"{name}(...) requires manifold=<name>", pos)
        for k in named:
            if k != "manifold":
                raise ExpressionParseError(f"unexpected {k}=… in {name}(...)", pos)
        return {"op": "polygon_intersection_area", "args": args, "manifold": manifold}
    _no_named(named, name, pos)
    if name in _STRUCTURAL_OPS:
        raise ExpressionParseError(f"'{name}' is not yet expressible in the text form", pos)
    if name == "D":
        # Friendly form D(expr, t) — wrt as an explicit second arg — in addition
        # to the to_ascii form D(expr)/Dt handled in _parse_postfix. Any other
        # arity is a nonstandard / discretization D (e.g. with boundary
        # conditions) that the printer emits via the generic call fallback; keep
        # it a generic call.
        if len(args) == 2 and isinstance(args[1], str):
            return {"op": "D", "wrt": args[1], "args": [args[0]]}
        if len(args) == 1:
            return {"op": "D", "args": args}
    return {"op": name, "args": args}


def _derive_aggregate_args(
    expr: Any,
    join: list[dict[str, Any]],
    filter_: Any,
    key: Any,
) -> list[str]:
    """Best-effort reconstruction of an aggregate's ``args`` — its array operands.

    ``to_ascii`` does NOT print ``args`` (it's a derived dependency cache), and
    the authoritative set excludes parameter arrays by *declared role*, which
    needs the variable table. From the printed structure alone we approximate it
    as: the base of every ``index(…)`` in the body / filter / key, plus the names
    in ``join`` clauses, in first-appearance order. This is reprint-neutral (the
    printer ignores it) and a dependency superset (safe for graph/dead-code
    analysis); an editor holding the symbol table should recompute it on save.
    """
    out: list[str] = []

    def add(n: str) -> None:
        if n not in out:
            out.append(n)

    def bases(e: Any) -> None:
        if isinstance(e, list):
            for x in e:
                bases(x)
            return
        if isinstance(e, dict):
            node_args = e.get("args")
            if (
                e.get("op") == "index"
                and isinstance(node_args, list)
                and node_args
                and isinstance(node_args[0], str)
            ):
                add(node_args[0])
            for v in list(e.values()):
                bases(v)

    bases(expr)
    for c in join:
        for a, b in c["on"]:
            add(a)
            add(b)
    bases(filter_)
    bases(key)
    return out


# --- normalization -----------------------------------------------------------


def _flatten(e: Any) -> Any:
    """Flatten nested same-op ``+`` / ``*`` in ``args`` into the n-ary form the
    printer emits and authored ASTs use: ``a + b + c`` -> one ``+`` with three
    args, not left-nested pairs. (``-`` and ``/`` are binary and stay as parsed.)
    Non-``args`` expression fields (integral bounds, etc.) are left as parsed."""
    if not _is_expr_node(e):
        return e
    args = [_flatten(a) for a in e["args"]]
    if e["op"] in ("+", "*"):
        out: list[Any] = []
        for a in args:
            if _is_expr_node(a) and a["op"] == e["op"] and a.get("wrt") is None:
                out.extend(a["args"])
            else:
                out.append(a)
        args = out
    node = dict(e)
    node["args"] = args
    return node


# --- public API --------------------------------------------------------------


def parse_expression(src: str) -> Expr:
    """Parse a single expression string into an AST expression — the inverse of
    :func:`~earthsci_ast.display.to_ascii`.

    Operator nodes come back in their JSON ``dict`` form (see the module
    docstring); numbers and bare references come back as ``int`` / ``float`` /
    ``str``.

    :raises ExpressionParseError: on malformed input, or on an operator that has
        no text surface yet (``table_lookup`` / ``broadcast`` / ``enum`` /
        ``intersect_polygon``).
    """
    return _Parser(_tokenize(src)).parse_entry()


def parse_equation(src: str) -> Equation:
    """Parse ``lhs = rhs`` into an :class:`~earthsci_ast.esm_types.Equation`.

    The top-level separator is a LONE ``=``; ``==`` (and ``>=`` / ``<=`` / ``!=``)
    remain comparison operators within either side, and an ``=`` inside a template
    application ``name<k = v>``, a call's ``axis=0``, an aggregate ``key=`` /
    ``join(a=b)`` / ``[semiring=…]`` clause, or any bracketed group is not a
    separator either.

    :raises ExpressionParseError: when there is no top-level lone ``=``, or when
        either side fails to parse.
    """
    toks = _tokenize(src)
    depth = 0
    angle = 0  # template `name<binding = value>` — its `=` is not a separator
    split = -1
    n = len(toks)
    for i in range(n):
        t = toks[i]
        if t.k in ("(", "[", "{"):
            depth += 1
        elif t.k in (")", "]", "}"):
            depth -= 1
        elif (
            t.k == "op"
            and t.v == "<"
            and i + 2 < n
            and toks[i + 1].k == "name"
            and toks[i + 2].k == "eq"
        ):
            angle += 1
        elif t.k == "op" and t.v == ">" and angle > 0:
            angle -= 1
        # The FIRST top-level lone `=` splits lhs/rhs; a later binding/`key=` `=`
        # (legitimately present in an aggregate or template on the rhs) is left
        # intact.
        elif t.k == "eq" and depth == 0 and angle == 0:
            split = i
            break
    if split == -1:
        raise ExpressionParseError("Expected 'lhs = rhs'", len(src))
    lhs = _Parser([*toks[:split], _Tok("eof", None, toks[split].pos)])
    rhs = _Parser(toks[split + 1 :])
    return Equation(lhs=lhs.parse_entry(), rhs=rhs.parse_entry())
