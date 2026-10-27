import Adapter.Datetime
import Adapter.Interp
import Adapter.Units

/-! The `esm-lean` adapter: `esm-lean <mode> <args>…`. Each mode reads the same
fixture files the binding adapters read and prints the same result JSON. -/

def usage : String :=
  "usage: esm-lean <mode> <args>…\n" ++
  "modes:\n" ++
  "  datetime <expected.json>   evaluate a tests/closed_functions/datetime fixture\n" ++
  "  interp <expected.json>     evaluate a tests/closed_functions/interp fixture\n" ++
  "  units <unit_verdicts.json> resolve every unit string in a unit-registry golden\n"

def main (args : List String) : IO UInt32 := do
  match args with
  | "datetime" :: rest => Adapter.Datetime.main rest
  | "interp" :: rest => Adapter.Interp.main rest
  | "units" :: rest => Adapter.Units.main rest
  | _ => IO.eprint usage; return 2
