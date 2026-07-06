//! Shared plumbing for the conformance adapter binaries
//! (`earthsci-*-adapter-rust` under `src/bin/`): the common
//! `--manifest <m.json> --output <r.json>` argument protocol and the report
//! writer. Keeping this in the library (rather than copy-pasted per binary)
//! pins one convention for all adapters: unknown arguments are rejected,
//! errors are prefixed with the binary name by the caller, the output
//! directory is created on demand, and reports end with a trailing newline.

use std::path::{Path, PathBuf};

/// The parsed `--manifest` / `--output` pair every conformance adapter takes.
pub struct AdapterArgs {
    /// Path to the tier's manifest JSON.
    pub manifest: PathBuf,
    /// Path the adapter writes its `{"binding": ..., "fixtures": ...}` report to.
    pub output: PathBuf,
}

/// Parse `--manifest <path> --output <path>` from `std::env::args`, rejecting
/// anything else. Both flags are required.
pub fn parse_manifest_output_args() -> Result<AdapterArgs, String> {
    let mut manifest: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--manifest" => manifest = args.next().map(PathBuf::from),
            "--output" => output = args.next().map(PathBuf::from),
            other => return Err(format!("unexpected argument {other:?}")),
        }
    }
    match (manifest, output) {
        (Some(manifest), Some(output)) => Ok(AdapterArgs { manifest, output }),
        _ => Err("--manifest and --output are required".to_string()),
    }
}

/// Write an adapter report as pretty-printed JSON with a trailing newline,
/// creating the output's parent directory if needed.
pub fn write_report(
    output_path: &Path,
    report: &serde_json::Value,
) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(parent) = output_path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(
        output_path,
        format!("{}\n", serde_json::to_string_pretty(report)?),
    )?;
    Ok(())
}
