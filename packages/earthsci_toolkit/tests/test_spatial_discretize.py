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
    ic = {f"u[{i}]": math.sin(math.pi * i / 5) for i in range(1, 5)}
    r = simulate(f, (0.0, 0.1), initial_conditions=ic, method="LSODA")
    assert r.success
    lam = (1 / 0.2**2) * (2 * math.cos(math.pi / 5) - 2)
    for i in range(1, 5):
        idx = next(k for k, n in enumerate(r.vars) if n.endswith(f"[{i}]"))
        got = float(np.interp(0.1, r.t, r.y[idx]))
        assert got == pytest.approx(math.exp(lam * 0.1) * math.sin(math.pi * i / 5), rel=1e-6)
