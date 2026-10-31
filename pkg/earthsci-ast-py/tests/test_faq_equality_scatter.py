"""The equality-scatter fixtures (``tests/conformance/faq_equality_scatter/``,
esm-spec §4.3.1, "One-pass scatter for an equality filter").

Every fixture is built under ``interpreter`` and ``native``; the right-hand side
at the document's initial state, default parameters and ``t = 0`` must equal the
committed golden BIT FOR BIT under both. The goldens come from the tier's
``generate.py``, a plain Python loop that imports nothing from this package.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast import esm_problem
from earthsci_ast.compiler import use_policy
from earthsci_ast.problem import policy_for

_TIER = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "faq_equality_scatter"
_MANIFEST = json.loads((_TIER / "manifest.json").read_text())


def _golden(v) -> float:
    if isinstance(v, dict):  # the interpreters disagree here today: our own entry
        v = v["python"]
    if isinstance(v, str):
        return {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf}[v]
    return float(v)


def _rhs_by_element(prob) -> dict[str, float]:
    build = prob.build
    y0 = np.asarray(build.y0, dtype=float)
    with use_policy(policy_for(prob)):
        du = np.asarray(build.rhs_function(0.0, y0), dtype=float)
    out: dict[str, float] = {}
    for name, sl in build.state_layout.items():
        short = name.split(".", 1)[1] if "." in name else name
        shape = tuple(build.shapes.get(name, ()))
        vals = du[sl]
        if not shape:
            out[short] = float(np.ravel(vals)[0])
            continue
        arr = vals.reshape(shape)
        for idx in np.ndindex(*shape):
            out[f"{short}[{','.join(str(i + 1) for i in idx)}]"] = float(arr[idx])
    return out


@pytest.mark.parametrize("compiler", ["interpreter", "native"])
@pytest.mark.parametrize("fixture", _MANIFEST["fixtures"], ids=lambda f: f["id"])
def test_rhs_equals_the_naive_golden_bit_for_bit(fixture, compiler) -> None:
    path = str(_TIER / fixture["path"])
    want = {
        k: _golden(v) for k, v in json.loads((_TIER / fixture["golden"]).read_text())["du"].items()
    }
    excluded = fixture["excluded"].get("python")
    try:
        got = _rhs_by_element(esm_problem(path, (0.0, 1.0), compiler=compiler))
    except Exception as err:  # noqa: BLE001 - a refusal is the excluded outcome
        assert excluded, f"{fixture['id']} ({compiler}) raised: {err}"
        return
    bad = sorted(set(got) ^ set(want)) + [
        (k, got[k], w)
        for k, w in sorted(want.items())
        if k in got
        and not (
            math.isnan(got[k])
            if math.isnan(w)
            else np.float64(got[k]).tobytes() == np.float64(w).tobytes()
        )
    ]
    if excluded:
        # The manifest says this binding fails the fixture; a pass means the
        # exclusion is stale and must be removed from generate.py.
        assert bad, (
            f"{fixture['id']} ({compiler}) now passes: remove its python exclusion ({excluded})"
        )
        return
    assert not bad, f"{fixture['id']} ({compiler}): {bad[:6]}"
