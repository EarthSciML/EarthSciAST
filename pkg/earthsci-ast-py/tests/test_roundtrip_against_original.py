"""``save(load(F))`` compared against **F itself**, over the shared corpus.

The existing round-trip checks cannot see a dropped field. The cross-binding
harness (``tests/conformance/round_trip/``) compares pass 2 against pass 3, and
``test_roundtrip.py`` asserts ``data2 == data3`` on hand-written inline literals
— the same shape. A serializer that silently forgets ``metadata.license`` is
perfectly idempotent about forgetting it, so both stay green. An empirical sweep
of ``save(load(F))`` against the ORIGINAL found 51 of the 94 ``tests/valid``
fixtures differing, one of which (``Parameter.update``) changed computed results
rather than merely losing annotation: an ``update`` block is the only channel
binding a parameter to a data source (esm-spec §5.4), so dropping it turned a
data-driven parameter into a constant.

This module closes that hole with the comparison the others cannot make.

Two tests, deliberately different in shape:

``test_save_load_reproduces_the_original``
    Full equality against the source document, for every fixture free of a
    load-time transform the spec REQUIRES. The transforming fixtures are NAMED
    with their reason (never glob-matched), so a new drop cannot hide by
    resembling one of them.

``test_no_fixture_loses_a_restored_field``
    Runs over ALL 94 fixtures, including the transforming ones, and asserts only
    that no key in the restored set disappears anywhere in the document. This is
    the half that still guards a fixture excluded above.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from conftest import VALID_DIR

import earthsci_ast as ea

# ---------------------------------------------------------------------------
# Fixtures whose load applies a transform the spec REQUIRES or explicitly
# permits, so `save(load(F)) == F` is the WRONG assertion for them. Named, never
# globbed: an entry states the exact transform, so the list cannot silently
# absorb an unrelated regression. Every one of these is verified below to
# actually differ — an entry that starts round-tripping cleanly is a stale
# exclusion and fails the test.
# ---------------------------------------------------------------------------
_EAGER_TEMPLATE_EXPANSION = (
    "eager expression-template expansion at the call site (esm-spec §9.6.4 "
    "rule 3), with the component-level `expression_templates` block dropped as "
    "rule 5 requires"
)
_METAPARAMETER_FOLDING = "metaparameter folding on emit (esm-spec §9.7.6)"
_SUBSYSTEM_REF_RESOLUTION = (
    "subsystem `ref` resolution: the {ref} mount is replaced in place by the "
    "instantiated component (esm-spec §4.7)"
)
_EMPTY_EVENT_ARRAY = (
    "an empty `discrete_events` / `continuous_events` array is omitted on "
    "re-emit — explicitly allowed (tests/conformance/README.md: 'Optional / "
    "default-valued fields may be omitted on re-emit')"
)
_EXPECT_CADENCE = (
    "`expect_cadence` node annotations are not carried by the typed IR. This "
    "matches the Julia reference (whose OpExpr deliberately omits it and runs "
    "the cadence classifier over raw JSON) and Rust; GO DOES round-trip it, so "
    "the three-way split is a cross-binding divergence awaiting a ruling, not a "
    "Python-local defect"
)

TRANSFORMING_FIXTURES: dict[str, str] = {
    "advection_reaction_loaded_ic_bc.esm": _EAGER_TEMPLATE_EXPANSION,
    "derivative_trailing_boundary_operands.esm": _EAGER_TEMPLATE_EXPANSION,
    "expression_templates_arrhenius.esm": _EAGER_TEMPLATE_EXPANSION,
    "template_import_minimal.esm": (
        "`expression_template_imports` is consumed at load and the imported "
        "bodies are expanded into their call sites (esm-spec §9.7.6)"
    ),
    "cadence/discrete_remesh_stencil.esm": _EXPECT_CADENCE,
    "cadence/loader_const_seed.esm": _EXPECT_CADENCE,
    "cadence/loader_temporal_seed.esm": _EXPECT_CADENCE,
    "cadence/mixed_stencil.esm": _EXPECT_CADENCE,
    "cadence/observed_leaf_seeds.esm": _EXPECT_CADENCE,
    "cadence/pure_pointwise.esm": _EXPECT_CADENCE,
    "cadence/pure_topology.esm": _EXPECT_CADENCE,
    "data_sources_ingest_and_select.esm": _METAPARAMETER_FOLDING,
    "makearray_empty_region_min_extent.esm": _METAPARAMETER_FOLDING,
    "enums_categorical_lookup.esm": (
        "`enum` nodes are lowered to `const` against the document's top-level "
        "`enums` block at load (esm-spec §9.3)"
    ),
    "lib_calendar_subsystem_inclusion.esm": _SUBSYSTEM_REF_RESOLUTION,
    "lib_solar_subsystem_inclusion.esm": _SUBSYSTEM_REF_RESOLUTION,
    "subsystem_index_set_merge.esm": (
        _SUBSYSTEM_REF_RESOLUTION
        + ", plus the referenced file's top-level `index_sets` merging into the "
        "importing document's registry"
    ),
    "events_discrete_periodic.esm": _EMPTY_EVENT_ARRAY,
    "events_discrete_preset_times.esm": _EMPTY_EVENT_ARRAY,
    "full_coupled.esm": _EMPTY_EVENT_ARRAY,
    "full_model_specification.esm": _EMPTY_EVENT_ARRAY,
    "tests_analyses_comprehensive.esm": (
        "the inline multi-series shorthand `y: [a, b]` is emitted in its "
        "desugared `y: a` + `series: [...]` form; esm-spec §6.7.4 states the two "
        "spellings ARE equivalent, and the round-trip contract permits "
        "normalization"
    ),
}

# ---------------------------------------------------------------------------
# Wire keys that MUST survive `load -> save` wherever they appear. Each was a
# measured drop against the corpus, or (the last four) a schema field with no
# corpus coverage that the Python-local fixtures below exercise instead.
# ---------------------------------------------------------------------------
RESTORED_KEYS: frozenset[str] = frozenset(
    {
        "reference",  # Model / ReactionSystem / Reaction
        "license",  # Metadata
        "notes",  # Reference
        "update",  # Parameter (a data binding, not an annotation)
        "distribution",  # Parameter
        "reinitialize",  # DiscreteEvent (an EXPLICIT false is not absence)
        "initial_offset",  # DiscreteEventTrigger (periodic)
        "coordinates",  # top-level registry
        "lifting",  # coupling[] (variable_map / couple / operator_compose)
        "arg",  # ExpressionNode (argmin / argmax witness)
        "x_esd",  # Metadata — normatively preserve-verbatim
        "system_class",  # Metadata
        "dae_info",  # Metadata
        "discretized_from",  # Metadata
    }
)

# `shape` is restored on `Parameter` but is NOT in RESTORED_KEYS: an expression
# node also carries a `shape`, and eager template expansion legitimately
# replaces whole nodes, so a document-wide "never drop `shape`" rule would fire
# on a sanctioned rewrite. Parameter shape is covered by the full-equality test.


def _corpus() -> list[Path]:
    return sorted(VALID_DIR.rglob("*.esm"))


def _rel(path: Path) -> str:
    return path.relative_to(VALID_DIR).as_posix()


def _reemit(path: Path) -> dict:
    """``save(load(F))``, back as parsed JSON."""
    return json.loads(ea.to_json(ea.load_path(path)))


def _dropped_keys(original: Any, reemitted: Any, path: str = "") -> Iterator[tuple[str, str]]:
    """Yield ``(wire_key, json_path)`` for every mapping key present in
    ``original`` and absent from ``reemitted``, recursively."""
    if isinstance(original, dict) and isinstance(reemitted, dict):
        for key, value in original.items():
            here = f"{path}.{key}"
            if key not in reemitted:
                yield key, here
            else:
                yield from _dropped_keys(value, reemitted[key], here)
    elif isinstance(original, list) and isinstance(reemitted, list):
        for i, (a, b) in enumerate(zip(original, reemitted)):
            yield from _dropped_keys(a, b, f"{path}[{i}]")


@pytest.mark.parametrize("fixture", _corpus(), ids=_rel)
def test_save_load_reproduces_the_original(fixture: Path) -> None:
    """``save(load(F))`` equals ``F`` — unless F is a NAMED transforming fixture,
    in which case it must still differ (a stale exclusion is a failure too)."""
    original = json.loads(fixture.read_text(encoding="utf-8"))
    reemitted = _reemit(fixture)
    reason = TRANSFORMING_FIXTURES.get(_rel(fixture))

    if reason is None:
        assert reemitted == original, (
            f"{_rel(fixture)}: re-emit differs from the source document. Either a "
            f"field is being dropped/invented, or a NEW spec-required load-time "
            f"transform needs an entry in TRANSFORMING_FIXTURES stating what it is."
        )
    else:
        assert reemitted != original, (
            f"{_rel(fixture)} now round-trips exactly, but is excluded as: {reason}. "
            f"Remove its TRANSFORMING_FIXTURES entry."
        )


@pytest.mark.parametrize("fixture", _corpus(), ids=_rel)
def test_no_fixture_loses_a_restored_field(fixture: Path) -> None:
    """No document in the corpus — transforming ones included — may lose a key
    from :data:`RESTORED_KEYS` anywhere in its tree."""
    original = json.loads(fixture.read_text(encoding="utf-8"))
    lost = [
        where for key, where in _dropped_keys(original, _reemit(fixture)) if key in RESTORED_KEYS
    ]
    assert not lost, f"{_rel(fixture)} dropped restored field(s) at: {lost}"


def test_every_transforming_fixture_exists() -> None:
    """The exclusion list names real files — a renamed fixture must not leave a
    dead entry silently excusing nothing."""
    present = {_rel(p) for p in _corpus()}
    assert not (set(TRANSFORMING_FIXTURES) - present)


# ---------------------------------------------------------------------------
# Schema fields with NO coverage anywhere in tests/valid. The shared corpus is
# owned by another work-stream (and four bindings read it), so these live here
# as package-local documents rather than as new corpus fixtures.
# ---------------------------------------------------------------------------

_METADATA_ONLY_FIELDS = {
    "esm": "1.0.0",
    "metadata": {
        "name": "MetadataPassthrough",
        "license": "AGPL-3.0-or-later",
        "system_class": "dae",
        "dae_info": {"algebraic_equation_count": 1, "per_model": {"M": 1}},
        "discretized_from": {"name": "SourceDocument"},
        # The schema's description is normative: "core tooling MUST NOT assign
        # meaning to them and MUST preserve them across parse -> emit like any
        # other metadata field." Deliberately nested and heterogeneous.
        "x_esd": {
            "catalog": "EarthSciDiscretizations",
            "version": 3,
            "rules": [{"id": "upwind", "order": 1}, {"id": "central", "order": 2}],
            "pushdown": {"applied": True},
        },
        "references": [{"citation": "Doe 2020", "notes": "the only field here"}],
    },
    "models": {
        "M": {
            "variables": {"x": {"type": "unknown", "units": "m"}},
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 1.0}],
            "reference": {"notes": "a component reference carrying only notes"},
        }
    },
}

_PARAMETER_VALUE_MACHINERY = {
    "esm": "1.0.0",
    "metadata": {"name": "ParameterValueMachinery"},
    "reaction_systems": {
        "chem": {
            "species": {"A": {"units": "ppb", "default": 1.0}},
            "parameters": {
                # `distribution` is mutually exclusive with `default`: with no
                # `update` the value is sampled once at setup and held for the
                # run. No corpus fixture puts one on a reaction-system parameter.
                # (`Parameter.update` and `Parameter.shape` ARE corpus-covered —
                # e.g. reaction_system_only.esm's `kind: data` photolysis rates.)
                "k": {
                    "units": "s^-1",
                    "description": "drawn, not fixed",
                    "distribution": {"kind": "normal", "mean": 0.5, "std": 0.1},
                },
                "T": {"units": "K", "default": 298.0, "shape": []},
            },
            "reactions": [
                {
                    "id": "R1",
                    "substrates": [{"species": "A", "stoichiometry": 1}],
                    "products": None,
                    "rate": "k",
                    "reference": {"citation": "Smith 1999", "notes": "per-reaction"},
                }
            ],
            "reference": {"notes": "a reaction-system reference"},
        }
    },
}


@pytest.mark.parametrize(
    "document",
    [_METADATA_ONLY_FIELDS, _PARAMETER_VALUE_MACHINERY],
    ids=["metadata_and_reference_fields", "parameter_value_machinery"],
)
def test_uncovered_schema_fields_survive_a_round_trip(document: dict) -> None:
    """Fields no corpus fixture exercises still survive ``load -> save``."""
    reemitted = json.loads(ea.to_json(ea.load_document(document)))
    assert reemitted == document


def test_a_reaction_without_a_name_does_not_gain_one() -> None:
    """The schema requires `id` and makes `name` an optional human-readable
    label. Parsing defaults `name` to `id` for downstream convenience; emit must
    not turn that default into a key the author never wrote."""
    document = {
        "esm": "1.0.0",
        "metadata": {"name": "NoReactionName"},
        "reaction_systems": {
            "chem": {
                "species": {"A": {"default": 1.0}},
                "parameters": {},
                "reactions": [
                    {
                        "id": "R1",
                        "substrates": [{"species": "A", "stoichiometry": 1}],
                        "products": None,
                        "rate": 1.0,
                    }
                ],
            }
        },
    }
    reemitted = json.loads(ea.to_json(ea.load_document(document)))
    assert "name" not in reemitted["reaction_systems"]["chem"]["reactions"][0]

    # ... and an authored `name` — even one equal to `id` — is kept.
    document["reaction_systems"]["chem"]["reactions"][0]["name"] = "R1"
    kept = json.loads(ea.to_json(ea.load_document(document)))
    assert kept["reaction_systems"]["chem"]["reactions"][0]["name"] == "R1"


def test_an_explicit_false_reinitialize_is_not_erased() -> None:
    """`reinitialize: false` is the schema default but is still the document's
    own text; absence and an explicit `false` stay distinguishable."""

    def doc(event: dict) -> dict:
        return {
            "esm": "1.0.0",
            "metadata": {"name": "ExplicitFalse"},
            "models": {
                "M": {
                    "variables": {"x": {"type": "unknown"}},
                    "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 1.0}],
                    "discrete_events": [event],
                }
            },
        }

    spelled = {
        "name": "tick",
        "trigger": {"type": "periodic", "interval": 1.0, "initial_offset": 0.0},
        "affects": [{"lhs": "x", "rhs": 0.0}],
        "reinitialize": False,
    }
    unspelled = {
        "name": "tick",
        "trigger": {"type": "periodic", "interval": 1.0},
        "affects": [{"lhs": "x", "rhs": 0.0}],
    }

    loaded_spelled = ea.load_document(doc(spelled))
    ev = json.loads(ea.to_json(loaded_spelled))["models"]["M"]["discrete_events"][0]
    assert ev["reinitialize"] is False
    assert ev["trigger"]["initial_offset"] == 0.0

    loaded_unspelled = ea.load_document(doc(unspelled))
    ev = json.loads(ea.to_json(loaded_unspelled))["models"]["M"]["discrete_events"][0]
    assert "reinitialize" not in ev
    assert "initial_offset" not in ev["trigger"]

    # The two spellings differ on the wire but agree on the EFFECTIVE flag,
    # which is what every consumer wants and what `.reinitializes` returns.
    assert loaded_spelled.models["M"].discrete_events[0].reinitialize is False
    assert loaded_unspelled.models["M"].discrete_events[0].reinitialize is None
    assert loaded_spelled.models["M"].discrete_events[0].reinitializes is False
    assert loaded_unspelled.models["M"].discrete_events[0].reinitializes is False
