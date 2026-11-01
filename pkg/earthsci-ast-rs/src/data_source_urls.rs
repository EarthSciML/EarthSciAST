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
pub(crate) fn is_scheme_led(template: &str) -> bool {
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

/// The names of the bare `{name}` placeholders in a template, in order of
/// appearance (esm-spec §4.7 "Binding a data source's location at the mount").
///
/// Only a brace pair enclosing a C identifier is a placeholder a mount edge can
/// bind; a formatted substitution such as `{date:%Y%m%d}` is not, so an edge can
/// never rewrite the runtime's own date expansion.
fn placeholders(template: &str) -> Vec<(usize, usize, &str)> {
    let b = template.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'{' {
            let start = i + 1;
            let mut j = start;
            while j < b.len() && (b[j].is_ascii_alphanumeric() || b[j] == b'_') {
                j += 1;
            }
            if j < b.len() && b[j] == b'}' && j > start && !b[start].is_ascii_digit() {
                out.push((i, j + 1, &template[start..j]));
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
    out
}

/// RFC 3986 §5.2 resolution of the relative path `rel` against the DIRECTORY
/// URL `base` (`scheme://authority/path`, read as a directory whether or not it
/// ends in `/`), with dot segments removed. A query or fragment on `base` is
/// dropped, as §5.2.2 drops them for a path reference.
fn join_url_directory(base: &str, rel: &str) -> String {
    let base = base.split(['?', '#']).next().unwrap_or(base);
    let after_scheme = base.find("://").map_or(0, |i| i + 3);
    let path_start = base[after_scheme..]
        .find('/')
        .map_or(base.len(), |i| after_scheme + i);
    let (origin, dir) = base.split_at(path_start);
    let mut out: Vec<&str> = Vec::new();
    let joined = format!("{}/{rel}", dir.trim_end_matches('/'));
    let trailing = joined.ends_with('/') || joined.ends_with("/.") || joined.ends_with("/..");
    for seg in joined.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            s => out.push(s),
        }
    }
    let mut path = format!("/{}", out.join("/"));
    if trailing && !path.ends_with('/') {
        path.push('/');
    }
    format!("{origin}{path}")
}

/// RFC 3986 §5.2.4 dot-segment removal on the PATH of the scheme-led URL `url`
/// (`scheme://authority/path?query#fragment`), leaving its scheme, authority,
/// query and fragment byte-for-byte as written. Empty segments are kept, as
/// §5.2.4 keeps them; a `..` that would climb past the root is dropped.
fn remove_url_path_dot_segments(url: &str) -> String {
    let after_scheme = url.find("://").map_or(0, |i| i + 3);
    let path_start = url[after_scheme..]
        .find(['/', '?', '#'])
        .map_or(url.len(), |i| after_scheme + i);
    let path_end = url[path_start..]
        .find(['?', '#'])
        .map_or(url.len(), |i| path_start + i);
    let path = &url[path_start..path_end];
    let Some(rest) = path.strip_prefix('/') else {
        return url.to_string();
    };
    let segs: Vec<&str> = rest.split('/').collect();
    let last = segs.len() - 1;
    let mut out: Vec<&str> = Vec::with_capacity(segs.len());
    for (i, seg) in segs.into_iter().enumerate() {
        match seg {
            "." => {}
            ".." => {
                out.pop();
            }
            s => out.push(s),
        }
        // A path ending in `.` or `..` names a directory: keep the slash.
        if i == last && (seg == "." || seg == "..") {
            out.push("");
        }
    }
    format!(
        "{}/{}{}",
        &url[..path_start],
        out.join("/"),
        &url[path_end..]
    )
}

/// Every `url_template` and `mirrors` string of a document's `data_sources`,
/// mutably, with the site each one is reported at.
fn location_strings(doc: &mut Value) -> Vec<(String, &mut Value)> {
    let mut out = Vec::new();
    let Some(sources) = doc.get_mut("data_sources").and_then(Value::as_object_mut) else {
        return out;
    };
    for (name, entry) in sources.iter_mut() {
        let Some(src) = entry.get_mut("source").and_then(Value::as_object_mut) else {
            continue;
        };
        for (key, v) in src.iter_mut() {
            if key == "url_template" && v.is_string() {
                out.push((format!("data_sources.{name}.source.url_template"), v));
            } else if key == "mirrors"
                && let Some(ms) = v.as_array_mut()
            {
                for (i, m) in ms.iter_mut().enumerate() {
                    if m.is_string() {
                        out.push((format!("data_sources.{name}.source.mirrors[{i}]"), m));
                    }
                }
            }
        }
    }
    out
}

/// Apply a mount edge's `url_substitutions` to the referenced document's
/// `data_sources` (esm-spec §4.7 "Binding a data source's location at the
/// mount").
///
/// `doc` is the referenced document as resolved at this edge — its own
/// `data_sources` and those its own mounts already hoisted into it — and
/// `binder_dir` is the directory of the MOUNTING document, the one that wrote
/// the edge. Three rules:
///
/// * A key names a bare `{key}` placeholder of some location in `doc`; one
///   that names none is `url_substitution_unknown_name`, so a misspelt key
///   fails at the edge rather than leaving the placeholder for a read to trip
///   over.
/// * A value is text: a string carrying no `{` or `}`, so a substitution never
///   introduces another one (`data_source_url_unresolved` otherwise).
/// * Who wrote the location decides what it anchors on (§8.2.1). A placeholder
///   that LEADS a template supplies the whole location, so the bound value is
///   the mounting document's location and a relative one joins onto
///   `binder_dir`. A placeholder anywhere else is a segment of a location the
///   referenced document wrote, so the value is spliced in as text and the
///   result resolves against the referenced document's directory, as before.
///
/// A placeholder the edge does not bind is left as written, so it travels up
/// with the hoisted entry and an enclosing edge may bind it. Every location this
/// rewrites is already resolved, or resolves next, so the output of the pass is
/// the §8.2.1 form.
pub(crate) fn apply_mount_url_substitutions(
    doc: &mut Value,
    edge: &Map<String, Value>,
    binder_dir: &Path,
    where_: &str,
) -> Result<(), DiagnosticError> {
    let Some(raw) = edge.get("url_substitutions") else {
        return Ok(());
    };
    let Some(map) = raw.as_object() else {
        return Err(err(
            codes::DATA_SOURCE_URL_UNRESOLVED,
            format!(
                "{where_}: `url_substitutions` must be an object mapping a \
                 placeholder name to a string (esm-spec §4.7)"
            ),
        ));
    };
    if map.is_empty() {
        return Ok(());
    }
    let mut values: Vec<(&str, &str)> = Vec::with_capacity(map.len());
    for (k, v) in map {
        let Some(s) = v.as_str() else {
            return Err(err(
                codes::DATA_SOURCE_URL_UNRESOLVED,
                format!(
                    "{where_}: `url_substitutions.{k}` must be a string, got {v} \
                     (esm-spec §4.7)"
                ),
            ));
        };
        if s.contains('{') || s.contains('}') {
            return Err(err(
                codes::DATA_SOURCE_URL_UNRESOLVED,
                format!(
                    "{where_}: `url_substitutions.{k}` = {s:?} carries a brace; a bound \
                     value is text and may not introduce another substitution \
                     (esm-spec §4.7)"
                ),
            ));
        }
        // A value names a directory or a path segment; a query or fragment
        // never names a file (and a `#` would be dropped when the location is
        // read), so neither may ride in on a substitution.
        if s.contains('?') || s.contains('#') {
            return Err(err(
                codes::DATA_SOURCE_URL_UNRESOLVED,
                format!(
                    "{where_}: `url_substitutions.{k}` = {s:?} carries a '?' or '#'; a \
                     bound value names a directory or a path segment, never a URL query \
                     or fragment (esm-spec §4.7)"
                ),
            ));
        }
        values.push((k.as_str(), s));
    }

    let mut sites = location_strings(doc);
    let mut present: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for (_, v) in &sites {
        if let Some(t) = v.as_str() {
            present.extend(placeholders(t).into_iter().map(|(_, _, n)| n.to_string()));
        }
    }
    for (k, _) in &values {
        if !present.contains(*k) {
            let avail: Vec<&str> = present.iter().map(String::as_str).collect();
            return Err(err(
                codes::URL_SUBSTITUTION_UNKNOWN_NAME,
                format!(
                    "{where_}: `url_substitutions` binds '{k}', which no `url_template` or \
                     `mirrors` entry of the referenced document's data_sources spells as \
                     a placeholder `{{{k}}}` (available: [{}]); a mount edge never \
                     invents a placeholder (esm-spec §4.7)",
                    avail.join(", ")
                ),
            ));
        }
    }

    // The value a LEADING placeholder contributes: the mounting document's
    // location, per §8.2.1's own forms. Computed once per name.
    // A mounting document loaded from a URL has a URL for a directory; a
    // relative value then joins onto it by RFC 3986 (§5.2), as that document's
    // own relative refs do (§4.7).
    let url_base = binder_dir.to_str().filter(|b| is_scheme_led(b));
    let base = absolute_base(binder_dir);
    let lead = |v: &str| -> String {
        if is_scheme_led(v) || v.starts_with('/') {
            v.to_string()
        } else if let Some(b) = url_base {
            join_url_directory(b, v)
        } else {
            base.join(v).to_string_lossy().into_owned()
        }
    };

    for (site, v) in sites.iter_mut() {
        let Some(t) = v.as_str() else { continue };
        let found = placeholders(t);
        if !found
            .iter()
            .any(|(_, _, n)| values.iter().any(|(k, _)| k == n))
        {
            continue;
        }
        let mut out = String::with_capacity(t.len() + 64);
        let mut last = 0;
        for (s, e, n) in found {
            let Some((_, val)) = values.iter().find(|(k, _)| *k == n) else {
                continue;
            };
            out.push_str(&t[last..s]);
            if s == 0 {
                out.push_str(&lead(val));
            } else {
                out.push_str(val);
            }
            last = e;
        }
        out.push_str(&t[last..]);
        // A location that was already resolved (hoisted from a nested mount, or
        // made absolute by a leading value) is renormalized here, since §8.2.1
        // leaves a scheme-led template alone: a spliced `..` must not survive,
        // in ANY scheme. A `file://` location is a path (and a '?' / '#' in it
        // is refused, as §8.2.1 refuses one); any other `scheme://authority`
        // location has the dot segments of its PATH removed (RFC 3986 §5.2.4),
        // its query and fragment untouched.
        let out = match out.strip_prefix("file://") {
            None if is_scheme_led(&out) => remove_url_path_dot_segments(&out),
            Some(path) if path.starts_with('/') => {
                let p = remove_dot_segments(Path::new(path));
                let p = p.to_string_lossy();
                if p.contains('?') || p.contains('#') {
                    return Err(err(
                        codes::DATA_SOURCE_URL_UNRESOLVED,
                        format!(
                            "{where_}: {site}: the substituted location {out:?} carries a '?' \
                             or '#' (esm-spec §8.2.1)"
                        ),
                    ));
                }
                format!("file://{p}")
            }
            _ => out,
        };
        **v = Value::String(out);
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

    /// esm-spec §4.7 "Binding a data source's location at the mount", against
    /// the SHARED pin `tests/conformance/url_substitutions/manifest.json`
    /// (`cases`): apply the edge with the mounting document's directory, then
    /// §8.2.1 resolution with the declaring document's.
    #[test]
    fn url_substitution_cases_match_the_shared_manifest() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let repo = remove_dot_segments(&absolute_base(&repo));
        let m: Value = serde_json::from_str(
            &std::fs::read_to_string(
                repo.join("tests/conformance/url_substitutions/manifest.json"),
            )
            .expect("read the shared manifest"),
        )
        .expect("manifest is JSON");
        let declaring = repo.join(m["declaring_dir"].as_str().expect("declaring_dir"));
        let binder = repo.join(m["binder_dir"].as_str().expect("binder_dir"));
        let want = |pin: &Value| -> String {
            match pin.get("verbatim").and_then(Value::as_str) {
                Some(v) => v.to_string(),
                None => format!(
                    "file://{}",
                    remove_dot_segments(&repo.join(pin["repo_path"].as_str().expect("repo_path")))
                        .display()
                ),
            }
        };
        let cases = m["cases"].as_array().expect("cases");
        assert!(!cases.is_empty());
        for c in cases {
            let id = c["id"].as_str().expect("id");
            let mut source = Map::new();
            source.insert("url_template".into(), c["url_template"].clone());
            if let Some(ms) = c.get("mirrors") {
                source.insert("mirrors".into(), ms.clone());
            }
            let mut doc = json!({"data_sources": {"s": {"kind": "static", "source": source}}});
            let edge = json!({"ref": "x.esm", "url_substitutions": c["url_substitutions"]});
            // A case may mount from a URL-valued directory (`binder_url`).
            let case_binder = c
                .get("binder_url")
                .and_then(Value::as_str)
                .map(PathBuf::from)
                .unwrap_or_else(|| binder.clone());
            let got = apply_mount_url_substitutions(
                &mut doc,
                edge.as_object().expect("edge"),
                &case_binder,
                "case",
            )
            .and_then(|()| resolve_data_source_urls(&mut doc, &declaring));
            let expect = &c["expect"];
            if let Some(code) = expect.get("error_code").and_then(Value::as_str) {
                let e = got.expect_err(id);
                assert_eq!(e.code, code, "{id}: {}", e.message);
                for n in expect["message_contains"]
                    .as_array()
                    .expect("message_contains")
                {
                    let n = n.as_str().expect("str");
                    assert!(
                        e.message.contains(n),
                        "{id}: message must name {n:?}: {}",
                        e.message
                    );
                }
                continue;
            }
            got.unwrap_or_else(|e| panic!("{id}: {e}"));
            let src = &doc["data_sources"]["s"]["source"];
            assert_eq!(
                src["url_template"],
                Value::String(want(&expect["url_template"])),
                "{id}"
            );
            if let Some(ms) = expect.get("mirrors").and_then(Value::as_array) {
                let w: Vec<Value> = ms.iter().map(|p| Value::String(want(p))).collect();
                assert_eq!(src["mirrors"], Value::Array(w), "{id}: mirrors");
            }
        }
    }

    #[test]
    fn an_edge_without_url_substitutions_leaves_the_document_alone() {
        let mut doc = json!({"data_sources": {"s": {"source": {"url_template": "{x}/t.nc"}}}});
        let before = doc.clone();
        let edge = json!({"ref": "x.esm"});
        apply_mount_url_substitutions(&mut doc, edge.as_object().unwrap(), Path::new("/a"), "e")
            .expect("no-op");
        assert_eq!(doc, before);
    }

    #[test]
    fn url_path_dot_segments_are_removed_and_query_kept() {
        let f = remove_url_path_dot_segments;
        assert_eq!(f("https://h/a/b/../c/./d"), "https://h/a/c/d");
        assert_eq!(f("https://h/a/.."), "https://h/");
        assert_eq!(f("https://h/a/b/."), "https://h/a/b/");
        assert_eq!(f("https://h/../a"), "https://h/a");
        assert_eq!(f("https://h/a//b/../c"), "https://h/a//c");
        assert_eq!(
            f("https://h/x/../y?q=./a/../b#f/../g"),
            "https://h/y?q=./a/../b#f/../g"
        );
        assert_eq!(f("https://h"), "https://h");
        assert_eq!(f("https://h?q=../a"), "https://h?q=../a");
        assert_eq!(f("s3://bucket/{date:%Y}/../t.nc"), "s3://bucket/t.nc");
    }

    #[test]
    fn placeholders_are_bare_identifiers_only() {
        let names = |t: &str| -> Vec<String> {
            placeholders(t)
                .into_iter()
                .map(|(_, _, n)| n.to_string())
                .collect()
        };
        assert_eq!(names("{a}/{b_1}/{date:%Y}/{1x}/{}/{a"), vec!["a", "b_1"]);
        assert_eq!(names("x{snapshot}y"), vec!["snapshot"]);
    }
}
