import Esm.Document.Math.RoundTripLatex
import Esm.Document.Math.RoundTripTypst

/-!
# Hand-written input

The round-trip theorems cover what the printer writes; these checks cover spellings a
person writes and the printer never does: binary minus without spaces, scientific
literals spaced any way, `\,` between names, the italic-d derivative against declared
names, and field keys with LaTeX-special characters. Each is evaluated by the kernel.
-/

namespace Esm.Document.Math.HandWritten

open Esm.Document Esm.Document.Math

/-- The parse is `e`. -/
def reads (o : Option Json) (e : Json) : Bool :=
  match o with
  | some x => jbeq x e
  | none => false

def S : Sym := { names := ["x", "k", "a", "T", "n", "N"] }

def x : Json := .str "x"
def k : Json := .str "k"
def a : Json := .str "a"
def int (z : Int) : Json := .num (.int z)

/-! ## Binary minus and negative literals -/

example : reads (parseLatex S "x-1") (node "-" [x, int 1]) = true := by decide +kernel
example : reads (parseLatex S "x - 1") (node "-" [x, int 1]) = true := by decide +kernel
example : reads (parseLatex S "x -1") (node "-" [x, int 1]) = true := by decide +kernel
example : reads (parseLatex S "-1") (int (-1)) = true := by decide +kernel
example : reads (parseLatex S "2-x") (node "-" [int 2, x]) = true := by decide +kernel
example : reads (parseLatex S "k-1-x") (node "-" [node "-" [k, int 1], x]) = true := by decide +kernel
example : reads (parseLatex S "a \\cdot -1") (node "*" [a, int (-1)]) = true := by decide +kernel
example : reads (parseLatex S "a\\cdot-1") (node "*" [a, int (-1)]) = true := by decide +kernel
example : reads (parseLatex S "x^{-1}") (node "^" [x, int (-1)]) = true := by decide +kernel
example : reads (parseLatex S "x = -1") (node "==" [x, int (-1)]) = true := by decide +kernel
example : reads (parseLatex S "k-2x") (node "-" [k, node "*" [int 2, x]]) = true := by decide +kernel
/-- `-0` is a minus sign and `0`: the literal has no sign to carry. -/
example : reads (parseLatex S "k-0") (node "-" [k, int 0]) = true := by decide +kernel

example : reads (parseTypst S "x-1") (node "-" [x, int 1]) = true := by decide +kernel
example : reads (parseTypst S "x - 1") (node "-" [x, int 1]) = true := by decide +kernel
example : reads (parseTypst S "-1") (int (-1)) = true := by decide +kernel
example : reads (parseTypst S "2-x") (node "-" [int 2, x]) = true := by decide +kernel
example : reads (parseTypst S "a dot -1") (node "*" [a, int (-1)]) = true := by decide +kernel
example : reads (parseTypst S "x^(-1)") (node "^" [x, int (-1)]) = true := by decide +kernel

/-! ## Scientific literals -/

def thousands : Json := int 2000
def tiny : Json := .num (.dec false [1, 5] (-12))

example : reads (parseLatex S "2 \\times 10^{3}") thousands = true := by decide +kernel
example : reads (parseLatex S "2\\times 10^{3}") thousands = true := by decide +kernel
example : reads (parseLatex S "2\\times10^{3}") thousands = true := by decide +kernel
example : reads (parseLatex S "2  \\times  10^{3}") thousands = true := by decide +kernel
example : reads (parseLatex S "2 \\times 10 ^ { 3 }") thousands = true := by decide +kernel
example : reads (parseLatex S "1.5\\times 10^{-12}") tiny = true := by decide +kernel
example : reads (parseLatex S "1.5 \\times 10^{-12}") tiny = true := by decide +kernel
/-- A non-integer exponent is not the literal shape: an ordinary product. -/
example : reads (parseLatex S "3 \\times 10^{n}") (node "*" [int 3, node "^" [int 10, .str "n"]]) = true := by
  decide +kernel

example : reads (parseTypst S "2 times 10^3") thousands = true := by decide +kernel
example : reads (parseTypst S "2times 10^3") thousands = true := by decide +kernel
example : reads (parseTypst S "2 times 10^( 3 )") thousands = true := by decide +kernel
example : reads (parseTypst S "1.5 times 10^(-12)") tiny = true := by decide +kernel
example : reads (parseTypst S "1.5times 10 ^ (-12)") tiny = true := by decide +kernel
example : reads (parseTypst S "3 times 10^n") (node "*" [int 3, node "^" [int 10, .str "n"]]) = true := by
  decide +kernel

/-! ## The thin space -/

def meters : Json :=
  .obj [("args", .arr []), ("op", .str "const"), ("units", .str "m"), ("value", int 3)]

example : reads (parseLatex S "3\\,\\mathrm{m}") meters = true := by decide +kernel
example : reads (parseLatex S "3 \\, \\mathrm{m}") meters = true := by decide +kernel
example : reads (parseLatex S "k\\,T") (node "*" [k, .str "T"]) = true := by decide +kernel
example : reads (parseLatex S "k \\, T") (node "*" [k, .str "T"]) = true := by decide +kernel
example : reads (parseTypst S "3 thin upright(\"m\")") meters = true := by decide +kernel

/-! ## The italic-d derivative and declared names -/

def Sd : Sym := { names := ["x"] }
def Sdx : Sym := { names := ["x", "dx", "dt"] }
def Sdx1 : Sym := { names := ["x", "dx"] }

/-- Neither `dx` nor `dt` declared: the derivative of `x`. -/
example : reads (parseLatex Sd "\\frac{dx}{dt}") (dNode x "t") = true := by decide +kernel
example : reads (parseLatex Sd "\\frac{d x}{d t}") (dNode x "t") = true := by decide +kernel
example : reads (parseTypst Sd "(d x)/(d t)") (dNode x "t") = true := by decide +kernel
/-- `dx` and `dt` declared: the declared whole words win, a quotient. -/
example : reads (parseLatex Sdx "\\frac{dx}{dt}") (node "/" [.str "dx", .str "dt"]) = true := by
  decide +kernel
example : reads (parseTypst Sdx "(dx)/(dt)") (node "/" [.str "dx", .str "dt"]) = true := by
  decide +kernel
/-- Only `dx` declared: no derivative, and `dt` is unknown, so the input is refused. -/
example : (parseLatex Sdx1 "\\frac{dx}{dt}").isNone = true := by decide +kernel

/-! ## Field keys -/

/-- A key with LaTeX-special characters prints with each written `{\char NNN}`. -/
example : Latex.render (keyToks .latex "a%b$") = "\\mathrm{a{\\char037}b{\\char036}}".toList := by
  decide +kernel

/-- And reads back. -/
example : reads (parseLatex S "\\operatorname{foo}(x; \\mathrm{a{\\char037}b} = 1)")
    (mkNode "foo" [x] [("a%b", int 1)]) = true := by decide +kernel

/-- A node whose field key is not an identifier prints in the escape form, where the key
is a JSON string with `%` and `$` as `\uXXXX`: no raw `%` or `$` reaches the LaTeX. -/
def oddKey : Json := .obj [("a%b$", int 1), ("args", .arr [x]), ("op", .str "foo")]

example : ((printLatex S oddKey).toList.contains '%' || (printLatex S oddKey).toList.contains '$') = false := by
  decide +kernel
example : reads (parseLatex S (printLatex S oddKey)) oddKey = true := by decide +kernel

end Esm.Document.Math.HandWritten
