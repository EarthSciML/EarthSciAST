//! Standalone kernels (API_SPEC §5.8, "Strip and expose"; RFC U6).
//!
//! A kernel is an [`RhsProgram`] over the Problem's flattened system in which
//! every output is a synthetic held state whose `D` equation is the output's
//! expression. The program writes only those states; the Problem's `u`, its
//! `z` and the kernel's `dt` parameters are its read-only `aux` inputs. A
//! kernel is therefore lowered by the same compiler, to the same tape, with
//! the same strictness, as the right-hand side, and an evaluation is that
//! program's evaluation plus a copy of the inputs into place.

use super::*;
use crate::flatten::Contribution;
use crate::strip::{
    StrippedConstructs, bare_reads, declared_sets, expr_sets, set_sizes, strip_error, strip_pre,
};
use crate::types::{Expr, ModelVariable, VariableType};
use serde_json::Value as Json;
use std::collections::BTreeSet;

const UNRESOLVED: &str = crate::diagnostic::codes::KERNEL_OUTPUT_UNRESOLVED;

// ============================================================================
// Specs
// ============================================================================

/// One output of a kernel spec (API_SPEC §5.8, "Kernel specs").
#[derive(Debug, Clone)]
pub enum KernelOutput {
    /// An observed's (or any variable's) value.
    Observed { name: String, label: Option<String> },
    /// An expression over flattened names.
    Expr { expr: Expr, label: Option<String> },
    /// A stripped residual `g(u, z)`, by id.
    Residual { id: String, label: Option<String> },
    /// A continuous event's `conditions[index]`, or a discrete event's
    /// `condition` trigger as 1 / 0 (`index` 1-based).
    Condition {
        event: String,
        index: usize,
        label: Option<String>,
    },
    /// A stripped parameter's new value under its `index`-th rule (1-based).
    Update {
        parameter: String,
        index: Option<usize>,
        label: Option<String>,
    },
    /// The post-event state of an event (`negative`: a continuous event's
    /// `affect_neg`).
    Affect { event: String, negative: bool },
    /// A step map `target <- from`.
    Assign { target: String, from: Expr },
}

impl KernelOutput {
    fn is_map(&self) -> bool {
        matches!(
            self,
            KernelOutput::Affect { .. } | KernelOutput::Assign { .. }
        )
    }
}

/// A kernel spec: a name, the parameters that read `dt`, and the outputs.
#[derive(Debug, Clone)]
pub struct KernelSpec {
    pub name: String,
    pub dt_params: Vec<String>,
    pub outputs: Vec<KernelOutput>,
}

fn spec_error(message: String) -> SimulateError {
    strip_error(UNRESOLVED, message)
}

impl KernelSpec {
    /// A spec from its JSON form (API_SPEC §5.8).
    pub fn from_json(v: &Json) -> Result<KernelSpec, SimulateError> {
        let obj = v
            .as_object()
            .ok_or_else(|| spec_error("a kernel spec is a JSON object".into()))?;
        let name = obj
            .get("name")
            .and_then(|n| n.as_str())
            .ok_or_else(|| spec_error("a kernel spec needs a string `name`".into()))?
            .to_string();
        let dt_params = match obj.get("dt_params") {
            None => Vec::new(),
            Some(Json::Array(a)) => a
                .iter()
                .map(|x| {
                    x.as_str().map(str::to_string).ok_or_else(|| {
                        spec_error(format!("kernel '{name}': a `dt_params` entry is a string"))
                    })
                })
                .collect::<Result<_, _>>()?,
            Some(_) => {
                return Err(spec_error(format!(
                    "kernel '{name}': `dt_params` is a list of parameter names"
                )));
            }
        };
        let mut outputs = Vec::new();
        for (k, o) in obj
            .get("outputs")
            .and_then(|o| o.as_array())
            .into_iter()
            .flatten()
            .enumerate()
        {
            outputs.push(parse_output(&name, k + 1, o)?);
        }
        Ok(KernelSpec {
            name,
            dt_params,
            outputs,
        })
    }

    /// A list of specs from a JSON array.
    pub fn list_from_json(v: &Json) -> Result<Vec<KernelSpec>, SimulateError> {
        v.as_array()
            .ok_or_else(|| spec_error("kernel specs are a JSON array".into()))?
            .iter()
            .map(KernelSpec::from_json)
            .collect()
    }
}

fn parse_output(kernel: &str, k: usize, o: &Json) -> Result<KernelOutput, SimulateError> {
    let bad = |what: &str| spec_error(format!("kernel '{kernel}': output {k} {what}"));
    let obj = o.as_object().ok_or_else(|| bad("is not an object"))?;
    let label = obj
        .get("label")
        .and_then(|l| l.as_str())
        .map(str::to_string);
    let string = |key: &str| {
        obj.get(key)
            .and_then(|x| x.as_str())
            .map(str::to_string)
            .ok_or_else(|| bad(&format!("needs a string `{key}`")))
    };
    let expr = |v: &Json| -> Result<Expr, SimulateError> {
        serde_json::from_value::<Expr>(v.clone())
            .map_err(|e| bad(&format!("is not an expression: {e}")))
    };
    let index = |key: &str| -> Result<Option<usize>, SimulateError> {
        match obj.get(key) {
            None => Ok(None),
            Some(x) => x
                .as_u64()
                .filter(|&i| i >= 1)
                .map(|i| Some(i as usize))
                .ok_or_else(|| bad(&format!("`{key}` is a 1-based integer"))),
        }
    };
    if obj.contains_key("observed") {
        return Ok(KernelOutput::Observed {
            name: string("observed")?,
            label,
        });
    }
    if let Some(e) = obj.get("expr") {
        return Ok(KernelOutput::Expr {
            expr: expr(e)?,
            label,
        });
    }
    if obj.contains_key("residual") {
        return Ok(KernelOutput::Residual {
            id: string("residual")?,
            label,
        });
    }
    if obj.contains_key("condition") {
        return Ok(KernelOutput::Condition {
            event: string("condition")?,
            index: index("index")?.unwrap_or(1),
            label,
        });
    }
    if obj.contains_key("update") {
        return Ok(KernelOutput::Update {
            parameter: string("update")?,
            index: index("index")?,
            label,
        });
    }
    if obj.contains_key("affect") {
        return Ok(KernelOutput::Affect {
            event: string("affect")?,
            negative: obj
                .get("negative")
                .and_then(|n| n.as_bool())
                .unwrap_or(false),
        });
    }
    if obj.contains_key("assign") {
        let from = obj.get("from").ok_or_else(|| bad("needs `from`"))?.clone();
        return Ok(KernelOutput::Assign {
            target: string("assign")?,
            from: expr(&from)?,
        });
    }
    Err(bad(
        "names no output kind (observed, expr, residual, condition, update, affect, assign)",
    ))
}

// ============================================================================
// Kernels
// ============================================================================

/// One output's block of a kernel's `out` (0-based `offset`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KernelBlock {
    pub label: String,
    pub offset: usize,
    pub shape: Vec<usize>,
}

#[derive(Clone, Copy, Debug)]
enum Src {
    U,
    Z,
    Dt,
    Zero,
}

/// A compiled kernel (API_SPEC §5.8). `Send + Sync`; a clone shares it.
#[derive(Clone)]
pub struct Kernel {
    inner: Arc<KernelInner>,
}

struct KernelInner {
    name: String,
    prog: RhsProgram,
    /// `(source, source offset, destination offset, len)` into the program's
    /// `u` and `aux`.
    u_plan: Vec<(Src, usize, usize, usize)>,
    aux_plan: Vec<(Src, usize, usize, usize)>,
    /// Program parameter `i` reads set parameter `p_map[i]`.
    p_map: Vec<usize>,
    n_u: usize,
    n_z: usize,
    n_p: usize,
    /// Value kernels: `(du offset, out offset, len)`. Map kernels: the
    /// assigned blocks, `(du offset, u offset, len)`.
    out_plan: Vec<(usize, usize, usize)>,
    map: bool,
    /// The program writes `out` directly (the `rhs` kernel).
    direct: bool,
    layout: Vec<KernelBlock>,
    out_len: usize,
}

impl std::fmt::Debug for Kernel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Kernel")
            .field("name", &self.inner.name)
            .field("layout", &self.inner.layout)
            .finish()
    }
}

/// A kernel's buffers, one per concurrent caller. `Send`, not `Sync`.
pub struct KernelWorkspace {
    owner: usize,
    ws: RhsWorkspace,
    u: Vec<f64>,
    aux: Vec<f64>,
    p: Vec<f64>,
    du: Vec<f64>,
}

impl std::fmt::Debug for KernelWorkspace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KernelWorkspace").finish()
    }
}

impl Kernel {
    /// The kernel's name.
    pub fn name(&self) -> &str {
        &self.inner.name
    }

    /// One block per output, in spec order; a map kernel's is the `u` layout.
    pub fn layout(&self) -> &[KernelBlock] {
        &self.inner.layout
    }

    /// The length of `out`.
    pub fn len(&self) -> usize {
        self.inner.out_len
    }

    /// Whether `out` is empty.
    pub fn is_empty(&self) -> bool {
        self.inner.out_len == 0
    }

    /// Whether the kernel is a map (its `out` is a whole `u`).
    pub fn is_map(&self) -> bool {
        self.inner.map
    }

    /// Buffers for [`Self::eval_into`].
    pub fn new_workspace(&self) -> KernelWorkspace {
        let lay = self.inner.prog.layout();
        KernelWorkspace {
            owner: Arc::as_ptr(&self.inner) as usize,
            ws: self.inner.prog.new_workspace(),
            u: vec![0.0; lay.u_len],
            aux: vec![0.0; lay.aux_len],
            p: vec![0.0; self.inner.p_map.len()],
            du: vec![0.0; lay.u_len],
        }
    }

    /// Evaluate the kernel: `out = k(u, z, p, t, dt)` reading `forcing`
    /// (API_SPEC §5.8, "The kernel ABI").
    #[allow(clippy::too_many_arguments)]
    pub fn eval_into(
        &self,
        u: &[f64],
        z: &[f64],
        p: &[f64],
        t: f64,
        dt: f64,
        forcing: &ForcingSet,
        out: &mut [f64],
        ws: &mut KernelWorkspace,
    ) -> Result<(), RhsError> {
        let k = &*self.inner;
        if ws.owner != Arc::as_ptr(&self.inner) as usize {
            return Err(RhsError::ForeignProgram { what: "workspace" });
        }
        for (what, got, want) in [
            ("u", u.len(), k.n_u),
            ("z", z.len(), k.n_z),
            ("p", p.len(), k.n_p),
            ("out", out.len(), k.out_len),
        ] {
            if got != want {
                return Err(RhsError::Shape {
                    what,
                    expected: want,
                    got,
                });
            }
        }
        let fill = |plan: &[(Src, usize, usize, usize)], dst: &mut [f64]| {
            for &(src, s, d, n) in plan {
                match src {
                    Src::U => dst[d..d + n].copy_from_slice(&u[s..s + n]),
                    Src::Z => dst[d..d + n].copy_from_slice(&z[s..s + n]),
                    Src::Dt => dst[d..d + n].fill(dt),
                    Src::Zero => dst[d..d + n].fill(0.0),
                }
            }
        };
        fill(&k.aux_plan, &mut ws.aux);
        for (i, &j) in k.p_map.iter().enumerate() {
            ws.p[i] = p[j];
        }
        if k.direct {
            return k
                .prog
                .eval_into(u, &ws.aux, &ws.p, t, forcing, out, &mut ws.ws);
        }
        fill(&k.u_plan, &mut ws.u);
        k.prog
            .eval_into(&ws.u, &ws.aux, &ws.p, t, forcing, &mut ws.du, &mut ws.ws)?;
        if k.map {
            out.copy_from_slice(u);
        }
        for &(s, d, n) in &k.out_plan {
            out[d..d + n].copy_from_slice(&ws.du[s..s + n]);
        }
        Ok(())
    }
}

/// The kernels of one [`compile_kernels`] call, sharing one `u` / `z` layout,
/// one parameter vector and one forcing signature.
#[derive(Clone)]
pub struct KernelSet {
    kernels: Arc<Vec<Kernel>>,
    rhs: RhsProgram,
    u_layout: Arc<Vec<StateBlock>>,
    z_layout: Arc<Vec<StateBlock>>,
}

impl std::fmt::Debug for KernelSet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_list()
            .entries(self.kernels.iter().map(|k| k.name()))
            .finish()
    }
}

impl KernelSet {
    /// The kernel named `name`.
    pub fn get(&self, name: &str) -> Option<&Kernel> {
        self.kernels.iter().find(|k| k.name() == name)
    }

    /// The kernel names, in spec order.
    pub fn names(&self) -> Vec<&str> {
        self.kernels.iter().map(|k| k.name()).collect()
    }

    /// The `u` layout every kernel reads.
    pub fn state_layout(&self) -> &[StateBlock] {
        &self.u_layout
    }

    /// The `z` layout every kernel reads (empty when nothing algebraic was
    /// stripped).
    pub fn z_layout(&self) -> &[StateBlock] {
        &self.z_layout
    }

    /// The length of `u`.
    pub fn n_states(&self) -> usize {
        self.rhs.layout().u_len
    }

    /// The length of `z`.
    pub fn n_z(&self) -> usize {
        self.rhs.layout().aux_len
    }

    /// The parameter vector's slots.
    pub fn parameters(&self) -> &[ParamSlot] {
        self.rhs.parameters()
    }

    /// The parameter vector, strictly (as [`RhsProgram::parameter_vector`]).
    pub fn parameter_vector(
        &self,
        overrides: &HashMap<String, f64>,
    ) -> Result<Vec<f64>, SimulateError> {
        self.rhs.parameter_vector(overrides)
    }

    /// The forcing slots every kernel reads.
    pub fn forcing_slots(&self) -> &[ForcingSlot] {
        self.rhs.forcing_slots()
    }

    /// The Problem's forcing.
    pub fn default_forcing(&self) -> ForcingSet {
        self.rhs.default_forcing()
    }
}

// ============================================================================
// compile_kernels
// ============================================================================

/// Compile `specs` against `prob`'s (stripped) build (API_SPEC §5.8). The
/// reserved name `rhs`, with no outputs, is the stripped right-hand side.
pub fn compile_kernels(
    prob: &EsmProblem,
    specs: &[KernelSpec],
) -> Result<KernelSet, SimulateError> {
    let compiler = prob.compiler;
    if !matches!(compiler, Compiler::Native | Compiler::Interpreter) {
        return Err(SimulateError::CompilerUnavailable {
            compiler: compiler.as_str(),
            details: "`compile_kernels` serves the `native` and `interpreter` compilers".into(),
        });
    }
    let _precision = prob.precision.enter();
    let flat = match (prob.program_source.as_deref(), prob.strip_source.as_deref()) {
        (Some(ProgramSource::Flattened(f)), _) => (**f).clone(),
        (Some(ProgramSource::File(file)), _) => {
            let annotated =
                crate::precision_infer::annotated(file).map_err(SimulateError::Compile)?;
            crate::flatten::flatten(annotated.as_ref().unwrap_or(file))
                .map_err(|e| SimulateError::Compile(e.into()))?
        }
        (None, Some(file)) => {
            crate::flatten::flatten(file).map_err(|e| SimulateError::Compile(e.into()))?
        }
        (None, None) => {
            return Err(build_error(
                "`compile_kernels`: this Problem has no right-hand side to compile against".into(),
            ));
        }
    };
    let forcing = match &*prob.backend {
        crate::problem::Backend::Array(c) => problem_forcing(c, &flat),
        crate::problem::Backend::Static(_) => HashMap::new(),
    };
    let stripped: &StrippedConstructs = &prob.stripped;
    let z_names: Vec<String> = stripped.z_layout().iter().map(|b| b.name.clone()).collect();
    let u_names: Vec<String> = flat
        .state_variables
        .keys()
        .filter(|n| !z_names.contains(n))
        .cloned()
        .collect();
    let rhs = RhsProgram::compile(
        Arc::new(flat.clone()),
        compiler,
        Some(&u_names),
        ForcingSource::Problem(&forcing),
        prob.runtime_array_parameters,
    )?;
    let u_layout = layout_of(&rhs.layout().u);
    let z_layout = layout_of(&rhs.layout().aux);
    let mut seen = HashSet::new();
    let mut kernels = Vec::new();
    for spec in specs {
        if !seen.insert(spec.name.clone()) {
            return Err(spec_error(format!(
                "two kernel specs are named '{}'",
                spec.name
            )));
        }
        let k = if spec.name == "rhs" {
            if !spec.outputs.is_empty() || !spec.dt_params.is_empty() {
                return Err(spec_error(
                    "kernel 'rhs' is the reserved stripped right-hand side and takes no \
                     outputs or dt_params"
                        .into(),
                ));
            }
            rhs_kernel(&rhs, &u_layout, &z_layout)
        } else {
            value_or_map_kernel(spec, &flat, &rhs, stripped, &u_layout, &z_layout)?
        };
        kernels.push(k);
    }
    Ok(KernelSet {
        kernels: Arc::new(kernels),
        rhs,
        u_layout: Arc::new(u_layout),
        z_layout: Arc::new(z_layout),
    })
}

fn layout_of(blocks: &[TileBlock]) -> Vec<StateBlock> {
    blocks
        .iter()
        .map(|b| StateBlock {
            name: b.name.clone(),
            flat_offset: b.base,
            shape: b
                .storage
                .iter()
                .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
                .collect(),
        })
        .collect()
}

fn block_len(b: &StateBlock) -> usize {
    b.shape.iter().product::<usize>().max(1)
}

fn rhs_kernel(rhs: &RhsProgram, u: &[StateBlock], z: &[StateBlock]) -> Kernel {
    let n_u = rhs.layout().u_len;
    let n_z = rhs.layout().aux_len;
    let aux_plan = z
        .iter()
        .map(|b| (Src::Z, b.flat_offset, b.flat_offset, block_len(b)))
        .collect();
    let layout = u
        .iter()
        .map(|b| KernelBlock {
            label: b.name.clone(),
            offset: b.flat_offset,
            shape: b.shape.clone(),
        })
        .collect();
    let n_p = rhs.parameters().len();
    Kernel {
        inner: Arc::new(KernelInner {
            name: "rhs".into(),
            prog: rhs.clone(),
            u_plan: Vec::new(),
            aux_plan,
            p_map: (0..n_p).collect(),
            n_u,
            n_z,
            n_p,
            out_plan: Vec::new(),
            map: false,
            direct: true,
            layout,
            out_len: n_u,
        }),
    }
}

/// One output lowered to a synthetic state: its name, declared index sets,
/// and value expression.
struct Synth {
    name: String,
    sets: Vec<String>,
    expr: Expr,
    label: String,
    /// For a map output, the `u` block it assigns.
    target: Option<String>,
}

fn value_or_map_kernel(
    spec: &KernelSpec,
    flat: &FlattenedSystem,
    rhs: &RhsProgram,
    stripped: &StrippedConstructs,
    u_layout: &[StateBlock],
    z_layout: &[StateBlock],
) -> Result<Kernel, SimulateError> {
    let kname = &spec.name;
    let unresolved =
        |what: String| spec_error(format!("kernel '{kname}': {what} does not resolve"));
    let n_map = spec.outputs.iter().filter(|o| o.is_map()).count();
    if n_map > 0 && n_map != spec.outputs.len() {
        return Err(spec_error(format!(
            "kernel '{kname}' mixes map outputs (assign, affect) with value outputs; a map \
             kernel's output is a whole state"
        )));
    }
    let map = n_map > 0;
    // The parameters that read `dt`.
    let mut dt_states: Vec<String> = Vec::new();
    for p in &spec.dt_params {
        let scalar = flat
            .parameters
            .get(p)
            .is_some_and(|v| v.shape.as_ref().is_none_or(|s| s.is_empty()));
        if !scalar {
            return Err(spec_error(format!(
                "kernel '{kname}': dt_params entry '{p}' is not a scalar parameter"
            )));
        }
        dt_states.push(p.clone());
    }
    let u_names: HashSet<&str> = u_layout.iter().map(|b| b.name.as_str()).collect();
    let resolve_names = |e: &Expr, what: &str| -> Result<(), SimulateError> {
        for n in crate::simulate_array::free_variable_names(e) {
            if n == "t" || declared_sets(&n, flat).is_some() || flat.index_sets.contains_key(&n) {
                continue;
            }
            return Err(unresolved(format!("{what} reads '{n}', which")));
        }
        Ok(())
    };
    let sets_of = |e: &Expr, what: &str| -> Result<Vec<String>, SimulateError> {
        expr_sets(e, flat).map_err(|why| {
            spec_error(format!(
                "kernel '{kname}': the shape of {what} cannot be decided: {why}"
            ))
        })
    };
    let mut synth: Vec<Synth> = Vec::new();
    let mut add = |sets: Vec<String>, expr: Expr, label: String, target: Option<String>| {
        let j = synth.len() + 1;
        synth.push(Synth {
            name: format!("__kernel_out_{j}"),
            sets,
            expr,
            label,
            target,
        });
    };
    let event = |id: &str| {
        stripped
            .events()
            .iter()
            .find(|e| e.id == id)
            .ok_or_else(|| unresolved(format!("event '{id}'")))
    };
    for (k, out) in spec.outputs.iter().enumerate() {
        match out {
            KernelOutput::Observed { name, label } => {
                let sets = declared_sets(name, flat)
                    .ok_or_else(|| unresolved(format!("observed '{name}'")))?;
                add(
                    sets,
                    Expr::Variable(name.clone()),
                    label.clone().unwrap_or_else(|| name.clone()),
                    None,
                );
            }
            KernelOutput::Expr { expr, label } => {
                let e = strip_pre(expr);
                resolve_names(&e, &format!("output {}", k + 1))?;
                let sets = sets_of(&e, &format!("output {}", k + 1))?;
                add(
                    sets,
                    e,
                    label.clone().unwrap_or_else(|| format!("out[{}]", k + 1)),
                    None,
                );
            }
            KernelOutput::Residual { id, label } => {
                let r = stripped
                    .residuals()
                    .iter()
                    .find(|r| &r.id == id)
                    .ok_or_else(|| unresolved(format!("residual '{id}'")))?;
                add(
                    r.sets.clone(),
                    r.expr.clone(),
                    label.clone().unwrap_or_else(|| id.clone()),
                    None,
                );
            }
            KernelOutput::Condition {
                event: id,
                index,
                label,
            } => {
                let ev = event(id)?;
                let e = match ev.kind {
                    crate::strip::EventKind::Continuous => {
                        ev.conditions.get(index - 1).cloned().ok_or_else(|| {
                            unresolved(format!("condition {index} of event '{id}'"))
                        })?
                    }
                    crate::strip::EventKind::Discrete => {
                        let c = ev.trigger.clone().ok_or_else(|| {
                            unresolved(format!(
                                "the condition of event '{id}' (its trigger is not a \
                                 `condition`), which"
                            ))
                        })?;
                        if *index != 1 {
                            return Err(unresolved(format!("condition {index} of event '{id}'")));
                        }
                        crate::strip::op_expr(
                            "ifelse",
                            vec![c, Expr::Number(1.0), Expr::Number(0.0)],
                        )
                    }
                };
                let e = strip_pre(&e);
                let sets = sets_of(&e, &format!("the condition of '{id}'"))?;
                add(
                    sets,
                    e,
                    label
                        .clone()
                        .unwrap_or_else(|| format!("{id}.condition[{index}]")),
                    None,
                );
            }
            KernelOutput::Update {
                parameter,
                index,
                label,
            } => {
                let u = stripped
                    .parameter_updates()
                    .iter()
                    .find(|u| &u.parameter == parameter)
                    .ok_or_else(|| unresolved(format!("parameter update '{parameter}'")))?;
                let i = match (index, u.values.len()) {
                    (Some(i), _) => *i,
                    (None, 1) => 1,
                    (None, n) => {
                        return Err(spec_error(format!(
                            "kernel '{kname}': parameter '{parameter}' has {n} update rules; \
                             name one with `index`"
                        )));
                    }
                };
                let e = u.values.get(i - 1).ok_or_else(|| {
                    unresolved(format!("update rule {i} of parameter '{parameter}'"))
                })?;
                let e = strip_pre(e);
                let sets = declared_sets(parameter, flat).unwrap_or_default();
                add(
                    sets,
                    e,
                    label.clone().unwrap_or_else(|| parameter.clone()),
                    None,
                );
            }
            KernelOutput::Affect {
                event: id,
                negative,
            } => {
                let ev = event(id)?;
                let affects = if *negative {
                    ev.affect_neg.clone().ok_or_else(|| {
                        unresolved(format!("the negative affects of event '{id}'"))
                    })?
                } else {
                    ev.affects.clone()
                };
                let assigned: HashSet<&str> = affects.iter().map(|(l, _)| l.as_str()).collect();
                for (lhs, rhs_e) in &affects {
                    let mut reads = BTreeSet::new();
                    bare_reads(rhs_e, &mut reads);
                    if let Some(v) = reads.iter().find(|r| assigned.contains(r.as_str())) {
                        return Err(strip_error(
                            crate::diagnostic::codes::AFFECT_READS_POST_VALUE,
                            format!(
                                "kernel '{kname}': event '{id}' assigns '{v}' and its affect on \
                                 '{lhs}' reads '{v}' bare, which is its post-event value; read \
                                 the pre-event value as Pre({v})"
                            ),
                        ));
                    }
                    if !u_names.contains(lhs.as_str()) {
                        return Err(unresolved(format!(
                            "the affect target '{lhs}' of event '{id}' (not an unknown of `u`)"
                        )));
                    }
                    let e = strip_pre(rhs_e);
                    resolve_names(&e, &format!("the affect on '{lhs}'"))?;
                    let sets = declared_sets(lhs, flat).unwrap_or_default();
                    add(sets, e, lhs.clone(), Some(lhs.clone()));
                }
            }
            KernelOutput::Assign { target, from } => {
                if !u_names.contains(target.as_str()) {
                    return Err(unresolved(format!(
                        "the assign target '{target}' (not an unknown of `u`)"
                    )));
                }
                let e = strip_pre(from);
                resolve_names(&e, &format!("the source of '{target}'"))?;
                let sets = declared_sets(target, flat).unwrap_or_default();
                let src_sets = sets_of(&e, &format!("the source of '{target}'"))?;
                if !src_sets.is_empty() && src_sets != sets {
                    return Err(spec_error(format!(
                        "kernel '{kname}': the source of '{target}' ranges over [{}], the target \
                         over [{}]",
                        src_sets.join(", "),
                        sets.join(", ")
                    )));
                }
                add(sets, e, target.clone(), Some(target.clone()));
            }
        }
    }

    // ---- the kernel's flattened system ----------------------------------
    let mut kflat = flat.clone();
    drop_derivative_equations(&mut kflat);
    for p in &dt_states {
        if let Some(mut v) = kflat.parameters.shift_remove(p) {
            kflat.discrete_parameters.shift_remove(p);
            kflat.brownian_parameters.shift_remove(p);
            v.var_type = VariableType::Unknown;
            v.update = None;
            v.default = Some(crate::types::InlineValue::Scalar(0.0));
            kflat.state_variables.insert(p.clone(), v);
        }
    }
    for s in &synth {
        let var = ModelVariable {
            var_type: VariableType::Unknown,
            units: None,
            default: Some(crate::types::InlineValue::Scalar(0.0)),
            shape: if s.sets.is_empty() {
                None
            } else {
                Some(s.sets.clone())
            },
            ..Default::default()
        };
        kflat.state_variables.insert(s.name.clone(), var);
        let lhs: Expr = serde_json::from_value(serde_json::json!({
            "op": "D", "args": [s.name], "wrt": "t"
        }))
        .expect("a derivative node deserializes");
        push_equation(&mut kflat, lhs, s.expr.clone());
    }
    let writes: Vec<String> = synth.iter().map(|s| s.name.clone()).collect();
    let prog = RhsProgram::compile(
        Arc::new(kflat),
        rhs.inner.compiler,
        Some(&writes),
        ForcingSource::Parent(&rhs.inner),
        rhs.inner.runtime_array_parameters,
    )?;

    // ---- the copy plans ---------------------------------------------------
    let lay = prog.layout();
    let mut aux_plan = Vec::new();
    for b in &lay.aux {
        let len = tile_len(b);
        let src = if let Some(s) = u_layout.iter().find(|s| s.name == b.name) {
            (Src::U, s.flat_offset)
        } else if let Some(s) = z_layout.iter().find(|s| s.name == b.name) {
            (Src::Z, s.flat_offset)
        } else if dt_states.contains(&b.name) {
            (Src::Dt, 0)
        } else {
            (Src::Zero, 0)
        };
        aux_plan.push((src.0, src.1, b.base, len));
    }
    let u_plan = lay
        .u
        .iter()
        .map(|b| (Src::Zero, 0, b.base, tile_len(b)))
        .collect();
    let set_params: Vec<&str> = rhs.parameters().iter().map(|p| p.name.as_str()).collect();
    let p_map = prog
        .parameters()
        .iter()
        .map(|p| {
            set_params.iter().position(|n| *n == p.name).ok_or_else(|| {
                build_error(format!(
                    "kernel '{kname}' reads parameter '{}', which the right-hand side does not",
                    p.name
                ))
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    let mut out_plan = Vec::new();
    let mut layout = Vec::new();
    let mut offset = 0usize;
    for s in &synth {
        let b = lay
            .u
            .iter()
            .find(|b| b.name == s.name)
            .expect("every output is written");
        let len = tile_len(b);
        let shape = set_sizes(&s.sets, flat);
        match &s.target {
            Some(t) => {
                let ub = u_layout
                    .iter()
                    .find(|x| &x.name == t)
                    .expect("checked above");
                out_plan.push((b.base, ub.flat_offset, len));
            }
            None => {
                out_plan.push((b.base, offset, len));
                layout.push(KernelBlock {
                    label: s.label.clone(),
                    offset,
                    shape,
                });
                offset += len;
            }
        }
    }
    let n_u: usize = u_layout.iter().map(block_len).sum();
    let (layout, out_len) = if map {
        (
            u_layout
                .iter()
                .map(|b| KernelBlock {
                    label: b.name.clone(),
                    offset: b.flat_offset,
                    shape: b.shape.clone(),
                })
                .collect(),
            n_u,
        )
    } else {
        (layout, offset)
    };
    Ok(Kernel {
        inner: Arc::new(KernelInner {
            name: kname.clone(),
            prog,
            u_plan,
            aux_plan,
            p_map,
            n_u,
            n_z: z_layout.iter().map(block_len).sum(),
            n_p: set_params.len(),
            out_plan,
            map,
            direct: false,
            layout,
            out_len,
        }),
    })
}

fn tile_len(b: &TileBlock) -> usize {
    b.storage
        .iter()
        .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
        .product::<usize>()
        .max(1)
}

/// Remove every time-derivative equation: a kernel evaluates outputs, and the
/// states it reads are inputs.
fn drop_derivative_equations(flat: &mut FlattenedSystem) {
    use crate::classification::{LhsFormRef, lhs_form_ref};
    let keep: Vec<bool> = flat
        .equations
        .iter()
        .map(|eq| !matches!(lhs_form_ref(&eq.lhs), LhsFormRef::Derivative(_)))
        .collect();
    let mut it = keep.iter();
    flat.equations.retain(|_| *it.next().unwrap());
    if flat.equation_contributions.len() == keep.len() {
        let mut it = keep.iter();
        flat.equation_contributions.retain(|_| *it.next().unwrap());
    }
    if flat.equation_lifted.len() == keep.len() {
        let mut it = keep.iter();
        flat.equation_lifted.retain(|_| *it.next().unwrap());
    }
}

fn push_equation(flat: &mut FlattenedSystem, lhs: Expr, rhs: Expr) {
    let n = flat.equations.len();
    if flat.equation_contributions.len() == n {
        flat.equation_contributions.push(vec![Contribution {
            expr: rhs.clone(),
            origins: Vec::new(),
        }]);
    }
    if !flat.equation_lifted.is_empty() && flat.equation_lifted.len() == n {
        flat.equation_lifted.push(false);
    }
    flat.equations.push(crate::types::Equation {
        lhs,
        rhs,
        comment: None,
    });
}
