#!/usr/bin/env python3
"""Generate `tests/conformance/compiled_rhs/manifest.json`.

The tier's fixtures are NOT authored here — every one of them already lives in
the corpus and is referenced by its path relative to `tests/`. What this script
produces is the part that has to be reproducible: the flat `state_order`, the
probe states, and the independent `analytic_rhs` anchors.

Three rules the tier depends on, and how they are kept:

1. **`state_order` is the reference evaluator's own layout, never hand-written.**
   The script shells out to Julia ONCE, builds each fixture through
   `build_evaluator`, and reads the variable map back. A hand-kept order would
   drift silently and every binding would then be probing the wrong slots.

2. **Probe states are literal and deterministic.** The first probe of every
   fixture (`default`) is the fixture's own initial state at `t = 0`. The rest
   are seeded perturbations of it: one `random.Random(20260913)` stream, drawn in
   manifest order, fixture order, probe order, element order (the evaluator's
   order), so the whole table regenerates byte-for-byte.

     * `t` values: 0.37, 1.0, 2.5 — the first two off any solver's grid, the
       third far enough out that a fixture whose RHS is genuinely time-dependent
       (the diurnal forcing in `events_cross_system`) moves a long way.
     * additive rule (the default): `v = base + max(1, |base|) * r`, `r` uniform
       on [-1, 1]. Scale-aware, so a 273 K column layer and a 0.5 mixing ratio
       are both perturbed meaningfully.
     * multiplicative rule (`domain="positive"`): `v = (base or 1) * exp(r/2)`,
       which is strictly positive. Used for the one fixture whose RHS leaves the
       reals on a non-positive state — `expr_graphs_variable_deps` takes
       `x^0.5` and `sqrt(x*y + (kappa*T)^2)`.
     * every value is rounded to 12 decimals so the manifest literal is short
       and parses back to exactly the float that was generated.

3. **`analytic_rhs` is computed here, from the fixture's mathematics, and never
   from a binding's output.** Each entry below carries a closure that recomputes
   `f(u, p, t)` in NumPy/`math` from the equations as authored. For the eight
   pre-discretized PDE fixtures that closure is the operator matrix `L u + b`
   assembled by `gen_pde_sim_fixtures`, the same independent anchor the
   PDE-simulation tier uses; their three original probes are copied over
   verbatim, anchors included.

Run:  python3 scripts/gen_compiled_rhs_manifest.py
"""

from __future__ import annotations

import argparse
import json
import math
import random
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_pde_sim_fixtures as pde  # noqa: E402 — needs the sys.path bootstrap above

REPO = Path(__file__).resolve().parent.parent
TESTS = REPO / "tests"
TIER = TESTS / "conformance" / "compiled_rhs"
JULIA_ENV = REPO / "pkg" / "EarthSciAST.jl" / "scripts" / "pde_sim_adapter"
JULIA_PKG = REPO / "pkg" / "EarthSciAST.jl"

SEED = 20260913
PERTURB_TIMES = (0.37, 1.0, 2.5)


# === Independent analytic anchors =========================================
#
# Every closure takes (state: {element -> value}, t) and returns the full
# {element -> du} map, recomputed from the fixture's equations. Nothing here
# loads an .esm or calls a binding.


def _linear_operator(L, b, order):
    """`du = L u + b` for a pre-discretized fixture, keyed by element name."""

    def anchor(state, t):
        return pde.analytic_rhs(L, b, order, state)

    return anchor


def _gather_column(state, t):
    """`elementwise_gather` / `explicit_gather` (model `Column`).

    `zc = [0,1,2,3]`; `f = 1 + cos(pi*zc)`; `colsum[i] = sum_{j<=i} f[j]`;
    `total = sum_j f[j]`; `D(u) = colsum`, `D(s) = total`. State-FREE, so the
    same vector answers every probe — which is itself the property worth pinning:
    a compiled emitter that let a probe state leak into a const-folded field
    would show up here immediately."""
    zc = [0.0, 1.0, 2.0, 3.0]
    f = [1.0 + math.cos(3.141592653589793 * z) for z in zc]
    colsum = [sum(f[: i + 1]) for i in range(len(f))]
    total = sum(f)
    du = {f"u[{i + 1}]": colsum[i] for i in range(len(f))}
    du["s"] = total
    return du


def _events_meteorology(state, t):
    """`events_cross_system`, model `MeteorologicalSystem`. Diurnal relaxation,
    the one fixture in the tier whose RHS genuinely depends on `t`:

        D(solar) = 0.1 * (base_solar + diurnal_amplitude*cos(0.26 t) - solar)
        D(temp)  = 0.2 * (base_temp + temp_amplitude*cos(0.26 (t+6)) - temp)
        D(wind)  = 0.05 * wind_variability * sin(0.1 t)
    """
    base_solar, diurnal_amplitude = 200.0, 600.0
    base_temp, temp_amplitude = 20.0, 10.0
    wind_variability = 1.0
    return {
        "solar_intensity": 0.1
        * (base_solar + diurnal_amplitude * math.cos(0.26 * t) - state["solar_intensity"]),
        "temperature": 0.2
        * (base_temp + temp_amplitude * math.cos(0.26 * (t + 6.0)) - state["temperature"]),
        "wind_speed": 0.05 * wind_variability * math.sin(0.1 * t),
    }


def _variable_deps(state, t):
    """`expr_graphs_variable_deps`, model `VariableDependencyModel`. An Arrhenius
    / power-law / log-and-sqrt kinetics triple — the tier's densest transcendental
    fixture:

        D(x) = k1 x y + exp(-T_act/T) P z k_p
        D(y) = k2 x^alpha z^beta - (T_ref/T) y k_y
        D(z) = sqrt(x y + (kappa T)^2) * log(1 + (P/P_ref) alpha beta) * k_z
    """
    T, P = 298.15, 1.0
    k1, k2 = 0.1, 0.01
    alpha, beta = 0.5, 2.0
    T_act, k_p, T_ref, k_y = 1000.0, 0.05, 298.15, 0.02
    kappa, P_ref, k_z = 0.001, 1.0, 0.05
    x, y, z = state["x"], state["y"], state["z"]
    return {
        "x": k1 * x * y + math.exp(-T_act / T) * P * z * k_p,
        "y": k2 * (x**alpha) * (z**beta) - (T_ref / T) * y * k_y,
        "z": math.sqrt(x * y + (kappa * T) ** 2) * math.log(1.0 + (P / P_ref) * alpha * beta) * k_z,
    }


def _indexed_lhs(state, t):
    """`pde_inline_observed_indexed_lhs`, model `M`. `wf[k] = 2k` (state-free) and
    `ws[k] = 3 u[k]` (state-dependent), both written through an indexed LHS;
    `D(u[k]) = wf[k]`, `D(v[k]) = ws[k]`."""
    du = {}
    for k in range(1, 5):
        du[f"u[{k}]"] = 2.0 * k
        du[f"v[{k}]"] = 3.0 * state[f"u[{k}]"]
    return du


def _rank2_scaled(k_scale):
    """`pde_inline_observed_rank2` (literal 1.5) and `..._param_rank2` (the
    parameter `k`, default 1.5). `base` is a 2x3 const field and
    `D(u[i,j]) = k * base[i,j]` — state-free."""
    base = {(1, 1): 0.5, (1, 2): 1.5, (1, 3): 2.5, (2, 1): 3.5, (2, 2): 4.5, (2, 3): 5.5}

    def anchor(state, t):
        return {f"u[{i},{j}]": k_scale * v for (i, j), v in base.items()}

    return anchor


def _state_dependent(state, t):
    """`pde_inline_observed_state_dependent`, model `M`. `rate[i] = i` (state-free)
    and `g[i] = 2 u[i] + rate[i]` (state-dependent); `D(u) = rate`, `D(v) = g`."""
    du = {}
    for i in range(1, 5):
        du[f"u[{i}]"] = float(i)
        du[f"v[{i}]"] = 2.0 * state[f"u[{i}]"] + float(i)
    return du


def _relaxation(var, n, rate):
    """A per-layer Newtonian relaxation column, `D(X[k]) = rate * X[k]`."""

    def anchor(state, t):
        return {f"{var}[{k}]": rate * state[f"{var}[{k}]"] for k in range(1, n + 1)}

    return anchor


def _first_order_decay(state, t):
    """`units_registry_grammar`, model `UnitsRegistryGrammar`. The document is a
    units-parsing discriminator with exactly one dynamical equation,
    `D(u) = -k_decay * u`, `k_decay = 0.01`. Its value here is that the RHS sits
    under a model whose observed set is full of units the emitters must carry
    through without touching the arithmetic."""
    return {"u": -0.01 * state["u"]}


# === The fixture table ====================================================
#
# `pde_spec` marks the eight pre-discretized fixtures whose three original probes
# (const1 / ramp / ic) and anchors are copied verbatim from the PDE-simulation
# manifest.

_DX_1D, _DX_2D, _DX_ADV = 0.2, 0.25, 0.25
_KAPPA_1D = 1.0 / (_DX_1D * _DX_1D)
_KAPPA_2D = 1.0 / (_DX_2D * _DX_2D)
_NU_ADV = 1.0 / _DX_ADV


def _pde_entry(fid, bc, n, kind, model):
    if kind == "diffusion":
        L, b = pde.diffusion_matrix(n, _KAPPA_1D, bc)
        order = pde.names_1d(n)
    elif kind == "diffusion2d":
        L, b = pde.diffusion_2d_matrix(n, _KAPPA_2D)
        order = pde.names_2d(n)
    elif kind == "advection":
        L, b = pde.advection_matrix(n, _NU_ADV)
        order = pde.names_1d(n)
    else:
        raise ValueError(kind)
    return {
        "id": fid,
        "path": f"conformance/pde_simulation/fixtures/{fid}.esm",
        "model": model,
        # `reduction`, not `algebraic`. A method-of-lines stencil IS a fold, and
        # these eight are the tier's only fixtures with EXACT CANCELLATION rows:
        # the `ramp` probe on `diffusion_1d_periodic_n8` has an interior row whose
        # exact value is 0, which the AST stencil reaches as exactly 0.0 and the
        # anchor's matrix-vector product reaches as -2.8e-14 — a summation-order
        # difference of 1 ulp of the row's operands, nothing more. A relative
        # bound on an exact zero is an impossible bound, which is what the
        # `reduction` class's SCALED absolute floor exists to fix (here 1e-14 *
        # 200 = 2e-12). Classing these `algebraic` would fail that one cell for
        # every binding forever, for a defect none of them has.
        "tolerance_class": "reduction",
        "anchor": _linear_operator(L, b, order),
        "domain": "any",
        "pde_spec": fid,
    }


FIXTURE_TABLE = [
    {
        "id": "elementwise_gather",
        "path": "conformance/elementwise_observed_gather/fixtures/elementwise_gather.esm",
        "model": "Column",
        "tolerance_class": "transcendental",
        "anchor": _gather_column,
        "domain": "any",
    },
    {
        "id": "explicit_gather",
        "path": "conformance/elementwise_observed_gather/fixtures/explicit_gather.esm",
        "model": "Column",
        "tolerance_class": "transcendental",
        "anchor": _gather_column,
        "domain": "any",
    },
    _pde_entry("diffusion_1d_dirichlet_n4", "dirichlet", 4, "diffusion", "Diff1D"),
    _pde_entry("diffusion_1d_neumann_n4", "neumann", 4, "diffusion", "Diff1D"),
    _pde_entry("diffusion_1d_zero_gradient_n4", "zero_gradient", 4, "diffusion", "Diff1D"),
    _pde_entry("diffusion_1d_robin_n4", "robin", 4, "diffusion", "Diff1D"),
    _pde_entry("diffusion_1d_periodic_n4", "periodic", 4, "diffusion", "Diff1D"),
    _pde_entry("diffusion_1d_periodic_n8", "periodic", 8, "diffusion", "Diff1D"),
    _pde_entry("diffusion_2d_dirichlet_n3", "dirichlet", 3, "diffusion2d", "Diff2D"),
    _pde_entry("advection_1d_periodic_n4", "periodic", 4, "advection", "Advect1D"),
    {
        "id": "events_cross_system_meteorology",
        "path": "valid/events_cross_system.esm",
        "model": "MeteorologicalSystem",
        "tolerance_class": "transcendental",
        "anchor": _events_meteorology,
        "domain": "any",
    },
    {
        "id": "expr_graphs_variable_deps",
        "path": "valid/expr_graphs_variable_deps.esm",
        "model": "VariableDependencyModel",
        "tolerance_class": "transcendental",
        "anchor": _variable_deps,
        "domain": "positive",
    },
    {
        "id": "pde_inline_observed_indexed_lhs",
        "path": "conformance/pde_inline_observed_indexed_lhs/fixtures/observed_indexed_lhs.esm",
        "model": "M",
        "tolerance_class": "algebraic",
        "anchor": _indexed_lhs,
        "domain": "any",
    },
    {
        "id": "pde_inline_observed_rank2",
        "path": "conformance/pde_inline_observed_rank2/fixtures/observed_rank2.esm",
        "model": "M",
        "tolerance_class": "algebraic",
        "anchor": _rank2_scaled(1.5),
        "domain": "any",
    },
    {
        "id": "pde_inline_observed_param_rank2",
        "path": "conformance/pde_inline_observed_param_rank2/fixtures/observed_param_rank2.esm",
        "model": "M",
        "tolerance_class": "algebraic",
        "anchor": _rank2_scaled(1.5),
        "domain": "any",
    },
    {
        "id": "pde_inline_observed_state_dependent",
        "path": "conformance/pde_inline_observed_state_dependent/fixtures/"
        "observed_state_dependent.esm",
        "model": "M",
        "tolerance_class": "algebraic",
        "anchor": _state_dependent,
        "domain": "any",
    },
    {
        "id": "mount_rename_atm_column",
        "path": "valid/mount_rename_atm_column.esm",
        "model": "AtmColumn",
        "tolerance_class": "algebraic",
        "anchor": _relaxation("T", 59, -1.0),
        "domain": "any",
    },
    {
        "id": "mount_rename_soil_column",
        "path": "valid/mount_rename_soil_column.esm",
        "model": "SoilColumn",
        "tolerance_class": "algebraic",
        "anchor": _relaxation("Tsoil", 4, -0.5),
        "domain": "any",
    },
    {
        "id": "units_registry_grammar",
        "path": "valid/units_registry_grammar.esm",
        "model": "UnitsRegistryGrammar",
        "tolerance_class": "algebraic",
        "anchor": _first_order_decay,
        "domain": "any",
    },
]


# Fixtures the tier does NOT carry, each with the reason and what would have to
# change to include it. The precision block is the 2026-09-13 ruling; the rest
# are fixtures from the phase-1 candidate list that the reference evaluator
# cannot build or that carry no ODE state to probe.
EXCLUDED = [
    {
        "path": "fixtures/recurrence/06_recurrence_float32_state.esm",
        "reason": "precision-changing; excluded until both compiled emitters lower it "
        "(ruling 2026-09-13)",
    },
    {
        "path": "valid/minimal_chemistry.esm",
        "reason": "precision-changing; excluded until both compiled emitters lower it "
        "(ruling 2026-09-13)",
    },
    {
        "path": "valid/model_only.esm",
        "reason": "precision-changing; excluded until both compiled emitters lower it "
        "(ruling 2026-09-13)",
    },
    {
        "path": "future/robustness/denormal_number_handling.esm",
        "reason": "precision-changing; excluded until both compiled emitters lower it "
        "(ruling 2026-09-13)",
    },
    {
        "path": "future/robustness/schema_evolution_stress.esm",
        "reason": "precision-changing; excluded until both compiled emitters lower it "
        "(ruling 2026-09-13)",
    },
    {
        "path": "conformance/flatten/cases.json",
        "reason": "precision-changing; excluded until both compiled emitters lower it "
        "(ruling 2026-09-13). Not a standalone .esm — a flatten case file whose "
        "embedded document declares element_type Float32.",
    },
    {
        "path": "conformance/classification_indexed_lhs/fixtures/observed_indexed_lhs.esm",
        "reason": "the reference tree-walk evaluator refuses to build it: "
        "E_TREEWALK_UNSUPPORTED_SHAPE on the bare-index LHS `index(wb, i) ~ 5`, whose "
        "index `i` is bound by no range. There is no reference RHS to probe, so the "
        "fixture cannot enter a tier whose golden IS the reference RHS. Include it once "
        "the evaluator supports the bare-index LHS spelling of esm-spec §6.3.1.",
    },
]


# === Julia state-layout dump ==============================================

_JULIA_DUMP = r"""
import Pkg
let env = raw"{env}", mpath = joinpath(raw"{env}", "Manifest.toml")
    Pkg.activate(env; io=devnull)
    isfile(mpath) || Pkg.develop(path=raw"{pkg}"; io=devnull)
    Pkg.instantiate(; io=devnull)
end
using EarthSciAST
using JSON3
_bare(s) = occursin('.', s) ? String(split(s, '.'; limit=2)[2]) : String(s)
spec = JSON3.read(read(ARGS[1], String))
out = Dict{{String,Any}}()
for e in spec
    file = load_path(String(e.path))
    f!, u0, p, _, vmap = build_evaluator(file; model_name=String(e.model))
    bare = Dict{{String,Int}}()
    for (k, i) in vmap
        bare[_bare(String(k))] = i
    end
    order = Vector{{String}}(undef, length(u0))
    for (n, i) in bare
        order[i] = n
    end
    out[String(e.id)] = Dict(
        "state_order" => order,
        "u0" => Dict{{String,Float64}}(n => Float64(u0[i]) for (n, i) in bare),
        "parameters" => p === nothing ? String[] : String.(collect(keys(p))),
    )
end
open(ARGS[2], "w") do io
    JSON3.write(io, out)
end
"""


def julia_state_layouts(entries: list[dict]) -> dict:
    """One Julia process; returns {id: {state_order, u0, parameters}}."""
    spec = [{"id": e["id"], "path": str(TESTS / e["path"]), "model": e["model"]} for e in entries]
    code = _JULIA_DUMP.format(env=str(JULIA_ENV), pkg=str(JULIA_PKG))
    with tempfile.TemporaryDirectory(prefix="compiled-rhs-gen-") as td:
        inp = Path(td) / "spec.json"
        outp = Path(td) / "layout.json"
        inp.write_text(json.dumps(spec))
        proc = subprocess.run(
            ["julia", "--project=" + str(JULIA_ENV), "-e", code, str(inp), str(outp)],
            capture_output=True,
            text=True,
            check=False,
        )
        if not outp.is_file():
            sys.stderr.write(proc.stdout + "\n" + proc.stderr + "\n")
            raise SystemExit("julia state-layout dump produced no output")
        return json.loads(outp.read_text())


# === Probe generation =====================================================


def _perturb(base: float, r: float, domain: str) -> float:
    if domain == "positive":
        return round((base if base > 0.0 else 1.0) * math.exp(0.5 * r), 12)
    return round(base + max(1.0, abs(base)) * r, 12)


def build_probes(entry: dict, layout: dict, rng: random.Random, pde_probes: dict) -> list:
    order = layout["state_order"]
    u0 = layout["u0"]
    anchor = entry["anchor"]
    probes: list = []

    if entry.get("pde_spec"):
        # The three original PDE-simulation probes, verbatim: same ids, same
        # states, same independent `L u + b` anchors. Re-anchoring them here
        # would be a second chance to get the operator wrong.
        probes.extend(pde_probes[entry["pde_spec"]])
    else:
        state = {name: float(u0[name]) for name in order}
        probes.append(
            {
                "id": "default",
                "t": 0.0,
                "state": state,
                "analytic_rhs": _as_float_map(anchor(state, 0.0), order),
            }
        )

    for k, t in enumerate(PERTURB_TIMES, start=1):
        state = {}
        for name in order:
            state[name] = _perturb(float(u0[name]), rng.uniform(-1.0, 1.0), entry["domain"])
        probes.append(
            {
                "id": f"perturbed_{k}",
                "t": t,
                "state": state,
                "analytic_rhs": _as_float_map(anchor(state, t), order),
            }
        )
    return probes


def _as_float_map(du: dict, order: list) -> dict:
    missing = [n for n in order if n not in du]
    if missing:
        raise SystemExit(f"anchor produced no value for {missing}")
    out = {}
    for name in order:
        v = float(du[name])
        if not math.isfinite(v):
            raise SystemExit(
                f"anchor produced a non-finite value for {name}: {v!r}. Probes must stay "
                "in the model's valid domain — adjust the fixture's perturbation rule."
            )
        out[name] = v
    return out


def pde_original_probes() -> dict:
    """The three committed PDE-simulation probes per fixture, by fixture id."""
    src = json.loads((TESTS / "conformance" / "pde_simulation" / "manifest.json").read_text())
    return {fx["id"]: fx["rhs_probes"] for fx in src["fixtures"]}


def pde_original_state_order() -> dict:
    src = json.loads((TESTS / "conformance" / "pde_simulation" / "manifest.json").read_text())
    return {fx["id"]: fx["state_order"] for fx in src["fixtures"]}


# === Manifest assembly ====================================================


MANIFEST_DESCRIPTION = (
    "Compiled right-hand-side conformance. Every binding's engine must reproduce the "
    "reference INTERPRETER's f(u, p, t) at fixed probe states, within the tolerance of "
    "the fixture's class. Agreement is numerical; nothing here inspects an emitted "
    "program. A model a compiled engine cannot lower completely is a hard error in that "
    "binding, recorded as a NAMED EXCLUSION in the report — never a pass and never a "
    "silent skip. Precision-changing fixtures are excluded until both emitters lower "
    "them (see `excluded`). Probe states and analytic_rhs anchors are generated by "
    "scripts/gen_compiled_rhs_manifest.py; see "
    "tests/conformance/compiled_rhs/README.md for the generator's seed and rules."
)


def build_manifest() -> dict:
    layouts = julia_state_layouts(FIXTURE_TABLE)
    pde_probes = pde_original_probes()
    pde_orders = pde_original_state_order()
    rng = random.Random(SEED)
    fixtures = []
    for entry in FIXTURE_TABLE:
        layout = layouts[entry["id"]]
        order = layout["state_order"]
        if entry.get("pde_spec"):
            # The PDE-simulation tier's `state_order` must name the SAME element
            # set, but not necessarily in the same sequence: that tier never uses
            # the order positionally (its probes, goldens and anchors are all
            # keyed by element name), and its 2-D entry is in fact listed
            # row-major (u[1,1], u[1,2], …) while the reference evaluator lays
            # the state out column-major (u[1,1], u[2,1], …). THIS tier's
            # `state_order` is the evaluator's real flat layout, so the sequence
            # is taken from the evaluator and only the element set is checked.
            committed = pde_orders[entry["pde_spec"]]
            if sorted(committed) != sorted(order):
                raise SystemExit(
                    f"{entry['id']}: the PDE-simulation manifest's state_order "
                    f"{committed} names a different element set than the "
                    f"evaluator's {order}"
                )
        fixtures.append(
            {
                "id": entry["id"],
                "path": entry["path"],
                "model": entry["model"],
                "tolerance_class": entry["tolerance_class"],
                "compiled_required": [],
                "state_order": order,
                "parameters": {},
                "rhs_probes": build_probes(entry, layout, rng, pde_probes),
            }
        )
    return {
        "category": "compiled_rhs",
        "version": "1.0",
        "description": MANIFEST_DESCRIPTION,
        "reference_binding": "julia",
        "engines": {
            "interpreter": {"bindings_required": ["julia", "rust", "python"]},
            "compiled": {"bindings_required": [], "bindings_optional": ["julia", "rust"]},
        },
        "scope_excluded": {
            "go": "rewrite-only port; no faq/makearray evaluator, no RHS hook",
            "typescript": "rewrite-only port; no faq/makearray evaluator, no RHS hook",
        },
        "tolerance_classes": {
            "algebraic": {"rtol": 1e-13, "atol": 1e-300},
            "transcendental": {"rtol": 1e-12, "atol": 1e-300},
            "reduction": {"rtol": 1e-11, "atol_scaled": 1e-14},
            "float32": {"rtol": 1e-5, "atol": 1e-30},
        },
        "excluded": EXCLUDED,
        "fixtures": fixtures,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--output",
        type=Path,
        default=TIER / "manifest.json",
        help="Where to write the manifest (default: the tier's manifest.json).",
    )
    args = ap.parse_args()
    manifest = build_manifest()
    out = args.output
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, indent=2) + "\n")
    n_probes = sum(len(fx["rhs_probes"]) for fx in manifest["fixtures"])
    # `--output` may point anywhere (regenerating into a scratch path to diff
    # against the committed manifest is how the reproducibility claim in the
    # tier README is checked), so render the path relative to the repo only when
    # it actually lies inside it.
    try:
        shown = out.resolve().relative_to(REPO)
    except ValueError:
        shown = out
    print(
        f"wrote {shown}: {len(manifest['fixtures'])} fixture(s), "
        f"{n_probes} probe(s), {len(manifest['excluded'])} exclusion(s)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
