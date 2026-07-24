"""Canonical registry of the ESM expression-AST ``op`` vocabulary.

This module is the **single source of truth** for the set of ``op`` strings that
may appear on an :class:`~earthsci_ast.esm_types.ExprNode`. It exists because the
vocabulary was previously implicit, scattered across at least six independent
tables / dispatch chains that could (and did) drift apart:

* :mod:`earthsci_ast.expression` — ``_UNARY_SYMPY`` / ``_BINARY_SYMPY`` (ESM→SymPy)
  and the ``_FROM_SYMPY_*`` reverse tables.
* :mod:`earthsci_ast.display` — the operator-precedence map plus the big
  render dispatch (``_format_structural_op`` + ``_format_expression_node``).
* :mod:`earthsci_ast.codegen` — the Julia and Python ``op → handler`` chains.
* :mod:`earthsci_ast.numpy_interpreter` — ``_SCALAR_FUNCS`` / ``_CMP_UFUNCS`` /
  ``_broadcast_fn`` and the ``eval_expr`` dispatch.
* :mod:`earthsci_ast.cadence` — ``RELATIONAL_OPS`` (the value-invention guard).

The historical failure mode (flagged by the Python audit): when a new op is
added it raises loudly in the SymPy path but **silently degrades** to generic
``op(args)`` rendering in ``display`` / ``codegen`` — no error, just wrong-looking
output. The registry, together with ``tests/test_op_registry.py``, closes that
gap: the test asserts each renderer/dispatcher stays in sync with this registry,
so adding an op to the registry without updating a renderer fails loudly at test
time. (``display`` / ``codegen`` do NOT warn at runtime: an op reaching the
generic ``op(args)`` fallback is either an evaluable-core function that renders
correctly as a call — ``sin(x)`` — or an open-tier rewrite-target op that is a
legitimate document element lowered before evaluation. Both are correct outputs,
so neither a registered sugar op like ``grad`` nor an unregistered custom op like
``godunov_hamiltonian`` is privileged over the other — they render identically.)

**Contract for renderers/dispatchers.** Every op below is part of the accepted
vocabulary. A renderer/dispatcher is expected to cover the subset appropriate to
its role (see the per-table scoping in ``tests/test_op_registry.py``).

This registry is the **single source** for the op VOCABULARY and each op's arity
bounds: the pure op-SET tables now DERIVE their contents from it rather than
re-authoring them, so drift is impossible by construction —
``structural_checks._OPERATOR_ARITY`` (:func:`arity_bounds_map`),
``cadence.RELATIONAL_OPS`` (``by_category("relational")``), ``esm_types.ARRAY_OPS``
(``by_category("array") | by_category("geometry")``), and ``codegen._COMPARISON_OPS``.
The heterogeneous VALUE tables keep their local values (a SymPy class, a numpy
ufunc, a target-language spelling, a precedence int — none of which may enter this
sympy/numpy-free leaf) but derive their KEY SETS from the registry categories:
``expression._UNARY_SYMPY`` / ``_BINARY_SYMPY`` and
``numpy_interpreter._SCALAR_FUNCS`` / ``_CMP_UFUNCS`` (via :func:`unary_elementary`,
:func:`by_category`, :func:`canonical_names`). The remaining per-op VALUE maps whose
key sets are NOT a clean registry category — ``codegen._INFIX_SEP`` / ``_CALL_NAME``
and ``display``'s precedence map — stay hand-authored and are cross-checked here.

**Derivation.** The set is the union of esm-spec.md §4.2's op vocabulary and
every one of the six tables above (read exhaustively). It is intentionally the
honest union, so accepted spelling aliases (``**`` / ``pow`` for ``^``; ``=`` for
``==``) are included and marked via :attr:`OpSpec.alias_of`.

Categories
----------

``arithmetic``       ``+ - * / ^`` (and the ``**`` / ``pow`` spellings)
``elementary``       spec §4.2 "Elementary Functions": exp/log/trig/hyperbolic
                     families, ``atan2``, ``min``/``max``, ``floor``/``ceil``,
                     ``abs``, ``sign``
``comparison``       ``> < >= <= == !=`` (and the ``=`` equality spelling)
``logical``          ``and`` / ``or`` / ``not`` and the ``true`` / ``false``
                     boolean literals
``conditional``      ``ifelse``
``calculus``         ``D`` (structural time-derivative LHS) and ``ic``
``event``            ``Pre``
``closed_registry``  ``fn`` / ``enum`` / ``table_lookup`` (spec §4.4/§4.5/§9.5)
``template``         ``apply_expression_template`` (spec §9.6)
``constant``         ``const`` (inline literal)
``array``            aggregate/makearray/index/broadcast/reshape/transpose/concat
``relational``       value-invention & index-returning reducers: skolem, rank,
                     argmin, argmax, distinct, join (RFC semiring-faq-unified-ir)
``geometry``         intersect_polygon, polygon_intersection_area (§8.6 kernels)

The open-tier rewrite-target sugar (grad/div/laplacian/curl/integral, esm-spec
§4.2) is intentionally **NOT** registered: those ops carry no dimensional rule,
no evaluator, no privileged arity, and are not used for spatial detection, so
they are ordinary unregistered rewrite-target ops indistinguishable from a
custom user op (``godunov_hamiltonian``). ``integral``'s ∫ rendering reads its
own ``var``/``lower``/``upper`` sidecar fields via a structural ``op ==
"integral"`` branch in :mod:`.display`, which needs no registry entry.

Tiers
-----

``core``            evaluable-core (closed) op — every binding's evaluator
                    implements it directly (esm-spec §4.2). Every registered op
                    is ``core`` (the default).
``rewrite_target``  open-tier op with **no** evaluator; it MUST be eliminated by
                    a rewrite rule before evaluation (``unlowered_operator`` if
                    not, esm-spec §9.6.6). Every rewrite-target op — the sugar
                    (grad/div/…) and any custom op — is UNregistered, a
                    rewrite-target by virtue of not being evaluable-core; the tier
                    label is retained in :data:`TIERS` for that vocabulary.
"""

from __future__ import annotations

from dataclasses import dataclass

#: The closed set of category labels (see the module docstring).
CATEGORIES: frozenset[str] = frozenset(
    {
        "arithmetic",
        "elementary",
        "comparison",
        "logical",
        "conditional",
        "calculus",
        "event",
        "closed_registry",
        "template",
        "constant",
        "array",
        "relational",
        "geometry",
    }
)

#: The closed set of tier labels.
TIERS: frozenset[str] = frozenset({"core", "rewrite_target"})

#: The closed set of arity descriptors. These are documentation-grade labels; the
#: authoritative NUMERIC arity bounds are :attr:`OpSpec.arity_bounds` (a
#: ``(min_args, max_args)`` tuple), which ``structural_checks._OPERATOR_ARITY``
#: now DERIVES from — see :func:`arity_bounds_map`.
ARITIES: frozenset[str] = frozenset(
    {
        "nullary",  # args == []; the payload lives in dedicated fields
        "unary",
        "binary",
        "ternary",
        "nary",  # variadic, >= 2 operands (n-ary fold)
        "variadic",  # variadic, >= 1 operand (e.g. `-`: negation .. n-ary subtraction)
        "special",  # bespoke shape (aggregate-family; index-set-driven)
    }
)


@dataclass(frozen=True)
class OpSpec:
    """Metadata for one canonical ``op`` string.

    Attributes:
        name: The op string as it appears in an ``ExprNode.op``.
        category: One of :data:`CATEGORIES`.
        arity: One of :data:`ARITIES` (documentation-grade prose label).
        arity_bounds: The AUTHORITATIVE numeric operand-count contract, a
            ``(min_args, max_args)`` tuple (``max_args`` ``None`` = unbounded),
            or ``None`` for an op that carries no structural arity check (array /
            relational / geometry ops with index-set-driven shapes, closed-registry
            ops whose args live in dedicated fields, spelling aliases, boolean
            literals). This is the single source ``structural_checks._OPERATOR_ARITY``
            derives from (:func:`arity_bounds_map`).
        tier: One of :data:`TIERS` — ``core`` (evaluable) or ``rewrite_target``.
        alias_of: For a pure spelling alias, the canonical op it spells (e.g.
            ``**`` → ``^``); ``None`` for a canonical op.
        note: Optional human-readable clarification.
    """

    name: str
    category: str
    arity: str
    arity_bounds: tuple[int, int | None] | None = None
    tier: str = "core"
    alias_of: str | None = None
    note: str = ""


# The canonical vocabulary. Order groups by category for readability; lookups go
# through the OPS dict below.
_ALL: tuple[OpSpec, ...] = (
    # --- arithmetic (esm-spec §4.2 Arithmetic) ---
    OpSpec("+", "arithmetic", "nary", arity_bounds=(2, None)),
    OpSpec("-", "arithmetic", "variadic", arity_bounds=(1, None),
           note="unary negation .. n-ary subtraction (corpus has a 3-operand `-`)"),
    OpSpec("*", "arithmetic", "nary", arity_bounds=(2, None)),
    OpSpec("/", "arithmetic", "binary", arity_bounds=(2, 2)),
    OpSpec("^", "arithmetic", "binary", arity_bounds=(2, 2), note="power"),
    OpSpec("**", "arithmetic", "binary", alias_of="^", note="Python-style power spelling"),
    OpSpec("pow", "arithmetic", "binary", alias_of="^", note="word spelling of power"),
    # --- elementary functions (esm-spec §4.2 Elementary Functions) ---
    OpSpec("exp", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("log", "elementary", "unary", arity_bounds=(1, 1), note="natural log"),
    OpSpec("log10", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("sqrt", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("abs", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("sign", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("sin", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("cos", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("tan", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("asin", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("acos", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("atan", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("atan2", "elementary", "binary", arity_bounds=(2, 2)),
    OpSpec("sinh", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("cosh", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("tanh", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("asinh", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("acosh", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("atanh", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("min", "elementary", "nary", arity_bounds=(2, None),
           note="n-ary (>= 2); clamp/clip primitive"),
    OpSpec("max", "elementary", "nary", arity_bounds=(2, None),
           note="n-ary (>= 2); clamp/clip primitive"),
    OpSpec("floor", "elementary", "unary", arity_bounds=(1, 1)),
    OpSpec("ceil", "elementary", "unary", arity_bounds=(1, 1)),
    # --- comparison (esm-spec §4.2 Conditionals) ---
    OpSpec(">", "comparison", "binary", arity_bounds=(2, 2)),
    OpSpec("<", "comparison", "binary", arity_bounds=(2, 2)),
    OpSpec(">=", "comparison", "binary", arity_bounds=(2, 2)),
    OpSpec("<=", "comparison", "binary", arity_bounds=(2, 2)),
    OpSpec("==", "comparison", "binary", arity_bounds=(2, 2)),
    OpSpec("!=", "comparison", "binary", arity_bounds=(2, 2)),
    OpSpec("=", "comparison", "binary", alias_of="==",
           note="equality spelling used by the equation/display layer"),
    # --- logical (esm-spec §4.2 Conditionals + boolean literals) ---
    OpSpec("and", "logical", "nary", arity_bounds=(2, None)),
    OpSpec("or", "logical", "nary", arity_bounds=(2, None)),
    OpSpec("not", "logical", "unary", arity_bounds=(1, 1)),
    OpSpec("true", "logical", "nullary", note="boolean-literal constant (spec §4.2)"),
    OpSpec("false", "logical", "nullary", note="boolean-literal constant"),
    # --- conditional ---
    OpSpec("ifelse", "conditional", "ternary", arity_bounds=(3, 3)),
    # --- calculus (esm-spec §4.2 Calculus) ---
    OpSpec("D", "calculus", "unary", arity_bounds=(1, 1),
           note="STRUCTURAL time-derivative LHS (`wrt` 't', or absent): STRICTLY UNARY. "
                "A REWRITE-TARGET D (spatial `wrt`) relaxes to "
                "REWRITE_TARGET_DERIVATIVE_ARITY_BOUNDS — see "
                "`is_rewrite_target_derivative`"),
    OpSpec("ic", "calculus", "unary", arity_bounds=(1, 1),
           note="initial-condition declaration (esm-spec §11.4)"),
    # --- event-specific (esm-spec §4.2 Event-specific / §5) ---
    OpSpec("Pre", "event", "unary", arity_bounds=(1, 1)),
    # --- closed-registry invocation (esm-spec §4.4 / §4.5 / §9.5) ---
    OpSpec("fn", "closed_registry", "variadic", note="closed function call; carries `name`"),
    OpSpec("enum", "closed_registry", "binary", arity_bounds=(2, 2),
           note="[enum_name, symbol]; lowered at load"),
    OpSpec("table_lookup", "closed_registry", "nullary",
           note="args empty; `table`/`axes` fields; lowered at load"),
    # --- expression templates (esm-spec §9.6) ---
    OpSpec("apply_expression_template", "template", "nullary",
           note="args empty; `name`/`bindings` fields; expanded at load"),
    # --- inline constants (esm-spec §4.2 Inline Constants) ---
    OpSpec("const", "constant", "nullary", arity_bounds=(0, 0),
           note="args empty; literal in `value`"),
    # --- array / tensor (esm-spec §4.2 Array / Tensor, §4.3) ---
    OpSpec("aggregate", "array", "special", note="FAQ semiring aggregate"),
    OpSpec("makearray", "array", "special"),
    OpSpec("index", "array", "variadic"),
    OpSpec("broadcast", "array", "variadic", note="carries scalar `fn`"),
    OpSpec("reshape", "array", "unary", note="carries `shape`"),
    OpSpec("transpose", "array", "unary", note="optional `perm`"),
    OpSpec("concat", "array", "variadic", note="carries `axis`"),
    # --- relational / value-invention (esm-spec §4.2 FAQ companions; RFC §5) ---
    OpSpec("skolem", "relational", "variadic", note="build-time value invention"),
    OpSpec("rank", "relational", "variadic", note="build-time dense IDs"),
    OpSpec("argmin", "relational", "special", note="index-returning reduction"),
    OpSpec("argmax", "relational", "special", note="index-returning reduction"),
    OpSpec("distinct", "relational", "variadic",
           note="dedup reducer / aggregate distinct flag (cadence guard)"),
    OpSpec("join", "relational", "special", note="equi-join gate (cadence guard)"),
    # --- geometry kernel leaves (esm-spec §8.6) ---
    OpSpec("intersect_polygon", "geometry", "binary", note="clipped overlap ring; carries `manifold`"),
    OpSpec("polygon_intersection_area", "geometry", "binary",
           note="fused scalar overlap area; carries `manifold`"),
    # --- open-tier rewrite-target sugar (esm-spec §4.2) is NOT registered ---
    # grad/div/laplacian/curl/integral are ORDINARY open-tier rewrite-target ops
    # with NO privilege over any other user op (`godunov_hamiltonian`): no
    # dimensional rule (dimension UNDETERMINABLE until lowered, §4.8.3/§4.8.4), no
    # evaluator (a discretization rule MUST lower them, `unlowered_operator`
    # otherwise), no privileged ARITY (structural validation skips their operand
    # count exactly as it does for an unregistered op), and they are NOT used for
    # spatial detection (that is now derived structurally from variable shapes /
    # the `dim` field — see `flatten`). They are therefore left UNregistered: the
    # display/codegen generic `op(args)` fallback renders them without warning,
    # exactly like `godunov_hamiltonian`. `integral`'s ∫ rendering reads its own
    # `var`/`lower`/`upper` sidecar fields via a structural `op == "integral"`
    # branch in `display`, which needs no registry entry.
)


#: The canonical registry: op string -> :class:`OpSpec`. This is the object
#: renderers/dispatchers cross-check against.
OPS: dict[str, OpSpec] = {spec.name: spec for spec in _ALL}


def names() -> frozenset[str]:
    """All op strings in the registry (canonical ops **and** spelling aliases)."""
    return frozenset(OPS)


def canonical_names() -> frozenset[str]:
    """Op strings that are canonical (not a spelling alias of another op)."""
    return frozenset(name for name, spec in OPS.items() if spec.alias_of is None)


def by_category(category: str) -> frozenset[str]:
    """All op names in ``category`` (including any aliases in that category)."""
    return frozenset(name for name, spec in OPS.items() if spec.category == category)


def by_tier(tier: str) -> frozenset[str]:
    """All op names in ``tier`` (``"core"`` or ``"rewrite_target"``)."""
    return frozenset(name for name, spec in OPS.items() if spec.tier == tier)


def unary_elementary() -> frozenset[str]:
    """The elementary-function ops that take a single argument.

    These are exactly the ops that dispatch through a single unary callable in
    the evaluator (``numpy_interpreter._SCALAR_FUNCS``) and the SymPy bridge
    (``expression._UNARY_SYMPY``, which additionally excludes ``abs`` and adds
    the unary logical ``not``). Excludes ``atan2`` (binary) and ``min``/``max``
    (n-ary). The single source those two value-tables derive their key sets from.
    """
    return frozenset(
        name for name, spec in OPS.items()
        if spec.category == "elementary" and spec.arity == "unary"
    )


def arity_bounds_map() -> dict[str, tuple[int, int | None]]:
    """``op -> (min_args, max_args)`` for every op that carries a structural
    arity contract (``max_args`` ``None`` = unbounded).

    This is the single source ``structural_checks._OPERATOR_ARITY`` derives from:
    exactly the ops whose :attr:`OpSpec.arity_bounds` is set (array / relational /
    geometry / closed-registry-field ops, spelling aliases, and boolean literals
    have no fixed operand count and are absent, so structural validation skips
    their arity exactly as before).
    """
    return {
        name: spec.arity_bounds
        for name, spec in OPS.items()
        if spec.arity_bounds is not None
    }


#: The ``wrt`` value that marks the STRUCTURAL time derivative. A ``D`` node with
#: this ``wrt`` — or with no ``wrt`` at all, which means the same thing — is the
#: evaluable-core, equation-LHS derivative consumed by system assembly.
STRUCTURAL_DERIVATIVE_WRT: str = "t"

#: Arity bounds a REWRITE-TARGET ``D`` relaxes to (esm-spec §4.2 "Arity of `D`").
#: ``args[0]`` is still the differentiated operand, so the minimum stays 1; the
#: maximum is UNBOUNDED because how many auxiliary boundary/halo fields a
#: discretization scheme needs is a property of the scheme, not of the format.
REWRITE_TARGET_DERIVATIVE_ARITY_BOUNDS: tuple[int, int | None] = (1, None)


def is_rewrite_target_derivative(op: str, wrt: str | None) -> bool:
    """True for a ``D`` whose ``wrt`` names a SPATIAL axis (esm-spec §4.2 / §9.6.8).

    Such a node has no evaluator — it MUST be lowered to a stencil by a
    discretization rule — which is exactly why it MAY carry trailing auxiliary
    operands after ``args[0]``: the per-face boundary/halo values the rule binds
    as ordinary §9.6.1 wildcards and consumes. The STRUCTURAL time derivative
    (``wrt`` :data:`STRUCTURAL_DERIVATIVE_WRT`, or absent) is *not* a
    rewrite-target and stays strictly unary.

    This is the ONE op whose operand contract depends on a FIELD of the node
    rather than on the op string alone, so it lives here — the registry — and
    every checker inherits it instead of re-deriving the predicate.
    """
    return op == "D" and (wrt or STRUCTURAL_DERIVATIVE_WRT) != STRUCTURAL_DERIVATIVE_WRT


def is_known(op: str) -> bool:
    """True iff ``op`` is part of the canonical AST op vocabulary.

    Used by :mod:`.lower_expression_templates` to classify an op as an
    evaluable-core registry op versus an open-namespace rewrite-target op (a
    custom op, or the unregistered sugar grad/div/laplacian/curl/integral, none
    of which are in the registry): an op that is not known is a rewrite-target
    tier **T** member by virtue of having no evaluable-core entry.
    """
    return op in OPS
