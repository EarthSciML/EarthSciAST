//! Variable bounds, `lb` and `ub` on a model variable (esm-spec §6.3.2): the
//! load-time version gate and the four `validate` rules.
//!
//! A bound is a number or a reference to another variable. What it means to a
//! solver is the consumer's decision; this module only checks that a bound is
//! well-formed. Flattening rewrites a reference bound with the renaming it
//! applies to equations ([`crate::flatten`], esm-libraries-spec §4.7.5).

use crate::EsmFile;
use crate::diagnostic::{DiagnosticError, codes, err};
use crate::structural::{
    ObservedScope, document_observeds, for_each_model_node, referenced_names, resolve_observed_ref,
    resolve_scoped_ref,
};
use crate::types::VariableBound;
use crate::validate::{StructuralError, StructuralErrorCode, SystemInfo};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

/// The JSON pointer of the first `lb` or `ub` on a model variable in `doc`,
/// in document order: models, each model's variables before its subsystems,
/// subsystems depth-first, and within one variable whichever of the two keys
/// is written first.
///
/// Reads the document as authored, so it must run before subsystem refs are
/// inlined: a mounted file is held to its own declared version (esm-spec §4.7),
/// and its bounds are judged when that file is loaded.
pub(crate) fn first_bound_pointer(doc: &Value) -> Option<String> {
    fn in_component(component: &Value, pointer: &str) -> Option<String> {
        if let Some(vars) = component.get("variables").and_then(Value::as_object) {
            for (name, var) in vars {
                let Some(fields) = var.as_object() else {
                    continue;
                };
                if let Some(key) = fields.keys().find(|k| *k == "lb" || *k == "ub") {
                    return Some(format!("{pointer}/variables/{name}/{key}"));
                }
            }
        }
        let subs = component.get("subsystems").and_then(Value::as_object)?;
        subs.iter()
            .find_map(|(name, sub)| in_component(sub, &format!("{pointer}/subsystems/{name}")))
    }
    let models = doc.get("models").and_then(Value::as_object)?;
    models
        .iter()
        .find_map(|(name, model)| in_component(model, &format!("/models/{name}")))
}

/// Reject `lb` / `ub` in a document declaring `esm` < 2.1.0 (esm-spec §6.3.2,
/// "Version gate"), naming the first such field. `offending` yields that
/// field's pointer in THIS file ([`first_bound_pointer`] over the authored
/// tree) and is called only when the declared version is below 2.1.0.
pub(crate) fn reject_variable_bounds_pre_v21(
    view: &Value,
    offending: impl FnOnce() -> Option<String>,
) -> Result<(), DiagnosticError> {
    let Some(esm) = view.get("esm").and_then(Value::as_str) else {
        return Ok(());
    };
    let Some((major, minor, _)) = crate::diagnostic::parse_semver(esm) else {
        return Ok(());
    };
    if (major, minor) >= (2, 1) {
        return Ok(());
    }
    match offending() {
        None => Ok(()),
        Some(path) => Err(err(
            codes::VARIABLE_BOUNDS_VERSION_TOO_OLD,
            format!(
                "variable bounds (`lb` / `ub`) require esm >= 2.1.0; file declares {esm}. \
                 Offending path: {path}"
            ),
        )),
    }
}

/// A bounded variable's declared shape, for comparison: `None` is scalar
/// (`shape` omitted, `null` or empty).
fn declared_shape(shape: Option<&Vec<String>>) -> Option<&[String]> {
    shape.filter(|s| !s.is_empty()).map(Vec::as_slice)
}

fn shape_label(shape: Option<&[String]>) -> String {
    match shape {
        None => "(scalar)".to_string(),
        Some(s) => format!("[{}]", s.join(", ")),
    }
}

/// The declared shape of the parameter `member` of the reaction system at the
/// full scoped path `system`: a top-level reaction system or one nested as a
/// subsystem of another, at any depth. `None` for a species, an unshaped
/// parameter, or a path through a `{"ref"}` mount not yet inlined.
fn reaction_parameter_shape(file: &EsmFile, system: &str, member: &str) -> Option<Vec<String>> {
    let mut segments = system.split('.');
    let head = segments.next()?;
    let rest: Vec<&str> = segments.collect();
    if rest.is_empty() {
        return file
            .reaction_systems
            .as_ref()?
            .get(head)?
            .parameters
            .get(member)?
            .shape
            .clone();
    }
    let subsystems = file
        .reaction_systems
        .as_ref()?
        .get(head)?
        .subsystems
        .as_ref()?;
    let mut node = subsystems.get(rest[0])?;
    for segment in &rest[1..] {
        node = node.get("subsystems")?.get(*segment)?;
    }
    let shape = node
        .get("parameters")?
        .get(member)?
        .get("shape")?
        .as_array()?;
    shape
        .iter()
        .map(|axis| axis.as_str().map(str::to_string))
        .collect()
}

/// What a bound reference resolved to.
enum Target {
    /// A variable of a model node, by full scoped name, with its declared
    /// shape.
    Variable {
        full: String,
        shape: Option<Vec<String>>,
    },
    /// A reaction-system species or parameter, at any nesting depth. Species
    /// are scalar; `shape` is the parameter's declared shape, `None` where it
    /// is scalar.
    ReactionSystemMember { shape: Option<Vec<String>> },
}

/// The model-node data the bound checks read, keyed by full scoped name.
struct Node {
    pointer: String,
    shapes: HashMap<String, Option<Vec<String>>>,
    bounds: Vec<(String, Option<Vec<String>>, BoundPair)>,
}

type BoundPair = (Option<VariableBound>, Option<VariableBound>);

/// Report every malformed variable bound in the document's models and their
/// subsystems at every depth (esm-spec §6.3.2 "Validity", rules 1–4).
///
/// A reference is resolved by [`resolve_observed_ref`], the §4.9.7 resolver
/// the `circular_dependency` check uses: the owning node's own names, then a
/// dotted path relative to its own subsystems, then a top-level system path.
/// A dotted reference no model node declares may still name a reaction-system
/// species or parameter, resolved against `system_refs` by
/// [`resolve_scoped_ref`] along the same two paths. The circularity walk
/// follows observed definitions only ([`document_observeds`]), so it stops at
/// a state, a parameter, an algebraic unknown and a species.
pub(crate) fn validate_variable_bounds(
    esm_file: &EsmFile,
    system_refs: &HashMap<String, SystemInfo>,
    errors: &mut Vec<StructuralError>,
) {
    let Some(models) = &esm_file.models else {
        return;
    };
    let mut scopes: Vec<ObservedScope> = Vec::new();
    let mut nodes: Vec<(String, Node)> = Vec::new();
    let mut any_bound = false;
    for_each_model_node(models, &mut |path, pointer, variables, equations| {
        let bounds: Vec<_> = variables
            .iter()
            .filter(|(_, v)| v.lb.is_some() || v.ub.is_some())
            .map(|(name, v)| (name.clone(), v.shape.clone(), (v.lb.clone(), v.ub.clone())))
            .collect();
        any_bound |= !bounds.is_empty();
        scopes.push(ObservedScope::new(path.to_string(), variables, equations));
        nodes.push((
            path.to_string(),
            Node {
                pointer: pointer.to_string(),
                shapes: variables
                    .iter()
                    .map(|(name, v)| (name.clone(), v.shape.clone()))
                    .collect(),
                bounds,
            },
        ));
    });
    if !any_bound {
        return;
    }
    let by_path: HashMap<&str, &ObservedScope> =
        scopes.iter().map(|s| (s.path.as_str(), s)).collect();
    let node_by_path: HashMap<&str, &Node> = nodes.iter().map(|(p, n)| (p.as_str(), n)).collect();
    let observed = document_observeds(&scopes, &by_path);
    let ctx = Ctx {
        esm_file,
        system_refs,
        by_path: &by_path,
        nodes: &node_by_path,
        observed: &observed,
    };

    for (path, node) in &nodes {
        for (name, shape, (lb, ub)) in &node.bounds {
            let var_pointer = format!("{}/variables/{name}", node.pointer);
            for (which, bound) in [("lb", lb), ("ub", ub)] {
                if let Some(VariableBound::Reference(reference)) = bound {
                    ctx.check_reference(
                        path,
                        name,
                        shape.as_ref(),
                        which,
                        reference,
                        &format!("{var_pointer}/{which}"),
                        errors,
                    );
                }
            }
            if let (Some(VariableBound::Number(l)), Some(VariableBound::Number(u))) = (lb, ub)
                && let (Some(lo), Some(hi)) = (l.as_f64(), u.as_f64())
                && lo > hi
            {
                errors.push(StructuralError {
                    path: var_pointer,
                    code: StructuralErrorCode::VariableBoundsInverted,
                    message: format!("'{name}' has lb {l} greater than ub {u}"),
                    details: serde_json::json!({ "variable": name, "lb": l, "ub": u }),
                });
            }
        }
    }
}

struct Ctx<'a> {
    esm_file: &'a EsmFile,
    system_refs: &'a HashMap<String, SystemInfo>,
    by_path: &'a HashMap<&'a str, &'a ObservedScope>,
    nodes: &'a HashMap<&'a str, &'a Node>,
    observed: &'a HashSet<String>,
}

impl Ctx<'_> {
    /// Rules 1–3 for one reference bound of the variable `name` declared in
    /// the model node `from`.
    #[allow(clippy::too_many_arguments)]
    fn check_reference(
        &self,
        from: &str,
        name: &str,
        shape: Option<&Vec<String>>,
        which: &str,
        reference: &str,
        pointer: &str,
        errors: &mut Vec<StructuralError>,
    ) {
        // Rule 1: the reference resolves.
        let Some(target) = self.resolve(from, reference) else {
            errors.push(StructuralError {
                path: pointer.to_string(),
                code: StructuralErrorCode::UndefinedVariable,
                message: format!(
                    "Variable \"{reference}\" referenced as the {which} of '{name}' but not \
                     declared"
                ),
                details: serde_json::json!({ "variable": reference, "bound": which }),
            });
            return;
        };
        let details = serde_json::json!({
            "variable": name,
            "bound": which,
            "reference": reference,
        });

        // Rule 2: the referenced shape is scalar or the bounded variable's.
        let target_shape = match &target {
            Target::Variable { shape, .. } | Target::ReactionSystemMember { shape } => {
                declared_shape(shape.as_ref())
            }
        };
        let own_shape = declared_shape(shape);
        if target_shape.is_some() && target_shape != own_shape {
            errors.push(StructuralError {
                path: pointer.to_string(),
                code: StructuralErrorCode::VariableBoundShapeMismatch,
                message: format!(
                    "The {which} of '{name}' references '{reference}', shaped {}; a bound must \
                     be scalar or the bounded variable's shape {}",
                    shape_label(target_shape),
                    shape_label(own_shape)
                ),
                details: details.clone(),
            });
        }

        // Rule 3: the reference is not the variable itself, nor an observed
        // whose definition reaches it.
        let Target::Variable { full, .. } = &target else {
            return;
        };
        let bounded = format!("{from}.{name}");
        if *full == bounded {
            errors.push(StructuralError {
                path: pointer.to_string(),
                code: StructuralErrorCode::VariableBoundCircular,
                message: format!("The {which} of '{name}' refers to '{reference}' itself"),
                details,
            });
            return;
        }
        if let Some(chain) = self.observed_chain_to(full, &bounded) {
            let local = |n: &String| {
                n.strip_prefix(from)
                    .and_then(|r| r.strip_prefix('.'))
                    .unwrap_or(n)
                    .to_string()
            };
            let rendered: Vec<String> = chain.iter().map(local).collect();
            errors.push(StructuralError {
                path: pointer.to_string(),
                code: StructuralErrorCode::VariableBoundCircular,
                message: format!(
                    "The {which} of '{name}' refers to '{reference}', whose definition depends \
                     on '{name}' ({})",
                    rendered.join(" -> ")
                ),
                details,
            });
        }
    }

    /// Resolve `reference`, read in the model node `from`, as a free variable
    /// reference in that node's expressions resolves (esm-spec §4.9.7).
    fn resolve(&self, from: &str, reference: &str) -> Option<Target> {
        if let Some(full) = resolve_observed_ref(self.by_path, from, reference) {
            let (system, var) = full.rsplit_once('.')?;
            let shape = self
                .nodes
                .get(system)
                .and_then(|n| n.shapes.get(var))
                .cloned()
                .flatten();
            return Some(Target::Variable { full, shape });
        }
        if !reference.contains('.') {
            return None;
        }
        let relative = format!("{from}.{reference}");
        let full = [relative.as_str(), reference]
            .into_iter()
            .find(|candidate| resolve_scoped_ref(candidate, self.system_refs).is_ok())?;
        let (system, member) = full.rsplit_once('.')?;
        let shape = reaction_parameter_shape(self.esm_file, system, member);
        Some(Target::ReactionSystemMember { shape })
    }

    /// The chain of full scoped names from the observed `start` to `goal`
    /// through observed definitions (`start`, …, `goal`), or `None` when no
    /// observed definition reached from `start` reads `goal`. Depth-first with
    /// each definition's references in lexicographic order, so the chain
    /// reported is deterministic; iterative, as the chain depth is bounded
    /// only by the document.
    fn observed_chain_to(&self, start: &str, goal: &str) -> Option<Vec<String>> {
        if !self.observed.contains(start) {
            return None;
        }
        let successors = |node: &str| -> Vec<String> {
            let Some((scope_path, local)) = node.rsplit_once('.') else {
                return Vec::new();
            };
            let Some(scope) = self.by_path.get(scope_path) else {
                return Vec::new();
            };
            let Some(rhs) = scope.class.observed_definitions.get(local) else {
                return Vec::new();
            };
            let mut names: Vec<String> = referenced_names(rhs).into_iter().collect();
            names.sort();
            names
                .iter()
                .filter_map(|r| resolve_observed_ref(self.by_path, scope_path, r))
                .collect()
        };
        let mut visited: HashSet<String> = HashSet::from([start.to_string()]);
        let mut chain: Vec<String> = vec![start.to_string()];
        let mut cursors: Vec<std::vec::IntoIter<String>> = vec![successors(start).into_iter()];
        while let Some(cursor) = cursors.last_mut() {
            let Some(next) = cursor.next() else {
                cursors.pop();
                chain.pop();
                continue;
            };
            if next == goal {
                chain.push(next);
                return Some(chain);
            }
            if self.observed.contains(&next) && visited.insert(next.clone()) {
                cursors.push(successors(&next).into_iter());
                chain.push(next);
            }
        }
        None
    }
}
