"""esm-spec §2.2.6 `solver.external` resolution, against the SHARED pin.

Reads ``tests/conformance/solver_external/manifest.json`` and asserts this
binding against it (CONFORMANCE_SPEC §5.47). Each fixture pins two things: the
authored string the typed document holds and ``emit`` writes, and the location
:func:`earthsci_ast.solver_external_location` returns. The resolved location is
never written into the document.

Expectations are repo- or cwd-relative, not literal ``file://`` URLs: a resolved
location is machine-specific. Nothing a fixture names exists on disk, and this
test creates none of it.
"""

from __future__ import annotations

import json
import os
import posixpath
from pathlib import Path

import pytest

import earthsci_ast
from earthsci_ast.error_handling import ERROR_CODES
from earthsci_ast.flatten import flatten

REPO_ROOT = Path(__file__).resolve().parents[3]
SUITE = REPO_ROOT / "tests" / "conformance" / "solver_external"
MANIFEST = json.loads((SUITE / "manifest.json").read_text())

ACCEPTED = [f for f in MANIFEST["fixtures"] if f["expect"] == "accepted"]
REFUSED = [f for f in MANIFEST["fixtures"] if f["expect"] == "refused"]


def _lexical(path: str) -> str:
    """RFC 3986 §5.2.4 dot-segment removal on an absolute POSIX path."""
    return posixpath.normpath(path)


def _expected_location(pin: dict | None) -> str | None:
    if pin is None:
        return None
    if "verbatim" in pin:
        return pin["verbatim"]
    if "repo_path" in pin:
        return "file://" + _lexical(str(REPO_ROOT / pin["repo_path"]))
    return "file://" + _lexical(posixpath.join(os.getcwd(), pin["cwd_path"]))


def _base(pin: dict | None) -> str | None:
    return None if pin is None else str(REPO_ROOT / pin["repo_path"])


def _load(fixture: dict) -> earthsci_ast.EsmFile:
    path = SUITE / fixture["path"]
    if fixture["load"] == "path":
        return earthsci_ast.load_path(str(path))
    return earthsci_ast.load_string(path.read_text())


def _external(f: earthsci_ast.EsmFile) -> str | None:
    return f.solver.external if f.solver is not None else None


def test_the_manifest_requires_this_binding() -> None:
    assert "python" in MANIFEST["bindings_required"]


@pytest.mark.parametrize("fixture", ACCEPTED, ids=[f["id"] for f in ACCEPTED])
def test_external_resolves_as_pinned(fixture: dict) -> None:
    loaded = _load(fixture)

    assert _external(loaded) == fixture["external"]
    location = earthsci_ast.solver_external_location(loaded, base=_base(fixture["base"]))
    assert location == _expected_location(fixture["location"])

    emitted = json.loads(earthsci_ast.to_json(loaded))
    assert emitted.get("solver") == fixture["solver"]


def test_nothing_a_fixture_names_exists_on_disk() -> None:
    for fixture in ACCEPTED:
        loc = _expected_location(fixture["location"])
        if loc is not None and loc.startswith("file://"):
            assert not os.path.exists(loc[len("file://") :]), loc


@pytest.mark.parametrize("fixture", REFUSED, ids=[f["id"] for f in REFUSED])
def test_an_unresolvable_external_is_refused_by_a_diagnostic_that_names_it(
    fixture: dict,
) -> None:
    code = fixture["error_code"]
    assert code in ERROR_CODES.values()
    with pytest.raises(Exception) as excinfo:  # noqa: PT011 - the code is the assertion
        earthsci_ast.load_path(str(SUITE / fixture["path"]))
    err = excinfo.value
    assert getattr(err, "code", None) == code, f"expected {code!r}, got {err!r}"
    for needle in fixture["message_contains"]:
        assert needle in str(err), f"the diagnostic must name {needle!r}; got: {err}"


def test_emit_keeps_the_authored_string_so_a_move_changes_only_the_location(
    tmp_path: Path,
) -> None:
    fixture = next(f for f in ACCEPTED if f["id"] == "parent_relative")
    first = _load(fixture)
    moved = tmp_path / "moved" / "doc.esm"
    moved.parent.mkdir()
    moved.write_text(earthsci_ast.to_json(first))

    second = earthsci_ast.load_path(str(moved))
    assert _external(second) == fixture["external"]
    assert earthsci_ast.solver_external_location(second) == "file://" + _lexical(
        str(tmp_path / "runs" / "probe.run.json")
    )
    assert earthsci_ast.solver_external_location(first) == _expected_location(fixture["location"])


def test_a_relative_explicit_base_is_taken_against_the_working_directory() -> None:
    loaded = earthsci_ast.load_path(str(SUITE / "fixtures" / "bare_relative.esm"))
    assert earthsci_ast.solver_external_location(loaded, base="a/./b/../c") == (
        "file://" + _lexical(posixpath.join(os.getcwd(), "a/c/runs/probe.run.json"))
    )


def test_a_document_built_in_memory_resolves_against_the_working_directory() -> None:
    from earthsci_ast.esm_types import EsmFile, Metadata, Solver

    f = EsmFile(
        version="1.3.0",
        metadata=Metadata(title="m"),
        solver=Solver(external="runs/x.run.json"),
    )
    assert earthsci_ast.solver_external_location(f) == "file://" + _lexical(
        posixpath.join(os.getcwd(), "runs/x.run.json")
    )
    assert earthsci_ast.solver_external_location(EsmFile(version="1.3.0", metadata=f.metadata)) is (
        None
    )


def test_flatten_does_not_read_external() -> None:
    """esm-spec §2.2.4 requirement 3: the flattened systems are identical."""
    inv = MANIFEST["invariance"]
    with_ext = earthsci_ast.load_path(str(SUITE / inv["with"]))
    without = earthsci_ast.load_path(str(SUITE / inv["without"]))
    assert with_ext.solver is not None and with_ext.solver.external is not None
    assert without.solver is not None and without.solver.external is None

    flat_with = flatten(with_ext, base_path=str(SUITE / "invariance"))
    flat_without = flatten(without, base_path=str(SUITE / "invariance"))
    assert flat_with == flat_without


def test_the_builtin_integrator_choice_ignores_external() -> None:
    """§2.2.6: ``solve()`` MUST NOT change its integrator because of ``external``."""
    from earthsci_ast.inline_tests import _method_for

    inv = MANIFEST["invariance"]
    with_ext = earthsci_ast.load_path(str(SUITE / inv["with"]))
    without = earthsci_ast.load_path(str(SUITE / inv["without"]))
    assert _method_for(None, with_ext) == _method_for(None, without)
