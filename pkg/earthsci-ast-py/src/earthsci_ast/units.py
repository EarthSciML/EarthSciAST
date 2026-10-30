"""
Unit validation and dimensional analysis for ESM Format.

Provides unit validation functionality using the pint library to ensure
dimensional consistency across models, reaction systems, and expressions.

The registry is CLOSED: it is exactly the flat table of esm-spec §4.8.1, and
nothing else resolves. See :data:`_CONTRACT_DEFINITIONS`.
"""

from __future__ import annotations

import math
import re
from collections import ChainMap
from collections.abc import Mapping
from dataclasses import dataclass, field, replace
from fractions import Fraction
from typing import Any, NamedTuple

from . import op_registry
from .classification import observed_definitions
from .esm_types import EsmFile, Expr, ExprNode, Model, ReactionSystem
from .expr_walk import map_children

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
    # The international avoirdupois pound, exact by definition since 1959:
    # 1 lb is exactly 0.45359237 kg -- and exactly `short_ton` / 2000, so the
    # table used to hold the DERIVED unit and not the one it is defined in.
    # US emission rates are tabulated in it: MOVES's NONROAD brake-specific fuel
    # consumption is `lb/(hp*h)` and its gasoline density constant CMFGAS is
    # 6.237 lb/gal.
    "lb = 0.45359237 kg",
    # The two tons, both spelled UNAMBIGUOUSLY and neither spelled `ton`.
    # A bare `ton` is three different masses depending on the country and the
    # decade (short 907.18474 kg, metric 1000 kg, long 1016.0469088 kg), and a
    # unit table whose job is to make a declared unit mean ONE thing cannot
    # contain a name that means three. `t` is excluded for the same reason `d`
    # is: a one-letter mass symbol reads as tera- to half its readers.
    #   * `short_ton` — exactly 2000 international pounds
    #     (2000 * 0.45359237 kg). This is what a US emissions inventory means by
    #     "tons": the FF10 ANN_VALUE column, and InMAP's own
    #     907184740000 ug/short_ton emission-conversion constant.
    #   * `tonne` — the metric ton, 1000 kg, which is what the rest of the world
    #     means. Present so that the disambiguation is a CHOICE a document makes
    #     rather than a unit it cannot express.
    "short_ton = 2000 lb",
    "tonne = 1e3 kg",
    # --- length -------------------------------------------------------------
    "dm = 1e-1 m",
    "cm = 1e-2 m",
    "mm = 1e-3 m",
    "um = 1e-6 m",
    "nm = 1e-9 m",
    "km = 1e3 m",
    # The international foot, exact by definition (1959): 1 ft is exactly
    # 0.3048 m. It is in the table because emission inventories are written in
    # it — the EPA FF10 point-source format stores STKHGT and STKDIAM in feet —
    # and a format for air-quality models that cannot spell the unit its own
    # input files use forces every such column to be declared in a unit it is
    # not stored in, which is a lie the dimensional checker cannot catch.
    # It has no long-form alias: `foot`/`feet` are pinned as REJECTS by
    # tests/conformance/unit_registry, so the imperial family is symbol-only.
    "ft = 0.3048 m",
    # The international mile, exact by definition since the same 1959 agreement:
    # 1 mi = 5280 ft = 1609.344 m. The US onroad transportation inventory is
    # written in it end to end — EPA MOVES stores `link.linkLength` in miles,
    # `link.linkAvgSpeed` in `mi/h`, and its whole activity model is built on
    # vehicle-MILES travelled — so a table with `ft` and not `mi` could spell a
    # stack height and not a road. `mi/h` composes; `mph` is deliberately not a
    # name, and neither are `in` and `yd`, which no corpus column uses.
    "mi = 1609.344 m",
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
    # The US liquid gallon, exact by definition: 231 in^3 = 3.785411784 L
    # (NIST SP 811 App. B) — NOT the imperial gallon, which is 20% larger.
    # US fuel data is per gallon: MOVES stores `fueltype.fuelDensity` in g/gal,
    # its refuelling spill rate in g/gal, and its dioxin and metal emission
    # rates in g/gal.
    "gal = 3.785411784 L",
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
    # Mechanical (imperial) horsepower — 550 ft*lbf/s = 745.6998715822702 W
    # (NIST SP 811 App. B gives 7.456 999 E+02 W). Written as the ft*lbf/s
    # product of this table's OWN `ft` and `lb` and standard gravity rather than
    # as an opaque literal, so it cannot drift away from the two entries that
    # define it; pint evaluates the product left to right, so the result is the
    # same bits the other four bindings compute. NOT the metric horsepower
    # (PS, 735.49875 W), which is a different unit by 1.4%. Engine ratings are
    # the axis MOVES's NONROAD model bins on: `nrsourceusetype.hpAvg` is
    # horsepower and every `nremissionrate` row is `g/(hp*h)`.
    "hp = 550 * ft * lb * 9.80665 * m / s ** 3",
    # --- pressure -----------------------------------------------------------
    "atm = 101325 Pa",
    "bar = 1e5 Pa",
    "hPa = 100 Pa",
    "kPa = 1e3 Pa",
    "mbar = 100 Pa",
    "Torr = 101325 / 760 Pa",
    "mmHg = 133.322387415 Pa",
    # Inch of mercury — exactly 25.4 mmHg, the conventional value (NIST SP 811).
    # US barometric datasets store pressure in inHg; without this entry such a
    # column has no honest declaration, because a unit string carries no numeric
    # scale factor, so `25.4 mmHg` cannot be spelled either.
    "inHg = 3386.388640341 Pa",
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
    # Solid angle — the steradian, `sr = rad ** 2` (esm-spec §4.8.1). `rad` is an
    # axis, so a solid angle is that axis SQUARED, not a ninth axis (just as an
    # area is `m ** 2`). Spherical-mesh cell areas — a patch of the unit sphere,
    # e.g. an MPAS Voronoi cell or a Girard triangle — declare `units: "sr"`.
    "sr = rad ** 2",
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

# ---------------------------------------------------------------------------
# Exact unit scales (esm-spec §4.8.1 "Scales are EXACT").
#
# pint does the DIMENSION algebra here, and pint's conversion factors are
# floats. A scale AGREEMENT (`m + km`, `m/s = mi/h`) is decided on an exact
# number instead: a product of prime powers and a power of pi, each with a
# rational exponent, so `mi` is 2^4 * 3^2 * 5^-3 * 11 * 127 and `sqrt(km)` is
# still exact. Floats never decide a verdict.
# ---------------------------------------------------------------------------


class ExactScale:
    """An exact, positive unit scale: prime powers times a power of pi."""

    __slots__ = ("_pi", "_primes")

    def __init__(self, primes: dict[int, Fraction] | None = None, pi: Fraction = Fraction(0)):
        self._primes = {p: Fraction(e) for p, e in (primes or {}).items() if e != 0}
        self._pi = Fraction(pi)

    @classmethod
    def one(cls) -> ExactScale:
        return cls()

    @classmethod
    def integer(cls, n: int) -> ExactScale:
        if n <= 0:
            raise ValueError("a unit scale must be positive")
        primes: dict[int, Fraction] = {}
        rest, p = n, 2
        while p * p <= rest:
            while rest % p == 0:
                primes[p] = primes.get(p, Fraction(0)) + 1
                rest //= p
            p += 1 if p == 2 else 2
        if rest > 1:
            primes[rest] = primes.get(rest, Fraction(0)) + 1
        return cls(primes)

    @classmethod
    def ratio(cls, num: int, den: int) -> ExactScale:
        return cls.integer(num) / cls.integer(den)

    @classmethod
    def pow10(cls, k: int) -> ExactScale:
        return cls({2: Fraction(k), 5: Fraction(k)})

    @classmethod
    def pi(cls) -> ExactScale:
        return cls(pi=Fraction(1))

    @classmethod
    def decimal(cls, literal: str) -> ExactScale:
        """The exact value of a positive decimal literal (``"0.3048"``,
        ``"2.6867e20"``), read from its TEXT, never through a float."""
        value = Fraction(literal)
        return cls.integer(value.numerator) / cls.integer(value.denominator)

    def __mul__(self, other: ExactScale) -> ExactScale:
        primes = dict(self._primes)
        for p, e in other._primes.items():
            primes[p] = primes.get(p, Fraction(0)) + e
        return ExactScale(primes, self._pi + other._pi)

    def __truediv__(self, other: ExactScale) -> ExactScale:
        primes = dict(self._primes)
        for p, e in other._primes.items():
            primes[p] = primes.get(p, Fraction(0)) - e
        return ExactScale(primes, self._pi - other._pi)

    def __pow__(self, exponent) -> ExactScale:
        r = Fraction(exponent)
        return ExactScale({p: e * r for p, e in self._primes.items()}, self._pi * r)

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, ExactScale):
            return NotImplemented
        return self._primes == other._primes and self._pi == other._pi

    def __hash__(self) -> int:
        return hash((tuple(sorted(self._primes.items())), self._pi))

    def is_one(self) -> bool:
        return not self._primes and self._pi == 0

    def __float__(self) -> float:
        value = math.pi ** float(self._pi)
        for p in sorted(self._primes):
            value *= float(p) ** float(self._primes[p])
        return value

    def ratio_string(self) -> str | None:
        """``p/q``, ``p/q*pi`` or ``p/q*pi^k`` in lowest terms (``/q`` omitted
        when it is 1) -- the spelling tests/conformance/unit_registry pins.
        ``None`` when an exponent is not whole (``sqrt(km)``)."""
        if self._pi.denominator != 1 or any(e.denominator != 1 for e in self._primes.values()):
            return None
        value = Fraction(1)
        for p, e in self._primes.items():
            value *= Fraction(p) ** int(e)
        text = str(value.numerator)
        if value.denominator != 1:
            text += f"/{value.denominator}"
        k = int(self._pi)
        if k == 1:
            text += "*pi"
        elif k != 0:
            text += f"*pi^{k}"
        return text

    def __repr__(self) -> str:
        text = self.ratio_string()
        return f"ExactScale({text if text is not None else float(self)!r})"

    __str__ = __repr__


_E = ExactScale
_FOOT = _E.decimal("0.3048")
_POUND = _E.decimal("0.45359237")
_GRAVITY = _E.decimal("9.80665")

#: The exact scale of every registry symbol whose scale is not 1, keyed by the
#: name pint resolves it to (aliases -- `meter`, `hour`, `DU`, `ppmv`, `%` --
#: resolve to these names). A symbol missing here is read as exactly 1, which is
#: why ``tests/test_unit_exact_scales.py`` checks every contract symbol against
#: pint's own float factor.
_EXACT_SCALES: dict[str, ExactScale] = {
    "g": _E.pow10(-3),
    "mg": _E.pow10(-6),
    "ug": _E.pow10(-9),
    "lb": _POUND,
    "short_ton": _E.integer(2000) * _POUND,
    "tonne": _E.pow10(3),
    "dm": _E.pow10(-1),
    "cm": _E.pow10(-2),
    "mm": _E.pow10(-3),
    "um": _E.pow10(-6),
    "nm": _E.pow10(-9),
    "km": _E.pow10(3),
    "ft": _FOOT,
    "mi": _E.integer(5280) * _FOOT,
    "ms": _E.pow10(-3),
    "us": _E.pow10(-6),
    "ns": _E.pow10(-9),
    "min": _E.integer(60),
    "h": _E.integer(3600),
    "hr": _E.integer(3600),
    "day": _E.integer(86400),
    "yr": _E.integer(31557600),
    "year": _E.integer(31557600),
    "L": _E.pow10(-3),
    "l": _E.pow10(-3),
    "mL": _E.pow10(-6),
    "gal": _E.decimal("0.003785411784"),
    "kmol": _E.pow10(3),
    "mmol": _E.pow10(-3),
    "umol": _E.pow10(-6),
    "nmol": _E.pow10(-9),
    "M": _E.pow10(3),
    "kJ": _E.pow10(3),
    "cal": _E.decimal("4.184"),
    "kcal": _E.integer(4184),
    "kW": _E.pow10(3),
    "MW": _E.pow10(6),
    "hp": _E.integer(550) * _FOOT * _POUND * _GRAVITY,
    "atm": _E.integer(101325),
    "bar": _E.pow10(5),
    "hPa": _E.pow10(2),
    "kPa": _E.pow10(3),
    "mbar": _E.pow10(2),
    "Torr": _E.ratio(101325, 760),
    "mmHg": _E.decimal("133.322387415"),
    "inHg": _E.decimal("3386.388640341"),
    "psi": _POUND * _GRAVITY / _E.decimal("0.0254") ** 2,
    "uatm": _E.decimal("0.101325"),
    "erg": _E.pow10(-7),
    "BTU": _E.decimal("1055.05585262"),
    "Wh": _E.integer(3600),
    "kWh": _E.integer(3600000),
    "degF": _E.ratio(5, 9),
    "deg": _E.pi() / _E.integer(180),
    "ppm": _E.pow10(-6),
    "ppb": _E.pow10(-9),
    "ppt": _E.pow10(-12),
    "Dobson": _E.decimal("2.6867e20"),
    "percent": _E.pow10(-2),
}


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
    (``x^n``), an op with no dimensional rule (``faq``/``index``/``fn``/
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
#     atom     := '1' | symbol | '(' unit ')'
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
            _, text = self.take()
            # A numeric atom is admissible ONLY when its value is exactly 1 —
            # the leading `1` of `1/s`. Any other number is a SCALING FACTOR,
            # and a unit string denotes a UNIT, not a quantity. `(m/s)^-1/3` —
            # an author reaching for a rational exponent — parses under this
            # grammar as `((m/s)^-1)/3`, and the five bindings gave it three
            # different meanings (magnitude dropped, magnitude retained, whole
            # string rejected). Rejecting the scaling factor makes `^(-1/3)` the
            # only spelling of that unit. Python already refused it, but only
            # DOWNSTREAM in pint ("Unit expression cannot have a scaling
            # factor"), which named neither the rule nor the fix.
            if float(text) != 1.0:
                self.fail(
                    "a number other than 1 is a scaling factor, not a unit (esm-spec 4.8.2); a rational exponent is spelled ^(p/q)"
                )
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


def exact_scale_of(unit) -> ExactScale:
    """The exact scale of a parsed pint ``Unit`` (esm-spec §4.8.1).

    Read from the unit's symbol exponents and the exact table, never from pint's
    float conversion factor.
    """
    scale = ExactScale.one()
    for name, exponent in unit._units.items():
        entry = _EXACT_SCALES.get(name)
        if entry is not None:
            scale = scale * entry ** Fraction(exponent).limit_denominator(1000)
    return scale


class ConstUnitsError(Exception):
    """Raised for declared ``units`` on an expression node a document's ``esm``
    version does not admit. Carries the stable diagnostic ``code`` (esm-spec
    §4.8.5) alongside the message, like ``SolverBlockError``."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def reject_const_units_pre_v12(view: Any) -> None:
    """Reject declared ``units`` on any expression node in a document declaring
    ``esm`` < 1.2.0 (esm-spec §4.8.5 item 6), naming the first offending node.
    Runs on the raw JSON before schema validation, like the ``solver`` gate."""
    if not isinstance(view, dict):
        return
    esm = view.get("esm")
    if not isinstance(esm, str):
        return
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", esm)
    if not m or (int(m.group(1)), int(m.group(2))) >= (1, 2):
        return

    def find(value: Any, at: str) -> str | None:
        if isinstance(value, dict):
            if "op" in value and "units" in value:
                return at
            for key, child in value.items():
                hit = find(child, f"{at}/{key}")
                if hit is not None:
                    return hit
        elif isinstance(value, list):
            for i, child in enumerate(value):
                hit = find(child, f"{at}/{i}")
                if hit is not None:
                    return hit
        return None

    path = find(view, "")
    if path is not None:
        from .error_handling import CONST_UNITS_VERSION_TOO_OLD

        raise ConstUnitsError(
            CONST_UNITS_VERSION_TOO_OLD,
            f"declared `units` on an expression node require esm >= 1.2.0; file declares "
            f"{esm}. Offending path: {path}",
        )


def unresolvable_const_units(expr: Any) -> list[str]:
    """Every declared ``const`` unit string in ``expr`` (a raw JSON expression
    or an ``ExprNode``) that does not resolve (esm-spec §4.8.5 item 2)."""
    out: list[str] = []

    def walk(node: Any) -> None:
        if isinstance(node, ExprNode):
            node = {"op": node.op, "units": node.units, "args": node.args}
        if isinstance(node, dict):
            units = node.get("units")
            if node.get("op") == "const" and isinstance(units, str):
                try:
                    parse_unit(units)
                except UnparseableUnitError:
                    out.append(units)
            for child in node.values():
                walk(child)
        elif isinstance(node, list):
            for child in node:
                walk(child)

    walk(expr)
    return out


def unit_exact_scale(unit: str | None) -> ExactScale:
    """The exact scale of a declared unit string.

    Raises :class:`UnparseableUnitError` when the string is not a unit.
    """
    return exact_scale_of(parse_unit(unit))


class _Typed(NamedTuple):
    """A subexpression's dimension together with its exact scale."""

    dim: UnitsContainer
    scale: ExactScale


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

#: The registry spellings of the dimensionless-but-SCALED units, most common
#: first, used to NAME a scale in a diagnostic (`... (ppm); divide by 1 ppm ...`).
#:
#: A fixed, ORDERED table rather than a reverse sweep of the registry: the
#: registry is a dict keyed by pint's resolved name, so a sweep would pick
#: `ppmv` or `ppm` depending on insertion order and the five bindings would
#: print different messages for the same document. The same table, in the same
#: order, is in every binding.
_SCALED_DIMENSIONLESS_SPELLINGS: tuple[tuple[str, int], ...] = (
    ("percent", -2),
    ("ppm", -6),
    ("ppb", -9),
    ("ppt", -12),
)


def scaled_dimensionless_spelling(scale: ExactScale) -> str | None:
    """The canonical registry spelling of a dimensionless unit at ``scale``
    (``1/100`` -> ``percent``, ``1e-6`` -> ``ppm``), or ``None``."""
    for name, k in _SCALED_DIMENSIONLESS_SPELLINGS:
        if ExactScale.pow10(k) == scale:
            return name
    return None


def scaled_dimensionless_message(op: str, scale: ExactScale) -> str:
    """The esm-spec §4.8.3 refusal for a dimensionless-but-SCALED argument to an
    op that requires a PURE NUMBER (issue #409).

    It names the REPAIR, not only the refusal: the author states the reading by
    dividing by a quantity carrying the scale, which costs one node and records
    the decision in the document. Normalizing silently instead would change the
    numbers of every document that already passes a ``percent`` or a ``ppm``
    into ``exp``/``log``. The same sentence is in every binding.
    """
    shown = scale.ratio_string() or float(scale)
    name = scaled_dimensionless_spelling(scale)
    if name is not None:
        return (
            f"Argument to '{op}' must be dimensionless at scale 1, but is "
            f"dimensionless at scale {shown} ({name}); divide by 1 {name}, or by "
            f"the scale you mean, to state which reading is intended"
        )
    return (
        f"Argument to '{op}' must be dimensionless at scale 1, but is "
        f"dimensionless at scale {shown}; divide by a quantity carrying that "
        f"scale to state which reading is intended"
    )


#: Circular functions: argument is an ANGLE or dimensionless; result is a
#: dimensionless ratio.
_CIRCULAR_FUNCS = frozenset({"sin", "cos", "tan"})

#: The array operators that carry their ELEMENT's unit, in the checker and on
#: the evaluation path (`UnitValidator._type_array_element`, esm-spec §4.8.3).
_ARRAY_ELEMENT_OPS = frozenset(
    {"faq", "makearray", "index", "reshape", "transpose", "concat", "broadcast"}
)

#: The dimensionality of a PLANE angle (`rad**1`). `sr` is `rad**2` and is NOT
#: this: no conversion turns a solid angle into a plane one, and multiplying by
#: `scale` where `scale**2` was meant would be silently wrong.
_ANGLE_DIMENSIONALITY = unit_dimensionality("rad")

#: Inverse circular functions: argument is a dimensionless ratio; result is an
#: ANGLE (`rad`). `atan2` is handled separately (it is binary).
_INVERSE_CIRCULAR_FUNCS = frozenset({"asin", "acos", "atan"})

#: Comparisons: operands must share a dimension; the result is a dimensionless
#: boolean.
_COMPARISON_OPS = frozenset({">", "<", ">=", "<=", "==", "!="})

#: Booleans, the boolean literals, and `sign` (whose result is a dimensionless
#: ±1) yield a dimensionless result regardless of operand dimensions.
_DIMENSIONLESS_RESULT_OPS = frozenset({"and", "or", "not", "sign", "true", "false"})

#: The places where an angle meeting a pure number counts as dimensionless
#: (esm-spec §4.8.3 "An angle meets a pure number"): the operands of these
#: ops, an equation's two sides, and a pure-number argument. NOT `atan2`,
#: `concat` or `makearray`, which keep the strict rule.
_ANGLE_AGREEMENT_OPS = frozenset({"+", "-", "min", "max", "ifelse"}) | _COMPARISON_OPS


def _is_pure_angle(dim) -> bool:
    """A dimension that is a nonzero power of ``[angle]`` and nothing else."""
    axes = {axis for axis, power in dim.items() if power != 0}
    return axes == {"[angle]"}


def _is_pure_number(dim) -> bool:
    return not any(power != 0 for power in dim.values())


def _angle_as_number(typed: _Typed) -> _Typed:
    """``typed`` (a pure angle) with its ``[angle]`` axis removed and its exact
    scale KEPT: ``rad`` becomes a pure number at scale 1, ``deg`` one at
    scale π/180 (esm-spec §4.8.3 "An angle meets a pure number")."""
    return _Typed(typed.dim / typed.dim, typed.scale)


def _angle_meets_number(a: _Typed, b: _Typed) -> tuple[_Typed, _Typed]:
    """The pair to compare when ``a`` and ``b`` meet at an equation side or an
    agreement position: a pure angle meeting a pure number loses its angle
    axis; anything else is returned unchanged."""
    if _is_pure_angle(a.dim) and _is_pure_number(b.dim):
        return _angle_as_number(a), b
    if _is_pure_number(a.dim) and _is_pure_angle(b.dim):
        return a, _angle_as_number(b)
    return a, b


#: The unit-finding vocabulary -- the SECOND, smaller unit code set, shared
#: with Go's ``UnitFinding*``, Rust's ``UNIT_FINDING_*`` and TypeScript's
#: ``UnitWarning['code']`` union. It is NOT the ``unit_inconsistency`` /
#: ``unit_parse_error`` pair, which names the STRUCTURAL error a finding is
#: promoted to; these name the finding itself.
#:
#: A finding is either a defect in the FILE -- which invalidates the document --
#: or a limit of the ANALYSIS, which does not. The classification is decided AT
#: THE POINT the finding is raised and never recovered from the prose, so
#: rewording a message can never silently change its severity.

#: A PROVABLE inconsistency: metres added to kilograms, an equation whose sides
#: cannot agree. The file is wrong.
UNIT_FINDING_DIMENSIONAL_MISMATCH = "dimensional_mismatch"
#: A declared unit string that denotes no real unit. Meaningless declaration,
#: so a defect in the FILE, not in the checker.
UNIT_FINDING_UNPARSEABLE = "unparseable_unit"
#: The checker could not DETERMINE a dimension -- a symbolic exponent, an
#: operator with no dimensional rule, an unknown variable, a missing pint.
#: A statement about the checker, not the file.
UNIT_FINDING_ANALYSIS = "analysis"
#: A check the CURRENT neutral-literal rule skips or passes fails once a bare
#: numeric literal is read as dimensionless (esm-spec §4.8.6). A WARNING at this
#: stage: validity is decided by the current rule alone.
UNIT_FINDING_DIMENSIONLESS_LITERAL = "units_dimensionless_literal_mismatch"


@dataclass
class UnitFinding:
    """One coded dimensional-analysis finding.

    Carries the ``code`` decided at the raise site alongside the prose, so
    :func:`~earthsci_ast.validation.validate` can build a
    :class:`~earthsci_ast.validation.UnitWarning` without parsing the message.
    """

    code: str
    message: str
    lhs_units: str = ""
    rhs_units: str = ""


@dataclass
class UnitValidationResult:
    """Result of unit validation check."""

    is_valid: bool
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    unit_registry: dict[str, str] = field(default_factory=dict)  # variable_name -> unit_string
    dimensional_analysis: dict[str, Any] = field(default_factory=dict)
    #: The same findings as ``errors`` + ``warnings``, but CODED. The two prose
    #: lists are kept in step by :meth:`add_error` / :meth:`add_warning` and stay
    #: byte-identical to what they always held, so nothing reading them changes.
    findings: list[UnitFinding] = field(default_factory=list)

    def add_error(self, code: str, message: str, lhs_units: str = "", rhs_units: str = "") -> None:
        """Record a hard finding: the prose in ``errors``, the code in
        ``findings``."""
        self.errors.append(message)
        self.findings.append(UnitFinding(code, message, lhs_units, rhs_units))

    def add_warning(
        self, code: str, message: str, lhs_units: str = "", rhs_units: str = ""
    ) -> None:
        """Record an advisory finding: the prose in ``warnings``, the code in
        ``findings``."""
        self.warnings.append(message)
        self.findings.append(UnitFinding(code, message, lhs_units, rhs_units))


@dataclass
class UnitConversionResult:
    """Result of unit conversion operation."""

    success: bool
    converted_value: float | None = None
    conversion_factor: float | None = None
    error_message: str | None = None


# ---------------------------------------------------------------------------
# Scoped references carry their target's units (esm-spec §4.8.4, issue #414)
# ---------------------------------------------------------------------------


def _component_member_units(component: Any) -> dict[str, str | None]:
    """Declared unit strings of a component's own members: a model's
    ``variables``, a reaction system's ``species`` and ``parameters``. A
    member that declares no units maps to ``None``: it still occupies its
    name (see :class:`ScopedUnits`)."""
    out: dict[str, str | None] = {}
    variables = getattr(component, "variables", None)
    if isinstance(variables, dict):
        for name, var in variables.items():
            out[name] = getattr(var, "units", None) or None
    for attr in ("species", "parameters"):
        members = getattr(component, attr, None)
        if isinstance(members, dict):
            items = list(members.items())
        elif isinstance(members, list):
            items = [(getattr(m, "name", None), m) for m in members]
        else:
            continue
        for name, member in items:
            if isinstance(name, str):
                out[name] = getattr(member, "units", None) or None
    return out


class ScopedUnit(NamedTuple):
    """A scoped reference's target: its declared unit string and the parsed
    unit (``None`` when it declares none or an unparseable one -- the
    reference is then undeterminable)."""

    units: str | None
    unit: Any


def _collect_scoped_units(prefix: str, component: Any, out: dict[str, ScopedUnit]) -> None:
    """Register ``<prefix>.<member>`` for every member of ``component`` and,
    recursively, of every subsystem it carries (esm-spec §4.9.2: a scoped
    reference is a dot path of arbitrary depth). An unparseable unit is
    reported at its own declaration, not here."""
    for name, units in _component_member_units(component).items():
        unit = None
        if units is not None:
            try:
                unit = parse_unit(units)
            except UnparseableUnitError:
                unit = None
        out[f"{prefix}.{name}"] = ScopedUnit(units, unit)
    for sub_name, sub in (getattr(component, "subsystems", None) or {}).items():
        if isinstance(sub, dict):
            continue  # an unresolved {"ref": ...} edge: nothing is known about it
        _collect_scoped_units(f"{prefix}.{sub_name}", sub, out)


class ScopedUnits:
    """The units every scoped reference in a document carries (esm-spec §4.9.2).

    A mounted component is, after resolution, the same as one written inline
    (§4.7 "Resolution timing"), so a variable reached across a ``{ref}`` mount
    edge -- a ``subsystems.<k>`` mount or a top-level ``models.<k>`` mount --
    carries the units its declaration states, exactly as a local one does
    (§4.8.4). Two kinds of path are covered, with the same precedence the
    reference-integrity check uses: ``<System>.<member>`` naming a top-level
    model or reaction system (and its subsystems), and ``<sub>.<member>``
    relative to a component's own subsystems, which wins on a collision -- even
    when the relative member declares no units, in which case the reference
    is undeterminable and its check is skipped.

    The top-level paths are built once per document; :meth:`for_component`
    overlays only that component's relative paths.
    """

    def __init__(self, esm_file: EsmFile | None):
        self._top: dict[str, ScopedUnit] = {}
        if esm_file is not None:
            for name, model in (esm_file.models or {}).items():
                _collect_scoped_units(name, model, self._top)
            for name, rs in (esm_file.reaction_systems or {}).items():
                _collect_scoped_units(name, rs, self._top)

    def for_component(self, component: Any) -> Mapping[str, ScopedUnit]:
        """Scoped name -> target for the references an expression in
        ``component`` can make."""
        relative: dict[str, ScopedUnit] = {}
        for sub_name, sub in (getattr(component, "subsystems", None) or {}).items():
            if isinstance(sub, dict):
                continue
            _collect_scoped_units(sub_name, sub, relative)
        if not relative:
            return self._top
        return ChainMap(relative, self._top)


# ---------------------------------------------------------------------------
# Constant exponents (esm-spec §4.8.3 `^`)
# ---------------------------------------------------------------------------


def _literal_rational(value: Any) -> Fraction | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return Fraction(str(value))


def constant_exponent_value(expr: Any) -> Fraction | None:
    """The exact rational value of a CONSTANT-EXPRESSION exponent, or ``None``.

    esm-spec §4.8.3 `^`: an exponent folds when it is a numeric literal; a
    ``const`` that declares no units, or a dimensionless unit at scale 1 (its
    value IS the pure number it denotes); or ``+``, ``*`` (one or more
    operands), ``-`` (unary negation, or a left fold of two or more) or ``/``
    (exactly two operands, nonzero divisor) over constant expressions, nested to
    any depth. Anything else -- a variable, an expression containing one, a
    ``const`` at a scale other than 1 (``%``: its value and its quantity
    disagree), any other operator -- is SYMBOLIC and leaves the power of a
    dimensional base undeterminable (§4.8.4).
    """
    literal = _literal_rational(expr)
    if literal is not None:
        return literal
    if not isinstance(expr, ExprNode):
        return None
    op = expr.op
    if op == "const":
        if expr.units is not None:
            try:
                unit = parse_unit(expr.units)
            except UnparseableUnitError:
                return None
            if unit.dimensionality or not exact_scale_of(unit).is_one():
                return None
        return _literal_rational(expr.value)
    args = list(expr.args or [])
    if not args:
        return None
    values = [constant_exponent_value(a) for a in args]
    if any(v is None for v in values):
        return None
    if op == "+":
        return sum(values, Fraction(0))
    if op == "*":
        product = Fraction(1)
        for v in values:
            product *= v
        return product
    if op == "-":
        if len(values) == 1:
            return -values[0]
        result = values[0]
        for v in values[1:]:
            result -= v
        return result
    if op == "/":
        if len(values) != 2 or values[1] == 0:
            return None
        return values[0] / values[1]
    return None


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
        # esm-spec §4.8.6: when True, a bare numeric literal (and a unit-less
        # `const`) other than zero is DIMENSIONLESS at scale 1 instead of
        # undeterminable. Only the dimensionless-literal warning pass sets it.
        self.dimensionless_literals = False
        # Targets of the current component's scoped references (`Leaf.p`,
        # `sub.v`), consulted after `known_units` (see ScopedUnits).
        self.scoped_units: Mapping[str, ScopedUnit] = {}

    def validate_esm_file(self, esm_file: EsmFile) -> UnitValidationResult:
        """
        Validate unit consistency across an entire ESM file.

        Args:
            esm_file: The ESM file to validate

        Returns:
            UnitValidationResult with validation status and any issues found
        """
        result = UnitValidationResult(is_valid=True)
        scoped = ScopedUnits(esm_file)

        if esm_file.models:
            self._merge_component_results(
                esm_file.models.values(),
                lambda m: self.validate_model(m, scoped),
                "Model",
                result,
            )

        if esm_file.reaction_systems:
            self._merge_component_results(
                esm_file.reaction_systems.values(),
                lambda rs: self.validate_reaction_system(rs, scoped),
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
            # Findings carry the same prose, prefixed identically, plus the code
            # decided at the raise site.
            result.findings.extend(
                UnitFinding(
                    f.code,
                    f"{prefix} {component.name}: {f.message}",
                    f.lhs_units,
                    f.rhs_units,
                )
                for f in sub.findings
            )
            result.unit_registry.update(sub.unit_registry)

    def validate_model(
        self, model: Model, scoped: ScopedUnits | None = None
    ) -> UnitValidationResult:
        """
        Validate unit consistency within a model.

        Args:
            model: The model to validate
            scoped: The containing document's :class:`ScopedUnits`; without
                one only paths into the model's own subsystems are typed

        Returns:
            UnitValidationResult for the model
        """
        result = UnitValidationResult(is_valid=True)

        # Scope the known-units registry to this component so that a variable
        # name reused in another model/reaction system cannot collide during
        # bare-name dimension lookups in _get_expression_dimension.
        unparseable = self._enter_component(model, scoped)

        if not model.variables:
            return result

        # Build unit registry for this model. An unparseable unit is a HARD
        # ERROR: a string that does not denote a real unit is a defect in the
        # FILE, not a limit of the checker (see UnparseableUnitError). The
        # variable is still omitted from known_units, so it propagates as an
        # unknown dimension and cannot ALSO manufacture a spurious
        # dimensional-mismatch error downstream.
        for var_name, var_info in model.variables.items():
            if var_name in self.known_units:
                result.unit_registry[var_name] = var_info.units
        for var_name, spelled, e in unparseable:
            result.add_error(
                UNIT_FINDING_UNPARSEABLE,
                f"Invalid unit '{spelled}' for variable '{var_name}': {e}",
            )

        # Validate equations. An observed unknown's DEFINING equation is
        # skipped here and typed below instead, under the VARIABLE's name --
        # where 0.x reported it, and where an author looks. Typing it in both
        # places reported one defect twice.
        definitions = observed_definitions(model)
        if model.equations:
            for i, equation in enumerate(model.equations):
                lhs = getattr(equation, "lhs", None)
                if isinstance(lhs, str) and lhs in definitions:
                    continue
                eq_result = self.validate_equation(equation, f"eq_{i}")
                result.errors.extend(eq_result.errors)
                result.warnings.extend(eq_result.warnings)
                result.findings.extend(eq_result.findings)

        # Validate each observed unknown's DEFINING EXPRESSION -- its
        # bare-variable-LHS equation's RHS (esm-spec §6.3.1). Before 1.0.0 this
        # was `variables[v].expression`; the equations are the only place it can
        # live now. (The equation loop above already types both sides, so this
        # reports the finding against the VARIABLE name, as it always did.)
        for var_name, definition in definitions.items():
            expr_result = self.validate_expression(definition, var_name)
            if expr_result.errors:
                result.errors.extend([f"Variable {var_name}: {e}" for e in expr_result.errors])
                result.findings.extend(
                    UnitFinding(
                        f.code, f"Variable {var_name}: {f.message}", f.lhs_units, f.rhs_units
                    )
                    for f in expr_result.findings
                )

        result.is_valid = len(result.errors) == 0
        return result

    def validate_reaction_system(
        self, rs: ReactionSystem, scoped: ScopedUnits | None = None
    ) -> UnitValidationResult:
        """
        Validate unit consistency within a reaction system.

        Args:
            rs: The reaction system to validate
            scoped: The containing document's :class:`ScopedUnits` (see
                :meth:`validate_model`)

        Returns:
            UnitValidationResult for the reaction system
        """
        result = UnitValidationResult(is_valid=True)

        # Scope the known-units registry to this component (see validate_model).
        unparseable = self._enter_component(rs, scoped)

        # Register species and parameter units. An unparseable unit is a HARD
        # ERROR (see validate_model); the name is still omitted from
        # known_units, so it is treated as unknown downstream.
        species_names = {sp.name for sp in rs.species or []}
        for name, spelled in _declared_units(rs).items():
            if name in self.known_units:
                result.unit_registry[name] = spelled
        for name, spelled, e in unparseable:
            kind = "species" if name in species_names else "parameter"
            result.add_error(
                UNIT_FINDING_UNPARSEABLE,
                f"Invalid unit '{spelled}' for {kind} '{name}': {e}",
            )

        # Validate reactions
        if rs.reactions:
            for reaction in rs.reactions:
                reaction_result = self._validate_reaction(reaction)
                result.errors.extend(reaction_result.errors)
                result.warnings.extend(reaction_result.warnings)
                result.findings.extend(reaction_result.findings)

        result.is_valid = len(result.errors) == 0
        return result

    def _enter_component(
        self, component: Any, scoped: ScopedUnits | None = None
    ) -> list[tuple[str, str, UnparseableUnitError]]:
        """Scope the typer to one model or reaction system: its own declared
        units, then its scoped references (esm-spec §4.8.4). A name reused in
        another component cannot collide. Returns the declarations whose unit
        string does not parse, as ``(name, units, error)``; those names stay
        undeterminable."""
        self.known_units = {}
        self.scoped_units = (scoped or ScopedUnits(None)).for_component(component)
        unparseable = []
        for name, spelled in _declared_units(component).items():
            try:
                self.known_units[name] = parse_unit(spelled)
            except UnparseableUnitError as e:
                unparseable.append((name, spelled, e))
        return unparseable

    def _unit_of(self, name: str):
        """The unit of a name: a component-local declaration, else a scoped
        reference's target (esm-spec §4.8.4); ``None`` when undeterminable."""
        if name in self.known_units:
            return self.known_units[name]
        target = self.scoped_units.get(name)
        return target.unit if target is not None else None

    def _describe_side(self, expr: Expr, typed: _Typed) -> str:
        """``typed`` for a diagnostic: its dimension and scale, led by the
        declared unit when ``expr`` is a bare name that has one."""
        text = f"dimension {typed.dim} at scale {typed.scale}"
        unit = self._unit_of(expr) if isinstance(expr, str) else None
        return f"'{expr}' [{unit}], {text}" if unit is not None else text

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
            lhs = self._type(equation.lhs)
            rhs = self._type(equation.rhs)

            # `D(x)` with respect to an undeclared time is undeterminable, so
            # the plain LHS-vs-RHS comparison below cannot see it. Whatever unit
            # the time carries contributes only powers of TIME, so a ratio with
            # any other dimension is provably irreconcilable (esm-spec §4.8.4).
            state = _derivative_of_undeclared_time(self, equation.lhs)
            state_typed = self._type(state) if state is not None else None
            if state_typed is not None and rhs is not None:
                ratio = state_typed.dim / rhs.dim
                if any(axis != "[time]" and power != 0 for axis, power in ratio.items()):
                    result.add_error(
                        UNIT_FINDING_DIMENSIONAL_MISMATCH,
                        f"Equation {equation_id}: No time unit can reconcile "
                        f"d({state_typed.dim})/dt with {rhs.dim} "
                        f"(their ratio {ratio} is not a power of time)",
                        lhs_units=str(state_typed.dim),
                        rhs_units=str(rhs.dim),
                    )
            elif lhs is not None and rhs is not None:
                # The angle-stripped pair is compared; the diagnostic reports
                # each side as written (esm-spec §4.8.3).
                lhs_cmp, rhs_cmp = _angle_meets_number(lhs, rhs)
                if not self._dimensions_compatible(lhs_cmp.dim, rhs_cmp.dim):
                    result.add_error(
                        UNIT_FINDING_DIMENSIONAL_MISMATCH,
                        f"Equation {equation_id}: Dimensional mismatch - "
                        f"LHS has dimension {lhs.dim}, RHS has dimension {rhs.dim}",
                        lhs_units=str(lhs.dim),
                        rhs_units=str(rhs.dim),
                    )
                elif lhs_cmp.scale != rhs_cmp.scale:
                    # Same dimension, different unit (esm-spec §4.8.3).
                    result.add_error(
                        UNIT_FINDING_DIMENSIONAL_MISMATCH,
                        f"Equation {equation_id}: Scale mismatch - "
                        f"LHS has {self._describe_side(equation.lhs, lhs)}, "
                        f"RHS has {self._describe_side(equation.rhs, rhs)}",
                        lhs_units=str(lhs.dim),
                        rhs_units=str(rhs.dim),
                    )
        # A PROVABLE inconsistency inside the expression tree is an ERROR — it
        # used to be filed as a "could not validate" warning, which meant a
        # detected mismatch could never fail validation.
        except DimensionalMismatchError as e:
            result.add_error(UNIT_FINDING_DIMENSIONAL_MISMATCH, f"Equation {equation_id}: {e}")
        # PintError means we could not PARSE/convert a unit — genuinely
        # indeterminate, so a warning. Nothing broader is caught here: a bare
        # ValueError/AssertionError is a bug and must propagate rather than be
        # silently downgraded (this is exactly how C5 hid for so long).
        except pint.PintError as e:
            result.add_warning(
                UNIT_FINDING_ANALYSIS,
                f"Could not validate dimensions for equation {equation_id}: {e}",
            )

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
            result.add_error(
                UNIT_FINDING_DIMENSIONAL_MISMATCH,
                f"Expression validation failed for {context}: {e}",
            )
        except pint.PintError as e:
            result.add_warning(
                UNIT_FINDING_ANALYSIS, f"Could not validate dimensions for {context}: {e}"
            )

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
        typed = self._type(expr)
        return None if typed is None else typed.dim

    def _type(self, expr: Expr) -> _Typed | None:
        """The dimension AND exact scale of an expression, or ``None`` when
        indeterminate. See :meth:`_get_expression_dimension` for the literal
        rule; the scale follows the same rules as the dimension (esm-spec §4.8.3).
        """
        if isinstance(expr, bool):
            return self._dimensionless

        if isinstance(expr, (int, float)):
            return self._literal_type(expr)

        if isinstance(expr, str):
            unit = self._unit_of(expr)
            if unit is not None:
                return _Typed(unit.dimensionality, exact_scale_of(unit))
            if expr == op_registry.STRUCTURAL_DERIVATIVE_WRT:
                # The implicit independent variable has the time dimension, in
                # seconds (esm-spec §4.9.1), as in the other bindings. A
                # derivative taken with respect to it stays undeterminable when
                # it is undeclared (see `D` below and `validate_equation`).
                return _Typed(self.ureg.parse_units("s").dimensionality, ExactScale.one())
            # Undeclared symbol: unknown dimension, so it is skipped rather
            # than assumed dimensionless.
            return None

        if isinstance(expr, ExprNode):
            return self._type_node(expr)

        return None

    def _literal_type(self, value: Any) -> _Typed | None:
        """The unit of a bare numeric literal (or a unit-less ``const``):
        undeterminable under the current rule (esm-spec §4.8.4); under the
        §4.8.6 rule, dimensionless at scale 1 unless it is zero, which stays
        neutral."""
        if not self.dimensionless_literals or value == 0:
            return None
        return self._dimensionless

    @property
    def _dimensionless(self) -> _Typed:
        return _Typed(self.ureg.dimensionless.dimensionality, ExactScale.one())

    @property
    def _angle(self) -> _Typed:
        """The `[angle]` dimension at scale 1 -- the unit `rad`."""
        return _Typed(self.ureg.parse_units("rad").dimensionality, ExactScale.one())

    def _require_angle_or_pure_number(self, typed: _Typed | None, op: str) -> None:
        """Raise unless ``typed`` is unknown, a plane ANGLE at any scale, or a
        PURE NUMBER (dimensionless at scale 1).

        Three outcomes, and the middle one is the point of issue #409:

        * An ANGLE is admitted WHATEVER its scale, because ``deg`` -> ``rad`` is
          exact and has no second reading; :func:`normalize_angle_arguments`
          converts it on the evaluation path before anything computes with it.
        * A PURE NUMBER is admitted (a phase written in turns).
        * Dimensionless at a scale OTHER than 1 (``percent``) is REFUSED, for
          the same reason ``log(x [ppm])`` is: nothing says which reading of the
          number was meant.

        Anything else — ``sin(kg)`` — is a provable inconsistency, as is
        ``sin(x [sr])``: ``sr`` is ``rad**2``, which no conversion turns into an
        angle.
        """
        if typed is None:
            return
        if self._dimensions_compatible(typed.dim, self._angle.dim):
            return
        if self._dimensions_compatible(typed.dim, self._dimensionless.dim):
            if typed.scale.is_one():
                return
            raise DimensionalMismatchError(scaled_dimensionless_message(op, typed.scale))
        raise DimensionalMismatchError(
            f"{op} argument must be an angle or dimensionless, got {typed.dim}"
        )

    def _require_pure_number(self, typed: _Typed | None, op: str, what: str) -> None:
        """Raise if ``typed`` is known and is not dimensionless AT SCALE 1.

        This is what esm-spec §4.8.3's "the argument MUST be dimensionless"
        means for a strict transcendental (issue #409): ``ppm`` and ``percent``
        are dimensionless too, and ``log(x [ppm])`` has two defensible readings
        — the log of the ppm NUMBER, or the log of the mole fraction — that
        differ by ``ln(1e-6) = 13.8155...``. Dimension alone cannot tell them
        apart, so the checker refuses rather than picking one.
        """
        if typed is None:
            return
        if _is_pure_angle(typed.dim):
            # An angle meets a pure number (esm-spec §4.8.3): `rad` passes,
            # `deg` is refused for its scale like `percent`.
            typed = _angle_as_number(typed)
        if not self._dimensions_compatible(typed.dim, self._dimensionless.dim):
            raise DimensionalMismatchError(f"{op} {what} must be dimensionless, got {typed.dim}")
        if not typed.scale.is_one():
            raise DimensionalMismatchError(scaled_dimensionless_message(op, typed.scale))

    def _agree(self, operands: list[_Typed | None], op: str) -> _Typed | None:
        """Require every KNOWN operand to have the same dimension AND exact scale
        (esm-spec §4.8.3), and return it (or ``None`` if every operand is
        unknown).

        Unknown (``None``) operands are skipped rather than treated as
        dimensionless: an operand we cannot type must never manufacture a
        mismatch. Two *known* operands that disagree are a provable
        inconsistency -- metres against kilograms, and metres against
        kilometres.
        """
        known = [t for t in operands if t is not None]
        if not known:
            return None
        if (
            op in _ANGLE_AGREEMENT_OPS
            and any(_is_pure_number(t.dim) for t in known)
            and any(_is_pure_angle(t.dim) for t in known)
        ):
            # An angle meets a pure number (esm-spec §4.8.3): the angle axis
            # cancels, the scale is kept, and the result is a pure number. Two
            # angles never meet a NUMBER with each other, so the angles are
            # first held to the ordinary rule among themselves (`rad` against
            # `sr` stays a mismatch however many pure numbers sit beside them).
            self._require_same(op, [t for t in known if _is_pure_angle(t.dim)])
            known = [_angle_as_number(t) if _is_pure_angle(t.dim) else t for t in known]
        return self._require_same(op, known)

    def _require_same(self, op: str, known: list[_Typed]) -> _Typed | None:
        """Require every operand of ``known`` to have the first one's dimension
        AND exact scale, and return that first operand (``None`` if empty)."""
        if not known:
            return None
        first = known[0]
        for typed in known[1:]:
            if not self._dimensions_compatible(first.dim, typed.dim):
                raise DimensionalMismatchError(
                    f"Incompatible dimensions in {op}: {first.dim} vs {typed.dim}"
                )
            if first.scale != typed.scale:
                raise DimensionalMismatchError(
                    f"Incompatible scales in {op}: {first.dim} at scale {first.scale} "
                    f"vs scale {typed.scale}"
                )
        return first

    def _require_dimensionless(self, typed: _Typed | None, op: str, what: str) -> None:
        """Raise if ``typed`` is known and is NOT dimensionless."""
        if typed is not None and not self._dimensions_compatible(
            typed.dim, self._dimensionless.dim
        ):
            raise DimensionalMismatchError(f"{op} {what} must be dimensionless, got {typed.dim}")

    def _get_expr_node_dimension(self, node: ExprNode) -> UnitsContainer | None:
        """The dimension of an operator node; see :meth:`_type_node`."""
        typed = self._type_node(node)
        return None if typed is None else typed.dim

    def _type_node(self, node: ExprNode) -> _Typed | None:
        """The dimension and exact scale of an expression node (an operator with
        arguments).

        Returns ``None`` for "indeterminate" — an unknown operand, or an
        operator with no dimensional rule. ``None`` NEVER means dimensionless;
        callers skip the check entirely when they see it.

        Raises :class:`DimensionalMismatchError` on a provable inconsistency.
        """
        if node.op == "const":
            # A `const` that DECLARES its units has that unit (esm-spec §4.8.5);
            # without `units` it is undeterminable, like a bare literal. An
            # unresolvable string is reported at the containing expression field,
            # not here.
            if node.units is None:
                value = node.value
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    return self._literal_type(value)
                return None
            try:
                unit = parse_unit(node.units)
            except UnparseableUnitError:
                return None
            return _Typed(unit.dimensionality, exact_scale_of(unit))

        if node.op in _ARRAY_ELEMENT_OPS:
            # Array operators carry their ELEMENT's unit (esm-spec §4.8.3,
            # "Array operators"), in the checker and on the evaluation path
            # alike.
            return self._type_array_element(node)

        if not node.args:
            return None

        op = node.op
        args = [self._type(arg) for arg in node.args]

        # n-ary unit-preserving ops: every operand must agree.
        if op in _DIM_PRESERVING_NARY:
            return self._agree(args, op)

        # Unary carry-through ops.
        if op in _DIM_PRESERVING_UNARY:
            return args[0]

        if op in _DIMENSIONLESS_RESULT_OPS:
            return self._dimensionless

        if op in _COMPARISON_OPS:
            # Operands must be comparable; the boolean result is dimensionless.
            self._agree(args, op)
            return self._dimensionless

        if op in _DIMENSIONLESS_ARG_FUNCS:
            self._require_pure_number(args[0], op, "argument")
            return self._dimensionless

        if op in _CIRCULAR_FUNCS:
            # sin/cos/tan take an ANGLE (at any scale) or a PURE NUMBER, and
            # return a dimensionless ratio. `sin(kg)` is still an error.
            self._require_angle_or_pure_number(args[0], op)
            return self._dimensionless

        if op in _INVERSE_CIRCULAR_FUNCS:
            # asin/acos/atan take a dimensionless RATIO — a pure number, not a
            # `percent` whose reading is unstated — and RETURN AN ANGLE.
            self._require_pure_number(args[0], op, "argument")
            return self._angle

        if op == "atan2":
            # atan2(y, x): both operands share a unit; the result is an ANGLE.
            self._agree(args, op)
            return self._angle

        if op == "sqrt":
            base = args[0]
            if base is None:
                return None
            return _Typed(base.dim**0.5, base.scale ** Fraction(1, 2))

        if op == "ifelse":
            # ifelse(cond, then, else): the condition is a dimensionless
            # boolean; the two branches must agree and give the result.
            if len(args) < 3:
                return None
            return self._agree(args[1:3], op)

        if op == "*":
            # A single unknown operand makes the whole product unknown —
            # folding only the KNOWN operands would report `unknown * t` as
            # [time], which is not the dimension of anything.
            if any(t is None for t in args):
                return None
            dim, scale = self._dimensionless
            for typed in args:
                dim, scale = dim * typed.dim, scale * typed.scale
            return _Typed(dim, scale)

        if op == "/":
            # POSITIONAL: numerator is args[0], every later operand divides it.
            if any(t is None for t in args):
                return None
            dim, scale = args[0]
            for typed in args[1:]:
                dim, scale = dim / typed.dim, scale / typed.scale
            return _Typed(dim, scale)

        if op == "^":
            base = args[0]
            exponent = args[1] if len(args) > 1 else None
            # An exponent must always be dimensionless, whatever the base is.
            self._require_dimensionless(exponent, op, "exponent")
            if base is None:
                return None
            # A dimensionless base of scale 1 stays exactly that under any
            # exponent; a dimensional OR scaled base (`x^2` with `x` in `%`)
            # needs a literal exponent to give a unit.
            if (
                self._dimensions_compatible(base.dim, self._dimensionless.dim)
                and base.scale.is_one()
            ):
                return self._dimensionless
            # The exponent is read BY VALUE: a literal, or any constant
            # expression over literals (`3/2`, `-(1)`), folds to an exact
            # rational (esm-spec §4.8.3). A symbolic exponent stays unknown.
            power = constant_exponent_value(node.args[1]) if len(node.args) > 1 else None
            if power is not None:
                dim_exp = power.numerator if power.denominator == 1 else float(power)
                return _Typed(base.dim**dim_exp, base.scale**power)
            return None

        if op == "D":
            # d(f)/d(wrt) has the unit of f divided by that of wrt. `wrt` is a
            # sidecar field, not an arg, and is often an undeclared time symbol —
            # in which case the dimension is indeterminate. Never assume seconds.
            #
            # An ABSENT `wrt` MEANS `t` (esm-spec §4.2), exactly as the four
            # other bindings read it here (`rs units::propagate_calculus_dim`,
            # `jl units.jl`, `go derivativeWrt`, `ts node.wrt || 't'`). Treating
            # the absent case as "no axis at all" instead made the derivative's
            # dimension UNKNOWN whenever the axis was declared, so a document
            # whose `D(h) + w` adds a length-per-time to a mass was reported as
            # a dimensional mismatch by Go, Julia, Rust and TypeScript and
            # silently accepted by Python (EarthSciAST#407).
            wrt = getattr(node, "wrt", None) or op_registry.STRUCTURAL_DERIVATIVE_WRT
            wrt_unit = self._unit_of(wrt)
            if args[0] is None or wrt_unit is None:
                return None
            return _Typed(
                args[0].dim / wrt_unit.dimensionality, args[0].scale / exact_scale_of(wrt_unit)
            )

        # Structural / array / query / rewrite-target ops (index, aggregate,
        # fn, const, makearray, table_lookup, grad, ...) carry no dimensional
        # rule here. Report UNKNOWN, not dimensionless.
        return None

    def _type_array_element(self, node: ExprNode) -> _Typed | None:
        """The ELEMENT unit of an array operator (esm-spec §4.8.3, "Array
        operators") -- the same rules in every binding:

        * ``index``, ``reshape``, ``transpose``: the source array's unit
          (``args[0]``); the subscripts and shape operands are walked for
          findings but are not part of it.
        * ``concat``: its operands agree like those of ``+``.
        * ``makearray``: its region ``values`` agree like the operands of
          ``+`` -- an undeterminable region is skipped.
        * ``broadcast``: the unit of ``{op: fn, args}``.
        * ``faq``: ``filter``, ``expr`` and any ``args`` are always walked;
          the node's unit is decided by its ⊕ (:meth:`_faq_unit`).

        Every operand is walked, so a mismatch inside a subscript
        (``index(lat, a + b)``) is reported.

        A node with nothing to read a unit from is undeterminable (``None``),
        never dimensionless (§4.8.4).
        """
        op = node.op
        if op == "faq":
            if node.filter is not None:
                self._type(node.filter)
            body = self._type(node.expr) if node.expr is not None else None
            for a in node.args:
                self._type(a)
            if node.expr is None:
                return None
            return self._faq_unit(node, body)
        if op == "makearray":
            for a in node.args:
                self._type(a)
            typed = [self._type(v) for v in (node.values or [])]
            known = [t for t in typed if t is not None]
            if not known:
                return None
            first = known[0]
            for t in known[1:]:
                if not self._dimensions_compatible(first.dim, t.dim) or first.scale != t.scale:
                    raise DimensionalMismatchError(
                        f"'makearray' regions must share units: {first.dim} at scale "
                        f"{first.scale} vs {t.dim} at scale {t.scale}"
                    )
            return first
        if op == "concat":
            return self._agree([self._type(a) for a in node.args], op)
        if op == "broadcast":
            if node.fn is None:
                for a in node.args:
                    self._type(a)
                return None
            return self._type_node(ExprNode(op=node.fn, args=list(node.args)))
        # index / reshape / transpose
        typed = [self._type(a) for a in node.args]
        return typed[0] if typed else None

    def _faq_unit(self, node: ExprNode, body: _Typed | None) -> _Typed | None:
        """The unit of an ``faq`` whose body has unit ``body``. The ⊗ is
        written by the author inside ``expr`` and ``join`` clauses contribute no
        factor, so only the ⊕ matters: ``+``/``max``/``min`` keep the body's
        unit; ``*`` keeps it only for a pure-number body (the power is the range
        length); ``bool_and_or`` is dimensionless; value invention
        (``distinct`` or a ``key``) and an unknown spelling are
        undeterminable."""
        if node.distinct is True or node.key is not None:
            return None
        if node.semiring is not None:
            kind = {
                "sum_product": "+",
                "max_product": "max",
                "min_sum": "min",
                "max_sum": "max",
                "bool_and_or": "or",
            }.get(node.semiring)
        else:
            kind = node.reduce or "+"
        if kind in ("+", "max", "min"):
            return body
        if kind == "*":
            if (
                body is not None
                and self._dimensions_compatible(body.dim, self._dimensionless.dim)
                and body.scale.is_one()
            ):
                return body
            return None
        if kind == "or":
            return self._dimensionless
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
                result.add_warning(
                    UNIT_FINDING_ANALYSIS,
                    f"Reaction {reaction.name}: Rate constant has no explicit units",
                )
            elif isinstance(reaction.rate_constant, ExprNode):
                # Validate the rate constant expression
                expr_result = self.validate_expression(
                    reaction.rate_constant, f"rate_constant_{reaction.name}"
                )
                result.errors.extend(expr_result.errors)
                result.warnings.extend(expr_result.warnings)
                result.findings.extend(expr_result.findings)

        result.is_valid = len(result.errors) == 0
        return result


def bare_literal_value(expr: Any) -> float | None:
    """The value of a bare numeric literal, a ``const`` without ``units``, or a
    unary ``+``/``-`` of one (nested to any depth); ``None`` for anything else."""
    if isinstance(expr, bool):
        return None
    if isinstance(expr, (int, float)):
        return expr
    if isinstance(expr, ExprNode):
        if expr.op == "const" and expr.units is None:
            value = expr.value
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                return value
            return None
        if expr.op in ("+", "-") and len(expr.args or []) == 1:
            inner = bare_literal_value(expr.args[0])
            if inner is None:
                return None
            return -inner if expr.op == "-" else inner
    return None


def _nonzero_literals(exprs: list[Any]) -> list[str]:
    """The distinct nonzero bare literals in ``exprs``, in walk order, spelled
    as JSON numbers -- what the dimensionless-literal warning names."""
    out: list[str] = []

    def walk(node: Any) -> None:
        value = bare_literal_value(node)
        if value is not None:
            if value != 0:
                text = repr(value)
                if text not in out:
                    out.append(text)
            return
        if isinstance(node, ExprNode):
            for child in node.args or []:
                walk(child)
            for child in (node.expr, node.filter):
                if child is not None:
                    walk(child)
            for child in node.values or []:
                walk(child)

    for expr in exprs:
        walk(expr)
    return out


def _declared_units(component: Any) -> dict[str, str]:
    """The unit strings a model (its ``variables``) or a reaction system (its
    ``species``, then its ``parameters``) declares, by name."""
    if hasattr(component, "variables"):
        return {n: v.units for n, v in (component.variables or {}).items() if v.units}
    declared = {sp.name: sp.units for sp in component.species or [] if sp.units}
    declared.update({p.name: p.units for p in component.parameters or [] if p.units})
    return declared


def _derivative_of_undeclared_time(validator: UnitValidator, lhs: Any) -> Any:
    """The operand ``x`` when ``lhs`` is ``D(x)`` taken with respect to an
    independent variable the component does not declare, else ``None``."""
    if not isinstance(lhs, ExprNode) or lhs.op != "D" or len(lhs.args or []) != 1:
        return None
    wrt = lhs.wrt or op_registry.STRUCTURAL_DERIVATIVE_WRT
    if validator._unit_of(wrt) is not None:
        return None
    return lhs.args[0]


def dimensionless_literal_findings(esm_file: EsmFile) -> list[tuple[str, str]]:
    """The esm-spec §4.8.6 warnings: every check site whose verdict is a
    provable mismatch when bare numeric literals are dimensionless, but not
    under the current neutral-literal rule. Returns ``(json_pointer, message)``
    pairs in document order.

    The sites are every model's ``equations`` and ``initialization_equations``
    and every reaction system's ``constraint_equations`` and reaction rates,
    in the top-level components and in their inline subsystems at any depth.
    Each site is judged by the check validation applies to it
    (:meth:`UnitValidator.validate_equation`, or
    :meth:`UnitValidator._validate_reaction` for a rate) in the component's
    own unit environment, once per literal rule. A site the current rule
    already rejects carries no warning: it is an error already.
    """
    if not PINT_AVAILABLE:
        return []
    from .structural_checks import _pointer_token

    scoped = ScopedUnits(esm_file)
    out: list[tuple[str, str]] = []

    def visit(pointer: str, validator: UnitValidator, exprs: list[Any], check) -> None:
        literals = _nonzero_literals(exprs)
        # With no nonzero literal the two rules type the site identically.
        if not literals:
            return
        validator.dimensionless_literals = True
        found = check().errors
        if not found:
            return
        validator.dimensionless_literals = False
        if check().errors:
            return
        out.append(
            (
                pointer,
                f"{pointer}: with bare numeric literals read as dimensionless "
                f"(esm-spec §4.8.6), {found[0]}; bare literal(s): {', '.join(literals)}. "
                "This becomes an error at the next major esm version; a literal that "
                'carries a unit is written const(value, units "...") '
                "(esm-spec §4.8.5)",
            )
        )

    def equation(pointer: str, validator: UnitValidator, eq: Any) -> None:
        equation_id = pointer.rsplit("/", 2)[-2:]
        visit(
            pointer,
            validator,
            [eq.lhs, eq.rhs],
            lambda: validator.validate_equation(eq, "/".join(equation_id)),
        )

    def walk_model(pointer: str, model: Any) -> None:
        validator = UnitValidator()
        validator._enter_component(model, scoped)
        for field_name in ("equations", "initialization_equations"):
            for i, eq in enumerate(getattr(model, field_name, None) or []):
                equation(f"{pointer}/{field_name}/{i}", validator, eq)
        walk_subsystems(pointer, model, walk_model)

    def walk_reaction_system(pointer: str, rs: Any) -> None:
        validator = UnitValidator()
        validator._enter_component(rs, scoped)
        for i, eq in enumerate(rs.constraint_equations or []):
            equation(f"{pointer}/constraint_equations/{i}", validator, eq)
        for i, reaction in enumerate(rs.reactions or []):
            rate = getattr(reaction, "rate_constant", None)
            if rate is None:
                continue
            visit(
                f"{pointer}/reactions/{i}",
                validator,
                [rate],
                lambda reaction=reaction: validator._validate_reaction(reaction),
            )
        walk_subsystems(pointer, rs, walk_reaction_system)

    def walk_subsystems(pointer: str, component: Any, walk) -> None:
        # Inline subsystems at any depth; an unresolved `{ref}` mount is a raw
        # dict and has nothing to type.
        for name, sub in (getattr(component, "subsystems", None) or {}).items():
            if isinstance(sub, dict):
                continue
            walk(f"{pointer}/subsystems/{_pointer_token(str(name))}", sub)

    for mname, model in (esm_file.models or {}).items():
        walk_model(f"/models/{_pointer_token(str(mname))}", model)
    for sname, rs in (esm_file.reaction_systems or {}).items():
        walk_reaction_system(f"/reaction_systems/{_pointer_token(str(sname))}", rs)
    return out


def angle_normalization_factor(unit) -> float | None:
    """The factor that brings a quantity in ``unit`` to RADIANS, when ``unit`` is
    a plane angle at a scale other than 1 (esm-spec §4.8.3, issue #409).

    ``None`` for anything else — a pure number, a ``rad``, a dimensional unit —
    so a document that declares no scaled angle is rewritten not at all.
    """
    if unit is None:
        return None
    if unit.dimensionality != _ANGLE_DIMENSIONALITY:
        return None
    scale = exact_scale_of(unit)
    return None if scale.is_one() else float(scale)


def normalize_angle_arguments(expr: Expr, env: dict[str, Any], _validator=None) -> Expr:
    """Rewrite every ``sin``/``cos``/``tan`` whose argument is an angle at a
    scale other than 1 so the argument reaches the evaluator in RADIANS.

    esm-spec §4.8.3 names angles as *the* exception to the dimensionless-argument
    rule, and ``deg`` is a registry unit at scale pi/180 — so ``sin(theta)`` with
    ``theta`` in ``deg`` is a CONFORMING document, and before this it evaluated
    ``sin(90)`` = 0.894 where 1 was meant, with no diagnostic (issue #409). The
    conversion is exact and has no second reading, which is why this half
    converts where the ``ppm`` half refuses.

    The rewrite runs on the EVALUATION path only (the flatten funnel); the
    checker still sees the authored spelling, and so still reports the
    argument's declared unit rather than a literal-poisoned ``unknown``.
    """
    if not isinstance(expr, ExprNode):
        return expr

    # ONE validator for the whole walk. It is a pure function of `env` — which
    # does not change during the walk — so rebuilding it per node would rebuild
    # the pint registry per trig call.
    validator = _validator
    if validator is None:
        validator = UnitValidator()
        validator.known_units = env
        # An array element carries its array's declared unit (esm-spec §4.8.3),
        # so `cos(index(lat, i))` with `lat` in `deg` is converted like `cos(lat)`.

    # Children first, so a nested `sin(theta [deg])` inside another argument is
    # converted too. IDENTITY-PRESERVING: ``map_children`` always rebuilds, and
    # template expansion leaves structurally SHARED sub-expressions, so a
    # subtree in which nothing changed is returned as the SAME object rather
    # than rematerialized as a tree.
    changed = False

    def rewrite_child(child: Expr) -> Expr:
        nonlocal changed
        out = normalize_angle_arguments(child, env, validator)
        if out is not child:
            changed = True
        return out

    mapped = map_children(expr, rewrite_child)
    node = mapped if changed else expr

    if node.op not in _CIRCULAR_FUNCS or len(node.args) != 1:
        return node

    try:
        typed = validator._type(node.args[0])
    except (DimensionalMismatchError, UnparseableUnitError):
        return node
    if typed is None or typed.dim != _ANGLE_DIMENSIONALITY or typed.scale.is_one():
        return node
    scaled = ExprNode(op="*", args=[node.args[0], float(typed.scale)])
    return replace(node, args=[scaled])


def flattened_unit_env(variables) -> dict[str, Any]:
    """``name -> parsed pint unit`` for every flattened variable that declares a
    RESOLVABLE unit. An unresolvable one is omitted, so it types as unknown and
    is skipped rather than manufacturing a verdict."""
    env: dict[str, Any] = {}
    for name, var in variables.items():
        declared = getattr(var, "units", None)
        if not declared:
            continue
        try:
            env[name] = parse_unit(declared)
        except UnparseableUnitError:
            continue
    return env


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
