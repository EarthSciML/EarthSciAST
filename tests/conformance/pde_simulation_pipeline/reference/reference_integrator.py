"""Independent reference integrator for the `pde_simulation_pipeline` conformance
category (Phase 0 anchor).

This module is a *binding-independent* re-implementation of the discretized RHS
for the fixture ``tests/valid/advection_reaction_loaded_ic_bc.esm``. It is derived
**only** from that fixture's declared math (its ``reaction_systems.Chemistry``
reactions/parameters and the ``Advection`` model's ``grad_lon_inflow``
expression_template regions) and from the manifest's provider dataset. It does
NOT read, import, or mirror any binding's evaluator source (Julia flatten/
tree_walk/simulate, Python/Rust flatten/simulate). That independence is the whole
point: it is the strong anchor that every binding's discretized RHS and
integrated trajectory are gated against.

--------------------------------------------------------------------------------
The system (3 species x a 4x2 [lon,lat] grid; 24 states)
--------------------------------------------------------------------------------
Grid indices are 1-based: lon i in 1..4 (row), lat j in 1..2 (col).

Per cell (i,j), the 0-D O3-NOx mass-action reactions (k1=0.018, jNO2=0.005):

    r = k1 * NO * O3            (NO + O3 -> NO2)
    p = jNO2 * NO2             (NO2 + hv -> NO + O3)
    D(O3)  = -r + p
    D(NO)  = -r + p
    D(NO2) = +r - p

plus a per-species longitudinal advection contribution ``-u_wind[i,j] * grad_i``,
where ``grad`` is the fixture's two-arg ``grad_lon_inflow`` stencil (makearray
over 3 lon regions; dx=100). For a species field f with western inflow vector
``inflow`` (over lat):

    west face   i=1  (region [[1,1],[1,2]]): (f[i+1,j] - inflow[j]) / (2*dx)
    interior    i=2,3 (region [[2,3],[1,2]]): (f[i+1,j] - f[i-1,j]) / (2*dx)
    east face   i=4  (region [[4,4],[1,2]]): (f[i,j]   - f[i-1,j]) / dx

Sign convention: the model equations are ``D(sp) = (-u_wind) * grad(sp, inflow)``,
so the advective tendency added to each cell is ``-u_wind[i,j] * grad_i[i,j]``.

--------------------------------------------------------------------------------
Inputs (the stub-provider dataset; row=lon, col=lat)
--------------------------------------------------------------------------------
Loaded ICs seed u0 cell-by-cell; wind and per-species inflow are static forcing.
See ``INPUTS`` below. All values come from the manifest `inputs` block, not from
any binding.

--------------------------------------------------------------------------------
Public API
--------------------------------------------------------------------------------
    STATE_ORDER                      documented flattened 24-element order
    rhs(u, t) -> du                  the 24-vector RHS (numpy)
    u0() -> ndarray                  flattened loaded initial condition
    analytic_rhs(state_dict, t=0.0)  {element: value} RHS at a probe state
    trajectory(checkpoints)          {t: {element: value}} tight integration

Dependency-light: numpy only. The integrator is a hand-rolled adaptive
Dormand-Prince (DOPRI5) with embedded 4th/5th-order error control; no scipy.
Running the module as a script regenerates the committed
``advection_reaction_loaded_ic_bc.json`` next to it.
"""

from __future__ import annotations

import json
import os
import numpy as np

# --------------------------------------------------------------------------- #
# Constants (from the fixture's declared math)                                 #
# --------------------------------------------------------------------------- #
K1 = 0.018      # Chemistry.k1  : NO + O3 -> NO2 rate constant
JNO2 = 0.005    # Chemistry.jNO2: NO2 photolysis rate
DX = 100.0      # Advection.dx  : eastward grid spacing
SPECIES = ("O3", "NO", "NO2")
NLON, NLAT = 4, 2

# --------------------------------------------------------------------------- #
# Provider inputs (the manifest `inputs` block; row=lon i, col=lat j)         #
# --------------------------------------------------------------------------- #
INPUTS = {
    "InitialConditions.O3_init":  [[38, 42], [39, 43], [41, 45], [43, 47]],
    "InitialConditions.NO_init":  [[0.10, 0.12], [0.11, 0.13], [0.09, 0.14], [0.12, 0.15]],
    "InitialConditions.NO2_init": [[1.0, 1.2], [1.1, 1.3], [0.9, 1.4], [1.2, 1.5]],
    "Meteorology.u_wind":         [[2.0, 2.2], [2.1, 2.3], [2.2, 2.4], [2.3, 2.5]],
    "BoundaryConditions.O3_inflow":  [35.0, 36.0],
    "BoundaryConditions.NO_inflow":  [0.20, 0.25],
    "BoundaryConditions.NO2_inflow": [1.5, 1.6],
}

# Derived arrays consumed by the RHS.
U_WIND = np.asarray(INPUTS["Meteorology.u_wind"], dtype=float)            # (4,2)
INFLOW = {                                                                 # (2,) each
    "O3":  np.asarray(INPUTS["BoundaryConditions.O3_inflow"], dtype=float),
    "NO":  np.asarray(INPUTS["BoundaryConditions.NO_inflow"], dtype=float),
    "NO2": np.asarray(INPUTS["BoundaryConditions.NO2_inflow"], dtype=float),
}
ICS = {                                                                    # (4,2) each
    "O3":  np.asarray(INPUTS["InitialConditions.O3_init"], dtype=float),
    "NO":  np.asarray(INPUTS["InitialConditions.NO_init"], dtype=float),
    "NO2": np.asarray(INPUTS["InitialConditions.NO2_init"], dtype=float),
}

# --------------------------------------------------------------------------- #
# Flattened state order: species-major, then lon i (1..4), then lat j (1..2)  #
# --------------------------------------------------------------------------- #
STATE_ORDER = [
    f"{sp}[{i},{j}]"
    for sp in SPECIES
    for i in range(1, NLON + 1)
    for j in range(1, NLAT + 1)
]
_INDEX = {name: k for k, name in enumerate(STATE_ORDER)}
_NCELL = NLON * NLAT


# --------------------------------------------------------------------------- #
# Layout helpers                                                              #
# --------------------------------------------------------------------------- #
def unflatten(u):
    """24-vector -> {species: (4,2) array}, matching STATE_ORDER."""
    u = np.asarray(u, dtype=float)
    out = {}
    k = 0
    for sp in SPECIES:
        out[sp] = u[k:k + _NCELL].reshape(NLON, NLAT)
        k += _NCELL
    return out


def flatten(fields):
    """{species: (4,2) array} -> 24-vector, matching STATE_ORDER."""
    return np.concatenate([np.asarray(fields[sp], float).reshape(-1) for sp in SPECIES])


def u0():
    """Flattened initial condition: each species field = its loaded IC, cell by cell."""
    return flatten(ICS)


def state_dict_to_vec(state):
    """{'O3[1,1]': v, ...} -> 24-vector in STATE_ORDER (missing entries -> 0)."""
    u = np.zeros(len(STATE_ORDER), dtype=float)
    for name, val in state.items():
        u[_INDEX[name]] = float(val)
    return u


def vec_to_state_dict(u):
    """24-vector -> {'O3[1,1]': v, ...} in STATE_ORDER."""
    u = np.asarray(u, float)
    return {name: float(u[_INDEX[name]]) for name in STATE_ORDER}


# --------------------------------------------------------------------------- #
# Discretized RHS (the anchor)                                               #
# --------------------------------------------------------------------------- #
def grad_lon(f, inflow):
    """Longitudinal gradient via the fixture's `grad_lon_inflow` stencil.

    f: (4,2) species field. inflow: (2,) western Dirichlet ghost over lat.
    Returns a (4,2) gradient with dx=100:
      west face  i=1 : (f[i+1,j] - inflow[j]) / (2 dx)
      interior   i=2,3: (f[i+1,j] - f[i-1,j]) / (2 dx)
      east face  i=4 : (f[i,j]   - f[i-1,j]) / dx
    (0-based array indices are i-1.)
    """
    f = np.asarray(f, float)
    inflow = np.asarray(inflow, float)
    g = np.empty_like(f)
    g[0, :] = (f[1, :] - inflow) / (2.0 * DX)     # i=1 west Dirichlet
    g[1, :] = (f[2, :] - f[0, :]) / (2.0 * DX)    # i=2 interior central
    g[2, :] = (f[3, :] - f[1, :]) / (2.0 * DX)    # i=3 interior central
    g[3, :] = (f[3, :] - f[2, :]) / DX            # i=4 east one-sided
    return g


def rhs(u, t=0.0):
    """Discretized 24-state RHS f(u, t) -> du (autonomous; t is accepted, ignored)."""
    f = unflatten(u)
    O3, NO, NO2 = f["O3"], f["NO"], f["NO2"]

    # Mass-action reactions (per cell, element-wise on the grid).
    r = K1 * NO * O3
    p = JNO2 * NO2
    dO3 = -r + p
    dNO = -r + p
    dNO2 = r - p

    # Per-species longitudinal advection: -u_wind * grad(species, its inflow).
    dO3 = dO3 - U_WIND * grad_lon(O3, INFLOW["O3"])
    dNO = dNO - U_WIND * grad_lon(NO, INFLOW["NO"])
    dNO2 = dNO2 - U_WIND * grad_lon(NO2, INFLOW["NO2"])

    return flatten({"O3": dO3, "NO": dNO, "NO2": dNO2})


def analytic_rhs(state, t=0.0):
    """RHS evaluated at a probe state dict -> {element: value} in STATE_ORDER."""
    return vec_to_state_dict(rhs(state_dict_to_vec(state), t))


# --------------------------------------------------------------------------- #
# Hand-rolled adaptive Dormand-Prince (DOPRI5) integrator                    #
# --------------------------------------------------------------------------- #
# Classic Dormand-Prince(4)5 tableau. b5 is the 5th-order solution advanced;
# b4 is the embedded 4th-order used only for the local error estimate.
_C = (0.0, 1 / 5, 3 / 10, 4 / 5, 8 / 9, 1.0, 1.0)
_A = (
    (),
    (1 / 5,),
    (3 / 40, 9 / 40),
    (44 / 45, -56 / 15, 32 / 9),
    (19372 / 6561, -25360 / 2187, 64448 / 6561, -212 / 729),
    (9017 / 3168, -355 / 33, 46732 / 5247, 49 / 176, -5103 / 18656),
    (35 / 384, 0.0, 500 / 1113, 125 / 192, -2187 / 6784, 11 / 84),
)
_B5 = (35 / 384, 0.0, 500 / 1113, 125 / 192, -2187 / 6784, 11 / 84, 0.0)
_B4 = (5179 / 57600, 0.0, 7571 / 16695, 393 / 640, -92097 / 339200, 187 / 2100, 1 / 40)


def integrate(f, y0, t0, t1, rtol=1e-11, atol=1e-13, h0=1.0):
    """Adaptive DOPRI5 from t0 to t1; returns y(t1). Lands exactly on t1."""
    t = float(t0)
    y = np.array(y0, dtype=float)
    h = float(h0)
    if t1 == t0:
        return y
    direction = 1.0 if t1 > t0 else -1.0
    h = direction * abs(h)
    while (t1 - t) * direction > 1e-13:
        if (t + h - t1) * direction > 0.0:
            h = t1 - t
        k = [None] * 7
        k[0] = f(y, t)
        for i in range(1, 7):
            ys = y.copy()
            ai = _A[i]
            for jj in range(i):
                ys = ys + h * ai[jj] * k[jj]
            k[i] = f(ys, t + _C[i] * h)
        y5 = y.copy()
        y4 = y.copy()
        for i in range(7):
            y5 = y5 + h * _B5[i] * k[i]
            y4 = y4 + h * _B4[i] * k[i]
        err = y5 - y4
        scale = atol + rtol * np.maximum(np.abs(y), np.abs(y5))
        errnorm = np.sqrt(np.mean((err / scale) ** 2))
        if errnorm <= 1.0 or abs(h) <= 1e-12:
            t = t + h
            y = y5
        # PI-free step-size control with safety + clamped growth/shrink.
        fac = 0.9 * (1.0 / max(errnorm, 1e-16)) ** (1 / 5)
        fac = min(5.0, max(0.2, fac))
        h = h * fac
    return y


def trajectory(checkpoints, rtol=1e-11, atol=1e-13):
    """Integrate from checkpoints[0] (state = u0) through each checkpoint.

    checkpoints: increasing list of times; checkpoints[0] is the initial time.
    Returns {checkpoint_time: {element: value}} in STATE_ORDER.
    """
    ckpts = [float(c) for c in checkpoints]
    out = {}
    y = u0()
    t_prev = ckpts[0]
    out[t_prev] = vec_to_state_dict(y)
    for tc in ckpts[1:]:
        y = integrate(rhs, y, t_prev, tc, rtol=rtol, atol=atol)
        out[tc] = vec_to_state_dict(y)
        t_prev = tc
    return out


# --------------------------------------------------------------------------- #
# RHS probes (independent anchors for the discretized RHS gate)              #
# --------------------------------------------------------------------------- #
def _probe_states():
    """Three probe states: loaded u0, a constant field, and a lon ramp.

    Each exercises a different corner of the RHS:
      * u0_loaded  : the actual initial condition (loaded ICs).
      * const_field: spatially uniform species -> interior/east gradients vanish,
                     but the west-face Dirichlet term (f - inflow)/(2 dx) stays live,
                     isolating the boundary-condition contribution + reactions.
      * lon_ramp   : monotone in lon so every stencil region is non-zero.
    """
    probes = []

    # 1) loaded initial condition
    probes.append(("u0_loaded", 0.0, vec_to_state_dict(u0())))

    # 2) spatially-uniform field
    const = {"O3": 40.0, "NO": 0.1, "NO2": 1.0}
    cfields = {sp: np.full((NLON, NLAT), const[sp]) for sp in SPECIES}
    probes.append(("const_field", 0.0, vec_to_state_dict(flatten(cfields))))

    # 3) longitudinal ramp (varies with i and j so all regions are exercised)
    ramp = {}
    for sp, (base, slope) in {"O3": (30.0, 5.0), "NO": (0.2, 0.05), "NO2": (1.0, 0.2)}.items():
        arr = np.empty((NLON, NLAT))
        for i in range(1, NLON + 1):
            for j in range(1, NLAT + 1):
                arr[i - 1, j - 1] = base + slope * i + 0.1 * j
        ramp[sp] = arr
    probes.append(("lon_ramp", 0.0, vec_to_state_dict(flatten(ramp))))

    return probes


def build_reference():
    """Assemble the committed reference dict (state_order, probes, trajectory)."""
    checkpoints = [0.0, 600.0]
    probes = []
    for pid, t, state in _probe_states():
        probes.append({
            "id": pid,
            "t": t,
            "state": state,
            "analytic_rhs": analytic_rhs(state, t),
        })
    traj = trajectory(checkpoints)
    return {
        "fixture": "advection_reaction_loaded_ic_bc",
        "description": (
            "Independent reference for the pde_simulation_pipeline category. "
            "24-state discretized RHS (3 species x 4x2 lon/lat grid): per-cell "
            "mass-action O3-NOx reactions (k1=0.018, jNO2=0.005) + per-species "
            "longitudinal advection -u_wind*grad with the fixture's grad_lon_inflow "
            "stencil (west Dirichlet from loaded inflow, interior central, east "
            "one-sided; dx=100). Derived from the fixture's declared math ONLY, "
            "independent of every binding's evaluator. Integrated with a hand-rolled "
            "adaptive DOPRI5 (rtol=1e-11, atol=1e-13)."
        ),
        "constants": {"k1": K1, "jNO2": JNO2, "dx": DX},
        "grid": {"lon": NLON, "lat": NLAT, "species": list(SPECIES)},
        "state_order": STATE_ORDER,
        "rhs_probes": probes,
        "trajectory": {
            "checkpoints": checkpoints,
            "reference": {repr(t): vals for t, vals in traj.items()},
        },
    }


def _self_check():
    """Gate G0: reproduce the fixture's committed inline `tests` values."""
    committed = {
        # t = 0 (loaded ICs)
        (0.0, "O3[1,1]"): 38.0,
        (0.0, "O3[4,2]"): 47.0,
        (0.0, "NO[1,1]"): 0.1,
        (0.0, "NO2[3,1]"): 0.9,
        # t = 600
        (600.0, "O3[1,1]"): 34.797506781720664,
        (600.0, "O3[4,2]"): 35.66089795504217,
        (600.0, "NO[1,1]"): 0.01641470334161223,
        (600.0, "NO2[1,1]"): 1.6832850160453867,
        (600.0, "NO2[3,1]"): 1.7093366875798413,
    }
    traj = trajectory([0.0, 600.0])
    ok = True
    for (t, name), expected in committed.items():
        got = traj[t][name]
        aerr = abs(got - expected)
        rerr = aerr / abs(expected) if expected != 0 else aerr
        passed = aerr <= 1e-4 and (expected == 0 or rerr <= 1e-5)
        ok = ok and passed
        flag = "ok " if passed else "FAIL"
        print(f"[{flag}] t={t:>6}  {name:<9} expected={expected:.15g} got={got:.15g} "
              f"abs={aerr:.3e} rel={rerr:.3e}")
    print("Gate G0:", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    _self_check()
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "advection_reaction_loaded_ic_bc.json")
    with open(out_path, "w") as fh:
        json.dump(build_reference(), fh, indent=2)
        fh.write("\n")
    print("wrote", out_path)
