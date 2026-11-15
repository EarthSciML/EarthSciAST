package docfmt

// Lines of text, and the input decoding. Port of
// formal/Esm/Document/Source/Lines.lean (Rust: document/source/lines.rs);
// prefix `lines`. (`heads` and `endBol` are used only by the Lean proofs.)

// linesDropBom is `Source.dropBOM`.
func linesDropBom(s []rune) []rune {
	if len(s) > 0 && s[0] == 0xFEFF {
		return s[1:]
	}
	return s
}

// linesFirstCrlf is `Source.firstCRLF`: whether the first line ends in CRLF.
func linesFirstCrlf(s []rune) bool {
	for i, c := range s {
		if c == '\n' {
			return false
		}
		if c == '\r' && i+1 < len(s) && s[i+1] == '\n' {
			return true
		}
	}
	return false
}

// linesUnCrlf is `Source.unCRLF`: every CRLF as LF.
func linesUnCrlf(s []rune) []rune {
	out := make([]rune, 0, len(s))
	for i, c := range s {
		if !(c == '\r' && i+1 < len(s) && s[i+1] == '\n') {
			out = append(out, c)
		}
	}
	return out
}

// linesDecodeText is `Source.decodeText`: no byte-order mark, and LF line
// endings when the first line ends in CRLF.
func linesDecodeText(s []rune) []rune {
	d := linesDropBom(s)
	if linesFirstCrlf(d) {
		return linesUnCrlf(d)
	}
	return d
}
