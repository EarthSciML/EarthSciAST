# The two `subsystems.<k>` resolution paths in this binding must not drift apart.
#
# LOADING goes through the native pass (`_inline_subsystem_refs!`, before
# `_load_parsed`). REMOTE `http(s)://` refs and direct callers of
# `resolve_subsystem_refs!` go through the typed walk (`_resolve_refs_in_file!`).
# Two code paths for one mechanism is a standing risk, so this file runs BOTH over
# every document in the corpus that mounts a LOCAL `subsystems.<k>` `{ref}` and
# requires the same resolved document and the same error. `_load_document`'s
# `native_subsystem_refs=false` is what makes the typed walk do the root's mounts.
#
# A small, closed set of documents is EXPECTED to differ, because each exercises
# behaviour only the native pass has. Each is listed with the ONE difference it is
# allowed, and that difference is checked — so an unexpected change in one of them
# still fails, and so does a listed document that stops differing (the list must
# not go stale and hide a regression behind it). Every other document must agree
# exactly.

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _NTA_ROOT = TESTUTILS_REPO_ROOT

# Documents under the corpus roots that mount a LOCAL `subsystems.<k>` `{ref}`
# somewhere in a root model's subsystem tree.
function _nta_mounts_local_subsystem(doc)::Bool
    doc isa AbstractDict || return false
    walk(c) = begin
        subs = get(c, "subsystems", nothing)
        subs isa AbstractDict || return false
        for (_, s) in pairs(subs)
            s isa AbstractDict || continue
            r = get(s, "ref", nothing)
            if r isa AbstractString
                (startswith(r, "http://") || startswith(r, "https://")) || return true
            elseif walk(s)
                return true
            end
        end
        false
    end
    for (_, m) in pairs(get(doc, "models", Dict()))
        m isa AbstractDict && walk(m) && return true
    end
    return false
end

function _nta_corpus()
    out = String[]
    for dir in ("tests/valid", "tests/invalid", "tests/fixtures", "lib")
        root = joinpath(_NTA_ROOT, dir)
        isdir(root) || continue
        for (r, _, fs) in walkdir(root), f in fs
            endswith(f, ".esm") || continue
            p = joinpath(r, f)
            d = try
                JSON3.read(read(p, String), Dict{String,Any})
            catch
                continue
            end
            _nta_mounts_local_subsystem(d) && push!(out, p)
        end
    end
    return sort!(out)
end

# One path's answer: the serialized document, or the error in the shape the
# conformance producer reports it.
function _nta_resolve(path::AbstractString, native::Bool)
    raw = EarthSciAST._read_json_document(read(path, String))
    try
        f = EarthSciAST._load_document(raw, dirname(path); native_subsystem_refs=native)
        return (:ok, JSON3.read(JSON3.write(EarthSciAST.serialize_esm_file(f)), Dict{String,Any}))
    catch e
        se = EarthSciAST.load_failure_structural_error(e)
        se === nothing && return (:error, Dict{String,Any}("type" => string(typeof(e)),
                                                          "message" => sprint(showerror, e)))
        return (:error, Dict{String,Any}("path" => se.path, "code" => se.error_type,
                                         "message" => se.message, "details" => se.details))
    end
end

_nta_ops(doc, op) = count(m -> true, eachmatch(Regex("\"op\":\"$(op)\""), JSON3.write(doc)))

# The documents allowed to differ, and the only way each may.
const _NTA_EXPECTED = Dict{String,Tuple{Symbol,String}}(
    # esm-spec §4.7 / §9.7.10, issue #311: a rule reaches a rewrite-target inside a
    # mounted component only when the mount is spliced in before the fixpoint.
    "tests/fixtures/mount_edge_injection_nested/nested_self_import.esm" =>
        (:lowers_through_mount, "input_x"),
    "tests/fixtures/mount_edge_injection_nested/nested_self_import_own_target.esm" =>
        (:lowers_through_mount, "input_x"),
    "tests/fixtures/mount_edge_injection_nested/nested_subsystem_mount.esm" =>
        (:lowers_through_mount, "input_x"),
    "tests/fixtures/mount_edge_injection_nested/nested_depth2_mount.esm" =>
        (:lowers_through_mount, "input_x"),
    # esm-spec §4.7 "Vocabulary and reach": a rename reaches an axis the leaf
    # shares with its own nested mount. The typed walk renames before it merges
    # the nested contribution, so it keeps a second, unrenamed entry.
    "tests/fixtures/mount_edge_rename_nested_scope/rename_scope_shared_axis.esm" =>
        (:rename_reach, "soil_lev"),
    # The raised `faq` floor (docs/content/rfcs/faq-node-rename.md §5.5). A 1.0.0
    # document that mounts a `faq`-using leaf CONTAINS `faq` once the leaf is in.
    # The native pass inlines before the typed pipeline raises the floor; the typed
    # walk inlines into an `EsmFile`, which is immutable, so it cannot rewrite
    # `esm`. Rust, Go and TypeScript all report 1.1.0 here.
    "tests/valid/mount_rename_two_columns.esm" => (:raised_faq_floor, "1.1.0"),
    "tests/valid/subsystem_index_set_merge.esm" => (:raised_faq_floor, "1.1.0"),
)

function _nta_allowed_difference(kind::Symbol, arg::String, native, typed)
    native[1] === :ok && typed[1] === :ok || return false
    n, t = native[2], typed[2]
    if kind === :lowers_through_mount
        return _nta_ops(n, arg) == 0 && _nta_ops(t, arg) > 0
    elseif kind === :rename_reach
        ni = collect(keys(get(n, "index_sets", Dict())))
        ti = collect(keys(get(t, "index_sets", Dict())))
        return arg in ni && arg in ti && length(ti) == length(ni) + 1
    elseif kind === :raised_faq_floor
        n2 = copy(n); t2 = copy(t)
        n2["esm"] == arg && t2["esm"] != arg || return false
        delete!(n2, "esm"); delete!(t2, "esm")
        return n2 == t2
    end
    return false
end

@testset "native and typed subsystems.<k> resolution agree" begin
    corpus = _nta_corpus()
    # Guard the scan itself: an empty or tiny corpus would pass vacuously.
    @test length(corpus) >= 25

    rel(p) = relpath(p, _NTA_ROOT)
    seen_expected = Set{String}()
    for path in corpus
        r = rel(path)
        native = _nta_resolve(path, true)
        typed = _nta_resolve(path, false)
        if haskey(_NTA_EXPECTED, r)
            push!(seen_expected, r)
            kind, arg = _NTA_EXPECTED[r]
            @testset "$r differs only by $(kind)" begin
                @test native != typed
                @test _nta_allowed_difference(kind, arg, native, typed)
            end
        else
            @testset "$r" begin
                @test native[1] === typed[1]
                @test native[2] == typed[2]
            end
        end
    end
    # Every listed document is still in the corpus the scan finds.
    @test seen_expected == Set(keys(_NTA_EXPECTED))
end
