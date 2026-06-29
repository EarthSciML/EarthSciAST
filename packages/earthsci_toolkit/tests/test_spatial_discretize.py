"""Generic GDD-driven spatial discretization (the Python PDE-op scan).

Key property under test: rule selection is **data, not code** — the same pass,
fed different GDDs, produces different stencils with zero code change (centered
vs. upwind), and a new catalog rule would plug in identically.
"""
from __future__ import annotations

import math

import numpy as np
import pytest

import earthsci_toolkit as et
from earthsci_toolkit.simulation import simulate
from earthsci_toolkit.spatial_discretize import spatial_discretize


def _arrayop_rule(name, op, expr):
    return {"discretizations": {name: {
        "applies_to": {"op": op, "args": ["$u"], "dim": "$x"},
        "grid_family": "cartesian",
        "replacement": {"op": "arrayop", "output_idx": ["$x"], "args": ["$u"], "expr": expr},
    }}}


# catalog-shaped stencil rules (as they would live in ESD JSON)
_CENTERED_GRAD = _arrayop_rule("centered_grad", "grad", {"op": "/", "args": [
    {"op": "-", "args": [
        {"op": "index", "args": ["$u", {"op": "+", "args": ["$x", 1]}]},
        {"op": "index", "args": ["$u", {"op": "+", "args": ["$x", -1]}]}]},
    {"op": "*", "args": [2, "dx"]}]})
_UPWIND_GRAD = _arrayop_rule("upwind_grad", "grad", {"op": "/", "args": [
    {"op": "-", "args": [
        {"op": "index", "args": ["$u", "$x"]},
        {"op": "index", "args": ["$u", {"op": "+", "args": ["$x", -1]}]}]}, "dx"]})
_CENTERED_D2 = _arrayop_rule("centered_d2", "d2", {"op": "/", "args": [
    {"op": "+", "args": [
        {"op": "index", "args": ["$u", {"op": "+", "args": ["$x", -1]}]},
        {"op": "*", "args": [-2, {"op": "index", "args": ["$u", "$x"]}]},
        {"op": "index", "args": ["$u", {"op": "+", "args": ["$x", 1]}]}]},
    {"op": "*", "args": ["dx", "dx"]}]})


def _advection(dx=0.25):
    return {
        "esm": "0.5.0", "metadata": {"name": "Adv"},
        "domains": {"line": {"independent_variable": "t",
            "spatial": {"x": {"min": 0.0, "max": 1.0, "grid_spacing": dx}},
            "boundary_conditions": [{"type": "dirichlet", "value": 0.0, "dimensions": ["x"]}]}},
        "models": {"Adv": {"domain": "line", "system_kind": "pde",
            "variables": {"u": {"type": "state", "units": "1"}},
            "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                           "rhs": {"op": "grad", "args": ["u"], "dim": "x"}}]}},
    }


def _interior(disc, model):
    return disc["models"][model]["equations"][0]["rhs"]["expr"]["args"][0]["values"][0]


def test_gdd_choice_flips_stencil_with_no_code_change():
    """Same pass + same model; the GDD alone decides centered vs upwind."""
    centered = _interior(spatial_discretize(_advection(),
                          {"discretizations": {"grad": _CENTERED_GRAD}}), "Adv")
    upwind = _interior(spatial_discretize(_advection(),
                       {"discretizations": {"grad": _UPWIND_GRAD}}), "Adv")
    assert centered != upwind
    # centered references u[x+1] and u[x-1]; upwind references u[x] and u[x-1] (no u[x+1])
    s = lambda e: __import__("json").dumps(e)
    assert '{"op": "+", "args": ["x", 1]}' in s(centered)
    assert '{"op": "+", "args": ["x", 1]}' not in s(upwind)
    assert centered["args"][1] == {"op": "*", "args": [2, 0.25]}   # 2*dx baked in
    assert upwind["args"][1] == 0.25                                # dx baked in


_UPWIND_GRAD_BWD = _arrayop_rule("upwind_1st", "grad", {"op": "/", "args": [
    {"op": "-", "args": [
        {"op": "index", "args": ["$u", "$x"]},
        {"op": "index", "args": ["$u", {"op": "+", "args": ["$x", -1]}]}]}, "dx"]})


def test_observed_grad_chain_discretizes_inline_level_set_form():
    """The level-set expresses |grad psi| via OBSERVED equations
    (psi_x = grad(psi,x); grad_mag = sqrt(psi_x^2)). The pass must inline those
    so the grad discretizes in place, then run end to end. A 1-D monotone front
    psi=x-r0 advances at speed R0 (psi_t = -R0|grad psi|)."""
    dx, r0, R0, tf = 0.1, 0.5, 1.0, 0.5
    ls = {
        "esm": "0.5.0", "metadata": {"name": "LS"},
        "domains": {"line": {"independent_variable": "t",
            "spatial": {"x": {"min": 0.0, "max": 2.0, "grid_spacing": dx}},
            "boundary_conditions": [{"type": "zero_gradient", "dimensions": ["x"]}]}},
        "models": {"LS": {"domain": "line", "system_kind": "pde",
            "variables": {
                "psi": {"type": "state", "units": "m"},
                "psi_x": {"type": "observed", "units": "1",
                          "expression": {"op": "grad", "args": ["psi"], "dim": "x"}},
                "grad_mag": {"type": "observed", "units": "1",
                             "expression": {"op": "sqrt", "args": [
                                 {"op": "^", "args": ["psi_x", 2]}]}},
                "R0": {"type": "parameter", "units": "m/s", "default": R0}},
            "equations": [{"lhs": {"op": "D", "args": ["psi"], "wrt": "t"},
                           "rhs": {"op": "*", "args": [{"op": "-", "args": ["R0"]},
                                                       "grad_mag"]}}]}},
    }
    disc = spatial_discretize(ls, {"discretizations": {"grad": _UPWIND_GRAD_BWD}})
    m = disc["models"]["LS"]
    assert "psi_x" not in m["variables"] and "grad_mag" not in m["variables"]  # inlined
    assert "grad" not in __import__("json").dumps(m["equations"][0])           # discretized

    f = et.load(disc)
    n = int(round(2.0 / dx)) + 1
    ic = {f"psi[{i}]": (i - 1) * dx - r0 for i in range(1, n + 1)}
    r = simulate(f, (0.0, tf), initial_conditions=ic, method="LSODA",
                 rtol=1e-7, atol=1e-9, parameters={"R0": R0})
    assert r.success
    xs = [(i - 1) * dx for i in range(1, n + 1)]
    vs = [float(np.interp(tf, r.t, r.y[next(k for k, nm in enumerate(r.vars)
                                            if nm.endswith(f"[{i}]"))]))
          for i in range(1, n + 1)]
    front = next(xs[k] + (xs[k + 1] - xs[k]) * (-vs[k]) / (vs[k + 1] - vs[k])
                 for k in range(len(vs) - 1) if vs[k] <= 0 <= vs[k + 1])
    assert abs(front - (r0 + R0 * tf)) < dx     # right speed, first-order accurate


def _godunov_norm_2d_rule():
    """A single composite catalog-shaped rule: matches the inlined
    sqrt(grad(u,x)^2 + grad(u,y)^2) and rewrites it to the coupled Godunov upwind
    |grad u| for a non-negative speed. No spec op — just a JSON rule."""
    def ix(ox, oy):
        sx = "$x" if ox == 0 else {"op": "+", "args": ["$x", ox]}
        sy = "$y" if oy == 0 else {"op": "+", "args": ["$y", oy]}
        return {"op": "index", "args": ["$u", sx, sy]}

    def comp(m, c, p):   # max(D-,0)^2 + min(D+,0)^2 along one axis
        dm = {"op": "/", "args": [{"op": "-", "args": [c, m]}, "dx"]}
        dp = {"op": "/", "args": [{"op": "-", "args": [p, c]}, "dx"]}
        return {"op": "+", "args": [
            {"op": "^", "args": [{"op": "max", "args": [dm, 0]}, 2]},
            {"op": "^", "args": [{"op": "min", "args": [dp, 0]}, 2]}]}
    c = ix(0, 0)
    return {"discretizations": {"grad_norm": {
        "applies_to": {"op": "sqrt", "args": [{"op": "+", "args": [
            {"op": "^", "args": [{"op": "grad", "args": ["$u"], "dim": "$x"}, 2]},
            {"op": "^", "args": [{"op": "grad", "args": ["$u"], "dim": "$y"}, 2]}]}]},
        "grid_family": "cartesian",
        "replacement": {"op": "sqrt", "args": [{"op": "+", "args": [
            comp(ix(-1, 0), c, ix(1, 0)), comp(ix(0, -1), c, ix(0, 1))]}]}}}}


def test_godunov_norm_via_single_json_rule_runs_symmetric_front():
    """The level-set Hamilton-Jacobi case. A *symmetric* expanding circle is
    unstable/wrong under per-grad centred or upwind differencing, but correct
    under the coupled Godunov scheme — which is achievable as a single composite
    JSON rule (no spec change), applied by the generic pass to the inlined norm."""
    dx, r0, R0, tf = 0.2, 0.4, 1.0, 0.2
    xmin, xmax = -1.0, 1.0
    n = int(round((xmax - xmin) / dx)) + 1
    ls = {
        "esm": "0.5.0", "metadata": {"name": "LS"},
        "domains": {"sq": {"independent_variable": "t",
            "spatial": {"x": {"min": xmin, "max": xmax, "grid_spacing": dx},
                        "y": {"min": xmin, "max": xmax, "grid_spacing": dx}},
            "boundary_conditions": [{"type": "zero_gradient", "dimensions": ["x", "y"]}]}},
        "models": {"LS": {"domain": "sq", "system_kind": "pde", "variables": {
            "psi": {"type": "state", "units": "m"},
            "psi_x": {"type": "observed", "units": "1",
                      "expression": {"op": "grad", "args": ["psi"], "dim": "x"}},
            "psi_y": {"type": "observed", "units": "1",
                      "expression": {"op": "grad", "args": ["psi"], "dim": "y"}},
            "grad_mag": {"type": "observed", "units": "1", "expression": {"op": "sqrt", "args": [
                {"op": "+", "args": [{"op": "^", "args": ["psi_x", 2]},
                                     {"op": "^", "args": ["psi_y", 2]}]}]}},
            "R0": {"type": "parameter", "units": "m/s", "default": R0}},
            "equations": [{"lhs": {"op": "D", "args": ["psi"], "wrt": "t"},
                           "rhs": {"op": "*", "args": [{"op": "-", "args": ["R0"]},
                                                       "grad_mag"]}}]}},
    }
    disc = spatial_discretize(ls, _godunov_norm_2d_rule())
    interior = _interior(disc, "LS")
    body = __import__("json").dumps(interior)
    assert "grad" not in body and '"max"' in body and '"min"' in body   # Godunov, not grad

    f = et.load(disc)

    def X(i):
        return xmin + (i - 1) * dx

    ic = {f"psi[{i},{j}]": math.hypot(X(i), X(j)) - r0
          for i in range(1, n + 1) for j in range(1, n + 1)}
    r = simulate(f, (0.0, tf), initial_conditions=ic, method="LSODA",
                 rtol=1e-6, atol=1e-8, parameters={"R0": R0})
    assert r.success

    jc = (n + 1) // 2

    def radius(t):
        xs = [X(i) for i in range(jc, n + 1)]
        vs = [float(np.interp(t, r.t, r.y[next(k for k, nm in enumerate(r.vars)
                                               if nm.endswith(f"[{i},{jc}]"))]))
              for i in range(jc, n + 1)]
        return next(xs[k] + (xs[k + 1] - xs[k]) * (-vs[k]) / (vs[k + 1] - vs[k])
                    for k in range(len(vs) - 1) if vs[k] <= 0 <= vs[k + 1])

    assert abs(radius(0.0) - r0) < dx
    assert abs(radius(tf) - (r0 + R0 * tf)) < dx        # symmetric front, right speed


def test_coupling_flatten_wires_a_0d_calc_into_the_front():
    """Full coupled pipeline: a 0-D spread-rate calc feeds the level-set's R_0 via
    param_to_var. flatten() resolves the coupling; flattened_to_esm adapts it;
    spatial_discretize inlines the calc and applies the Godunov norm; simulate runs."""
    from earthsci_toolkit.spatial_discretize import flattened_to_esm

    dx = 0.2
    domains = {"sq": {"independent_variable": "t",
        "spatial": {"x": {"min": -1.0, "max": 1.0, "grid_spacing": dx, "units": "m"},
                    "y": {"min": -1.0, "max": 1.0, "grid_spacing": dx, "units": "m"}},
        "boundary_conditions": [{"type": "zero_gradient", "dimensions": ["x", "y"]}]}}
    coupled = {
        "esm": "0.5.0", "metadata": {"name": "Fire"}, "domains": domains,
        "models": {
            "Roth": {"variables": {
                "R_base": {"type": "parameter", "units": "m/s", "default": 1.0},
                "wf": {"type": "parameter", "units": "1", "default": 0.5},
                "R": {"type": "observed", "units": "m/s", "expression":
                      {"op": "*", "args": ["R_base", {"op": "+", "args": [1.0, "wf"]}]}}},
                "equations": []},
            "LevelSet": {"domain": "sq", "system_kind": "pde", "variables": {
                "psi": {"type": "state", "units": "m"},
                "psi_x": {"type": "observed", "units": "1",
                          "expression": {"op": "grad", "args": ["psi"], "dim": "x"}},
                "psi_y": {"type": "observed", "units": "1",
                          "expression": {"op": "grad", "args": ["psi"], "dim": "y"}},
                "grad_mag": {"type": "observed", "units": "1", "expression":
                    {"op": "sqrt", "args": [{"op": "+", "args": [
                        {"op": "^", "args": ["psi_x", 2]}, {"op": "^", "args": ["psi_y", 2]}]}]}},
                "R_0": {"type": "parameter", "units": "m/s", "default": 1.0}},
                "equations": [{"lhs": {"op": "D", "args": ["psi"], "wrt": "t"},
                               "rhs": {"op": "*", "args": [{"op": "-", "args": ["R_0"]},
                                                          "grad_mag"]}}]}},
        "coupling": [{"type": "variable_map", "from": "Roth.R", "to": "LevelSet.R_0",
                      "transform": "param_to_var", "lifting": "pointwise"}],
    }

    # flatten resolves param_to_var: the PDE RHS now references Roth.R, not R_0
    flat = et.flatten(et.load(coupled))
    pde = next(e for e in flat.equations if _serialize(e.lhs).count('"op": "D"'))
    rhs = _serialize(pde.rhs)
    assert "Roth.R" in rhs and "R_0" not in rhs

    # adapt -> discretize (Godunov): the Rothermel calc is inlined; |grad| -> Godunov
    disc = spatial_discretize(flattened_to_esm(flat, domains), _godunov_norm_2d_rule())
    model = disc["models"]["Flattened"]
    body = __import__("json").dumps(model["equations"][0]["rhs"])
    assert "R_base" in body and '"max"' in body and "grad" not in body

    # the coupled, discretized system integrates AND the front advances at the
    # Rothermel-driven speed R = R_base*(1+wf) = 1.5 (not the default R_0=1).
    state = next(n for n, v in model["variables"].items() if v["type"] == "state")
    nn = int(round(2.0 / dx)) + 1
    r0, speed, tf = 0.4, 1.0 * (1 + 0.5), 0.2

    def X(i):
        return -1.0 + (i - 1) * dx

    ic = {f"{state}[{i},{j}]": math.hypot(X(i), X(j)) - r0
          for i in range(1, nn + 1) for j in range(1, nn + 1)}
    r = simulate(et.load(disc), (0.0, tf), initial_conditions=ic, method="LSODA",
                 rtol=1e-6, atol=1e-8)
    assert r.success

    jc = (nn + 1) // 2
    xs = [X(i) for i in range(jc, nn + 1)]
    vs = [float(np.interp(tf, r.t, r.y[next(k for k, nm in enumerate(r.vars)
                                            if nm.endswith(f"[{i},{jc}]"))]))
          for i in range(jc, nn + 1)]
    front = next(xs[k] + (xs[k + 1] - xs[k]) * (-vs[k]) / (vs[k + 1] - vs[k])
                 for k in range(len(vs) - 1) if vs[k] <= 0 <= vs[k + 1])
    assert abs(front - (r0 + speed * tf)) < dx        # front driven by the coupled rate


def _serialize(e):
    from earthsci_toolkit.spatial_discretize import _to_json
    return __import__("json").dumps(_to_json(e))


def test_godunov_matches_real_component_form_via_canonicalization():
    """The composite Godunov rule (int exponent, x-before-y) must still match a
    component that writes the norm differently — float exponent ^2.0 AND reversed
    operand order sqrt(psi_y^2 + psi_x^2) — as the real level_set_fire_spread.esm
    does. Canonicalization (number-type + commutative sort) bridges the gap."""
    dx = 0.2
    comp = {
        "esm": "0.5.0", "metadata": {"name": "LS"},
        "domains": {"sq": {"independent_variable": "t",
            "spatial": {"x": {"min": -1.0, "max": 1.0, "grid_spacing": dx, "units": "m"},
                        "y": {"min": -1.0, "max": 1.0, "grid_spacing": dx, "units": "m"}},
            "boundary_conditions": [{"type": "zero_gradient", "dimensions": ["x", "y"]}]}},
        "models": {"LS": {"domain": "sq", "system_kind": "pde", "variables": {
            "psi": {"type": "state", "units": "m"},
            "psi_x": {"type": "observed", "units": "1",
                      "expression": {"op": "grad", "args": ["psi"], "dim": "x"}},
            "psi_y": {"type": "observed", "units": "1",
                      "expression": {"op": "grad", "args": ["psi"], "dim": "y"}},
            # float exponent 2.0 AND y-term before x-term (vs the rule's int 2, x-first)
            "grad_mag": {"type": "observed", "units": "1", "expression": {"op": "sqrt", "args": [
                {"op": "+", "args": [{"op": "^", "args": ["psi_y", 2.0]},
                                     {"op": "^", "args": ["psi_x", 2.0]}]}]}},
            "R0": {"type": "parameter", "units": "m/s", "default": 1.0}},
            "equations": [{"lhs": {"op": "D", "args": ["psi"], "wrt": "t"},
                           "rhs": {"op": "*", "args": [{"op": "-", "args": ["R0"]},
                                                       "grad_mag"]}}]}},
    }
    disc = spatial_discretize(comp, _godunov_norm_2d_rule())
    body = __import__("json").dumps(_interior(disc, "LS"))
    assert "grad" not in body and '"max"' in body and '"min"' in body   # matched & lowered
    assert et.load(disc) is not None                                    # valid (no `neg` leak)


def test_discretize_single_entry_with_gdd():
    """The canonical discretize(esm, gdd=...) does the PDE-op scan then the DAE
    pass in one call (like Julia build_ode_problem's grid_ref), producing a
    pure-ODE arrayop system that integrates."""
    from earthsci_toolkit.discretize import discretize

    heat = {
        "esm": "0.5.0", "metadata": {"name": "Heat"},
        "domains": {"line": {"independent_variable": "t",
            "spatial": {"x": {"min": 0.0, "max": 1.0, "grid_spacing": 0.2, "units": "m"}},
            "boundary_conditions": [{"type": "dirichlet", "value": 0.0, "dimensions": ["x"]}]}},
        "models": {"Heat": {"domain": "line", "system_kind": "pde",
            "variables": {"u": {"type": "state", "units": "1"}},
            "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                           "rhs": {"op": "laplacian", "args": ["u"]}}]}},
    }
    disc = discretize(heat, gdd={"discretizations": {"d2": _CENTERED_D2}})
    assert disc["metadata"]["system_class"] == "ode"            # PDE -> ODE in one call
    assert disc["models"]["Heat"]["variables"]["u"]["shape"] == ["x"]

    # Homogeneous Dirichlet now lowers to the declarative reflected ghost
    # (u[0] = 2*0 - u[1]) on the FULL N=6 grid, at parity with Julia — a
    # face-centred Dirichlet Laplacian whose eigenmode is sin(k*pi*(i-0.5)/N)
    # with eigenvalue (1/dx^2)(2 cos(k*pi/N) - 2), NOT the old drop-a-cell
    # interior-point form sin(k*pi*i/5).
    f = et.load(disc)   # loads directly: discretize's diagnostic metadata is now schema-valid
    n, dx = 6, 0.2
    ic = {f"u[{i}]": math.sin(math.pi * (i - 0.5) / n) for i in range(1, n + 1)}
    r = simulate(f, (0.0, 0.1), initial_conditions=ic, method="LSODA")
    assert r.success
    lam = (1 / dx**2) * (2 * math.cos(math.pi / n) - 2)
    for i in range(1, n + 1):
        idx = next(k for k, nm in enumerate(r.vars) if nm.endswith(f"[{i}]"))
        assert float(np.interp(0.1, r.t, r.y[idx])) == pytest.approx(
            math.exp(lam * 0.1) * math.sin(math.pi * (i - 0.5) / n), rel=1e-6)


def test_heat_runs_end_to_end_via_gdd():
    """laplacian -> d2 (GDD-selected centered) -> simulate; matches analytical."""
    heat = {
        "esm": "0.5.0", "metadata": {"name": "Heat"},
        "domains": {"line": {"independent_variable": "t",
            "spatial": {"x": {"min": 0.0, "max": 1.0, "grid_spacing": 0.2}},
            "boundary_conditions": [{"type": "dirichlet", "value": 0.0, "dimensions": ["x"]}]}},
        "models": {"Heat": {"domain": "line", "system_kind": "pde",
            "variables": {"u": {"type": "state", "units": "1"}},
            "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                           "rhs": {"op": "laplacian", "args": ["u"]}}]}},
    }
    disc = spatial_discretize(heat, {"discretizations": {"d2": _CENTERED_D2}})
    f = et.load(disc)
    # Reflected-ghost Dirichlet on the full N=6 grid (see
    # test_discretize_single_entry_with_gdd): face-centred eigenmode.
    n, dx = 6, 0.2
    ic = {f"u[{i}]": math.sin(math.pi * (i - 0.5) / n) for i in range(1, n + 1)}
    r = simulate(f, (0.0, 0.1), initial_conditions=ic, method="LSODA")
    assert r.success
    lam = (1 / dx**2) * (2 * math.cos(math.pi / n) - 2)
    for i in range(1, n + 1):
        idx = next(k for k, nm in enumerate(r.vars) if nm.endswith(f"[{i}]"))
        got = float(np.interp(0.1, r.t, r.y[idx]))
        assert got == pytest.approx(math.exp(lam * 0.1) * math.sin(math.pi * (i - 0.5) / n), rel=1e-6)


# --- width-N halo + vectorized stencil evaluation --------------------------

def _d2_4th_rule():
    """A WENO-width (±2) 4th-order centered 2nd-derivative rule, to exercise the
    width-N ghost halo: needs u[x-2 .. x+2]."""
    ix = lambda k: {"op": "index", "args": ["$u", ("$x" if k == 0 else {"op": "+", "args": ["$x", k]})]}
    num = {"op": "+", "args": [{"op": "*", "args": [-1, ix(-2)]}, {"op": "*", "args": [16, ix(-1)]},
                               {"op": "*", "args": [-30, ix(0)]}, {"op": "*", "args": [16, ix(1)]},
                               {"op": "*", "args": [-1, ix(2)]}]}
    return {"discretizations": {"d2": {"applies_to": {"op": "d2", "args": ["$u"], "dim": "$x"},
        "grid_family": "cartesian", "replacement": {"op": "arrayop", "output_idx": ["$x"], "args": ["$u"],
        "expr": {"op": "/", "args": [num, {"op": "*", "args": [12, {"op": "*", "args": ["dx", "dx"]}]}]}}}}}


def _heat_model(bc, dx=0.1):
    return {"esm": "0.5.0", "metadata": {"name": "Heat"},
        "domains": {"line": {"independent_variable": "t",
            "spatial": {"x": {"min": 0.0, "max": 1.0, "grid_spacing": dx}},
            "boundary_conditions": [{"type": bc, "value": 0.0, "dimensions": ["x"]}]}},
        "models": {"Heat": {"domain": "line", "system_kind": "pde",
            "variables": {"u": {"type": "state", "units": "1"}},
            "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                           "rhs": {"op": "laplacian", "args": ["u"]}}]}}}


def test_width_n_halo_carves_disjoint_band_for_wide_stencil():
    """A ±2 stencil yields a width-2 ghost halo: a disjoint interior band plus
    two boundary cells on each side (vs. the single edge cell a ±1 stencil gets).
    Regions must partition the index box with no overlap."""
    disc = spatial_discretize(_heat_model("dirichlet", dx=0.1), _d2_4th_rule())
    ma = disc["models"]["Heat"]["equations"][0]["rhs"]["expr"]["args"][0]
    regions = [r[0] for r in ma["regions"]]   # 1-D: one [lo,hi] per region
    n = max(hi for lo, hi in regions)
    # interior band is [3, n-2]; boundary cells 1,2 and n-1,n.
    assert [3, n - 2] in regions
    assert [1, 1] in regions and [2, 2] in regions
    assert [n - 1, n - 1] in regions and [n, n] in regions
    # disjoint partition: every cell covered exactly once.
    covered = sorted(c for lo, hi in regions for c in range(lo, hi + 1))
    assert covered == list(range(1, n + 1))


def test_width_n_halo_runs_for_both_bcs():
    """The ±2 stencil integrates end-to-end under Dirichlet and zero-gradient
    BCs — the width-2 boundary cells keep every access in range."""
    for bc in ("dirichlet", "zero_gradient"):
        disc = spatial_discretize(_heat_model(bc, dx=0.1), _d2_4th_rule())
        f = et.load(disc)
        n = max(hi for r in disc["models"]["Heat"]["equations"][0]["rhs"]["expr"]["args"][0]["regions"]
                for (lo, hi) in r)
        ic = {f"u[{i}]": math.sin(math.pi * i / (n + 1)) for i in range(1, n + 1)}
        r = simulate(f, (0.0, 0.02), initial_conditions=ic, method="LSODA", rtol=1e-7, atol=1e-9)
        assert r.success, f"{bc}: {r.message}"


def test_vectorized_stencil_matches_scalar_bit_for_bit():
    """The vectorized makearray materialization must be identical to the scalar
    fallback. Disable the fast path and compare a centered-diffusion run."""
    import earthsci_toolkit.numpy_interpreter as _ni
    disc = spatial_discretize(_heat_model("dirichlet", dx=0.05), {"discretizations": {"d2": _CENTERED_D2}})
    n = max(hi for r in disc["models"]["Heat"]["equations"][0]["rhs"]["expr"]["args"][0]["regions"]
            for (lo, hi) in r)
    ic = {f"u[{i}]": math.sin(math.pi * i / (n + 1)) for i in range(1, n + 1)}

    def solve():
        return simulate(et.load(disc), (0.0, 0.02), initial_conditions=ic,
                        method="LSODA", rtol=1e-6, atol=1e-8)

    rv = solve()
    saved = _ni._materialize_map
    _ni._materialize_map = lambda *a, **k: None      # force scalar fallback
    try:
        rs = solve()
    finally:
        _ni._materialize_map = saved
    assert rv.success and rs.success
    tf = min(rv.t[-1], rs.t[-1])
    av = np.array([np.interp(tf, rv.t, rv.y[i]) for i in range(len(rv.vars))])
    as_ = np.array([np.interp(tf, rs.t, rs.y[i]) for i in range(len(rs.vars))])
    assert np.max(np.abs(av - as_)) == 0.0           # bit-identical


def test_flattened_to_esm_carries_loader_regrid():
    """flattened_to_esm must emit a `regrid` block keyed by loader var so
    re-flatten re-attaches each loader's regrid method; otherwise discretized
    loaders bind at NATIVE resolution and the coupled RHS fails combining a
    millions-of-cells GeoTIFF with a 17x13 ERA5 grid. Regression for the
    'operands could not be broadcast together with shapes (221,) (3301829,)'."""
    from types import SimpleNamespace

    from earthsci_toolkit.spatial_discretize import flattened_to_esm
    from earthsci_toolkit.flatten import LoaderField
    from earthsci_toolkit.esm_types import (
        DataLoader, DataLoaderKind, DataLoaderSource, DataLoaderVariable, RegridSpec,
    )

    loader = DataLoader(
        name="Met", kind=DataLoaderKind.GRID,
        source=DataLoaderSource(url_template="http://x/{date}.nc"),
        variables={"u": DataLoaderVariable(file_variable="u", units="1")},
    )
    lf = LoaderField(name="Met.pl.u", owner="Met", subkey="pl", var="u",
                     loader=loader, cadence="const",
                     regrid=RegridSpec(method="bspline"))
    flat = SimpleNamespace(loader_fields=[lf], state_variables={},
                           observed_variables={}, parameters={}, equations=[])
    domains = {"d": {"spatial": {"x": {"min": 0.0, "max": 1.0,
                                       "grid_spacing": 0.5, "units": "m"}}}}

    model = flattened_to_esm(flat, domains)["models"]["Flattened"]
    assert model["regrid"]["u"]["method"] == "bspline"
