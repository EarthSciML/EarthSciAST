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

use crate::diagnostic::{DiagnosticError, err};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

/// Capture a document's closed metaparameter environment from its top-level
/// `metaparameters` block: each name's integer `default`, overlaid with the
/// loader-API `api_meta` bindings (esm-spec §9.7.6 sites 4-5). This is the
/// scope against which a §4.7 subsystem-edge binding EXPRESSION folds at the
/// mount (e.g. `NTGT = NX*NY`), captured BEFORE the root template-machinery
/// pass consumes the `metaparameters` block. Mirrors the Python `load()`
/// `root_meta_env`.
fn root_metaparameter_env(
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
/// The merge is scoped to MODEL subsystems, matching the Julia resolver (a
/// mounted mesh file whose axis size disagrees with the importer must fail at
/// load rather than the importer silently winning).
///
/// # Arguments
///
/// * `value` - the parsed ESM JSON to resolve (modified in place)
/// * `base_path` - directory to resolve relative file paths against
pub fn resolve_subsystem_refs(value: &mut Value, base_path: &Path) -> Result<(), DiagnosticError> {
    resolve_subsystem_refs_with_metaparameters(value, base_path, &BTreeMap::new())
}

/// Like [`resolve_subsystem_refs`], but with the loader-API metaparameter
/// bindings (esm-spec §9.7.6 site 4) available, so a §4.7 subsystem-edge
/// binding EXPRESSION (`NTGT = NX*NY`, §9.7.6 site 3) folds against the root
/// document's closed metaparameter environment (defaults overlaid with the API
/// bindings) at the mount. Mirrors the Python `resolve_model_refs(...,
/// parent_metaparameters=root_meta_env)`.
pub fn resolve_subsystem_refs_with_metaparameters(
    value: &mut Value,
    base_path: &Path,
    api_meta: &BTreeMap<String, i64>,
) -> Result<(), DiagnosticError> {
    let root_meta = root_metaparameter_env(value, api_meta);
    let mut visited = HashSet::new();
    walk_top_level(value, base_path, &mut visited, &root_meta)
}

/// Merge a referenced subsystem file's top-level `index_sets` into the
/// importing document's `registry` (esm-spec §4.7). Deep-equal redeclaration is
/// idempotent; a non-deep-equal collision is `subsystem_index_set_conflict`.
/// (`serde_json` `Map` equality is order-independent structural equality, the
/// JSON-level analogue of the Julia typed field-wise deep-equal.)
fn merge_subsystem_index_sets(
    registry: &mut Map<String, Value>,
    loaded: &Map<String, Value>,
    ref_str: &str,
) -> Result<(), DiagnosticError> {
    for (n, decl) in loaded {
        if let Some(existing) = registry.get(n) {
            if existing != decl {
                return Err(err(
                    "subsystem_index_set_conflict",
                    format!(
                        "index set '{n}' from subsystem ref \
                         '{ref_str}' collides with a non-deep-equal declaration in the importing \
                         document. A referenced subsystem file's top-level index_sets merge into \
                         the importing document's registry; deep-equal redeclaration is \
                         idempotent, a size/kind disagreement is a load-time error (esm-spec §4.7)."
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
    code: "unresolved_subsystem_ref",
};

/// A subsystem ref that resolved to a file containing MULTIPLE (or zero)
/// top-level systems — the ref mechanism requires exactly one, so which system
/// to mount is ambiguous. Distinct from a ref that could not be resolved at all.
const AMBIGUOUS_SUBSYSTEM_REF: &str = "ambiguous_subsystem_ref";

/// A top-level `models.<k>` mount edge (used by [`inline_toplevel_model_refs`]).
const TOPLEVEL_MODEL_REF: RefNoun = RefNoun {
    remote_plural: "top-level model refs",
    cycle_singular: "top-level model reference",
    item: "top-level model ref",
    code: "toplevel_model_ref_unresolved",
};

/// The shared "load a referenced .esm document" sequence both ref-resolvers run:
/// reject a remote URL, canonicalize `ref_str` against `base`, guard against a
/// cycle, mark the path visited, then read + parse it. Returns the canonical
/// path (still marked visited) and the parsed JSON.
///
/// On success the CALLER owns the visited mark: it recurses into the loaded
/// document (so nested refs see this path on the stack) and must
/// `visited.remove(&canonical)` when done — mirroring the manual insert/remove
/// this used to duplicate at both sites. On any failure here the mark is not
/// left dangling (it is removed before returning a read/parse error, and is
/// never inserted on the URL / canonicalize / cycle errors).
fn load_ref_document(
    ref_str: &str,
    base: &Path,
    visited: &mut HashSet<PathBuf>,
    noun: &RefNoun,
) -> Result<(PathBuf, Value), DiagnosticError> {
    if ref_str.starts_with("http://") || ref_str.starts_with("https://") {
        return Err(err(
            noun.code,
            format!(
                "Remote {} are not supported in the Rust loader; \
                 download {ref_str:?} to a local file first",
                noun.remote_plural
            ),
        ));
    }

    let canonical = base.join(ref_str).canonicalize().map_err(|e| {
        err(
            noun.code,
            format!("failed to resolve {} {ref_str:?}: {e}", noun.item),
        )
    })?;

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

    let loaded = (|| -> Result<Value, DiagnosticError> {
        let content = std::fs::read_to_string(&canonical).map_err(|e| {
            err(
                noun.code,
                format!(
                    "failed to read {} {}: {}",
                    noun.item,
                    canonical.display(),
                    e
                ),
            )
        })?;
        serde_json::from_str(&content).map_err(|e| {
            err(
                noun.code,
                format!(
                    "failed to parse {} {}: {}",
                    noun.item,
                    canonical.display(),
                    e
                ),
            )
        })
    })();

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

fn walk_top_level(
    value: &mut Value,
    base_path: &Path,
    visited: &mut HashSet<PathBuf>,
    parent_meta: &BTreeMap<String, i64>,
) -> Result<(), DiagnosticError> {
    let obj = match value.as_object_mut() {
        Some(o) => o,
        None => return Ok(()),
    };

    // esm-spec §4.7 / §9.7.10: a top-level `models.<k>` that is a bare `{ref}`
    // (has `ref`, no inline `variables`) is a model-ref MOUNT EDGE — splice in
    // the referenced leaf's single model, carrying the edge's
    // `expression_template_imports` into that model's own scope, BEFORE the
    // ordinary subsystem walk (the spliced model may itself carry subsystems).
    // Resolution of the injected discretization is DEFERRED to the root
    // template-machinery pass (`load_with_options`), so the loader-API
    // metaparameters (grid resolution) reach the leaf document-wide — mirroring
    // the Julia inliner (`_inline_toplevel_model_refs!`).
    inline_toplevel_model_refs(obj, base_path, visited)?;

    // The importing document's index-set registry starts from its own
    // top-level `index_sets`; model subsystem refs merge theirs into it
    // (esm-spec §4.7). Reaction-system subsystem refs do NOT merge (Julia
    // resolver scope), so they thread `None`.
    let mut registry: Map<String, Value> = obj
        .get("index_sets")
        .and_then(|v| v.as_object())
        .cloned()
        .unwrap_or_default();

    if let Some(map) = obj.get_mut("models").and_then(|v| v.as_object_mut()) {
        for (_name, system) in map.iter_mut() {
            walk_subsystems(system, base_path, visited, Some(&mut registry), parent_meta)?;
        }
    }
    if let Some(map) = obj
        .get_mut("reaction_systems")
        .and_then(|v| v.as_object_mut())
    {
        for (_name, system) in map.iter_mut() {
            walk_subsystems(system, base_path, visited, None, parent_meta)?;
        }
    }

    // Write the merged registry back so the merged axes are visible post-load
    // (and, for a file loaded as a subsystem ref, so the importer can read this
    // file's complete index_sets to merge in turn).
    if !registry.is_empty() {
        obj.insert("index_sets".to_string(), Value::Object(registry));
    }
    Ok(())
}

/// Inline every top-level `models.<k>` MOUNT EDGE — a bare `{ref}` (has `ref`,
/// no inline `variables`) — by splicing in the referenced leaf's single model,
/// with the edge's `expression_template_imports` folded into that model's own
/// scope (esm-spec §9.7.10 form A at a top-level model-ref edge). Mirrors the
/// Julia `_inline_toplevel_model_refs!`:
///
/// * the leaf's own nested top-level model-refs are inlined first (component of
///   component), sharing this walk's path-scoped cycle set;
/// * the leaf's single model (or the `model`-selected one) is spliced in;
/// * the model's own relative `{ref}`s (its `expression_template_imports`,
///   subsystems) are absolutized against the LEAF's dir, and the edge's imports
///   against THIS document's dir, so both resolve after the model lands in a
///   parent whose directory differs;
/// * the leaf's `function_tables` / `data_loaders` / `enums` are merged in
///   (parent wins on a key clash).
///
/// The injected discretization is NOT resolved here — it is left as model-level
/// `expression_template_imports` for the root template-machinery pass, so the
/// loader-API metaparameters reach the leaf document-wide.
fn inline_toplevel_model_refs(
    obj: &mut Map<String, Value>,
    base_path: &Path,
    visited: &mut HashSet<PathBuf>,
) -> Result<(), DiagnosticError> {
    let edge_names: Vec<String> = match obj.get("models").and_then(|v| v.as_object()) {
        Some(models) => models
            .iter()
            .filter(|(_, m)| {
                m.is_object() && m.get("ref").is_some() && m.get("variables").is_none()
            })
            .map(|(k, _)| k.clone())
            .collect(),
        None => return Ok(()),
    };
    if edge_names.is_empty() {
        return Ok(());
    }

    for name in edge_names {
        let entry = obj
            .get_mut("models")
            .and_then(|v| v.as_object_mut())
            .and_then(|m| m.remove(&name))
            .expect("edge entry present");
        let entry_obj = entry.as_object().expect("edge entry is an object");
        let ref_str = entry_obj
            .get("ref")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                err(
                    TOPLEVEL_MODEL_REF.code,
                    "top-level model ref must be a string",
                )
            })?;
        let (canonical, mut comp) =
            load_ref_document(ref_str, base_path, visited, &TOPLEVEL_MODEL_REF)?;
        let leaf_dir = canonical.parent().unwrap_or(base_path).to_path_buf();

        // `comp` stays owned here; the closure only borrows it (so the visited
        // mark can be removed and `comp`'s by-name blocks merged below on every
        // exit path), and yields the spliced model.
        let build: Result<Value, DiagnosticError> = (|| {
            // Component-of-component: inline the leaf's own top-level model-refs.
            if let Some(comp_obj) = comp.as_object_mut() {
                inline_toplevel_model_refs(comp_obj, &leaf_dir, visited)?;
            }
            let sel = entry_obj.get("model").and_then(|v| v.as_str());
            let mut model = extract_toplevel_model(&comp, sel, ref_str, &canonical)?;
            // The leaf model's own relative refs anchor at the leaf's dir; the
            // edge's injected imports anchor at THIS document's dir (§9.7.10
            // merge order: target's own first, then injected).
            absolutize_nested_refs(&mut model, &leaf_dir);
            if let Some(imports) = entry_obj
                .get("expression_template_imports")
                .and_then(|v| v.as_array())
            {
                let mut injected = imports.clone();
                for e in injected.iter_mut() {
                    absolutize_nested_refs(e, base_path);
                }
                append_component_imports(
                    model.as_object_mut().ok_or_else(|| {
                        err(
                            TOPLEVEL_MODEL_REF.code,
                            format!("top-level model ref {ref_str:?} is not an object"),
                        )
                    })?,
                    injected,
                );
            }
            Ok(model)
        })();
        visited.remove(&canonical);
        let model = build?;

        // Splice the resolved model back under the same key, then merge the
        // leaf's by-name blocks (parent wins on a clash).
        obj.get_mut("models")
            .and_then(|v| v.as_object_mut())
            .expect("models map present")
            .insert(name, model);
        for blk in ["function_tables", "data_loaders", "enums"] {
            let Some(src) = comp.get(blk).and_then(|v| v.as_object()) else {
                continue;
            };
            if src.is_empty() {
                continue;
            }
            let src = src.clone();
            let dst = obj
                .entry(blk.to_string())
                .or_insert_with(|| Value::Object(Map::new()));
            if let Some(dst) = dst.as_object_mut() {
                for (k, v) in src {
                    dst.entry(k).or_insert(v);
                }
            }
        }
    }
    Ok(())
}

/// Extract the single top-level model from a referenced component file (or the
/// `sel`-named one when the file holds several), for a top-level model-ref mount.
fn extract_toplevel_model(
    comp: &Value,
    sel: Option<&str>,
    ref_str: &str,
    source: &Path,
) -> Result<Value, DiagnosticError> {
    let models = comp
        .as_object()
        .and_then(|o| o.get("models"))
        .and_then(|v| v.as_object())
        .ok_or_else(|| {
            err(
                TOPLEVEL_MODEL_REF.code,
                format!(
                    "top-level model ref '{ref_str}' resolves to a file with no models block ({})",
                    source.display()
                ),
            )
        })?;
    match sel {
        Some(name) => models.get(name).cloned().ok_or_else(|| {
            let mut avail: Vec<&String> = models.keys().collect();
            avail.sort();
            err(
                TOPLEVEL_MODEL_REF.code,
                format!(
                    "top-level model ref '{ref_str}' has no model '{name}' (available: {})",
                    avail
                        .iter()
                        .map(|s| s.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            )
        }),
        None => {
            if models.len() == 1 {
                Ok(models.values().next().cloned().expect("one model"))
            } else {
                let mut avail: Vec<&String> = models.keys().collect();
                avail.sort();
                Err(err(
                    TOPLEVEL_MODEL_REF.code,
                    format!(
                        "top-level model ref '{ref_str}' resolves to {} models; add a \"model\" \
                         selector to choose one (available: {})",
                        models.len(),
                        avail
                            .iter()
                            .map(|s| s.as_str())
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                ))
            }
        }
    }
}

/// Append raw §9.7.2 import entries to a model's own
/// `expression_template_imports` (esm-spec §9.7.10 merge order: the target's own
/// imports first, then the injected list).
fn append_component_imports(model: &mut Map<String, Value>, injected: Vec<Value>) {
    let arr = model
        .entry("expression_template_imports".to_string())
        .or_insert_with(|| Value::Array(Vec::new()));
    if let Some(arr) = arr.as_array_mut() {
        arr.extend(injected);
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
                let is_abs =
                    r.starts_with('/') || r.starts_with("http://") || r.starts_with("https://");
                if !is_abs {
                    let joined = base_dir.join(r.as_str());
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
    base_path: &Path,
    visited: &mut HashSet<PathBuf>,
    mut registry: Option<&mut Map<String, Value>>,
    parent_meta: &BTreeMap<String, i64>,
) -> Result<(), DiagnosticError> {
    let obj = match value.as_object_mut() {
        Some(o) => o,
        None => return Ok(()),
    };

    let subs_val = match obj.get_mut("subsystems") {
        Some(v) => v,
        None => return Ok(()),
    };

    let subs = match subs_val.as_object_mut() {
        Some(m) => m,
        None => return Ok(()),
    };

    let names: Vec<String> = subs.keys().cloned().collect();
    for name in names {
        let entry = subs.remove(&name).unwrap_or(Value::Null);
        let resolved = resolve_value(
            entry,
            base_path,
            visited,
            registry.as_deref_mut(),
            parent_meta,
        )?;
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
) -> Result<std::collections::BTreeMap<String, i64>, DiagnosticError> {
    let mut out = std::collections::BTreeMap::new();
    let Some(bindings) = obj.get("bindings") else {
        return Ok(out);
    };
    let Some(bindings_obj) = bindings.as_object() else {
        return Err(err(
            "metaparameter_type_error",
            "subsystem ref `bindings` must be an object of \
             metaparameter expressions (esm-spec 9.7.6)",
        ));
    };
    for (k, v) in bindings_obj {
        let ctx = format!("subsystem ref, binding '{k}'");
        // Structural grammar check at the edge (bad op / empty args / float —
        // even with a symbolic arg), then fold against the mounting scope.
        crate::template_imports::require_meta_expr(v, &ctx)?;
        let folded = crate::template_imports::eval_meta_expr(v, parent_meta, &ctx)?;
        out.insert(k.clone(), folded);
    }
    Ok(out)
}

/// If `value` is a `{ "ref": "..." }` object, load the referenced file and
/// inline the single top-level system from it. Otherwise recurse into the
/// value's own `subsystems` map.
///
/// esm-spec §9.7: a subsystem ref MUST NOT target a template-library file
/// (`subsystem_ref_is_template_library` — the two reference mechanisms are
/// disjoint, §9.7.1), and the referenced document's own §9.7 machinery
/// (template imports + metaparameters) is resolved in the referenced file's
/// directory, closed with this edge's `bindings` (§9.7.6 binding site 3) and
/// lowered to the §9.6.3 fixpoint, before the single component is extracted.
/// Template-import diagnostics propagate as
/// [`crate::lower_expression_templates::ExpressionTemplateError`] (a
/// [`DiagnosticError`]), carrying their stable `code`, matching how `load()`
/// surfaces them.
fn resolve_value(
    value: Value,
    base_path: &Path,
    visited: &mut HashSet<PathBuf>,
    registry: Option<&mut Map<String, Value>>,
    parent_meta: &BTreeMap<String, i64>,
) -> Result<Value, DiagnosticError> {
    if let Some(obj) = value.as_object()
        && let Some(ref_val) = obj.get("ref")
    {
        let ref_str = ref_val
            .as_str()
            .ok_or_else(|| err(SUBSYSTEM_REF.code, "subsystem ref must be a string"))?;

        let (canonical, mut parsed) =
            load_ref_document(ref_str, base_path, visited, &SUBSYSTEM_REF)?;

        // A §4.7 subsystem ref MUST NOT target a template-library file — the
        // two reference mechanisms are disjoint (esm-spec §9.7.1).
        if crate::template_imports::is_template_library_doc(&parsed) {
            visited.remove(&canonical);
            return Err(err(
                "subsystem_ref_is_template_library",
                format!(
                    "Subsystem ref '{ref_str}' targets a \
                     template-library file ({}); libraries are imported via \
                     expression_template_imports (esm-spec 9.7.1)",
                    canonical.display()
                ),
            ));
        }

        // Likewise, a §4.7 subsystem ref MUST NOT target a coupling-library
        // file — those are imported via a `coupling_import` coupling entry, not
        // mounted as a subsystem (esm-spec §10.9).
        if crate::coupling_imports::is_coupling_library_doc(&parsed) {
            visited.remove(&canonical);
            return Err(err(
                "subsystem_ref_is_coupling_library",
                format!(
                    "Subsystem ref '{ref_str}' targets a \
                     coupling-library file ({}); libraries are imported via a coupling_import \
                     coupling entry (esm-spec 10.9)",
                    canonical.display()
                ),
            ));
        }

        // Resolve the referenced document's §9.7 machinery in its own
        // directory, closing its metaparameters with this edge's `bindings`
        // (esm-spec §9.7.6 binding site 3), then run the §9.6.3 fixpoint so
        // the inlined component carries only concrete Expression ASTs.
        let parent_dir = canonical.parent().unwrap_or(base_path).to_path_buf();
        let edge_result: Result<(), DiagnosticError> = (|| {
            crate::lower_expression_templates::reject_expression_templates_pre_v04(&parsed)?;
            crate::template_imports::reject_template_imports_pre_v08(&parsed)?;
            let bindings = read_edge_bindings(obj, parent_meta)?;
            // esm-spec §9.7.10 form A: the edge's `expression_template_imports`
            // inject a discretization into the referenced component's own
            // scope, appended BEFORE resolution so the §9.6.3 fixpoint lowers
            // its rewrite-targets at the mount. Consumed here (does not survive
            // parse → emit; the mount round-trips as the lowered inline
            // component). Refs resolve against the referenced file's directory.
            let injected: Vec<Value> = obj
                .get("expression_template_imports")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            crate::template_imports::apply_scope_injections(&mut parsed, &injected)?;
            if let Some(mut resolved) = crate::template_imports::resolve_template_machinery(
                &parsed,
                &parent_dir,
                &bindings,
            )? {
                crate::lower_expression_templates::lower_expression_templates(&mut resolved)?;
                parsed = resolved;
            }
            Ok(())
        })();
        if let Err(e) = edge_result {
            visited.remove(&canonical);
            return Err(e);
        }

        // Recursively resolve any refs inside the loaded file, then merge its
        // top-level `index_sets` into the importing document's registry
        // (esm-spec §4.7, bottom-up; `registry` is `None` for reaction-system
        // subsystem refs). Wrapped in a closure so `visited.remove` below runs
        // on the error paths too — a load error aborts the whole resolution
        // today, but a path left marked visited would silently skip the file
        // if resolution ever becomes partially recoverable.
        let nested_result = (|| -> Result<(), DiagnosticError> {
            // The referenced document's own metaparameters were just closed and
            // folded by `resolve_template_machinery` above, so any binding on
            // its OWN nested subsystem refs arrives with metaparameter names
            // already substituted to concrete integers — its refs fold against
            // an empty environment (esm-spec §9.7.6: refs resolve post-close).
            walk_top_level(&mut parsed, &parent_dir, visited, &BTreeMap::new())?;
            if let Some(reg) = registry
                && let Some(loaded) = parsed.get("index_sets").and_then(|v| v.as_object())
            {
                merge_subsystem_index_sets(reg, &loaded.clone(), ref_str)?;
            }
            Ok(())
        })();

        visited.remove(&canonical);
        nested_result?;

        return extract_single_system(parsed, &canonical);
    }

    let mut value = value;
    walk_subsystems(&mut value, base_path, visited, registry, parent_meta)?;
    Ok(value)
}

/// A referenced file must contain exactly one top-level model, reaction
/// system, or data loader. Extract that single entry as a JSON value to inline
/// into the caller's subsystem slot. Precedence is models -> reaction_systems
/// -> data_loaders.
fn extract_single_system(value: Value, source: &Path) -> Result<Value, DiagnosticError> {
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
    // → `data_loaders`) and took the first that happened to hold exactly one
    // entry. A file with TWO models and ONE data loader therefore fell past the
    // ambiguous `models` map and silently mounted the LOADER — the caller asked
    // for a subsystem and got a completely different object, with no diagnostic.
    // That is precisely tests/invalid/subsystem_ref_ambiguous.esm (2 models +
    // 1 loader), and it is a worse failure than the error it was avoiding.
    let systems: Vec<&Value> = ["models", "reaction_systems", "data_loaders"]
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tempfile::TempDir;

    #[test]
    fn test_resolve_no_refs() {
        let mut value = json!({
            "esm": "0.1.0",
            "metadata": { "name": "test" },
            "models": {
                "Main": { "variables": {}, "equations": [] }
            }
        });
        let result = resolve_subsystem_refs(&mut value, Path::new("/tmp"));
        assert!(result.is_ok());
    }

    #[test]
    fn test_resolve_local_subsystem_ref() {
        let dir = TempDir::new().unwrap();
        let inner = json!({
            "esm": "0.1.0",
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
            "esm": "0.1.0",
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

        resolve_subsystem_refs(&mut value, dir.path()).unwrap();

        let inner_resolved = &value["models"]["Outer"]["subsystems"]["Inner"];
        assert!(inner_resolved.get("variables").is_some());
        assert!(inner_resolved.get("ref").is_none());
    }

    #[test]
    fn test_resolve_local_data_loader_ref() {
        // A subsystem ref to a LOADER-ONLY file (top-level `data_loaders` with
        // exactly one entry, no `models`) must resolve to the loader object.
        let dir = TempDir::new().unwrap();
        let loader = json!({
            "esm": "0.1.0",
            "metadata": { "name": "loader-only" },
            "data_loaders": {
                "MetData": {
                    "kind": "grid",
                    "source": {
                        "url_template": "https://example.org/data/{date:%Y%m%d}.nc"
                    },
                    "grid": {
                        "family": "cartesian",
                        "crs": { "projection": "longlat", "datum": "WGS84" },
                        "dimensions": ["lon", "lat"],
                        "extents": {
                            "lon": { "n": "n_lon", "spacing": "uniform" },
                            "lat": { "n": "n_lat", "spacing": "uniform" }
                        },
                        "parameters": {
                            "n_lon": { "description": "lon cell count" },
                            "n_lat": { "description": "lat cell count" }
                        }
                    },
                    "variables": {
                        "T": {
                            "file_variable": "temperature",
                            "units": "K",
                            "description": "Air temperature"
                        }
                    }
                }
            }
        });
        std::fs::write(
            dir.path().join("loader.esm"),
            serde_json::to_string(&loader).unwrap(),
        )
        .unwrap();

        let mut value = json!({
            "esm": "0.1.0",
            "metadata": { "name": "main" },
            "models": {
                "Outer": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {
                        "Met": { "ref": "loader.esm" }
                    }
                }
            }
        });

        resolve_subsystem_refs(&mut value, dir.path()).unwrap();

        let resolved = &value["models"]["Outer"]["subsystems"]["Met"];
        // The ref is replaced by the single top-level data loader object.
        assert!(resolved.get("ref").is_none());
        assert_eq!(resolved["kind"], "grid");
        assert!(resolved.get("source").is_some());
        assert_eq!(
            resolved["source"]["url_template"],
            "https://example.org/data/{date:%Y%m%d}.nc"
        );
        assert!(resolved.get("variables").is_some());
        assert_eq!(resolved["variables"]["T"]["file_variable"], "temperature");
    }

    #[test]
    fn test_reject_remote_ref() {
        let mut value = json!({
            "esm": "0.1.0",
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

        let result = resolve_subsystem_refs(&mut value, Path::new("/tmp"));
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
            "esm": "0.1.0",
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
            "esm": "0.1.0",
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
            "esm": "0.1.0",
            "metadata": { "name": "main" },
            "models": {
                "Root": {
                    "variables": {},
                    "equations": [],
                    "subsystems": { "Start": { "ref": "a.json" } }
                }
            }
        });

        let result = resolve_subsystem_refs(&mut value, dir.path());
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("circular"));
    }

    #[test]
    fn test_nonexistent_ref() {
        let dir = TempDir::new().unwrap();
        let mut value = json!({
            "esm": "0.1.0",
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

        let result = resolve_subsystem_refs(&mut value, dir.path());
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
            "esm": "0.1.0",
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
            "esm": "0.1.0",
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

        resolve_subsystem_refs(&mut value, dir.path()).unwrap();
        let resolved = &value["reaction_systems"]["Main"]["subsystems"]["SubKey"];
        assert!(resolved.get("species").is_some());
        assert!(resolved.get("ref").is_none());
    }
}
