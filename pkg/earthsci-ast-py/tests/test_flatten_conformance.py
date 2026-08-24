"""Cross-language conformance for `flatten`'s canonical FlattenedSystem shape.

Drives the shared corpus at ``tests/conformance/flatten/cases.json``, which
esm-libraries-spec §4.7.5 step 4 makes a cross-binding contract rather than five
lookalike structs. The corpus is generated FROM this binding
(``scripts/generate-flatten-corpus.py``), so for Python this module is a
REGRESSION lock, not a discovery test: it fails when a change to `flatten` moves
the oracle out from under the other four bindings without the corpus being
regenerated deliberately.

What is pinned per fixture:

* the ordered contents of every step-4 map, with per-variable metadata (units,
  ``default``, ``shape``, update kinds, distribution kind);
* the equation count and every equation rendered with ``to_ascii``;
* the derived ``system_kind``;
* the registries — ``index_sets``, ``function_tables``, ``template_registry`` —
  and ``field_ics`` / ``loader_fields`` / ``lifted_shapes``.

ORDER IS PART OF THE CONTRACT. A parameter vector is positional, so sorted or
map-iteration order is non-conforming; :func:`test_document_order_is_not_sorted`
states that in the form that actually fails under sorting rather than trusting
the recorded lists to notice.

The §6.3.1 partition invariants are re-asserted here as well as in the
generator: the generator protects the corpus, this protects the binding.
"""

from __future__ import annotations

import json

import pytest
from conftest import CONFORMANCE_DIR, FIXTURES_ROOT, REPO_ROOT

from earthsci_ast import flatten, load_path

CASES_FILE = CONFORMANCE_DIR / "flatten" / "cases.json"


def _load_corpus() -> dict:
    """Read the shared corpus; a missing file is a hard failure, not a skip —
    the corpus IS the contract this module exists to enforce."""
    assert CASES_FILE.exists(), f"flatten corpus not found at {CASES_FILE}"
    return json.loads(CASES_FILE.read_text(encoding="utf-8"))


CORPUS = _load_corpus()
CASES = CORPUS["cases"]
IDS = [c["id"] for c in CASES]

#: Every recorded field except the case's own bookkeeping keys. Enumerated from
#: the corpus rather than hard-coded so a field added upstream is compared here
#: without editing this module — and so a field SILENTLY DROPPED from the oracle
#: fails loudly instead of going uncompared.
_BOOKKEEPING = {"id", "tier", "fixture"}


@pytest.fixture(scope="module")
def generator():
    """The corpus generator module, loaded once."""
    import importlib.util

    spec_path = REPO_ROOT / "scripts" / "generate-flatten-corpus.py"
    assert spec_path.is_file(), f"corpus generator not found at {spec_path}"
    spec = importlib.util.spec_from_file_location("_flatten_corpus_gen", spec_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_the_corpus_is_not_empty():
    """A corpus that silently generated zero cases would make every parametrized
    test below vacuously green."""
    assert CASES, "the flatten corpus recorded no cases"
    assert CORPUS["oracle"].startswith("earthsci_ast.flatten")


@pytest.mark.parametrize("case", CASES, ids=IDS)
def test_flatten_matches_the_corpus(case, generator):
    """Every recorded field of the step-4 table, compared field by field.

    Compared per field rather than as one blob so a failure names WHICH field
    moved — a diff of two 300-line records is not a diagnosis.
    """
    actual = generator._record(flatten(load_path(str(FIXTURES_ROOT / case["fixture"]))))
    for key, expected in case.items():
        if key in _BOOKKEEPING:
            continue
        assert key in actual, f"{case['id']}: `{key}` is recorded but no longer produced"
        assert actual[key] == expected, f"{case['id']}: `{key}` diverged from the corpus"
    extra = set(actual) - set(case) - _BOOKKEEPING
    assert not extra, (
        f"{case['id']}: flatten now produces {sorted(extra)}, which the corpus does not "
        "pin — regenerate scripts/generate-flatten-corpus.py"
    )


@pytest.mark.parametrize("case", CASES, ids=IDS)
def test_the_parameter_subsets_partition_the_parameters(case):
    """esm-spec §6.3.1: ``brownian_parameters`` / ``discrete_parameters`` /
    ``sampled_parameters`` / ``constant_parameters`` partition THE PARAMETERS.

    So a wiener-updated entry is a parameter that ALSO appears in
    ``brownian_parameters``. Removing it from ``parameters`` — what Rust and
    TypeScript do today — leaves the four sets partitioning nothing and makes
    the parameter vector's length depend on whether the model happens to be
    stochastic. This is the single invariant this corpus exists to spread.
    """
    flat = flatten(load_path(str(FIXTURES_ROOT / case["fixture"])))
    parameters = set(flat.parameters)
    assert set(flat.brownian_parameters) <= parameters
    assert set(flat.discrete_parameters) <= parameters
    assert not set(flat.brownian_parameters) & set(flat.discrete_parameters)
    # ... and the algebraic unknowns are unknowns.
    assert set(flat.algebraic_variables) <= set(flat.state_variables) | set(flat.observed_variables)


@pytest.mark.parametrize("case", CASES, ids=IDS)
def test_losing_the_subsets_would_lose_system_kind(case):
    """§6.3.1's ``system_kind`` derivation tests ``brownian_parameters`` FIRST,
    so the bucket surviving flatten is what keeps the flattened form able to say
    ``"sde"``. A consumer of a FlattenedSystem that dropped it integrates a
    stochastic system as a deterministic one."""
    flat = flatten(load_path(str(FIXTURES_ROOT / case["fixture"])))
    if flat.brownian_parameters:
        assert flat.system_kind == "sde"
    assert flat.system_kind == case["system_kind"]


def test_document_order_is_not_sorted():
    """Step 4's ordering rule, in the form that fails under sorted or hash order.

    ``ornstein_uhlenbeck.esm`` declares its variables x, theta, sigma, Bw. The
    conforming parameter vector is therefore [OU.theta, OU.sigma, OU.Bw];
    sorting yields [OU.Bw, OU.sigma, OU.theta] and a Dict-hash order yields
    something else again. All three "contain the same parameters", which is
    exactly why a set-valued assertion cannot catch the defect: a parameter
    vector is positional, so the order is observable in every solution the
    binding produces.
    """
    flat = flatten(load_path(str(FIXTURES_ROOT / "fixtures/sde/ornstein_uhlenbeck.esm")))
    assert list(flat.parameters) == ["OU.theta", "OU.sigma", "OU.Bw"]
    assert list(flat.parameters) != sorted(flat.parameters)
    # The subset keeps its parent's position, rather than being re-sorted.
    assert list(flat.brownian_parameters) == ["OU.Bw"]
    assert "OU.Bw" in flat.parameters, "a wiener parameter is still a parameter"


def test_document_order_survives_coupling():
    """Coupling-merged entries keep the position of their FIRST occurrence
    (step 4's ordering rule), so a multi-component system's parameter vector is
    the components' vectors concatenated in file order — not re-sorted, and not
    reordered by which coupling edge touched what."""
    case = next(c for c in CASES if c["id"] == "coupled_atmospheric_system")
    flat = flatten(load_path(str(FIXTURES_ROOT / case["fixture"])))
    names = list(flat.parameters)
    assert names == [v["name"] for v in case["parameters"]]
    assert names != sorted(names)
    # Components appear in file order: every parameter of the first source
    # system precedes every parameter of the last.
    first, last = flat.metadata.source_systems[0], flat.metadata.source_systems[-1]
    firsts = [i for i, n in enumerate(names) if n.startswith(f"{first}.")]
    lasts = [i for i, n in enumerate(names) if n.startswith(f"{last}.")]
    if firsts and lasts:
        assert max(firsts) < min(lasts)


@pytest.mark.parametrize(
    "entry", CORPUS["refusals"], ids=[r["fixture"] for r in CORPUS["refusals"]]
)
def test_the_refusals_are_refused(entry):
    """A document the corpus records as refused must still be refused, with the
    named error class. The ``reason`` is prose for a human and is not asserted."""
    with pytest.raises(Exception) as excinfo:  # noqa: B017 - the class name IS the assert
        flatten(load_path(str(FIXTURES_ROOT / entry["fixture"])))
    assert type(excinfo.value).__name__ == entry["error"]


def test_the_template_registry_is_scoped_before_it_is_unioned():
    """The step-4 ordering requirement that the union is taken over
    COMPONENT-SCOPED bodies, pinned on the fixture built for it.

    ``fixture_twins.esm`` has two byte-identical models importing one library
    whose body carries a free ``inv_dx`` — a model-local parameter, so it
    denotes a DIFFERENT variable in each. Deduplicating the pre-scoping bodies
    keeps one entry that is correct for neither model. Scoping first makes them
    non-deep-equal, which routes them into the collision rename and keeps an
    entry per owner, each wrapper reaching its own leaf.
    """
    path = FIXTURES_ROOT / (
        "conformance/expression_templates/flatten_registry_merge_transitive/fixture_twins.esm"
    )
    flat = flatten(load_path(str(path)))
    assert set(flat.template_registry) == {
        "A.interior_stencil",
        "A.outer_stencil",
        "B.interior_stencil",
        "B.outer_stencil",
    }, "bare names here mean the union was taken before the bodies were scoped"
    body = json.dumps(flat.template_registry["A.interior_stencil"]["body"])
    assert "A.inv_dx" in body and "B.inv_dx" not in body
    # Nothing dangles: every nested reference resolves in the merged registry.
    for name, decl in flat.template_registry.items():
        for ref in _apply_names(decl):
            assert ref in flat.template_registry, f"{name} references missing {ref}"


def _apply_names(node) -> list[str]:
    """Every ``apply_expression_template`` name reachable from a raw JSON node."""
    out: list[str] = []
    if isinstance(node, dict):
        if node.get("op") == "apply_expression_template" and isinstance(node.get("name"), str):
            out.append(node["name"])
        for value in node.values():
            out.extend(_apply_names(value))
    elif isinstance(node, list):
        for value in node:
            out.extend(_apply_names(value))
    return out
