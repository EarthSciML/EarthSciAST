package docfmt

// Reaction sides, shared by the containers. Port of
// formal/Esm/Document/Source/Reaction.lean (Rust: document/source/reaction.rs);
// prefix `rxn`.
//
// A side is the empty-set symbol as math for an empty side, otherwise its
// terms separated by ` + `; a term is its coefficient as math and a space
// (left out when it is 1), then the species, bare when formula-shaped and
// otherwise its name as math under the empty symbol table. A side is a
// (has, terms) pair: has false is the empty side.

import "slices"

// RSurf is `Source.RSurf`: how a math piece prints and reads back (under the
// empty symbol table), and the content of the empty-set piece.
type RSurf struct {
	pm    func(string) (Json, bool)
	prm   func(Json) []rune
	empty []rune
}

// rxnIsAlnumC is `Source.isAlnumC`.
func rxnIsAlnumC(c rune) bool { return exprIsLetter(c) || exprIsDig(c) }

// rxnSpeciesTxt is `Source.speciesTxt`.
func rxnSpeciesTxt(r *RSurf, n string, out []rune) []rune {
	cs := []rune(n)
	if exprIsFormula(cs) {
		return append(out, cs...)
	}
	out = append(out, '$')
	out = append(out, r.prm(n)...)
	return append(out, '$')
}

// rxnTermTxt is `Source.termTxt`.
func rxnTermTxt(r *RSurf, t *Term, out []rune) []rune {
	if !t.Coef.IsInt(1) {
		out = append(out, '$')
		out = append(out, r.prm(t.Coef)...)
		out = append(out, '$', ' ')
	}
	return rxnSpeciesTxt(r, t.Species, out)
}

// rxnTermsTxt is `Source.termsTxt`.
func rxnTermsTxt(r *RSurf, ts []Term, out []rune) []rune {
	for i := range ts {
		if i > 0 {
			out = append(out, ' ', '+', ' ')
		}
		out = rxnTermTxt(r, &ts[i], out)
	}
	return out
}

// rxnSideTxt is `Source.sideTxt`.
func rxnSideTxt(r *RSurf, has bool, ts []Term) []rune {
	if !has {
		out := []rune{'$'}
		out = append(out, r.empty...)
		return append(out, '$')
	}
	return rxnTermsTxt(r, ts, nil)
}

// rxnTermOk is `Source.termOK`.
func rxnTermOk(r *RSurf, t *Term) bool {
	sp := []rune(t.Species)
	if !exprNameOk(t.Species) {
		return false
	}
	if !exprIsFormula(sp) {
		ps := r.prm(t.Species)
		if slices.Contains(ps, '$') || runesEqual(ps, r.empty) {
			return false
		}
	}
	if t.Coef.IsInt(1) {
		return true
	}
	pc := r.prm(t.Coef)
	return exprNumOk(t.Coef) && !slices.Contains(pc, '$') && !runesEqual(pc, r.empty)
}

// rxnSideOk is `Source.sideOK`.
func rxnSideOk(r *RSurf, has bool, ts []Term) bool {
	if !has {
		return true
	}
	if len(ts) == 0 {
		return false
	}
	for i := range ts {
		if !rxnTermOk(r, &ts[i]) {
			return false
		}
	}
	return true
}

// rxnIdChar is `Source.idChar`.
func rxnIdChar(c rune) bool { return strIsIdentChar(c) || c == '-' || c == '.' || c == ':' }

// rxnIdOk is `Source.idOK`: a reaction id the containers spell as a label.
func rxnIdOk(i string) bool {
	if i == "" {
		return false
	}
	for _, c := range i {
		if !rxnIdChar(c) {
			return false
		}
	}
	return true
}

// rxnPPiece is `Source.pPiece`: the text up to the next `$`, and the text
// after it.
func rxnPPiece(t []rune) ([]rune, []rune, bool) {
	p, r := textTakeWhile(t, func(c rune) bool { return c != '$' })
	if len(r) == 0 {
		return nil, nil, false
	}
	return p, r[1:], true
}

// rxnPSpecies is `Source.pSpecies`: a math piece holding a name, or a bare run
// of letters and digits.
func rxnPSpecies(r *RSurf, s []rune) (string, []rune, bool) {
	if len(s) > 0 && s[0] == '$' {
		p, rest, ok := rxnPPiece(s[1:])
		if !ok {
			return "", nil, false
		}
		v, ok := r.pm(string(p))
		n, isStr := v.(string)
		if !ok || !isStr {
			return "", nil, false
		}
		return n, rest, true
	}
	a, rest := textTakeWhile(s, rxnIsAlnumC)
	if len(a) == 0 {
		return "", nil, false
	}
	return string(a), rest, true
}

// rxnPTerm is `Source.pTerm`.
func rxnPTerm(r *RSurf, s []rune) (Term, []rune, bool) {
	if len(s) > 0 && s[0] == '$' {
		p, rest, ok := rxnPPiece(s[1:])
		if !ok {
			return Term{}, nil, false
		}
		v, ok := r.pm(string(p))
		if !ok {
			return Term{}, nil, false
		}
		switch x := v.(type) {
		case JNum:
			if len(rest) == 0 || rest[0] != ' ' {
				return Term{}, nil, false
			}
			n, r3, ok := rxnPSpecies(r, rest[1:])
			if !ok {
				return Term{}, nil, false
			}
			return Term{n, x}, r3, true
		case string:
			return Term{x, IntNum(1)}, rest, true
		}
		return Term{}, nil, false
	}
	n, r2, ok := rxnPSpecies(r, s)
	if !ok {
		return Term{}, nil, false
	}
	return Term{n, IntNum(1)}, r2, true
}

// rxnPTerms is `Source.pTerms`: terms separated by ` + `.
func rxnPTerms(r *RSurf, s []rune) ([]Term, []rune, bool) {
	var out []Term
	for {
		t, rest, ok := rxnPTerm(r, s)
		if !ok {
			return nil, nil, false
		}
		out = append(out, t)
		if hasPrefix(rest, " + ") {
			s = rest[3:]
		} else {
			return out, rest, true
		}
	}
}

// rxnPSide is `Source.pSide`: the empty-set piece (has false), or terms.
func rxnPSide(r *RSurf, s []rune) (ts []Term, has bool, rest []rune, ok bool) {
	if len(s) > 0 && s[0] == '$' {
		p, rest, ok := rxnPPiece(s[1:])
		if !ok {
			return nil, false, nil, false
		}
		if runesEqual(p, r.empty) {
			return nil, false, rest, true
		}
	}
	ts, r2, ok := rxnPTerms(r, s)
	if !ok {
		return nil, false, nil, false
	}
	return ts, true, r2, true
}
