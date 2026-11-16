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
use crate::simulate_array::data_feed_source;
use crate::types::{EsmFile, ParameterUpdateSpec, for_each_subsystem_mut};

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
/// `from` binding (esm-spec §5.4)? The classifier lists a parameter in
/// `data_fed` under the same test ([`data_feed_source`]),
/// so the refusal and the pin agree on which parameters they are talking about.
/// A `schedule` / `condition` / `crossing` update, or a `handler`-valued one, is
/// not provider-fed and is not this module's business.
pub(crate) fn is_data_fed(spec: &ParameterUpdateSpec) -> bool {
    data_feed_source(spec).is_some()
}

/// Strip the `update` of every data-fed parameter the caller pinned with `p`,
/// and report their flattened names.
///
/// Walks the places a data-fed parameter can be declared — a model's
/// `variables` and a reaction system's `parameters`, at the top level and in
/// every subsystem at any depth — naming each the way flatten will:
/// `Component.var`, with each subsystem's own name spliced in.
///
/// A pin is deliberately allowed to be ambiguous (see [`designates`]): binding
/// one parameter too many turns a refusal into a build the caller asked for,
/// whereas binding one too few would make the documented escape hatch fail for
/// the spelling esm-spec §6.6.2 admits.
pub(crate) fn pin_data_fed_parameters<'a>(
    file: &mut EsmFile,
    p: impl IntoIterator<Item = &'a String> + Clone,
) -> Vec<String> {
    fn strip<'a, 'v>(
        prefix: &str,
        updates: impl Iterator<Item = (&'v String, &'v mut Option<ParameterUpdateSpec>)>,
        p: impl IntoIterator<Item = &'a String> + Clone,
        out: &mut Vec<String>,
    ) {
        for (name, update) in updates {
            let full = format!("{prefix}.{name}");
            if update.as_ref().is_some_and(is_data_fed) && pinned(p.clone(), &full) {
                *update = None;
                out.push(full);
            }
        }
    }
    let mut pinned_names = Vec::new();
    for (model_name, model) in file.models.iter_mut().flatten() {
        strip(
            model_name,
            model.variables.iter_mut().map(|(n, v)| (n, &mut v.update)),
            p.clone(),
            &mut pinned_names,
        );
        for_each_subsystem_mut(model, model_name, &mut |path, sub| {
            strip(
                path,
                sub.variables.iter_mut().map(|(n, v)| (n, &mut v.update)),
                p.clone(),
                &mut pinned_names,
            );
        });
    }
    for (sys_name, sys) in file.reaction_systems.iter_mut().flatten() {
        strip(
            sys_name,
            sys.parameters.iter_mut().map(|(n, v)| (n, &mut v.update)),
            p.clone(),
            &mut pinned_names,
        );
        for_each_subsystem_mut(sys, sys_name, &mut |path, sub| {
            strip(
                path,
                sub.parameters.iter_mut().map(|(n, v)| (n, &mut v.update)),
                p.clone(),
                &mut pinned_names,
            );
        });
    }
    pinned_names
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
/// * the caller pinned it with `p` (`pins`). When the input was a document,
///   [`pin_data_fed_parameters`] already stripped the `update`, so the
///   parameter is not in this list at all; a PRE-FLATTENED system has no
///   document to strip, so the pin is honoured here instead.
///
/// Called after the providers are bound and BEFORE the compiler's own gate
/// builds the tape, so the answer is the same under `native` and
/// `interpreter`: this asks whether the DOCUMENT's inputs are bound, not what a
/// compiler can lower. Under `native` the tape would otherwise report the same
/// document as `compiler_refused_rule` ("wholesale: unresolved symbol"), which
/// names the tape's limits in place of the defect and which no `providers`
/// argument would clear.
pub(crate) fn refuse_unbound<'a>(
    compiled: &crate::simulate_array::ArrayCompiled,
    const_arrays: &std::collections::HashMap<String, ndarray::ArrayD<f64>>,
    discrete_forcing: &std::collections::HashSet<String>,
    pins: impl IntoIterator<Item = &'a String> + Clone,
) -> Result<(), SimulateError> {
    if compiled.data_fed().is_empty() {
        return Ok(());
    }
    let forcing = compiled.forcing_handle();
    let bound = forcing.borrow();
    for (name, source) in compiled.data_fed() {
        // The forcing buffer and the provider registries are keyed by the
        // variable name the model declares: QUALIFIED on the coupled path
        // (`Forcing.k`, which `data_fed` spells the same way) and BARE on the
        // single-model path, where `data_fed` was qualified afterwards by the
        // model's namespace. The bare spelling is accepted only on that path
        // and only for THIS parameter's own leaf — on a coupled document two
        // components may each declare a `k`, and a binding for one must not
        // answer for the other.
        if pinned(pins.clone(), name) {
            continue;
        }
        let bare = compiled
            .namespace()
            .and_then(|ns| name.strip_prefix(ns))
            .and_then(|rest| rest.strip_prefix('.'));
        let known = |k: &str| k == name || bare == Some(k);
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
}
