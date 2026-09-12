//! A discovered `extent` binds where the NAME is declared, not only at the root.
//!
//! esm-spec §8.9.4 lets a data source measure its own record count and bind a
//! metaparameter an index set is sized by. The count arrives as a §9.7.6 site-4
//! loader-API binding, so these tests bind it directly:
//! `load_path_with_options(..., {"N_REC": 3})` is exactly what extent discovery
//! hands the loader, and it exercises the same path without needing a file on
//! disk.
//!
//! Three separable properties are pinned here:
//!
//! * the mounting document need not RESTATE a metaparameter the leaf it mounts
//!   already declares (§9.7.6 site 4, widened past "the root document's");
//! * the two §4.7 mount forms size the axis IDENTICALLY — the property "Two
//!   mount forms, one mechanism" states and the one that was silently false, a
//!   subsystem-mounted leaf having sized its axis at the placeholder default
//!   while a top-level-mounted one sized it from the data;
//! * whether a leaf resolves does not turn on an `expression_template_imports`
//!   entry it never calls.
//!
//! The fixtures are shared with the other bindings and live under
//! `tests/fixtures/` rather than `tests/valid/`, because the corpus sweep would
//! score TypeScript and Go a false pass on the top-level mount form they do not
//! implement. This file is the Rust port of the Python oracle's
//! `tests/test_data_source_extent_scope.py`.

use earthsci_ast::{EsmFile, load_path, load_path_with_options};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// The shared fixture directory, at the repo root (the crate dir's grandparent).
fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root resolves")
        .join("tests/fixtures/data_source_extent_scope")
        .join(name)
}

fn api(pairs: &[(&str, i64)]) -> BTreeMap<String, i64> {
    pairs.iter().map(|(k, v)| ((*k).to_string(), *v)).collect()
}

/// The merged `records` axis's folded size.
fn records_size(doc: &EsmFile) -> Option<i64> {
    doc.index_sets
        .as_ref()
        .expect("the merged registry must carry the leaf's axis")["records"]
        .size
}

/// The whole merged `records` declaration, for the differential assertions.
/// Rendered as JSON because the crate root does not export `IndexSet`.
fn records_decl(doc: &EsmFile) -> serde_json::Value {
    serde_json::to_value(
        &doc.index_sets
            .as_ref()
            .expect("the merged registry must carry the leaf's axis")["records"],
    )
    .expect("an index-set declaration renders as JSON")
}

// ---------------------------------------------------------------------------
// §9.7.6 site 4 reaches a name only a MOUNTED document declares
// ---------------------------------------------------------------------------

/// The thin root owns the `data_sources` entry and declares NO
/// `metaparameters`; the leaf it mounts declares `N_REC` and is sized by it.
///
/// The discovered extent is a loader-API binding, and the site-4 check used to
/// ask only whether the ROOT declared the name — so every assembly had to carry
/// a second, identical `metaparameters` block that configured nothing. The check
/// now accepts a name declared by any document the root mounts, and the mount
/// edge forwards the value into the leaf's own close.
#[test]
fn a_mounted_leafs_metaparameter_need_not_be_restated_by_the_root() {
    let doc = load_path_with_options(fixture("extent_root_toplevel.esm"), &api(&[("N_REC", 3)]))
        .expect("a root that restates nothing must load");
    assert_eq!(records_size(&doc), Some(3));
}

/// Widening the check must not delete it. A name neither the root nor anything
/// it mounts declares is still `template_import_unknown_name` — §9.7.6:
/// bindings never invent metaparameters, a typo fails loudly.
#[test]
fn a_loader_api_binding_no_document_declares_is_still_refused() {
    let e = load_path_with_options(fixture("extent_root_toplevel.esm"), &api(&[("N_RECS", 3)]))
        .expect_err("a name nobody declares is a typo, not a binding");
    let text = e.to_string();
    assert!(
        text.contains("template_import_unknown_name"),
        "the stable §9.7.6 code, not a coercion panic: {text}"
    );
    assert!(
        text.contains("N_RECS"),
        "the diagnostic must name it: {text}"
    );
}

// ---------------------------------------------------------------------------
// §4.7 "Two mount forms, one mechanism"
// ---------------------------------------------------------------------------

/// THE ORACLE PIN. Same leaf, same data source, same discovered count; the two
/// assemblies differ only in which attachment point mounts the leaf.
///
/// Before, only the top-level `models.<k>` form forwarded the loader-API
/// bindings into the leaf's close. A `subsystems.<k>` mount fell through to the
/// leaf's own placeholder default, so the axis folded to 0 and the ingested
/// field was ZERO-LENGTH — with no diagnostic, a clean validate and a clean
/// exit. §4.7 says a binding MUST NOT make the two forms differ; this is the
/// test that says so out loud.
#[test]
fn the_same_leaf_sizes_its_axis_at_either_mount_form() {
    let bindings = api(&[("N_REC", 3)]);
    let top = load_path_with_options(fixture("extent_root_toplevel.esm"), &bindings)
        .expect("the top-level `models.<k>` mount form loads");
    let sub = load_path_with_options(fixture("extent_root_subsystem.esm"), &bindings)
        .expect("the `subsystems.<k>` mount form loads");
    assert_eq!(records_size(&top), Some(3));
    assert_eq!(
        records_size(&sub),
        Some(3),
        "a subsystem-mounted leaf sized its axis at the placeholder default \
         while a top-level-mounted one sized it from the data (esm-spec §4.7)"
    );
    assert_eq!(records_decl(&top), records_decl(&sub));
}

// ---------------------------------------------------------------------------
// An UNUSED template import does not decide whether a leaf resolves
// ---------------------------------------------------------------------------

/// Two assemblies differing by ONE import of a library the leaf never calls.
///
/// Whether a mounted leaf folded strictly used to be a whole-document boolean —
/// does it carry ANY §9.7 machinery — so adding that import flipped the leaf
/// from "axis merges symbolically and the assembler closes it" to
/// `metaparameter_unbound`. Factoring a shared expression into a library is not
/// supposed to change whether a document's shape resolves.
///
/// The assertion is DIFFERENTIAL rather than absolute on purpose: where the §4.7
/// merge sits relative to the mounting document's own §9.7.6 close still differs
/// across bindings (RFC `mount-edge-index-set-renaming.md` open question 2), so
/// the portable contract is that the two spellings agree with each other.
#[test]
fn an_unused_template_import_does_not_change_whether_a_leaf_resolves() {
    let with_import = load_path(fixture("assembler_root_with_import.esm"))
        .expect("a leaf that carries an import it never calls must still resolve");
    let no_import = load_path(fixture("assembler_root_no_import.esm"))
        .expect("and so must the same assembly without the import");
    assert_eq!(
        records_decl(&with_import),
        records_decl(&no_import),
        "an unused `expression_template_imports` entry must not decide the axis"
    );
}

// ---------------------------------------------------------------------------
// §8.9.4 statically: an extent nobody declares is refused at `validate`
// ---------------------------------------------------------------------------

/// `extent` names `N_RECS`; neither the root nor the leaf declares it.
///
/// This used to validate clean and fail only once the source was SAMPLED, at
/// build — the same validate/build split §9.7.6's own binding sites had. It is
/// decidable from the document alone, so it is decided at load.
#[test]
fn an_extent_naming_an_undeclared_metaparameter_is_refused_at_load() {
    let e = load_path(fixture("extent_undeclared_root.esm"))
        .expect_err("an extent nobody declares must not validate clean");
    let text = e.to_string();
    assert!(
        text.contains("template_import_unknown_name"),
        "reuse the §9.7.6 code an unknown name at a binding site already has: {text}"
    );
    assert!(
        text.contains("N_RECS"),
        "the diagnostic must name the typo: {text}"
    );
}

/// The static check must not refuse the ordinary case: an `extent` whose
/// metaparameter the mounted leaf declares loads standalone, at its default,
/// with no loader-API bindings at all (§8.9.4: "declare the metaparameter with a
/// `default` so the document still validates and loads standalone").
#[test]
fn a_declared_extent_still_loads_with_no_loader_bindings() {
    let doc = load_path(fixture("extent_root_toplevel.esm"))
        .expect("the ordinary standalone load must not be refused");
    assert_eq!(records_size(&doc), Some(0));
}

/// The site-4 backfill is FILTERED to the names the leaf declares, and widening
/// the root's check must not loosen that.
///
/// Here the assembler declares `N_REC` and the leaf it mounts declares nothing.
/// Forwarding the whole loader-API map into the leaf's close would raise
/// `template_import_unknown_name` against a leaf that never asked for the name
/// — and, worse, would let an assembler's unrelated metaparameter silently
/// resize a leaf axis the edge never bound (esm-spec §4.7).
#[test]
fn a_loader_binding_the_leaf_does_not_declare_is_not_forwarded_to_it() {
    let doc = load_path_with_options(
        fixture("assembler_root_with_import.esm"),
        &api(&[("N_REC", 5)]),
    )
    .expect("a name the leaf does not declare must never be forwarded into it");
    assert_eq!(
        records_size(&doc),
        Some(5),
        "the assembler's own close sizes the merged axis"
    );
}

/// The shared fixtures are read by four other bindings; a silent edit that
/// removed the property under test would leave every suite green.
#[test]
fn the_fixtures_say_what_they_are() {
    let root: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(fixture("extent_root_toplevel.esm")).unwrap(),
    )
    .unwrap();
    assert!(
        root.get("metaparameters").is_none(),
        "the root must restate nothing"
    );
    let leaf: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(fixture("extent_axis_leaf.esm")).unwrap())
            .unwrap();
    assert_eq!(leaf["metaparameters"]["N_REC"]["default"], 0);
    assert_eq!(leaf["index_sets"]["records"]["size"], "N_REC");
}
