# Helpers that keep compiled code valid when other packages load.
#
# Code cached in this package's image carries backedges to every method it was
# inferred to call. When a package loaded later (SciMLBase, the OrdinaryDiffEq
# solvers, ForwardDiff, ModelingToolkit) adds a method that one of those calls
# could now reach, the cached code is discarded and compiled again on first
# use. The calls most exposed to this are Base generics inferred with abstract
# argument types, because new array and number types keep adding methods that
# match them. The helpers below avoid the two patterns that cost the most here.

# `any(f, xs)` / `all(f, xs)` as a plain loop, specialized on `f` and `xs`.
#
# Base's `any(f::Function, ::AbstractArray; dims = :)` does not specialize on
# `f`, and it passes `dims` on through an unspecialized `Function`-typed slot.
# In a recursive predicate (a tree walk asking "does any child ...?") inference
# meets the recursion with that widened signature and resolves the call through
# Base's dimensional `mapreduce` machinery on an abstract array, which the
# StaticArrays, SparseArrays and RecursiveArrayTools methods the solver stack
# brings invalidate. A loop has no such call to resolve. Use these in recursive
# walkers and wherever `f` or `xs` is not concretely inferred.
@inline function _anyof(f::F, xs) where {F}
    for x in xs
        f(x) && return true
    end
    return false
end

@inline function _allof(f::F, xs) where {F}
    for x in xs
        f(x) || return false
    end
    return true
end

# `count(f, xs)` as a plain loop, for the same reason.
@inline function _countof(f::F, xs) where {F}
    n = 0
    for x in xs
        f(x)::Bool && (n += 1)
    end
    return n
end

# `x` as type `T`: itself when it already is one, otherwise `convert(T, x)`
# through a dynamic call. For values read out of `Dict{String, Any}` JSON, where
# a statically inferred `convert(T, ::Any)` would be resolved into Base's
# abstract array and range conversions and invalidated with them; the dynamic
# call leaves no backedge into `convert`'s method table.
@inline _as_type(::Type{T}, x) where {T} = x isa T ? x : _convert_dynamic(T, x)

# A constructor argument as the type of the field `f` of `T` it fills, for an
# inner constructor whose `new` would otherwise convert an `Any`-typed value.
Base.@constprop :aggressive @inline _field(::Type{T}, f::Symbol, x) where {T} =
    _as_type(fieldtype(T, f), x)

@noinline _convert_dynamic(::Type{T}, @nospecialize(x)) where {T} =
    Base.invokelatest(convert, T, x)::T

# `f(args...)` through a dynamic call that inference does not look into. For
# small helpers handed values whose type the caller cannot infer (document
# content read from `Dict{String, Any}`): inferred for an abstract argument
# type, their bodies resolve Base calls on abstract arrays that later packages
# invalidate, and the invalidation then reaches every caller. Called this way
# the caller keeps no backedge into them; at run time the call dispatches on the
# concrete argument types, whose specializations are backed by concrete methods
# only. Assert the result type at the call site, since inference sees `Any`.
@inline _dynamic(f::F, args...) where {F} = Base.inferencebarrier(f)(args...)
