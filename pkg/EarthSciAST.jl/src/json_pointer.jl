# JSON pointers (RFC 6901), as diagnostics address a document.

# One reference token, with `~` and `/` escaped (RFC 6901 §4).
_ptr_escape(seg::AbstractString) = replace(replace(seg, "~" => "~0"), "/" => "~1")

"""
    _pointer(base, segments...) -> String

The JSON pointer `base` extended by each segment: a string (or symbol) is an
object key, escaped by `_ptr_escape`; an integer is a 1-based Julia position,
written as its 0-based array index. The one place a diagnostic pointer gains a
segment, so no caller escapes a name or subtracts one itself.
"""
_pointer(base::AbstractString) = String(base)
_pointer(base::AbstractString, seg, rest...) = _pointer(_ptr_append(base, seg), rest...)

_ptr_append(base::AbstractString, seg::AbstractString) = string(base, "/", _ptr_escape(seg))
_ptr_append(base::AbstractString, seg::Symbol) = _ptr_append(base, String(seg))
_ptr_append(base::AbstractString, i::Integer) = string(base, "/", i - 1)
