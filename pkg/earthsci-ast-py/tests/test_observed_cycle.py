"""``observed_cycle`` — a cycle among one model's OBSERVED definitions.

esm-spec §4.9.6 (issue #181). An observed unknown is *defined* by the RHS of the
equation whose LHS names it (§6.3.1), so a model's observed definitions induce a
dependency graph over the observed names: ``V -> W`` whenever ``W`` occurs free
in ``V``'s defining RHS and ``W`` is itself an observed of the same model. A
cycle in that graph means no evaluation order satisfies every definition, and
the equations ALONE decide it, so it is a hard structural error in ``validate``.

The pinned pair is ``(observed_cycle, /models/<M>)``; the prose is deliberately
NOT pinned across bindings (CONFORMANCE_SPEC §5.19.5), but every binding's
message must NAME the observeds on the cycle, so the assertions below test for
the names rather than for a sentence.
"""

from __future__ import annotations

import json

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast import load_path, load_string
from earthsci_ast.error_handling import ERROR_CODES, OBSERVED_CYCLE
from earthsci_ast.validation import SchemaValidationError

_CYCLE_FIXTURE = FIXTURES_ROOT / "invalid" / "observed_cycle_array_elementwise.esm"


def _records(document: dict) -> list[dict]:
    """Every structural finding ``load`` produced for ``document``.

    Returns ``[]`` for a document that loaded clean, so a test can assert both
    directions without a second code path."""
    try:
        load_string(json.dumps(document))
    except SchemaValidationError as err:
        return list(getattr(err, "records", []))
    return []


def _cycle_records(document: dict) -> list[dict]:
    return [r for r in _records(document) if r["code"] == OBSERVED_CYCLE]


def _model(variables: dict, equations: list) -> dict:
    """A one-model document with nothing in it but the equations under test."""
    return {
        "esm": "1.0.0",
        "metadata": {"name": "ObservedCycleUnderTest"},
        "models": {"M": {"variables": variables, "equations": equations}},
    }


@pytest.fixture(scope="module")
def records() -> list[dict]:
    """Every structural finding ``load`` produced for the shared #181 fixture."""
    assert _CYCLE_FIXTURE.is_file(), f"shared fixture missing: {_CYCLE_FIXTURE}"
    try:
        load_path(str(_CYCLE_FIXTURE))
    except SchemaValidationError as err:
        return list(getattr(err, "records", []))
    pytest.fail("the shared observed-cycle fixture loaded clean; it must be rejected")


class TestTheSharedFixture:
    """``tests/invalid/observed_cycle_array_elementwise.esm`` — the cross-binding
    fixture for issue #181: three ARRAY observeds over one index set reading each
    other ELEMENTWISE, plus a fourth (``in_pbl``) that is correct in every
    respect and merely reads one of them."""

    def test_it_is_rejected_with_the_pinned_code_and_path(self, records):
        """The pin is the ``(code, path)`` pair. A cycle belongs to no single
        equation, so it pins at the MODEL — exactly as ``equation_count_mismatch``
        does — not at whichever equation the walk happened to reach first."""
        pairs = [(r["code"], r["path"]) for r in records]
        assert (OBSERVED_CYCLE, "/models/YSU") in pairs, pairs

    def test_the_message_names_the_observeds_on_the_cycle(self, records):
        """Naming the cycle is the requirement, not a nicety: a diagnostic that
        says only "there is a cycle" leaves the author exactly where the
        pre-#181 build-time failure did."""
        found = [r for r in records if r["code"] == OBSERVED_CYCLE]
        assert len(found) == 1, f"one cycle is reported per model; got {found}"
        message = found[0]["message"]
        for name in ("gamfac", "hpbl", "wscale"):
            assert name in message, f"{name!r} is on the cycle but not in {message!r}"
        assert " -> " in message, f"the cycle must be joined by ' -> ': {message!r}"

    def test_the_innocent_bystander_is_not_on_the_reported_cycle(self, records):
        """``in_pbl`` is the whole reason the fixture has this shape. It is a
        fourth observed, declared, defined and referenced perfectly well, that
        merely READS ``hpbl``; it is the name a binding that lets the cycle
        through to the build reports instead (``E_TREEWALK_UNBOUND_NAME:
        'in_pbl'``), because it is whichever name that walk tried first after the
        cycle stalled. Reporting it is the mis-attribution this diagnostic
        exists to replace."""
        found = next(r for r in records if r["code"] == OBSERVED_CYCLE)
        assert "in_pbl" not in found["details"]["cycle"]
        assert "in_pbl" not in found["message"]

    def test_details_carry_the_closed_traversal_path(self, records):
        """``details["cycle"]`` is a PATH — traversal order with the entry node
        repeated to close it — not one of the §7.1.0 name lists, so it is
        ordered semantically rather than lexicographically. Sorted roots and
        sorted successors make it the same path on every run: ``gamfac`` sorts
        first among the observeds, and its successor closes back to it."""
        found = next(r for r in records if r["code"] == OBSERVED_CYCLE)
        assert found["details"]["cycle"] == ["gamfac", "hpbl", "wscale", "gamfac"]

    def test_the_walk_is_deterministic(self):
        """Same document, same named cycle — every time. A graph with more than
        one cycle (or one entered from more than one root) must not report a
        different name on a different run, or the diagnostic is untestable and
        two bindings can never be compared."""
        reported = set()
        for _ in range(5):
            try:
                load_path(str(_CYCLE_FIXTURE))
            except SchemaValidationError as err:
                for r in getattr(err, "records", []):
                    if r["code"] == OBSERVED_CYCLE:
                        reported.add(tuple(r["details"]["cycle"]))
        assert reported == {("gamfac", "hpbl", "wscale", "gamfac")}


class TestScalarCycles:
    """The graph is over NAMES, not over shapes: a cycle among plain scalar
    observeds is the same defect and carries the same code."""

    def test_two_variable_scalar_cycle(self):
        """``a ~ b + 1; b ~ a + 1`` — neither definition can be evaluated first."""
        doc = _model(
            {
                "a": {"type": "unknown", "units": "1"},
                "b": {"type": "unknown", "units": "1"},
            },
            [
                {"lhs": "a", "rhs": {"op": "+", "args": ["b", 1.0]}},
                {"lhs": "b", "rhs": {"op": "+", "args": ["a", 1.0]}},
            ],
        )
        found = _cycle_records(doc)
        assert len(found) == 1, f"expected one observed_cycle, got {_records(doc)}"
        assert found[0]["path"] == "/models/M"
        assert set(found[0]["details"]["cycle"]) == {"a", "b"}
        assert found[0]["details"]["cycle"][0] == found[0]["details"]["cycle"][-1]

    def test_scalar_self_reference_is_a_cycle_of_length_one(self):
        """``x ~ x + 1`` is NOT a recurrence candidate — a scalar has no axis to
        fold along and carries no ``index`` self-read — so the §4.3.1.1 self-edge
        exemption does not reach it and it IS a cycle of length one (esm-spec
        §4.9.6). Exempting every self-edge, rather than only a candidate's, would
        silently drop this."""
        doc = _model(
            {"x": {"type": "unknown", "units": "1"}},
            [{"lhs": "x", "rhs": {"op": "+", "args": ["x", 1.0]}}],
        )
        found = _cycle_records(doc)
        assert len(found) == 1, f"expected one observed_cycle, got {_records(doc)}"
        assert found[0]["details"]["cycle"] == ["x", "x"]
        assert "x" in found[0]["message"]


class TestTheRecurrenceSelfEdgeIsExempt:
    """esm-spec §4.3.1.1 / CONFORMANCE_SPEC §5.19.5. A causal self-read is an
    ORDERING WITHIN one variable — the sweep publishes each cell before the axis
    advances — rather than a dependency between two, so a recurrence CANDIDATE's
    self-edge is dropped from the §4.9.6 graph."""

    @staticmethod
    def _array_doc(rhs_body: dict, shape: list | None) -> dict:
        decl = {"type": "unknown", "units": "1"}
        if shape:
            decl["shape"] = list(shape)
        doc = _model({"s": decl}, [{"lhs": "s", "rhs": rhs_body}])
        doc["index_sets"] = {"steps": {"kind": "interval", "size": 4}}
        return doc

    @staticmethod
    def _agg(body: dict) -> dict:
        return {
            "op": "faq",
            "args": [],
            "output_idx": ["k"],
            "ranges": {"k": {"from": "steps"}},
            "expr": body,
        }

    def test_the_valid_recurrence_fixture_still_loads_clean(self):
        """``tests/valid/recurrence_causal_self_reference.esm`` is the pinned
        legal case: an array-shaped unknown whose own RHS reads ``index(r, y-a)``.
        If this check reported it, the construct would be unusable."""
        fixture = FIXTURES_ROOT / "valid" / "recurrence_causal_self_reference.esm"
        assert fixture.is_file(), f"fixture missing: {fixture}"
        assert load_path(str(fixture)) is not None

    def test_an_ill_founded_candidate_still_gets_the_recurrence_diagnosis(self):
        """The gate is CANDIDACY, never the well-foundedness VERDICT. A provably
        FORWARD self-read ``s[k+1]`` is ill founded and is still a candidate;
        gating on the verdict would leave the exemption off, this check would
        fire first, and ``recurrence_not_wellfounded`` — the named diagnosis the
        construct exists to produce — would never be reached."""
        doc = self._array_doc(
            self._agg({"op": "index", "args": ["s", {"op": "+", "args": ["k", 1]}]}),
            ["steps"],
        )
        codes = [r["code"] for r in _records(doc)]
        assert ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED in codes, codes
        assert OBSERVED_CYCLE not in codes, (
            f"the self-edge must be dropped for a candidate: {codes}"
        )

    def test_a_bare_array_self_read_is_not_a_candidate_and_is_a_cycle(self):
        """``s ~ aggregate{ s + 1 }`` reads the WHOLE array, not a cell of it, so
        there is no axis to fold along and it can never be a recurrence. It keeps
        the cycle diagnosis: candidacy is narrower than "the equation reads its
        own name"."""
        doc = self._array_doc(self._agg({"op": "+", "args": ["s", 1.0]}), ["steps"])
        found = _cycle_records(doc)
        assert len(found) == 1, f"expected one observed_cycle, got {_records(doc)}"
        assert found[0]["details"]["cycle"] == ["s", "s"]

    def test_a_self_read_through_a_template_binding_is_still_exempt(self):
        """``apply_expression_template`` carries its call-site arguments in
        ``bindings``, and this validator runs BEFORE the §9.6.4 Option-B
        expansion, so a self-read bound to a template parameter is visible to the
        reference walk (which descends ``bindings``) but not to the recurrence
        walk. The two walks must see the same tree, or this legal recurrence —
        pinned as ``tests/fixtures/recurrence/09_recurrence_through_expression_template.esm``
        — is reported as a length-one cycle."""
        fixture = (
            FIXTURES_ROOT
            / "fixtures"
            / "recurrence"
            / "09_recurrence_through_expression_template.esm"
        )
        assert fixture.is_file(), f"fixture missing: {fixture}"
        assert load_path(str(fixture)) is not None


class TestNoFalsePositives:
    """What must NOT be reported."""

    def test_a_chain_without_a_cycle_loads_clean(self):
        """``c -> b -> a`` is a DAG, so it has an evaluation order and there is
        nothing to report — the check must not fire merely because observeds
        reference one another."""
        doc = _model(
            {
                "p": {"type": "parameter", "units": "1", "default": 1.0},
                "a": {"type": "unknown", "units": "1"},
                "b": {"type": "unknown", "units": "1"},
                "c": {"type": "unknown", "units": "1"},
            },
            [
                {"lhs": "a", "rhs": {"op": "*", "args": ["p", 2.0]}},
                {"lhs": "b", "rhs": {"op": "+", "args": ["a", 1.0]}},
                {"lhs": "c", "rhs": {"op": "+", "args": ["b", 1.0]}},
            ],
        )
        assert _records(doc) == []

    def test_a_binder_sharing_an_observed_s_name_makes_no_edge(self):
        """A loop symbol is a BINDER, not a reference. An aggregate that
        contracts over ``k`` inside the definition of an observed also named
        ``k`` must not manufacture the self-edge ``k -> k``: the binder-introduced
        symbols are subtracted before the free names are intersected with the
        observed-name set."""
        doc = _model(
            {
                "p": {"type": "parameter", "units": "1", "default": 1.0},
                "k": {"type": "unknown", "units": "1"},
            },
            [
                {
                    "lhs": "k",
                    "rhs": {
                        "op": "faq",
                        "args": [],
                        "output_idx": [],
                        "ranges": {"k": {"from": "steps"}},
                        "expr": {"op": "*", "args": ["p", "k"]},
                        "reduce": "+",
                    },
                }
            ],
        )
        doc["index_sets"] = {"steps": {"kind": "interval", "size": 4}}
        assert _records(doc) == []

    def test_an_ode_state_read_by_an_observed_makes_no_edge(self):
        """``D(u) ~ …`` makes ``u`` a STATE, not an observed: the solver supplies
        its value, so an observed that reads it — and that ``D(u)``'s own RHS
        reads back — closes no cycle. Only observed definitions are nodes."""
        doc = _model(
            {
                "u": {"type": "unknown", "units": "1", "default": 1.0},
                "v": {"type": "unknown", "units": "1"},
            },
            [
                {
                    "lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                    "rhs": {"op": "*", "args": ["v", -1.0]},
                },
                {"lhs": "v", "rhs": {"op": "+", "args": ["u", 1.0]}},
            ],
        )
        assert _records(doc) == []

    def test_a_chain_deeper_than_the_recursion_limit_loads_clean(self):
        """The walk's depth is the length of the longest observed CHAIN, which is
        a property of the DOCUMENT and unbounded — not of expression nesting,
        which the schema caps.

        A recursive DFS raised ``RecursionError`` out of ``load_string`` on an
        acyclic chain of roughly 800 observeds (CPython's default limit is
        ~1000), turning a document that must validate CLEAN into a crash. 1500
        is comfortably past that limit and comfortably under anything a real
        mechanism reaches, so it pins the ceiling without pinning the constant.
        """
        n = 1500
        variables = {"p": {"type": "parameter", "units": "1", "default": 1.0}}
        variables.update({f"x{i}": {"type": "unknown", "units": "1"} for i in range(n)})
        # x_i reads x_{i+1}, so the DFS entered at the sorted-first root descends
        # the whole chain; x_{n-1} is the base case that keeps it ACYCLIC.
        equations = [
            {"lhs": f"x{i}", "rhs": {"op": "+", "args": [f"x{i + 1}", "p"]}} for i in range(n - 1)
        ]
        equations.append({"lhs": f"x{n - 1}", "rhs": "p"})
        assert _records(_model(variables, equations)) == []

    def test_a_cycle_deeper_than_the_recursion_limit_is_still_named(self):
        """The other half: closing the chain into a ring at the same depth must
        still produce ``observed_cycle`` with the whole path, not a crash."""
        n = 1500
        variables = {"p": {"type": "parameter", "units": "1", "default": 1.0}}
        variables.update({f"x{i}": {"type": "unknown", "units": "1"} for i in range(n)})
        equations = [
            {"lhs": f"x{i}", "rhs": {"op": "+", "args": [f"x{i + 1}", "p"]}} for i in range(n - 1)
        ]
        equations.append({"lhs": f"x{n - 1}", "rhs": {"op": "+", "args": ["x0", "p"]}})
        found = [r for r in _records(_model(variables, equations)) if r["code"] == OBSERVED_CYCLE]
        assert len(found) == 1
        assert found[0]["details"]["cycle"] == [f"x{i}" for i in range(n)] + ["x0"]


def test_the_code_is_in_the_public_registry():
    """``ERROR_CODES`` is the cross-binding vocabulary's single entry point, and
    the VALUE is contract (``tests/invalid/expected_errors.json`` asserts it
    verbatim)."""
    assert OBSERVED_CYCLE == "observed_cycle"
    assert ERROR_CODES.OBSERVED_CYCLE == OBSERVED_CYCLE
