//! The §4.7 edge pipeline at a top-level `models.<k>` `{ref}` mount.
//!
//! "Two mount forms, one mechanism" (esm-spec §4.7) forbids a binding from
//! making the two attachment points differ, and the "Edge pipeline (normative)"
//! paragraph fixes the order: (1) the referenced document resolves in its OWN
//! scope — this edge's `bindings` and §9.7.10 injection, its metaparameter
//! close and fold, the §9.6.3 fixpoint; (2) `index_set_rename` applies to that
//! resolved document; (3) the renamed `index_sets` merge into the mounting
//! registry, deep-equal-or-`subsystem_index_set_conflict`.
//!
//! Rust used to inline this form with a raw pre-pass that deferred all of §9.7
//! to the root, so step (1) never ran and step (3) skipped every axis whose
//! `size` was still a metaparameter expression. These tests pin the closed gap
//! AND the behaviour that must not change with it: the conflict still fires,
//! and the documents that redeclare everything today keep loading unchanged.

use earthsci_ast::load_path;
use std::path::{Path, PathBuf};

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "esm_toplevel_mount_{tag}_{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

fn write(dir: &Path, name: &str, body: &str) -> PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, body).unwrap_or_else(|e| panic!("write {name}: {e}"));
    p
}

/// A leaf whose single axis is sized by the leaf's OWN metaparameter. The rest
/// of the file is the minimum that makes it a loadable component.
const SELF_CONTAINED_LEAF: &str = r#"{
  "esm": "1.0.0",
  "metadata": {"name": "leaf"},
  "metaparameters": {"NLEV": {"type": "integer", "default": 4}},
  "index_sets": {"lev": {"kind": "interval", "size": "NLEV"}},
  "models": {"Column": {
    "variables": {"u": {"type":"unknown","units":"1","shape":["lev"],"default":1.0}},
    "equations": [{"lhs": {"op":"D","args":["u"],"wrt":"t"},
                   "rhs": {"op":"*","args":[-1.0,"u"]}}]}}}"#;

/// Step (1) + (3): §9.7.5's promise, "the importing model's variables may be
/// shaped over the mesh file's axes WITHOUT redeclaring them, the mesh file
/// stays the source of truth for its own sizes". The importer declares no
/// `index_sets` at all and the leaf's axis arrives folded to the LEAF's own
/// default, not skipped and not resolved in the root's scope.
#[test]
fn leaf_metaparameter_sized_axis_folds_at_the_edge_and_merges() {
    let dir = scratch("fold");
    write(&dir, "leaf.esm", SELF_CONTAINED_LEAF);
    let host = write(
        &dir,
        "host.esm",
        r#"{"esm":"1.0.0","metadata":{"name":"host"},
            "models":{"M":{"ref":"./leaf.esm"}}}"#,
    );

    let f = load_path(&host).expect("the importer must not have to redeclare the leaf's axis");
    let isets = f.index_sets.as_ref().expect("index_sets");
    assert_eq!(isets["lev"].size, Some(4));

    let _ = std::fs::remove_dir_all(&dir);
}

/// Step (1), §9.7.6 binding site 3: the edge's `bindings` close the leaf's
/// metaparameters, so the merged axis takes the ASSEMBLER's size. Before the
/// edge ran the close, `bindings` at this mount form were read by nobody.
#[test]
fn edge_bindings_close_the_leaf_at_a_toplevel_mount() {
    let dir = scratch("bindings");
    write(&dir, "leaf.esm", SELF_CONTAINED_LEAF);
    let host = write(
        &dir,
        "host.esm",
        r#"{"esm":"1.0.0","metadata":{"name":"host"},
            "models":{"M":{"ref":"./leaf.esm","bindings":{"NLEV":9}}}}"#,
    );

    let f = load_path(&host).expect("edge bindings must close the leaf");
    assert_eq!(
        f.index_sets.as_ref().expect("index_sets")["lev"].size,
        Some(9),
        "the edge's `bindings` must beat the leaf's own default"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// FALSIFICATION 1 — the merge must not become permissive. A mounted leaf whose
/// axis collides non-deep-equal with the importer's own declaration is still a
/// load-time `subsystem_index_set_conflict` naming both contributors and the
/// `index_set_rename` remedy (esm-spec §4.7, §9.6.6). The collision is now
/// reachable on an axis it could not reach before: one the edge just FOLDED.
#[test]
fn a_folded_leaf_axis_still_collides_loudly() {
    let dir = scratch("conflict");
    write(&dir, "leaf.esm", SELF_CONTAINED_LEAF);
    let host = write(
        &dir,
        "host.esm",
        r#"{"esm":"1.0.0","metadata":{"name":"host"},
            "index_sets":{"lev":{"kind":"interval","size":59}},
            "models":{"M":{"ref":"./leaf.esm"}}}"#,
    );

    let e = load_path(&host).expect_err("a size disagreement must fail at load, not silently win");
    let text = e.to_string();
    assert!(
        text.contains("subsystem_index_set_conflict"),
        "stable code required: {text}"
    );
    for needle in ["size=4", "size=59", "index_set_rename"] {
        assert!(
            text.contains(needle),
            "the diagnostic must name both contributors and the remedy ({needle}): {text}"
        );
    }

    let _ = std::fs::remove_dir_all(&dir);
}

/// FALSIFICATION 2 — backward compatibility, the case that matters most. A leaf
/// that is NOT self-contained (its axes are sized by names only the assembler
/// declares) has no metaparameters to close, so nothing folds at the edge and
/// the symbolic `size` merges up for the ROOT's close to resolve. That is the
/// shape of every verbose assembly written against the old behaviour: it must
/// keep loading whether it restates the leaf's axes byte-identically or not,
/// and both spellings must produce the same registry.
#[test]
fn an_assembler_scoped_axis_merges_symbolically_with_or_without_restatement() {
    let dir = scratch("compat");
    write(
        &dir,
        "leaf.esm",
        r#"{
  "esm": "1.0.0",
  "metadata": {"name": "leaf"},
  "index_sets": {"rows": {"kind": "interval", "size": "n_rows"}},
  "models": {"Census": {
    "variables": {"u": {"type":"unknown","units":"1","shape":["rows"],"default":1.0}},
    "equations": [{"lhs": {"op":"D","args":["u"],"wrt":"t"},
                   "rhs": {"op":"*","args":[-1.0,"u"]}}]}}}"#,
    );
    // The verbose spelling: the assembler restates the leaf's axis, byte for
    // byte, exactly as the 500-line hand-written mounts do today.
    let verbose = write(
        &dir,
        "verbose.esm",
        r#"{"esm":"1.0.0","metadata":{"name":"verbose"},
            "metaparameters":{"n_rows":{"type":"integer","default":7}},
            "index_sets":{"rows":{"kind":"interval","size":"n_rows"}},
            "models":{"M":{"ref":"./leaf.esm"}}}"#,
    );
    // The terse spelling: the same document with the restatement deleted.
    let terse = write(
        &dir,
        "terse.esm",
        r#"{"esm":"1.0.0","metadata":{"name":"terse"},
            "metaparameters":{"n_rows":{"type":"integer","default":7}},
            "models":{"M":{"ref":"./leaf.esm"}}}"#,
    );

    let a = load_path(&verbose).expect("today's verbose-but-correct document must keep loading");
    let b = load_path(&terse).expect("and the restatement must be deletable");
    assert_eq!(a.index_sets.as_ref().expect("index_sets")["rows"].size, Some(7));
    assert_eq!(
        serde_json::to_value(a.index_sets.as_ref()).expect("json"),
        serde_json::to_value(b.index_sets.as_ref()).expect("json"),
        "restating a leaf's axis must be exactly idempotent"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// FALSIFICATION 3 — round trip (esm-spec §4.7 "Round trip"). A mount edge is
/// consumed at load, so `bindings` / `index_set_rename` must not survive
/// `parse → emit`, and `emit ∘ load` must be a byte-wise fixed point: the
/// emitted document carries the inlined component with its axes already spelled
/// under the post-rename names, so a second load has no edge left to rename.
#[test]
fn a_consumed_mount_edge_round_trips_to_a_fixed_point() {
    let dir = scratch("roundtrip");
    write(&dir, "leaf.esm", SELF_CONTAINED_LEAF);
    let host = write(
        &dir,
        "host.esm",
        r#"{"esm":"1.0.0","metadata":{"name":"host"},
            "models":{"M":{"ref":"./leaf.esm","bindings":{"NLEV":6},
                           "index_set_rename":{"lev":"soil.lev"}}}}"#,
    );

    let first = load_path(&host).expect("mount with both edge fields loads");
    let emitted = serde_json::to_string_pretty(&first).expect("emit");
    assert!(
        !emitted.contains("index_set_rename") && !emitted.contains("\"bindings\""),
        "an edge field must not survive parse → emit: {emitted}"
    );
    assert!(
        emitted.contains("soil.lev") && !emitted.contains("\"lev\""),
        "the emitted document must spell the axis post-rename: {emitted}"
    );

    let again = write(&dir, "again.esm", &emitted);
    let second = load_path(&again).expect("the emitted document must load");
    assert_eq!(
        emitted,
        serde_json::to_string_pretty(&second).expect("emit"),
        "emit ∘ load must be a byte-wise fixed point"
    );
    assert_eq!(
        second.index_sets.as_ref().expect("index_sets")["soil.lev"].size,
        Some(6)
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// The strictness boundary the close introduces, pinned so it is visible rather
/// than discovered. §9.7.6 site 3 resolves a mounted leaf "as a complete
/// document and folded to concrete integers at the mount", so the leaf's OWN
/// close is strict: once the leaf has any §9.7 machinery to resolve, an axis
/// sized by a name the leaf does not declare is `metaparameter_unbound` at the
/// edge — it never reaches the mounting document's close. A leaf with NO
/// machinery has no close to be strict about, so the same size merges
/// symbolically (the test above). Both behaviours match Python and match this
/// binding's own `subsystems.<k>` edge, which is what §4.7 requires; whether
/// the edge close SHOULD be strict about a name only the assembler can bind is
/// a spec question, not a divergence.
#[test]
fn a_leaf_with_machinery_is_strict_about_an_assembler_scoped_size() {
    let dir = scratch("strict");
    write(
        &dir,
        "leaf.esm",
        r#"{
  "esm": "1.0.0",
  "metadata": {"name": "leaf"},
  "metaparameters": {"UNRELATED": {"type": "integer", "default": 1}},
  "index_sets": {"rows": {"kind": "interval", "size": "n_rows"}},
  "models": {"Census": {
    "variables": {"u": {"type":"unknown","units":"1","shape":["rows"],"default":1.0}},
    "equations": [{"lhs": {"op":"D","args":["u"],"wrt":"t"},
                   "rhs": {"op":"*","args":[-1.0,"u"]}}]}}}"#,
    );
    let host = write(
        &dir,
        "host.esm",
        r#"{"esm":"1.0.0","metadata":{"name":"host"},
            "metaparameters":{"n_rows":{"type":"integer","default":7}},
            "models":{"M":{"ref":"./leaf.esm"}}}"#,
    );

    let e = load_path(&host).expect_err("the leaf's own close is strict");
    assert!(
        e.to_string().contains("metaparameter_unbound")
            && e.to_string().contains("n_rows"),
        "a proper diagnostic, not an i64 coercion panic: {e}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}
