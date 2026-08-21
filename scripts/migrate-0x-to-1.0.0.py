#!/usr/bin/env python3
"""Migrate a corpus of 0.x `.esm` documents to esm 1.0.0.

esm 1.0.0 is a clean break with no deprecation path (see the comment above
`_CURRENT_VERSION` in `earthsci_ast/parse.py`): a major-0 document is rejected
outright, so every file in a downstream corpus has to move at once. This tool
does the part of that move that is MECHANICAL and leaves the part that needs
semantic judgement alone, reporting it instead.

What it rewrites
----------------
* `"esm": "0.x.y"` -> `"1.0.0"`.
* `"type": "state"` -> `"unknown"`.
* `"type": "observed"` -> `"unknown"`, with the variable's `expression` moved
  out to a bare-variable-LHS equation `{"lhs": <name>, "rhs": <expression>}`
  appended to the owning model's `equations` in DECLARATION order. From 1.0.0
  an unknown's behaviour is stated by `equations` and nowhere else, and the
  variable `expression` field is gone (esm-spec §6.3.1).
* `examples` -> `analyses` on a model or reaction system, including inline
  `subsystems` children. A separate pre-1.0.0 rename (esm-spec §6.7), but both
  containers are `additionalProperties: false`, so a 0.4-era document carrying
  the old key is rejected just as hard as one carrying `state`.

Everything above recurses through `subsystems`: an inline child model is a
Model, and the 0.x corpus nests them several deep.

What it refuses to touch, and reports
-------------------------------------
* `data_loaders`: 1.0.0 demotes a loader from a component to a document-scoped
  `data_sources` registry entry whose `variables` map is deleted, each former
  loader variable becoming a PARAMETER on the model that consumes it carrying
  `update: {kind: "data", source: ..., from: {...}}`. Which model consumes
  which field, and which coupling entries existed only to wire the two
  together and must therefore be deleted, is not derivable from the loader
  document.
* `functional_affect` / `discrete_parameters` on events: parameter mutation
  moves onto the parameter as an ordered `update` array.
* `"type"` values that were never valid in any version (e.g. `"variable"`):
  these documents never passed schema validation, so guessing an intent here
  would launder a pre-existing defect into a migration.

Formatting
----------
A file whose structure does not change is edited as TEXT so its existing
formatting survives and its diff stays one line per variable. Only a file that
actually gains equations is rewritten through JSON, at its own detected indent.
Every text edit is verified by re-parsing and comparing against the intended
JSON transform, so a `"type": "state"` occurring inside a description string
cannot be silently corrupted.

Usage
-----
    migrate-0x-to-1.0.0.py --report-only <root> [<root> ...]
    migrate-0x-to-1.0.0.py --write <root> [--skip archive] [--skip tests/foo]
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
from collections import Counter, defaultdict

TARGET_VERSION = "1.0.0"

# Containers that own a `variables` map AND an `equations` list.
_EQUATION_OWNERS = ("models", "reaction_systems")


def esm_files(root: str, skip: tuple[str, ...] = ()) -> list[str]:
    out: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", ".claude", "__pycache__")]
        rel = os.path.relpath(dirpath, root)
        if any(rel == s or rel.startswith(s + os.sep) for s in skip):
            continue
        out += [os.path.join(dirpath, f) for f in filenames if f.endswith(".esm")]
    return sorted(out)


def detect_indent(text: str) -> int:
    """Indent width of the first indented line, defaulting to 2."""
    for line in text.split("\n")[1:]:
        stripped = line.lstrip(" ")
        if stripped and stripped != line:
            return len(line) - len(stripped)
    return 2


def transform(doc: dict) -> tuple[dict, Counter, list[str]]:
    """Return (new_doc, counts, blockers). Pure; does not mutate `doc`."""
    out = copy.deepcopy(doc)
    counts: Counter = Counter()
    blockers: list[str] = []

    if out.get("esm") != TARGET_VERSION:
        counts["version_bumped"] += 1
    if "esm" not in out:
        blockers.append("no `esm` version key")
    out["esm"] = TARGET_VERSION

    def migrate_owner(owner: dict, where: str) -> None:
        """Rewrite one model / reaction system in place, then its subsystems.

        `subsystems` values are themselves Models (or SubsystemRefs, which carry
        no variables), so an inline child model's `state` / `observed` variables
        are only reached by recursing — the 0.x corpus nests these several deep.
        """
        if not isinstance(owner, dict):
            return
        # §6.7 `examples` became `analyses` (esm-spec commit 6b8d5a6c5): a pure
        # key rename with an unchanged item shape, on both Model and
        # ReactionSystem. Both are `additionalProperties: false`, so a document
        # still carrying the old key is REJECTED, not silently ignored.
        if "examples" in owner:
            if "analyses" in owner:
                blockers.append(f"{where}: both `examples` and `analyses` are present")
            else:
                owner["analyses"] = owner.pop("examples")
                counts["examples_renamed"] += 1
        if isinstance(owner.get("variables"), dict):
            appended = []
            for var_name, var in owner["variables"].items():
                if not isinstance(var, dict):
                    blockers.append(f"{where}.variables.{var_name} is not an object")
                    continue
                vtype = var.get("type")
                if vtype == "state":
                    var["type"] = "unknown"
                    counts["state_renamed"] += 1
                elif vtype == "observed":
                    var["type"] = "unknown"
                    counts["observed_converted"] += 1
                    if "expression" in var:
                        appended.append({"lhs": var_name, "rhs": var.pop("expression")})
                    else:
                        blockers.append(
                            f"{where}.variables.{var_name}: observed with no `expression`"
                        )
                elif vtype in ("unknown", "parameter"):
                    pass
                else:
                    blockers.append(
                        f"{where}.variables.{var_name}: `type: {vtype!r}` is not a 0.x variable type "
                        f"(0.x allowed state/parameter/observed/brownian/discrete) — this "
                        f"document never validated"
                    )
                if "expression" in var and var.get("type") != "unknown":
                    blockers.append(
                        f"{where}.variables.{var_name}: `expression` on a {vtype!r} variable"
                    )
            if appended:
                owner.setdefault("equations", []).extend(appended)
                counts["equations_appended"] += len(appended)
        for child_name, child in (owner.get("subsystems") or {}).items():
            migrate_owner(child, f"{where}.subsystems.{child_name}")

    for owner_key in _EQUATION_OWNERS:
        for owner_name, owner in (out.get(owner_key) or {}).items():
            migrate_owner(owner, f"{owner_key}.{owner_name}")

    if "data_loaders" in out:
        n_vars = sum(
            len(loader.get("variables") or {})
            for loader in out["data_loaders"].values()
            if isinstance(loader, dict)
        )
        blockers.append(
            f"`data_loaders` ({len(out['data_loaders'])} loader(s), {n_vars} loader "
            f"variable(s)) — needs the data_sources conversion, done by hand"
        )
        for lname, loader in out["data_loaders"].items():
            if isinstance(loader, dict):
                extra = set(loader) - {
                    "kind",
                    "source",
                    "temporal",
                    "determinism",
                    "reader_options",
                    "select",
                    "record_filter",
                    "extent",
                    "reference",
                    "metadata",
                    "variables",
                }
                if extra:
                    blockers.append(
                        f"data_loaders.{lname}: key(s) {sorted(extra)} have no home on "
                        f"the 1.0.0 DataSource (additionalProperties: false)"
                    )

    blob = json.dumps(out)
    for removed in ("functional_affect", "discrete_parameters"):
        if f'"{removed}"' in blob:
            blockers.append(f"`{removed}` is removed in 1.0.0 — see ParameterUpdate")

    return out, counts, blockers


_TYPE_RE = re.compile(r'("type"\s*:\s*")(state|observed)(")')
_VERSION_RE = re.compile(r'("esm"\s*:\s*")\d+\.\d+\.\d+(")')


def text_rewrite(text: str) -> str:
    text = _VERSION_RE.sub(rf"\g<1>{TARGET_VERSION}\g<2>", text, count=1)
    return _TYPE_RE.sub(r"\g<1>unknown\g<3>", text)


def migrate_file(path: str, write: bool) -> dict:
    with open(path, encoding="utf-8") as fh:
        original_text = fh.read()
    try:
        doc = json.loads(original_text)
    except Exception as exc:  # noqa: BLE001 - reported, not raised
        return {
            "path": path,
            "error": f"JSON parse failed: {exc}",
            "blockers": [],
            "counts": Counter(),
        }

    target, counts, blockers = transform(doc)
    if target == doc:
        return {"path": path, "changed": False, "blockers": blockers, "counts": counts}

    def as_json() -> str:
        return json.dumps(target, indent=detect_indent(original_text), ensure_ascii=False) + "\n"

    if counts["equations_appended"] or counts["examples_renamed"]:
        # Structure changed: rewrite through JSON at the file's own indent.
        new_text, mode = as_json(), "json"
    else:
        new_text, mode = text_rewrite(original_text), "text"
        # Verify the text edit produced EXACTLY the intended transform. A
        # description that quotes the literal `"type": "state"` (several
        # migration notes in the EarthSciModels corpus do) would otherwise be
        # silently rewritten; fall back to JSON, which cannot get this wrong.
        try:
            diverged = json.loads(new_text) != target
        except Exception:  # noqa: BLE001 - malformed output is a divergence too
            diverged = True
        if diverged:
            new_text, mode = as_json(), "json-fallback"

    if write:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(new_text)
    return {"path": path, "changed": True, "mode": mode, "blockers": blockers, "counts": counts}


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("roots", nargs="+")
    ap.add_argument("--write", action="store_true", help="apply changes (default is a dry run)")
    ap.add_argument("--skip", action="append", default=[], help="repo-relative directory to skip")
    args = ap.parse_args()

    totals: Counter = Counter()
    errors: list[tuple[str, str]] = []
    blocked: dict[str, list[str]] = defaultdict(list)
    modes: Counter = Counter()

    for root in args.roots:
        root = os.path.abspath(root)
        files = esm_files(root, tuple(args.skip))
        print(f"== {root} — {len(files)} .esm file(s), skip={args.skip or 'none'} ==")
        for path in files:
            result = migrate_file(path, args.write)
            rel = os.path.relpath(path, root)
            if result.get("error"):
                errors.append((rel, result["error"]))
                continue
            totals.update(result["counts"])
            if result.get("changed"):
                modes[result["mode"]] += 1
            if result["blockers"]:
                blocked[rel] = result["blockers"]

    print(f"\n-- {'applied' if args.write else 'dry run'} --")
    for k, v in sorted(totals.items()):
        print(f"  {v:6d}  {k}")
    print(f"  {modes['text']:6d}  files edited as text")
    print(f"  {modes['json']:6d}  files rewritten through JSON")
    print(
        f"  {modes['json-fallback']:6d}  files rewritten through JSON after a text-edit divergence"
    )

    if errors:
        print(f"\n-- {len(errors)} FILE(S) NOT MIGRATED --")
        for rel, err in errors:
            print(f"  {rel}: {err}")

    if blocked:
        print(f"\n-- {len(blocked)} file(s) need hand work — REPORT, do not weaken --")
        for rel in sorted(blocked):
            print(f"  {rel}")
            for b in blocked[rel]:
                print(f"      {b}")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
