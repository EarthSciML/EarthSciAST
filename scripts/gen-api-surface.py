#!/usr/bin/env python3
"""Derive `api-surface.json` from the bindings' live surfaces.

    python3 scripts/gen-api-surface.py            # write api-surface.json
    python3 scripts/gen-api-surface.py --stdout   # print it instead

The manifest is BOOTSTRAPPED, not aspirational: every entry records the
spelling a binding exports *today*, so the per-binding surface tests are green
on the current tree. Intended-but-not-yet-true renames live in API_SPEC.md's
"Planned reconciliations" table and in the manifest's `planned` array, which
nothing asserts.

Canonicalisation: a symbol's identity is (canonical snake_case name, kind).
Two bindings that spell one capability differently under the transliteration
rule in API_SPEC.md §2 collapse to one entry; two that genuinely disagree stay
apart and are recorded in `notes` / `planned`.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "extract_api_surface",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "extract-api-surface.py"),
)
_ex = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_ex)

ROOT = _ex.ROOT
BINDINGS = _ex.BINDINGS

# ---------------------------------------------------------------------------
# Canonicalisation (the inverse of API_SPEC.md §2's transliteration rule)
# ---------------------------------------------------------------------------
# Tokenises PascalCase / camelCase, keeping acronyms whole — including a
# pluralised one (`ODEs` is one token, not `OD` + `Es`).
_WORD = re.compile(r"[A-Z]{2,}s(?![a-z])|[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+")


def canonical(name: str) -> str:
    """Fold any binding's spelling down to the canonical snake_case key."""
    name = name.rstrip("!").lstrip("_")          # Julia's mutating-bang suffix
    if name.isupper() and "_" not in name:
        return name.lower()
    if "_" in name:
        return "_".join(p.lower() for p in name.split("_") if p)
    parts = [w.lower() for w in _WORD.findall(name)]
    # A version token splits as ("v", "04"); rejoin it so `preV04` and
    # `pre_v04` land on the same key.
    merged: list[str] = []
    for p in parts:
        if merged and len(merged[-1]) == 1 and merged[-1].isalpha() and p.isdigit():
            merged[-1] += p
        else:
            merged.append(p)
    return "_".join(merged)


def kind_of(name: str) -> str:
    """Infer a symbol kind from its spelling.

    Sound for Julia / Python / Rust / TypeScript, where snake_case means a
    function, PascalCase a type and SCREAMING_SNAKE a constant. NOT sound for
    Go, whose functions are PascalCase too — `binding_kinds()` supplies Go's
    kinds from the AST walk instead.
    """
    n = name.lstrip("_")
    if not n:
        return "function"
    if n.isupper() and len(n) > 1:
        return "constant"
    if n[0].isupper():
        return "error" if n.endswith(("Error", "Exception")) else "type"
    return "function"


_GO_KIND = {"func": "function", "type": "type", "const": "constant", "var": "constant"}

# Julia's surface is read textually (the `export` block), so its kinds come from
# the spelling rule -- which reads any `...Error` as a throwable. These two are
# not: they are diagnostic RECORDS (`SchemaError{path, keyword, message}`,
# `StructuralError{path, message, error_type}`) that `validate_schema` /
# `validate_structural` RETURN in a vector, exactly like their TypeScript twins.
# `pkg/EarthSciAST.jl/test/api_surface_test.jl` is what keeps this list honest:
# it checks every manifest `error` against `<: Exception` and fails if one of
# these entries becomes wrong.
KIND_OVERRIDES = {
    ("julia", "SchemaError"): "type",
    ("julia", "StructuralError"): "type",
}


def binding_kinds(surfaces: dict) -> dict[str, dict[str, str]]:
    """binding -> spelling -> kind, using each extractor's own evidence."""
    kinds: dict[str, dict[str, str]] = {}
    for binding in BINDINGS:
        kinds[binding] = {}
    for s in surfaces["go"]:
        k = _GO_KIND[s["kind"]]
        if k == "type" and s["name"].endswith(("Error", "Exception")):
            k = "error"
        # A Go `var Err...` sentinel is an error value, not a constant.
        if s["kind"] == "var" and s["name"].startswith("Err"):
            k = "error"
        kinds["go"][s["name"]] = k
    for binding in ("typescript", "editor"):
        # A TypeScript error is a class, so it is a VALUE export. A `export type`
        # named `...Error` is a diagnostic record, not something you throw.
        for n in surfaces[binding]["types"]:
            kinds[binding][n] = "type"
        for n in surfaces[binding]["values"]:
            kinds[binding][n] = kind_of(n)
    kinds["python"].update(surfaces["python"]["kinds"])
    for (binding, name), kind in KIND_OVERRIDES.items():
        kinds[binding][name] = kind
    return kinds


# ---------------------------------------------------------------------------
# Forward transliteration: canonical (name, kind) -> the spelling API_SPEC.md §2
# says each binding must use. Used only to FLAG divergences, never to rename.
# ---------------------------------------------------------------------------
INITIALISMS = {
    "esm", "ode", "dae", "pde", "sde", "ast", "json", "xml", "url", "uri", "id",
    "io", "dot", "cf", "ic", "rhs", "lhs", "cse", "faq", "api", "http", "https",
    "uuid", "csv", "ascii", "html", "cli", "mtk", "db", "os", "ip", "tls", "ml",
}


def _pascal(tokens: list[str], go: bool) -> str:
    out = []
    for t in tokens:
        if go and t in INITIALISMS:
            out.append(t.upper())
        else:
            out.append(t[:1].upper() + t[1:])
    return "".join(out)


def transliterate(name: str, kind: str, binding: str, upper_initialisms: bool = False) -> str:
    tokens = name.split("_")
    if upper_initialisms and binding != "go":
        if kind in ("type", "error"):
            return _pascal(tokens, go=True)
        if kind not in ("constant",):
            head, *rest = tokens
            if binding in ("typescript", "editor"):
                return head + _pascal(rest, go=True)
    if binding == "go":
        return _pascal(tokens, go=True)
    if kind in ("type", "error"):
        return _pascal(tokens, go=False)
    if kind == "constant":
        return name.upper()
    if binding in ("typescript", "editor"):
        head, *rest = tokens
        return head + _pascal(rest, go=False)
    return name  # julia / python / rust: verbatim snake_case


def transliterate_initialism_upper(name: str, kind: str, binding: str) -> str:
    return transliterate(name, kind, binding, upper_initialisms=True)


# ---------------------------------------------------------------------------
# Tier assignment
# ---------------------------------------------------------------------------
# Default rule: a (name, kind) exported by two or more bindings is `stable`;
# a one-binding symbol is an `extension seam`. These override that.
EXTENSION_OVERRIDES = {
    # Julia's build/inspection seam and its forcing-buffer ABI (RFC perf-plan B2).
    ("build_evaluator", "function"),
    ("build_inspection", "type"),
    ("expanded_model", "function"),
    ("expand_flattened_refs", "function"),
    ("evaluate_expr", "function"),
    ("rhs_with_buffers", "function"),
    ("forcing_buffers", "function"),
    ("forcing_buffer_index", "function"),
    ("sync_forcing", "function"),
    ("oop_intern_stats", "function"),
    ("oop_intern_stats_reset", "function"),
    ("param_map", "function"),
    ("parameter_classes", "function"),
    ("remake_parameters", "function"),
    # Rust's interning / performance / array-simulation internals.
    ("compact_expr", "type"),
    ("performance_error", "error"),
    ("parallel_evaluator", "type"),
    ("model_allocator", "type"),
    ("stoichiometric_matrix_parallel", "function"),
    ("interpret", "function"),
    ("compile_array", "function"),
    ("fold_constant_expr", "function"),
    ("compiled", "type"),
    ("resolved_expr", "type"),
    # Host/runtime integration seams: callbacks, sinks, providers, checkpoints.
    ("build_refresh_callback", "function"),
    ("build_output_callback", "function"),
    ("build_checkpoint_callback", "function"),
    ("build_zarr_sink", "function"),
    ("zarr_restart_state", "function"),
    ("abstract_sink", "type"),
    ("providers_from_document", "function"),
    ("prepare_provider", "type"),
}

STABLE_OVERRIDES = {
    # The editor's component / primitive / store surface is that package's whole
    # public product, so it is stable even though no other binding exports it.
    ("expression_node", "type"), ("equation_editor", "type"), ("model_editor", "type"),
    ("reaction_editor", "type"), ("coupling_graph", "type"), ("validation_panel", "type"),
    ("file_summary", "type"), ("create_ast_store", "function"),
    ("register_web_components", "function"),
}

# Bindings that deliberately do not implement a capability family. Recorded so
# a reader can tell "absent by design" from "absent by drift".
CAPABILITY_PROFILES = {
    "core": {
        "summary": "parse / serialize / validate / display / canonicalize / graph / edit / flatten",
        "bindings": ["julia", "typescript", "python", "rust", "go"],
    },
    "classification": {
        "summary": "esm-spec §6.3.1 derived variable classification",
        "bindings": ["julia", "typescript", "python", "rust", "go"],
    },
    "simulation": {
        "summary": "build an RHS and integrate it; TypeScript and Go are deliberately non-simulating",
        "bindings": ["julia", "python", "rust"],
    },
    "runtime_io": {
        "summary": "data-source providers, refresh cadence, output sinks, checkpoints",
        "bindings": ["julia", "python", "rust"],
    },
    "ui": {
        "summary": "interactive SolidJS editing components",
        "bindings": ["editor"],
    },
}

PLANNED = [
    # `load`, `save` and `VERSION` used to live here. All three landed in the
    # phase-2 I/O split: `load_path` / `load_string` / `load_document`,
    # `to_json` / `to_json_compact` / `write_path`, and `SCHEMA_VERSION` /
    # `LIBRARY_VERSION` — each 5/5 in the manifest above, with the old names
    # deleted rather than deprecated. See API_SPEC.md §5.1.
    {
        "canonical": "abstol / reltol / saveat / alg",
        "issue": "Python's `simulate` takes scipy's `rtol=` / `atol=` / `method=`; "
                 "Julia and Rust take SciML's `reltol` / `abstol` and Julia takes "
                 "`alg` / `saveat`. Rust's `SimulateOptions` spells them "
                 "`solver` and `output_times`.",
        "resolution": "SciML spelling is canonical (API_SPEC.md §4): Python gains "
                      "`reltol` / `abstol` / `alg` (old names deprecated aliases for "
                      "one minor), Rust renames `SimulateOptions::solver` -> `alg` and "
                      "`output_times` -> `saveat`.",
        "affects": ["python", "rust"],
    },
    {
        "canonical": "closed_function_names",
        "issue": "Julia, Rust and Go export a FUNCTION; TypeScript exports a "
                 "CONSTANT array `CLOSED_FUNCTION_NAMES`.",
        "resolution": "TypeScript adds `closedFunctionNames()`; the constant stays one "
                      "minor as a deprecated alias.",
        "affects": ["typescript"],
    },
    {
        "canonical": "derive_odes",
        "issue": "TypeScript spells it `deriveODEs`, violating the §2 rule that "
                 "TypeScript is lowerCamelCase of the canonical name (`deriveOdes`). "
                 "TypeScript already spells the sibling `odeStates` / `isOdeState` "
                 "correctly.",
        "resolution": "Rename to `deriveOdes`; `deriveODEs` stays one minor as an alias.",
        "affects": ["typescript"],
    },
    {
        "canonical": "unknowns / parameters",
        "issue": "TypeScript and Python export `unknowns` / `parameters`; Julia "
                 "exports `unknown_names` / `parameter_names` for the same query.",
        "resolution": "Canonical is `unknowns` / `parameters`; Julia keeps "
                      "`unknown_names` / `parameter_names` as deprecated aliases "
                      "because the bare names collide with common downstream bindings.",
        "affects": ["julia"],
    },
    {
        "canonical": "add_variable / remove_variable / ...",
        "issue": "Python suffixes every edit operation with its container "
                 "(`add_variable_to_model`, `remove_coupling_from_file`, "
                 "`extract_component_from_file`, `merge_esm_files`); Julia, "
                 "TypeScript and Rust use the bare verb (`add_variable`).",
        "resolution": "Python gains the bare names; the suffixed ones become "
                      "deprecated aliases.",
        "affects": ["python"],
    },
    {
        "canonical": "to_dot / to_mermaid / to_json",
        "issue": "Julia exports `to_dot` / `to_mermaid` / `to_json` and TypeScript "
                 "`toDot` / `toMermaid` / `toJsonGraph`; Go spells the same six "
                 "renderings `ExportComponentGraphDOT` / `ExportExpressionGraphDOT` "
                 "and friends, plus exporter objects.",
        "resolution": "Canonical `to_dot(graph)` / `to_mermaid(graph)` / "
                      "`to_json(graph)` dispatching on graph kind; Go's `Export*` "
                      "family becomes `ToDOT` / `ToMermaid` / `ToJSON`.",
        "affects": ["typescript", "go"],
    },
    {
        "canonical": "substitute_with_context",
        "issue": "Rust names the scoped substitution family `*_with_context` "
                 "(`ScopedContext`); Go names it `*WithScoped`.",
        "resolution": "Canonical is `substitute_with_context`; Go renames to "
                      "`SubstituteWithContext` and friends.",
        "affects": ["go"],
    },
    {
        "canonical": "reference_resolution_error",
        "issue": "Julia and Python raise `ReferenceResolutionError`; Rust's is "
                 "`ReferenceError`.",
        "resolution": "Canonical is `reference_resolution_error`; Rust renames, "
                      "keeping `ReferenceError` as a type alias for one minor.",
        "affects": ["rust"],
    },
    {
        "canonical": "system_kind",
        "issue": "Julia / Python / Rust / Go export a FUNCTION `system_kind`; "
                 "TypeScript exports both the function `systemKind` and the type "
                 "`SystemKind`, and Go additionally has `EffectiveSystemKind` with "
                 "no counterpart elsewhere.",
        "resolution": "Keep the function/type pair (they are distinct symbols under "
                      "the (name, kind) identity rule). Decide whether "
                      "`EffectiveSystemKind` is `declared_system_kind`'s peer or a "
                      "Go-only convenience, and harmonise the trio "
                      "`system_kind` / `declared_system_kind` / "
                      "`declared_system_kind_mismatch`, which currently exists in "
                      "three different two-binding subsets.",
        "affects": ["julia", "typescript", "python", "go"],
    },
]


def build() -> dict:
    surfaces = _ex.extract_all()
    live = _ex.live_names(surfaces)
    kinds = binding_kinds(surfaces)

    def kind_for(binding: str, name: str) -> str:
        return kinds[binding].get(name) or kind_of(name)

    # (canonical, kind) -> binding -> [spelling, ...]. A binding may carry more
    # than one spelling of one canonical symbol: Julia's mutating `!` twin
    # (`apply_unit_conversion` / `apply_unit_conversion!`) and TypeScript's
    # `component_graph` / `componentGraph` alias pair are the two live cases.
    table: dict[tuple[str, str], dict[str, list[str]]] = collections.defaultdict(
        lambda: collections.defaultdict(list)
    )
    for binding, names in live.items():
        for name in sorted(names):
            table[(canonical(name), kind_for(binding, name))][binding].append(name)

    symbols = []
    for (name, kind), bindings in sorted(table.items()):
        key = (name, kind)
        if key in EXTENSION_OVERRIDES:
            tier = "extension"
        elif key in STABLE_OVERRIDES:
            tier = "stable"
        else:
            tier = "stable" if len(bindings) >= 2 else "extension"
        entry = {
            "name": name,
            "kind": kind,
            "tier": tier,
            # A string when the binding has exactly one spelling; a list when it
            # exports aliases. Surface tests flatten both.
            "bindings": {
                b: (v[0] if len(v) == 1 else sorted(v))
                for b, v in sorted(bindings.items())
            },
        }
        notes = []
        # Flag any binding whose spelling is not the one API_SPEC.md §2's
        # transliteration rule generates from (name, kind).
        divergent = []
        for b, spellings in sorted(bindings.items()):
            want = transliterate(name, kind, b)
            ok = {want}
            if b != "go":
                # Outside Go, uppercasing an embedded acronym is a style choice
                # (§2): `AstExpr` and `ASTExpr` are both conforming.
                ok.add(transliterate_initialism_upper(name, kind, b))
            if b == "julia":
                # Julia may append `!` to a mutating function.
                ok |= {w + "!" for w in list(ok)}
            off = [sp for sp in spellings if sp not in ok]
            if off:
                divergent.append(f"{b}={'/'.join(off)} (expected {want})")
        if divergent:
            notes.append("spelling differs from the §2 rule: " + "; ".join(divergent))
        aliased = sorted(b for b, v in bindings.items() if len(v) > 1)
        if aliased:
            notes.append("multiple spellings exported by: " + ", ".join(aliased))
        if notes:
            entry["notes"] = "; ".join(notes)
        symbols.append(entry)

    def _spellings(sym, binding):
        v = sym["bindings"].get(binding)
        if v is None:
            return []
        return [v] if isinstance(v, str) else v

    counts_by_binding = {
        b: sum(len(_spellings(s, b)) for s in symbols) for b in BINDINGS
    }
    counts_by_tier = collections.Counter(s["tier"] for s in symbols)

    return {
        "$schema_note": "Companion manifest to API_SPEC.md. Regenerate with "
                        "`python3 scripts/gen-api-surface.py`; verify with "
                        "`python3 scripts/extract-api-surface.py --check` or each "
                        "binding's own api-surface test.",
        "version": 1,
        "spec": "API_SPEC.md",
        "tiers": {
            "stable": "Harmonized across bindings, surface-tested, breaks only at a major.",
            "extension": "Named and documented extension seam. May differ between "
                         "bindings and may break at a minor.",
            "private": "Everything else. Not listed here; a symbol absent from this "
                       "manifest MUST NOT be exported.",
        },
        "capability_profiles": CAPABILITY_PROFILES,
        "binding_profiles": {
            "julia": {
                "package": "EarthSciAST.jl",
                "surface_declaration": "pkg/EarthSciAST.jl/src/EarthSciAST.jl `export` block",
                "surface_test": "pkg/EarthSciAST.jl/test/api_surface_test.jl",
            },
            "typescript": {
                "package": "@earthsciml/ast",
                "surface_declaration": "pkg/earthsci-ast-ts/src/index.ts named re-exports",
                "surface_test": "pkg/earthsci-ast-ts/src/api-surface.test.ts",
                "star_reexports": surfaces["typescript"]["star_reexports"],
                "star_reexport_note": "`export * from './types.js'` re-exports the generated "
                                      "schema type barrel wholesale. Its members are "
                                      "schema-derived and churn with esm-schema.json, so the "
                                      "manifest pins the barrel LIST, not its members.",
            },
            "python": {
                "package": "earthsci-ast",
                "surface_declaration": "pkg/earthsci-ast-py/src/earthsci_ast/__init__.py `__all__`",
                "surface_test": "pkg/earthsci-ast-py/tests/test_api_surface.py",
            },
            "rust": {
                "package": "earthsci-ast",
                "surface_declaration": "pkg/earthsci-ast-rs/src/lib.rs root `pub use` / `pub const`",
                "surface_test": "pkg/earthsci-ast-rs/tests/api_surface.rs",
                "public_modules": surfaces["rust"]["modules"],
                "public_module_note": "`cargo public-api` needs a nightly toolchain and is "
                                      "not installed here, so the test is the vendored "
                                      "equivalent: it parses the crate root, which is the "
                                      "only source of `earthsci_ast::<name>` paths. Module "
                                      "interiors are extension seams reachable as "
                                      "`earthsci_ast::<module>::<name>`.",
            },
            "go": {
                "package": "github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm",
                "surface_declaration": "package-level exported identifiers of pkg/esm",
                "surface_test": "pkg/earthsci-ast-go/pkg/esm/api_surface_test.go",
                "scope_note": "Package-level func / type / const / var only. Methods on an "
                              "exported type are covered by that type's entry, not listed "
                              "separately.",
            },
            "editor": {
                "package": "@earthsciml/ast-editor",
                "surface_declaration": "pkg/earthsci-ast-editor/src/index.ts named re-exports",
                "surface_test": "pkg/earthsci-ast-editor/src/api-surface.test.ts",
                "star_reexports": surfaces["editor"]["star_reexports"],
            },
        },
        "counts": {
            "symbols": len(symbols),
            "note": "`by_binding` counts exported SPELLINGS (so alias pairs count "
                    "twice); `symbols` counts canonical (name, kind) entries.",
            "by_binding": counts_by_binding,
            "by_tier": dict(sorted(counts_by_tier.items())),
        },
        "planned": PLANNED,
        "symbols": symbols,
    }


# ---------------------------------------------------------------------------
# API_SPEC.md §6: the stable-surface tables, regenerated alongside the manifest
# so the prose cannot drift away from the JSON.
# ---------------------------------------------------------------------------
BEGIN_MARKER = "<!-- BEGIN GENERATED: stable-surface -->"
END_MARKER = "<!-- END GENERATED: stable-surface -->"

_HEADERS = {"julia": "Julia", "typescript": "TS", "python": "Python",
            "rust": "Rust", "go": "Go", "editor": "Editor"}


def _cell(sym: dict, binding: str) -> str:
    entry = sym["bindings"].get(binding)
    if entry is None:
        return "\u2013"
    if isinstance(entry, list):
        return " / ".join(f"`{x}`" for x in entry)
    return f"`{entry}`"


def _table(syms: list, cols: list) -> str:
    rows = ["| Canonical | Kind | " + " | ".join(_HEADERS[b] for b in cols) + " |",
            "|---|---|" + "---|" * len(cols)]
    for s in sorted(syms, key=lambda s: (s["name"], s["kind"])):
        rows.append(f"| `{s['name']}` | {s['kind']} | "
                    + " | ".join(_cell(s, b) for b in cols) + " |")
    return "\n".join(rows)


def stable_surface_tables(manifest: dict) -> str:
    stable = [s for s in manifest["symbols"] if s["tier"] == "stable"]
    core = [b for b in BINDINGS if b != "editor"]
    counted = {s["name"] + s["kind"]: sum(b in s["bindings"] for b in core)
               for s in stable}

    def at(n: int) -> list:
        return [s for s in stable if counted[s["name"] + s["kind"]] == n]

    parts = []
    for n, label in ((5, "all five format bindings"), (4, "four of the five"),
                     (3, "three of the five"), (2, "two of the five")):
        parts.append(f"#### Exported by {label}\n\n" + _table(at(n), core))
    editor_only = [s for s in stable
                   if counted[s["name"] + s["kind"]] < 2 and "editor" in s["bindings"]]
    parts.append("#### Editor package\n\n" + _table(editor_only, ["typescript", "editor"]))
    return "\n\n".join(parts)


def render_spec_section(manifest: dict) -> str:
    """The API_SPEC.md text between the generated-block markers."""
    return f"{BEGIN_MARKER}\n\n{stable_surface_tables(manifest)}\n\n{END_MARKER}"


def update_spec(manifest: dict, path: str | None = None) -> bool:
    """Rewrite API_SPEC.md's generated block. Returns True if it changed."""
    path = path or os.path.join(ROOT, "API_SPEC.md")
    text = open(path).read()
    start, end = text.find(BEGIN_MARKER), text.find(END_MARKER)
    if start < 0 or end < 0:
        raise SystemExit(f"{path}: generated-block markers not found")
    updated = text[:start] + render_spec_section(manifest) + text[end + len(END_MARKER):]
    if updated == text:
        return False
    open(path, "w").write(updated)
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stdout", action="store_true")
    args = ap.parse_args()
    manifest = build()
    text = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    if args.stdout:
        sys.stdout.write(text)
        return 0
    path = os.path.join(ROOT, "api-surface.json")
    open(path, "w").write(text)
    c = manifest["counts"]
    print(f"wrote {path}: {c['symbols']} symbols")
    print("  by binding:", c["by_binding"])
    print("  by tier:   ", c["by_tier"])
    print("  API_SPEC.md \u00a76:", "updated" if update_spec(manifest) else "already current")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
