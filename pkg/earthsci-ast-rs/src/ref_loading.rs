//! Subsystem reference loading: cross-FILE `{ "ref": ... }` inlining.
//!
//! Not to be confused with [`crate::reference_resolution`], which builds the
//! intra-document node-id / index-set dependency DAG — this module is the
//! load-time pass that splices other .esm files into this one.
//!
//! Implements ESM library spec section 2.1b: walks all `subsystems` maps in
//! models and reaction systems, and replaces any `{ "ref": "..." }` reference
//! object with the resolved content of the referenced ESM file. Local file
//! references are resolved relative to a base path and cycles are detected.
//!
//! HTTP(S) URL references are recognised but not fetched in the Rust loader,
//! since this crate does not depend on an HTTP client. Callers that need
//! remote refs should download the file first and rewrite the ref to a local
//! path. URL refs raise a clear error rather than being silently ignored.
//!
//! Resolution operates on raw [`serde_json::Value`] before typed coercion to
//! [`crate::EsmFile`], because the typed model intentionally does not store
//! the `subsystems` map (it would force every consumer of `Model` /
//! `ReactionSystem` to handle nested-by-default systems). Resolving at the
//! JSON layer means refs are inlined into the parsed value, and the typed
//! model only ever sees fully resolved input.

use crate::diagnostic::{DiagnosticError, codes, err};
use serde_json::{Map, Value};
use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::{Path, PathBuf};

/// Capture a document's closed metaparameter environment from its top-level
/// `metaparameters` block: each name's integer `default`, overlaid with the
/// loader-API `api_meta` bindings (esm-spec §9.7.6 sites 4-5). This is the
/// scope against which a §4.7 subsystem-edge binding EXPRESSION folds at the
/// mount (e.g. `NTGT = NX*NY`), captured BEFORE the root template-machinery
/// pass consumes the `metaparameters` block. Mirrors the Python `load_string()`
/// `root_meta_env`.
pub(crate) fn root_metaparameter_env(
    value: &Value,
    api_meta: &BTreeMap<String, i64>,
) -> BTreeMap<String, i64> {
    let mut env: BTreeMap<String, i64> = BTreeMap::new();
    if let Some(decls) = value.get("metaparameters").and_then(|v| v.as_object()) {
        for (name, decl) in decls {
            if let Some(d) = decl.get("default")
                && d.as_i64().is_some()
                && !d.is_boolean()
            {
                env.insert(name.clone(), d.as_i64().expect("checked integer default"));
            }
        }
    }
    for (k, v) in api_meta {
        env.insert(k.clone(), *v);
    }
    env
}

/// Resolve all subsystem references in a parsed JSON value representing an
/// ESM file.
///
/// Walks every `subsystems` map in models and reaction systems and inlines
/// the referenced content. Resolution is recursive (referenced files may
/// contain their own refs) and circular references are detected.
///
/// A referenced subsystem file's top-level `index_sets` merge into the
/// importing document's registry (esm-spec §4.7, mirroring the §9.7.5
/// template-import merge): deep-equal redeclaration is idempotent, an absent
/// name is added, and a non-deep-equal collision is `subsystem_index_set_conflict`.
/// The merge is scoped to MODEL mounts, matching the Julia resolver (a mounted
/// mesh file whose axis size disagrees with the importer must fail at load
/// rather than the importer silently winning) — and it applies to BOTH model
/// mount forms: a `subsystems.<k>` ref and a top-level `models.<k>` ref
/// ([`inline_toplevel_refs`]) merge identically.
///
/// # Arguments
///
/// * `value` - the parsed ESM JSON to resolve (modified in place)
/// * `base_path` - directory to resolve relative file paths against
///
/// This is the raw-`serde_json::Value` extension seam (API_SPEC.md §8 item
/// 14): it is what the LOADER runs, before the document is coerced to an
/// [`crate::EsmFile`]. A caller holding a typed document wants
/// [`resolve_subsystem_refs`].
pub fn resolve_subsystem_refs_raw(
    value: &mut Value,
    base_path: &Path,
) -> Result<(), DiagnosticError> {
    let staged = resolve_subsystem_refs_with_metaparameters(value, base_path, &BTreeMap::new())?;
    // This seam has no §9.7.6 close of its own to defer past — it IS just ref
    // resolution — so the staged §4.7 contributions land immediately.
    apply_staged_index_sets(value, staged, &BTreeMap::new())
}

/// Merge the §4.7 contributions a deferred root walk STAGED into the mounting
/// document's registry (esm-spec §4.7 "Index-set merge").
///
/// The other half of the inline/merge split: `walk_top_level` spliced the
/// referenced content in early, so the root's own §9.7 machinery can lower
/// through it, and held the `index_sets` back until the mounting document had
/// closed. This is where they arrive, compared deep-equal against a registry
/// whose own sizes the close has already folded.
pub(crate) fn apply_staged_index_sets(
    value: &mut Value,
    staged: Map<String, Value>,
    env: &BTreeMap<String, i64>,
) -> Result<(), DiagnosticError> {
    if staged.is_empty() {
        return Ok(());
    }
    let Some(obj) = value.as_object_mut() else {
        return Ok(());
    };
    let mut registry: Map<String, Value> = obj
        .get("index_sets")
        .and_then(|v| v.as_object())
        .cloned()
        .unwrap_or_default();
    merge_subsystem_index_sets(&mut registry, &staged, "a §4.7 mount", env)?;
    obj.insert("index_sets".to_string(), Value::Object(registry));
    Ok(())
}

/// Resolve every subsystem `{ "ref": ... }` in a TYPED document, in place.
///
/// The canonical entry point (API_SPEC.md §8 item 14): Julia
/// (`resolve_subsystem_refs!`), Python and TypeScript all take a typed
/// document and mutate it; this binding alone took an untyped
/// `serde_json::Value`. Implemented over [`resolve_subsystem_refs_raw`] —
/// `file` is rendered to JSON, resolved, and read back — so the two agree by
/// construction.
///
/// # Arguments
///
/// * `file` - the document to resolve (modified in place)
/// * `base_path` - directory to resolve relative file paths against
pub fn resolve_subsystem_refs(
    file: &mut crate::EsmFile,
    base_path: &Path,
) -> Result<(), DiagnosticError> {
    let mut value = serde_json::to_value(&*file).map_err(|e| {
        err(
            codes::UNRESOLVED_SUBSYSTEM_REF,
            format!("could not render the document as JSON for ref resolution: {e}"),
        )
    })?;
    resolve_subsystem_refs_raw(&mut value, base_path)?;
    *file = serde_json::from_value(value).map_err(|e| {
        err(
            codes::UNRESOLVED_SUBSYSTEM_REF,
            format!("resolved document did not deserialize back into an EsmFile: {e}"),
        )
    })?;
    Ok(())
}

/// Like [`resolve_subsystem_refs_raw`], but with the loader-API metaparameter
/// bindings (esm-spec §9.7.6 site 4) available, so a §4.7 subsystem-edge
/// binding EXPRESSION (`NTGT = NX*NY`, §9.7.6 site 3) folds against the root
/// document's closed metaparameter environment (defaults overlaid with the API
/// bindings) at the mount. Mirrors the Python `resolve_model_refs(...,
/// parent_metaparameters=root_meta_env)`.
pub fn resolve_subsystem_refs_with_metaparameters(
    value: &mut Value,
    base_path: &Path,
    api_meta: &BTreeMap<String, i64>,
) -> Result<Map<String, Value>, DiagnosticError> {
    let root_meta = root_metaparameter_env(value, api_meta);
    let mut visited = HashSet::new();
    walk_top_level(
        value,
        &DocScope {
            base_path,
            parent_meta: &root_meta,
            api_meta,
            forwarded: &BTreeMap::new(),
            caller_env: &root_meta,
            enclosing_precision: DEFAULT_ELEMENT_TYPE,
        },
        &mut visited,
        true,
    )
}

/// A one-line rendering of an index-set declaration for the collision message
/// — `kind=interval, size=59` — so the diagnostic names both definitions rather
/// than only the axis they disagree about. Mirrors the Julia `_index_set_show`.
fn show_index_set(decl: &Value) -> String {
    let Some(obj) = decl.as_object() else {
        return decl.to_string();
    };
    let parts: Vec<String> = [
        "kind", "size", "members", "of", "offsets", "values", "from_faq", "records",
    ]
    .iter()
    .filter_map(|k| obj.get(*k).map(|v| format!("{k}={v}")))
    .collect();
    if parts.is_empty() {
        decl.to_string()
    } else {
        parts.join(", ")
    }
}

/// Are two raw index-set declarations the same declaration (esm-spec §4.7
/// "Index-set merge")? Structural JSON equality, except that `"records": false`
/// and an absent `records` are one declaration (esm-spec §8.5.1), so a mount
/// that spells the default out never conflicts with one that leaves it out.
/// `"records": true` against either is a real disagreement.
pub(crate) fn index_set_decls_equal(a: &Value, b: &Value) -> bool {
    fn records_flag(v: &Value) -> bool {
        v.get("records").and_then(Value::as_bool) == Some(true)
    }
    match (a.as_object(), b.as_object()) {
        (Some(x), Some(y)) => {
            fn rest(m: &Map<String, Value>) -> BTreeMap<&str, &Value> {
                m.iter()
                    .filter(|(k, _)| k.as_str() != "records")
                    .map(|(k, v)| (k.as_str(), v))
                    .collect()
            }
            records_flag(a) == records_flag(b) && rest(x) == rest(y)
        }
        _ => a == b,
    }
}

/// Merge a referenced subsystem file's top-level `index_sets` into the
/// importing document's `registry` (esm-spec §4.7). Deep-equal redeclaration is
/// idempotent; a non-deep-equal collision is `subsystem_index_set_conflict`.
/// Deep equality is [`index_set_decls_equal`]: order-independent structural
/// equality, with `"records": false` the same as an absent `records`.
fn merge_subsystem_index_sets(
    registry: &mut Map<String, Value>,
    loaded: &Map<String, Value>,
    ref_str: &str,
    env: &BTreeMap<String, i64>,
) -> Result<(), DiagnosticError> {
    for (n, raw) in loaded {
        // esm-spec §4.7 "Index-set merge": fold the incoming contribution
        // against the MOUNTING document's closed environment before comparing.
        // Two IDENTICAL declarations, one folded and one not, are otherwise a
        // `subsystem_index_set_conflict` — issue #198.
        let owned = crate::template_imports::fold_mount_contribution(raw, env);
        let decl = &owned;
        if let Some(existing) = registry.get(n) {
            if !index_set_decls_equal(existing, decl) {
                return Err(err(
                    codes::SUBSYSTEM_INDEX_SET_CONFLICT,
                    format!(
                        "index set '{n}' from subsystem ref '{ref_str}' ({}) collides with a \
                         non-deep-equal declaration already in the importing document's registry \
                         ({}) — contributed by the document's own `index_sets` or by an earlier \
                         mount. A referenced subsystem file's top-level index_sets merge into the \
                         importing document's registry; deep-equal redeclaration is idempotent, a \
                         size/kind disagreement is a load-time error (esm-spec §4.7). If the two \
                         are genuinely different axes that happen to share a name, rename one at \
                         its mount edge with `index_set_rename` (esm-spec §4.7 \"Mount-edge \
                         index-set renaming\"), e.g. \
                         {{\"ref\": \"{ref_str}\", \"index_set_rename\": {{\"{n}\": \"{n}_2\"}}}}.",
                        show_index_set(decl),
                        show_index_set(existing),
                    ),
                ));
            }
        } else {
            registry.insert(n.clone(), decl.clone());
        }
    }
    Ok(())
}

/// Wording for [`load_ref_document`]'s diagnostics, so each call site keeps its
/// original error strings while sharing the load sequence.
struct RefNoun {
    /// Plural noun for the remote-URL rejection (e.g. `"subsystem refs"`).
    remote_plural: &'static str,
    /// Singular noun for the cycle message (e.g. `"subsystem reference"`).
    cycle_singular: &'static str,
    /// Item noun for the resolve / read / parse messages (e.g. `"ref"`).
    item: &'static str,
    /// Stable diagnostic code for this ref-kind's load/shape failures.
    code: &'static str,
}

/// A subsystem `{ "ref": ... }` edge (used by [`resolve_value`]).
///
/// `code` is the settled cross-binding name for a subsystem ref that cannot be
/// resolved (a missing file, a remote URL, a cycle, an unreadable document); the
/// distinct "resolved, but the file does not contain exactly one system" case is
/// [`AMBIGUOUS_SUBSYSTEM_REF`]. Both names are pinned by
/// `tests/invalid/expected_errors.json`.
const SUBSYSTEM_REF: RefNoun = RefNoun {
    remote_plural: "subsystem refs",
    cycle_singular: "subsystem reference",
    item: "ref",
    code: codes::UNRESOLVED_SUBSYSTEM_REF,
};

/// A subsystem ref that resolved to a file containing MULTIPLE (or zero)
/// top-level systems — the ref mechanism requires exactly one, so which system
/// to mount is ambiguous. Distinct from a ref that could not be resolved at all.
const AMBIGUOUS_SUBSYSTEM_REF: &str = codes::AMBIGUOUS_SUBSYSTEM_REF;

/// A top-level `models.<k>` mount edge (used by [`inline_toplevel_refs`]).
/// Its unresolved code is the generic `unresolved_subsystem_ref`, as at the
/// `reaction_systems.<k>` form: the Julia reference raises its
/// `SubsystemRefError` at both forms (esm-spec §4.7 "Two mount forms, one
/// mechanism").
const TOPLEVEL_MODEL_REF: RefNoun = RefNoun {
    remote_plural: "top-level model refs",
    cycle_singular: "top-level model reference",
    item: "top-level model ref",
    code: codes::UNRESOLVED_SUBSYSTEM_REF,
};

/// A top-level `reaction_systems.<k>` mount edge. Its unresolved code is the
/// generic `unresolved_subsystem_ref`, which is what the Julia reference raises
/// at this form (its `SubsystemRefError`).
const TOPLEVEL_REACTION_SYSTEM_REF: RefNoun = RefNoun {
    remote_plural: "top-level reaction system refs",
    cycle_singular: "top-level reaction system reference",
    item: "top-level reaction system ref",
    code: codes::UNRESOLVED_SUBSYSTEM_REF,
};

/// One of the two top-level attachment points of a §4.7 `{ref}` mount: a
/// `models.<k>` or a `reaction_systems.<k>` entry. esm-spec §4.7 "Two mount
/// forms, one mechanism": the two run the SAME edge pipeline and differ only in
/// which block the leaf's component is taken from and spliced into, so
/// [`inline_toplevel_refs`] is written once over this descriptor.
struct TopLevelMountForm {
    /// The top-level block the entry lives in, and the leaf's block the
    /// component is extracted from.
    block: &'static str,
    /// The key whose presence marks an entry as an INLINE component rather
    /// than a bare `{ref}` stub (Julia's discriminator: `variables` for a
    /// model, `species` for a reaction system).
    inline_key: &'static str,
    /// The edge's optional selector naming one component of a multi-component
    /// leaf.
    selector: &'static str,
    /// `"model"` / `"reaction system"`, for diagnostics.
    noun: &'static str,
    /// The capitalized noun, for diagnostics that start a sentence.
    noun_cap: &'static str,
    ref_noun: &'static RefNoun,
}

const MODEL_MOUNT: TopLevelMountForm = TopLevelMountForm {
    block: "models",
    inline_key: "variables",
    selector: "model",
    noun: "model",
    noun_cap: "Model",
    ref_noun: &TOPLEVEL_MODEL_REF,
};

const REACTION_SYSTEM_MOUNT: TopLevelMountForm = TopLevelMountForm {
    block: "reaction_systems",
    inline_key: "species",
    selector: "reaction_system",
    noun: "reaction system",
    noun_cap: "Reaction system",
    ref_noun: &TOPLEVEL_REACTION_SYSTEM_REF,
};

/// A mount edge's diagnostic for a ref [`crate::ref_reader`] could not read.
fn ref_read_error(
    e: crate::ref_reader::RefError,
    ref_str: &str,
    noun: &RefNoun,
) -> DiagnosticError {
    use crate::ref_reader::RefError;
    match e {
        RefError::Bundled(why) => err(
            noun.code,
            format!("failed to resolve {} {ref_str:?}: {why}", noun.item),
        ),
        RefError::Remote => err(
            noun.code,
            format!(
                "Remote {} are not supported in the Rust loader; \
             download {ref_str:?} to a local file first",
                noun.remote_plural
            ),
        ),
        RefError::Missing { err: e, .. } => err(
            noun.code,
            format!("failed to resolve {} {ref_str:?}: {e}", noun.item),
        ),
        RefError::Read { path, err: e } => err(
            noun.code,
            format!("failed to read {} {}: {e}", noun.item, path.display()),
        ),
        RefError::Parse { path, err: e } => err(
            noun.code,
            format!("failed to parse {} {}: {e}", noun.item, path.display()),
        ),
    }
}

/// Load a document a §4.7 mount edge references: locate and read it through
/// [`crate::ref_reader`] (which owns `${VAR}` expansion, the bundled standard
/// library, the remote refusal and file identity), guard against a cycle, mark
/// it visited, then open it ([`crate::ref_reader::open`]: the wire treatment
/// and the version gates a mounted file gets).
/// Returns the file's identity (still marked visited) and the parsed JSON.
///
/// On success the CALLER owns the visited mark: it recurses into the loaded
/// document (so nested refs see this path on the stack) and must
/// `visited.remove(&canonical)` when done. On any failure here the mark is not
/// left dangling (it is removed before returning a read/parse error, and is
/// never inserted on the locate / cycle errors).
fn load_ref_document(
    ref_str: &str,
    base: &Path,
    visited: &mut HashSet<PathBuf>,
    noun: &RefNoun,
) -> Result<(PathBuf, Value), DiagnosticError> {
    let expanded = crate::ref_reader::expand(ref_str);
    let ref_str: &str = &expanded;
    let read_error = |e| ref_read_error(e, ref_str, noun);
    let located = crate::ref_reader::locate(ref_str, base).map_err(read_error)?;
    let canonical = located.identity.clone();

    if visited.contains(&canonical) {
        return Err(err(
            noun.code,
            format!(
                "circular {} detected: {}",
                noun.cycle_singular,
                canonical.display()
            ),
        ));
    }
    visited.insert(canonical.clone());

    // A REFERENCED document is a document: it gets the root's wire-boundary
    // treatment (without it a removed op would survive a `{ref}` into `emit`,
    // docs/content/rfcs/faq-node-rename.md §5.2), and it is held to its own
    // `esm` version by every gate that applies to it (§4.7 "Each file is held
    // to its own declared `esm` version"), never the mounting document's. The
    // `solver` gate (§2.2.4) is among them: a leaf's block does not cross the
    // mount edge, but it must still be legal in the file that carries it.
    let loaded = crate::ref_reader::open(&located, crate::version_gates::DocKind::MountedLeaf)
        .map_err(|e| match e {
            crate::ref_reader::OpenError::Ref(e) => read_error(e),
            crate::ref_reader::OpenError::Wire(e) => {
                err(noun.code, format!("{}: {e}", canonical.display()))
            }
            crate::ref_reader::OpenError::Gate(e) => {
                err(e.code, format!("{}: {}", canonical.display(), e.message))
            }
        });

    match loaded {
        Ok(parsed) => Ok((canonical, parsed)),
        Err(e) => {
            // Read/parse failed after we marked it visited — un-mark so the set
            // is not left with a dangling entry.
            visited.remove(&canonical);
            Err(e)
        }
    }
}

/// The index-set names a document's top-level registry holds right now.
fn index_set_names(value: &Value) -> std::collections::BTreeSet<String> {
    value
        .get("index_sets")
        .and_then(|v| v.as_object())
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default()
}

/// A metaparameter environment: name to closed integer value.
type MetaEnv = BTreeMap<String, i64>;

/// What a document being walked for mount edges inherits from the scope that
/// loads it. Built once at the root ([`resolve_subsystem_refs_with_metaparameters`])
/// and once per mount edge ([`resolve_mount_edge`]).
struct DocScope<'a> {
    /// The directory this document's relative refs resolve against.
    base_path: &'a Path,
    /// The closed environment this document's edge `bindings` expressions
    /// fold against.
    parent_meta: &'a MetaEnv,
    /// The loader-API bindings (§9.7.6 site 4); they reach every depth.
    api_meta: &'a MetaEnv,
    /// Edge bindings forwarded through an assembly (§4.7 "Bindings reach
    /// through an assembly"); see [`close_mount_edge`].
    forwarded: &'a MetaEnv,
    /// The edge `bindings` that closed this document (the root's own
    /// environment at depth zero), overlaid on its declared defaults to form
    /// the fold environment of its registry.
    caller_env: &'a MetaEnv,
    /// The precision of the document mounting this one.
    enclosing_precision: &'a str,
}

/// The scope every mount edge a document carries resolves under: the
/// document's directory, the environments that reach its edges, and the two
/// facts [`walk_top_level`] derives for the document itself.
struct MountScope<'a> {
    /// The MOUNTING document's directory.
    base_path: &'a Path,
    parent_meta: &'a MetaEnv,
    api_meta: &'a MetaEnv,
    forwarded: &'a MetaEnv,
    /// The mounting document's own closed environment, which a contribution
    /// landing in its registry folds against.
    merge_env: &'a MetaEnv,
    /// The mounting document's effective working precision.
    precision: &'a str,
}

fn walk_top_level(
    value: &mut Value,
    doc: &DocScope<'_>,
    visited: &mut HashSet<PathBuf>,
    defer: bool,
) -> Result<Map<String, Value>, DiagnosticError> {
    // esm-spec §4.7 "Working precision crosses a mount": THIS document's
    // effective precision is its own `domain.element_type`, else the one it
    // inherits from the document mounting it (`"Float64"` at a root). Every
    // edge this document carries compares its leaf's declaration against it.
    let precision = effective_element_type(value, doc.enclosing_precision);
    // esm-spec §4.7 "Which environment a contribution folds against": the
    // registry a contribution lands in here belongs to THIS document, so the
    // fold environment is this document's own CLOSED one — not the caller's.
    //
    // Closed means the edge `bindings` that closed this document are part of it,
    // overlaid on its own `default`s: §9.7.6 site 3 says an explicit edge binding
    // wins over the referenced document's default. `caller_env` carries them in.
    // Filtered to the names this document DECLARES, which is the same filter
    // site 4 applies to the backfill — an outer metaparameter this document
    // never declared must not size an axis here. At depth zero the overlay is a
    // no-op: `caller_env` IS this environment there.
    //
    // Without it one resolved document disagrees with ITSELF: an axis the
    // document declares goes through `resolve_template_machinery` with the edge
    // bindings and folds to 7, while an axis contributed by its own nested mount
    // would fold against the unoverlaid defaults and come out 4.
    let merge_env = {
        let mut env = root_metaparameter_env(value, doc.api_meta);
        let declared: Vec<String> = value
            .get("metaparameters")
            .and_then(|v| v.as_object())
            .map(|o| o.keys().cloned().collect())
            .unwrap_or_default();
        for (k, v) in doc.caller_env {
            if declared.contains(k) {
                env.insert(k.clone(), *v);
            }
        }
        env
    };
    let scope = MountScope {
        base_path: doc.base_path,
        parent_meta: doc.parent_meta,
        api_meta: doc.api_meta,
        forwarded: doc.forwarded,
        merge_env: &merge_env,
        precision: &precision,
    };
    let obj = match value.as_object_mut() {
        Some(o) => o,
        None => return Ok(Map::new()),
    };

    // esm-spec §4.7 / §9.7.10: a top-level `models.<k>` that is a bare `{ref}`
    // (a string `ref`, no inline `variables`) is a model-ref MOUNT EDGE — splice in
    // the referenced leaf's single model, carrying the edge's
    // `expression_template_imports` into that model's own scope, BEFORE the
    // ordinary subsystem walk (the spliced model may itself carry subsystems).
    // The leaf resolves in its OWN scope at the edge ([`resolve_mount_edge`],
    // the same pipeline a `subsystems.<k>` ref runs), so BOTH environments are
    // threaded in, and they are NOT interchangeable: edge `bindings` fold
    // against `parent_meta` (the mounting document's full closed environment),
    // while only `api_meta` — the loader-API bindings, §9.7.6 site 4 —
    // backfills the leaf's own close.
    // `defer` splits INLINING from MERGING (esm-spec §4.7). The content must be
    // spliced in HERE, before the root's own §9.7 machinery, so a rewrite target
    // inside a mounted component lowers at all; but the `index_sets` it
    // contributes must not join the registry until the mounting document has
    // CLOSED (§9.7.6 site 3: "subsystem refs resolve post-close"). At the root
    // the contributions are therefore collected and handed back for
    // `parse::load_value` to merge after the close; nested scopes have already
    // closed by the time they get here and merge in place.
    //
    // A top-level `reaction_systems.<k>` `{ref}` (a string `ref` and no `species`) is
    // the same edge at the other attachment point, and runs the same pipeline
    // (§4.7 "Two mount forms, one mechanism"). Models first, then reaction
    // systems, so the two forms' contributions stage in a fixed order.
    let mut staged: Map<String, Value> = Map::new();
    for form in [&MODEL_MOUNT, &REACTION_SYSTEM_MOUNT] {
        inline_toplevel_refs(
            form,
            obj,
            &scope,
            visited,
            if defer { Some(&mut staged) } else { None },
        )?;
    }

    // The importing document's index-set registry starts from its own
    // top-level `index_sets` — already carrying whatever the top-level model
    // mounts above merged in, since they run first — and model subsystem refs
    // merge theirs into it (esm-spec §4.7). Reaction-system subsystem refs do
    // NOT merge (Julia resolver scope), so they thread `None`.
    // When deferring, the registry starts EMPTY and the document's own
    // `index_sets` are left alone: they are the mounting document's to close,
    // and the contributions are compared against them only afterwards.
    let mut registry: Map<String, Value> = if defer {
        staged
    } else {
        obj.get("index_sets")
            .and_then(|v| v.as_object())
            .cloned()
            .unwrap_or_default()
    };

    if let Some(map) = obj.get_mut("models").and_then(|v| v.as_object_mut()) {
        for (_name, system) in map.iter_mut() {
            walk_subsystems(system, &scope, visited, Some(&mut registry))?;
        }
    }
    if let Some(map) = obj
        .get_mut("reaction_systems")
        .and_then(|v| v.as_object_mut())
    {
        for (_name, system) in map.iter_mut() {
            walk_subsystems(system, &scope, visited, None)?;
        }
    }

    hoist_subsystem_data_sources(obj)?;

    // Write the merged registry back so the merged axes are visible post-load
    // (and, for a file loaded as a subsystem ref, so the importer can read this
    // file's complete index_sets to merge in turn).
    if defer {
        return Ok(registry);
    }
    if !registry.is_empty() {
        obj.insert("index_sets".to_string(), Value::Object(registry));
    }
    Ok(Map::new())
}

/// The private key a `subsystems.<k>` mount carries its leaf's resolved
/// `data_sources` up under, from [`resolve_value`] to the mounting document's
/// [`hoist_subsystem_data_sources`]. Never survives a load.
const HOISTED_SOURCES_KEY: &str = "__esm_mounted_data_sources";

/// Merge every mounted document's `data_sources` into the document that mounts
/// it (esm-spec §4.7 "A mounted document's data sources"), whichever form the
/// mount took and at any depth of inline subsystems. Each mount edge left its
/// leaf's resolved entries on the spliced component under
/// [`HOISTED_SOURCES_KEY`] as `{"edge": <label>, "sources": {...}}`.
///
/// The mounting document's OWN entry wins a name clash. Two mounts that
/// contribute the same name must contribute IDENTICAL entries — compared
/// structurally, every field, after substitution and location resolution — or
/// the load fails with `data_source_merge_conflict` naming the source and both
/// edges; a diamond (one catalogue reached twice at one binding) merges once.
fn hoist_subsystem_data_sources(obj: &mut Map<String, Value>) -> Result<(), DiagnosticError> {
    fn collect(system: &mut Value, out: &mut Vec<(String, Map<String, Value>)>) {
        let Some(o) = system.as_object_mut() else {
            return;
        };
        if let Some(Value::Object(mut m)) = o.remove(HOISTED_SOURCES_KEY) {
            let edge = m
                .remove("edge")
                .and_then(|e| e.as_str().map(str::to_string))
                .unwrap_or_default();
            if let Some(Value::Object(src)) = m.remove("sources") {
                out.push((edge, src));
            }
        }
        if let Some(subs) = o.get_mut("subsystems").and_then(Value::as_object_mut) {
            for (_, sub) in subs.iter_mut() {
                collect(sub, out);
            }
        }
    }
    let mut found: Vec<(String, Map<String, Value>)> = Vec::new();
    for blk in ["models", "reaction_systems"] {
        if let Some(map) = obj.get_mut(blk).and_then(Value::as_object_mut) {
            for (_, system) in map.iter_mut() {
                collect(system, &mut found);
            }
        }
    }
    if found.is_empty() {
        return Ok(());
    }
    let dst = obj
        .entry("data_sources".to_string())
        .or_insert_with(|| Value::Object(Map::new()));
    let Some(dst) = dst.as_object_mut() else {
        return Ok(());
    };
    let own: HashSet<String> = dst.keys().cloned().collect();
    let mut first_edge: std::collections::HashMap<String, String> = Default::default();
    for (edge, m) in found {
        for (k, v) in m {
            if own.contains(&k) {
                continue;
            }
            match dst.get(&k) {
                None => {
                    dst.insert(k.clone(), v);
                    first_edge.insert(k, edge.clone());
                }
                Some(prev) if *prev == v => {}
                Some(_) => {
                    return Err(err(
                        codes::DATA_SOURCE_MERGE_CONFLICT,
                        format!(
                            "data source '{k}' is contributed by two mounts with different \
                             entries — {} and {edge} — after url_substitutions and location \
                             resolution (esm-spec §4.7 \"A mounted document's data sources\"). \
                             Give them different names, bind them alike, or declare '{k}' in \
                             the mounting document to override both.",
                            first_edge
                                .get(&k)
                                .map_or("an earlier mount", String::as_str)
                        ),
                    ));
                }
            }
        }
    }
    Ok(())
}

/// How one mount edge names itself in the diagnostics its pipeline raises.
struct EdgeNouns<'a> {
    /// Starts the library-target refusal: `"Subsystem"`, `"Model"`, ….
    library: &'a str,
    /// Names the edge in a `bindings` diagnostic.
    bindings: &'a str,
    /// Names the edge everywhere else.
    edge: &'a str,
}

/// A referenced document resolved in its own scope at a §4.7 mount edge, ready
/// for its caller to extract the component and splice it in.
struct MountedLeaf {
    /// The resolved, lowered document, its `index_sets` renamed by the edge
    /// and its `data_sources` taken out into [`MountedLeaf::data_sources`].
    doc: Value,
    /// The leaf file's identity (its canonical path, or a bundled library's).
    canonical: PathBuf,
    /// The directory the leaf's own relative refs resolve against.
    leaf_dir: PathBuf,
    /// The leaf's declared `domain.element_type`, read before resolution.
    precision: Option<String>,
    /// The leaf's `data_sources`, bound by the edge's `url_substitutions` and
    /// resolved against the leaf's directory; `None` when it declares none.
    data_sources: Option<Value>,
}

/// The §4.7 edge pipeline, run once for both mount forms ("Two mount forms, one
/// mechanism": the forms differ only in where the component lands, which
/// component a multi-component leaf yields, and that the top-level form drops
/// the leaf's `tests`). Those differences stay with the callers,
/// [`inline_toplevel_refs`] and [`resolve_value`].
///
/// In order:
///
/// 1. the referenced document loads ([`load_ref_document`], which runs the
///    version gates against the leaf's own `esm`), and must not be a template
///    or coupling library;
/// 2. the leaf resolves in its OWN scope (esm-spec §4.7 "Edge pipeline" step
///    1): this edge closes its metaparameters ([`close_mount_edge`]), its own
///    nested refs of either form are inlined in its directory FIRST
///    ("before validation or any other processing", so the fixpoint sees the
///    components the leaf mounts — issue #311), this edge's §9.7.10 injection
///    is appended, and its §9.7 machinery resolves, lowers and expands;
/// 3. its `enum` ops lower against its own `enums` block (esm-spec §9.3);
/// 4. the contributions its nested mounts staged merge into its own registry,
///    now that it has closed;
/// 5. this edge's `index_set_rename` applies (step 2), over the axes the leaf
///    declares and imports only;
/// 6. this edge's `url_substitutions` bind the leaf's data-source
///    placeholders, and the leaf's `data_sources` resolve against its own
///    directory (esm-spec §8.2.1).
///
/// The caller then merges the leaf's `index_sets` (step 3) and splices the
/// component in. The leaf's path is marked visited for the whole pipeline, so
/// a self- or mutually-importing document is `circular …`, and unmarked on
/// every exit.
fn resolve_mount_edge(
    edge: &Map<String, Value>,
    ref_str: &str,
    ref_noun: &RefNoun,
    nouns: &EdgeNouns<'_>,
    scope: &MountScope<'_>,
    visited: &mut HashSet<PathBuf>,
) -> Result<MountedLeaf, DiagnosticError> {
    let (canonical, mut comp) = load_ref_document(ref_str, scope.base_path, visited, ref_noun)?;
    // Read before anything below can consume the leaf's `domain`.
    let precision = declared_element_type(&comp);
    let leaf_dir = canonical.parent().unwrap_or(scope.base_path).to_path_buf();
    let result = resolve_loaded_leaf(
        &mut comp, &leaf_dir, &canonical, edge, ref_str, nouns, scope, visited,
    );
    visited.remove(&canonical);
    let data_sources = result?;
    Ok(MountedLeaf {
        doc: comp,
        canonical,
        leaf_dir,
        precision,
        data_sources,
    })
}

/// Steps 1 (after the load) to 6 of [`resolve_mount_edge`], on the loaded leaf
/// `comp`, in place. Returns the leaf's resolved `data_sources`, taken out of
/// `comp`.
#[allow(clippy::too_many_arguments)]
fn resolve_loaded_leaf(
    comp: &mut Value,
    leaf_dir: &Path,
    canonical: &Path,
    edge: &Map<String, Value>,
    ref_str: &str,
    nouns: &EdgeNouns<'_>,
    scope: &MountScope<'_>,
    visited: &mut HashSet<PathBuf>,
) -> Result<Option<Value>, DiagnosticError> {
    // A §4.7 mount MUST NOT target a template-library file — the two reference
    // mechanisms are disjoint (esm-spec §9.7.1) — nor a coupling-library file,
    // which is imported via a `coupling_import` coupling entry (§10.9).
    if crate::template_imports::is_template_library_doc(comp) {
        return Err(err(
            codes::SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY,
            format!(
                "{} ref '{ref_str}' targets a template-library file ({}); \
                 libraries are imported via expression_template_imports \
                 (esm-spec 9.7.1)",
                nouns.library,
                canonical.display()
            ),
        ));
    }
    if crate::coupling_imports::is_coupling_library_doc(comp) {
        return Err(err(
            codes::SUBSYSTEM_REF_IS_COUPLING_LIBRARY,
            format!(
                "{} ref '{ref_str}' targets a coupling-library file ({}); \
                 libraries are imported via a coupling_import coupling entry \
                 (esm-spec 10.9)",
                nouns.library,
                canonical.display()
            ),
        ));
    }

    // §9.7.6 binding site 3: close the leaf's metaparameters. Explicit edge
    // `bindings` win, backfilled by the LOADER-API bindings (site 4) for the
    // names the leaf DECLARES — so a leaf mounted with no edge bindings still
    // inherits the loader's grid instead of falling to its own defaults (a
    // discovered `extent`, §8.9.4, sizes the leaf from the data). Names the
    // leaf does not declare are never forwarded, so they cannot raise
    // `template_import_unknown_name` against it. Mirrors the Python
    // `_load_ref_data` backfill.
    //
    // The backfill reads `api_meta`, NOT `parent_meta`. `parent_meta`
    // additionally carries the mounting document's OWN declared defaults, and
    // forwarding those would let an assembler's unrelated `NLEV` silently
    // override the leaf's own default for a name the edge never bound.
    // `parent_meta` is the scope edge `bindings` EXPRESSIONS fold against, and
    // that is all it is.
    //
    // The same edge also forwards a binding through an assembly (§4.7
    // "Bindings reach through an assembly"); see [`close_mount_edge`].
    let EdgeClose {
        bindings,
        forwarded: leaf_forwarded,
        mount_declared: leaf_mount_declared_pre,
    } = close_mount_edge(
        comp,
        leaf_dir,
        edge,
        scope.parent_meta,
        scope.api_meta,
        scope.forwarded,
        nouns.bindings,
    )?;

    // §4.7: a `{ref}` resolves "before validation or any other processing", so
    // the leaf's OWN nested refs — of either mount form, in the leaf's
    // directory — are inlined HERE, before the §9.6.3 fixpoint below. A leaf's
    // template scope reaches the components it mounts (a rule declared in its
    // own `expression_template_imports` lowers a rewrite-target inside its
    // `subsystems.<k>`), and §9.7.10 defines the edge injection as "as if the
    // target had added those entries to the end of its own
    // `expression_template_imports`" — so the fixpoint must see the mounted
    // content for the two to agree.
    //
    // Nested edge `bindings` fold against the leaf's own closed metaparameter
    // environment — its declared defaults overlaid with this edge's close —
    // which is exactly what a STANDALONE load of the leaf hands them
    // (`root_metaparameter_env` in `load_with_meta`). `caller_env` is this
    // edge's `bindings`, the overlay that makes the leaf's fold environment
    // CLOSED rather than just its defaults (see `walk_top_level`).
    //
    // `defer: true` is load-bearing, and it is the SAME split the root makes:
    // the content splices in early so the fixpoint can lower through it, but
    // the `index_sets` it contributes are STAGED, not merged, because THIS leaf
    // has not closed yet. They land in `apply_staged_index_sets` after the
    // close below.
    let leaf_env = root_metaparameter_env(comp, &bindings);
    let staged_nested = walk_top_level(
        comp,
        &DocScope {
            base_path: leaf_dir,
            parent_meta: &leaf_env,
            api_meta: scope.api_meta,
            forwarded: &leaf_forwarded,
            caller_env: &bindings,
            enclosing_precision: scope.precision,
        },
        visited,
        true,
    )?;

    // §9.7.10 form A: the edge's `expression_template_imports` inject a
    // discretization into the leaf's own scope BEFORE resolution, so the
    // §9.6.3 fixpoint lowers its rewrite-targets at the mount. Consumed here
    // (the mount round-trips as the lowered inline component). Their own
    // relative refs are authored by the assembler carrying the edge, so they
    // absolutize against the MOUNTING document's directory, not the leaf's, at
    // both mount forms.
    let injected: Vec<Value> = edge
        .get("expression_template_imports")
        .and_then(|v| v.as_array())
        .map(|a| {
            let mut a = a.clone();
            for e in a.iter_mut() {
                absolutize_nested_refs(e, scope.base_path);
            }
            a
        })
        .unwrap_or_default();
    crate::template_imports::apply_scope_injections(comp, &injected)?;

    // This IS a §4.7 mount edge, so the leaf resolves under the two
    // mount-scope facts a root document does not have:
    //
    // * `mount_declared` — what the leaf's OWN nested mounts declare — so the
    //   §9.7.6 site-4 widening composes down the reference DAG;
    // * `mounted_leaf` — the leaf is NOT the last scope that can close a name.
    //   Its `index_sets` merge into the mounting document's registry after
    //   this and close there (§9.7.6 site 5), so an axis sized by a name only
    //   the assembler declares stays symbolic rather than failing here.
    let mut leaf_mount_declared =
        crate::template_imports::collect_mount_declared_metaparameters(comp, leaf_dir);
    leaf_mount_declared.extend(leaf_mount_declared_pre);
    let mut resolved = crate::template_imports::resolve_template_machinery_scoped(
        comp,
        leaf_dir,
        &bindings,
        &leaf_mount_declared,
        true,
    )?
    .unwrap_or_else(|| std::mem::take(comp));
    // The leaf keeps its references (esm-spec §9.6.4 rule 1): it is lowered
    // here, in its own file, and each component keeps the match-less template
    // definitions its references read (its `match` rules have fired), which
    // the mounting document merges into its own registry by flatten's rule —
    // at its lowering for a subsystem mount
    // (`lower_expression_templates::hoist_mounted_templates`), or as the
    // mounted component's own registry at a top-level mount. Mirrors the Julia
    // reference `_mounted_registries!`.
    crate::lower_expression_templates::lower_expression_templates(&mut resolved)?;
    crate::lower_expression_templates::mounted_registries(&mut resolved);
    *comp = resolved;

    // esm-spec §9.3: the leaf's `enum` ops resolve against ITS OWN `enums`
    // block, here, while that block is still at hand. The mounting document's
    // block is a different one and `enums` do not merge across a mount, so an
    // importer declaring an enum of the same name cannot change what the leaf
    // computes. The leaf's own nested mounts were lowered at their own edges.
    lower_mounted_enums_at_edge(comp, nouns.edge)?;

    // The leaf has now CLOSED, so the contributions its own nested mounts
    // staged can land — folded against the leaf's own closed environment and
    // compared deep-equal, the §4.7 merge rule run at the leaf rather than at
    // the importer. A nested contribution that is deep-equal to an axis the
    // leaf declares itself is idempotent and adds no key, which is what leaves
    // it renameable below.
    let before_nested = index_set_names(comp);
    apply_staged_index_sets(comp, staged_nested, &leaf_env)?;
    let nested_contributed: BTreeSet<String> = index_set_names(comp)
        .difference(&before_nested)
        .cloned()
        .collect();

    // esm-spec §4.7 "Mount-edge index-set renaming", pipeline step 2.
    // `index_set_rename` speaks the resolved leaf's own post-resolution
    // vocabulary, so it applies HERE — after the close and fold above, over
    // the leaf's own and imported axes only: an axis that reached the registry
    // through a mount nested inside it is renamed (or not) at that nested
    // edge, so `nested_contributed` is held out. Absent or empty ⇒ identity.
    crate::template_imports::apply_mount_index_set_rename(
        comp,
        edge,
        nouns.edge,
        &nested_contributed,
    )?;

    // §4.7 "Binding a data source's location at the mount": this edge's
    // `url_substitutions` bind the leaf's placeholders FIRST, so a spliced
    // segment resolves with the leaf's own location and a leading value anchors
    // on the MOUNTING document's directory. Then the leaf's `data_sources` —
    // its own, and those its own mounts already merged into it — resolve
    // against the LEAF's directory (§8.2.1), here, because once merged into
    // the mounting document an entry is indistinguishable from one the
    // importer declared.
    crate::data_source_urls::apply_mount_url_substitutions(
        comp,
        edge,
        scope.base_path,
        nouns.edge,
    )?;
    crate::data_source_urls::resolve_data_source_urls(comp, leaf_dir)?;
    Ok(comp
        .as_object_mut()
        .and_then(|o| o.remove("data_sources"))
        .filter(|v| v.as_object().is_some_and(|m| !m.is_empty())))
}

/// What both mount forms do to the component they extracted from a resolved
/// leaf, before it splices in.
fn finish_mounted_component(
    component: &mut Value,
    leaf: &MountedLeaf,
    scope: &MountScope<'_>,
    edge_label: String,
    mount_noun: &str,
) -> Result<(), DiagnosticError> {
    // esm-spec §4.7 "A mounted document's data sources": the leaf's entries
    // ride on the spliced component under a private key and merge, with every
    // other mount's, in [`hoist_subsystem_data_sources`] — one merge rule for
    // both forms.
    if let (Some(src), Some(obj)) = (&leaf.data_sources, component.as_object_mut()) {
        obj.insert(
            HOISTED_SOURCES_KEY.to_string(),
            serde_json::json!({ "edge": edge_label, "sources": src }),
        );
    }
    // esm-spec §4.7 "Working precision crosses a mount": the leaf's declared
    // `domain.element_type` does not merge (one document, one domain), so it
    // travels on the variables it governs.
    carry_mounted_element_type(
        component,
        leaf.precision.as_deref(),
        scope.precision,
        mount_noun,
    )?;
    // Any relative `{ref}` the resolution above did not consume anchors at the
    // LEAF's directory, not at the parent it is about to land in.
    absolutize_nested_refs(component, &leaf.leaf_dir);
    Ok(())
}

/// Inline every top-level `models.<k>` MOUNT EDGE — a bare `{ref}` (has `ref`,
/// no inline `variables`) — by resolving the referenced leaf IN ITS OWN SCOPE
/// ([`resolve_mount_edge`], the pipeline a `subsystems.<k>` edge runs too) and
/// splicing in its single model.
///
/// What this form adds to the shared pipeline is what esm-spec §4.7 says
/// differs: the component lands under the same key of this document's
/// `models` block, a `model` selector picks one of a multi-model leaf, and the
/// leaf's inline `tests` are dropped (§6.6: they do not cross a mount edge).
/// The leaf's renamed `index_sets` merge into THIS document's registry (or are
/// staged, when the root defers its merge) under the
/// deep-equal-or-`subsystem_index_set_conflict` rule.
///
/// The same function serves a top-level `reaction_systems.<k>` `{ref}`, through
/// `form` ([`TopLevelMountForm`]): only the block the component comes from and
/// lands in, the inline discriminator and the selector key differ.
fn inline_toplevel_refs(
    form: &TopLevelMountForm,
    obj: &mut Map<String, Value>,
    scope: &MountScope<'_>,
    visited: &mut HashSet<PathBuf>,
    mut staged: Option<&mut Map<String, Value>>,
) -> Result<(), DiagnosticError> {
    // An entry is a mount edge only when its `ref` is a STRING (and it carries
    // no inline body). Any other `ref` value leaves the entry to the typed
    // parse and the schema, which report it at the entry, as in the other
    // bindings.
    let edge_names: Vec<String> = match obj.get(form.block).and_then(|v| v.as_object()) {
        Some(systems) => systems
            .iter()
            .filter(|(_, m)| {
                m.is_object()
                    && m.get("ref").is_some_and(Value::is_string)
                    && m.get(form.inline_key).is_none()
            })
            .map(|(k, _)| k.clone())
            .collect(),
        None => return Ok(()),
    };

    for name in edge_names {
        let entry = obj
            .get_mut(form.block)
            .and_then(|v| v.as_object_mut())
            .and_then(|m| m.remove(&name))
            .expect("edge entry present");
        let entry_obj = entry.as_object().expect("edge entry is an object");
        let ref_str = entry_obj
            .get("ref")
            .and_then(|v| v.as_str())
            .expect("edge filter admits only a string ref");
        let mount_noun = format!("top-level {} ref '{ref_str}'", form.noun);
        let leaf = resolve_mount_edge(
            entry_obj,
            ref_str,
            form.ref_noun,
            &EdgeNouns {
                library: form.noun_cap,
                bindings: &mount_noun,
                edge: &mount_noun,
            },
            scope,
            visited,
        )?;

        let sel = entry_obj.get(form.selector).and_then(|v| v.as_str());
        let mut component =
            extract_toplevel_component(form, &leaf.doc, sel, ref_str, &leaf.canonical)?;
        // esm-spec §6.6: inline tests do NOT cross a mount edge. They are
        // assertions about the leaf under the leaf's OWN standalone conditions,
        // and the mounting document may couple it — replacing a parameter,
        // reshaping it, feeding it another component's state — so re-running
        // them here would check a claim the leaf's author never made. They run
        // when the leaf's own file is the test target.
        if let Some(component_obj) = component.as_object_mut() {
            component_obj.remove("tests");
        }
        finish_mounted_component(
            &mut component,
            &leaf,
            scope,
            format!("{}.{name} ({mount_noun})", form.block),
            &mount_noun,
        )?;
        obj.get_mut(form.block)
            .and_then(|v| v.as_object_mut())
            .expect("mount block present")
            .insert(name.clone(), component);

        // esm-spec §4.7 "Index-set merge": the leaf's document-scoped
        // `index_sets` merge into THIS document's registry, exactly as at a
        // subsystem mount, so an assembly may shape its coupling over the
        // leaf's axes without redeclaring them. `comp`'s registry already
        // carries whatever ITS own mounts brought in, so the merge composes
        // transitively. Unlike the by-name blocks, the importer does NOT
        // silently win a clash.
        //
        // A `size` is concrete here only when the leaf HAS §9.7 machinery: then
        // the edge closed and folded its `metaparameters`. A leaf with NO
        // machinery has no close to run, so a `size` naming a metaparameter the
        // ASSEMBLER declares still arrives here SYMBOLIC and merges that way, to
        // be closed by the mounting document's own §9.7.6 pass.
        // `merge_subsystem_index_sets` compares declarations structurally and
        // has no symbolic handling, so on that path the idempotence it enforces
        // is SYNTACTIC: a mount that restates the leaf's axis verbatim
        // (`size: "n_rows"`) merges clean, and one that restates it with the
        // concrete number the name folds to (`size: 7`) is a
        // `subsystem_index_set_conflict`. Python agrees on both.
        if let Some(loaded) = leaf.doc.get("index_sets").and_then(|v| v.as_object())
            && !loaded.is_empty()
        {
            // Deferred at the ROOT (see `walk_top_level`): the contribution is
            // staged, not merged, until the mounting document has closed.
            if let Some(staged) = staged.as_deref_mut() {
                merge_subsystem_index_sets(staged, loaded, ref_str, scope.merge_env)?;
            } else {
                let registry = obj
                    .entry("index_sets".to_string())
                    .or_insert_with(|| Value::Object(Map::new()));
                if let Some(registry) = registry.as_object_mut() {
                    merge_subsystem_index_sets(registry, loaded, ref_str, scope.merge_env)?;
                }
            }
        }
        // Not `enums`: it is file-local (esm-spec §9.3), and the leaf's `enum`
        // ops were already lowered against it at the edge.
    }
    Ok(())
}

/// Lower `doc`'s `enum` ops against its own `enums` block at a §4.7 mount edge
/// (esm-spec §9.3), naming the edge in the diagnostic.
fn lower_mounted_enums_at_edge(doc: &mut Value, mount_noun: &str) -> Result<(), DiagnosticError> {
    crate::lower_enums::lower_mounted_document_enums(doc).map_err(|e| {
        err(
            e.code,
            format!(
                "{mount_noun}: {} — an `enum` op in a mounted file resolves against that \
                 file's own `enums` block (esm-spec §9.3)",
                e.message
            ),
        )
    })
}

/// Extract the single top-level component of `form`'s kind from a referenced
/// file (or the `sel`-named one when the file holds several), for a top-level
/// `models.<k>` / `reaction_systems.<k>` ref mount.
fn extract_toplevel_component(
    form: &TopLevelMountForm,
    comp: &Value,
    sel: Option<&str>,
    ref_str: &str,
    source: &Path,
) -> Result<Value, DiagnosticError> {
    let noun = form.noun;
    let code = form.ref_noun.code;
    let systems = comp
        .as_object()
        .and_then(|o| o.get(form.block))
        .and_then(|v| v.as_object())
        .ok_or_else(|| {
            err(
                code,
                format!(
                    "top-level {noun} ref '{ref_str}' resolves to a file with no {} block ({})",
                    form.block,
                    source.display()
                ),
            )
        })?;
    let available = || {
        let mut avail: Vec<&str> = systems.keys().map(String::as_str).collect();
        avail.sort_unstable();
        avail.join(", ")
    };
    match sel {
        Some(name) => systems.get(name).cloned().ok_or_else(|| {
            err(
                code,
                format!(
                    "top-level {noun} ref '{ref_str}' has no {noun} '{name}' (available: {})",
                    available()
                ),
            )
        }),
        None => {
            if systems.len() == 1 {
                Ok(systems.values().next().cloned().expect("one component"))
            } else {
                Err(err(
                    code,
                    format!(
                        "top-level {noun} ref '{ref_str}' resolves to {} {noun}s; add a \"{}\" \
                         selector to choose one (available: {})",
                        systems.len(),
                        form.selector,
                        available()
                    ),
                ))
            }
        }
    }
}

/// Rewrite every relative `{"ref": "..."}` under `value` to an absolute path
/// anchored at `base_dir`, so the references resolve after the containing model
/// is spliced into a parent whose directory differs. Absolute paths and URLs are
/// left untouched. Mirrors the Julia `_absolutize_nested_refs!`.
fn absolutize_nested_refs(value: &mut Value, base_dir: &Path) {
    match value {
        Value::Object(map) => {
            if let Some(Value::String(r)) = map.get("ref") {
                // esm-spec §4.7: expand `${VAR}` BEFORE deciding whether the ref
                // is absolute, as the Julia reference does — classifying first
                // would anchor an expanded ABSOLUTE ref at `base_dir` as though
                // it were relative.
                let r = crate::stdlib::expand_ref(r).into_owned();
                let is_abs = r.starts_with('/')
                    || r.starts_with("http://")
                    || r.starts_with("https://")
                    || crate::stdlib::is_std_ref(&r);
                if !is_abs {
                    let joined = base_dir.join(&r);
                    let abs = joined
                        .canonicalize()
                        .map(|p| p.to_string_lossy().into_owned())
                        .unwrap_or_else(|_| joined.to_string_lossy().into_owned());
                    map.insert("ref".to_string(), Value::String(abs));
                }
            }
            for v in map.values_mut() {
                absolutize_nested_refs(v, base_dir);
            }
        }
        Value::Array(arr) => {
            for v in arr.iter_mut() {
                absolutize_nested_refs(v, base_dir);
            }
        }
        _ => {}
    }
}

/// Walk a model or reaction system value and resolve any refs in its
/// `subsystems` map. `registry`, when `Some`, accumulates referenced files'
/// top-level `index_sets` (esm-spec §4.7 model-subsystem merge).
fn walk_subsystems(
    value: &mut Value,
    scope: &MountScope<'_>,
    visited: &mut HashSet<PathBuf>,
    mut registry: Option<&mut Map<String, Value>>,
) -> Result<(), DiagnosticError> {
    let Some(subs) = value
        .as_object_mut()
        .and_then(|o| o.get_mut("subsystems"))
        .and_then(Value::as_object_mut)
    else {
        return Ok(());
    };

    let names: Vec<String> = subs.keys().cloned().collect();
    for name in names {
        let entry = subs.remove(&name).unwrap_or(Value::Null);
        let resolved = resolve_value(entry, scope, visited, registry.as_deref_mut())?;
        subs.insert(name, resolved);
    }

    Ok(())
}

/// Read the optional metaparameter `bindings` off a `{ ref, bindings }`
/// subsystem entry (esm-spec §9.7.6 binding site 3). A value may be a
/// *metaparameter expression* — an integer literal, a name in the MOUNTING
/// document's metaparameter scope, or a `{op: +|-|*|/, args}` tree over the
/// same (e.g. `NTGT = NX*NY`). A subsystem ref is resolved as a complete
/// document and folded to concrete integers at the mount, so — unlike an
/// import edge — its binding values cannot be carried symbolically: each folds
/// IMMEDIATELY against `parent_meta`, the mounting document's already-closed
/// metaparameter environment (the parent closes before its refs resolve).
/// A free name absent from `parent_meta` is `template_import_unknown_name`;
/// a bad op / empty args / float is `metaparameter_type_error`.
fn read_edge_bindings(
    obj: &serde_json::Map<String, Value>,
    parent_meta: &std::collections::BTreeMap<String, i64>,
    mount_noun: &str,
) -> Result<std::collections::BTreeMap<String, i64>, DiagnosticError> {
    let mut out = std::collections::BTreeMap::new();
    let Some(bindings) = obj.get("bindings") else {
        return Ok(out);
    };
    let Some(bindings_obj) = bindings.as_object() else {
        return Err(err(
            codes::METAPARAMETER_TYPE_ERROR,
            format!(
                "{mount_noun} `bindings` must be an object of \
                 metaparameter expressions (esm-spec 9.7.6)"
            ),
        ));
    };
    for (k, v) in bindings_obj {
        let ctx = format!("{mount_noun}, binding '{k}'");
        // Structural grammar check at the edge (bad op / empty args / float —
        // even with a symbolic arg), then fold against the mounting scope.
        crate::template_imports::require_meta_expr(v, &ctx)?;
        let folded = crate::template_imports::eval_meta_expr(v, parent_meta, &ctx)?;
        out.insert(k.clone(), folded);
    }
    Ok(out)
}

/// What one §4.7 mount edge closes its leaf with, and what the leaf hands down
/// its OWN mount edges. Built by [`close_mount_edge`].
struct EdgeClose {
    /// The leaf's §9.7.6 site-3 close: the bindings reaching it from above
    /// (loader-API, overlaid by forwarded) for the names it DECLARES, overlaid
    /// by this edge's explicit `bindings`.
    bindings: BTreeMap<String, i64>,
    /// The forwarded edge bindings the leaf passes down its own mount edges.
    forwarded: BTreeMap<String, i64>,
    /// The names a document in the leaf's mount tree declares, read on the
    /// AUTHORED leaf (before its mounts are inlined). Collected only when this
    /// edge binds a name the leaf itself does not declare — the only case it
    /// can decide anything — and empty otherwise.
    mount_declared: BTreeSet<String>,
}

/// The binding half of a §4.7 mount edge, shared by both mount forms
/// ([`inline_toplevel_refs`] and [`resolve_value`]): "Two mount forms,
/// one mechanism".
///
/// Two maps reach an edge from above and they are kept APART:
///
/// * `api_meta` — the loader-API bindings (§9.7.6 site 4). They reach every
///   depth, each edge closing the names its own leaf declares.
/// * `forwarded` — edge `bindings` an enclosing edge wrote for a name its leaf
///   did not declare but a document in its mount tree does (§4.7 "Bindings
///   reach through an assembly"). Such a binding STOPS at the first document on
///   each mount path that declares the name: it closes that document and is not
///   handed further down, so it closes exactly what it would had the enclosing
///   edge mounted that document directly.
///
/// The leaf sees `api_meta` overlaid by `forwarded` (forwarded wins), filtered
/// to the names it declares, with this edge's own explicit `bindings` winning
/// over both. It hands its own mount edges `api_meta` unchanged and
///
/// `forwarded' = {forwarded entries it does NOT declare}
///             ∪ {this edge's bindings it does not declare but its mount tree does}`
///
/// (the latter winning). A binding naming something neither the leaf nor its
/// mount tree declares is left in `bindings`, for the leaf's close to refuse
/// as `template_import_unknown_name`.
///
/// Edge `bindings` EXPRESSIONS fold against `parent_meta`, the mounting
/// document's closed environment; `parent_meta` never backfills the leaf (it
/// carries the mounting document's own defaults, which would silently resize a
/// leaf axis the edge never bound).
#[allow(clippy::too_many_arguments)]
fn close_mount_edge(
    leaf: &Value,
    leaf_dir: &Path,
    edge: &Map<String, Value>,
    parent_meta: &BTreeMap<String, i64>,
    api_meta: &BTreeMap<String, i64>,
    forwarded: &BTreeMap<String, i64>,
    mount_noun: &str,
) -> Result<EdgeClose, DiagnosticError> {
    let leaf_declared: BTreeSet<String> = leaf
        .get("metaparameters")
        .and_then(|v| v.as_object())
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default();
    let mut bindings: BTreeMap<String, i64> = api_meta
        .iter()
        .chain(forwarded)
        .filter(|(k, _)| leaf_declared.contains(*k))
        .map(|(k, v)| (k.clone(), *v))
        .collect();
    let explicit = read_edge_bindings(edge, parent_meta, mount_noun)?;
    // The declared-through-mounts set re-reads every document the leaf mounts,
    // so it is read only when this edge binds a name the leaf does not declare.
    // It is read on the AUTHORED leaf: after its mounts are inlined it is gone.
    let mount_declared = if explicit.keys().any(|k| !leaf_declared.contains(k)) {
        crate::template_imports::collect_mount_declared_metaparameters(leaf, leaf_dir)
    } else {
        BTreeSet::new()
    };
    let mut next: BTreeMap<String, i64> = forwarded
        .iter()
        .filter(|(k, _)| !leaf_declared.contains(*k))
        .map(|(k, v)| (k.clone(), *v))
        .collect();
    for (k, v) in &explicit {
        if !leaf_declared.contains(k) && mount_declared.contains(k) {
            next.insert(k.clone(), *v);
        }
    }
    bindings.extend(explicit);
    Ok(EdgeClose {
        bindings,
        forwarded: next,
        mount_declared,
    })
}

/// If `value` is a `{ "ref": "..." }` object, resolve the referenced file at
/// this mount edge ([`resolve_mount_edge`], the pipeline the top-level form
/// runs too) and inline its single top-level system. Otherwise recurse into the
/// value's own `subsystems` map.
///
/// What this form adds to the shared pipeline is where the component lands —
/// in this `subsystems.<k>` slot — and that the leaf must hold exactly one
/// system ([`extract_single_system`]); its `tests` stay (a subsystem's tests
/// are never run by the mounting document). The leaf's renamed `index_sets`
/// merge into `registry` when it is `Some` (model subsystems; reaction-system
/// subsystems do not merge).
fn resolve_value(
    value: Value,
    scope: &MountScope<'_>,
    visited: &mut HashSet<PathBuf>,
    registry: Option<&mut Map<String, Value>>,
) -> Result<Value, DiagnosticError> {
    if let Some(obj) = value.as_object()
        && let Some(ref_val) = obj.get("ref")
    {
        let ref_str = ref_val
            .as_str()
            .ok_or_else(|| err(SUBSYSTEM_REF.code, "subsystem ref must be a string"))?;
        let mount_noun = format!("subsystem ref '{ref_str}'");
        let leaf = resolve_mount_edge(
            obj,
            ref_str,
            &SUBSYSTEM_REF,
            &EdgeNouns {
                library: "Subsystem",
                bindings: "subsystem ref",
                edge: &mount_noun,
            },
            scope,
            visited,
        )?;

        let mut system = extract_single_system(&leaf.doc, &leaf.canonical)?;
        finish_mounted_component(&mut system, &leaf, scope, mount_noun.clone(), &mount_noun)?;

        // esm-spec §4.7 "Index-set merge", step 3: bottom-up into the
        // importing document's registry.
        if let Some(reg) = registry
            && let Some(loaded) = leaf.doc.get("index_sets").and_then(|v| v.as_object())
        {
            merge_subsystem_index_sets(reg, loaded, ref_str, scope.merge_env)?;
        }
        return Ok(system);
    }

    let mut value = value;
    walk_subsystems(&mut value, scope, visited, registry)?;
    Ok(value)
}

/// The document's own §4.7 mount edges that do not resolve, as structured
/// `(code, path)` findings: every `subsystems.<k>` `{ref}` of a top-level
/// model or reaction system, at `/<block>/<system>/subsystems/<k>`, then every
/// top-level `models.<k>` / `reaction_systems.<k>` `{ref}` stub, at
/// `/<block>/<k>`.
///
/// Each edge is judged on its own, by the rules the loader applies at that
/// edge before resolving the leaf: the ref must locate, read and parse
/// (`unresolved_subsystem_ref` otherwise), and the leaf must yield the
/// component — exactly one system for a subsystem mount
/// (`ambiguous_subsystem_ref` otherwise), and for a top-level mount one
/// component of the form's kind, or the one its selector names
/// (`unresolved_subsystem_ref` otherwise). An edge that passes contributes
/// nothing, even when something deeper in the leaf fails; nested edges are
/// the leaf's own to report. Relative refs resolve against `base_dir`, the
/// document's directory.
///
/// A load that refuses the document while resolving its mounts carries these
/// as its [`crate::EsmError::findings`].
pub fn mount_edge_errors(document: &Value, base_dir: &Path) -> Vec<crate::StructuralError> {
    use crate::{StructuralError, StructuralErrorCode};
    let read = |ref_str: &str, noun: &RefNoun| {
        let expanded = crate::ref_reader::expand(ref_str);
        crate::ref_reader::locate(&expanded, base_dir)
            .and_then(|located| crate::ref_reader::read(&located).map(|doc| (located, doc)))
            .map_err(|e| ref_read_error(e, &expanded, noun))
    };
    let finding = |path: String, e: DiagnosticError, details: Value| StructuralError {
        path,
        code: if e.code == codes::AMBIGUOUS_SUBSYSTEM_REF {
            StructuralErrorCode::AmbiguousSubsystemRef
        } else {
            StructuralErrorCode::UnresolvedSubsystemRef
        },
        message: e.message,
        details,
    };
    let mut out = Vec::new();
    for container in ["models", "reaction_systems"] {
        let Some(systems) = document.get(container).and_then(Value::as_object) else {
            continue;
        };
        for (sys_name, system) in systems {
            let Some(subs) = system.get("subsystems").and_then(Value::as_object) else {
                continue;
            };
            for (sub_name, sub) in subs {
                let Some(ref_str) = sub.get("ref").and_then(Value::as_str) else {
                    continue;
                };
                let outcome = read(ref_str, &SUBSYSTEM_REF)
                    .and_then(|(located, doc)| extract_single_system(&doc, &located.identity));
                if let Err(e) = outcome {
                    out.push(finding(
                        format!("/{container}/{sys_name}/subsystems/{sub_name}"),
                        e,
                        serde_json::json!({
                            "ref": ref_str,
                            "subsystem": sub_name,
                            "parent_model": sys_name,
                        }),
                    ));
                }
            }
        }
    }
    for form in [&MODEL_MOUNT, &REACTION_SYSTEM_MOUNT] {
        let Some(entries) = document.get(form.block).and_then(Value::as_object) else {
            continue;
        };
        for (name, entry) in entries {
            let Some(ref_str) = entry.get("ref").and_then(Value::as_str) else {
                continue;
            };
            if entry.get(form.inline_key).is_some() {
                continue;
            }
            let sel = entry.get(form.selector).and_then(Value::as_str);
            let outcome = read(ref_str, form.ref_noun).and_then(|(located, doc)| {
                extract_toplevel_component(form, &doc, sel, ref_str, &located.identity)
            });
            if let Err(e) = outcome {
                let mut details = serde_json::json!({ "ref": ref_str });
                if let Some(sel) = sel {
                    details[form.selector] = Value::from(sel);
                }
                out.push(finding(format!("/{}/{name}", form.block), e, details));
            }
        }
    }
    out
}

/// The part of a document [`mount_edge_errors`] reads — its top-level
/// `{ref}` stubs and its top-level systems' `subsystems` refs — copied out, so
/// the edges can still be judged after resolution consumed them in place.
pub(crate) fn mount_edge_skeleton(document: &Value) -> Value {
    let mut out = Map::new();
    for block in ["models", "reaction_systems"] {
        let Some(systems) = document.get(block).and_then(Value::as_object) else {
            continue;
        };
        let mut kept = Map::new();
        for (name, system) in systems {
            if system.get("ref").is_some() {
                kept.insert(name.clone(), system.clone());
            } else if let Some(subs) = system.get("subsystems").and_then(Value::as_object) {
                let refs: Map<String, Value> = subs
                    .iter()
                    .filter(|(_, sub)| sub.get("ref").is_some())
                    .map(|(k, sub)| (k.clone(), sub.clone()))
                    .collect();
                if !refs.is_empty() {
                    kept.insert(
                        name.clone(),
                        serde_json::json!({ "subsystems": Value::Object(refs) }),
                    );
                }
            }
        }
        if !kept.is_empty() {
            out.insert(block.to_string(), Value::Object(kept));
        }
    }
    Value::Object(out)
}

/// The working precision a document that declares none evaluates in
/// (esm-spec §11.3: `domain.element_type` defaults to `"Float64"`).
const DEFAULT_ELEMENT_TYPE: &str = "Float64";

/// The `domain.element_type` a document declares, if it declares one.
fn declared_element_type(doc: &Value) -> Option<String> {
    doc.get("domain")
        .and_then(|d| d.get("element_type"))
        .and_then(Value::as_str)
        .map(str::to_string)
}

/// A document's EFFECTIVE working precision (esm-spec §4.7 "Working precision
/// crosses a mount"): its own declaration, else the one it inherits from the
/// document that mounts it. A root inherits [`DEFAULT_ELEMENT_TYPE`].
fn effective_element_type(doc: &Value, enclosing: &str) -> String {
    declared_element_type(doc).unwrap_or_else(|| enclosing.to_string())
}

/// Carry a mounted document's declared working precision onto the component
/// it splices in (esm-spec §4.7 "Working precision crosses a mount").
///
/// A leaf that declares no `domain.element_type` declares no precision and
/// adopts the mounting document's, so nothing is written. A leaf whose
/// declaration equals the mounting document's EFFECTIVE precision needs
/// nothing written either. Otherwise every `ModelVariable` of the component —
/// and of every subsystem it carries, at any depth — that does not declare its
/// own `element_type` gets the leaf's; a variable that does declare one keeps
/// it. The result is exactly the set of overrides an author writing the
/// assembly inline would have had to write, so `emit ∘ load` stays a fixed
/// point and the evaluator needs no mount-specific path.
fn carry_mounted_element_type(
    component: &mut Value,
    leaf: Option<&str>,
    enclosing: &str,
    mount_noun: &str,
) -> Result<(), DiagnosticError> {
    let Some(leaf) = leaf else {
        return Ok(());
    };
    if leaf == enclosing {
        return Ok(());
    }
    stamp_element_type(component, leaf, enclosing, mount_noun, "")
}

fn stamp_element_type(
    system: &mut Value,
    leaf: &str,
    enclosing: &str,
    mount_noun: &str,
    path: &str,
) -> Result<(), DiagnosticError> {
    let Some(obj) = system.as_object_mut() else {
        return Ok(());
    };
    // A reaction system's species and parameters have no `element_type`, so
    // the format cannot state its precision per component. Refused rather than
    // evaluated in the mounting document's precision (esm-spec §11.3.1).
    if obj.contains_key("species") || obj.contains_key("reactions") {
        let at = if path.is_empty() {
            String::new()
        } else {
            format!(" (subsystem '{path}')")
        };
        return Err(err(
            codes::ELEMENT_TYPE_UNCARRIED,
            format!(
                "{mount_noun}: the mounted document declares `domain.element_type: \"{leaf}\"` \
                 but the document mounting it evaluates in {enclosing}, and the component \
                 carries a reaction system{at} whose species and parameters cannot declare a \
                 per-variable `element_type`; the mount cannot keep the leaf's precision \
                 (esm-spec §4.7 \"Working precision crosses a mount\"). Declare the same \
                 `domain.element_type` on the mounting document, or remove it from the leaf"
            ),
        ));
    }
    if let Some(vars) = obj.get_mut("variables").and_then(Value::as_object_mut) {
        for var in vars.values_mut() {
            if let Some(v) = var.as_object_mut()
                && !v.contains_key("element_type")
            {
                v.insert("element_type".to_string(), Value::String(leaf.to_string()));
            }
        }
    }
    if let Some(subs) = obj.get_mut("subsystems").and_then(Value::as_object_mut) {
        for (name, sub) in subs.iter_mut() {
            let sub_path = if path.is_empty() {
                name.clone()
            } else {
                format!("{path}.{name}")
            };
            stamp_element_type(sub, leaf, enclosing, mount_noun, &sub_path)?;
        }
    }
    Ok(())
}

/// A referenced file must contain exactly one top-level model, reaction
/// system, or data loader. Extract that single entry as a JSON value to inline
/// into the caller's subsystem slot. Precedence is models -> reaction_systems
/// -> data_sources.
fn extract_single_system(value: &Value, source: &Path) -> Result<Value, DiagnosticError> {
    let obj = value.as_object().ok_or_else(|| {
        err(
            SUBSYSTEM_REF.code,
            format!("ref {} did not parse to a JSON object", source.display()),
        )
    })?;

    // "Exactly one top-level system" counts across ALL system kinds TOGETHER —
    // it is not a per-kind question.
    //
    // The previous chain asked each kind in turn (`models` → `reaction_systems`
    // → `data_sources`) and took the first that happened to hold exactly one
    // entry. A file with TWO models and ONE data loader therefore fell past the
    // ambiguous `models` map and silently mounted the LOADER — the caller asked
    // for a subsystem and got a completely different object, with no diagnostic.
    // That is precisely tests/invalid/subsystem_ref_ambiguous.esm (2 models +
    // 1 loader), and it is a worse failure than the error it was avoiding.
    // `data_sources` is NOT a top-level system. From 1.0.0 a data source is not
    // a component (esm-spec §8) — it cannot be a coupling endpoint, a subsystem
    // or a scoped-name path root — so a file holding a model plus the sources
    // that model consumes still declares exactly one mountable system. Counting
    // sources made that shape, which is the natural 1.0.0 one now that a loader
    // is no longer a component, the one shape a `ref` could not mount.
    let systems: Vec<&Value> = ["models", "reaction_systems"]
        .iter()
        .filter_map(|key| obj.get(*key).and_then(|v| v.as_object()))
        .flat_map(|m| m.values())
        .collect();

    match systems.as_slice() {
        [only] => Ok((*only).clone()),
        // The file WAS found and read — it just does not contain exactly one
        // top-level system (zero, or several), so which system to mount is
        // AMBIGUOUS. This is a different defect from a ref that could not be
        // resolved at all, and the corpus pins the two under different codes.
        _ => Err(err(
            AMBIGUOUS_SUBSYSTEM_REF,
            format!(
                "Subsystem reference '{}' resolves to a file containing multiple top-level \
                 systems; exactly one is required",
                source.display()
            ),
        )),
    }
}

/// Expand `${VAR}` tokens in a `ref` from the loader's environment
/// (esm-spec §4.7) — the mechanism a document uses to reach a sibling library
/// repository checked out at a deployment-chosen path.
///
/// Three rules, matching the Julia reference and the Python binding, which both
/// spell them as the regex `\$\{([A-Za-z_][A-Za-z0-9_]*)\}`:
///
/// * only the BRACED form with a C-identifier name expands — never a bare
///   `$VAR`, never a non-identifier name, never an unclosed `${`;
/// * an UNSET variable is left verbatim, so the ref fails with the ordinary
///   unresolved diagnostic naming the `${VAR}` text rather than misresolving
///   against a path built from an empty string;
/// * callers expand BEFORE classifying the ref as remote / absolute / relative,
///   because §4.7 resolves the EXPANDED string: an expanded relative ref
///   anchors against the referencing file's directory and an expanded
///   absolute-or-URL ref is used as-is.
pub(crate) fn expand_env_refs(ref_str: &str) -> Cow<'_, str> {
    if !ref_str.contains("${") {
        return Cow::Borrowed(ref_str);
    }
    let mut out = String::with_capacity(ref_str.len());
    let mut rest = ref_str;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        match after.find('}') {
            Some(end) if is_env_var_name(&after[..end]) => {
                match std::env::var(&after[..end]) {
                    Ok(value) => out.push_str(&value),
                    // Unset: keep the whole token, so the ref fails unresolved.
                    Err(_) => out.push_str(&rest[start..start + 3 + end]),
                }
                rest = &after[end + 1..];
            }
            // Not a `${IDENT}` token, so `${` is an ordinary path character.
            _ => {
                out.push_str("${");
                rest = after;
            }
        }
    }
    out.push_str(rest);
    Cow::Owned(out)
}

/// A C-identifier — the only variable-name shape §4.7's `${VAR}` token admits.
fn is_env_var_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tempfile::TempDir;

    #[test]
    fn test_resolve_no_refs() {
        let mut value = json!({
            "esm": "2.0.0",
            "metadata": { "name": "test" },
            "models": {
                "Main": { "variables": {}, "equations": [] }
            }
        });
        let result = resolve_subsystem_refs_raw(&mut value, Path::new("/tmp"));
        assert!(result.is_ok());
    }

    #[test]
    fn test_resolve_local_subsystem_ref() {
        let dir = TempDir::new().unwrap();
        let inner = json!({
            "esm": "2.0.0",
            "metadata": { "name": "inner" },
            "models": {
                "Inner": {
                    "variables": {},
                    "equations": []
                }
            }
        });
        std::fs::write(
            dir.path().join("inner.json"),
            serde_json::to_string(&inner).unwrap(),
        )
        .unwrap();

        let mut value = json!({
            "esm": "2.0.0",
            "metadata": { "name": "main" },
            "models": {
                "Outer": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {
                        "Inner": { "ref": "inner.json" }
                    }
                }
            }
        });

        resolve_subsystem_refs_raw(&mut value, dir.path()).unwrap();

        let inner_resolved = &value["models"]["Outer"]["subsystems"]["Inner"];
        assert!(inner_resolved.get("variables").is_some());
        assert!(inner_resolved.get("ref").is_none());
    }

    /// Each file is held to its OWN declared `esm` version (esm-spec §4.7,
    /// §4.8.5 item 6): a 1.0.0 document may mount a 1.2.0 leaf whose
    /// expressions carry unit-bearing `const` nodes, and a 1.0.0 leaf that
    /// carries one is refused even when a 1.2.0 document mounts it.
    #[test]
    fn const_units_gate_reads_each_files_own_version() {
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/valid/version_gate_older_mounts_newer.esm");
        crate::load_path(&fixture).expect("a 1.0.0 file may mount a 1.2.0 leaf");

        let dir = TempDir::new().unwrap();
        let leaf = |esm: &str| {
            json!({
                "esm": esm,
                "metadata": { "name": "leaf" },
                "models": { "Leaf": {
                    "variables": {
                        "p": { "type": "parameter", "units": "Pa", "default": 1.0 },
                        "q": { "type": "unknown", "units": "Pa" }
                    },
                    "equations": [{ "lhs": "q", "rhs": { "op": "+", "args": [
                        "p", { "op": "const", "args": [], "value": 1.0, "units": "Pa" }
                    ] } }]
                } }
            })
        };
        std::fs::write(dir.path().join("old_leaf.esm"), leaf("1.0.0").to_string()).unwrap();
        let root = json!({
            "esm": "2.0.0",
            "metadata": { "name": "root" },
            "models": { "Outer": {
                "variables": {},
                "equations": [],
                "subsystems": { "Leaf": { "ref": "old_leaf.esm" } }
            } }
        });
        let e = resolve_subsystem_refs_raw(&mut root.clone(), dir.path())
            .expect_err("a 1.0.0 leaf carrying a unit-bearing const is refused");
        assert_eq!(e.code, codes::CONST_UNITS_VERSION_TOO_OLD, "{e}");
    }

    /// A mounted leaf's top-level `solver` block is gated against the leaf's
    /// OWN declared `esm` (esm-spec §2.2.4, §4.7): a 1.0.0 leaf carrying one is
    /// refused even when a 1.1.0 document mounts it, and a 1.1.0 leaf is not.
    #[test]
    fn solver_gate_reads_each_files_own_version() {
        let dir = TempDir::new().unwrap();
        let leaf = |esm: &str| {
            json!({
                "esm": esm,
                "metadata": { "name": "leaf" },
                "solver": { "stiffness": "high" },
                "models": { "Leaf": {
                    "variables": { "q": { "type": "unknown", "units": "1", "default": 1.0 } },
                    "equations": [{ "lhs": { "op": "D", "args": ["q"], "wrt": "t" }, "rhs": 0.0 }]
                } }
            })
        };
        let root = |file: &str| {
            json!({
                "esm": "2.0.0",
                "metadata": { "name": "root" },
                "models": { "Outer": {
                    "variables": {},
                    "equations": [],
                    "subsystems": { "Leaf": { "ref": file } }
                } }
            })
        };
        std::fs::write(dir.path().join("old_leaf.esm"), leaf("1.0.0").to_string()).unwrap();
        std::fs::write(dir.path().join("new_leaf.esm"), leaf("1.1.0").to_string()).unwrap();
        let e = resolve_subsystem_refs_raw(&mut root("old_leaf.esm"), dir.path())
            .expect_err("a 1.0.0 leaf carrying a `solver` block is refused");
        assert_eq!(e.code, codes::SOLVER_VERSION_TOO_OLD, "{e}");
        resolve_subsystem_refs_raw(&mut root("new_leaf.esm"), dir.path())
            .expect("a 1.1.0 leaf may carry a `solver` block");

        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/invalid/version_gate_newer_mounts_older_solver.esm");
        let e = crate::load_path(&fixture).expect_err("the shared fixture is refused");
        assert!(e.to_string().contains(codes::SOLVER_VERSION_TOO_OLD), "{e}");
    }

    /// esm-spec §9.7.10 form A at both mount forms: a RELATIVE ref in an
    /// edge's injected `expression_template_imports` is authored by the
    /// document carrying the edge, so it resolves against THAT document's
    /// directory, never the mounted leaf's. The shared fixture keeps the leaf
    /// in a subdirectory, where the injected relative ref names nothing.
    #[test]
    fn injected_template_imports_resolve_against_the_mounting_directory() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/conformance/expression_templates/inject_mounting_directory");
        for name in ["subsystem_form.esm", "toplevel_form.esm"] {
            crate::load_path(dir.join(name)).unwrap_or_else(|e| {
                panic!("{name}: the injected library resolves beside the mounting document: {e}")
            });
        }
    }

    /// A load refused at a mount edge keeps its diagnostic code and carries
    /// the edge that does not resolve, at its pointer; the display text is
    /// the one the uncoded error rendered.
    #[test]
    fn a_mount_refusal_carries_its_code_and_the_failing_edge() {
        let dir = TempDir::new().unwrap();
        let two = json!({
            "esm": "2.0.0",
            "metadata": { "name": "two" },
            "models": {
                "A": { "variables": {}, "equations": [] },
                "B": { "variables": {}, "equations": [] }
            }
        });
        std::fs::write(dir.path().join("two.esm"), two.to_string()).unwrap();
        let root = json!({
            "esm": "2.0.0",
            "metadata": { "name": "root" },
            "models": {
                "Outer": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {
                        "Missing": { "ref": "missing.esm" },
                        "Two": { "ref": "two.esm" }
                    }
                },
                "Top": { "ref": "two.esm" }
            }
        });
        let path = dir.path().join("root.esm");
        std::fs::write(&path, root.to_string()).unwrap();
        let e = crate::load_path(&path).expect_err("a missing ref is refused");
        assert_eq!(e.code(), Some(codes::UNRESOLVED_SUBSYSTEM_REF));
        assert!(
            e.to_string()
                .starts_with("Schema validation error: [unresolved_subsystem_ref] "),
            "{e}"
        );
        let found: Vec<(&str, String)> = e
            .findings()
            .iter()
            .map(|f| (f.path.as_str(), f.code.to_string()))
            .collect();
        assert_eq!(
            found,
            vec![
                (
                    "/models/Outer/subsystems/Missing",
                    "unresolved_subsystem_ref".to_string()
                ),
                (
                    "/models/Outer/subsystems/Two",
                    "ambiguous_subsystem_ref".to_string()
                ),
                ("/models/Top", "unresolved_subsystem_ref".to_string()),
            ]
        );
        assert_eq!(
            mount_edge_errors(&root, dir.path()).len(),
            3,
            "the entry point reports what the refusal carries"
        );
    }

    #[test]
    fn test_reject_data_source_only_ref() {
        // A subsystem ref to a SOURCE-ONLY file must be REJECTED. From 1.0.0 a
        // data source is not a component: `$defs/DataSource` says it "cannot be
        // a coupling endpoint, a subsystem, or a scoped-name path root", and a
        // model reaches one only through a parameter whose `update` names it.
        //
        // This test asserted the opposite until 2026-08-20 — that the ref
        // resolved TO the loader object, complete with the `grid` and
        // `variables` blocks that 0.8.0 and 1.0.0 respectively removed. It was
        // a 0.x test relabelled `esm: 1.0.0` without its premise re-examined.
        let dir = TempDir::new().unwrap();
        let source_only = json!({
            "esm": "2.0.0",
            "metadata": { "name": "source-only" },
            "data_sources": {
                "MetData": {
                    "kind": "grid",
                    "source": {
                        "url_template": "https://example.org/data/{date:%Y%m%d}.nc"
                    }
                }
            }
        });
        std::fs::write(
            dir.path().join("source.esm"),
            serde_json::to_string(&source_only).unwrap(),
        )
        .unwrap();

        let mut value = json!({
            "esm": "2.0.0",
            "metadata": { "name": "main" },
            "models": {
                "Outer": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {
                        "Met": { "ref": "source.esm" }
                    }
                }
            }
        });

        let err = resolve_subsystem_refs_raw(&mut value, dir.path())
            .expect_err("a source-only file declares no mountable system");
        assert!(err.to_string().contains("multiple top-level systems"));
    }

    #[test]
    fn test_resolve_model_plus_its_data_sources_ref() {
        // The shape 1.0.0 makes natural, and the one the old count forbade: ONE
        // model plus the sources that model consumes, in one file. The 0.x
        // `X.esm` / `X_loader.esm` split existed only because a loader was a
        // component; with sources uncounted this mounts like any other model.
        let dir = TempDir::new().unwrap();
        let leaf = json!({
            "esm": "2.0.0",
            "metadata": { "name": "leaf" },
            "data_sources": {
                "MetData": {
                    "kind": "grid",
                    "source": { "url_template": "https://example.org/{var}.nc" }
                }
            },
            "models": {
                "Leaf": {
                    "variables": {
                        "T": {
                            "type": "parameter",
                            "units": "K",
                            "shape": [],
                            "update": {
                                "kind": "data",
                                "source": "MetData",
                                "from": { "file_variable": "temperature" }
                            }
                        }
                    },
                    "equations": []
                }
            }
        });
        std::fs::write(
            dir.path().join("leaf.esm"),
            serde_json::to_string(&leaf).unwrap(),
        )
        .unwrap();

        let mut value = json!({
            "esm": "2.0.0",
            "metadata": { "name": "main" },
            "models": {
                "Outer": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {
                        "Met": { "ref": "leaf.esm" }
                    }
                }
            }
        });

        resolve_subsystem_refs_raw(&mut value, dir.path()).unwrap();

        // The ref is replaced by the single MODEL — the sources rode along in
        // the document but were never candidates for the mount.
        let resolved = &value["models"]["Outer"]["subsystems"]["Met"];
        assert!(resolved.get("ref").is_none());
        assert_eq!(resolved["variables"]["T"]["update"]["source"], "MetData");
    }

    #[test]
    fn test_reject_remote_ref() {
        let mut value = json!({
            "esm": "2.0.0",
            "metadata": { "name": "main" },
            "models": {
                "Outer": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {
                        "Remote": { "ref": "https://example.com/inner.json" }
                    }
                }
            }
        });

        let result = resolve_subsystem_refs_raw(&mut value, Path::new("/tmp"));
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("Remote subsystem refs")
        );
    }

    #[test]
    fn test_circular_ref_detection() {
        let dir = TempDir::new().unwrap();
        let a = json!({
            "esm": "2.0.0",
            "metadata": { "name": "a" },
            "models": {
                "A": {
                    "variables": {},
                    "equations": [],
                    "subsystems": { "Cycle": { "ref": "b.json" } }
                }
            }
        });
        let b = json!({
            "esm": "2.0.0",
            "metadata": { "name": "b" },
            "models": {
                "B": {
                    "variables": {},
                    "equations": [],
                    "subsystems": { "Cycle": { "ref": "a.json" } }
                }
            }
        });
        std::fs::write(
            dir.path().join("a.json"),
            serde_json::to_string(&a).unwrap(),
        )
        .unwrap();
        std::fs::write(
            dir.path().join("b.json"),
            serde_json::to_string(&b).unwrap(),
        )
        .unwrap();

        let mut value = json!({
            "esm": "2.0.0",
            "metadata": { "name": "main" },
            "models": {
                "Root": {
                    "variables": {},
                    "equations": [],
                    "subsystems": { "Start": { "ref": "a.json" } }
                }
            }
        });

        let result = resolve_subsystem_refs_raw(&mut value, dir.path());
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("circular"));
    }

    #[test]
    fn test_nonexistent_ref() {
        let dir = TempDir::new().unwrap();
        let mut value = json!({
            "esm": "2.0.0",
            "metadata": { "name": "main" },
            "models": {
                "Outer": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {
                        "Missing": { "ref": "does-not-exist.json" }
                    }
                }
            }
        });

        let result = resolve_subsystem_refs_raw(&mut value, dir.path());
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("failed to resolve ref")
        );
    }

    #[test]
    fn test_resolves_inside_reaction_systems() {
        let dir = TempDir::new().unwrap();
        let sub = json!({
            "esm": "2.0.0",
            "metadata": { "name": "sub" },
            "reaction_systems": {
                "Sub": {
                    "species": {},
                    "parameters": {},
                    "reactions": []
                }
            }
        });
        std::fs::write(
            dir.path().join("sub.json"),
            serde_json::to_string(&sub).unwrap(),
        )
        .unwrap();

        let mut value = json!({
            "esm": "2.0.0",
            "metadata": { "name": "main" },
            "reaction_systems": {
                "Main": {
                    "species": {},
                    "parameters": {},
                    "reactions": [],
                    "subsystems": {
                        "SubKey": { "ref": "sub.json" }
                    }
                }
            }
        });

        resolve_subsystem_refs_raw(&mut value, dir.path()).unwrap();
        let resolved = &value["reaction_systems"]["Main"]["subsystems"]["SubKey"];
        assert!(resolved.get("species").is_some());
        assert!(resolved.get("ref").is_none());
    }

    /// API_SPEC.md §8 item 14: the canonical `resolve_subsystem_refs` takes a
    /// TYPED document, as Julia, Python and TypeScript do. It must resolve
    /// exactly what the raw seam resolves.
    #[test]
    fn typed_resolve_subsystem_refs_matches_the_raw_pass() {
        let dir = TempDir::new().unwrap();
        let inner = json!({
            "esm": "2.0.0",
            "metadata": { "name": "inner" },
            "models": { "Inner": { "variables": {}, "equations": [] } }
        });
        std::fs::write(
            dir.path().join("inner.json"),
            serde_json::to_string(&inner).unwrap(),
        )
        .unwrap();

        let doc = json!({
            "esm": "2.0.0",
            "metadata": { "name": "main" },
            "models": {
                "Outer": {
                    "variables": {},
                    "equations": [],
                    "subsystems": { "Inner": { "ref": "inner.json" } }
                }
            }
        });

        let mut raw = doc.clone();
        resolve_subsystem_refs_raw(&mut raw, dir.path()).unwrap();

        let mut typed: crate::EsmFile = serde_json::from_value(doc).expect("typed document");
        resolve_subsystem_refs(&mut typed, dir.path()).unwrap();

        let inner_resolved = &typed.models.as_ref().unwrap()["Outer"]
            .subsystems
            .as_ref()
            .unwrap()["Inner"];
        assert!(
            inner_resolved.as_inline().is_some(),
            "the mount is spliced in"
        );
        assert_eq!(serde_json::to_value(&typed).unwrap(), raw);
    }
}
