"""The document source formats (CONFORMANCE_SPEC §5.58): the golden set in
``tests/conformance/document_format/``, and the whole-corpus round trip.

The fixture contract is the README of that directory:

* ``print``: ``print(esm) == text`` character for character and
  ``parse(text) == esm`` as a JSON value, in both formats (and
  ``canonicalize(written) == esm`` when the case is about the canonical form);
* ``variant``: ``parse(surface, input) == esm`` and
  ``print(surface, esm) == canonical``;
* ``refusal``: ``parse(surface, input)`` raises a diagnostic whose code is
  ``error``.

Documents are compared as JSON values with numbers compared by type too (``2`` is
not ``2.0``).

The corpus round trip is computed here from the corpus itself, never stored: every
``.esm`` under ``tests/`` that is a JSON object (the corpus of
``formal/scripts/doc-corpus.py``), canonicalized, printed in each format and read
back, must give its canonical form again.

With ``ESM_LEAN`` naming a built ``esm-lean`` (``formal/.lake/build/bin/esm-lean``),
``test_document_format_matches_lean`` also checks, over the whole corpus, that
these printers write exactly what ``esm-lean print-md`` / ``print-typ`` write for
the canonical document and these readers read the Lean-printed texts exactly as
``esm-lean parse-md`` / ``parse-typ`` do (a self round trip alone cannot see a
printer and a reader that drift together). ``ESM_LEAN_SCRATCH`` names the
directory its intermediate files go to (default: a pytest temporary directory).
"""

from __future__ import annotations

import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from conftest import CONFORMANCE_DIR, FIXTURES_ROOT

from earthsci_ast import (
    DocumentFormat,
    canonicalize_document,
    parse_document,
    parse_markdown,
    parse_typst,
    print_document,
    print_markdown,
    print_math,
    print_typst,
)
from earthsci_ast.errors import ParseError

FIXTURES_DIR = CONFORMANCE_DIR / "document_format"
FILES = (
    "operators.json",
    "names.json",
    "variants.json",
    "documents.json",
    "units.json",
    "refusals.json",
)
FORMATS = ("markdown", "typst")


def _typed(value) -> str:
    """JSON text with sorted keys: an int and an equal float spell differently."""
    return json.dumps(value, sort_keys=True, ensure_ascii=False)


def _cases():
    out = []
    for name in FILES:
        doc = json.loads((FIXTURES_DIR / name).read_text(encoding="utf-8"))
        out.extend(doc["cases"])
    return out


@pytest.mark.parametrize("case", _cases(), ids=lambda c: c["id"])
def test_document_format_fixture(case):
    kind = case["kind"]
    if kind == "print":
        esm = case["esm"]
        if "written" in case:
            assert _typed(canonicalize_document(case["written"])) == _typed(esm)
        for fmt in FORMATS:
            assert print_document(esm, fmt) == case[fmt], f"print {fmt}"
            assert _typed(parse_document(case[fmt], fmt)) == _typed(esm), f"parse {fmt}"
    elif kind == "variant":
        fmt = case["surface"]
        assert _typed(parse_document(case["input"], fmt)) == _typed(case["esm"])
        assert print_document(case["esm"], fmt) == case["canonical"]
    elif kind == "refusal":
        with pytest.raises(ParseError) as info:
            parse_document(case["input"], case["surface"])
        assert getattr(info.value, "code", None) == case["error"]
    else:
        raise AssertionError(f"unknown case kind {kind!r}")


def _math_cases():
    return [c for c in _cases() if "math" in c]


@pytest.mark.parametrize("case", _math_cases(), ids=lambda c: c["id"])
def test_print_math_reproduces_the_display(case):
    """The ``math`` field of a case is the math of the case's one equation
    display, so ``print_math`` of that equation under the names its model
    declares (the keys of its variables, species and parameters, and the
    document's index sets) gives it in both formats. A case whose model or
    document declares expression templates is skipped: no template is in scope
    for ``print_math``."""
    esm = case["esm"]
    models = esm.get("models", {})
    assert len(models) == 1, "a math case has one model"
    (model,) = models.values()
    if "expression_templates" in model or "expression_templates" in esm:
        pytest.skip("the display depends on a template")
    (eq,) = model["equations"]
    names = [
        k for field in ("variables", "species", "parameters") for k in model.get(field, {})
    ] + list(esm.get("index_sets", {}))
    assert print_math(eq, names, "markdown") == case["math"]["latex"]
    assert print_math(eq, names, DocumentFormat.TYPST) == case["math"]["typst"]


def test_fixture_files_are_nonempty():
    assert len(_cases()) > 100


def test_format_selector_and_entry_points_agree():
    esm = next(c["esm"] for c in _cases() if c["kind"] == "print")
    md, typ = print_markdown(esm), print_typst(esm)
    assert print_document(esm, DocumentFormat.MARKDOWN) == md
    assert print_document(esm, "typst") == typ
    assert _typed(parse_markdown(md)) == _typed(parse_document(md, DocumentFormat.MARKDOWN))
    assert _typed(parse_typst(typ)) == _typed(parse_document(typ, "typst"))
    with pytest.raises(ValueError):
        print_document(esm, "latex")


def test_printing_does_not_mutate_the_document():
    esm = next(c["esm"] for c in _cases() if c["kind"] == "print")
    before = _typed(esm)
    print_markdown(esm)
    print_typst(esm)
    assert _typed(esm) == before


def _corpus() -> list:
    """The ``.esm`` files under ``tests/`` that are JSON objects."""
    out = []
    for path in sorted(FIXTURES_ROOT.rglob("*.esm")):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (ValueError, UnicodeDecodeError):
            continue
        if isinstance(doc, dict):
            out.append((path, doc))
    return out


def test_document_format_corpus_round_trip():
    corpus = _corpus()
    assert len(corpus) > 100, f"only {len(corpus)} corpus documents found"
    failures = []
    for path, doc in corpus:
        canon = canonicalize_document(doc)
        want = _typed(canon)
        for fmt in FORMATS:
            try:
                back = parse_document(print_document(canon, fmt), fmt)
            except Exception as exc:  # noqa: BLE001 - every failure is reported
                failures.append(f"{path.relative_to(FIXTURES_ROOT)} ({fmt}): {exc!r}")
                continue
            if _typed(back) != want:
                failures.append(
                    f"{path.relative_to(FIXTURES_ROOT)} ({fmt}): reads back differently"
                )
    assert not failures, f"{len(failures)} of {2 * len(corpus)} round trips failed:\n" + "\n".join(
        failures
    )


def _esm_lean(binary: str, mode: str, path: Path):
    """``esm-lean <mode> <path>``: its stdout, or ``None`` when it refuses."""
    r = subprocess.run([binary, mode, str(path)], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


@pytest.mark.skipif(
    not os.environ.get("ESM_LEAN"), reason="needs the esm-lean executable (ESM_LEAN)"
)
def test_document_format_matches_lean(tmp_path):
    binary = os.environ["ESM_LEAN"]
    scratch = Path(os.environ.get("ESM_LEAN_SCRATCH") or tmp_path)
    scratch.mkdir(parents=True, exist_ok=True)
    corpus = _corpus()

    def lean_side(item):
        path, _ = item
        stem = scratch / str(path.relative_to(FIXTURES_ROOT)).replace(os.sep, "__")
        canon = _esm_lean(binary, "canon", path)
        if canon is None:
            return None
        canon_path = stem.with_suffix(".canon.json")
        canon_path.write_text(canon, encoding="utf-8")
        out = {"canon": canon}
        for print_mode, parse_mode, ext in (
            ("print-md", "parse-md", ".md"),
            ("print-typ", "parse-typ", ".typ"),
        ):
            text = _esm_lean(binary, print_mode, canon_path)
            out[print_mode] = text
            if text is not None:
                text_path = stem.with_suffix(ext)
                text_path.write_text(text, encoding="utf-8")
                out[parse_mode] = _esm_lean(binary, parse_mode, text_path)
        return out

    with ThreadPoolExecutor(os.cpu_count() or 1) as pool:
        lean = list(pool.map(lean_side, corpus))

    failures = []
    for (path, doc), got in zip(corpus, lean):
        name = str(path.relative_to(FIXTURES_ROOT))
        if got is None:
            failures.append(f"{name}: esm-lean canon refused")
            continue
        canon = canonicalize_document(doc)
        if _typed(json.loads(got["canon"])) != _typed(canon):
            failures.append(f"{name}: canonical forms differ")
            continue
        for fmt, print_mode, parse_mode in (
            ("markdown", "print-md", "parse-md"),
            ("typst", "print-typ", "parse-typ"),
        ):
            lean_text = got[print_mode]
            if lean_text is None:
                failures.append(f"{name}: esm-lean {print_mode} refused")
                continue
            if print_document(canon, fmt) != lean_text:
                failures.append(f"{name}: {print_mode} differs")
            try:
                mine = _typed(parse_document(lean_text, fmt))
            except ParseError:
                mine = None
            theirs = got.get(parse_mode)
            theirs = None if theirs is None else _typed(json.loads(theirs))
            if mine != theirs:
                failures.append(f"{name}: {parse_mode} differs")
    assert not failures, f"{len(failures)} differences over {len(corpus)} documents:\n" + "\n".join(
        failures
    )
