import Esm.Document.Source.Typst
import Esm.Document.Source.MarkdownDoc

/-!
# Typst documents: printing, parsing, and the round trip

`printTyp` spells a canonical ESM document as Typst, `parseTyp` reads it back, and
`parseTyp_printTyp` is the round trip, composed exactly as for Markdown
(`Esm.Document.Source.MarkdownDoc`) with the Typst math theorem `parseTypst_printTypst`.
-/

namespace Esm.Document.Source.Typ

open Esm.Document Esm.Document.Math Esm.Document.Source Esm.Document.Strings

/-! ## Equations in Typst math -/

def typOf (S : Sym) (e : Eqn) : List Char := (printTypst S (eqExpr e)).toList

/-- An equation's math text: its `_comment` as a `//` comment line, then the equation. -/
def prT (S : Sym) (e : Eqn) : String :=
  String.ofList ((match e.comment with
    | some c => '/' :: '/' :: ' ' :: c.toList ++ ['\n']
    | none => []) ++ typOf S e)

/-- One display in Typst math: one equation, or (an accepted variant) several rows
separated by `\` with `&` alignment, read by `cookRows` (`cookRows_layout`). -/
def oneT (S : Sym) (c : Option String) (body : List Char) : Option (List Eqn) :=
  match (parseTypst S (String.ofList body)).bind eqSides with
  | some (l, r) => some [⟨c, l, r⟩]
  | none => ((Typst.lex body).bind (cookRows .typst S false)).map (Md.withComment c)

/-- **Read the math text of a display equation** under the symbol table `S`. -/
def ckT (S : Sym) (raw : String) : Option (List Eqn) :=
  match raw.toList with
  | '/' :: '/' :: ' ' :: r => oneT S (some (String.ofList (splitLine r).1)) (splitLine r).2
  | cs => oneT S none cs

/-- A math entry's text: an equation's Typst math (`prT`), or a reaction with its rate
as Typst math. -/
def prTx : Sym → MC → MR := prMx prT (fun S j => printTypst S j)

/-- Read a math entry's text. -/
def ckTx : Sym → MR → Option (List MC) := ckMx ckT (fun S raw => parseTypst S raw)

/-! ## What Typst spells natively -/

/-- The Typst container's predicates: front-matter keys and attributes are named
arguments (identifiers that are not keywords); an equation's Typst math must not contain
`$` nor start with `//` (it may span lines: a code value inside an escape node does). Descriptions and component names are always
spellable (escapes). -/
def capsT : Caps where
  frontKey k := bareKey TypstDict.reserved k
  desc _ := true
  compName _ := true
  declName n := nameOK n && !(nameTyp n).contains '$'
  attr a := bareKey TypstDict.reserved a.1
  eqn S e := Md.commentOK e.comment && !(typOf S e).contains '$' && !pre ['/', '/'] (typOf S e) &&
    (tmLexT (prT S e).toList).isNone
  rxn S x := rxnOK { x with rate := printTypst S x.rate }
  plot a := a.all argOK
  tm S t := itemOK (.tm { t with lhs := t.lhs.map (fun j => printTypst S j), body := printTypst S t.body })

theorem ckT_prT (S : Sym) (e : Eqn) (hc : capsT.eqn S e = true) (hl : isE e.lhs = true)
    (hr : isE e.rhs = true) : ckT S (prT S e) = some [e] := by
  simp only [capsT, Bool.and_eq_true, Bool.not_eq_true'] at hc
  obtain ⟨⟨⟨hcm, hd⟩, hp⟩, -⟩ := hc
  have hparse : (parseTypst S (String.ofList (typOf S e))).bind eqSides = some (e.lhs, e.rhs) := by
    simp only [typOf, String.ofList_toList, parseTypst_printTypst S _ (isE_eqExpr e hl hr),
      Option.bind_some, eqSides_eqExpr]
  obtain ⟨cm, l, r⟩ := e
  unfold ckT prT
  rw [String.toList_ofList]
  cases cm with
  | some c =>
    simp only [Md.commentOK, Bool.and_eq_true, Bool.not_eq_true'] at hcm
    simp only [List.cons_append, List.append_assoc]
    rw [splitLine_line _ _ (Md.contains_false hcm.1)]
    simp only [oneT, String.ofList_toList, List.nil_append]
    rw [hparse]
  | none =>
    simp only [List.nil_append]
    split
    · rename_i r' h; rw [h] at hp; simp [pre] at hp
    · simp only [oneT]; rw [hparse]

/-! ## The document -/

/-- The header: the package import, then `#show: esm-document.with(…)` with the
front-matter entries. -/
def headerT (front : List (String × Json)) : List Char := header ++ argsFirstT front ++ [')', '\n']

/-- The canonical layout: each construct after a blank line. -/
def canonSegs (its : List RItem) : List Seg :=
  its.flatMap (fun it => [.prose ['\n'], .item it] ++ (if isBlock it then [] else [.prose ['\n']]))

/-- **Print a document as Typst.** -/
def printTyp (d : Json) : String :=
  let D := toDoc capsT d
  String.ofList (headerT D.front ++ render (canonSegs (items (rawDoc prTx D))))

/-- Read the header and the constructs. -/
def lexDoc (s : List Char) : Option (List (String × Json) × List RItem) :=
  if pre header s then
    match pArgsFirst (3 * s.length + 3) (s.length + 1) (s.drop header.length) with
    | some (front, r) =>
      match lineEnd r with
      | some r' => (lex (s.length + 1) true r').map (fun its => (front, its))
      | none => none
    | none => none
  else none

/-- **Read a Typst document.** -/
def parseTyp (s : String) : Option Json := do
  let p ← lexDoc s.toList
  let R ← unitems p.1 p.2
  let D ← cookDoc ckTx R
  ofDoc D

theorem segItems_append (a b : List Seg) : segItems (a ++ b) = segItems a ++ segItems b := by
  induction a with
  | nil => rfl
  | cons x a ih => cases x <;> simp [segItems, ih]

theorem segItems_canon (its : List RItem) : segItems (canonSegs its) = its := by
  induction its with
  | nil => rfl
  | cons it its ih =>
    simp only [canonSegs, List.flatMap_cons] at ih ⊢
    rw [segItems_append, ih]
    cases it with
    | decl d => by_cases hk : d.kind = .sub <;> simp [segItems, isBlock, hk]
    | _ => simp [segItems, isBlock]

theorem inert_nl (bol : Bool) (t : List Char) : Inert bol ['\n'] t := by
  refine ⟨?_, ?_, trivial⟩
  · simp [blockOpen, oDesc, oBlock, oModel, oRs, oEq, oCe_l, oRxn_l, oInit_l, oCons_l, oPlot_l, oSub_l,
      oTmpl_l, oRule_l, pre]
  · simp [declOpen, oVar, oParam, oSpecies, pre]

theorem valid_canon : ∀ (its : List RItem), (∀ it ∈ its, itemOK it = true) →
    ∀ bol, Valid bol (canonSegs its)
  | [], _, _ => trivial
  | it :: its, h, bol => by
    have ih := valid_canon its (fun x hx => h x (List.mem_cons_of_mem _ hx))
    have hit := h it List.mem_cons_self
    simp only [canonSegs, List.flatMap_cons] at ih ⊢
    cases it with
    | decl d =>
      obtain ⟨k, n, as⟩ := d
      cases k
      · exact ⟨inert_nl _ _, hit, fun h => by simp [isBlock] at h, inert_nl _ _, ih _⟩
      · exact ⟨inert_nl _ _, hit, fun h => by simp [isBlock] at h, inert_nl _ _, ih _⟩
      · exact ⟨inert_nl _ _, hit, fun h => by simp [isBlock] at h, inert_nl _ _, ih _⟩
      · exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | desc _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | block _ _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | comp _ _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | eqn _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | eqx _ _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | rxn _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | plot _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | tm _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩

theorem argsFirstT_len (as : List (String × Json)) : as.length ≤ (argsFirstT as).length := by
  cases as with
  | nil => simp [argsFirstT]
  | cons a as =>
    have := argsMoreT_len as
    have h1 : 1 ≤ (argT a).length := by simp [argT]; omega
    simp [argsFirstT]; omega

theorem argsFirstT_size (as : List (String × Json)) : ∀ a ∈ as, a.2.size ≤ (argsFirstT as).length := by
  intro a ha
  cases as with
  | nil => cases ha
  | cons b bs =>
    simp only [argsFirstT, List.length_append]
    rcases List.mem_cons.mp ha with rfl | h
    · have := size_le_argT a; omega
    · have := argsMoreT_size bs a h; omega

/-- **The header and the body read back.** -/
theorem lexDoc_front (front : List (String × Json)) (hf : ∀ a ∈ front, argOK a = true)
    (segs : List Seg) (hv : Valid true segs) :
    lexDoc (headerT front ++ render segs) = some (front, segItems segs) := by
  unfold lexDoc headerT
  simp only [List.append_assoc, pre_append, ite_true, List.drop_left]
  have hl := argsFirstT_len front
  have hs := argsFirstT_size front
  rw [show [')', '\n'] ++ render segs = ')' :: ('\n' :: render segs) from rfl,
    pArgsFirst_argsFirstT _ front hf (fun a ha => by have := hs a ha; simp; omega) _ _
    (by simp; omega)]
  simp only [lineEnd_nl]
  rw [lex_render segs true hv _ (by simp; omega)]
  rfl

theorem typ_noDollar (S : Sym) (e : Eqn) (hc : capsT.eqn S e = true) :
    (prT S e).toList.contains '$' = false := by
  simp only [capsT, Bool.and_eq_true, Bool.not_eq_true'] at hc
  obtain ⟨⟨⟨hcm, hd⟩, _⟩, _⟩ := hc
  unfold prT
  rw [String.toList_ofList]
  rw [Bool.eq_false_iff]
  intro hm
  rw [List.contains_iff_mem] at hm
  simp only [List.mem_append] at hm
  rcases hm with hm | hm
  · cases hcom : e.comment with
    | none => rw [hcom] at hm; cases hm
    | some c =>
      rw [hcom] at hm hcm
      simp only [Md.commentOK, Bool.and_eq_true, Bool.not_eq_true'] at hcm
      simp only [List.cons_append, List.mem_cons, List.mem_append] at hm
      rcases hm with h | h | h | h | h | h
      · cases h
      · cases h
      · cases h
      · exact Md.contains_false hcm.2 h
      · cases h
      · cases h
  · exact Md.contains_false hd hm

/-- Every construct of the printed skeleton satisfies `itemOK`. -/
theorem items_ok (D : Doc MC) (h : DocOK capsT D) :
    ∀ it ∈ items (rawDoc prTx D), itemOK it = true := by
  intro it hit
  simp only [items, rawDoc, List.mem_append, List.mem_map, List.mem_flatMap, Option.mem_toList,
    Option.map_eq_some_iff] at hit
  rcases hit with (((⟨s, hs, rfl⟩) | ⟨kv, hkv, rfl⟩) | ⟨m', ⟨m, hm, rfl⟩, rfl⟩) | ⟨c', ⟨c, hc, rfl⟩, hit⟩
  · rfl
  · exact h.blocks kv hkv
  · obtain ⟨hmc, -, t, rfl⟩ := h.rmath m hm
    exact hmc
  · simp only [compItems, Comp.mapMath, List.mem_cons, List.mem_append, List.mem_map,
      Option.mem_toList, Option.map_eq_some_iff] at hit
    rcases hit with rfl | (((((⟨s, hs, rfl⟩) | ⟨d, hd, rfl⟩) | ⟨r, ⟨m, hm, rfl⟩, rfl⟩) |
      ⟨kv, hkv, rfl⟩) | ⟨kv, hkv, rfl⟩)
    · rfl
    · rfl
    · have hn := h.declName c hc d hd
      have ha := h.attrs c hc d hd
      have hat : d.attrs.all argOK = true := List.all_eq_true.mpr fun a hma => by
        have := ha a hma
        simp only [argOK, Bool.and_eq_true]
        exact ⟨this.1, this.2⟩
      simp only [capsT, Bool.and_eq_true] at hn
      simp only [itemOK]
      split
      · exact hat
      · simp only [declOK, Bool.and_eq_true]; exact ⟨hn, hat⟩
    · have hmc := (h.math c hc m hm).1
      cases m with
      | eq ro e =>
        have hns := typ_noDollar _ e hmc
        have htm : (tmLexT (prT (symFor D c) e).toList).isNone = true := by
          simp only [Caps.item, capsT, Bool.and_eq_true] at hmc; exact hmc.2
        cases ro with
        | eqn => simp only [prTx, prMx, mItem, itemOK, hns, Bool.not_false, htm, Bool.and_self]
        | init => simp only [prTx, prMx, mItem, itemOK, hns, Bool.not_false, Bool.and_true]; decide
        | cons => simp only [prTx, prMx, mItem, itemOK, hns, Bool.not_false, Bool.and_true]; decide
      | rxn x => exact hmc
      | plot a => exact hmc
      | tm t => exact hmc
    · exact (h.mathBlocks c hc kv hkv).2
    · exact (h.cblocks c hc kv hkv).2

/-- **The Typst round trip.** Every ESM document in canonical form reads back from its
Typst spelling. -/
theorem parseTyp_printTyp (d : Json) (hd : canonDoc d = true) : parseTyp (printTyp d) = some d := by
  have hok := toDoc_ok capsT rfl d hd
  have hfront : ∀ a ∈ (toDoc capsT d).front, argOK a = true := by
    intro a ha
    have h1 := hok.front a ha
    have h2 := (jwf_obj_iff _).mp hok.frontWF
    simp only [argOK, Bool.and_eq_true]
    exact ⟨h1, h2.2 a ha⟩
  unfold parseTyp printTyp
  simp only [String.toList_ofList]
  rw [lexDoc_front _ hfront _ (valid_canon _ (items_ok _ hok) true), segItems_canon]
  simp only [Option.bind_eq_bind, Option.bind_some]
  have hR := unitems_items (rawDoc prTx (toDoc capsT d)) (by
    refine ⟨fun c hc => ?_, ?_⟩
    · simp only [rawDoc, List.mem_map] at hc
      obtain ⟨c0, hc0, rfl⟩ := hc
      exact ⟨fun kv hkv => (hok.cblocks c0 hc0 kv hkv).1, fun kv hkv => (hok.mathBlocks c0 hc0 kv hkv).1⟩
    · intro m hm
      simp only [rawDoc, List.mem_map] at hm
      obtain ⟨m0, hm0, rfl⟩ := hm
      obtain ⟨-, -, t, rfl⟩ := hok.rmath m0 hm0
      exact ⟨_, rfl⟩)
  rw [show (rawDoc prTx (toDoc capsT d)).front = (toDoc capsT d).front from rfl] at hR
  rw [hR]
  simp only [Option.bind_some]
  have hck : ∀ S m, capsT.item S m = true → mathWF m = true → ckTx S (prTx S m) = some [m] := by
    intro S m hc hw
    apply ckMx_prMx
    · intro r e he
      subst he
      simp only [mathWF, Bool.and_eq_true] at hw
      exact ckT_prT _ e hc hw.1 hw.2
    · intro x hx
      subst hx
      exact parseTypst_printTypst _ _ hw
    · intro t ht
      subst ht
      simp only [mathWF, tmWF, Bool.and_eq_true] at hw
      refine ⟨parseTypst_printTypst _ _ hw.1, fun l hl => parseTypst_printTypst _ _ ?_⟩
      have := hw.2; rw [hl] at this; simpa using this
  rw [cookDoc_rawDoc prTx ckTx (fun S => prMx_heads _ _ S) _
    (fun m hm => by
      have := hok.rmath m hm
      exact hck _ m this.1 this.2.1)
    (fun c hc m hm => by
      have := hok.math c hc m hm
      exact hck _ m this.1 this.2)]
  simp only [Option.bind_some]
  exact ofDoc_toDoc capsT d hd

/-! ## Prose and labels do not change the parse -/

def parseItemsT (front : List (String × Json)) (its : List RItem) : Option Json := do
  let R ← unitems front its
  let D ← cookDoc ckTx R
  ofDoc D

/-- **The parse of a Typst document depends only on its front matter and its sequence of
constructs**: not on the prose between them, and not on equation labels. -/
theorem parseTyp_body (front : List (String × Json)) (hf : ∀ a ∈ front, argOK a = true)
    (segs : List Seg) (hv : Valid true segs) :
    parseTyp (String.ofList (headerT front ++ render segs)) = parseItemsT front (segItems segs) := by
  unfold parseTyp parseItemsT
  simp only [String.toList_ofList]
  rw [lexDoc_front front hf segs hv]
  rfl

theorem parseTyp_eq_of_items (front : List (String × Json)) (hf : ∀ a ∈ front, argOK a = true)
    (s₁ s₂ : List Seg) (h₁ : Valid true s₁) (h₂ : Valid true s₂) (h : segItems s₁ = segItems s₂) :
    parseTyp (String.ofList (headerT front ++ render s₁)) =
      parseTyp (String.ofList (headerT front ++ render s₂)) := by
  rw [parseTyp_body front hf s₁ h₁, parseTyp_body front hf s₂ h₂, h]

theorem segItems_prose (a b : List Seg) (p : List Char) :
    segItems (a ++ .prose p :: b) = segItems (a ++ b) := by
  simp [segItems_append, segItems]

theorem segItems_label (a b : List Seg) (raw : String) (l : List Char) :
    segItems (a ++ .labeled raw l :: b) = segItems (a ++ .item (.eqn raw) :: b) := by
  simp [segItems_append, segItems]

/-- **Inserting prose does not change the parse.** -/
theorem parseTyp_insert_prose (front : List (String × Json)) (hf : ∀ a ∈ front, argOK a = true)
    (a b : List Seg) (p : List Char) (h₁ : Valid true (a ++ b)) (h₂ : Valid true (a ++ .prose p :: b)) :
    parseTyp (String.ofList (headerT front ++ render (a ++ .prose p :: b))) =
      parseTyp (String.ofList (headerT front ++ render (a ++ b))) :=
  parseTyp_eq_of_items front hf _ _ h₂ h₁ (segItems_prose a b p)

/-- **Adding an equation label does not change the parse.** -/
theorem parseTyp_label (front : List (String × Json)) (hf : ∀ a ∈ front, argOK a = true)
    (a b : List Seg) (raw : String) (l : List Char) (h₁ : Valid true (a ++ .item (.eqn raw) :: b))
    (h₂ : Valid true (a ++ .labeled raw l :: b)) :
    parseTyp (String.ofList (headerT front ++ render (a ++ .labeled raw l :: b))) =
      parseTyp (String.ofList (headerT front ++ render (a ++ .item (.eqn raw) :: b))) :=
  parseTyp_eq_of_items front hf _ _ h₂ h₁ (segItems_label a b raw l)

end Esm.Document.Source.Typ
