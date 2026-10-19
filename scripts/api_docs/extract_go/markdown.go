package main

import (
	"go/doc/comment"
	"go/parser"
	"go/token"
	"strings"
)

// markdown renders a Go doc comment as CommonMark, following the conventions
// in docs/api/README.md §2: a Go heading becomes a bold line, a doc link
// [Foo] becomes [`Foo`](api:Foo), and a code block becomes a fenced block.
func (ex *extractor) markdown(text string) string {
	if strings.TrimSpace(text) == "" {
		return ""
	}
	d := ex.parser.Parse(text)
	var blocks []string
	for _, b := range d.Content {
		if s := ex.block(b, ""); s != "" {
			blocks = append(blocks, s)
		}
	}
	return strings.Join(blocks, "\n\n")
}

func (ex *extractor) block(b comment.Block, indent string) string {
	switch b := b.(type) {
	case *comment.Heading:
		return indent + "**" + ex.inline(b.Text) + "**"
	case *comment.Paragraph:
		return indent + ex.inline(b.Text)
	case *comment.Code:
		code := strings.TrimRight(b.Text, "\n")
		lines := strings.Split("```"+codeLang(code)+"\n"+code+"\n```", "\n")
		for i := range lines {
			lines[i] = indent + lines[i]
		}
		return strings.Join(lines, "\n")
	case *comment.List:
		var items []string
		for _, it := range b.Items {
			marker := "- "
			if it.Number != "" {
				marker = it.Number + ". "
			}
			pad := indent + strings.Repeat(" ", len(marker))
			var parts []string
			for j, c := range it.Content {
				s := ex.block(c, pad)
				if j == 0 {
					s = indent + marker + strings.TrimPrefix(s, pad)
				}
				parts = append(parts, s)
			}
			items = append(items, strings.Join(parts, "\n\n"))
		}
		sep := "\n"
		if b.BlankBetween() {
			sep = "\n\n"
		}
		return strings.Join(items, sep)
	}
	return ""
}

// codeLang labels a code block "go" when it parses as Go source (a file body,
// a statement list, or an expression), and "text" otherwise, so JSON or prose
// snippets inside doc comments are not highlighted as Go.
func codeLang(code string) string {
	if _, err := parser.ParseExpr(code); err == nil {
		return "go"
	}
	if _, err := parser.ParseFile(token.NewFileSet(), "", "package p\n"+code, 0); err == nil {
		return "go"
	}
	if _, err := parser.ParseFile(token.NewFileSet(), "", "package p\nfunc _() {\n"+code+"\n}", 0); err == nil {
		return "go"
	}
	return "text"
}

// inline renders a run of doc-comment text. Backtick code spans pass through
// verbatim (the comments in pkg/esm use them as Markdown does), so the renderer
// tracks whether it is inside one: there, links render as their bare text and
// nothing is escaped.
func (ex *extractor) inline(ts []comment.Text) string {
	var sb strings.Builder
	inCode := false
	for _, t := range ts {
		switch t := t.(type) {
		case comment.Plain:
			inCode = writePlain(&sb, string(t), inCode)
		case comment.Italic:
			if inCode {
				sb.WriteString(string(t))
			} else {
				sb.WriteString("*" + escape(string(t)) + "*")
			}
		case *comment.Link:
			text := plainText(t.Text)
			switch {
			case inCode:
				sb.WriteString(text)
			case t.Auto || text == t.URL:
				sb.WriteString("<" + t.URL + ">")
			default:
				sb.WriteString("[" + escape(text) + "](" + t.URL + ")")
			}
		case *comment.DocLink:
			text := plainText(t.Text)
			if inCode {
				sb.WriteString(text)
				continue
			}
			sb.WriteString("[`" + text + "`](" + ex.docLinkTarget(t) + ")")
		}
	}
	return sb.String()
}

// docLinkTarget resolves a Go doc link. A symbol of this package links to its
// api: page (a method links to its receiver type's page, where the method is
// listed); a symbol of another package links to pkg.go.dev.
func (ex *extractor) docLinkTarget(l *comment.DocLink) string {
	if l.ImportPath == "" || l.ImportPath == ex.importPath {
		if l.Recv != "" {
			return "api:" + l.Recv
		}
		if l.Name == "" {
			return pkgDocsBase + ex.importPath
		}
		return "api:" + l.Name
	}
	url := pkgDocsBase + l.ImportPath
	switch {
	case l.Recv != "":
		url += "#" + l.Recv + "." + l.Name
	case l.Name != "":
		url += "#" + l.Name
	}
	return url
}

func plainText(ts []comment.Text) string {
	var sb strings.Builder
	for _, t := range ts {
		switch t := t.(type) {
		case comment.Plain:
			sb.WriteString(string(t))
		case comment.Italic:
			sb.WriteString(string(t))
		case *comment.Link:
			sb.WriteString(plainText(t.Text))
		case *comment.DocLink:
			sb.WriteString(plainText(t.Text))
		}
	}
	return strings.ReplaceAll(sb.String(), "\n", " ")
}

// writePlain writes s, escaping CommonMark syntax outside backtick spans, and
// returns whether a code span is still open at the end of s. Line breaks
// become spaces so a wrapped line that starts with "-" or "#" cannot turn
// into a list item or a heading.
func writePlain(sb *strings.Builder, s string, inCode bool) bool {
	s = strings.ReplaceAll(s, "\n", " ")
	for len(s) > 0 {
		i := strings.IndexByte(s, '`')
		if i < 0 {
			if inCode {
				sb.WriteString(s)
			} else {
				sb.WriteString(escape(s))
			}
			return inCode
		}
		if inCode {
			sb.WriteString(s[:i+1])
		} else {
			sb.WriteString(escape(s[:i]) + "`")
		}
		inCode = !inCode
		s = s[i+1:]
	}
	return inCode
}

var escaper = strings.NewReplacer(
	`\`, `\\`, `*`, `\*`, `_`, `\_`, `[`, `\[`, `]`, `\]`, `<`, `&lt;`, `>`, `&gt;`,
)

func escape(s string) string { return escaper.Replace(s) }
