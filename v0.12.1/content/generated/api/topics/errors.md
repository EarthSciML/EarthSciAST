---
title: "Errors"
description: "The base error type, the parse error, and the table of diagnostic codes shared by every binding. Errors specific to one operation are listed with it."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`error_code_names`](/generated/api/ref/error_code_names) | function | Julia, Rust | Every diagnostic code string in `ERROR_CODES`, sorted. |
| [`earth_sci_ast_error`](/generated/api/ref/earth_sci_ast_error) | error | Julia, Python | Abstract supertype of every exception raised by `EarthSciAST`. |
| [`parse_error`](/generated/api/ref/parse_error) | error | Julia, TypeScript | Exception thrown when JSON parsing fails. |
| [`error_codes`](/generated/api/ref/error_codes) | constant | Julia, TypeScript, Python, Rust | The registry itself: a `NamedTuple` mapping each SCREAMING_SNAKE_CASE name to the stable diagnostic code string it stands for. |

[All topics](/generated/api)
