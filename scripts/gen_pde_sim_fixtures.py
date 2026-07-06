#!/usr/bin/env python3
"""Generate the cross-language PDE-simulation conformance fixtures + manifest
(bead ess-fmw).

Each fixture is a **pre-discretized** method-of-lines ESM document: the spatial
operator is already lowered to a full-grid ``arrayop`` whose body is an
``index(makearray(regions, values), ...)`` — exactly the form the existing
``tests/fixtures/arrayop/15,16`` heat fixtures use and that all three
PDE-simulation bindings (Julia / Python / Rust) evaluate natively. The
boundary-cell stencils live in dedicated single-cell makearray regions so the
**BC ghost / makearray path** is exercised, not just the interior stencil.

For every fixture we ALSO assemble the same semi-discrete linear operator as an
explicit dense matrix ``L`` (+ constant vector ``b``):  du/dt = L u + b.  That
matrix is the source of the *independent* analytic anchors the conformance
harness checks the Julia golden against:

    analytic_rhs(u)      = L u + b
    analytic_traj(t)     = expm(L t) (u0 + L^{-1} b) - L^{-1} b   (b == 0 => expm(L t) u0)

The matrix is built from the BC definition directly; the AST stencils are built
separately; agreement between them (verified by the golden self-test) is what
proves the fixtures were authored correctly.

Run:  python3 scripts/gen_pde_sim_fixtures.py
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from scipy.linalg import expm

# Output dirs are resolved relative to the repo root (this script lives in scripts/).
REPO = Path(__file__).resolve().parent.parent
TIER = REPO / "tests" / "conformance" / "pde_simulation"
FIXTURES = TIER / "fixtures"
GOLDEN = TIER / "golden"

# ---------------------------------------------------------------------------
# AST builders (match the JSON shape of tests/fixtures/arrayop/15_*.esm)
# ---------------------------------------------------------------------------


def idx(var, *args):
    return {"op": "index", "args": [var, *args]}


def add(*args):
    return {"op": "+", "args": list(args)}


def mul(*args):
    return {"op": "*", "args": list(args)}


def isub(a, b):  # index arithmetic  a - b
    return {"op": "-", "args": [a, b]}


def iadd(a, b):  # index arithmetic  a + b
    return {"op": "+", "args": [a, b]}


def arrayop_lhs(out_idx, var, ranges):
    return {
        "op": "aggregate",
        "args": [],
        "output_idx": list(out_idx),
        "expr": {"op": "D", "args": [idx(var, *out_idx)], "wrt": "t"},
        "ranges": ranges,
    }


def arrayop_rhs(out_idx, makearray, ranges):
    return {
        "op": "aggregate",
        "args": [],
        "output_idx": list(out_idx),
        "expr": {"op": "index", "args": [makearray, *out_idx]},
        "ranges": ranges,
    }


def makearray(regions, values):
    return {"op": "makearray", "args": [], "regions": regions, "values": values}


# ---------------------------------------------------------------------------
# 1-D diffusion stencils.  kappa = D / dx^2.  Loop variable is "i".
# Interior cell:   kappa * (u[i-1] - 2 u[i] + u[i+1])
# Boundary cells replace the out-of-range ghost with a BC-specific expression.
# ---------------------------------------------------------------------------

I = "i"  # noqa: E741 — index-symbol literal used throughout the stencils
IM1 = isub("i", 1)
IP1 = iadd("i", 1)


def diff_interior(kappa):
    return mul(kappa, add(idx("u", IM1), mul(-2, idx("u", I)), idx("u", IP1)))


def diff_left(kappa, ghost):
    # ghost replaces u[i-1] at the left boundary cell
    return mul(kappa, add(ghost, mul(-2, idx("u", I)), idx("u", IP1)))


def diff_right(kappa, ghost):
    # ghost replaces u[i+1] at the right boundary cell
    return mul(kappa, add(idx("u", IM1), mul(-2, idx("u", I)), ghost))


# BC ghost expressions (functions of the interior trace u[i] / literal cells).
def ghost_dirichlet():  # u_ghost = 0
    return 0


def ghost_zero_gradient():  # u_ghost = u[boundary]  (mirror, du/dn = 0)
    return idx("u", I)


def ghost_neumann(b_flux):  # u_ghost = u[boundary] + b_flux   (const flux)
    return add(idx("u", I), b_flux)


def ghost_robin(r_a, r_b):  # u_ghost = r_a * u[boundary] + r_b
    return add(mul(r_a, idx("u", I)), r_b)


def ghost_periodic_left(n):  # u_ghost = u[N]  (literal index N)
    return idx("u", n)


def ghost_periodic_right():  # u_ghost = u[1]  (literal index 1)
    return idx("u", 1)


# ---------------------------------------------------------------------------
# Operator matrices  du = L u + b   (column order = u[1..N], 0-based rows)
# ---------------------------------------------------------------------------


def diffusion_matrix(n, kappa, bc, *, neumann=(0.5, -0.5), robin=(0.5, 0.3)):
    L = np.zeros((n, n))
    b = np.zeros(n)
    for k in range(n):  # cell k -> u[k+1]
        left_bc = k == 0
        right_bc = k == n - 1
        interior = not (left_bc or right_bc)
        if interior:
            L[k, k - 1] += kappa
            L[k, k] += -2 * kappa
            L[k, k + 1] += kappa
            continue
        # boundary cell: -2 u[k] + (the in-range neighbour) + ghost
        L[k, k] += -2 * kappa
        if left_bc:
            L[k, k + 1] += kappa  # u[i+1] in range
            _ghost_into(L, b, k, k, "left", kappa, n, bc, neumann, robin)
        if right_bc:
            L[k, k - 1] += kappa  # u[i-1] in range
            _ghost_into(L, b, k, k, "right", kappa, n, bc, neumann, robin)
    return L, b


def _ghost_into(L, b, row, cell, side, kappa, n, bc, neumann, robin):
    """Fold a boundary ghost u_ghost into row `row` of L/b.  u_ghost enters the
    stencil with coefficient +kappa."""
    if bc == "dirichlet":
        pass  # ghost = 0
    elif bc == "zero_gradient":
        L[row, cell] += kappa  # ghost = u[cell]
    elif bc == "neumann":
        L[row, cell] += kappa  # ghost = u[cell] + b_flux
        b_flux = neumann[0] if side == "left" else neumann[1]
        b[row] += kappa * b_flux
    elif bc == "robin":
        r_a, r_b = robin
        L[row, cell] += kappa * r_a  # ghost = r_a u[cell] + r_b
        b[row] += kappa * r_b
    elif bc == "periodic":
        wrap = n - 1 if side == "left" else 0  # u[N] for left, u[1] for right
        L[row, wrap] += kappa
    else:
        raise ValueError(bc)


def advection_matrix(n, nu):
    """Upwind (a>0) first-derivative, periodic:  du[i] = -nu (u[i] - u[i-1])."""
    L = np.zeros((n, n))
    for k in range(n):
        L[k, k] += -nu
        L[k, (k - 1) % n] += nu  # periodic wrap on the left
    return L, np.zeros(n)


def diffusion_2d_matrix(n, kappa):
    """5-point Laplacian on an n x n interior grid, homogeneous Dirichlet
    (implicit zero ghost).  Column order = column-major u[i,j], i outer."""
    size = n * n

    def pos(i, j):  # 1-based (i,j) -> 0-based flat, column-major (i outer)
        return (i - 1) * n + (j - 1)

    L = np.zeros((size, size))
    for i in range(1, n + 1):
        for j in range(1, n + 1):
            r = pos(i, j)
            L[r, r] += -4 * kappa
            for ii, jj in ((i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)):
                if 1 <= ii <= n and 1 <= jj <= n:
                    L[r, pos(ii, jj)] += kappa  # else ghost = 0
    return L, np.zeros(size)


# ---------------------------------------------------------------------------
# Fixture assembly
# ---------------------------------------------------------------------------


def names_1d(n):
    return [f"u[{k}]" for k in range(1, n + 1)]


def names_2d(n):
    return [f"u[{i},{j}]" for i in range(1, n + 1) for j in range(1, n + 1)]


def analytic_rhs(L, b, order, state):
    v = np.array([state[name] for name in order], dtype=float)
    dy = L @ v + b
    return {name: float(dy[k]) for k, name in enumerate(order)}


def analytic_traj(L, b, order, u0_dict, t):
    """Exact solution of the linear semi-discrete system du/dt = L u + b at time
    t:  u(t) = expm(L t) u0 + (integral_0^t expm(L s) ds) b.  Computed via the
    Van Loan augmented-matrix identity so it stays exact even when L is singular
    (pure-Neumann / periodic operators have the constant mode in their null
    space, so L^{-1} does not exist):

        expm( [[L, b], [0, 0]] * t ) = [[expm(L t),  phi(t) b], [0, 1]]

    where the top-right column is exactly the forced response."""
    u0 = np.array([u0_dict[name] for name in order], dtype=float)
    n = len(order)
    M = np.zeros((n + 1, n + 1))
    M[:n, :n] = L
    M[:n, n] = b
    E = expm(M * t)
    ut = E[:n, :n] @ u0 + E[:n, n]
    return {name: float(ut[k]) for k, name in enumerate(order)}


def build_1d_diffusion(fid, n, dx, bc, *, neumann=(0.5, -0.5), robin=(0.5, 0.3), t_end=0.05):
    kappa = 1.0 / (dx * dx)
    rng = {"i": [1, n]}
    # makearray regions: full-interior, then single-cell left & right overrides.
    if bc == "dirichlet":
        gl, gr = ghost_dirichlet(), ghost_dirichlet()
    elif bc == "zero_gradient":
        gl, gr = ghost_zero_gradient(), ghost_zero_gradient()
    elif bc == "neumann":
        gl, gr = ghost_neumann(neumann[0]), ghost_neumann(neumann[1])
    elif bc == "robin":
        gl, gr = ghost_robin(robin[0], robin[1]), ghost_robin(robin[0], robin[1])
    elif bc == "periodic":
        gl, gr = ghost_periodic_left(n), ghost_periodic_right()
    else:
        raise ValueError(bc)
    regions = [[[1, n]], [[1, 1]], [[n, n]]]
    values = [diff_interior(kappa), diff_left(kappa, gl), diff_right(kappa, gr)]
    ma = makearray(regions, values)
    model = {
        "tolerance": {"rel": 1e-3, "abs": 0.0},
        "variables": {"u": {"type": "state", "shape": ["i"]}},
        "equations": [
            {
                "lhs": arrayop_lhs(["i"], "u", rng),
                "rhs": arrayop_rhs(["i"], ma, rng),
            }
        ],
    }
    L, b = diffusion_matrix(n, kappa, bc, neumann=neumann, robin=robin)
    order = names_1d(n)
    return _finish(fid, "Diff1D", model, L, b, order, n, dx, bc, t_end, ic_kind="diffusion")


def build_advection(fid, n, dx, a=1.0, t_end=0.1):
    nu = a / dx
    rng = {"i": [1, n]}
    interior = mul(-nu, isub(idx("u", I), idx("u", IM1)))
    left = mul(-nu, isub(idx("u", I), idx("u", n)))  # wrap u[0] -> u[N]
    regions = [[[1, n]], [[1, 1]]]
    values = [interior, left]
    ma = makearray(regions, values)
    model = {
        "tolerance": {"rel": 1e-3, "abs": 0.0},
        "variables": {"u": {"type": "state", "shape": ["i"]}},
        "equations": [
            {
                "lhs": arrayop_lhs(["i"], "u", rng),
                "rhs": arrayop_rhs(["i"], ma, rng),
            }
        ],
    }
    L, b = advection_matrix(n, nu)
    order = names_1d(n)
    return _finish(
        fid, "Advect1D", model, L, b, order, n, dx, "periodic", t_end, ic_kind="advection"
    )


def build_2d_diffusion(fid, n, h, t_end=0.03):
    kappa = 1.0 / (h * h)
    rng = {"i": [1, n], "j": [1, n]}
    # single arrayop, implicit zero ghost on out-of-bounds (fixture-16 style)
    body = mul(
        kappa,
        add(
            idx("u", isub("i", 1), "j"),
            idx("u", iadd("i", 1), "j"),
            idx("u", "i", isub("j", 1)),
            idx("u", "i", iadd("j", 1)),
            mul(-4, idx("u", "i", "j")),
        ),
    )
    model = {
        "tolerance": {"rel": 1e-3, "abs": 0.0},
        "variables": {"u": {"type": "state", "shape": ["i", "j"]}},
        "equations": [
            {
                "lhs": arrayop_lhs(["i", "j"], "u", rng),
                "rhs": {
                    "op": "aggregate",
                    "args": [],
                    "output_idx": ["i", "j"],
                    "expr": body,
                    "ranges": rng,
                },
            }
        ],
    }
    L, b = diffusion_2d_matrix(n, kappa)
    order = names_2d(n)
    return _finish(
        fid, "Diff2D", model, L, b, order, n, h, "dirichlet", t_end, ic_kind="diffusion2d"
    )


def _initial_conditions(order, n, ic_kind):
    """Smooth, fixture-specific IC dict keyed by element name."""
    if ic_kind == "diffusion":  # 1-D: half-sine bump (non-zero interior)
        return {f"u[{k}]": math.sin(math.pi * k / (n + 1)) + 0.25 for k in range(1, n + 1)}
    if ic_kind == "advection":  # 1-D periodic: shifted cosine wave
        return {f"u[{k}]": 1.0 + 0.5 * math.cos(2 * math.pi * (k - 1) / n) for k in range(1, n + 1)}
    if ic_kind == "diffusion2d":  # 2-D: product sine mode
        return {
            f"u[{i},{j}]": math.sin(i * math.pi / (n + 1)) * math.sin(j * math.pi / (n + 1))
            for i in range(1, n + 1)
            for j in range(1, n + 1)
        }
    raise ValueError(ic_kind)


def _rhs_probes(order, n, L, b, ic_kind):
    """const, ramp, and the IC state — each with an independent analytic RHS."""
    probes = {}
    # const = 1 everywhere
    const = {name: 1.0 for name in order}
    probes["const1"] = const
    # ramp:  1-D u[k]=k ; 2-D u[i,j]=i+j
    if ic_kind == "diffusion2d":
        ramp = {}
        for name in order:
            ij = name[2:-1].split(",")
            ramp[name] = float(int(ij[0]) + int(ij[1]))
    else:
        ramp = {name: float(k + 1) for k, name in enumerate(order)}
    probes["ramp"] = ramp
    # the IC itself
    probes["ic"] = _initial_conditions(order, n, ic_kind)
    out = []
    for pid, state in probes.items():
        out.append(
            {"id": pid, "t": 0.0, "state": state, "analytic_rhs": analytic_rhs(L, b, order, state)}
        )
    return out


def _finish(fid, model_name, model, L, b, order, n, spacing, bc, t_end, ic_kind):
    ic = _initial_conditions(order, n, ic_kind)
    out_times = [round(t_end / 2, 6), round(t_end, 6)]
    traj_analytic = {f"{t:g}": analytic_traj(L, b, order, ic, t) for t in out_times}
    esm = {
        "esm": "0.1.0",
        "metadata": {
            "name": fid,
            "description": _describe(fid, n, spacing, bc, ic_kind),
            "authors": ["EarthSciSerialization/polecats/gastown.nux"],
            "tags": ["arrayop", "conformance", "pde", "simulation", bc, ic_kind],
        },
        "models": {model_name: model},
    }
    fixture = {
        "id": fid,
        "path": f"fixtures/{fid}.esm",
        "model": model_name,
        "tags": [ic_kind, bc, f"n{n}"],
        "bc_kind": bc,
        "grid": {"n": n, "spacing": spacing},
        "state_order": order,
        "rhs_probes": _rhs_probes(order, n, L, b, ic_kind),
        "trajectory": {
            "initial_conditions": ic,
            "time_span": {"start": 0.0, "end": t_end},
            "output_times": out_times,
            "analytic": traj_analytic,
        },
        "golden": f"golden/{fid}.json",
    }
    return esm, fixture


def _describe(fid, n, spacing, bc, ic_kind):
    if ic_kind == "advection":
        return (
            f"Discretized 1-D linear advection (upwind, a=1, dx={spacing}, "
            f"nu={1.0 / spacing:g}) on {n} cells, periodic. First-derivative "
            "stencil with a single-cell left makearray region wrapping "
            "u[0]->u[N]. du[i]/dt = -nu (u[i]-u[i-1])."
        )
    if ic_kind == "diffusion2d":
        return (
            f"Discretized 2-D heat equation on a {n}x{n} interior grid "
            f"(h={spacing}, kappa={1.0 / (spacing * spacing):g}) with homogeneous "
            "Dirichlet BCs (implicit zero ghost on out-of-bounds neighbours)."
        )
    return (
        f"Discretized 1-D heat equation on {n} cells (dx={spacing}, "
        f"kappa={1.0 / (spacing * spacing):g}) with {bc} boundary conditions. "
        "Full-grid arrayop; boundary cells use single-cell makearray regions "
        f"with the {bc} ghost expression."
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    FIXTURES.mkdir(parents=True, exist_ok=True)
    GOLDEN.mkdir(parents=True, exist_ok=True)

    specs = [
        build_1d_diffusion("diffusion_1d_dirichlet_n4", 4, 0.2, "dirichlet"),
        build_1d_diffusion("diffusion_1d_neumann_n4", 4, 0.2, "neumann"),
        build_1d_diffusion("diffusion_1d_zero_gradient_n4", 4, 0.2, "zero_gradient"),
        build_1d_diffusion("diffusion_1d_robin_n4", 4, 0.2, "robin"),
        build_1d_diffusion("diffusion_1d_periodic_n4", 4, 0.2, "periodic"),
        build_1d_diffusion("diffusion_1d_periodic_n8", 8, 0.2, "periodic"),
        build_2d_diffusion("diffusion_2d_dirichlet_n3", 3, 0.25),
        build_advection("advection_1d_periodic_n4", 4, 0.25),
    ]

    fixtures_meta = []
    for esm, fixture in specs:
        path = FIXTURES / f"{fixture['id']}.esm"
        path.write_text(json.dumps(esm, indent=2) + "\n")
        fixtures_meta.append(fixture)
        print(f"wrote {path.relative_to(REPO)}  ({len(fixture['state_order'])} cells)")

    manifest = {
        "category": "pde_simulation",
        "version": "1.0",
        "description": (
            "Cross-language PDE-simulation conformance (bead ess-fmw): Julia "
            "(reference), Python, and Rust evaluate the SAME pre-discretized "
            "method-of-lines fixtures and must agree on the discretized RHS f(u,t) "
            "and the integrated trajectory within numeric tolerance. Go and TS are "
            "out of scope (no makearray/spatial lowering, no simulator)."
        ),
        "reference_binding": "julia",
        "bindings_required": ["julia", "python", "rust"],
        "scope_excluded": {
            "go": "rewrite-only port; no makearray lowering / simulator",
            "typescript": "rewrite-only port; no makearray lowering / simulator",
        },
        "tolerances": {
            "rhs_rtol": 1e-9,
            "rhs_atol": 1e-11,
            "traj_golden_rtol": 1e-6,
            "traj_golden_atol": 1e-9,
            "traj_analytic_rtol": 1e-4,
            "traj_analytic_atol": 1e-6,
        },
        "integrators": {
            "julia": {"algorithm": "Tsit5", "reltol": 1e-10, "abstol": 1e-12},
            "python": {"method": "RK45", "rtol": 1e-10, "atol": 1e-12},
            "rust": {"solver": "Erk", "reltol": 1e-10, "abstol": 1e-12},
        },
        "fixtures": fixtures_meta,
    }
    (TIER / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {(TIER / 'manifest.json').relative_to(REPO)}  ({len(fixtures_meta)} fixtures)")


if __name__ == "__main__":
    main()
