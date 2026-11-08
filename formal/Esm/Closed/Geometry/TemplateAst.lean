import Esm.Closed.Relational.TemplateAst
import Esm.Lib.Geometry

/-!
# The planar overlap template of `lib/geometry.esm`

`Esm/Lib/Geometry.lean` holds the templates of `lib/geometry.esm` (generated,
checked current in CI). This file is about `overlap_area_planar`: the overlap
area of two convex polygons, cell `cell_a` of the `[cells, nv_a, 2]` ring
stack `ring_a` and cell `cell_b` of `ring_b`, by Green's theorem — each edge's
shoelace term about the first vertex of ring A, restricted to the parameter
interval `[t0, t1]` the other ring's half-planes leave (a `max` and a `min`
reduction), with a relative tolerance deciding "on the line".

* `expand_planar`: the expansion is, by computation, the tree `planarA` built
  from the named shapes below (the same names as in the library's comments).
* `planar_template_eq`: at every scalar type with `RealNaN` and `ExprLaws`,
  the expansion evaluated on two rank-3 ring stacks is `planarRef`, a Lean
  transcription of the clip-area algorithm on the two vertex lists: the
  shoelace fans `fan`, the orientation signs `sgn`, the half-plane quantities
  `cross`, `tol`, `dot`, the candidate parameters `cand1`/`cand0`, and the
  three folds (`+` from `+0`, `min`, `max`) in the template's order.

Nothing here is a statement about areas in real arithmetic: the reference is
the algorithm, operation for operation, and the theorem is that the template
computes it.
-/

namespace Esm.Closed.GeometryAst

open Esm.Expr Esm.Closed Esm.Closed.Template Esm.Closed.TemplateAst Esm.Closed.RelationalAst
open Scalar RealNaN

set_option linter.unusedSectionVars false

/-! ## The shapes -/

/-- A vertex as its two coordinate expressions. -/
abbrev P2 := Ast × Ast

def subA (a b : Ast) : Ast := .node "-" [a, b]
def mulA (a b : Ast) : Ast := .node "*" [a, b]
def addA (a b : Ast) : Ast := .node "+" [a, b]
def absA (a : Ast) : Ast := .node "abs" [a]
def iteA (c a b : Ast) : Ast := .node "ifelse" [c, a, b]

/-- `index(R, C, i, d)`. -/
def ixA3 (R C i : Ast) (d : ℤ) : Ast := .node "index" [R, C, i, .num d 0]
def vtx (R C i : Ast) : P2 := (ixA3 R C i 1, ixA3 R C i 2)
/-- The next vertex slot, `ifelse(k < nv, k + 1, 1)` (implicit closure). -/
def nxtA (k : String) (N : Ast) : Ast :=
  .node "ifelse" [.node "<" [.var k, N], .node "+" [.var k, .num 1 0], .num 1 0]

/-- `(Q1 − Q0) × (P − Q0)`: the side of `P` relative to the edge `Q0 → Q1`. -/
def crossA (Q0 Q1 P : P2) : Ast :=
  subA (mulA (subA Q1.1 Q0.1) (subA P.2 Q0.2)) (mulA (subA Q1.2 Q0.2) (subA P.1 Q0.1))

/-- `(Q1 − Q0) · (P1 − P0)`. -/
def dotA (Q0 Q1 P0 P1 : P2) : Ast :=
  addA (mulA (subA Q1.1 Q0.1) (subA P1.1 P0.1)) (mulA (subA Q1.2 Q0.2) (subA P1.2 P0.2))

/-- The on-the-line tolerance `L1(Q1 − Q0) · (L1(P0) + L1(P1) + L1(Q0)) · 1e-12`. -/
def tolA (P0 P1 Q0 Q1 : P2) : Ast :=
  .node "*" [addA (absA (subA Q1.1 Q0.1)) (absA (subA Q1.2 Q0.2)),
    .node "+" [addA (absA P0.1) (absA P0.2), addA (absA P1.1) (absA P1.2),
      addA (absA Q0.1) (absA Q0.2)], .num 1 12]

def onA (c tl : Ast) : Ast := .node "<=" [absA c, tl]
def ltNegA (s c tl : Ast) : Ast := .node "<" [mulA s c, .node "-" [tl]]
/-- The crossing parameter `c0 / (c0 − c1)` (`c0 / 1` when they are equal). -/
def ratioA (c0 c1 : Ast) : Ast :=
  .node "/" [c0, iteA (.node "==" [c0, c1]) (.num 1 0) (subA c0 c1)]

/-- The upper end `t1` an edge's half-plane imposes. -/
def cand1A (s c0 c1 tl : Ast) : Ast :=
  iteA (.node "and" [onA c0 tl, onA c1 tl]) (.num 1 0)
    (iteA (ltNegA s c0 tl) (.num 1 0)
      (iteA (ltNegA s c1 tl) (iteA (onA c0 tl) (.num 0 0) (ratioA c0 c1)) (.num 1 0)))

/-- The lower end `t0` an edge's half-plane imposes; `both` is the value when
the edge lies on the half-plane's line. -/
def cand0A (s c0 c1 tl both : Ast) : Ast :=
  iteA (.node "and" [onA c0 tl, onA c1 tl]) both
    (iteA (ltNegA s c0 tl)
      (iteA (ltNegA s c1 tl) (.num 1 0) (iteA (onA c1 tl) (.num 1 0) (ratioA c0 c1)))
      (.num 0 0))

def gargs : List Ast := [.var "RA", .var "RB"]

def sumA (k : String) (N body : Ast) : Ast := .faq [] "+" (.cons k [.num 1 0, N] .nil) body gargs
def minA (k : String) (N body : Ast) : Ast := .faq [] "min" (.cons k [.num 1 0, N] .nil) body gargs
def maxA (k : String) (N body : Ast) : Ast := .faq [] "max" (.cons k [.num 1 0, N] .nil) body gargs

/-- The signed shoelace fan of a ring about its first vertex. -/
def fanA (R C N : Ast) (k : String) : Ast :=
  sumA k N (crossA (vtx R C (.num 1 0)) (vtx R C (.var k)) (vtx R C (nxtA k N)))

/-- The orientation sign `ifelse(fan >= 0, 1, -1)`. -/
def sgnA (fan : Ast) : Ast := iteA (.node ">=" [fan, .num 0 0]) (.num 1 0) (.num (-1) 0)

def RA : Ast := .var "RA"
def CA : Ast := .var "CA"
def RB : Ast := .var "RB"
def CB : Ast := .var "CB"

def k1 : String := "k_overlap_area_planar_1"
def k2 : String := "k_overlap_area_planar_2"
def k3 : String := "k_overlap_area_planar_3"
def k4 : String := "k_overlap_area_planar_4"
def k5 : String := "k_overlap_area_planar_5"
def k6 : String := "k_overlap_area_planar_6"
def k7 : String := "k_overlap_area_planar_7"
def k8 : String := "k_overlap_area_planar_8"

/-- The template's expansion, with `NA`, `NB` the two vertex-slot counts. -/
def planarA (NA NB : Ast) : Ast :=
  let fA := fanA RA CA NA k1
  let fB := fanA RB CB NB k2
  let sA := sgnA fA
  let sB := sgnA fB
  let O := vtx RA CA (.num 1 0)
  -- A's edges clipped by B's half-planes
  let a0 := vtx RA CA (.var k3)
  let a1 := vtx RA CA (nxtA k3 NA)
  let b5 := vtx RB CB (.var k5)
  let b5' := vtx RB CB (nxtA k5 NB)
  let b4 := vtx RB CB (.var k4)
  let b4' := vtx RB CB (nxtA k4 NB)
  let t1A := minA k5 NB (cand1A sB (crossA b5 b5' a0) (crossA b5 b5' a1) (tolA a0 a1 b5 b5'))
  let t0A := maxA k4 NB (cand0A sB (crossA b4 b4' a0) (crossA b4 b4' a1) (tolA a0 a1 b4 b4')
    (iteA (.node "<" [.node "*" [sA, sB, dotA b4 b4' a0 a1], .num 0 0]) (.num 1 0) (.num 0 0)))
  let loopA := sumA k3 NA (.node "*" [sA, .node "max" [.num 0 0, subA t1A t0A],
    crossA O a0 a1, .num 5 1])
  -- B's edges clipped by A's half-planes
  let b0 := vtx RB CB (.var k6)
  let b1 := vtx RB CB (nxtA k6 NB)
  let a8 := vtx RA CA (.var k8)
  let a8' := vtx RA CA (nxtA k8 NA)
  let a7 := vtx RA CA (.var k7)
  let a7' := vtx RA CA (nxtA k7 NA)
  let t1B := minA k8 NA (cand1A sA (crossA a8 a8' b0) (crossA a8 a8' b1) (tolA b0 b1 a8 a8'))
  let t0B := maxA k7 NA (cand0A sA (crossA a7 a7' b0) (crossA a7 a7' b1) (tolA b0 b1 a7 a7')
    (iteA (.node "==" [.node "*" [sB, sA, dotA a7 a7' b0 b1], .num 0 0]) (.num 0 0) (.num 1 0)))
  let loopB := sumA k6 NB (.node "*" [sB, .node "max" [.num 0 0, subA t1B t0B],
    crossA O b0 b1, .num 5 1])
  iteA (.node "or" [.node "==" [fA, .num 0 0], .node "==" [fB, .num 0 0]]) (.num 0 0)
    (addA loopA loopB)

def bindP (na nb : ℕ) : Bindings :=
  [("ring_a", RA), ("cell_a", CA), ("nv_a", .num (na : ℤ) 0),
   ("ring_b", RB), ("cell_b", CB), ("nv_b", .num (nb : ℤ) 0)]

theorem expand_planar (na nb : ℕ) :
    expandIn Esm.Lib.Geometry.lib 32 Esm.Lib.Geometry.overlap_area_planar (bindP na nb) =
      .ok (planarA (.num (na : ℤ) 0) (.num (nb : ℤ) 0)) := rfl

/-! ## The reference: the clip-area algorithm on two vertex lists -/

section Ref

variable {α : Type} [Scalar α] [Lits α] [Elem α]

/-- Coordinate `d` of vertex `i` of cell `c` (all 1-based), NaN when absent. -/
def crd (M : List (List (List α))) (c i d : ℕ) : α :=
  ((M.getD (c - 1) []).getD (i - 1) []).getD (d - 1) nan

/-- The next vertex slot (implicit closure). -/
def nxt (n i : ℕ) : ℕ := if i < n then i + 1 else 1

/-- A vertex. -/
abbrev V (α : Type) := α × α

def vat (M : List (List (List α))) (c i : ℕ) : V α := (crd M c i 1, crd M c i 2)

def crossR (q0 q1 p : V α) : α :=
  sub (mul (sub q1.1 q0.1) (sub p.2 q0.2)) (mul (sub q1.2 q0.2) (sub p.1 q0.1))

def dotR (q0 q1 p0 p1 : V α) : α :=
  add (mul (sub q1.1 q0.1) (sub p1.1 p0.1)) (mul (sub q1.2 q0.2) (sub p1.2 p0.2))

def tolR (p0 p1 q0 q1 : V α) : α :=
  mul (mul (add (Elem.abs (sub q1.1 q0.1)) (Elem.abs (sub q1.2 q0.2)))
    (add (add (add (Elem.abs p0.1) (Elem.abs p0.2)) (add (Elem.abs p1.1) (Elem.abs p1.2)))
      (add (Elem.abs q0.1) (Elem.abs q0.2)))) (Lits.ofDec 1 12)

def onR (c tl : α) : Bool := le (Elem.abs c) tl
def ltNegR (s c tl : α) : Bool := lt (mul s c) (Elem.neg tl)
def eqR (a b : α) : Bool := le a b && le b a

def ratioR (c0 c1 : α) : α := div c0 (if eqR c0 c1 then one else sub c0 c1)

def cand1R (s c0 c1 tl : α) : α :=
  if onR c0 tl && onR c1 tl then one
  else if ltNegR s c0 tl then one
  else if ltNegR s c1 tl then (if onR c0 tl then zero else ratioR c0 c1)
  else one

def cand0R (s c0 c1 tl both : α) : α :=
  if onR c0 tl && onR c1 tl then both
  else if ltNegR s c0 tl then
    (if ltNegR s c1 tl then one else if onR c1 tl then one else ratioR c0 c1)
  else zero

/-- A `faq` `+` over `[1, n]` from the `+0` seed. -/
def sumR (g : ℕ → α) : ℕ → α
  | 0 => zero
  | n + 1 => add (sumR g n) (g (n + 1))

def fanR (M : List (List (List α))) (c n : ℕ) : α :=
  sumR (fun j => crossR (vat M c 1) (vat M c j) (vat M c (nxt n j))) n

def sgnR (f : α) : α := if le zero f then one else Lits.ofDec (-1) 0

/-- **The planar clip-area algorithm**, as `lib/geometry.esm` writes it:
`n ≥ 1` slots per ring; `m - 1` and `n - 1` are the folds' last indices. -/
def planarRef (MA : List (List (List α))) (ca na : ℕ) (MB : List (List (List α))) (cb nb : ℕ) :
    α :=
  let fA := fanR MA ca na
  let fB := fanR MB cb nb
  let sA := sgnR fA
  let sB := sgnR fB
  let O := vat MA ca 1
  let termA := fun i =>
    let a0 := vat MA ca i
    let a1 := vat MA ca (nxt na i)
    let t1 := foldR fmin (fun j =>
      let q0 := vat MB cb j
      let q1 := vat MB cb (nxt nb j)
      cand1R sB (crossR q0 q1 a0) (crossR q0 q1 a1) (tolR a0 a1 q0 q1)) (nb - 1)
    let t0 := foldR fmax (fun j =>
      let q0 := vat MB cb j
      let q1 := vat MB cb (nxt nb j)
      cand0R sB (crossR q0 q1 a0) (crossR q0 q1 a1) (tolR a0 a1 q0 q1)
        (if lt (mul (mul sA sB) (dotR q0 q1 a0 a1)) zero then one else zero)) (nb - 1)
    mul (mul (mul sA (fmax zero (sub t1 t0))) (crossR O a0 a1)) (Lits.ofDec 5 1)
  let termB := fun i =>
    let b0 := vat MB cb i
    let b1 := vat MB cb (nxt nb i)
    let t1 := foldR fmin (fun j =>
      let q0 := vat MA ca j
      let q1 := vat MA ca (nxt na j)
      cand1R sA (crossR q0 q1 b0) (crossR q0 q1 b1) (tolR b0 b1 q0 q1)) (na - 1)
    let t0 := foldR fmax (fun j =>
      let q0 := vat MA ca j
      let q1 := vat MA ca (nxt na j)
      cand0R sA (crossR q0 q1 b0) (crossR q0 q1 b1) (tolR b0 b1 q0 q1)
        (if eqR (mul (mul sB sA) (dotR q0 q1 b0 b1)) zero then zero else one)) (na - 1)
    mul (mul (mul sB (fmax zero (sub t1 t0))) (crossR O b0 b1)) (Lits.ofDec 5 1)
  if eqR fA zero || eqR fB zero then zero else add (sumR termA na) (sumR termB nb)

end Ref

/-! ## Evaluating the shapes -/

section Eval

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α]

/-- `a` evaluates to the scalar `v`. -/
abbrev EV (env : Env α) (a : Ast) (v : α) : Prop := eval a env = .ok (.num v)

/-- `a` evaluates to the truth value `b`. -/
abbrev EB (env : Env α) (a : Ast) (b : Bool) : Prop := eval a env = .ok (.num (ofBool b : α))

theorem op_abs' : Op.ofString "abs" = .strict .abs := rfl
theorem op_lt' : Op.ofString "<" = .strict .lt := rfl
theorem op_eq'' : Op.ofString "==" = .strict .eq := rfl
theorem op_and'' : Op.ofString "and" = .strict .and := rfl
theorem op_or'' : Op.ofString "or" = .strict .or := rfl

variable {env : Env α}

theorem ev_un' {op : String} {o : StrictOp} (hop : Op.ofString op = .strict o) {a : Ast} {u : α}
    (ha : eval a env = .ok (.num u)) :
    eval (.node op [a]) env = (applyStrict o [.num u]).map Val.num := by
  simp only [eval, hop, evalList, ha, bind, Except.bind, pure, Except.pure]
  cases h : applyStrict o [.num u] <;> rfl

theorem ev_tri {op : String} {o : StrictOp} (hop : Op.ofString op = .strict o) {a b c : Ast}
    {u v w : α} (ha : EV env a u) (hb : EV env b v) (hc : EV env c w) :
    eval (.node op [a, b, c]) env = (applyStrict o [.num u, .num v, .num w]).map Val.num := by
  simp only [eval, hop, evalList, ha, hb, hc, bind, Except.bind, pure, Except.pure]
  cases h : applyStrict o [.num u, .num v, .num w] <;> rfl

theorem ev_quad {op : String} {o : StrictOp} (hop : Op.ofString op = .strict o) {a b c d : Ast}
    {u v w x : α} (ha : EV env a u) (hb : EV env b v) (hc : EV env c w) (hd : EV env d x) :
    eval (.node op [a, b, c, d]) env =
      (applyStrict o [.num u, .num v, .num w, .num x]).map Val.num := by
  simp only [eval, hop, evalList, ha, hb, hc, hd, bind, Except.bind, pure, Except.pure]
  cases h : applyStrict o [.num u, .num v, .num w, .num x] <;> rfl

theorem ev_lit (m : ℤ) (e : ℕ) : EV env (.num m e) (Lits.ofDec m e : α) := rfl

theorem ev_absA {a : Ast} {u : α} (ha : EV env a u) : EV env (absA a) (Elem.abs u) := by
  unfold EV absA; rw [ev_un' op_abs' ha]; rfl

theorem ev_negA {a : Ast} {u : α} (ha : EV env a u) : EV env (.node "-" [a]) (Elem.neg u) := by
  unfold EV; rw [ev_un' op_sub ha]; rfl

theorem ev_subA {a b : Ast} {u v : α} (ha : EV env a u) (hb : EV env b v) :
    EV env (subA a b) (sub u v) := ev_sub ha hb
theorem ev_mulA {a b : Ast} {u v : α} (ha : EV env a u) (hb : EV env b v) :
    EV env (mulA a b) (mul u v) := ev_mul ha hb
theorem ev_addA {a b : Ast} {u v : α} (ha : EV env a u) (hb : EV env b v) :
    EV env (addA a b) (add u v) := ev_add ha hb

theorem ev_mul3 {a b c : Ast} {u v w : α} (ha : EV env a u) (hb : EV env b v) (hc : EV env c w) :
    EV env (.node "*" [a, b, c]) (mul (mul u v) w) := by
  unfold EV; rw [ev_tri op_mul ha hb hc]; rfl

theorem ev_add3 {a b c : Ast} {u v w : α} (ha : EV env a u) (hb : EV env b v) (hc : EV env c w) :
    EV env (.node "+" [a, b, c]) (add (add u v) w) := by
  unfold EV; rw [ev_tri op_add ha hb hc]; rfl

theorem ev_mul4 {a b c d : Ast} {u v w x : α} (ha : EV env a u) (hb : EV env b v)
    (hc : EV env c w) (hd : EV env d x) :
    EV env (.node "*" [a, b, c, d]) (mul (mul (mul u v) w) x) := by
  unfold EV; rw [ev_quad op_mul ha hb hc hd]; rfl

theorem ev_maxA {a b : Ast} {u v : α} (ha : EV env a u) (hb : EV env b v) :
    EV env (.node "max" [a, b]) (fmax u v) := by
  unfold EV; rw [ev_bin op_max ha hb]; rfl

theorem ev_divA {a b : Ast} {u v : α} (ha : EV env a u) (hb : EV env b v) :
    EV env (.node "/" [a, b]) (div u v) := ev_div ha hb

theorem ev_leA {a b : Ast} {u v : α} (ha : EV env a u) (hb : EV env b v) :
    EB env (.node "<=" [a, b]) (le u v) := ev_le ha hb

theorem ev_geA {a b : Ast} {u v : α} (ha : EV env a u) (hb : EV env b v) :
    EB env (.node ">=" [a, b]) (le v u) := ev_ge ha hb

theorem ev_ltA {a b : Ast} {u v : α} (ha : EV env a u) (hb : EV env b v) :
    EB env (.node "<" [a, b]) (lt u v) := by
  unfold EB; rw [ev_bin op_lt' ha hb]; rfl

theorem ev_eqA {a b : Ast} {u v : α} (ha : EV env a u) (hb : EV env b v) :
    EB env (.node "==" [a, b]) (eqR u v) := by
  unfold EB; rw [ev_bin op_eq'' ha hb]; rfl

theorem ev_andA {a b : Ast} {p q : Bool} (ha : EB env a p) (hb : EB env b q) :
    EB env (.node "and" [a, b]) (p && q) := by
  unfold EB; rw [ev_bin op_and'' ha hb]
  simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, truthy_ofBool]

theorem ev_orA {a b : Ast} {p q : Bool} (ha : EB env a p) (hb : EB env b q) :
    EB env (.node "or" [a, b]) (p || q) := by
  unfold EB; rw [ev_bin op_or'' ha hb]
  simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, truthy_ofBool]

theorem ev_iteA {c a b : Ast} {p : Bool} {u v : α} (hc : EB env c p) (ha : EV env a u)
    (hb : EV env b v) : EV env (iteA c a b) (if p then u else v) := by
  unfold EV iteA; rw [ev_ifelse hc]; cases p <;> simpa

theorem ev_one' : EV env (.num 1 0) (one : α) := rfl
theorem ev_zero' : EV env (.num 0 0) (zero : α) := rfl

/-! ### Vertices -/

/-- The cell `c` of `M` has `n` vertex slots of two coordinates. -/
def Shape (M : List (List (List α))) (c n : ℕ) : Prop :=
  1 ≤ c ∧ c ≤ M.length ∧ n ≤ (M.getD (c - 1) []).length ∧
    ∀ i, 1 ≤ i → i ≤ n → 2 ≤ ((M.getD (c - 1) []).getD (i - 1) []).length

theorem ev_ix3 {R C i : Ast} {M : List (List (List α))} {c j n : ℕ} (dz : ℤ) (d : ℕ)
    (hdz : dz = d) (hd1 : 1 ≤ d) (hd2 : d ≤ 2) (hR : eval R env = .ok (.arr3 M))
    (hC : EV env C (fin (c : ℝ))) (hi : EV env i (fin (j : ℝ))) (hS : Shape M c n)
    (hj1 : 1 ≤ j) (hjn : j ≤ n) : EV env (ixA3 R C i dz) (crd M c j d) := by
  obtain ⟨c1, c2, cn, cv⟩ := hS
  have hv := cv j hj1 hjn
  subst hdz
  have hdl : (Lits.ofDec (d : ℤ) 0 : α) = fin (d : ℝ) := ofDec_nat' (by omega)
  have hc' : ((c : ℤ) - 1).toNat = c - 1 := by omega
  have hj' : ((j : ℤ) - 1).toNat = j - 1 := by omega
  have hd' : ((d : ℤ) - 1).toNat = d - 1 := by omega
  rw [List.getD_eq_getElem _ _ (show c - 1 < M.length by omega)] at cn hv
  rw [List.getD_eq_getElem _ _ (show j - 1 < M[c - 1].length by omega)] at hv
  simp only [EV, ixA3, eval, op_index, evalList, hR, hC, hi, bind, Except.bind, pure,
    Except.pure, hdl]
  simp [hasInf, applyStrict, asNum, asInt, toInt_nat, indexVal, crd, hc', hj', hd', c1, c2, hj1,
    hd1, bind, Except.bind, pure, Except.pure,
    List.getElem?_eq_getElem (show c - 1 < M.length by omega),
    List.getElem?_eq_getElem (show j - 1 < M[c - 1].length by omega),
    List.getElem?_eq_getElem (show d - 1 < M[c - 1][j - 1].length by omega),
    show (j : ℤ) ≤ (M[c - 1].length : ℤ) by omega, show (d : ℤ) ≤ (M[c - 1][j - 1].length : ℤ) by omega]

theorem ev_vtx {R C i : Ast} {M : List (List (List α))} {c j n : ℕ}
    (hR : eval R env = .ok (.arr3 M)) (hC : EV env C (fin (c : ℝ))) (hi : EV env i (fin (j : ℝ)))
    (hS : Shape M c n) (hj1 : 1 ≤ j) (hjn : j ≤ n) :
    EV env (vtx R C i).1 (vat M c j).1 ∧ EV env (vtx R C i).2 (vat M c j).2 :=
  ⟨ev_ix3 1 1 rfl le_rfl (by norm_num) hR hC hi hS hj1 hjn,
    ev_ix3 2 2 rfl (by norm_num) le_rfl hR hC hi hS hj1 hjn⟩

theorem ev_nxt {k : String} {n j : ℕ} (hn : n < 2 ^ 53) (hk : EV env (.var k) (fin (j : ℝ)))
    (hjn : j ≤ n) : EV env (nxtA k (.num (n : ℤ) 0)) (fin (nxt n j : ℝ)) := by
  have hN : EV env (.num (n : ℤ) 0) (fin (n : ℝ)) := ev_nat env hn.le
  have hc : EB env (.node "<" [.var k, .num (n : ℤ) 0]) (decide (j < n)) := by
    have := ev_ltA hk hN
    rwa [lt_fin, show decide ((j : ℝ) < n) = decide (j < n) by simp] at this
  have h1 : EV env (.num 1 0) (fin ((1 : ℕ) : ℝ)) := ev_lit1 env
  have hs : EV env (.node "+" [.var k, .num 1 0]) (fin ((j + 1 : ℕ) : ℝ)) := by
    unfold EV; rw [ev_add hk h1, add_nat (by omega)]
  have := ev_iteA hc hs h1
  by_cases h : j < n
  · simp only [h, decide_true, ↓reduceIte] at this
    simpa only [nxt, nxtA, iteA, h, ↓reduceIte] using this
  · simp only [h, decide_false, Bool.false_eq_true, ↓reduceIte] at this
    simpa only [nxt, nxtA, iteA, h, ↓reduceIte] using this

/-! ### Edge quantities -/

theorem ev_cross {Q0 Q1 P : P2} {q0 q1 p : V α}
    (h0 : EV env Q0.1 q0.1 ∧ EV env Q0.2 q0.2) (h1 : EV env Q1.1 q1.1 ∧ EV env Q1.2 q1.2)
    (hp : EV env P.1 p.1 ∧ EV env P.2 p.2) : EV env (crossA Q0 Q1 P) (crossR q0 q1 p) :=
  ev_subA (ev_mulA (ev_subA h1.1 h0.1) (ev_subA hp.2 h0.2))
    (ev_mulA (ev_subA h1.2 h0.2) (ev_subA hp.1 h0.1))

theorem ev_dot {Q0 Q1 P0 P1 : P2} {q0 q1 p0 p1 : V α}
    (h0 : EV env Q0.1 q0.1 ∧ EV env Q0.2 q0.2) (h1 : EV env Q1.1 q1.1 ∧ EV env Q1.2 q1.2)
    (h2 : EV env P0.1 p0.1 ∧ EV env P0.2 p0.2) (h3 : EV env P1.1 p1.1 ∧ EV env P1.2 p1.2) :
    EV env (dotA Q0 Q1 P0 P1) (dotR q0 q1 p0 p1) :=
  ev_addA (ev_mulA (ev_subA h1.1 h0.1) (ev_subA h3.1 h2.1))
    (ev_mulA (ev_subA h1.2 h0.2) (ev_subA h3.2 h2.2))

theorem ev_tol {P0 P1 Q0 Q1 : P2} {p0 p1 q0 q1 : V α}
    (h2 : EV env P0.1 p0.1 ∧ EV env P0.2 p0.2) (h3 : EV env P1.1 p1.1 ∧ EV env P1.2 p1.2)
    (h0 : EV env Q0.1 q0.1 ∧ EV env Q0.2 q0.2) (h1 : EV env Q1.1 q1.1 ∧ EV env Q1.2 q1.2) :
    EV env (tolA P0 P1 Q0 Q1) (tolR p0 p1 q0 q1) :=
  ev_mul3 (ev_addA (ev_absA (ev_subA h1.1 h0.1)) (ev_absA (ev_subA h1.2 h0.2)))
    (ev_add3 (ev_addA (ev_absA h2.1) (ev_absA h2.2)) (ev_addA (ev_absA h3.1) (ev_absA h3.2))
      (ev_addA (ev_absA h0.1) (ev_absA h0.2))) (ev_lit 1 12)

theorem ev_on {c tl : Ast} {cv tv : α} (hc : EV env c cv) (ht : EV env tl tv) :
    EB env (onA c tl) (onR cv tv) := ev_leA (ev_absA hc) ht

theorem ev_ltNeg {s c tl : Ast} {sv cv tv : α} (hs : EV env s sv) (hc : EV env c cv)
    (ht : EV env tl tv) : EB env (ltNegA s c tl) (ltNegR sv cv tv) :=
  ev_ltA (ev_mulA hs hc) (ev_negA ht)

theorem ev_ratio {c0 c1 : Ast} {u v : α} (h0 : EV env c0 u) (h1 : EV env c1 v) :
    EV env (ratioA c0 c1) (ratioR u v) :=
  ev_divA h0 (ev_iteA (ev_eqA h0 h1) ev_one' (ev_subA h0 h1))

theorem ev_cand1 {s c0 c1 tl : Ast} {sv u v tv : α} (hs : EV env s sv) (h0 : EV env c0 u)
    (h1 : EV env c1 v) (ht : EV env tl tv) :
    EV env (cand1A s c0 c1 tl) (cand1R sv u v tv) :=
  ev_iteA (ev_andA (ev_on h0 ht) (ev_on h1 ht)) ev_one'
    (ev_iteA (ev_ltNeg hs h0 ht) ev_one'
      (ev_iteA (ev_ltNeg hs h1 ht) (ev_iteA (ev_on h0 ht) ev_zero' (ev_ratio h0 h1)) ev_one'))

theorem ev_cand0 {s c0 c1 tl both : Ast} {sv u v tv bv : α} (hs : EV env s sv)
    (h0 : EV env c0 u) (h1 : EV env c1 v) (ht : EV env tl tv) (hb : EV env both bv) :
    EV env (cand0A s c0 c1 tl both) (cand0R sv u v tv bv) :=
  ev_iteA (ev_andA (ev_on h0 ht) (ev_on h1 ht)) hb
    (ev_iteA (ev_ltNeg hs h0 ht)
      (ev_iteA (ev_ltNeg hs h1 ht) ev_one' (ev_iteA (ev_on h1 ht) ev_one' (ev_ratio h0 h1)))
      ev_zero')

/-! ### The `+` reduction -/

theorem foldlM_sumR (g : ℕ → α) (step : α → ℤ → Except EvalError α) (M : ℕ)
    (hstep : ∀ acc (i : ℕ), i < M → step acc ((1 : ℤ) + i) = .ok (add acc (g (i + 1)))) :
    ∀ m, m ≤ M → ((List.range m).map (fun i : ℕ => (1 : ℤ) + i)).foldlM step zero =
      .ok (sumR g m) := by
  intro m
  induction m with
  | zero => intro _; rfl
  | succ m ih =>
    intro hm
    have hs := hstep (sumR g m) m (by omega)
    rw [List.range_succ, List.map_append, List.foldlM_append, ih (by omega)]
    simp only [List.map_cons, List.map_nil, List.foldlM_cons, List.foldlM_nil, bind,
      Except.bind, hs, pure, Except.pure, sumR]

theorem ev_faq_sum {k : String} {body : Ast} {args : List Ast} {n : ℕ} (hn : n ≤ 2 ^ 53)
    (g : ℕ → α)
    (hb : ∀ j : ℕ, 1 ≤ j → j ≤ n → EV ((k, .num (fin (j : ℝ))) :: env) body (g j)) :
    EV env (.faq [] "+" (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) body args) (sumR g n) := by
  have o1 : (Lits.ofDec (1 : ℤ) 0 : α) = fin 1 := by
    simpa using ofDec_nat' (α := α) (j := 1) (by norm_num)
  have t1 : Lits.toInt? (fin 1 : α) = some 1 := by
    simpa using toInt_nat (α := α) 1
  have hi : indices 1 (n : ℤ) = (List.range n).map (fun i : ℕ => (1 : ℤ) + (i : ℤ)) := by
    simp [indices]
  have hfold := foldlM_sumR (α := α) g (fun acc j => do
      faqStep acc (← eval body ((k, .num (Lits.ofDec j 0)) :: env))) n ?_ n le_rfl
  · simp only [EV, eval, asNum, asInt, o1, t1, toInt_n hn, bind, Except.bind, pure,
      Except.pure, Option.bind, hi] at hfold ⊢
    rw [hfold]
  · intro acc i hi'
    have e : (Lits.ofDec ((1 : ℤ) + (i : ℤ)) 0 : α) = fin (((i + 1 : ℕ)) : ℝ) := by
      rw [show (1 : ℤ) + (i : ℤ) = ((i + 1 : ℕ) : ℤ) by push_cast; ring]
      exact ofDec_nat' (by omega)
    have := hb (i + 1) (by omega) (by omega)
    unfold EV at this
    simp only [e, this, faqStep, bind, Except.bind, pure, Except.pure, asNum]

end Eval

/-! ## The template, evaluated -/

section Main

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α]

/-- The environment binds the two ring stacks and the two cell indices. -/
def Good (MA : List (List (List α))) (ca : ℕ) (MB : List (List (List α))) (cb : ℕ)
    (env : Env α) : Prop :=
  env.lookup "RA" = some (.arr3 MA) ∧ env.lookup "CA" = some (.num (fin (ca : ℝ))) ∧
    env.lookup "RB" = some (.arr3 MB) ∧ env.lookup "CB" = some (.num (fin (cb : ℝ)))

theorem good_cons {MA MB : List (List (List α))} {ca cb : ℕ} {env : Env α} {kk : String}
    (v : Val α) (hk : kk ∈ [k1, k2, k3, k4, k5, k6, k7, k8]) (h : Good MA ca MB cb env) :
    Good MA ca MB cb ((kk, v) :: env) := by
  obtain ⟨h1, h2, h3, h4⟩ := h
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hk
  rcases hk with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    exact ⟨by simpa [List.lookup, k1, k2, k3, k4, k5, k6, k7, k8] using h1,
      by simpa [List.lookup, k1, k2, k3, k4, k5, k6, k7, k8] using h2,
      by simpa [List.lookup, k1, k2, k3, k4, k5, k6, k7, k8] using h3,
      by simpa [List.lookup, k1, k2, k3, k4, k5, k6, k7, k8] using h4⟩

theorem lookup_head {env : Env α} {kk : String} {j : ℕ} :
    EV ((kk, .num (fin (j : ℝ))) :: env) (.var kk) (fin (j : ℝ)) :=
  ev_lookup _ (by simp)

theorem lookup_under {env : Env α} {kk kk' : String} {v : Val α} {j : ℕ} (hne : kk ≠ kk')
    (h : EV env (.var kk) (fin (j : ℝ))) : EV ((kk', v) :: env) (.var kk) (fin (j : ℝ)) := by
  have hb : (kk == kk') = false := by simp [hne]
  unfold EV at h ⊢
  simp only [eval] at h ⊢
  simp only [List.lookup, hb]
  exact h

variable {MA MB : List (List (List α))} {ca cb na nb : ℕ}

theorem ev_vA {env : Env α} (hG : Good MA ca MB cb env) (hS : Shape MA ca na) {i : Ast} {j : ℕ}
    (hi : EV env i (fin (j : ℝ))) (hj1 : 1 ≤ j) (hjn : j ≤ na) :
    EV env (vtx RA CA i).1 (vat MA ca j).1 ∧ EV env (vtx RA CA i).2 (vat MA ca j).2 :=
  ev_vtx (ev_lookup _ hG.1) (ev_lookup _ hG.2.1) hi hS hj1 hjn

theorem ev_vB {env : Env α} (hG : Good MA ca MB cb env) (hS : Shape MB cb nb) {i : Ast} {j : ℕ}
    (hi : EV env i (fin (j : ℝ))) (hj1 : 1 ≤ j) (hjn : j ≤ nb) :
    EV env (vtx RB CB i).1 (vat MB cb j).1 ∧ EV env (vtx RB CB i).2 (vat MB cb j).2 :=
  ev_vtx (ev_lookup _ hG.2.2.1) (ev_lookup _ hG.2.2.2) hi hS hj1 hjn

theorem nxt_mem {n j : ℕ} (h1 : 1 ≤ j) (h2 : j ≤ n) : 1 ≤ nxt n j ∧ nxt n j ≤ n := by
  unfold nxt; split <;> omega

theorem ev_fanRA {env : Env α} (hG : Good MA ca MB cb env) (hS : Shape MA ca na) (h1 : 1 ≤ na)
    (hn : na < 2 ^ 53) : EV env (fanA RA CA (.num (na : ℤ) 0) k1) (fanR MA ca na) := by
  refine ev_faq_sum hn.le _ (fun j j1 jn => ?_)
  have hG' := good_cons (.num (fin (j : ℝ))) (by simp) hG (kk := k1)
  have hx := nxt_mem j1 jn
  exact ev_cross (ev_vA hG' hS (ev_lit1 _) le_rfl h1) (ev_vA hG' hS lookup_head j1 jn)
    (ev_vA hG' hS (ev_nxt hn lookup_head jn) hx.1 hx.2)

theorem ev_fanRB {env : Env α} (hG : Good MA ca MB cb env) (hS : Shape MB cb nb) (h1 : 1 ≤ nb)
    (hn : nb < 2 ^ 53) : EV env (fanA RB CB (.num (nb : ℤ) 0) k2) (fanR MB cb nb) := by
  refine ev_faq_sum hn.le _ (fun j j1 jn => ?_)
  have hG' := good_cons (.num (fin (j : ℝ))) (by simp) hG (kk := k2)
  have hx := nxt_mem j1 jn
  exact ev_cross (ev_vB hG' hS (ev_lit1 _) le_rfl h1) (ev_vB hG' hS lookup_head j1 jn)
    (ev_vB hG' hS (ev_nxt hn lookup_head jn) hx.1 hx.2)

theorem ev_sgn {env : Env α} {f : Ast} {fv : α} (hf : EV env f fv) : EV env (sgnA f) (sgnR fv) :=
  ev_iteA (ev_geA hf ev_zero') ev_one' (ev_lit (-1) 0)

/-- **The planar overlap template computes the clip-area algorithm.** For two
ring stacks with `na`, `nb` vertex slots (`1 ≤ n < 2^53`) of two coordinates
in the named cells, `overlap_area_planar` applied and evaluated is
`planarRef`, at every scalar type with `RealNaN` and `ExprLaws`; at `Bin64`
this is bit-for-bit. -/
theorem planar_template_eq (hSA : Shape MA ca na) (hSB : Shape MB cb nb) (ha1 : 1 ≤ na)
    (hb1 : 1 ≤ nb) (han : na < 2 ^ 53) (hbn : nb < 2 ^ 53) :
    evalApplyIn Esm.Lib.Geometry.lib 32 Esm.Lib.Geometry.overlap_area_planar (bindP na nb)
        [("RA", .arr3 MA), ("CA", .num (fin (ca : ℝ))), ("RB", .arr3 MB),
          ("CB", .num (fin (cb : ℝ)))] =
      .ok (.num (planarRef MA ca na MB cb nb)) := by
  set E0 : Env α := [("RA", .arr3 MA), ("CA", .num (fin (ca : ℝ))), ("RB", .arr3 MB),
    ("CB", .num (fin (cb : ℝ)))]
  have hG0 : Good MA ca MB cb E0 := ⟨rfl, rfl, rfl, rfl⟩
  suffices h : EV E0 (planarA (.num (na : ℤ) 0) (.num (nb : ℤ) 0)) (planarRef MA ca na MB cb nb) by
    unfold evalApplyIn; rw [expand_planar]; simp only []; rw [h]
  obtain ⟨ma, rfl⟩ : ∃ m, na = m + 1 := ⟨na - 1, by omega⟩
  obtain ⟨mb, rfl⟩ : ∃ m, nb = m + 1 := ⟨nb - 1, by omega⟩
  have hfA : ∀ env, Good MA ca MB cb env →
      EV env (fanA RA CA (.num ((ma + 1 : ℕ) : ℤ) 0) k1) (fanR MA ca (ma + 1)) :=
    fun env hG => ev_fanRA hG hSA ha1 han
  have hfB : ∀ env, Good MA ca MB cb env →
      EV env (fanA RB CB (.num ((mb + 1 : ℕ) : ℤ) 0) k2) (fanR MB cb (mb + 1)) :=
    fun env hG => ev_fanRB hG hSB hb1 hbn
  unfold planarA planarRef
  simp only [Nat.add_sub_cancel]
  refine ev_iteA (ev_orA (ev_eqA (hfA E0 hG0) ev_zero') (ev_eqA (hfB E0 hG0) ev_zero')) ev_zero'
    (ev_addA ?_ ?_)
  · -- A's edges, clipped by B's half-planes
    refine ev_faq_sum han.le _ (fun i i1 i2 => ?_)
    have hG3 : Good MA ca MB cb ((k3, .num (fin (i : ℝ))) :: E0) := good_cons _ (by simp) hG0
    have hx := nxt_mem i1 i2
    have ha0 := ev_vA hG3 hSA (lookup_head (kk := k3)) i1 i2
    have ha1' := ev_vA hG3 hSA (ev_nxt han lookup_head i2) hx.1 hx.2
    have hO := ev_vA hG3 hSA (ev_lit1 _) le_rfl ha1
    refine ev_mul4 (ev_sgn (hfA _ hG3)) (ev_maxA ev_zero' (ev_subA ?_ ?_)) (ev_cross hO ha0 ha1')
      (ev_lit 5 1)
    · refine ev_faq_min (m := mb) (by omega) _ (fun j j1 j2 => ?_)
      have hG5 : Good MA ca MB cb ((k5, .num (fin (j : ℝ))) :: (k3, .num (fin (i : ℝ))) :: E0) :=
        good_cons _ (by simp) hG3
      have hy := nxt_mem j1 j2
      have hq0 := ev_vB hG5 hSB (lookup_head (kk := k5)) j1 j2
      have hq1 := ev_vB hG5 hSB (ev_nxt hbn lookup_head j2) hy.1 hy.2
      have hk3 : EV ((k5, .num (fin (j : ℝ))) :: (k3, .num (fin (i : ℝ))) :: E0) (.var k3)
          (fin (i : ℝ)) := lookup_under (by simp [k3, k5]) lookup_head
      have hp0 := ev_vA hG5 hSA hk3 i1 i2
      have hp1 := ev_vA hG5 hSA (ev_nxt han hk3 i2) hx.1 hx.2
      exact ev_cand1 (ev_sgn (hfB _ hG5)) (ev_cross hq0 hq1 hp0) (ev_cross hq0 hq1 hp1)
        (ev_tol hp0 hp1 hq0 hq1)
    · refine ev_faq_max (m := mb) (by omega) _ (fun j j1 j2 => ?_)
      have hG4 : Good MA ca MB cb ((k4, .num (fin (j : ℝ))) :: (k3, .num (fin (i : ℝ))) :: E0) :=
        good_cons _ (by simp) hG3
      have hy := nxt_mem j1 j2
      have hq0 := ev_vB hG4 hSB (lookup_head (kk := k4)) j1 j2
      have hq1 := ev_vB hG4 hSB (ev_nxt hbn lookup_head j2) hy.1 hy.2
      have hk3 : EV ((k4, .num (fin (j : ℝ))) :: (k3, .num (fin (i : ℝ))) :: E0) (.var k3)
          (fin (i : ℝ)) := lookup_under (by simp [k3, k4]) lookup_head
      have hp0 := ev_vA hG4 hSA hk3 i1 i2
      have hp1 := ev_vA hG4 hSA (ev_nxt han hk3 i2) hx.1 hx.2
      exact ev_cand0 (ev_sgn (hfB _ hG4)) (ev_cross hq0 hq1 hp0) (ev_cross hq0 hq1 hp1)
        (ev_tol hp0 hp1 hq0 hq1)
        (ev_iteA (ev_ltA (ev_mul3 (ev_sgn (hfA _ hG4)) (ev_sgn (hfB _ hG4))
          (ev_dot hq0 hq1 hp0 hp1)) ev_zero') ev_one' ev_zero')
  · -- B's edges, clipped by A's half-planes
    refine ev_faq_sum hbn.le _ (fun i i1 i2 => ?_)
    have hG6 : Good MA ca MB cb ((k6, .num (fin (i : ℝ))) :: E0) := good_cons _ (by simp) hG0
    have hx := nxt_mem i1 i2
    have hb0 := ev_vB hG6 hSB (lookup_head (kk := k6)) i1 i2
    have hb1' := ev_vB hG6 hSB (ev_nxt hbn lookup_head i2) hx.1 hx.2
    have hO := ev_vA hG6 hSA (ev_lit1 _) le_rfl ha1
    refine ev_mul4 (ev_sgn (hfB _ hG6)) (ev_maxA ev_zero' (ev_subA ?_ ?_)) (ev_cross hO hb0 hb1')
      (ev_lit 5 1)
    · refine ev_faq_min (m := ma) (by omega) _ (fun j j1 j2 => ?_)
      have hG8 : Good MA ca MB cb ((k8, .num (fin (j : ℝ))) :: (k6, .num (fin (i : ℝ))) :: E0) :=
        good_cons _ (by simp) hG6
      have hy := nxt_mem j1 j2
      have hq0 := ev_vA hG8 hSA (lookup_head (kk := k8)) j1 j2
      have hq1 := ev_vA hG8 hSA (ev_nxt han lookup_head j2) hy.1 hy.2
      have hk6 : EV ((k8, .num (fin (j : ℝ))) :: (k6, .num (fin (i : ℝ))) :: E0) (.var k6)
          (fin (i : ℝ)) := lookup_under (by simp [k6, k8]) lookup_head
      have hp0 := ev_vB hG8 hSB hk6 i1 i2
      have hp1 := ev_vB hG8 hSB (ev_nxt hbn hk6 i2) hx.1 hx.2
      exact ev_cand1 (ev_sgn (hfA _ hG8)) (ev_cross hq0 hq1 hp0) (ev_cross hq0 hq1 hp1)
        (ev_tol hp0 hp1 hq0 hq1)
    · refine ev_faq_max (m := ma) (by omega) _ (fun j j1 j2 => ?_)
      have hG7 : Good MA ca MB cb ((k7, .num (fin (j : ℝ))) :: (k6, .num (fin (i : ℝ))) :: E0) :=
        good_cons _ (by simp) hG6
      have hy := nxt_mem j1 j2
      have hq0 := ev_vA hG7 hSA (lookup_head (kk := k7)) j1 j2
      have hq1 := ev_vA hG7 hSA (ev_nxt han lookup_head j2) hy.1 hy.2
      have hk6 : EV ((k7, .num (fin (j : ℝ))) :: (k6, .num (fin (i : ℝ))) :: E0) (.var k6)
          (fin (i : ℝ)) := lookup_under (by simp [k6, k7]) lookup_head
      have hp0 := ev_vB hG7 hSB hk6 i1 i2
      have hp1 := ev_vB hG7 hSB (ev_nxt hbn hk6 i2) hx.1 hx.2
      exact ev_cand0 (ev_sgn (hfA _ hG7)) (ev_cross hq0 hq1 hp0) (ev_cross hq0 hq1 hp1)
        (ev_tol hp0 hp1 hq0 hq1)
        (ev_iteA (ev_eqA (ev_mul3 (ev_sgn (hfB _ hG7)) (ev_sgn (hfA _ hG7))
          (ev_dot hq0 hq1 hp0 hp1)) ev_zero') ev_zero' ev_one')

end Main

end Esm.Closed.GeometryAst
