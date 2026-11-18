"""Array and template notation of the document math surfaces: regression cases
for the reader accepting exactly what the printer writes (canonical-only
acceptance), the region product read as two ordinary tokens, ``delim`` /
``augment`` as ordinary words, and constant matrices wider than ``bmatrix``
allows."""

from __future__ import annotations

import pytest

from earthsci_ast.document.math import Sym, parse_latex, parse_typst, print_latex, print_typst
from earthsci_ast.document.math import token as K
from earthsci_ast.document.math.expr import REMOVED_SET
from earthsci_ast.document.math.latex import lex as lex_latex
from earthsci_ast.document.math.printer import ANNOT_KEYS, reserved_opn
from earthsci_ast.document.math.typst import lex as lex_typst
from earthsci_ast.document.value import from_plain, sort_obj, to_plain
from earthsci_ast.esm_types import NODE_ANNOTATION_KEYS

NAMES = frozenset({"x", "y", "A", "B", "i", "j", "f", "g", "t", "delim", "augment"})
S = Sym(NAMES, ())

SURFACES = [
    pytest.param(print_latex, parse_latex, id="latex"),
    pytest.param(print_typst, parse_typst, id="typst"),
]


def j(d):
    return sort_obj(from_plain(d))


def round_trips(pr, pa, s, e) -> str:
    t = pr(s, e)
    assert pa(s, t) == e, t
    return t


FAQ_OUT = j(
    {
        "op": "faq",
        "args": ["f"],
        "expr": {"op": "index", "args": ["A", "i", "j"]},
        "output_idx": ["i"],
        "ranges": {"j": {"from": "J"}},
    }
)
FAQ_RANK0 = j(
    {
        "op": "faq",
        "args": ["f"],
        "expr": {"op": "index", "args": ["A", "j"]},
        "output_idx": [],
        "ranges": {"j": {"from": "J"}},
    }
)


# ## Reductions: superscript sets


@pytest.mark.parametrize(
    "text",
    [
        r"\sum\limits_{j \in J}^{\{f\}} A_{j}",
        r"\left[\sum\limits_{j \in J} A_{i, j}\right]^{\{f\}}_{i}",
        r"\left[\sum\limits_{j \in J}^{\{f\}} A_{i, j}\right]_{i}",
    ],
)
def test_marked_head_with_a_set_is_refused_latex(text):
    assert parse_latex(S, text) is None


@pytest.mark.parametrize(
    "text",
    [
        "limits(sum)_(j in J)^({f}) A_j",
        "lr([limits(sum)_(j in J) A_(i, j)])^({f})_(i)",
        "lr([limits(sum)_(j in J)^({f}) A_(i, j)])_(i)",
    ],
)
def test_marked_head_with_a_set_is_refused_typst(text):
    assert parse_typst(S, text) is None


def test_output_form_set_is_on_the_bracket_only():
    assert print_latex(S, FAQ_OUT) == r"\left[\sum_{j \in J} A_{i, j}\right]^{\{f\}}_{i}"
    assert parse_latex(S, r"\left[\sum_{j \in J} A_{i, j}\right]^{\{f\}}_{i}") == FAQ_OUT
    # an inner set: refused with or without a bracket set
    assert parse_latex(S, r"\left[\sum_{j \in J}^{\{f\}} A_{i, j}\right]_{i}") is None
    assert parse_latex(S, r"\left[\sum_{j \in J}^{\{g\}} A_{i, j}\right]^{\{f\}}_{i}") is None
    assert parse_typst(S, "lr([sum_(j in J)^({f}) A_(i, j)])_(i)") is None
    assert parse_typst(S, "lr([sum_(j in J)^({g}) A_(i, j)])^({f})_(i)") is None
    assert parse_typst(S, "lr([sum_(j in J) A_(i, j)])^({f})_(i)") == FAQ_OUT


@pytest.mark.parametrize(("pr", "pa"), SURFACES)
def test_rank0_reduction_keeps_its_own_set(pr, pa):
    t = round_trips(pr, pa, S, FAQ_RANK0)
    assert "{f}" in t.replace("\\", "")


# ## The `;` call form


def test_call_form_refuses_an_annotated_core_operator():
    assert parse_latex(S, r'\operatorname{transpose}(x; \mathrm{id} = \text{"a"})') is None
    assert (
        parse_latex(S, r'\operatorname{transpose}(x; \mathrm{expect\_cadence} = \text{"const"})')
        is None
    )
    assert parse_typst(S, 'op("transpose")(x; upright("id") = #"a")') is None
    e = j({"op": "transpose", "args": ["x"], "perm": [1, 0]})
    assert parse_latex(S, r"\operatorname{transpose}(x; \mathrm{perm} = [1, 0])") == e


def test_call_form_refuses_a_node_with_a_native_spelling():
    # this faq prints natively (`\sum x`), so its call form is not canonical
    e = j({"op": "faq", "args": [], "expr": "x", "output_idx": []})
    assert print_latex(S, e) == r"\sum x"
    assert (
        parse_latex(
            S,
            r"\operatorname{faq}(; \mathrm{expr} = x, \mathrm{output\_idx} = [])",
        )
        is None
    )
    # a const with an array value prints natively too
    assert parse_latex(S, r"\operatorname{const}(; \mathrm{value} = [1, 2])") is None


@pytest.mark.parametrize(("pr", "pa"), SURFACES)
def test_call_form_still_reads_what_the_printer_writes(pr, pa):
    for d in (
        {"op": "faq", "args": [], "expr": "x", "output_idx": [], "reduce": "foo"},
        {"op": "custom", "args": ["x"], "id": "a", "scheme": 2},
        {"op": "reshape", "args": ["x"], "shape": [2, 3]},
    ):
        t = round_trips(pr, pa, S, j(d))
        assert ";" in t, t


# ## Bare template names


def test_bare_template_name_out_of_scope_reads_and_prints_bare():
    e = j({"op": "apply_expression_template", "args": [], "name": "upwind", "bindings": {}})
    assert print_latex(S, e) == r"\operatorname{upwind}"
    assert parse_latex(S, r"\operatorname{upwind}") == e
    assert parse_latex(S, r"\operatorname{upwind} x") is not None
    assert print_typst(S, e) == 'op("upwind")'
    assert parse_typst(S, 'op("upwind")') == e


def test_bare_template_name_refused_when_in_scope_with_no_parameters():
    s0 = Sym(NAMES, (("upwind", ()),))
    e = j({"op": "apply_expression_template", "args": [], "name": "upwind", "bindings": {}})
    assert print_latex(s0, e) == r"\operatorname{upwind}()"
    assert parse_latex(s0, r"\operatorname{upwind}()") == e
    assert parse_latex(s0, r"\operatorname{upwind}") is None
    assert parse_latex(s0, r"\operatorname{upwind} x") is None
    assert parse_typst(s0, 'op("upwind")') is None
    # in scope with parameters: still bare
    s1 = Sym(NAMES, (("upwind", ("u",)),))
    assert print_latex(s1, e) == r"\operatorname{upwind}"
    assert parse_latex(s1, r"\operatorname{upwind}") == e


@pytest.mark.parametrize("name", ["grad", "div", "laplacian"])
def test_ops_removed_at_2_4_0_are_reserved(name):
    """esm 2.4.0 removed `grad`, `div` and `laplacian`: like every removed op,
    the name is reserved — never read as a template or an open operator."""
    assert reserved_opn(name)
    assert name in REMOVED_SET


# ## The region product: `\times` then `[`


def test_region_product_lexes_as_two_tokens():
    assert lex_latex(r"[1, 2] \times [3, 4]")[5:7] == [K.TIMES, K.LBK]
    assert lex_typst("[1, 2] times [3, 4]")[5:7] == [K.TIMES, K.LBK]
    assert not hasattr(K, "TIMES_LBK")


@pytest.mark.parametrize(("pr", "pa"), SURFACES)
def test_makearray_regions_round_trip(pr, pa):
    mk = j(
        {
            "op": "makearray",
            "args": [],
            "regions": [[[1, 2], [3, 4], [5, 6]], [[7, 8], [9, 10], [11, 12]]],
            "values": ["x", {"op": "*", "args": ["x", "y"]}],
        }
    )
    t = round_trips(pr, pa, S, mk)
    assert ("\\times [" if pr is print_latex else "times [") in t


def test_makearray_text_is_unchanged():
    mk = j(
        {
            "op": "makearray",
            "args": [],
            "regions": [[[1, 2], [3, 4]], [[5, 6], [7, 8]]],
            "values": ["x", "y"],
        }
    )
    assert print_latex(S, mk) == (
        r"\left[\begin{array}{l|l} x & [1, 2] \times [3, 4] \\ "
        r"y & [5, 6] \times [7, 8] \end{array}\right]"
    )
    assert print_typst(S, mk) == (
        'mat(delim: "[", augment: #1, x, [1, 2] times [3, 4]; y, [5, 6] times [7, 8])'
    )


def test_times_bracket_outside_a_region_is_a_product():
    prod = j({"op": "*", "args": ["x", "y"]})
    assert parse_latex(S, r"x \times [y]") == prod
    assert parse_latex(S, r"x \times[y]") == prod
    assert parse_typst(S, "x times [y]") == prod


# ## `delim` and `augment` are ordinary words


def test_delim_and_augment_are_names():
    s = Sym(frozenset({"x", "t", "delim", "augment"}), ())
    assert to_plain(parse_typst(s, "x = delim + 1")) == {
        "op": "==",
        "args": ["x", {"op": "+", "args": ["delim", 1]}],
    }
    assert to_plain(parse_typst(s, "(dif augment)/(dif t)")) == {
        "op": "D",
        "args": ["augment"],
        "wrt": "t",
    }
    assert parse_latex(s, "x = delim + augment") is not None
    e = j({"op": "+", "args": ["delim", "augment"]})
    round_trips(print_typst, parse_typst, s, e)
    round_trips(print_latex, parse_latex, s, e)


# ## Wide constant matrices


def _mat(cols: int) -> object:
    return j({"op": "const", "args": [], "value": [list(range(cols)), list(range(cols))]})


def test_wide_matrix_prints_as_an_array():
    e = j({"op": "const", "args": [], "value": [list(range(1, 12)), list(range(12, 23))]})
    t = print_latex(S, e)
    assert t == (
        r"\left[\begin{array}{ccccccccccc}1 & 2 & 3 & 4 & 5 & 6 & 7 & 8 & 9 & 10 & 11 \\ "
        r"12 & 13 & 14 & 15 & 16 & 17 & 18 & 19 & 20 & 21 & 22 \end{array}\right]"
    )
    assert parse_latex(S, t) == e
    assert print_typst(S, e).startswith("mat(1, 2,")
    assert parse_typst(S, print_typst(S, e)) == e


def test_wide_matrix_with_units_round_trips():
    e = j({"op": "const", "args": [], "units": "m", "value": [list(range(12))] * 2})
    assert print_latex(S, e).endswith(r"\end{array}\right]\,\mathrm{m}")
    assert parse_latex(S, print_latex(S, e)) == e


@pytest.mark.parametrize(("pr", "pa"), SURFACES)
def test_ten_columns_and_column_vectors_keep_bmatrix(pr, pa):
    t = round_trips(pr, pa, S, _mat(10))
    if pr is print_latex:
        assert t.startswith(r"\begin{bmatrix}")
    col = j({"op": "const", "args": [], "value": list(range(20))})
    t = round_trips(pr, pa, S, col)
    if pr is print_latex:
        assert t.startswith(r"\begin{bmatrix}")


def test_wide_matrix_non_canonical_spellings_are_refused():
    row11 = " & ".join(str(k) for k in range(11))
    row10 = " & ".join(str(k) for k in range(10))
    # a bmatrix wider than ten columns
    assert parse_latex(S, r"\begin{bmatrix}" + row11 + r"\end{bmatrix}") is None
    # an array whose column count is ten or fewer
    assert (
        parse_latex(S, r"\left[\begin{array}{cccccccccc}" + row10 + r"\end{array}\right]") is None
    )
    # a column count that disagrees with a row
    assert (
        parse_latex(S, r"\left[\begin{array}{cccccccccccc}" + row11 + r"\end{array}\right]") is None
    )
    assert (
        parse_latex(
            S,
            r"\left[\begin{array}{ccccccccccc}" + row11 + r" \\ " + row10 + r"\end{array}\right]",
        )
        is None
    )
    # the closing bracket is required
    assert parse_latex(S, r"\left[\begin{array}{ccccccccccc}" + row11 + r"\end{array}") is None


# ## One annotation-key list


def test_annotation_keys_are_the_schema_list():
    assert ANNOT_KEYS is NODE_ANNOTATION_KEYS
    assert frozenset({"id", "expect_cadence"}) == NODE_ANNOTATION_KEYS


def test_call_form_reads_a_key_the_printer_escapes():
    # the printer writes this node escaped (its key is not an identifier), yet the
    # call form still reads it
    e = j({"op": "custom", "args": ["x"], "a%b": 1})
    assert parse_latex(S, r"\operatorname{custom}(x; \mathrm{a{\char037}b} = 1)") == e


@pytest.mark.parametrize(
    "fields",
    [
        r"\mathrm{args} = [], \mathrm{expr} = x",
        r'\mathrm{op} = \text{"g"}',
        r'\mathrm{op} = \text{"g"}, \mathrm{scheme} = 1',
        r"\mathrm{scheme} = 1, \mathrm{scheme} = 2",
    ],
)
def test_call_form_refuses_repeated_or_reserved_keys(fields):
    assert parse_latex(S, r"\operatorname{custom}(x; " + fields + ")") is None


def test_call_form_refuses_repeated_or_reserved_keys_typst():
    assert parse_typst(S, 'op("custom")(x; upright("op") = #"g")') is None
    assert parse_typst(S, 'op("custom")(x; upright("args") = #(1,))') is None
    assert parse_typst(S, 'op("custom")(x; upright("a") = 1, upright("a") = 2)') is None


def test_call_form_check_prints_nothing(monkeypatch):
    # the native-spelling check reads the node's own fields; printing the operands
    # at every nesting level would make reading nested call forms quadratic
    from earthsci_ast.document.math import printer

    def no_print(*_a, **_k):
        raise AssertionError("the reader printed a node")

    monkeypatch.setattr(printer, "pr", no_print)
    nested = "x"
    for _ in range(50):
        nested = r"\operatorname{custom}(" + nested + r"; \mathrm{a} = 1)"
    e = parse_latex(S, nested)
    assert e is not None and e[2] == ("op", "custom")
    assert parse_latex(S, r"\operatorname{const}(; \mathrm{value} = [1, 2])") is None
    assert (
        parse_latex(S, r"\operatorname{faq}(; \mathrm{expr} = x, \mathrm{output\_idx} = [])")
        is None
    )
    assert (
        parse_latex(
            S,
            r"\operatorname{makearray}(; \mathrm{regions} = [[[1, 2]]], \mathrm{values} = [x])",
        )
        is None
    )
