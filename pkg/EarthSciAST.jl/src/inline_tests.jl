# ===========================================================================
# inline_tests — the §6.6 inline-test runner over `esm_problem` + `solve`.
#
# A document's inline tests (esm-spec §6.6) assert values of its components at
# times: a scalar sample of a state or observed, or (§6.6.5) a REDUCTION of a
# spatial field — `reduce: L2_error | Linf_error` against a `reference` (an
# analytic expression or a `from_file` JSON snapshot), or the pure collapsers
# `integral | mean | max | min` — or a point sample of one via `coords`. Each
# test builds its problem through `esm_problem` under the compiler the caller
# names (`compiler`, default `:native`), solves it with the caller's algorithm
# (or the one the document's stiffness picks), and reads every asserted value
# off the solution through the problem's layout and its observed reader.
#
# Conventions pinned across the Julia, Python and Rust bindings:
#
# 1. `coords` point-sampling — coords values are positions in INDEX space
#    (1-based, fractional allowed) along the named interval index sets;
#    sampling picks the NEAREST grid index, with exact half-way ties rounding
#    DOWN toward the lower index (`idx = ceil(c - 1/2)`). Keys must name the
#    asserted field's index sets; a strict subset pins only when every
#    remaining dimension has exactly one sample; the resolved index must lie
#    in `1:size`. Mutually exclusive with `reduce`.
# 2. `integral` reduce — the uniform-cell Riemann sum under a UNIT total
#    domain measure per axis: `integral = Σ field / N_cells = mean(field)`.
# 3. `from_file` references — `{type: "from_file", path, format?}`: `path`
#    resolves relative to the .esm file's directory (`base_dir`, defaulting
#    to the loaded path's directory, else the working directory); the default
#    and only `format` is "json": a row-major nested JSON array matching the
#    field's shape (a mismatch is an error).
#
# The per-test frame (`_run_test_frame!`: the per-assertion loop, §6.6.4
# tolerance resolution, §6.6.3 pass predicate, wall-time split,
# `AssertionResult`, JUnit) lives in run_tests.jl; this file is the
# `SimulateTestEngine` it drives and the §6.6.5 field evaluation.
# ===========================================================================

"""
    InlineTestError(msg, code = "")

A §6.6.5 inline-test evaluation failed: an ill-formed `coords` / `reduce`
assertion, a `from_file` reference that is missing or shape-mismatched, an
asserted variable with no field, or a per-test discretization injection
(§9.7.10 form C) that could not build. `run_inline_tests` catches it per
assertion and records the message on the failing [`AssertionResult`](@ref).
Fields: `code` (an [`ERROR_CODES`](@ref) value, or `""`) and `msg`.
"""
struct InlineTestError <: EarthSciASTError
    code::String
    msg::String
    InlineTestError(msg::AbstractString, code::AbstractString = "") = new(String(code), String(msg))
end

# Both inline-test runners share one result type, [`AssertionResult`](@ref)
# (run_tests.jl), with one JUnit emitter. For results this runner produces, `container_kind` is `:model` or
# `:reaction_system` after the component the test hangs off (both carry
# `tests`); `file` is the document's path whenever the document came from one —
# on an assertion row as well as on the `<load>` row a batch emits for an
# unreadable file, so every row of a corpus run says which document it is about
# — and `""` for a document handed over as an in-memory `EsmFile`, which has no
# path to carry and which `write_junit_xml(...; file=...)` can label instead;
# and `reduce` / `rtol` / `atol` carry the assertion's declared reduction and
# the resolved §6.6.4 tolerances.


"""
    field_reduce(kind, actual; reference=nothing) -> Float64

Collapse a spatial field to the scalar a §6.6.5 `reduce` assertion compares
(esm-spec §6.6.5):

- `"L2_error"`  — `‖actual − reference‖₂ / ‖reference‖₂` (relative L2 over the
  domain; requires `reference`).
- `"Linf_error"` — `max |actual − reference|` (absolute supremum norm; requires
  `reference`).
- `"integral"` — the uniform-cell Riemann sum under a UNIT total domain
  measure per axis: `Σ field / N_cells`, i.e. exactly `mean`. This is the
  pinned cross-binding convention (the same measure convention under which
  the relative-L2 reduction is measure-free); non-unit physical domains must
  be scaled by the author until the spec grows a measure concept.
- `"mean" | "max" | "min"` — pure collapsers of `actual`.
"""
function field_reduce(
        kind::AbstractString, actual::AbstractVector{<:Real};
        reference::Union{Nothing, AbstractVector{<:Real}} = nothing
    )::Float64
    k = String(kind)
    if k == "L2_error" || k == "Linf_error"
        reference === nothing &&
            throw(ArgumentError("field_reduce: `$(k)` requires a reference field"))
        length(reference) == length(actual) ||
            throw(
            ArgumentError(
                "field_reduce: actual has $(length(actual)) cells " *
                    "but reference has $(length(reference))"
            )
        )
        diff = Float64[Float64(a) - Float64(r) for (a, r) in zip(actual, reference)]
        if k == "L2_error"
            refnorm = sqrt(sum(abs2(Float64(r)) for r in reference))
            refnorm == 0.0 &&
                throw(ArgumentError("field_reduce: L2_error reference has zero norm"))
            return sqrt(sum(abs2, diff)) / refnorm
        end
        return maximum(abs, diff)
    elseif k == "mean" || k == "integral"
        isempty(actual) && throw(ArgumentError("field_reduce: empty field"))
        return sum(Float64(a) for a in actual) / length(actual)
    elseif k == "max"
        return Float64(maximum(actual))
    elseif k == "min"
        return Float64(minimum(actual))
    end
    throw(ArgumentError("field_reduce: unsupported reduce kind '$(k)'"))
end

# The state names an assertion on `variable` of the component at `owner` reads:
# its qualified name, and for an unscoped assertion also the bare name a
# bare-keyed single-model registry carries. Only an exact name matches: a row of
# another component that shares the bare name never answers an assertion
# (`_refuse_unmatched_assertion`).
_assertion_names(owner::AbstractString, variable::AbstractString; scoped::Bool = false) =
    scoped ? String[String(owner) * "." * String(variable)] :
    String[String(owner) * "." * String(variable), String(variable)]

# The flat slot of the first of `names` the layout holds, else of the survivor
# an `operator_compose` renaming match folded the first renamed one onto
# (§4.7.1 step 4): a test is written against the component that owns a state,
# and a merge can fold that state onto another's. Renames are tried LAST, so a
# live row always wins (CONFORMANCE_SPEC §5.35). 0 if none.
function _slot_of(var_map::AbstractDict, names, renames::AbstractDict)::Int
    for n in names
        slot = get(var_map, n, 0)
        slot == 0 || return Int(slot)
    end
    for n in names
        survivor = get(renames, n, nothing)
        survivor === nothing && continue
        return Int(get(var_map, survivor, 0))
    end
    return 0
end

# Flat slot of the SCALAR `variable` of component `model` (unscoped assertion).
_scalar_slot(
    var_map::AbstractDict, variable::AbstractString, model::AbstractString,
    renames::AbstractDict = Dict{String, String}()
) = _slot_of(var_map, _assertion_names(model, variable), renames)

# Flat slot of the SCALAR `variable` of the component at `owner`, under the name
# that component owns only (scoped assertion).
_scoped_scalar_slot(
    var_map::AbstractDict, owner::AbstractString, variable::AbstractString,
    renames::AbstractDict = Dict{String, String}()
) = _slot_of(var_map, _assertion_names(owner, variable; scoped = true), renames)

# The `(cell, slot)` pairs of the array state stored under any of `names`,
# sorted by cell tuple so callers get a deterministic pairing.
function _cells_of(var_map::StateLayout, names)
    return _block_cell_pairs(_ArrayBlock[b for b in _layout_blocks(var_map) if b.name in names])
end
function _cells_of(var_map::AbstractDict, names)
    out = Tuple{Vector{Int}, Int}[]
    for (name, slot) in var_map
        # `_parse_cell_key` is the one inverse of the `"name[i,j]"` encoding.
        parsed = _parse_cell_key(String(name))
        parsed === nothing && continue
        stem, cell = parsed
        stem in names && push!(out, (cell, Int(slot)))
    end
    sort!(out; by = first)
    return out
end

# Every `(cell, slot)` of `blocks`, in slot order and then sorted by cell — the
# order the key-parsing form produces.
function _block_cell_pairs(blocks)
    out = Tuple{Vector{Int}, Int}[]
    for b in blocks
        for slot in b.base:(b.base + b.len - 1)
            push!(out, (_block_cell(b, slot), slot))
        end
    end
    sort!(out; by = first)
    return out
end

# The cells of the ARRAY `variable` of component `model` (unscoped assertion).
_state_cells(var_map::AbstractDict, variable::AbstractString, model::AbstractString) =
    _cells_of(var_map, _assertion_names(model, variable))

# The cells of the ARRAY `variable` of the component at `owner`, under the name
# that component owns only (scoped assertion).
_scoped_state_cells(var_map::AbstractDict, owner::AbstractString, variable::AbstractString) =
    _cells_of(var_map, _assertion_names(owner, variable; scoped = true))

# The state names of OTHER components that carry `variable` as a dotted suffix
# (`NameTable`): the candidates an unmatched unscoped assertion lists. Cell keys
# are reported once, by their stem.
function _assertion_candidates(var_map, variable::AbstractString)
    names = var_map isa StateLayout ?
        vcat(_layout_scalar_names(var_map), String[b.name for b in _layout_blocks(var_map)]) :
        String[String(k) for k in keys(var_map)]
    stems = Set{String}()
    for n in names
        parsed = _parse_cell_key(n)
        push!(stems, parsed === nothing ? n : first(parsed))
    end
    return copy(get(NameTable(stems).by_suffix, String(variable), String[]))
end

# An unscoped assertion whose variable has no exact match in the component
# under test, as a state or as an observed, is refused; a same-named variable
# of another component is named as a candidate, never read.
function _refuse_unmatched_assertion(var_map, a, owner::AbstractString, loc::AbstractString, kind::String)
    cands = _assertion_candidates(var_map, loc)
    msg = "$kind '$(a.variable)' not found in component '$owner'"
    isempty(cands) || (
        msg *= "; a variable of that name exists in another component: " *
            join(cands, ", ") * " (scope the assertion to read it)"
    )
    throw(InlineTestError(msg))
end


# The component a dotted component PATH names, or `nothing` (esm-spec §4.6): the
# first segment is a top-level `models` / `reaction_systems` key and each later
# one a key of its parent's `subsystems`. An unresolved `SubsystemRef` is not a
# component and ends the walk. Identical to the Python `_component_at` and the
# Rust `component_at`.
function _component_at(file::EsmFile, path::AbstractString)
    segs = split(String(path), '.')
    head = String(segs[1])
    comp = file.models === nothing ? nothing : get(file.models, head, nothing)
    if comp === nothing && file.reaction_systems !== nothing
        comp = get(file.reaction_systems, head, nothing)
    end
    for seg in segs[2:end]
        (comp isa Model || comp isa ReactionSystem) || return nothing
        comp = get(comp.subsystems, String(seg), nothing)
    end
    return (comp isa Model || comp isa ReactionSystem) ? comp : nothing
end

# Split an assertion's `variable` into `(owner component path, local name)`.
#
# The schema documents `Assertion.variable` as a local name OR a scoped
# reference, and it resolves by the rule `namespace_expr` already applies to the
# same string in the same component's equations: a dotted name whose HEAD is a
# subsystem key of the asserting component is relative to it (`Leaf.u` in
# `Host` with a `Leaf` subsystem is `Host.Leaf.u`); any other dotted name is
# document-absolute (§4.6). Every per-component lookup then runs against the
# owner, so a mounted leaf's state, observed and declared shape are read from
# the leaf.
#
# A bare name, or a dotted one that walks to no component, is returned
# unchanged against `mname`, and the caller reports it.
# Identical to the Python `_resolve_asserted_name` and the Rust
# `resolve_asserted_name`.
function _resolve_asserted_name(
        file::EsmFile, mname::AbstractString,
        variable::AbstractString
    )
    m = String(mname)
    v = String(variable)
    cut = findlast('.', v)
    cut === nothing && return (m, v)
    prefix = v[1:prevind(v, cut)]
    loc = v[nextind(v, cut):end]
    head = String(split(prefix, '.')[1])
    asserting = _component_at(file, m)
    owner = (asserting !== nothing && haskey(asserting.subsystems, head)) ?
        m * "." * prefix : prefix
    _component_at(file, owner) === nothing && return (m, v)
    return (owner, loc)
end

# Whether `name` occurs FREE in `expr`: as a variable reference not bound by an
# enclosing `faq` / `makearray` loop symbol (`output_idx`, a
# `ranges` key) or an `integral`'s integration variable. A binder shadows the
# name for its whole subtree.
#
# Deliberately NOT `free_variables`: that function also reports a node's `wrt`,
# the symbol a derivative differentiates WITH RESPECT TO. `wrt` is a
# differentiation target named by the node, not a value read from the enclosing
# scope, and it is added AFTER binder subtraction — so a reference containing
# `deriv(u, wrt: "x")` would be wrapped here but by neither the Rust
# `mentions_free` nor the Python `_mentions_free`, which ignore `wrt`. That is
# exactly the kind of cross-binding divergence CONFORMANCE_SPEC §5.30 exists to
# close. Mirrors those two functions.
_mentions_free(::ASTExpr, ::AbstractString) = false
_mentions_free(expr::VarExpr, name::AbstractString) = expr.name == name
function _mentions_free(expr::OpExpr, name::AbstractString)::Bool
    String(name) in _bound_symbols(expr) && return false
    return _anyof(c -> _mentions_free(c, name), child_exprs(expr))
end

# The ARRAY half of the §6.6.5 build-time clash scope: every name the build's
# array registries bind, plus each one's UNAMBIGUOUS bare alias — the same alias
# rule `_param_scope_with_aliases` applies to the scalar half, and the rule under
# which a flattened `M.table` is readable as `table`. Accepts any number of
# name-keyed collections (`insp.const_arrays`, `insp.setup_arrays`), so a binding
# that keeps its build arrays in more than one registry passes all of them.
# The Python (`_array_scope_names`) and Rust (`array_scope_names`) mirrors derive
# the same set.
function _array_scope_names(regs...)::Set{String}
    names = Set{String}()
    for r in regs
        r === nothing && continue
        for k in keys(r)
            push!(names, String(k))
        end
    end
    counts = Dict{String, Int}()
    for n in names
        b = _bare_param_name(n)
        b == n && continue
        counts[b] = get(counts, b, 0) + 1
    end
    out = copy(names)
    for n in names
        b = _bare_param_name(n)
        (b != n && counts[b] == 1 && !(b in out)) && push!(out, b)
    end
    return out
end

# The refusal for a §6.6.5 analytic `reference` that mentions the independent
# variable.
#
# esm-spec §6.6.5 says what a reference may read: the asserted field's DIMENSION
# NAMES, free, plus the model's PARAMETERS. The independent variable is neither.
# It is not rejected by the evaluator either, because a reference is evaluated by
# the BUILD-TIME cellwise evaluator, whose time slot is `0.0` — so a reference of
# `t` would answer with the expression at the start of the span and report a
# plausible wrong number. Refusing names the mistake instead.
#
# For the independent variable `t` the text is BYTE-IDENTICAL in Rust
# (`REFERENCE_MENTIONS_TIME`) and Python (`REFERENCE_MENTIONS_TIME`); the three
# bindings must reject the same document with the same sentence. A document
# that renames its independent variable gets the same sentence with its name.
const _REFERENCE_MENTIONS_TIME = "inline `reference` mentions `t`, which esm-spec §6.6.5 does not admit: a reference's free variables are the field's dimension names, and its other names are the model's parameters. A reference is evaluated at build time, where the independent variable has no value, so `t` would silently read 0 rather than the asserted time."
_reference_mentions_time(iv::AbstractString) =
    iv == "t" ? _REFERENCE_MENTIONS_TIME : replace(_REFERENCE_MENTIONS_TIME, "`t`" => "`$iv`")

"""
    bind_dimension_names(expr, dims, scope=Dict{String,Float64}(),
                         arrays=Set{String}(); independent_variable="t") -> ASTExpr

esm-spec §6.6.5: an inline `reference`'s free variables are the domain DIMENSION
NAMES. For a field shaped over index sets those are the asserted variable's
`shape` entries, each bound at every grid point to the 1-based position along
its axis — the same index space `coords` reads (convention 1) — so
`index(table, lev)` reads the cell's entry of a lookup array and
`sin(pi * (x - 0.5) / N)` is the cell-centre analytic form, with no explicit
gather. A reference that mentions a dimension name FREE (`_mentions_free`, for
which every binder's own loop symbols shadow it) is turned into the whole field
by wrapping it in a `faq` whose output indices ARE the dimension names
(in shape order, each ranging over its index set); one that mentions none — a
literal, a parameter expression, or a `faq` that already produces the
field under its own loop symbols — is returned untouched, so nothing that
evaluated before evaluates differently. Mirrors the Python / Rust
`bind_dimension_names`.

"Nothing that evaluated before evaluates differently" holds only because a
dimension name the BUILD-TIME SCOPE ALREADY BINDS is rejected here: wrapping
would silently shadow that other meaning with the cell's index — the same
expression, a different number, no diagnostic. One name meaning two things in
one scope is an ill-formed document, so it is a fault. esm-spec §6.6.5 makes the
clash scope the WHOLE build-time scope, in two halves:

  * `scope` — the scalar parameter scope (flattened names plus their
    unambiguous bare aliases, `_param_scope_with_aliases`); and
  * `arrays` — the build-time ARRAY names (`_array_scope_names` over
    `insp.const_arrays` / `insp.setup_arrays`), likewise with bare aliases.

The array half is not decorative here: Julia hands `evaluate_cellwise` its
`const_arrays`, so a `const` array named after a shape index set (an array `lev`
over the index set `lev`) is a name the reference could already read, and
checking only the parameter half would rebind it to the cell index in silence.
"""
function bind_dimension_names(
        expr::ASTExpr, dims::AbstractVector{<:AbstractString},
        scope::AbstractDict = Dict{String, Float64}(),
        arrays = Set{String}();
        independent_variable::AbstractString = "t"
    )::ASTExpr
    # esm-spec §6.6.5 names what a reference may read, and the independent
    # variable (`independent_variable`, `t` unless the document renames it) is not on the
    # list. Reaching the evaluator with it is not an error there — the
    # build-time evaluator has a time slot and it holds `0.0` — so without this
    # check a `t`-dependent reference would answer with its value at the start
    # of the span, a plausible wrong number. A reference
    # whose FIELD is shaped over an index set actually named `t` is a different
    # statement: there `t` IS a dimension name, §6.6.5 admits it, and it binds
    # to the cell index below. Checked BEFORE the `isempty(dims)` exit, so a
    # reference on an unshaped target is refused too.
    iv = String(independent_variable)
    (iv in dims || !_mentions_free(expr, iv)) ||
        throw(InlineTestError(_reference_mentions_time(iv)))
    isempty(dims) && return expr
    mentioned = String[String(d) for d in dims if _mentions_free(expr, String(d))]
    isempty(mentioned) && return expr
    clash = findfirst(d -> haskey(scope, d) || d in arrays, mentioned)
    clash === nothing || throw(
        InlineTestError(
            "inline `reference` mentions '$(mentioned[clash])', which is both a dimension " *
                "of the asserted field and a name the build-time scope already binds " *
                "($(haskey(scope, mentioned[clash]) ? "a parameter" : "a build-time array")). " *
                "esm-spec §6.6.5 binds a free dimension name to the cell's 1-based position, " *
                "which would shadow it. Rename one of them, or gather explicitly with " *
                "`aggregate(i from $(mentioned[clash]); …)`."
        )
    )
    names = String[String(d) for d in dims]
    return OpExpr(
        "faq", ASTExpr[];
        output_idx = Any[names...],
        ranges = Dict{String, Any}(d => IndexSetRef(d) for d in names),
        expr_body = expr
    )
end

# The asserted variable's declared spatial shape (ordered index-set names).
# Errors when the variable is missing or scalar — a `coords` assertion is
# ill-formed on a 0-D variable per esm-spec §6.6.5.
function _variable_shape(
        file::EsmFile, mname::AbstractString,
        variable::AbstractString
    )::Vector{String}
    component = _component_at(file, mname)
    model = component isa Model ? component : nothing
    if model === nothing
        # A reaction system declares SPECIES, and a species is 0-D. The answer
        # is therefore the coords-specific rejection, not "model not found":
        # the component exists, and what is ill-formed is asking a scalar for
        # a grid cell.
        component isa ReactionSystem &&
            throw(
            InlineTestError(
                "`coords` requires a spatially-shaped variable; '$(variable)' is scalar"
            )
        )
        throw(InlineTestError("model '$(mname)' not found", ERROR_CODES.UNDEFINED_SYSTEM))
    end
    v = get(model.variables, String(variable), nothing)
    v === nothing && throw(
        InlineTestError(
            "variable '$(variable)' is not declared in model '$(mname)'",
            ERROR_CODES.UNDEFINED_VARIABLE
        )
    )
    (v.shape === nothing || isempty(v.shape)) && throw(
        InlineTestError(
            "`coords` requires a spatially-shaped variable; '$(variable)' is scalar"
        )
    )
    return String[String(s) for s in v.shape]
end

# Resolve a §6.6.5 `coords` map to a concrete 1-based cell tuple over `shape`
# (the field's ordered index-set names), per the pinned cross-binding
# convention: coords values are positions in INDEX space (1-based, fractional
# allowed) along interval index sets; sampling = nearest grid index with exact
# half-way ties rounding DOWN (`idx = ceil(c - 1/2)`). A strict subset of
# dimensions may be pinned only when every remaining dimension is singleton.
function _coords_cell(
        coords::AbstractDict, shape::Vector{String},
        index_sets::AbstractDict
    )::Vector{Int}
    for k in keys(coords)
        String(k) in shape ||
            throw(
            InlineTestError(
                "`coords` names unknown dimension '$(k)' " *
                    "(field dimensions: $(join(shape, ", ")))"
            )
        )
    end
    cell = Int[]
    for s in shape
        iset = get(index_sets, s, nothing)
        (iset !== nothing && iset.kind == "interval" && iset.size !== nothing) ||
            throw(
            InlineTestError(
                "`coords` sampling requires interval index sets " *
                    "with a declared size; '$(s)' is not one"
            )
        )
        n = Int(iset.size)
        if haskey(coords, s)
            c = Float64(coords[s])
            idx = ceil(Int, c - 0.5)  # nearest index; exact ties round DOWN
            (1 <= idx <= n) ||
                throw(
                InlineTestError(
                    "`coords` position $(c) along '$(s)' resolves " *
                        "to index $(idx), outside 1..$(n)"
                )
            )
            push!(cell, idx)
        else
            n == 1 ||
                throw(
                InlineTestError(
                    "`coords` leaves dimension '$(s)' unpinned " *
                        "with $(n) samples; a strict subset pins only when every " *
                        "remaining dimension is singleton"
                )
            )
            push!(cell, 1)
        end
    end
    return cell
end

# Walk a row-major nested JSON array to the value at 1-based `cell`,
# validating each level's extent against `exts` (the field's per-dimension
# extents). The full Cartesian cell sweep visits every node, so ragged or
# mis-sized payloads always surface a shape-mismatch error.
function _nested_at(data, cell::Vector{Int}, exts::Vector{Int})::Float64
    node = data
    for (d, i) in enumerate(cell)
        node isa AbstractVector ||
            throw(
            InlineTestError(
                "from_file reference shape mismatch along " *
                    "dimension $(d): expected a nested array of length $(exts[d])"
            )
        )
        length(node) == exts[d] ||
            throw(
            InlineTestError(
                "from_file reference shape mismatch along " *
                    "dimension $(d): expected length $(exts[d]), found $(length(node))"
            )
        )
        node = node[i]
    end
    (node isa Real && !(node isa Bool)) ||
        throw(
        InlineTestError(
            "from_file reference shape mismatch at cell " *
                "[$(join(cell, ","))]: expected a number"
        )
    )
    return Float64(node)
end

# Load a `{type: "from_file", path, format?}` reference (esm-spec §6.6.5) as
# the per-cell reference field over `cell_tuples`, per the pinned
# cross-binding convention: `path` resolves relative to `base_dir` (the .esm
# file's directory); the default and only v1 `format` is "json" — a row-major
# nested array exactly matching the field's shape.
function _from_file_reference(
        ref::AbstractDict, base_dir::AbstractString,
        cell_tuples::Vector{Vector{Int}}
    )::Vector{Float64}
    fmt_raw = get(ref, "format", nothing)
    fmt = fmt_raw === nothing ? "json" : lowercase(String(fmt_raw))
    fmt == "json" ||
        throw(
        InlineTestError(
            "from_file reference format '$(fmt)' is not supported " *
                "(v1 supports \"json\" only)"
        )
    )
    path_raw = get(ref, "path", nothing)
    path_raw === nothing && throw(InlineTestError("from_file reference is missing `path`"))
    p = String(path_raw)
    resolved = isabspath(p) ? p : joinpath(String(base_dir), p)
    isfile(resolved) ||
        throw(InlineTestError("from_file reference file not found: $(resolved)"))
    data = JSON3.read(read(resolved, String))
    isempty(cell_tuples) &&
        throw(InlineTestError("from_file reference: field has no cells"))
    nd = length(cell_tuples[1])
    exts = Int[maximum(c[d] for c in cell_tuples) for d in 1:nd]
    return Float64[_nested_at(data, c, exts) for c in cell_tuples]
end

"""
    _ephemeral_injected_file(file, source_path, mname, imports, base_dir) -> EsmFile

esm-spec §9.7.10 form C: build a throwaway [`EsmFile`](@ref) in which component
`mname` has the test's `imports` (raw §9.7.2 entries) appended to its own
`expression_template_imports`, so the ordinary import resolver + §9.6.3 fixpoint
lower its rewrite-targets under the test-chosen discretization. The persisted
`file` is never mutated. The raw base is re-read from `source_path` when `input`
was a path (relative `ref`s resolve against its directory), else re-serialized
from the loaded `file` (`base_dir` anchors the injected `ref`s). This is what
lets one test suite exercise a discretization-agnostic PDE leaf under several
schemes with no conflict between tests.
"""
function _ephemeral_injected_file(
        file::EsmFile, source_path::Union{Nothing, AbstractString},
        mname::AbstractString, imports, base_dir::AbstractString
    )::EsmFile
    raw = source_path !== nothing ?
        _to_native_json(JSON3.read(read(String(source_path), String))) :
        serialize_esm_file(file)
    injected = false
    for kind in ("models", "reaction_systems")
        comps = get(raw, kind, nothing)
        comps isa AbstractDict || continue
        haskey(comps, String(mname)) || continue
        comp = comps[String(mname)]
        comp isa AbstractDict || continue
        existing = get(comp, "operator_imports", nothing)
        base = existing === nothing ? Any[] : Any[e for e in existing]
        for e in imports
            push!(base, _to_native_json(e))
        end
        comp["operator_imports"] = base
        injected = true
        break
    end
    injected || throw(
        InlineTestError(
            "component '$(mname)' not found for per-test injection (esm-spec §9.7.10)",
            ERROR_CODES.UNDEFINED_SYSTEM
        )
    )
    f = load_string(JSON3.write(raw); base_path = String(base_dir))
    return resolve_subsystem_refs!(f, String(base_dir))
end

# Relative slack when matching an assertion's `time` against the solver's
# saved time points: `saveat` hits the requested times only to solver/Float64
# precision, so accept the nearest saved point within this relative tolerance
# (scaled by `max(1, |t|)`). 1e-9 sits far above Float64 roundoff accumulation
# yet far below any two distinct assertion times in practice.
const _SAVED_TIME_RTOL = 1.0e-9

# ---------------------------------------------------------------------------
# Per-assertion evaluation — the §6.6.5 scalar-selection / reduction machinery,
# split out of `run_inline_tests` so the driver stays a flat loop. Returns the
# scalar `actual`; throws [`InlineTestError`](@ref) on any spec-relevant failure
# (the driver records it as an `ERROR` result).
# ---------------------------------------------------------------------------
function _evaluate_assertion(
        a, sim, var_map::AbstractDict,
        insp::BuildProducts, eval_file::EsmFile,
        mname::AbstractString,
        resolved_base::AbstractString,
        renames::AbstractDict = Dict{String, String}();
        ctx = nothing, backend_prob = nothing
    )::Float64
    # A solve whose `saveat` lies entirely outside the span saves NOTHING, and
    # `argmin` over the empty trajectory raised `ArgumentError: reducing over an
    # empty collection is not allowed` — an internal Julia message where the
    # other bindings report a §6.6.3 refusal. Same vocabulary as the Rust
    # runner's `time_index`.
    isempty(sim.t) &&
        throw(InlineTestError("no saved state at t=$(a.time) (empty trajectory)"))
    ti = argmin(abs.(sim.t .- a.time))
    abs(sim.t[ti] - a.time) <= _SAVED_TIME_RTOL * max(1.0, abs(a.time)) ||
        throw(InlineTestError("no saved state at t=$(a.time) (nearest $(sim.t[ti]))"))
    state = sim.u[ti]
    # A scoped `variable` reads the component it names (schema
    # `Assertion.variable`); every lookup below runs against that owner.
    owner, loc = _resolve_asserted_name(eval_file, mname, String(a.variable))
    # A scoped name is read ONLY under the name its owner holds; the bare-name
    # fallbacks that serve an unscoped assertion would reach a same-named row
    # of another component.
    scoped = owner != String(mname)

    if a.coords === nothing && a.reduce === nothing
        slot = scoped ? _scoped_scalar_slot(var_map, owner, loc, renames) :
            _scalar_slot(var_map, loc, owner, renames)
        slot == 0 || return state[slot]
        # Not an ODE state — so an OBSERVED, a variable the document defines by
        # an algebraic equation rather than a time derivative, which esm-spec
        # §6.6 makes as assertable as a state (`tests/valid/units_propagation.esm`).
        #
        # `_observed_field` already answers for one: it treats a SHAPELESS
        # observed as rank 0 (one empty cell index) precisely so a contracted
        # scalar is readable, and it puts the trajectory sample in scope, so a
        # state-DEPENDENT observed evaluates at the state the solver had. Same
        # function, same scope, same ordering as the `coords` / `reduce` path
        # below — this is a second entry to it, not a second evaluator.
        obs = _assertion_observed(
            backend_prob, insp, eval_file, owner, loc, ctx, state, Float64(sim.t[ti]), var_map
        )
        obs === nothing && _refuse_unmatched_assertion(var_map, a, owner, loc, "scalar state")
        field, cell_tuples = obs
        # A SHAPED observed named by a bare assertion is a different error from
        # an absent one: §6.6.5 says pick a cell with `coords` or collapse the
        # field with `reduce`, and silently returning element one would answer a
        # question the author did not ask.
        length(field) == 1 || throw(
            InlineTestError(
                "'$(a.variable)' is a field of $(length(field)) cells; a scalar " *
                    "assertion on it needs `coords` or `reduce` (esm-spec §6.6.5)"
            )
        )
        isempty(cell_tuples) || isempty(first(cell_tuples)) || throw(
            InlineTestError(
                "'$(a.variable)' is a shaped variable; a scalar assertion on it " *
                    "needs `coords` or `reduce` (esm-spec §6.6.5)"
            )
        )
        return field[1]
    end

    # `coords` validation runs BEFORE field materialization so a coords
    # assertion on a scalar variable fails with the §6.6.5 coords-specific
    # message.
    coords_target = nothing
    if a.coords !== nothing
        shape = _variable_shape(eval_file, owner, loc)
        coords_target = _coords_cell(a.coords, shape, eval_file.index_sets)
    end

    cells = scoped ? _scoped_state_cells(var_map, owner, loc) :
        _state_cells(var_map, loc, owner)
    local field::Vector{Float64}, cell_tuples::Vector{Vector{Int}}
    if !isempty(cells)
        field = Float64[state[slot] for (_, slot) in cells]
        cell_tuples = [c for (c, _) in cells]
    else
        # No ODE slots: an ARRAY OBSERVED asserted directly (§6.6.5). The
        # trajectory sample at this time is put in scope alongside the build's
        # constants and parameters, so a STATE-DEPENDENT observed evaluates at
        # the state the solver had; a state-free one never reads those names and
        # is unaffected.
        obs = _assertion_observed(
            backend_prob, insp, eval_file, owner, loc, ctx, state, Float64(sim.t[ti]), var_map
        )
        obs === nothing && _refuse_unmatched_assertion(var_map, a, owner, loc, "array state")
        field, cell_tuples = obs
    end

    if coords_target !== nothing
        pos = findfirst(==(coords_target), cell_tuples)
        pos === nothing && throw(
            InlineTestError(
                "no grid sample at cell " *
                    "[$(join(coords_target, ","))] of '$(a.variable)'"
            )
        )
        return field[pos]
    end

    ref = nothing
    if a.reference !== nothing
        if a.reference isa ASTExpr
            # Model parameters (load-time constants) are in scope for a §6.6.5
            # analytic `reference`; state is not. `insp.params` carries the
            # build's resolved scalar params (override-or-default). The field's
            # dimension names are in scope too, bound per cell
            # (`bind_dimension_names`).
            dims = try
                _variable_shape(eval_file, owner, loc)
            catch err
                err isa InlineTestError ? String[] : rethrow()
            end
            scope = _param_scope_with_aliases(insp.params, String(owner))
            # The ARRAY half of the §6.6.5 clash scope: `evaluate_cellwise`
            # binds `const_arrays` by name, so an array named after a shape
            # index set is a name the reference could already read and the
            # wrap would silently rebind it to the cell index (issue #226).
            arrays = _array_scope_names(insp.const_arrays, insp.setup_arrays)
            # THE SPLIT between the model and the test's oracle. Everything above
            # is a value OF THE MODEL and runs under the plan of the compiler that
            # built it. An analytic `reference` is not: it is the expected value
            # the assertion compares against, written as an expression, so it is
            # evaluated by the interpreter whatever compiler is under test — an
            # oracle has no reason to be compiled, and a strict compiler refusing
            # the test's own answer key would be refusing nothing of the model's.
            ref = _with_compiler_plan(_plan(:interpreter)) do
                evaluate_cellwise(
                    bind_dimension_names(
                        a.reference, dims, scope, arrays;
                        independent_variable = _indep_var(eval_file)
                    ),
                    cell_tuples;
                    const_arrays = insp.const_arrays, params = scope
                )
            end
        elseif a.reference isa AbstractDict &&
                string(get(a.reference, "type", "")) == "from_file"
            ref = _from_file_reference(a.reference, resolved_base, cell_tuples)
        else
            throw(InlineTestError("unsupported `reference` shape $(typeof(a.reference))"))
        end
    end
    return field_reduce(a.reduce, field; reference = ref)
end

# The observed `loc` of the component at `owner`, at the sampled `state` and
# time, as `(values, cells)` in row-major cell order, or `nothing` when it is
# not an observed of that component. A compiler that built its own program
# (`backend_prob`, `:mtk`) answers out of its compiled system's observed
# equations, as `observed_field` does; otherwise `_observed_field` reads it.
function _assertion_observed(backend_prob, insp, file, owner, loc, ctx, state, t, var_map)
    backend_prob === nothing && return _observed_field(
        insp, file, owner, loc; ctx = ctx, u = state, t = t, var_map = var_map
    )
    # Any variable the compiled system does not integrate is one of its
    # observeds (its compilation may eliminate a state the document declares).
    model = _component_at(file, owner)
    (model isa Model && haskey(model.variables, loc)) || return nothing
    vals = try
        _backend_observed_field(
            _compiler_backend(backend_prob.f!), backend_prob, owner * "." * loc;
            u = state, t = t
        )
    catch err
        err isa SimulateError || rethrow()
        return nothing
    end
    shape = something(model.variables[loc].shape, String[])
    exts = _shape_extents(insp, file, shape)
    cells = (exts === nothing || prod(exts; init = 1) != length(vals)) ?
        [Int[i] for i in eachindex(vals)] : _row_major_cells(exts)
    return (vals, cells)
end

# esm-spec §9.7.10 form C: resolve the file test `t` runs against. A test
# that injects a discretization runs against an EPHEMERAL instance of
# component `mname` with the test's imports appended to its scope and its
# rewrite-targets lowered; the persisted `file` is never mutated. A test with
# no injection runs against the file as loaded. Returns an `_EngineFailure`
# when the ephemeral build could not be built.
function _resolve_test_target(
        file::EsmFile, input, mname::AbstractString, t,
        resolved_base::AbstractString
    )::Union{EsmFile, _EngineFailure}
    isempty(t.expression_template_imports) && return file
    try
        src = input isa AbstractString ? String(input) : nothing
        return _ephemeral_injected_file(
            file, src, String(mname),
            t.expression_template_imports, resolved_base
        )
    catch err
        _is_resource_error(err) && rethrow()
        return _EngineFailure("per-test discretization injection failed: ", err)
    end
end

# ---------------------------------------------------------------------------
# Simulate engine — the tree-walk execution strategy plugged into the unified
# per-test frame (`_run_test_frame!`, run_tests.jl). Per test: resolve the
# §9.7.10 form-C injection target, `solve` with the assertion times as
# `saveat`, then evaluate each assertion against the saved fields. The solve
# flattens the file (models + coupling) into ONE runnable system named
# "Flattened", so no model_name is passed; element names keep their
# owning-model prefix, which the `_state_cells` / `_scalar_slot` lookups
# resolve per assertion.
# ---------------------------------------------------------------------------
struct SimulateTestEngine
    file::EsmFile            # document as loaded
    input::Any               # original `run_inline_tests` input (path or EsmFile)
    mname::String
    resolved_base::String
    alg::Any
    reltol::Float64
    abstol::Float64
    # Caller-supplied SEEDS from an `InlineTestOptions` (empty when there is
    # none). They sit BENEATH each test's own maps — see `_engine_setup`.
    seed_p::AbstractDict
    seed_u0::AbstractDict
    # Which compiler builds each test's problem (API_SPEC §5.8). A runner that
    # could not name one could only ever exercise the default, which is the
    # single compiler a compiler-agreement fixture has no need to re-check.
    compiler::Symbol
    # `file` loaded, checked and flattened once for every test that runs
    # against it (`_prepare_tests_document`), or why that failed.
    prep::Union{PreparedRun, _EngineFailure}
end

# Per-test handle: the successful simulation plus the build-observability sink
# (assertions on ARRAY OBSERVEDS evaluate their resolved expression from
# `insp` — see `_observed_field`) and the file the assertions resolve shapes
# against (the ephemeral injected file when the test injects a discretization).
struct _SimulateHandle
    sim::Any                      # the SciML solution `solve(prob, alg)` returned
    var_map::AbstractDict{String, Int}     # state-element name → flat index (from the problem)
    insp::BuildProducts
    eval_file::EsmFile
    # The states an `operator_compose` renaming match DELETED, mapped onto the
    # survivors (issue #230). An assertion names its component's LOCAL variable,
    # which a merge may have folded onto another component's.
    merged_renames::Dict{String, String}
    # The compiler that built the problem. Every model-side value an assertion
    # reads is evaluated under this compiler's plan (esm-libraries-spec
    # §2.5.10), so a strict build refuses here exactly what it refuses at
    # `observed_field(prob, name)`.
    compiler::Symbol
    # The problem's compiled-observed-program context (observed_program.jl):
    # an assertion on an observed reads it through the same program
    # `observed_field(prob, name; u, t)` runs.
    ctx::Any
    # The problem, for a compiler that built its own program (`:mtk`), whose
    # observeds live in its compiled system; `nothing` otherwise.
    backend_prob::Union{Nothing, EsmProblem}
end

# The §6.6 stand-in for a solution when the document has NOTHING TO INTEGRATE:
# the asserted times, an empty state vector at each, and a successful retcode.
#
# A document whose equations are all algebraic declares no state, and handing
# its zero-length `u0` to an ODE integrator is not a degenerate solve that
# returns the initial state — OrdinaryDiffEq's dense interpolant reads element
# one of the state and throws `BoundsError: attempt to access 0-element
# Vector{Float64} at index [1]` as soon as a saved time is not the span's start.
# Such a document's answers are its OBSERVED graph, which
# `_evaluate_assertion` already evaluates out of the build's `BuildProducts` with `t`
# bound to the sampled time, so the runner needs nothing from a solver here
# except the time grid — which is exactly what this carries. Duck-typed on `.t`
# / `.u` / `.retcode`, the three members `_evaluate_assertion` and
# `_engine_setup` read, so this file stays solver-free.
struct _StaticSolution
    t::Vector{Float64}
    u::Vector{Vector{Float64}}
    retcode::Symbol
end

_static_solution(times::Vector{Float64}) =
    _StaticSolution(times, [Float64[] for _ in times], :Success)

# The times a document with NOTHING TO INTEGRATE is evaluated at: the asserted
# times inside the declared span, plus the span's own endpoints.
#
# esm-spec §6.6.3 constrains an assertion's `time` to `[time_span.start,
# time_span.end]`. An INTEGRATED document enforces that incidentally — the
# trajectory stops at the span's end, so an assertion past it is refused by the
# saved-time lookup in `_evaluate_assertion` — and Python's runner, which
# samples a dense grid over the span, refuses the same assertion on a STATIC
# document too. A static evaluation has no boundary of its own: evaluating the
# observed graph at whatever number the assertion names would answer `t = 100`
# on a span of `[0, 1]` and report a PASS, a plausible wrong number, and would
# put this binding on a different verdict from Python for one document.
#
# The endpoints are kept whatever the assertions say, so that the refusal names
# the span ("nearest 1.0") instead of reducing over an empty collection, and so
# that a test whose asserted times are ALL out of span — or which has no
# assertions at all — still produces a well-formed evaluation.
function _static_evaluation_times(
        times::AbstractVector{<:Real},
        tstart::Real, tstop::Real
    )::Vector{Float64}
    lo, hi = minmax(Float64(tstart), Float64(tstop))
    out = Float64[lo, hi]
    for x in times
        lo <= x <= hi && push!(out, Float64(x))
    end
    return sort!(unique!(out))
end

# Qualify a test's override keys with the component that OWNS the test.
#
_overrides_or_empty(o) = o === nothing ? Dict{String, Any}() : o

# Lay a caller's SEED under a test's own override map (esm-spec §6.6.2). The
# document is authoritative about its own test, so the test's key wins; the
# seed only supplies what the document left unsaid.
#
# The merge happens BEFORE `_scope_to_component`, so a seed key and a test key
# naming the same variable collide on the one spelling. Merging afterwards
# would instead hand `esm_problem` both `T` and `M.T` — two keys designating
# one parameter, with two values.
function _seeded_overrides(seed::AbstractDict, authored)
    isempty(seed) && return authored
    out = Dict{String, Any}()
    for (k, v) in seed
        out[String(k)] = v
    end
    authored === nothing && return out
    for (k, v) in authored
        out[String(k)] = v
    end
    return out
end

# esm-spec §6.6.2 keys `parameter_overrides` / `initial_conditions` by LOCAL
# name — local to the ENCLOSING component, since a test "exercises one model in
# isolation" (§6.6). The runner hands them to `esm_problem`, which resolves against
# the WHOLE flattened document, where that locality is gone: two mounted
# components that each declare a `T` flatten to `M1.T` / `M2.T`, and the bare
# `T` in `M2`'s test is then AMBIGUOUS document-wide even though it is
# unambiguous where it was written.
#
# So re-attach the scope the runner still knows: a key whose `<model>.<key>`
# form names a real variable of the flattened system is rewritten to it. A key
# that does not (already qualified, a scoped reference the prefix would double
# up, or simply wrong) passes through untouched, so `esm_problem` reports on it
# exactly as it would have.
#
# `scope` is `_test_name_scope(target)`: the flattened system's parameter and
# state names and its merged renames, or `nothing` when the target does not
# flatten (the keys then pass through and `esm_problem` reports the failure).
function _scope_to_component(overrides, mname, scope)
    (overrides === nothing || isempty(overrides) || scope === nothing) && return overrides
    known, renames = scope
    # `Any`-valued: esm-spec §6.6.2 admits a scalar or INLINE ARRAY DATA (a
    # shaped variable's whole column), and re-scoping must not flatten the
    # second to a number.
    out = Dict{String, Any}()
    for (rawk, v) in overrides
        k = String(rawk)
        q = string(mname, ".", k)
        # An `operator_compose` renaming match may have DELETED the very name
        # this component's test keys on (§4.7.1 step 4): `Sink.O3` folded onto
        # `Chem.ozone` leaves the scoped spelling naming nothing. Resolve it onto
        # the survivor instead (CONFORMANCE_SPEC §5.35).
        out[q in known ? q : get(renames, q, k)] = v
    end
    return out
end

function _test_name_scope(target::Union{EsmFile, PreparedRun, _EngineFailure})
    target isa _EngineFailure && return nothing
    flat = target isa PreparedRun ? target.flat : try
            flatten(target)
    catch err
            err isa EarthSciASTError || rethrow()
            return nothing
    end
    known = union(
        Set{String}(String(n) for n in keys(flat.parameters)),
        Set{String}(String(n) for n in keys(flat.state_variables))
    )
    return (known, flat.metadata.merged_variable_renames)
end

# `file` loaded, checked and flattened once for all of its tests: the
# document-level refusals and `flatten`, without a compiler's own refusals,
# which each test's `esm_problem` applies to the prepared run. A failure is
# every such test's failure, reported as its build would have reported it.
function _prepare_tests_document(file::EsmFile)
    return try
        _prepare_run(file; refuse_file = (_, _) -> nothing, refuse_flat = _ -> nothing)
    catch err
        _is_resource_error(err) && rethrow()
        _EngineFailure("simulation failed: ", err)
    end
end

function _engine_setup(e::SimulateTestEngine, t)
    target = _resolve_test_target(e.file, e.input, e.mname, t, e.resolved_base)
    target isa _EngineFailure && return target   # injection failed
    times = sort!(unique(Float64[a.time for a in t.assertions]))
    local prob, sim
    try
        p = _seeded_overrides(e.seed_p, t.parameter_overrides)
        u0 = _seeded_overrides(e.seed_u0, t.initial_conditions)
        # The target is flattened for the scope only when a key needs one.
        scope = (isempty(something(p, ())) && isempty(something(u0, ()))) ? nothing :
            _test_name_scope(target === e.file ? e.prep : target)
        # A test with no injection runs against the document prepared once.
        if target === e.file
            e.prep isa _EngineFailure && return e.prep
            input = e.prep
        else
            input = target
        end
        prob = esm_problem(
            input, (t.time_span.start, t.time_span.stop);
            p = _overrides_or_empty(_scope_to_component(p, e.mname, scope)),
            u0 = _scope_to_component(u0, e.mname, scope),
            compiler = e.compiler
        )
        # A document with NOTHING TO INTEGRATE is EVALUATED, not solved.
        #
        # esm-spec §6.6.3 defines an assertion's `time` as "Simulation time at
        # which to evaluate the assertion; must lie in `[time_span.start,
        # time_span.end]`": it constrains the value and says *evaluate*, not
        # *integrate to*. An algebraic document is still a function of `t` — the
        # diurnal solar-geometry component that found this is declination, hour
        # angle and zenith cosine, all algebraic in `t` — and
        # `_evaluate_assertion` binds `t` to each sampled time before reading
        # the observed graph, so every asserted time answers on its own terms.
        # The grid is restricted to the declared span, because the same clause
        # says the time "must lie in `[time_span.start, time_span.end]`" and a
        # static evaluation is the one path with no boundary of its own
        # (`_static_evaluation_times`).
        sim = isempty(prob.u0) ?
            _static_solution(
                _static_evaluation_times(
                    times, t.time_span.start,
                    t.time_span.stop
                )
            ) :
            _solve_problem(
                prob, e.alg; reltol = e.reltol, abstol = e.abstol,
                saveat = times
            )
    catch err
        _is_resource_error(err) && rethrow()
        return _EngineFailure("simulation failed: ", err)
    end
    # `retcode` is a SciML `ReturnCode` (§2.5.3); compare it by name so this
    # core file stays solver-free.
    Symbol(sim.retcode) === :Success ||
        return _EngineFailure("solver retcode $(sim.retcode)", nothing)
    return _SimulateHandle(
        sim, prob.var_map, prob.build.products, target,
        Dict{String, String}(prob.merged_renames),
        compiler(prob), _obs_ctx(prob),
        _compiler_backend(prob.f!) === nothing ? nothing : prob
    )
end

# Under the plan of the compiler that BUILT the problem, not the process default:
# the observeds and states an assertion reads are evaluations of the model, and
# §2.5.10 puts every one of them under that compiler's refusal rule.
_engine_actual(e::SimulateTestEngine, h::_SimulateHandle, a) =
    _with_compiler_plan(_plan(h.compiler)) do
    _evaluate_assertion(
        a, h.sim, h.var_map, h.insp, h.eval_file, e.mname,
        e.resolved_base, h.merged_renames; ctx = h.ctx, backend_prob = h.backend_prob
    )
end

_engine_error_message(::SimulateTestEngine, err) =
    "assertion evaluation failed: $(sprint(showerror, err))"

"""
    InlineTestOptions(; model_name=nothing, alg=nothing, reltol=nothing,
                      abstol=nothing, base_dir=nothing,
                      initial_conditions=nothing, parameter_overrides=nothing)

Per-document overrides for [`run_inline_tests`](@ref), returned by its
`options_for` callback.

Every field is optional, and a field left `nothing` INHERITS the value passed
to `run_inline_tests` itself — so a callback that cares about one document's
solver and nothing else returns `InlineTestOptions(alg=Rodas5())` and the rest
of the run is unchanged.

This record exists so that site-specific policy stays at the site. A CI gate
over a model corpus routinely carries basename-keyed tables — a stiff-solver
map, an initial-condition seed for the documents whose tests do not state one
— and each of those is a reason the gate could not call the library entry and
re-implemented esm-spec §6.6 instead. One callback absorbs all of them without
this module learning anything about the corpus.

`initial_conditions` / `parameter_overrides` are SEEDS: they are laid BENEATH
each test's own maps, so a test that states a value keeps it and a test that is
silent gets the caller's. They are merged with the test's map before
`_scope_to_component` runs, and so are keyed and resolved exactly like a test's
own keys — which is what makes the precedence well defined.
"""
Base.@kwdef struct InlineTestOptions
    model_name::Union{Nothing, AbstractString} = nothing
    alg::Any = nothing
    reltol::Union{Nothing, Float64} = nothing
    abstol::Union{Nothing, Float64} = nothing
    base_dir::Union{Nothing, AbstractString} = nothing
    initial_conditions::Union{Nothing, AbstractDict} = nothing
    parameter_overrides::Union{Nothing, AbstractDict} = nothing
    # Which compiler builds this document's problems (API_SPEC §5.8); `nothing`
    # defers to the `run_inline_tests` keyword, which itself defaults to the
    # strict `:native`.
    compiler::Union{Nothing, Symbol} = nothing
end

# The document's TEST-BEARING components, models first and then reaction
# systems, each in the document's own key order.
#
# esm-spec §6.6 hangs `tests` off a component, and the schema gives
# `reaction_systems` the same `tests` / `tolerance` members it gives `models`.
# Both maps are walked: a component with no rows and a component that was
# never looked at are indistinguishable in the result list.
#
# Reaction-system species are 0-D, so their assertions take the pointwise
# (scalar-slot) form; nothing about the build changes, because the whole
# document is flattened either way and a species becomes an ordinary state.
function _test_components(file::EsmFile, model_name)
    out = Tuple{String, Symbol, Any}[]
    for (kind, container) in (
            (:model, file.models),
            (:reaction_system, file.reaction_systems),
        )
        container === nothing && continue
        for (name, component) in container
            model_name !== nothing && String(name) != String(model_name) && continue
            isempty(component.tests) && continue
            push!(out, (String(name), kind, component))
        end
    end
    return out
end

# Resolve `run_inline_tests`' `inputs` to a flat vector of documents: a path
# stays a path, a directory expands to the `.esm` files under it, an `EsmFile`
# stays itself. An `AbstractString` and an `EsmFile` are SINGLE inputs — neither
# is iterated element-wise.
function _expand_inputs(inputs)
    items = (inputs isa AbstractString || inputs isa EsmFile) ? Any[inputs] :
        (
            applicable(iterate, inputs) ? collect(Any, inputs) :
            throw(
                ArgumentError(
                    "run_inline_tests expects a path, an EsmFile, a " *
                    "directory or an iterable of those, got $(typeof(inputs))"
                )
            )
        )
    out = Any[]
    for item in items
        if item isa EsmFile
            push!(out, item)
        elseif item isa AbstractString
            p = String(item)
            isdir(p) ? append!(out, discover_esm_files([p]; root = p, exclude = String[])) :
                push!(out, p)
        else
            throw(ArgumentError("run_inline_tests: $(typeof(item)) is not a path or EsmFile"))
        end
    end
    return out
end

# The one ERROR row a document that could not be LOADED contributes to a batch.
# A corpus run must not lose a file to one bad document, and must not lose it
# SILENTLY either — a document that vanishes from the result list is
# indistinguishable from one that passed.
_load_failure_result(path::AbstractString, err) = AssertionResult(
    String(path), :file, "<parse>", "<load>", 0, "", NaN, NaN, nothing,
    ERROR, "load failed: $(sprint(showerror, err))", 0.0, nothing, 0.0, 0.0,
    _result_code(err)
)

# Fold one document's `InlineTestOptions` onto the call-level defaults: a field
# the override left `nothing` inherits, every other field wins.
_opt_or(::Nothing, _field, fallback) = fallback
_opt_or(o::InlineTestOptions, field::Symbol, fallback) =
    (v = getfield(o, field); v === nothing ? fallback : v)
_opt_dict(::Nothing, _field) = Dict{String, Any}()
_opt_dict(o::InlineTestOptions, field::Symbol) =
    (v = getfield(o, field); v === nothing ? Dict{String, Any}() : v)

"""
    run_inline_tests(inputs; model_name=nothing, alg=nothing, reltol=nothing,
                     abstol=nothing, base_dir=nothing, compiler=:native,
                     options_for=nothing)
        -> Vector{AssertionResult}

Run every inline test (esm-spec §6.6, including the §6.6.5 field assertions) of
the selected component(s) of `inputs` through [`esm_problem`](@ref) and `solve`,
and return one [`AssertionResult`](@ref) per assertion, carrying the actual
value alongside pass/fail.

`inputs` is a path to a `.esm` file, a loaded [`EsmFile`](@ref), a directory
(walked recursively for `*.esm`, sorted), or any iterable of those. Results are
concatenated in input order; `models` run before `reaction_systems`.

Per test: `solve(esm_problem(input, (time_span.start, time_span.stop); compiler),
alg; reltol, abstol, saveat=<assertion times>)` with the test's
`initial_conditions` / `parameter_overrides` applied. Each assertion then reads
the asserted variable at its time: a scalar sample, a point sample per `coords`
(1-based index space, nearest index, exact ties rounding down), or a reduction
per `reduce` (error norms against a `reference`: an analytic expression,
evaluated with [`evaluate_cellwise`](@ref), or a
`{type: "from_file", path, format?}` JSON snapshot resolved against `base_dir`).
`base_dir` defaults to the `.esm` file's directory, else the working directory.

Assertion tolerances resolve per field over four levels (esm-spec §6.6.4:
assertion > test > model > `rel=1e-6`), and the pass predicate, wall-time
accounting and JUnit output ([`write_junit_xml`](@ref)) are those of
[`run_esm_tests`](@ref) (both runners share `_run_test_frame!`).

Keywords:
* `alg` — the ODE algorithm for every document. Left `nothing`, each document
  gets `Rosenbrock23` when it declares `solver.stiffness: "high"` (esm-spec §2.2),
  else `Tsit5`; that needs OrdinaryDiffEqRosenbrock or OrdinaryDiffEqTsit5
  loaded, and a document with tests and no available solver raises an
  `ArgumentError`.
* `reltol` / `abstol` — integration tolerances (not the assertion tolerances
  above). Each resolves most-specific first: an `options_for` override, this
  keyword, the document's `solver.reltol` / `solver.abstol`, then
  `DEFAULT_TEST_RELTOL` / `DEFAULT_TEST_ABSTOL`.
* `compiler` — passed to `esm_problem` for every test.
* `options_for` — called once per document, before it is loaded, with its path
  (or the `EsmFile` when there is none); returns an [`InlineTestOptions`](@ref)
  whose non-`nothing` fields override the keywords for that document, or
  `nothing`.

A document that fails to load throws when `inputs` names a single document; in
a batch (an iterable or a directory) it contributes one error row naming the
path instead. `r.file` is the path each row's document was loaded from (`""`
for an in-memory `EsmFile`).
"""
function run_inline_tests(
        inputs; model_name::Union{Nothing, AbstractString} = nothing,
        alg = nothing,
        reltol::Union{Float64, Nothing} = nothing,
        abstol::Union{Float64, Nothing} = nothing,
        base_dir::Union{Nothing, AbstractString} = nothing,
        compiler::Symbol = :native,
        options_for = nothing
    )
    documents = _expand_inputs(inputs)
    batch = !(
        (inputs isa EsmFile) ||
            (inputs isa AbstractString && !isdir(String(inputs)))
    )
    results = AssertionResult[]
    for document in documents
        o = options_for === nothing ? nothing : options_for(document)
        (o === nothing || o isa InlineTestOptions) || throw(
            ArgumentError(
                "options_for must return an InlineTestOptions or nothing, got $(typeof(o))"
            )
        )
        file = document
        if document isa AbstractString
            file = try
                load_path(String(document))
            catch err
                batch || rethrow()
                push!(results, _load_failure_result(document, err))
                continue
            end
        end
        file isa EsmFile || throw(
            ArgumentError(
                "run_inline_tests expects a path or EsmFile, got $(typeof(document))"
            )
        )
        _run_document_tests!(
            results, file, document, o;
            model_name, alg, reltol, abstol, base_dir, compiler
        )
    end
    return results
end

# Run one document's inline tests, appending to `results`. `document` is the
# path it was loaded from, or the `EsmFile` itself — it anchors `from_file`
# references and the §9.7.10 per-test injection. The per-document body of
# `run_inline_tests`.
function _run_document_tests!(
        results, file::EsmFile, document, o;
        model_name, alg, reltol, abstol, base_dir, compiler
    )
    d_model_name = _opt_or(o, :model_name, model_name)
    # Resolved BEFORE anything is picked or built for this document, because a
    # document with no tests is most of a corpus and must cost nothing — and,
    # more sharply, must not be able to fail: picking a solver for it below can
    # throw when no OrdinaryDiffEq package is loaded, and a document with
    # nothing to integrate has no business demanding an integrator.
    components = _test_components(file, d_model_name)
    isempty(components) && return results
    d_alg = _opt_or(o, :alg, alg)
    if d_alg === nothing
        # Nobody named an algorithm, so the DOCUMENT's own stiffness
        # declaration chooses one (esm-spec §2.2: `stiffness` is advisory and a
        # binding MAY select an implicit / BDF-family integrator on `"high"`;
        # §2.2.3 is why the document cannot simply name the algorithm itself —
        # an algorithm name is not portable, so the block has no `alg` field).
        # The pick goes through the same `_pick_solver` the MTK runner uses, so
        # the two Julia runners answer a stiff document with the same
        # integrator instead of one of them hitting `MaxIters`. (Python's
        # `_method_for` has always done this; this binding required an `alg`
        # from the caller, and a corpus gate can only pass ONE for every
        # document, which makes a stiff one unrunnable there.)
        d_alg, _ = _pick_solver(
            document isa AbstractString ? String(document) : "";
            stiffness = (
                file.solver === nothing ? nothing :
                    file.solver.stiffness
            )
        )
    end
    # esm-spec §2.2.2, most-specific first: an `options_for` override, then the
    # keyword, then THIS DOCUMENT's `solver` block, then the runner defaults
    # (which `_test_integration_tolerances` supplies as its own fallback). A
    # `nothing` at either of the first two levels is what lets the next one
    # speak. INTEGRATION tolerances; the §6.6.4 assertion tolerance is separate.
    doc_reltol, doc_abstol = _test_integration_tolerances(file.solver)
    d_reltol = Float64(_opt_or(o, :reltol, reltol === nothing ? doc_reltol : reltol))
    d_abstol = Float64(_opt_or(o, :abstol, abstol === nothing ? doc_abstol : abstol))
    d_base_dir = _opt_or(o, :base_dir, base_dir)
    seed_p = _opt_dict(o, :parameter_overrides)
    seed_u0 = _opt_dict(o, :initial_conditions)
    resolved_base = d_base_dir !== nothing ? String(d_base_dir) :
        (document isa AbstractString ? dirname(abspath(String(document))) : pwd())
    # The row's `file` is the document it came from, so a BATCH's results say
    # which document each row is about — the same field the MTK runner fills,
    # and the only thing that made a corpus run's rows tellable apart. It was
    # `""` while this entry ran one document at a time; a load failure has
    # always named its path (`_load_failure_result`), so the empty string also
    # made the failures of a document inconsistent with each other.
    source = document isa AbstractString ? String(document) : ""
    d_compiler = _opt_or(o, :compiler, compiler)
    prep = _prepare_tests_document(file)
    for (mname, kind, component) in components
        engine = SimulateTestEngine(
            file, document, mname, resolved_base,
            d_alg, d_reltol, d_abstol, seed_p, seed_u0,
            d_compiler, prep
        )
        _run_test_frame!(
            results, engine, source, kind, mname,
            component.tolerance, component.tests
        )
    end
    return results
end
