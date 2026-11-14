import Esm.Document.Source.Markdown
import Esm.Document.Source.Equation

/-!
# Markdown documents: printing, parsing, and the round trip

`printMd` spells a canonical ESM document as Markdown, `parseMd` reads it back, and
`parseMd_printMd` is the round trip. The layers compose:

1. `toDoc capsMd` (the skeleton, with the path-keyed fallback for anything Markdown
   cannot spell natively) and `ofDoc` — `ofDoc_toDoc`;
2. `rawDoc prMd` (each equation as LaTeX under its component's symbol table) and
   `cookDoc ckMd` — `cookDoc_rawDoc`, with the Phase 2 theorem `parseLatex_printLatex`;
3. `items` and `unitems` — `unitems_items`;
4. the text: front matter, then the constructs separated by blank lines — `lex_render`.
-/

namespace Esm.Document.Source.Md

open Esm.Document Esm.Document.Math Esm.Document.Source Esm.Document.Strings

/-! ## Equations in LaTeX -/

/-- An equation's LaTeX under the symbol table `S`. -/
def latexOf (S : Sym) (e : Eqn) : List Char := (printLatex S (eqExpr e)).toList

/-- An equation's math text: its `_comment` as a LaTeX comment line, then the equation. -/
def prMd (S : Sym) (e : Eqn) : String :=
  String.ofList ((match e.comment with
    | some c => '%' :: ' ' :: c.toList ++ ['\n']
    | none => []) ++ latexOf S e)

/-- One equation in LaTeX. -/
def oneMd (S : Sym) (c : Option String) (body : List Char) : Option (List Eqn) :=
  match (parseLatex S (String.ofList body)).bind eqSides with
  | some (l, r) => some [⟨c, l, r⟩]
  | none => none

/-- **Read the math text of a display equation** under the symbol table `S`: an
optional leading comment line `% …` (the `_comment`), then the equation. -/
def ckMd (S : Sym) (raw : String) : Option (List Eqn) :=
  match raw.toList with
  | '%' :: ' ' :: r => oneMd S (some (String.ofList (splitLine r).1)) (splitLine r).2
  | cs => oneMd S none cs

/-- A comment Markdown can carry on its LaTeX comment line. -/
def commentOK : Option String → Bool
  | some c => !c.toList.contains '\n' && !c.toList.contains '$'
  | none => true

/-! ## What Markdown spells natively -/

/-- The Markdown container's predicates. A description must not contain a line that
would close its fence (`noStop`; CommonMark also closes a fence indented by up to three
spaces, and treats a carriage return as a line end). An equation's LaTeX must be one
line without `$` and not start with `%`. -/
def capsMd : Caps where
  frontKey _ := true
  desc s := noStop fence (s.toList ++ ['\n']) && noStop (' ' :: fence) (s.toList ++ ['\n']) &&
    noStop (' ' :: ' ' :: fence) (s.toList ++ ['\n']) &&
    noStop (' ' :: ' ' :: ' ' :: fence) (s.toList ++ ['\n']) && !s.toList.contains '\r'
  compName n := !n.toList.contains ']' && !n.toList.contains '\n'
  declName n := nameOK n && !(nameLatex n).contains '$'
  attr a := isIdent a.1.toList && Yaml.isInl a.2
  eqn S e := commentOK e.comment && !(latexOf S e).contains '$' && !(latexOf S e).contains '\n' &&
    (latexOf S e).head? != some '%'

theorem heads_sub {c : Char} : ∀ {bol : Bool} {x : List Char}, c ∈ heads bol x → c ∈ x
  | _, [], h => by cases h
  | bol, d :: r, h => by
    simp only [heads, List.mem_append] at h
    rcases h with h | h
    · cases bol <;> simp_all
    · exact List.mem_cons_of_mem _ (heads_sub h)

theorem contains_false {c : Char} {x : List Char} (h : x.contains c = false) : c ∉ x := by
  intro hm
  have : x.contains c = true := List.contains_iff_mem.mpr hm
  rw [h] at this; cases this

/-- **An equation reads back from its LaTeX**, comment included. -/
theorem ckMd_prMd (S : Sym) (e : Eqn) (hc : capsMd.eqn S e = true) (hl : isE e.lhs = true)
    (hr : isE e.rhs = true) : ckMd S (prMd S e) = some [e] := by
  simp only [capsMd, Bool.and_eq_true, Bool.not_eq_true', bne_iff_ne, ne_eq] at hc
  obtain ⟨⟨⟨hcm, hd⟩, hn⟩, hp⟩ := hc
  have hparse : (parseLatex S (String.ofList (latexOf S e))).bind eqSides = some (e.lhs, e.rhs) := by
    simp only [latexOf, String.ofList_toList, parseLatex_printLatex S _ (isE_eqExpr e hl hr),
      Option.bind_some, eqSides_eqExpr]
  obtain ⟨cm, l, r⟩ := e
  unfold ckMd prMd
  rw [String.toList_ofList]
  cases cm with
  | some c =>
    simp only [commentOK, Bool.and_eq_true, Bool.not_eq_true'] at hcm
    simp only [List.cons_append, List.append_assoc]
    rw [splitLine_line _ _ (contains_false hcm.1)]
    simp only [oneMd, String.ofList_toList, List.nil_append]
    rw [hparse]
  | none =>
    simp only [List.nil_append]
    split
    · rename_i r' h; rw [h] at hp; simp at hp
    · simp only [oneMd]; rw [hparse]

/-! ## The document -/

/-- The front matter: `---`, the YAML of the entries, `---`. -/
def frontMd (front : List (String × Json)) : List Char :=
  dashes ++ '\n' :: Yaml.encode (.obj front) ++ dashes ++ ['\n']

/-- The canonical layout: each construct after a blank line, a declaration on a line of
its own. -/
def canonSegs (its : List RItem) : List Seg :=
  its.flatMap (fun it => [.prose ['\n'], .item it] ++ (if isBlock it then [] else [.prose ['\n']]))

/-- **Print a document as Markdown.** -/
def printMd (d : Json) : String :=
  let D := toDoc capsMd d
  String.ofList (frontMd D.front ++ render (canonSegs (items (rawDoc prMd D))))

/-- Read the front matter and the constructs. -/
def lexDoc (s : List Char) : Option (List (String × Json) × List RItem) :=
  match s with
  | '-' :: '-' :: '-' :: '\n' :: r =>
    match untilStop dashes (s.length + 1) r with
    | some (body, sl, rest) =>
      if sl.all (· == ' ') then
        match Yaml.decode body with
        | some (.obj kvs) => (lex (s.length + 1) true rest).map (fun its => (kvs, its))
        | _ => none
      else none
    | none => none
  | _ => none

/-- **Read a Markdown document.** -/
def parseMd (s : String) : Option Json := do
  let p ← lexDoc s.toList
  let R ← unitems p.1 p.2
  let D ← cookDoc ckMd R
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
    cases it <;> simp [segItems, isBlock]

theorem render_append (a b : List Seg) : render (a ++ b) = render a ++ render b := by
  simp [render]

theorem inert_nl (bol : Bool) (t : List Char) : Inert bol ['\n'] t := by
  refine ⟨?_, ?_, trivial⟩
  · simp [blockOpen, fenceEsm, dd, dModel, dRs, pre]
  · simp [declOpen, pre]

theorem valid_canon : ∀ (its : List RItem), (∀ it ∈ its, itemOK it = true) →
    ∀ bol, Valid bol (canonSegs its)
  | [], _, _ => trivial
  | it :: its, h, bol => by
    have ih := valid_canon its (fun x hx => h x (List.mem_cons_of_mem _ hx))
    have hit := h it List.mem_cons_self
    simp only [canonSegs, List.flatMap_cons] at ih ⊢
    cases it with
    | decl d => exact ⟨inert_nl _ _, hit, fun h => by simp [isBlock] at h, inert_nl _ _, ih _⟩
    | desc _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | block _ _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | comp _ _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | eqn _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩

/-- **The front matter and the body read back.** -/
theorem lexDoc_front (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (segs : List Seg) (hv : Valid true segs) :
    lexDoc (frontMd front ++ render segs) = some (front, segItems segs) := by
  have hw : (Json.obj front).WF := jwf_sound _ hf
  have hl : Lines (Yaml.encode (.obj front)) := Or.inr (by
    have := yaml_ends (.obj front)
    unfold endBol at this
    split at this
    · cases this
    · rename_i c hc; simp at this; rw [hc, this])
  have hns : noStop dashes (Yaml.encode (.obj front)) = true :=
    noStop_of_heads _ _ (yaml_heads_dash front hw)
  unfold lexDoc frontMd
  simp only [dashes, List.append_assoc, List.cons_append]
  have hu := untilStop_body dashes (by decide) (by decide) (Yaml.encode (.obj front)) [] (render segs)
    hl hns (by simp)
  have e : ("---".toList : List Char) = ['-', '-', '-'] := rfl
  simp only [dashes, List.append_assoc, List.nil_append, e, List.cons_append] at hu ⊢
  rw [hu _ (by simp; omega)]
  simp only [List.all_nil, ↓reduceIte, Yaml.decode_encode _ hw]
  rw [lex_render segs true hv _ (by simp; omega)]
  rfl

theorem prMd_noDollar (S : Sym) (e : Eqn) (hc : capsMd.eqn S e = true) :
    '$' ∉ (prMd S e).toList ++ ['\n'] := by
  simp only [capsMd, Bool.and_eq_true, Bool.not_eq_true'] at hc
  obtain ⟨⟨⟨hcm, hd⟩, _⟩, _⟩ := hc
  unfold prMd
  rw [String.toList_ofList]
  intro hm
  simp only [List.mem_append, List.mem_singleton] at hm
  rcases hm with (hm | hm) | hm
  · cases hcom : e.comment with
    | none => rw [hcom] at hm; cases hm
    | some c =>
      rw [hcom] at hm hcm
      simp only [commentOK, Bool.and_eq_true, Bool.not_eq_true'] at hcm
      simp only [List.cons_append, List.mem_cons, List.mem_append] at hm
      rcases hm with h | h | h | h | h
      · cases h
      · cases h
      · exact contains_false hcm.2 h
      · cases h
      · cases h
  · exact contains_false hd hm
  · cases hm

/-- Every construct of the printed skeleton satisfies `itemOK`. -/
theorem items_ok (D : Doc Eqn) (h : DocOK capsMd D) :
    ∀ it ∈ items (rawDoc prMd D), itemOK it = true := by
  intro it hit
  simp only [items, rawDoc, List.mem_append, List.mem_map, List.mem_flatMap, Option.mem_toList,
    Option.map_eq_some_iff] at hit
  rcases hit with ((⟨s, hs, rfl⟩) | ⟨kv, hkv, rfl⟩) | ⟨c', ⟨c, hc, rfl⟩, hit⟩
  · have := h.desc s hs
    simp only [capsMd, Bool.and_eq_true] at this
    exact this.1.1.1.1
  · exact h.blocks kv hkv
  · simp only [compItems, Comp.mapEqns, List.mem_cons, List.mem_append, List.mem_map,
      Option.mem_toList, Option.map_eq_some_iff] at hit
    rcases hit with rfl | (((((⟨s, hs, rfl⟩) | ⟨d, hd, rfl⟩) | ⟨r, ⟨e, he, rfl⟩, rfl⟩) |
      ⟨v, hv, rfl⟩) | ⟨kv, hkv, rfl⟩)
    · exact h.compName c hc
    · have := h.cdesc c hc s hs
      simp only [capsMd, Bool.and_eq_true] at this
      exact this.1.1.1.1
    · have hn := h.declName c hc d hd
      have ha := h.attrs c hc d hd
      simp only [itemOK, declOK, Bool.and_eq_true]
      simp only [capsMd, Bool.and_eq_true] at hn
      refine ⟨hn, List.all_eq_true.mpr fun a hma => ?_⟩
      have := ha a hma
      simp only [capsMd, Bool.and_eq_true] at this
      simp only [attrOK, Bool.and_eq_true]
      exact ⟨this.1, this.2⟩
    · exact noStop_of_heads _ _ (fun hm =>
        prMd_noDollar _ e (h.eqns c hc e he).1 (heads_sub hm))
    · exact h.eqBlock c hc v hv
    · exact (h.cblocks c hc kv hkv).2

/-- **The Markdown round trip.** Every ESM document in canonical form reads back from its
Markdown spelling. -/
theorem parseMd_printMd (d : Json) (hd : canonDoc d = true) : parseMd (printMd d) = some d := by
  have hok := toDoc_ok capsMd rfl d hd
  unfold parseMd printMd
  simp only [String.toList_ofList]
  rw [lexDoc_front _ hok.frontWF _ (valid_canon _ (items_ok _ hok) true), segItems_canon]
  simp only [Option.bind_eq_bind, Option.bind_some]
  have hR := unitems_items (rawDoc prMd (toDoc capsMd d)) (by
    intro c hc kv hkv
    simp only [rawDoc, List.mem_map] at hc
    obtain ⟨c0, hc0, rfl⟩ := hc
    exact (hok.cblocks c0 hc0 kv hkv).1)
  rw [show (rawDoc prMd (toDoc capsMd d)).front = (toDoc capsMd d).front from rfl] at hR
  rw [hR]
  simp only [Option.bind_some]
  rw [cookDoc_rawDoc prMd ckMd _ (fun c hc e he => by
    have := hok.eqns c hc e he
    exact ckMd_prMd _ e this.1 this.2.1 this.2.2)]
  simp only [Option.bind_some]
  exact ofDoc_toDoc capsMd d hd

/-! ## Prose and labels do not change the parse -/

/-- What a document says, given its front matter and its constructs. -/
def parseItemsMd (front : List (String × Json)) (its : List RItem) : Option Json := do
  let R ← unitems front its
  let D ← cookDoc ckMd R
  ofDoc D

/-- **The parse of a Markdown document depends only on its front matter and its sequence
of constructs**: not on the prose between them, and not on equation labels. -/
theorem parseMd_body (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (segs : List Seg) (hv : Valid true segs) :
    parseMd (String.ofList (frontMd front ++ render segs)) = parseItemsMd front (segItems segs) := by
  unfold parseMd parseItemsMd
  simp only [String.toList_ofList]
  rw [lexDoc_front front hf segs hv]
  rfl

/-- Two valid documents with the same constructs parse alike. -/
theorem parseMd_eq_of_items (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (s₁ s₂ : List Seg) (h₁ : Valid true s₁) (h₂ : Valid true s₂) (h : segItems s₁ = segItems s₂) :
    parseMd (String.ofList (frontMd front ++ render s₁)) =
      parseMd (String.ofList (frontMd front ++ render s₂)) := by
  rw [parseMd_body front hf s₁ h₁, parseMd_body front hf s₂ h₂, h]

/-- Inserting prose leaves the constructs as they were. -/
theorem segItems_prose (a b : List Seg) (p : List Char) :
    segItems (a ++ .prose p :: b) = segItems (a ++ b) := by
  simp [segItems_append, segItems]

/-- Labelling an equation leaves the constructs as they were. -/
theorem segItems_label (a b : List Seg) (raw : String) (l : List Char) :
    segItems (a ++ .labeled raw l :: b) = segItems (a ++ .item (.eqn raw) :: b) := by
  simp [segItems_append, segItems]

/-- **Inserting prose does not change the parse** (where the result is still valid: the
prose is `Inert` and block constructs still start a line). -/
theorem parseMd_insert_prose (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (a b : List Seg) (p : List Char) (h₁ : Valid true (a ++ b)) (h₂ : Valid true (a ++ .prose p :: b)) :
    parseMd (String.ofList (frontMd front ++ render (a ++ .prose p :: b))) =
      parseMd (String.ofList (frontMd front ++ render (a ++ b))) :=
  parseMd_eq_of_items front hf _ _ h₂ h₁ (segItems_prose a b p)

/-- **Adding an equation label does not change the parse.** -/
theorem parseMd_label (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (a b : List Seg) (raw : String) (l : List Char) (h₁ : Valid true (a ++ .item (.eqn raw) :: b))
    (h₂ : Valid true (a ++ .labeled raw l :: b)) :
    parseMd (String.ofList (frontMd front ++ render (a ++ .labeled raw l :: b))) =
      parseMd (String.ofList (frontMd front ++ render (a ++ .item (.eqn raw) :: b))) :=
  parseMd_eq_of_items front hf _ _ h₂ h₁ (segItems_label a b raw l)

end Esm.Document.Source.Md
