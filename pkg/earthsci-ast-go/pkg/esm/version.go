package esm

// LibraryVersion is this Go module's OWN version — NOT the `.esm` format
// version, which is SchemaVersion. The two are unrelated numbers, and until
// this split Go exposed neither under a shared name while TypeScript and Rust
// both exported a `VERSION` that meant the SCHEMA version in one and the
// PACKAGE version in the other. Every binding now exposes exactly
// SchemaVersion and LibraryVersion.
//
// Unlike the other four bindings, a Go module carries no in-tree version
// manifest — a module's version is the git tag the proxy resolves — so there
// is nothing to derive this from and no file a test could pin it against.
// It is maintained by hand alongside the repo-wide release version, which the
// release process bumps in lockstep with the Julia Project.toml, the Rust
// Cargo.toml, the npm package.json and the Python pyproject.toml.
const LibraryVersion = "0.1.1"
