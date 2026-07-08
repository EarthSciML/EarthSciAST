#!/usr/bin/env python3
"""tools/diagnose_geoschem_oom.py  (esm-9ms — Python sibling of mdl-i5j)

Localize the memory peak of running the canonical Python simulation pipeline
on components/gaschem/geoschem_fullchem.esm (272 species × 819 reactions) by
instrumenting it with phase-wise psutil RSS + perf_counter markers. Hard-aborts
above a 6 GB safety budget so the host does not OOM.

DIAGNOSIS ONLY — the script does not propose a fix and does not touch any
other .esm file. Per esm-9ms: lambdify is built with ``cse=False`` (the
``cse=True`` path is its own OOM bomb on this mechanism per esm-c6v; this
diagnostic must NOT trigger it). The compiled RHS is stashed onto
``flat._simulate_compile_cache`` so subsequent simulate() calls reuse it
instead of taking the cse=True path inside ``_compile_flat_rhs``.

Pipeline phases instrumented (all via the canonical pathway —
parse → flatten → lambdify → simulate from earthsci_ast):

  1. imports_loaded             import earthsci_ast + sympy + scipy stack
  2. esm_loaded                 earthsci_ast.load(geoschem_fullchem.esm)
  3. flatten_done               earthsci_ast.flatten(esm_file)
  4. lambdify_no_cse            _flat_to_sympy_rhs + sp.lambdify(cse=False),
                                stashed onto flat._simulate_compile_cache
  5. simulate_clean_troposphere simulate(flat, …) for inline test #1
  6. simulate_polluted_urban    simulate(flat, …) for inline test #2
  7. simulate_upper_troposphere simulate(flat, …) for inline test #3

The deltas across the three simulate phases are the key signal — Python should
show ZERO growth across them, while Julia's signature is monotonic growth.

Invocation:
    python3 tools/diagnose_geoschem_oom.py [path/to/geoschem_fullchem.esm]

Exit codes:
    0  pipeline ran end-to-end
    2  RSS exceeded MAX_RSS_BYTES, or a phase exceeded MAX_PHASE_SECONDS,
       or the .esm fixture could not be located. Partial phase output IS
       the answer.
"""

from __future__ import annotations

import os
import signal
import sys
import time
from pathlib import Path

import psutil

# Capture process-baseline RSS + clock BEFORE importing anything heavy so the
# first phase delta reflects the real cost of `import earthsci_ast` etc.
_PROC = psutil.Process(os.getpid())
_BASELINE_RSS = _PROC.memory_info().rss
_BASELINE_T = time.perf_counter()

MAX_RSS_BYTES = 6_000_000_000
MAX_PHASE_SECONDS = 5 * 60

# Prefer the in-repo package over a `pip install -e` from a sibling worktree
# so the diagnostic always exercises the version it ships alongside.
_THIS = Path(__file__).resolve()
_PKG_SRC = _THIS.parent.parent / "pkg" / "earthsci-ast-py" / "src"
if _PKG_SRC.is_dir():
    sys.path.insert(0, str(_PKG_SRC))


class _Tracker:
    last_rss = _BASELINE_RSS
    last_t = _BASELINE_T


def phase(name: str) -> None:
    rss = _PROC.memory_info().rss
    now = time.perf_counter()
    delta_b = rss - _Tracker.last_rss
    dt = now - _Tracker.last_t
    print(
        f"PHASE {name:<32s} rss={rss/1024/1024:6.0f} MB   "
        f"delta={delta_b/1024/1024:+7.0f} MB   t={dt:6.2f} s",
        flush=True,
    )
    _Tracker.last_rss = rss
    _Tracker.last_t = now
    if rss > MAX_RSS_BYTES:
        print(
            f"ABORT: RSS {rss/1024/1024:.0f} MB exceeded "
            f"{MAX_RSS_BYTES/1024/1024:.0f} MB budget after phase '{name}'",
            flush=True,
        )
        sys.exit(2)


def _alarm_handler(signum, frame):  # noqa: ARG001
    rss = _PROC.memory_info().rss
    print(
        f"ABORT: phase exceeded {MAX_PHASE_SECONDS}s wall "
        f"(rss={rss/1024/1024:.0f} MB) — runaway compile or solver",
        flush=True,
    )
    sys.exit(2)


signal.signal(signal.SIGALRM, _alarm_handler)


def _arm() -> None:
    signal.alarm(MAX_PHASE_SECONDS)


def _disarm() -> None:
    signal.alarm(0)


def _find_esm() -> Path:
    if len(sys.argv) > 1:
        p = Path(sys.argv[1]).resolve()
        if not p.exists():
            print(f"ABORT: argv[1] path not found: {p}", flush=True)
            sys.exit(2)
        return p
    rels = (
        ("EarthSciModels", "components", "gaschem", "geoschem_fullchem.esm"),
        ("EarthSciModels", "refinery", "rig", "components", "gaschem",
         "geoschem_fullchem.esm"),
    )
    for ancestor in (_THIS.parent, *_THIS.parents):
        for rel in rels:
            cand = ancestor.joinpath(*rel)
            if cand.exists():
                return cand.resolve()
    print(
        "ABORT: could not locate geoschem_fullchem.esm in any ancestor; "
        "pass path as argv[1]",
        flush=True,
    )
    sys.exit(2)


# ----- 1. imports_loaded -------------------------------------------------
_arm()
import earthsci_ast as ek  # noqa: E402
from earthsci_ast.simulation import simulate  # noqa: E402
from earthsci_ast.sympy_bridge import (  # noqa: E402
    _LAMBDIFY_MODULES,
    _compile_flat_rhs,
)
_disarm()
phase("imports_loaded")

ESM_PATH = _find_esm()

# ----- 2. esm_loaded -----------------------------------------------------
_arm()
esm_file = ek.load(str(ESM_PATH))
_disarm()
phase("esm_loaded")

RS_NAME = "GEOSChemGasPhase"
rs = esm_file.reaction_systems[RS_NAME]
if not rs.tests:
    print(
        f"ABORT: {ESM_PATH} has no inline tests on {RS_NAME}",
        flush=True,
    )
    sys.exit(2)

# ----- 3. flatten_done ---------------------------------------------------
_arm()
flat = ek.flatten(esm_file)
_disarm()
phase("flatten_done")

# ----- 4. lambdify_no_cse ------------------------------------------------
# Compile with cse=False and stash on the FlattenedSystem so the
# simulate() calls below see a cache hit and skip the cse=True path.
_arm()
_compile_flat_rhs(flat, cse=False)
_disarm()
phase("lambdify_no_cse")

# ----- 5/6/7. simulate_<test_id> ----------------------------------------
for test in rs.tests:
    _arm()
    res = simulate(
        flat,
        tspan=(test.time_span.start, test.time_span.end),
        parameters=dict(test.parameter_overrides),
        initial_conditions=dict(test.initial_conditions),
    )
    _disarm()
    if not res.success:
        print(
            f"NOTE: simulate({test.id}) success=False message={res.message!r}",
            flush=True,
        )
    phase(f"simulate_{test.id}")

print(
    f"\nDONE: final RSS {_PROC.memory_info().rss/1024/1024:.0f} MB across "
    f"{4 + len(rs.tests)} phases",
    flush=True,
)
