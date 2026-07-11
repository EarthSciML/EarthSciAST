# Shared Core.eval macro-invocation scaffold for programmatic variable
# creation. Included by BOTH EarthSciASTMTKExt and EarthSciASTCatalystExt,
# whose seven `_make_*` constructors previously each spelled out the same
# bindings-block / let-wrap / `Core.eval` / `vars[1]` dance by hand.

"""
    _eval_var_macro(mod, macro_sym, call_args...; bindings=()) -> variable

Invoke a Symbolics-family variable-declaration macro (`@variables` /
`@parameters` / `@species`) at runtime via `Core.eval` in `mod`. The macros
insist on literal identifiers, so programmatic variable creation has to
assemble the call AST and evaluate it; evaluating in `mod` (Symbolics /
ModelingToolkit / Catalyst) keeps us robust to internal type-parameter
changes across versions — only the macro's public surface is used.

`call_args` are the macro's argument expressions: a bare name `Symbol`, a
`name(iv...)` call `Core.Expr`, a metadata vector `Core.Expr`, ….

`bindings` (`holder_name => value` pairs) wrap the macro call in a `let`
block so live symbolic objects (e.g. independent variables) can be passed
by value into the macro's scope under invented placeholder identifiers:

```
let
    holder1 = value1
    ...
    @variables name(holder1, ...)
end
```

Returns the first element of the vector the macro returns.
"""
function _eval_var_macro(mod::Module, macro_sym::Symbol, call_args...;
                         bindings=())
    mc = Core.Expr(:macrocall, macro_sym, LineNumberNode(0), call_args...)
    binds = [Core.Expr(:(=), name, val) for (name, val) in bindings]
    block = Core.Expr(:block, binds..., mc)
    vars = Core.eval(mod, Core.Expr(:let, Core.Expr(:block), block))
    return vars[1]
end
