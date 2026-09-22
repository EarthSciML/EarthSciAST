//! Data-fed parameters and what binds them (esm-spec §5.4/§8.5/§9.6.6,
//! CONFORMANCE_SPEC §5.46).
//!
//! A **data-fed parameter** is one whose `update` is `{kind: "data", source: …,
//! from: {file_variable: …}}`. From esm 1.0.0 that parameter IS the loaded
//! field — a data source is not a component and has no coupling edge — so the
//! `update` block is the whole of the document's statement that this number
//! comes from a file.
//!
//! Two things live here, and they answer two different halves of the ruling:
//!
//! * [`pin_data_fed_parameters`] — a caller who passes an explicit `p` value for
//!   such a parameter HAS bound it, so for THIS build it is no longer fed by
//!   data. Stripping its `update` here, on the typed document and before the
//!   backend is built, is what makes the pin actually reach the right-hand side:
//!   the array runtime routes a parameter that still carries a `data` update to
//!   the external forcing channel, where a `p` binding never lands, and the tape
//!   cannot lower a read of that channel at all. Strip it and the parameter is
//!   ordinary under every compiler.
//! * [`refuse_unbound`] — what is LEFT is refused. The set it reads is recorded
//!   by the array build itself ([`crate::simulate_array::ArrayCompiled::data_fed`]),
//!   at the point that decides a parameter's fate, so it carries the exact
//!   flattened names the runtime will look up and needs no second flatten and no
//!   re-derivation of the document's namespacing.

use crate::simulate::SimulateError;
use crate::types::{EsmFile, ParameterUpdateSpec};

/// Does `key` — a `p` key — designate the flattened parameter `full`?
///
/// Exactly, or as a DOTTED SUFFIX: esm-spec §6.6.2 rule 4 lets a caller spell an
/// override with the bare local name (`k` for `Forcing.k`) or with any partial
/// qualification. Ambiguity between two parameters is the override resolver's
/// business and is reported there; here an ambiguous key binds both, which is
/// the conservative direction — it can only turn a refusal into a build the
/// caller asked for.
fn designates(key: &str, full: &str) -> bool {
    full == key || full.ends_with(&format!(".{key}"))
}

/// Whether some key of `p` designates `full`.
fn pinned<'a>(p: impl IntoIterator<Item = &'a String>, full: &str) -> bool {
    p.into_iter().any(|k| designates(k, full))
}

/// Is this update spec a data feed — some rule of `kind: "data"` carrying a
/// `from` binding (esm-spec §5.4)? A `schedule` / `condition` / `crossing`
/// update, or a `handler`-valued one, is not provider-fed and is not this
/// module's business.
fn is_data_fed(spec: &ParameterUpdateSpec) -> bool {
    spec.rules()
        .iter()
        .any(|r| r.data_source().is_some() && r.value().is_some_and(|v| v.from.is_some()))
}

/// Strip the `update` of every data-fed parameter the caller pinned with `p`,
/// and report their flattened names.
///
/// Walks the three places a data-fed parameter can be declared — a model's
/// `variables`, a model subsystem's (which the typed form keeps as raw JSON),
/// and a reaction system's `parameters` — naming each the way flatten will:
/// `Component.var`, with a subsystem's own name spliced in.
///
/// A pin is deliberately allowed to be ambiguous (see [`designates`]): binding
/// one parameter too many turns a refusal into a build the caller asked for,
/// whereas binding one too few would make the documented escape hatch fail for
/// the spelling esm-spec §6.6.2 admits.
pub(crate) fn pin_data_fed_parameters<'a>(
    file: &mut EsmFile,
    p: impl IntoIterator<Item = &'a String> + Clone,
) -> Vec<String> {
    let mut pinned_names = Vec::new();

    if let Some(models) = file.models.as_mut() {
        for (model_name, model) in models.iter_mut() {
            for (var_name, var) in model.variables.iter_mut() {
                let full = format!("{model_name}.{var_name}");
                if var.update.as_ref().is_some_and(is_data_fed) && pinned(p.clone(), &full) {
                    var.update = None;
                    pinned_names.push(full);
                }
            }
            if let Some(subs) = model.subsystems.as_mut() {
                for (sub_name, sub) in subs.iter_mut() {
                    pin_in_json(
                        sub,
                        &format!("{model_name}.{sub_name}"),
                        p.clone(),
                        &mut pinned_names,
                    );
                }
            }
        }
    }

    if let Some(systems) = file.reaction_systems.as_mut() {
        for (sys_name, sys) in systems.iter_mut() {
            for (par_name, par) in sys.parameters.iter_mut() {
                let full = format!("{sys_name}.{par_name}");
                if par.update.as_ref().is_some_and(is_data_fed) && pinned(p.clone(), &full) {
                    par.update = None;
                    pinned_names.push(full);
                }
            }
            if let Some(subs) = sys.subsystems.as_mut() {
                for (sub_name, sub) in subs.iter_mut() {
                    pin_in_json(
                        sub,
                        &format!("{sys_name}.{sub_name}"),
                        p.clone(),
                        &mut pinned_names,
                    );
                }
            }
        }
    }

    pinned_names
}

/// The same strip, on a subsystem the typed form keeps as raw JSON.
///
/// Reads the update shape structurally (`kind == "data"` plus a `from` object)
/// rather than round-tripping through the typed enum: a subsystem's JSON is
/// whatever the document (or the §4.7 `ref` resolver) put there, and a shape
/// this walk does not recognise is left alone — the parameter is then simply
/// not pinned, which fails towards the refusal rather than towards a silent
/// default.
fn pin_in_json<'a>(
    node: &mut serde_json::Value,
    prefix: &str,
    p: impl IntoIterator<Item = &'a String> + Clone,
    out: &mut Vec<String>,
) {
    let Some(obj) = node.as_object_mut() else {
        return;
    };
    if let Some(vars) = obj.get_mut("variables").and_then(|v| v.as_object_mut()) {
        for (var_name, var) in vars.iter_mut() {
            let full = format!("{prefix}.{var_name}");
            let Some(var_obj) = var.as_object_mut() else {
                continue;
            };
            if json_update_is_data_fed(var_obj.get("update")) && pinned(p.clone(), &full) {
                var_obj.remove("update");
                out.push(full);
            }
        }
    }
    // A reaction-system subsystem spells its parameters under `parameters`.
    if let Some(pars) = obj.get_mut("parameters").and_then(|v| v.as_object_mut()) {
        for (par_name, par) in pars.iter_mut() {
            let full = format!("{prefix}.{par_name}");
            let Some(par_obj) = par.as_object_mut() else {
                continue;
            };
            if json_update_is_data_fed(par_obj.get("update")) && pinned(p.clone(), &full) {
                par_obj.remove("update");
                out.push(full);
            }
        }
    }
    if let Some(subs) = obj.get_mut("subsystems").and_then(|v| v.as_object_mut()) {
        for (sub_name, sub) in subs.iter_mut() {
            pin_in_json(sub, &format!("{prefix}.{sub_name}"), p.clone(), out);
        }
    }
}

/// The raw-JSON reading of [`is_data_fed`]: the object form, or any entry of
/// the array form, with `kind == "data"` and a `from` object.
fn json_update_is_data_fed(update: Option<&serde_json::Value>) -> bool {
    fn one(rule: &serde_json::Value) -> bool {
        rule.get("kind").and_then(|k| k.as_str()) == Some("data") && rule.get("from").is_some()
    }
    match update {
        Some(serde_json::Value::Array(rules)) => rules.iter().any(one),
        Some(rule) => one(rule),
        None => false,
    }
}

/// Refuse every data-fed parameter of `compiled` that nothing bound
/// (esm-spec §9.6.6 `data_source_unbound`, CONFORMANCE_SPEC §5.46).
///
/// Four channels count as bound, and between them they are every way a value
/// can have arrived by the time construction reaches here:
///
/// * the FORCING BUFFER already holds the name — a CONST provider materialized
///   it, or the host wrote it through
///   [`ArrayCompiled::forcing_handle`](crate::simulate_array::ArrayCompiled::forcing_handle);
/// * a DISCRETE provider owns it and will refresh it at its cadence anchors;
/// * a caller `const_arrays` entry supplies it, which is the same channel as
///   the first by another door;
/// * the caller pinned it with `p` — in which case it is not in this list at
///   all, because [`pin_data_fed_parameters`] stripped its `update` before the
///   backend was built.
///
/// Called after the providers are bound and BEFORE the compiler's own gate
/// builds the tape, so the answer is the same under `native` and
/// `interpreter`: this asks whether the DOCUMENT's inputs are bound, not what a
/// compiler can lower. Under `native` the tape would otherwise report the same
/// document as `compiler_refused_rule` ("wholesale: unresolved symbol"), which
/// names the tape's limits in place of the defect and which no `providers`
/// argument would clear.
pub(crate) fn refuse_unbound(
    compiled: &crate::simulate_array::ArrayCompiled,
    const_arrays: &std::collections::HashMap<String, ndarray::ArrayD<f64>>,
    discrete_forcing: &std::collections::HashSet<String>,
) -> Result<(), SimulateError> {
    if compiled.data_fed().is_empty() {
        return Ok(());
    }
    let forcing = compiled.forcing_handle();
    let bound = forcing.borrow();
    for (name, source) in compiled.data_fed() {
        // The forcing buffer and the provider registries are keyed by the
        // variable name the model declares, which on the single-model path is
        // the BARE one; `data_fed` carries the qualified spelling so the
        // refusal names something the caller can find. Accept either.
        let leaf = name.rsplit('.').next().unwrap_or(name);
        let known = |k: &str| k == name || k == leaf;
        if bound.keys().any(|k| known(k))
            || discrete_forcing.iter().any(|k| known(k))
            || const_arrays.keys().any(|k| known(k))
        {
            continue;
        }
        return Err(SimulateError::DataSourceUnbound {
            parameter: name.clone(),
            data_source: source.clone(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dotted_suffix_designates_the_parameter_and_a_partial_segment_does_not() {
        assert!(designates("Forcing.k", "Forcing.k"));
        assert!(designates("k", "Forcing.k"));
        assert!(designates("Sub.k", "M.Sub.k"));
        // "orcing.k" is a suffix of the STRING but not of the dotted path, and
        // "kk" shares the tail character; neither designates the parameter.
        assert!(!designates("orcing.k", "Forcing.k"));
        assert!(!designates("kk", "Forcing.k"));
        assert!(!designates("Forcing", "Forcing.k"));
    }

    #[test]
    fn the_json_reading_accepts_both_update_forms_and_rejects_a_non_data_rule() {
        let data =
            serde_json::json!({"kind": "data", "source": "S", "from": {"file_variable": "v"}});
        assert!(json_update_is_data_fed(Some(&data)));
        assert!(json_update_is_data_fed(Some(&serde_json::json!([
            data.clone()
        ]))));
        // A `data` rule with no `from` binds nothing from a file, and a
        // scheduled rule is not provider-fed at all.
        assert!(!json_update_is_data_fed(Some(
            &serde_json::json!({"kind": "data", "source": "S"})
        )));
        assert!(!json_update_is_data_fed(Some(
            &serde_json::json!({"kind": "schedule", "interval": 1.0, "expression": "x"})
        )));
        assert!(!json_update_is_data_fed(None));
    }
}
