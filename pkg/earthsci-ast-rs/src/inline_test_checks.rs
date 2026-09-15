//! Static checks on every inline test (esm-spec §6.6), decidable from the
//! document alone and so owed by every binding, executing or not:
//!
//! - an assertion `variable` that is a bare name (element suffix removed) the
//!   asserting component does not declare is `undefined_variable` (§6.6.3); a
//!   dotted target names a declaration elsewhere and is resolved by the runtime;
//! - an `initial_conditions` / `parameter_overrides` key that matches no declared
//!   name under the §6.6.2 rules is `unknown_override_key`; skipped when the
//!   document still holds an unresolved `{ref}` mount a key could name into;
//! - an assertion whose form does not match the declared rank of its target is
//!   `assertion_rank_mismatch` (§6.6.5).

use std::collections::{HashMap, HashSet};

use crate::validate::{StructuralError, StructuralErrorCode};
use crate::{EsmFile, ModelTest};

/// `u[1]` -> `("u", true)`; a name without an element suffix is unchanged.
fn strip_element_suffix(name: &str) -> (&str, bool) {
    if let Some(inner) = name.strip_suffix(']')
        && let Some(open) = inner.rfind('[')
        && !inner[open + 1..].contains(']')
    {
        return (&name[..open], true);
    }
    (name, false)
}

/// Escape one JSON Pointer reference token (RFC 6901).
fn pointer_token(key: &str) -> String {
    key.replace('~', "~0").replace('/', "~1")
}

/// The document's declared names qualified as a flatten qualifies them
/// (`<component>.<name>`, `<component>.<subsystem>.<name>` at any depth), the
/// component and subsystem names §6.6.2 rule 2 validates a key's leading
/// segments against, and whether every mount is resolved.
struct DeclaredNames {
    names: HashSet<String>,
    namespaces: HashSet<String>,
    complete: bool,
}

impl DeclaredNames {
    fn collect(esm_file: &EsmFile) -> Self {
        let mut out = DeclaredNames {
            names: HashSet::new(),
            namespaces: HashSet::new(),
            complete: true,
        };
        for (name, model) in esm_file.models.iter().flatten() {
            out.namespaces.insert(name.clone());
            out.names
                .extend(model.variables.keys().map(|v| format!("{name}.{v}")));
            for (sub_name, sub) in model.subsystems.iter().flatten() {
                out.add_raw(&format!("{name}.{sub_name}"), sub);
            }
        }
        for (name, rs) in esm_file.reaction_systems.iter().flatten() {
            out.namespaces.insert(name.clone());
            out.names
                .extend(rs.species.keys().map(|s| format!("{name}.{s}")));
            out.names
                .extend(rs.parameters.keys().map(|p| format!("{name}.{p}")));
            for (sub_name, sub) in rs.subsystems.iter().flatten() {
                out.add_raw(&format!("{name}.{sub_name}"), sub);
            }
        }
        out
    }

    fn add_raw(&mut self, prefix: &str, raw: &serde_json::Value) {
        let Some(component) = raw.as_object().filter(|c| !c.contains_key("ref")) else {
            self.complete = false;
            return;
        };
        let last = prefix.rsplit('.').next().unwrap_or(prefix);
        self.namespaces.insert(last.to_string());
        for field in ["variables", "species", "parameters"] {
            if let Some(decls) = component.get(field).and_then(|d| d.as_object()) {
                self.names
                    .extend(decls.keys().map(|n| format!("{prefix}.{n}")));
            }
        }
        if let Some(subs) = component.get("subsystems").and_then(|s| s.as_object()) {
            for (sub_name, sub) in subs {
                self.add_raw(&format!("{prefix}.{sub_name}"), sub);
            }
        }
    }

    /// Whether `key` reaches a declared name under §6.6.2 rules 1-3: an exact
    /// hit; a dotted suffix of the key that is a name, every dropped leading
    /// segment naming a component or subsystem; or the key a dotted suffix of
    /// some name. Ambiguity is a runtime diagnostic, so one match suffices.
    fn matches(&self, key: &str) -> bool {
        if self.names.contains(key) {
            return true;
        }
        let parts: Vec<&str> = key.split('.').collect();
        for i in 1..parts.len() {
            if self.names.contains(&parts[i..].join("."))
                && parts[..i].iter().all(|p| self.namespaces.contains(*p))
            {
                return true;
            }
        }
        let tail = format!(".{key}");
        self.names.iter().any(|n| n.ends_with(&tail))
    }
}

/// Run the static inline-test checks over every top-level component, in sorted
/// order so the findings do not depend on map iteration.
pub(crate) fn validate_inline_tests(esm_file: &EsmFile, errors: &mut Vec<StructuralError>) {
    let declared = DeclaredNames::collect(esm_file);
    if let Some(models) = &esm_file.models {
        let mut names: Vec<&String> = models.keys().collect();
        names.sort();
        for name in names {
            let model = &models[name];
            let shapes: HashMap<&str, &[String]> = model
                .variables
                .iter()
                .map(|(v, decl)| (v.as_str(), decl.shape.as_deref().unwrap_or(&[])))
                .collect();
            let tests = model.tests.as_deref().unwrap_or(&[]);
            check_tests(
                tests,
                &format!("/models/{name}"),
                &shapes,
                &declared,
                errors,
            );
        }
    }
    if let Some(systems) = &esm_file.reaction_systems {
        let mut names: Vec<&String> = systems.keys().collect();
        names.sort();
        for name in names {
            let rs = &systems[name];
            let mut shapes: HashMap<&str, &[String]> =
                rs.species.keys().map(|s| (s.as_str(), &[][..])).collect();
            for (p, decl) in &rs.parameters {
                shapes.insert(p.as_str(), decl.shape.as_deref().unwrap_or(&[]));
            }
            let tests = rs.tests.as_deref().unwrap_or(&[]);
            check_tests(
                tests,
                &format!("/reaction_systems/{name}"),
                &shapes,
                &declared,
                errors,
            );
        }
    }
}

fn check_tests(
    tests: &[ModelTest],
    component_path: &str,
    shapes: &HashMap<&str, &[String]>,
    declared: &DeclaredNames,
    errors: &mut Vec<StructuralError>,
) {
    for (ti, test) in tests.iter().enumerate() {
        let base = format!("{component_path}/tests/{ti}");
        if declared.complete {
            for (field, keys) in [
                ("initial_conditions", &test.initial_conditions),
                ("parameter_overrides", &test.parameter_overrides),
            ] {
                let mut keys: Vec<&String> = keys.iter().flat_map(|m| m.keys()).collect();
                keys.sort();
                for key in keys {
                    let (bare_key, _) = strip_element_suffix(key);
                    if declared.matches(bare_key) {
                        continue;
                    }
                    errors.push(StructuralError {
                        path: format!("{base}/{field}/{}", pointer_token(key)),
                        code: StructuralErrorCode::UnknownOverrideKey,
                        message: format!(
                            "Override key \"{key}\" in {field} matches no declared name"
                        ),
                        details: serde_json::json!({ "key": key, "field": field }),
                    });
                }
            }
        }
        for (ai, assertion) in test.assertions.iter().enumerate() {
            let (bare, is_element) = strip_element_suffix(&assertion.variable);
            if bare.contains('.') {
                continue;
            }
            let pointer = format!("{base}/assertions/{ai}");
            let Some(shape) = shapes.get(bare) else {
                errors.push(StructuralError {
                    path: format!("{pointer}/variable"),
                    code: StructuralErrorCode::UndefinedVariable,
                    message: format!(
                        "Variable \"{bare}\" referenced in assertion variable but not declared"
                    ),
                    details: serde_json::json!({ "variable": bare }),
                });
                continue;
            };
            if is_element {
                continue;
            }
            let selects = assertion.coords.is_some() || assertion.reduce.is_some();
            if !shape.is_empty() && !selects {
                errors.push(StructuralError {
                    path: pointer,
                    code: StructuralErrorCode::AssertionRankMismatch,
                    message: format!(
                        "Assertion on shaped variable \"{bare}\" selects no scalar (give coords, reduce, or an element name)"
                    ),
                    details: serde_json::json!({ "variable": bare, "shape": shape }),
                });
            } else if shape.is_empty() && selects {
                errors.push(StructuralError {
                    path: pointer,
                    code: StructuralErrorCode::AssertionRankMismatch,
                    message: format!(
                        "Assertion on scalar variable \"{bare}\" carries coords or reduce"
                    ),
                    details: serde_json::json!({ "variable": bare, "shape": [] }),
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::strip_element_suffix;

    #[test]
    fn element_suffix_is_stripped_only_at_the_end() {
        assert_eq!(strip_element_suffix("u[1]"), ("u", true));
        assert_eq!(strip_element_suffix("u[2,3]"), ("u", true));
        assert_eq!(strip_element_suffix("u[1][2]"), ("u[1]", true));
        assert_eq!(strip_element_suffix("u"), ("u", false));
        assert_eq!(strip_element_suffix("u[1]x"), ("u[1]x", false));
    }
}
