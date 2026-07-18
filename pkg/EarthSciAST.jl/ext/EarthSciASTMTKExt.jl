"""
    EarthSciASTMTKExt

The ModelingToolkit binding, loaded automatically when `ModelingToolkit`,
`Symbolics`, and `DomainSets` are in the session. It supplies both
directions of the ESM ⇄ MTK bridge:

- **ESM → MTK**: `ModelingToolkit.System(::FlattenedSystem/::Model)` and
  `ModelingToolkit.PDESystem(...)` constructors that lower the flattened
  equations (including the `arrayop` stencil vocabulary and events) into
  real symbolic systems (`mtk_ext/lowering.jl`, `mtk_ext/arrayop.jl`,
  `mtk_ext/variables.jl`, `mtk_ext/systems.jl`).
- **MTK → ESM**: `EarthSciAST.Model(::AbstractSystem)` plus the `mtk2esm` /
  `mtk2esm_gaps` migration exporters with their `GapReport` machinery
  (`mtk_ext/export.jl`).

Kept a `weakdep` extension (mirroring `SimulateExt` / `DataRefreshExt`) so
the base package carries no MTK dependency; without it loaded, the core
stubs in src/mtk_export.jl throw an `ArgumentError` naming what to load,
and the MTK-free path (`flatten` → `FlattenedSystem`, `build_evaluator`,
`simulate`) remains fully available.
"""
module EarthSciASTMTKExt

using EarthSciAST
# We refer to the ESM abstract expression type via the `EsmExpr` alias (below)
# rather than importing it unqualified — a convenience shared with the Catalyst
# extension. Programmatic variable creation via `Symbolics.@variables` builds
# Julia `Core.Expr` AST, written explicitly throughout (there is no name clash
# now that the ESM type is `ASTExpr`, not `Expr`).
using EarthSciAST: FlattenedSystem, ModelVariable, StateVariable,
    ParameterVariable, ObservedVariable, BrownianVariable,
    NumExpr, IntExpr, VarExpr, OpExpr,
    Equation, AffectEquation, Model, ContinuousEvent, DiscreteEvent,
    ConditionTrigger, PeriodicTrigger, PresetTimesTrigger, FunctionalAffect,
    Domain, flatten, infer_array_shapes,
    GapReport,
    # MTK-independent helpers shared with the Catalyst extension
    # (src/mtk_export.jl) plus the ODE-vs-PDE split predicate and redirect
    # messages (src/flatten.jl).
    _strip_time, _resolve_sys_name,
    _reference_notes, _esm_file_metadata, _warn_gaps,
    _has_spatial_ivs, _use_pde_ctor_msg, _use_ode_ctor_msg
# Explicit import so we can add methods to these generics.
import EarthSciAST: mtk2esm, mtk2esm_gaps
const EsmExpr = EarthSciAST.ASTExpr
using ModelingToolkit
using ModelingToolkit: @variables, @parameters, Differential, System, PDESystem
using Symbolics
using Symbolics: Num
# SymbolicUtils ships inside Symbolics (via @reexport); access the module
# through Symbolics.SymbolicUtils so we don't need to declare a separate
# weak dep in Project.toml. Alias it locally for readability.
const SymUtils = Symbolics.SymbolicUtils
using DomainSets: Interval

# Files under ext/shared/ are included by BOTH this module and
# EarthSciASTCatalystExt (each gets its own copy); see their headers for the
# per-extension policy hooks that keep the two extensions' behavior distinct.
include("shared/esm_to_symbolic.jl")
include("shared/symbolic_to_esm.jl")
include("shared/eval_var_macro.jl")

include("mtk_ext/lowering.jl")
include("mtk_ext/arrayop.jl")
include("mtk_ext/variables.jl")
include("mtk_ext/systems.jl")
include("mtk_ext/export.jl")

end # module EarthSciASTMTKExt
