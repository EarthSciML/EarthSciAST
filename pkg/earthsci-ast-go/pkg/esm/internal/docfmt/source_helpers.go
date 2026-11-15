package docfmt

// Small helpers of the source layer that have no Lean counterpart.

// appendSpaces appends n spaces.
func appendSpaces(out []rune, n int) []rune {
	for i := 0; i < n; i++ {
		out = append(out, ' ')
	}
	return out
}

// runesEqual is equality of two character lists.
func runesEqual(a, b []rune) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// asStr is the string a value holds.
func asStr(j Json) (string, bool) {
	s, ok := j.(string)
	return s, ok
}
