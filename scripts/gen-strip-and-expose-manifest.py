#!/usr/bin/env python3
"""Generate tests/conformance/strip_and_expose/manifest.json (CONFORMANCE_SPEC §5.57).

Every expected kernel value below is an analytic anchor computed from the
fixture's mathematics here, without any binding. The inputs are dyadic
rationals, so every anchor is exact in binary64.
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tests" / "conformance" / "strip_and_expose" / "manifest.json"
UC = "../unsupported_construct/fixtures/"
FX = "fixtures/"

CE, DE, PU, AL = "continuous_events", "discrete_events", "parameter_updates", "algebraic"
CLASSES = [CE, DE, PU, AL]


def others(own):
    return [[c] for c in CLASSES if c not in own]


def per_class():
    cases = []
    event_docs = {
        DE: [
            "discrete_event_on_the_array_path",
            "discrete_event_on_the_scalar_path",
            "discrete_event_in_a_subsystem_on_the_array_path",
            "discrete_event_in_a_subsystem_on_the_scalar_path",
            "discrete_event_on_a_reaction_system",
        ],
        CE: [
            "continuous_event_on_the_array_path",
            "continuous_event_on_the_scalar_path",
            "continuous_event_in_a_subsystem_on_the_array_path",
            "continuous_event_in_a_subsystem_on_the_scalar_path",
            "continuous_event_on_a_coupled_array_document",
            "continuous_event_on_a_reaction_system",
        ],
        AL: [
            "implicit_equation_on_the_array_path",
            "implicit_equation_on_the_scalar_path",
        ],
    }
    for cls, docs in event_docs.items():
        for d in docs:
            cases.append(
                {
                    "id": d,
                    "path": UC + d + ".esm",
                    "builds_with": [cls],
                    "refuses_with": others([cls]),
                    "refusal_code": "unsupported_construct",
                }
            )
    cases.append(
        {
            "id": "implicit_equation_as_the_derivative_of_an_expression",
            "path": UC + "implicit_equation_as_the_derivative_of_an_expression.esm",
            "builds_with": None,
            "refuses_with": [[AL], CLASSES],
            "refusal_code": None,
            "note": "D(a + b) ~ 3 is a misspelled equation, not a residual: it stays refused under every class.",
        }
    )
    for d in ["wiener_noise_on_the_scalar_path", "wiener_noise_on_the_array_path"]:
        cases.append(
            {
                "id": d,
                "path": UC + d + ".esm",
                "builds_with": None,
                "refuses_with": [[c] for c in CLASSES] + [CLASSES],
                "refusal_code": "unsupported_construct",
                "note": "Wiener noise is never strippable.",
            }
        )
    cases.append(
        {
            "id": "parameter_updates",
            "path": FX + "parameter_updates.esm",
            "builds_with": [CE, PU],
            "refuses_with": [[PU], [CE], [DE], [AL]],
            "refusal_code": None,
            "note": "`gate` carries a crossing rule, stripped only with continuous_events too. The refusal of a symbolic parameter update has no common code across bindings yet (RFC U6 open question 4), so only the refusal itself is gated.",
        }
    )
    cases.append(
        {
            "id": "coupling_level_event",
            "path": FX + "coupling_level_event.esm",
            "builds_with": [DE],
            "refuses_with": [[CE], [PU], [AL]],
            "refusal_code": "unsupported_construct",
        }
    )
    cases.append(
        {
            "id": "imported_coupling_event",
            "path": FX + "imported_coupling_event.esm",
            "builds_with": [CE, DE],
            "refuses_with": [[CE], [DE], [PU], [AL]],
            "refusal_code": "unsupported_construct",
            "note": "The two discrete events arrive through a coupling_import: with continuous_events alone they are what is refused.",
        }
    )
    cases.append(
        {
            "id": "nested_and_mounted",
            "path": FX + "nested_and_mounted.esm",
            "builds_with": [DE, PU],
            "refuses_with": [[DE], [PU], [CE], [AL]],
            "refusal_code": None,
            "note": "With discrete_events alone the updates two levels deep and across the {ref} mount are still refused; with parameter_updates alone, the events. The symbolic-update refusal has no common code yet (RFC U6 open question 4).",
        }
    )
    cases.append(
        {
            "id": "reaction_system_subsystem_events",
            "path": FX + "reaction_system_subsystem_events.esm",
            "builds_with": [CE, DE],
            "refuses_with": [[CE], [DE], [PU], [AL]],
            "refusal_code": None,
            "note": "Only the refusal is gated: Python's build reports an event left in place that writes Pool.P as event_var_undeclared before it reaches the unsupported_construct gate.",
        }
    )
    cases.append(
        {
            "id": "z0_warm_start",
            "path": FX + "z0_warm_start.esm",
            "builds_with": [AL],
            "refuses_with": others([AL]),
            "refusal_code": "unsupported_construct",
        }
    )
    return cases


def goldens():
    rows = [
        ("discrete_event_in_a_subsystem_on_the_scalar_path", UC, [DE]),
        ("continuous_event_in_a_subsystem_on_the_array_path", UC, [CE]),
        ("continuous_event_on_a_reaction_system", UC, [CE]),
        ("discrete_event_on_a_reaction_system", UC, [DE]),
        ("continuous_event_on_a_coupled_array_document", UC, [CE]),
        ("implicit_equation_on_the_scalar_path", UC, [AL]),
        ("implicit_equation_on_the_array_path", UC, [AL]),
        ("coupling_level_event", FX, [DE]),
        ("parameter_updates", FX, [CE, PU]),
        ("ssa_residual_1d", FX, [AL]),
        ("condition_event_swap", FX, [CE, DE]),
        ("imported_coupling_event", FX, [CE, DE]),
        ("nested_and_mounted", FX, [DE, PU]),
        ("reaction_system_subsystem_events", FX, [CE, DE]),
    ]
    out = [
        {"id": i, "path": base + i + ".esm", "strip": s, "golden": "goldens/" + i + ".json"}
        for i, base, s in rows
    ]
    # z0 is the ic evaluated at the start of the run with the Problem's
    # parameter values: k = 1 by default (y = 2 k + t = 2.5, v = k + t = 1.5 at
    # t0 = 0.5), and the caller's p wins (k = 3: y = 6.5, v = 3.5).
    for i, p in [("z0_warm_start", {}), ("z0_warm_start_with_p", {"W.k": 3.0})]:
        out.append(
            {
                "id": i,
                "path": FX + "z0_warm_start.esm",
                "strip": [AL],
                "tspan": [0.5, 1.0],
                "p": p,
                "golden": "goldens/" + i + ".json",
            }
        )
    return out


def not_solvable():
    return [
        {
            "id": "stripped_discrete_event",
            "path": UC + "discrete_event_on_the_array_path.esm",
            "strip": [DE],
            "tspan": [0.0, 1.0],
            "expect": "stripped_problem_not_solvable",
        },
        {
            "id": "stripped_implicit_equation",
            "path": FX + "ssa_residual_1d.esm",
            "strip": [AL],
            "tspan": [0.0, 1.0],
            "expect": "stripped_problem_not_solvable",
        },
        {
            "id": "control_nothing_to_strip",
            "path": UC + "control_array_path_without_the_construct.esm",
            "strip": CLASSES,
            "tspan": [0.0, 3.5],
            "expect": "solves",
            "note": "strip names every class, the document has none of them: the Problem is not stripped and solves.",
        },
    ]


def remaining_rhs():
    def case(d, base, cls, probes):
        return {
            "id": d,
            "path": base + d + ".esm",
            "strip": [cls],
            "probes": probes,
            "control": "the same document with every continuous_events and discrete_events key deleted (models, subsystems at any depth, reaction systems) and every coupling entry of type event removed",
        }

    return [
        case(
            "discrete_event_on_the_array_path",
            UC,
            DE,
            [{"u": {"DiscreteEventOnTheArrayPath.s": 1.5}, "t": 0.25}],
        ),
        case("continuous_event_on_the_scalar_path", UC, CE, [{"u": None, "t": 0.5}]),
        case("continuous_event_on_a_coupled_array_document", UC, CE, [{"u": None, "t": 0.5}]),
        case("discrete_event_on_a_reaction_system", UC, DE, [{"u": None, "t": 0.5}]),
        case("coupling_level_event", FX, DE, [{"u": {"A.x": 0.75, "B.y": 0.25}, "t": 1.5}]),
        case("condition_event_swap", FX, DE, [{"u": {"Swap.a": 3.0, "Swap.b": 1.0}, "t": 0.0}]),
    ]


def kernels():
    out = []
    # 1. SSA residual at the exact discrete profile and at zero velocity.
    h, dx = 2.0, 0.25
    xs = [i * dx for i in range(6)]
    L = 5 * dx
    vel_exact = [h * x * (L - x) / 2 for x in xs]
    H = [h] * 6

    def jac(vel):
        r = []
        for i in range(6):
            if i in (0, 5):
                r.append(vel[i] - 0.0)
            else:
                r.append(vel[i] - (vel[i + 1] + vel[i - 1] + dx**2 * H[i]) * 0.5)
        return r

    vel0 = [0.0] * 6
    out.append(
        {
            "id": "ssa_residual",
            "path": FX + "ssa_residual_1d.esm",
            "strip": [AL],
            "tolerance_class": "algebraic",
            "specs": [
                {"name": "ssa_residual", "outputs": [{"residual": "SSA.residual[1]"}]},
                {"name": "rhs"},
            ],
            "z_layout": {"SSA.vel": {"base": 1, "shape": [6]}},
            "probes": [
                {
                    "kernel": "ssa_residual",
                    "u": {"SSA.H": H},
                    "z": {"SSA.vel": vel_exact},
                    "t": 0.0,
                    "dt": 0.0,
                    "expected": {"SSA.residual[1]": jac(vel_exact)},
                    "note": "the exact discrete parabola: the residual vanishes",
                },
                {
                    "kernel": "ssa_residual",
                    "u": {"SSA.H": H},
                    "z": {"SSA.vel": vel0},
                    "t": 0.0,
                    "dt": 0.0,
                    "expected": {"SSA.residual[1]": jac(vel0)},
                },
                {
                    "kernel": "rhs",
                    "u": {"SSA.H": H},
                    "z": {"SSA.vel": vel_exact},
                    "t": 0.0,
                    "dt": 0.0,
                    "expected": {"du": [-0.5 * v for v in vel_exact]},
                    "note": "the stripped right-hand side reads z",
                },
            ],
        }
    )
    # 2. Geometry source step map at two dt values, one build.
    Hg = [100.0, 200.0, 300.0]
    probes = []
    for dt in (0.5, 2.0):
        probes.append(
            {
                "kernel": "geometry_source",
                "u": {"Geometry.H": Hg},
                "z": {},
                "t": 0.0,
                "dt": dt,
                "expected": {"u": [x + dt * (0.5 - 0.25) for x in Hg]},
            }
        )
        probes.append(
            {
                "kernel": "geometry_source_value",
                "u": {"Geometry.H": Hg},
                "z": {},
                "t": 0.0,
                "dt": dt,
                "expected": {"Geometry.H_out_source": [x + dt * (0.5 - 0.25) for x in Hg]},
            }
        )
    out.append(
        {
            "id": "geometry_step_map",
            "path": FX + "geometry_step_map.esm",
            "strip": [],
            "tolerance_class": "algebraic",
            "specs": [
                {
                    "name": "geometry_source",
                    "dt_params": ["Geometry.dt"],
                    "outputs": [{"assign": "Geometry.H", "from": "Geometry.H_out_source"}],
                },
                {
                    "name": "geometry_source_value",
                    "dt_params": ["Geometry.dt"],
                    "outputs": [{"observed": "Geometry.H_out_source"}],
                },
            ],
            "probes": probes,
            "note": "dt is live: both dt values are answered by one compile_kernels call.",
        }
    )
    # 3. Ignition-time map and CFL limit.
    psi = [-1.0, 0.5, 0.0, 2.0]
    tig = [3.0, 1000000.0, 1000000.0, 1000000.0]
    w = [2.0, -4.0, 0.5, 8.0]
    t, dt = 10.0, 0.5
    tig_next = [min(g, t + dt) if p <= 0 else g for p, g in zip(psi, tig)]
    out.append(
        {
            "id": "fire_maps",
            "path": FX + "fire_maps.esm",
            "strip": [],
            "tolerance_class": "algebraic",
            "specs": [
                {
                    "name": "ignition",
                    "dt_params": ["Fire.dt"],
                    "outputs": [{"assign": "Fire.tig", "from": "Fire.tig_next"}],
                },
                {
                    "name": "cfl",
                    "outputs": [
                        {"observed": "Fire.dt_cfl"},
                        {
                            "expr": {
                                "op": "faq",
                                "args": [],
                                "output_idx": [],
                                "ranges": {"i": {"from": "x"}},
                                "expr": {
                                    "op": "/",
                                    "args": [
                                        "Fire.dx",
                                        {
                                            "op": "abs",
                                            "args": [{"op": "index", "args": ["Fire.w", "i"]}],
                                        },
                                    ],
                                },
                                "reduce": "min",
                            },
                            "label": "dt_cfl_min",
                        },
                    ],
                },
            ],
            "probes": [
                {
                    "kernel": "ignition",
                    "u": {"Fire.psi": psi, "Fire.tig": tig, "Fire.w": w},
                    "z": {},
                    "t": t,
                    "dt": dt,
                    "expected": {"u": psi + tig_next + w},
                },
                {
                    "kernel": "cfl",
                    "u": {"Fire.psi": psi, "Fire.tig": tig, "Fire.w": w},
                    "z": {},
                    "t": t,
                    "dt": dt,
                    "expected": {
                        "Fire.dt_cfl": [1.0 / abs(x) for x in w],
                        "dt_cfl_min": min(1.0 / abs(x) for x in w),
                    },
                },
            ],
        }
    )
    # 4. Discrete condition and its simultaneous affect.
    out.append(
        {
            "id": "condition_event_swap",
            "path": FX + "condition_event_swap.esm",
            "strip": [DE],
            "tolerance_class": "algebraic",
            "specs": [
                {"name": "swap_condition", "outputs": [{"condition": "Swap.swap"}]},
                {"name": "swap_affect", "outputs": [{"affect": "Swap.swap"}]},
            ],
            "probes": [
                {
                    "kernel": "swap_condition",
                    "u": {"Swap.a": 3.0, "Swap.b": 1.0},
                    "z": {},
                    "t": 0.0,
                    "dt": 0.0,
                    "expected": {"Swap.swap.condition[1]": 1.0},
                },
                {
                    "kernel": "swap_condition",
                    "u": {"Swap.a": 0.0, "Swap.b": 2.0},
                    "z": {},
                    "t": 0.0,
                    "dt": 0.0,
                    "expected": {"Swap.swap.condition[1]": 0.0},
                },
                {
                    "kernel": "swap_affect",
                    "u": {"Swap.a": 3.0, "Swap.b": 1.0},
                    "z": {},
                    "t": 0.0,
                    "dt": 0.0,
                    "expected": {"u": [1.0, 3.0]},
                },
            ],
        }
    )
    return out


def refusals():
    return [
        {
            "id": "affect_reads_post_value",
            "path": FX + "affect_reads_post_value.esm",
            "strip": [DE],
            "specs": [{"name": "swap_affect", "outputs": [{"affect": "PostValue.swap"}]}],
            "expect_error": {
                "code": "affect_reads_post_value",
                "mentions": ["PostValue.swap", "PostValue.b"],
            },
        },
        {
            "id": "unknown_observed",
            "path": FX + "geometry_step_map.esm",
            "strip": [],
            "specs": [{"name": "bad", "outputs": [{"observed": "Geometry.nonexistent"}]}],
            "expect_error": {
                "code": "kernel_output_unresolved",
                "mentions": ["bad", "Geometry.nonexistent"],
            },
        },
        {
            "id": "unknown_residual",
            "path": FX + "ssa_residual_1d.esm",
            "strip": [AL],
            "specs": [{"name": "bad", "outputs": [{"residual": "SSA.residual[2]"}]}],
            "expect_error": {
                "code": "kernel_output_unresolved",
                "mentions": ["bad", "SSA.residual[2]"],
            },
        },
        {
            "id": "affect_reads_a_dotted_post_value",
            "path": FX + "reaction_system_subsystem_events.esm",
            "strip": [CE, DE],
            "specs": [{"name": "bad_affect", "outputs": [{"affect": "Chem.bad"}]}],
            "expect_error": {
                "code": "affect_reads_post_value",
                "mentions": ["Chem.bad", "Chem.Pool.P"],
            },
        },
        {
            "id": "condition_index_zero",
            "path": FX + "condition_event_swap.esm",
            "strip": [DE],
            "specs": [{"name": "bad", "outputs": [{"condition": "Swap.swap", "index": 0}]}],
            "expect_error": {"code": "kernel_output_unresolved", "mentions": ["bad"]},
        },
        {
            "id": "unknown_event",
            "path": FX + "condition_event_swap.esm",
            "strip": [DE],
            "specs": [{"name": "bad", "outputs": [{"condition": "Swap.nope"}]}],
            "expect_error": {"code": "kernel_output_unresolved", "mentions": ["bad", "Swap.nope"]},
        },
        {
            "id": "assign_to_a_parameter",
            "path": FX + "geometry_step_map.esm",
            "strip": [],
            "specs": [
                {"name": "bad", "outputs": [{"assign": "Geometry.smb", "from": "Geometry.bmb"}]}
            ],
            "expect_error": {
                "code": "kernel_output_unresolved",
                "mentions": ["bad", "Geometry.smb"],
            },
        },
        {
            "id": "dt_param_not_a_parameter",
            "path": FX + "geometry_step_map.esm",
            "strip": [],
            "specs": [
                {
                    "name": "bad",
                    "dt_params": ["Geometry.H"],
                    "outputs": [{"observed": "Geometry.H_out_source"}],
                }
            ],
            "expect_error": {"code": "kernel_output_unresolved", "mentions": ["bad", "Geometry.H"]},
        },
        {
            "id": "map_mixed_with_value",
            "path": FX + "geometry_step_map.esm",
            "strip": [],
            "specs": [
                {
                    "name": "bad",
                    "outputs": [
                        {"assign": "Geometry.H", "from": "Geometry.H_out_source"},
                        {"observed": "Geometry.H_out_source"},
                    ],
                }
            ],
            "expect_error": {"code": "kernel_output_unresolved", "mentions": ["bad"]},
        },
    ]


def main():
    manifest = {
        "category": "strip_and_expose",
        "version": "1.0",
        "description": (
            "Strip and expose (issue #543, RFC U6): esm_problem's `strip` removes the named construct "
            "classes from what the build lowers and hands them back as one object (`stripped`), and "
            "`compile_kernels` compiles observeds and expressions as kernels sharing the stripped "
            "right-hand side's ABI, k(out, u, z, p, t, dt). Generated by "
            "scripts/gen-strip-and-expose-manifest.py; every kernel anchor is analytic."
        ),
        "spec": [
            "API_SPEC.md §5.8 (Strip and expose)",
            "CONFORMANCE_SPEC.md §5.57",
            "esm-libraries-spec.md §2.5.13",
        ],
        "bindings": {
            "julia": "every section",
            "rust": "every section",
            "python": "per_class, stripped_goldens, not_solvable, and compile_kernels refused with compiler_unavailable",
        },
        "classes": CLASSES,
        "tolerance_classes": {
            "algebraic": {"rtol": 1e-13, "atol": 1e-300},
            "note": "CONFORMANCE_SPEC §5.38.2; |got - want| <= atol + rtol |want|",
        },
        "probe_inputs": (
            "u and z name every block of state_layout(ks) / z_layout(ks) by flattened name (a number for a "
            "0-d block, a column-major list for an array block); p is parameter_vector(ks, {}) (the "
            "declared defaults); forcing is default_forcing_set(ks). `u: null` in remaining_rhs means the "
            "program's default state (each state's starting value). expected maps a kernel_layout label to "
            "its values; `u` is the whole output of a map kernel and `du` that of the rhs kernel."
        ),
        "default_refusal": {
            "manifest": "../unsupported_construct/manifest.json",
            "note": "With strip empty every refusal case of CONFORMANCE_SPEC §5.39 still refuses; that category's own adapters gate it.",
        },
        "per_class": per_class(),
        "stripped_goldens": goldens(),
        "not_solvable": not_solvable(),
        "remaining_rhs": remaining_rhs(),
        "kernels": kernels(),
        "refusals": refusals(),
    }
    OUT.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
