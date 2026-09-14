# A discovered `extent` binds where the NAME is declared, not only at the root.
#
# esm-spec §8.9.4 lets a data source measure its own record count and bind a
# metaparameter an index set is sized by. The count arrives as a §9.7.6 site-4
# loader-API binding, so these tests bind it directly: `load_path(...;
# metaparameters=Dict("N_REC" => 3))` is exactly what extent discovery hands the
# loader, and it exercises the same path without needing a file on disk.
#
# Four separable properties are pinned here:
#
#   * the mounting document need not RESTATE a metaparameter the leaf it mounts
#     already declares (§9.7.6 site 4, widened past "the root document's");
#   * the two §4.7 mount forms size the axis IDENTICALLY — the property "Two
#     mount forms, one mechanism" states and the one that was silently false, a
#     subsystem-mounted leaf having sized its axis at the placeholder default
#     while a top-level-mounted one sized it from the data;
#   * whether a leaf resolves does not turn on an `expression_template_imports`
#     entry it never calls;
#   * an `extent` naming a metaparameter nobody declares is refused at LOAD,
#     not when the source is finally sampled at build.
#
# The fixtures are shared with the other bindings and live under
# `tests/fixtures/` rather than `tests/valid/`, because the corpus sweep would
# score TypeScript and Go a false pass on the top-level mount form they do not
# implement. Ported from
# `pkg/earthsci-ast-py/tests/test_data_source_extent_scope.py`.

using Test
using JSON3
using EarthSciAST
using EarthSciAST: ExpressionTemplateError, ERROR_CODES

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _EXTENT_SCOPE_DIR =
    joinpath(TESTUTILS_REPO_ROOT, "tests", "fixtures", "data_source_extent_scope")

# The merged `records` axis declaration, whatever shape the registry holds.
_extent_records(f::EarthSciAST.EsmFile) = f.index_sets["records"]

_extent_load(name; metaparameters=Dict{String,Int}()) =
    EarthSciAST.load_path(joinpath(_EXTENT_SCOPE_DIR, name);
                          metaparameters=metaparameters)

_extent_err(f) = try
    f()
    nothing
catch e
    e
end

# The OUTCOME of a load, reduced to what a DIFFERENTIAL assertion may compare:
# the merged axis size on success, and the exception's stable §9.6.6 code on
# failure. Deliberately NOT the message — two spellings of one assembly mount
# differently-named files, so their messages differ where their meanings must
# not. Used where the portable contract is "these two agree with each other"
# rather than an absolute value.
function _extent_outcome(name; metaparameters=Dict{String,Int}())
    e = _extent_err(() -> _extent_load(name; metaparameters=metaparameters))
    e === nothing || return (:error, e.code)
    return (:ok, _extent_records(_extent_load(name; metaparameters=metaparameters)).size)
end

@testset "§8.9.4 discovered extent binds where the name is declared" begin

    # -----------------------------------------------------------------------
    # §9.7.6 site 4 reaches a name only a MOUNTED document declares
    # -----------------------------------------------------------------------

    @testset "a mounted leaf's metaparameter need not be restated by the root" begin
        # The thin root owns the `data_sources` entry and declares NO
        # `metaparameters`; the leaf it mounts declares `N_REC` and is sized by
        # it. The discovered extent is a loader-API binding, and the site-4
        # check used to ask only whether the ROOT declared the name — so every
        # assembly had to carry a second, identical `metaparameters` block that
        # configured nothing. The check now accepts a name declared by any
        # document the root mounts, and the mount edge forwards the value into
        # the leaf's own close.
        f = _extent_load("extent_root_toplevel.esm"; metaparameters=Dict("N_REC" => 3))
        @test _extent_records(f).size == 3
    end

    @testset "a loader-API binding no document declares is still refused" begin
        # Widening the check must not delete it. A name neither the root nor
        # anything it mounts declares is still `template_import_unknown_name` —
        # §9.7.6: bindings never invent metaparameters, a typo fails loudly.
        err = _extent_err(() ->
            _extent_load("extent_root_toplevel.esm"; metaparameters=Dict("N_RECS" => 3)))
        @test err isa ExpressionTemplateError
        @test err.code == ERROR_CODES.TEMPLATE_IMPORT_UNKNOWN_NAME
        @test occursin("N_RECS", err.message)
    end

    # -----------------------------------------------------------------------
    # §4.7 "Two mount forms, one mechanism"
    # -----------------------------------------------------------------------

    @testset "the same leaf sizes its axis at either mount form" begin
        # THE ORACLE PIN. Same leaf, same data source, same discovered count;
        # the two assemblies differ only in which attachment point mounts the
        # leaf.
        #
        # Before, only the top-level `models.<k>` form forwarded the loader-API
        # bindings into the leaf's close. A `subsystems.<k>` mount fell through
        # to the leaf's own placeholder default, so the axis folded to 0 and the
        # ingested field was ZERO-LENGTH — with no diagnostic, a clean validate
        # and a clean exit. §4.7 says a binding MUST NOT make the two forms
        # differ; this is the test that says so out loud.
        top = _extent_load("extent_root_toplevel.esm"; metaparameters=Dict("N_REC" => 3))
        sub = _extent_load("extent_root_subsystem.esm"; metaparameters=Dict("N_REC" => 3))
        @test _extent_records(top).size == 3
        @test _extent_records(sub).size == 3  # a subsystem-mounted leaf used to
        # size its axis at the placeholder default while a top-level-mounted one
        # sized it from the data (esm-spec §4.7).
        @test _extent_records(top).size == _extent_records(sub).size
        @test _extent_records(top).kind == _extent_records(sub).kind
    end

    # -----------------------------------------------------------------------
    # An UNUSED template import does not decide whether a leaf resolves
    # -----------------------------------------------------------------------

    @testset "an unused template import does not change whether a leaf resolves" begin
        # Two assemblies differing by ONE import of a library the leaf never
        # calls.
        #
        # Whether a mounted leaf folded strictly used to be a whole-document
        # boolean — does it carry ANY §9.7 machinery — so adding that import
        # flipped the leaf from "axis merges symbolically and the assembler
        # closes it" to `metaparameter_unbound`. Factoring a shared expression
        # into a library is not supposed to change whether a document's shape
        # resolves (§4.7).
        #
        # The assertion is DIFFERENTIAL rather than absolute on purpose: where
        # the §4.7 merge sits relative to the mounting document's own §9.7.6
        # close still differs across bindings (RFC
        # `mount-edge-index-set-renaming.md` open question 2), so the portable
        # contract is that the two spellings agree with each other.
        @test _extent_outcome("assembler_root_with_import.esm") ==
              _extent_outcome("assembler_root_no_import.esm")

        # …and the ABSOLUTE form, which Julia now reaches too.
        #
        # These fixtures mount at the `subsystems.<k>` form, where Julia merges
        # on the TYPED side and `IndexSet.size` is `Union{Int,Nothing}` — so a
        # still-symbolic axis used to abort the mount before any merge. Settling
        # RFC `mount-edge-index-set-renaming.md` open question 2 removed the need
        # for that representation rather than widening it: the leaf closes what
        # it can, then the contribution folds against the MOUNTING document's
        # closed environment while still native, so coercion only ever sees an
        # integer. The axis lands at the assembler's own `N_REC` default.
        @test _extent_err(() -> _extent_load("assembler_root_no_import.esm")) === nothing
        @test _extent_records(_extent_load("assembler_root_no_import.esm")).size == 3
        @test _extent_records(_extent_load("assembler_root_with_import.esm")).size == 3
    end

    # -----------------------------------------------------------------------
    # §8.9.4 statically: an extent nobody declares is refused at `validate`
    # -----------------------------------------------------------------------

    @testset "an extent naming an undeclared metaparameter is refused at load" begin
        # `extent` names `N_RECS`; neither the root nor the leaf declares it.
        # This used to validate clean and fail only once the source was SAMPLED,
        # at build — the same validate/build split §9.7.6's own binding sites
        # had. It is decidable from the documents alone, so it is decided at
        # load, with the code §9.7.6 already gives an unknown name at a binding
        # site (no new diagnostic code).
        err = _extent_err(() -> _extent_load("extent_undeclared_root.esm"))
        @test err isa ExpressionTemplateError
        @test err.code == ERROR_CODES.TEMPLATE_IMPORT_UNKNOWN_NAME
        @test occursin("N_RECS", err.message)
        @test occursin("EGU_Emis", err.message)   # names the site, not just the name
    end

    @testset "a declared extent still loads with no loader bindings" begin
        # The static check must not refuse the ordinary case: an `extent` whose
        # metaparameter the mounted leaf declares loads standalone, at its
        # default, with no loader-API bindings at all (§8.9.4: "declare the
        # metaparameter with a `default` so the document still validates and
        # loads standalone").
        f = _extent_load("extent_root_toplevel.esm")
        @test _extent_records(f).size == 0
    end

    @testset "a loader binding the leaf does not declare is not forwarded to it" begin
        # The site-4 backfill is FILTERED to the names the LEAF declares, and
        # widening the root's check must not loosen that.
        #
        # Here the assembler declares `N_REC` and the leaf it mounts declares
        # nothing. Forwarding the whole loader-API map into the leaf's close
        # would raise `template_import_unknown_name` against a leaf that never
        # asked for the name — and, worse, would let an assembler's unrelated
        # metaparameter silently resize a leaf axis the edge never bound
        # (esm-spec §4.7).
        # …and the axis lands at 5 because the ASSEMBLER's own close sized it,
        # not because the leaf was handed the name. The leaf declares no
        # `metaparameters` at all, so `records` merges up still symbolic and the
        # mounting document closes it (§9.7.6 site 5, §4.7 "Index-set merge").
        # `assembler_partial_overlap_root.esm` below is where forwarding an
        # UNRELATED name can actually be caught.
        @test _extent_records(_extent_load("assembler_root_with_import.esm";
                                           metaparameters=Dict("N_REC" => 5))).size == 5
    end

    @testset "the site-4 backfill at a `subsystems.<k>` edge, all four halves" begin
        # The `subsystems.<k>` twin of `toplevel_mount_edge_pipeline_test.jl`'s
        # "the loader API backfills a leaf and an edge binding outranks it".
        # §4.7 "Two mount forms, one mechanism" means the backfill's PRECEDENCE
        # has to match at both attachment points, not just its existence — the
        # shared fixtures above pin existence, and this pins the rest.
        #
        # The fourth half is why this testset exists at all: the shared fixtures
        # exercise a leaf that declares NOTHING, which the backfill short-circuits
        # before it ever consults the leaf-declared filter. A leaf that declares
        # SOME name and not the bound one is the case that reaches the filter, and
        # without it "forward the whole loader-API map" is a silent no-op on every
        # test in this file.
        dir = mktempdir()
        write(joinpath(dir, "leaf.esm"), """
            {"esm":"1.1.0","metadata":{"name":"leaf"},
             "metaparameters":{"NLEV":{"type":"integer","default":4}},
             "index_sets":{"lev":{"kind":"interval","size":"NLEV"}},
             "models":{"Column":{
               "variables":{"u":{"type":"unknown","units":"1","shape":["lev"],"default":1.0}},
               "equations":[{"lhs":{"op":"D","args":["u"],"wrt":"t"},
                             "rhs":{"op":"*","args":[-1.0,"u"]}}]}}}""")
        host_body(edge) = """
            {"esm":"1.1.0","metadata":{"name":"host"},
             "metaparameters":{"NLEV":{"type":"integer","default":12},
                               "NROWS":{"type":"integer","default":2}},
             "models":{"Host":{
               "variables":{"q":{"type":"unknown","units":"1","default":1.0}},
               "equations":[{"lhs":{"op":"D","args":["q"],"wrt":"t"},
                             "rhs":{"op":"*","args":[-1.0,"q"]}}],
               "subsystems":{"M":{"ref":"./leaf.esm"$edge}}}}}"""
        write(joinpath(dir, "bare.esm"), host_body(""))
        write(joinpath(dir, "bound.esm"), host_body(""","bindings":{"NLEV":7}"""))
        lev(f) = f.index_sets["lev"].size

        # (1) the loader API DOES reach a subsystem-mounted leaf, for the names
        #     the leaf declares — the property a discovered `extent` rides on.
        @test lev(EarthSciAST.load_path(joinpath(dir, "bare.esm");
                                        metaparameters=Dict("NLEV" => 9))) == 9
        # (2) an explicit edge `bindings` entry (site 3) outranks the backfill.
        @test lev(EarthSciAST.load_path(joinpath(dir, "bound.esm");
                                        metaparameters=Dict("NLEV" => 9))) == 7
        # (3) the HOST's own declared default (12) is its site-5 close, not a
        #     binding on what it mounts, and never reaches the leaf.
        @test lev(EarthSciAST.load_path(joinpath(dir, "bare.esm"))) == 4
        # (4) a loader-API name the LEAF does not declare is dropped, not
        #     forwarded: the leaf never asked for `NROWS`, so it must neither be
        #     bound by it nor raise `template_import_unknown_name` about it.
        @test lev(EarthSciAST.load_path(joinpath(dir, "bare.esm");
                                        metaparameters=Dict("NROWS" => 3))) == 4
    end

    @testset "the fixtures say what they are" begin
        # The shared fixtures are read by four other bindings; a silent edit
        # that removed the property under test would leave every suite green.
        root = JSON3.read(read(joinpath(_EXTENT_SCOPE_DIR, "extent_root_toplevel.esm"), String))
        @test !haskey(root, :metaparameters)      # the root must restate nothing
        leaf = JSON3.read(read(joinpath(_EXTENT_SCOPE_DIR, "extent_axis_leaf.esm"), String))
        @test leaf[:metaparameters][:N_REC][:default] == 0
        @test leaf[:index_sets][:records][:size] == "N_REC"
    end

    @testset "an unrelated assembler metaparameter is withheld from the leaf" begin
        # The backfill's PER-NAME filter, driven from the SHARED fixture the
        # other four bindings drive, rather than only from this file's inline
        # one. The assembler declares `N_OTHER` and the leaf it mounts declares
        # `N_REC`, so the loader-API map carries one name the leaf must receive
        # and one it must not. A filter that withholds the whole map from a leaf
        # declaring NOTHING looks correct against every other fixture here and
        # still lets an assembler's unrelated metaparameter through to a leaf
        # that declares something — which is how an unbound `NLEV: default 12`
        # silently resizes a leaf axis the edge never bound (esm-spec §4.7, the
        # PR #298 precedence invariant).
        f = _extent_load("assembler_partial_overlap_root.esm";
                         metaparameters=Dict("N_REC" => 3, "N_OTHER" => 7))
        @test _extent_records(f).size == 3
    end

    @testset "an extent naming a re-exported metaparameter loads" begin
        # The name reaches this document by §9.7.6 site-2 RE-EXPORT, not by
        # declaration and not through a mount. The document declares no
        # `metaparameters` and mounts nothing; it IMPORTS a library that declares
        # `N_REC` and does not bind it at the edge, so the name joins this
        # document's own scope and the loader API may bind it — which is exactly
        # what a discovered `extent` does. The static check runs on the AUTHORED
        # tree, before the imports resolve, so it has to walk the import edges
        # too or it refuses a document §9.7.6 accepts.
        f = _extent_load("extent_reexport_root.esm";
                         metaparameters=Dict("N_REC" => 3))
        @test _extent_records(f).size == 3
        # …and standalone, at the library's default, with no bindings at all.
        @test _extent_records(_extent_load("extent_reexport_root.esm")).size == 0
    end

    @testset "a resolved document re-loads" begin
        # The check is an AUTHORING check and has to be idempotent. A §4.7 mount
        # CONSUMES the leaf's `metaparameters` (§9.7.6 site 3), so once
        # `extent_root_toplevel.esm` has been resolved, `N_REC` is declared
        # nowhere and the `{ref}` stub the mount walk reads is gone — while the
        # `extent` that named it is still there, having already done its job. A
        # binding that re-loads its own resolved document (Rust does, at build)
        # must not be told that document is invalid.
        @test _extent_records(_extent_load("extent_resolved_shape.esm")).size == 3
    end

    @testset "the idempotency fixtures say what they are" begin
        # Both fixtures above are load-bearing by ABSENCE, which a silent edit
        # could restore without any suite going red.
        reexport = JSON3.read(read(
            joinpath(_EXTENT_SCOPE_DIR, "extent_reexport_root.esm"), String))
        @test !haskey(reexport, :metaparameters)   # the name arrives by re-export
        @test reexport[:index_sets][:records][:size] == "N_REC"
        resolved = JSON3.read(read(
            joinpath(_EXTENT_SCOPE_DIR, "extent_resolved_shape.esm"), String))
        @test !haskey(resolved, :metaparameters)   # a mount consumed the leaf's block
        @test resolved[:index_sets][:records][:size] == 3          # already folded
        @test !haskey(resolved[:models][:Ingest], :ref)            # already inlined
        @test resolved[:data_sources][:EGU_Emis][:extent][:metaparameter] == "N_REC"
    end

    @testset "two identical declarations do not collide at either mount form" begin
        # The shape issue #198 reported, driven from the SHARED fixtures so all
        # five bindings answer the same two documents.
        #
        # The assembly and the leaf it mounts declare the SAME metaparameter and
        # the SAME axis sized by it. A merge that runs BEFORE the mounting
        # document's own §9.7.6 close compares the leaf's already-folded
        # `size: 40` against the assembly's still-symbolic `size: "NLEV"` and
        # calls two identical declarations a `subsystem_index_set_conflict` —
        # which is what this binding did at the top-level form and not at the
        # subsystem one, a §4.7 "two mount forms" violation in its own right.
        top = _extent_load("mount_merge_order_toplevel.esm")
        sub = _extent_load("mount_merge_order_subsystem.esm")
        @test top.index_sets["lev"].size == 40
        @test sub.index_sets["lev"].size == 40
        @test top.index_sets["lev"] == sub.index_sets["lev"]
    end

    @testset "the purest typo is caught, and stays caught" begin
        # One file, no mounts, no imports: it declares `N_REC`, sizes its axis by
        # it, and the `extent` says `N_RECS`. On the AUTHORED tree that is
        # refused. After the close it is not — the close folds `records.size`
        # from `"N_REC"` to `0`, which makes the document satisfy
        # `_document_is_in_resolved_shape` (no unresolved mount, every size an
        # integer), and the idempotency exemption then skips the check entirely.
        # Measured both ways; this test is what keeps the check on the authored
        # tree.
        err = _extent_err(() -> _extent_load("extent_typo_no_mount.esm"))
        @test err isa ExpressionTemplateError
        @test err.code == ERROR_CODES.TEMPLATE_IMPORT_UNKNOWN_NAME
        @test occursin("N_RECS", err.message)
    end
end
