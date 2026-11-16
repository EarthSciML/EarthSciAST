//! Reading the files a document's `data_sources` name, for `simulate` and
//! `test`.

use std::collections::BTreeMap;
#[cfg(feature = "esio")]
use std::collections::HashMap;
#[cfg(feature = "esio")]
use std::path::PathBuf;

// =============================================================================
// data_sources ingest
// =============================================================================
//
// A document whose parameters declare `update: {kind: "data", …}` reads its
// numbers off disk (esm-spec §8.9). Nothing in the library opens a file on its
// own: the build-time provider contract `earthsci_ast::PrepareProvider` is
// supplied by the CALLER, and until this module existed the `esm` binary
// supplied none — so `esm test` and `esm simulate` evaluated every data-fed
// parameter at its `default` and reported the result as if it were the
// document's answer. A declared source that is never read is a WRONG ANSWER,
// not a missing feature, so every path below either ingests or says why it
// cannot, naming the source.
//
// The reader itself is EarthSciIO, behind the crate's opt-in `esio` feature
// (a dependency tree no library consumer should have to build). The release
// binaries turn it on; a `cargo install` without it gets the refusal below.
// A binary built without it still detects a consumed source and refuses,
// which is the whole point: the two builds differ in what they can read, never
// in whether they tell you.

/// The `data_sources` entries some parameter actually READS, mapped to the
/// flattened names of the parameters that read them.
///
/// A source no parameter consumes is inert — a document may carry sources only
/// some of its models use — so it raises nothing. Subsystems are walked because
/// a mounted component's parameters consume the document's sources exactly as a
/// top-level model's do.
pub(crate) fn consumed_data_sources(doc: &serde_json::Value) -> BTreeMap<String, Vec<String>> {
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

    let declared: Vec<&String> = match doc.get("data_sources").and_then(|v| v.as_object()) {
        Some(m) => m.keys().collect(),
        None => return BTreeMap::new(),
    };
    let mut out = BTreeMap::new();
    if let Some(models) = doc.get("models").and_then(|v| v.as_object()) {
        for (mname, model) in models {
            visit(model, mname, &mut out);
        }
    }
    // A binding naming a source the document does not declare is a validation
    // error, not an ingest one — leave it to `validate` and ignore it here.
    out.retain(|src, _| declared.contains(&src));
    out
}

/// Where EarthSciIO's content-addressed cache lives for a CLI run.
///
/// Overridable so a batch runner can point it at fast local scratch; the
/// default is a stable per-user directory rather than a fresh temporary one, so
/// re-running `esm test` over the same sources re-reads bytes it already has.
#[cfg(feature = "esio")]
pub(crate) fn cache_root() -> PathBuf {
    match std::env::var_os("ESM_CACHE_DIR") {
        Some(dir) => PathBuf::from(dir),
        None => std::env::temp_dir().join("earthsci-esm-cache"),
    }
}

/// The sources being ingested and the parameters that read them, rendered for a
/// diagnostic.
///
/// Every ingest failure carries this, whatever went wrong underneath: the
/// reader's own errors name the CONSUMER (`provider Ingest.annual: …`), which
/// does not tell an author which `data_sources` entry to go and look at.
pub(crate) fn consumed_summary(consumed: &BTreeMap<String, Vec<String>>) -> String {
    consumed
        .iter()
        .map(|(src, readers)| format!("'{src}' (read by {})", readers.join(", ")))
        .collect::<Vec<_>>()
        .join("; ")
}

/// The message a build with no reader gives for a document it cannot ingest.
#[cfg(not(feature = "esio"))]
pub(crate) fn no_reader_diagnostic(consumed: &BTreeMap<String, Vec<String>>) -> String {
    format!(
        "this `esm` binary cannot ingest data_sources: it was built WITHOUT the \
         `esio` feature, so it links no data reader, but the document declares \
         {} that {} read: {}. Rebuild the binary with \
         `cargo build --release --features esio` (see pkg/earthsci-ast-rs/Cargo.toml). \
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
        consumed_summary(consumed)
    )
}

/// What builds a document's data providers, once per build: the shape of
/// `earthsci_ast::BuildProviderFactory`, spelled out here because that alias
/// is exported only with the library's solver (`earthsci-ast/solve`), and the
/// `integrator` solver builds without it.
pub(crate) type ProviderFactory =
    dyn Fn() -> Result<Vec<(String, Box<dyn earthsci_ast::PrepareProvider>)>, String>;

/// Close every metaparameter a `data_sources` `extent` binds, by SAMPLING the
/// sources that measure themselves, and re-load the document with the sizes the
/// data gave.
///
/// esm-spec §8.9.4 puts this sampling BEFORE the document's metaparameters are
/// closed (§9.7.6 site 4), and it has to be there. An index set declared
/// `size: "N_REC"` is folded to an integer AT LOAD, so a runner that loads
/// first has already frozen the row count at the declaration's default — which,
/// for a source whose count is not knowable until the table is read, is zero.
/// Every shape downstream is then zero-length, and the two ways that surfaces
/// are both bad: the array runtime panics building a rank-1 array of length 0,
/// and an aggregate over the empty range returns a sum over no rows — 0, from a
/// document that validates, which is this toolchain's characteristic failure.
/// The alternative, a hardcoded row count in the document, is exactly what
/// `extent` exists to avoid: the next snapshot has a different number of rows.
///
/// **Best effort by construction.** Anything that goes wrong in the sampling —
/// a source that cannot be constructed, a file that is not there, a build with
/// no reader linked — is left to the RUN to report, because the run reports it
/// against the assertion or the command that needed the data, with the source
/// named. Reporting it here as well would only make it arrive twice, and the
/// first time in a worse place. Only a re-load that fails with the discovered
/// extents in hand is an error of this pass's own.
pub(crate) fn close_declared_extents(
    esm_file: earthsci_ast::EsmFile,
    reload: impl FnOnce(&BTreeMap<String, i64>) -> Result<earthsci_ast::EsmFile, String>,
) -> Result<(earthsci_ast::EsmFile, Option<Box<ProviderFactory>>), String> {
    let factory = |file: &earthsci_ast::EsmFile| {
        serde_json::to_value(file)
            .ok()
            .and_then(|doc| data_source_providers(&doc))
    };
    let Some(make) = factory(&esm_file) else {
        return Ok((esm_file, None));
    };
    let Ok(provs) = make() else {
        return Ok((esm_file, Some(make)));
    };

    let mut extents: BTreeMap<String, i64> = BTreeMap::new();
    for (key, mut prov) in provs {
        let Some(mp) = earthsci_ast::PrepareProvider::extent_metaparameter(&*prov) else {
            continue;
        };
        let Ok(arr) = prov.sample() else {
            return Ok((esm_file, Some(make)));
        };
        // The LEADING axis is the record count: a record-table provider serves
        // one column, rank-1 over its rows.
        let n = arr.shape().first().copied().unwrap_or(0) as i64;
        if let Some(prev) = extents.insert(mp.clone(), n)
            && prev != n
        {
            return Err(format!(
                "the data sources binding metaparameter '{mp}' disagree on its extent: \
                 one measures {prev} records and '{key}' measures {n}. Every source \
                 declaring the same `extent` metaparameter must measure the same number \
                 of records — that agreement is what keeps a table's columns aligned."
            ));
        }
    }
    if extents.is_empty() {
        return Ok((esm_file, Some(make)));
    }
    let reloaded = reload(&extents)?;
    // Rebuilt from the RELOADED document, so the providers the run ingests
    // through and the shapes it fills come from one and the same document.
    let make = factory(&reloaded);
    Ok((reloaded, make))
}

/// The build-time provider factory for `doc`'s consumed `data_sources`, or
/// `None` when the document consumes none (the overwhelmingly common case,
/// which must stay free of every cost above).
///
/// A factory rather than a set because `ProblemOptions` takes providers by
/// value and `esm test` builds one problem per inline test.
#[cfg(feature = "esio")]
fn data_source_providers(doc: &serde_json::Value) -> Option<Box<ProviderFactory>> {
    let consumed = consumed_data_sources(doc);
    if consumed.is_empty() {
        return None;
    }
    let doc = doc.clone();
    let cache_root = cache_root();
    let summary = consumed_summary(&consumed);
    let names: Vec<String> = consumed.into_keys().collect();
    Some(Box::new(move || {
        // NAMED, not an unrestricted sweep: `providers_from_document` silently
        // SKIPS a source with no `metadata.esio_format` when it is sweeping,
        // and a silently skipped source is the defect this whole module exists
        // to close. Naming them makes a source that cannot be constructed an
        // error that names it.
        let selected: Vec<&str> = names.iter().map(String::as_str).collect();
        earthsci_ast::esio_provider::providers_from_document(
            &doc,
            &cache_root,
            Some(&selected),
            &HashMap::new(),
        )
        .map(|provs| {
            provs
                .into_iter()
                .map(|(k, p)| (k, Box::new(p) as Box<dyn earthsci_ast::PrepareProvider>))
                .collect()
        })
        .map_err(|e| format!("data_sources ingest failed for {summary}: {}", e.0))
    }))
}

#[cfg(not(feature = "esio"))]
fn data_source_providers(doc: &serde_json::Value) -> Option<Box<ProviderFactory>> {
    let consumed = consumed_data_sources(doc);
    if consumed.is_empty() {
        return None;
    }
    let msg = no_reader_diagnostic(&consumed);
    Some(Box::new(move || Err(msg.clone())))
}
