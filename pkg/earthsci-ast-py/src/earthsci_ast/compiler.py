"""Which strategy builds a Problem's right-hand side (``API_SPEC.md`` §5.8,
esm-libraries-spec §2.5.10).

``esm_problem(..., compiler=...)`` names one member of a CLOSED vocabulary —
``native``, ``interpreter``, ``xla``, ``mtk``, ``sympy`` — and the Problem
reports back both the value that built it and, per rule, the tier each rule
landed on. Before this module the Python binding chose between a lambdified
SymPy form and the NumPy interpreter by inspecting the document, and then chose
among the interpreter's seven fast tiers per aggregate at evaluation time, and
neither choice was expressible or readable by a caller.

Three things live here.

**The vocabulary and its refusals.** :func:`resolve_compiler` maps the keyword
to a member or raises: ``compiler_unknown`` outside the vocabulary,
``compiler_unavailable`` for ``xla`` / ``mtk``, which this binding does not
provide. Neither is ever answered by building with a different compiler — the
point of naming one is that the caller knows which ran.

**The policy.** A :class:`CompilerPolicy` is the compiler's choice made
AMBIENT for the duration of a build: :func:`use_policy` installs one on a
:class:`~contextvars.ContextVar` that the NumPy interpreter's aggregate ladder
reads. Ambient rather than threaded through every ``EvalContext`` on purpose:
under ``native`` the refusal must fire wherever a per-cell walk is reached, and
a context that was built without the policy would refuse nothing while
reporting that ``native`` ran. An evaluation outside any :func:`use_policy`
scope — a unit test driving a synthetic context, say — sees no policy and
behaves exactly as it did before this module existed.

**The recorder.** Each tier of the ladder calls :meth:`CompilerPolicy.decline`
with its own name and the reason it could not take the node, and the tier that
answers calls :meth:`CompilerPolicy.land`. The accumulated declines travel with
the landing, so a rule that ends on the per-cell walk carries the whole chain
that put it there — which is what a ``native`` refusal names, and what
:attr:`~earthsci_ast.problem.EsmProblem.compiler_report` shows for a rule that
landed on a fast tier.
"""

from __future__ import annotations

import contextvars
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Literal

from .error_handling import (
    COMPILER_REFUSED_RULE,
    COMPILER_UNAVAILABLE,
    COMPILER_UNKNOWN,
)
from .errors import SimulationError

#: The closed vocabulary, in the order §5.8's table lists it. Every binding has
#: the same five members; which of them it PROVIDES is per-binding.
COMPILERS: tuple[str, ...] = ("native", "interpreter", "xla", "mtk", "sympy")

#: The type a caller's ``compiler`` keyword takes.
Compiler = Literal["native", "interpreter", "xla", "mtk", "sympy"]

#: The vocabulary members Python does not provide, and what would have to exist
#: for each. Named in the refusal so the message is the ruling, not a machine's
#: configuration.
_UNAVAILABLE: dict[str, str] = {
    "xla": (
        "the Python binding has no StableHLO emitter; XLA lowering lives in the "
        "Julia binding (through Reactant) and in the Rust binding (the `xla` "
        "cargo feature), and providing it here would mean writing one"
    ),
    "mtk": (
        "ModelingToolkit is a Julia package and has no Python equivalent this "
        "binding could load; `compiler='mtk'` is available in the Julia binding "
        "only, which is also the only place events and implicit equations run"
    ),
}

#: The per-cell tiers: a Python tree walk per output cell. Under ``native``
#: reaching one of these is :data:`COMPILER_REFUSED_RULE`; under ``interpreter``
#: it is where every aggregate lands by design.
PER_CELL_TIERS: frozenset[str] = frozenset({"scalar", "scalar-gate-driven", "ragged"})


class CompilerUnknownError(SimulationError):
    """``compiler_unknown``: the value is outside the closed vocabulary."""

    code = COMPILER_UNKNOWN

    def __init__(self, value: object) -> None:
        self.value = value
        super().__init__(
            f"compiler_unknown: {value!r} is not a compiler; the closed vocabulary "
            f"(API_SPEC.md §5.8) is {', '.join(repr(c) for c in COMPILERS)}"
        )


class CompilerUnavailableError(SimulationError):
    """``compiler_unavailable``: in the vocabulary, but not provided here."""

    code = COMPILER_UNAVAILABLE

    def __init__(self, value: str, reason: str) -> None:
        self.value = value
        self.reason = reason
        super().__init__(
            f"compiler_unavailable: the Python binding cannot provide "
            f"compiler={value!r} — {reason}. A compiler this binding does not "
            f"have is refused, never substituted (esm-libraries-spec §2.5.10)."
        )


class CompilerRefusedRuleError(SimulationError):
    """``compiler_refused_rule``: this compiler cannot run this rule.

    Raised at CONSTRUCTION, naming the compiler, the rule (an equation or an
    observed, component-qualified) and the reason. Never a fallback: the rule is
    not then run on a slower path.
    """

    code = COMPILER_REFUSED_RULE

    def __init__(
        self,
        compiler: str,
        rule: str,
        reason: str,
        *,
        declines: tuple[tuple[str, str], ...] = (),
        phase: str = "construction",
    ) -> None:
        self.compiler = compiler
        self.rule = rule
        self.reason = reason
        self.declines = declines
        self.phase = phase
        chain = (
            "".join(f"\n    {tier}: {why}" for tier, why in declines)
            if declines
            else "\n    (no fast tier was attempted)"
        )
        super().__init__(
            f"compiler_refused_rule: compiler={compiler!r} cannot run {rule} "
            f"({phase}) — {reason}. The tiers that declined, fastest first:{chain}\n"
            f"  A refusal is not a fallback: {compiler!r} will not run this rule on "
            f"a slower path. Build with compiler='interpreter' to run it per cell, "
            f"or with compiler='sympy' if the document is scalar."
        )


def resolve_compiler(value: str | None) -> str:
    """The vocabulary member ``value`` names, or the refusal it earns.

    ``None`` means ``native``: the default is strict, and a binding MUST NOT
    read an unspecified compiler as permission to pick a slower one on the
    grounds that the document is small or awkward (esm-libraries-spec §2.5.10).
    """
    if value is None:
        return "native"
    if not isinstance(value, str):
        raise CompilerUnknownError(value)
    if value not in COMPILERS:
        raise CompilerUnknownError(value)
    if value in _UNAVAILABLE:
        raise CompilerUnavailableError(value, _UNAVAILABLE[value])
    return value


# --------------------------------------------------------------------------- #
# The per-rule report
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class RuleTier:
    """One rule's landing: which tier answered, and what declined first.

    ``rule`` is the equation or observed, component-qualified, in the spelling
    the refusal would name. ``phase`` is WHEN the evaluation happened — a
    Python build evaluates rules in three places (§2.5.10 puts all three under
    the compiler), and the census found six sevenths of the per-cell landings in
    the first of them:

    * ``construction`` — the const-geometry hoist and the static-observed
      materialization, inside ``esm_problem`` itself;
    * ``rhs`` — one evaluation of the right-hand side;
    * ``observed-output`` — the observeds reported at output times.

    ``declines`` is the chain that led here, fastest tier first, as
    ``(tier, reason)`` pairs.
    """

    rule: str
    phase: str
    tier: str
    declines: tuple[tuple[str, str], ...] = ()

    @property
    def per_cell(self) -> bool:
        """Did this rule land on a Python walk per output cell?"""
        return self.tier in PER_CELL_TIERS

    def __str__(self) -> str:  # pragma: no cover - display only
        chain = " ← ".join(t for t, _ in self.declines)
        via = f" (declined: {chain})" if chain else ""
        return f"{self.rule} [{self.phase}] → {self.tier}{via}"


class CompilerReport:
    """Per rule, the tier it landed on and what declined on the way.

    One entry per aggregate LANDING, not per rule: a rule whose body holds two
    aggregates, or whose aggregate is re-evaluated in a second phase, produces
    an entry each, which is what makes the record a cost story rather than a
    summary. A rule with no aggregate at all produces no entry — the whole
    ladder this records is the ``faq`` ladder — so :meth:`rules` is the rules
    that had a tier to land on.
    """

    def __init__(self) -> None:
        self._entries: list[RuleTier] = []
        self._seen: set[RuleTier] = set()

    def add(self, entry: RuleTier) -> None:
        """Record a landing, ONCE per distinct (rule, phase, tier, chain).

        A right-hand side is evaluated thousands of times in a solve and the
        ladder's answer for a given node does not change between them, so a
        record that appended per call would grow without bound and say nothing
        the first entry did not. Deduplicating makes the report the cost story
        §5.8 describes rather than a log — which is also why the counts in
        :meth:`tiers` are DISTINCT landings, not evaluations.
        """
        if entry in self._seen:
            return
        self._seen.add(entry)
        self._entries.append(entry)

    @property
    def entries(self) -> tuple[RuleTier, ...]:
        return tuple(self._entries)

    def rules(self) -> tuple[str, ...]:
        """Every rule that landed somewhere, in first-landing order."""
        seen: dict[str, None] = {}
        for e in self._entries:
            seen.setdefault(e.rule, None)
        return tuple(seen)

    def for_rule(self, rule: str) -> tuple[RuleTier, ...]:
        return tuple(e for e in self._entries if e.rule == rule)

    def tiers(self) -> dict[str, int]:
        """Landing counts by tier — the one-line cost summary."""
        out: dict[str, int] = {}
        for e in self._entries:
            out[e.tier] = out.get(e.tier, 0) + 1
        return out

    def per_cell_rules(self) -> tuple[str, ...]:
        """The rules that walked per cell. Empty under a build that survived
        ``native``, by construction."""
        seen: dict[str, None] = {}
        for e in self._entries:
            if e.per_cell:
                seen.setdefault(e.rule, None)
        return tuple(seen)

    def __iter__(self) -> Iterator[RuleTier]:
        return iter(self._entries)

    def __len__(self) -> int:
        return len(self._entries)

    def __bool__(self) -> bool:
        return bool(self._entries)

    def __repr__(self) -> str:  # pragma: no cover - display only
        return f"CompilerReport({len(self._entries)} landings, tiers={self.tiers()})"

    def __str__(self) -> str:  # pragma: no cover - display only
        return "\n".join(str(e) for e in self._entries) or "CompilerReport: no aggregates"


# --------------------------------------------------------------------------- #
# The policy: the compiler's choice, made ambient for one build
# --------------------------------------------------------------------------- #


@dataclass
class CompilerPolicy:
    """The active compiler, its strictness, and the report it is filling.

    ``strict`` (``native``) makes a per-cell landing a
    :class:`CompilerRefusedRuleError`. ``every_tier_off`` (``interpreter``)
    sends every aggregate to the per-cell walk and turns the source codegen and
    the shape-interval hull off, so the reference evaluator is a genuinely
    second implementation rather than the fast one with a flag flipped.
    """

    compiler: str
    strict: bool = False
    every_tier_off: bool = False
    report: CompilerReport = field(default_factory=CompilerReport)
    #: The rule currently being evaluated, set by :func:`rule_scope`. ``None``
    #: means the evaluation is not attributable to one rule — the setup passes
    #: that resolve index sets and invent values — and is recorded as ``<setup>``.
    rule: str | None = None
    #: Which of §2.5.10's three evaluations is running, set by :func:`phase_scope`.
    phase: str = "construction"
    # Per-NODE decline accumulators, one frame per aggregate node currently in
    # the ladder. A STACK rather than one list because an aggregate body may hold
    # another aggregate: the inner node's ladder runs inside the outer node's
    # tier, and with one list the inner landing would consume the outer node's
    # chain. `rule_scope` clears the stack at each rule boundary, so a frame left
    # behind by an evaluation that raised cannot leak into the next rule.
    _frames: list[list[tuple[str, str]]] = field(default_factory=list)
    # Whether the whole-box tier that is about to land got its body from
    # generated source (`numpy_codegen`) rather than the compiled closure. Set
    # by `_codegen_box_fn`, read once by the landing.
    _codegen: bool = False

    # -- the ladder's hooks ------------------------------------------------- #

    def begin_node(self) -> None:
        """A fresh aggregate node enters the ladder."""
        self._frames.append([])
        self._codegen = False

    def decline(self, tier: str, reason: str) -> None:
        """``tier`` could not take the innermost node, for ``reason``."""
        if not self._frames:
            self._frames.append([])
        self._frames[-1].append((tier, reason))

    def _pop_declines(self) -> tuple[tuple[str, str], ...]:
        return tuple(self._frames.pop()) if self._frames else ()

    def note_codegen(self, used: bool) -> None:
        """Whether the box body about to be evaluated is generated source."""
        self._codegen = used

    def land(self, tier: str) -> None:
        """``tier`` answered this node. Records the landing and the chain."""
        if tier in ("broadcast", "map") and self._codegen:
            tier = "codegen"
        self.report.add(
            RuleTier(
                rule=self.rule or "<setup>",
                phase=self.phase,
                tier=tier,
                declines=self._pop_declines(),
            )
        )
        self._codegen = False

    def land_per_cell(self, tier: str) -> None:
        """A per-cell walk is about to run. Under ``native`` it never does.

        The refusal is raised HERE rather than at the ladder's exit because the
        walk is the expensive thing: a caller who asked for vectorized NumPy
        must not pay for one cell of it.
        """
        if self.strict:
            declines = self._pop_declines()
            reason = declines[-1][1] if declines else "no fast tier applies"
            raise CompilerRefusedRuleError(
                self.compiler,
                self.rule or "<setup>",
                reason,
                declines=declines,
                phase=self.phase,
            )
        self.land(tier)


_ACTIVE: contextvars.ContextVar[CompilerPolicy | None] = contextvars.ContextVar(
    "earthsci_ast_compiler_policy", default=None
)


def active_policy() -> CompilerPolicy | None:
    """The policy in force, or ``None`` outside every :func:`use_policy` scope."""
    return _ACTIVE.get()


@contextmanager
def use_policy(policy: CompilerPolicy | None) -> Iterator[CompilerPolicy | None]:
    """Install ``policy`` for the duration of the block."""
    token = _ACTIVE.set(policy)
    try:
        yield policy
    finally:
        _ACTIVE.reset(token)


@contextmanager
def rule_scope(rule: str) -> Iterator[None]:
    """Attribute every landing inside the block to ``rule``. A no-op with no
    policy installed, which is what keeps the attribution free for a caller who
    did not ask for a report."""
    policy = _ACTIVE.get()
    if policy is None:
        yield
        return
    previous = policy.rule
    policy.rule = rule
    policy._frames.clear()
    try:
        yield
    finally:
        policy.rule = previous
        policy._frames.clear()


@contextmanager
def phase_scope(phase: str) -> Iterator[None]:
    """Record every landing inside the block under ``phase``."""
    policy = _ACTIVE.get()
    if policy is None:
        yield
        return
    previous = policy.phase
    policy.phase = phase
    try:
        yield
    finally:
        policy.phase = previous


def every_tier_off() -> bool:
    """Is the reference evaluator selected? Read by the tiers that are OFF under
    ``interpreter`` but live outside the aggregate ladder — the source codegen
    and the shape-inference interval hull."""
    policy = _ACTIVE.get()
    return policy is not None and policy.every_tier_off
