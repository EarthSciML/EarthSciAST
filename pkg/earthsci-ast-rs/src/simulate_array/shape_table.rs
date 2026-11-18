//! The one record of the shape every variable of a build has: its index-set
//! axes and where they came from. [`super::normalize`] computes it once, from
//! the model it hands the compile, and every later reader of a variable's
//! axes — the compiled model, the build pipeline, a program cut from the
//! compiled one, the inline-test runner — reads this table rather than
//! inferring the shape again from a system that may no longer decide it.
//!
//! The table holds axes, not extents: the extents of an index set are not
//! final until the build has scoped its ragged factors and sized its derived
//! sets, so a reader resolves the axes it reads against the registry it holds
//! ([`super::resolve_declared_shape`]).

use super::HashMap;
use crate::flatten::ConditionalShapes;
use crate::types::Model;
use std::sync::Arc;

/// Where a variable's axes in a [`ShapeTable`] came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ShapeSource {
    /// The variable's declared `shape`.
    Declared,
    /// The shape inferred from the variable's defining equation
    /// ([`crate::structural::promoted_var_shapes`]).
    Inferred,
    /// The array arm of an unshaped mixed-rank `ifelse` (esm-spec §4.3.4,
    /// [`crate::flatten::conditional_shape_promotions`]).
    Conditional,
    /// The index sets of an expression template applied elementwise over an
    /// array argument (esm-spec §9.6.11, [`crate::elementwise_lift`]).
    Lifted,
    /// The shape the program a restricted system was cut from built it at.
    Inherited,
}

impl ShapeSource {
    /// Whether the build decided this shape where neither the document nor
    /// the flattened system records it (esm-libraries-spec §4.7.5): a reader
    /// of a flattened declaration takes it from the table instead.
    fn is_built(self) -> bool {
        matches!(
            self,
            ShapeSource::Conditional | ShapeSource::Lifted | ShapeSource::Inherited
        )
    }
}

#[derive(Debug, Clone)]
pub(super) struct ShapeEntry {
    pub(super) axes: Vec<String>,
    pub(super) source: ShapeSource,
}

/// Every shaped variable of a build, keyed by the name the build gives it,
/// and the unshaped variables whose shape only data can decide. A variable
/// absent from the table is a scalar.
#[derive(Debug, Clone, Default)]
pub(crate) struct ShapeTable {
    pub(super) entries: HashMap<String, ShapeEntry>,
    /// The variables whose only arrays are unshaped data-fed parameters, and
    /// those parameters (sorted). Such a variable takes the one shape their
    /// data has, read where the data is bound ([`crate::flatten::data_fill_shape`]).
    data_shaped: HashMap<String, Vec<String>>,
}

impl ShapeTable {
    /// The table of `model` after the shape rewrites: `axes`, every
    /// variable's declared or inferred axes; `conditional` and `lifted`, the
    /// shapes the rewrites gave unshaped variables; `inherited`, the table of
    /// the program a restricted system was cut from. A later source wins over
    /// an earlier one for the same name, in that order.
    pub(super) fn assemble(
        model: &Model,
        axes: HashMap<String, Vec<String>>,
        conditional: ConditionalShapes,
        lifted: HashMap<String, Vec<String>>,
        inherited: Option<&ShapeTable>,
    ) -> Self {
        let mut entries: HashMap<String, ShapeEntry> = axes
            .into_iter()
            .map(|(name, axes)| {
                let declared = model
                    .variables
                    .get(&name)
                    .is_some_and(|v| v.shape.is_some());
                let source = if declared {
                    ShapeSource::Declared
                } else {
                    ShapeSource::Inferred
                };
                (name, ShapeEntry { axes, source })
            })
            .collect();
        let mut set = |name: String, axes: Vec<String>, source: ShapeSource| {
            entries.insert(name, ShapeEntry { axes, source });
        };
        for (name, axes) in conditional.built {
            set(name, axes, ShapeSource::Conditional);
        }
        for (name, axes) in lifted {
            set(name, axes, ShapeSource::Lifted);
        }
        // A name the restricted system no longer declares is never read
        // from it, and a system cut from it declares no more.
        for (name, axes) in inherited.into_iter().flat_map(ShapeTable::built) {
            if model.variables.contains_key(name) {
                set(name.clone(), axes.to_vec(), ShapeSource::Inherited);
            }
        }
        ShapeTable {
            entries,
            data_shaped: conditional.data_shaped,
        }
    }

    /// `name`'s axes, declared or decided by the build; `None` for a scalar.
    pub(crate) fn axes(&self, name: &str) -> Option<&[String]> {
        self.entries.get(name).map(|e| e.axes.as_slice())
    }

    /// `name`'s axes when the build decided them where no declaration
    /// records them ([`ShapeSource::Conditional`], [`ShapeSource::Lifted`],
    /// [`ShapeSource::Inherited`]); `None` otherwise.
    pub(crate) fn built_axes(&self, name: &str) -> Option<&[String]> {
        self.entries
            .get(name)
            .filter(|e| e.source.is_built())
            .map(|e| e.axes.as_slice())
    }

    /// Where `name`'s axes came from; `None` for a scalar.
    #[cfg(test)]
    pub(crate) fn source(&self, name: &str) -> Option<ShapeSource> {
        self.entries.get(name).map(|e| e.source)
    }

    /// Every shape the build decided where no declaration records it.
    pub(super) fn built(&self) -> impl Iterator<Item = (&String, &[String])> {
        self.entries
            .iter()
            .filter(|(_, e)| e.source.is_built())
            .map(|(n, e)| (n, e.axes.as_slice()))
    }

    /// The unshaped data-fed parameters whose data decides `name`'s shape,
    /// when only they do.
    pub(crate) fn data_shaped(&self, name: &str) -> Option<&[String]> {
        self.data_shaped.get(name).map(Vec::as_slice)
    }
}

/// What a build knows of its variables by NAME, for a reader that addresses
/// one after the build (the inline-test runner's §6.6 assertions): the
/// build's [`ShapeTable`], and the inputs a coupling substituted away.
#[derive(Debug, Clone, Default)]
pub(crate) struct BuiltVariables {
    pub(crate) shapes: Arc<ShapeTable>,
    /// [`crate::flatten::FlattenMetadata::bound_inputs`]: `to → (from,
    /// factor)`. Empty for a build that applied no coupling.
    pub(crate) bound_inputs: indexmap::IndexMap<String, (String, Option<f64>)>,
}

impl BuiltVariables {
    /// `name`'s non-empty axes: the table's, else, for an input a coupling
    /// bound (`Box.T` bound to `Col.T`), those of the variable at the end of
    /// its chain of bindings, so a reader that names the input finds the
    /// field it reads.
    pub(crate) fn axes(&self, name: &str) -> Option<&[String]> {
        if let Some(axes) = self.shapes.axes(name) {
            return Some(axes);
        }
        let mut name = name;
        if !self.bound_inputs.contains_key(name) {
            return None;
        }
        for _ in 0..=self.bound_inputs.len() {
            match self.bound_inputs.get(name) {
                Some((from, _)) => name = from,
                None => break,
            }
        }
        self.shapes.axes(name).filter(|a| !a.is_empty())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::simulate_array::{apply_shape_rewrites, model_from_flattened};
    use crate::types::IndexSet;

    fn table_of(doc: serde_json::Value, inherited: Option<&ShapeTable>) -> ShapeTable {
        let file = crate::parse::load_string(&doc.to_string()).expect("loads");
        let flat = crate::flatten::flatten(&file).expect("flattens");
        let mut model = model_from_flattened(&flat);
        let index_sets: HashMap<String, IndexSet> = flat
            .index_sets
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        apply_shape_rewrites(&mut model, &index_sets, inherited).expect("rewrites")
    }

    fn doc(equations: serde_json::Value) -> serde_json::Value {
        serde_json::json!({
            "esm": "2.0.0",
            "metadata": {"name": "shape_table"},
            "index_sets": {"cell": {"kind": "interval", "size": 3}},
            "models": {"M": {
                "variables": {
                    "lev": {"type": "parameter", "default": 1.0},
                    "F": {"type": "parameter", "shape": ["cell"], "default": 1.5},
                    "X": {"type": "unknown"},
                    "G": {"type": "unknown"},
                    "S": {"type": "unknown", "shape": []}
                },
                "equations": equations
            }}
        })
    }

    /// Each shape is recorded once, with where it came from, and only the
    /// shapes no declaration records are the build's own.
    #[test]
    fn every_shape_is_recorded_with_its_source() {
        let table = table_of(
            doc(serde_json::json!([
                {"lhs": "X", "rhs": {"op": "ifelse", "args": [
                    {"op": "<", "args": ["lev", 2.0]},
                    {"op": "*", "args": ["F", 2.0]}, 0.0]}},
                {"lhs": "G", "rhs": {"op": "*", "args": ["F", 3.0]}},
                {"lhs": "S", "rhs": 1.0}
            ])),
            None,
        );
        let cell = ["cell".to_string()];
        assert_eq!(table.axes("M.F"), Some(&cell[..]));
        assert_eq!(table.source("M.F"), Some(ShapeSource::Declared));
        assert_eq!(table.built_axes("M.F"), None);
        assert_eq!(table.axes("M.X"), Some(&cell[..]));
        assert_eq!(table.source("M.X"), Some(ShapeSource::Conditional));
        assert_eq!(table.built_axes("M.X"), Some(&cell[..]));
        assert_eq!(table.axes("M.G"), Some(&cell[..]));
        assert_eq!(table.source("M.G"), Some(ShapeSource::Inferred));
        assert_eq!(table.built_axes("M.G"), None);
        assert_eq!(table.axes("M.S"), None);
        assert_eq!(table.axes("M.lev"), None);
    }

    /// A system cut from a build keeps the shapes that build decided, though
    /// it no longer holds the equation that decided them.
    #[test]
    fn a_restricted_system_inherits_the_shapes_its_parent_built() {
        let parent = table_of(
            doc(serde_json::json!([
                {"lhs": "X", "rhs": {"op": "ifelse", "args": [
                    {"op": "<", "args": ["lev", 2.0]},
                    {"op": "*", "args": ["F", 2.0]}, 0.0]}}
            ])),
            None,
        );
        let cut = table_of(
            doc(serde_json::json!([{"lhs": "S", "rhs": 1.0}])),
            Some(&parent),
        );
        let cell = ["cell".to_string()];
        assert_eq!(cut.axes("M.X"), Some(&cell[..]));
        assert_eq!(cut.source("M.X"), Some(ShapeSource::Inherited));
        assert_eq!(cut.built_axes("M.X"), Some(&cell[..]));
        let alone = table_of(doc(serde_json::json!([{"lhs": "S", "rhs": 1.0}])), None);
        assert_eq!(alone.axes("M.X"), None);
    }

    /// An input a coupling bound away reads the axes of the variable at the
    /// end of its chain of bindings.
    #[test]
    fn a_bound_input_reads_the_axes_at_the_end_of_its_chain() {
        let mut entries = HashMap::new();
        entries.insert(
            "Col.T".to_string(),
            ShapeEntry {
                axes: vec!["cell".to_string()],
                source: ShapeSource::Declared,
            },
        );
        let built = BuiltVariables {
            shapes: Arc::new(ShapeTable {
                entries,
                data_shaped: HashMap::new(),
            }),
            bound_inputs: [
                ("Box.T".to_string(), ("Mid.T".to_string(), None)),
                ("Mid.T".to_string(), ("Col.T".to_string(), None)),
            ]
            .into_iter()
            .collect(),
        };
        let cell = ["cell".to_string()];
        assert_eq!(built.axes("Box.T"), Some(&cell[..]));
        assert_eq!(built.axes("Mid.T"), Some(&cell[..]));
        assert_eq!(built.axes("Col.T"), Some(&cell[..]));
        assert_eq!(built.axes("Other.T"), None);
    }
}
