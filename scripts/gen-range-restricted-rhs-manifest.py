#!/usr/bin/env python3
"""Write tests/conformance/range_restricted_rhs/manifest.json.

    python3 scripts/gen-range-restricted-rhs-manifest.py           # write it
    python3 scripts/gen-range-restricted-rhs-manifest.py --check   # diff only

The case table below is the source of truth: the documents, decompositions,
selections and expected halo reports. This script derives the tile boxes of
every tiling (1x1, 2x1, 3x2 uneven, a tile narrower than the boundary band, two
tiles sharing one rank storage box) and the seeded lane plans, so that every
binding reads the same explicit boxes and cell lists rather than re-deriving
them. See tests/conformance/range_restricted_rhs/README.md and
CONFORMANCE_SPEC.md §5.49.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITE = os.path.join(ROOT, "tests", "conformance", "range_restricted_rhs")
MANIFEST = os.path.join(SUITE, "manifest.json")

ALL = "all"

# Global extents of the decomposed and face sets each document declares, after
# the case's metaparameters are bound.
EXTENTS = {
    "stencil_1d_centered": {"x": 12},
    "stencil_2d_centered": {"x": 9, "y": 7},
    "observed_chain": {"x": 14},
    "face_state_1d": {"x": 10, "x_nodes": 11},
    "selection_two_operator": {"x": 10},
    "global_horizontal_sum": {"x": 6, "y": 5},
    "global_scalar_state": {"x": 6},
    "esd_ppm_1d_periodic": {"x": 16},
    "esd_ppm_1d_inflow": {"x": 16},
    "esd_heat_1d_zero_flux": {"x": 16},
    "esd_latlon3d_zonal_ppm": {"lon": 16, "lat": 5},
    "esd_latlon3d_meridional_zero_grad": {"lon": 8, "lat": 10},
    "esd_latlon3d_regional_inflow": {"lon": 12, "lat": 9, "lon_nodes": 13, "lat_nodes": 10},
}

DOCS = {
    "stencil_1d_centered": {"document": "fixtures/stencil_1d_centered.esm"},
    "stencil_2d_centered": {"document": "fixtures/stencil_2d_centered.esm"},
    "observed_chain": {"document": "fixtures/observed_chain.esm"},
    "face_state_1d": {"document": "fixtures/face_state_1d.esm"},
    "selection_two_operator": {"document": "fixtures/selection_two_operator.esm"},
    "lanes_pointwise": {"document": "fixtures/lanes_pointwise.esm"},
    "lanes_column": {"document": "fixtures/lanes_column.esm"},
    "global_horizontal_sum": {"document": "fixtures/global_horizontal_sum.esm"},
    "global_scalar_state": {"document": "fixtures/global_scalar_state.esm"},
    "esd_ppm_1d_periodic": {
        "document": "fixtures/esd/problems/advection_1d_ppm_periodic.esm",
        "metaparameters": {"N": 16},
    },
    "esd_ppm_1d_inflow": {
        "document": "fixtures/esd/problems/advection_1d_inflow_ppm.esm",
        "metaparameters": {"N": 16},
    },
    "esd_heat_1d_zero_flux": {
        "document": "fixtures/esd/problems/heat_1d_varcoeff_zero_flux.esm",
        "metaparameters": {"N": 16},
    },
    "esd_latlon3d_zonal_ppm": {
        "document": "fixtures/esd/problems/latlon3d_advection_zonal_ppm.esm",
        "metaparameters": {"NLON": 16},
    },
    "esd_latlon3d_meridional_zero_grad": {
        "document": "fixtures/esd/problems/latlon3d_advection_meridional_zero_grad.esm",
        "metaparameters": {"NLAT": 10},
    },
    "esd_latlon3d_regional_inflow": {
        "document": "fixtures/esd/problems/latlon3d_transport_cwc_regional_inflow.esm"
    },
}


def axis(index_set, period=None):
    return {"index_set": index_set, "period": period}


def dec(axes, faces=()):
    return {"axes": axes, "faces": [list(f) for f in faces]}


def halo(*rows):
    return [{"variable": v, "index_set": s, "lo": lo, "hi": hi} for v, s, lo, hi in rows]


SELECT_ALL = {"writes": ALL, "terms": ALL}

# Tile-partition cases: (case id, document key, selection, decomposition,
# expected halo, covers).
ADV = [{"component": "Adv"}]
CHEM = [{"component": "Chem"}]
EMIS = [{"coupling": 0}]
NO2, O3 = "Chem.NO2", "Chem.O3"

# The halo of the regional-inflow document. Only mq and m are read (through
# q = mq / m); dev is written but never read, and Mx, My are state-free. The
# monotone flux-form PPM divergence reaches three cells low and two high, but
# the inflow slabs [1,1] and [2,2] read q[1..4] and q[1..5], three cells high.
# On a uniform grid those reads carry an exact-zero coefficient, so perturbing
# the state does not see them; the halo counts reads, and a zero times a
# missing or NaN cell is not zero.
REGIONAL_INFLOW_ROWS = [
    ("TransportCWCRegionalInflow.m", "lat", 3, 3),
    ("TransportCWCRegionalInflow.m", "lon", 3, 3),
    ("TransportCWCRegionalInflow.mq", "lat", 3, 3),
    ("TransportCWCRegionalInflow.mq", "lon", 3, 3),
]

TILE_CASES = [
    (
        "stencil_1d_centered",
        "stencil_1d_centered",
        SELECT_ALL,
        dec([axis("x")]),
        halo(("Stencil1D.u", "x", 1, 1)),
        ["tile_partition", "zero_ghost", "region_overwrite"],
    ),
    (
        "stencil_2d_centered",
        "stencil_2d_centered",
        SELECT_ALL,
        dec([axis("x", 9), axis("y")]),
        halo(
            ("Stencil2D.u", "x", 1, 1),
            ("Stencil2D.u", "y", 1, 1),
            ("Stencil2D.v", "x", 0, 0),
            ("Stencil2D.v", "y", 1, 1),
        ),
        ["tile_partition", "explicit_wrap", "zero_ghost"],
    ),
    (
        "observed_chain",
        "observed_chain",
        SELECT_ALL,
        dec([axis("x")]),
        halo(("Chain.u", "x", 3, 3)),
        ["tile_partition", "observed_need_box", "halo_composition"],
    ),
    (
        "face_state_1d",
        "face_state_1d",
        SELECT_ALL,
        dec([axis("x")], [("x_nodes", "x")]),
        halo(("Staggered.U", "x_nodes", 0, 1), ("Staggered.h", "x", 1, 0)),
        ["tile_partition", "face_ownership"],
    ),
    (
        "esd_ppm_1d_periodic",
        "esd_ppm_1d_periodic",
        SELECT_ALL,
        dec([axis("x", 16)]),
        halo(("AdvectionPPM.u", "x", 3, 2)),
        ["tile_partition", "boundary_regions", "explicit_wrap"],
    ),
    (
        "esd_ppm_1d_inflow",
        "esd_ppm_1d_inflow",
        SELECT_ALL,
        dec([axis("x")]),
        halo(("AdvectionPPMInflow.u", "x", 3, 2)),
        ["tile_partition", "boundary_regions", "inflow"],
    ),
    (
        "esd_heat_1d_zero_flux",
        "esd_heat_1d_zero_flux",
        SELECT_ALL,
        dec([axis("x")]),
        halo(("Heat.u", "x", 1, 1)),
        ["tile_partition", "boundary_regions", "no_flux"],
    ),
    (
        "esd_latlon3d_zonal_ppm",
        "esd_latlon3d_zonal_ppm",
        SELECT_ALL,
        dec([axis("lon", 16), axis("lat")], [("lon_nodes", "lon"), ("lat_nodes", "lat")]),
        halo(("ZonalAdvectionPPM3d.u", "lat", 0, 0), ("ZonalAdvectionPPM3d.u", "lon", 3, 2)),
        ["tile_partition", "boundary_regions", "explicit_wrap"],
    ),
    (
        "esd_latlon3d_meridional_zero_grad",
        "esd_latlon3d_meridional_zero_grad",
        SELECT_ALL,
        dec([axis("lon", 8), axis("lat")], [("lon_nodes", "lon"), ("lat_nodes", "lat")]),
        halo(("MeridionalAdvection3d.u", "lat", 1, 1), ("MeridionalAdvection3d.u", "lon", 0, 0)),
        ["tile_partition", "boundary_regions", "zero_gradient"],
    ),
    (
        "esd_latlon3d_regional_inflow",
        "esd_latlon3d_regional_inflow",
        SELECT_ALL,
        dec([axis("lon"), axis("lat")], [("lon_nodes", "lon"), ("lat_nodes", "lat")]),
        halo(*REGIONAL_INFLOW_ROWS),
        [
            "tile_partition",
            "boundary_regions",
            "inflow",
            "halo_operands",
            "face_field",
            "observed_need_box",
        ],
    ),
    (
        "selection_adv_tiles",
        "selection_two_operator",
        {"writes": [NO2, O3], "terms": ADV},
        dec([axis("x")]),
        halo((NO2, "x", 1, 0), (O3, "x", 1, 0)),
        ["tile_partition", "selection"],
    ),
    (
        "selection_emis_tiles",
        "selection_two_operator",
        {"writes": [NO2], "terms": EMIS},
        dec([axis("x")]),
        halo((O3, "x", 0, 0)),
        ["tile_partition", "selection", "aux"],
    ),
    (
        "global_horizontal_sum_uncut",
        "global_horizontal_sum",
        SELECT_ALL,
        dec([axis("y")]),
        halo(("Sum.u", "y", 0, 0)),
        ["tile_partition", "contraction_along_whole_axis"],
    ),
]


def splits(n, parts):
    """Uneven contiguous split of 1..n into `parts` pieces (larger pieces last)."""
    base, extra = divmod(n, parts)
    sizes = [base + (1 if i >= parts - extra else 0) for i in range(parts)]
    out, lo = [], 1
    for s in sizes:
        out.append([lo, lo + s - 1])
        lo += s
    return out


def axis_dilation(h, axes, faces):
    """Per decomposed cell set: the (lo, hi) storage dilation the halo implies."""
    face_of = {f: c for f, c in faces}
    dil = {a["index_set"]: [0, 0] for a in axes}
    for row in h:
        s = row["index_set"]
        if s in dil:
            lo, hi = row["lo"], row["hi"]
            cell = s
        elif s in face_of:
            # Storage faces are the storage cells plus one (RFC §1), so a face
            # reach of hi needs hi - 1 cells beyond the owned ones.
            cell, lo, hi = face_of[s], row["lo"], max(row["hi"] - 1, 0)
        else:
            continue
        d = dil[cell]
        d[0], d[1] = max(d[0], lo), max(d[1], hi)
    return dil


def tile(owned, dil):
    return {
        "owned": {s: list(r) for s, r in owned.items()},
        "storage": {s: [r[0] - dil[s][0], r[1] + dil[s][1]] for s, r in owned.items()},
    }


def tilings(ext, axes, h, faces):
    sets = [a["index_set"] for a in axes]
    dil = axis_dilation(h, axes, faces)
    full = {s: [1, ext[s]] for s in sets}
    a0 = sets[0]
    out = [{"id": "1x1", "tiles": [tile(full, dil)]}]

    def grid(p0, p1):
        r0 = splits(ext[a0], p0)
        rest = sets[1:]
        r1 = splits(ext[rest[0]], p1) if rest else [None]
        tiles = []
        for b in r1:
            for a in r0:
                o = dict(full)
                o[a0] = a
                if rest:
                    o[rest[0]] = b
                tiles.append(tile(o, dil))
        return tiles

    out.append({"id": "2x1", "tiles": grid(2, 1)})
    out.append({"id": "3x2" if len(sets) > 1 else "3", "tiles": grid(3, 2)})
    # One tile narrower than the boundary band: owned 1..2 along the first axis.
    n0 = ext[a0]
    mid = 2 + (n0 - 2) // 2
    narrow = []
    for a in ([1, 2], [3, mid], [mid + 1, n0]):
        o = dict(full)
        o[a0] = a
        narrow.append(tile(o, dil))
    out.append({"id": "narrow", "tiles": narrow})
    # Two tiles of one rank sharing one storage box: the whole domain.
    shared = []
    for a in splits(n0, 2):
        o = dict(full)
        o[a0] = a
        shared.append(
            {
                "owned": {s: list(r) for s, r in o.items()},
                "storage": {s: list(r) for s, r in full.items()},
            }
        )
    out.append({"id": "rank_storage", "tiles": shared, "shared_storage": True})
    return out


def doc_ref(key):
    d = {"document": DOCS[key]["document"]}
    if "metaparameters" in DOCS[key]:
        d["metaparameters"] = DOCS[key]["metaparameters"]
    return d


def tile_cases():
    cases = []
    for cid, key, sel, dc, h, covers in TILE_CASES:
        c = {
            "id": cid,
            "kind": "tile_partition",
            **doc_ref(key),
            "selection": sel,
            "decomposition": dc,
            "halo": h,
            "tilings": tilings(EXTENTS[key], dc["axes"], h, dc["faces"]),
            "covers": covers,
        }
        cases.append(c)
    return cases


def err(code, **detail):
    return {"code": code, **detail}


def box_cases():
    """Single-tile cases: a storage box one cell short, a dead halo left out,
    and every range_box_invalid shape."""
    x = dec([axis("x")])
    return [
        {
            "id": "observed_chain_storage_short",
            "kind": "tile_error",
            **doc_ref("observed_chain"),
            "selection": SELECT_ALL,
            "decomposition": x,
            "tile": {"owned": {"x": [5, 9]}, "storage": {"x": [3, 12]}},
            "expect_error": err(
                "range_halo_insufficient", variable="Chain.u", index_set="x", missing=[2, 2]
            ),
            "covers": ["halo_insufficient"],
        },
        {
            "id": "zonal_ppm_storage_short_across_seam",
            "kind": "tile_error",
            **doc_ref("esd_latlon3d_zonal_ppm"),
            "selection": SELECT_ALL,
            "decomposition": dec([axis("lon", 16), axis("lat")]),
            "tile": {
                "owned": {"lon": [1, 8], "lat": [1, 5]},
                "storage": {"lon": [-1, 10], "lat": [1, 5]},
            },
            "expect_error": err(
                "range_halo_insufficient",
                variable="ZonalAdvectionPPM3d.u",
                index_set="lon",
                missing=[-2, -2],
            ),
            "covers": ["halo_insufficient", "explicit_wrap"],
        },
        {
            "id": "observed_chain_dead_halo_omitted",
            "kind": "tile_ok",
            **doc_ref("observed_chain"),
            "selection": SELECT_ALL,
            "decomposition": x,
            "tile": {"owned": {"x": [1, 4]}, "storage": {"x": [1, 7]}},
            "covers": ["dead_halo"],
        },
        {
            "id": "box_owned_outside_domain",
            "kind": "tile_error",
            **doc_ref("stencil_1d_centered"),
            "selection": SELECT_ALL,
            "decomposition": x,
            "tile": {"owned": {"x": [0, 4]}, "storage": {"x": [-1, 5]}},
            "expect_error": err("range_box_invalid", index_set="x"),
            "covers": ["box_invalid"],
        },
        {
            "id": "box_owned_outside_storage",
            "kind": "tile_error",
            **doc_ref("stencil_1d_centered"),
            "selection": SELECT_ALL,
            "decomposition": x,
            "tile": {"owned": {"x": [3, 6]}, "storage": {"x": [4, 8]}},
            "expect_error": err("range_box_invalid", index_set="x"),
            "covers": ["box_invalid"],
        },
        {
            "id": "box_unknown_index_set",
            "kind": "tile_error",
            **doc_ref("stencil_1d_centered"),
            "selection": SELECT_ALL,
            "decomposition": dec([axis("z")]),
            "tile": {"owned": {"z": [1, 2]}, "storage": {"z": [0, 3]}},
            "expect_error": err("range_box_invalid", index_set="z"),
            "covers": ["box_invalid"],
        },
        {
            "id": "box_face_set_not_against_decomposed_axis",
            "kind": "tile_error",
            **doc_ref("face_state_1d"),
            "selection": SELECT_ALL,
            "decomposition": dec([axis("x")], [("x_nodes", "y")]),
            "tile": {"owned": {"x": [1, 5]}, "storage": {"x": [0, 5]}},
            "expect_error": err("range_box_invalid", index_set="x_nodes"),
            "covers": ["box_invalid"],
        },
    ]


def refusal_cases():
    xy = dec([axis("x"), axis("y")])
    return [
        {
            "id": "global_horizontal_sum_halo",
            "kind": "halo_error",
            **doc_ref("global_horizontal_sum"),
            "selection": SELECT_ALL,
            "decomposition": xy,
            "expect_error": err("range_global_locality", index_set="x"),
            "covers": ["decision_8"],
        },
        {
            "id": "global_horizontal_sum_restrict",
            "kind": "tile_error",
            **doc_ref("global_horizontal_sum"),
            "selection": SELECT_ALL,
            "decomposition": xy,
            "tile": {"owned": {"x": [1, 3], "y": [1, 5]}, "storage": {"x": [1, 6], "y": [1, 5]}},
            "expect_error": err("range_global_locality", index_set="x"),
            "covers": ["decision_8"],
        },
        {
            "id": "global_scalar_state_restrict",
            "kind": "tile_error",
            **doc_ref("global_scalar_state"),
            "selection": SELECT_ALL,
            "decomposition": dec([axis("x")]),
            "tile": {"owned": {"x": [1, 3]}, "storage": {"x": [1, 3]}},
            "expect_error": err("range_global_locality", variable="Scalar.s"),
            "covers": ["decision_8"],
        },
        {
            "id": "global_scalar_state_halo",
            "kind": "halo_ok",
            **doc_ref("global_scalar_state"),
            "selection": SELECT_ALL,
            "decomposition": dec([axis("x")]),
            "halo": halo(("Scalar.u", "x", 0, 0)),
            "covers": ["halo_report"],
        },
    ]


def selection_cases():
    return [
        {
            "id": "selection_sum",
            "kind": "selection_sum",
            **doc_ref("selection_two_operator"),
            "operators": [
                {"name": "adv", "writes": [NO2, O3], "terms": ADV, "aux": []},
                {"name": "chem", "writes": [NO2, O3], "terms": CHEM, "aux": []},
                {"name": "emis", "writes": [NO2], "terms": EMIS, "aux": [O3]},
            ],
            "contributions": {
                O3: [CHEM, ADV],
                NO2: [CHEM, ADV, EMIS],
            },
            "tolerance": {
                "rule": "abs(sum_k G_k - F) <= rel * sum_k abs(G_k), elementwise",
                "rel": 1e-14,
            },
            "covers": ["selection"],
        },
        {
            "id": "selection_writes_incomplete",
            "kind": "selection_error",
            **doc_ref("selection_two_operator"),
            "selection": {"writes": [O3], "terms": CHEM},
            "expect_error": err("range_selection_writes_incomplete", variable=NO2),
            "covers": ["selection"],
        },
        {
            "id": "selection_terms_unmatched_write",
            "kind": "selection_ok",
            **doc_ref("selection_two_operator"),
            "selection": {"writes": [NO2, O3], "terms": EMIS},
            "zero_rows": [O3],
            "aux": [],
            "covers": ["selection"],
        },
    ]


def lane_cases():
    rng = random.Random(540)
    out = []
    # Pointwise: every cell of the 6 x 5 x 4 grid.
    cells = [[i, j, k] for k in range(1, 5) for j in range(1, 6) for i in range(1, 7)]
    perm = cells[:]
    rng.shuffle(perm)
    cap = 64
    batches = [
        {"id": "permutation_1", "cells": perm[:cap], "n": cap},
        {
            "id": "permutation_2",
            "cells": perm[cap:] + [perm[cap]] * (2 * cap - len(perm)),
            "n": len(perm) - cap,
        },
    ]
    real = [rng.choice(cells) for _ in range(17)]
    real += [real[3], real[3], real[10]]
    dup = real + [real[0]] * 4
    batches.append(
        {"id": "duplicates_and_padding", "cells": dup + [dup[0]] * (cap - len(dup)), "n": len(dup)}
    )
    out.append(
        {
            "id": "lanes_pointwise",
            "kind": "lanes",
            **doc_ref("lanes_pointwise"),
            "selection": SELECT_ALL,
            "lane_kind": "cells",
            "lane_sets": ["lon", "lat", "lev"],
            "capacity": cap,
            "batches": batches,
            "negative_control": {"batch": "permutation_1", "swap_lanes": [1, 2]},
            "covers": [
                "lanes",
                "index_derived_reads",
                "level_gate",
                "state_free_observed",
                "array_parameter_affine_read",
            ],
        }
    )
    # Columns: every (lon, lat) column of the 5 x 4 x 6 grid.
    cols = [[i, j] for j in range(1, 5) for i in range(1, 6)]
    perm = cols[:]
    rng.shuffle(perm)
    cap = 8
    batches = [
        {
            "id": f"permutation_{b + 1}",
            "cells": (perm[b * cap : (b + 1) * cap] + [perm[b * cap]] * cap)[:cap],
            "n": len(perm[b * cap : (b + 1) * cap]),
        }
        for b in range(3)
    ]
    real = [rng.choice(cols) for _ in range(4)] + [cols[7], cols[7]]
    batches.append(
        {"id": "duplicates_and_padding", "cells": real + [real[0]] * (cap - len(real)), "n": cap}
    )
    out.append(
        {
            "id": "lanes_column",
            "kind": "lanes",
            **doc_ref("lanes_column"),
            "selection": SELECT_ALL,
            "lane_kind": "columns",
            "lane_sets": ["lon", "lat"],
            "capacity": cap,
            "batches": batches,
            "negative_control": {"batch": "permutation_1", "swap_lanes": [1, 2]},
            "covers": ["lanes", "column", "index_derived_reads"],
        }
    )
    # A lane program over an operator that reads a neighbour is refused.
    out.append(
        {
            "id": "lanes_refuse_stencil",
            "kind": "lanes_error",
            **doc_ref("stencil_1d_centered"),
            "selection": SELECT_ALL,
            "lane_kind": "cells",
            "lane_sets": ["x"],
            "capacity": 4,
            "expect_error": err("compiler_refused_rule"),
            "covers": ["lanes"],
        }
    )
    return out


def build():
    cases = tile_cases() + box_cases() + refusal_cases() + selection_cases() + lane_cases()
    return {
        "category": "range_restricted_rhs",
        "version": "1.0",
        "description": (
            "Range-restricted, operator-restricted right-hand sides (issue #540): operator "
            "selection by per-term provenance, tiles of a horizontal decomposition reading "
            "halo cells from an extended local array, and lanes over a run-time list of "
            "cells or columns. Every comparison is BITWISE against the same binding's "
            "whole-domain evaluation of the same selected program under the same compiler "
            "(native). Generated by scripts/gen-range-restricted-rhs-manifest.py."
        ),
        "spec": [
            "API_SPEC.md §5.8 (Range-restricted right-hand sides)",
            "CONFORMANCE_SPEC.md §5.49",
        ],
        "compiler": "native",
        "bindings_required": ["julia", "rust"],
        "scope_excluded": {
            "python": (
                'No native tile or lane implementation (API_SPEC §5.8, "Range-restricted right-hand sides"): '
                "rhs_program, select, halo, restrict and lanes raise "
                "compiler_unavailable, which pkg/earthsci-ast-py/tests/"
                "test_range_restricted_rhs.py asserts for the first case."
            ),
            "typescript": "No simulator (API_SPEC §3, capability profiles).",
            "go": "No simulator (API_SPEC §3, capability profiles).",
        },
        "state": {
            "generator": "hash01",
            "value": "0.5 + h(v, k)",
            "h": (
                "x = (fnv1a32(v) + 0x9e3779b1 * k) mod 2^32; x ^= x >> 16; "
                "x = (x * 0x85ebca6b) mod 2^32; x ^= x >> 13; "
                "x = (x * 0xc2b2ae35) mod 2^32; x ^= x >> 16; h = x / 2^32"
            ),
            "v": 'the flattened variable name, UTF-8 (e.g. "Chain.u")',
            "k": (
                "the 1-based column-major linear index of the element over the "
                "variable's full declared shape (1 for a 0-d state)"
            ),
            "fnv1a32": "FNV-1a, 32-bit: offset basis 0x811c9dc5, prime 0x01000193",
            "parameters": "document defaults",
            "t": 0.0,
        },
        "fills": {"dead_halo": "NaN", "du_prefill": "NaN"},
        "cases": cases,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    text = json.dumps(build(), indent=1) + "\n"
    if args.check:
        cur = open(MANIFEST).read() if os.path.exists(MANIFEST) else ""
        if cur != text:
            print(f"{MANIFEST} is stale; rerun without --check", file=sys.stderr)
            return 1
        return 0
    with open(MANIFEST, "w") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
