"""Jupyter rich display (esm-libraries-spec §5.3.6).

Importing the package gives :class:`Equation`, :class:`Model`,
:class:`ReactionSystem` and :class:`EsmFile` a ``_repr_latex_`` method, which a
notebook shows as display math. Every expression is printed by
:func:`~earthsci_ast.print_math` in its LaTeX (``"markdown"``) form, under the
names the component declares:

* an equation is one display;
* a model shows its equations, one per line;
* a reaction system shows each reaction as its substrates, an arrow labelled
  with the rate, and its products, then its constraint equations;
* a file shows each model and reaction system in turn, each under its name.

A component with nothing to show returns ``None``, and the notebook falls back to
the plain ``repr``.
"""

from __future__ import annotations

from collections.abc import Iterable

from .document import expression_names, print_math
from .esm_types import Equation, EsmFile, Model, ReactionSystem
from .serialize import _serialize_equation, _serialize_expression


def _display(rows: list[str]) -> str | None:
    if not rows:
        return None
    return "$$\\begin{gathered}\n" + " \\\\\n".join(rows) + "\n\\end{gathered}$$"


def _equation_rows(equations: Iterable[Equation], names: list[str]) -> list[str]:
    return [print_math(_serialize_equation(eq), names, "markdown") for eq in equations]


def _model_rows(model: Model) -> list[str]:
    return _equation_rows(model.equations, list(model.variables))


def _side(terms: list[tuple[str, int | float]], names: list[str]) -> str:
    if not terms:
        return "\\varnothing"
    out = []
    for species, coeff in terms:
        name = print_math(species, names, "markdown")
        out.append(name if coeff == 1 else f"{print_math(coeff, names, 'markdown')}\\,{name}")
    return " + ".join(out)


def _reaction_system_rows(rs: ReactionSystem) -> list[str]:
    names = [s.name for s in rs.species] + [p.name for p in rs.parameters]
    rows = []
    for r in rs.reactions:
        rate = (
            ""
            if r.rate_constant is None
            else print_math(_serialize_expression(r.rate_constant), names, "markdown")
        )
        rows.append(
            f"{_side(r.substrate_list(), names)} \\xrightarrow{{{rate}}} "
            f"{_side(r.product_list(), names)}"
        )
    return rows + _equation_rows(rs.constraint_equations, names)


# Each character TeX gives a meaning, as the math-mode symbol that prints it.
# Text-mode escapes do not travel: MathJax takes the argument of ``\textbf``
# literally unless its ``textmacros`` package is loaded, and has no
# ``\textbackslash`` when it is. These symbols render in MathJax and KaTeX alike.
_TEX_SPECIALS = {
    "\\": "\\backslash ",
    "{": "\\{",
    "}": "\\}",
    "$": "\\$",
    "&": "\\&",
    "#": "\\#",
    "%": "\\%",
    "_": "\\_",
    "^": "\\hat{}",
    "~": "\\tilde{}",
}


def _bold_text(text: str) -> str:
    """``text`` as bold display-math content, every character printed as written:
    the runs of ordinary characters in ``\\textbf``, each TeX special between
    them as its math-mode symbol."""
    out: list[str] = []
    run = ""
    for ch in text:
        if ch in _TEX_SPECIALS:
            if run:
                out.append(f"\\textbf{{{run}}}")
                run = ""
            out.append(_TEX_SPECIALS[ch])
        else:
            run += ch
    if run:
        out.append(f"\\textbf{{{run}}}")
    return "".join(out)


def _titled(name: str, rows: list[str]) -> list[str]:
    return [_bold_text(name), *rows] if rows else []


def _equation_repr_latex(self: Equation) -> str:
    eq = _serialize_equation(self)
    return f"$${print_math(eq, expression_names(eq), 'markdown')}$$"


def _model_repr_latex(self: Model) -> str | None:
    return _display(_model_rows(self))


def _reaction_system_repr_latex(self: ReactionSystem) -> str | None:
    return _display(_reaction_system_rows(self))


def _esm_file_repr_latex(self: EsmFile) -> str | None:
    rows: list[str] = []
    for name, model in self.models.items():
        rows += _titled(name, _model_rows(model))
    for name, rs in self.reaction_systems.items():
        rows += _titled(name, _reaction_system_rows(rs))
    return _display(rows)


Equation._repr_latex_ = _equation_repr_latex  # type: ignore[attr-defined]
Model._repr_latex_ = _model_repr_latex  # type: ignore[attr-defined]
ReactionSystem._repr_latex_ = _reaction_system_repr_latex  # type: ignore[attr-defined]
EsmFile._repr_latex_ = _esm_file_repr_latex  # type: ignore[attr-defined]
