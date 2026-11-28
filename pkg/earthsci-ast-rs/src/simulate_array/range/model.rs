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
    pub(in crate::simulate_array) rewrites: crate::problem::CompilerRewrites,
    pub(in crate::simulate_array) merged_renames: HashMap<String, String>,
    pub(in crate::simulate_array) var_shapes: IndexMap<String, VarShape>,
    pub(in crate::simulate_array) state_defaults: Vec<StateDefault>,
    pub(in crate::simulate_array) param_names: Vec<String>,
    pub(in crate::simulate_array) param_index: HashMap<String, usize>,
    pub(in crate::simulate_array) param_defaults: Vec<Option<f64>>,
    pub(in crate::simulate_array) observed_rules: Vec<AlgebraicRule>,
    pub(in crate::simulate_array) rhs_rules: Vec<RhsRule>,
    pub(in crate::simulate_array) n_states: usize,
    pub(in crate::simulate_array) data_fed: Vec<(String, String)>,
    pub(in crate::simulate_array) index_sets: HashMap<String, IndexSet>,
    pub(in crate::simulate_array) const_scope: Arc<ConstArrayScope>,
    /// The operator instances the rules' references name.
    pub(in crate::simulate_array) operators: Arc<crate::operator_refs::Instances>,
    pub(in crate::simulate_array) precision: crate::precision::Env,
    pub(in crate::simulate_array) declared_names: HashSet<String>,
    pub(in crate::simulate_array) forcing_decls: IndexMap<String, Option<Vec<usize>>>,
    pub(in crate::simulate_array) declared_forcing_shapes: IndexMap<String, Option<Vec<usize>>>,
    pub(in crate::simulate_array) forcing_defaults: HashMap<String, Option<(Vec<usize>, Vec<f64>)>>,
    pub(in crate::simulate_array) unvalued_shaped_params: Vec<String>,
}

impl ArrayCompiled {
    /// A copy of this model's rules and tables with empty caches and its own
    /// forcing buffer: what [`crate::rhs_program`] builds a Problem's program
    /// from instead of compiling the document a second time. The names are the
    /// build's own, qualified ones.
    pub(in crate::simulate_array) fn program_copy(&self) -> ArrayCompiled {
        ArrayCompiled {
            runtime_mode: self.runtime_mode,
            rewrites: self.rewrites,
            #[cfg(feature = "xla")]
            xla_rhs: std::cell::OnceCell::new(),
            var_shapes: self.var_shapes.clone(),
            state_names: std::cell::OnceCell::new(),
            qualified_state_names: std::cell::OnceCell::new(),
            shown_param_names: std::cell::OnceCell::new(),
            state_defaults: self.state_defaults.clone(),
            param_names: self.param_names.clone(),
            param_index: self.param_index.clone(),
            param_defaults: self.param_defaults.clone(),
            observed_rules: self.observed_rules.clone(),
            rhs_rules: self.rhs_rules.clone(),
            n_states: self.n_states,
            declared_names: self.declared_names.clone(),
            built_variables: self.built_variables.clone(),
            forcing: Default::default(),
            data_fed: self.data_fed.clone(),
            field_ics: self.field_ics.clone(),
            init_faqs: self.init_faqs.clone(),
            n_explicit_faqs: self.n_explicit_faqs,
            init_system: self.init_system.clone(),
            init_guesses: self.init_guesses.clone(),
            init_stripped: self.init_stripped,
            alg_stripped: self.alg_stripped,
            ic_scope: self.ic_scope.clone(),
            index_sets: self.index_sets.clone(),
            namespace: None,
            const_scope: Arc::clone(&self.const_scope),
            operators: Arc::clone(&self.operators),
            precision: self.precision.clone(),
            merged_renames: self.merged_renames.clone(),
            #[cfg(feature = "solve")]
            field_ic_memo: std::cell::RefCell::new(None),
            forcing_decls: self.forcing_decls.clone(),
            declared_forcing_shapes: self.declared_forcing_shapes.clone(),
            forcing_defaults: self.forcing_defaults.clone(),
            unvalued_shaped_params: self.unvalued_shaped_params.clone(),
            held_at_ic: self.held_at_ic.clone(),
            tape_cache: crate::simulate_array::tape::TapeCache::new(),
        }
    }
}

impl ProgramModel {
    /// The model of `c`, taking its rules and tables.
    pub(in crate::simulate_array) fn from_compiled(c: ArrayCompiled) -> ProgramModel {
        ProgramModel {
            runtime_mode: c.runtime_mode,
            rewrites: c.rewrites,
            merged_renames: c.merged_renames,
            var_shapes: c.var_shapes,
            state_defaults: c.state_defaults,
            param_names: c.param_names,
            param_index: c.param_index,
            param_defaults: c.param_defaults,
            observed_rules: c.observed_rules,
            rhs_rules: c.rhs_rules,
            n_states: c.n_states,
            data_fed: c.data_fed,
            index_sets: c.index_sets,
            const_scope: c.const_scope,
            operators: c.operators,
            precision: c.precision,
            declared_names: c.declared_names,
            forcing_decls: c.forcing_decls,
            declared_forcing_shapes: c.declared_forcing_shapes,
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
            rewrites: self.rewrites,
            #[cfg(feature = "xla")]
            xla_rhs: std::cell::OnceCell::new(),
            merged_renames: self.merged_renames.clone(),
            var_shapes,
            state_names: std::cell::OnceCell::new(),
            qualified_state_names: std::cell::OnceCell::new(),
            shown_param_names: std::cell::OnceCell::new(),
            state_defaults,
            param_names: self.param_names.clone(),
            param_index: self.param_index.clone(),
            param_defaults: self.param_defaults.clone(),
            observed_rules,
            rhs_rules,
            n_states,
            forcing: Default::default(),
            data_fed: self.data_fed.clone(),
            field_ics: Vec::new(),
            init_faqs: Vec::new(),
            n_explicit_faqs: 0,
            init_system: Default::default(),
            init_guesses: Default::default(),
            init_stripped: false,
            alg_stripped: false,
            ic_scope: Default::default(),
            index_sets: self.index_sets.clone(),
            const_scope: Arc::clone(&self.const_scope),
            operators: Arc::clone(&self.operators),
            namespace: None,
            precision: self.precision.clone(),
            declared_names: self.declared_names.clone(),
            // A tape-build shell is never asked for its variables by name;
            // the build's downstream readers take its shapes from the
            // program (`ProgramInner::shapes`).
            built_variables: Default::default(),
            #[cfg(feature = "solve")]
            field_ic_memo: std::cell::RefCell::new(None),
            forcing_decls: self.forcing_decls.clone(),
            declared_forcing_shapes: self.declared_forcing_shapes.clone(),
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
            [],
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
