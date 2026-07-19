"""
Pretty-printing formatters for ESM format expressions, equations, models, and files.

Implements output formats:
- to_unicode(): Unicode mathematical notation with chemical subscripts
- to_latex(): LaTeX mathematical notation

Based on ESM Format Specification Section 6.1
"""
from __future__ import annotations

import math
import re

from .esm_types import Equation, EsmFile, Expr, ExprNode, Model, ReactionSystem
from .serialize import _canonical_number

# ---------------------------------------------------------------------------
# Greek letters: ONE canonical table drives every derived lookup / regex below
# (LaTeX / unicode / ascii), mirroring pretty-print.ts GREEK_TABLE. Each row is
# [asciiName, lowerChar, upperChar, hasUpperLatex] where hasUpperLatex marks the
# uppercase forms with a distinct LaTeX command (\Gamma, ...).
# ---------------------------------------------------------------------------
GREEK_TABLE = [
    ("alpha", "α", "Α", False),
    ("beta", "β", "Β", False),
    ("gamma", "γ", "Γ", True),
    ("delta", "δ", "Δ", True),
    ("epsilon", "ε", "Ε", False),
    ("zeta", "ζ", "Ζ", False),
    ("eta", "η", "Η", False),
    ("theta", "θ", "Θ", True),
    ("iota", "ι", "Ι", False),
    ("kappa", "κ", "Κ", False),
    ("lambda", "λ", "Λ", True),
    ("mu", "μ", "Μ", False),
    ("nu", "ν", "Ν", False),
    ("xi", "ξ", "Ξ", True),
    ("omicron", "ο", "Ο", False),
    ("pi", "π", "Π", True),
    ("rho", "ρ", "Ρ", False),
    ("sigma", "σ", "Σ", True),
    ("tau", "τ", "Τ", False),
    ("upsilon", "υ", "Υ", True),
    ("phi", "φ", "Φ", True),
    ("chi", "χ", "Χ", False),
    ("psi", "ψ", "Ψ", True),
    ("omega", "ω", "Ω", True),
]

# LaTeX: named lowercase → \name, lowercase char → \name, distinct uppercase → \Name.
GREEK_LETTERS: dict[str, str] = {}
# Named lowercase → Unicode symbol (unicode output).
GREEK_NAME_TO_CHAR: dict[str, str] = {}
# Lowercase Unicode char → ascii name (ascii output).
GREEK_CHAR_TO_NAME: dict[str, str] = {}
for _name, _lower, _upper, _has_upper_latex in GREEK_TABLE:
    GREEK_LETTERS[_name] = f"\\{_name}"
    GREEK_LETTERS[_lower] = f"\\{_name}"
    if _has_upper_latex:
        GREEK_LETTERS[_name.capitalize()] = f"\\{_name.capitalize()}"
    GREEK_NAME_TO_CHAR[_name] = _lower
    GREEK_CHAR_TO_NAME[_lower] = _name

_GREEK_NAME_GROUP = "(?:" + "|".join(name for name, *_ in GREEK_TABLE) + ")"
_GREEK_CHAR_CLASS = "[α-ωΑ-Ω]"
# LaTeX: a Greek char OR a named letter that is NOT preceded by a backslash or
# another letter (so the `eta` inside `\theta`, and any `\command`, is left
# alone) and NOT followed by an uppercase letter (chemical prefix) or `}`
# (already inside \mathrm{}).
_GREEK_LATEX_RE = re.compile(
    _GREEK_CHAR_CLASS + r"|(?<![\\A-Za-z])" + _GREEK_NAME_GROUP + r"(?![A-Z}])"
)
# Unicode: a named letter not followed by an uppercase letter (chemical prefix).
_GREEK_UNICODE_RE = re.compile(f"{_GREEK_NAME_GROUP}(?![A-Z])")
# ASCII: bare Greek Unicode chars.
_GREEK_CHAR_RE = re.compile(_GREEK_CHAR_CLASS)


def _convert_greek(text: str, format_type: str) -> str:
    """Port of pretty-print.ts convertGreekLetters (unicode / latex / ascii)."""
    if format_type == "latex":
        return _GREEK_LATEX_RE.sub(lambda m: GREEK_LETTERS.get(m.group(0), m.group(0)), text)
    if format_type == "unicode":
        return _GREEK_UNICODE_RE.sub(
            lambda m: GREEK_NAME_TO_CHAR.get(m.group(0), m.group(0)), text
        )
    if format_type == "ascii":
        return _GREEK_CHAR_RE.sub(lambda m: GREEK_CHAR_TO_NAME.get(m.group(0), m.group(0)), text)
    return text


# Element lookup table for chemical subscript detection (118 elements)
ELEMENTS = {
    # Period 1
    "H",
    "He",
    # Period 2
    "Li",
    "Be",
    "B",
    "C",
    "N",
    "O",
    "F",
    "Ne",
    # Period 3
    "Na",
    "Mg",
    "Al",
    "Si",
    "P",
    "S",
    "Cl",
    "Ar",
    # Period 4
    "K",
    "Ca",
    "Sc",
    "Ti",
    "V",
    "Cr",
    "Mn",
    "Fe",
    "Co",
    "Ni",
    "Cu",
    "Zn",
    "Ga",
    "Ge",
    "As",
    "Se",
    "Br",
    "Kr",
    # Period 5
    "Rb",
    "Sr",
    "Y",
    "Zr",
    "Nb",
    "Mo",
    "Tc",
    "Ru",
    "Rh",
    "Pd",
    "Ag",
    "Cd",
    "In",
    "Sn",
    "Sb",
    "Te",
    "I",
    "Xe",
    # Period 6
    "Cs",
    "Ba",
    "La",
    "Ce",
    "Pr",
    "Nd",
    "Pm",
    "Sm",
    "Eu",
    "Gd",
    "Tb",
    "Dy",
    "Ho",
    "Er",
    "Tm",
    "Yb",
    "Lu",
    "Hf",
    "Ta",
    "W",
    "Re",
    "Os",
    "Ir",
    "Pt",
    "Au",
    "Hg",
    "Tl",
    "Pb",
    "Bi",
    "Po",
    "At",
    "Rn",
    # Period 7
    "Fr",
    "Ra",
    "Ac",
    "Th",
    "Pa",
    "U",
    "Np",
    "Pu",
    "Am",
    "Cm",
    "Bk",
    "Cf",
    "Es",
    "Fm",
    "Md",
    "No",
    "Lr",
    "Rf",
    "Db",
    "Sg",
    "Bh",
    "Hs",
    "Mt",
    "Ds",
    "Rg",
    "Cn",
    "Nh",
    "Fl",
    "Mc",
    "Lv",
    "Ts",
    "Og",
}

# Unicode subscripts for digits 0-9
SUBSCRIPT_DIGITS = "₀₁₂₃₄₅₆₇₈₉"


def _to_subscript(n: int) -> str:
    """Convert integer to Unicode subscript digits."""
    return "".join(SUBSCRIPT_DIGITS[int(d)] for d in str(n))


# Unicode superscripts for digits 0-9 and signs
SUPERSCRIPT_MAP = {
    "0": "⁰",
    "1": "¹",
    "2": "²",
    "3": "³",
    "4": "⁴",
    "5": "⁵",
    "6": "⁶",
    "7": "⁷",
    "8": "⁸",
    "9": "⁹",
    "+": "⁺",
    "-": "⁻",
}


def _to_superscript(text: str) -> str:
    """Convert text to Unicode superscript."""
    return "".join(SUPERSCRIPT_MAP.get(c, c) for c in text)


def _is_ascii_letter(ch: str) -> bool:
    """True for a single ``[A-Za-z]`` character (mirrors JS ``/[A-Za-z]/``)."""
    return ("a" <= ch <= "z") or ("A" <= ch <= "Z")


def _scan_elements(s: str):
    """Greedy 2-char-before-1-char element tokenizer (pretty-print.ts scanElements).

    Yields ``{"element", "digits"}`` for a recognized symbol plus the ASCII-digit
    run that immediately follows it, or ``{"other"}`` for any single other
    character. ASCII digits only (`[0-9]`), so pre-formatted Unicode subscripts
    (e.g. ``₃``) are treated as ``other``.
    """
    tokens = []
    i = 0
    n = len(s)
    while i < n:
        sym = None
        if i + 1 < n and s[i : i + 2] in ELEMENTS:
            sym = s[i : i + 2]
        elif s[i] in ELEMENTS:
            sym = s[i]
        if sym is not None:
            i += len(sym)
            digits = ""
            while i < n and s[i] in "0123456789":
                digits += s[i]
                i += 1
            tokens.append({"element": sym, "digits": digits})
        else:
            tokens.append({"other": s[i]})
            i += 1
    return tokens


def _has_element_pattern(variable: str) -> bool:
    """True only if ``variable`` is PURELY a chemical formula (pretty-print.ts).

    Underscores are stripped first; any non-element ASCII letter disqualifies the
    string (so ``alphaCO2`` is NOT a pure formula and routes to the mixed path).
    """
    clean = variable.replace("_", "")
    has_element = False
    for t in _scan_elements(clean):
        if "element" in t:
            has_element = True
        elif _is_ascii_letter(t["other"]):
            return False
    return has_element


def _latex_chemical_inner(formula: str) -> str:
    """Digit runs → LaTeX subscripts, WITHOUT the ``\\mathrm{}`` wrapper.

    ``H2O`` → ``H_2O``, ``CO12`` → ``CO_{12}`` (pretty-print.ts latexChemicalInner).
    """
    return re.sub(
        r"([0-9]+)",
        lambda m: f"_{m.group(1)}" if len(m.group(1)) == 1 else f"_{{{m.group(1)}}}",
        formula,
    )


def _strip_outer_mathrm(s: str) -> str:
    """Peel one leading ``\\mathrm{`` and one trailing ``}`` (pretty-print.ts)."""
    inner = s[len("\\mathrm{") :] if s.startswith("\\mathrm{") else s
    return inner[:-1] if inner.endswith("}") else inner


def _get_chemical_suffix(variable: str):
    """Split a variable into a non-element prefix and a chemical suffix, or None.

    Port of pretty-print.ts getChemicalSuffix.
    """
    if "_" in variable:
        parts = variable.split("_")
        if len(parts) == 2:
            prefix, suffix = parts
            if _has_element_pattern(suffix) and not _has_element_pattern(prefix):
                return {"prefix": prefix, "suffix": suffix}
        if len(parts) == 3:
            prefix = parts[0]
            suffix = "_".join(parts[1:])
            if _has_element_pattern(suffix) and not _has_element_pattern(prefix):
                return {"prefix": prefix, "suffix": suffix}
    for i in range(1, len(variable)):
        prefix, suffix = variable[:i], variable[i:]
        if _has_element_pattern(suffix) and not _has_element_pattern(prefix):
            return {"prefix": prefix, "suffix": suffix}
    return None


def _format_chemical_suffix_inner(variable: str) -> str:
    """Inner content of a chemical suffix embedded in a subscript (pretty-print.ts)."""
    if _get_chemical_suffix(variable):
        return _strip_outer_mathrm(_format_chemical_latex(variable))
    if variable in ELEMENTS and not any(c in "0123456789" for c in variable):
        return variable
    return _latex_chemical_inner(variable)


def _is_preformatted_latex(variable: str) -> bool:
    """Whether a variable NAME is already LaTeX that must render verbatim.

    Port of pretty-print.ts isPreformattedLatex. Three shapes qualify: an
    already roman-wrapped species (``\\mathrm{...}``); a bare control word with
    no group (``\\theta``); or a name carrying its own ``{...}`` subscript
    grouping but no command (``k_{NO_O3}``, ``j_{NO2}``). A different
    ``\\command{...}`` atom (``\\mathbf{v}``) is NOT pre-formatted.
    """
    if variable.startswith("\\mathrm{"):
        return True
    if "\\" in variable:
        return "{" not in variable
    return "{" in variable or "}" in variable


def _format_chemical_latex(variable: str) -> str:
    """LaTeX chemical / variable subscript formatting (pretty-print.ts formatChemicalLatex)."""
    # A trailing ionic charge is a superscript (``Ca^{2+}``), not a subscript.
    body, charge = _split_charge(variable)
    if charge is not None and _has_element_pattern(body):
        return f"{_format_chemical_latex(body)}^{{{charge}}}"
    # A name that is already LaTeX renders verbatim (re-formatting only mangles it).
    if _is_preformatted_latex(variable):
        return variable

    has_elements = _has_element_pattern(variable)

    chem = _get_chemical_suffix(variable)
    if chem:
        prefix, suffix = chem["prefix"], chem["suffix"]
        if "_" in suffix:
            segments = suffix.split("_")
            should_split = bool(re.search(r"[0-9]$", segments[0])) or len(prefix) > 1
            if should_split:
                if len(prefix) == 1 and _is_ascii_letter(prefix):
                    result = prefix
                else:
                    result = f"\\mathrm{{{prefix}}}"
                for seg in segments:
                    if _has_element_pattern(seg):
                        result += f"_{{\\mathrm{{{_latex_chemical_inner(seg)}}}}}"
                    else:
                        result += f"_\\mathrm{{{seg}}}"
                return result
        inner_content = _format_chemical_suffix_inner(suffix)
        formatted_prefix = f"\\mathrm{{{prefix}}}" if len(prefix) > 1 else prefix
        return f"{formatted_prefix}_{{\\mathrm{{{inner_content}}}}}"

    if has_elements:
        # A bare element symbol without digits (e.g. "B", "C", "N") is a variable name.
        if variable in ELEMENTS and not any(c in "0123456789" for c in variable):
            return variable
        return f"\\mathrm{{{_latex_chemical_inner(variable)}}}"

    # Regular (non-chemical) variable.
    # Greek letter (Unicode or named) → return as-is (convertGreek handles later).
    if variable in GREEK_LETTERS:
        return variable
    # Single letter + digits → italic with subscript (e.g. T_{298}, x_1).
    single = re.match(r"^([A-Za-zΑ-ω])([0-9]+)$", variable)
    if single:
        letter, digits = single.group(1), single.group(2)
        return f"{letter}_{digits}" if len(digits) == 1 else f"{letter}_{{{digits}}}"
    # Single letter (Latin or Greek) → italic (no wrapping).
    if len(variable) == 1:
        return variable
    # Underscore-separated variable with mixed segments.
    if "_" in variable:
        parts = variable.split("_")
        if any(_has_element_pattern(p) for p in parts):
            base = parts[0]
            if len(base) == 1 and _is_ascii_letter(base):
                result = base
            elif _has_element_pattern(base):
                result = _format_chemical_latex(base)
            else:
                result = f"\\mathrm{{{base}}}"
            for part in parts[1:]:
                if _has_element_pattern(part):
                    result += f"_{{\\mathrm{{{_latex_chemical_inner(part)}}}}}"
                else:
                    result += f"_\\mathrm{{{part}}}"
            return result
        escaped = variable.replace("_", "\\_")
        return f"\\mathrm{{{escaped}}}"
    # A symbol with no lowercase letters (e.g. "RT", "-E") is a math variable,
    # not a descriptive name — leave it italic instead of wrapping in \mathrm{}.
    if not re.search(r"[a-z]", variable):
        return variable
    # Multi-character → \mathrm{}.
    return f"\\mathrm{{{variable}}}"


# Trailing ionic charge: digits-then-sign (``Ca2+``), sign-then-digits
# (``SO4-2``), or a bare sign (``Na+``). Normalized to ``<digits><sign>`` and
# rendered as a SUPERSCRIPT (contract F-7). ``(.+?)`` keeps the body non-empty
# so a bare operator token (``+``/``-``) is never mistaken for a charge.
_CHARGE_DIGIT_SIGN_RE = re.compile(r"^(.+?)([0-9]+)([+-])$")
_CHARGE_SIGN_DIGIT_RE = re.compile(r"^(.+?)([+-])([0-9]+)$")
_CHARGE_BARE_SIGN_RE = re.compile(r"^(.+?)([+-])$")


def _split_charge(formula: str):
    """Split a trailing ionic charge off a formula (pretty-print.ts splitCharge).

    Returns ``(body, charge)`` with the charge normalized to magnitude-then-sign
    (``"2+"``, ``"2-"``), or ``(formula, None)`` when there is no trailing charge.
    """
    m = _CHARGE_DIGIT_SIGN_RE.match(formula)
    if m:
        return m.group(1), m.group(2) + m.group(3)
    m = _CHARGE_SIGN_DIGIT_RE.match(formula)
    if m:
        return m.group(1), m.group(3) + m.group(2)
    m = _CHARGE_BARE_SIGN_RE.match(formula)
    if m:
        return m.group(1), m.group(2)
    return formula, None


def _format_chemical_unicode(variable: str) -> str:
    """Unicode chemical / variable subscript formatting (pretty-print.ts formatChemicalUnicode)."""
    # A trailing ionic charge is a superscript (``Ca²⁺``), not a subscript.
    body, charge = _split_charge(variable)
    if charge is not None and _has_element_pattern(body):
        return f"{_format_chemical_unicode(body)}{_to_superscript(charge)}"

    has_elements = _has_element_pattern(variable)

    if not has_elements:
        chem = _get_chemical_suffix(variable)
        if chem:
            prefix, suffix = chem["prefix"], chem["suffix"]
            chemical_part = _format_chemical_unicode(suffix)
            if "_" not in variable:
                return f"{prefix}{chemical_part}"
            return f"{prefix}_{chemical_part}"
        if "_" in variable:
            parts = variable.split("_")
            if any(_has_element_pattern(p) for p in parts):
                return "_".join(
                    _format_chemical_unicode(p) if _has_element_pattern(p) else p for p in parts
                )
        return variable

    # Element-aware subscript detection: elements keep their digits as subscripts;
    # stray digits (e.g. after a closing paren) are subscripted too.
    result = ""
    for t in _scan_elements(variable):
        if "element" in t:
            result += t["element"]
            for d in t["digits"]:
                result += SUBSCRIPT_DIGITS[int(d)]
        elif t["other"] in "0123456789":
            result += SUBSCRIPT_DIGITS[int(t["other"])]
        else:
            result += t["other"]
    return result


def _format_chemical_subscripts(variable: str, format_type: str) -> str:
    """Element-aware chemical subscript + Greek-letter formatting of a bare name.

    Mirrors pretty-print.ts formatAny's ``variable`` case: ASCII transliterates
    Greek Unicode chars to names; unicode / latex format chemical subscripts then
    apply the Greek conversion to the result.
    """
    if format_type == "ascii":
        return _convert_greek(variable, "ascii")
    if format_type == "latex":
        # A name already in LaTeX form (`\mathrm{O_3}`, `\theta`, `k_{NO_O3}`)
        # renders verbatim — re-formatting or Greek transliteration only mangles it.
        if _is_preformatted_latex(variable):
            return variable
        return _convert_greek(_format_chemical_latex(variable), "latex")
    # unicode: a name carrying a LaTeX command (backslash) renders verbatim
    # (`\mathrm{O_3}`, `\theta`); a brace-only name like `k_{NO_O3}` still gets
    # its digits subscripted (`k_{NO_O₃}`), matching the reference bindings.
    if "\\" in variable:
        return variable
    return _convert_greek(_format_chemical_unicode(variable), "unicode")


# Scientific-notation cutoffs (RENDERING_CONTRACT.md / spec §6.1): a nonzero
# number whose magnitude is below the min or at/above the max renders in
# scientific notation; everything between renders as a plain decimal / integer.
_SCI_NOTATION_MIN = 0.01
_SCI_NOTATION_MAX = 10000
# Precision format for plain-decimal floats (trailing zeros stripped afterward).
_DECIMAL_FLOAT_FORMAT = "%.12g"
# Precision format for scientific-notation numbers.
_SCIENTIFIC_FORMAT = "%.6e"
# JSON string tokens for non-finite values → their float value.
_NONFINITE = {"Infinity": math.inf, "-Infinity": -math.inf, "NaN": math.nan}


def _format_number(num: int | float, format_type: str) -> str:
    """Format a number per the rendering contract (number-formatting section).

    Non-finite values render as symbols (``∞`` / ``−∞`` / ``NaN``); the unicode
    sign is U+2212 (mantissa AND exponent); ascii scientific notation carries NO
    ``+`` on a positive exponent; mantissa precision is never lost.
    """
    if isinstance(num, float):
        if math.isinf(num):
            if format_type == "unicode":
                return "∞" if num > 0 else "−∞"
            if format_type == "latex":
                return "\\infty" if num > 0 else "-\\infty"
            return "inf" if num > 0 else "-inf"
        if math.isnan(num):
            if format_type == "latex":
                return "\\text{NaN}"
            return "NaN"

    if num == 0:
        return "0"

    abs_num = abs(num)

    if abs_num < _SCI_NOTATION_MIN or abs_num >= _SCI_NOTATION_MAX:
        mantissa, exponent = (_SCIENTIFIC_FORMAT % num).split("e")
        exp = int(exponent)
        mantissa_val = float(mantissa)
        # A whole mantissa keeps one decimal place ("2.0") to preserve precision.
        if mantissa_val == int(mantissa_val):
            mantissa = f"{int(mantissa_val)}.0"
        else:
            mantissa = str(mantissa_val)
        if format_type == "unicode":
            return f"{mantissa.replace('-', '−')}×10{_to_superscript(str(exp))}"
        if format_type == "latex":
            return f"{mantissa} \\times 10^{{{exp}}}"
        # ascii: no leading `+` on a positive exponent.
        return f"{mantissa}e{exp}"

    # Plain-decimal band. Integers (and integral floats) print without a point,
    # via the shared canonical-number rule (:func:`serialize._canonical_number`).
    canon = _canonical_number(num)
    if isinstance(canon, int):
        s = str(canon)
    else:
        s = (_DECIMAL_FLOAT_FORMAT % num).rstrip("0").rstrip(".")
    if format_type == "unicode":
        s = s.replace("-", "−")
    return s


def _latex_mult_sep(args) -> str:
    """LaTeX multiplication separator (pretty-print.ts `*`).

    A product whose operands are already-typeset factors (a string containing a
    backslash, e.g. ``\\mathrm{O_3}``) is written by implicit juxtaposition (a
    space); a product of plain symbols uses ``\\cdot`` to stay unambiguous.
    """
    return " " if any(isinstance(a, str) and "\\" in a for a in args) else " \\cdot "


def _get_operator_precedence(op: str) -> int:
    """Get operator precedence for proper parenthesization."""
    precedence_map = {
        "or": 1,
        "and": 2,
        "=": 3,
        "==": 3,
        "!=": 3,
        "<": 3,
        ">": 3,
        "<=": 3,
        ">=": 3,
        "+": 4,
        "-": 4,
        "*": 5,
        "/": 5,
        "not": 6,  # Unary
        "^": 7,
        "**": 7,
        "pow": 7,
    }
    return precedence_map.get(op, 8)  # Functions get highest precedence


def _needs_parentheses(parent: ExprNode, child: Expr, is_right_operand: bool = False) -> bool:
    """Check if parentheses are needed around a subexpression."""
    if isinstance(child, (int, float, str)):
        return False

    # Read the child's operator whether the child is an ExprNode or a
    # dict-style node — the precedence rules below are identical for both.
    if isinstance(child, ExprNode):
        child_op = child.op
    elif isinstance(child, dict) and "op" in child:
        child_op = child["op"]
    else:
        return False

    parent_prec = _get_operator_precedence(parent.op)
    child_prec = _get_operator_precedence(child_op)

    if child_prec < parent_prec:
        return True
    if child_prec > parent_prec:
        return False

    # Same precedence: need parens if child is right operand and operator is not
    # associative (subtraction / division / exponentiation).
    if is_right_operand and parent.op in ["-", "/", "^", "**", "pow"]:
        return True

    # `^` is RIGHT-associative, so a LEFT-nested power must be parenthesized:
    # `(a^b)^c` reads back correctly, `a^b^c` would mean `a^(b^c)` (contract F-7).
    if not is_right_operand and parent.op in ["^", "**", "pow"]:
        return True

    return False


def _format(target: Expr | Equation | Model | ReactionSystem | EsmFile, format_type: str) -> str:
    """
    Shared dispatch backing to_unicode/to_latex/to_ascii.

    ``format_type`` is one of "unicode", "latex", or "ascii" and is threaded
    down to the leaf formatters. Container summaries (EsmFile/Model/
    ReactionSystem) have no dedicated LaTeX form, so they are rendered as plain
    text ("ascii") whenever ``format_type`` is not "unicode".
    """
    if target is None:
        return "None"

    if isinstance(target, (int, float)):
        return _format_number(target, format_type)

    if isinstance(target, str):
        # Non-finite values may arrive as the JSON string tokens; render them as
        # symbols (∞ / −∞ / NaN) rather than treating them as variable names.
        nonfinite = _NONFINITE.get(target)
        if nonfinite is not None:
            return _format_number(nonfinite, format_type)
        return _format_chemical_subscripts(target, format_type)

    if isinstance(target, ExprNode):
        return _format_expression_node(target, format_type)

    if isinstance(target, dict) and "op" in target:
        # Structural / array-query ops carry defining data in non-`args` fields
        # (value, table, axes, output_idx, …) that the ExprNode conversion below
        # would drop, so render them directly from the dict first.
        structural = _format_structural_op(target, format_type)
        if structural is not None:
            return structural
        # Handle dictionary-style expressions for compatibility
        args = target.get("args") or []
        node = ExprNode(op=target["op"], args=args, wrt=target.get("wrt"), dim=target.get("dim"))
        return _format_expression_node(node, format_type)

    if isinstance(target, dict):
        # Handle malformed dict expressions gracefully
        return str(target)

    if isinstance(target, Equation):
        return f"{_format(target.lhs, format_type)} = {_format(target.rhs, format_type)}"

    # Container summaries are rendered as plain text for both LaTeX and ASCII.
    summary_format = "unicode" if format_type == "unicode" else "ascii"

    if isinstance(target, EsmFile):
        return _format_esm_file_summary(target, summary_format)

    if isinstance(target, Model):
        return _format_model_summary(target, summary_format)

    if isinstance(target, ReactionSystem):
        return _format_reaction_system_summary(target, summary_format)

    label = {"unicode": "Unicode", "latex": "LaTeX", "ascii": "ASCII"}[format_type]
    raise ValueError(f"Unsupported type for {label} formatting: {type(target)}")


def to_unicode(target: Expr | Equation | Model | ReactionSystem | EsmFile) -> str:
    """
    Format target as Unicode mathematical notation with chemical subscripts.

    Args:
        target: Expression, equation, model, reaction system, or ESM file to format

    Returns:
        Unicode string representation
    """
    return _format(target, "unicode")


def to_latex(target: Expr | Equation | Model | ReactionSystem | EsmFile) -> str:
    """
    Format target as LaTeX mathematical notation.

    Args:
        target: Expression, equation, model, reaction system, or ESM file to format

    Returns:
        LaTeX string representation
    """
    return _format(target, "latex")


def to_ascii(target: Expr | Equation | Model | ReactionSystem | EsmFile) -> str:
    """
    Format target as plain ASCII mathematical notation.

    Args:
        target: Expression, equation, model, reaction system, or ESM file to format

    Returns:
        Plain ASCII string representation (no Unicode symbols)
    """
    return _format(target, "ascii")


def _node_field(node, key, default=None):
    """Read a field from an expression node, whether it is a dict or ExprNode."""
    if isinstance(node, dict):
        return node.get(key, default)
    return getattr(node, key, default)


def _is_op_node(expr) -> bool:
    """True if the value is an operator node (dict with 'op' or an ExprNode)."""
    return isinstance(expr, ExprNode) or (isinstance(expr, dict) and "op" in expr)


def _render_expr(expr: Expr, format_type: str) -> str:
    """Render a sub-expression in the requested text format."""
    return {"unicode": to_unicode, "latex": to_latex, "ascii": to_ascii}[format_type](expr)


def _wrap_if_op(expr: Expr, format_type: str) -> str:
    """Parenthesize a sub-expression only when it is an operator node."""
    s = _render_expr(expr, format_type)
    if _is_op_node(expr):
        return f"({s})"
    return s


def _latex_name(name: str) -> str:
    """Escape LaTeX-special underscores in a bare operator / identifier name."""
    return name.replace("_", "\\_")


def _format_const_value(value, format_type: str) -> str:
    """Format a ``const`` node's literal value (scalar number or nested array)."""
    if isinstance(value, list):
        return "[" + ", ".join(_format_const_value(v, format_type) for v in value) + "]"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return _format_number(value, format_type)
    return str(value)


def _format_bound(value, format_type: str) -> str:
    """Format a structural integer bound (region / shape / range entry)."""
    if isinstance(value, bool):
        return str(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return value
    if isinstance(value, float):
        canon = _canonical_number(value)
        return str(canon) if isinstance(canon, int) else str(value)
    if _is_op_node(value):
        return _render_expr(value, format_type)
    return str(value)


def _aggregate_symbol(semiring, reduce, format_type: str) -> str:
    """Big-operator symbol for an ``aggregate`` reduction (semiring supersedes reduce)."""
    if semiring:
        if semiring in ("max_product", "max_sum"):
            fam = "max"
        elif semiring == "min_sum":
            fam = "min"
        elif semiring == "bool_and_or":
            fam = "bool"
        else:
            fam = "plus"
    else:
        fam = (
            "times"
            if reduce == "*"
            else "max"
            if reduce == "max"
            else "min"
            if reduce == "min"
            else "plus"
        )
    table = {
        "plus": ("Σ", "\\sum", "sum"),
        "times": ("Π", "\\prod", "prod"),
        "max": ("max", "\\max", "max"),
        "min": ("min", "\\min", "min"),
        "bool": ("⋁", "\\bigvee", "any"),
    }
    u, latex, ascii_ = table[fam]
    return u if format_type == "unicode" else latex if format_type == "latex" else ascii_


def _format_ranges_clause(ranges: dict, format_type: str) -> str:
    """Render the ` where {…}` range clause shared by aggregate and argmin/argmax."""
    in_sym = " \\in " if format_type == "latex" else "∈" if format_type == "unicode" else " in "
    parts = []
    for k in sorted(ranges.keys()):
        rng = ranges[k]
        if isinstance(rng, list):
            rng_str = ":".join(_format_bound(x, format_type) for x in rng)
        elif isinstance(rng, dict) and "from" in rng:
            frm = str(rng["from"])
            of = rng.get("of")
            rng_str = f"{frm}({', '.join(of)})" if of else frm
        else:
            rng_str = str(rng)
        parts.append(f"{k}{in_sym}{rng_str}")
    if format_type == "latex":
        return " \\text{ where } \\{" + ", ".join(parts) + "\\}"
    return " where {" + ", ".join(parts) + "}"


def _format_aggregate(node, format_type: str) -> str:
    """Render an ``aggregate`` node per the rendering contract."""

    def r(e):
        return _render_expr(e, format_type)

    output_idx = _node_field(node, "output_idx") or []
    out_idx = ", ".join(str(o) for o in output_idx)
    expr = _node_field(node, "expr")
    expr_str = r(expr) if expr is not None else ""
    semiring = _node_field(node, "semiring")
    reduce = _node_field(node, "reduce")
    if reduce is None:
        reduce = "+"
    sym = _aggregate_symbol(semiring, reduce, format_type)
    idx_part = f"_{{{out_idx}}}" if format_type == "latex" else f"[{out_idx}]"
    out = f"{sym}{idx_part} ({expr_str})"
    ranges = _node_field(node, "ranges")
    if ranges:
        out += _format_ranges_clause(ranges, format_type)
    join = _node_field(node, "join")
    if join:
        clauses = "; ".join(
            ", ".join(f"{p[0]}={p[1]}" for p in (c.get("on") or [])) for c in join
        )
        out += f" join({clauses})"
    filt = _node_field(node, "filter")
    if filt is not None:
        out += f" if {r(filt)}"
    if _node_field(node, "distinct") is True:
        out += " distinct"
    key = _node_field(node, "key")
    if key is not None:
        out += f" key={r(key)}"
    if semiring and semiring != "sum_product":
        out += f" [semiring={semiring}]"
    return out


def _format_arg_witness(node, format_type: str) -> str:
    """Render an ``argmin`` / ``argmax`` arg-witness node per the rendering contract."""

    def r(e):
        return _render_expr(e, format_type)

    arg = str(_node_field(node, "arg") or "")
    expr = _node_field(node, "expr")
    expr_str = r(expr) if expr is not None else ""
    idx_part = f"_{{{arg}}}" if format_type == "latex" else f"[{arg}]"
    op = _node_field(node, "op")
    name = f"\\mathrm{{{op}}}" if format_type == "latex" else op
    out = f"{name}{idx_part} ({expr_str})"
    ranges = _node_field(node, "ranges")
    if ranges:
        out += _format_ranges_clause(ranges, format_type)
    return out


def _format_structural_op(node, format_type: str):
    """
    Render the closed-core structural / array-query ops (esm-spec §4.2), whose
    defining data lives in fields OTHER than ``args``, plus ``integral``.

    Returns a fully-formatted string, or ``None`` for ops handled by the
    scalar-op dispatch (arithmetic, elementary functions, comparisons, D, Pre,
    …) or by the generic fallback (open-tier sugar grad/div/laplacian, unknown
    user ops). Mirrors pretty-print.ts formatStructuralOp; see
    tests/display/RENDERING_CONTRACT.md.
    """
    op = _node_field(node, "op")
    args = _node_field(node, "args") or []

    def r(e):
        return _render_expr(e, format_type)

    if op == "const":
        return _format_const_value(_node_field(node, "value"), format_type)

    if op == "true":
        return "true"

    if op == "fn":
        name = str(_node_field(node, "name") or "")
        inner = ", ".join(r(a) for a in args)
        if format_type == "latex":
            return f"\\mathrm{{{_latex_name(name)}}}({inner})"
        return f"{name}({inner})"

    if op == "enum":
        label = f"{args[0]}.{args[1]}"
        if format_type == "latex":
            return f"\\mathrm{{{_latex_name(label)}}}"
        return label

    if op == "index":
        if len(args) == 0:
            return None
        arr, idx = args[0], args[1:]
        return f"{_wrap_if_op(arr, format_type)}[{', '.join(r(i) for i in idx)}]"

    if op == "broadcast":
        fn = _node_field(node, "fn")
        if not isinstance(fn, str):
            return None
        return _render_expr({"op": fn, "args": args}, format_type)

    if op == "integral":
        if len(args) == 0:
            return None
        f = r(args[0])
        v = str(_node_field(node, "var") or "x")
        lower = _node_field(node, "lower")
        upper = _node_field(node, "upper")
        lo = r(lower) if lower is not None else ""
        hi = r(upper) if upper is not None else ""
        if format_type == "latex":
            return f"\\int_{{{lo}}}^{{{hi}}} {f} \\, d{v}"
        if format_type == "unicode":
            return f"∫[{lo}, {hi}] {f} d{v}"
        return f"integral({f}, {v}, {lo}, {hi})"

    if op == "table_lookup":
        table = str(_node_field(node, "table") or "")
        axes = _node_field(node, "axes")
        if axes is None:
            axes = _node_field(node, "table_axes") or {}
        eq = " = " if format_type == "latex" else "="
        bindings = ", ".join(f"{k}{eq}{r(axes[k])}" for k in sorted(axes.keys()))
        output = _node_field(node, "output")
        out_str = f":{output}" if output is not None else ""
        name = f"\\mathrm{{{_latex_name(table)}}}" if format_type == "latex" else table
        return f"{name}[{bindings}]{out_str}"

    if op == "apply_expression_template":
        name = str(_node_field(node, "name") or "")
        bindings = _node_field(node, "bindings") or {}
        eq = " = " if format_type == "latex" else "="
        inner = ", ".join(f"{k}{eq}{r(bindings[k])}" for k in sorted(bindings.keys()))
        if format_type == "latex":
            return f"\\mathrm{{{_latex_name(name)}}}\\langle {inner} \\rangle"
        if format_type == "unicode":
            return f"{name}⟨{inner}⟩"
        return f"{name}<{inner}>"

    if op == "makearray":
        regions = _node_field(node, "regions") or []
        values = _node_field(node, "values") or []
        parts = []
        for i, region in enumerate(regions):
            reg_str = ", ".join(
                f"{_format_bound(dim[0], format_type)}:{_format_bound(dim[1], format_type)}"
                for dim in region
            )
            val = r(values[i]) if i < len(values) else "?"
            parts.append(f"[{reg_str}] = {val}")
        name = "\\mathrm{makearray}" if format_type == "latex" else "makearray"
        return f"{name}({', '.join(parts)})"

    if op == "reshape":
        if len(args) == 0:
            return None
        shape = ", ".join(_format_bound(s, format_type) for s in (_node_field(node, "shape") or []))
        name = "\\mathrm{reshape}" if format_type == "latex" else "reshape"
        return f"{name}({r(args[0])}, [{shape}])"

    if op == "transpose":
        if len(args) == 0:
            return None
        perm = _node_field(node, "perm")
        if perm:
            name = "\\mathrm{transpose}" if format_type == "latex" else "transpose"
            return f"{name}({r(args[0])}, [{', '.join(str(p) for p in perm)}])"
        a = _wrap_if_op(args[0], format_type)
        if format_type == "latex":
            return f"{a}^{{T}}"
        if format_type == "unicode":
            return f"{a}ᵀ"
        return f"transpose({r(args[0])})"

    if op == "concat":
        inner = ", ".join(r(a) for a in args)
        axis = _node_field(node, "axis")
        if axis is None:
            axis = 0
        name = "\\mathrm{concat}" if format_type == "latex" else "concat"
        return f"{name}({inner}, axis={axis})"

    if op in ("intersect_polygon", "polygon_intersection_area"):
        inner = ", ".join(r(a) for a in args)
        manifold = _node_field(node, "manifold")
        name = f"\\mathrm{{{_latex_name(op)}}}" if format_type == "latex" else op
        return f"{name}({inner}, manifold={manifold if manifold is not None else ''})"

    if op == "aggregate":
        return _format_aggregate(node, format_type)

    if op in ("argmin", "argmax"):
        return _format_arg_witness(node, format_type)

    return None


def _format_expression_node(node: ExprNode, format_type: str) -> str:
    """Format an ExpressionNode (operator with arguments)."""
    op, args = node.op, node.args
    wrt = getattr(node, "wrt", None)

    # Closed-core structural / array-query ops (const, fn, index, aggregate, …)
    # render from fields other than `args`; try them first.
    structural = _format_structural_op(node, format_type)
    if structural is not None:
        return structural

    # Formatter dispatch
    _fmt = {"unicode": to_unicode, "latex": to_latex, "ascii": to_ascii}[format_type]

    def format_arg(arg: Expr, is_right_operand: bool = False) -> str:
        result = _fmt(arg)
        if _needs_parentheses(node, arg, is_right_operand):
            return f"({result})"
        return result

    def _latex_func(name, arg_str):
        """Wrap function call: use \\left/\\right when arg contains \\frac."""
        if "\\frac" in arg_str:
            return f"\\{name}\\left({arg_str}\\right)"
        return f"\\{name}({arg_str})"

    # ---- N-ary / Binary operators ----
    if len(args) >= 2:
        # Fold n-ary operators left-to-right when there are more than two args.
        # esm-spec §6.1 pins +, *, min, max, and, or as n-ary (e.g. `+` renders
        # `a + b + c`). The exactly-2-arg cases fall through to the binary
        # handlers below, which carry per-op niceties (a+(-b) → a−b,
        # same-precedence parenthesization) that the plain fold does not need.
        if len(args) > 2:
            if op == "*":
                latex_sep = _latex_mult_sep(args)
                result = format_arg(args[0])
                for a in args[1:]:
                    fa = format_arg(a, True)
                    if format_type == "unicode":
                        result = f"{result}·{fa}"
                    elif format_type == "latex":
                        result = f"{result}{latex_sep}{fa}"
                    else:
                        result = f"{result} * {fa}"
                return result
            if op == "+":
                result = format_arg(args[0])
                for a in args[1:]:
                    # a + (-b) → a − b (per-term, mirroring the 2-arg branch).
                    neg_inner = None
                    if isinstance(a, ExprNode) and a.op == "-" and len(a.args) == 1:
                        neg_inner = a.args[0]
                    elif (
                        isinstance(a, dict)
                        and a.get("op") == "-"
                        and len(a.get("args", [])) == 1
                    ):
                        neg_inner = a["args"][0]
                    if neg_inner is not None:
                        sep = " − " if format_type == "unicode" else " - "
                        result = f"{result}{sep}{_fmt(neg_inner)}"
                    else:
                        result = f"{result} + {format_arg(a, True)}"
                return result
            if op in ("and", "or"):
                if format_type == "unicode":
                    sym = " ∧ " if op == "and" else " ∨ "
                    return sym.join(format_arg(a) for a in args)
                if format_type == "latex":
                    sym = " \\land " if op == "and" else " \\lor "
                    return sym.join(format_arg(a) for a in args)
                # ascii: word operators, precedence disambiguates (no parens).
                sym = " and " if op == "and" else " or "
                return sym.join(format_arg(a) for a in args)
            if op in ("min", "max"):
                if format_type == "latex":
                    return f"\\{op}(" + ", ".join(to_latex(a) for a in args) + ")"
                return f"{op}(" + ", ".join(format_arg(a) for a in args) + ")"

        left, right = args[0], args[1]

        if op == "+":
            # Detect a + (-b) → render as a − b
            is_neg = False
            if isinstance(right, ExprNode) and right.op == "-" and len(right.args) == 1:
                is_neg = True
                neg_inner = right.args[0]
            elif (
                isinstance(right, dict)
                and right.get("op") == "-"
                and len(right.get("args", [])) == 1
            ):
                is_neg = True
                neg_inner = right["args"][0]
            if is_neg:
                sep = " − " if format_type == "unicode" else " - "
                return f"{format_arg(left)}{sep}{_fmt(neg_inner)}"
            return f"{format_arg(left)} + {format_arg(right, True)}"

        if op == "-":
            sep = " − " if format_type == "unicode" else " - "
            return f"{format_arg(left)}{sep}{format_arg(right, True)}"

        if op == "*":
            if format_type == "unicode":
                return f"{format_arg(left)}·{format_arg(right, True)}"
            if format_type == "latex":
                return f"{format_arg(left)}{_latex_mult_sep(args)}{format_arg(right, True)}"
            return f"{format_arg(left)} * {format_arg(right, True)}"

        if op == "/":
            if format_type == "latex":
                return f"\\frac{{{to_latex(left)}}}{{{to_latex(right)}}}"
            if format_type == "unicode":
                return f"{format_arg(left)}/{format_arg(right, True)}"
            return f"{format_arg(left)} / {format_arg(right, True)}"

        if op in ("^", "**", "pow"):
            if format_type == "latex":
                return f"{format_arg(left)}^{{{to_latex(right)}}}"
            if format_type == "unicode" and isinstance(right, int):
                return f"{format_arg(left)}{_to_superscript(str(right))}"
            return f"{format_arg(left)}^{format_arg(right, True)}"

        if op in ("=", "=="):
            if format_type == "unicode":
                return f"{format_arg(left)} = {format_arg(right, True)}"
            if format_type == "latex":
                return f"{format_arg(left)} = {format_arg(right, True)}"
            return f"{format_arg(left)} == {format_arg(right, True)}"

        if op == "!=":
            if format_type == "unicode":
                return f"{format_arg(left)} ≠ {format_arg(right, True)}"
            if format_type == "latex":
                return f"{format_arg(left)} \\neq {format_arg(right, True)}"
            return f"{format_arg(left)} != {format_arg(right, True)}"

        if op in ("<", ">"):
            return f"{format_arg(left)} {op} {format_arg(right, True)}"

        if op == ">=":
            if format_type == "unicode":
                return f"{format_arg(left)} ≥ {format_arg(right, True)}"
            if format_type == "latex":
                return f"{format_arg(left)} \\geq {format_arg(right, True)}"
            return f"{format_arg(left)} >= {format_arg(right, True)}"

        if op == "<=":
            if format_type == "unicode":
                return f"{format_arg(left)} ≤ {format_arg(right, True)}"
            if format_type == "latex":
                return f"{format_arg(left)} \\leq {format_arg(right, True)}"
            return f"{format_arg(left)} <= {format_arg(right, True)}"

        if op == "and":
            if format_type == "unicode":
                return f"{format_arg(left)} ∧ {format_arg(right, True)}"
            if format_type == "latex":
                return f"{format_arg(left)} \\land {format_arg(right, True)}"
            return f"{format_arg(left)} and {format_arg(right, True)}"

        if op == "or":
            if format_type == "unicode":
                return f"{format_arg(left)} ∨ {format_arg(right, True)}"
            if format_type == "latex":
                return f"{format_arg(left)} \\lor {format_arg(right, True)}"
            return f"{format_arg(left)} or {format_arg(right, True)}"

        if op in ("min", "max"):
            if format_type == "latex":
                return f"\\{op}({to_latex(left)}, {to_latex(right)})"
            return f"{op}({format_arg(left)}, {format_arg(right)})"

        if op == "atan2":
            if format_type == "latex":
                return f"\\mathrm{{atan2}}({to_latex(left)}, {to_latex(right)})"
            return f"atan2({_fmt(left)}, {_fmt(right)})"

    # ---- Unary operators ----
    if len(args) == 1:
        arg = args[0]
        fa = _fmt(arg)

        if op == "-":
            if format_type == "unicode":
                return f"−{format_arg(arg)}"
            return f"-{format_arg(arg)}"

        if op == "not":
            if format_type == "unicode":
                return f"¬{format_arg(arg)}"
            if format_type == "latex":
                return f"\\neg {format_arg(arg)}"
            return f"not {format_arg(arg)}"

        # Standard trig
        if op in ("sin", "cos", "tan"):
            if format_type == "latex":
                return _latex_func(op, to_latex(arg))
            return f"{op}({fa})"

        # Inverse trig
        if op in ("asin", "acos", "atan"):
            base = op[1:]  # sin, cos, tan
            if format_type == "unicode":
                return f"arc{base}({fa})"
            if format_type == "latex":
                return f"\\arc{base}({to_latex(arg)})"
            return f"{op}({fa})"

        # Hyperbolic
        if op in ("sinh", "cosh", "tanh"):
            if format_type == "latex":
                return _latex_func(op, to_latex(arg))
            return f"{op}({fa})"

        # Inverse hyperbolic
        if op in ("asinh", "acosh", "atanh"):
            base = op[1:]  # sinh, cosh, tanh
            if format_type == "unicode":
                return f"{base}⁻¹({fa})"
            if format_type == "latex":
                return f"\\{base}^{{-1}}({to_latex(arg)})"
            return f"{op}({fa})"

        if op == "exp":
            if format_type == "latex":
                return _latex_func("exp", to_latex(arg))
            return f"exp({fa})"

        if op == "log":
            if format_type == "unicode":
                return f"ln({fa})"
            if format_type == "latex":
                return _latex_func("ln", to_latex(arg))
            return f"log({fa})"

        if op == "log10":
            if format_type == "unicode":
                return f"log₁₀({fa})"
            if format_type == "latex":
                return f"\\log_{{10}}({to_latex(arg)})"
            return f"log10({fa})"

        if op == "sqrt":
            if format_type == "unicode":
                # Parenthesize a compound radicand for clarity: √(a² + b²).
                return f"√({fa})" if _is_op_node(arg) else f"√{fa}"
            if format_type == "latex":
                return f"\\sqrt{{{to_latex(arg)}}}"
            return f"sqrt({fa})"

        if op == "abs":
            if format_type == "ascii":
                return f"abs({fa})"
            return f"|{fa}|"

        if op == "floor":
            if format_type == "unicode":
                return f"⌊{fa}⌋"
            if format_type == "latex":
                return f"\\lfloor {to_latex(arg)} \\rfloor"
            return f"floor({fa})"

        if op == "ceil":
            if format_type == "unicode":
                return f"⌈{fa}⌉"
            if format_type == "latex":
                return f"\\lceil {to_latex(arg)} \\rceil"
            return f"ceil({fa})"

        if op == "D":
            wrt_var = wrt or "t"
            # The operand is parenthesized when it is an operator node so
            # `∂(x + y)/∂t` cannot read back as `(∂x) + (y/∂t)` (contract F-7).
            if format_type == "unicode":
                return f"∂{_wrap_if_op(arg, 'unicode')}/∂{wrt_var}"
            if format_type == "latex":
                return f"\\frac{{\\partial {_wrap_if_op(arg, 'latex')}}}{{\\partial {wrt_var}}}"
            # ascii fraction form mirroring unicode/latex ∂x/∂t: `D(x)/Dt`, and
            # `D(x + y)/Dt` for an operator-node operand (the D() call parens
            # supply the parenthesization the goldens require).
            return f"D({to_ascii(arg)})/D{wrt_var}"

        if op == "sign":
            if format_type == "unicode":
                return f"sgn({fa})"
            if format_type == "latex":
                return f"\\mathrm{{sgn}}({to_latex(arg)})"
            return f"sign({fa})"

        if op == "Pre":
            if format_type == "latex":
                return f"\\mathrm{{Pre}}({to_latex(arg)})"
            return f"Pre({fa})"

    # ---- Ternary: ifelse ----
    if op == "ifelse" and len(args) == 3:
        cond, if_true, if_false = args
        if format_type == "latex":
            return (
                f"\\begin{{cases}} {to_latex(if_true)} & "
                f"\\text{{if }} {to_latex(cond)} \\\\ "
                f"{to_latex(if_false)} & \\text{{otherwise}} \\end{{cases}}"
            )
        return f"ifelse({_fmt(cond)}, {_fmt(if_true)}, {_fmt(if_false)})"

    # Generic fallback: function-call notation. This is the correct rendering for
    # every op that reaches here — the relational build-time ops
    # (skolem/rank/distinct/join/…) which carry no dedicated math notation, and
    # the open-tier rewrite-target sugar (grad/div/laplacian/curl) which is
    # ordinary unregistered document sugar a rewrite rule lowers before eval,
    # rendered identically to any custom user op (`godunov_hamiltonian`). None of
    # these is an error, so no "unknown op" warning is emitted. Only `args` shown.
    if format_type == "unicode":
        arg_list = ", ".join(to_unicode(arg) for arg in args)
    elif format_type == "latex":
        arg_list = ", ".join(to_latex(arg) for arg in args)
        return f"\\mathrm{{{_latex_name(op)}}}({arg_list})"
    elif format_type == "ascii":
        arg_list = ", ".join(to_ascii(arg) for arg in args)
    else:
        arg_list = ", ".join(str(arg) for arg in args)

    return f"{op}({arg_list})"


def _format_model_summary(model: Model, format_type: str) -> str:
    """Format model summary (implementation per spec Section 6.3)."""
    name = getattr(model, "name", "unnamed")
    eq_count = len(model.equations) if model.equations else 0

    if not model.variables:
        return f"Model: {name} (0 variables, {eq_count} equations)"

    # Count variables by type according to spec Section 6.3
    type_counts = {"state": 0, "parameter": 0, "observed": 0}

    for _var_name, var_info in model.variables.items():
        var_type = getattr(var_info, "type", "unknown")
        if var_type in type_counts:
            type_counts[var_type] += 1

    # Create the type summary according to spec Section 6.3 format
    type_parts = []
    if type_counts["state"] > 0:
        if type_counts["state"] == 1:
            type_parts.append("1 state")
        else:
            type_parts.append(f"{type_counts['state']} state")

    if type_counts["parameter"] > 0:
        if type_counts["parameter"] == 1:
            type_parts.append("1 parameter")
        else:
            type_parts.append(f"{type_counts['parameter']} parameters")

    if type_counts["observed"] > 0:
        if type_counts["observed"] == 1:
            type_parts.append("1 observed")
        else:
            type_parts.append(f"{type_counts['observed']} observed")

    type_summary = ", ".join(type_parts) if type_parts else "0 variables"
    eq_text = "equation" if eq_count == 1 else "equations"
    return f"Model: {name} ({type_summary}, {eq_count} {eq_text})"


def _format_reaction_system_summary(reaction_system: ReactionSystem, format_type: str) -> str:
    """Format reaction system summary showing reactions in chemical notation."""
    name = getattr(reaction_system, "name", "unnamed")
    species_count = len(reaction_system.species) if reaction_system.species else 0
    reaction_count = len(reaction_system.reactions) if reaction_system.reactions else 0
    return f"ReactionSystem: {name} ({species_count} species, {reaction_count} reactions)"


def _format_esm_file_summary(esm_file: EsmFile, format_type: str) -> str:
    """Format ESM file summary (implementation per spec Section 6.3)."""
    models_count = len(esm_file.models) if esm_file.models else 0
    reaction_systems_count = len(esm_file.reaction_systems) if esm_file.reaction_systems else 0
    data_loaders_count = len(esm_file.data_loaders) if esm_file.data_loaders else 0
    title = getattr(esm_file.metadata, "title", "Untitled")

    return f"ESM v{esm_file.version}: {title} ({models_count} models, {reaction_systems_count} reaction systems, {data_loaders_count} data loaders)"


# Add _repr_latex_ methods for Jupyter notebook rich display


def _add_repr_methods():
    """Add _repr_latex_ methods to classes for Jupyter rich display."""

    def esm_file_repr_latex(self) -> str:
        return to_latex(self)

    def model_repr_latex(self) -> str:
        return to_latex(self)

    def reaction_system_repr_latex(self) -> str:
        return to_latex(self)

    def equation_repr_latex(self) -> str:
        return to_latex(self)

    # Add methods to classes
    EsmFile._repr_latex_ = esm_file_repr_latex
    Model._repr_latex_ = model_repr_latex
    ReactionSystem._repr_latex_ = reaction_system_repr_latex
    Equation._repr_latex_ = equation_repr_latex


# Initialize the _repr_latex_ methods when the module is imported
_add_repr_methods()
