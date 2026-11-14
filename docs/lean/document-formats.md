An ESM document can be written as a Markdown (`.md`) or Typst (`.typ`) source
file as well as `.esm` JSON. This chapter specifies those source formats: the
notation tables, the LaTeX and Typst math grammars, the value codecs (JSON, the
strict YAML subset, Typst dictionaries) and the unit spellings. It is not a
description of a Lean model; it *is* the Lean model, `formal/` in the
EarthSciAST repository, rendered page by page.

The Lean modules are the authority for these formats: `esm-spec.md` only points
here, and a change to the notation is a change to the modules first. Every proof
is checked by Lean in EarthSciAST's CI (the `formal` workflow; `formal/README.md`
explains how to build it locally).
