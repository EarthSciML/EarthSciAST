package docfmt

// Objects in canonical form: sorting entries, and splitting an object between
// surfaces. Port of formal/Esm/Document/Source/Keys.lean (Rust:
// document/source/keys.rs); prefix `keys`.

import "sort"

// keysSortKeys is `Source.sortKeys`: the entries ordered by key (a stable
// sort). The argument is sorted in place and returned.
func keysSortKeys(l Obj) Obj {
	sort.SliceStable(l, func(a, b int) bool { return l[a].K < l[b].K })
	return l
}

// keysAt is `Source.at_`: the entries of l with key k.
func keysAt(k string, l Obj) Obj {
	var out Obj
	for _, kv := range l {
		if kv.K == k {
			out = append(out, kv)
		}
	}
	return out
}

// keysSplitField is `Source.splitField`: the entries of an object-valued field
// that pick takes, and the residue (hasR false when every entry was taken and
// there was at least one).
func keysSplitField[B any](pick func(string, Json) (B, bool), v Json) (ps []B, r Json, hasR bool) {
	kvs, ok := v.(Obj)
	if !ok {
		return nil, v, true
	}
	rs := Obj{}
	for _, kv := range kvs {
		if p, ok := pick(kv.K, kv.V); ok {
			ps = append(ps, p)
		} else {
			rs = append(rs, kv)
		}
	}
	if len(ps) > 0 && len(rs) == 0 {
		return ps, nil, false
	}
	return ps, rs, true
}

// keysSplitOpt is `Source.splitOpt`: splitField of a field that may be absent.
func keysSplitOpt[B any](pick func(string, Json) (B, bool), v Json, present bool) ([]B, Json, bool) {
	if !present {
		return nil, nil, false
	}
	return keysSplitField(pick, v)
}

// keysJoinField is `Source.joinField`: the field rebuilt from its pieces and
// its residue. ok is false when they do not fit together; present is false
// when the field is absent.
func keysJoinField[B any](back func(B) (KV, bool), ps []B, r Json, hasR bool) (v Json, present, ok bool) {
	if len(ps) == 0 {
		return r, hasR, true
	}
	es := make(Obj, 0, len(ps))
	for _, p := range ps {
		e, ok := back(p)
		if !ok {
			return nil, false, false
		}
		es = append(es, e)
	}
	if !hasR {
		return keysSortKeys(es), true, true
	}
	rs, isObj := r.(Obj)
	if !isObj {
		return nil, false, false
	}
	es = append(es, rs...)
	return keysSortKeys(es), true, true
}

// keysPickOne is `Source.pickOne`: the value of key k, when it occurs at most
// once (ok false otherwise; present false when it does not occur).
func keysPickOne(k string, l Obj) (v Json, present, ok bool) {
	for _, kv := range l {
		if kv.K == k {
			if present {
				return nil, false, false
			}
			v, present = kv.V, true
		}
	}
	return v, present, true
}
