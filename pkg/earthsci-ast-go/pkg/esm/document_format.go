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
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"

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
//
// expr may also be, or hold at any depth (an equation map whose `rhs` is an
// ExprNode), one of this package's typed values (an ExprNode, an Equation, a
// pointer to one), which prints as its JSON encoding does.
func PrintMath(expr any, names []string, f DocumentFormat) string {
	expr = decodedValue(expr)
	return docfmt.PrintMath(docfmt.FromGo(CanonicalizeDocument(expr)), names, f != DocumentTypst)
}

// ExpressionNames returns the variable names an expression or an equation
// uses, in order of first use: its string leaves under `lhs`, `rhs` and `args`.
// These are the names to give PrintMath to show an expression on its own, with
// its names declared. expr is a decoded expression or equation, or one of this
// package's typed values (ExprNode, Equation, ...).
func ExpressionNames(expr any) []string {
	var out []string
	seen := map[string]bool{}
	var walk func(v any)
	walk = func(v any) {
		switch x := v.(type) {
		case string:
			if !seen[x] {
				seen[x] = true
				out = append(out, x)
			}
		case []any:
			for _, item := range x {
				walk(item)
			}
		case map[string]any:
			for _, key := range []string{"lhs", "rhs", "args"} {
				if child, ok := x[key]; ok {
					walk(child)
				}
			}
		}
	}
	walk(decodedValue(expr))
	return out
}

// ParseMath reads one expression, or one equation, written as math under a
// set of declared names: LaTeX for DocumentMarkdown (Lean `Math.parseLatex`),
// Typst math for DocumentTypst (`Math.parseTypst`). It is the inverse of
// PrintMath: ParseMath(PrintMath(e, names, f), names, f) is e in canonical form
// (CanonicalizeDocument), the value PrintMath takes.
//
// text is what a document display holds, without its delimiters. Text whose
// top is `=` reads as an equation, a map with `lhs` and `rhs`, as a display
// does (`Source.eqSides`); any other text reads as an expression. names plays
// the part of the variables a component declares: it decides how a run of
// letters reads (in LaTeX, `RT` is the name `RT` when it is declared, the
// product of `R` and `T` when they are). No template is in scope.
//
// A text that is not math returns a *DocumentFormatError with code
// `removed_op` when it uses an operator removed from the format (esm-spec
// §4.2), and `parse_error` for any other text, and for one past a bound of the
// reader, as ParseMarkdown: nested too deeply, or holding a number beyond the
// binary64 range.
func ParseMath(text string, names []string, format DocumentFormat) (any, error) {
	var lim docfmt.Lim
	e, ok := docfmt.ParseMath(&lim, text, names, format != DocumentTypst)
	if !ok && lim.RemovedOp == "" && !lim.TooDeep {
		return nil, &DocumentFormatError{
			Code:    CodeParseError,
			Message: fmt.Sprintf("not an ESM expression in %s math", map[DocumentFormat]string{DocumentMarkdown: "LaTeX", DocumentTypst: "Typst"}[format]),
		}
	}
	return checkedRead(e, ok, &lim, format)
}

// decodedValue is v as encoding/json decodes it: a typed value of this package
// (ExprNode, Equation, a pointer to one, at any depth, inside a map or a slice
// too) becomes its JSON tree, in which an operator node built with no Args has
// the empty `args` the schema requires. A non-finite number, which no JSON
// holds, stays a float64 in the tree.
func decodedValue(v any) any {
	tree := jsonTree(v)
	var fill func(any)
	fill = func(x any) {
		switch t := x.(type) {
		case map[string]any:
			if args, ok := t["args"]; ok && args == nil {
				if _, isNode := t["op"]; isNode {
					t["args"] = []any{}
				}
			}
			for _, child := range t {
				fill(child)
			}
		case []any:
			for _, child := range t {
				fill(child)
			}
		}
	}
	fill(tree)
	return tree
}

// mathText is an expression or an equation, decoded or typed, as Typst math
// under its own names: how a message or a String method shows one.
func mathText(expr any) string {
	v := decodedValue(expr)
	return PrintMath(v, ExpressionNames(v), DocumentTypst)
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
	return checkedRead(d, ok, &lim, format)
}

// documentJSONText reads a source document written in the given format and
// returns it as JSON text, the form the JSON load path takes (esm-spec §1.2.1).
// The reader's entries keep their order (docfmt.Render), so the declaration
// order a document carries survives as it does for a `.esm` file. Numbers are
// spelled canonically, with the same reading ParseDocument gives them: an
// integer stays an integer and a decimal below the smallest subnormal is the
// integer 0. A text the reader refuses returns ParseDocument's
// *DocumentFormatError.
func documentJSONText(text string, format DocumentFormat) (string, error) {
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
	if _, err := checkedRead(d, ok, &lim, format); err != nil {
		return "", err
	}
	return docfmt.Render(zeroUnderflow(d)), nil
}

// zeroUnderflow replaces each decimal that rounds to zero by the integer 0, as
// docfmt.ToGo reads it, so the rendered text means what ParseDocument returns.
func zeroUnderflow(j docfmt.Json) docfmt.Json {
	switch x := j.(type) {
	case docfmt.JNum:
		if x.Dec && x.Float() == 0 {
			return docfmt.IntNum(0)
		}
	case []docfmt.Json:
		for i, e := range x {
			x[i] = zeroUnderflow(e)
		}
	case docfmt.Obj:
		for i := range x {
			x[i].V = zeroUnderflow(x[i].V)
		}
	}
	return j
}

// checkedRead is the result of a read (Rust `checked`): refused past a bound
// of the reader (nested too deeply, a number beyond binary64), else the
// reader's value in Go form, else the reader's refusal.
func checkedRead(d docfmt.Json, ok bool, lim *docfmt.Lim, format DocumentFormat) (any, error) {
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

// sameExpression reports whether two expressions, decoded or typed, are the
// same: whether their expressionKey is.
func sameExpression(a, b any) bool {
	return expressionKey(a) == expressionKey(b)
}

// expressionKey is the comparison key of an expression or an equation,
// decoded or typed: its canonical form (CanonicalizeDocument; numbers in their
// canonical kind, CONFORMANCE §5.5.3.1) with every `D` that names no `wrt`
// given the independent variable it means (esm-spec §4.2), and with the
// docfmt.NodeAnnotations of every operator node dropped (a rewrite-target op's
// `attrs` are its scheme parameters, so they stay), written out as
// text. Everything else is kept, and a non-finite number is written out as
// well, so a NaN constant has the same key as itself.
func expressionKey(v any) string {
	var b strings.Builder
	writeExpressionKey(&b, CanonicalizeDocument(decodedValue(v)))
	return b.String()
}

func writeExpressionKey(b *strings.Builder, v any) {
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		b.WriteString(strconv.FormatBool(x))
	case string:
		b.WriteString(strconv.Quote(x))
	case int64:
		b.WriteString("i")
		b.WriteString(strconv.FormatInt(x, 10))
	case float64:
		b.WriteString("f")
		b.WriteString(strconv.FormatFloat(x, 'g', -1, 64))
	case json.Number:
		b.WriteString("n")
		b.WriteString(string(x))
	case []any:
		b.WriteString("[")
		for i, item := range x {
			if i > 0 {
				b.WriteString(",")
			}
			writeExpressionKey(b, item)
		}
		b.WriteString("]")
	case map[string]any:
		_, isNode := x["op"]
		if isNode {
			if x["op"] == "D" {
				if _, has := x["wrt"]; !has {
					x["wrt"] = DefaultIndepVar
				}
			}
			for _, k := range docfmt.NodeAnnotations {
				delete(x, k)
			}
		}
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		b.WriteString("{")
		for i, k := range keys {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString(strconv.Quote(k))
			b.WriteString(":")
			writeExpressionKey(b, x[k])
		}
		b.WriteString("}")
	default:
		fmt.Fprintf(b, "%T(%#v)", x, x)
	}
}
