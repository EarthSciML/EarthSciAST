package esm

// The document source formats (CONFORMANCE_SPEC §5.58): an ESM document written
// as Markdown (LaTeX math, remark-directive directives, YAML front matter and
// container bodies) or as Typst (Typst math, `esm` package functions, Typst
// dictionaries). Both formats are lossless: printing a document and reading it
// back gives its canonical form (CanonicalizeDocument) again, and prose between
// the constructs never changes what is read.
//
// The notation is formal/Esm/Document/Notation.lean; the printer and reader are
// a port of the Lean model's executable definitions (internal/docfmt). The
// golden set is tests/conformance/document_format/.

import (
	"fmt"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm/internal/docfmt"
)

// DocumentFormat is a source format an ESM document can be written in.
type DocumentFormat int

const (
	// DocumentMarkdown is Markdown with LaTeX math.
	DocumentMarkdown DocumentFormat = iota
	// DocumentTypst is Typst.
	DocumentTypst
)

// String names the format.
func (f DocumentFormat) String() string {
	switch f {
	case DocumentMarkdown:
		return "markdown"
	case DocumentTypst:
		return "typst"
	}
	return fmt.Sprintf("DocumentFormat(%d)", int(f))
}

// DocumentFormatError is the diagnostic for a text that is not an ESM document
// in the format it was read as. Code is `removed_op` when the document's math
// writes an operator removed from the format in the call or escape form
// (esm-spec §4.2, CONFORMANCE §7.1), and `parse_error` for any other text.
type DocumentFormatError struct {
	Code    string
	Message string
}

func (e *DocumentFormatError) Error() string { return fmt.Sprintf("[%s] %s", e.Code, e.Message) }

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *DocumentFormatError) DiagnosticCode() string { return e.Code }

// printableDocument is the value the printers take: CanonicalizeDocument
// applied, every object's keys sorted (Lean `Source.canonDoc`).
func printableDocument(doc any) docfmt.Json {
	return docfmt.FromGo(CanonicalizeDocument(doc))
}

// PrintMarkdown prints an ESM document as Markdown (Lean `Source.Md.printMd`).
//
// doc is a decoded document (the value CanonicalizeDocument takes: a
// map[string]any as encoding/json produces, numbers as float64, json.Number or
// int64). It is put in canonical form first, so two documents that
// canonicalize alike print alike, and ParseMarkdown(PrintMarkdown(d)) is
// CanonicalizeDocument(d).
func PrintMarkdown(doc any) string { return docfmt.PrintMd(printableDocument(doc)) }

// PrintTypst prints an ESM document as Typst (Lean `Source.Typ.printTyp`). See
// PrintMarkdown.
func PrintTypst(doc any) string { return docfmt.PrintTyp(printableDocument(doc)) }

// PrintDocument prints an ESM document in the given format.
func PrintDocument(doc any, format DocumentFormat) string {
	if format == DocumentTypst {
		return PrintTypst(doc)
	}
	return PrintMarkdown(doc)
}

// PrintMath prints one expression, or one equation, as math under a set of
// declared names: LaTeX for DocumentMarkdown (Lean `Math.printLatex`), Typst
// math for DocumentTypst (`Math.printTypst`).
//
// expr is a decoded ESM expression (a number, a name or an operator node) or an
// equation, an object with `lhs` and `rhs` (other fields, such as `_comment`,
// are not printed), which prints as its two sides around `=` as in a document
// (`Source.eqExpr`). names plays the part of the variables a component
// declares: a name in it prints in its declared shape, and the printer avoids
// spellings that would collide with it. The result is what a document display
// holds, without its delimiters; it is meant for showing one expression outside
// a document, so no template is in scope.
func PrintMath(expr any, names []string, f DocumentFormat) string {
	return docfmt.PrintMath(docfmt.FromGo(CanonicalizeDocument(expr)), names, f != DocumentTypst)
}

// ParseMarkdown reads a Markdown ESM document (Lean `Source.Md.parseMd`). The
// result is in canonical form, the representation CanonicalizeDocument returns
// (map[string]any, []any, int64 for an integer, float64 for a decimal).
//
// A text that is not a Markdown ESM document returns a *DocumentFormatError
// with code `removed_op` when the document's math uses an operator removed
// from the format (esm-spec §4.2), and `parse_error` for any other text, and
// for one past a bound of the reader: nested too deeply (more than 128 reader
// constructs open at once, or more than 127 levels of arrays and objects), or
// holding a number beyond the binary64 range.
func ParseMarkdown(text string) (any, error) { return ParseDocument(text, DocumentMarkdown) }

// ParseTypst reads a Typst ESM document (Lean `Source.Typ.parseTyp`). See
// ParseMarkdown.
func ParseTypst(text string) (any, error) { return ParseDocument(text, DocumentTypst) }

// ParseDocument reads an ESM document written in the given format. See
// ParseMarkdown.
func ParseDocument(text string, format DocumentFormat) (any, error) {
	var (
		lim docfmt.Lim
		d   docfmt.Json
		ok  bool
	)
	if format == DocumentTypst {
		d, ok = docfmt.ParseTyp(&lim, text)
	} else {
		d, ok = docfmt.ParseMd(&lim, text)
	}
	if lim.TooDeep || (ok && docfmt.JSONDepth(d) > docfmt.MaxJSONDepth) {
		return nil, &DocumentFormatError{
			Code: CodeParseError,
			Message: fmt.Sprintf("the document nests too deeply for the reader (at most %d constructs open at once, and %d levels of arrays and objects)",
				docfmt.MaxNesting, docfmt.MaxJSONDepth),
		}
	}
	if !ok {
		return nil, documentRefusal(lim.RemovedOp, format)
	}
	v, bad, ok := docfmt.ToGo(d)
	if !ok {
		return nil, &DocumentFormatError{
			Code:    CodeParseError,
			Message: fmt.Sprintf("the number `%s` is outside the binary64 range", docfmt.PrintNum(bad)),
		}
	}
	return v, nil
}

// documentRefusal is the diagnostic for a text the reader refused. The Lean
// reader refuses every bad input alike; the code comes from the specification:
// a removed operator the math writes in the call form or the escape form
// (removedOp, as the reader met it) is refused by name (CONFORMANCE §7.1),
// everything else is a parse error.
func documentRefusal(removedOp string, format DocumentFormat) *DocumentFormatError {
	if removedOp != "" {
		return &DocumentFormatError{
			Code:    codeRemovedOp,
			Message: fmt.Sprintf("`%s` was removed from the format (esm-spec §4.2)", removedOp),
		}
	}
	return &DocumentFormatError{
		Code:    CodeParseError,
		Message: fmt.Sprintf("not an ESM %s document", map[DocumentFormat]string{DocumentMarkdown: "Markdown", DocumentTypst: "Typst"}[format]),
	}
}
