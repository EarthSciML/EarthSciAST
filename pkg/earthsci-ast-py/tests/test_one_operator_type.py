"""esm 2.4.0 "one operator type" (esm-spec §4.2, §4.8.3, §9.6.1-9.6.3, §9.6.6,
§9.6.12; CONFORMANCE_SPEC §5.61).

Calls of defined operators resolve to definitions and become references, old
spellings are read at the wire boundary, core names are reserved, arity is
checked at load, and unit expressions type a call. The fixtures live under
``tests/conformance/expression_templates/``; the emitted goldens are byte for
byte what the Julia reference writes. Mirrors
``pkg/EarthSciAST.jl/test/one_operator_type_test.jl``.
"""

from __future__ import annotations

import json
import os
import warnings

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import load_path, validate
from earthsci_ast.error_handling import ERROR_CODE_ALIASES, ERROR_CODES, canonical_error_code
from earthsci_ast.lower_expression_templates import (
    Expand,
    emit_document,
    emit_esm_string,
    explain_unresolved_call,
    lower_expression_templates,
)
from earthsci_ast.parse import EsmDeprecationWarning, rewrite_old_spellings
from earthsci_ast.problem import esm_problem
from earthsci_ast.template_imports import resolve_template_machinery

CONF = CONFORMANCE_DIR / "expression_templates"


def _p(*parts: str) -> str:
    return str(CONF.joinpath(*parts))


def _emit(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    return emit_esm_string(emit_document(raw, os.path.dirname(path)))


def _lowered(path: str):
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    resolved = resolve_template_machinery(raw, os.path.dirname(path))
    return lower_expression_templates(raw if resolved is None else resolved)


def _core(d: dict) -> dict:
    return {k: d[k] for k in ("models", "reaction_systems", "coupling", "index_sets") if k in d}


def _code(fn) -> str | None:
    try:
        fn()
    except Exception as e:  # noqa: BLE001 — the code is what is asserted
        return getattr(e, "code", type(e).__name__)
    return None


def _codes_warned(fn) -> list[str]:
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        fn()
    return [
        str(w.message).split(":", 1)[0]
        for w in caught
        if issubclass(w.category, EsmDeprecationWarning)
    ]


EMITTED = [
    ("operator_call_by_name", "fixture.esm", "emitted.esm"),
    ("placeholder_call", "fixture.esm", "emitted.esm"),
    ("partial_wrt_param_instance", "fixture.esm", "emitted.esm"),
    ("old_names", "fixture.esm", "emitted.esm"),
    ("reference_only_round_trip", "fixture.esm", "emitted.esm"),
    ("independent_variable_wrt", "fixture.esm", "emitted.esm"),
    ("vector_calculus_import", "fixture.esm", "emitted.esm"),
]


@pytest.mark.parametrize("case,fixture,golden", EMITTED, ids=[c[0] for c in EMITTED])
def test_emitted_golden_byte_for_byte_and_a_fixed_point(case, fixture, golden, tmp_path):
    out = _emit(_p(case, fixture))
    with open(_p(case, golden), encoding="utf-8") as f:
        assert out == f.read()
    again = tmp_path / "e.esm"
    again.write_text(out, encoding="utf-8")
    assert _emit(str(again)) == out


def test_old_spellings_emit_exactly_as_the_new_ones():
    def strip_meta(text: str) -> dict:
        d = json.loads(text)
        d.pop("metadata", None)
        return d

    assert strip_meta(_emit(_p("old_names", "fixture.esm"))) == strip_meta(
        _emit(_p("old_names", "new_names.esm"))
    )


@pytest.mark.parametrize("case", ["operator_call_by_name", "partial_wrt_param_instance"])
def test_expanded_golden_structurally(case):
    got = _core(Expand(_lowered(_p(case, "fixture.esm"))))
    with open(_p(case, "expanded.esm"), encoding="utf-8") as f:
        want = _core(json.load(f))
    assert got == want


def test_calls_resolve_to_references_by_operator_name():
    """§9.6.3 constraint 2 / §9.6.12: a call of a defined operator becomes a
    reference to the definition selected for it; a placeholder stays a call."""
    loaded = _lowered(_p("operator_call_by_name", "fixture.esm"))
    text = json.dumps(loaded["models"])
    assert '"apply_operator"' in text
    for decl in loaded["models"][next(iter(loaded["models"]))]["operators"].values():
        assert isinstance(decl.get("defines"), str)


@pytest.mark.parametrize(
    "case,fixture,error",
    [
        ("operator_arity_mismatch", "fixture.esm", "error.json"),
        ("operator_defines_core_op", "fixture.esm", "error.json"),
        ("operator_defines_core_op", "explicit_defines.esm", "error_explicit_defines.json"),
    ],
)
def test_load_errors_by_code(case, fixture, error):
    with open(_p(case, error), encoding="utf-8") as f:
        want = json.load(f)["code"]
    assert _code(lambda: load_path(_p(case, fixture))) == want


def test_defines_core_op_names_the_definition_and_the_core_op():
    try:
        load_path(_p("operator_defines_core_op", "fixture.esm"))
    except Exception as e:  # noqa: BLE001
        msg = str(e)
    assert "operators.exp" in msg and "'exp'" in msg


def test_a_compound_rule_rooted_at_a_core_op_is_exempt():
    load_path(_p("operator_defines_core_op", "compound_rule_exempt.esm"))


def test_old_spellings_warn_and_new_spellings_do_not():
    old = _codes_warned(lambda: load_path(_p("old_names", "fixture.esm")))
    assert "deprecated_field" in old
    assert "deprecated_op" in old
    with open(_p("old_names", "warnings.json"), encoding="utf-8") as f:
        assert set(json.load(f)["warnings"]) <= set(old)
    assert _codes_warned(lambda: load_path(_p("old_names", "new_names.esm"))) == []


def test_old_spellings_are_read_once():
    with open(_p("old_names", "fixture.esm"), encoding="utf-8") as f:
        doc = json.load(f)
    fsites, osites = rewrite_old_spellings(doc)
    assert fsites and osites
    assert rewrite_old_spellings(doc) == ([], [])
    assert "operators" in doc["models"]["m"]
    assert doc["models"]["m"]["operators"]["diff_x"]["match"]["op"] == "partial"


def test_both_spellings_in_one_object_is_refused():
    doc = {"models": {"m": {"operators": {}, "expression_templates": {}}}}
    assert _code(lambda: rewrite_old_spellings(doc)) == "operator_invalid_definition"


def test_a_D_whose_wrt_is_a_definition_param_is_decided_per_instance():
    """§4.2 "Reading earlier documents": left as `D` at the wire boundary, read
    as `partial` in each instance that binds the parameter to an axis."""
    doc = {
        "models": {
            "m": {
                "operators": {
                    "d": {
                        "params": ["f", "ax"],
                        "body": {"op": "D", "args": ["f"], "wrt": "ax"},
                    }
                },
                "equations": [{"lhs": "y", "rhs": {"op": "D", "args": ["u"], "wrt": "x"}}],
            }
        }
    }
    rewrite_old_spellings(doc)
    m = doc["models"]["m"]
    assert m["operators"]["d"]["body"]["op"] == "D"
    assert m["equations"][0]["rhs"]["op"] == "partial"


def test_a_placeholder_loads_and_is_refused_only_if_evaluated():
    f = load_path(_p("placeholder_call", "fixture.esm"))
    with pytest.raises(Exception) as exc:
        esm_problem(f, (0.0, 1.0))
    assert getattr(exc.value, "code", None) == "unlowered_operator"
    assert "placeholder" in str(exc.value)


def test_unresolved_call_explanation_lists_definitions_and_reasons():
    registry = {
        "one": {"params": ["a"], "body": "a", "defines": "g"},
        "two": {
            "params": ["a"],
            "where": {"a": {"shape": ["x"]}},
            "body": "a",
            "defines": "g",
        },
    }
    two_args = explain_unresolved_call({"op": "g", "args": ["u", "v"]}, registry)
    assert two_args.startswith("definitions of 'g' in scope: 'one': takes 1 operand(s)")
    assert "'two': takes 1 operand(s), the call carries 2" in two_args
    fields = explain_unresolved_call({"op": "g", "args": ["u"], "wrt": "x"}, registry)
    assert "has no match, so it binds operands only, and the call carries wrt" in fields
    where = explain_unresolved_call({"op": "g", "args": ["u"]}, {"two": registry["two"]})
    assert 'its where constraint a.shape = ["x"] fails' in where
    note = "; definitions no reference reached were removed by emit and flatten and are not listed"
    assert explain_unresolved_call({"op": "h", "args": []}, registry) == (
        "no definition of 'h' is in scope (a placeholder)" + note
    )
    assert two_args.endswith(note)
    refonly = explain_unresolved_call(
        {"op": "g", "args": ["u"]},
        {"g.variant1": {"params": ["a"], "body": "a", "defines": "g", "reference_only": True}},
    )
    assert "'g.variant1': reference-only, reached by explicit references, never by a call" in (
        refonly
    )


def test_unit_expressions_type_a_call():
    with open(_p("definition_units", "expected.json"), encoding="utf-8") as f:
        expected = json.load(f)
    for name in ("fixture.esm", "body_mismatch.esm", "call_unit_from_expression.esm"):
        r = validate(load_path(_p("definition_units", name)))
        errors = sorted({e.code for e in r.structural_errors})
        warned = sorted({w.code for w in r.unit_warnings if w.code == "definition_unit_mismatch"})
        assert errors == sorted(expected[name]["errors"]), name
        assert warned == sorted(expected[name]["warnings"]), name


def test_new_codes_are_registered():
    for code in (
        "operator_arity_mismatch",
        "operator_defines_core_op",
        "definition_unit_mismatch",
        "deprecated_field",
    ):
        assert code in set(ERROR_CODES.values())


def test_old_codes_are_aliases_of_the_new_ones():
    assert canonical_error_code("template_import_cycle") == "operator_import_cycle"
    assert (
        canonical_error_code("apply_expression_template_unknown_template")
        == "operator_unknown_definition"
    )
    assert canonical_error_code("operator_import_cycle") == "operator_import_cycle"
    registered = set(ERROR_CODES.values())
    for old in ERROR_CODE_ALIASES:
        assert old not in registered, f"{old} is reported; only the new code may be"


@pytest.mark.parametrize(
    "rhs,declared,valid",
    [
        ({"op": "partial", "args": ["u"], "wrt": "x"}, "K/m", True),
        ({"op": "partial", "args": ["u", "w"], "wrt": "x"}, "K/m", True),
        ({"op": "partial", "args": ["u"], "wrt": "x"}, "K", False),
        ({"op": "integral", "args": ["u"], "var": "x", "lower": 0, "upper": 1}, "K*m", True),
        ({"op": "integral", "args": ["u"], "var": "x", "lower": 0, "upper": 1}, "K", False),
    ],
)
def test_partial_and_integral_have_fixed_unit_expressions(rhs, declared, valid):
    """esm-spec §4.2 / §4.8.3: `partial(f; wrt: x)` has [f]/[x] and
    `integral(f; var: x)` has [f]·[x], resolved or not; trailing operands of
    `partial` never enter its unit."""
    from earthsci_ast import load_document

    doc = {
        "esm": "2.4.0",
        "metadata": {"name": "fixed_units"},
        "models": {
            "m": {
                "variables": {
                    "u": {"type": "parameter", "units": "K", "default": 1.0},
                    "w": {"type": "parameter", "units": "s", "default": 1.0},
                    "x": {"type": "parameter", "units": "m", "default": 1.0},
                    "y": {"type": "unknown", "units": declared},
                },
                "equations": [{"lhs": "y", "rhs": rhs}],
            }
        },
    }
    r = validate(load_document(doc))
    codes = {e.code for e in r.structural_errors}
    assert ("unit_inconsistency" not in codes) == valid, codes


def test_emitted_rules_are_reference_only_and_reemit_exactly(tmp_path):
    """esm-spec §9.6.1, §9.6.4 rule 5: a materialized rule (and every variant)
    is ``reference_only``, so reloading the emitted document makes it no
    callable definition of its operator, and emit → load → emit is exact."""
    with open(_p("reference_only_round_trip", "emitted.esm"), encoding="utf-8") as f:
        out = f.read()
    reg = json.loads(out)["models"]["m"]["operators"]
    assert reg["fv_div_edges"]["reference_only"] is True
    assert reg["exp"]["reference_only"] is True
    assert "where" not in reg["fv_div_edges"]
    assert '"op": "div"' in out  # div(G) stayed a call
    for case in ("reference_only_round_trip", "constrained_match_scope"):
        once = _emit(_p(case, "fixture.esm"))
        p = tmp_path / f"{case}.esm"
        p.write_text(once, encoding="utf-8")
        twice = _emit(str(p))
        assert twice == once
        p.write_text(twice, encoding="utf-8")
        assert _emit(str(p)) == once


def test_reference_only_definitions_are_not_called_and_not_checked():
    """A ``reference_only`` match-less entry is never a call rule, adds no arity
    and is exempt from the core-name reservation (esm-spec §9.6.1)."""
    doc = {
        "esm": "2.4.0",
        "metadata": {"name": "refonly"},
        "models": {
            "m": {
                "variables": {
                    "x": {"type": "parameter", "default": 1.0},
                    "y": {"type": "unknown"},
                },
                "equations": [{"lhs": "y", "rhs": {"op": "g", "args": ["x", "x"]}}],
                "operators": {
                    "g": {"params": ["a"], "body": "a", "reference_only": True},
                    "exp": {"params": ["a"], "body": "a", "reference_only": True},
                },
            }
        },
    }
    out = lower_expression_templates(doc)
    assert out["models"]["m"]["equations"][0]["rhs"]["op"] == "g"


def test_wrt_naming_the_independent_variable_is_time():
    """esm-spec §4.2 "The derivative axis": a ``D`` whose ``wrt`` names the
    document's renamed independent variable reads as ``wrt: "t"``, silently;
    any other axis is ``partial``."""
    doc = {
        "domain": {"independent_variable": "tau"},
        "models": {
            "m": {
                "equations": [
                    {"lhs": {"op": "D", "args": ["u"], "wrt": "tau"}, "rhs": 1},
                    {"lhs": "y", "rhs": {"op": "D", "args": ["u"], "wrt": "x"}},
                ]
            }
        },
    }
    fsites, osites = rewrite_old_spellings(doc)
    eqs = doc["models"]["m"]["equations"]
    assert eqs[0]["lhs"] == {"op": "D", "args": ["u"], "wrt": "t"}
    assert eqs[1]["rhs"]["op"] == "partial"
    assert osites == ["/models/m/equations/1/rhs (D)"]


def test_empty_operator_library_imports_as_a_no_op():
    load_path(_p("vector_calculus_import", "fixture.esm"))


def test_pushdown_resolves_an_old_spelled_import_edge(monkeypatch):
    """With ``pushdown_rewrite=True`` the raw document is read in the esm-2.4.0
    spellings before the import-edge test (esm-spec §9.6.12), so a component
    that wrote ``expression_template_imports`` still has its imports resolved
    before the recogniser looks."""
    import earthsci_ast.problem as problem

    class Resolved(Exception):
        pass

    def _resolve(raw, *_a, **_k):
        assert raw["models"]["m"]["operator_imports"] == [{"ref": "./lib.esm"}]
        raise Resolved

    monkeypatch.setattr(problem, "resolve_template_machinery", _resolve)
    doc = {
        "esm": "2.3.0",
        "metadata": {"name": "old_import_edge"},
        "models": {
            "m": {
                "variables": {"x": {"type": "unknown", "units": "1", "default": 1.0}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                        "rhs": {"op": "-", "args": ["x"]},
                    }
                ],
                "expression_template_imports": [{"ref": "./lib.esm"}],
            }
        },
    }
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with pytest.raises(Resolved):
            esm_problem(doc, (0.0, 1.0), pushdown_rewrite=True)


def test_a_reference_to_a_leaf_bodied_definition_is_typed_by_its_unit_expression():
    """A reference whose definition's body is a single leaf still carries the
    definition's unit record (esm-spec §9.6.12 "Units"): the body ``q`` (unit
    m) disagrees with the unit expression ``q / (1 s)``, which is
    ``definition_unit_mismatch``, not a plain inconsistency at the equation."""
    with open(_p("definition_units", "body_mismatch.esm"), encoding="utf-8") as f:
        raw = json.load(f)
    m = raw["models"]["m"]
    m["operators"]["bad"]["body"] = "q"
    m["equations"][0]["rhs"] = {
        "op": "apply_operator",
        "args": [],
        "name": "bad",
        "bindings": {"q": "x"},
    }
    from earthsci_ast import load_string
    from earthsci_ast.serialize import to_json

    loaded = load_string(json.dumps(raw))
    codes = [e.code for e in validate(loaded).structural_errors]
    assert codes == ["definition_unit_mismatch"]
    # The holder that carries the record is not written back.
    assert json.loads(to_json(loaded))["models"]["m"]["equations"][0]["rhs"] == "x"


def _mount_docs(tmp_path, host_rhs):
    leaf = {
        "esm": "2.4.0",
        "metadata": {"name": "leaf"},
        "models": {
            "Leaf": {
                "operators": {
                    "scale": {"params": ["x"], "body": {"op": "*", "args": [3, "x"]}},
                },
                "variables": {"c": {"type": "unknown", "units": "1", "default": 1.0}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                        "rhs": {"op": "scale", "args": ["c"]},
                    }
                ],
            }
        },
    }
    host = {
        "esm": "2.4.0",
        "metadata": {"name": "host"},
        "models": {
            "Host": {
                "variables": {"y": {"type": "unknown", "units": "1", "default": 1.0}},
                "equations": [{"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": host_rhs}],
                "subsystems": {"Sub": {"ref": "./leaf.esm"}},
            }
        },
    }
    (tmp_path / "leaf.esm").write_text(json.dumps(leaf))
    (tmp_path / "host.esm").write_text(json.dumps(host))
    return str(tmp_path / "host.esm")


def test_a_mounted_leafs_definitions_resolve_only_the_leafs_calls(tmp_path):
    """Definitions are component-local (esm-spec §9.6.3 constraint 4): a leaf's
    definitions join the host's registry for the leaf's own references, but a
    host call of the same operator does not resolve to them, and they count for
    no arity in the host (§9.6.12)."""
    f = load_path(_mount_docs(tmp_path, {"op": "scale", "args": ["y"]}))
    host_rhs = f.models["Host"].equations[0].rhs
    assert host_rhs.op == "scale" and host_rhs.args == ["y"]
    # The leaf's own call still resolves to its definition: dc/dt = 3c.
    leaf_rhs = f.models["Host"].subsystems["Sub"].equations[0].rhs
    assert leaf_rhs.op == "*" and leaf_rhs.args == [3, "c"]
    # A host call with an operand count the leaf's definition does not take is
    # a placeholder, not operator_arity_mismatch.
    g = load_path(_mount_docs(tmp_path, {"op": "scale", "args": ["y", "y"]}))
    assert g.models["Host"].equations[0].rhs.op == "scale"


def test_an_inline_subsystems_calls_resolve_to_its_own_definitions():
    """An authored subsystem's definitions resolve the calls in its own subtree
    (esm-spec §9.6.3 constraint 4), and only there: the host's call of the same
    operator stays a placeholder. The host has no definitions: a block on a
    subsystem alone, at any depth, is enough for the document to be lowered."""
    raw = {
        "esm": "2.4.0",
        "metadata": {"name": "inline_scope"},
        "models": {
            "Host": {
                "variables": {"y": {"type": "unknown", "units": "1", "default": 1.0}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                        "rhs": {"op": "scale", "args": ["y"]},
                    }
                ],
                "subsystems": {
                    "Sub": {
                        "operators": {
                            "scale": {"params": ["x"], "body": {"op": "*", "args": [3, "x"]}}
                        },
                        "variables": {"c": {"type": "unknown", "units": "1", "default": 1.0}},
                        "equations": [
                            {
                                "lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                                "rhs": {"op": "scale", "args": ["c"]},
                            }
                        ],
                    }
                },
            }
        },
    }
    host = lower_expression_templates(raw)["models"]["Host"]
    assert host["equations"][0]["rhs"] == {"op": "scale", "args": ["y"]}
    assert host["subsystems"]["Sub"]["equations"][0]["rhs"] == {
        "op": "apply_operator",
        "args": [],
        "name": "scale",
        "bindings": {"x": "c"},
    }


def test_a_block_on_a_nested_inline_subsystem_is_lowered():
    """The only ``operators`` block sits two subsystems down: the document is
    still lowered, and that subsystem's call resolves to its definition."""
    inner = {
        "operators": {"scale": {"params": ["x"], "body": {"op": "*", "args": [3, "x"]}}},
        "variables": {"c": {"type": "unknown", "units": "1", "default": 1.0}},
        "equations": [
            {
                "lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                "rhs": {"op": "scale", "args": ["c"]},
            }
        ],
    }
    raw = {
        "esm": "2.4.0",
        "metadata": {"name": "nested_inline_scope"},
        "models": {
            "Host": {
                "variables": {"y": {"type": "unknown", "units": "1", "default": 1.0}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                        "rhs": {"op": "-", "args": ["y"]},
                    }
                ],
                "subsystems": {
                    "Mid": {
                        "variables": {"m": {"type": "unknown", "units": "1", "default": 1.0}},
                        "equations": [
                            {
                                "lhs": {"op": "D", "args": ["m"], "wrt": "t"},
                                "rhs": {"op": "-", "args": ["m"]},
                            }
                        ],
                        "subsystems": {"Inner": inner},
                    }
                },
            }
        },
    }
    host = lower_expression_templates(raw)["models"]["Host"]
    rhs = host["subsystems"]["Mid"]["subsystems"]["Inner"]["equations"][0]["rhs"]
    assert rhs == {"op": "apply_operator", "args": [], "name": "scale", "bindings": {"x": "c"}}
    # And through the typed load, the call expands to the definition's body.
    from earthsci_ast import load_string

    f = load_string(json.dumps(raw))
    leaf = f.models["Host"].subsystems["Mid"].subsystems["Inner"].equations[0].rhs
    assert leaf.op == "*" and leaf.args == [3, "c"]


def test_a_fired_partial_rule_is_held_to_partials_fixed_unit():
    """A ``partial`` rule that fires loses its ``match`` when rule 3
    materializes it, but the call it wrote is still typed by ``partial``'s
    fixed unit expression (esm-spec §4.2, §9.6.12 "Units"): ``partial(u, wrt:
    x)`` has unit kg/m, so the equation checks, and the body ``f*k`` (unit kg)
    is ``definition_unit_mismatch``. The emitted registry carries no private
    key."""
    raw = {
        "esm": "2.4.0",
        "metadata": {"name": "partial_fixed_unit"},
        "models": {
            "m": {
                "variables": {
                    "u": {"type": "parameter", "units": "kg", "default": 1.0},
                    "x": {"type": "parameter", "units": "m", "default": 1.0},
                    "k": {"type": "parameter", "units": "1", "default": 2.0},
                    "y": {"type": "unknown", "units": "kg/m"},
                },
                "equations": [{"lhs": "y", "rhs": {"op": "partial", "args": ["u"], "wrt": "x"}}],
                "operators": {
                    "d_rule": {
                        "params": ["f", "d"],
                        "match": {"op": "partial", "args": ["f"], "wrt": "d"},
                        "body": {"op": "*", "args": ["f", "k"]},
                    }
                },
            }
        },
    }
    from earthsci_ast import load_string

    r = validate(load_string(json.dumps(raw)))
    assert [e.code for e in r.structural_errors] == ["definition_unit_mismatch"]
    assert "fixed unit expression of 'partial'" in r.structural_errors[0].message
    emitted = emit_esm_string(emit_document(raw, "."))
    assert "__esm_" not in emitted


def test_a_library_with_an_empty_operators_block_is_valid_and_round_trips():
    """An operator-library file's ``operators`` MAY be empty (esm 2.4.0):
    lib/vector_calculus.esm only documents operator names. It is a library,
    not an empty document, and re-emitting it keeps the block."""
    from earthsci_ast import to_json

    path = os.path.join(os.path.dirname(__file__), "..", "..", "..", "lib", "vector_calculus.esm")
    assert validate(load_path(path)).is_valid
    assert json.loads(to_json(load_path(path)))["operators"] == {}
