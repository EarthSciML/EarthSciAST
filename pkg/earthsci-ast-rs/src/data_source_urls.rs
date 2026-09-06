//! Load-time resolution of `data_sources[*].source.url_template`
//! (esm-spec §8.2.1).
//!
//! A `url_template` need not be an absolute URL. §8.2.1 resolves it to one at
//! load time against the directory of the file the entry was read from — the
//! same base and the same timing rule §4.7 fixes for a `ref`. That is what
//! lets a document name data living outside its own repository without
//! carrying a machine-specific absolute path.
//!
//! Environment variables are deliberately NOT expanded (§4.7 permits `${VAR}`
//! in a `ref`; §8.2 does not permit it at all), and a template that needs one
//! is REFUSED rather than passed through: a document reading `${…}` from the
//! ambient environment does not say what it reads, the expanded value is
//! spliced into a URL that is then fetched, and an optional expansion
//! capability would make the same document resolve under one binding and not
//! another. See `docs/content/rfcs/portable-data-source-urls.md`.
//!
//! The pass rewrites the RAW document, before schema validation and before
//! typed coercion, so the typed [`crate::types::components::DataSourceLocation`],
//! the ingest providers ([`crate::esio_provider`]) and `emit` all see one
//! resolved form and none of them needs a base directory. It is idempotent
//! (its output is scheme-led), so `parse → emit → parse` is stable.

use crate::diagnostic::{DiagnosticError, codes, err};
use serde_json::{Map, Value};
use std::path::{Component, Path, PathBuf};

/// True when `template` is already an absolute URL.
///
/// esm-spec §8.2.1 requires the `://` (rather than a bare `scheme:`) so that a
/// Windows drive letter and a `{date:%Y}` substitution are both read as path
/// text, not as a scheme.
fn is_scheme_led(template: &str) -> bool {
    let Some(idx) = template.find("://") else {
        return false;
    };
    let scheme = &template[..idx];
    let mut chars = scheme.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '.' || c == '-')
}

/// RFC 3986 §5.2.4 dot-segment removal, lexically, on an absolute path.
///
/// Never [`std::fs::canonicalize`]: a template carrying a `{date:…}`
/// substitution names a file that need not exist at load time, and resolving
/// symlinks would make the resolved URL depend on the filesystem rather than on
/// the document. A `..` that would climb past the root is dropped, per §5.2.4.
fn remove_dot_segments(path: &Path) -> PathBuf {
    let mut root = PathBuf::new();
    let mut parts: Vec<&std::ffi::OsStr> = Vec::new();
    for c in path.components() {
        match c {
            Component::Prefix(_) | Component::RootDir => root.push(c.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                parts.pop();
            }
            Component::Normal(s) => parts.push(s),
        }
    }
    let mut out = root;
    for p in parts {
        out.push(p);
    }
    out
}

/// `base_dir` as an absolute directory.
///
/// The loader's base may be relative (`esm validate fixtures/x.esm` gives
/// `fixtures`; a string load defaults to the working directory) and splicing a
/// relative path after `file://` would silently make its first segment the URL
/// HOST — the exact misresolution §8.2.1 exists to stop.
fn absolute_base(base_dir: &Path) -> PathBuf {
    if base_dir.is_absolute() {
        return base_dir.to_path_buf();
    }
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    cwd.join(base_dir)
}

/// Resolve one `url_template` / `mirrors` entry per esm-spec §8.2.1.
pub(crate) fn resolve_source_url(
    template: &str,
    base_dir: &Path,
) -> Result<String, DiagnosticError> {
    if template.contains("${") {
        return Err(err(
            codes::DATA_SOURCE_URL_UNRESOLVED,
            format!(
                "url template {template:?} carries an unexpanded '${{...}}' variable. \
                 esm-spec §8.2.1 does not expand environment variables into a data \
                 source's location: a document that reads one does not say what it \
                 reads, and the value is spliced into a URL that is then fetched. \
                 Write a path relative to this document instead (it resolves against \
                 the document's own directory), or symlink the data to that path."
            ),
        ));
    }
    // Substitution-led: the author's own substitution supplies the location, so
    // there is no literal prefix to classify. §8.2 requires unrecognized
    // substitutions to be passed through, so this is left alone.
    if template.starts_with('{') || is_scheme_led(template) {
        return Ok(template.to_string());
    }

    let joined = if template.starts_with('/') {
        PathBuf::from(template)
    } else {
        absolute_base(base_dir).join(template)
    };
    let resolved = remove_dot_segments(&joined);
    let Some(resolved) = resolved.to_str() else {
        return Err(err(
            codes::DATA_SOURCE_URL_UNRESOLVED,
            format!(
                "url template {template:?} resolves to a path that is not valid UTF-8 \
                 and so cannot be spelled as a URL (esm-spec §8.2.1)."
            ),
        ));
    };
    if resolved.contains('?') || resolved.contains('#') {
        return Err(err(
            codes::DATA_SOURCE_URL_UNRESOLVED,
            format!(
                "url template {template:?} resolves to {resolved:?}, whose '?' or '#' \
                 would be read as a URL query or fragment rather than as part of the \
                 path (esm-spec §8.2.1). Rename or relocate the file."
            ),
        ));
    }
    Ok(format!("file://{resolved}"))
}

/// [`resolve_source_url`], with the failure naming its document site.
///
/// A resolution failure must name the entry AND the template: `io error at
/// /${MOVES_SNAPSHOTS}/x.parquet` names neither, and a source whose location
/// silently fails to resolve is indistinguishable from one that read zeros.
fn resolved_at(template: &str, base_dir: &Path, site: &str) -> Result<String, DiagnosticError> {
    resolve_source_url(template, base_dir)
        .map_err(|e| err(e.code, format!("{site}: {}", e.message)))
}

/// Resolve every `data_sources[*].source` location in `doc`, in place.
///
/// A no-op for the overwhelmingly common document that declares no
/// `data_sources`, and for one whose templates are already absolute URLs.
pub(crate) fn resolve_data_source_urls(
    doc: &mut Value,
    base_dir: &Path,
) -> Result<(), DiagnosticError> {
    let Some(sources) = doc.get_mut("data_sources").and_then(Value::as_object_mut) else {
        return Ok(());
    };
    for (name, entry) in sources.iter_mut() {
        let Some(src) = entry.get_mut("source").and_then(Value::as_object_mut) else {
            continue;
        };
        resolve_one(name, src, base_dir)?;
    }
    Ok(())
}

fn resolve_one(
    name: &str,
    src: &mut Map<String, Value>,
    base_dir: &Path,
) -> Result<(), DiagnosticError> {
    if let Some(t) = src.get("url_template").and_then(Value::as_str) {
        let site = format!("data_sources.{name}.source.url_template");
        let resolved = resolved_at(t, base_dir, &site)?;
        src.insert("url_template".to_string(), Value::String(resolved));
    }
    if let Some(mirrors) = src.get("mirrors").and_then(Value::as_array) {
        let mut out = Vec::with_capacity(mirrors.len());
        for (i, m) in mirrors.iter().enumerate() {
            match m.as_str() {
                Some(s) => {
                    let site = format!("data_sources.{name}.source.mirrors[{i}]");
                    out.push(Value::String(resolved_at(s, base_dir, &site)?));
                }
                None => out.push(m.clone()),
            }
        }
        src.insert("mirrors".to_string(), Value::Array(out));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn r(t: &str) -> String {
        resolve_source_url(t, Path::new("/a/b")).expect("resolves")
    }

    #[test]
    fn a_relative_template_anchors_on_the_referencing_documents_directory() {
        assert_eq!(r("./x.parquet"), "file:///a/b/x.parquet");
        assert_eq!(r("x.parquet"), "file:///a/b/x.parquet");
        // The motivating shape (finding F15): a sibling checkout.
        assert_eq!(
            r("../../moves.rs/characterization/snapshots/t.parquet"),
            "file:///moves.rs/characterization/snapshots/t.parquet"
        );
    }

    #[test]
    fn an_absolute_path_is_used_as_is_and_dot_segments_go_lexically() {
        assert_eq!(r("/data/./y/../x.nc"), "file:///data/x.nc");
        // §5.2.4: a `..` that would climb past the root is dropped, not kept.
        assert_eq!(r("/../x.nc"), "file:///x.nc");
    }

    #[test]
    fn an_absolute_url_is_untouched_whatever_its_scheme() {
        for t in [
            "file:///data/x.nc",
            "https://example.org/x.nc",
            "s3://bucket/x.nc",
            "cds://reanalysis/{date:%Y%m}.nc",
        ] {
            assert_eq!(r(t), t, "{t} must be used as-is");
        }
    }

    #[test]
    fn substitutions_survive_the_join_unexpanded() {
        assert_eq!(
            r("snap/{date:%Y%m%d}.nc"),
            "file:///a/b/snap/{date:%Y%m%d}.nc"
        );
        // Substitution-LED: the author's own substitution supplies the
        // location, so there is no literal prefix to classify (§8.2 requires
        // unrecognized substitutions to be passed through).
        assert_eq!(r("{root}/x.nc"), "{root}/x.nc");
    }

    #[test]
    fn resolution_is_idempotent_so_parse_emit_parse_is_stable() {
        let once = r("./x.parquet");
        let twice = resolve_source_url(&once, Path::new("/somewhere/else")).expect("resolves");
        assert_eq!(once, twice);
    }

    #[test]
    fn a_dollar_brace_variable_is_refused_and_the_diagnostic_names_the_template() {
        let e = resolve_source_url("file://${MOVES_SNAPSHOTS}/t.parquet", Path::new("/a/b"))
            .expect_err("must refuse an environment variable");
        assert_eq!(e.code, codes::DATA_SOURCE_URL_UNRESOLVED);
        assert!(
            e.message.contains("${MOVES_SNAPSHOTS}"),
            "the diagnostic must name the unresolved template, got: {}",
            e.message
        );
    }

    #[test]
    fn a_query_or_fragment_in_the_resolved_path_is_refused() {
        for t in ["./a?b.nc", "./a#b.nc"] {
            let e = resolve_source_url(t, Path::new("/a/b")).expect_err("must refuse");
            assert_eq!(e.code, codes::DATA_SOURCE_URL_UNRESOLVED);
            assert!(
                e.message.contains(t),
                "must name the template: {}",
                e.message
            );
        }
    }

    #[test]
    fn the_document_pass_rewrites_the_primary_and_every_mirror_and_names_its_site() {
        let mut doc = json!({
            "data_sources": {
                "snap": {
                    "kind": "static",
                    "source": {
                        "url_template": "./tables/t.parquet",
                        "mirrors": ["../mirror/t.parquet", "https://example.org/t.parquet"]
                    }
                }
            }
        });
        resolve_data_source_urls(&mut doc, Path::new("/a/b")).expect("resolves");
        let src = &doc["data_sources"]["snap"]["source"];
        assert_eq!(src["url_template"], "file:///a/b/tables/t.parquet");
        assert_eq!(src["mirrors"][0], "file:///a/mirror/t.parquet");
        assert_eq!(src["mirrors"][1], "https://example.org/t.parquet");

        let mut bad = json!({
            "data_sources": {
                "snap": { "kind": "static", "source": { "url_template": "${ROOT}/t.parquet" } }
            }
        });
        let e = resolve_data_source_urls(&mut bad, Path::new("/a/b")).expect_err("must refuse");
        assert!(
            e.message.contains("data_sources.snap.source.url_template"),
            "the diagnostic must name the offending entry, got: {}",
            e.message
        );
    }

    #[test]
    fn a_document_with_no_data_sources_is_untouched() {
        let mut doc = json!({"esm": "1.0.0", "models": {}});
        let before = doc.clone();
        resolve_data_source_urls(&mut doc, Path::new("/a/b")).expect("no-op");
        assert_eq!(doc, before);
    }
}
