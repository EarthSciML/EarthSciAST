"""
Unit validation and dimensional analysis for ESM Format.

Provides unit validation functionality using the pint library to ensure
dimensional consistency across models, reaction systems, and expressions.

The registry is CLOSED: it is exactly the flat table of esm-spec §4.8.1, and
nothing else resolves. See :data:`_CONTRACT_DEFINITIONS`.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

from .esm_types import EsmFile, Expr, ExprNode, Model, ReactionSystem

# ---------------------------------------------------------------------------
# The shared ESM unit contract (esm-spec §4.8 / docs/content/units-standard.md).
#
# The registry is a FLAT, EXACT-MATCH TABLE with **no SI-prefix mechanism**. A
# symbol is either one of the names below or the unit string does not resolve.
# This is a deliberate narrowing, not an oversight:
#
#   * A prefix mechanism makes the legal-unit-string set unbounded and therefore
#     un-pinnable across five bindings: it silently accepts `kmolec`, `nppb`,
#     `Tunits`. Worse, it is AMBIGUOUS against the table — `T` is TESLA but also
#     reads as tera-, and `M` is MOLAR but also reads as mega-.
#   * The cost is that a new prefixed unit is a one-line addition here. That is
#     the intended trade.
#
# pint is used for the DIMENSION ALGEBRA only. Its default registry is a wild
# superset of the contract (~1050 names, a full prefix mechanism, imperial
# units, physical constants as units), and every extra name is a silent
# wrong-dimension hazard now that a unit finding is a hard error. Three of them
# were live defects against this corpus:
#
#   1. ``units`` — pint has no unit by that name, so its prefix mechanism
#      resolved it as ``u`` + ``nit`` = MICRO-NIT, a LUMINANCE. The corpus
#      declares ``units/L`` and ``units/s``; both silently acquired a luminosity
#      dimension. The contract says ``units`` is a dimensionless COUNT NOUN.
#   2. ``molec`` — pint aliased it to ``particle`` (= 1/N_A mol), i.e.
#      [substance]. The contract says ``molec/cm^3`` MUST be ``[length]^-3``.
#   3. ``C`` — must be the COULOMB (SI), never Celsius.
#
# ``pint.UnitRegistry(filename=None)`` builds an EMPTY registry: no units, no
# dimensions, and — crucially — no prefixes. Defining only the table below is
# therefore what DISABLES the prefix mechanism; there is no prefix left to
# apply. (`km` resolves because it is a table entry, not because `k` is a
# prefix: with `m` defined and no prefixes, pint rejects `Tm` and `dam`.)
# ---------------------------------------------------------------------------

#: The contract table, in pint definition syntax, in dependency order.
#: ``name = <definition> = _ = <alias>`` — the ``_`` suppresses a symbol so the
#: third field reads as an alias. A bare scale (``ppm = 1e-6``) registers a
#: scaling of the EMPTY dimension; writing ``1e-6 * dimensionless`` instead
#: trips a pint bug that stores ``dimensionless`` as a reference name and then
#: fails conversion with ``KeyError: ''``.
_CONTRACT_DEFINITIONS: tuple[str, ...] = (
    # --- the eight canonical axes (esm-spec §4.8.1) -------------------------
    # `rad` is an axis, not a dimensionless alias: an angle is tracked so that
    # `deg` and `rad` are commensurate with each other and with nothing else.
    "m = [length]",
    "kg = [mass]",
    "s = [time]",
    "mol = [substance]",
    "K = [temperature]",
    "A = [current]",
    "cd = [luminosity]",
    "rad = [angle]",
    # --- mass ---------------------------------------------------------------
    "g = 1e-3 kg",
    "mg = 1e-6 kg",
    "ug = 1e-9 kg",
    # --- length -------------------------------------------------------------
    "dm = 1e-1 m",
    "cm = 1e-2 m",
    "mm = 1e-3 m",
    "um = 1e-6 m",
    "nm = 1e-9 m",
    "km = 1e3 m",
    # --- time ---------------------------------------------------------------
    "ms = 1e-3 s",
    "us = 1e-6 s",
    "ns = 1e-9 s",
    "min = 60 s",
    "h = 3600 s",
    "hr = 3600 s",
    # The canonical spelling of a day is `day`. `d` is DELIBERATELY EXCLUDED from
    # the table (§4.8.1): a one-letter `d` reads as a deci- prefix or as a
    # differential, so it is precisely the kind of symbol the flat table exists to
    # keep out. Nothing here defines it, so `units: "d"` does not resolve — which
    # is the intended answer, not a gap.
    "day = 86400 s",
    # Julian year (365.25 days) — the astronomical/climate convention.
    "yr = 31557600 s",
    "year = 31557600 s",
    # --- volume -------------------------------------------------------------
    "L = 1e-3 m ** 3",
    "l = 1e-3 m ** 3",
    "mL = 1e-6 m ** 3",
    # --- amount -------------------------------------------------------------
    "kmol = 1e3 mol",
    "mmol = 1e-3 mol",
    "umol = 1e-6 mol",
    "nmol = 1e-9 mol",
    "M = mol / L",  # MOLAR — never mega-
    # --- derived ------------------------------------------------------------
    "Hz = 1 / s",
    "N = kg * m / s ** 2",
    "Pa = N / m ** 2",
    "J = N * m",
    "kJ = 1e3 J",
    "cal = 4.184 J",
    "kcal = 4184 J",
    "W = J / s",
    "kW = 1e3 W",
    "MW = 1e6 W",
    # --- pressure -----------------------------------------------------------
    "atm = 101325 Pa",
    "bar = 1e5 Pa",
    "hPa = 100 Pa",
    "kPa = 1e3 Pa",
    "mbar = 100 Pa",
    "Torr = 101325 / 760 Pa",
    "mmHg = 133.322387415 Pa",
    "psi = 6894.757293168361 Pa",
    "uatm = 1e-6 atm",
    # --- energy -------------------------------------------------------------
    "erg = 1e-7 J",
    "BTU = 1055.05585262 J",
    "Wh = 3600 J",
    "kWh = 3.6e6 J",
    # --- electromagnetic ----------------------------------------------------
    "C = A * s",  # COULOMB — never Celsius
    "V = kg * m ** 2 / (A * s ** 3)",
    "Ohm = V / A",
    "F = C / V",
    "T = kg / (A * s ** 2)",  # TESLA — never tera-
    # --- temperature / angle ------------------------------------------------
    # Affine offsets are NOT modelled (esm-spec §4.8.1): degC/degF carry the
    # Kelvin DIMENSION and their SCALE; the zero offset is irrelevant to
    # dimensional analysis. A conversion that needs the offset is a
    # `unit_conversion` expression, not a dimensional judgement.
    "degC = K",
    "degF = 5 / 9 K",
    "deg = 0.017453292519943295 rad",
    # --- mixing ratios (dimensionless) --------------------------------------
    # ppmv/ppbv/pptv are volume-mixing-ratio spellings that equal ppm/ppb/ppt
    # under the ideal-gas approximation, so every binding treats them as one.
    "ppm = 1e-6 = _ = ppmv",
    "ppb = 1e-9 = _ = ppbv",
    "ppt = 1e-12 = _ = pptv",
    # --- counts (DIMENSIONLESS) ---------------------------------------------
    # A count of discrete things carries no physical dimension: scale 1 over the
    # empty dimension (`[]`). This is what makes `molec/cm^3` == `1/cm^3`.
    "molec = [] = _ = molecule",
    "count = [] = _",
    "individuals = [] = _",
    "vehicles = [] = _",
    "units = [] = _",
    # --- column amount (dimensionless count per area) ------------------------
    # 1 Dobson = 2.6867e20 molec/m^2; `molec` is dimensionless, so [length]^-2.
    "Dobson = 2.6867e20 / m ** 2 = _ = DU",
    # --- misc ---------------------------------------------------------------
    "percent = 1e-2 = %",
    "psu = [] = _",  # practical salinity — a dimensionless ratio
    # --- long-form aliases the contract admits ------------------------------
    "@alias m = meter = meters",
    "@alias h = hour",
    "@alias degC = Celsius",
    "@alias deg = degree = degrees",
)

try:
    import pint

    PINT_AVAILABLE = True
    #: An EMPTY pint registry — no units, no dimensions, NO PREFIX MECHANISM —
    #: populated with exactly the contract table. This is the whole narrowing.
    ureg = pint.UnitRegistry(filename=None)
    for _definition in _CONTRACT_DEFINITIONS:
        ureg.define(_definition)
    UnitsContainer = pint.util.UnitsContainer

except ImportError:
    PINT_AVAILABLE = False
    ureg = None
    UnitsContainer = Any


class DimensionalMismatchError(ValueError):
    """A PROVABLE dimensional inconsistency found while typing an expression.

    Distinct from "could not determine the dimension" (which is signalled by
    returning ``None``) and from :class:`UnparseableUnitError` ("this string
    does not denote a real unit"). Both this exception and
    ``UnparseableUnitError`` are defects in the FILE and are promoted to
    validation ERRORS; only an indeterminate dimension (``None``) is skipped.

    It subclasses ``ValueError`` so that pre-existing
    ``except ValueError`` callers keep catching it.
    """


class UnparseableUnitError(ValueError):
    """A declared unit string that does not denote a real unit.

    This is a defect in the FILE, not a limit of the checker: if ``"not_a_unit"``
    or ``"1/time"`` is written where a unit belongs, the document is malformed
    and no amount of analysis can rescue it. It is therefore a HARD ERROR, the
    same severity as a provable dimensional mismatch — and the same call the
    other bindings make (Go's ``UnitFindingUnparseable``, TS's ``unit_error``).

    Contrast with a GENUINELY UNDETERMINABLE dimension — a symbolic exponent
    (``x^n``), an op with no dimensional rule (``aggregate``/``index``/``fn``/
    ``table_lookup``), an undeclared variable — which is a statement about the
    checker and stays a WARNING (signalled by ``None``, never by an exception).
    """


#: The three spellings of "no units" the shared contract accepts.
_DIMENSIONLESS_SPELLINGS = frozenset({"", "1", "dimensionless"})

#: Units whose real-world conversion needs an additive OFFSET, which the
#: contract deliberately does not model (esm-spec §4.8.1): the registry gives
#: them the Kelvin dimension and their scale only. A caller computing a
#: multiplicative conversion FACTOR must therefore refuse to compute one for
#: these, rather than silently reporting the (dimensionally correct but
#: physically wrong) pure scale.
AFFINE_UNITS = frozenset({"degC", "degF", "Celsius"})


def has_affine_unit(unit: str | None) -> bool:
    """True if ``unit`` mentions a unit whose conversion requires an offset."""
    if not unit:
        return False
    return any(re.search(rf"\b{sym}\b", unit) for sym in AFFINE_UNITS)


#: Exception types pint can raise from a garbage unit string. Beyond its own
#: ``PintError`` hierarchy (``UndefinedUnitError``, ``DefinitionSyntaxError``,
#: …) the tokenizer leaks ``SyntaxError`` for e.g. an embedded NUL byte, and the
#: string preprocessor can leak ``ValueError``/``TypeError``/``AttributeError``/
#: ``KeyError``. Every one of them means the same thing — "this is not a unit" —
#: so :func:`parse_unit` re-raises them all as :class:`UnparseableUnitError`.
#: The tuple is deliberately explicit rather than a bare ``except Exception`` so
#: that a genuine bug in this module still propagates.
_UNIT_PARSE_ERRORS: tuple[type[BaseException], ...] = (
    (pint.errors.PintError, SyntaxError, ValueError, TypeError, AttributeError, KeyError)
    if PINT_AVAILABLE
    else (SyntaxError, ValueError, TypeError, AttributeError, KeyError)
)


#: Unicode → ASCII rewrites applied BEFORE parsing (esm-spec §4.8.2). A pure
#: SPELLING normalization: no unit is invented, every target is already a table
#: entry. Longest-first so ``°C`` wins over a bare ``°``.
#:
#: Spelled with explicit ``\u`` ESCAPES, never with the literal glyph. Several of
#: these characters have a visually identical twin at another codepoint
#: (``Ω`` U+03A9 GREEK CAPITAL OMEGA vs ``Ω`` U+2126 OHM SIGN; ``µ`` U+00B5 MICRO
#: SIGN vs ``μ`` U+03BC GREEK SMALL MU), and an editor, a formatter, or a
#: copy-paste through an NFC-normalizing tool will silently collapse one onto the
#: other — leaving a rewrite table that LOOKS like it covers both and covers only
#: one. That is exactly what happened here: both omega entries were written as
#: literals and both ended up as U+03A9, so `Ω*m` spelled with the OHM SIGN was
#: rejected while the source read as though it were handled.
_UNICODE_REWRITES: tuple[tuple[str, str], ...] = (
    ("\u00b0C", "degC"),
    ("\u00b0F", "degF"),
    ("\u00b0K", "K"),
    ("\u00b0", "deg"),  # bare DEGREE SIGN
    ("\u00b5", "u"),  # MICRO SIGN
    ("\u03bc", "u"),  # GREEK SMALL LETTER MU
    ("\u00b7", "*"),  # MIDDLE DOT
    ("\u22c5", "*"),  # DOT OPERATOR
    ("\u03a9", "Ohm"),  # GREEK CAPITAL LETTER OMEGA
    ("\u2126", "Ohm"),  # OHM SIGN
)

#: Unicode superscript digits / minus → the ASCII exponent they denote, so that
#: ``m⁻³`` normalizes to ``m^-3``.
#:
#: ENUMERATED, never a character range: the superscript digits are NOT contiguous
#: in Unicode. ``¹`` (U+00B9), ``²`` (U+00B2) and ``³`` (U+00B3) live in Latin-1
#: Supplement, while ``⁰⁴⁵⁶⁷⁸⁹`` live at U+2070+. A ``[⁰-⁹]`` class —
#: the obvious spelling — silently drops exactly the three exponents that
#: actually occur in real unit strings (``m²``, ``cm³``, ``W/m²``).
_SUPERSCRIPTS: dict[str, str] = {
    "\u2070": "0",
    "\u00b9": "1",  # Latin-1 Supplement, NOT U+2071
    "\u00b2": "2",  # Latin-1 Supplement
    "\u00b3": "3",  # Latin-1 Supplement
    "\u2074": "4",
    "\u2075": "5",
    "\u2076": "6",
    "\u2077": "7",
    "\u2078": "8",
    "\u2079": "9",
    "\u207b": "-",  # SUPERSCRIPT MINUS
}


def normalize_unit_string(unit: str) -> str:
    """Rewrite the non-ASCII spellings the corpus uses into the ASCII grammar.

    Applies the esm-spec §4.8.1 pre-parse normalization, identically in every
    binding: superscript runs (``⁻³``) become ``^-3``; ``·``/``⋅`` become ``*``;
    ``µ``/``μ`` become ``u``; ``°C`` becomes ``degC``; ``Ω`` becomes ``Ohm``.
    """
    for src, dst in _UNICODE_REWRITES:
        unit = unit.replace(src, dst)
    if not any(ch in _SUPERSCRIPTS for ch in unit):
        return unit
    # A RUN of superscripts is one exponent: `m⁻¹²` is `m^-12`, not `m^-1^2`.
    out: list[str] = []
    run: list[str] = []
    for ch in unit:
        if ch in _SUPERSCRIPTS:
            run.append(_SUPERSCRIPTS[ch])
            continue
        if run:
            out.append("^" + "".join(run))
            run = []
        out.append(ch)
    if run:
        out.append("^" + "".join(run))
    return "".join(out)


# ---------------------------------------------------------------------------
# The unit-string grammar (esm-spec §4.8.2), enforced BEFORE pint sees the
# string:
#
#     unit     := term (('*' | '/')? term)*        # a bare space is '*'
#     term     := atom (('^' | '**') exponent)?
#     exponent := sign? (integer | decimal) | '(' sign? int '/' sign? int ')'
#     atom     := number | symbol | '(' unit ')'
#
# pint's own parser is LOOSER than this in ways that matter. It evaluates the
# string as Python, so `kg**2**3` silently means `kg**8` (right-associative
# chained power) — not in the grammar, and a typo that would otherwise pass. It
# also has its own preprocessor whose acceptance surface is not the contract's.
# Gating on our own tokenizer means the set of legal unit STRINGS is the
# contract's, not pint's, and the symbol table is checked explicitly (which
# yields the exact "not in the ESM unit table" message rather than pint's
# prefix-flavoured guesswork).
#
# EXPONENTS ARE RATIONAL, deliberately: `1/s^0.5` is the noise coefficient of a
# scalar SDE and appears in the corpus. `integer | decimal | (p/q)` are all
# admissible.
# ---------------------------------------------------------------------------

_TOKEN_RE = re.compile(
    r"""
      (?P<space>\s+)
    | (?P<pow>\*\*|\^)
    | (?P<mul>\*)
    | (?P<div>/)
    | (?P<lpar>\()
    | (?P<rpar>\))
    | (?P<sign>[+-])
    | (?P<number>\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)
    | (?P<symbol>%|[A-Za-z_][A-Za-z0-9_]*)
    """,
    re.VERBOSE,
)


class _UnitGrammar:
    """Recursive-descent gate for the §4.8.2 grammar. Raises
    :class:`UnparseableUnitError` on anything outside it."""

    def __init__(self, text: str, original: str):
        self.original = original
        self.toks: list[tuple[str, str]] = []
        pos = 0
        while pos < len(text):
            m = _TOKEN_RE.match(text, pos)
            if not m:
                self.fail(f"unexpected character {text[pos]!r}")
            pos = m.end()
            kind = m.lastgroup
            if kind != "space":
                self.toks.append((kind, m.group()))
        self.i = 0

    def fail(self, why: str):
        raise UnparseableUnitError(f"'{self.original}' is not a valid unit string: {why}")

    def peek(self) -> str | None:
        return self.toks[self.i][0] if self.i < len(self.toks) else None

    def take(self) -> tuple[str, str]:
        tok = self.toks[self.i]
        self.i += 1
        return tok

    def parse(self) -> None:
        if not self.toks:
            self.fail("empty")
        self.unit()
        if self.i != len(self.toks):
            self.fail(f"trailing {self.toks[self.i][1]!r}")

    def unit(self) -> None:
        self.term()
        while True:
            kind = self.peek()
            if kind in ("mul", "div"):
                self.take()
                self.term()
            elif kind in ("number", "symbol", "lpar"):
                # Whitespace between terms IS multiplication (§4.8.2):
                # "ppb^-1 s^-1" is ppb⁻¹·s⁻¹.
                self.term()
            else:
                return

    def term(self) -> None:
        self.atom()
        if self.peek() == "pow":
            self.take()
            self.exponent()
            if self.peek() == "pow":
                # `kg**2**3` is not in the grammar. pint would read it as
                # kg**(2**3) = kg**8; the contract rejects it outright.
                self.fail("chained exponent (`a^b^c`) is not a unit expression")

    def exponent(self) -> None:
        if self.peek() == "lpar":
            # A rational exponent: `(1/2)`, `(-3/2)`.
            self.take()
            self.signed_number()
            if self.peek() != "div":
                self.fail("a parenthesised exponent must be a rational `(p/q)`")
            self.take()
            self.signed_number()
            if self.peek() != "rpar":
                self.fail("unclosed exponent '('")
            self.take()
            return
        self.signed_number()

    def signed_number(self) -> None:
        if self.peek() == "sign":
            self.take()
        if self.peek() != "number":
            self.fail("an exponent must be an integer, a decimal, or a rational `(p/q)`")
        self.take()

    def atom(self) -> None:
        kind = self.peek()
        if kind is None:
            self.fail("unexpected end of input")
        if kind == "lpar":
            self.take()
            self.unit()
            if self.peek() != "rpar":
                self.fail("unclosed '('")
            self.take()
            return
        if kind == "number":
            self.take()
            return
        if kind == "symbol":
            _, name = self.take()
            if name not in _CONTRACT_SYMBOLS:
                # No prefix mechanism, no fallback: the table is the contract.
                self.fail(f"'{name}' is not in the ESM unit table (esm-spec §4.8.1)")
            return
        self.fail(f"unexpected {self.toks[self.i][1]!r}")


def _contract_symbols() -> frozenset[str]:
    """Every name the closed registry resolves — the §4.8.1 table plus its
    aliases, read back OFF the registry so the gate and pint can never drift."""
    if not PINT_AVAILABLE:
        return frozenset()
    return frozenset(ureg._units.keys())


#: The complete set of legal unit symbols. Nothing else parses.
_CONTRACT_SYMBOLS: frozenset[str] = _contract_symbols()


def parse_unit(unit: str | None):
    """Resolve a declared unit string to a pint ``Unit``.

    ``None`` and the dimensionless spellings (``""``, ``"1"``,
    ``"dimensionless"``) resolve to the dimensionless unit. Anything outside the
    §4.8.2 grammar, or naming a symbol outside the §4.8.1 table, raises
    :class:`UnparseableUnitError`.

    Uses ``ureg.parse_units`` rather than ``ureg(...)`` because the latter
    evaluates the string as a QUANTITY expression; ``parse_units`` yields the
    unit, which is all a dimensional judgement needs.
    """
    if not PINT_AVAILABLE:
        raise ImportError("pint library is required for unit parsing")
    if unit is None:
        return ureg.parse_units("")
    text = normalize_unit_string(unit).strip()
    if text in _DIMENSIONLESS_SPELLINGS:
        return ureg.parse_units("")
    # Gate on the contract grammar + table FIRST, so the accepted string set is
    # the spec's rather than pint's.
    _UnitGrammar(text, unit).parse()
    try:
        return ureg.parse_units(text)
    except _UNIT_PARSE_ERRORS as exc:
        raise UnparseableUnitError(f"'{unit}' does not denote a known unit: {exc}") from exc


def unit_dimensionality(unit: str | None) -> UnitsContainer:
    """The dimensionality container of a declared unit string.

    Raises :class:`UnparseableUnitError` when the string is not a unit.
    """
    return parse_unit(unit).dimensionality


# ---------------------------------------------------------------------------
# Operator dimension rules (esm-spec §4.2 evaluable core).
#
# The former catch-all `return dimensionless` for every non-arithmetic op was
# wrong in BOTH directions: it reported `max(P1, P2)` (both in Pa) as
# dimensionless, and it never checked that `sin`/`exp`/`log` arguments ARE
# dimensionless. Each op now states its rule explicitly, and anything not
# listed returns None ("unknown dimension") rather than manufacturing a false
# `dimensionless` — an unknown dimension is skipped by the callers, a
# dimensionless one would produce spurious mismatches.
# ---------------------------------------------------------------------------

#: n-ary ops whose operands must all share one dimension, which is also the
#: dimension of the result.
_DIM_PRESERVING_NARY = frozenset({"+", "-", "min", "max"})

#: Ops that carry through the dimension of their FIRST operand unchanged.
#: (`ic`/`Pre` are value-preserving form ops; `floor`/`ceil`/`abs` preserve
#: magnitude and therefore units.)
_DIM_PRESERVING_UNARY = frozenset({"abs", "floor", "ceil", "ic", "Pre"})

#: Elementary functions whose ARGUMENT must be dimensionless and whose result is
#: dimensionless. `sqrt` is deliberately NOT here — it halves the dimension —
#: and neither are the CIRCULAR functions, which have their own rules below.
_DIMENSIONLESS_ARG_FUNCS = frozenset(
    {
        "exp",
        "log",
        "ln",
        "log10",
        "sinh",
        "cosh",
        "tanh",
        "asinh",
        "acosh",
        "atanh",
    }
)

# ---------------------------------------------------------------------------
# Circular trigonometry, and why it is NOT just "argument must be dimensionless".
#
# `rad` is one of the eight canonical AXES (esm-spec §4.8.1), so an angle is a
# DIMENSION here — `rad` is not a spelling of "dimensionless". Two rules follow,
# and folding the circular functions into the generic transcendental set gets
# BOTH of them wrong, in opposite directions:
#
#   * `sin`/`cos`/`tan` take an ANGLE. Requiring a dimensionless argument
#     REJECTS `cos(gamma)` with `gamma` in `rad` — which is every line of
#     `lib/solar.esm`. They accept an angle OR a dimensionless number (a phase
#     in turns/cycles is written dimensionless), and return a dimensionless
#     ratio. `sin(kg)` is still an error.
#   * `asin`/`acos`/`atan` RETURN an angle. Reporting a dimensionless result
#     makes `solar_zenith_angle: "rad" = acos(...)` a GUARANTEED mismatch — a
#     live false rejection of the shipped stdlib.
# ---------------------------------------------------------------------------

#: Circular functions: argument is an ANGLE or dimensionless; result is a
#: dimensionless ratio.
_CIRCULAR_FUNCS = frozenset({"sin", "cos", "tan"})

#: Inverse circular functions: argument is a dimensionless ratio; result is an
#: ANGLE (`rad`). `atan2` is handled separately (it is binary).
_INVERSE_CIRCULAR_FUNCS = frozenset({"asin", "acos", "atan"})

#: Comparisons: operands must share a dimension; the result is a dimensionless
#: boolean.
_COMPARISON_OPS = frozenset({">", "<", ">=", "<=", "==", "!="})

#: Booleans (and `sign`, whose result is a dimensionless ±1) yield a
#: dimensionless result regardless of operand dimensions.
_DIMENSIONLESS_RESULT_OPS = frozenset({"and", "or", "not", "sign", "true"})


@dataclass
class UnitValidationResult:
    """Result of unit validation check."""

    is_valid: bool
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    unit_registry: dict[str, str] = field(default_factory=dict)  # variable_name -> unit_string
    dimensional_analysis: dict[str, Any] = field(default_factory=dict)


@dataclass
class UnitConversionResult:
    """Result of unit conversion operation."""

    success: bool
    converted_value: float | None = None
    conversion_factor: float | None = None
    error_message: str | None = None


class UnitValidator:
    """Validator for dimensional consistency in ESM format structures."""

    def __init__(self):
        """Initialize the unit validator."""
        if not PINT_AVAILABLE:
            raise ImportError(
                "pint library is required for unit validation. Install with: pip install pint"
            )

        self.ureg = ureg
        self.known_units: dict[str, pint.Quantity] = {}

    def validate_esm_file(self, esm_file: EsmFile) -> UnitValidationResult:
        """
        Validate unit consistency across an entire ESM file.

        Args:
            esm_file: The ESM file to validate

        Returns:
            UnitValidationResult with validation status and any issues found
        """
        result = UnitValidationResult(is_valid=True)

        if esm_file.models:
            self._merge_component_results(
                esm_file.models.values(), self.validate_model, "Model", result
            )

        if esm_file.reaction_systems:
            self._merge_component_results(
                esm_file.reaction_systems.values(),
                self.validate_reaction_system,
                "ReactionSystem",
                result,
            )

        result.is_valid = len(result.errors) == 0
        return result

    def _merge_component_results(self, components, validator, prefix, result):
        """Validate each component and fold its errors/warnings/registry into
        ``result``, prefixing every message with ``"{prefix} {name}: "``."""
        for component in components:
            sub = validator(component)
            result.errors.extend(f"{prefix} {component.name}: {e}" for e in sub.errors)
            result.warnings.extend(f"{prefix} {component.name}: {w}" for w in sub.warnings)
            result.unit_registry.update(sub.unit_registry)

    def validate_model(self, model: Model) -> UnitValidationResult:
        """
        Validate unit consistency within a model.

        Args:
            model: The model to validate

        Returns:
            UnitValidationResult for the model
        """
        result = UnitValidationResult(is_valid=True)

        # Scope the known-units registry to this component so that a variable
        # name reused in another model/reaction system cannot collide during
        # bare-name dimension lookups in _get_expression_dimension.
        self.known_units = {}

        if not model.variables:
            return result

        # Build unit registry for this model
        for var_name, var_info in model.variables.items():
            if var_info.units:
                try:
                    unit = parse_unit(var_info.units)
                    result.unit_registry[var_name] = var_info.units
                    self.known_units[var_name] = unit
                except UnparseableUnitError as e:
                    # An unparseable unit is a HARD ERROR: a string that does not
                    # denote a real unit is a defect in the FILE, not a limit of
                    # the checker (see UnparseableUnitError). The variable is
                    # still omitted from known_units, so it propagates as an
                    # unknown dimension and cannot ALSO manufacture a spurious
                    # dimensional-mismatch error downstream.
                    result.errors.append(
                        f"Invalid unit '{var_info.units}' for variable '{var_name}': {e}"
                    )

        # Validate equations
        if model.equations:
            for i, equation in enumerate(model.equations):
                eq_result = self.validate_equation(equation, f"eq_{i}")
                result.errors.extend(eq_result.errors)
                result.warnings.extend(eq_result.warnings)

        # Validate variable expressions
        for var_name, var_info in model.variables.items():
            if hasattr(var_info, "expression") and var_info.expression:
                expr_result = self.validate_expression(var_info.expression, var_name)
                if expr_result.errors:
                    result.errors.extend([f"Variable {var_name}: {e}" for e in expr_result.errors])

        result.is_valid = len(result.errors) == 0
        return result

    def validate_reaction_system(self, rs: ReactionSystem) -> UnitValidationResult:
        """
        Validate unit consistency within a reaction system.

        Args:
            rs: The reaction system to validate

        Returns:
            UnitValidationResult for the reaction system
        """
        result = UnitValidationResult(is_valid=True)

        # Scope the known-units registry to this component (see validate_model).
        self.known_units = {}

        # Register species units
        if rs.species:
            for species in rs.species:
                if species.units:
                    try:
                        unit = parse_unit(species.units)
                        result.unit_registry[species.name] = species.units
                        self.known_units[species.name] = unit
                    except UnparseableUnitError as e:
                        # Unparseable unit is a HARD ERROR (see validate_model);
                        # the species is still omitted from known_units, so it is
                        # treated as unknown downstream.
                        result.errors.append(
                            f"Invalid unit '{species.units}' for species '{species.name}': {e}"
                        )

        # Register parameter units
        if rs.parameters:
            for param in rs.parameters:
                if param.units:
                    try:
                        unit = parse_unit(param.units)
                        result.unit_registry[param.name] = param.units
                        self.known_units[param.name] = unit
                    except UnparseableUnitError as e:
                        # Unparseable unit is a HARD ERROR (see validate_model);
                        # the parameter is still omitted from known_units, so it
                        # is treated as unknown downstream.
                        result.errors.append(
                            f"Invalid unit '{param.units}' for parameter '{param.name}': {e}"
                        )

        # Validate reactions
        if rs.reactions:
            for reaction in rs.reactions:
                reaction_result = self._validate_reaction(reaction)
                result.errors.extend(reaction_result.errors)
                result.warnings.extend(reaction_result.warnings)

        result.is_valid = len(result.errors) == 0
        return result

    def validate_equation(self, equation, equation_id: str) -> UnitValidationResult:
        """
        Validate dimensional consistency of an equation.

        Args:
            equation: The equation to validate
            equation_id: Identifier for the equation (for error reporting)

        Returns:
            UnitValidationResult for the equation
        """
        result = UnitValidationResult(is_valid=True)

        try:
            lhs_dim = self._get_expression_dimension(equation.lhs)
            rhs_dim = self._get_expression_dimension(equation.rhs)

            if lhs_dim is not None and rhs_dim is not None:
                if not self._dimensions_compatible(lhs_dim, rhs_dim):
                    result.errors.append(
                        f"Equation {equation_id}: Dimensional mismatch - "
                        f"LHS has dimension {lhs_dim}, RHS has dimension {rhs_dim}"
                    )
        # A PROVABLE inconsistency inside the expression tree is an ERROR — it
        # used to be filed as a "could not validate" warning, which meant a
        # detected mismatch could never fail validation.
        except DimensionalMismatchError as e:
            result.errors.append(f"Equation {equation_id}: {e}")
        # PintError means we could not PARSE/convert a unit — genuinely
        # indeterminate, so a warning. Nothing broader is caught here: a bare
        # ValueError/AssertionError is a bug and must propagate rather than be
        # silently downgraded (this is exactly how C5 hid for so long).
        except pint.PintError as e:
            result.warnings.append(f"Could not validate dimensions for equation {equation_id}: {e}")

        result.is_valid = len(result.errors) == 0
        return result

    def validate_expression(self, expr: Expr, context: str = "") -> UnitValidationResult:
        """
        Validate dimensional consistency of an expression.

        Note:
            Bare variable names in ``expr`` are resolved against
            ``self.known_units``, which is populated as a side effect of a
            prior :meth:`validate_model` / :meth:`validate_reaction_system`
            call (each seeds it with that component's declared variable/species/
            parameter units, scoped per component). Called standalone on a fresh
            :class:`UnitValidator`, ``known_units`` is empty, so every bare-name
            operand resolves to "unknown dimension" and the check passes
            vacuously. Validate the enclosing model/reaction system (or invoke
            :func:`validate_units`) to get a meaningful result.

        Args:
            expr: The expression to validate
            context: Context string for error reporting

        Returns:
            UnitValidationResult for the expression
        """
        result = UnitValidationResult(is_valid=True)

        try:
            dimension = self._get_expression_dimension(expr)
            if dimension is not None:
                result.dimensional_analysis[context] = str(dimension)
        # A provable inconsistency is an error; an unparseable unit is only a
        # warning (see validate_equation). Nothing broader is caught, so a real
        # bug propagates instead of masquerading as a unit finding.
        except DimensionalMismatchError as e:
            result.errors.append(f"Expression validation failed for {context}: {e}")
        except pint.PintError as e:
            result.warnings.append(f"Could not validate dimensions for {context}: {e}")

        result.is_valid = len(result.errors) == 0
        return result

    def convert_units(self, value: float, from_unit: str, to_unit: str) -> UnitConversionResult:
        """
        Convert a value from one unit to another.

        Args:
            value: The numeric value to convert
            from_unit: Source unit string
            to_unit: Target unit string

        Returns:
            UnitConversionResult with converted value or error information
        """
        try:
            from_quantity = self.ureg.Quantity(value, from_unit)
            to_quantity = from_quantity.to(to_unit)

            return UnitConversionResult(
                success=True,
                converted_value=float(to_quantity.magnitude),
                conversion_factor=float(to_quantity.magnitude) / value if value != 0 else None,
            )
        except pint.PintError as e:
            return UnitConversionResult(success=False, error_message=str(e))

    def _get_expression_dimension(self, expr: Expr) -> UnitsContainer | None:
        """Get the dimensional analysis of an expression.

        ``None`` means "indeterminate" — it does NOT mean dimensionless.

        A bare NUMERIC LITERAL is dimension-POLYMORPHIC: it adopts whatever
        dimension its context requires, so it is reported as indeterminate and
        never constrains (nor contradicts) its neighbours. This is the contract
        the shared corpus pins, not a convenience:

          * ``tests/valid/minimal_chemistry.esm`` writes the Arrhenius rate as
            ``1.8e-12 * exp(-1370 / T) * M`` — the literal ``-1370`` is an
            activation TEMPERATURE, so ``-1370 / T`` is dimensionless only if
            the literal carries kelvin.
          * ``tests/valid/units_conversions.esm`` writes ``T_kelvin + (-273.15)``
            — the literal ``-273.15`` is a temperature.

        Typing a literal as ``dimensionless`` would report both of those
        (VALID) fixtures as dimensionally inconsistent. Treating it as
        indeterminate keeps every pinned ``units_*`` INVALID fixture rejected,
        because each of those states its inconsistency between two DECLARED
        quantities, never against a literal.
        """
        if isinstance(expr, bool):
            # A boolean is a genuine dimensionless truth value, not a
            # polymorphic numeric literal (bool is an int subclass in Python).
            return self.ureg.dimensionless.dimensionality

        if isinstance(expr, (int, float)):
            return None

        if isinstance(expr, str):
            # Variable lookup
            if expr in self.known_units:
                return self.known_units[expr].dimensionality
            # Undeclared symbol: unknown dimension, so it is skipped rather
            # than assumed dimensionless.
            return None

        if isinstance(expr, ExprNode):
            return self._get_expr_node_dimension(expr)

        return None

    @property
    def _dimensionless(self) -> UnitsContainer:
        return self.ureg.dimensionless.dimensionality

    @property
    def _angle(self) -> UnitsContainer:
        """The `[angle]` dimension — the axis `rad` and `deg` live on."""
        return self.ureg.parse_units("rad").dimensionality

    def _require_angle_or_dimensionless(self, dim: UnitsContainer | None, op: str) -> None:
        """Raise if ``dim`` is known and is neither an angle nor dimensionless.

        A circular function's argument is an ANGLE; a dimensionless argument is
        also admitted (a phase written as a pure number). Anything else —
        ``sin(kg)`` — is a provable inconsistency.
        """
        if dim is None:
            return
        if self._dimensions_compatible(dim, self._angle):
            return
        if self._dimensions_compatible(dim, self._dimensionless):
            return
        raise DimensionalMismatchError(
            f"{op} argument must be an angle or dimensionless, got {dim}"
        )

    def _agree(self, dims: list[UnitsContainer | None], op: str) -> UnitsContainer | None:
        """Require every KNOWN dimension in ``dims`` to be the same, and return
        it (or ``None`` if every operand's dimension is unknown).

        Unknown (``None``) operands are skipped rather than treated as
        dimensionless: an operand we cannot type must never manufacture a
        mismatch. Two *known* operands that disagree are a provable
        inconsistency.
        """
        known = [d for d in dims if d is not None]
        if not known:
            return None
        first = known[0]
        for dim in known[1:]:
            if not self._dimensions_compatible(first, dim):
                raise DimensionalMismatchError(f"Incompatible dimensions in {op}: {first} vs {dim}")
        return first

    def _require_dimensionless(self, dim: UnitsContainer | None, op: str, what: str) -> None:
        """Raise if ``dim`` is known and is NOT dimensionless."""
        if dim is not None and not self._dimensions_compatible(dim, self._dimensionless):
            raise DimensionalMismatchError(f"{op} {what} must be dimensionless, got {dim}")

    def _get_expr_node_dimension(self, node: ExprNode) -> UnitsContainer | None:
        """Get the dimension of an expression node (an operator with arguments).

        Returns ``None`` for "indeterminate" — an unknown operand, or an
        operator with no dimensional rule. ``None`` NEVER means dimensionless;
        callers skip the check entirely when they see it.

        Raises :class:`DimensionalMismatchError` on a provable inconsistency.
        """
        if not node.args:
            return None

        op = node.op
        arg_dims = [self._get_expression_dimension(arg) for arg in node.args]

        # n-ary dimension-preserving ops: every operand must agree.
        if op in _DIM_PRESERVING_NARY:
            return self._agree(arg_dims, op)

        # Unary carry-through ops.
        if op in _DIM_PRESERVING_UNARY:
            return arg_dims[0]

        if op in _DIMENSIONLESS_RESULT_OPS:
            return self._dimensionless

        if op in _COMPARISON_OPS:
            # Operands must be comparable; the boolean result is dimensionless.
            self._agree(arg_dims, op)
            return self._dimensionless

        if op in _DIMENSIONLESS_ARG_FUNCS:
            self._require_dimensionless(arg_dims[0], op, "argument")
            return self._dimensionless

        if op in _CIRCULAR_FUNCS:
            # sin/cos/tan take an ANGLE or a dimensionless number, and return a
            # dimensionless ratio. `sin(kg)` is still an error.
            self._require_angle_or_dimensionless(arg_dims[0], op)
            return self._dimensionless

        if op in _INVERSE_CIRCULAR_FUNCS:
            # asin/acos/atan take a dimensionless ratio and RETURN AN ANGLE.
            self._require_dimensionless(arg_dims[0], op, "argument")
            return self._angle

        if op == "atan2":
            # atan2(y, x): both operands share a dimension; the result is an ANGLE.
            self._agree(arg_dims, op)
            return self._angle

        if op == "sqrt":
            base = arg_dims[0]
            return None if base is None else base**0.5

        if op == "ifelse":
            # ifelse(cond, then, else): the condition is a dimensionless
            # boolean; the two branches must agree and give the result.
            if len(arg_dims) < 3:
                return None
            return self._agree(arg_dims[1:3], op)

        if op == "*":
            # A single unknown operand makes the whole product unknown —
            # folding only the KNOWN operands would report `unknown * t` as
            # [time], which is not the dimension of anything.
            if any(d is None for d in arg_dims):
                return None
            result = self._dimensionless
            for dim in arg_dims:
                result = result * dim
            return result

        if op == "/":
            # POSITIONAL: numerator is args[0], every later operand divides it.
            # (The former code filtered None out of the operand list and then
            # indexed it positionally, so `unknown / t` reported [time] — the
            # exact inverse of the right answer.)
            if any(d is None for d in arg_dims):
                return None
            result = arg_dims[0]
            for dim in arg_dims[1:]:
                result = result / dim
            return result

        if op == "^":
            base = arg_dims[0]
            exp_dim = arg_dims[1] if len(arg_dims) > 1 else None
            # An exponent must always be dimensionless, whatever the base is.
            self._require_dimensionless(exp_dim, op, "exponent")
            if base is None:
                return None
            if self._dimensions_compatible(base, self._dimensionless):
                return self._dimensionless
            # A dimensional base needs a literal exponent to give a dimension.
            if (
                len(node.args) > 1
                and isinstance(node.args[1], (int, float))
                and not isinstance(node.args[1], bool)
            ):
                return base ** node.args[1]
            return None

        if op == "D":
            # d(f)/d(wrt) has dimension dim(f) / dim(wrt). `wrt` is a sidecar
            # field, not an arg, and is often an undeclared time symbol — in
            # which case the dimension is indeterminate. Never assume seconds.
            wrt = getattr(node, "wrt", None)
            if arg_dims[0] is None or not wrt or wrt not in self.known_units:
                return None
            return arg_dims[0] / self.known_units[wrt].dimensionality

        # Structural / array / query / rewrite-target ops (index, aggregate,
        # fn, const, makearray, table_lookup, grad, ...) carry no dimensional
        # rule here. Report UNKNOWN, not dimensionless.
        return None

    def _dimensions_compatible(self, dim1: UnitsContainer, dim2: UnitsContainer) -> bool:
        """Check whether two DIMENSIONALITY containers denote the same dimension.

        ``dim1``/``dim2`` are pint *dimensionality* containers (e.g.
        ``[length]``), not units. The previous implementation built
        ``ureg.Quantity(1.0, dim1)`` from one and called ``q1.to(q2.units)``,
        which trips pint's ``assert len(names) == 1`` in ``_is_multiplicative``
        and raises a bare ``AssertionError`` for EVERY bracketed dimension —
        which the handler then swallowed, so the function returned ``True`` for
        every input pair and the whole dimensional check was dead code.

        Comparing the containers directly is both correct and total (it is the
        same test ``structural_checks._units_compatible`` already uses), so
        there is no exception path left to swallow a logic error.
        """
        return dim1 == dim2

    def _validate_reaction(self, reaction) -> UnitValidationResult:
        """Validate unit consistency in a single reaction."""
        result = UnitValidationResult(is_valid=True)

        # Check that rate constant has appropriate units
        if hasattr(reaction, "rate_constant") and reaction.rate_constant:
            if isinstance(reaction.rate_constant, (int, float, str)):
                # For now, just warn if no units specified
                result.warnings.append(
                    f"Reaction {reaction.name}: Rate constant has no explicit units"
                )
            elif isinstance(reaction.rate_constant, ExprNode):
                # Validate the rate constant expression
                expr_result = self.validate_expression(
                    reaction.rate_constant, f"rate_constant_{reaction.name}"
                )
                result.errors.extend(expr_result.errors)
                result.warnings.extend(expr_result.warnings)

        result.is_valid = len(result.errors) == 0
        return result


def validate_units(target: EsmFile | Model | ReactionSystem) -> UnitValidationResult:
    """
    Convenience function to validate units of an ESM structure.

    Args:
        target: The ESM file, model, or reaction system to validate

    Returns:
        UnitValidationResult with validation status and issues
    """
    validator = UnitValidator()

    if isinstance(target, EsmFile):
        return validator.validate_esm_file(target)
    if isinstance(target, Model):
        return validator.validate_model(target)
    if isinstance(target, ReactionSystem):
        return validator.validate_reaction_system(target)
    raise ValueError(f"Unsupported type for unit validation: {type(target)}")


def convert_units(value: float, from_unit: str, to_unit: str) -> UnitConversionResult:
    """
    Convenience function to convert units.

    Args:
        value: Numeric value to convert
        from_unit: Source unit string
        to_unit: Target unit string

    Returns:
        UnitConversionResult with conversion result
    """
    validator = UnitValidator()
    return validator.convert_units(value, from_unit, to_unit)
