---
title: "Expressions"
description: "Parsing, inspecting, substituting into, simplifying and evaluating expressions and equations."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`closed_function_names`](/generated/api/ref/closed_function_names) | function | Julia, TypeScript, Rust, Go | Return the v0.3.0 closed function set. |
| [`contains`](/generated/api/ref/contains) | function | TypeScript, Python, Rust, Go | Check if an expression contains a specific variable |
| [`evaluate`](/generated/api/ref/evaluate) | function | Python, Rust, Go | Evaluate a scalar AST expression against a dict of float variable bindings. |
| [`evaluate_closed_function`](/generated/api/ref/evaluate_closed_function) | function | Julia, Rust, Go | Dispatch a closed function call. |
| [`expand`](/generated/api/ref/expand) | function | Python, Go | Public alias for `expand_document` using the spec's spelling (esm-spec §9.6.4 rule 2). |
| [`free_variables`](/generated/api/ref/free_variables) | function | Julia, TypeScript, Python, Rust, Go | Extract all free (unbound) variable names from an expression. |
| [`parse_equation`](/generated/api/ref/parse_equation) | function | Julia, TypeScript, Python, Rust, Go | Parse `lhs = rhs` into an `Equation`. |
| [`parse_expression`](/generated/api/ref/parse_expression) | function | Julia, TypeScript, Python, Rust, Go | Parse a single expression string in the INFIX TEXT form into an AST expression — the inverse of `to_ascii`. |
| [`simplify`](/generated/api/ref/simplify) | function | Julia, TypeScript, Python, Rust, Go | Perform constant folding and algebraic simplification on an expression. |
| [`substitute`](/generated/api/ref/substitute) | function | Julia, TypeScript, Python, Rust, Go | Replace every variable named in `bindings` with its replacement expression, throughout `expr` (including faq bodies, filter predicates, integral bounds and every other… |
| [`substitute_in_equations`](/generated/api/ref/substitute_in_equations) | function | Julia, TypeScript, Go | Apply substitutions across all equations in a model. |
| [`substitute_in_model`](/generated/api/ref/substitute_in_model) | function | TypeScript, Python, Rust, Go | Apply substitution across an ENTIRE model, not just its equations. |
| [`substitute_in_model_with_context`](/generated/api/ref/substitute_in_model_with_context) | function | Rust, Go | `substitute_in_model` with scoped reference resolution. |
| [`substitute_in_reaction_system`](/generated/api/ref/substitute_in_reaction_system) | function | TypeScript, Python, Rust, Go | Apply substitution across all rate expressions in a reaction system. |
| [`substitute_in_reaction_system_with_context`](/generated/api/ref/substitute_in_reaction_system_with_context) | function | Rust, Go | `substitute_in_reaction_system` with scoped reference resolution. |
| [`substitute_with_context`](/generated/api/ref/substitute_with_context) | function | Rust, Go | Substitute variables in an expression with scoped reference resolution (esm-spec §2.3.3). |
| [`expr`](/generated/api/ref/expr) | type | Python, Rust | An expression (esm-spec §4): a numeric literal (`int` or `float`), a variable or parameter reference (`str`), or an operator node (`ExprNode`) whose `args` are themselves… |
| [`expr_node`](/generated/api/ref/expr_node) | type | Python, Go | A node in an expression tree. |
| [`closed_function_error`](/generated/api/ref/closed_function_error) | error | Julia, TypeScript, Rust, Go | Raised by the closed function registry when the spec contract is violated. |
| [`expression_parse_error`](/generated/api/ref/expression_parse_error) | error | Julia, TypeScript, Python, Rust, Go | Thrown when an expression string cannot be parsed by `parse_expression` or `parse_equation`. |

[All topics](/generated/api)
