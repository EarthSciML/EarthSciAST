//! Build script.
//!
//! Its ONLY job is the `xla` feature's runtime link path. The `xla` crate
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
