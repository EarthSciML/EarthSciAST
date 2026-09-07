"""esm-spec §6.6: a component's inline tests do NOT cross a mount edge.

A leaf's ``tests`` are assertions about the leaf under the leaf's OWN standalone
conditions. A document that mounts it by a top-level ``models`` ``{ref}``
(§4.7 / §9.7.10) may legitimately change those conditions — here a
``variable_map`` entry replaces the leaf's decay rate ``k`` with a fivefold
forcing — so re-running the leaf's assertions inside the assembly checks a claim
its author never made and reports a correct component as broken.

Reported against a real coupled assembly as issue #198 item 2, where a leaf that
passes standalone contributed 767 ERROR/FAIL rows to the document that mounted
it. The fixtures are shared with the Julia and Rust bindings
(``tests/conformance/mounted_component_tests/``), which pin the same rule.
"""

from __future__ import annotations

from conftest import FIXTURES_ROOT

from earthsci_ast.parse import load_path
from earthsci_ast.pde_inline_tests import run_pde_tests

FIXTURES = FIXTURES_ROOT / "conformance" / "mounted_component_tests" / "fixtures"


def _run(name: str):
    """A fixture's inline tests through the library runner, ``load_path``
    included — that is what resolves the mount."""
    esm_file = load_path(str(FIXTURES / name))
    return esm_file, run_pde_tests(esm_file, base_dir=str(FIXTURES))


def test_the_leaf_alone_passes_its_own_test():
    """``k = 1``, so ``u(1) = 1/e``. This is what attributes a failure inside
    the assembly to the mount rather than to the leaf."""
    _, results = _run("leaf.esm")
    assert [r.model for r in results] == ["Decay"]
    assert results[0].passed, results[0].message


def test_a_mounted_components_tests_do_not_run_in_the_assembly():
    """Before the fix the leaf's assertion ran here too, under ``k = 5``, and
    failed by two orders of magnitude."""
    _, results = _run("assembly.esm")
    assert [r.model for r in results] == ["Forcing"], results
    assert results[0].passed, results[0].message


def test_the_mount_does_not_carry_the_leafs_tests():
    """Dropped at the mount, not skipped by the runner — so every consumer of
    the assembled document agrees about what it asserts."""
    esm_file, _ = _run("assembly.esm")
    assert esm_file.models["Decay"].tests == []
    # The mount is otherwise a faithful splice.
    assert "u" in esm_file.models["Decay"].variables
    assert [t.id for t in esm_file.models["Forcing"].tests] == ["forcing_holds_its_rate"]
