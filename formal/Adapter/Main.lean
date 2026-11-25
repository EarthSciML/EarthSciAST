import Adapter.Determinism
import Adapter.Templates
import Adapter.Static
import Adapter.Units
import Adapter.Doc
import Adapter.Expressions

/-! The `esm-lean` adapter: `esm-lean <mode> <args>…`. Each mode reads the same
fixture files the binding adapters read and prints the same result JSON. -/

def usage : String :=
  "usage: esm-lean <mode> <args>…\n" ++
  "modes:\n" ++
  "  templates <document.esm> [model [case.json]] evaluate the apply_operator equations of a document\n" ++
  "  static-assertions <doc.esm> <model> evaluate requested static assertions (JSON on stdin)\n" ++
  "  units <unit_verdicts.json> resolve every unit string in a unit-registry golden\n" ++
  "  expressions <fixture.json> … parse and emit bare expressions for property-corpus conformance\n" ++
  "  canon <doc.esm>              print a document in canonical form (compact JSON)\n" ++
  "  print-md <doc.esm>           print a document as Markdown\n" ++
  "  parse-md <doc.md>            read a Markdown document, print its canonical JSON\n" ++
  "  print-typ <doc.esm>          print a document as Typst\n" ++
  "  parse-typ <doc.typ>          read a Typst document, print its canonical JSON\n" ++
  "  determinism --manifest <manifest.json> --output <result.json> run the exact relational producers\n"

def main (args : List String) : IO UInt32 := do
  match args with
  | "determinism" :: rest => Adapter.Determinism.main rest
  | "templates" :: rest => Adapter.Templates.main rest
  | "static-assertions" :: rest => Adapter.Static.main rest
  | "units" :: rest => Adapter.Units.main rest
  | "expressions" :: rest => Adapter.Expressions.main rest
  | m :: rest =>
    if m ∈ ["canon", "print-md", "parse-md", "print-typ", "parse-typ"] then Adapter.Doc.main m rest
    else do IO.eprint usage; return 2
  | [] => IO.eprint usage; return 2
