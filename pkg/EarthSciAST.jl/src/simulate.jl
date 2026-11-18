# ===========================================================================
# EsmProblem — the ESM simulation Problem, and its SciML plumbing.
#
# esm-libraries-spec §2.5: a run is TWO steps, one noun and one verb.
#
#     prob = esm_problem(input, tspan; p, u0, providers, …)   # build once
#     sol  = solve(prob, alg; abstol, reltol, saveat, …)      # run per knob set
#
# Construction absorbs the whole deterministic-per-document pipeline (load →
# flatten → shape transforms → pushdown rewrite → value invention → the gated
# fetch of provider data → `_build_evaluator`), plus the run wiring that belongs
# to the DOCUMENT rather than to a particular run: the initial state, the
# data-refresh callback, the output-sink callback and the checkpoint callback.
# `solve` varies only the per-run knobs.
#
# EarthSciAST never depends on a solver. Everything here — coerce → _build_evaluator → seed → compose callbacks — is
# solver-free, so CONSTRUCTING an `EsmProblem` needs no SciMLBase and no
# OrdinaryDiffEq (§2.5.9). The `ODEProblem` + `solve` live in a SciMLBase
# package EXTENSION (EarthSciASTSimulateExt), which specializes
# `SciMLBase.__init` / `SciMLBase.__solve` on `EsmProblem` so the STANDARD
# SciML entry points — `solve`, `init`, `step!`, `solve!`, `remake`,
# `EnsembleProblem` — work on it directly. A solution is therefore a real
# `ODESolution`: its `retcode` is a real `SciMLBase.ReturnCode`, and it is
# indexed BY NAME through SymbolicIndexingInterface (§2.5.7):
#
#     sol[Symbol("Chem.A")]        # that state element's trajectory
#     sol.retcode == ReturnCode.Success
# ===========================================================================

"""
    final_state(sol) -> Vector{Float64}

The final state vector of a solution (empty when the solve produced no points).

Works on any SciML solution — `sol.u[end]` as a dense `Vector{Float64}`,
which is the flat state vector `var_map` indexes.
"""
final_state(sol) = isempty(sol.u) ? Float64[] : Vector{Float64}(sol.u[end])


"""
    SimulateError(msg, code = "")

Exception thrown when a simulation Problem cannot be built or run (API_SPEC
§5.8): [`esm_problem`](@ref) given a missing file or an unsupported input, an
override in `p` / `u0` that names no variable, is ambiguous or collides with
another, a document with no models, a provider or compiler that cannot serve
the request, an [`observed_field`](@ref) read of a name that is not an
evaluable observed, or `solve` called without the solver extension loaded. The
ModelingToolkit and Catalyst constructors (`ModelingToolkit.System`,
`Catalyst.ReactionSystem`) raise it too, for a document construct they cannot
lower.

Fields: `code`, the [`ERROR_CODES`](@ref) value when the failure has one (such
as `compiler_unknown`, `override_key_ambiguous` or `unsupported_construct`) and
`""` otherwise, then `msg`, the human-readable description.
"""
struct SimulateError <: EarthSciASTError
    code::String
    msg::String
    SimulateError(msg::AbstractString, code::AbstractString = "") = new(String(code), String(msg))
end

# --------------------------------------------------------------------------- #
# Default solver tolerances. Shared with the SciMLBase solve extension
# (ext/EarthSciASTSimulateExt.jl), which references these consts instead of
# duplicating the literals; they are what `solve(prob, alg)` uses when the
# caller names no `reltol` / `abstol`.
# --------------------------------------------------------------------------- #
const DEFAULT_SIM_RELTOL = 1.0e-4
const DEFAULT_SIM_ABSTOL = 1.0e-6

"""
    _resolve_merged_renames(renames, overrides) -> AbstractDict

Rewrite override keys off names an `operator_compose` merge DELETED
(esm-libraries-spec §4.7.1 step 4; issue #230).

A renaming match folds `B.x` into `A.x`, so only `A.x` still exists and every
equation is rewritten off the dead spelling. A CALLER holding `"B.x"` — a
`parameter_overrides` or `initial_conditions` key, an output selection — is
addressing a state that has moved, and nothing rewrites the strings it holds:
the key resolves to nothing and is silently dropped, so the state runs from its
default and the run still reports a verdict.

An EXPLICIT key for the survivor wins over an alias for the dead spelling: the
caller who names the surviving state has said what they mean.
"""
function _resolve_merged_renames(renames::AbstractDict, overrides::AbstractDict)
    (isempty(renames) || isempty(overrides)) && return overrides
    keytype(overrides) <: AbstractString || return overrides
    any(haskey(renames, String(k)) for k in keys(overrides)) || return overrides
    out = empty(overrides)
    for (key, value) in overrides
        k = String(key)
        survivor = get(renames, k, k)
        survivor != k && haskey(overrides, survivor) && continue
        out[survivor] = value
    end
    return out
end

# esm-libraries-spec §8.1: a library MUST reject a document whose major version
# it does not implement. Python and Rust refuse it at load; here it is refused at
# the build, before a document of another major is run as if it were this one.
# Majors 1 and 2 are implemented too: a 1.x or 2.x document that uses none of
# the constructs 2.0.0 and 3.0.0 removed means the same thing under 3.0.0 (a
# removed one is refused by name at load, `removed_op`), so the major version
# alone never refuses it.
function _refuse_unsupported_major_version(version)
    parsed = _parse_esm_version(string(version))
    parsed === nothing && return nothing
    supported = _parse_esm_version(SCHEMA_VERSION)[1]
    major = parsed[1]
    1 <= major <= supported || throw(
        ParseError(
            "Unsupported major version $major. This library supports major versions " *
                join(1:supported, ", ") * "."
        )
    )
    return nothing
end

# esm-spec §4.9.1.1: a declaration spelled with the independent variable or
# `_var` is unreachable — every reader gets the implicit symbol instead of the
# declared quantity, and the run is finite, plausible and wrong. `validate`
# reports it; the build refuses it rather than run that document.
function _refuse_reserved_declaration_names(file::EsmFile)
    errors = _check_reserved_file_names!(StructuralError[], file)
    isempty(errors) && return nothing
    e = first(errors)
    throw(
        ParseError(
            "[$(e.error_type)] $(e.path): $(e.message) (esm-spec §4.9.1.1)";
            code = e.error_type, path = e.path, details = e.details
        )
    )
end

# esm-spec §9.6.6 `callback_unregistered`: an equation that reads a variable a
# `callback` coupling injects (`config.callback_variables[].name`) reads a value
# only a registered callback supplies. Nothing registers one at construction, so
# a build would read a placeholder the document does not describe.
function _refuse_unregistered_callback_reads(file::EsmFile)
    injected = Dict{String, String}()          # variable name => callback_id
    for entry in file.coupling
        entry isa CouplingCallback || continue
        cfg = entry.config
        cvs = cfg === nothing ? nothing : get(cfg, "callback_variables", nothing)
        cvs isa AbstractVector || continue
        for cv in cvs
            nm = cv isa AbstractDict ? get(cv, "name", nothing) : nothing
            nm isa AbstractString && (injected[String(nm)] = entry.callback_id)
        end
    end
    (isempty(injected) || file.models === nothing) && return nothing
    for name in sort!(collect(keys(file.models)))
        _refuse_callback_reads_in(file.models[name], name, injected)
    end
    return nothing
end

function _refuse_callback_reads_in(
        model::Model, path::AbstractString,
        injected::AbstractDict{String, String}
    )
    for eq in model.equations, side in (eq.lhs, eq.rhs)
        for v in sort!(collect(free_variables(side)))
            haskey(model.variables, v) && continue
            id = get(injected, v, nothing)
            id === nothing && continue
            throw(
                TreeWalkError(
                    ERROR_CODES.CALLBACK_UNREGISTERED,
                    "'$path' reads '$v', which the `callback` coupling '$id' supplies, " *
                        "but no callback is registered to supply it at construction; refusing " *
                        "the build rather than reading a value the document does not give " *
                        "(esm-spec §9.6.6)"
                )
            )
        end
    end
    for (sub_name, sub) in model.subsystems
        sub isa Model && _refuse_callback_reads_in(sub, "$path.$sub_name", injected)
    end
    return nothing
end

# esm-libraries-spec §2.5.2: the structural-validation codes a build refuses on.
# They are the reference-integrity findings: a name, reference or data source the
# document uses and does not declare. A build that went ahead would read a value
# the document does not describe. Equation-count and unit findings are not here:
# they stay `validate`'s to report. `faq_bare_array_operand` (esm-spec §4.3.1)
# is here too: a shaped variable read by bare name in a `faq` body or
# filter has no defined alignment to the node's symbols, and another binding
# built it into a silently ignored filter.
const _BUILD_REFUSED_VALIDATION_CODES = ("undefined_variable", "undefined_parameter", "undefined_species", "undefined_system", "undefined_index_set", "unresolved_scoped_ref", "event_var_undeclared", "data_source_undefined", "missing_required_field", "faq_bare_array_operand")

function _refuse_reference_integrity_errors(file::EsmFile; supplied_names = ())
    for e in validate_structural(file)
        e.error_type in _BUILD_REFUSED_VALIDATION_CODES || continue
        # An inline test's references are the test runner's to report (§6.6);
        # the build does not evaluate them.
        occursin("/tests/", e.path) && continue
        # A bare name the caller binds at construction — a `const_arrays`,
        # `param_arrays` or `providers` key — is in scope for this build.
        e.error_type == ERROR_CODES.UNDEFINED_VARIABLE &&
            get(e.details, "variable", nothing) in supplied_names && continue
        throw(
            ParseError(
                "[$(e.error_type)] $(e.path): $(e.message) (esm-libraries-spec §2.5.2)";
                code = e.error_type, path = e.path, details = e.details
            )
        )
    end
    return nothing
end

# --------------------------------------------------------------------------- #
# Initial-condition seeding (mirrors the Python `_apply_initial_conditions`):
# a key may be a scalar name, an explicit element `name[i,j]`, or a bare array
# name that broadcasts a single value over every element of that array.
# --------------------------------------------------------------------------- #

# The state elements an `initial_conditions` key can address in `var_map`: the
# scalar names with their slots, and each array base name. A `StateLayout` is
# read through its blocks, so no cell's key is spelled; any other map is read
# by decoding its cell keys (`_parse_cell_key`).
struct _IcSpace
    scalars::Dict{String, Int}
    bases::Vector{String}
    layout::Union{Nothing, StateLayout}
    cells::Dict{String, Vector{Tuple{Vector{Int}, Int}}}   # when `layout` is nothing
end
function _IcSpace(L::StateLayout)
    bases = String[b.name for b in _layout_blocks(L)]
    return _IcSpace(L.scalars, bases, L, Dict{String, Vector{Tuple{Vector{Int}, Int}}}())
end
function _IcSpace(var_map::AbstractDict)
    scalars = Dict{String, Int}()
    cells = Dict{String, Vector{Tuple{Vector{Int}, Int}}}()
    for (vname, idx) in var_map
        parsed = _parse_cell_key(String(vname))
        if parsed === nothing
            scalars[String(vname)] = idx
        else
            push!(get!(cells, parsed[1], Tuple{Vector{Int}, Int}[]), (parsed[2], idx))
        end
    end
    return _IcSpace(scalars, collect(keys(cells)), nothing, cells)
end

# The slot of cell `idx` of array `base`, or 0.
function _ic_slot(sp::_IcSpace, base::String, idx::Vector{Int})
    sp.layout === nothing || return _layout_slot(sp.layout, base, idx)
    for (c, slot) in get(sp.cells, base, ())
        c == idx && return slot
    end
    return 0
end

# `f(idx, slot)` for every cell of array `base`, in slot order.
function _ic_foreach_cell(f, sp::_IcSpace, base::String)
    if sp.layout === nothing
        for (idx, slot) in sort(sp.cells[base]; by = last)
            f(idx, slot)
        end
    else
        b = _layout_block(sp.layout, base)
        for slot in b.base:(b.base + b.len - 1)
            f(_block_cell!(Vector{Int}(undef, length(b.lo)), b, slot), slot)
        end
    end
    return nothing
end

# Resolve a cell key `base[i,…]` (`parsed`, from `_parse_cell_key`) through the
# array base names: the bases the key's base designates, kept only when they
# hold that cell. The resolution names the cell key.
function _ic_cell_resolution(sp::_IcSpace, bases::NameTable, parsed)
    base, idx = parsed
    r = resolve_key(bases, base)
    if r.how === :ambiguous
        held = String[c for c in r.candidates if _ic_slot(sp, c, idx) != 0]
        isempty(held) && return KeyResolution(nothing, :unknown, String[])
        length(held) == 1 && return KeyResolution(_cell_key(held[1], idx), :suffix, String[])
        return KeyResolution(nothing, :ambiguous, String[_cell_key(c, idx) for c in held])
    end
    (r.name === nothing || _ic_slot(sp, r.name, idx) == 0) &&
        return KeyResolution(nothing, :unknown, String[])
    return KeyResolution(_cell_key(r.name, idx), r.how, String[])
end

function _apply_initial_conditions!(
        u0::Vector{Float64}, var_map::AbstractDict,
        ics::AbstractDict
    )
    isempty(ics) && return u0
    # esm-spec §6.6.2 keys `initial_conditions` by LOCAL variable name (`u`)
    # while every name the build uses is flattened (`M.u`): each key is resolved
    # onto a state by the one resolver every caller key goes through
    # (`resolve_key`, src/name_table.jl), and an ambiguous suffix is refused, never
    # guessed at.
    sp = _IcSpace(var_map)
    scalar_names = Set{String}(keys(sp.scalars))
    base_names = Set{String}(sp.bases)
    # Two name spaces, tried in order: the ELEMENT names (`M.u`, and a cell key
    # `M.f[1]` resolved through its base), then the array BASE names for the
    # broadcast form (`M.f` sets every `M.f[...]` cell). Rule 2 validates a
    # key's leading segments against the components the build's names carry
    # (`M.u` ⇒ `M`), so `Missing.u` is reported rather than re-pointed at `u`.
    namespaces = _override_namespaces(union(scalar_names, base_names))
    scalars = NameTable(scalar_names; namespaces = namespaces)
    bases = NameTable(base_names; namespaces = namespaces)
    function refuse_ambiguous(key, r)
        r.how === :ambiguous && throw(
            SimulateError(
                _override_ambiguous_message("initial_conditions", key, r.candidates; kind = "state"),
                ERROR_CODES.OVERRIDE_KEY_AMBIGUOUS
            )
        )
        return r
    end
    function state_key(key)
        r = refuse_ambiguous(key, resolve_key(scalars, key))
        r.name === nothing || return r, :element
        parsed = _parse_cell_key(key)
        if parsed !== nothing
            r = refuse_ambiguous(key, _ic_cell_resolution(sp, bases, parsed))
            r.name === nothing || return r, :cell
        end
        r = refuse_ambiguous(key, resolve_key(bases, key))
        r.name === nothing || return r, :base
        return nothing
    end
    # An exact key wins outright; two NON-EXACT keys designating one state is an
    # authoring error (esm-spec §6.6.2 "two keys, one name"): the caller wrote
    # two initial conditions and only one can take effect.
    claimed = Dict{String, Vector{String}}()
    exact_keys = Set{String}()
    resolved_keys = Dict{String, Tuple{KeyResolution, Symbol}}()
    for (rawkey, _) in ics
        key = String(rawkey)
        hit = state_key(key)
        hit === nothing && throw(
            SimulateError(
                "esm_problem: initial_conditions names unknown state element '$key'",
                ERROR_CODES.UNKNOWN_OVERRIDE_KEY
            )
        )
        resolved_keys[key] = hit
        r = first(hit)
        r.how === :exact ? push!(exact_keys, r.name) :
            push!(get!(claimed, r.name, String[]), key)
    end
    for name in sort!(collect(keys(claimed)))
        (name in exact_keys || length(claimed[name]) < 2) && continue
        throw(
            SimulateError(
                _override_collision_message(
                    "initial_conditions", "state", name, sort!(claimed[name])
                ),
                ERROR_CODES.OVERRIDE_KEY_CONFLICT
            )
        )
    end
    for (rawkey, value) in ics
        key = String(rawkey)
        r, space = resolved_keys[key]
        resolved = r.name::String
        if space === :element || space === :cell
            is_inline_array(value) && throw(
                SimulateError(
                    "esm_problem: initial_conditions['$key'] carries inline array data for a " *
                        "single state element; only a SHAPED unknown's whole-variable key takes " *
                        "a nested array (esm-spec §6.6.2)",
                    ERROR_CODES.ARRAY_SHAPE_MISMATCH
                )
            )
            slot = space === :element ? sp.scalars[resolved] :
                _ic_slot(sp, _parse_cell_key(resolved)...)
            u0[slot] = Float64(value)
            continue
        end
        if is_inline_array(value)
            _ic_foreach_cell(sp, resolved) do idxs, idx
                checkbounds(Bool, value, idxs...) || throw(
                    SimulateError(
                        "esm_problem: initial_conditions['$key'] has shape $(size(value)), " *
                            "which does not cover cell $(Tuple(idxs)) of '$resolved' " *
                            "(esm-spec §6.6.2 — the array MUST match the variable's declared " *
                            "shape after metaparameter folding)",
                        ERROR_CODES.ARRAY_SHAPE_MISMATCH
                    )
                )
                u0[idx] = Float64(value[idxs...])
            end
        else
            v = Float64(value)
            _ic_foreach_cell((_, idx) -> (u0[idx] = v), sp, resolved)
        end
    end
    return u0
end

"""
    seed_expression_ic!(u0, var_map, var_name, expr, coords) -> u0

Seed an array state's initial field from an expression evaluated over a grid —
the generic form of a domain-level `expression` initial condition (the Python
`_seed_expression_initial_conditions`). `coords` is an ordered collection of
`dim_name => coordinate_vector` pairs (one per array axis, in index order);
`expr` is evaluated at each grid node with the dimension names bound to the
node's coordinates and written into `u0` at `var_map["var_name[i,j,…]"]`.

Used to seed the level-set's signed-distance `psi` from the domain's declared
IC over the real (projected) fire grid — no per-cell loop in the runner.

`expr` is compiled ONCE with the dimension names bound as parameters and then
evaluated at each cell of `var_name` that `var_map` holds; the cells are read
off `var_map` itself, so no key is built per grid node. An expression the
compiler does not accept is evaluated per cell by `evaluate_expr` instead,
which a strict compiler plan in force refuses.
"""
function seed_expression_ic!(
        u0::Vector{Float64}, var_map::AbstractDict,
        var_name::AbstractString, expr::ASTExpr, coords
    )
    pairs_ = collect(coords)
    dims = String[String(first(p)) for p in pairs_]
    axes_ = [collect(Float64, last(p)) for p in pairs_]
    sizes = Tuple(length.(axes_))
    # The cells to seed: every `var_name[i,j,…]` entry of `var_map` inside the
    # grid, as (indices, slot) — `idx` holds the indices of cell `c` at
    # `(c-1)*nd+1 : c*nd`.
    nd = length(sizes)
    idx = Int[]
    slots = Int[]
    buf = zeros(Int, nd)
    for (key, slot) in var_map
        _seed_cell_indices!(buf, String(key), var_name, sizes) || continue
        append!(idx, buf)
        push!(slots, Int(slot))
    end
    ce = _setup_compile_once_enabled() ? _seed_expression_compile(expr, dims) : nothing
    if ce !== nothing
        vals = Vector{Float64}(undef, nd)
        @inbounds for c in eachindex(slots)
            for d in 1:nd
                vals[d] = axes_[d][idx[(c - 1) * nd + d]]
            end
            u0[slots[c]] = ce(vals)
        end
        return u0
    end
    binding(c) = Dict{String, Any}(
        dims[d] => axes_[d][idx[(c - 1) * nd + d]]
            for d in eachindex(dims)
    )
    # An expression no form can evaluate — an undeclared name — is the caller's
    # error, not a compiler's refusal, so a strict compiler's probe evaluates
    # the first cell, for its diagnostic only, before the refusal is raised.
    lic = _percell_evaluation_license(
        "seed_expression_ic!($(var_name))",
        "the expression initial-state seed", length(slots);
        one_cell = !isempty(slots),
        probe = _ -> isempty(slots) || evaluate_expr(expr, binding(1))
    )
    return _seed_expression_percell!(lic, u0, slots, expr, binding)
end

# The per-cell seed: the expression evaluated from its tree at every cell.
function _seed_expression_percell!(
        ::_PerCellLicense, u0::Vector{Float64},
        slots::Vector{Int}, expr::ASTExpr, binding
    )
    for c in eachindex(slots)
        u0[slots[c]] = evaluate_expr(expr, binding(c))
    end
    return u0
end

# Read the indices of a `name[i,j,…]` key into `buf` without allocating; false
# when the key is another variable's, has another rank, or lies off the grid.
function _seed_cell_indices!(
        buf::Vector{Int}, key::String, name::AbstractString,
        sizes::Tuple
    )
    n = ncodeunits(name)
    (
        ncodeunits(key) > n + 2 && startswith(key, name) &&
            codeunit(key, n + 1) == UInt8('[') && codeunit(key, ncodeunits(key)) == UInt8(']')
    ) ||
        return false
    d = 1; v = 0; seen = false
    @inbounds for i in (n + 2):(ncodeunits(key) - 1)
        b = codeunit(key, i)
        if UInt8('0') <= b <= UInt8('9')
            v = 10v + Int(b - UInt8('0')); seen = true
        elseif b == UInt8(',') && seen && d < length(buf)
            buf[d] = v; d += 1; v = 0; seen = false
        else
            return false
        end
    end
    (seen && d == length(buf)) || return false
    buf[d] = v
    for k in eachindex(buf)
        1 <= buf[k] <= sizes[k] || return false
    end
    return true
end

# The seed's expression compiled once with the dimension names as parameters:
# a `_CellEval` whose "cell" is the vector of coordinate values, or `nothing`
# when a name collides with the time symbol or the expression does not compile.
# The time symbol is the build compiler's (`_compile` reads the name `"t"` as
# time whatever the document's independent variable), so a dimension spelled
# `"t"` could not be read as a parameter.
function _seed_expression_compile(expr::ASTExpr, dims::Vector{String})
    any(==("t"), dims) && return nothing
    allunique(dims) || return nothing
    psyms = Symbol[Symbol(d) for d in dims]
    node = try
        _compile(expr, Dict{String, Int}(), Set{Symbol}(psyms))
    catch err
        err isa EarthSciASTError || rethrow()
        return nothing
    end
    return _CoordEval{Tuple(psyms), length(dims)}(node)
end

struct _CoordEval{syms, N}
    node::_Node
end
@inline (ce::_CoordEval{syms, N})(vals::AbstractVector{Float64}) where {syms, N} =
    _eval_node(ce.node, _NO_STATE_U, NamedTuple{syms}(ntuple(d -> @inbounds(vals[d]), Val(N))), 0.0)

# --------------------------------------------------------------------------- #
# Provider keys → the names the build reads (esm-spec §6.6.2).
#
# A `providers` key may spell the parameter it feeds the way a caller spells a
# `parameter_overrides` key: exactly (`Fed.s`), bare (`s`), partly qualified,
# or with a longer qualification whose leading segments name real components.
# The build reads only the flattened name, so data written under any other
# spelling was never read and the parameter silently kept its default. Keys are
# resolved onto the flattened PARAMETERS by the resolver `parameter_overrides`
# uses (`canonicalize_keys`), so the two surfaces cannot disagree: an
# exact key wins outright over a non-exact key for the same parameter, two
# non-exact keys for one parameter collide, and a key two parameters carry is
# ambiguous; the last two are errors.
#
# `keys_` are the keys routed by name: a gated provider is routed by its gate
# spec instead, so callers leave those out. Returns `(targets, shadowed)`:
# `targets` maps each key that designates a parameter to that parameter's
# flattened name (an exact key to itself), and `shadowed` holds the keys that
# lost to an exact key for the same parameter, which are not read. A key that
# names a state or observed exactly (a loader field, say), or designates no
# parameter, is in neither and is used as given.
# --------------------------------------------------------------------------- #
function _provider_routing(flat_rec, keys_; model_name = nothing)
    targets = Dict{String, String}()
    shadowed = Set{String}()
    flat_rec === nothing && return targets, shadowed
    flat = flat_rec.flat::FlattenedSystem
    params = Set{String}(keys(flat.parameters))
    asked = _routable_keys(flat_rec, keys_)
    isempty(asked) && return targets, shadowed
    table = NameTable(params; namespaces = _override_namespaces(params; model_name = model_name))
    normalized, unknown, ambiguous, collisions = canonicalize_keys(Any, table, asked)
    _raise_key_failures("providers", "parameter", unknown, ambiguous, collisions)
    for (name, k) in normalized
        targets[k::String] = name
    end
    for k in keys(asked)
        haskey(targets, k) || k in unknown || push!(shadowed, k)
    end
    return targets, shadowed
end

# The keys of `keys_` the parameter resolver considers, each mapped to itself.
# A key that is not a parameter's exact name is left out when it names a state
# or observed exactly, or a name a `variable_map` coupling reads
# (`coupling_reads`): the build reads it under that very name, so it is used as
# given rather than routed onto a parameter it is a suffix of, as Rust's
# `ParameterKeyResolver` does.
function _routable_keys(flat_rec, keys_)
    flat = flat_rec.flat::FlattenedSystem
    reads = hasproperty(flat_rec, :coupling_reads) ? flat_rec.coupling_reads : ()
    asked = Dict{String, String}()
    for rawk in keys_
        k = String(rawk)
        elsewhere = k in reads || haskey(flat.state_variables, k) ||
            haskey(flat.observed_variables, k)
        k in keys(flat.parameters) || !elsewhere || continue
        asked[k] = k
    end
    return asked
end

# Refuse a provider routed onto a parameter the caller's own `const_arrays` or
# `param_arrays` also supply, under any spelling of it: two sources for one
# value, where writing the provider's would silently replace the caller's array
# (or, for a live buffer, the very object the caller holds). A registry key is
# resolved onto the parameters by the same resolver the provider keys went
# through (`canonicalize_keys`, via `_routable_keys`), so the two
# surfaces agree on what a key designates. A registry key carried by several
# parameters, one of them provider-fed, is refused as ambiguous (esm-spec
# §6.6.2); one that names a state, observed or loader field is not a
# parameter's and never overlaps.
function _refuse_provider_registry_overlap(
        targets::AbstractDict, flat_rec, registries::Pair...;
        model_name = nothing
    )
    (isempty(targets) || flat_rec === nothing) && return nothing
    flat = flat_rec.flat::FlattenedSystem
    params = Set{String}(keys(flat.parameters))
    table = NameTable(params; namespaces = _override_namespaces(params; model_name = model_name))
    fed = Dict{String, String}(name => pk for (pk, name) in targets)
    overlap(label, pk, rk, name) = throw(
        SimulateError(
            "providers['$(pk)'] and $(label)['$(rk)'] both supply the parameter " *
                "'$(name)'; pass one of them (esm-spec §6.6.2)",
            ERROR_CODES.OVERRIDE_KEY_CONFLICT
        )
    )
    for (label, reg) in registries
        reg === nothing && continue
        asked = _routable_keys(flat_rec, keys(reg))
        isempty(asked) && continue
        normalized, _, ambiguous, collisions = canonicalize_keys(Any, table, asked)
        for (k, cands) in sort!(collect(ambiguous), by = first)
            any(c -> haskey(fed, c), cands) &&
                throw(SimulateError(_override_ambiguous_message(label, k, cands), ERROR_CODES.OVERRIDE_KEY_AMBIGUOUS))
        end
        for (name, rk) in sort!(collect(normalized), by = first)
            haskey(fed, name) && overlap(label, fed[name], rk, name)
        end
        for (name, rks) in sort!(collect(collisions), by = first)
            haskey(fed, name) && overlap(label, fed[name], first(rks), name)
        end
    end
    return nothing
end

# A discrete provider delivering its field under the caller's key, re-exposed
# under the name the build reads, so the refresh callback and the re-seed at a
# run's start find it under the buffer's own name. One wrapper per provider
# object, so a provider serving several fields is still sampled once per
# refresh. Every function of the provider protocol is forwarded, so the
# wrapper answers each one as the provider it wraps does.
struct _RekeyedProvider
    inner::Any
    fields::Vector{Pair{String, String}}   # name the build reads => caller's key
end
provider_refresh_times(p::_RekeyedProvider) = provider_refresh_times(p.inner)
provider_is_const(p::_RekeyedProvider) = provider_is_const(p.inner)
provider_supports_selection(p::_RekeyedProvider) = provider_supports_selection(p.inner)
provider_gate_spec(p::_RekeyedProvider) = provider_gate_spec(p.inner)
provider_extent_metaparameter(p::_RekeyedProvider) = provider_extent_metaparameter(p.inner)
function provider_sample(p::_RekeyedProvider, t::Real; selection = nothing)
    s = selection === nothing ? provider_sample(p.inner, t) :
        provider_sample(p.inner, t; selection = selection)
    return Dict{String, Any}(to => _sample_field(s, from) for (to, from) in p.fields)
end

# `renamed` maps each caller key whose buffer now lives under another name to
# that name; `discrete` is keyed by the names the build reads.
function _rekey_discrete_providers!(discrete::Dict{String, Any}, renamed::AbstractDict)
    isempty(renamed) && return discrete
    from = Dict{String, String}(v => k for (k, v) in renamed)
    moved = Base.IdSet{Any}(discrete[n] for n in keys(from) if haskey(discrete, n))
    isempty(moved) && return discrete
    wrap = IdDict{Any, _RekeyedProvider}()
    for (k, prov) in discrete
        # Every field of a provider any of whose keys was renamed rides one
        # wrapper; its other fields keep their own names.
        prov in moved || continue
        w = get!(() -> _RekeyedProvider(prov, Pair{String, String}[]), wrap, prov)
        push!(w.fields, k => get(from, k, k))
    end
    for k in collect(keys(discrete))
        haskey(wrap, discrete[k]) && (discrete[k] = wrap[discrete[k]])
    end
    return discrete
end

# The provider keys routed by name: every key but a gated provider's, whose
# fields are placed by its gate spec.
_routable_provider_keys(traits::AbstractDict{String, _ProviderTraits}) =
    String[k for (k, t) in traits if t.gate === nothing]

# Every provider described once (`_provider_traits`), under its caller's key.
_describe_providers(::Nothing) = Dict{String, _ProviderTraits}()
_describe_providers(providers::AbstractDict) = Dict{String, _ProviderTraits}(
    String(k) => _provider_traits(prov, String(k)) for (k, prov) in providers
)

# `t` with the gate the pushdown rewrite's record derives for its provider, which
# takes precedence over the provider's own.
_with_gate(t::_ProviderTraits, gate::_GateSpec) = _ProviderTraits(
    gate, true, Float64[], t.extent_metaparameter, t.supports_selection
)

# Const provider data under the name the build reads, and under the caller's
# key beside it (as `_normalize_const_array_keys` keeps a caller's const key),
# so a consumer that reads the caller's spelling (a pushdown alias) finds it.
function _put_provider_const!(merged_const, key::String, target::String, data)
    merged_const[target] = data
    target == key || (merged_const[key] = data)
    return merged_const
end

# --------------------------------------------------------------------------- #
# Callback composition seam — the `CallbackSet` constructor lives in
# EarthSciASTSimulateExt (SciMLBase), exactly like the callback CONSTRUCTORS
# live in the DiffEqCallbacks extensions. A problem with zero or one callback
# composes without SciMLBase at all; two or more can only have come from those
# extensions, so SciMLBase is loaded by then and the extension method wins.
# --------------------------------------------------------------------------- #
function _callback_set end
_callback_set(cbs) = throw(
    SimulateError(
        "composing $(length(cbs)) problem-level callbacks needs the SciMLBase extension; " *
            "add `using SciMLBase` so EarthSciASTSimulateExt is active",
        ERROR_CODES.EXTENSION_UNAVAILABLE
    )
)

_compose_callbacks(cbs::AbstractVector) =
    isempty(cbs) ? nothing : length(cbs) == 1 ? cbs[1] : _callback_set(cbs)

# --------------------------------------------------------------------------- #
# The compiler-built backend seam (API_SPEC §5.8).
#
# `:native` and `:interpreter` hand back a plain closure, and everything
# downstream of it — the `ODEProblem` the SciMLBase extension assembles, the
# build-time observed reader — is this package's own. A SPECIALTY compiler
# builds a whole program instead: `:mtk` compiles a ModelingToolkit `System`,
# whose EVENTS, mass matrix and OBSERVED EQUATIONS live on ITS `ODEProblem` and
# would be silently lost if the solve path rebuilt one out of the right-hand
# side alone.
#
# Such a compiler parks that program on the CALLABLE it returns, and these
# three hooks ask the callable for it. Dispatch is on the right-hand side's own
# type — a type the extension owns — so an extension ADDS a method instead of
# overwriting a core one, and a compiler with no backend needs no method at all.
# --------------------------------------------------------------------------- #
_compiler_backend(@nospecialize(f)) = nothing
function _backend_ode_problem end
function _backend_observed_field end

# The `:mtk` construction itself (EarthSciASTMTKExt). No fallback method: the
# plan `_compiler_plan(:mtk)` returns has already raised `compiler_unavailable`
# when the extension is not loaded, so this name is only ever called with it.
function _mtk_problem end

# --------------------------------------------------------------------------- #
# Internal solve bridge, for the CORE-RESIDENT callers that have to run a
# problem themselves — today only the inline-test engine (`run_inline_tests`),
# which lives in this package and is handed an `alg` by its caller. It is NOT a
# second public entry point beside `solve`: the extension implements it BY
# calling `SciMLBase.solve(prob, alg; …)`, so there is exactly one solve path.
# --------------------------------------------------------------------------- #
function _solve_problem end
_solve_problem(prob, alg; kwargs...) = throw(
    alg === nothing ?
        SimulateError(
            "solving an EsmProblem needs an ODE algorithm: pass `alg = Tsit5()` " *
            "(and `using OrdinaryDiffEqTsit5`)",
            ERROR_CODES.INVALID_ARGUMENT
        ) :
        SimulateError(
            "solving an EsmProblem needs the SciMLBase extension; add `using SciMLBase` " *
            "plus a solver (e.g. OrdinaryDiffEqTsit5) so EarthSciASTSimulateExt is active",
            ERROR_CODES.EXTENSION_UNAVAILABLE
        )
)

# --------------------------------------------------------------------------- #
# EsmProblem — the run-ready artifact, built once per document. `solve` varies
# only the per-run settings, and `remake(prob; p, u0, tspan)` substitutes without
# redoing what the substitution cannot have invalidated.
# --------------------------------------------------------------------------- #

# What a program of a Problem is built from (`rhs_program`, `compile_kernels`):
# the prepared run the Problem's build compiled and the inputs that build took,
# so a program is lowered from the same prepared document without loading it
# again or sampling a provider twice.
struct _ProgramSeed
    prep::PreparedRun                 # with the data shapes the Problem adopted
    compiler::Symbol
    model_name::Union{Nothing, String}
    overrides::Dict{String, Any}
    const_arrays::Dict{String, Any}   # the merged const registry the build read
    param_arrays::Dict{String, Any}   # the Problem's live buffers (the same arrays)
    gated_providers::Dict{String, _GatedProvider}
    sample_time::Float64
    runtime_array_parameters::Bool
    # The start of the run and the data-fed values there, which the `ic`
    # right-hand sides read (esm-spec §11.4.2).
    ic_t0::Float64
    ic_data::Dict{String, Any}
end

# A Problem's own build products, plus what the Problem keeps across reads of
# them: the `observed_field` answers (name → `_ObservedMemo`), the lock around
# them and the report rows reads file, since two tasks may read one problem at
# once; the seed its programs are built from (`nothing` for a compiler that
# builds no program); and its whole-model program once one is built (by
# `rhs_program`, or by `esm_problem(…; program_build = true)` as the Problem's
# own right-hand side).
struct _ProblemBuild
    products::BuildProducts
    observed_memo::Dict{String, _ObservedMemo}
    observed_lock::ReentrantLock
    seed::Union{Nothing, _ProgramSeed}
    program::Base.RefValue{Any}
    program_lock::ReentrantLock
end
_ProblemBuild(products::BuildProducts, seed = nothing, program = nothing) = _ProblemBuild(
    products, Dict{String, _ObservedMemo}(), ReentrantLock(), seed,
    Ref{Any}(program), ReentrantLock()
)

"""
    EsmProblem

The ESM simulation problem [`esm_problem`](@ref) builds once per document: the
right-hand side `f!` the chosen `compiler` built, the seeded initial state `u0`,
the integration interval `tspan`, the parameter carrier `p`, the `var_map`, the
live forcing buffers, the discrete-provider refresh state and the problem's own
callback set.

```julia
using EarthSciAST, OrdinaryDiffEqTsit5
prob = esm_problem("model.esm", (0.0, 1.0); p = Dict("M.k" => 2.5))
sol  = solve(prob, Tsit5())
sol.retcode                     # SciMLBase.ReturnCode.Success
sol[Symbol("M.y")]              # that state element's trajectory, BY NAME
prob2 = remake(prob; tspan = (0.0, 5.0))   # no re-load / re-flatten / re-build
```

The input document is parsed and compiled at construction, so later mutations
to it are not seen. Forcing arrays (`const_arrays` / `param_arrays`) are the
exception: they are captured by reference, not copied.

Repeated runs are independent: `u0` is copied per run, and discrete forcing
buffers are re-seeded from their providers at each run's `t0` (with the
[`DiscreteMaterializer`](@ref) caches recomputed) whenever a previous run may
have refreshed them or the start time changed.

Parameter overrides split by CLASS (see [`parameter_classes`](@ref)):
`:numeric` ones may be passed to `remake(prob; p = …)` and are applied by
swapping `p` (no rebuild). `:structural`, `:const_folded` and `:forcing` ones
throw, since the build consumed them or they never reach `p`; call
[`esm_problem`](@ref) again for those.

Fields are an extension seam, not stable API; `var_map`, `p`, `u0`, `tspan`
and `output_meta` are the ones downstream code reads.
"""
struct EsmProblem
    f!::Function                          # the built RHS, in-place, whatever
    # `compiler` produced it
    u0::Vector{Float64}                   # seeded initial state; COPIED per run
    tspan::Tuple{Float64, Float64}         # integration interval
    p::Any                                # parameter NamedTuple (or nothing)
    var_map::AbstractDict{String, Int}     # state-element name → flat index (a `StateLayout`)
    param_buffers::Dict{String, Any}       # live forcing buffers, aliased into f!
    discrete_providers::Dict{String, Any}  # forcing var → DISCRETE data Provider
    dm::DiscreteMaterializer              # discrete-cadence cache sink (may be empty)
    n_equations::Int                      # flattened equation count (display only)
    buffer_time::Base.RefValue{Float64}   # t the discrete buffers currently hold
    dirty::Base.RefValue{Bool}            # true once a run may have refreshed them
    output_meta::OutputMeta               # doc-derived output naming/CF metadata (RFC §7–§8)
    # The single-model run document the problem was built from (`_run_file`):
    # what [`observed_field`](@ref) resolves shapes and index sets against, and
    # where `solve` reads the document's `solver` block.
    run_file::EsmFile
    # The parameter PARTITION this build produced (see `parameter_classes`):
    # name → `:numeric` / `:structural` / `:const_folded` / `:forcing`. Derived
    # from what the build-time consumers actually READ, which is what decides
    # whether an override can ride `p` at solve time or needs a rebuild.
    param_classes::Dict{String, Symbol}
    # What the build produced besides the right-hand side, and this problem's
    # output-time read cache (`_ProblemBuild`). Shared by its `remake`s, which
    # share its build.
    build::_ProblemBuild
    # The problem's callback set (§2.5.4). Composed at CONSTRUCTION from the
    # data-refresh, output-sink and checkpoint callbacks, because a callback
    # that refreshes provider buffers or writes an output stream belongs to the
    # document, not to a particular run's tolerances. `solve(prob; callback=…)`
    # REPLACES it entirely; read it back with [`callbacks`](@ref) to extend.
    callback::Any
    tstops::Vector{Float64}               # refresh ∪ output anchors
    save_everystep::Bool                  # false once a sink owns the trajectory
    sinks::Vector{Any}                    # diagnostic sinks
    lifecycle_sinks::Vector{Any}          # distinct sinks to open!/close! per run
    symcache::Base.RefValue{Any}          # lazy SymbolicIndexingInterface cache
    # Every state spelling an `operator_compose` renaming match DELETED, mapped
    # onto the survivor it was folded into (issue #230): a NAME-KEYED read of
    # this problem — `observed_field(prob, name)` — names a quantity that MOVED,
    # not one that never existed. Empty for a document with no renaming merge.
    merged_renames::OrderedDict{String, String}
    # `(; seed, overrides)`, `seed(t0, overrides) -> u0`: this problem's
    # initial state at another start of the run, for a document whose `ic`
    # right-hand sides read the start (`t`, a data-fed parameter; esm-spec
    # §11.4.2). `remake` with a new `tspan` calls it. `nothing` when the
    # initial state does not depend on the start.
    ic_restart::Any
    # What `strip` removed (a `StrippedConstructs`), or `nothing` when the
    # Problem was built without `strip` (API_SPEC §5.8, "Strip and expose").
    stripped::Any
end

# The keyword constructor every construction site uses, so a field added to
# the struct is an error at each site rather than a shifted argument.
EsmProblem(;
    f!, u0, tspan, p, var_map, param_buffers = Dict{String, Any}(),
    discrete_providers = Dict{String, Any}(), dm = DiscreteMaterializer(),
    n_equations, buffer_time, dirty = Ref(false), output_meta, run_file,
    param_classes, build, callback, tstops, save_everystep, sinks, lifecycle_sinks,
    symcache = Ref{Any}(nothing), merged_renames, ic_restart = nothing, stripped = nothing
) = EsmProblem(
    f!, u0, tspan, p, var_map, param_buffers, discrete_providers, dm, n_equations,
    buffer_time, dirty, output_meta, run_file, param_classes, build, callback, tstops,
    save_everystep, sinks, lifecycle_sinks, symcache, merged_renames, ic_restart, stripped
)

# `prob` with the fields named in `changes` replaced.
function _with(prob::EsmProblem; changes...)
    names = fieldnames(EsmProblem)
    fields = NamedTuple{names}(map(f -> getfield(prob, f), names))
    return EsmProblem(; merge(fields, values(changes))...)
end

function Base.show(io::IO, prob::EsmProblem)
    # A compiler that built its own program carries its own parameter object
    # (`:mtk` hands back ModelingToolkit's), whose `length` is a count of ITS
    # internal partitions and not of the document's parameters. The build's
    # parameter PARTITION is per declared name under every compiler, so it is
    # what says how many parameters this problem has.
    np = _compiler_backend(prob.f!) === nothing ?
        (prob.p === nothing ? 0 : length(prob.p)) : length(prob.param_classes)
    print(
        io, "EsmProblem(", length(prob.u0), " state elements, ",
        prob.n_equations, " equations, ", np, " parameters, tspan=", prob.tspan
    )
    isempty(prob.discrete_providers) ||
        print(io, ", ", length(prob.discrete_providers), " discrete forcings")
    prob.callback === nothing || print(io, ", callbacks")
    # What BUILT it and where its rules landed — the two things §5.8 makes
    # readable off a problem, and the two a caller comparing two problems needs.
    rep = compiler_report(prob)
    print(io, "; compiler :", rep.compiler)
    hist = tier_histogram(rep)
    isempty(hist) ||
        print(io, " [", join(("$(t)=$(n)" for (t, n) in hist), ", "), "]")
    return print(io, ")")
end

"""
    compiler(prob::EsmProblem) -> Symbol

The vocabulary value (API_SPEC §5.8) that BUILT this problem — what actually
ran, not what was asked for, which for a successful build are the same thing
because a compiler that cannot run a document refuses it rather than
substituting another.
"""
compiler(prob::EsmProblem)::Symbol = compiler_report(prob).compiler

"""
    compiler_report(prob::EsmProblem) -> CompilerReport

Which tier every rule of this problem landed on, and the declines it collected
on the way (API_SPEC §5.8). Under [`compiler`](@ref)`(prob) === :native` this is
the cost story: affine versus generated code versus a whole-array form, and
which equations were scalarized per output cell at BUILD.

```julia
prob = esm_problem("model.esm", (0.0, 1.0))
compiler(prob)                       # :native
show(stdout, MIME"text/plain"(), compiler_report(prob))
```

The names and their meanings are stable; the record's shape is per-binding.
"""
compiler_report(prob::EsmProblem)::CompilerReport = prob.build.products.compiler_report

"""
    compiler_report(insp::BuildInspection) -> CompilerReport

The same record, off a build's [`BuildInspection`](@ref). A caller who passed
`inspect = insp` to [`esm_problem`](@ref) reads it here — including after a
build that REFUSED, which is the case the partial record is most wanted for and
the one no Problem exists to carry.

This is the whole of what build observability answers about the compiler:
the tier every rule landed on, the declines it collected getting there, and the
build's cascade counters. `compiler_report(prob)` is the same object.
"""
compiler_report(insp::BuildInspection)::CompilerReport = insp.compiler_report

"""
    forcing_buffers(prob::EsmProblem) -> NamedTuple

The live forcing buffers of `prob`: every `param_arrays` entry and every
[`DiscreteMaterializer`](@ref) cache the build bound, in a STABLE (name-sorted)
order, each value the ALIASED flat host view of the exact array the build bound
— not a copy, so a discrete-cadence refresh writing the original array is
visible through this container. Empty for a document with no live forcing.

The Problem publishes it whatever compiler built it. Position of a name is
[`forcing_buffer_index`](@ref)`(prob)[name]`, and
[`sync_forcing!`](@ref) mirrors the container into a compiled program's device
arrays at a cadence boundary.
"""
forcing_buffers(prob::EsmProblem)::NamedTuple = prob.build.products.forcing_buffers

"""
    forcing_buffer_index(prob::EsmProblem) -> Dict{String,Int}

Name → position in [`forcing_buffers`](@ref)`(prob)`, and in any container
aligned with it. Treat as read-only.
"""
forcing_buffer_index(prob::EsmProblem)::Dict{String, Int} =
    prob.build.products.forcing_buffer_index


# Equation count of the run document — display metadata only.
_doc_equation_count(file::EsmFile) =
    file.models === nothing ? 0 : sum(m -> length(m.equations), values(file.models); init = 0)

# The pushdown prepass's input (`esm_problem(...; pushdown_rewrite = true)`):
# the rewritten document when the pattern matched, else the loaded file, and
# whether it matched.
function _pushdown_input(input, model_name, metaparams, base_path)
    pfile = input isa EsmFile ? input :
        input isa AbstractString ? _load_run_path(String(input), metaparams) :
        input isa AbstractDict ? load_document(
            input; base_path = base_path,
            metaparameters = metaparams
        ) :
        throw(
            SimulateError(
                "esm_problem: pushdown_rewrite=true needs a path, native Dict, or " *
                "EsmFile input — a FlattenedSystem is already past the rewrite point",
                ERROR_CODES.INVALID_ARGUMENT
            )
        )
    raw = serialize_esm_file(pfile)
    rewritten = desugar_pushdown(raw; model_name = model_name)
    return rewritten !== raw ? (rewritten, true) : (pfile, false)
end

# --------------------------------------------------------------------------- #
# Loader-discovered extents (esm-spec §8.9.4, CONFORMANCE_SPEC §5.5) — the
# pre-pass `esm_problem` runs before ANY load, because a discovered extent closes a
# metaparameter and metaparameters are bound at the loader API.
#
# Returns `(metaparameters, discovered)`: the caller's bindings PLUS whatever
# the loaders measured, and the sampled arrays themselves so the injection loop
# reuses them instead of re-reading (a zipped inventory is decoded once).
# --------------------------------------------------------------------------- #
function _discover_loader_extents(
        providers, traits::AbstractDict{String, _ProviderTraits},
        metaparameters::AbstractDict, t0::Float64
    )
    out = Dict{String, Int}(String(k) => Int(v) for (k, v) in metaparameters)
    discovered = Dict{String, Any}()
    providers === nothing && return out, discovered
    # `by` records which provider bound each metaparameter, so a disagreement
    # names BOTH sides. Sorted keys keep that naming deterministic.
    by = Dict{String, Tuple{Int, String}}()
    for rawk in sort!(collect(keys(traits)))
        prov = providers[rawk]
        mp = traits[rawk].extent_metaparameter
        mp === nothing && continue
        traits[rawk].gate === nothing || throw(
            SimulateError(
                "provider '$rawk' both GATES on a derived index set and declares the " *
                    "extent metaparameter '$mp'; a gated slab's extent is the gating set's, " *
                    "not a discovered one",
                ERROR_CODES.PROVIDER_EXTENT_CONFLICT
            )
        )
        # Only the record count is read here; the field is checked and
        # converted once, where `esm_problem` binds it.
        field = _sample_field(provider_sample(prov, t0), rawk)
        n = ndims(field) == 0 ? 1 : size(field, 1)
        if haskey(by, mp)
            prev, prevk = by[mp]
            prev == n || throw(
                SimulateError(
                    "loader extent '$mp' is $prev from provider '$prevk' but $n from " *
                        "'$rawk' — the loader's variables are not aligned on one record axis",
                    ERROR_CODES.PROVIDER_EXTENT_CONFLICT
                )
            )
        elseif haskey(out, mp) && out[mp] != n
            throw(
                SimulateError(
                    "metaparameter '$mp' was closed at $(out[mp]) by the caller but " *
                        "provider '$rawk' discovers $n records; drop the binding and let the " *
                        "loader declare its own extent",
                    ERROR_CODES.PROVIDER_EXTENT_CONFLICT
                )
            )
        end
        by[mp] = (n, rawk)
        out[mp] = n
        discovered[rawk] = field
    end
    return out, discovered
end

# The declared shape of each provider-fed parameter in `keys`, resolved
# against the flattened system's index sets: what `esm_problem` checks each
# whole-bound provider sample against (`forcing_from_sample`). `shape: []`
# takes one value. A parameter declared WITHOUT a shape is not checked: it
# takes its data's shape (`_adopt_data_shapes`). A key no parameter declares (a
# loader field a coupling routes), and a shape naming a set the registry does
# not size before the build (a derived set), are not checked either.
function _provider_declared_shapes(flat::FlattenedSystem, keys)
    out = Dict{String, Vector{Int}}()
    for k in keys
        v = get(flat.parameters, k, nothing)
        v === nothing && continue
        if v.shape === nothing
            continue
        elseif isempty(v.shape)
            out[k] = Int[]
        else
            exts = _declared_shape_extents(v.shape, flat.index_sets, _EMPTY_DERIVED_EXTENTS)
            exts === nothing || (out[k] = exts)
        end
    end
    return out
end

# esm-spec §4.3.4: a parameter declared WITHOUT a `shape` whose data (a
# caller's `const_arrays` / `param_arrays` entry, or a provider's sample bound
# into them) holds more than one value takes the data's shape, decided here
# once, before the build, so every consumer — shape promotion of the observeds
# that read it, the build, the observed and program reads — sees one shape. Each
# axis is an anonymous interval index set `<name>__data<k>` of the data's extent
# on that axis. Data of one value leaves the parameter a scalar, and
# `shape: []` declares a scalar whatever its data (the build refuses array data
# for it, `_refuse_array_data_for_scalar`). A registry key names a parameter as
# any caller key does (`resolve_key`, esm-spec §6.6.2); one that several parameters
# carry is refused. Returns `flat` itself when nothing adopts a shape.
# Whether `flat` declares `name` (in any partition).
_declares(flat::FlattenedSystem, name::AbstractString) =
    haskey(flat.parameters, name) || haskey(flat.state_variables, name) ||
    haskey(flat.observed_variables, name) || haskey(flat.discrete_parameters, name)

function _adopt_data_shapes(flat::FlattenedSystem, registries...)
    cands = Set{String}(k for (k, v) in flat.parameters if v.shape === nothing)
    isempty(cands) && return flat
    table = NameTable(cands)
    adopted = Dict{String, Vector{Int}}()
    for reg in registries, (rawk, a) in reg
        a isa AbstractArray && length(a) != 1 || continue
        k = String(rawk)
        # A key naming another declaration exactly (a state, a loader field) is
        # that declaration's.
        k in cands || !_declares(flat, k) || continue
        r = resolve_key(table, k)
        r.how === :ambiguous && throw(
            SimulateError(_override_ambiguous_message("const_arrays", k, r.candidates), ERROR_CODES.OVERRIDE_KEY_AMBIGUOUS)
        )
        name = r.name
        name === nothing && continue
        # An exact key outranks a suffix spelling of the same parameter.
        haskey(adopted, name) && k != name && continue
        adopted[name] = collect(Int, size(a))
    end
    isempty(adopted) && return flat
    index_sets = OrderedDict{String, IndexSet}(flat.index_sets)
    data_axes(name) = [string(name, "__data", d) for d in eachindex(adopted[name])]
    reshape_part(part) = OrderedDict{String, ModelVariable}(
        k => (haskey(adopted, k) ? reconstruct(v; shape = data_axes(k)) : v) for (k, v) in part
    )
    for (name, dims) in adopted, (d, n) in enumerate(dims)
        index_sets[string(name, "__data", d)] = IndexSet("interval"; size = n)
    end
    return FlattenedSystem(
        flat; parameters = reshape_part(flat.parameters),
        discrete_parameters = reshape_part(flat.discrete_parameters),
        index_sets = index_sets
    )
end

"""
    esm_problem(input, tspan; p=Dict(), u0=nothing, kwargs...) -> EsmProblem

Build the simulation problem for `input` over `tspan = (t0, t1)`
(esm-libraries-spec §2.5). Construction loads, flattens and shape-transforms the
document, materializes provider fields, builds the evaluator, seeds the initial
state and composes the callbacks once; `solve` then integrates the returned
[`EsmProblem`](@ref) as often as you like.

`input` is a path to an `.esm` file, a native ESM `Dict`, a loaded
[`EsmFile`](@ref) or a [`FlattenedSystem`](@ref). All but a `FlattenedSystem` are
flattened, so every name below and every solution index is namespaced
(`"Chem.A"`, not `"A"`). The document is parsed here: mutating `input` afterwards
does not affect the problem (forcing arrays are aliased; see [`EsmProblem`](@ref)).
Two problems may be built at once on two tasks; one problem's `f!` is not to be
called from several threads at once.

Keywords (API_SPEC §5.8):

* `p::AbstractDict` — parameter overrides, baked into the build, so every class
  of parameter can be set here, including the `:structural` ones `remake` refuses
  ([`parameter_classes`](@ref)). Keys may be local (`pert_amp`) or namespaced
  (`Chem.pert_amp`). The values also bind build-time evaluation (esm-spec §6.6.5):
  a coordinate-expression `ic` and an inline assertion `reference` see them.
* `u0` — an `AbstractDict` of overrides applied on top of the document's initial
  conditions (`"M.y"`, `"M.f[1,2]"`, or `"M.f"` broadcasting one value over every
  cell), or an `AbstractVector` replacing the seeded state.
* `providers::AbstractDict` — `<Loader>.<var> => data Provider`. Const providers
  ([`provider_is_const`](@ref)) are materialized once into `const_arrays`;
  discrete providers get a live buffer and a [`build_refresh_callback`](@ref). A
  key naming a data-fed parameter may be local or namespaced (esm-spec §6.6.2).
  A scalar parameter fed this way has no slot in `p`.
* `model_name` — the model to build when the document holds several.
* `metaparameters::AbstractDict` — binds open metaparameters, as
  [`load_path`](@ref)`(path; metaparameters=…)` does (esm-spec §9.7.6).
* `base_path::AbstractString = pwd()` — where a `Dict` input's relative `{ref}`s
  resolve (a path input uses its own directory).
* `sample_time::Real = tspan[1]` — the `t` at which providers are sampled for the
  build. An `ic` right-hand side reads data-fed parameters at `tspan[1]` whatever
  `sample_time` is (esm-libraries-spec §2.5.2).
* `compiler::Symbol = :native` — one of `:native`, `:interpreter`, `:xla`, `:mtk`,
  `:sympy` (esm-libraries-spec §2.5.10); read back with [`compiler`](@ref) and
  [`compiler_report`](@ref). `:native` is strict: where one of its compiled tiers
  declines, the build raises `compiler_refused_rule` naming the rule and reason
  instead of falling back to a slower path. It refuses events, implicit equations
  and SDE noise with `unsupported_construct`. `:interpreter` is the reference tree
  walk with no performance promise. `:mtk` needs `using ModelingToolkit`, runs
  events and implicit equations, refuses loaded data, a continuous spatial
  dimension, a geometry operator and a time derivative of an expression
  (`compiler_refused_rule`), classifies every parameter `:structural`, and indexes
  its solution by the compiled system's symbols (`prob.var_map` and
  [`observed_field`](@ref) give the document names). `:xla` needs `using Reactant`.
  A compiler this session cannot run raises `compiler_unavailable` (`:sympy`
  always does in Julia); a value outside the vocabulary raises `compiler_unknown`.
  Both are raised before the document is loaded. The Simulation Runners page has
  the details.
* `strip` — classes of construct to remove before the build (`"algebraic"`,
  `"continuous_events"`, `"discrete_events"`, `"parameter_updates"`); the removed
  constructs are on the problem ([`stripped`](@ref)) and `solve` refuses a problem
  that lost any. `:native` and `:interpreter` only.
* `program_build::Bool = false` — build the right-hand side as the whole-model
  program [`rhs_program`](@ref) returns, so `rhs_program(prob)` does not lower the
  model again. Evaluations are bitwise those of that program. A state-free field
  over a live forcing buffer is recomputed on every call rather than per refresh,
  and every externally fed parameter is read from a live buffer (classified
  `:forcing`, absent from `prob.p`). Needs `:native` or `:interpreter`; refuses
  `materialize_out`.
* `runtime_array_parameters::Bool = false` — keep every shaped parameter with a
  value as a live buffer ([`forcing_buffers`](@ref)) instead of folding it, so a
  program of the problem takes it as a [`ForcingSlot`](@ref) of kind
  `:array_parameter`. A shaped parameter bound through `param_arrays` is a live
  buffer either way.
* `pushdown_rewrite::Bool = false` — apply [`desugar_pushdown`](@ref) to the
  authored document before flattening; a provider routed onto a rewritten array
  is then fetched pre-sliced to its support set.

Julia extension-seam keywords (allowed by §2.5.2; not stable API): `const_arrays`,
`param_arrays` (forwarded to the build), `inspect` (a fresh
[`BuildInspection`](@ref) the build fills; one record per call),
`materialize_out` (a caller-owned [`DiscreteMaterializer`](@ref)), `seed_ic!` (an
`(u0, var_map) -> nothing` hook run after `u0`; see
[`seed_expression_ic!`](@ref)), and the streaming-output set `sinks`, `snapshot`,
`pre_write`, `checkpoint_predicates`, `checkpoint_sinks`,
`terminate_on_checkpoint`.

**Callbacks** (§2.5.4). Discrete providers, `sinks` and `checkpoint_predicates`
contribute refresh, output and checkpoint callbacks, composed into one set read
back with [`callbacks`](@ref). A `callback` passed to `solve` replaces that set:

```julia
prob = esm_problem("model.esm", (0.0, 10.0); p = Dict("Chem.k" => 2.0))
sol = solve(prob, Tsit5(); callback = CallbackSet(callbacks(prob), my_extra))
```

**Loader-discovered extents** (esm-spec §8.9.4). A provider reporting a
[`provider_extent_metaparameter`](@ref) is sampled once, first, and its record
count binds that metaparameter for the load; the sample is reused at injection.
Providers of one loader disagreeing on the count, or a `metaparameters` binding
contradicting it, is an error, and `input` must then be a path or a `Dict` (an
`EsmFile` has its metaparameters closed already).

Per-run settings (`alg`, `abstol`, `reltol`, `saveat`, `callback`, `maxiters`)
belong to `solve(prob, alg; …)`; this call needs neither SciMLBase nor an
OrdinaryDiffEq package.
"""
function esm_problem(
        input, tspan;
        p::AbstractDict = Dict{String, Float64}(),
        u0 = nothing,
        providers::Union{Nothing, AbstractDict} = nothing,
        model_name::Union{Nothing, AbstractString} = nothing,
        metaparameters::AbstractDict = Dict{String, Int}(),
        base_path::AbstractString = pwd(),
        compiler::Symbol = :native,
        sample_time::Union{Nothing, Real} = nothing,
        runtime_array_parameters::Bool = false,
        strip = (),
        # ---- Julia extension seam (§2.5.2) ----
        const_arrays::AbstractDict = Dict{String, Any}(),
        param_arrays::AbstractDict = Dict{String, Any}(),
        inspect::Union{Nothing, BuildInspection} = nothing,
        materialize_out::Union{Nothing, DiscreteMaterializer} = nothing,
        pushdown_rewrite::Bool = false,
        program_build::Bool = false,
        seed_ic! = nothing,
        sinks = (),
        snapshot = state_snapshot,
        pre_write = () -> nothing,
        checkpoint_predicates = (),
        checkpoint_sinks = nothing,
        terminate_on_checkpoint::Bool = true
    )
    # The compiler is resolved before anything else runs: `compiler_unknown` and
    # `compiler_unavailable` are answers about the REQUEST, and making the
    # caller wait through a load and a flatten to hear one would be a worse
    # diagnostic for no gain.
    _check_compiler(compiler)
    span = (Float64(tspan[1]), Float64(tspan[2]))
    req = _ProblemRequest(
        span, p, u0, providers, model_name === nothing ? nothing : String(model_name),
        metaparameters, String(base_path), compiler,
        sample_time === nothing ? span[1] : Float64(sample_time),
        runtime_array_parameters, const_arrays, param_arrays, inspect, materialize_out,
        pushdown_rewrite, program_build, seed_ic!, sinks, snapshot, pre_write,
        checkpoint_predicates, checkpoint_sinks, terminate_on_checkpoint
    )
    classes = _strip_classes(strip)
    isempty(classes) || return _stripped_problem(input, req, classes)
    _refuse_program_build_request(req)
    # `:mtk` builds a ModelingToolkit `System` rather than this package's own
    # evaluator (EarthSciASTMTKExt). The plan above has already answered
    # `compiler_unavailable` if ModelingToolkit is not loaded.
    compiler === :mtk && return _mtk_problem(input, req)
    return _esm_problem(input, req)
end

# What an `esm_problem` call asked for: its keywords, with the span and the
# sample time resolved.
struct _ProblemRequest
    span::Tuple{Float64, Float64}
    p::AbstractDict
    u0::Any
    providers::Union{Nothing, AbstractDict}
    model_name::Union{Nothing, String}
    metaparameters::AbstractDict
    base_path::String
    compiler::Symbol
    sample_time::Float64
    runtime_array_parameters::Bool
    const_arrays::AbstractDict
    param_arrays::AbstractDict
    inspect::Union{Nothing, BuildInspection}
    materialize_out::Union{Nothing, DiscreteMaterializer}
    pushdown_rewrite::Bool
    program_build::Bool
    seed_ic!::Any
    sinks::Any
    snapshot::Any
    pre_write::Any
    checkpoint_predicates::Any
    checkpoint_sinks::Any
    terminate_on_checkpoint::Bool
end

function _refuse_program_build_request(req::_ProblemRequest)
    req.program_build || return nothing
    (req.compiler === :native || req.compiler === :interpreter) || throw(
        SimulateError(
            "esm_problem: program_build = true needs compiler = :native or :interpreter, " *
                "the compilers a program is built with (API_SPEC §5.8); this call names :$(req.compiler)",
            ERROR_CODES.COMPILER_UNAVAILABLE
        )
    )
    # A program has no discrete-cadence cut, so a build as one leaves a
    # materializer empty: a caller's would never be filled.
    req.materialize_out === nothing || throw(
        SimulateError(
            "esm_problem: program_build = true takes no materialize_out: a Problem built as " *
                "its program has no discrete-cadence cut, so nothing would fill the materializer",
            ERROR_CODES.INVALID_ARGUMENT
        )
    )
    return nothing
end

# `esm_problem(…; strip)`: the document with the constructs of `classes`
# removed (`_strip_document`), built as any other, with what was removed on the
# Problem. A coupling-level event the stripped document keeps is not refused
# when its class was taken.
function _stripped_problem(input, req::_ProblemRequest, classes::Vector{String})
    req.compiler in (:native, :interpreter) || throw(
        SimulateError(
            "esm_problem: `strip` serves the :native and :interpreter compilers (API_SPEC " *
                "§5.8, \"Strip and expose\"); this call names :$(req.compiler)",
            ERROR_CODES.COMPILER_UNAVAILABLE
        )
    )
    _refuse_program_build_request(req)
    input isa Union{AbstractString, AbstractDict, EsmFile} || throw(
        SimulateError(
            "esm_problem: `strip` removes constructs from a document; pass a path, a " *
                "native Dict or an EsmFile, not a $(typeof(input))",
            ERROR_CODES.INVALID_ARGUMENT
        )
    )
    # The providers are described and any loader extent discovered before the
    # load, which closes the metaparameters a discovered extent binds.
    found = _discover_extents(input, req)
    file = input isa EsmFile ? input :
        input isa AbstractDict ?
        load_document(input; base_path = req.base_path, metaparameters = found.metaparameters) :
        _load_run_path(String(input), found.metaparameters)
    sfile, sobj = _strip_document(file, classes)
    prob = _esm_problem(sfile, req; strip_taken = classes, found = found)
    if !isempty(sobj.z_layout)
        sflat = prob.build.seed.prep.flat
        params = Dict{String, Float64}(
            k => Float64(v.default) for (k, v) in sflat.parameters if v.default isa Real
        )
        for (k, v) in req.p
            haskey(params, String(k)) && (params[String(k)] = Float64(v))
        end
        append!(sobj.z0, _z_starting_values(sflat, sobj.z_layout, params, req.span[1]))
    end
    return _with(prob; stripped = sobj)
end

# The providers of `req` described (`_provider_traits`) and the loader extents
# they discover, with the metaparameters those close: what every load of the
# run binds. A loader that measures its OWN record count is sampled FIRST,
# because a discovered extent CLOSES a metaparameter and a load binds
# metaparameters at the loader API (esm-spec §9.7.6 site 3). The sampled arrays
# are kept and reused at injection, so a zipped inventory is decoded once.
function _discover_extents(input, req::_ProblemRequest)
    traits = _describe_providers(req.providers)
    metaparams, discovered = _discover_loader_extents(
        req.providers, traits, req.metaparameters, req.sample_time
    )
    # `load` is where a metaparameter closes, so an ALREADY-loaded carrier has
    # closed them — silently ignoring a binding (the caller's or a loader's) is
    # exactly the failure this seam exists to prevent.
    if !isempty(metaparams) && !(input isa AbstractString || input isa AbstractDict)
        why = isempty(discovered) ? "" :
            string(
                ". ", join(sort!(collect(keys(discovered))), ", "),
                " DISCOVERED its own extent, which only a not-yet-loaded ",
                "document can be sized by"
            )
        throw(
            SimulateError(
                "esm_problem: metaparameters $(sort!(collect(keys(metaparams)))) must be bound " *
                    "at the loader API, but `input` is a $(typeof(input)) whose metaparameters " *
                    "are already closed — pass the path or the native Dict to esm_problem (and drop " *
                    "the pre-`load`), or bind them in that `load` call instead" * why,
                ERROR_CODES.INVALID_ARGUMENT
            )
        )
    end
    return (; traits, metaparameters = metaparams, discovered)
end

# The `:native`, `:interpreter` and `:xla` construction (`esm_problem`). `found`
# is `_discover_extents(input, req)`, already run by a caller that loads the
# document itself (`strip`).
function _esm_problem(
        input, req::_ProblemRequest; strip_taken = String[],
        found = _discover_extents(input, req)
    )
    compiler = req.compiler
    span = req.span
    t_sample = req.sample_time
    providers = req.providers
    traits, metaparams, discovered = found.traits, found.metaparameters, found.discovered

    # ---- the projection-pushdown prepass, BEFORE flatten ----
    # The desugar matches the AUTHORED (not yet flattened) model, and running it
    # here puts the provenance record in hand BEFORE the provider
    # classification below needs it.
    pd_coupling = Pair{String, String}[]
    if req.pushdown_rewrite
        input, matched = _pushdown_input(input, req.model_name, metaparams, req.base_path)
        if matched
            for (k, gate) in _pushdown_provider_gates(input, providers)
                # A discovered extent and a record-derived gate are mutually
                # exclusive: a gated slab's extent belongs to the gating set,
                # which value invention has not materialized yet. (The
                # provider's OWN gate is caught in the pre-pass; this catches
                # the gate the rewrite record derives, which only exists now.)
                haskey(discovered, k) && throw(
                    SimulateError(
                        "provider '$k' both GATES on a derived index set and declares the extent " *
                            "metaparameter '$(traits[k].extent_metaparameter)'; a gated " *
                            "slab's extent is the gating set's, not a discovered one",
                        ERROR_CODES.PROVIDER_EXTENT_CONFLICT
                    )
                )
                traits[k] = _with_gate(traits[k], _GateSpec(gate, k))
            end
            pd_coupling = _pushdown_coupling_pairs(input)
        end
    end
    supplied = Set{String}(
        string(k) for d in (req.const_arrays, req.param_arrays, providers)
            if d !== nothing for k in keys(d)
    )
    prep = _prepare_run(
        input; metaparameters = metaparams, base_path = req.base_path,
        supplied_names = supplied, strip_taken = strip_taken
    )
    # The state spellings an `operator_compose` renaming match DELETED (issue
    # #230). A caller holding `"Sink.O3"` after the merge folded it into
    # `Chem.O3` addresses a state that has moved, and nothing rewrites the
    # strings a caller holds, so its keys are resolved onto the survivors here.
    merged_renames = OrderedDict{String, String}(_merged_renames(prep))
    # The parameter each provider feeds, under the name the build reads
    # (`_provider_routing`): a bare `s` lands on `Fed.s`.
    provider_targets, provider_shadowed = providers === nothing ?
        (Dict{String, String}(), Set{String}()) :
        _provider_routing(
            prep, _routable_provider_keys(traits);
            model_name = req.model_name
        )
    _refuse_provider_registry_overlap(
        provider_targets, prep,
        "const_arrays" => req.const_arrays, "param_arrays" => req.param_arrays;
        model_name = req.model_name
    )
    # The declared shape every whole-bound provider sample is checked against
    # (`forcing_from_sample`), resolved now that discovery has closed the
    # loader extents.
    provider_shapes = providers === nothing ? Dict{String, Vector{Int}}() :
        _provider_declared_shapes(
            prep.flat,
            (get(provider_targets, String(k), String(k)) for k in keys(providers))
        )

    # esm-spec §6.6.2: a `p` binding is a scalar, or — for a SHAPED parameter —
    # INLINE ARRAY DATA (a row-major nested array supplying the whole column).
    # `_coerce_inline_value` normalizes both; the build then routes the array
    # ones onto the const-array channel (`_register_inline_array_parameters`).
    overrides = _resolve_merged_renames(
        merged_renames,
        Dict{String, Any}(String(k) => _coerce_inline_value(v) for (k, v) in req.p)
    )
    u0 = req.u0
    u0 = u0 === nothing || isempty(merged_renames) ? u0 :
        (u0 isa AbstractDict ? _resolve_merged_renames(merged_renames, u0) : u0)

    merged_const, merged_param, discrete_providers, ic_data, gated_providers =
        _sample_providers(
        req, traits, discovered, provider_targets, provider_shadowed, provider_shapes
    )
    # Every whole-bound array is in hand: an unshaped parameter fed array data
    # takes the data's shape now, before anything reads the run document.
    prep = _with_data_shapes(prep, merged_const, merged_param)
    file = _run_file(prep)

    # The pushdown path's name aliasing. The build's pre-passes
    # (`_derive_binning_coords`, value invention) and `observed_field` read the
    # flattened VARIABLES' expressions, which keep namespaced pre-coupling names:
    # the caller's and the providers' arrays are registered under those
    # spellings too (same objects, no copies).
    if req.pushdown_rewrite
        _inject_pushdown_aliases!(merged_const, file, pd_coupling)
        _inject_pushdown_aliases!(merged_param, file, pd_coupling)
    end

    # The discrete-cadence materializer (`_problem_build_run`): the caller's,
    # or a fresh one.
    dm = _problem_materializer(req.materialize_out)
    # What the build produces besides the right-hand side; the Problem owns it.
    # A caller's `inspect` record is claimed now and pointed at it when the
    # build ends, refused or not.
    products = BuildProducts()
    req.inspect === nothing || _take_inspection!(req.inspect)
    # The parameter partition sink: the build
    # fills it with name → `:numeric` / `:structural` / `:const_folded` /
    # `:forcing`, derived from which names its BUILD-TIME consumers read. It is
    # what lets `remake(prob; p = …)` accept the numeric half instead of refusing
    # every override.
    param_classes = Dict{String, Symbol}()
    # `:xla` refuses live forcing buffers, and every one a caller or a discrete
    # provider binds is already in `merged_param`: refuse those now rather than
    # after a build that can take hours. src/compiler_xla.jl keeps the check on
    # the build product too, for the discrete-materializer caches only the
    # build creates.
    compiler === :xla && _xla_refuse_before_build(merged_param)
    # What a program of this Problem is built from (`rhs_program`). It holds the
    # prepared run and the merged const registry, so a program is lowered from
    # the document this build compiled, without loading it again.
    seed = compiler in (:native, :interpreter) ? _ProgramSeed(
            prep, compiler, req.model_name, overrides, merged_const, merged_param,
            gated_providers, t_sample, req.runtime_array_parameters, span[1], ic_data
        ) : nothing
    # `:xla` is built OUT OF PLACE — the compiled tree-walk intermediate
    # representation is what the direct StableHLO emitter lowers — and the
    # executable is wrapped back into the in-place `f!` this Problem's surface
    # promises, just below. Every other compiler builds the in-place evaluator
    # directly. See src/compiler_xla.jl.
    # With `program_build`, the Problem's right-hand side IS its whole-model
    # program, built once here; `rhs_program(prob)` returns it rather than
    # lowering the model again.
    shared_program = nothing
    local f!, u0_built, p_built, var_map
    try
        if req.program_build
            shared_program, u0_built, p_built = _problem_program(
                seed; products = products, param_classes = param_classes, caller_u0 = u0
            )
            f!, var_map = shared_program.f!, shared_program.internal
            _publish_program_slots!(products, shared_program, merged_param)
        else
            f!, u0_built, p_built, _tspan, var_map = _problem_build_run(
                file;
                compiler = compiler,
                form = compiler === :xla ? :oop : :inplace,
                model_name = req.model_name,
                parameter_overrides = overrides,
                const_arrays = merged_const,
                param_arrays = merged_param,
                products = products,
                materialize_out = dm,
                param_classes = param_classes,
                runtime_array_parameters = req.runtime_array_parameters,
                gated_providers = gated_providers,
                sample_time = t_sample,
                ic_t0 = span[1], ic_data = ic_data, caller_u0 = u0,
                seed_ic! = req.seed_ic!
            )
        end
    finally
        req.inspect === nothing || _publish_inspection!(req.inspect, products)
    end

    if compiler === :xla
        f! = _xla_problem_rhs(
            f!, var_map, u0_built, p_built,
            products.compiler_report
        )
    end

    # ---- initial state: the document's own ICs, then the caller's -----------
    # Under the build's plan: a `seed_ic!` hook (`seed_expression_ic!`) is an
    # evaluation for this problem, and §2.5.10 puts the seed under the same
    # refusal rule as the right-hand side.
    u0_run = _with_compiler_plan(_plan(compiler)) do
        _seed_u0(u0_built, var_map, u0, req.seed_ic!)
    end
    # `_problem_build_run` refused a state with no starting value; a program
    # build is checked here.
    req.program_build &&
        _refuse_missing_initial_values(products.unvalued_slots, u0_built, var_map, u0, req.seed_ic!)
    # The same seeding at another start of the run, when the document's `ic`
    # right-hand sides read it: the build's re-seed with each discrete
    # provider sampled at the new start, then the caller's `u0` and hook.
    ic_restart = _ic_restart(
        products.ic_reseed, discrete_providers, provider_shapes, var_map, u0, req.seed_ic!,
        compiler
    )

    cbs = _problem_callbacks(
        req, isempty(discrete_providers) ? nothing :
            (
                providers = discrete_providers, buffers = merged_param, owner = dm,
                post_refresh = dm.materialize!,
            )
    )
    prob = EsmProblem(;
        f!, u0 = u0_run, tspan = span, p = p_built, var_map, param_buffers = merged_param,
        discrete_providers, dm, n_equations = _doc_equation_count(file),
        buffer_time = Ref(t_sample), output_meta = derive_output_meta(file), run_file = file,
        param_classes, build = _ProblemBuild(products, seed, shared_program),
        callback = cbs.callback, tstops = cbs.tstops, save_everystep = cbs.save_everystep,
        sinks = cbs.sinks, lifecycle_sinks = cbs.lifecycle_sinks, merged_renames, ic_restart
    )
    cbs.prob_ref[] = prob
    return prob
end

# Provider injection (DESIGN pde_simulation_pipeline §2). Loaded fields enter
# through the Provider seam, never as raw `const_arrays` keyed by internal
# consumer names. CONST providers (empty `provider_refresh_times`) are
# materialized ONCE at build time into `const_arrays` keyed by their declared
# loader variable name — reachable when scoped-`ic` folds `Loader.*` into u0
# and when the loader→consumer `variable_map` binding routes a consumer gather
# to the loader name. DISCRETE providers ride the refresh callback. GATED
# providers are deferred: fetched pre-sliced after value invention
# (`_build_run`).
#
# Returns `(merged_const, merged_param, discrete_providers, ic_data,
# gated_providers)`: the caller's `const_arrays` and `param_arrays` with the
# providers' data added, the discrete providers by the buffer they refresh, the
# data-fed values at the run's start where they differ from the sample time,
# and the deferred gated providers with their gates.
function _sample_providers(
        req::_ProblemRequest, traits::AbstractDict{String, _ProviderTraits}, discovered,
        provider_targets, provider_shadowed, provider_shapes
    )
    t_sample = req.sample_time
    merged_const = Dict{String, Any}(String(k) => v for (k, v) in req.const_arrays)
    merged_param = Dict{String, Any}(String(k) => v for (k, v) in req.param_arrays)
    discrete_providers = Dict{String, Any}()
    ic_data = Dict{String, Any}()
    gated_providers = Dict{String, _GatedProvider}()
    req.providers === nothing &&
        return merged_const, merged_param, discrete_providers, ic_data, gated_providers
    sample(prov, t, k, tk) = forcing_from_sample(
        provider_sample(prov, t), k; shape = get(provider_shapes, tk, nothing)
    )
    for (rawk, prov) in req.providers
        k = String(rawk)
        # A key that lost to an exact key for the same parameter is not read
        # (esm-spec §6.6.2, as for `parameter_overrides`).
        k in provider_shadowed && continue
        tk = get(provider_targets, k, k)
        tr = traits[k]
        if haskey(discovered, k)
            # Already materialized by the extent-discovery pre-pass; never
            # sampled twice.
            _put_provider_const!(
                merged_const, k, tk,
                forcing_from_sample(discovered[k], k; shape = get(provider_shapes, tk, nothing))
            )
        elseif tr.gate !== nothing
            # Deferred: value invention must derive the gating set's members
            # before the rows to fetch are known. The gate is the provider's
            # own or the one the pushdown rewrite's record derives.
            gated_providers[k] = _GatedProvider(prov, tr.gate)
        elseif tr.is_const
            _put_provider_const!(merged_const, k, tk, sample(prov, t_sample, k, tk))
        else
            # DISCRETE: a LIVE forcing buffer seeded at the initial tick, in
            # `param_arrays`. That makes the loader field a `live_param`, so the
            # setup partition (`_geometry_setup_vars`) taints any in-model regrid
            # over it: `F_tgt = A_ij ⊗ F_src / A_j` keeps its overlap WEIGHTS at
            # setup but stays a runtime observed / discrete-materialized cache,
            # instead of a build-once setup const where the (still-unbound) live
            # `F_src` would fail. The refresh callback then rewrites this SAME
            # buffer in place at each cadence tick.
            merged_param[tk] = sample(prov, t_sample, k, tk)
            discrete_providers[tk] = prov
            # An `ic` right-hand side reads the record at the run's start,
            # whatever `sample_time` the forcing holds (esm-libraries-spec
            # §2.5.2); sampled again only when the two differ.
            t_sample == req.span[1] || (ic_data[tk] = sample(prov, req.span[1], k, tk))
        end
    end
    _rekey_discrete_providers!(
        discrete_providers, filter(((k, n),) -> k != n, provider_targets)
    )
    return merged_const, merged_param, discrete_providers, ic_data, gated_providers
end

# The problem's callback set (§2.5.4), composed at construction because a
# callback that refreshes provider buffers or writes an output stream belongs to
# the DOCUMENT, not to a particular run's tolerances. `solve(prob; callback=…)`
# replaces the whole set; `callbacks(prob)` reads it back so a caller can extend
# it. `refresh` is `(; providers, buffers, owner, post_refresh)` for a document with
# discrete providers, else `nothing`.
#
# Returns `(; callback, tstops, save_everystep, sinks, lifecycle_sinks,
# prob_ref)`; `prob_ref[]` is to be set to the Problem once it exists, which is
# how a sink naming observed fields reads them through the Problem's compiled
# observed program.
function _problem_callbacks(req::_ProblemRequest, refresh)
    cbs = Any[]
    tstops = Float64[]
    if refresh !== nothing
        cb, ts = build_refresh_callback(;
            providers = refresh.providers,
            buffers = RefreshBuffers(refresh.buffers),
            owner = refresh.owner,
            post_refresh = refresh.post_refresh
        )
        push!(cbs, cb)
        tstops = _union_tstops(tstops, ts)
    end
    # Streaming output sinks (streaming-output-sinks RFC §16.5): the output
    # callback's tstops join the refresh tstops, so input refresh and output
    # write stop the solver at the union of their anchors, and
    # `save_everystep = false` stops the dense in-memory trajectory: the sink IS
    # the trajectory store.
    sink_vec = collect(Any, req.sinks)
    save_everystep = true
    prob_ref = Ref{Any}(nothing)
    snapshot = _observed_snapshot(req.snapshot, sink_vec, prob_ref)
    if !isempty(sink_vec)
        out_cb, out_tstops = build_output_callback(;
            sinks = sink_vec, snapshot = snapshot, pre_write = req.pre_write
        )
        tstops = _union_tstops(tstops, out_tstops)
        push!(cbs, out_cb)
        save_everystep = false
    end
    # Predicate-driven checkpointing (streaming-output-sinks RFC §10, §16.7): a
    # full-state checkpoint to `checkpoint_sinks` (default: `sinks`) and a flush
    # of the durable barrier the instant any predicate fires, optionally
    # terminating for a clean pre-preemption exit. Interval-only checkpointing
    # rides the ordinary output callback above.
    ck_vec = req.checkpoint_sinks === nothing ? sink_vec : collect(Any, req.checkpoint_sinks)
    if !isempty(collect(Any, req.checkpoint_predicates))
        push!(
            cbs, build_checkpoint_callback(;
                sinks = ck_vec, predicates = req.checkpoint_predicates, snapshot = snapshot,
                pre_write = req.pre_write, terminate_on_fire = req.terminate_on_checkpoint
            )
        )
        save_everystep = false
    end
    return (;
        callback = _compose_callbacks(cbs), tstops, save_everystep, sinks = sink_vec,
        lifecycle_sinks = _distinct_sinks(sink_vec, ck_vec), prob_ref,
    )
end

# `esm_problem`'s initial-state seeding as a function of the start of the run
# (`EsmProblem.ic_restart`): `seed(t0, overrides)`, where `overrides` are the
# `u0` overrides `remake` has applied since, each on top of the last. `nothing`
# when the build's initial state does not depend on the start.
function _ic_restart(reseed, discrete_providers, provider_shapes, var_map, u0, seed_ic!, compiler)
    reseed === nothing && return nothing
    providers = copy(discrete_providers)
    seed = function (t0::Float64, overrides = ())
        data = Dict{String, Any}(
            k => forcing_from_sample(
                provider_sample(prov, t0), k; shape = get(provider_shapes, k, nothing)
            ) for (k, prov) in providers
        )
        return _with_compiler_plan(_plan(compiler)) do
            out = _seed_u0(reseed(t0, data), var_map, u0, seed_ic!)
            for o in overrides
                out = _seed_u0(out, var_map, o, nothing)
            end
            out
        end
    end
    return (; seed, overrides = ())
end

# A Problem built as its program reads every externally fed parameter from a
# live buffer, and the program's build registered one, filled with the
# parameter's value, for each the Problem holds none for (`_program_build`).
# Nothing refreshes those, so their values are the build's constants: publish
# them into the Problem's build products as the default build does its folded and
# const-bound parameters, so a build-time observed read (`observed_field`
# through the cellwise evaluator) finds them: an array into `const_arrays`; a
# scalar into `params` and, as the one-cell array the program reads it as
# (`_scalar_slots_to_arrays`), into `const_arrays`.
function _publish_program_slots!(products::BuildProducts, prog, live::AbstractDict)
    d = default_forcing_set(prog)
    for (k, s) in enumerate(forcing_slots(prog))
        haskey(live, s.name) && continue
        b = d.bufs[k]
        isempty(s.shape) && (products.params[s.name] = b[1])
        products.const_arrays[s.name] = isempty(s.shape) ? copy(b) : reshape(copy(b), s.shape...)
    end
    return nothing
end

# The output callback's snapshot for `sinks`: the caller's own when it passed
# one, or when no sink names an observed field (`sink_observed_names`);
# otherwise the state snapshot with each named field read at the record's
# state and time, `observed_field(prob, name; u, t)` — the flat row-major
# vector that returns — with the integrator's parameters, so a solve of a
# `remake`d problem (which shares this callback) records its own `p`.
# `prob_ref` holds the problem once it is built.
function _observed_snapshot(snapshot, sinks, prob_ref::Base.RefValue{Any})
    snapshot === state_snapshot || return snapshot
    names = String[]
    for s in sinks, n in sink_observed_names(s)
        String(n) in names || push!(names, String(n))
    end
    isempty(names) && return snapshot
    return function (integrator)
        u = integrator.u
        t = Float64(integrator.t)
        obs = Dict{String, Array}(
            n => _observed_field_read(
                prob_ref[], n, Array(u), t,
                integrator.p
            )
                for n in names
        )
        return StateSnapshot(t, state_snapshot(integrator), obs)
    end
end

# The discrete-cadence materialization sink a build always has: the caller's
# (reused, so it stays inspectable) or a fresh one. With it, a state-free derived
# field over a live forcing buffer (a regrid→physics stack) is cut out of the
# per-step right-hand side into a cache filled once per refresh, and a
# parameter-only array observed is filled once at setup; with no such field it
# changes nothing.
_problem_materializer(dm) = dm === nothing ? DiscreteMaterializer() : dm

"""
    _problem_build_run(file::EsmFile; products, materialize_out = nothing,
                       param_classes = Dict(), caller_u0 = nothing, seed_ic! = nothing,
                       kwargs...)

The build `esm_problem` runs on its run file (`_run_file`), which
`Internal.build` runs too, so the two compile the same thing: `_build_run` with
a discrete-cadence materializer (`_problem_materializer`) and a parameter
partition sink, then the refusal of an ODE state nothing gives a starting value
(esm-spec §11.4; a caller `u0`, an `initial_conditions` entry or `seed_ic!`
gives one). `kwargs` are the build's own.
"""
function _problem_build_run(
        file::EsmFile; products::BuildProducts, materialize_out = nothing,
        param_classes::AbstractDict = Dict{String, Symbol}(), caller_u0 = nothing,
        seed_ic! = nothing, kwargs...
    )
    out = _build_run(
        file; products = products, materialize_out = _problem_materializer(materialize_out),
        param_classes = param_classes, caller_u0 = caller_u0, kwargs...
    )
    _, u0_built, _, _, var_map = out
    _refuse_missing_initial_values(products.unvalued_slots, u0_built, var_map, caller_u0, seed_ic!)
    return out
end

# The seeded initial state: the build's own `u0`, then the caller's `u0`
# argument (a Dict of per-element / broadcast overrides, or a whole vector),
# then the `seed_ic!` hook. Always a fresh vector — the build's `u0` is never
# mutated, so `remake(prob; u0 = …)` cannot disturb the problem it came from.
# esm-spec §11.4: an unknown that needs a starting value and has none — no
# `default`, no initial condition, no `ic` equation, no caller `u0` — is an
# error when the problem is built. The build reports the slots it could not
# seed (`BuildProducts.unvalued_slots`, holding a 0.0 placeholder); a caller
# `u0` that names them, a whole replacement vector, or a `seed_ic!` hook covers
# them.
function _refuse_missing_initial_values(
        unvalued::Vector{Int}, u0_built::Vector{Float64},
        var_map::AbstractDict, u0, seed_ic!
    )
    isempty(unvalued) && return nothing
    (u0 isa AbstractVector || seed_ic! !== nothing) && return nothing
    probe = copy(u0_built)
    probe[unvalued] .= NaN
    u0 isa AbstractDict && !isempty(u0) && _apply_initial_conditions!(probe, var_map, u0)
    missing_slots = Set(s for s in unvalued if isnan(probe[s]))
    isempty(missing_slots) && return nothing
    # A state is refused only when NONE of its slots got a value: cells left
    # over in a partly seeded one are layout (a grid widened past the cells the
    # document names) and keep their placeholder.
    base(k) = String(first(split(String(k), '['; limit = 2)))
    partly = Set(base(k) for (k, s) in var_map if !(s in missing_slots))
    names = sort!(
        unique!(
            String[
                base(k) for (k, s) in var_map
                    if s in missing_slots && !(base(k) in partly)
            ]
        )
    )
    isempty(names) && return nothing
    shown = join(("'$(n)'" for n in first(names, 5)), ", ") * (length(names) > 5 ? ", …" : "")
    throw(
        TreeWalkError(
            "E_TREEWALK_MISSING_INITIAL_VALUE",
            "no starting value for $(length(names)) unknown(s) ($(shown)): the unknown " *
                "declares no `default`, and no initial condition, `ic` equation or caller " *
                "`u0` sets it. An unknown with no starting value is an error when a problem " *
                "is built (esm-spec §11.4). To supply it, pass `u0 = Dict(\"$(first(names))\" " *
                "=> value)` to `esm_problem`, or declare a `default` on the unknown."
        )
    )
end

function _seed_u0(u0_built::Vector{Float64}, var_map::AbstractDict, u0, seed_ic!)
    out = copy(u0_built)
    if u0 isa AbstractDict
        isempty(u0) || _apply_initial_conditions!(out, var_map, u0)
    elseif u0 isa AbstractVector
        length(u0) == length(out) || throw(
            SimulateError(
                "u0 has $(length(u0)) elements but the flattened state vector has " *
                    "$(length(out)); pass a Dict of named overrides to set a subset",
                ERROR_CODES.ARRAY_SHAPE_MISMATCH
            )
        )
        out = collect(Float64, u0)
    elseif u0 !== nothing
        throw(
            SimulateError(
                "u0 must be an AbstractDict of named overrides or an AbstractVector " *
                    "replacing the whole state, got a $(typeof(u0))",
                ERROR_CODES.INVALID_ARGUMENT
            )
        )
    end
    seed_ic! === nothing || seed_ic!(out, var_map)
    return out
end


notify_forcing_refresh!(prob::EsmProblem) = _bump_epoch!(prob.build.products.forcing_epoch)

function notify_forcing_refresh!(prob::EsmProblem, name::AbstractString)
    haskey(prob.param_buffers, name) || throw(
        ArgumentError(
            "notify_forcing_refresh!: '$name' is not a live forcing buffer of this " *
                "problem; its buffers are " * join(sort!(collect(keys(prob.param_buffers))), ", ")
        )
    )
    return notify_forcing_refresh!(prob)
end

# Re-seed the DISCRETE forcing buffers at the run's t0 and recompute the
# discrete-materialized caches, so every run starts from freshly initialized
# refresh state — a previous run's callback mutates the buffers in place, and a
# different start time needs a different initial tick. Skipped when the buffers
# are pristine and already hold the sample at t0 (the first solve of a problem
# built at that t0 — no double sample). Called from the solve/init seam, which
# is the only place that knows a run is starting.
function _prepare_run!(prob::EsmProblem, t0::Float64)
    isempty(prob.discrete_providers) && return nothing
    if prob.dirty[] || prob.buffer_time[] != t0
        for (k, prov) in prob.discrete_providers
            buf = prob.param_buffers[k]::Array{Float64}
            _write_forcing!(buf, k, provider_sample(prov, t0))
        end
        notify_forcing_refresh!(prob)
        prob.dm.materialize!()   # discrete caches must see the re-seeded buffers
        prob.buffer_time[] = t0
    end
    prob.dirty[] = true          # this run's refresh callback will mutate them
    return nothing
end

"""
    parameter_classes(prob::EsmProblem) -> Dict{String,Symbol}

The parameter partition of the build behind `prob` — `:numeric`, `:structural`,
`:const_folded`, `:forcing`. See the [`parameter_classes`](@ref) docstring on the
[`BuildInspection`](@ref) method for what each class means and how it is derived.
"""
parameter_classes(prob::EsmProblem) = prob.param_classes

# A readable name list for an error: a real model carries dozens of parameters
# and dumping all of them buries the diagnostic that matters.
function _elide_names(ns::AbstractVector{String}, n::Int = 12)
    length(ns) <= n && return join(ns, ", ")
    return join(ns[1:n], ", ") * ", … ($(length(ns)) total; see parameter_classes(prob))"
end

# One override's refusal message, naming the parameter AND its class AND why the
# class cannot ride `p`. Each class fails for a different reason, and saying
# which is the whole point of the partition: "parameters bake at build time"
# was true of all of them and useful about none.
function _param_class_refusal(name::AbstractString, cls::Symbol)
    what = cls === :structural ?
        "STRUCTURAL: its value is read at BUILD time (setup geometry, " *
        "value-invention index-set extents, binning coordinates, join key columns, " *
        "ic() folds), " *
        "where it can decide the SHAPE of the problem — length(u0), the compiled " *
        "kernels. A value swapped into `p` at solve time would contradict the one " *
        "already baked into the build" :
        cls === :const_folded ?
        "CONST-FOLDED DATA: it is supplied as const data (a const provider / a " *
        "`const_arrays` entry), frozen into the build and inlined into the RHS, so " *
        "it never reaches the runtime `p` at all. An override here would be silently " *
        "ignored — and so is a derivative: ∂/∂(this) is an unconditional zero that a " *
        "finite-difference check on its declared default would CONFIRM" :
        cls === :forcing ?
        "LIVE FORCING DATA: it is bound to a forcing buffer that a discrete provider " *
        "rewrites in place at each refresh, so it never reaches the runtime `p`. " *
        "Change the provider or write the buffer" :
        "not a solve-time parameter of this build ($(cls))"
    fix = cls === :forcing ?
        "supply a different provider / write `prob.param_buffers[\"$name\"]`" :
        "call esm_problem(input, tspan; p = Dict(\"$name\" => …)) again — a " *
        "structural change is an explicit rebuild, never something hidden " *
        "inside a `p` swap"
    return "remake(prob::EsmProblem; p): '$name' is $what. " *
        "To change it, $fix."
end

"""
    remake_parameters(prob::EsmProblem, overrides) -> p

The parameter carrier `prob.p` with the `:numeric` `overrides` applied — the
value `remake(prob; p = overrides)` installs, exposed on its own as a tier-2
extension seam for callers that drive `SciMLBase.remake` on their own problem.

```julia
prob2 = remake(prob; p = Dict("Emis.scale" => 2.0))          # the stable path
p2    = remake_parameters(prob, Dict("Emis.scale" => 2.0))   # the seam
```

This is deliberately a `p` SWAP and nothing more: `remake` exists precisely so a
sensitivity analysis can vary `p` without rebuilding `f`, and overloading it to
re-run the build would make gradients impossible by construction. So it is cheap
(a `NamedTuple` merge, no build), and AD-transparent — each override keeps its
own type, so a `ForwardDiff.Dual` handed in here stays a `Dual` in `p` and
`∂(solution)/∂(parameter)` flows through the same compiled RHS.

Only `:numeric` parameters can be swapped. A `:structural`, `:const_folded` or
`:forcing` override throws a [`SimulateError`](@ref) naming the parameter and its
class — changing one of those is an explicit rebuild, because it changes the
build, not just a number the build reads. Keys may be spelled locally
(`"scale"`) or namespaced (`"NEIRegrid.scale"`), exactly as `esm_problem`'s `p`
overrides are; an unknown or ambiguous key throws rather than being dropped.
"""
function remake_parameters(prob::EsmProblem, overrides::AbstractDict)
    isempty(overrides) && return prob.p
    classes = prob.param_classes
    pm = param_map(prob.p)
    names = Set{String}(keys(classes))
    union!(names, keys(pm))
    normalized, unknown, ambiguous, collisions = canonicalize_keys(Any, NameTable(names), overrides)
    isempty(collisions) || throw(
        SimulateError(
            _override_collision_message(
                "remake(prob; p)", "parameter",
                first(sort!(collect(collisions), by = first))...
            ),
            ERROR_CODES.OVERRIDE_KEY_CONFLICT
        )
    )
    isempty(unknown) || throw(
        SimulateError(
            "remake(prob; p): no parameter named " *
                join(("'" * k * "'" for k in sort(unknown)), ", ") *
                " in the problem (keys may be local or namespaced; a name the " *
                "flattener's coupling rewired onto a loader variable is spelled by its " *
                "SURVIVING name). Known: " * _elide_names(sort(collect(names))),
            ERROR_CODES.UNKNOWN_OVERRIDE_KEY
        )
    )
    isempty(ambiguous) || throw(
        SimulateError(
            "remake(prob; p): ambiguous parameter key(s) " *
                join(
                (
                    "'" * k * "' (matches " * join(sort(v), ", ") * ")"
                        for (k, v) in sort(collect(ambiguous), by = first)
                ), "; "
            ) *
                "; spell the namespaced name.",
            ERROR_CODES.OVERRIDE_KEY_AMBIGUOUS
        )
    )
    syms = Symbol[]
    vals = Any[]
    for name in sort(collect(keys(normalized)))
        cls = get(classes, name, haskey(pm, name) ? :numeric : :unclassified)
        cls === :numeric || throw(SimulateError(_param_class_refusal(name, cls), ERROR_CODES.PARAMETER_NOT_OVERRIDABLE))
        # A `:numeric` parameter is by definition a slot of `p`; if it somehow is
        # not, refuse rather than silently drop the override.
        haskey(pm, name) || throw(
            SimulateError(
                "remake(prob; p): '$name' classifies :numeric but is not a " *
                    "slot of the problem's `p` — refusing to apply an override that would " *
                    "have no effect (this is a build bug; please report it).",
                ERROR_CODES.INTERNAL_ERROR
            )
        )
        push!(syms, Symbol(name))
        push!(vals, normalized[name])
    end
    # `merge` keeps the FIRST tuple's key order, which is the build's own
    # parameter order (`param_map`) and the order every `_NK_PARAM` node's `idx`
    # was minted against. Values keep their own types (a `Dual` stays a `Dual`).
    return merge(prob.p, NamedTuple{Tuple(syms)}(Tuple(vals)))
end

# The distinct sinks across the diagnostic + checkpoint sets, by object identity —
# a sink that is BOTH a diagnostic and checkpoint target opens/closes exactly once.
function _distinct_sinks(sinks, ck_sinks)
    out = Any[]
    for s in sinks
        any(x -> x === s, out) || push!(out, s)
    end
    for s in ck_sinks
        any(x -> x === s, out) || push!(out, s)
    end
    return out
end

# Sorted, de-duplicated union of two tstop vectors — the refresh anchors and the
# output anchors merge into the single `tstops` the solver stops at (mirrors the
# per-provider / per-sink union inside build_refresh_callback / build_output_callback).
function _union_tstops(a::AbstractVector{Float64}, b::AbstractVector{Float64})
    out = Float64[]
    append!(out, a)
    append!(out, b)
    sort!(out)
    unique!(out)
    return out
end

# Sentinel for "the caller did not pass `callback`" — `nothing` is a MEANINGFUL
# value there (§2.5.4: an explicit `callback` replaces the problem's set, and
# replacing it with nothing is exactly how a caller drops it).
struct _KeepCallbacks end
const _KEEP_CALLBACKS = _KeepCallbacks()

"""
    callbacks(prob::EsmProblem)

The problem's own callback set — the composition of its data-refresh, output-sink
and checkpoint callbacks, or `nothing` when it has none.

Stable API in every simulation-capable binding, for one reason (§2.5.4): a
`callback` argument to `solve` **REPLACES** this set entirely — it does not
append, merge, or wrap. Silent composition is the more dangerous default (two
callbacks both writing output, or both mutating the same buffer, produce a wrong
run rather than an error), so a caller who wants to EXTEND reads the set back
and composes explicitly:

```julia
solve(prob, Tsit5(); callback = CallbackSet(callbacks(prob), my_extra_callback))
```
"""
callbacks(prob::EsmProblem) = prob.callback

"""
    remake(prob::EsmProblem; p, u0, tspan, callback) -> EsmProblem

A NEW problem with the named substitutions applied and everything else SHARED
(esm-libraries-spec §2.5.5). It does not mutate `prob`, and it does not redo the
parts of construction the substitution cannot have invalidated: a changed
parameter value does not re-fetch provider data and does not recompile the
right-hand side.

* `p` — an `AbstractDict` of overrides (resolved and class-checked by
  [`remake_parameters`](@ref)) or a ready-made parameter carrier to install
  verbatim.
* `u0` — an `AbstractDict` of per-element / broadcast overrides applied on top of
  this problem's seeded state, or an `AbstractVector` replacing it outright.
  Always applied to a COPY, so `prob`'s own `u0` is untouched.
* `tspan` — a new `(t0, t1)`. A new start `t0` evaluates the document's `ic`
  right-hand sides again at it, where they read the start (`t`, a data-fed
  parameter, an observed over those; esm-spec §11.4.2), with the caller's `u0`
  overrides applied on top.
* `callback` — replace the problem's callback set (§2.5.4). Omit to keep it.

Refusal behaviour is that of `remake_parameters`: a substitution the
problem cannot honour without a rebuild raises, naming the parameter AND the
class that makes it un-substitutable (`:structural`, `:const_folded`,
`:forcing`), rather than silently rebuilding or silently ignoring it.

`EarthSciAST.remake` and `SciMLBase.remake` are the same function on an
`EsmProblem`: the SciMLBase extension forwards the canonical spelling here, so
`remake(prob; …)` works from a session that has `using OrdinaryDiffEq` without
EarthSciAST exporting a second `remake` into the conflict.
"""
function remake(
        prob::EsmProblem; p = nothing, u0 = nothing, tspan = nothing,
        callback = _KEEP_CALLBACKS
    )
    p_new = p === nothing ? prob.p :
        p isa AbstractDict ? remake_parameters(prob, p) : p
    span = tspan === nothing ? prob.tspan : (Float64(tspan[1]), Float64(tspan[2]))
    # A new start re-evaluates the `ic` right-hand sides that read it (esm-spec
    # §11.4.2), with every `u0` override a remake has applied since on top.
    restart = prob.ic_restart
    if restart !== nothing
        overrides = u0 === nothing ? restart.overrides : (restart.overrides..., u0)
        restart = (; seed = restart.seed, overrides)
    end
    u0_new = if restart !== nothing && span[1] != prob.tspan[1]
        restart.seed(span[1], restart.overrides)
    elseif u0 === nothing
        copy(prob.u0)
    else
        _seed_u0(prob.u0, prob.var_map, u0, nothing)
    end
    cb = callback === _KEEP_CALLBACKS ? prob.callback : callback
    # The symbol cache is a function of `var_map` and the `p` NAMES, neither of
    # which a Dict-driven swap can change — so it is shared. A verbatim carrier
    # could carry different names, so that path gets a fresh (lazy) slot.
    sc = (p === nothing || p isa AbstractDict) ? prob.symcache : Ref{Any}(nothing)
    return _with(
        prob; u0 = u0_new, tspan = span, p = p_new, callback = cb, symcache = sc,
        ic_restart = restart
    )
end
