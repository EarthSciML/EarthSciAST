package docfmt

// Text scanning shared by the containers: prefixes, lines, and fenced bodies
// ended by a closing line. Port of formal/Esm/Document/Source/Text.lean (Rust:
// document/source/text.rs); prefix `text`.

// textPre is `Source.pre`: p is a prefix of s.
func textPre(p, s []rune) bool {
	if len(p) > len(s) {
		return false
	}
	for i := range p {
		if p[i] != s[i] {
			return false
		}
	}
	return true
}

// textHasSub is `Source.hasSub`: p occurs in s.
func textHasSub(p, s []rune) bool {
	for i := 0; i <= len(s); i++ {
		if textPre(p, s[i:]) {
			return true
		}
	}
	return false
}

// textSplitLine is `Source.splitLine`: the first line (without its newline)
// and the text after it.
func textSplitLine(s []rune) ([]rune, []rune) {
	for i, c := range s {
		if c == '\n' {
			return s[:i], s[i+1:]
		}
	}
	return s, nil
}

// textNoStop is `Source.noStop`: no line of s starts with stop.
func textNoStop(stop, s []rune) bool {
	for len(s) > 0 {
		if textPre(stop, s) {
			return false
		}
		_, s = textSplitLine(s)
	}
	return true
}

// textUntilStop is `Source.untilStop`: lines up to the first one that starts
// with stop: the lines before it (each with its newline), the rest of the
// closing line, and the text after the closing line.
func textUntilStop(stop, s []rune) (body, rest, after []rune, ok bool) {
	for {
		if len(s) == 0 {
			return nil, nil, nil, false
		}
		if textPre(stop, s) {
			a, b := textSplitLine(s[len(stop):])
			return body, a, b, true
		}
		line, r := textSplitLine(s)
		body = append(body, line...)
		body = append(body, '\n')
		s = r
	}
}

// textBlank is `l.all (· == ' ')`.
func textBlank(l []rune) bool {
	for _, c := range l {
		if c != ' ' {
			return false
		}
	}
	return true
}

// textTakeWhile is `t.takeWhile p` and the rest.
func textTakeWhile(t []rune, p func(rune) bool) ([]rune, []rune) {
	n := 0
	for n < len(t) && p(t[n]) {
		n++
	}
	return t[:n], t[n:]
}

// textPreS is textPre with a spelling as the prefix (no allocation).
func textPreS(p string, s []rune) bool { return hasPrefix(s, p) }

// textAfterS is `after` (Reaction.lean) with a spelling as the prefix.
func textAfterS(p string, s []rune) ([]rune, bool) {
	r, ok := cutPrefix(s, p)
	if !ok {
		return nil, false
	}
	return r, true
}
