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

// dropN is s without its first n characters (empty when it is shorter).
func dropN(s []rune, n int) []rune {
	if n >= len(s) {
		return nil
	}
	return s[n:]
}

// symEmpty is the empty symbol table. It is never modified.
var symEmpty = &Sym{}

// containsRune reports whether s contains c.
func containsRune(s []rune, c rune) bool {
	for _, d := range s {
		if d == c {
			return true
		}
	}
	return false
}

// cutTrailingNewline splits a text ending in a newline into the text before it.
func cutTrailingNewline(s []rune) ([]rune, bool) {
	if len(s) == 0 || s[len(s)-1] != '\n' {
		return nil, false
	}
	return s[:len(s)-1], true
}
