#!/usr/bin/env python3
"""Generate the cross-language `flatten` conformance corpus.

The Python `earthsci_ast.flatten` (pkg/earthsci-ast-py) is the ORACLE. That is a
measured choice, not a default: esm-libraries-spec §4.7.5 step 4 fixed the
canonical `FlattenedSystem` shape only in `esm: 1.0.0`, and at that moment the
five bindings disagreed four ways about the parameter vector of ONE document
(tests/fixtures/sde/ornstein_uhlenbeck.esm). Python was already right on the two
properties the corpus cannot recover after the fact:

  * DOCUMENT ORDER. Step 4 makes ordering normative — components in file order,
    variables in declaration order, coupling-merged entries keeping their first
    occurrence. A parameter vector is positional, so Go's sorted order and
    Julia's Dict-hash order are observable defects. Python already emits
    [OU.theta, OU.sigma, OU.Bw], the order the file declares.
  * FULL PER-VARIABLE METADATA. Step 4's "Full metadata, not names" requires each
    `name -> variable` map to carry units / default / shape / update /
    distribution. A corpus generated from a names-only oracle could never pin
    them.

Python was NOT right about everything, and the two gaps it had are why this
script exists at all: `flatten` discarded the §6.3.1 classification the binding
already computed correctly (`system_kind()` returned "sde" for the OU document
while `flatten()` produced a struct that could not say so), and it carried no
merged template registry. Both are fixed in the same commit as this generator.

WHAT EACH CASE RECORDS
----------------------
Every field of the step-4 normative table, in a language-neutral JSON form:
ordered name lists for each map, the per-variable metadata that matters (units,
default, shape, update kinds, distribution kind), the equation count and the
`to_ascii` rendering of every equation (the same renderer the shared display
fixtures and the expression-parse corpus use), and the derived `system_kind`.
Anything left out here cannot be pinned later, so the maps are recorded even
when empty.

SELF-ASSERTIONS
---------------
Each case is checked before it may enter the corpus, so a bad case cannot reach
the other bindings:

  1. `set(brownian_parameters) | set(discrete_parameters)` is a SUBSET of
     `set(parameters)` — esm-spec §6.3.1's partition. This is the invariant Rust
     and TypeScript violate today (they move a wiener parameter OUT of
     `parameters`), which is exactly why it is asserted rather than assumed.
  2. `brownian_parameters` and `discrete_parameters` are disjoint.
  3. `algebraic_variables` is a subset of `state_variables | observed_variables`.
  4. Every subset's ORDER is a subsequence of its parent map's order — the
     document-order rule, stated in the only form a corpus can check.
  5. `system_kind` is "sde" whenever `brownian_parameters` is non-empty, per
     §6.3.1's first row.
  6. `equation_count == len(equations)`.
  7. Flattening the same fixture twice produces an identical record.

Regenerate with:  python3 scripts/generate-flatten-corpus.py
Output:           tests/conformance/flatten/cases.json
"""

from __future__ import annotations

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "pkg", "earthsci-ast-py", "src"))

from earthsci_ast import flatten, load_path, to_ascii  # noqa: E402
from earthsci_ast.classification import SYSTEM_KINDS  # noqa: E402
from earthsci_ast.esm_types import ExprNode  # noqa: E402

OUT_DIR = os.path.join(ROOT, "tests", "conformance", "flatten")

# --- the curated fixture set, by tier ---------------------------------------
#
# Every entry names a fixture that already exists in the shared tree. No .esm
# file is authored here: a corpus whose inputs only this script can produce pins
# nothing the other bindings can independently load.

CASES: list[tuple[str, str, str]] = [
    # (tier, id, fixture path relative to tests/)
    # --- scalar ODE, single component ---------------------------------------
    (
        "scalar_ode",
        "full_model_specification",
        "valid/full_model_specification.esm",
    ),
    # --- an algebraic unknown + the "nonlinear" system_kind branch -----------
    (
        "nonlinear_algebraic",
        "nonlinear_isorropia_shape",
        "valid/nonlinear_isorropia_shape.esm",
    ),
    # --- SDE: a wiener-updated parameter ------------------------------------
    # The reference document of the divergence this corpus fixes. Its variables
    # are declared x, theta, sigma, Bw — an order that is NOT alphabetical, so
    # the recorded parameter list fails under both sorted and hash ordering.
    ("sde", "ornstein_uhlenbeck", "fixtures/sde/ornstein_uhlenbeck.esm"),
    ("sde", "correlated_noise", "fixtures/sde/correlated_noise.esm"),
    # All three unknown kinds AND a brownian parameter in one document; this is
    # the §6.3.1 worked example, so the classification corpus already pins the
    # per-model answer and this case pins the flattened one.
    (
        "sde",
        "basic_partition",
        "conformance/classification/fixtures/basic_partition.esm",
    ),
    # --- discrete (non-wiener `update`) parameters ---------------------------
    # Seven discrete parameters spanning every non-wiener update kind, plus one
    # wiener, so the two subsets are exercised side by side and their
    # disjointness is not vacuous.
    (
        "discrete_parameters",
        "parameter_cadences",
        "conformance/classification/fixtures/parameter_cadences.esm",
    ),
    ("discrete_parameters", "advanced_coupling", "coupling/advanced_coupling.esm"),
    # --- multi-component coupled --------------------------------------------
    ("coupled", "full_coupled", "valid/full_coupled.esm"),
    (
        "coupled",
        "complete_coupling_types",
        "coupling/complete_coupling_types.esm",
    ),
    (
        "coupled",
        "coupled_atmospheric_system",
        "end_to_end/coupled_atmospheric_system.esm",
    ),
    # --- operator_compose that actually COMPOSES -----------------------------
    # Added 2026-08-24. Until then EVERY coupled case above recorded an
    # operator_compose that matched nothing, because each named an operator model
    # whose equations used a state of its own instead of the `_var` placeholder
    # (esm-spec §6.4). The corpus therefore pinned the NO-OP as the correct
    # answer, and a binding whose `operator_compose` did nothing at all passed
    # every case. These three fixtures are the ones in the shared tree whose
    # operator model really is spelled with `_var`, so they are what makes
    # §4.7.1 steps 3-5 observable:
    #
    #   * minimal_chemistry        -- the canonical §4.7.1 example: three species
    #                                 x one placeholder advection equation.
    #   * metadata_inheritance_coupled -- the same shape under a reaction system.
    #   * bare_reference_resolution -- placeholder expansion AND a `translate`
    #                                 map together, which is the pair that pins
    #                                 §10.2's redundancy invariant: consulting
    #                                 `translate` with the POST-expansion
    #                                 dependent variable turns this document into
    #                                 a spurious ConflictingDerivativeError.
    ("operator_compose", "minimal_chemistry", "valid/minimal_chemistry.esm"),
    (
        "operator_compose",
        "metadata_inheritance_coupled",
        "valid/metadata_inheritance_coupled.esm",
    ),
    (
        "operator_compose",
        "bare_reference_resolution",
        "scoping/bare_reference_resolution.esm",
    ),
    # --- arrayed model exercising index_sets ---------------------------------
    (
        "arrayed",
        "edge_enumeration_area_eff",
        "valid/aggregate/edge_enumeration_area_eff.esm",
    ),
    # --- function_tables / table_lookup --------------------------------------
    (
        "function_tables",
        "function_tables_linear",
        "conformance/function_tables/linear/fixture.esm",
    ),
    (
        "function_tables",
        "function_tables_bilinear",
        "conformance/function_tables/bilinear/fixture.esm",
    ),
    # --- expression templates: the merged template_registry ------------------
    # A reaction-system registry (carried unscoped by policy — a rate-law
    # reference is expanded eagerly at collect and never resolved post-flatten).
    (
        "template_registry",
        "expression_templates_arrhenius",
        "valid/expression_templates_arrhenius.esm",
    ),
    # Deep-equal dedup (`sten`) AND a non-deep-equal collision rename
    # (`A.s` / `B.s`) in one document.
    (
        "template_registry",
        "flatten_registry_merge",
        "conformance/expression_templates/flatten_registry_merge/fixture.esm",
    ),
    # Collision propagation along the reference DAG: a byte-identical wrapper
    # over a per-component leaf renames per owner rather than deduping into one
    # body whose nested reference no longer resolves.
    (
        "template_registry",
        "flatten_registry_merge_transitive",
        "conformance/expression_templates/flatten_registry_merge_transitive/fixture.esm",
    ),
    # The SCOPING PRECONDITION. Two byte-identical models import one library
    # whose body has a free `inv_dx` that denotes a different variable in each.
    # Pre-scoping the bodies are deep-equal and dedup to one entry that is
    # correct for neither; post-scoping they collide and are kept per owner.
    # A binding that unions before it scopes records bare names here and fails.
    (
        "template_registry",
        "flatten_registry_merge_twins",
        "conformance/expression_templates/flatten_registry_merge_transitive/fixture_twins.esm",
    ),
    # --- reaction system: species -> derived ODEs, initial values ------------
    (
        "reaction_system",
        "autocatalytic_reaction",
        "simulation/autocatalytic_reaction.esm",
    ),
    # --- field_ics: deferred `ic` equations (esm-spec §11.4.1) ---------------
    # Also the richest loader_fields / lifted_shapes case in the tree.
    (
        "field_ics",
        "advection_reaction_loaded_ic_bc",
        "valid/advection_reaction_loaded_ic_bc.esm",
    ),
]

# --- explicit refusals -------------------------------------------------------
#
# Documents deliberately NOT in the corpus, with the reason. Each is checked to
# actually raise, so a refusal cannot quietly become stale when the behavior
# changes. `error` is the oracle's exception CLASS NAME; the `reason` is prose
# and is not asserted by a consuming binding.

REFUSALS: list[dict[str, str]] = [
    {
        "fixture": "valid/template_import_lib.esm",
        "error": "ValueError",
        "reason": (
            "a pure template LIBRARY: templates and no component. There is "
            "nothing to flatten, and a library file must stay generic (its "
            "metaparameters bind per import edge), so flatten refuses rather "
            "than instantiating it at its defaults."
        ),
    },
    {
        "fixture": "coupling/couple_multiplicative_no_tendency.esm",
        "error": "CoupleMultiplicativeNoTendencyError",
        "reason": (
            "a `couple` connector applies `multiplicative` to `Surface.resistance`, a constant "
            "parameter with no `D(...)` tendency. esm-spec \u00a710.3 and libraries \u00a74.7.2 both "
            "define the transform against the target's EXISTING ODE RHS, so there is nothing to "
            "multiply. Four of five bindings used to drop the connector equation SILENTLY -- the "
            "document declared a coupling and the flattened system carried no trace of it. This "
            "case exists so `couple_multiplicative_no_tendency` cannot rot the way "
            "`operator_compose` did: every fixture that used the idiom was migrated to the "
            "\u00a710.4 `variable_map` spelling, which left the diagnostic with no fixture at all. "
            "It lives in tests/coupling/ and NOT in tests/invalid/ because it is schema-valid and "
            "structurally valid -- `tests/invalid/` means `validate()` must reject, and this "
            "document is refused at FLATTEN. Same placement rule as valid/template_import_lib.esm."
        ),
    },
    {
        "fixture": "conformance/expression_templates/nonterminating_rewrite/fixture.esm",
        "error": "ExpressionTemplateError",
        "reason": (
            "rejected at LOAD with rewrite_rule_nonterminating (esm-spec "
            "§9.6.3), so it never reaches step 4. Recorded so a binding that "
            "reaches flatten with this document knows its rewrite fixpoint is "
            "wrong, not its flatten."
        ),
    },
]

# Tiers requested for this corpus that no fixture in the shared tree supports.
# Named rather than silently dropped.
UNCOVERED_TIERS: list[dict[str, str]] = [
    {
        "tier": "conflicting_derivative",
        "reason": (
            "ConflictingDerivativeError (step 4's pre-flight over-determination "
            "check) has no fixture FILE in tests/: every binding builds the "
            "conflicting document inline in its own suite. A shared fixture "
            "would be worth adding, and this corpus would then pin the refusal."
        ),
    },
]


# --- recording ---------------------------------------------------------------


def _scalar(value):
    """A default / literal in a JSON-safe, language-neutral form."""
    if isinstance(value, ExprNode):
        return {"expr": to_ascii(value)}
    if isinstance(value, (list, tuple)):
        return [_scalar(v) for v in value]
    return value


def _update_kinds(update) -> list[str]:
    """The ordered `update.kind` tags of a variable, `[]` when it has none.

    The KIND is what the §6.3.1 parameter partition turns on and what every
    binding spells identically; the per-kind payload slots (`times`, `when`,
    `from`, `handler`) are deliberately not recorded, so the corpus does not
    pin a wire detail it is not the contract for.
    """
    if update is None:
        return []
    rules = update if isinstance(update, (list, tuple)) else [update]
    return [
        getattr(r, "kind", None) or (r.get("kind") if isinstance(r, dict) else None) for r in rules
    ]


def _variable_record(var) -> dict:
    """One flattened variable, with the metadata step 4 requires it to carry."""
    dist = var.distribution
    return {
        "name": var.name,
        "role": var.type,
        "units": var.units,
        "default": _scalar(var.default),
        "shape": list(var.shape) if var.shape else None,
        "update_kinds": _update_kinds(var.update),
        "distribution_kind": getattr(dist, "kind", None) if dist is not None else None,
        "source_system": var.source_system,
    }


def _variable_map(m) -> list[dict]:
    return [_variable_record(v) for v in m.values()]


def _event_record(ev) -> dict:
    return {
        "name": getattr(ev, "name", None),
        "conditions": [to_ascii(c) for c in (getattr(ev, "conditions", None) or [])],
        "affects": [
            f"{to_ascii(a.lhs)} = {to_ascii(a.rhs)}" for a in (getattr(ev, "affects", None) or [])
        ],
    }


def _record(flat) -> dict:
    """The whole step-4 normative field set, language-neutral."""
    return {
        "system_kind": flat.system_kind,
        "independent_variables": list(flat.independent_variables),
        "state_variables": _variable_map(flat.state_variables),
        "parameters": _variable_map(flat.parameters),
        "observed_variables": _variable_map(flat.observed_variables),
        "algebraic_variables": [v.name for v in flat.algebraic_variables.values()],
        "brownian_parameters": [v.name for v in flat.brownian_parameters.values()],
        "discrete_parameters": [v.name for v in flat.discrete_parameters.values()],
        "equation_count": len(flat.equations),
        "equations": [
            {
                "lhs": to_ascii(eq.lhs),
                "rhs": to_ascii(eq.rhs),
                "source_system": eq.source_system,
            }
            for eq in flat.equations
        ],
        "continuous_events": [_event_record(e) for e in flat.continuous_events],
        "discrete_events": [_event_record(e) for e in flat.discrete_events],
        "domain": None
        if flat.domain is None
        else {
            "independent_variable": getattr(flat.domain, "independent_variable", None),
            "element_type": getattr(flat.domain, "element_type", None),
            "array_type": getattr(flat.domain, "array_type", None),
        },
        "metadata": {
            "source_systems": list(flat.metadata.source_systems),
            "coupling_rules": list(flat.metadata.coupling_rules),
            "operator_applies": list(flat.metadata.operator_applies),
            "callbacks": list(flat.metadata.callbacks),
        },
        "index_sets": list(flat.index_sets),
        "function_tables": list(flat.function_tables),
        "template_registry": list(flat.template_registry),
        "field_ics": [{"state": s, "expr": to_ascii(e)} for s, e in flat.field_ics],
        "loader_fields": [
            {
                "name": lf.name,
                "owner": lf.owner,
                "source": lf.subkey,
                "file_variable": lf.var,
                "cadence": lf.cadence,
            }
            for lf in flat.loader_fields
        ],
        "lifted_shapes": {k: list(v) for k, v in sorted(flat.lifted_shapes.items())},
    }


# --- self-assertions ---------------------------------------------------------


def _is_subsequence(sub: list[str], whole: list[str]) -> bool:
    it = iter(whole)
    return all(any(x == y for y in it) for x in sub)


def _check(case_id: str, rec: dict) -> None:
    names = lambda key: [v["name"] for v in rec[key]]  # noqa: E731

    parameters = names("parameters")
    brownian = rec["brownian_parameters"]
    discrete = rec["discrete_parameters"]

    # 1. The §6.3.1 partition: a wiener-updated entry IS a parameter. Rust and
    #    TypeScript drop it from `parameters`, which makes the parameter
    #    vector's LENGTH depend on whether the model is stochastic and leaves
    #    the four sets partitioning nothing.
    missing = (set(brownian) | set(discrete)) - set(parameters)
    if missing:
        raise AssertionError(
            f"{case_id}: brownian|discrete is not a subset of parameters; "
            f"missing from `parameters`: {sorted(missing)}"
        )
    # 2. ... and the two subsets do not overlap.
    both = set(brownian) & set(discrete)
    if both:
        raise AssertionError(f"{case_id}: {sorted(both)} is both brownian and discrete")

    # 3. An algebraic unknown is an unknown.
    unknowns = set(names("state_variables")) | set(names("observed_variables"))
    stray = set(rec["algebraic_variables"]) - unknowns
    if stray:
        raise AssertionError(
            f"{case_id}: algebraic_variables not among the unknowns: {sorted(stray)}"
        )

    # 4. Document order: a subset's order is its parent's order, restricted.
    #    This is the only form of the ordering rule a corpus can check without
    #    re-reading the source document, and it is enough to reject sorting.
    for label, subset, parent in (
        ("brownian_parameters", brownian, parameters),
        ("discrete_parameters", discrete, parameters),
        (
            "algebraic_variables",
            rec["algebraic_variables"],
            names("state_variables") + names("observed_variables"),
        ),
    ):
        if not _is_subsequence(subset, parent):
            raise AssertionError(
                f"{case_id}: {label} is not in document order relative to its "
                f"parent map: {subset} vs {parent}"
            )

    # 5. §6.3.1's system_kind derivation tests brownian FIRST.
    if rec["system_kind"] not in SYSTEM_KINDS:
        raise AssertionError(f"{case_id}: unknown system_kind {rec['system_kind']!r}")
    if brownian and rec["system_kind"] != "sde":
        raise AssertionError(
            f"{case_id}: brownian parameters {brownian} but system_kind is "
            f"{rec['system_kind']!r}; §6.3.1 row 1 makes it 'sde'"
        )

    # 6. The count is the count.
    if rec["equation_count"] != len(rec["equations"]):
        raise AssertionError(f"{case_id}: equation_count disagrees with equations")


# --- build -------------------------------------------------------------------


def main() -> int:
    cases = []
    for tier, case_id, rel in CASES:
        path = os.path.join(ROOT, "tests", rel)
        if not os.path.isfile(path):
            raise SystemExit(f"fixture not found: {rel}")
        rec = _record(flatten(load_path(path)))
        # 7. Determinism: the oracle run twice must agree with itself before it
        #    may ask four other bindings to agree with it.
        again = _record(flatten(load_path(path)))
        if json.dumps(rec, sort_keys=True) != json.dumps(again, sort_keys=True):
            raise SystemExit(f"{case_id}: flatten is not deterministic")
        _check(case_id, rec)
        cases.append({"id": case_id, "tier": tier, "fixture": rel, **rec})

    for entry in REFUSALS:
        path = os.path.join(ROOT, "tests", entry["fixture"])
        if not os.path.isfile(path):
            raise SystemExit(f"refusal fixture not found: {entry['fixture']}")
        try:
            flatten(load_path(path))
        except Exception as exc:  # noqa: BLE001 - the class name is the contract
            actual = type(exc).__name__
            if actual != entry["error"]:
                raise SystemExit(
                    f"{entry['fixture']}: expected {entry['error']}, got {actual}"
                ) from exc
        else:
            raise SystemExit(f"{entry['fixture']}: expected the oracle to refuse it")

    corpus = {
        "$comment": (
            "Cross-language `flatten` conformance corpus. GENERATED by "
            "scripts/generate-flatten-corpus.py from the Python oracle - do not "
            "hand-edit. Each case pins the canonical FlattenedSystem field set of "
            "esm-libraries-spec §4.7.5 step 4 for one shared fixture: the ordered "
            "contents of every map, the per-variable metadata (units, default, "
            "shape, update kinds, distribution kind), every equation rendered with "
            "to_ascii, and the derived system_kind. ORDER IS PART OF THE CONTRACT "
            "- a parameter vector is positional, so a binding that sorts or uses "
            "map-iteration order is non-conforming. The parameter subsets "
            "brownian_parameters / discrete_parameters PARTITION `parameters` "
            "(esm-spec §6.3.1); they are recorded as name lists because their full "
            "metadata is already in `parameters`, where each MUST also appear. "
            "Entries in `refusals` must be rejected, with the named error type."
        ),
        "oracle": "earthsci_ast.flatten (pkg/earthsci-ast-py)",
        "spec": "esm-libraries-spec §4.7.5 step 4; esm-spec §6.3.1",
        "equation_renderer": "to_ascii",
        "cases": cases,
        "refusals": REFUSALS,
        "uncovered_tiers": UNCOVERED_TIERS,
    }

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, "cases.json")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(corpus, indent=2, ensure_ascii=False) + "\n")

    tiers: dict[str, int] = {}
    for c in cases:
        tiers[c["tier"]] = tiers.get(c["tier"], 0) + 1
    print(f"cases: {len(cases)}")
    for tier in sorted(tiers):
        print(f"  {tier}: {tiers[tier]}")
    print(f"refusals: {len(REFUSALS)}")
    print(f"uncovered tiers: {len(UNCOVERED_TIERS)}")
    print(f"-> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
