"""Tests for esm-spec §9.7 — template-library files,
``expression_template_imports``, and load-time ``metaparameters``
(docs/content/rfcs/template-library-imports.md; esm-libraries-spec §2.1c).

Drives the shared conformance fixtures under
``tests/conformance/expression_templates/`` and the resolver-level invalid
fixtures under ``tests/invalid/template_imports/``, mirroring the Julia
reference testset ``EarthSciAST.jl/test/template_imports_test.jl``.
"""

from __future__ import annotations

import copy
import json
import os

import conftest
import pytest

from earthsci_ast.lower_expression_templates import (
    ExpressionTemplateError,
    emit_document,
    expand_document,
    lower_expression_templates,
)
from earthsci_ast.parse import SchemaValidationError, load
from earthsci_ast.serialize import _serialize_esm_file, emit_esm_string, save
from earthsci_ast.template_imports import (
    MAX_TEMPLATE_EXPANSION_DEPTH,
    _substitute_metaparams,
    reject_template_imports_pre_v08,
    resolve_template_machinery,
)

CONF = str(conftest.CONFORMANCE_DIR / "expression_templates")
INVALID_DIR = str(conftest.INVALID_DIR / "template_imports")
VALID_DIR = str(conftest.VALID_DIR)


def _defining(doc: dict, model: str, var: str):
    """The RHS of the bare-variable-LHS equation defining ``var``, raw-dict form.

    esm 1.0.0 removed the variable ``expression`` field: an observed unknown is
    defined by an EQUATION, so a template call site that used to sit on
    ``variables[v]["expression"]`` now sits on that equation's ``rhs``.
    """
    eqs = [e for e in doc["models"][model]["equations"] if e.get("lhs") == var]
    assert len(eqs) == 1, f"expected exactly one defining equation for {var!r}"
    return eqs[0]["rhs"]


def _defining_typed(model, var: str):
    """The RHS of the equation defining ``var`` on a parsed ``Model``."""
    eqs = [e for e in model.equations if e.lhs == var]
    assert len(eqs) == 1, f"expected exactly one defining equation for {var!r}"
    return eqs[0].rhs


def _canonical_equation_order(node):
    """Sort every ``equations`` list in a document, recursively.

    From esm 1.0.0 an observed unknown's defining expression is an EQUATION, so
    a document's equation list gained one entry per observed variable — and
    which equation defines what is a property of the equation SET, not of
    traversal order. The resolver appends its folded definitions in its own
    order while the Julia-generated golden lists them in the author's, so the
    comparison is canonicalized here rather than pinned to one traversal.
    """
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            v = _canonical_equation_order(v)
            if k == "equations" and isinstance(v, list):
                v = sorted(v, key=lambda e: json.dumps(e, sort_keys=True))
            out[k] = v
        return out
    if isinstance(node, list):
        return [_canonical_equation_order(v) for v in node]
    return node


def _read_json(path: str) -> dict:
    with open(path) as fh:
        return json.load(fh)


def _expand_raw(path: str) -> dict:
    """The raw §9.7 pipeline (resolve → lower → Expand), mirroring the Julia
    golden generator. Under Option B (esm-spec §9.6.4) ``lower`` preserves
    references + registries; ``expand_document`` produces the Option-A image the
    ``expanded*.esm`` goldens pin (RFC out-of-line-expression-templates §12
    gate 1)."""
    raw = _read_json(path)
    resolved = resolve_template_machinery(raw, os.path.dirname(path))
    return expand_document(lower_expression_templates(resolved if resolved is not None else raw))


def _err_code(fn) -> str | None:
    try:
        fn()
        return None
    except ExpressionTemplateError as e:
        return e.code


# ---------------------------------------------------------------------------
# Conformance fixture groups vs the committed Julia goldens
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "group,fixture,golden",
    [
        ("import_smoke", "fixture.esm", "expanded.esm"),
        ("import_diamond", "fixture.esm", "expanded.esm"),
        ("import_order_determinism", "fixture_import_order.esm", "expanded_import_order.esm"),
        (
            "import_order_determinism",
            "fixture_priority_override.esm",
            "expanded_priority_override.esm",
        ),
        # §5.5.3.1 rule 1: integer ratio {op:/,args:[1,N]} inside a nested
        # aggregate expr stays integer on the AST-golden pathway.
        ("aggregate_int_ratio_golden", "fixture.esm", "expanded.esm"),
        # §9.7.7 import renaming / namespacing / free-name rebinding
        ("import_rename_two_instances", "fixture.esm", "expanded.esm"),
        ("import_where_rename_two_instances", "fixture.esm", "expanded.esm"),
        ("import_rebind_keyed_factors", "fixture.esm", "expanded.esm"),
        ("import_rename_diamond", "fixture.esm", "expanded.esm"),
    ],
)
def test_import_conformance_matches_golden(group, fixture, golden):
    """The raw pipeline (resolve → lower) must match the Julia-generated
    golden structurally, for the whole document."""
    got = _canonical_equation_order(_expand_raw(os.path.join(CONF, group, fixture)))
    want = _canonical_equation_order(_read_json(os.path.join(CONF, group, golden)))
    assert got == want


def test_import_smoke_typed_load():
    """§9.7.7 four-file layering: index sets merged and folded at the edge
    bindings; D(c, wrt: lon) lowered to the makearray rule body."""
    f = load(os.path.join(CONF, "import_smoke", "fixture.esm"))
    assert f.index_sets["lon"]["size"] == 288
    assert f.index_sets["lat"]["size"] == 181
    eq = f.models["Advection"].equations[0]
    assert eq.lhs.op == "D"
    assert eq.rhs.args[1].op == "makearray"


def test_import_diamond_dedups_at_first_occurrence():
    f = load(os.path.join(CONF, "import_diamond", "fixture.esm"))
    assert f.index_sets["cells"]["size"] == 10  # NC default, deduped once


def test_effective_order_pins_tie_break_and_priority_flips_it():
    """Winner sanity, independent of the goldens: earlier import wins the
    equal-priority tie (2*x); explicit priority 10 out-ranks it (5*x)."""
    d1 = _expand_raw(os.path.join(CONF, "import_order_determinism", "fixture_import_order.esm"))
    assert _defining(d1, "M", "y")["args"][0] == 2
    d2 = _expand_raw(
        os.path.join(CONF, "import_order_determinism", "fixture_priority_override.esm")
    )
    assert _defining(d2, "M", "y")["args"][0] == 5


# ---------------------------------------------------------------------------
# Valid suite: library file + minimal consumer
# ---------------------------------------------------------------------------


def test_valid_suite_library_file_loads_clean():
    """A model-less template-library document loads (esm-spec §9.7.1) and its
    top-level DECLARATIONS SURVIVE.

    This test used to assert the opposite — that round-trip "strips every §9.7
    construct, leaving the folded registry" — which enshrined the bug as the
    contract. §9.6.4 rule 5: Option A expands `apply_expression_template` CALL
    SITES; it does not delete DECLARATIONS. The registry and `metaparameters` are
    peers of `index_sets` and survive `parse -> emit` verbatim; a library file
    MUST round-trip to itself. Dropping them emitted `{esm, metadata,
    index_sets}` — none of the five top-level payload keys — which the schema's
    top-level `anyOf` rejects, so a conforming library was unrepresentable.
    """
    lib = load(os.path.join(VALID_DIR, "template_import_lib.esm"))
    assert not lib.models
    assert lib.expression_templates, "the template registry is a declaration; it survives"
    assert lib.metaparameters, "the metaparameter block is a declaration; it survives"
    # A library is GENERIC: `N` is bound per import edge, so an unbound load must
    # NOT fold `size: "N"` to the default. Folding it here would hard-wire the
    # library to 8 and destroy the genericity that makes it a library.
    assert lib.index_sets["cells"]["size"] == "N"

    # But a loader-API binding (§9.7.6 site 4) is a request to INSTANTIATE the
    # library at a size, so there the fold is exactly what was asked for.
    lib12 = load(os.path.join(VALID_DIR, "template_import_lib.esm"), metaparameters={"N": 12})
    assert lib12.index_sets["cells"]["size"] == 12


def test_valid_suite_minimal_consumer():
    m = load(os.path.join(VALID_DIR, "template_import_minimal.esm"))
    assert m.index_sets["cells"]["size"] == 8  # §9.7.5 merge into consumer
    y = _defining_typed(m.models["M"], "y")
    assert y.op == "*"
    assert y.args == ["x", 8]


# ---------------------------------------------------------------------------
# metaparameter_resolutions: subsystem-ref bindings (§9.7.6 site 3)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "wrapper,golden,n",
    [("wrapper_n4.esm", "expanded_n4.esm", 4), ("wrapper_n8.esm", "expanded_n8.esm", 8)],
)
def test_metaparameter_resolutions_subsystem_bindings(wrapper, golden, n):
    f = load(os.path.join(CONF, "metaparameter_resolutions", wrapper))
    sub = f.models["Sweep"].subsystems["Problem"]
    # Expression position: bare "N" substituted as an integer literal.
    assert _defining_typed(sub, "npts") == n
    # Expression-position division stays an AST division (no folding).
    half = _defining_typed(sub, "half")
    assert half.op == "/"
    assert half.args == [n, 2]
    # Structural site: the aggregate dense range folded exactly.
    ramp = _defining_typed(sub, "ramp")
    assert ramp.op == "aggregate"
    assert ramp.ranges == {"i": [1, n // 2]}
    # Typed round-trip matches the golden, fully structurally.
    got = _canonical_equation_order(_serialize_esm_file(f))
    want = _canonical_equation_order(
        _read_json(os.path.join(CONF, "metaparameter_resolutions", golden))
    )
    assert got == want


def test_loader_api_bindings_and_defaults():
    """§9.7.6 binding sites 4 (loader API) and 5 (defaults, last)."""
    problem = os.path.join(CONF, "metaparameter_resolutions", "problem.esm")
    fdef = load(problem)
    assert _defining_typed(fdef.models["Problem"], "npts") == 2  # default
    fapi = load(problem, metaparameters={"N": 6})
    assert _defining_typed(fapi.models["Problem"], "npts") == 6  # API > default
    assert _defining_typed(fapi.models["Problem"], "ramp").ranges == {"i": [1, 3]}
    # Binding a name the document does not declare is an error.
    assert (
        _err_code(lambda: load(problem, metaparameters={"Q": 1})) == "template_import_unknown_name"
    )


def test_round_trip_emits_expanded_folded_form():
    """A CONSUMER file round-trips to its expanded, folded form (§9.7.6).

    ``expression_template_imports`` IS an import edge and is consumed, along with
    the ``apply_expression_template`` call sites it lowers. This fixture declares
    NO top-level ``expression_templates`` registry and NO top-level
    ``metaparameters`` block, so there is no DECLARATION here to preserve —
    contrast ``test_template_library_round_trips_to_itself``. NLON / NLAT are
    declared by the IMPORTED grid and closed at the edge, so they fold away.
    """
    f = load(os.path.join(CONF, "import_smoke", "fixture.esm"))
    text = save(f)
    assert "expression_template_imports" not in text
    assert "metaparameters" not in text
    assert "expression_templates" not in text
    assert "apply_expression_template" not in text
    reloaded = load(text)
    assert reloaded.index_sets["lon"]["size"] == 288
    assert reloaded.models["Advection"].equations[0].rhs.args[1].op == "makearray"


@pytest.mark.parametrize("lib", ["template_import_lib.esm", "template_import_rename_lib.esm"])
def test_template_library_round_trips_to_itself(lib):
    """A TEMPLATE-LIBRARY file MUST round-trip to ITSELF (§9.6.4 rule 5, §9.7.6).

    The top-level ``expression_templates`` registry and ``metaparameters`` block
    are DECLARATIONS — peers of ``index_sets``, not ``apply_expression_template``
    call sites. Option A expands call sites; it does NOT delete declarations.
    Both survive ``parse -> emit`` VERBATIM.

    ``resolve_template_machinery`` deleted both, so a pure library file emitted
    as ``{esm, metadata, index_sets}`` — NONE of the five top-level payload keys,
    which the schema's top-level ``anyOf`` rejects. A conforming library was
    legal on disk and illegal the instant it was loaded and re-emitted.

    VERBATIM is asserted, not merely "present": the close/fold/compose phases
    mutate the working registry in place (``size: "N"`` -> ``size: 8``), so
    preserving the WORKING copy would emit the folded form and the library would
    still not round-trip to ITSELF. Mirrors the Rust
    ``template_library_round_trips_to_itself`` and the TypeScript
    ``§9.6.4 rule 5: a template library round-trips to itself``.
    """
    path = os.path.join(VALID_DIR, lib)
    on_disk = _read_json(path)
    assert on_disk.get("expression_templates"), f"{lib} must author the registry to pin anything"
    assert on_disk.get("metaparameters"), f"{lib} must author metaparameters to pin anything"

    # The resolver's own output — the tree every downstream pass and the emit
    # surface see.
    resolved = resolve_template_machinery(on_disk, os.path.dirname(path))
    assert resolved is not None
    assert resolved["expression_templates"] == on_disk["expression_templates"]
    assert resolved["metaparameters"] == on_disk["metaparameters"]
    # The import EDGE, by contrast, is consumed.
    assert "expression_template_imports" not in resolved

    # The reference-preserving EMIT surface (the cross-binding byte-identity
    # surface): the emitted document keeps both declarations and is itself a
    # legal, loadable document — the property that was actually broken.
    emitted = emit_document(_read_json(path), os.path.dirname(path))
    assert emitted["expression_templates"] == on_disk["expression_templates"]
    assert emitted["metaparameters"] == on_disk["metaparameters"]
    assert any(
        k in emitted
        for k in ("models", "reaction_systems", "data_sources", "operators", "expression_templates")
    ), f"{lib}: emitted form carries none of the five top-level payload keys"
    load(emit_esm_string(emitted), base_path=os.path.dirname(path))

    # ...and the typed load -> save surface.
    typed = json.loads(save(load(path)))
    assert typed["expression_templates"] == on_disk["expression_templates"]
    assert typed["metaparameters"] == on_disk["metaparameters"]


def test_edge_consumed_metaparameter_still_folds_away():
    """The declarations survive, but a metaparameter CONSUMED AT AN IMPORT EDGE
    is still closed and folded away (§9.7.6 binding site 1).

    The imported grid declares NLON / NLAT, the edge binds them, and neither the
    name nor a ``metaparameters`` block may leak into the importing document's
    resolved or emitted scope. The negative half of
    ``test_template_library_round_trips_to_itself``: restoring the authored
    SNAPSHOT must not become "re-export everything the resolver saw".
    """
    path = os.path.join(CONF, "import_smoke", "fixture.esm")
    resolved = resolve_template_machinery(_read_json(path), os.path.dirname(path))
    assert resolved is not None
    assert "metaparameters" not in resolved
    assert resolved["index_sets"]["lon"]["size"] == 288
    assert resolved["index_sets"]["lat"]["size"] == 181

    text = emit_esm_string(emit_document(_read_json(path), os.path.dirname(path)))
    assert "metaparameters" not in text
    assert "NLON" not in text
    assert "NLAT" not in text


def test_import_where_rename_carries_where_shape():
    """§9.7.7: importing a `where`-constrained rule twice under prefix rewrites
    each instance's ``where.F.shape`` from x to meshA.x / meshB.x in lockstep
    with the index set, so each rule registers and fires ONLY on its own field.
    Without the rewrite this raised template_constraint_unknown_index_set."""
    d = _expand_raw(os.path.join(CONF, "import_where_rename_two_instances", "fixture.esm"))
    va = _defining(d, "TwoGrids", "div_A")
    vb = _defining(d, "TwoGrids", "div_B")
    assert va["op"] == "*" and vb["op"] == "*"  # both div nodes lowered
    assert va["args"][0]["op"] == "/" and va["args"][0]["args"][1] == 16
    assert vb["args"][0]["op"] == "/" and vb["args"][0]["args"][1] == 8
    assert va["args"][1] == "F_A" and vb["args"][1] == "F_B"
    f = load(os.path.join(CONF, "import_where_rename_two_instances", "fixture.esm"))
    assert f.index_sets["meshA.x"]["size"] == 16
    assert f.index_sets["meshB.x"]["size"] == 8


def test_import_where_rename_unknown_index_set_rejected():
    """A `where` shape naming a set the library never declares survives the
    rename as spelled and is rejected at rule registration (esm-spec §9.6.6)."""
    assert (
        _err_code(
            lambda: load(os.path.join(CONF, "import_where_rename_unknown_index_set", "fixture.esm"))
        )
        == "template_constraint_unknown_index_set"
    )


# ---------------------------------------------------------------------------
# Invalid fixtures: every §9.7 diagnostic code, machine-checked
# ---------------------------------------------------------------------------


def _invalid_fixture_names():
    return sorted(f for f in os.listdir(INVALID_DIR) if f.endswith(".esm"))


# ---------------------------------------------------------------------------
# Invalid fixtures in the SHARED corpus whose declared defect the esm 1.0.0
# conversion erased. The corpus is owned by a different work-stream, so this
# package cannot repair them; each is NAMED (never glob-matched) and carries the
# exact defect and its repair, so the list cannot silently absorb an unrelated
# regression. Delete an entry the moment its fixture is repaired upstream.
#
# Currently empty: `import_version_too_old.esm` was the sole entry, and it has
# been resolved upstream by RETIRING the diagnostic rather than restoring the
# fixture -- see `test_invalid_fixture_set_covers_the_reachable_code_table`.
# ---------------------------------------------------------------------------
_CORPUS_DEFECTS: dict[str, str] = {}


@pytest.mark.parametrize("fname", _invalid_fixture_names())
def test_invalid_template_import_fixture(fname):
    if fname in _CORPUS_DEFECTS:
        pytest.xfail(f"{fname}: {_CORPUS_DEFECTS[fname]}")
    expected = _read_json(str(conftest.INVALID_DIR / "expected_errors.json"))
    entry = expected[fname]
    assert entry["resolver_only"] is True
    want = entry["resolver_error_code"]
    with pytest.raises(ExpressionTemplateError) as excinfo:
        load(os.path.join(INVALID_DIR, fname))
    assert excinfo.value.code == want


def test_invalid_fixture_set_covers_the_reachable_code_table():
    """The fixture set exercises every REACHABLE §9.6.6 / §9.7 code.

    Two codes are deliberately absent. `template_import_unresolved` is exercised
    by the unit tests below — a missing file is not representable as a fixture.
    `template_import_version_too_old` is RETIRED as unreachable: it gated files
    declaring an esm version older than `expression_template_imports`, and from
    1.0.0 such a file is rejected by the major-version gate in `load` long before
    the template resolver sees it, so no document can reach the code. Its fixture
    was deleted upstream. The gate FUNCTION is still covered directly, below, as
    defence in depth.
    """
    expected = _read_json(str(conftest.INVALID_DIR / "expected_errors.json"))
    seen = {expected[f]["resolver_error_code"] for f in _invalid_fixture_names()}
    for code in [
        "template_import_not_library",
        "subsystem_ref_is_template_library",
        "template_import_cycle",
        "template_import_name_conflict",
        "template_import_unknown_name",
        "template_import_index_set_conflict",
        "apply_expression_template_recursive_body",
        "template_body_expansion_too_deep",
        "metaparameter_unbound",
        "metaparameter_type_error",
        "metaparameter_name_conflict",
        # §9.7.7 import renaming / namespacing / free-name rebinding
        "template_import_rename_unknown_name",
        "template_import_rebind_unknown_name",
        "template_import_rename_collision",
        "template_import_rename_invalid",
    ]:
        assert code in seen


# ---------------------------------------------------------------------------
# Unit-level behavior over generated files
# ---------------------------------------------------------------------------


def _model_json(extra_model_fields: str = "", top_fields: str = "") -> str:
    return f"""
    {{
      "esm": "1.0.0",
      "metadata": {{"name": "t"}},{top_fields}
      "models": {{
        "M": {{{extra_model_fields}
          "variables": {{"x": {{"type": "unknown", "units": "1", "default": 0.5}}}},
          "equations": [{{"lhs": {{"op": "D", "args": ["x"], "wrt": "t"}},
                         "rhs": {{"op": "-", "args": ["x"]}}}}]
        }}
      }}
    }}
    """


def test_template_import_unresolved_missing_and_unparsable_ref(tmp_path):
    p = tmp_path / "m.esm"
    p.write_text(_model_json('\n"expression_template_imports": [{"ref": "./nope.esm"}],'))
    assert _err_code(lambda: load(str(p))) == "template_import_unresolved"
    (tmp_path / "junk.esm").write_text("{not json")
    p.write_text(_model_json('\n"expression_template_imports": [{"ref": "./junk.esm"}],'))
    assert _err_code(lambda: load(str(p))) == "template_import_unresolved"


def test_only_filters_visibility_not_internal_wiring(tmp_path):
    (tmp_path / "lib.esm").write_text(
        json.dumps(
            {
                "esm": "1.0.0",
                "metadata": {"name": "lib"},
                "expression_templates": {
                    "t_inner": {"params": [], "body": 7},
                    "t_keep": {
                        "params": [],
                        "body": {
                            "op": "*",
                            "args": [
                                2,
                                {
                                    "op": "apply_expression_template",
                                    "args": [],
                                    "name": "t_inner",
                                    "bindings": {},
                                },
                            ],
                        },
                    },
                    "t_drop": {"params": [], "body": 9},
                },
            }
        )
    )
    # esm-spec §9.6.4 Option B: t_keep's body reference to t_inner resolved in
    # the LIBRARY's own scope. Bodies are no longer inlined (§9.7.3), so
    # importing `only: [t_keep]` carries the internal-wiring reference-closure
    # (t_inner) along and the reference SURVIVES; Expand yields 2 * 7 (the
    # Option-A image, §9.6.4 rule 2).
    p = tmp_path / "m.esm"
    p.write_text(
        _model_json('\n"expression_template_imports": [{"ref": "./lib.esm", "only": ["t_keep"]}],')
    )
    raw = json.loads(p.read_text())
    resolved = resolve_template_machinery(raw, str(tmp_path))
    tpl = resolved["models"]["M"]["expression_templates"]
    # t_keep kept explicitly; t_inner carried by the reference closure;
    # t_drop (unreferenced, filtered) is gone.
    assert set(tpl.keys()) == {"t_keep", "t_inner"}
    assert tpl["t_keep"]["body"] == {
        "op": "*",
        "args": [
            2,
            {"op": "apply_expression_template", "args": [], "name": "t_inner", "bindings": {}},
        ],
    }
    assert tpl["t_inner"]["body"] == 7
    # The surviving reference expands to the inlined value (2 * 7).
    from earthsci_ast.lower_expression_templates import _expand_all

    assert _expand_all(tpl["t_keep"]["body"], tpl, "only-closure") == {"op": "*", "args": [2, 7]}
    # Referencing a filtered-out name from an expression position fails.
    p2 = tmp_path / "m2.esm"
    p2.write_text(
        _model_json(
            '\n"expression_template_imports": [{"ref": "./lib.esm", "only": ["t_keep"]}],\n'
            '"expression_templates": {"local_uses_drop": {"params": [],\n'
            '  "body": {"op": "apply_expression_template", "args": [], '
            '"name": "t_drop", "bindings": {}}}},'
        )
    )
    assert _err_code(lambda: load(str(p2))) == "apply_expression_template_unknown_template"


def test_diamond_with_conflicting_edge_bindings_rejected(tmp_path):
    (tmp_path / "grid.esm").write_text(
        json.dumps(
            {
                "esm": "1.0.0",
                "metadata": {"name": "grid"},
                "metaparameters": {"NC": {"type": "integer"}},
                "index_sets": {"cells": {"kind": "interval", "size": "NC"}},
                "expression_templates": {"nc": {"params": [], "body": "NC"}},
            }
        )
    )
    p = tmp_path / "m.esm"
    p.write_text(
        _model_json(
            '\n"expression_template_imports": ['
            '{"ref": "./grid.esm", "bindings": {"NC": 4}},'
            '{"ref": "./grid.esm", "bindings": {"NC": 8}}],'
        )
    )
    assert _err_code(lambda: load(str(p))) in (
        "template_import_name_conflict",
        "template_import_index_set_conflict",
    )
    # Equal instantiation on both edges dedups cleanly.
    p.write_text(
        _model_json(
            '\n"expression_template_imports": ['
            '{"ref": "./grid.esm", "bindings": {"NC": 4}},'
            '{"ref": "./grid.esm", "bindings": {"NC": 4}}],'
        )
    )
    f = load(str(p))
    assert f.index_sets["cells"]["size"] == 4


def test_edge_bindings_unknown_names_and_non_integers(tmp_path):
    (tmp_path / "lib.esm").write_text(
        json.dumps(
            {
                "esm": "1.0.0",
                "metadata": {"name": "lib"},
                "metaparameters": {"N": {"type": "integer", "default": 8}},
                "expression_templates": {"n": {"params": [], "body": "N"}},
            }
        )
    )
    p = tmp_path / "m.esm"
    p.write_text(
        _model_json(
            '\n"expression_template_imports": [{"ref": "./lib.esm", "bindings": {"Q": 1}}],'
        )
    )
    assert _err_code(lambda: load(str(p))) == "template_import_unknown_name"
    # A non-integer binding is schema-invalid (TemplateImport.bindings is
    # integer-typed), so `load` rejects at schema validation; the
    # resolver-level backstop still reports metaparameter_type_error.
    p.write_text(
        _model_json(
            '\n"expression_template_imports": [{"ref": "./lib.esm", "bindings": {"N": 2.5}}],'
        )
    )
    with pytest.raises(SchemaValidationError):
        load(str(p))
    raw = json.loads(p.read_text())
    assert (
        _err_code(lambda: resolve_template_machinery(raw, str(tmp_path)))
        == "metaparameter_type_error"
    )


def test_metaparameter_fold_ranges_regions_size_exact(tmp_path):
    p = tmp_path / "m.esm"
    p.write_text(
        json.dumps(
            {
                "esm": "1.0.0",
                "metadata": {"name": "fold"},
                "metaparameters": {"N": {"type": "integer", "default": 6}},
                "index_sets": {
                    "cells": {"kind": "interval", "size": {"op": "*", "args": ["N", 2]}}
                },
                "models": {
                    "M": {
                        "variables": {
                            "x": {"type": "unknown", "units": "1", "default": 0.5},
                            "agg": {"type": "unknown", "units": "1"},
                            "ma": {"type": "unknown", "units": "1"},
                        },
                        # `agg` / `ma` are OBSERVED unknowns: their structural
                        # metaparameter sites live on their defining EQUATIONS.
                        "equations": [
                            {
                                "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                                "rhs": {"op": "-", "args": ["x"]},
                            },
                            {
                                "lhs": "agg",
                                "rhs": {
                                    "op": "aggregate",
                                    "output_idx": ["i"],
                                    "args": ["x"],
                                    "ranges": {"i": [1, {"op": "-", "args": ["N", 1]}]},
                                    "expr": {"op": "*", "args": ["x", "i"]},
                                },
                            },
                            {
                                "lhs": "ma",
                                "rhs": {
                                    "op": "makearray",
                                    "args": [],
                                    "regions": [[[{"op": "/", "args": ["N", 2]}, "N"]]],
                                    "values": [1.5],
                                },
                            },
                        ],
                    }
                },
            }
        )
    )
    f = load(str(p))
    assert f.index_sets["cells"]["size"] == 12
    m = f.models["M"]
    assert _defining_typed(m, "agg").ranges == {"i": [1, 5]}
    assert _defining_typed(m, "ma").regions == [[[3, 6]]]


def test_expression_position_substitution_never_folds(tmp_path):
    p = tmp_path / "m.esm"
    p.write_text(
        json.dumps(
            {
                "esm": "1.0.0",
                "metadata": {"name": "subst"},
                "metaparameters": {"N": {"type": "integer", "default": 144}},
                "models": {
                    "M": {
                        "variables": {
                            "x": {"type": "unknown", "units": "1", "default": 0.5},
                            "dlon": {"type": "unknown", "units": "1"},
                        },
                        "equations": [
                            {
                                "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                                "rhs": {"op": "-", "args": ["x"]},
                            },
                            {"lhs": "dlon", "rhs": {"op": "/", "args": [360, "N"]}},
                        ],
                    }
                },
            }
        )
    )
    f = load(str(p))
    dlon = _defining_typed(f.models["M"], "dlon")
    assert dlon.op == "/"
    assert dlon.args == [360, 144]


def _chain_doc(n: int) -> dict:
    """An n-template body-reference chain c_01 -> ... -> c_<n>."""
    tpl = {}
    for i in range(1, n + 1):
        name = f"c_{i:02d}"
        if i == n:
            tpl[name] = {"params": [], "body": 1}
        else:
            tpl[name] = {
                "params": [],
                "body": {
                    "op": "apply_expression_template",
                    "args": [],
                    "name": f"c_{i + 1:02d}",
                    "bindings": {},
                },
            }
    return {
        "esm": "1.0.0",
        "metadata": {"name": "chain"},
        "models": {
            "M": {
                "expression_templates": tpl,
                "variables": {"x": {"type": "unknown", "default": 0.5}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                        "rhs": {"op": "-", "args": ["x"]},
                    }
                ],
            }
        },
    }


def test_body_composition_inlines_acyclic_dag_and_depth_bound_is_exact():
    # A 3-deep local chain inlines through the §9.6.3 fixpoint untouched.
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "chain3"},
        "models": {
            "M": {
                "expression_templates": {
                    "c1": {
                        "params": [],
                        "body": {
                            "op": "+",
                            "args": [
                                1,
                                {
                                    "op": "apply_expression_template",
                                    "args": [],
                                    "name": "c2",
                                    "bindings": {},
                                },
                            ],
                        },
                    },
                    "c2": {
                        "params": [],
                        "body": {
                            "op": "+",
                            "args": [
                                2,
                                {
                                    "op": "apply_expression_template",
                                    "args": [],
                                    "name": "c3",
                                    "bindings": {},
                                },
                            ],
                        },
                    },
                    "c3": {"params": [], "body": 3},
                },
                "variables": {
                    "x": {"type": "unknown", "units": "1", "default": 0.5},
                    "y": {"type": "unknown", "units": "1"},
                },
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                        "rhs": {"op": "-", "args": ["x"]},
                    },
                    {
                        "lhs": "y",
                        "rhs": {
                            "op": "apply_expression_template",
                            "args": [],
                            "name": "c1",
                            "bindings": {},
                        },
                    },
                ],
            }
        },
    }
    # esm-spec §9.6.4 Option B: the 3-deep local chain is CHECKED (acyclic,
    # depth-bounded) but NOT inlined; the references survive lower and Expand
    # denotes the fully-inlined value (§9.6.4 rule 2).
    out = expand_document(lower_expression_templates(copy.deepcopy(doc)))
    assert _defining(out, "M", "y") == {"op": "+", "args": [1, {"op": "+", "args": [2, 3]}]}

    # Exactly MAX_TEMPLATE_EXPANSION_DEPTH templates chain: accepted; one
    # more: template_body_expansion_too_deep. The depth counts TEMPLATES on
    # the longest chain — a 33-template chain is rejected, 32 accepted (the
    # shared generated fixture pins the reject side; this pins the boundary).
    assert lower_expression_templates(_chain_doc(MAX_TEMPLATE_EXPANSION_DEPTH)) is not None
    assert (
        _err_code(lambda: lower_expression_templates(_chain_doc(MAX_TEMPLATE_EXPANSION_DEPTH + 1)))
        == "template_body_expansion_too_deep"
    )


def _chainlib_consumer(tmp_path, chain_len):
    """A consumer whose local `uses_head` template references the head of an
    imported `chain_len`-deep library chain (uninlined under Option B)."""
    tmp_path.mkdir(parents=True, exist_ok=True)
    lib = _chain_doc(chain_len)
    lib_doc = {
        "esm": "1.0.0",
        "metadata": {"name": "chainlib"},
        "expression_templates": lib["models"]["M"]["expression_templates"],
    }
    (tmp_path / "chainlib.esm").write_text(json.dumps(lib_doc))
    consumer = tmp_path / "m.esm"
    consumer.write_text(
        _model_json(
            '\n"expression_template_imports": [{"ref": "./chainlib.esm"}],\n'
            '"expression_templates": {"uses_head": {"params": [],\n'
            '  "body": {"op": "apply_expression_template", "args": [], '
            '"name": "c_01", "bindings": {}}}},'
        )
    )
    return str(consumer)


def test_cross_file_chains_accumulate_depth_under_option_b(tmp_path):
    """esm-spec §9.6.4 Option B: with bodies NO LONGER inlined (§9.7.3
    check-only), an imported library's chain does NOT arrive closed — its
    references are preserved, so the §9.7.3 depth check in the CONSUMING scope
    spans the full cross-file chain. A consumer template referencing the head of
    a 31-deep library chain composes to depth 32 (accepted); referencing the
    head of a 32-deep chain composes to depth 33 and is rejected with
    `template_body_expansion_too_deep`. (This inverts the pre-0.9.0 Option-A
    behavior, where inlined-closed library bodies counted as depth-1 leaves; the
    Julia reference dropped the old assertion for the same reason.)"""
    # 31-deep library + head reference = 32 templates on the chain → accepted.
    f = load(_chainlib_consumer(tmp_path / "ok", MAX_TEMPLATE_EXPANSION_DEPTH - 1))
    assert "M" in f.models
    # 32-deep library + head reference = 33 → rejected in the consuming scope.
    assert (
        _err_code(lambda: load(_chainlib_consumer(tmp_path / "bad", MAX_TEMPLATE_EXPANSION_DEPTH)))
        == "template_body_expansion_too_deep"
    )


def test_effective_order_beats_sorted_name_order(tmp_path):
    """§9.7.4: the effective declaration order is imports (array order) then
    locals — NOT sorted template names. The first import's rule name sorts
    AFTER the second's, so a name-sorted tie-break would pick the wrong
    winner; the effective sequence must pin z_rule (2*x)."""
    (tmp_path / "lib_first.esm").write_text(
        json.dumps(
            {
                "esm": "1.0.0",
                "metadata": {"name": "lib_first"},
                "expression_templates": {
                    "z_rule": {
                        "params": ["f"],
                        "match": {"op": "lowerme", "args": ["f"]},
                        "body": {"op": "*", "args": [2, "f"]},
                    }
                },
            }
        )
    )
    (tmp_path / "lib_second.esm").write_text(
        json.dumps(
            {
                "esm": "1.0.0",
                "metadata": {"name": "lib_second"},
                "expression_templates": {
                    "a_rule": {
                        "params": ["f"],
                        "match": {"op": "lowerme", "args": ["f"]},
                        "body": {"op": "*", "args": [3, "f"]},
                    }
                },
            }
        )
    )
    p = tmp_path / "m.esm"
    p.write_text(
        json.dumps(
            {
                "esm": "1.0.0",
                "metadata": {"name": "order"},
                "models": {
                    "M": {
                        "expression_template_imports": [
                            {"ref": "./lib_first.esm"},
                            {"ref": "./lib_second.esm"},
                        ],
                        "variables": {
                            "x": {"type": "unknown", "units": "1", "default": 1.5},
                            "y": {"type": "unknown", "units": "1"},
                        },
                        "equations": [
                            {
                                "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                                "rhs": {"op": "-", "args": ["x"]},
                            },
                            {"lhs": "y", "rhs": {"op": "lowerme", "args": ["x"]}},
                        ],
                    }
                },
            }
        )
    )
    f = load(str(p))
    y = _defining_typed(f.models["M"], "y")
    assert y.op == "*"
    assert y.args == [2, "x"]  # the FIRST import's rule wins the tie


def test_body_may_not_reference_match_rule():
    doc = json.loads(
        _model_json(
            '\n"expression_templates": {'
            '"rule": {"params": ["f"], "match": {"op": "lowerme", "args": ["f"]},'
            ' "body": {"op": "*", "args": [2, "f"]}},'
            '"uses_rule": {"params": [], "body": {"op": "apply_expression_template",'
            ' "args": [], "name": "rule", "bindings": {"f": 1}}}},'
        )
    )
    assert (
        _err_code(lambda: lower_expression_templates(doc))
        == "apply_expression_template_unknown_template"
    )


def test_match_pattern_may_not_contain_apply_node():
    """esm-spec §9.7.3: match patterns MUST NOT reference templates — the
    match-with-apply rejection is now apply_expression_template_invalid_declaration."""
    doc = json.loads(
        _model_json(
            '\n"expression_templates": {'
            '"frag": {"params": [], "body": 1},'
            '"rule": {"params": ["f"],'
            ' "match": {"op": "lowerme", "args": [{"op": "apply_expression_template",'
            ' "args": [], "name": "frag", "bindings": {}}]},'
            ' "body": {"op": "*", "args": [2, "f"]}}},'
        )
    )
    assert (
        _err_code(lambda: lower_expression_templates(doc))
        == "apply_expression_template_invalid_declaration"
    )


def test_version_gate_flags_every_v097_construct():
    """The pre-0.8.0 gate, exercised DIRECTLY.

    From 1.0.0 ``load()`` rejects every major-version-0 document outright, so
    this gate is only reached by calling it — the 0.7.0 documents below are
    deliberately spelled in the LEGACY format (``"type": "state"``) they would
    have carried, because that is the only kind of file the gate ever sees.
    """
    for snippet in [
        '"metaparameters": {"N": {"type": "integer"}},',
        '"expression_templates": {"t": {"params": [], "body": 1}},',
    ]:
        doc = json.loads(f"""
        {{"esm": "0.7.0", "metadata": {{"name": "old"}},{snippet}
         "models": {{"M": {{"variables": {{"x": {{"type": "state", "default": 0.5}}}},
                          "equations": []}}}}}}""")
        assert (
            _err_code(lambda: reject_template_imports_pre_v08(doc))
            == "template_import_version_too_old"
        )
    # 0.8.0-and-later files pass the gate; 1.0.0 is what a real file declares.
    ok = json.loads("""
    {"esm": "1.0.0", "metadata": {"name": "new"},
     "metaparameters": {"N": {"type": "integer", "default": 1}},
     "expression_templates": {"t": {"params": [], "body": 1}}}""")
    assert reject_template_imports_pre_v08(ok) is None


def test_zero_parameter_templates_are_legal():
    """esm-spec §9.6.1 (0.8.0): params MAY be empty — a zero-parameter
    template is a named constant fragment."""
    doc = json.loads(
        _model_json(
            '\n"expression_templates": {"two": {"params": [], "body": 2}},'
            '"initialization_equations": [],'
        )
    )
    doc["models"]["M"]["variables"]["y"] = {"type": "unknown", "units": "1"}
    doc["models"]["M"]["equations"].append(
        {
            "lhs": "y",
            "rhs": {
                "op": "apply_expression_template",
                "args": [],
                "name": "two",
                "bindings": {},
            },
        }
    )
    # Option B: `two` is target-free → the reference survives lower; Expand
    # yields the Option-A constant image.
    out = expand_document(lower_expression_templates(doc))
    assert _defining(out, "M", "y") == 2


# ---------------------------------------------------------------------------
# Spec pins: §4.3.2 makearray empty/inverted regions, §4.7 subsystem
# index-set merge (mirrors the Julia reference)
# ---------------------------------------------------------------------------


def test_makearray_empty_region_min_extent_loads_and_rebind_rejects():
    """§4.3.2: an interior region [2, N-1] at the minimum admissible extent
    N = 2 folds to the canonical EMPTY bound [2, 1] and loads clean; re-binding
    N = 1 at the loader API folds it to [2, 0] — INVERTED — and is rejected."""
    path = os.path.join(VALID_DIR, "makearray_empty_region_min_extent.esm")
    load(path)  # N = 2 (default) → empty bound, loads clean
    with pytest.raises(ExpressionTemplateError) as exc:
        load(path, metaparameters={"N": 1})
    assert exc.value.code == "makearray_region_inverted"


def test_subsystem_index_set_merge_brings_axes_into_registry():
    """§4.7: a mounted subsystem file's top-level index_sets merge into the
    importing document's registry. The host redeclares cells deep-equal
    (idempotent) and gains vertices from the mesh file."""
    f = load(os.path.join(VALID_DIR, "subsystem_index_set_merge.esm"))
    assert f.index_sets["cells"]["size"] == 5
    assert f.index_sets["vertices"]["size"] == 4


def test_dim_axis_name_survives_metaparameter_substitution():
    """§9.7.6: a `dim` field names an AXIS / index set (a structural namespace),
    never an expression position. Even when a metaparameter `N` is bound to an
    integer, a body node's `"dim":"N"` must be preserved verbatim — NOT folded
    to the integer value — because `dim` is in `_META_SUBST_SKIP_KEYS`."""
    body = {"op": "sum", "dim": "N", "of": ["x"]}
    out = _substitute_metaparams(body, {"N": 7})
    assert out["dim"] == "N"
    # sanity: the substitution machinery IS active for genuine expression
    # positions (bare variable-reference strings), so this is a real skip.
    assert _substitute_metaparams("N", {"N": 7}) == 7
