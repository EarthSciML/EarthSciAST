//! Narrative EarthSciAST models: tests, analyses and figures for `.esm`
//! documents written as prose.
//!
//! An author writes a model in the prose of a document — in the ESM Markdown
//! or Typst source format, declaring variables as they are introduced and
//! writing equations as displays — and adds tests and figures. The core
//! (`earthsci_ast::parse_markdown`, `parse_typst`) reads the document; this
//! crate validates it, runs its tests and analyses, and draws its figures, so
//! static and interactive figures look the same everywhere.
//!
//! - [`build`]: a document in, everything a front end shows out.
//! - [`analysis`]: run §6.7 analyses into plot data.
//! - [`markdown`]: narrative pages for the docs site (native only, `markdown`
//!   feature): a page in the ESM Markdown format, read by the core, with
//!   narrative's `esm-` directives for tests, figures and tables.
//! - [`plot_data`]: the data behind one figure.
//! - [`svg`]: figures as SVG.
//!
//! [`element`] and [`assemble`] are internal: the element format is how the
//! Markdown front end hands its tests and figures to the builder, and what the
//! Typst plugin's `build` takes. It is not a document format.
//!
//! Everything here builds for `wasm32-unknown-unknown` with no host imports,
//! because the Typst plugin and the browser widget both link it.

pub mod analysis;
#[doc(hidden)]
pub mod assemble;
pub mod build;
pub mod diagnostic;
#[doc(hidden)]
pub mod element;
#[cfg(feature = "markdown")]
pub mod markdown;
pub mod plot_data;
pub mod svg;

#[doc(hidden)]
pub use assemble::{Assembly, assemble, assemble_onto, check};
pub use build::{BuildOptions, BuildOutput, ConstructOutput, build_document, build_text};
#[doc(hidden)]
pub use build::{build, build_json, build_onto, build_value};
pub use diagnostic::{Diagnostic, Severity};
#[doc(hidden)]
pub use element::{Document, Element, ElementKind, FORMAT_VERSION, SourceSpan};
pub use plot_data::PlotData;
