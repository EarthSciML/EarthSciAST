import Esm.Closed.Interp.Template
import Mathlib.Analysis.SpecialFunctions.Complex.Arg

/-!
# The ESM Expression AST and its evaluator (esm-spec §4.1–4.3), first slice

This is the start of the model's expression core: one Lean type for the JSON
Expression AST of §4.1 and an evaluator over the scalar types of
`Esm/Closed/Interp.lean` (`Scalar`), so the same code runs at the exact `Num`,
at the binary64 `Bin64`, and at the adapter's `Float`.

The evaluator covers exactly the slice the `lib/interp.esm` templates use:

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
* the elementary functions `floor`, `abs`, `sqrt`, `sin`, `cos` and `atan2`,
  through the `Elem` operations of the scalar type;
* `min` / `max`, n-ary with arity ≥ 2, left folds, NaN-propagating (§4.2: IEEE
  754-2019 `minimum`/`maximum`, not `minNum`/`maxNum`);
* `index` on a rank-1, rank-2 or rank-3 array, 1-based, each index a value holding an
  integer, out of range an error (§4.3.3, `E_TREEWALK_CONSTARRAY_OOB`);
* `faq` with `output_idx: []`, `reduce` one of `+`, `*`, `min`, `max`, and one
  dense `ranges` entry `[start, stop]`: the fold `0 + t_start + … + t_stop`
  seeded at `+0.0` (`1` for `*`), in increasing index order (§4.3.1). A `min` /
  `max` fold starts from its first term: its identity `±∞` is not a value of
  the model's scalar types, so a `min` / `max` reduction over an empty range is
  `EvalError.unsupported` (IEEE `minimum(+∞, x) = x`, so a non-empty fold is
  unchanged). A `faq` nested in another's body is evaluated afresh at each
  outer index.

Everything else — another op, a `faq` with output indices, another reduction,
a stepped or `from` range, several range symbols — evaluates to
`EvalError.unsupported`, never to a value. Signed zeros are not modelled by
`Num`/`Bin64` (so `min`/`max` do not order `-0.0` below `+0.0`).
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
  ofDec m e :=
    let v := Float.ofScientific m.natAbs true e
    if m < 0 then -v else v
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

noncomputable instance : Elem Num where
  floor | .fin r => .fin ⌊r⌋ | .nan => .nan
  abs | .fin r => .fin |r| | .nan => .nan
  neg | .fin r => .fin (-r) | .nan => .nan
  sqrt | .fin r => if r < 0 then .nan else .fin (Real.sqrt r) | .nan => .nan
  sin | .fin r => .fin (Real.sin r) | .nan => .nan
  cos | .fin r => .fin (Real.cos r) | .nan => .nan
  atan2 | .fin y, .fin x => .fin (realAtan2 y x) | _, _ => .nan

noncomputable instance : Elem Bin64 where
  floor | .fin r => .fin ⌊r⌋ | .nan => .nan
  abs | .fin r => .fin |r| | .nan => .nan
  neg | .fin r => .fin (-r) | .nan => .nan
  sqrt | .fin r => if r < 0 then .nan else .fin (Esm.F64.rn (Real.sqrt r)) | .nan => .nan
  sin | .fin r => .fin (Esm.F64.rn (Real.sin r)) | .nan => .nan
  cos | .fin r => .fin (Esm.F64.rn (Real.cos r)) | .nan => .nan
  atan2 | .fin y, .fin x => .fin (Esm.F64.rn (realAtan2 y x)) | _, _ => .nan

instance : Elem Float where
  floor := Float.floor
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

mutual

/-- The ESM Expression AST (§4.1). A JSON number is `num`, a bare string a
`var`, an object with an `op` a `const`, a `faq`, an `apply_expression_template`
reference or a generic `node` (its remaining scalar fields, which this slice
never needs, are not carried). -/
inductive Ast where
  | num (m : Int) (e : Nat)
  | var (name : String)
  | const (c : Const)
  | node (op : String) (args : List Ast)
  /-- `faq`: `output_idx`, `reduce`, `ranges`, `expr`, `args`. -/
  | faq (outputIdx : List String) (reduce : String) (ranges : Ranges) (expr : Ast)
      (args : List Ast)
  /-- `apply_expression_template`: the template `name` with its `bindings`
  (§9.6.2). It denotes its expansion (§9.6.4 rule 2); `eval` refuses it, and
  `Esm.Expr.expandRefs` replaces it by that expansion. -/
  | apply (name : String) (bindings : Binds)

/-- A `faq`'s `ranges` object, in key order: each symbol with its tuple
(`[start, stop]` or `[start, step, stop]`). -/
inductive Ranges where
  | nil
  | cons (sym : String) (tuple : List Ast) (rest : Ranges)

/-- An `apply_expression_template` node's `bindings` object, in key order. -/
inductive Binds where
  | nil
  | cons (param : String) (value : Ast) (rest : Binds)

end

/-! ## Values and errors -/

/-- A value: a scalar or a rank-1, rank-2 or rank-3 array (row-major). -/
inductive Val (α : Type) where
  | num (v : α)
  | arr1 (v : List α)
  | arr2 (v : List (List α))
  | arr3 (v : List (List (List α)))

inductive EvalError where
  /-- Outside the modelled slice: an explicit refusal, not a value. -/
  | unsupported (what : String)
  | unbound (name : String)
  | typeError (what : String)
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

/-- IEEE 754-2019 `maximum` on the model's values: NaN if either side is. -/
def fmax (a b : α) : α := if isNaN a then a else if isNaN b then b else if lt a b then b else a

/-- IEEE 754-2019 `minimum`. -/
def fmin (a b : α) : α := if isNaN a then a else if isNaN b then b else if lt b a then b else a

def asNum : Val α → Except EvalError α
  | .num v => .ok v
  | _ => .error (.typeError "expected a scalar")

def asInt (v : α) : Except EvalError Int :=
  match Lits.toInt? v with
  | some k => .ok k
  | none => .error .nonIntegral

/-- `index` (§4.3.3), 1-based, each index checked against its own dimension. -/
def indexVal : Val α → List Int → Except EvalError α
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
  | _, _ => .error (.typeError "operand count")

/-- One step of a `faq` `+` fold. -/
def faqStep (acc : α) (v : Val α) : Except EvalError α := do
  return add acc (← asNum v)

mutual

/-- Evaluation of the modelled slice (§4.2, §4.3.1, §4.3.3). -/
def eval : Ast → Env α → Except EvalError (Val α)
  | .num m e, _ => .ok (.num (Lits.ofDec m e))
  | .var s, env =>
    match env.lookup s with
    | some v => .ok v
    | none => .error (.unbound s)
  | .const c, _ => constVal c
  | .node op args, env =>
    match Op.ofString op with
    | .ifelse => evalIfelse args env
    | .strict o => do
      let vs ← evalList args env
      return .num (← applyStrict o vs)
    | .other s => .error (.unsupported s)
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
    let r ← (indices a b).foldlM
      (fun acc j => do return mul acc (← asNum (← eval body ((k, .num (Lits.ofDec j 0)) :: env))))
      (one : α)
    return .num r
  | .faq [] "min" (.cons k [s, t] .nil) body _, env => do
    let a ← asInt (← asNum (← eval s env))
    let b ← asInt (← asNum (← eval t env))
    match indices a b with
    | [] => .error (.unsupported "min reduction over an empty range (its identity +Inf)")
    | j :: js => do
      let v ← asNum (← eval body ((k, .num (Lits.ofDec j 0)) :: env))
      let r ← js.foldlM (fun acc i => do
        return fmin acc (← asNum (← eval body ((k, .num (Lits.ofDec i 0)) :: env)))) v
      return .num r
  | .faq [] "max" (.cons k [s, t] .nil) body _, env => do
    let a ← asInt (← asNum (← eval s env))
    let b ← asInt (← asNum (← eval t env))
    match indices a b with
    | [] => .error (.unsupported "max reduction over an empty range (its identity -Inf)")
    | j :: js => do
      let v ← asNum (← eval body ((k, .num (Lits.ofDec j 0)) :: env))
      let r ← js.foldlM (fun acc i => do
        return fmax acc (← asNum (← eval body ((k, .num (Lits.ofDec i 0)) :: env)))) v
      return .num r
  | .apply n _, _ => .error (.unsupported s!"apply_expression_template {n}: not expanded")
  | .faq _ _ _ _ _, _ =>
    .error (.unsupported "faq outside output_idx [], reduce + * min max, one dense [start, stop] range")

def evalList : List Ast → Env α → Except EvalError (List (Val α))
  | [], _ => .ok []
  | e :: es, env => do
    let v ← eval e env
    let vs ← evalList es env
    return v :: vs

/-- `ifelse` evaluates its condition, then only the branch it takes. -/
def evalIfelse : List Ast → Env α → Except EvalError (Val α)
  | [c, a, b], env => do
    let cv ← asNum (← eval c env)
    if truthy cv then eval a env else eval b env
  | _, _ => .error (.typeError "ifelse takes three arguments")

end

end Eval

end Esm.Expr
