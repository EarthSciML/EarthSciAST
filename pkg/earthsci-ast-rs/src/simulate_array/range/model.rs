//! The compiled model a program keeps: the plain-data part of an
//! [`ArrayCompiled`], without its caches, so a program can be shared across
//! threads.

use crate::simulate_array::{
    AlgebraicRule, ArrayCompiled, ConstArrayScope, RhsRule, RuntimeMode, StateDefault, VarShape,
};
use crate::types::IndexSet;
use indexmap::IndexMap;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

/// Everything a program reads of its compiled model: the rules, the state
/// layout, the parameter tables and the forcing declarations. Built once,
/// never mutated; `Send + Sync`.
#[allow(clippy::type_complexity)]
#[derive(Default)]
pub(in crate::simulate_array) struct ProgramModel {
    pub(in crate::simulate_array) runtime_mode: RuntimeMode,
    pub(in crate::simulate_array) merged_renames: HashMap<String, String>,
    pub(in crate::simulate_array) var_shapes: IndexMap<String, VarShape>,
    pub(in crate::simulate_array) state_defaults: Vec<StateDefault>,
    pub(in crate::simulate_array) param_names: Vec<String>,
    pub(in crate::simulate_array) param_index: HashMap<String, usize>,
    pub(in crate::simulate_array) param_defaults: Vec<Option<f64>>,
    pub(in crate::simulate_array) observed_rules: Vec<AlgebraicRule>,
    pub(in crate::simulate_array) rhs_rules: Vec<RhsRule>,
    pub(in crate::simulate_array) rule_set: u64,
    pub(in crate::simulate_array) n_states: usize,
    pub(in crate::simulate_array) data_fed: Vec<(String, String)>,
    pub(in crate::simulate_array) index_sets: HashMap<String, IndexSet>,
    pub(in crate::simulate_array) const_scope: Arc<ConstArrayScope>,
    pub(in crate::simulate_array) namespace: Option<String>,
    pub(in crate::simulate_array) precision: crate::precision::Env,
    pub(in crate::simulate_array) declared_names: HashSet<String>,
    pub(in crate::simulate_array) inline_param_arrays: HashMap<String, (Vec<usize>, Vec<f64>)>,
    pub(in crate::simulate_array) forcing_decls: IndexMap<String, Option<Vec<usize>>>,
    pub(in crate::simulate_array) forcing_defaults: HashMap<String, Option<(Vec<usize>, Vec<f64>)>>,
    pub(in crate::simulate_array) unvalued_shaped_params: Vec<String>,
}

impl ProgramModel {
    /// The model of `c`, taking its rules and tables.
    pub(in crate::simulate_array) fn from_compiled(c: ArrayCompiled) -> ProgramModel {
        ProgramModel {
            runtime_mode: c.runtime_mode,
            merged_renames: c.merged_renames,
            var_shapes: c.var_shapes,
            state_defaults: c.state_defaults,
            param_names: c.param_names,
            param_index: c.param_index,
            param_defaults: c.param_defaults,
            observed_rules: c.observed_rules,
            rhs_rules: c.rhs_rules,
            rule_set: c.rule_set,
            n_states: c.n_states,
            data_fed: c.data_fed,
            index_sets: c.index_sets,
            const_scope: c.const_scope,
            namespace: c.namespace,
            precision: c.precision,
            declared_names: c.declared_names,
            inline_param_arrays: c.inline_param_arrays,
            forcing_decls: c.forcing_decls,
            forcing_defaults: c.forcing_defaults,
            unvalued_shaped_params: c.unvalued_shaped_params,
        }
    }

    /// An [`ArrayCompiled`] over this model with `var_shapes`, the given rules
    /// and `held`, and empty caches: the input a tape build reads.
    pub(in crate::simulate_array) fn shell(
        &self,
        var_shapes: IndexMap<String, VarShape>,
        rhs_rules: Vec<RhsRule>,
        observed_rules: Vec<AlgebraicRule>,
        held: HashSet<String>,
    ) -> ArrayCompiled {
        let n_states = var_shapes
            .values()
            .map(|v| v.shape.iter().product::<usize>().max(1))
            .sum();
        let state_defaults = vec![StateDefault::Scalar(None); var_shapes.len()];
        ArrayCompiled {
            runtime_mode: self.runtime_mode,
            #[cfg(feature = "xla")]
            xla_rhs: std::cell::OnceCell::new(),
            merged_renames: self.merged_renames.clone(),
            var_shapes,
            state_names: std::cell::OnceCell::new(),
            qualified_state_names: std::cell::OnceCell::new(),
            state_defaults,
            param_names: self.param_names.clone(),
            param_index: self.param_index.clone(),
            param_defaults: self.param_defaults.clone(),
            observed_rules,
            rhs_rules,
            rule_set: crate::simulate_array::rhs::next_rule_set_id(),
            n_states,
            forcing: Default::default(),
            data_fed: self.data_fed.clone(),
            forcing_generation: std::cell::Cell::new(0),
            field_ics: Vec::new(),
            init_faqs: Vec::new(),
            ic_scope: Default::default(),
            index_sets: self.index_sets.clone(),
            const_scope: Arc::clone(&self.const_scope),
            namespace: self.namespace.clone(),
            precision: self.precision.clone(),
            declared_names: self.declared_names.clone(),
            #[cfg(feature = "solve")]
            field_ic_memo: std::cell::RefCell::new(None),
            inline_param_arrays: self.inline_param_arrays.clone(),
            forcing_decls: self.forcing_decls.clone(),
            forcing_defaults: self.forcing_defaults.clone(),
            unvalued_shaped_params: self.unvalued_shaped_params.clone(),
            held_at_ic: held,
            tape_cache: crate::simulate_array::tape::TapeCache::new(),
        }
    }

    /// The positional parameter vector for `overrides`, strictly: a key that
    /// names no parameter, or a parameter with neither an override nor a
    /// default, is an error naming it.
    pub(in crate::simulate_array) fn parameter_vector(
        &self,
        overrides: &HashMap<String, f64>,
    ) -> Result<Vec<f64>, crate::simulate::SimulateError> {
        let namespaces = crate::simulate::namespace_scope(
            self.param_names
                .iter()
                .chain(self.var_shapes.keys())
                .map(String::as_str),
            self.namespace.as_deref(),
        );
        let given = crate::simulate::canonicalize_override_keys(
            &self.param_index,
            &namespaces,
            overrides,
            &self.merged_renames,
        )
        .map_err(crate::simulate::param_key_error)?;
        self.param_names
            .iter()
            .zip(&self.param_defaults)
            .map(|(name, d)| {
                given.get(name).copied().or(*d).ok_or_else(|| {
                    crate::simulate::SimulateError::InvalidParameter { name: name.clone() }
                })
            })
            .collect()
    }
}
