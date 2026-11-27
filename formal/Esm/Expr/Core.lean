import Esm.Closed.Interp.Template
import Esm.Float64.Decimal
import Esm.Expr.Array
import Mathlib.Analysis.SpecialFunctions.Complex.Arg
import Mathlib.Analysis.SpecialFunctions.Pow.Real

import Esm.Semiring.Registry

/-!
# The ESM Expression AST and its evaluator (esm-spec §4.1–4.3), first slice

This is the start of the model's expression core: one Lean type for the JSON
Expression AST of §4.1 and an evaluator over the scalar types of
`Esm/Closed/Interp.lean` (`Scalar`), so the same code runs at the exact `Num`,
at the binary64 `Bin64`, and at the adapter's `Float`.

The evaluator covers the scalar operations and the array operations below:

* numeric literals (a JSON number `m · 10^-e`, rounded as the scalar type
  rounds, `Lits.ofDec`);
* `const` nodes (§4.3.3: a scalar, or a rank-1, rank-2 or rank-3 array of
  literals);
* references to variables and parameters, looked up in an environment, whose
  values may be arrays (§4.3.3: a variable whose defining equation is a
  `const` node gathers like an inline `const`);
* `+` and `*` (n-ary left folds), binary `-` and `/` (§4.2 Arithmetic);
* unary `-` and `neg`;
* `<=`, `>=`, `<`, `>`, `==`, `!=` (IEEE comparisons; §4.2 encodes a comparison
  as `1`/`0` in a numeric position), `and`, `or`, `not` (an operand holds when
  it is a nonzero number) and `ifelse`, which evaluates only the branch it
  takes (§4.3.3 "Only a read that happens can fault");
* the boolean literals `true` / `false`, `sign`, and the elementary functions
  `^`, `floor`, `ceil`, `abs`, `sqrt`, `sin`, `cos`, `tan`, `atan2`, `exp`, `log`
  and `log10`, through the scalar operations or `Elem`;
* `min` / `max`, n-ary with arity ≥ 2, left folds, NaN-propagating (§4.2: IEEE
  754-2019 `minimum`/`maximum`, not `minNum`/`maxNum`);
* `index` with 1-based integer subscripts, checking each subscript against
  the matching extent (§4.3.3, `E_TREEWALK_CONSTARRAY_OOB`);
* scalar and shaped `faq` over dense, stepped or sized index-set ranges
  (§4.3.1, §9.6.1). Output symbols are bound in `output_idx` order and
  contracted tuples fold in symbol order. Only admitted tuples contribute.
  A reverse window over the node's own output index folds from the top.
  The numeric identities are `+0.0`, `1`, `+∞` and `−∞` for `+`, `*`, `min`
  and `max`, respectively. A pointwise cell returns its admitted body value
  directly. A nested `faq` has its own bindings.
* scalar `bool_and_or` (`CONFORMANCE_SPEC` §5.6.1), with exact zero/one
  results and NaN counted as a nonzero admitted term.

The model infers an omitted range from a bare subscript into a known array.
Ragged contractions visit each parent's positions in order. Join nodes are
outside the modelled slice. Signed zeros are
preserved at `Float`. The exact `Num` and `Bin64` types do not distinguish the
zero signs.
-/

namespace Esm.Expr

open Esm.Closed Esm.Closed.Template Scalar

/-! ## Literals and integral values -/

/-- How a scalar type reads a JSON numeric literal and recognises an integral
value (an `index` argument, a `ranges` bound). -/
class Lits (α : Type) where
  /-- The literal `m · 10^-e`, rounded as the type rounds. -/
  ofDec : Int → Nat → α
  /-- `some k` when the value is the finite integer `k`. -/
  toInt? : α → Option Int

noncomputable instance : Lits Num where
  ofDec m e := .fin ((m : ℝ) / 10 ^ e)
  toInt? x := match x with
    | .fin r => if ((⌊r⌋ : ℤ) : ℝ) = r then some ⌊r⌋ else none
    | .nan => none

noncomputable instance : Lits Bin64 where
  ofDec m e := .fin (Esm.F64.rn ((m : ℝ) / 10 ^ e))
  toInt? x := match x with
    | .fin r => if ((⌊r⌋ : ℤ) : ℝ) = r then some ⌊r⌋ else none
    | .nan => none

instance : Lits Float where
  ofDec := Esm.F64.Decimal.toFloat
  toInt? x :=
    if x.isFinite && x.floor == x && x.abs < 9.0e15 then
      some (if x < 0 then -((-x).toUInt64.toNat : Int) else (x.toUInt64.toNat : Int))
    else none

/-! ## Elementary functions -/

/-- The §4.2 elementary functions and unary minus on a scalar type. At `Num`
they are the exact real functions; at `Bin64` each is the real function
rounded once to nearest (`floor`, `abs` and `neg` are exact on a double; for
`sqrt`, `sin`, `cos` and `atan2` this is the correctly rounded result, an
idealisation of a binding's libm); at `Float` they are Lean's `Float`
functions. NaN propagates, and `sqrt` of a negative number is NaN. -/
class Elem (α : Type) where
  floor : α → α
  ceil : α → α
  exp : α → α
  log : α → α
  log10 : α → α
  pow : α → α → α
  tan : α → α
  abs : α → α
  neg : α → α
  sqrt : α → α
  sin : α → α
  cos : α → α
  /-- `atan2(y, x)`. -/
  atan2 : α → α → α

/-- The angle of the point `(x, y)` in `(-π, π]` (`0` at the origin), the
real `atan2(y, x)`. -/
noncomputable def realAtan2 (y x : ℝ) : ℝ := Complex.arg ⟨x, y⟩

/-- A negative real base has a real power only for integral exponents in
this model. The exact model represents out-of-domain results as NaN. -/
noncomputable def realPow (a b : ℝ) : Num :=
  if a < 0 then
    if ((⌊b⌋ : ℤ) : ℝ) = b then .fin (a ^ (⌊b⌋ : ℤ)) else .nan
  else if a = 0 ∧ b < 0 then .nan
  else .fin (Real.rpow a b)

noncomputable instance : Elem Num where
  floor | .fin r => .fin ⌊r⌋ | .nan => .nan
  ceil | .fin r => .fin ⌈r⌉ | .nan => .nan
  exp | .fin r => .fin (Real.exp r) | .nan => .nan
  log | .fin r => if 0 < r then .fin (Real.log r) else .nan | .nan => .nan
  log10 | .fin r => if 0 < r then .fin (Real.log r / Real.log 10) else .nan | .nan => .nan
  pow | .fin a, .fin b => realPow a b | _, _ => .nan
  tan | .fin r => .fin (Real.tan r) | .nan => .nan
  abs | .fin r => .fin |r| | .nan => .nan
  neg | .fin r => .fin (-r) | .nan => .nan
  sqrt | .fin r => if r < 0 then .nan else .fin (Real.sqrt r) | .nan => .nan
  sin | .fin r => .fin (Real.sin r) | .nan => .nan
  cos | .fin r => .fin (Real.cos r) | .nan => .nan
  atan2 | .fin y, .fin x => .fin (realAtan2 y x) | _, _ => .nan

noncomputable instance : Elem Bin64 where
  floor | .fin r => .fin ⌊r⌋ | .nan => .nan
  ceil | .fin r => .fin ⌈r⌉ | .nan => .nan
  exp | .fin r => .fin (Esm.F64.rn (Real.exp r)) | .nan => .nan
  log | .fin r => if 0 < r then .fin (Esm.F64.rn (Real.log r)) else .nan | .nan => .nan
  log10 | .fin r => if 0 < r then .fin (Esm.F64.rn (Real.log r / Real.log 10)) else .nan | .nan => .nan
  pow
    | .fin a, .fin b => match realPow a b with
      | .fin r => .fin (Esm.F64.rn r)
      | .nan => .nan
    | _, _ => .nan
  tan | .fin r => .fin (Esm.F64.rn (Real.tan r)) | .nan => .nan
  abs | .fin r => .fin |r| | .nan => .nan
  neg | .fin r => .fin (-r) | .nan => .nan
  sqrt | .fin r => if r < 0 then .nan else .fin (Esm.F64.rn (Real.sqrt r)) | .nan => .nan
  sin | .fin r => .fin (Esm.F64.rn (Real.sin r)) | .nan => .nan
  cos | .fin r => .fin (Esm.F64.rn (Real.cos r)) | .nan => .nan
  atan2 | .fin y, .fin x => .fin (Esm.F64.rn (realAtan2 y x)) | _, _ => .nan

instance : Elem Float where
  floor := Float.floor
  ceil := Float.ceil
  exp := Float.exp
  log := Float.log
  log10 := Float.log10
  pow := Float.pow
  tan := Float.tan
  abs := Float.abs
  neg := fun x => -x
  sqrt := Float.sqrt
  sin := Float.sin
  cos := Float.cos
  atan2 := Float.atan2

/-! ## The AST -/

/-- A `const` node's `value`: a numeric leaf or a nested array. -/
inductive Const where
  | leaf (m : Int) (e : Nat)
  | arr (cs : List Const)

/-- `faq.output_idx` contains bound symbols and literal singleton axes (§4.3.1). -/
inductive OutputIndex where
  | symbol (name : String)
  | singleton

def OutputIndex.mapSymbol (f : String → String) : OutputIndex → OutputIndex
  | .symbol name => .symbol (f name)
  | .singleton => .singleton

mutual

/-- The ESM Expression AST (§4.1). A JSON number is `num`, a bare string a
`var`, an object with an `op` a `const`, a `faq`, an `apply_operator`
reference or a generic `node` (its remaining scalar fields, which this slice
never needs, are not carried). -/
inductive Ast where
  | num (m : Int) (e : Nat)
  | var (name : String)
  | const (c : Const)
  | node (op : String) (args : List Ast)
  | array (op : ShapeOp) (args : List Ast)
  /-- `faq`: `output_idx`, `reduce`, `ranges`, `expr`, `args`. -/
  | faq (outputIdx : List OutputIndex) (reduce : String) (ranges : Ranges) (expr : Ast)
      (args : List Ast)
  /-- `faq` with a `filter`: `output_idx`, `reduce`, `ranges`, `filter`, `expr`,
  `args`. -/
  | faqWhere (outputIdx : List OutputIndex) (reduce : String) (ranges : Ranges) (filter : Ast)
      (expr : Ast) (args : List Ast)
  /-- `apply_operator`: the template `name` with its `bindings`
  (§9.6.2). It denotes its expansion (§9.6.4 rule 2); `eval` refuses it, and
  `Esm.Expr.expandRefs` replaces it by that expansion. -/
  | apply (name : String) (bindings : Binds)

/-- A `faq`'s `ranges` object, in key order: each symbol with its tuple
(`[start, stop]` or `[start, step, stop]`). -/
inductive Ranges where
  | nil
  | cons (sym : String) (tuple : List Ast) (rest : Ranges)
  /-- A range over a whole index set, `{"from": set}`. The set's extent
  is bound in the evaluation environment; its name is a substitution site. -/
  | fromSet (sym : String) (set : String) (rest : Ranges)
  /-- A range over a ragged set at the current values of `parents`. -/
  | fromRagged (sym : String) (set : String) (parents : List String) (rest : Ranges)

/-- An `apply_operator` node's `bindings` object, in key order. -/
inductive Binds where
  | nil
  | cons (param : String) (value : Ast) (rest : Binds)

end

structure RaggedUse where
  name : String
  set : String
  parents : List String

def Ranges.raggedUses : Ranges → List RaggedUse
  | .nil => []
  | .cons _ _ rest | .fromSet _ _ rest => rest.raggedUses
  | .fromRagged name set parents rest => ⟨name, set, parents⟩ :: rest.raggedUses

/-- All symbols bound by the query's declared ranges. -/
def Ranges.names : Ranges → List String
  | .nil => []
  | .cons name _ rest | .fromSet name _ rest | .fromRagged name _ _ rest => name :: rest.names

/-! ## Values and errors -/

/-- A value: a scalar or a rank-1, rank-2 or rank-3 array (row-major). -/
inductive Val (α : Type) where
  | num (v : α)
  | arr1 (v : List α)
  | arr2 (v : List (List α))
  | arr3 (v : List (List (List α)))
  /-- Row-major cells with explicit extents, preserving zero-length axes
  and the infinite cells produced by empty extrema reductions. -/
  | shaped (dims : List Nat) (cells : List (Val α))
  /-- `+∞` (`neg = false`) or `-∞`: the identity of an empty `min` / `max`
  reduction (§4.3.1). Scalar extrema, multiplication, and Boolean FAQ terms
  consume it explicitly because the exact scalar types have no infinity. -/
  | inf (neg : Bool)
  /-- Registry metadata stored under `raggedSetKey`. Numeric operands cannot
  read this reserved environment key. -/
  | raggedSet (parentRank : Nat) (offsets values : String)

@[simp] def Val.rank {α : Type} : Val α → Nat
  | .arr1 _ => 1
  | .arr2 _ => 2
  | .arr3 _ => 3
  | .shaped dims _ => dims.length
  | _ => 0

/-- The rectangular arrays recognized by the evaluator, in output-axis order. -/
def Val.arrayData {α : Type} : Val α → Option (List Nat × List (Val α))
  | .arr1 values => some ([values.length], values.map .num)
  | .arr2 rows => do
    let width := rows.head?.map List.length |>.getD 0
    if rows.all (fun row => row.length == width) then
      some ([rows.length, width], rows.flatMap (List.map .num))
    else none
  | .arr3 planes => do
    let first := planes.head?.getD []
    let width := first.head?.map List.length |>.getD 0
    if planes.all (fun plane => plane.length == first.length &&
        plane.all (fun row => row.length == width)) then
      some ([planes.length, first.length, width], planes.flatMap (·.flatMap (List.map .num)))
    else none
  | .shaped dims cells => some (dims, cells)
  | _ => none

inductive EvalError where
  /-- Outside the modelled slice: an explicit refusal, not a value. -/
  | unsupported (what : String)
  | unbound (name : String)
  | typeError (what : String)
  | shapeMismatch
  /-- `E_TREEWALK_CONSTARRAY_OOB` (§4.3.3). -/
  | outOfRange
  | nonIntegral

/-- Bindings, newest first. -/
abbrev Env (α : Type) := List (String × Val α)

section Eval

variable {α : Type} [Scalar α] [Lits α] [Elem α]

def zero : α := Lits.ofDec 0 0
def one : α := Lits.ofDec 1 0

/-- §4.2: a comparison in a numeric position is `1` or `0`. -/
def ofBool (b : Bool) : α := if b then one else zero

/-- An `ifelse` condition holds when it is a nonzero number (false for NaN). -/
def truthy (v : α) : Bool := lt zero v || lt v zero

/-- IEEE 754-2019 `maximum`: NaN if either side is NaN. At `Float`, the
extrema order places `-0.0` below `+0.0`. -/
def fmax (a b : α) : α :=
  if isNaN a then a else if isNaN b then b else if ltExtrema a b then b else a

/-- IEEE 754-2019 `minimum`. -/
def fmin (a b : α) : α :=
  if isNaN a then a else if isNaN b then b else if ltExtrema b a then b else a

def asNum : Val α → Except EvalError α
  | .num v => .ok v
  | _ => .error (.typeError "expected a scalar")

def asInt (v : α) : Except EvalError Int :=
  match Lits.toInt? v with
  | some k => .ok k
  | none => .error .nonIntegral

/-- `index` (§4.3.3), 1-based, each index checked against its own dimension. -/
def indexVal : Val α → List Int → Except EvalError α
  | .num x, [] => .ok x
  | .arr1 xs, [i] =>
    if h : 1 ≤ i ∧ i ≤ xs.length then .ok (xs[(i - 1).toNat]'(by omega)) else .error .outOfRange
  | .arr2 rows, [i, j] =>
    if h : 1 ≤ i ∧ i ≤ rows.length then
      let row := rows[(i - 1).toNat]'(by omega)
      if h' : 1 ≤ j ∧ j ≤ row.length then .ok (row[(j - 1).toNat]'(by omega))
      else .error .outOfRange
    else .error .outOfRange
  | .arr3 m, [i, j, k] =>
    if h : 1 ≤ i ∧ i ≤ m.length then
      let pl := m[(i - 1).toNat]'(by omega)
      if h' : 1 ≤ j ∧ j ≤ pl.length then
        let row := pl[(j - 1).toNat]'(by omega)
        if h'' : 1 ≤ k ∧ k ≤ row.length then .ok (row[(k - 1).toNat]'(by omega))
        else .error .outOfRange
      else .error .outOfRange
    else .error .outOfRange
  | _, _ => .error (.typeError "index: operand rank and index count disagree")

/-- The row-major offset, checking each one-based subscript against its own axis. -/
def indexOffset (offset : Nat) : List Nat → List Int → Except EvalError Nat
  | [], [] => .ok offset
  | dim :: dims, i :: is =>
    if 1 ≤ i ∧ i ≤ (dim : Int) then indexOffset (offset * dim + (i - 1).toNat) dims is
    else .error .outOfRange
  | _, _ => .error (.typeError "index: operand rank and index count disagree")

/-- Check leading coordinates and read a cell or a trailing slice from a
rectangular array's row-major storage. -/
def indexRect (data : ArrayData (Val α)) (subscripts : List Int) :
    Except EvalError (Val α) := do
  let n := subscripts.length
  if n > data.dims.length then
    throw (.typeError "index: operand rank and index count disagree")
  let offset ← indexOffset 0 (data.dims.take n) subscripts
  if n = data.dims.length then
    match data.cells[offset]? with
    | some cell => return cell
    | none => throw (.typeError "index: inconsistent array extents")
  else
    let slice := data.trailingSlice n offset
    unless slice.cells.length == slice.dims.prod do
      throw (.typeError "index: inconsistent array extents")
    return .shaped slice.dims slice.cells

/-- Fix leading indices. A complete gather returns a cell, and a partial
gather keeps the trailing axes, including zero-length extents. -/
def indexCell (value : Val α) (subscripts : List Int) : Except EvalError (Val α) :=
  match value with
  | .shaped dims cells => indexRect ⟨dims, cells⟩ subscripts
  | .inf neg => if subscripts.isEmpty then pure (.inf neg) else
      throw (.typeError "index: operand rank and index count disagree")
  | _ =>
    if subscripts.length < value.rank then do
      let some (dims, cells) := value.arrayData
        | throw (.typeError "index: expected a rectangular array")
      indexRect ⟨dims, cells⟩ subscripts
    else .num <$> indexVal value subscripts

def constLeaf : Const → Except EvalError α
  | .leaf m e => .ok (Lits.ofDec m e)
  | .arr _ => .error (.unsupported "const: array rank above 3")

/-- A rank-1 row of a `const` array. -/
def constRow : Const → Except EvalError (List α)
  | .arr r => r.mapM constLeaf
  | .leaf _ _ => .error (.unsupported "const: ragged")

/-- A rank-2 plane of a `const` array. -/
def constPlane : Const → Except EvalError (List (List α))
  | .arr r => r.mapM constRow
  | .leaf _ _ => .error (.unsupported "const: ragged")

def constVal : Const → Except EvalError (Val α)
  | .leaf m e => .ok (.num (Lits.ofDec m e))
  | .arr cs =>
    match cs.mapM constLeaf with
    | .ok v => .ok (.arr1 v)
    | .error _ =>
      match cs.mapM constRow with
      | .ok v => .ok (.arr2 v)
      | .error _ =>
        match cs.mapM constPlane with
        | .ok v => .ok (.arr3 v)
        | .error e => .error e

/-- The index values of a dense range `[a, b]`, in increasing order. -/
def indices (a b : Int) : List Int :=
  (List.range (b + 1 - a).toNat).map (fun i : Nat => a + (i : Int))

/-- The evaluable ops of the slice whose operands are all evaluated (every op
but `ifelse`). -/
inductive StrictOp where
  | index | add | mul | sub | div | le | ge | lt | gt | max | min
  | eq | ne | and | or | not | neg | floor | abs | sqrt | sin | cos | atan2
  | pow | sign | ceil | exp | log | log10 | tan | bool (value : Bool)
  deriving DecidableEq

/-- How an `op` string is dispatched. -/
inductive Op where
  | ifelse
  | strict (o : StrictOp)
  | other (s : String)

def Op.ofString (s : String) : Op :=
  if s = "ifelse" then .ifelse
  else if s = "index" then .strict .index
  else if s = "+" then .strict .add
  else if s = "*" then .strict .mul
  else if s = "-" then .strict .sub
  else if s = "/" then .strict .div
  else if s = "^" || s = "pow" then .strict .pow
  else if s = "<=" then .strict .le
  else if s = ">=" then .strict .ge
  else if s = "<" then .strict .lt
  else if s = ">" then .strict .gt
  else if s = "max" then .strict .max
  else if s = "min" then .strict .min
  else if s = "==" then .strict .eq
  else if s = "!=" then .strict .ne
  else if s = "and" then .strict .and
  else if s = "or" then .strict .or
  else if s = "not" then .strict .not
  else if s = "neg" then .strict .neg
  else if s = "floor" then .strict .floor
  else if s = "abs" then .strict .abs
  else if s = "sqrt" then .strict .sqrt
  else if s = "sin" then .strict .sin
  else if s = "cos" then .strict .cos
  else if s = "atan2" then .strict .atan2
  else if s = "sign" then .strict .sign
  else if s = "ceil" then .strict .ceil
  else if s = "exp" then .strict .exp
  else if s = "log" then .strict .log
  else if s = "log10" then .strict .log10
  else if s = "tan" then .strict .tan
  else if s = "true" then .strict (.bool true)
  else if s = "false" then .strict (.bool false)
  else .other s

/-- A strict op on its evaluated operands. -/
def applyStrict : StrictOp → List (Val α) → Except EvalError α
  | .index, a :: is => do
    let ks ← is.mapM (fun v => do asInt (← asNum v))
    indexVal a ks
  | .add, v :: vs => do
    let u ← asNum v
    let us ← vs.mapM asNum
    return us.foldl add u
  | .mul, v :: vs => do
    let u ← asNum v
    let us ← vs.mapM asNum
    return us.foldl mul u
  | .sub, [a, b] => do return sub (← asNum a) (← asNum b)
  | .sub, [a] => do return Elem.neg (← asNum a)
  | .neg, [a] => do return Elem.neg (← asNum a)
  | .div, [a, b] => do return div (← asNum a) (← asNum b)
  | .le, [a, b] => do return ofBool (le (← asNum a) (← asNum b))
  | .ge, [a, b] => do
    let u ← asNum a
    let v ← asNum b
    return ofBool (le v u)
  | .lt, [a, b] => do return ofBool (lt (← asNum a) (← asNum b))
  | .gt, [a, b] => do
    let u ← asNum a
    let v ← asNum b
    return ofBool (lt v u)
  | .max, v :: w :: vs => do
    let u ← asNum v
    let us ← (w :: vs).mapM asNum
    return us.foldl fmax u
  | .min, v :: w :: vs => do
    let u ← asNum v
    let us ← (w :: vs).mapM asNum
    return us.foldl fmin u
  | .eq, [a, b] => do
    let u ← asNum a
    let v ← asNum b
    return ofBool (le u v && le v u)
  | .ne, [a, b] => do
    let u ← asNum a
    let v ← asNum b
    return ofBool !(le u v && le v u)
  | .and, [a, b] => do
    let u ← asNum a
    let v ← asNum b
    return ofBool (truthy u && truthy v)
  | .or, [a, b] => do
    let u ← asNum a
    let v ← asNum b
    return ofBool (truthy u || truthy v)
  | .not, [a] => do return ofBool !(truthy (← asNum a))
  | .floor, [a] => do return Elem.floor (← asNum a)
  | .abs, [a] => do return Elem.abs (← asNum a)
  | .sqrt, [a] => do return Elem.sqrt (← asNum a)
  | .sin, [a] => do return Elem.sin (← asNum a)
  | .cos, [a] => do return Elem.cos (← asNum a)
  | .atan2, [a, b] => do return Elem.atan2 (← asNum a) (← asNum b)
  | .pow, [a, b] => do return Elem.pow (← asNum a) (← asNum b)
  | .sign, [a] => do
    let x ← asNum a
    return if lt x zero then Elem.neg one else if lt zero x then one else x
  | .ceil, [a] => do return Elem.ceil (← asNum a)
  | .exp, [a] => do return Elem.exp (← asNum a)
  | .log, [a] => do return Elem.log (← asNum a)
  | .log10, [a] => do return Elem.log10 (← asNum a)
  | .tan, [a] => do return Elem.tan (← asNum a)
  | .bool b, [] => .ok (ofBool b)
  | _, _ => .error (.typeError "operand count")

/-- Some operand is an infinity (the value of an empty `min` / `max`). -/
def hasInf : List (Val α) → Bool
  | [] => false
  | .inf _ :: _ => true
  | _ :: vs => hasInf vs

/-- `min` / `max` over operands some of which are infinities: `+∞` is the
identity of `min` and absorbs `max` unless an operand is NaN (IEEE 754-2019
`minimum` / `maximum`), and `-∞` the reverse. -/
def infMinMax : StrictOp → List (Val α) → Except EvalError (Val α)
  | o, vs => do
    let isMin := o == .min
    unless o == .min || o == .max do throw (.typeError "an infinity outside min / max")
    let nums ← vs.filterMapM (fun v => match v with
      | .num x => pure (some x)
      | .inf _ => pure none
      | _ => throw (.typeError "expected a scalar"))
    -- the absorbing infinity: `-∞` for `min`, `+∞` for `max`
    if vs.any (fun v => match v with | .inf neg => neg == isMin | _ => false) then
      match nums.find? isNaN with
      | some x => return .num x
      | none => return .inf isMin
    match nums with
    | [] => return .inf (!isMin)
    | u :: us => return .num (us.foldl (if isMin then fmin else fmax) u)

/-- Ordinary numeric multiplication may consume the infinite value of an
empty reduction. An infinity multiplied by either signed zero yields NaN. -/
private def mulWithInf : Val α → Val α → Except EvalError (Val α)
  | .num a, .num b => .ok (.num (mul a b))
  | .inf a, .inf b => .ok (.inf (a != b))
  | .inf neg, .num x | .num x, .inf neg =>
    if isNaN x then .ok (.num x)
    else if lt x zero then .ok (.inf (!neg))
    else if lt zero x then .ok (.inf neg)
    else .ok (.num nan)
  | _, _ => .error (.typeError "expected a scalar")

def strictWithInf : StrictOp → List (Val α) → Except EvalError (Val α)
  | .index, [.inf neg] => pure (.inf neg)
  | .mul, v :: vs => vs.foldlM mulWithInf v
  | op, vs => infMinMax op vs

/-- One step of a `faq` `+` fold. -/
def faqStep (acc : α) (v : Val α) : Except EvalError α := do
  return add acc (← asNum v)

/-- The environment key under which the size of the index set `S` is bound
(§4.3.1 `{"from": S}`). It is not an identifier, so it never collides with a
variable, parameter or loop symbol. -/
def setKey (S : String) : String := "{\"from\": \"" ++ S ++ "\"}"

/-- The number of positions a `{"from": S}` range visits: the size bound under
`setKey S` (an interval set's declared `size`). A set with no size bound — a
derived set before value invention, a ragged set — is refused. -/
def setSize (S : String) (env : Env α) : Except EvalError Int :=
  match env.lookup (setKey S) with
  | some (.num v) => asInt v
  | some _ => .error (.typeError s!"index set {S}: size is not a scalar")
  | none => .error (.unsupported s!"\{\"from\": \"{S}\"}: index set {S} has no size bound")

/-- A `faq` reduction `+`, `*`, `min` or `max` over the index values `js`, the
term at `j` given by `term j`: the same folds as the dense-range cases of
`eval`, in the order of `js`. -/
def foldRed (red : String) (js : List Int) (term : Int → Except EvalError (Val α)) :
    Except EvalError (Val α) :=
  if red = "+" then do
    let r ← js.foldlM (fun acc j => do faqStep acc (← term j)) (zero : α)
    return .num r
  else if red = "*" then do
    js.foldlM (fun acc j => do mulWithInf acc (← term j)) (.num one)
  else if red = "min" then
    match js with
    | [] => .ok (.inf false)
    | j :: js => do
      let v ← asNum (← term j)
      let r ← js.foldlM (fun acc i => do return fmin acc (← asNum (← term i))) v
      return .num r
  else if red = "max" then
    match js with
    | [] => .ok (.inf true)
    | j :: js => do
      let v ← asNum (← term j)
      let r ← js.foldlM (fun acc i => do return fmax acc (← asNum (← term i))) v
      return .num r
  else .error (.unsupported s!"faq with reduce {red}")

/-- A numeric FAQ term counts as true exactly when it is not zero. Unlike
a branch condition in this evaluator, an admitted NaN is true (§5.6.1). -/
def nonzeroTerm : Val α → Except EvalError Bool
  | .num v => return isNaN v || truthy v
  | .inf _ => return true
  | _ => throw (.typeError "expected a scalar")

/-- An index range and the function that resolves its visiting order in the
current environment. -/
abbrev FaqRange (α : Type) := String × (Env α → Except EvalError (List Int))

private def outputNames (output : List OutputIndex) : List String :=
  output.filterMap (fun axis => match axis with | .symbol name => some name | .singleton => none)

/-- Reserved environment key for an index set's ragged backing factors. -/
def raggedSetKey (name : String) : String := "\x00ragged_" ++ name

private def raggedFactors (range : RaggedUse) (env : Env α) :
    Except EvalError (String × String) := do
  let some (.raggedSet parentRank offsets values) := env.lookup (raggedSetKey range.set)
    | throw (.typeError s!"faq ragged index set {range.set} is not declared")
  unless range.parents.length == parentRank && parentRank != 0 do
    throw (.typeError s!"faq ragged index set {range.set}: parent rank mismatch")
  return (offsets, values)

/-- Read one parent's length, then bind the positions `1 .. length`. The
member factors are gathered separately by the expression. -/
def raggedPositions (lengths : Val α) (parents : List Int) : Except EvalError (List Int) := do
  let n ← asInt (← asNum (← indexCell lengths parents))
  if n < 0 then throw (.typeError "faq ragged range length must be non-negative")
  return indices 1 n

omit [Scalar α] [Elem α] in
/-- Any parent whose offsets entry is `n` contributes exactly the ascending
sequence of `n` positions, independently of the padded members. -/
theorem raggedPositions_of_count (lengths : Val α) (parents : List Int) (entry : α) (n : Nat)
    (located : indexCell lengths parents = .ok (.num entry))
    (count : Lits.toInt? entry = some (n : Int)) :
    raggedPositions lengths parents = .ok ((List.range n).map (fun i : Nat => 1 + (i : Int))) := by
  have nonnegative : ¬ (n : Int) < 0 := by omega
  simp [raggedPositions, located, asNum, asInt, count, bind, Except.bind, pure, Except.pure,
    indices, nonnegative]

mutual

/-- Inspect a read for the ragged values constraint. An unexpanded application
defers the check, as it may supply the gather after expansion. -/
private def readsRaggedValues (values : String) (bound : List String) : Ast → Bool
  | .var name => (name == values && (!bound.contains name || name.contains '.')) ||
      name.endsWith ("." ++ values)
  | .node _ args | .array _ args => readsRaggedValuesIn values bound args
  | .faq out _ ranges body _ =>
    readsRaggedValues values (outputNames out ++ ranges.names ++ bound) body
  | .faqWhere out _ ranges filter body _ =>
    let bound := outputNames out ++ ranges.names ++ bound
    readsRaggedValues values bound filter || readsRaggedValues values bound body
  | .apply _ _ => true
  | .num _ _ | .const _ => false

private def readsRaggedValuesIn (values : String) (bound : List String) : List Ast → Bool
  | [] => false
  | a :: rest => readsRaggedValues values bound a || readsRaggedValuesIn values bound rest

end

private def checkRaggedUses (out : List OutputIndex) (uses : List RaggedUse) (names : List String)
    (body : Ast) (filter : Option Ast) (env : Env α) : Except EvalError Unit := do
  let outputs := outputNames out
  for range in uses do
    if outputs.contains range.name then throw (.unsupported "faq ragged output index")
    let (_, values) ← raggedFactors range env
    unless range.parents.all (fun parent => names.contains parent) do
      throw (.typeError s!"faq ragged index set {range.set}: parent is not a range symbol")
    unless readsRaggedValues values names body || (filter.any (readsRaggedValues values names)) do
      throw (.typeError "ragged_values_not_gathered")

private def parentFirstRanges (uses : List RaggedUse) (ranges : List (FaqRange α)) :
    Nat → Except EvalError (List (FaqRange α))
  | 0 => if ranges.isEmpty then pure [] else throw (.typeError "cyclic faq ragged parents")
  | fuel + 1 => do
    if ranges.isEmpty then return []
    let ready := fun (axis : FaqRange α) =>
      match uses.find? (fun range => range.name == axis.1) with
      | none => true
      | some range => !range.parents.any (fun p => (ranges.lookup p).isSome)
    let some axis := ranges.find? ready | throw (.typeError "cyclic faq ragged parents")
    let tail ← parentFirstRanges uses (ranges.filter (fun r => r.1 != axis.1)) fuel
    return axis :: tail

/-- A shape-only binding cannot collide with an authored variable or index. -/
def shapeKey (name : String) : String := "\x00shape_" ++ name

private def valueDims (value : Val α) : List Nat :=
  (value.arrayData.map Prod.fst).getD []

private def variableDims (env : Env α) (name : String) : Option (List Nat) :=
  match env.lookup name with
  | some value => some (valueDims value)
  | none => (env.lookup (shapeKey name)).map valueDims

private def gatherDims (env : Env α) : Ast → Except String (List Nat)
  | .var name =>
    match variableDims env name with
    | some dims => pure dims
    | none => throw name
  | .const value => pure ((constVal (α := α) value).toOption.map valueDims |>.getD [])
  | _ => pure []

private abbrev ImplicitFaqAxis := String × Except String Nat

mutual

/-- Extents implied by bare symbols in direct gathers. A nested query owns
its own ranges; its gather sites do not constrain the enclosing query. -/
private def implicitFaqAxes (env : Env α) : Ast → List ImplicitFaqAxis
  | .node "index" (base :: is) =>
    let extents := match gatherDims env base with
      | .ok dims => dims.map Except.ok
      | .error name => List.replicate is.length (.error name)
    let reads := (is.zip extents).filterMap fun (subscript, extent) =>
      match subscript with | .var name => some (name, extent) | _ => none
    reads ++ implicitFaqAxes env base ++ implicitFaqArgs env is
  | .node _ args | .array _ args => implicitFaqArgs env args
  | _ => []

private def implicitFaqArgs (env : Env α) : List Ast → List ImplicitFaqAxis
  | [] => []
  | arg :: args => implicitFaqAxes env arg ++ implicitFaqArgs env args

end

private def declareFaqRanges (output : List OutputIndex) (ranges : List (FaqRange α))
    (body : Ast) (filter : Option Ast) (env : Env α) (onlyOutput : Bool := false) :
    Except EvalError (List (FaqRange α)) := do
  let outputs := outputNames output
  let reads := implicitFaqAxes env body ++ (filter.map (implicitFaqAxes env)).getD []
  let names := (reads.map Prod.fst).eraseDups
  let implicitRanges ← names.filterMapM fun name => do
    let isOutput := outputs.contains name
    if (ranges.lookup name).isSome || (!isOutput && (onlyOutput || (env.lookup name).isSome)) then
      return none
    let candidates := reads.filterMap (fun (k, n) => if k == name then some n else none)
    -- Resolve every extent before binding the index, including indices used
    -- by the filter. The filter still gates evaluation of each term.
    let lengths ← candidates.mapM (fun n => n.mapError .unbound)
    return lengths.min?.map (fun size => (name, fun _ : Env α => .ok (indices 1 (size : Int))))
  return ranges ++ implicitRanges

private def checkedFaqRanges (out : List OutputIndex) (ragged : List RaggedUse)
    (ranges : List (FaqRange α)) (body : Ast) (filter : Option Ast) (env : Env α) :
    Except EvalError (List (FaqRange α)) := do
  let ranges ← declareFaqRanges out ranges body filter env
  checkRaggedUses out ragged (ranges.map Prod.fst) body filter env
  return ranges

private def steppedIndices (lo step hi : Int) : Except EvalError (List Int) :=
  if step == 0 then throw (.typeError "faq range: step is zero")
  else if (0 < step ∧ hi < lo) ∨ (step < 0 ∧ lo < hi) then pure []
  else pure ((List.range ((hi - lo).natAbs / step.natAbs + 1)).map
    (fun i => lo + (i : Int) * step))

/-- A suffix scan folds from the highest admitted term. The comparison must
use the node's own output index and its only contracted index (esm-spec §4.3.1). -/
def reverseFaqWindow (output : List String) (contracted : List String) (filter : Option Ast) : Bool :=
  match contracted, filter with
  | [k], some (.node op [.var a, .var b]) =>
    ((op == ">=" || op == ">") && a == k && output.contains b) ||
    ((op == "<=" || op == "<") && b == k && output.contains a)
  | _, _ => false

/-- Visit contracted tuples in order, passing their current bindings to the fold. -/
def faqFold (reverse : Bool) (step : Val α → Env α → Except EvalError (Val α)) :
    List (FaqRange α) → Env α → Val α → Except EvalError (Val α)
  | [], env, acc => step acc env
  | (name, bounds) :: rest, env, acc => do
    let values ← bounds env
    let values := if reverse then values.mergeSort (fun a b => decide (b ≤ a)) else values
    values.foldlM (fun a i => faqFold reverse step rest ((name, .num (Lits.ofDec i 0)) :: env) a) acc

omit [Scalar α] [Elem α] in
/-- An empty outer range preserves the seeded identity and evaluates no term. -/
theorem faqFold_empty_range (reverse : Bool) (step : Val α → Env α → Except EvalError (Val α))
    (name : String) (bounds : Env α → Except EvalError (List Int)) (rest : List (FaqRange α))
    (env : Env α) (identity : Val α) (empty : bounds env = .ok []) :
    faqFold reverse step ((name, bounds) :: rest) env identity = .ok identity := by
  cases reverse <;> simp [faqFold, empty, bind, Except.bind, pure, Except.pure]

omit [Scalar α] [Elem α] in
/-- A one-axis reverse window is the sequential fold in descending index order. -/
theorem faqFold_reverse (step : Val α → Env α → Except EvalError (Val α))
    (name : String) (bounds : Env α → Except EvalError (List Int)) (env : Env α)
    (identity : Val α) (values : List Int) (resolved : bounds env = .ok values) :
    faqFold true step [(name, bounds)] env identity =
      (values.mergeSort (fun a b => decide (b ≤ a))).foldlM
        (fun acc i => step acc ((name, .num (Lits.ofDec i 0)) :: env)) identity := by
  simp [faqFold, resolved, bind, Except.bind]

/-- The scalar Boolean fold shares the registry's exact OR over admitted terms. -/
private def foldBoolRanges (term : Env α → Except EvalError Bool) :
    List (FaqRange α) → Env α → Except EvalError Bool
  | [], env => term env
  | (name, bounds) :: rest, env => do
    let values ← bounds env
    Semiring.foldBoolM values
      (fun i => foldBoolRanges term rest ((name, .num (Lits.ofDec i 0)) :: env))

private def faqIdentity (red : String) : Except EvalError (Val α) :=
  match red with
  | "+" | "bool_and_or" => pure (.num zero)
  | "*" => pure (.num one)
  | "min" => pure (.inf false)
  | "max" => pure (.inf true)
  | _ => throw (.unsupported s!"faq with reduce {red}")

/-- Combine one admitted term with the cell's current accumulator. -/
def faqCombine (red : String) (acc term : Val α) : Except EvalError (Val α) := do
  match red with
  | "+" => return .num (← faqStep (← asNum acc) term)
  | "*" =>
    if hasInf [acc, term] then strictWithInf .mul [acc, term]
    else return .num (mul (← asNum acc) (← asNum term))
  | "min" | "max" =>
    let op := if red == "min" then StrictOp.min else StrictOp.max
    if hasInf [acc, term] then infMinMax op [acc, term]
    else return .num (← applyStrict op [acc, term])
  | _ => throw (.unsupported s!"faq with reduce {red}")

/-- Fold the explicitly declared range of a scalar filtered extremum. -/
def foldFilteredExtremum (isMax : Bool) (values : List Int)
    (passesFilter : Int → Except EvalError Bool) (term : Int → Except EvalError (Val α)) :
    Except EvalError (Val α) :=
  values.foldlM (fun acc i => do
    if ← passesFilter i then
      faqCombine (if isMax then "max" else "min") acc (← term i)
    else pure acc) (.inf isMax)

private def faqOutputRanges (ranges : List (FaqRange α)) (env : Env α) :
    List OutputIndex → Except EvalError (List (Option String × List Int))
  | [] => pure []
  | .singleton :: rest => return (none, [1]) :: (← faqOutputRanges ranges env rest)
  | .symbol name :: rest => do
    let some bounds := ranges.lookup name
      | throw (.unsupported s!"faq output index {name} has no explicit range")
    return (some name, ← bounds env) :: (← faqOutputRanges ranges env rest)

private def faqCells (cell : Env α → Except EvalError (Val α)) :
    List (Option String × List Int) → Env α → Except EvalError (List (Val α))
  | [], env => return [← cell env]
  | (name, values) :: rest, env => do
    let parts ← values.mapM (fun i =>
      let env' := match name with
        | some k => (k, .num (Lits.ofDec i 0)) :: env
        | none => env
      faqCells cell rest env')
    return parts.flatten

/-- Evaluate a rectangular output box in output-axis order. Each cell folds
its admitted contracted tuples using the same evaluator as the scalar case. -/
private def evalFaq (output : List OutputIndex) (red : String) (ranges : List (FaqRange α))
    (isReverse : List String → List String → Bool)
    (passesFilter : Env α → Except EvalError Bool) (term : Env α → Except EvalError (Val α))
    (env : Env α) (atCell : Option (List Nat) := none) (ragged : List RaggedUse := []) :
    Except EvalError (Val α) := do
  let outputs := outputNames output
  let contracted := (ranges.filter (fun r => !outputs.contains r.1)).mergeSort
    (fun a b => decide (a.1 ≤ b.1))
  let contracted ← if ragged.isEmpty then pure contracted
    else parentFirstRanges ragged contracted contracted.length
  if red == "bool_and_or" then
    if output.isEmpty then
      let result ← foldBoolRanges (fun e => do
        if ← passesFilter e then nonzeroTerm (← term e) else pure false) contracted env
      return .num (ofBool result)
    unless contracted.isEmpty do throw (.unsupported "array-valued bool_and_or reduction")
  let identity ← faqIdentity red
  let reverse := isReverse outputs (contracted.map Prod.fst)
  let cell := fun e =>
    if contracted.isEmpty then do
      if ← passesFilter e then
        match ← term e with
        | .num x => pure (.num x)
        | .inf neg => pure (.inf neg)
        | _ => throw (.typeError "faq: expected a scalar body")
      else pure identity
    else
      faqFold reverse (fun acc e => do
        if ← passesFilter e then faqCombine red acc (← term e) else pure acc) contracted e identity
  if output.isEmpty then cell env
  else
    let axes ← faqOutputRanges ranges env output
    match atCell with
    | none => return .shaped (axes.map fun axis => axis.2.length) (← faqCells cell axes env)
    | some ix =>
      unless axes.length ≤ ix.length do throw .shapeMismatch
      let bindings ← (axes.zip ix).foldlM (fun e ((name, values), pos) => do
        let some i := values[if values.length == 1 then 0 else pos]? | throw .shapeMismatch
        return match name with
          | some k => (k, .num (Lits.ofDec i 0)) :: e
          | none => e) env
      cell bindings

private def shapeData (value : Val α) : Except EvalError (ArrayData (Val α)) :=
  match value with
  | .num _ | .inf _ => pure (ArrayData.scalar value)
  | _ =>
    match value.arrayData with
    | some (dims, cells) => pure ⟨dims, cells⟩
    | none => throw (.typeError "ragged array")

private def fromShape (data : ArrayData (Val α)) : Except EvalError (Val α) :=
  if data.dims.isEmpty then
    match data.cells with
    | [x] => pure x
    | _ => throw (.typeError "invalid scalar extent")
  else pure (.shaped data.dims data.cells)

private def shapeResult {β : Type} (result : Option β) : Except EvalError β :=
  match result with
  | some result => pure result
  | none => throw .shapeMismatch

/-- Apply a strict primitive to one set of scalar cell operands. -/
def applyCell (op : StrictOp) (values : List (Val α)) : Except EvalError (Val α) :=
  if hasInf values then strictWithInf op values else Val.num <$> applyStrict op values

def broadcastArity (fn : String) (arity : Nat) : Bool :=
  match Op.ofString fn with
  | .ifelse => arity == 3
  | .other s =>
    arity == 1 && ["asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh"].contains s
  | .strict o => match o with
    | .index | .bool _ => false
    | .add | .mul => arity ≥ 1
    | .min | .max | .and | .or => arity ≥ 2
    | .sub => arity == 1 || arity == 2
    | .div | .pow | .le | .ge | .lt | .gt | .eq | .ne | .atan2 => arity == 2
    | _ => arity == 1

private def reshapeDims (shape : List (Nat ⊕ String)) (env : Env α) :
    Except EvalError (List Nat) :=
  shape.mapM fun d => match d with
    | .inl n => pure n
    | .inr set => do
      let n ← setSize set env
      if n < 0 then throw .shapeMismatch else return n.toNat

private def broadcastDims (shapes : List (List Nat)) : Except EvalError (List Nat) :=
  shapeResult (shapes.foldlM ArrayData.mergeDims [])

private def projectCell (value : Val α) (ix : List Nat) : Except EvalError (Val α) := do
  let data ← shapeData value
  shapeResult (data.broadcastAt ix)

private def evalShape (op : ShapeOp) (values : List (Val α)) (env : Env α) :
    Except EvalError (Val α) := do
  let data ← values.mapM shapeData
  let result ← match op, data with
    | .reshape shape, [source] => do
      shapeResult (source.reshape (← reshapeDims shape env))
    | .transpose perm, [source] => shapeResult (source.transpose perm)
    | .concat axis, sources => shapeResult (ArrayData.concat axis sources)
    | .makearray regions, sources =>
      shapeResult (ArrayData.makearray regions sources (.num zero))
    | .broadcast fn, sources =>
      match Op.ofString fn with
      | .strict o => ArrayData.broadcast (applyCell o) .shapeMismatch sources
      | .other s => throw (.unsupported s)
      | .ifelse => throw (.typeError "invalid_broadcast_fn")
    | _, _ => throw .shapeMismatch
  fromShape result

private def queryDims (out : List OutputIndex) (ranges : List (FaqRange α)) (body : Ast)
    (p : Option Ast) (env : Env α) : Except EvalError (Option (List Nat)) := do
  match declareFaqRanges out ranges body p env (onlyOutput := true) with
  | .error (.unbound _) => return none
  | .error err => throw err
  | .ok ranges =>
    let axes ← faqOutputRanges ranges env out
    return some (axes.map fun axis => axis.2.length)

private def expressionBroadcastDims (shapes : List (Option (List Nat))) :
    Except EvalError (Option (List Nat)) := do
  let some shapes := shapes.mapM id | return none
  some <$> broadcastDims shapes

mutual

/-- Evaluation of the modelled slice (§4.2 and §4.3). -/
def eval : Ast → Env α → Except EvalError (Val α)
  | .num m e, _ => .ok (.num (Lits.ofDec m e))
  | .var s, env =>
    match env.lookup s with
    | some v => .ok v
    | none => .error (.unbound s)
  | .const c, _ => constVal c
  | .array (.makearray regions) args, env => do
    if regions.any ArrayData.invertedRegion then throw (.typeError "makearray_region_inverted")
    evalShape (.makearray regions) (← evalRegions regions args env) env
  | .array (.broadcast fn) args, env => do
    unless broadcastArity fn args.length do throw (.typeError "invalid_broadcast_fn")
    if fn == "ifelse" then evalBroadcastIfelse args env
    else evalShape (.broadcast fn) (← evalList args env) env
  | .array op args, env => do
    evalShape op (← evalList args env) env
  | .node op args, env =>
    match Op.ofString op with
    | .ifelse => evalIfelse args env
    | .strict o => do
      let vs ← evalList args env
      let broadcast := do
        let data ← vs.mapM shapeData
        fromShape (← ArrayData.broadcast (applyCell o) .shapeMismatch data)
      match vs with
      | (.shaped dims cells) :: is =>
        if o = .index then
          indexCell (.shaped dims cells) (← is.mapM (fun v => do asInt (← asNum v)))
        else broadcast
      | base :: is =>
        if is.length < base.rank && o == .index then
          indexCell base (← is.mapM (fun v => do asInt (← asNum v)))
        else if vs.any (fun v => v.arrayData.isSome) && o != .index then broadcast
        else if hasInf vs then strictWithInf o vs else return .num (← applyStrict o vs)
      | [] => return .num (← applyStrict o [])
    | .other s => .error (.unsupported s)
  | .faq [] "bool_and_or" rs body _, env => do
    let ranges ← checkedFaqRanges [] rs.raggedUses (← faqRanges rs) body none env
    evalFaq [] "bool_and_or" ranges (fun _ _ => false) (fun _ => pure true) (eval body) env
      (ragged := rs.raggedUses)
  | .faq [] "+" (.cons k [s, t] .nil) body _, env => do
    -- §4.3.1: a `+` reduction over one dense range, seeded at `+0.0`, in index order
    let a ← asInt (← asNum (← eval s env))
    let b ← asInt (← asNum (← eval t env))
    let r ← (indices a b).foldlM
      (fun acc j => do faqStep acc (← eval body ((k, .num (Lits.ofDec j 0)) :: env))) (zero : α)
    return .num r
  | .faq [] "*" (.cons k [s, t] .nil) body _, env => do
    let a ← asInt (← asNum (← eval s env))
    let b ← asInt (← asNum (← eval t env))
    foldRed "*" (indices a b) (fun j => eval body ((k, .num (Lits.ofDec j 0)) :: env))
  | .faq [] "min" (.cons k [s, t] .nil) body _, env => do
    let a ← asInt (← asNum (← eval s env))
    let b ← asInt (← asNum (← eval t env))
    match indices a b with
    | [] => .ok (.inf false)
    | j :: js => do
      let v ← asNum (← eval body ((k, .num (Lits.ofDec j 0)) :: env))
      let r ← js.foldlM (fun acc i => do
        return fmin acc (← asNum (← eval body ((k, .num (Lits.ofDec i 0)) :: env)))) v
      return .num r
  | .faq [] "max" (.cons k [s, t] .nil) body _, env => do
    let a ← asInt (← asNum (← eval s env))
    let b ← asInt (← asNum (← eval t env))
    match indices a b with
    | [] => .ok (.inf true)
    | j :: js => do
      let v ← asNum (← eval body ((k, .num (Lits.ofDec j 0)) :: env))
      let r ← js.foldlM (fun acc i => do
        return fmax acc (← asNum (← eval body ((k, .num (Lits.ofDec i 0)) :: env)))) v
      return .num r
  | .faq [] red (.fromSet k S .nil) body _, env => do
    -- §4.3.1: a range over an index set visits its positions `1 … |S|` in order
    let n ← setSize S env
    foldRed red (indices 1 n) (fun j => eval body ((k, .num (Lits.ofDec j 0)) :: env))
  | .faqWhere [] "min" (.cons k [s, t] .nil) p body _, env => do
    let a ← asInt (← asNum (← eval s env))
    let b ← asInt (← asNum (← eval t env))
    foldFilteredExtremum false (indices a b)
      (fun j => do return truthy (← asNum (← eval p ((k, .num (Lits.ofDec j 0)) :: env))))
      (fun j => eval body ((k, .num (Lits.ofDec j 0)) :: env))
  | .faqWhere [] "max" (.cons k [s, t] .nil) p body _, env => do
    let a ← asInt (← asNum (← eval s env))
    let b ← asInt (← asNum (← eval t env))
    foldFilteredExtremum true (indices a b)
      (fun j => do return truthy (← asNum (← eval p ((k, .num (Lits.ofDec j 0)) :: env))))
      (fun j => eval body ((k, .num (Lits.ofDec j 0)) :: env))
  | .faq out red rs body _, env => do
    let ranges ← checkedFaqRanges out rs.raggedUses (← faqRanges rs) body none env
    evalFaq out red ranges (fun _ _ => false) (fun _ => pure true) (eval body) env
      (ragged := rs.raggedUses)
  | .faqWhere out red rs p body _, env => do
    let ranges ← checkedFaqRanges out rs.raggedUses (← faqRanges rs) body (some p) env
    evalFaq out red ranges (fun outputs contracted => reverseFaqWindow outputs contracted (some p))
      (fun e => do return truthy (← asNum (← eval p e))) (eval body) env (ragged := rs.raggedUses)
  | .apply n _, _ => .error (.unsupported s!"apply_operator {n}: not expanded")

/-- Resolve declared bounds in the environment where the range is visited. -/
def faqRanges : Ranges → Except EvalError (List (FaqRange α))
  | .nil => return []
  | .cons k [lo, hi] rest => do
    let ranges ← faqRanges rest
    return (k, fun env => do
      let a ← asInt (← asNum (← eval lo env))
      let b ← asInt (← asNum (← eval hi env))
      return indices a b) :: ranges
  | .cons k [lo, step, hi] rest => do
    let ranges ← faqRanges rest
    return (k, fun env => do
      let a ← asInt (← asNum (← eval lo env))
      let s ← asInt (← asNum (← eval step env))
      let b ← asInt (← asNum (← eval hi env))
      steppedIndices a s b) :: ranges
  | .fromSet k set rest => do
    let ranges ← faqRanges rest
    return (k, fun env => do return indices 1 (← setSize set env)) :: ranges
  | .fromRagged k set parents rest => do
    let ranges ← faqRanges rest
    return (k, fun env => do
      let (offsets, _) ← raggedFactors ⟨k, set, parents⟩ env
      -- An index-set declaration names an array factor. Scoped scalar indices
      -- can shadow expression reads without shadowing that registry reference.
      let some lengths := env.findSome? (fun (name, value) =>
        if name == offsets && value.rank != 0 then some value else none)
        | throw (.unbound offsets)
      let positions ← parents.mapM fun p => do
        let some index := env.lookup p | throw (.unbound p)
        asInt (← asNum index)
      raggedPositions lengths positions) :: ranges
  | .cons _ _ _ => throw (.typeError "faq range: expected [start, stop] or [start, step, stop]")

def evalList : List Ast → Env α → Except EvalError (List (Val α))
  | [], _ => .ok []
  | e :: es, env => do
    let v ← eval e env
    let vs ← evalList es env
    return v :: vs

/-- Infer extents from the AST and shape bindings without reading operand cells. -/
def expressionDims : Ast → Env α → Except EvalError (Option (List Nat))
  | .num _ _, _ => return some []
  | .var name, env => return variableDims env name
  | .const c, _ => return some (valueDims (← constVal (α := α) c))
  | .node "index" (base :: subscripts), env => do
    return (← expressionDims base env).map (·.drop subscripts.length)
  | .node op args, env =>
    if broadcastArity op args.length then do expressionBroadcastDims (← expressionDimsList args env)
    else return some []
  | .array (.broadcast _) args, env => do expressionBroadcastDims (← expressionDimsList args env)
  | .array (.reshape dims) _, env => some <$> reshapeDims dims env
  | .array (.transpose perm) [a], env => do
    let some dims ← expressionDims a env | return none
    let order ← shapeResult (ArrayData.transposeOrder perm dims.length)
    return order.mapM (fun i => dims[i]?)
  | .array (.concat axis) args, env => do
    let some shapes := (← expressionDimsList args env).mapM id | return none
    some <$> shapeResult (ArrayData.concatDims axis shapes)
  | .array (.makearray regions) _, _ =>
    some <$> shapeResult ((ArrayData.regionBounds regions).map (List.map ArrayData.extent))
  | .faq [] _ _ _ _, _ | .faqWhere [] _ _ _ _ _, _ => return some []
  | .faq out _ rs body _, env => do
    if rs.raggedUses.any (fun range => (outputNames out).contains range.name) then
      throw (.unsupported "faq ragged output index")
    queryDims out (← faqRanges rs) body none env
  | .faqWhere out _ rs p body _, env => do
    if rs.raggedUses.any (fun range => (outputNames out).contains range.name) then
      throw (.unsupported "faq ragged output index")
    queryDims out (← faqRanges rs) body (some p) env
  | _, _ => return none

def expressionDimsList : List Ast → Env α → Except EvalError (List (Option (List Nat)))
  | [], _ => pure []
  | a :: rest, env => do return (← expressionDims a env) :: (← expressionDimsList rest env)

/-- Interpret each selected branch at a broadcast coordinate. Scalar gathers
and whole-array operators keep their operand scopes. -/
def evalCell : Ast → Env α → List Nat → Except EvalError (Val α)
  | .num m e, _, _ => pure (.num (Lits.ofDec m e))
  | .var name, env, ix => do
    let some value := env.lookup name | throw (.unbound name)
    projectCell value ix
  | .const c, _, ix => do projectCell (← constVal c) ix
  | .node op args, env, ix =>
    match Op.ofString op with
    | .ifelse => evalConditionalCell args env ix
    | .strict .index => do
      let a :: is ← evalList args env | throw (.typeError "operand count")
      let value ← indexCell a (← is.mapM (fun v => do asInt (← asNum v)))
      projectCell value ix
    | .strict o => do applyCell o (← evalCellList args env ix)
    | .other s => throw (.unsupported s)
  | .array (.broadcast fn) args, env, ix => do
    unless broadcastArity fn args.length do throw (.typeError "invalid_broadcast_fn")
    match Op.ofString fn with
    | .ifelse => evalConditionalCell args env ix
    | .strict o => applyCell o (← evalCellList args env ix)
    | .other s => throw (.unsupported s)
  | .array (.makearray regions) args, env, ix => do
    if regions.any ArrayData.invertedRegion then throw (.typeError "makearray_region_inverted")
    projectCell (← evalShape (.makearray regions) (← evalRegions regions args env) env) ix
  | .array op args, env, ix => do
    projectCell (← evalShape op (← evalList args env) env) ix
  | .faq out red rs body _, env, ix => do
    let ranges ← checkedFaqRanges out rs.raggedUses (← faqRanges rs) body none env
    evalFaq out red ranges (fun _ _ => false) (fun _ => pure true) (eval body) env (some ix) rs.raggedUses
  | .faqWhere out red rs p body _, env, ix => do
    let ranges ← checkedFaqRanges out rs.raggedUses (← faqRanges rs) body (some p) env
    evalFaq out red ranges (fun outputs contracted => reverseFaqWindow outputs contracted (some p))
      (fun e => do return truthy (← asNum (← eval p e))) (eval body) env (some ix) rs.raggedUses
  | .apply n _, _, _ => .error (.unsupported s!"apply_operator {n}: not expanded")

def evalCellList : List Ast → Env α → List Nat → Except EvalError (List (Val α))
  | [], _, _ => pure []
  | a :: rest, env, ix => do return (← evalCell a env ix) :: (← evalCellList rest env ix)

def evalConditionalCell : List Ast → Env α → List Nat → Except EvalError (Val α)
  | [c, a, b], env, ix => do
    let cv ← asNum (← evalCell c env ix)
    if truthy cv then evalCell a env ix else evalCell b env ix
  | _, _, _ => throw (.typeError "ifelse takes three arguments")

def evalBroadcastIfelse : List Ast → Env α → Except EvalError (Val α)
  | [c, a, b], env => do
    let condition ← shapeData (← eval c env)
    let shapes := [← expressionDims a env, ← expressionDims b env]
    let dims ← broadcastDims (condition.dims :: shapes.filterMap id)
    if dims.isEmpty then
      let cv ← asNum (← shapeResult (condition.at? []))
      if truthy cv then eval a env else eval b env
    else
      let cells ← (ArrayData.coords dims).mapM fun ix => do
        let cv ← asNum (← shapeResult (condition.broadcastAt ix))
        if truthy cv then evalCell a env ix else evalCell b env ix
      return .shaped dims cells
  | _, _ => throw (.typeError "ifelse takes three arguments")

/-- An empty makearray region skips its value expression entirely. -/
def evalRegions : List (List (Int × Int)) → List Ast → Env α → Except EvalError (List (Val α))
  | [], [], _ => pure []
  | region :: regions, arg :: args, env => do
    let value ← if ArrayData.emptyRegion region then pure (.num zero) else eval arg env
    return value :: (← evalRegions regions args env)
  | _, _, _ => throw (.typeError "makearray region/value count mismatch")

/-- `ifelse` evaluates its condition, then only the branch it takes. -/
def evalIfelse : List Ast → Env α → Except EvalError (Val α)
  | [c, a, b], env => do
    let cv ← asNum (← eval c env)
    if truthy cv then eval a env else eval b env
  | _, _ => .error (.typeError "ifelse takes three arguments")

end

end Eval

end Esm.Expr
