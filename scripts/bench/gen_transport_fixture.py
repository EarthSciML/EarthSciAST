#!/usr/bin/env python3
"""Regenerate the ReSEACT Stage-B analytic-winds transport fixture from the
EarthSciDiscretizations exemplar, parameterized by NLEV.

This is a faithful port of reseact.esm/prototypes/transport_3d/gen_t3d.py
(commit 95023a2 era), with three changes:
  1. SRC/OUT/NLEV come from the command line instead of hardcoded paths.
  2. NLEV is a parameter (7 reproduces the prototype's 7x7x7 fixture;
     72 produces the full-column GEOS-FP analytic-winds variant).
  3. The hybrid dA/dB tables are emitted next to the fixture as
     <out>.hybrid_coefs.json (dA/dB of length NLEV) so the bench driver can
     pass them as const_arrays without hardcoding.

Why regenerate instead of loading the committed
reseact.esm/prototypes/transport_3d/transport_3d.esm? That artifact was
regenerated (reseact.esm commit 0fc02f4) for the 3-operand inflow contract
introduced by EarthSciDiscretizations commit e358325 ("promote qbc_* to a rule
param") -- a commit the EarthSciDiscretizations checkout on this machine does
not have. Regenerating from the on-disk exemplar guarantees the fixture and
the rules it imports agree, whichever side of e358325 the checkout is on.
The rules themselves are still imported BY REFERENCE from the live
EarthSciDiscretizations checkout (via ../../../EarthSciDiscretizations/...),
never copied.

Usage:
  gen_transport_fixture.py ESD_ROOT OUT_ESM NLEV
where OUT_ESM must sit exactly three directory levels below a directory that
contains (a symlink to) EarthSciDiscretizations, so the relative refs resolve.
"""
import json
import sys

GEOSFP_72_HYBRID = None  # filled from reseact_3d/hybrid_coefs.json by the caller for NLEV=72

# GEOS-FP hybrid coefficients, edges k=1..8 (k=1 = surface: Ap=0, Bp=1).
# Source: EarthSciModels geosfp.esm P observed (as in gen_t3d.py).
AP7 = [0.0, 4.804826, 659.3752, 1313.48, 1961.311, 2609.201, 3257.081, 3898.201]
BP7 = [1.0, 0.984952, 0.963406, 0.941865, 0.920387, 0.898908, 0.877429, 0.856018]


def main(esd_root, out, nlev, hybrid_json=None):
    NLON = NLAT = 7
    NLEV = int(nlev)
    if NLEV == 7 and hybrid_json is None:
        Ap, Bp = AP7, BP7
    else:
        co = json.load(open(hybrid_json))
        Ap, Bp = co["Ap"], co["Bp"]
        assert len(Ap) == NLEV + 1 and len(Bp) == NLEV + 1, \
            f"hybrid table has {len(Ap)} edges, need NLEV+1={NLEV + 1}"
    dA = [Ap[k] - Ap[k + 1] for k in range(NLEV)]
    dB = [Bp[k] - Bp[k + 1] for k in range(NLEV)]

    SRC = esd_root + "/problems/latlon3d_transport_cwc_regional_inflow.esm"
    RULES = "../../../EarthSciDiscretizations/grids/latlon3d/rules/"

    d = json.load(open(SRC))
    name = list(d["models"])[0]
    m = d["models"][name]

    # 1. rebind every existing import, and ADD the hybrid vertical pair
    B = {"NLON": NLON, "NLAT": NLAT, "NLEV": NLEV}
    for i in m["expression_template_imports"]:
        i["bindings"] = dict(B)
        i["ref"] = RULES + i["ref"].split("/")[-1]
    m["expression_template_imports"] += [
        {"ref": RULES + "ppm_flux_D_lev_mono_hybrid_noflux_bc.esm", "bindings": dict(B)},
        {"ref": RULES + "face_flux_divergence_lev_massform_noflux_bc.esm", "bindings": dict(B)},
    ]
    v = m["variables"]

    # 2. CONUS-centered native GEOS-FP 4x5 slice
    v["lon0_deg"] = {"type": "parameter", "units": "deg", "default": -112.5,
                     "description": "West EDGE of the slice (native GEOS-FP 4x5 cell edge)."}
    v["lat0_deg"] = {"type": "parameter", "units": "deg", "default": 26.0,
                     "description": "Southern-most lat POINT of the slice (native GEOS-FP 4x5 point)."}
    v["dlon_deg"] = {"type": "observed", "units": "deg", "expression": 5.0,
                     "description": "GEOS-FP 4x5 native zonal spacing. Open west/east walls."}
    v["dlat_deg"] = {"type": "observed", "units": "deg", "expression": 4.0,
                     "description": "GEOS-FP 4x5 native meridional spacing. Open south/north walls."}

    def agg(idx, ranges, args, expr):
        return {"op": "aggregate", "output_idx": idx,
                "ranges": {k: {"from": r} for k, r in ranges.items()},
                "args": args, "expr": expr}

    def ix(a, *s):
        return {"op": "index", "args": [a, *s]}

    # 3a. Hybrid coefficient differences as SHAPED PARAMETERS via const_arrays.
    v["dA"] = {"type": "parameter", "units": "Pa", "shape": ["lev"], "default": 0.0,
               "description": "dA[k] = Ap[k]-Ap[k+1], native GEOS-FP hybrid table. Supplied via const_arrays."}
    v["dB"] = {"type": "parameter", "units": "1", "shape": ["lev"], "default": 0.0,
               "description": "dB[k] = Bp[k]-Bp[k+1], native GEOS-FP hybrid table. Supplied via const_arrays."}

    # 3. PS constant for this analytic stage
    PS0 = 101325.0
    v["PS"] = {"type": "observed", "units": "Pa", "shape": ["lon", "lat"],
               "description": "Surface pressure, constant 101325 Pa (analytic Stage-B forcing).",
               "expression": agg(["gi", "gj"], {"gi": "lon", "gj": "lat"}, [], PS0)}

    # 4. dp = dA[k] + dB[k]*PS(i,j)
    v["dp"] = {"type": "observed", "units": "Pa", "shape": ["lon", "lat", "lev"],
               "description": "Hybrid sigma-pressure thickness dp = dA[k] + dB[k]*PS(i,j).",
               "expression": agg(["gi", "gj", "gk"], {"gi": "lon", "gj": "lat", "gk": "lev"},
                                 ["PS", "dA", "dB"],
                                 {"op": "+", "args": [ix("dA", "gk"),
                                                      {"op": "*", "args": [ix("dB", "gk"), ix("PS", "gi", "gj")]}]})}

    # 6. Mz: analytic vertical air-mass flux, vanishing at both walls
    s = {"op": "/", "args": [{"op": "-", "args": ["ck", 1]}, float(NLEV)]}
    v["Mz"] = {"type": "observed", "units": "Pa/s", "shape": ["lon", "lat", "lev_nodes"],
               "description": "Analytic vertical face-normal air-mass flux, positive UPWARD; "
                              "vanishes exactly at surface (k=1) and lid (k=NLEV+1).",
               "expression": agg(["ci", "cj", "ck"], {"ci": "lon", "cj": "lat", "ck": "lev_nodes"}, [],
                                 {"op": "*", "args": [0.05, {"op": "*", "args": [
                                     4.0, s, {"op": "-", "args": [1.0, s]},
                                     {"op": "-", "args": [1.0, {"op": "*", "args": [2.0, s]}]}]}]})}

    # 7. add the vertical term to the three tendency equations
    def Dlev(a):
        return {"op": "D", "args": [a], "wrt": "lev"}

    for e in m["equations"]:
        lhs = e["lhs"]
        if lhs.get("op") != "D" or lhs.get("wrt") != "t":
            continue
        tgt = lhs["args"][0]
        inner = Dlev("Mz") if tgt == "m" else Dlev({"op": "*", "args": ["Mz", "q"]})
        if tgt == "dev":
            e["rhs"]["args"][0]["args"][0]["args"].append(Dlev({"op": "*", "args": ["Mz", "q"]}))
            e["rhs"]["args"][0]["args"][1]["args"].append(Dlev("Mz"))
        else:
            e["rhs"]["args"][0]["args"].append(inner)

    d["metadata"]["name"] = f"ReSEACT_Transport3D_bench_{NLON}x{NLAT}x{NLEV}"
    d["metadata"]["description"] = (
        f"Bench fixture: monotone PPM 3-D transport, {NLON}x{NLAT}x{NLEV} CONUS-centered native "
        "GEOS-FP 4x5 slice, analytic winds/PS, hybrid sigma-pressure vertical. Regenerated from the "
        "EarthSciDiscretizations exemplar by scripts/bench/gen_transport_fixture.py (see header).")
    d["models"] = {"Transport3D": m}
    json.dump(d, open(out, "w"), indent=1)
    json.dump({"dA": dA, "dB": dB}, open(out + ".hybrid_coefs.json", "w"))
    print(f"wrote {out}  (NLEV={NLEV}, imports={len(m['expression_template_imports'])})")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
