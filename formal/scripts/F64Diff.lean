import Esm.Float64

/-! Reads lines `p q` (integers, `q > 0`) on stdin and prints `num den` of
`Esm.F64.rn (p / q : ℚ)` for each. Driven by `f64-diff.py`. -/

open Esm.F64

partial def loop (inp out : IO.FS.Stream) : IO Unit := do
  let line ← inp.getLine
  if line.isEmpty then return
  match line.trimAscii.toString.splitOn " " with
  | [p, q] =>
    let r : ℚ := rn ((p.toInt! : ℚ) / (q.toInt! : ℚ))
    out.putStrLn s!"{r.num} {r.den}"
  | _ => out.putStrLn "ERR"
  loop inp out

def main : IO Unit := do
  loop (← IO.getStdin) (← IO.getStdout)
