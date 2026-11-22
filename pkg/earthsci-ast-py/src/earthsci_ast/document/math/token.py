"""Math tokens, shared by the two surfaces.

Port of ``formal/Esm/Document/Math/Token.lean``. A token names what the surface
text MEANS (``LAND`` is ``\\land`` in LaTeX and ``and`` in Typst), so one parser
reads both; each surface has its own renderer and lexer.

A keyword token (``Math.Kw``) is its name, a ``str``. Every other token is a tuple
whose first element is its tag:

* ``("num", n)``: a number (``int`` or :class:`~earthsci_ast.document.value.Dec`);
* ``("letter", c)``, ``("greek", g)``, ``("word", w)``, ``("it", s)``;
* ``("rm", raw)``: LaTeX ``\\mathrm{…}``, kept raw;
* ``("ups", ((text, digits), …))``: a Typst run of adjacent ``upright("…")``;
* ``("opn", s)``, ``("txt", s)``;
* ``("jstr", s)``: a LaTeX JSON string inside an escape node's fields;
* ``("esc", op)``: LaTeX ``\\esm{op}``;
* ``("code", value)``: Typst ``#value``;
* ``("units", ((symbol, exponent), …))``: the unit after a quantity's number;
* ``("arrc", n)``: LaTeX ``\\begin{array}{c…c}`` with ``n`` columns, the opener of a
  constant matrix wider than ``bmatrix`` allows.
"""

from __future__ import annotations

# Math.Kw: operators
PLUS = "Plus"
MINUS = "Minus"
EQ = "Eq"
NE = "Ne"
LT = "Lt"
GT = "Gt"
LE = "Le"
GE = "Ge"
LAND = "Land"
LOR = "Lor"
LNOT = "Lnot"
CDOT = "Cdot"
TIMES = "Times"
SLASH = "Slash"
CARET = "Caret"
US = "Us"
# delimiters: LP/RP call parentheses, LPG/RPG grouping parentheses
LP = "Lp"
RP = "Rp"
LPG = "Lpg"
RPG = "Rpg"
LB = "Lb"
RB = "Rb"
LBK = "Lbk"
RBK = "Rbk"
COMMA = "Comma"
SEMI = "Semi"
COLON = "Colon"
AMP = "Amp"
NL = "Nl"
SDOT = "Sdot"
# functions and notations
FRAC = "Frac"
SQRT = "Sqrt"
EXP = "Exp"
LN = "Ln"
LOG = "Log"
SIN = "Sin"
COS = "Cos"
TAN = "Tan"
ASIN = "Asin"
ACOS = "Acos"
ATAN = "Atan"
SINH = "Sinh"
COSH = "Cosh"
TANH = "Tanh"
MIN = "Min"
MAX = "Max"
LABS = "Labs"
RABS = "Rabs"
LFLOOR = "Lfloor"
RFLOOR = "Rfloor"
LCEIL = "Lceil"
RCEIL = "Rceil"
ABS = "Abs"
FLOOR = "Floor"
CEIL = "Ceil"
PDIFF = "Pdiff"
DIF = "Dif"
DOTACC = "Dotacc"
BCASES = "Bcases"
ECASES = "Ecases"
CASES = "Cases"
ESMNODE = "Esmnode"
# the nabla of the grad, div, laplacian and curl forms: LaTeX ``\\nabla``, Typst ``nabla``
NABLA = "Nabla"
# constant arrays
BMAT = "Bmat"
EMAT = "Emat"
VEC = "Vec"
MAT = "Mat"
# faq reductions
SUM = "Sum"
PROD = "Prod"
INN = "Inn"
SUBSTACK = "Substack"
LIMITS = "Limits"
LBKG = "Lbkg"
RBKG = "Rbkg"
LR = "Lr"
#: The LaTeX marker ``\\limits``.
LIMITS_L = "LimitsL"
# makearray: LaTeX ``\\begin{array}{l|l}`` ``\\end{array}`` (the closer also ends a
# wide constant matrix, opened by the ``("arrc", n)`` token)
BARR = "Barr"
EARR = "Earr"
# a set of names, LaTeX ``\\{`` ``\\}``, Typst ``{`` ``}`` (the ``args`` of a ``faq``)
LSET = "Lset"
RSET = "Rset"

#: ``Math.Sf``: the two surfaces.
LATEX = "latex"
TYPST = "typst"


def is_kw(t: object) -> bool:
    return type(t) is str


def num(n: object) -> tuple:
    return ("num", n)
