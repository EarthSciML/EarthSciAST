"""A discovered `extent` binds where the NAME is declared, not only at the root.

esm-spec §8.9.4 lets a data source measure its own record count and bind a
metaparameter an index set is sized by. The count arrives as a §9.7.6 site-4
loader-API binding, so these tests bind it directly: `load(..., metaparameters=
{"N_REC": 3})` is exactly what extent discovery hands the loader, and it
exercises the same path without needing a file on disk.

Three separable properties are pinned here:

* the mounting document need not RESTATE a metaparameter the leaf it mounts
  already declares (§9.7.6 site 4, widened past "the root document's");
* the two §4.7 mount forms size the axis IDENTICALLY — the property "Two mount
  forms, one mechanism" states and the one that was silently false, a
  subsystem-mounted leaf having sized its axis at the placeholder default while
  a top-level-mounted one sized it from the data;
* whether a leaf resolves does not turn on an `expression_template_imports`
  entry it never calls.

The fixtures are shared with the other bindings and live under
`tests/fixtures/` rather than `tests/valid/`, because the corpus sweep would
score TypeScript and Go a false pass on the top-level mount form they do not
implement.
"""

import json

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast import load_path

_DIR = FIXTURES_ROOT / "fixtures" / "data_source_extent_scope"


def _records(doc):
    """The merged `records` axis declaration, whatever shape the registry holds."""
    return doc.index_sets["records"]


# ---------------------------------------------------------------------------
# §9.7.6 site 4 reaches a name only a MOUNTED document declares
# ---------------------------------------------------------------------------


def test_a_mounted_leafs_metaparameter_need_not_be_restated_by_the_root():
    """The thin root owns the `data_sources` entry and declares NO
    `metaparameters`; the leaf it mounts declares `N_REC` and is sized by it.

    The discovered extent is a loader-API binding, and the site-4 check used to
    ask only whether the ROOT declared the name — so every assembly had to carry
    a second, identical `metaparameters` block that configured nothing. The check
    now accepts a name declared by any document the root mounts, and the mount
    edge forwards the value into the leaf's own close.
    """
    doc = load_path(str(_DIR / "extent_root_toplevel.esm"), metaparameters={"N_REC": 3})
    assert _records(doc)["size"] == 3


def test_a_loader_api_binding_no_document_declares_is_still_refused():
    """Widening the check must not delete it. A name neither the root nor
    anything it mounts declares is still `template_import_unknown_name` —
    §9.7.6: bindings never invent metaparameters, a typo fails loudly."""
    with pytest.raises(Exception) as excinfo:
        load_path(str(_DIR / "extent_root_toplevel.esm"), metaparameters={"N_RECS": 3})
    assert "template_import_unknown_name" in str(excinfo.value)


# ---------------------------------------------------------------------------
# §4.7 "Two mount forms, one mechanism"
# ---------------------------------------------------------------------------


def test_the_same_leaf_sizes_its_axis_at_either_mount_form():
    """THE ORACLE PIN. Same leaf, same data source, same discovered count; the
    two assemblies differ only in which attachment point mounts the leaf.

    Before, only the top-level `models.<k>` form forwarded the loader-API
    bindings into the leaf's close. A `subsystems.<k>` mount fell through to the
    leaf's own placeholder default, so the axis folded to 0 and the ingested
    field was ZERO-LENGTH — with no diagnostic, a clean validate and a clean
    exit. §4.7 says a binding MUST NOT make the two forms differ; this is the
    test that says so out loud.
    """
    top = load_path(str(_DIR / "extent_root_toplevel.esm"), metaparameters={"N_REC": 3})
    sub = load_path(str(_DIR / "extent_root_subsystem.esm"), metaparameters={"N_REC": 3})
    assert _records(top)["size"] == 3
    assert _records(sub)["size"] == 3, (
        "a subsystem-mounted leaf sized its axis at the placeholder default "
        "while a top-level-mounted one sized it from the data (esm-spec §4.7)"
    )
    assert _records(top) == _records(sub)


# ---------------------------------------------------------------------------
# An UNUSED template import does not decide whether a leaf resolves
# ---------------------------------------------------------------------------


def test_an_unused_template_import_does_not_change_whether_a_leaf_resolves():
    """Two assemblies differing by ONE import of a library the leaf never calls.

    Whether a mounted leaf folded strictly used to be a whole-document boolean
    — does it carry ANY §9.7 machinery — so adding that import flipped the leaf
    from "axis merges symbolically and the assembler closes it" to
    `metaparameter_unbound`. Factoring a shared expression into a library is not
    supposed to change whether a document's shape resolves.

    The assertion is DIFFERENTIAL rather than absolute on purpose: where the
    §4.7 merge sits relative to the mounting document's own §9.7.6 close still
    differs across bindings (RFC `mount-edge-index-set-renaming.md` open question
    2), so the portable contract is that the two spellings agree with each other.
    """
    with_import = load_path(str(_DIR / "assembler_root_with_import.esm"))
    no_import = load_path(str(_DIR / "assembler_root_no_import.esm"))
    assert _records(with_import) == _records(no_import)


# ---------------------------------------------------------------------------
# §8.9.4 statically: an extent nobody declares is refused at `validate`
# ---------------------------------------------------------------------------


def test_an_extent_naming_an_undeclared_metaparameter_is_refused_at_load():
    """`extent` names `N_RECS`; neither the root nor the leaf declares it.

    This used to validate clean and fail only once the source was SAMPLED, at
    build — the same validate/build split §9.7.6's own binding sites had. It is
    decidable from the document alone, so it is decided at load.
    """
    with pytest.raises(Exception) as excinfo:
        load_path(str(_DIR / "extent_undeclared_root.esm"))
    msg = str(excinfo.value)
    assert "template_import_unknown_name" in msg
    assert "N_RECS" in msg


def test_a_declared_extent_still_loads_with_no_loader_bindings():
    """The static check must not refuse the ordinary case: an `extent` whose
    metaparameter the mounted leaf declares loads standalone, at its default,
    with no loader-API bindings at all (§8.9.4: "declare the metaparameter with
    a `default` so the document still validates and loads standalone")."""
    doc = load_path(str(_DIR / "extent_root_toplevel.esm"))
    assert _records(doc)["size"] == 0


def test_a_loader_binding_the_leaf_does_not_declare_is_not_forwarded_to_it():
    """The site-4 backfill is FILTERED to the names the leaf declares, and
    widening the root's check must not loosen that.

    Here the assembler declares `N_REC` and the leaf it mounts declares nothing.
    Forwarding the whole loader-API map into the leaf's close would raise
    `template_import_unknown_name` against a leaf that never asked for the name
    — and, worse, would let an assembler's unrelated metaparameter silently
    resize a leaf axis the edge never bound (esm-spec §4.7).
    """
    doc = load_path(str(_DIR / "assembler_root_with_import.esm"), metaparameters={"N_REC": 5})
    assert doc is not None
    # …and the axis lands at 5 because the ASSEMBLER's own close sized it, not
    # because the leaf was handed the name. The leaf declares no
    # `metaparameters` at all, so `records` merges up still symbolic and the
    # mounting document closes it (§9.7.6 site 5, §4.7 "Index-set merge").
    assert _records(doc)["size"] == 5


def test_an_unrelated_assembler_metaparameter_is_withheld_from_the_leaf():
    """The backfill's PER-NAME filter, tested where it can actually fail.

    The assembler declares `N_OTHER` and the leaf it mounts declares `N_REC`, so
    the loader-API map carries a name the leaf must receive and one it must not.
    A filter that withholds the whole map from a leaf declaring NOTHING looks
    correct against every other fixture here and still lets an assembler's
    unrelated metaparameter through to a leaf that declares something — which is
    how an unbound `NLEV: default 12` silently resizes a leaf axis the edge never
    bound (esm-spec §4.7, the PR #298 precedence invariant).
    """
    doc = load_path(
        str(_DIR / "assembler_partial_overlap_root.esm"),
        metaparameters={"N_REC": 3, "N_OTHER": 7},
    )
    assert _records(doc)["size"] == 3


def test_the_fixtures_say_what_they_are():
    """The shared fixtures are read by four other bindings; a silent edit that
    removed the property under test would leave every suite green."""
    root = json.loads((_DIR / "extent_root_toplevel.esm").read_text())
    assert "metaparameters" not in root, "the root must restate nothing"
    leaf = json.loads((_DIR / "extent_axis_leaf.esm").read_text())
    assert leaf["metaparameters"]["N_REC"]["default"] == 0
    assert leaf["index_sets"]["records"]["size"] == "N_REC"


# ---------------------------------------------------------------------------
# The static check must not refuse what §9.7.6 accepts
# ---------------------------------------------------------------------------


def test_an_extent_naming_a_re_exported_metaparameter_loads():
    """The name reaches this document by §9.7.6 site-2 RE-EXPORT, not by
    declaration and not through a mount.

    The document declares no `metaparameters` and mounts nothing; it IMPORTS a
    library that declares `N_REC` and does not bind it at the edge, so the name
    joins this document's own scope and the loader API may bind it — which is
    exactly what a discovered `extent` does. The static check runs on the
    AUTHORED tree, before the imports resolve, so it has to walk the import
    edges too or it refuses a document §9.7.6 accepts.
    """
    doc = load_path(str(_DIR / "extent_reexport_root.esm"), metaparameters={"N_REC": 3})
    assert _records(doc)["size"] == 3
    # …and standalone, at the library's default, with no bindings at all.
    assert _records(load_path(str(_DIR / "extent_reexport_root.esm")))["size"] == 0


def test_a_resolved_document_reloads():
    """The check is an AUTHORING check and has to be idempotent.

    A §4.7 mount CONSUMES the leaf's `metaparameters` (§9.7.6 site 3), so once
    `extent_root_toplevel.esm` has been resolved, `N_REC` is declared nowhere
    and the `{ref}` stub the mount walk reads is gone — while the `extent` that
    named it is still there, having already done its job. A binding that
    re-loads its own resolved document (Rust does, at build) must not be told
    that document is invalid.
    """
    doc = load_path(str(_DIR / "extent_resolved_shape.esm"))
    assert _records(doc)["size"] == 3


def test_the_idempotency_fixtures_say_what_they_are():
    """Both fixtures above are load-bearing by ABSENCE, which a silent edit
    could restore without any suite going red."""
    reexport = json.loads((_DIR / "extent_reexport_root.esm").read_text())
    assert "metaparameters" not in reexport, "the name must arrive by re-export"
    assert reexport["index_sets"]["records"]["size"] == "N_REC"
    resolved = json.loads((_DIR / "extent_resolved_shape.esm").read_text())
    assert "metaparameters" not in resolved, "a mount consumed the leaf's declaration"
    assert resolved["index_sets"]["records"]["size"] == 3, "already folded"
    assert "ref" not in resolved["models"]["Ingest"], "already inlined"
    assert resolved["data_sources"]["EGU_Emis"]["extent"]["metaparameter"] == "N_REC"
