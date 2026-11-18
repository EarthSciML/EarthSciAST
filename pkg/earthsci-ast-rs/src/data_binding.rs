//! Binding a document's `data_sources` to readers (esm-spec §8.9).
//!
//! A document whose parameters declare `update: {kind: "data", …}` reads its
//! numbers off disk. Nothing in this crate opens a file on its own: a build
//! takes its data through [`crate::problem::ProblemOptions::providers`], and a
//! host that supplies none evaluates every data-fed parameter at its `default`
//! and reports the result as the document's answer. [`bind_data_sources`] is
//! the one entry that turns a loaded document into the providers its sources
//! name, so no host has to re-derive that, or the ordering rule it carries.
//!
//! The reader is EarthSciIO, behind the opt-in `esio` feature (a dependency
//! tree no library consumer should have to build). A build without it still
//! detects a consumed source and refuses: the two builds differ in what they
//! can read, never in whether they say so.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;

use crate::error::{EsmError, MessageError};
use crate::provider::{BuildProviderFactory, ProviderError};
use crate::types::EsmFile;

/// A document bound to its `data_sources`, as [`bind_data_sources`] returns it.
#[derive(Clone)]
pub struct BoundDocument {
    /// The document to build: re-loaded with every metaparameter a source
    /// measured closed, or the input unchanged when none did.
    pub file: EsmFile,
    /// Builds the providers for [`Self::file`]'s consumed sources, once per
    /// build; `None` when the document consumes no source.
    pub providers: Option<Arc<BuildProviderFactory<'static>>>,
}

impl std::fmt::Debug for BoundDocument {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BoundDocument")
            .field("file", &self.file)
            .field("providers", &self.providers.is_some())
            .finish()
    }
}

fn bound(file: EsmFile, providers: Option<Arc<BuildProviderFactory<'static>>>) -> BoundDocument {
    BoundDocument { file, providers }
}

/// Bind `file`'s consumed `data_sources` to readers, closing every
/// metaparameter a source's `extent` binds first.
///
/// Returns the document to build, re-loaded through `reload` with the closed
/// metaparameters when a source measured one, and the provider factory for
/// it: call it once per build and put what it returns in
/// [`crate::problem::ProblemOptions::providers`] with
/// [`crate::problem::ProblemOptions::build_pipeline`] set, or hand it to the
/// inline-test runner as `InlineTestOptions::providers`. A document that
/// consumes no source comes back unchanged, with no factory and no cost.
///
/// **The ordering rule.** esm-spec §8.9.4 puts the sampling of a source that
/// measures its own extent BEFORE the document's metaparameters are closed
/// (§9.7.6 site 4). An index set declared `size: "N_REC"` is folded to an
/// integer at load, so a host that loads once has already frozen the row
/// count at the declaration's default, and every shape downstream is wrong
/// (for a count not knowable until the table is read, zero-length, so an
/// aggregate over it is a sum over no rows). `reload` is called with the
/// discovered extents, keyed by metaparameter, and must load the same document
/// with them bound, for example
/// `|mp| load_path_with_options(path, mp)`. Every source naming the same
/// metaparameter must measure the same number of records; a disagreement is
/// refused.
///
/// **Best effort sampling.** A source that cannot be constructed or sampled
/// during the extent pass is not reported here: the factory reports it, with
/// the source named, to the build that needed the data. Only a disagreement
/// between extents and a failed `reload` are errors of this pass.
///
/// `cache_root` is EarthSciIO's content-addressed cache directory.
///
/// **Without the `esio` feature** there is no reader, so a document that
/// consumes a source is refused, naming the source, the parameters that read
/// it, and the feature: running it would evaluate every data-fed parameter at
/// its `default`.
pub fn bind_data_sources(
    file: EsmFile,
    cache_root: &Path,
    reload: impl FnOnce(&BTreeMap<String, i64>) -> Result<EsmFile, EsmError>,
) -> Result<BoundDocument, ProviderError> {
    let consumed = consumed_of(&file)?;
    if consumed.is_empty() {
        return Ok(bound(file, None));
    }
    bind_consumed(file, consumed, cache_root, reload)
}

/// The consumed sources of `file` ([`consumed_data_sources`] over its JSON).
fn consumed_of(file: &EsmFile) -> Result<BTreeMap<String, Vec<String>>, ProviderError> {
    if file.data_sources.as_ref().is_none_or(|m| m.is_empty()) {
        return Ok(BTreeMap::new());
    }
    let doc = serde_json::to_value(file)
        .map_err(|e| MessageError(format!("serializing the document for data_sources: {e}")))?;
    Ok(consumed_data_sources(&doc))
}

#[cfg(not(feature = "esio"))]
fn bind_consumed(
    _file: EsmFile,
    consumed: BTreeMap<String, Vec<String>>,
    _cache_root: &Path,
    _reload: impl FnOnce(&BTreeMap<String, i64>) -> Result<EsmFile, EsmError>,
) -> Result<BoundDocument, ProviderError> {
    Err(MessageError(format!(
        "cannot ingest data_sources: earthsci-ast was built WITHOUT the `esio` \
         feature, so it links no data reader, but the document declares {} that {} \
         read: {}. Rebuild with the `esio` feature (for the `esm` tool, \
         `cargo build --release --features esio`; see pkg/earthsci-ast-rs/Cargo.toml). \
         Running anyway would evaluate every data-fed parameter at its `default` \
         and report the result as the document's answer.",
        if consumed.len() == 1 {
            "a source"
        } else {
            "sources"
        },
        if consumed.len() == 1 {
            "it"
        } else {
            "its parameters"
        },
        consumed_summary(&consumed)
    )))
}

#[cfg(feature = "esio")]
fn bind_consumed(
    file: EsmFile,
    consumed: BTreeMap<String, Vec<String>>,
    cache_root: &Path,
    reload: impl FnOnce(&BTreeMap<String, i64>) -> Result<EsmFile, EsmError>,
) -> Result<BoundDocument, ProviderError> {
    let make = esio_factory(&file, consumed, cache_root)?;
    let Ok(provs) = make() else {
        return Ok(bound(file, Some(make)));
    };

    let mut extents: BTreeMap<String, i64> = BTreeMap::new();
    for (key, mut prov) in provs {
        let Some(mp) = prov.extent_metaparameter() else {
            continue;
        };
        let Ok(arr) = prov.sample() else {
            return Ok(bound(file, Some(make)));
        };
        // The LEADING axis is the record count: a record-table provider serves
        // one column, rank-1 over its rows.
        let n = arr.shape().first().copied().unwrap_or(0) as i64;
        if let Some(prev) = extents.insert(mp.clone(), n)
            && prev != n
        {
            return Err(MessageError(format!(
                "the data sources binding metaparameter '{mp}' disagree on its extent: \
                 one measures {prev} records and '{key}' measures {n}. Every source \
                 declaring the same `extent` metaparameter must measure the same number \
                 of records — that agreement is what keeps a table's columns aligned."
            )));
        }
    }
    if extents.is_empty() {
        return Ok(bound(file, Some(make)));
    }
    let reloaded = reload(&extents).map_err(|e| {
        MessageError(format!(
            "re-loading with the discovered source extents: {e}"
        ))
    })?;
    // Rebuilt from the RELOADED document, so the providers a build ingests
    // through and the shapes it fills come from one and the same document.
    let consumed = consumed_of(&reloaded)?;
    if consumed.is_empty() {
        return Ok(bound(reloaded, None));
    }
    let make = esio_factory(&reloaded, consumed, cache_root)?;
    Ok(bound(reloaded, Some(make)))
}

/// The EarthSciIO provider factory for `file`'s `consumed` sources.
#[cfg(feature = "esio")]
fn esio_factory(
    file: &EsmFile,
    consumed: BTreeMap<String, Vec<String>>,
    cache_root: &Path,
) -> Result<Arc<BuildProviderFactory<'static>>, ProviderError> {
    let doc = serde_json::to_value(file)
        .map_err(|e| MessageError(format!("serializing the document for data_sources: {e}")))?;
    let cache_root = cache_root.to_path_buf();
    let summary = consumed_summary(&consumed);
    let names: Vec<String> = consumed.into_keys().collect();
    Ok(Arc::new(move || {
        // NAMED, not an unrestricted sweep: `providers_from_document` skips a
        // source with no `metadata.esio_format` when it is sweeping. Naming
        // them makes a source that cannot be constructed an error that names
        // it.
        let selected: Vec<&str> = names.iter().map(String::as_str).collect();
        crate::esio_provider::providers_from_document(
            &doc,
            &cache_root,
            Some(&selected),
            &std::collections::HashMap::new(),
        )
        .map(|provs| {
            provs
                .into_iter()
                .map(|(k, p)| (k, Box::new(p) as Box<dyn crate::provider::DataProvider>))
                .collect()
        })
        .map_err(|e| format!("data_sources ingest failed for {summary}: {}", e.0))
    }))
}

/// The `data_sources` entries some parameter actually READS, mapped to the
/// flattened names of the parameters that read them.
///
/// A source no parameter consumes is inert (a document may carry sources only
/// some of its models use). Subsystems are walked because a mounted
/// component's parameters consume the document's sources exactly as a
/// top-level model's do. A binding naming a source the document does not
/// declare is a validation error, not an ingest one, and is ignored here.
fn consumed_data_sources(doc: &serde_json::Value) -> BTreeMap<String, Vec<String>> {
    fn visit(node: &serde_json::Value, prefix: &str, out: &mut BTreeMap<String, Vec<String>>) {
        if let Some(vars) = node.get("variables").and_then(|v| v.as_object()) {
            for (vname, var) in vars {
                let Some(update) = var.get("update") else {
                    continue;
                };
                if update.get("kind").and_then(|k| k.as_str()) != Some("data") {
                    continue;
                }
                let Some(src) = update.get("source").and_then(|s| s.as_str()) else {
                    continue;
                };
                out.entry(src.to_string())
                    .or_default()
                    .push(format!("{prefix}.{vname}"));
            }
        }
        if let Some(subs) = node.get("subsystems").and_then(|v| v.as_object()) {
            for (sname, sub) in subs {
                visit(sub, &format!("{prefix}.{sname}"), out);
            }
        }
    }

    let Some(declared) = doc.get("data_sources").and_then(|v| v.as_object()) else {
        return BTreeMap::new();
    };
    let mut out = BTreeMap::new();
    if let Some(models) = doc.get("models").and_then(|v| v.as_object()) {
        for (mname, model) in models {
            visit(model, mname, &mut out);
        }
    }
    out.retain(|src, _| declared.contains_key(src));
    out
}

/// The consumed sources and the parameters that read them, for a diagnostic:
/// a reader's own errors name the consuming parameter, which does not tell an
/// author which `data_sources` entry to look at.
fn consumed_summary(consumed: &BTreeMap<String, Vec<String>>) -> String {
    consumed
        .iter()
        .map(|(src, readers)| format!("'{src}' (read by {})", readers.join(", ")))
        .collect::<Vec<_>>()
        .join("; ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_consumed_declared_sources_are_reported() {
        let doc = json!({
            "data_sources": {"A": {}, "Unused": {}},
            "models": {"M": {
                "variables": {
                    "p": {"type": "parameter", "update": {"kind": "data", "source": "A"}},
                    "q": {"type": "parameter", "update": {"kind": "data", "source": "Undeclared"}}
                },
                "subsystems": {"S": {"variables": {
                    "r": {"type": "parameter", "update": {"kind": "data", "source": "A"}}
                }}}
            }}
        });
        let got = consumed_data_sources(&doc);
        assert_eq!(got.len(), 1);
        assert_eq!(got["A"], vec!["M.p".to_string(), "M.S.r".to_string()]);
    }

    #[test]
    fn a_document_without_sources_is_returned_unbound() {
        let file = crate::load_string(
            &json!({
                "esm": crate::SCHEMA_VERSION,
                "metadata": {"name": "t"},
                "models": {"M": {
                    "variables": {"x": {"type": "unknown", "units": "1", "default": 1.0}},
                    "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 0.0}]
                }}
            })
            .to_string(),
        )
        .expect("loads");
        let bound = bind_data_sources(file, Path::new("."), |_| {
            panic!("a document with no sources is not reloaded")
        })
        .expect("binds");
        assert!(bound.providers.is_none());
    }
}
