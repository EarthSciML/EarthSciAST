package docfmt

// The entry points the esm package calls.

// PrintMd prints a document (canonical form, keys sorted) as Markdown
// (`Source.Md.printMd`).
func PrintMd(d Json) string { return mdDocPrintMd(d) }

// ParseMd reads a Markdown document (`Source.Md.parseMd`).
func ParseMd(text string) (Json, bool) { return mdDocParseMd(text) }

// PrintTyp prints a document (canonical form, keys sorted) as Typst
// (`Source.Typ.printTyp`).
func PrintTyp(d Json) string { return typDocPrintTyp(d) }

// ParseTyp reads a Typst document (`Source.Typ.parseTyp`).
func ParseTyp(text string) (Json, bool) { return typDocParseTyp(text) }
