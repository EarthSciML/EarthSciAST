package docfmt

// The skeleton as a sequence of constructs. Port of
// formal/Esm/Document/Source/Items.lean (Rust: document/source/items.rs);
// prefix `items`.
//
// itemsItems lists the constructs of a skeleton in the printer's order;
// itemsUnitems reads a construct sequence back. Math entries are held as the
// container's math text at this layer; itemsRawDoc prints them under each
// component's symbol table and itemsCookDoc reads them back.

// RItemKind says which variant an RItem is.
type RItemKind uint8

// The construct variants.
const (
	RIDesc RItemKind = iota
	RIBlock
	RIComp
	RIDecl
	RIEqn
	RIEqx
	RIRxn
	RIPlot
	RITm
)

// RItem is `Source.RItem`: one construct of a document. An equation is its
// math text, uninterpreted; so is a reaction's rate.
type RItem struct {
	K    RItemKind
	S    string      // RIDesc text, RIBlock key, RIComp name, RIEqn/RIEqx math text
	V    Json        // RIBlock value
	Kind Kind        // RIComp
	Decl Decl        // RIDecl
	Role Role        // RIEqx
	Rxn  Rxn[string] // RIRxn
	Plot Obj         // RIPlot
	Tm   Tm[string]  // RITm
}

// itemsMItem is `Source.mItem`: the construct of a math entry.
func itemsMItem(m *MR) RItem {
	switch m.K {
	case MxRxn:
		return RItem{K: RIRxn, Rxn: m.Rxn}
	case MxPlot:
		return RItem{K: RIPlot, Plot: m.Plot}
	case MxTm:
		return RItem{K: RITm, Tm: m.Tm}
	}
	if m.Role == RoleEqn {
		return RItem{K: RIEqn, S: m.Eq}
	}
	return RItem{K: RIEqx, Role: m.Role, S: m.Eq}
}

// itemsCompItems is `Source.compItems`: the constructs of a component section.
func itemsCompItems(c *Comp[MR], out []RItem) []RItem {
	out = append(out, RItem{K: RIComp, Kind: c.Kind, S: c.Name})
	if c.HasDesc {
		out = append(out, RItem{K: RIDesc, S: c.Desc})
	}
	for _, d := range c.Decls {
		out = append(out, RItem{K: RIDecl, Decl: d})
	}
	for i := range c.Math {
		out = append(out, itemsMItem(&c.Math[i]))
	}
	for _, kv := range c.MathBlocks {
		out = append(out, RItem{K: RIBlock, S: kv.K, V: kv.V})
	}
	for _, kv := range c.Blocks {
		out = append(out, RItem{K: RIBlock, S: kv.K, V: kv.V})
	}
	return out
}

// itemsItems is `Source.items`: the constructs of a skeleton, in the printer's
// order.
func itemsItems(d *Doc[MR]) []RItem {
	var out []RItem
	if d.HasDesc {
		out = append(out, RItem{K: RIDesc, S: d.Desc})
	}
	for _, kv := range d.Blocks {
		out = append(out, RItem{K: RIBlock, S: kv.K, V: kv.V})
	}
	for i := range d.Math {
		out = append(out, itemsMItem(&d.Math[i]))
	}
	for i := range d.Comps {
		out = itemsCompItems(&d.Comps[i], out)
	}
	return out
}

// itemsAddTo is `Source.addTo`: add a construct to a component section; a
// second description is refused.
func itemsAddTo(c *Comp[MR], it RItem) bool {
	switch it.K {
	case RIDesc:
		if c.HasDesc {
			return false
		}
		c.HasDesc, c.Desc = true, it.S
	case RIBlock:
		if skIsMathField(it.S) {
			c.MathBlocks = append(c.MathBlocks, KV{it.S, it.V})
		} else {
			c.Blocks = append(c.Blocks, KV{it.S, it.V})
		}
	case RIDecl:
		c.Decls = append(c.Decls, it.Decl)
	case RIEqn:
		c.Math = append(c.Math, MR{K: MxEq, Role: RoleEqn, Eq: it.S})
	case RIEqx:
		c.Math = append(c.Math, MR{K: MxEq, Role: it.Role, Eq: it.S})
	case RIRxn:
		c.Math = append(c.Math, MR{K: MxRxn, Rxn: it.Rxn})
	case RIPlot:
		c.Math = append(c.Math, MR{K: MxPlot, Plot: it.Plot})
	case RITm:
		c.Math = append(c.Math, MR{K: MxTm, Tm: it.Tm})
	default:
		return false
	}
	return true
}

// itemsSt is `Source.St`: the reader's state.
type itemsSt struct {
	hasDesc bool
	desc    string
	blocks  Obj
	math    []MR
	comps   []Comp[MR]
	hasCur  bool
	cur     Comp[MR]
}

// itemsStep is `Source.step`: read one construct. Before the first directive
// only a description, blocks and templates are allowed.
func itemsStep(st *itemsSt, it RItem) bool {
	if it.K == RIComp {
		if st.hasCur {
			st.comps = append(st.comps, st.cur)
		}
		st.hasCur, st.cur = true, Comp[MR]{Kind: it.Kind, Name: it.S}
		return true
	}
	if st.hasCur {
		return itemsAddTo(&st.cur, it)
	}
	switch it.K {
	case RIDesc:
		if st.hasDesc {
			return false
		}
		st.hasDesc, st.desc = true, it.S
	case RIBlock:
		st.blocks = append(st.blocks, KV{it.S, it.V})
	case RITm:
		st.math = append(st.math, MR{K: MxTm, Tm: it.Tm})
	default:
		return false
	}
	return true
}

// itemsUnitems is `Source.unitems`: read a construct sequence (with the front
// matter) into a skeleton.
func itemsUnitems(front Obj, its []RItem) (Doc[MR], bool) {
	var st itemsSt
	for _, it := range its {
		if !itemsStep(&st, it) {
			return Doc[MR]{}, false
		}
	}
	comps := st.comps
	if st.hasCur {
		comps = append(comps, st.cur)
	}
	return Doc[MR]{Front: front, HasDesc: st.hasDesc, Desc: st.desc, Blocks: st.blocks, Math: st.math, Comps: comps}, true
}

// itemsRawDoc is `Source.rawDoc`: every math entry printed under its symbol
// table.
func itemsRawDoc(pr func(*Sym, *MC) MR, d *Doc[MC]) Doc[MR] {
	ts := skTopSym(d)
	math := make([]MR, len(d.Math))
	for i := range d.Math {
		math[i] = pr(ts, &d.Math[i])
	}
	comps := make([]Comp[MR], len(d.Comps))
	for i := range d.Comps {
		c := &d.Comps[i]
		s := skSymFor(d, c)
		comps[i] = skMapMath(c, func(_ *Comp[MC], m *MC) MR { return pr(s, m) })
	}
	return Doc[MR]{Front: d.Front, HasDesc: d.HasDesc, Desc: d.Desc, Blocks: d.Blocks, Math: math, Comps: comps}
}

// itemsCookComp is `Source.cookComp`: read a component's math entries under
// its symbol table; one math text may hold several equations.
func itemsCookComp(lim *Lim, ck func(*Lim, *Sym, *MR) ([]MC, bool), d *Doc[MR], c *Comp[MR]) (Comp[MC], bool) {
	s := skSymFor(d, c)
	var math []MC
	for i := range c.Math {
		ms, ok := ck(lim, s, &c.Math[i])
		if !ok {
			return Comp[MC]{}, false
		}
		math = append(math, ms...)
	}
	return Comp[MC]{
		Kind: c.Kind, Name: c.Name, HasDesc: c.HasDesc, Desc: c.Desc, Decls: c.Decls,
		Math: math, MathBlocks: c.MathBlocks, Blocks: c.Blocks,
	}, true
}

// itemsCookDoc is `Source.cookDoc`: read every math entry of a skeleton.
func itemsCookDoc(lim *Lim, ck func(*Lim, *Sym, *MR) ([]MC, bool), d *Doc[MR]) (Doc[MC], bool) {
	ts := skTopSym(d)
	var rm []MC
	for i := range d.Math {
		ms, ok := ck(lim, ts, &d.Math[i])
		if !ok {
			return Doc[MC]{}, false
		}
		rm = append(rm, ms...)
	}
	cs := make([]Comp[MC], len(d.Comps))
	for i := range d.Comps {
		c, ok := itemsCookComp(lim, ck, d, &d.Comps[i])
		if !ok {
			return Doc[MC]{}, false
		}
		cs[i] = c
	}
	return Doc[MC]{Front: d.Front, HasDesc: d.HasDesc, Desc: d.Desc, Blocks: d.Blocks, Math: rm, Comps: cs}, true
}

// itemsPrMx is `Source.prMx`: a math entry's text, from the equation and
// expression printers.
func itemsPrMx(prE func(*Sym, *Eqn) string, prR func(*Sym, Json) string, s *Sym, m *MC) MR {
	switch m.K {
	case MxRxn:
		x := &m.Rxn
		return MR{K: MxRxn, Rxn: Rxn[string]{
			ID: x.ID, HasSubs: x.HasSubs, Subs: x.Subs, HasProds: x.HasProds, Prods: x.Prods,
			Rate: prR(s, x.Rate), Attrs: x.Attrs,
		}}
	case MxPlot:
		return MR{K: MxPlot, Plot: m.Plot}
	case MxTm:
		t := &m.Tm
		sc := t.scope(s)
		out := Tm[string]{Name: t.Name, Params: t.Params, HasLhs: t.HasLhs, Body: prR(sc, t.Body), Attrs: t.Attrs}
		if t.HasLhs {
			out.Lhs = prR(sc, t.Lhs)
		}
		return MR{K: MxTm, Tm: out}
	}
	return MR{K: MxEq, Role: m.Role, Eq: prE(s, &m.Eq)}
}

// itemsCkMx is `Source.ckMx`: read a math entry's text back.
func itemsCkMx(lim *Lim, ckE func(*Lim, *Sym, string) ([]Eqn, bool), ckR func(*Lim, *Sym, string) (Json, bool), s *Sym, m *MR) ([]MC, bool) {
	switch m.K {
	case MxRxn:
		x := &m.Rxn
		j, ok := ckR(lim, s, x.Rate)
		if !ok {
			return nil, false
		}
		return []MC{{K: MxRxn, Rxn: Rxn[Json]{
			ID: x.ID, HasSubs: x.HasSubs, Subs: x.Subs, HasProds: x.HasProds, Prods: x.Prods,
			Rate: j, Attrs: x.Attrs,
		}}}, true
	case MxPlot:
		return []MC{{K: MxPlot, Plot: m.Plot}}, true
	case MxTm:
		t := &m.Tm
		sc := t.scope(s)
		out := Tm[Json]{Name: t.Name, Params: t.Params, HasLhs: t.HasLhs, Attrs: t.Attrs}
		if t.HasLhs {
			l, ok := ckR(lim, sc, t.Lhs)
			if !ok {
				return nil, false
			}
			out.Lhs = l
		}
		b, ok := ckR(lim, sc, t.Body)
		if !ok {
			return nil, false
		}
		out.Body = b
		return []MC{{K: MxTm, Tm: out}}, true
	}
	es, ok := ckE(lim, s, m.Eq)
	if !ok {
		return nil, false
	}
	out := make([]MC, len(es))
	for i, e := range es {
		out[i] = MC{K: MxEq, Role: m.Role, Eq: e}
	}
	return out, true
}
