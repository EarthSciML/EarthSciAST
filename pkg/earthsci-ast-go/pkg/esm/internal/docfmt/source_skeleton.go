package docfmt

// The document skeleton: front matter, description, path blocks, and one
// section per model or reaction system, with the path-keyed fallback for every
// field without a native surface. Port of
// formal/Esm/Document/Source/Skeleton.lean (Rust: document/source/skeleton.rs);
// prefix `sk`.
//
// The mapping is total: every field a container cannot spell natively falls
// back to a block keyed by its JSON path relative to the enclosing section.
// Caps are the container's predicates saying which values it spells natively.

import "slices"

// ## The canonical form of a document

// skSortedDeep is `Source.sortedDeep`: every object, at every depth, has
// strictly increasing keys.
func skSortedDeep(j Json) bool {
	switch x := j.(type) {
	case Obj:
		if !exprKeysSorted(x) {
			return false
		}
		for _, kv := range x {
			if !skSortedDeep(kv.V) {
				return false
			}
		}
	case []Json:
		for _, e := range x {
			if !skSortedDeep(e) {
				return false
			}
		}
	}
	return true
}

// skCanonDoc is `Source.canonDoc`: a JSON object, well formed, with sorted
// keys at every depth.
func skCanonDoc(j Json) bool {
	_, ok := j.(Obj)
	return ok && exprJwf(j) && skSortedDeep(j)
}

// Kind is `Source.Kind`: a model or a reaction system.
type Kind uint8

// The component kinds.
const (
	KindModel Kind = iota
	KindRs
)

// DKind is `Source.DKind`: the declaration directives (DKSub: a subsystem
// included by reference).
type DKind uint8

// The declaration kinds.
const (
	DKVar DKind = iota
	DKParam
	DKSpecies
	DKSub
)

// Decl is `Source.Decl`: the directive, the declared name, and the other
// fields of the declared object as attributes.
type Decl struct {
	Kind  DKind
	Name  string
	Attrs Obj
}

// Eqn is `Source.Eqn`: `lhs = rhs`, with its optional `_comment`.
type Eqn struct {
	HasComment bool
	Comment    string
	Lhs, Rhs   Json
}

// Role is `Source.Role`: the field an equation belongs to.
type Role uint8

// The equation roles.
const (
	RoleEqn Role = iota
	RoleInit
	RoleCons
)

// field is `Role.field`.
func (r Role) field() string {
	switch r {
	case RoleInit:
		return "initialization_equations"
	case RoleCons:
		return "constraint_equations"
	}
	return "equations"
}

// Term is `Source.Term`: a species and its stoichiometric coefficient.
type Term struct {
	Species string
	Coef    JNum
}

// Rxn is `Source.Rxn`: a reaction's `id`, sides (nil Subs/Prods with
// HasSubs/HasProds false for an empty side), rate (R: the expression, or its
// math text) and other fields.
type Rxn[R any] struct {
	ID       string
	HasSubs  bool
	Subs     []Term
	HasProds bool
	Prods    []Term
	Rate     R
	Attrs    Obj
}

// Tm is `Source.Tm`: an entry of `operators`: a template (HasLhs
// false) or a rewrite rule (HasLhs true, Lhs the match).
type Tm[R any] struct {
	Name   string
	Params []string
	HasLhs bool
	Lhs    R
	Body   R
	Attrs  Obj
}

// MxKind says which variant an Mx is.
type MxKind uint8

// The variants of Mx.
const (
	MxEq MxKind = iota
	MxRxn
	MxPlot
	MxTm
)

// Mx is `Source.Mx`: a list entry of a component.
type Mx[A, R any] struct {
	K    MxKind
	Role Role   // MxEq
	Eq   A      // MxEq
	Rxn  Rxn[R] // MxRxn
	Plot Obj    // MxPlot
	Tm   Tm[R]  // MxTm
}

// MC is `Source.MC`: a math entry as read.
type MC = Mx[Eqn, Json]

// MR is `Source.MR`: a math entry as the container's text.
type MR = Mx[string, string]

// field is `Mx.field`.
func (m *Mx[A, R]) field() string {
	switch m.K {
	case MxRxn:
		return "reactions"
	case MxPlot:
		return "analyses"
	case MxTm:
		return "operators"
	}
	return m.Role.field()
}

// key is `Mx.key`.
func (m *Mx[A, R]) key() string {
	if m.K == MxTm {
		return m.Tm.Name
	}
	return ""
}

// head is `Mx.head`: the symbol-table entry of a template or rule.
func (m *Mx[A, R]) head() (TemplateParams, bool) {
	if m.K == MxTm {
		return TemplateParams{m.Tm.Name, m.Tm.ps()}, true
	}
	return TemplateParams{}, false
}

// skMathFields is `Source.mathFields`.
var skMathFields = []string{
	"analyses", "constraint_equations", "equations",
	"initialization_equations", "operators", "reactions",
}

// skIsMathField is `k ∈ mathFields`.
func skIsMathField(k string) bool { return slices.Contains(skMathFields, k) }

// Comp is `Source.Comp`: one component section.
type Comp[A any] struct {
	Kind       Kind
	Name       string
	HasDesc    bool
	Desc       string
	Decls      []Decl
	Math       []A
	MathBlocks Obj
	Blocks     Obj
}

// Doc is `Source.Doc`: a document skeleton.
type Doc[A any] struct {
	Front   Obj
	HasDesc bool
	Desc    string
	Blocks  Obj
	Math    []A
	Comps   []Comp[A]
}

// skMapMath is `Comp.mapMath`.
func skMapMath[A, B any](c *Comp[A], f func(*Comp[A], *A) B) Comp[B] {
	math := make([]B, len(c.Math))
	for i := range c.Math {
		math[i] = f(c, &c.Math[i])
	}
	return Comp[B]{
		Kind: c.Kind, Name: c.Name, HasDesc: c.HasDesc, Desc: c.Desc, Decls: c.Decls,
		Math: math, MathBlocks: c.MathBlocks, Blocks: c.Blocks,
	}
}

// ## The symbol table of a component

// skKeysOf is `Source.keysOf`.
func skKeysOf(v Json) []string {
	kvs, ok := v.(Obj)
	if !ok {
		return nil
	}
	out := make([]string, len(kvs))
	for i, kv := range kvs {
		out[i] = kv.K
	}
	return out
}

// lookV is the value of key k, nil when absent (for the callers that only
// test its shape).
func lookV(k string, kvs Obj) Json {
	v, _ := exprLook(k, kvs)
	return v
}

// skStrsOf is `Source.strsOf`.
func skStrsOf(v Json) []string {
	xs, ok := v.([]Json)
	if !ok {
		return nil
	}
	var out []string
	for _, x := range xs {
		if s, ok := x.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// skTemplatesOf is `Source.templatesOf`.
func skTemplatesOf(v Json) []TemplateParams {
	kvs, ok := v.(Obj)
	if !ok {
		return nil
	}
	var out []TemplateParams
	for _, kv := range kvs {
		if t, ok := kv.V.(Obj); ok {
			out = append(out, TemplateParams{kv.K, skStrsOf(lookV("params", t))})
		}
	}
	return out
}

// ps is `Tm.ps`: a template's header parameters; a rule's `params` attribute.
func (t *Tm[R]) ps() []string {
	if !t.HasLhs {
		return t.Params
	}
	return skStrsOf(lookV("params", t.Attrs))
}

// scope is `Tm.scope`: the table around it, with the parameters declared.
func (t *Tm[R]) scope(s *Sym) *Sym {
	ps := t.ps()
	names := make([]string, 0, len(s.Names)+len(ps))
	names = append(names, s.Names...)
	names = append(names, ps...)
	return &Sym{Names: names, Templates: s.Templates}
}

// mscope is `Tm.mscope`: the symbol table a rule's `match` pattern is read
// under: its body's, with no templates. A pattern never applies a template
// (spec §9.7.3), so an operator in it named like a template in scope (a rule
// is in scope under its own name) reads as that operator, in the call form.
func (t *Tm[R]) mscope(s *Sym) *Sym {
	return &Sym{Names: t.scope(s).Names}
}

// skRootTs is `Source.rootTs`.
func skRootTs[A, R any](root Obj, rm []Mx[A, R]) []TemplateParams {
	out := skTemplatesOf(lookV("operators", root))
	for i := range rm {
		if h, ok := rm[i].head(); ok {
			out = append(out, h)
		}
	}
	return out
}

// skCompTs is `Source.compTs`.
func skCompTs[A, R any](c *Comp[Mx[A, R]]) []TemplateParams {
	out := skTemplatesOf(lookV("operators", c.MathBlocks))
	for i := range c.Math {
		if h, ok := c.Math[i].head(); ok {
			out = append(out, h)
		}
	}
	return out
}

// skSymWith is `Source.symWith`.
func skSymWith[A any](root Obj, rt []TemplateParams, c *Comp[A], ct []TemplateParams) *Sym {
	var names []string
	for _, d := range c.Decls {
		if d.Kind != DKSub {
			names = append(names, d.Name)
		}
	}
	names = append(names, skKeysOf(lookV("variables", c.Blocks))...)
	names = append(names, skKeysOf(lookV("species", c.Blocks))...)
	names = append(names, skKeysOf(lookV("parameters", c.Blocks))...)
	names = append(names, skKeysOf(lookV("index_sets", root))...)
	templates := make([]TemplateParams, 0, len(rt)+len(ct))
	templates = append(templates, rt...)
	templates = append(templates, ct...)
	return &Sym{Names: names, Templates: templates}
}

// skSymFor is `Source.symFor`: the symbol table of a component.
func skSymFor[A, R any](d *Doc[Mx[A, R]], c *Comp[Mx[A, R]]) *Sym {
	return skSymWith(d.Blocks, skRootTs(d.Blocks, d.Math), c, skCompTs(c))
}

// skTopSym is `Source.topSym`: the symbol table of the top-level templates.
func skTopSym[A, R any](d *Doc[Mx[A, R]]) *Sym {
	return &Sym{Names: skKeysOf(lookV("index_sets", d.Blocks)), Templates: skRootTs(d.Blocks, d.Math)}
}

// Caps is `Source.Caps`: what a container spells natively.
type Caps interface {
	// frontKey: a front-matter key.
	frontKey(k string) bool
	// desc: a description text.
	desc(s string) bool
	// compName: a component name in its directive.
	compName(n string) bool
	// declName: a declared name (printed as math).
	declName(n string) bool
	// attr: a declaration attribute.
	attr(a KV) bool
	// eqn: an equation under the component's symbol table.
	eqn(lim *Lim, s *Sym, e *Eqn) bool
	// rxn: a reaction under the component's symbol table.
	rxn(s *Sym, x *Rxn[Json]) bool
	// plot: the fields of a plot directive.
	plot(a Obj) bool
	// tm: a template or rule, under its body's symbol table.
	tm(lim *Lim, s *Sym, t *Tm[Json]) bool
}

// skCapsItem is `Caps.item`: a list entry the container spells.
func skCapsItem(lim *Lim, caps Caps, s *Sym, m *MC) bool {
	switch m.K {
	case MxRxn:
		return caps.rxn(s, &m.Rxn)
	case MxPlot:
		return caps.plot(m.Plot)
	case MxTm:
		return caps.tm(lim, m.Tm.scope(s), &m.Tm)
	}
	return caps.eqn(lim, s, &m.Eq)
}

// ## Equations and the other math entries

// skEqnJson is `Source.eqnJson`.
func skEqnJson(e *Eqn) Json {
	if e.HasComment {
		return Obj{{"_comment", e.Comment}, {"lhs", e.Lhs}, {"rhs", e.Rhs}}
	}
	return Obj{{"lhs", e.Lhs}, {"rhs", e.Rhs}}
}

// skEqnOf is `Source.eqnOf`: exactly the keys `lhs`, `rhs` and optionally a
// string `_comment`, both sides well-formed expressions.
func skEqnOf(v Json) (Eqn, bool) {
	kvs, ok := v.(Obj)
	if !ok {
		return Eqn{}, false
	}
	switch len(kvs) {
	case 3:
		cm, isStr := kvs[0].V.(string)
		if isStr && kvs[0].K == "_comment" && kvs[1].K == "lhs" && kvs[2].K == "rhs" &&
			exprIsE(kvs[1].V) && exprIsE(kvs[2].V) {
			return Eqn{HasComment: true, Comment: cm, Lhs: kvs[1].V, Rhs: kvs[2].V}, true
		}
	case 2:
		if kvs[0].K == "lhs" && kvs[1].K == "rhs" && exprIsE(kvs[0].V) && exprIsE(kvs[1].V) {
			return Eqn{Lhs: kvs[0].V, Rhs: kvs[1].V}, true
		}
	}
	return Eqn{}, false
}

// skTermJson is `Source.termJson`.
func skTermJson(t Term) Json {
	return Obj{{"species", t.Species}, {"stoichiometry", t.Coef}}
}

// skTermOf is `Source.termOf`.
func skTermOf(v Json) (Term, bool) {
	kvs, ok := v.(Obj)
	if !ok || len(kvs) != 2 || kvs[0].K != "species" || kvs[1].K != "stoichiometry" {
		return Term{}, false
	}
	s, ok1 := kvs[0].V.(string)
	n, ok2 := kvs[1].V.(JNum)
	if !ok1 || !ok2 {
		return Term{}, false
	}
	return Term{s, n}, true
}

// skSideJson is `Source.sideJson`.
func skSideJson(has bool, ts []Term) Json {
	if !has {
		return nil
	}
	out := make([]Json, len(ts))
	for i, t := range ts {
		out[i] = skTermJson(t)
	}
	return out
}

// skSideOf is `Source.sideOf`: `null`, or a non-empty array of terms. has is
// false for null.
func skSideOf(v Json) (ts []Term, has, ok bool) {
	switch x := v.(type) {
	case nil:
		return nil, false, true
	case []Json:
		if len(x) == 0 {
			return nil, false, false
		}
		ts = make([]Term, len(x))
		for i, e := range x {
			t, ok := skTermOf(e)
			if !ok {
				return nil, false, false
			}
			ts[i] = t
		}
		return ts, true, true
	}
	return nil, false, false
}

// skRxnKeys is `Source.rxnKeys`.
var skRxnKeys = []string{"id", "products", "rate", "substrates"}

// skRxnJson is `Source.rxnJson`.
func skRxnJson(x *Rxn[Json]) Json {
	kvs := Obj{
		{"id", x.ID},
		{"products", skSideJson(x.HasProds, x.Prods)},
		{"rate", x.Rate},
		{"substrates", skSideJson(x.HasSubs, x.Subs)},
	}
	kvs = append(kvs, x.Attrs...)
	return keysSortKeys(kvs)
}

// skRxnOf is `Source.rxnOf`: checked by printing it back.
func skRxnOf(v Json) (Rxn[Json], bool) {
	kvs, ok := v.(Obj)
	if !ok {
		return Rxn[Json]{}, false
	}
	idv, okI := exprLook("id", kvs)
	id, isStr := idv.(string)
	sv, okS := exprLook("substrates", kvs)
	pv, okP := exprLook("products", kvs)
	r, okR := exprLook("rate", kvs)
	if !okI || !isStr || !okS || !okP || !okR {
		return Rxn[Json]{}, false
	}
	s, hs, ok1 := skSideOf(sv)
	p, hp, ok2 := skSideOf(pv)
	if !ok1 || !ok2 {
		return Rxn[Json]{}, false
	}
	var attrs Obj
	for _, kv := range kvs {
		if !slices.Contains(skRxnKeys, kv.K) {
			attrs = append(attrs, kv)
		}
	}
	x := Rxn[Json]{ID: id, HasSubs: hs, Subs: s, HasProds: hp, Prods: p, Rate: r, Attrs: attrs}
	if JsonEqual(skRxnJson(&x), v) && exprIsE(r) {
		return x, true
	}
	return Rxn[Json]{}, false
}

// skPlotJson is `Source.plotJson`.
func skPlotJson(attrs Obj) Json {
	out := make(Obj, len(attrs))
	for i, kv := range attrs {
		if kv.K == "plot" {
			out[i] = KV{"plots", []Json{kv.V}}
		} else {
			out[i] = kv
		}
	}
	return keysSortKeys(out)
}

// skPlotOf is `Source.plotOf`: an analysis with exactly one plot and no `plot`
// field, checked by printing it back.
func skPlotOf(v Json) (Obj, bool) {
	kvs, ok := v.(Obj)
	if !ok {
		return nil, false
	}
	psv, okPs := exprLook("plots", kvs)
	_, okP := exprLook("plot", kvs)
	ps, isArr := psv.([]Json)
	if !okPs || okP || !isArr || len(ps) != 1 {
		return nil, false
	}
	a := make(Obj, len(kvs))
	for i, kv := range kvs {
		if kv.K == "plots" {
			a[i] = KV{"plot", ps[0]}
		} else {
			a[i] = kv
		}
	}
	if JsonEqual(skPlotJson(a), v) {
		return a, true
	}
	return nil, false
}

// skTmJson is `Source.tmJson`.
func skTmJson(t *Tm[Json]) Json {
	var kvs Obj
	if !t.HasLhs {
		ps := make([]Json, len(t.Params))
		for i, p := range t.Params {
			ps[i] = p
		}
		kvs = Obj{{"body", t.Body}, {"params", ps}}
	} else {
		kvs = Obj{{"body", t.Body}, {"match", t.Lhs}}
	}
	kvs = append(kvs, t.Attrs...)
	return keysSortKeys(kvs)
}

// skStrList is `Source.strList`: the string entries of a list, when every
// entry is a string.
func skStrList(xs []Json) ([]string, bool) {
	out := make([]string, len(xs))
	for i, x := range xs {
		s, ok := x.(string)
		if !ok {
			return nil, false
		}
		out[i] = s
	}
	return out, true
}

// skTmOf is `Source.tmOf`: the template or rule an entry of
// `operators` is, checked by printing it back.
func skTmOf(n string, v Json) (Tm[Json], bool) {
	kvs, ok := v.(Obj)
	if !ok {
		return Tm[Json]{}, false
	}
	b, okB := exprLook("body", kvs)
	m, okM := exprLook("match", kvs)
	psv, okPs := exprLook("params", kvs)
	if !okB {
		return Tm[Json]{}, false
	}
	if !okM {
		ps, isArr := psv.([]Json)
		if !okPs || !isArr {
			return Tm[Json]{}, false
		}
		ps2, ok := skStrList(ps)
		if !ok {
			return Tm[Json]{}, false
		}
		var attrs Obj
		for _, kv := range kvs {
			if kv.K != "body" && kv.K != "params" {
				attrs = append(attrs, kv)
			}
		}
		t := Tm[Json]{Name: n, Params: ps2, Body: b, Attrs: attrs}
		if JsonEqual(skTmJson(&t), v) && exprIsE(b) {
			return t, true
		}
		return Tm[Json]{}, false
	}
	var attrs Obj
	for _, kv := range kvs {
		if kv.K != "body" && kv.K != "match" {
			attrs = append(attrs, kv)
		}
	}
	t := Tm[Json]{Name: n, HasLhs: true, Lhs: m, Body: b, Attrs: attrs}
	if JsonEqual(skTmJson(&t), v) && exprIsE(b) && exprIsE(m) {
		return t, true
	}
	return Tm[Json]{}, false
}

// skItemJson is `Source.itemJson`.
func skItemJson(m *MC) Json {
	switch m.K {
	case MxRxn:
		return skRxnJson(&m.Rxn)
	case MxPlot:
		return skPlotJson(m.Plot)
	case MxTm:
		return skTmJson(&m.Tm)
	}
	return skEqnJson(&m.Eq)
}

// skFieldJson is `Source.fieldJson`: an object keyed by the entries' names for
// `operators`, a list otherwise.
func skFieldJson(f string, ms []*MC) Json {
	if f == "operators" {
		out := make(Obj, len(ms))
		for i, m := range ms {
			out[i] = KV{m.key(), skItemJson(m)}
		}
		return out
	}
	out := make([]Json, len(ms))
	for i, m := range ms {
		out[i] = skItemJson(m)
	}
	return out
}

// skRoleOf is `Source.roleOf`.
func skRoleOf(f string) (Role, bool) {
	for _, r := range []Role{RoleEqn, RoleInit, RoleCons} {
		if r.field() == f {
			return r, true
		}
	}
	return 0, false
}

// skItemOf is `Source.itemOf`.
func skItemOf(f string, v Json) (MC, bool) {
	switch f {
	case "reactions":
		x, ok := skRxnOf(v)
		return MC{K: MxRxn, Rxn: x}, ok
	case "analyses":
		a, ok := skPlotOf(v)
		return MC{K: MxPlot, Plot: a}, ok
	}
	r, ok := skRoleOf(f)
	if !ok {
		return MC{}, false
	}
	e, ok := skEqnOf(v)
	return MC{K: MxEq, Role: r, Eq: e}, ok
}

// skTmItem is `Source.tmItem`.
func skTmItem(kv KV) (MC, bool) {
	t, ok := skTmOf(kv.K, kv.V)
	return MC{K: MxTm, Tm: t}, ok
}

// skMathOf is `Source.mathOf`: the entries of a math field, when all of them
// print natively.
func skMathOf(lim *Lim, caps Caps, s *Sym, f string, v Json) ([]MC, bool) {
	var ms []MC
	switch x := v.(type) {
	case []Json:
		if len(x) == 0 || f == "operators" {
			return nil, false
		}
		ms = make([]MC, len(x))
		for i, e := range x {
			m, ok := skItemOf(f, e)
			if !ok {
				return nil, false
			}
			ms[i] = m
		}
	case Obj:
		if len(x) == 0 || f != "operators" {
			return nil, false
		}
		ms = make([]MC, len(x))
		for i, kv := range x {
			m, ok := skTmItem(kv)
			if !ok {
				return nil, false
			}
			ms[i] = m
		}
	default:
		return nil, false
	}
	for i := range ms {
		if !skCapsItem(lim, caps, s, &ms[i]) {
			return nil, false
		}
	}
	return ms, true
}

// skDescOf is `Source.descOf`.
func skDescOf(caps Caps, v Json, present bool) (string, bool) {
	s, ok := v.(string)
	if present && ok && caps.desc(s) {
		return s, true
	}
	return "", false
}

// skMetaOf is `Source.metaOf`: `metadata` printed in the front matter: the
// front-matter entries and the description.
func skMetaOf(caps Caps, v Json, present bool) (es Obj, hasD bool, d string, ok bool) {
	kvs, isObj := v.(Obj)
	if !present || !isObj || len(kvs) == 0 {
		return nil, false, "", false
	}
	if _, has := exprLook("esm", kvs); has {
		return nil, false, "", false
	}
	for _, kv := range kvs {
		if !caps.frontKey(kv.K) {
			return nil, false, "", false
		}
	}
	dv, dp := exprLook("description", kvs)
	d, hasD = skDescOf(caps, dv, dp)
	for _, kv := range kvs {
		if kv.K != "description" || !hasD {
			es = append(es, kv)
		}
	}
	return es, hasD, d, true
}

// skPickVar is `Source.pickVar`: a model variable as a declaration.
func skPickVar(caps Caps, n string, v Json) (Decl, bool) {
	if !caps.declName(n) {
		return Decl{}, false
	}
	kvs, ok := v.(Obj)
	if !ok {
		return Decl{}, false
	}
	withoutType := func() Obj {
		var out Obj
		for _, kv := range kvs {
			if kv.K != "type" {
				out = append(out, kv)
			}
		}
		return out
	}
	mk := func(kind DKind, attrs Obj) (Decl, bool) {
		for _, a := range attrs {
			if !caps.attr(a) {
				return Decl{}, false
			}
		}
		return Decl{kind, n, attrs}, true
	}
	t, present := exprLook("type", kvs)
	if !present {
		return Decl{}, false
	}
	switch t {
	case "parameter":
		return mk(DKParam, withoutType())
	case "unknown":
		return mk(DKVar, withoutType())
	}
	return mk(DKVar, kvs)
}

// skPickPlain is `Source.pickPlain`: a reaction-system species or parameter as
// a declaration of kind k.
func skPickPlain(caps Caps, k DKind, n string, v Json) (Decl, bool) {
	if !caps.declName(n) {
		return Decl{}, false
	}
	kvs, ok := v.(Obj)
	if !ok {
		return Decl{}, false
	}
	for _, a := range kvs {
		if !caps.attr(a) {
			return Decl{}, false
		}
	}
	return Decl{k, n, kvs}, true
}

// skPickSub is `Source.pickSub`: a subsystem included by reference.
func skPickSub(caps Caps, n string, v Json) (Decl, bool) {
	kvs, ok := v.(Obj)
	if !ok {
		return Decl{}, false
	}
	if _, has := exprLook("ref", kvs); !has {
		return Decl{}, false
	}
	return skPickPlain(caps, DKSub, n, v)
}

// skPicker is one of the pickers of `Source.declFields`.
type skPicker struct {
	kind  uint8 // 0 Var, 1 Plain, 2 Sub
	plain DKind
}

// pick applies the picker.
func (p skPicker) pick(caps Caps, n string, v Json) (Decl, bool) {
	switch p.kind {
	case 0:
		return skPickVar(caps, n, v)
	case 1:
		return skPickPlain(caps, p.plain, n, v)
	}
	return skPickSub(caps, n, v)
}

// skDeclFieldEntry is one declaration field and its picker.
type skDeclFieldEntry struct {
	field string
	p     skPicker
}

var (
	skModelDeclFields = []skDeclFieldEntry{{"variables", skPicker{kind: 0}}, {"subsystems", skPicker{kind: 2}}}
	skRsDeclFields    = []skDeclFieldEntry{
		{"species", skPicker{kind: 1, plain: DKSpecies}},
		{"parameters", skPicker{kind: 1, plain: DKParam}},
		{"subsystems", skPicker{kind: 2}},
	}
)

// skDeclFields is `Source.declFields`: the declaration fields of a component
// kind, with their pickers.
func skDeclFields(k Kind) []skDeclFieldEntry {
	if k == KindModel {
		return skModelDeclFields
	}
	return skRsDeclFields
}

// skDeclField is `Source.declField`.
func skDeclField(k Kind, d DKind) (string, bool) {
	switch {
	case d == DKSub:
		return "subsystems", true
	case k == KindModel && (d == DKVar || d == DKParam):
		return "variables", true
	case k == KindRs && d == DKSpecies:
		return "species", true
	case k == KindRs && d == DKParam:
		return "parameters", true
	}
	return "", false
}

// skBackDecl is `Source.backDecl`: the entry a declaration stands for.
func skBackDecl(k Kind, d *Decl) (KV, bool) {
	hasType := false
	for _, kv := range d.Attrs {
		if kv.K == "type" {
			hasType = true
		}
	}
	with := func(t string) Json {
		a := Obj{{"type", t}}
		a = append(a, d.Attrs...)
		return keysSortKeys(a)
	}
	sorted := func() Json { return keysSortKeys(append(Obj(nil), d.Attrs...)) }
	switch {
	case k == KindModel && d.Kind == DKParam:
		if hasType {
			return KV{}, false
		}
		return KV{d.Name, with("parameter")}, true
	case k == KindModel && d.Kind == DKVar:
		if hasType {
			return KV{d.Name, sorted()}, true
		}
		return KV{d.Name, with("unknown")}, true
	case (k == KindRs && (d.Kind == DKSpecies || d.Kind == DKParam)) || d.Kind == DKSub:
		return KV{d.Name, sorted()}, true
	}
	return KV{}, false
}

// skCompBlock is `Source.compBlock`: where an entry of a component goes when
// it is not a native surface.
func skCompBlock(caps Caps, k Kind, hasDesc bool, kv KV) (KV, bool) {
	if kv.K == "description" {
		if hasDesc {
			return KV{}, false
		}
		return kv, true
	}
	if skIsMathField(kv.K) {
		return KV{}, false
	}
	for _, f := range skDeclFields(k) {
		if f.field == kv.K {
			p := f.p
			_, r, hasR := keysSplitField(func(n string, v Json) (Decl, bool) { return p.pick(caps, n, v) }, kv.V)
			if !hasR {
				return KV{}, false
			}
			return KV{kv.K, r}, true
		}
	}
	return kv, true
}

// skCompBase is `Source.compBase`: a component before its equations are
// decided.
func skCompBase(caps Caps, k Kind, name string, kvs Obj) Comp[MC] {
	dv, dp := exprLook("description", kvs)
	desc, hasDesc := skDescOf(caps, dv, dp)
	var decls []Decl
	for _, f := range skDeclFields(k) {
		p := f.p
		v, present := exprLook(f.field, kvs)
		ds, _, _ := keysSplitOpt(func(n string, v Json) (Decl, bool) { return p.pick(caps, n, v) }, v, present)
		decls = append(decls, ds...)
	}
	var blocks Obj
	for _, kv := range kvs {
		if b, ok := skCompBlock(caps, k, hasDesc, kv); ok {
			blocks = append(blocks, b)
		}
	}
	return Comp[MC]{Kind: k, Name: name, HasDesc: hasDesc, Desc: desc, Decls: decls, Blocks: blocks}
}

// skMathPart is `Source.mathPart`: one math field of a component: its entries
// when every one prints natively under s, else its block.
func skMathPart(lim *Lim, caps Caps, s *Sym, kvs Obj, f string) ([]MC, KV, bool) {
	v, present := exprLook(f, kvs)
	if !present {
		return nil, KV{}, false
	}
	if ms, ok := skMathOf(lim, caps, s, f, v); ok {
		return ms, KV{}, false
	}
	return nil, KV{f, v}, true
}

// skCompOf is `Source.compOf`: a component, with its math fields decided.
func skCompOf(lim *Lim, caps Caps, root Obj, rt []TemplateParams, k Kind, name string, kvs Obj) Comp[MC] {
	c := skCompBase(caps, k, name, kvs)
	s := skSymWith(root, rt, &c, skTemplatesOf(lookV("operators", kvs)))
	for _, f := range skMathFields {
		ms, b, hasB := skMathPart(lim, caps, s, kvs, f)
		c.Math = append(c.Math, ms...)
		if hasB {
			c.MathBlocks = append(c.MathBlocks, b)
		}
	}
	return c
}

// skNamedObj is a component name and its fields.
type skNamedObj struct {
	name string
	kvs  Obj
}

// skPickComp is `Source.pickComp`.
func skPickComp(caps Caps, n string, v Json) (skNamedObj, bool) {
	kvs, ok := v.(Obj)
	if !ok || !caps.compName(n) {
		return skNamedObj{}, false
	}
	return skNamedObj{n, kvs}, true
}

// skTopSymOf is `Source.topSymOf`.
func skTopSymOf(kvs Obj) *Sym {
	return &Sym{
		Names:     skKeysOf(lookV("index_sets", kvs)),
		Templates: skTemplatesOf(lookV("operators", kvs)),
	}
}

// skTopMath is `Source.topMath`: the top-level templates, when every one
// prints natively.
func skTopMath(lim *Lim, caps Caps, kvs Obj) ([]MC, bool) {
	v, present := exprLook("operators", kvs)
	if !present {
		return nil, false
	}
	return skMathOf(lim, caps, skTopSymOf(kvs), "operators", v)
}

// skRootBlock is `Source.rootBlock`.
func skRootBlock(caps Caps, tn bool, kv KV) (KV, bool) {
	switch k := kv.K; {
	case k == "esm":
		return KV{}, false
	case k == "metadata":
		if _, _, _, ok := skMetaOf(caps, kv.V, true); ok {
			return KV{}, false
		}
		return kv, true
	case k == "models" || k == "reaction_systems":
		_, r, hasR := keysSplitField(func(n string, v Json) (skNamedObj, bool) { return skPickComp(caps, n, v) }, kv.V)
		if !hasR {
			return KV{}, false
		}
		return KV{kv.K, r}, true
	case k == "operators" && tn:
		return KV{}, false
	}
	return kv, true
}

// skRootBlocks is `Source.rootBlocks`.
func skRootBlocks(caps Caps, tn bool, kvs Obj) Obj {
	var out Obj
	for _, kv := range kvs {
		if b, ok := skRootBlock(caps, tn, kv); ok {
			out = append(out, b)
		}
	}
	return out
}

// skToDoc is `Source.toDoc`: the skeleton of a document.
func skToDoc(lim *Lim, caps Caps, d Json) Doc[MC] {
	kvs, ok := d.(Obj)
	if !ok {
		return Doc[MC]{}
	}
	mv, mp := exprLook("metadata", kvs)
	es, hasD, desc, hasM := skMetaOf(caps, mv, mp)
	tm, hasTm := skTopMath(lim, caps, kvs)
	blocks := skRootBlocks(caps, hasTm, kvs)
	rt := skTemplatesOf(lookV("operators", kvs))
	comps := func(k Kind, f string) []Comp[MC] {
		v, present := exprLook(f, kvs)
		ns, _, _ := keysSplitOpt(func(n string, v Json) (skNamedObj, bool) { return skPickComp(caps, n, v) }, v, present)
		out := make([]Comp[MC], len(ns))
		for i, n := range ns {
			out[i] = skCompOf(lim, caps, blocks, rt, k, n.name, n.kvs)
		}
		return out
	}
	cs := comps(KindModel, "models")
	cs = append(cs, comps(KindRs, "reaction_systems")...)
	front := keysAt("esm", kvs)
	if hasM {
		front = append(front, es...)
	} else {
		hasD = false
	}
	if !hasTm {
		tm = nil
	}
	return Doc[MC]{Front: front, HasDesc: hasD, Desc: desc, Blocks: blocks, Math: tm, Comps: cs}
}

// ## From a skeleton back to the document

// skOptKv is `Source.optKv`.
func skOptKv(k string, v Json, present bool) Obj {
	if present {
		return Obj{{k, v}}
	}
	return nil
}

// skMathKv is `Source.mathKv`: one rebuilt math field.
func skMathKv(c *Comp[MC], f string) (Obj, bool) {
	var ms []*MC
	for i := range c.Math {
		if c.Math[i].field() == f {
			ms = append(ms, &c.Math[i])
		}
	}
	bs := keysAt(f, c.MathBlocks)
	switch {
	case len(ms) == 0 && len(bs) == 0:
		return nil, true
	case len(ms) == 0 && len(bs) == 1:
		return Obj{{f, bs[0].V}}, true
	case len(ms) > 0 && len(bs) == 0:
		return Obj{{f, skFieldJson(f, ms)}}, true
	}
	return nil, false
}

// skMathKvs is `Source.mathKvs`.
func skMathKvs(c *Comp[MC]) (Obj, bool) {
	var out Obj
	for _, f := range skMathFields {
		kv, ok := skMathKv(c, f)
		if !ok {
			return nil, false
		}
		out = append(out, kv...)
	}
	return out, true
}

// skDeclFieldNames is `Source.declFieldNames`.
func skDeclFieldNames(k Kind) []string {
	if k == KindModel {
		return []string{"variables", "subsystems"}
	}
	return []string{"species", "parameters", "subsystems"}
}

// skDeclKv is `Source.declKv`.
func skDeclKv(k Kind, c *Comp[MC], f string) (Obj, bool) {
	r, hasR, ok := keysPickOne(f, c.Blocks)
	if !ok {
		return nil, false
	}
	var ds []*Decl
	for i := range c.Decls {
		if df, ok := skDeclField(k, c.Decls[i].Kind); ok && df == f {
			ds = append(ds, &c.Decls[i])
		}
	}
	v, present, ok := keysJoinField(func(d *Decl) (KV, bool) { return skBackDecl(k, d) }, ds, r, hasR)
	if !ok {
		return nil, false
	}
	return skOptKv(f, v, present), true
}

// skDeclKvs is `Source.declKvs`: a declaration of a kind the component does
// not have is refused.
func skDeclKvs(k Kind, c *Comp[MC]) (Obj, bool) {
	for _, d := range c.Decls {
		if _, ok := skDeclField(k, d.Kind); !ok {
			return nil, false
		}
	}
	var out Obj
	for _, f := range skDeclFieldNames(k) {
		kv, ok := skDeclKv(k, c, f)
		if !ok {
			return nil, false
		}
		out = append(out, kv...)
	}
	return out, true
}

// skOfComp is `Source.ofComp`: a component rebuilt from its section.
func skOfComp(c *Comp[MC]) (Json, bool) {
	ds, ok := skDeclKvs(c.Kind, c)
	if !ok {
		return nil, false
	}
	es, ok := skMathKvs(c)
	if !ok {
		return nil, false
	}
	names := skDeclFieldNames(c.Kind)
	kvs := skOptKv("description", c.Desc, c.HasDesc)
	kvs = append(kvs, ds...)
	kvs = append(kvs, es...)
	for _, kv := range c.Blocks {
		if !slices.Contains(names, kv.K) {
			kvs = append(kvs, kv)
		}
	}
	return keysSortKeys(kvs), true
}

// skBackComp is `Source.backComp`.
func skBackComp(c *Comp[MC]) (KV, bool) {
	v, ok := skOfComp(c)
	if !ok {
		return KV{}, false
	}
	return KV{c.Name, v}, true
}

// skOfDoc is `Source.ofDoc`: a document rebuilt from its skeleton, checked to
// be canonical.
func skOfDoc(d *Doc[MC]) (Json, bool) {
	esmKv := keysAt("esm", d.Front)
	var metaEs Obj
	for _, kv := range d.Front {
		if kv.K != "esm" {
			metaEs = append(metaEs, kv)
		}
	}
	metaEs = append(metaEs, skOptKv("description", d.Desc, d.HasDesc)...)
	var metaKv Obj
	if len(metaEs) > 0 {
		metaKv = Obj{{"metadata", keysSortKeys(metaEs)}}
	}
	mr, hasMr, ok := keysPickOne("models", d.Blocks)
	if !ok {
		return nil, false
	}
	var ms, rs []*Comp[MC]
	for i := range d.Comps {
		if d.Comps[i].Kind == KindModel {
			ms = append(ms, &d.Comps[i])
		} else {
			rs = append(rs, &d.Comps[i])
		}
	}
	models, hasModels, ok := keysJoinField(skBackComp, ms, mr, hasMr)
	if !ok {
		return nil, false
	}
	rr, hasRr, ok := keysPickOne("reaction_systems", d.Blocks)
	if !ok {
		return nil, false
	}
	rss, hasRss, ok := keysJoinField(skBackComp, rs, rr, hasRr)
	if !ok {
		return nil, false
	}
	var tkv Obj
	if len(d.Math) > 0 {
		refs := make([]*MC, len(d.Math))
		for i := range d.Math {
			refs[i] = &d.Math[i]
		}
		tkv = Obj{{"operators", skFieldJson("operators", refs)}}
	}
	kvs := esmKv
	kvs = append(kvs, metaKv...)
	kvs = append(kvs, skOptKv("models", models, hasModels)...)
	kvs = append(kvs, skOptKv("reaction_systems", rss, hasRss)...)
	kvs = append(kvs, tkv...)
	for _, kv := range d.Blocks {
		if kv.K != "models" && kv.K != "reaction_systems" {
			kvs = append(kvs, kv)
		}
	}
	doc := keysSortKeys(kvs)
	if skCanonDoc(doc) {
		return doc, true
	}
	return nil, false
}
