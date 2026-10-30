package esm

import "strings"

// quoteSafe escapes a document-supplied name for interpolation between quotes
// in a diagnostic message ("template '%s'", "\"%s\""). A backslash becomes
// `\\` and each single or double quote gains a leading backslash, so the
// quoted span always ends where the message author put the closing quote.
// Ordinary identifiers, which contain none of the three characters, come back
// unchanged, so the message text is the same for every realistic document.
func quoteSafe(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `'`, `\'`)
	return strings.ReplaceAll(s, `"`, `\"`)
}
