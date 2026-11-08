//! Build script.
//!
//! Two jobs. First, it lists the bundled standard library: every
//! `src/stdlib/*.esm` (copied from the repo-root `lib/` by
//! `scripts/sync-lib.sh`) becomes one `include_str!` entry of
//! `$OUT_DIR/stdlib_files.rs`, which `src/stdlib.rs` includes, so adding a
//! library file needs no Rust edit. `esm:std/<file>.esm` refs (esm-spec §4.7)
//! resolve against that table.
//!
//! Second, the `xla` feature's runtime link path. The `xla` crate
//! links the prebuilt `xla_extension` shared library out of the directory
//! named by `XLA_EXTENSION_DIR`, but a dependency's `cargo:rustc-link-arg` is
//! NOT applied to the binaries, tests, examples and benches of the crate that
//! depends on it — only to that dependency's own artifacts. So without the
//! lines below every `earthsci-ast` binary built with `--features xla` links
//! fine and then dies at startup with
//!
//! ```text
//! error while loading shared libraries: libxla_extension.so: cannot open shared object file
//! ```
//!
//! unless the caller also sets `LD_LIBRARY_PATH`. Emitting an rpath here bakes
//! the path into the ELF instead (verify with
//! `readelf -d <binary> | grep -E 'RPATH|RUNPATH'`).
//!
//! With the feature OFF this script emits the two `rerun-if` lines and
//! nothing else, so a default build is unaffected and needs no extension.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    write_stdlib_table();
    println!("cargo:rerun-if-env-changed=XLA_EXTENSION_DIR");
    // `CARGO_FEATURE_<NAME>` is set by cargo for every enabled feature.
    if std::env::var_os("CARGO_FEATURE_XLA").is_none() {
        return;
    }
    let Some(dir) = std::env::var_os("XLA_EXTENSION_DIR") else {
        // The `xla` crate's own build script is what fails (loudly) when the
        // extension is missing; do not pre-empt its error message here.
        return;
    };
    let lib = std::path::Path::new(&dir).join("lib");
    // The unscoped form, not one `rustc-link-arg-<kind>` per target kind:
    // `-tests` reaches only the `tests/` integration binaries, NOT the lib's
    // own unit-test harness (`cargo test --lib`), which then fails to start
    // with the error above. rustc ignores a link arg on the rlib, and the
    // cdylib wants the rpath as much as a binary does.
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib.display());
}

/// Write `$OUT_DIR/stdlib_files.rs`: a `&[(name, text)]` slice expression with
/// one `include_str!` per `src/stdlib/*.esm`, sorted by name.
fn write_stdlib_table() {
    let manifest = std::path::PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let dir = manifest.join("src").join("stdlib");
    println!("cargo:rerun-if-changed={}", dir.display());
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("read {}: {e}", dir.display()))
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".esm"))
        .collect();
    names.sort();
    let mut out = String::from("&[\n");
    for name in &names {
        let path = dir.join(name);
        out.push_str(&format!(
            "    ({name:?}, include_str!({:?})),\n",
            path.to_string_lossy()
        ));
    }
    out.push_str("]\n");
    let dest =
        std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap()).join("stdlib_files.rs");
    std::fs::write(&dest, out).unwrap_or_else(|e| panic!("write {}: {e}", dest.display()));
}
