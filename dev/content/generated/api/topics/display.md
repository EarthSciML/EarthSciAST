---
title: "Display"
description: "Printing expressions and equations as math for people to read, LaTeX or Typst, under the names they use."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`expression_names`](/generated/api/ref/expression_names) | function | Julia, TypeScript, Python, Rust, Go | The variable names an expression or an equation uses, in order of first use: its string leaves under `lhs`, `rhs` and `args`. |
| [`print_math`](/generated/api/ref/print_math) | function | Julia, TypeScript, Python, Rust, Go | Print one expression, or one equation, as math under a set of declared names: LaTeX for `:markdown` (Lean `Math.printLatex`), Typst math for `:typst` (`Math.printTypst`). |
| [`to_julia_code`](/generated/api/ref/to_julia_code) | function | Julia, Python | Generate a Julia script from an ESM file. |

[All topics](/generated/api)
