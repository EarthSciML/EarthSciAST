"""DENSE-AGGREGATE scaling for the spatial OVERLAP join gate — CONFORMANCE_SPEC
§5.5.6: the gate drives ANY aggregate, not only a ``distinct`` producer.

The Python mirror of the Julia ``vi_overlap_scaling_test.jl`` dense testset. One
geometry (``NCELLS`` unit cells, ``NPTS`` points, each point strictly inside
exactly one cell) read in BOTH orientations, each of which used to walk the full
product and reject every non-candidate tuple with a membership test — and, in
Python, did not run at all: ``_resolve_join`` had no ``overlap`` arm.

  (A) MIRRORED — ``P[p] = Σ_c […]`` reducing over CELLS. Full product
      ``NPTS·NCELLS``; driven, ``NPTS``.
  (B) FORWARD — the projection-pushdown rewrite's own ``E[c] = Σ_r […]`` after
      :func:`desugar_pushdown` re-points it onto the compact support axis and
      gates it on the generated ``pd_cell__*`` envelopes. Full product
      ``|support|·|records|``; driven, ``NPTS``. At isrm.esm scale the same ratio
      is 43,650 against 1520·43,650 = 66.3M.

Each asserts the VISIT COUNT (``broad_phase.ENUM_VISITS``, which the dense path
now increments too) and, independently, the values against a plain-Python
oracle: the driver must remove work without moving a number. The forward case
compares EXACTLY (``==``), not approximately — the driven sequence is an
order-preserving subsequence of the filtered full product, so the ⊕-reduction is
bit-identical, and that is the property the 1e-12 cross-language tolerance rests
on.
"""

from __future__ import annotations

import numpy as np
import pytest

from earthsci_ast import broad_phase
from earthsci_ast.prepare import observed_field, prepare
from earthsci_ast.pushdown_rewrite import desugar_pushdown
from earthsci_ast.simulation_array import BuildInspection

# A 100x50 grid of unit cells with one point in the middle of NPTS of them.
GX, GY = 100, 50
NCELLS = GX * GY
NPTS = 200


def _ix(f, *idx):
    return {"op": "index", "args": [f, *idx]}


def _op(o, *args):
    return {"op": o, "args": list(args)}


def _contains(csym, rsym):
    """The rectangle-containment predicate; cell symbol ``csym``, record ``rsym``."""
    return _op(
        "and",
        _op("<=", _ix("W", csym), _ix("X", rsym)),
        _op("<", _ix("X", rsym), _ix("E", csym)),
        _op("<=", _ix("S", csym), _ix("Y", rsym)),
        _op("<", _ix("Y", rsym), _ix("N", csym)),
    )


@pytest.fixture(scope="module")
def geom():
    """Cell rects, the chosen point cells, and the point coordinates."""
    rng = np.random.default_rng(0xC0FFEE)
    k = np.arange(NCELLS)
    a = k // GY
    b = k % GY
    chosen = rng.permutation(NCELLS)[:NPTS]
    return {
        "W": a.astype(float),
        "S": b.astype(float),
        "E": (a + 1).astype(float),
        "N": (b + 1).astype(float),
        "chosen": chosen,
        "X": (a[chosen] + 0.5).astype(float),
        "Y": (b[chosen] + 0.5).astype(float),
        "cell_a": a,
        "cell_b": b,
    }


def _param(shape):
    return {"type": "parameter", "default": 0.0, "shape": list(shape)}


def _obs(shape, expression):
    """An OBSERVED unknown, in the esm 1.0.0 spelling.

    1.0.0 has no ``observed`` type and no ``expression`` field on a variable:
    the variable is declared ``unknown`` and a bare-variable-LHS equation
    defines it. This helper carries the body under the helper-only key
    ``defined_by``, which :func:`_lift_observed` moves onto the model's
    ``equations`` before the document is handed to ``prepare`` /
    ``desugar_pushdown``.
    """
    return {"type": "unknown", "shape": list(shape), "defined_by": expression}


def _lift_observed(doc):
    """Move every ``defined_by`` body onto its model's ``equations``."""
    for model in (doc.get("models") or {}).values():
        equations = model.setdefault("equations", [])
        for name, var in (model.get("variables") or {}).items():
            body = var.pop("defined_by", None)
            if body is not None:
                equations.append({"lhs": name, "rhs": body})
    return doc


def _observed_body(model, name):
    """The RHS of ``name``'s defining equation -- where an observed unknown's
    expression lives now that the variable carries none."""
    return next(eq["rhs"] for eq in model["equations"] if eq.get("lhs") == name)


# --------------------------------------------------------------------------- #
# (A) MIRRORED orientation — a per-RECORD aggregate reducing over CELLS
# --------------------------------------------------------------------------- #


def test_mirrored_dense_aggregate_is_gate_driven(geom):
    """``P[p] = Σ_{c∈cells} [contains(cell_c, pt_p)] · (W_c + S_c)``.

    One candidate cell per point, so the driver visits NPTS tuples against a
    NPTS·NCELLS full product — and the values equal the oracle EXACTLY (one
    surviving term per record either way)."""
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "dense_overlap_mirror"},
        "index_sets": {
            "points": {"kind": "interval", "size": NPTS},
            "cells": {"kind": "interval", "size": NCELLS},
        },
        "models": {
            "Mirror": {
                "variables": {
                    "X": _param(["points"]),
                    "Y": _param(["points"]),
                    "W": _param(["cells"]),
                    "S": _param(["cells"]),
                    "E": _param(["cells"]),
                    "N": _param(["cells"]),
                    "P": _obs(
                        ["points"],
                        {
                            "op": "aggregate",
                            "semiring": "sum_product",
                            "output_idx": ["p"],
                            "ranges": {
                                "p": {"from": "points"},
                                "c": {"from": "cells"},
                            },
                            "join": [
                                {
                                    "overlap": {
                                        "src_env": ["X", "Y"],
                                        "tgt_env": ["W", "S", "E", "N"],
                                        "eps": 0.0,
                                    }
                                }
                            ],
                            "args": ["W", "S", "E", "N", "X", "Y"],
                            "expr": _op(
                                "*",
                                _op("ifelse", _contains("c", "p"), 1.0, 0.0),
                                _op("+", _ix("W", "c"), _ix("S", "c")),
                            ),
                        },
                    ),
                },
                "equations": [],
            }
        },
    }
    _lift_observed(doc)
    # Const arrays ride the FLATTENED spelling (`flatten` prefixes every
    # variable with its owning model); the gate's env factors keep the bare
    # authored names, which is the reconciliation `_scoped_array_name` performs.
    ca = {f"Mirror.{k}": geom[k] for k in ("X", "Y", "W", "S", "E", "N")}

    broad_phase.ENUM_VISITS[0] = 0
    prep = prepare(doc, const_arrays=ca, model_name="Mirror")
    got = observed_field(prep, "P")
    visits = broad_phase.ENUM_VISITS[0]

    oracle = (geom["cell_a"][geom["chosen"]] + geom["cell_b"][geom["chosen"]]).astype(float)
    assert got.shape == (NPTS,)
    # EXACT — one surviving term per record whether driven or filtered.
    assert np.array_equal(got, oracle)
    # One candidate per point => the driver visits NPTS tuples, not NPTS*NCELLS.
    assert visits == NPTS, f"expected {NPTS} candidate-driven visits, got {visits}"
    assert visits < NPTS * NCELLS // 1000, "the gate must not walk the full product"


# --------------------------------------------------------------------------- #
# (B) FORWARD orientation, through the pushdown REWRITE
# --------------------------------------------------------------------------- #


def test_forward_rewritten_binning_aggregate_is_gate_driven(geom):
    """``E[c] = Σ_{r∈points} [contains(cell_c, pt_r)] · annual_r`` after
    :func:`desugar_pushdown` re-points it onto ``pd_support__cells`` and attaches
    the derived gate over the generated ``pd_cell__*`` envelopes."""
    annual = np.arange(1.0, NPTS + 1.0)
    sr = np.array([[float((i % 7) + j) for j in range(2)] for i in range(NCELLS)])
    binagg = {
        "op": "aggregate",
        "output_idx": ["c"],
        "reduce": "+",
        "ranges": {"c": {"from": "cells"}, "r": {"from": "points"}},
        "args": ["W", "S", "E", "N", "X", "Y", "annual"],
        "expr": _op(
            "*",
            _op("ifelse", _contains("c", "r"), 1.0, 0.0),
            _ix("annual", "r"),
        ),
    }
    concagg = {
        "op": "aggregate",
        "output_idx": ["rcv"],
        "reduce": "+",
        "ranges": {"s": {"from": "cells"}, "rcv": {"from": "rcv_cells"}},
        "args": ["SR", "Emis"],
        "expr": _op("*", _ix("SR", "s", "rcv"), _ix("Emis", "s")),
    }
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "dense_overlap_forward"},
        "index_sets": {
            "points": {"kind": "interval", "size": NPTS},
            "cells": {"kind": "interval", "size": NCELLS},
            "rcv_cells": {"kind": "interval", "size": 2},
        },
        "models": {
            "Fwd": {
                "variables": {
                    "X": _param(["points"]),
                    "Y": _param(["points"]),
                    "annual": _param(["points"]),
                    "W": _param(["cells"]),
                    "S": _param(["cells"]),
                    "E": _param(["cells"]),
                    "N": _param(["cells"]),
                    "SR": _param(["cells", "rcv_cells"]),
                    "Emis": _obs(["cells"], binagg),
                    "conc": _obs(["rcv_cells"], concagg),
                },
                "equations": [],
            }
        },
    }
    _lift_observed(doc)

    rw = desugar_pushdown(doc, "Fwd")
    assert rw is not doc
    emis_expr = _observed_body(rw["models"]["Fwd"], "Emis")
    # The rewritten binning aggregate carries the DERIVED gate, over the
    # generated COMPACT-axis envelopes — not the full-grid rects.
    assert "join" in emis_expr
    ov = emis_expr["join"][0]["overlap"]
    assert ov["src_env"] == ["X", "Y"]
    assert ov["tgt_env"] == [
        "pd_cell__cells__W",
        "pd_cell__cells__S",
        "pd_cell__cells__E",
        "pd_cell__cells__N",
    ]
    assert ov["eps"] == 0.0

    ca = {k: geom[k] for k in ("X", "Y", "W", "S", "E", "N")}
    ca["annual"] = annual
    ca["SR"] = sr

    insp = BuildInspection()
    broad_phase.ENUM_VISITS[0] = 0
    # `prepare` runs the SAME rewrite itself (and aliases the bare authored
    # const-array names onto the flattened spellings while doing it).
    prep = prepare(doc, const_arrays=ca, model_name="Fwd", inspect=insp, pushdown_rewrite=True)
    field = observed_field(prep, "Emis")
    visits = broad_phase.ENUM_VISITS[0]

    n_support = prep.build.derived_extents["pd_faq__cells"]
    assert n_support == NPTS  # distinct cells, one point each
    assert field.shape == (n_support,)
    # Every record contributes its `annual` to exactly one support cell.
    assert field.sum() == annual.sum()
    # `visits` covers the producer's own drive AND the rewritten aggregate's:
    # NPTS each. Undriven, the same pair would walk NPTS (the producer already
    # drove before this change) + n_support*NPTS = 40,200 tuples; at isrm.esm
    # scale the rewritten aggregate alone is 1520*43,650 = 66.3M.
    assert visits == 2 * NPTS, f"expected {2 * NPTS} candidate-driven visits, got {visits}"
    undriven = NPTS + n_support * NPTS
    assert visits < undriven // 50, "the dense path must not fall back to the product"


# --------------------------------------------------------------------------- #
# IDENTITY FILL (§5.5.6, normative)
# --------------------------------------------------------------------------- #


def test_output_position_with_no_candidate_is_the_semiring_identity():
    """A record outside the grid is never visited by the driver, and MUST come
    out as 0̄ — not a hole, not NaN, not a stale buffer value."""
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "dense_overlap_identity_fill"},
        "index_sets": {
            "points": {"kind": "interval", "size": 3},
            "cells": {"kind": "interval", "size": 2},
        },
        "models": {
            "Fill": {
                "variables": {
                    # p1 in cell 1, p2 in cell 2, p3 outside BOTH.
                    "X": _param(["points"]),
                    "Y": _param(["points"]),
                    "W": _param(["cells"]),
                    "S": _param(["cells"]),
                    "E": _param(["cells"]),
                    "N": _param(["cells"]),
                    "P": _obs(
                        ["points"],
                        {
                            "op": "aggregate",
                            "semiring": "sum_product",
                            "output_idx": ["p"],
                            "ranges": {
                                "p": {"from": "points"},
                                "c": {"from": "cells"},
                            },
                            "join": [
                                {
                                    "overlap": {
                                        "src_env": ["X", "Y"],
                                        "tgt_env": ["W", "S", "E", "N"],
                                        "eps": 0.0,
                                    }
                                }
                            ],
                            "args": ["W", "S", "E", "N", "X", "Y"],
                            "expr": _op(
                                "*",
                                _op("ifelse", _contains("c", "p"), 1.0, 0.0),
                                _op("+", _ix("W", "c"), 7.0),
                            ),
                        },
                    ),
                },
                "equations": [],
            }
        },
    }
    _lift_observed(doc)
    ca = {
        "Fill.X": np.array([0.5, 1.5, 99.0]),
        "Fill.Y": np.array([0.5, 0.5, 99.0]),
        "Fill.W": np.array([0.0, 1.0]),
        "Fill.S": np.array([0.0, 0.0]),
        "Fill.E": np.array([1.0, 2.0]),
        "Fill.N": np.array([1.0, 1.0]),
    }
    prep = prepare(doc, const_arrays=ca, model_name="Fill")
    got = observed_field(prep, "P")
    assert np.array_equal(got, np.array([7.0, 8.0, 0.0]))


# --------------------------------------------------------------------------- #
# The `pairs` drive shape — both gated symbols contracted on a DENSE node
# --------------------------------------------------------------------------- #


def test_scalar_reduction_drives_from_the_candidate_pairs(geom):
    """``T = Σ_{p,c} [contains(cell_c, pt_p)] · (W_c + S_c)`` — a dense scalar
    reduction whose two contracted axes are exactly the two gated ones. §5.5.6
    pins this as the ``pairs`` shape: bind both from the sorted candidate pairs,
    which is a MUST-drive shape even though the node is not a producer."""
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "dense_overlap_pairs"},
        "index_sets": {
            "points": {"kind": "interval", "size": NPTS},
            "cells": {"kind": "interval", "size": NCELLS},
        },
        "models": {
            "Pairs": {
                "variables": {
                    "X": _param(["points"]),
                    "Y": _param(["points"]),
                    "W": _param(["cells"]),
                    "S": _param(["cells"]),
                    "E": _param(["cells"]),
                    "N": _param(["cells"]),
                    "T": {
                        "type": "unknown",
                        "defined_by": {
                            "op": "aggregate",
                            "semiring": "sum_product",
                            "output_idx": [],
                            "ranges": {
                                "p": {"from": "points"},
                                "c": {"from": "cells"},
                            },
                            "join": [
                                {
                                    "overlap": {
                                        "src_env": ["X", "Y"],
                                        "tgt_env": ["W", "S", "E", "N"],
                                        "eps": 0.0,
                                    }
                                }
                            ],
                            "args": ["W", "S", "E", "N", "X", "Y"],
                            "expr": _op(
                                "*",
                                _op("ifelse", _contains("c", "p"), 1.0, 0.0),
                                _op("+", _ix("W", "c"), _ix("S", "c")),
                            ),
                        },
                    },
                },
                "equations": [],
            }
        },
    }
    _lift_observed(doc)
    ca = {f"Pairs.{k}": geom[k] for k in ("X", "Y", "W", "S", "E", "N")}

    broad_phase.ENUM_VISITS[0] = 0
    prep = prepare(doc, const_arrays=ca, model_name="Pairs")
    got = observed_field(prep, "T")
    visits = broad_phase.ENUM_VISITS[0]

    oracle = float((geom["cell_a"][geom["chosen"]] + geom["cell_b"][geom["chosen"]]).sum())
    assert got == pytest.approx(oracle, rel=0, abs=0)
    assert visits == NPTS, f"expected {NPTS} candidate-driven visits, got {visits}"
    assert visits < NPTS * NCELLS // 1000


# --------------------------------------------------------------------------- #
# ORDER PRESERVATION — the driven walk is BIT-IDENTICAL, not merely close
# --------------------------------------------------------------------------- #


def test_driven_reduction_is_bit_identical_to_the_membership_tested_product(monkeypatch):
    """The driver may only change the enumeration EXTENT, never the
    ⊕-accumulation ORDER.

    Same node, evaluated twice: once driven, once with the planner forced to
    decline (``none``) so the untouched full product runs and every tuple takes
    the membership test instead. The terms the driver drops are exactly the
    gate-rejected ones, each contributing the semiring identity, and the
    survivors keep their relative order — so the two float sums must be EQUAL
    BIT FOR BIT, not merely within tolerance. The repo's cross-language
    tolerance is 1e-12 against a measured 3.1e-15 spread; reassociating a
    many-term sum would blow that.

    The summands are irrational, and each output cell reduces ~25 of them, so a
    reassociation would show.
    """
    ncell, npt = 16, 400
    rng = np.random.default_rng(1234)
    w = np.arange(ncell, dtype=float)
    e = w + 1.0
    s = np.zeros(ncell)
    n = np.ones(ncell)
    px = rng.uniform(0.0, float(ncell), npt)
    py = rng.uniform(0.0, 1.0, npt)
    vals = np.sqrt(np.arange(1.0, npt + 1.0)) * np.pi

    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "dense_overlap_order"},
        "index_sets": {
            "points": {"kind": "interval", "size": npt},
            "cells": {"kind": "interval", "size": ncell},
        },
        "models": {
            "Ord": {
                "variables": {
                    "X": _param(["points"]),
                    "Y": _param(["points"]),
                    "V": _param(["points"]),
                    "W": _param(["cells"]),
                    "S": _param(["cells"]),
                    "E": _param(["cells"]),
                    "N": _param(["cells"]),
                    "B": _obs(
                        ["cells"],
                        {
                            "op": "aggregate",
                            "semiring": "sum_product",
                            "output_idx": ["c"],
                            "ranges": {
                                "c": {"from": "cells"},
                                "r": {"from": "points"},
                            },
                            "join": [
                                {
                                    "overlap": {
                                        "src_env": ["X", "Y"],
                                        "tgt_env": ["W", "S", "E", "N"],
                                        "eps": 0.0,
                                    }
                                }
                            ],
                            "args": ["W", "S", "E", "N", "X", "Y", "V"],
                            "expr": _op(
                                "*",
                                _op("ifelse", _contains("c", "r"), 1.0, 0.0),
                                _ix("V", "r"),
                            ),
                        },
                    ),
                },
                "equations": [],
            }
        },
    }
    _lift_observed(doc)
    ca = {
        "Ord.X": px,
        "Ord.Y": py,
        "Ord.V": vals,
        "Ord.W": w,
        "Ord.S": s,
        "Ord.E": e,
        "Ord.N": n,
    }

    broad_phase.ENUM_VISITS[0] = 0
    driven = observed_field(prepare(doc, const_arrays=ca, model_name="Ord"), "B")
    driven_visits = broad_phase.ENUM_VISITS[0]

    # Force the planner to decline: the SAME node now walks the full product and
    # membership-tests every tuple, exactly as it did before this change.
    real_plan = broad_phase.overlap_drive_plan
    monkeypatch.setattr(broad_phase, "overlap_drive_plan", lambda *a, **k: ("none",))
    broad_phase.ENUM_VISITS[0] = 0
    undriven = observed_field(prepare(doc, const_arrays=ca, model_name="Ord"), "B")
    undriven_visits = broad_phase.ENUM_VISITS[0]
    monkeypatch.setattr(broad_phase, "overlap_drive_plan", real_plan)

    assert undriven_visits == ncell * npt  # the untouched full product
    assert driven_visits == npt  # one candidate cell per point
    assert np.array_equal(driven, undriven), "the driver reassociated the ⊕-fold"
    # ...and the aggregate really is doing multi-term sums, so the check bites.
    assert (driven != 0.0).all()
    assert driven.sum() == pytest.approx(vals.sum(), rel=1e-12)
