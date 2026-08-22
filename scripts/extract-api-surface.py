#!/usr/bin/env python3
"""Mechanically extract the declared public surface of every EarthSciAST binding.

This is the provenance of `api-surface.json`: the manifest is DERIVED from what
the bindings export today, never hand-transcribed. Run it two ways:

    python3 scripts/extract-api-surface.py            # print the raw surfaces
    python3 scripts/extract-api-surface.py --check    # diff them against api-surface.json

The per-binding surface tests (`*api_surface*` under each `pkg/`) assert the
same equality in each language's own test runner; this script is the
cross-cutting view and the regeneration aid for `scripts/gen-api-surface.py`.

Extraction points, one per binding, each the binding's single declaration of
"this is public":

  Julia       the `export` block of `pkg/EarthSciAST.jl/src/EarthSciAST.jl`
  TypeScript  the named re-exports of `pkg/earthsci-ast-ts/src/index.ts`
  Python      `__all__` of `pkg/earthsci-ast-py/src/earthsci_ast/__init__.py`
  Rust        the root `pub use` / `pub const` / `pub mod` of `pkg/earthsci-ast-rs/src/lib.rs`
  Go          package-level exported identifiers of `pkg/earthsci-ast-go/pkg/esm`
  editor      the named re-exports of `pkg/earthsci-ast-editor/src/index.ts`
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

BINDINGS = ("julia", "typescript", "python", "rust", "go", "editor")


def _strip_line_comments(text: str, marker: str) -> str:
    out = []
    for line in text.splitlines():
        i = line.find(marker)
        if i >= 0:
            line = line[:i]
        out.append(line)
    return "\n".join(out)


# --------------------------------------------------------------------------
# Julia — the `export` block
# --------------------------------------------------------------------------
def extract_julia() -> list[str]:
    src = open(os.path.join(ROOT, "pkg/EarthSciAST.jl/src/EarthSciAST.jl")).read()
    m = re.search(r"^export\b", src, re.M)
    if not m:
        raise SystemExit("EarthSciAST.jl: no `export` block found")
    lines = []
    for line in src[m.end():].splitlines():
        s = line.strip()
        # The block runs until the next top-level construct (docstring / function / end).
        if s.startswith('"""') or s.startswith("function ") or s.startswith("end "):
            break
        lines.append(line)
    body = _strip_line_comments("\n".join(lines), "#")
    names = [n for n in re.split(r"[,\s]+", body) if n]
    bad = [n for n in names if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_!]*", n)]
    if bad:
        raise SystemExit(f"EarthSciAST.jl: unparsable export tokens {bad}")
    return sorted(set(names))


# --------------------------------------------------------------------------
# TypeScript — the named re-exports of index.ts
# --------------------------------------------------------------------------
def _extract_ts_index(path: str) -> dict:
    src = open(path).read()
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = _strip_line_comments(src, "//")
    values: set[str] = set()
    types: set[str] = set()
    stars: set[str] = set()
    for m in re.finditer(r"export\s+(type\s+)?\{([^}]*)\}\s*from\s*'([^']+)'", src, re.S):
        default_bucket = types if m.group(1) else values
        for item in m.group(2).split(","):
            item = item.strip()
            if not item:
                continue
            bucket = default_bucket
            if item.startswith("type "):
                item, bucket = item[5:].strip(), types
            alias = re.match(r"\S+\s+as\s+(\S+)$", item)
            if alias:
                item = alias.group(1)
            bucket.add(item)
    for m in re.finditer(r"export\s+\*\s+from\s*'([^']+)'", src):
        stars.add(m.group(1))
    return {"values": sorted(values), "types": sorted(types), "star_reexports": sorted(stars)}


def extract_typescript() -> dict:
    return _extract_ts_index(os.path.join(ROOT, "pkg/earthsci-ast-ts/src/index.ts"))


def extract_editor() -> dict:
    return _extract_ts_index(os.path.join(ROOT, "pkg/earthsci-ast-editor/src/index.ts"))


# --------------------------------------------------------------------------
# Python — __all__
# --------------------------------------------------------------------------
_PY_INTROSPECT = r"""
import inspect, json, sys
sys.path.insert(0, __SRC__)
import earthsci_ast as m

def kind(name):
    obj = getattr(m, name, None)
    if inspect.isclass(obj):
        return "error" if issubclass(obj, BaseException) else "type"
    if obj is not None and (inspect.isfunction(obj) or inspect.isbuiltin(obj)
                            or inspect.ismethod(obj)):
        return "function"
    if isinstance(obj, (str, int, float, bool, tuple, frozenset)) and name.isupper():
        return "constant"
    return None   # let the caller fall back to the spelling heuristic

names = sorted(set(m.__all__))
print(json.dumps({"names": names, "kinds": {n: kind(n) for n in names}}))
"""


def extract_python() -> dict:
    pkg_src = os.path.join(ROOT, "pkg/earthsci-ast-py/src")
    code = _PY_INTROSPECT.replace("__SRC__", repr(pkg_src))
    proc = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    if proc.returncode == 0:
        out = json.loads(proc.stdout)
        out["kinds"] = {k: v for k, v in out["kinds"].items() if v}
        return out
    # Fall back to a static parse when the package cannot be imported (no deps
    # installed): the conditional `__all__.extend([...])` tiers are literal lists.
    sys.stderr.write("earthsci_ast import failed; static __all__ parse "
                     "(kinds fall back to the spelling heuristic)\n")
    src = open(os.path.join(pkg_src, "earthsci_ast/__init__.py")).read()
    names: set[str] = set()
    for m in re.finditer(r"__all__(?:\s*=\s*|\.extend\()\s*\[(.*?)\]", src, re.S):
        names.update(re.findall(r'"([^"]+)"', m.group(1)))
        names.update(re.findall(r"'([^']+)'", m.group(1)))
    return {"names": sorted(names), "kinds": {}}


# --------------------------------------------------------------------------
# Rust — root re-exports. `cargo public-api` needs a nightly toolchain and is
# not installed in this repo's environment, so this is the vendored equivalent:
# the crate root is the only place `earthsci_ast::<name>` can come from, so
# parsing its `pub use` / `pub const` / `pub mod` is exact for the root path.
# --------------------------------------------------------------------------
def extract_rust() -> dict:
    src = open(os.path.join(ROOT, "pkg/earthsci-ast-rs/src/lib.rs")).read()
    src = re.sub(r"//[!/].*", "", src)
    src = _strip_line_comments(src, "//")
    reexports: dict[str, str] = {}
    for m in re.finditer(r"pub\s+use\s+([A-Za-z0-9_]+)::\{([^}]*)\}\s*;", src, re.S):
        for item in m.group(2).split(","):
            item = item.strip()
            if not item:
                continue
            item = re.sub(r"^\S+\s+as\s+(\S+)$", r"\1", item)
            reexports[item] = m.group(1)
    for m in re.finditer(r"pub\s+use\s+([A-Za-z0-9_]+)::([A-Za-z0-9_]+)\s*;", src):
        reexports[m.group(2)] = m.group(1)
    modules = sorted(re.findall(r"^\s*pub\s+mod\s+([A-Za-z0-9_]+)\s*;", src, re.M))
    consts = sorted(re.findall(r"pub\s+const\s+([A-Za-z0-9_]+)\s*:", src))
    return {
        "reexports": dict(sorted(reexports.items())),
        "modules": modules,
        "consts": consts,
    }


# --------------------------------------------------------------------------
# Go — package-level exported identifiers of package `esm`
# --------------------------------------------------------------------------
_GO_WALKER = r'''
package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strings"
)

type sym struct {
	Name string `json:"name"`
	Kind string `json:"kind"`
}

func main() {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, os.Args[1], func(fi os.FileInfo) bool {
		return !strings.HasSuffix(fi.Name(), "_test.go")
	}, 0)
	if err != nil {
		panic(err)
	}
	var syms []sym
	for _, p := range pkgs {
		if strings.HasSuffix(p.Name, "_test") {
			continue
		}
		for _, f := range p.Files {
			for _, decl := range f.Decls {
				switch d := decl.(type) {
				case *ast.FuncDecl:
					if !d.Name.IsExported() || d.Recv != nil {
						continue // methods belong to their receiver type's entry
					}
					syms = append(syms, sym{d.Name.Name, "func"})
				case *ast.GenDecl:
					for _, spec := range d.Specs {
						switch s := spec.(type) {
						case *ast.TypeSpec:
							if s.Name.IsExported() {
								syms = append(syms, sym{s.Name.Name, "type"})
							}
						case *ast.ValueSpec:
							for _, n := range s.Names {
								if !n.IsExported() {
									continue
								}
								k := "var"
								if d.Tok == token.CONST {
									k = "const"
								}
								syms = append(syms, sym{n.Name, k})
							}
						}
					}
				}
			}
		}
	}
	sort.Slice(syms, func(i, j int) bool {
		if syms[i].Name == syms[j].Name {
			return syms[i].Kind < syms[j].Kind
		}
		return syms[i].Name < syms[j].Name
	})
	b, _ := json.Marshal(syms)
	fmt.Println(string(b))
}
'''


def extract_go() -> list[dict]:
    import tempfile

    pkg = os.path.join(ROOT, "pkg/earthsci-ast-go/pkg/esm")
    with tempfile.TemporaryDirectory() as tmp:
        open(os.path.join(tmp, "main.go"), "w").write(_GO_WALKER)
        open(os.path.join(tmp, "go.mod"), "w").write("module apiwalk\n\ngo 1.22\n")
        proc = subprocess.run(["go", "run", ".", pkg], cwd=tmp, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit("go surface walk failed:\n" + proc.stderr[-3000:])
    return json.loads(proc.stdout)


def extract_all() -> dict:
    return {
        "julia": extract_julia(),
        "typescript": extract_typescript(),
        "python": extract_python(),
        "rust": extract_rust(),
        "go": extract_go(),
        "editor": extract_editor(),
    }


# --------------------------------------------------------------------------
# --check: compare the live surfaces against the manifest
# --------------------------------------------------------------------------
def manifest_names(manifest: dict) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {b: set() for b in BINDINGS}
    for sym in manifest["symbols"]:
        for binding, spelling in sym["bindings"].items():
            # A binding entry is a string, or a list when it exports aliases.
            if isinstance(spelling, str):
                out[binding].add(spelling)
            else:
                out[binding].update(spelling)
    return out


def live_names(surfaces: dict) -> dict[str, set[str]]:
    ts = surfaces["typescript"]
    ed = surfaces["editor"]
    rs = surfaces["rust"]
    return {
        "julia": set(surfaces["julia"]),
        "typescript": set(ts["values"]) | set(ts["types"]),
        "python": set(surfaces["python"]["names"]),
        "rust": set(rs["reexports"]) | set(rs["consts"]),
        "go": {s["name"] for s in surfaces["go"]},
        "editor": set(ed["values"]) | set(ed["types"]),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="diff live surfaces against api-surface.json")
    ap.add_argument("--binding", choices=BINDINGS, help="restrict --check / output to one binding")
    args = ap.parse_args()

    surfaces = extract_all()
    if not args.check:
        if args.binding:
            print(json.dumps(surfaces[args.binding], indent=1, sort_keys=True))
        else:
            print(json.dumps(surfaces, indent=1, sort_keys=True))
        return 0

    manifest = json.load(open(os.path.join(ROOT, "api-surface.json")))
    declared = manifest_names(manifest)
    live = live_names(surfaces)
    failed = False
    for binding in BINDINGS:
        if args.binding and binding != args.binding:
            continue
        missing = sorted(declared[binding] - live[binding])   # manifest says yes, code says no
        extra = sorted(live[binding] - declared[binding])     # code says yes, manifest says no
        if missing or extra:
            failed = True
            print(f"[{binding}] MISMATCH")
            for n in missing:
                print(f"  - in manifest, not exported: {n}")
            for n in extra:
                print(f"  + exported, not in manifest: {n}")
        else:
            print(f"[{binding}] ok ({len(live[binding])} symbols)")

    # Structural extras the manifest pins beyond the flat name list.
    ts_stars = manifest["binding_profiles"]["typescript"]["star_reexports"]
    if sorted(ts_stars) != surfaces["typescript"]["star_reexports"]:
        failed = True
        print(f"[typescript] star re-export list changed: "
              f"{surfaces['typescript']['star_reexports']} != {sorted(ts_stars)}")
    rs_mods = manifest["binding_profiles"]["rust"]["public_modules"]
    if sorted(rs_mods) != surfaces["rust"]["modules"]:
        failed = True
        print(f"[rust] pub mod list changed:\n"
              f"  + {sorted(set(surfaces['rust']['modules']) - set(rs_mods))}\n"
              f"  - {sorted(set(rs_mods) - set(surfaces['rust']['modules']))}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
