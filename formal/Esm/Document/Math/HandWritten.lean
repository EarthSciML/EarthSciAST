import Esm.Document.Math.RoundTripLatex
import Esm.Document.Math.RoundTripTypst

/-!
# Hand-written input

The round-trip theorems cover what the printer writes; these checks cover spellings a
person writes and the printer never does: binary minus without spaces, scientific
literals spaced any way, `\,` between names, the italic-d derivative against declared
names, field keys with LaTeX-special characters, and JSON strings. Each is evaluated by
the kernel.
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

/-! ## Operators in the source formats (esm-spec §1.2, draft 2.4.0) -/

/-- A derivative along an axis other than `t` is `partial`, whichever differential writes it. -/
example : reads (parseLatex S "\\frac{\\partial x}{\\partial a}") (pNode x "a") = true := by decide +kernel
example : reads (parseTypst S "(partial x)/(partial a)") (pNode x "a") = true := by decide +kernel
/-- Along `t`, `\\partial` reads as the time derivative `D`. -/
example : reads (parseLatex S "\\frac{\\partial x}{\\partial t}") (dNode x "t") = true := by decide +kernel
/-- The trailing-operand form, and the earlier `\\operatorname{D}_{x}` spelling of it. -/
example : reads (parseLatex S "\\partial_{a}(x, k)") (dCallNode "a" [x, k]) = true := by decide +kernel
example : reads (parseLatex S "\\operatorname{D}_{a}(x, k)") (dCallNode "a" [x, k]) = true := by decide +kernel
example : reads (parseTypst S "partial_(a)(x, k)") (dCallNode "a" [x, k]) = true := by decide +kernel
example : reads (parseTypst S "op(\"D\")_(a)(x, k)") (dCallNode "a" [x, k]) = true := by decide +kernel
/-- The four `\\nabla` forms, told apart by what follows `\\nabla`. -/
example : reads (parseLatex S "\\nabla x") (node "grad" [x]) = true := by decide +kernel
example : reads (parseLatex S "\\nabla \\cdot x") (node "div" [x]) = true := by decide +kernel
example : reads (parseLatex S "\\nabla^{2} x") (node "laplacian" [x]) = true := by decide +kernel
example : reads (parseLatex S "\\nabla \\times x") (node "curl" [x]) = true := by decide +kernel
example : reads (parseTypst S "nabla x") (node "grad" [x]) = true := by decide +kernel
example : reads (parseTypst S "nabla dot x") (node "div" [x]) = true := by decide +kernel
example : reads (parseTypst S "nabla^2 x") (node "laplacian" [x]) = true := by decide +kernel
example : reads (parseTypst S "nabla times x") (node "curl" [x]) = true := by decide +kernel
/-- Trees, not identities: `\\nabla \\cdot \\nabla x` is `div(grad(x))`. -/
example : reads (parseLatex S "\\nabla \\cdot \\nabla x") (node "div" [node "grad" [x]]) = true := by
  decide +kernel
/-- The operand is read at the level of a power base: `\\nabla x k` is a product with `grad(x)`. -/
example : reads (parseLatex S "\\nabla x \\cdot k") (node "*" [node "grad" [x], k]) = true := by
  decide +kernel
/-- `\\nabla x^{2}` is refused: the operand of a `\\nabla` form is not a power. -/
example : (parseLatex S "\\nabla x^{2}").isNone = true := by decide +kernel

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

/-! ## JSON strings render in KaTeX's text mode -/

/-- An open operator with a string field holding braces. -/
def strOp : Json := mkNode "myop" [k] [("s", .str "a{b}")]

/-- The string prints inside `\text{"…"}` with the braces escaped, not as `\u007B`, which
KaTeX refuses in math mode ("accent \u works only in text mode"). -/
example : printLatex S strOp = "\\operatorname{myop}(k; \\mathrm{s} = \\text{\"a\\{b\\}\"})" := by
  decide +kernel
example : reads (parseLatex S (printLatex S strOp)) strOp = true := by decide +kernel

/-- Every other awkward character is `{\char NNN}`: `$`, `%`, `~`, `\`, a line break, a
non-ASCII letter, and (seven digits) a character above 999. No `$` or line break reaches
the LaTeX, and it reads back. -/
def oddStr : Json := mkNode "myop" [k] [("s", .str "x$%é\n\"_~\\ 中")]

example : printLatex S oddStr = "\\operatorname{myop}(k; \\mathrm{s} = \\text{\"x{\\char036}{\\char037}{\\char233}{\\char010}\"\\_{\\char126}{\\char092} {\\char0020013}\"})" := by
  decide +kernel
example : reads (parseLatex S (printLatex S oddStr)) oddStr = true := by decide +kernel

/-- The earlier spelling, the string double-quoted with JSON escapes in math mode, still
reads. -/
example : reads (parseLatex S "\\operatorname{myop}(k; \\mathrm{s} = \"a\\u007Bb\\u007D\")") strOp = true := by
  decide +kernel

/-! ## Array notation (2026-11-15) -/

/-- A bare `\operatorname{n}` is a template applied with no bindings; with `()` it is an
open operator with no operands. -/
example : reads (parseLatex S "\\operatorname{dlon}") (tNode "dlon" []) = true := by decide +kernel
example : reads (parseLatex S "\\operatorname{dlon}()") (node "dlon" []) = true := by decide +kernel
example : reads (parseTypst S "op(\"dlon\")") (tNode "dlon" []) = true := by decide +kernel
example : reads (parseTypst S "op(\"dlon\")()") (node "dlon" []) = true := by decide +kernel

/-- `\times [` outside a region is still a product with a bracket group. -/
example : reads (parseLatex S "a \\times [x + 1]") (node "*" [a, node "+" [x, int 1]]) = true := by
  decide +kernel
example : reads (parseLatex S "a \\times[x + 1]") (node "*" [a, node "+" [x, int 1]]) = true := by
  decide +kernel
example : reads (parseTypst S "a times [x + 1]") (node "*" [a, node "+" [x, int 1]]) = true := by
  decide +kernel

/-- A `makearray` table, the region product spaced any way. -/
def table : Json :=
  mkJson ⟨[], [[(int 1, .str "N")], [(int 1, int 1), (int 2, int 2)]], [x, int 0]⟩

example : reads (parseLatex S "\\left[\\begin{array}{l|l} x & [1, N] \\\\ 0 & [1, 1]\\times[2, 2] \\end{array}\\right]")
    table = true := by decide +kernel
example : reads (parseTypst S "mat(delim: \"[\", augment: #1, x, [1, N]; 0, [1, 1] times [2, 2])")
    table = true := by decide +kernel
example : reads (parseLatex S (printLatex S table)) table = true := by decide +kernel
example : reads (parseTypst S (printTypst S table)) table = true := by decide +kernel

/-- A lone equality filter followed by a superscript set is the filter, not a dense range. -/
def filtSet : Json :=
  .obj [("args", .arr [.str "a"]), ("expr", x), ("filter", node "==" [k, int 1]), ("op", .str "faq"),
    ("output_idx", .arr [])]

example : reads (parseLatex S "\\sum_{k = 1}^{\\{a\\}} x") filtSet = true := by decide +kernel
example : reads (parseLatex S (printLatex S filtSet)) filtSet = true := by decide +kernel

end Esm.Document.Math.HandWritten
