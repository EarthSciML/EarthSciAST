"""`esm_problem(..., compiler=...)` — the closed vocabulary, the strict
`native` default, the `interpreter` oracle and the per-rule report
(``API_SPEC.md`` §5.8, esm-libraries-spec §2.5.10, CONFORMANCE_SPEC §5.44).

What these tests pin, in the order the contract states it:

* the three ways naming a compiler fails, with their registry codes;
* that ``native`` refuses a rule the vectorized tiers cannot express, AT
  CONSTRUCTION, naming the rule and the chain of declines — and that the same
  document builds under ``interpreter``;
* that ``native`` and ``interpreter`` agree BIT FOR BIT on the documents both
  run, which is the whole reason the reference exists;
* that ``sympy`` runs a scalar document and refuses an array one;
* that the report names every rule that had a tier to land on.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast import (
    COMPILERS,
    CompilerRefusedRuleError,
    CompilerUnavailableError,
    CompilerUnknownError,
    ReturnCode,
    esm_problem,
    load_path,
    solve,
)
from earthsci_ast.flatten import LoaderField

_REPO = Path(__file__).resolve().parents[3]
_TESTS = _REPO / "tests"

#: A scalar box model: no aggregate anywhere, so every compiler can run it and
#: the three answers are directly comparable.
SCALAR_ODE = _TESTS / "simulation" / "box_model_ozone.esm"
#: A discretized 1-D diffusion PDE — the whole-box pure-map tier under `native`.
PDE_DIFFUSION = (
    _TESTS / "conformance" / "pde_simulation" / "fixtures" / "diffusion_1d_dirichlet_n4.esm"
)
#: A join-gated CONTRACTION — the dense gated reduce under `native`.
FAQ_JOIN = _TESTS / "valid" / "faq" / "join_disaggregation_m2m.esm"
#: The loader-fed subsystem: the cadence-SEGMENTED engine, which is internal to
#: both `native` and `interpreter`.
LOADER_ODE = _TESTS / "conformance" / "subsystem_loader" / "fixtures" / "subsystem_loader_ode.esm"
LOADER_GOLDEN = _TESTS / "conformance" / "subsystem_loader" / "golden" / "subsystem_loader_ode.json"
#: A join-gated `faq` with NO contraction: every gated whole-box tier needs one,
#: so this shape has no whole-box tier in this binding at all and walks per cell
#: by construction (the census's largest structural hole).
GATED_PURE_MAP = _TESTS / "valid" / "geometry" / "conservative_regrid_assembly.esm"


def _loader_provider():
    """The offline CONST provider `test_subsystem_loader_conformance` uses, so
    the segmented engine has data to run on."""
    golden = json.loads(LOADER_GOLDEN.read_text())
    native = {
        name: np.asarray(spec["native"], dtype=float) for name, spec in golden["loaders"].items()
    }

    def provider(field: LoaderField, t: float) -> np.ndarray:
        return native[field.name]

    return golden, provider


# --------------------------------------------------------------------------- #
# The vocabulary
# --------------------------------------------------------------------------- #


def test_the_vocabulary_is_the_five_members_of_the_spec() -> None:
    assert COMPILERS == ("native", "interpreter", "xla", "mtk", "sympy")


@pytest.mark.parametrize("value", ["numpy", "NATIVE", "", "tape", "auto"])
def test_a_value_outside_the_vocabulary_is_compiler_unknown(value: str) -> None:
    with pytest.raises(CompilerUnknownError) as excinfo:
        esm_problem(str(SCALAR_ODE), (0.0, 1.0), compiler=value)
    assert excinfo.value.code == "compiler_unknown"
    # The message names the value AND the vocabulary, so the caller can correct
    # a near miss without reading the spec.
    assert repr(value) in str(excinfo.value)
    assert "'native'" in str(excinfo.value)


@pytest.mark.parametrize("value", ["xla", "mtk"])
def test_a_compiler_this_binding_does_not_provide_is_compiler_unavailable(value: str) -> None:
    with pytest.raises(CompilerUnavailableError) as excinfo:
        esm_problem(str(SCALAR_ODE), (0.0, 1.0), compiler=value)
    assert excinfo.value.code == "compiler_unavailable"
    message = str(excinfo.value)
    assert value in message
    # It names what would have to exist, not a machine's configuration.
    assert ("Reactant" in message) or ("ModelingToolkit" in message)


def test_an_unavailable_compiler_is_never_answered_by_building_another_one() -> None:
    # The failure mode this rules out is the kind one: refusing `xla` by quietly
    # handing back a `native` problem, which makes `prob.compiler` a lie.
    for value in ("xla", "mtk"):
        with pytest.raises(CompilerUnavailableError):
            esm_problem(str(SCALAR_ODE), (0.0, 1.0), compiler=value)


def test_no_compiler_named_means_the_strict_native_default() -> None:
    prob = esm_problem(str(SCALAR_ODE), (0.0, 1.0))
    assert prob.compiler == "native"
    assert esm_problem(str(SCALAR_ODE), (0.0, 1.0), compiler=None).compiler == "native"


# --------------------------------------------------------------------------- #
# `native` is strict, and it refuses at CONSTRUCTION
# --------------------------------------------------------------------------- #


def test_native_refuses_a_gated_pure_map_at_construction_and_names_the_rule() -> None:
    with pytest.raises(CompilerRefusedRuleError) as excinfo:
        esm_problem(str(GATED_PURE_MAP), (0.0, 1.0))
    err = excinfo.value
    assert err.code == "compiler_refused_rule"
    assert err.compiler == "native"
    # The rule is named, component-qualified, and it is an OBSERVED — this
    # document's refusal happens in the const-geometry hoist, inside
    # `esm_problem` itself, before any right-hand side exists. A `native` that
    # probed only `rhs_function` would let this document through.
    assert err.rule == "observed ConservativeRegridAssembly.W_ij"
    assert err.phase == "construction"
    # The reason is the DEEPEST decline, and the whole chain travels with it.
    assert "NO contraction" in err.reason
    tiers = [tier for tier, _ in err.declines]
    assert tiers == ["batched-leaf", "prefix-scan", "operator-cache", "gated-reduce"]


def test_the_same_document_builds_and_runs_under_the_interpreter() -> None:
    prob = esm_problem(str(GATED_PURE_MAP), (0.0, 1.0), compiler="interpreter")
    assert prob.compiler == "interpreter"
    # The rule `native` refused landed on the per-cell walk, which is where the
    # reference puts every aggregate.
    assert "observed ConservativeRegridAssembly.W_ij" in prob.compiler_report.per_cell_rules()


def test_a_refusal_names_how_to_get_an_answer_instead_of_only_failing() -> None:
    with pytest.raises(CompilerRefusedRuleError) as excinfo:
        esm_problem(str(GATED_PURE_MAP), (0.0, 1.0))
    message = str(excinfo.value)
    assert "not a fallback" in message
    assert "compiler='interpreter'" in message


def test_native_carries_no_per_cell_landing_on_a_document_it_accepts() -> None:
    # The invariant a strict `native` exists to give: if the build returned, no
    # rule walked per cell. Checked on a document with aggregates, so the claim
    # is not vacuous.
    prob = esm_problem(str(FAQ_JOIN), (0.0, 1.0))
    assert prob.compiler_report
    assert prob.compiler_report.per_cell_rules() == ()


# --------------------------------------------------------------------------- #
# `native` and `interpreter` agree bit for bit
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "fixture",
    [
        pytest.param(SCALAR_ODE, id="scalar-ode"),
        pytest.param(PDE_DIFFUSION, id="pde-diffusion"),
        pytest.param(FAQ_JOIN, id="faq-join"),
    ],
)
def test_native_and_the_interpreter_agree_bit_for_bit(fixture: Path) -> None:
    kw = {"tspan": (0.0, 1.0)}
    native = solve(esm_problem(str(fixture), kw["tspan"]), alg="LSODA")
    oracle = solve(esm_problem(str(fixture), kw["tspan"], compiler="interpreter"), alg="LSODA")
    assert native.retcode is ReturnCode.Success, native.message
    assert oracle.retcode is ReturnCode.Success, oracle.message
    assert native.vars == oracle.vars
    # BIT for bit, not to a tolerance: the whole-box tiers are written to fold in
    # the scalar walk's term order, and a difference here is a defect in one of
    # them rather than a rounding budget to widen.
    np.testing.assert_array_equal(native.t, oracle.t)
    np.testing.assert_array_equal(native.y, oracle.y)


def test_native_and_the_interpreter_agree_on_the_segmented_loader_engine() -> None:
    # The cadence-segmented engine is INTERNAL to both compilers: naming one
    # changes the tiers its per-segment builds use, never whether it segments.
    golden, provider = _loader_provider()
    t0, t1 = golden["cadence"]["tspan"]
    probs = {
        name: esm_problem(
            load_path(str(LOADER_ODE)),
            (float(t0), float(t1)),
            loader_provider=provider,
            compiler=name,
        )
        for name in ("native", "interpreter")
    }
    assert {p.engine for p in probs.values()} == {"loaders"}
    native = solve(probs["native"], alg="LSODA")
    oracle = solve(probs["interpreter"], alg="LSODA")
    assert native.retcode is ReturnCode.Success, native.message
    assert oracle.retcode is ReturnCode.Success, oracle.message
    np.testing.assert_array_equal(native.y, oracle.y)


# --------------------------------------------------------------------------- #
# `sympy`
# --------------------------------------------------------------------------- #


def test_sympy_runs_a_scalar_document_and_matches_native() -> None:
    lam = esm_problem(str(SCALAR_ODE), (0.0, 10.0), compiler="sympy")
    assert lam.compiler == "sympy"
    assert lam.engine == "scalar"
    sym = solve(lam, alg="LSODA")
    nat = solve(esm_problem(str(SCALAR_ODE), (0.0, 10.0)), alg="LSODA")
    assert sym.retcode is ReturnCode.Success, sym.message
    for name in nat.vars:
        assert name in sym.vars
        np.testing.assert_allclose(sym[name], nat[name], rtol=1e-12, atol=1e-12, err_msg=name)


def test_a_scalar_document_builds_under_native_with_no_sympy_involved() -> None:
    # The default no longer lambdifies a scalar document: §2.5.10 forbids
    # switching strategy inside `native` on document content, so a box model and
    # a grid are built by the same machinery.
    prob = esm_problem(str(SCALAR_ODE), (0.0, 10.0))
    assert prob.engine == "array"
    assert prob.scalar_build is None
    assert prob.build is not None


@pytest.mark.parametrize(
    "fixture", [pytest.param(PDE_DIFFUSION, id="pde"), pytest.param(FAQ_JOIN, id="faq-join")]
)
def test_sympy_refuses_an_array_document(fixture: Path) -> None:
    with pytest.raises(CompilerRefusedRuleError) as excinfo:
        esm_problem(str(fixture), (0.0, 1.0), compiler="sympy")
    err = excinfo.value
    assert err.code == "compiler_refused_rule"
    assert err.compiler == "sympy"
    assert err.phase == "construction"
    assert "SCALAR" in err.reason


# --------------------------------------------------------------------------- #
# The report
# --------------------------------------------------------------------------- #


def test_the_report_names_every_rule_that_had_a_tier_to_land_on() -> None:
    prob = esm_problem(str(FAQ_JOIN), (0.0, 1.0))
    report = prob.compiler_report
    assert len(report) > 0
    rules = report.rules()
    assert rules, "a document with aggregates must attribute them to rules"
    # Every entry is attributed to a real rule, never to the `<setup>` catch-all.
    assert "<setup>" not in rules
    for rule in rules:
        assert rule.startswith(("equation ", "observed "))
    # And each entry says which tier answered and in which of §2.5.10's phases.
    for entry in report:
        assert entry.tier
        assert entry.phase in ("construction", "rhs", "observed-output", "solve")


def test_the_report_distinguishes_the_tiers_the_two_compilers_land_on() -> None:
    native = esm_problem(str(FAQ_JOIN), (0.0, 1.0)).compiler_report
    oracle = esm_problem(str(FAQ_JOIN), (0.0, 1.0), compiler="interpreter").compiler_report
    assert set(native.tiers()) == {"gated-reduce"}
    assert set(oracle.tiers()) == {"scalar"}
    # Same rules, different tiers — which is exactly what the record is for.
    assert set(native.rules()) == set(oracle.rules())


def test_a_landing_carries_the_chain_of_declines_that_led_to_it() -> None:
    entries = list(esm_problem(str(FAQ_JOIN), (0.0, 1.0)).compiler_report)
    landed = [e for e in entries if e.tier == "gated-reduce"]
    assert landed
    # The gated sub-ladder is tried fastest-first, and every tier above the one
    # that answered says why it could not.
    for entry in landed:
        assert [tier for tier, _ in entry.declines] == [
            "batched-leaf",
            "prefix-scan",
            "operator-cache",
        ]
        assert all(reason for _, reason in entry.declines)


def test_the_problem_says_which_compiler_built_it() -> None:
    for name in ("native", "interpreter"):
        prob = esm_problem(str(SCALAR_ODE), (0.0, 1.0), compiler=name)
        assert prob.compiler == name
        assert f"compiler={name!r}" in repr(prob)
        assert name in str(prob)
