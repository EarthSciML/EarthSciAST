#!/usr/bin/env python3
"""Check that every string-capable property in esm-schema.json is classified
for load-time metaparameter substitution (esm-spec §9.7.6).

Substitution rewrites a bare string that spells a bound metaparameter, in every
field EXCEPT the structural ones the five bindings skip by key name. That skip
list is a blocklist, so a field the schema gains later is substituted unless
someone remembers to add it. This check makes forgetting a CI failure instead of
a silent document corruption.

The classification file
(tests/metaparameter_substitution/field_classification.json) sorts every
string-capable schema property into ``substituted`` or ``structural``, each under
a named reason. From it this script DERIVES the key-level skip set the bindings
must hold, and fails when:

* a string-capable schema property is unclassified, or a classified path no
  longer exists in the schema;
* a structural property that substitution can reach shares its key with a
  substituted property (the key cannot be skipped without breaking the
  substituted one), unless the file lists that exposure explicitly;
* the file's ``skip_keys`` / ``name_keyed_map_keys`` disagree with what the
  schema and classification derive.

Each binding's own test suite then compares its skip table and name-keyed map
table to the same file, so a binding that disagrees fails there.

Usage:
    scripts/check-metaparameter-substitution-fields.py           # check
    scripts/check-metaparameter-substitution-fields.py --derive  # print derived sets
"""

from __future__ import annotations

import argparse
import collections
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA = REPO_ROOT / "esm-schema.json"
CLASSIFICATION = REPO_ROOT / "tests" / "metaparameter_substitution" / "field_classification.json"

# A property whose value can hold one of these is an expression position or a
# folded metaparameter site, whatever else it can hold.
_EXPRESSION_REFS = {
    "#/$defs/Expression": "expression",
    "#/$defs/ExpressionNode": "expression",
    "#/$defs/MetaparameterExpression": "metaparameter_site",
}


def _is_record(schema: dict) -> bool:
    return bool(schema.get("properties")) or any(
        isinstance(alt, dict) and alt.get("properties") for alt in schema.get("oneOf", [])
    )


def _capability(schema, defs, depth=0):
    """What a property's value can hold, looking through arrays, maps and
    alternatives but NOT into record objects (their properties are sites of
    their own): ``expression`` / ``metaparameter_site`` / ``string`` / None."""
    if not isinstance(schema, dict) or depth > 8:
        return None
    ref = schema.get("$ref")
    if ref in _EXPRESSION_REFS:
        return _EXPRESSION_REFS[ref]
    if ref:
        target = defs[ref.split("/")[-1]]
        return None if _is_record(target) else _capability(target, defs, depth + 1)
    found = None
    types = schema.get("type")
    types = types if isinstance(types, list) else [types]
    if (
        "string" in types
        or any(isinstance(e, str) for e in schema.get("enum", []))
        or isinstance(schema.get("const"), str)
    ):
        found = "string"
    children = schema.get("oneOf", []) + schema.get("anyOf", []) + schema.get("allOf", [])
    if "properties" not in schema:
        items = schema.get("items")
        if isinstance(items, dict) and "properties" not in items:
            children = children + [items]
        extra = schema.get("additionalProperties")
        if isinstance(extra, dict) and "properties" not in extra:
            children = children + [extra]
    for child in children:
        if isinstance(child, dict) and "properties" in child:
            continue
        c = _capability(child, defs, depth + 1)
        if c in ("expression", "metaparameter_site"):
            return c
        found = found or c
    return found


def enumerate_schema(schema: dict):
    """Return (sites, maps, records).

    ``sites``: path -> (key, capability) for every string-capable property.
    ``maps``: path -> key for every property that is a map keyed by
    author-chosen names (an object with ``additionalProperties`` and no fixed
    ``properties``).
    ``records``: key -> paths where the property is a record object.

    Paths are ``<Def>.<prop>``, with ``[]`` for array items, ``{}`` for map
    values and ``|i`` for the i-th ``oneOf``/``anyOf``/``allOf`` alternative;
    ``(root)`` is the top-level document object.
    """
    defs = schema["$defs"]
    sites, maps = {}, {}
    records = collections.defaultdict(list)

    def walk(node, path):
        if isinstance(node, dict):
            for key, value in node.get("properties", {}).items():
                p = f"{path}.{key}"
                cap = _capability(value, defs)
                if cap:
                    sites[p] = (key, cap)
                if isinstance(value, dict):
                    extra = value.get("additionalProperties")
                    if (
                        value.get("type") == "object"
                        and not value.get("properties")
                        and extra not in (None, False)
                    ):
                        maps[p] = key
                    if value.get("properties"):
                        records[key].append(p)
            for key, value in node.items():
                if key == "properties":
                    for pk, pv in value.items():
                        walk(pv, f"{path}.{pk}")
                elif key == "items":
                    walk(value, f"{path}[]")
                elif key == "additionalProperties" and isinstance(value, dict):
                    walk(value, f"{path}{{}}")
                elif key in ("oneOf", "anyOf", "allOf"):
                    for i, alt in enumerate(value):
                        walk(alt, f"{path}|{i}")

    walk({"properties": schema["properties"]}, "(root)")
    for name, definition in defs.items():
        walk(definition, name)
    return sites, maps, records


def reachable_defs(schema: dict, roots) -> set[str]:
    """The $defs reachable by $ref from the definitions substitution walks."""
    defs = schema["$defs"]

    def refs(node, out):
        if isinstance(node, dict):
            ref = node.get("$ref")
            if isinstance(ref, str) and ref.startswith("#/$defs/"):
                out.add(ref.split("/")[-1])
            for v in node.values():
                refs(v, out)
        elif isinstance(node, list):
            for v in node:
                refs(v, out)

    seen, todo = set(), list(roots)
    while todo:
        name = todo.pop()
        if name in seen:
            continue
        seen.add(name)
        found = set()
        refs(defs[name], found)
        todo.extend(found - seen)
    return seen


def _def_of(path: str) -> str:
    return re.split(r"[.|{\[]", path, maxsplit=1)[0]


def check(schema: dict, classification: dict) -> tuple[list[str], dict]:
    errors: list[str] = []
    sites, maps, records = enumerate_schema(schema)

    reasons = classification.get("reasons", {})
    classes: dict[str, tuple[str, str]] = {}
    for verdict in ("substituted", "structural"):
        for reason, paths in classification.get(verdict, {}).items():
            if reason not in reasons.get(verdict, {}):
                errors.append(f"{verdict} reason {reason!r} is not described under `reasons`")
            for p in paths:
                if p in classes:
                    errors.append(f"{p} is classified twice")
                classes[p] = (verdict, reason)

    for p in sorted(set(sites) - set(classes)):
        errors.append(
            f"unclassified string-capable schema property {p} (key {sites[p][0]!r}): add it "
            f"to {CLASSIFICATION.relative_to(REPO_ROOT)} as substituted or structural"
        )
    for p in sorted(set(classes) - set(sites)):
        errors.append(f"classified path {p} is not a string-capable property in the schema")
    for p, (verdict, reason) in classes.items():
        if (
            p in sites
            and sites[p][1] in ("expression", "metaparameter_site")
            and verdict != "substituted"
        ):
            errors.append(
                f"{p} holds an Expression / metaparameter expression but is classified {verdict}"
            )

    reach = reachable_defs(schema, classification["substitution_roots"])
    by_key = collections.defaultdict(list)
    for p, (key, _cap) in sites.items():
        if p in classes and _def_of(p) in reach:
            by_key[key].append(p)

    # A key is skipped when some reachable property under it is structural and
    # none is a live substitution site. A `declared_name` property is not live:
    # it holds a variable / parameter / species / index-set name, which
    # `metaparameter_name_conflict` guarantees no metaparameter spells, so
    # substituting it is a no-op and skipping it loses nothing.
    derived_skip, exposed = set(), set()
    for key, paths in by_key.items():
        structural = [p for p in paths if classes[p][0] == "structural"]
        live = [
            p for p in paths if classes[p][0] == "substituted" and classes[p][1] != "declared_name"
        ]
        if structural and not live:
            derived_skip.add(key)
        elif structural:
            exposed.update(structural)

    listed_exposed = set(classification.get("exposed_structural_sites", {}))
    for p in sorted(exposed - listed_exposed):
        errors.append(
            f"structural property {p} shares key {sites[p][0]!r} with a substituted property, so "
            "the key cannot be skipped: list it under `exposed_structural_sites` with the reason "
            "the exposure is acceptable, or rename the field"
        )
    for p in sorted(listed_exposed - exposed):
        errors.append(f"`exposed_structural_sites` lists {p}, which is not exposed")

    verbatim = classification.get("verbatim_keys", {})
    for key in sorted(verbatim):
        live = [
            p
            for p in by_key.get(key, [])
            if classes[p][0] == "substituted" and classes[p][1] != "declared_name"
        ]
        if live:
            errors.append(f"verbatim key {key!r} would hide the substituted properties {live}")
    expected_skip = sorted(derived_skip | set(verbatim))
    if sorted(classification.get("skip_keys", [])) != expected_skip:
        have = set(classification.get("skip_keys", []))
        errors.append(
            "`skip_keys` disagrees with the derivation: missing "
            f"{sorted(set(expected_skip) - have)}, extra {sorted(have - set(expected_skip))}"
        )

    expected_maps = sorted({key for p, key in maps.items() if _def_of(p) in reach})
    if sorted(classification.get("name_keyed_map_keys", [])) != expected_maps:
        have = set(classification.get("name_keyed_map_keys", []))
        errors.append(
            "`name_keyed_map_keys` disagrees with the schema: missing "
            f"{sorted(set(expected_maps) - have)}, extra {sorted(have - set(expected_maps))}"
        )
    for key in expected_maps:
        clashes = [p for p in records.get(key, []) if _def_of(p) in reach]
        if clashes:
            errors.append(
                f"key {key!r} is a name-keyed map at one site but a record at {clashes}; a walk "
                "that dispatches on the key name cannot tell them apart"
            )

    derived = {"skip_keys": expected_skip, "name_keyed_map_keys": expected_maps}
    return errors, derived


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--derive", action="store_true", help="print the derived key sets")
    args = parser.parse_args()
    schema = json.loads(SCHEMA.read_text())
    classification = json.loads(CLASSIFICATION.read_text())
    errors, derived = check(schema, classification)
    if args.derive:
        print(json.dumps(derived, indent=2))
    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        print(f"{len(errors)} metaparameter-substitution classification error(s)", file=sys.stderr)
        return 1
    print(
        f"metaparameter substitution: every string-capable schema property is classified "
        f"({len(derived['skip_keys'])} skip keys, {len(derived['name_keyed_map_keys'])} name-keyed maps)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
