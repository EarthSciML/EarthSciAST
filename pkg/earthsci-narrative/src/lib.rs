//! Narrative EarthSciAST models: the shared core behind the Markdown and Typst
//! front ends.
//!
//! An author defines a model in the prose of a document — declaring variables
//! as they are introduced, writing equations inline, adding tests and figures —
//! and a front end extracts those constructs as a [`Document`] of elements.
//! This crate turns that document into a validated `.esm` file, renders its
//! mathematics, runs its tests and analyses, and draws its figures, so both
//! front ends share one implementation and static and interactive figures look
//! the same.
//!
//! - [`element`]: the element format, the contract with the front ends.
//! - [`assemble`]: elements into an `.esm` document, with diagnostics.
//! - [`analysis`]: run §6.7 analyses into plot data.
//! - [`build`]: all of the above in one call, per element.
//! - [`typst_math`]: expressions as Typst math.
//! - [`plot_data`]: the data behind one figure.
//! - [`svg`]: figures as SVG.
//!
//! Everything here builds for `wasm32-unknown-unknown` with no host imports,
//! because the Typst plugin and the browser widget both link it.

pub mod analysis;
pub mod assemble;
pub mod build;
pub mod diagnostic;
pub mod element;
pub mod plot_data;
pub mod svg;
pub mod typst_math;

pub use assemble::{Assembly, assemble, check};
pub use build::{BuildOptions, BuildOutput, build, build_json};
pub use diagnostic::{Diagnostic, Severity};
pub use element::{Document, Element, ElementKind, FORMAT_VERSION, SourceSpan};
pub use plot_data::PlotData;
