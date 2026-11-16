//! `Display` for expressions and equations: Typst math, printed by
//! [`crate::print_math`] with the expression's own names declared
//! ([`crate::expression_names`]). This is the one way the crate quotes an
//! expression in a message.
//!
//! A file, a model and a reaction system display as a short summary: names
//! and counts, no math.

use crate::document::{DocumentFormat, expression_names, print_math};
use crate::types::{Equation, EsmFile, Expr, Model, ReactionSystem, VariableType};
use std::fmt;

/// Typst math for an ESM expression or equation given as JSON.
pub(crate) fn math_text(value: &serde_json::Value) -> String {
    print_math(value, &expression_names(value), DocumentFormat::Typst)
}

fn write_math<T: serde::Serialize + fmt::Debug>(v: &T, f: &mut fmt::Formatter<'_>) -> fmt::Result {
    match serde_json::to_value(v) {
        Ok(value) => f.write_str(&math_text(&value)),
        Err(_) => write!(f, "{v:?}"),
    }
}

impl fmt::Display for Expr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write_math(self, f)
    }
}

impl fmt::Display for Equation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write_math(self, f)
    }
}

/// `n` and the noun, plural unless `n` is 1.
fn count(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

/// `Name (2 parameters, 1 equation)`.
impl fmt::Display for Model {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let parameters = self
            .variables
            .values()
            .filter(|v| matches!(v.var_type, VariableType::Parameter))
            .count();
        write!(
            f,
            "{} ({}, {})",
            self.name.as_deref().unwrap_or("Unnamed"),
            count(parameters, "parameter", "parameters"),
            count(self.equations.len(), "equation", "equations")
        )
    }
}

/// `ReactionSystem (3 species, 1 parameter, 2 reactions)`.
impl fmt::Display for ReactionSystem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "ReactionSystem ({}, {}, {})",
            count(self.species.len(), "species", "species"),
            count(self.parameters.len(), "parameter", "parameters"),
            count(self.reactions.len(), "reaction", "reactions")
        )
    }
}

/// The version and name, then one line per reaction system and model, and
/// how many data sources and coupling entries there are.
impl fmt::Display for EsmFile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "ESM v{}: {}",
            self.esm,
            self.metadata.name.as_deref().unwrap_or("Unnamed")
        )?;
        if let Some(systems) = self.reaction_systems.as_ref().filter(|s| !s.is_empty()) {
            write!(f, "\n  Reaction systems:")?;
            for (key, system) in systems {
                write!(f, "\n    {key}: {system}")?;
            }
        }
        if let Some(models) = self.models.as_ref().filter(|m| !m.is_empty()) {
            write!(f, "\n  Models:")?;
            for (key, model) in models {
                write!(f, "\n    {key}: {model}")?;
            }
        }
        if let Some(sources) = self.data_sources.as_ref().filter(|s| !s.is_empty()) {
            write!(
                f,
                "\n  {}",
                count(sources.len(), "data source", "data sources")
            )?;
        }
        if let Some(coupling) = self.coupling.as_ref().filter(|c| !c.is_empty()) {
            write!(
                f,
                "\n  {}",
                count(coupling.len(), "coupling entry", "coupling entries")
            )?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn components_display_as_a_summary() {
        let file: crate::EsmFile = serde_json::from_value(serde_json::json!({
            "esm": "2.3.0",
            "metadata": {"name": "Decay"},
            "models": {"M": {
                "name": "Decay",
                "variables": {
                    "N": {"type": "unknown", "default": 1.0},
                    "k": {"type": "parameter", "default": 0.1}
                },
                "equations": [{"lhs": {"op": "D", "args": ["N"], "wrt": "t"},
                               "rhs": {"op": "*", "args": [-1, "k", "N"]}}]
            }},
            "reaction_systems": {"R": {
                "species": {"A": {}, "B": {}},
                "parameters": {"k1": {}},
                "reactions": [{"id": "r1", "substrates": [{"species": "A", "stoichiometry": 1}],
                               "products": [{"species": "B", "stoichiometry": 1}], "rate": "k1"}]
            }}
        }))
        .unwrap();
        assert_eq!(
            file.to_string(),
            "ESM v2.3.0: Decay\n  Reaction systems:\n    R: ReactionSystem (2 species, 1 parameter, 1 reaction)\n  Models:\n    M: Decay (1 parameter, 1 equation)"
        );
    }
}
