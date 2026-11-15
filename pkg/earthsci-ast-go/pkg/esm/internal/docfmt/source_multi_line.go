package docfmt

// Multi-line equations (accepted input variants): rows split at top-level line
// breaks, cells at the first top-level `&`. Port of
// formal/Esm/Document/Source/MultiLine.lean (Rust:
// document/source/multi_line.rs); prefix `ml`. The reader works on the math
// tokens, so rows and cells are found by token and depth.

// mlDelta is `Source.delta`: how a token changes the delimiter depth.
func mlDelta(t *Tok) int64 {
	if t.K != TKw {
		return 0
	}
	switch t.W {
	case KwLp, KwLpg, KwLb, KwLbk, KwBcases, KwBmat, KwLbkg:
		return 1
	case KwRp, KwRpg, KwRb, KwRbk, KwEcases, KwEmat, KwRbkg:
		return -1
	}
	return 0
}

// mlCut is `Source.cut`: cut at the first k at depth 0 (starting at depth d).
// found is false when there is none.
func mlCut(k Kw, d int64, ts []Tok) (before, after []Tok, found bool) {
	for i := range ts {
		if d == 0 && ts[i].isKw(k) {
			return ts[:i], ts[i+1:], true
		}
		d += mlDelta(&ts[i])
	}
	return ts, nil, false
}

// mlSplitAll is `Source.splitAll`: split at every top-level k.
func mlSplitAll(k Kw, ts []Tok) [][]Tok {
	var out [][]Tok
	for {
		a, r, found := mlCut(k, 0, ts)
		if !found {
			return append(out, ts)
		}
		out = append(out, a)
		ts = r
	}
}

// mlGroup is `Source.group`: rows into equations (one: all rows are one
// equation).
func mlGroup(one bool, rows [][]Tok) ([][]Tok, bool) {
	var acc [][]Tok
	extendLast := func(parts ...[]Tok) {
		cur := acc[len(acc)-1]
		for _, p := range parts {
			cur = append(cur, p...)
		}
		acc[len(acc)-1] = cur
	}
	fresh := func(parts ...[]Tok) {
		var v []Tok
		for _, p := range parts {
			v = append(v, p...)
		}
		acc = append(acc, v)
	}
	for _, row := range rows {
		l, r, found := mlCut(KwAmp, 0, row)
		if !found {
			if len(l) == 0 {
				continue
			}
			if one && len(acc) > 0 {
				extendLast(l)
			} else {
				fresh(l)
			}
			continue
		}
		if _, _, again := mlCut(KwAmp, 0, r); again {
			return nil, false
		}
		switch {
		case len(l) == 0 && !one:
			if len(acc) == 0 {
				return nil, false
			}
			if len(r) > 0 && r[0].isKw(KwEq) {
				return nil, false
			}
			extendLast(r)
		case one:
			if len(acc) == 0 {
				fresh(l, r)
			} else {
				extendLast(l, r)
			}
		default:
			fresh(l, r)
		}
	}
	return acc, true
}

// mlCookRows is `Source.cookRows`: read the rows of a multi-line display into
// equations.
func mlCookRows(sf Sf, s *Sym, one bool, ts []Tok) ([]Eqn, bool) {
	eqs, ok := mlGroup(one, mlSplitAll(KwNl, ts))
	if !ok {
		return nil, false
	}
	out := make([]Eqn, len(eqs))
	for i, t := range eqs {
		j, ok := mathParseToks(sf, s, t)
		if !ok {
			return nil, false
		}
		l, r, ok := eqnEqSides(j)
		if !ok {
			return nil, false
		}
		out[i] = Eqn{Lhs: l, Rhs: r}
	}
	return out, true
}
