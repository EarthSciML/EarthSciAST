# The §4.7 edge pipeline at a top-level `models.<k>` `{ref}` mount.
#
# "Two mount forms, one mechanism" (esm-spec §4.7) forbids a binding from
# making the two attachment points differ, and the "Edge pipeline (normative)"
# paragraph fixes the order: (1) the referenced document resolves in its OWN
# scope — this edge's `bindings` and §9.7.10 injection, its metaparameter close
# and fold, the §9.6.3 fixpoint; (2) `index_set_rename` applies to that
# resolved document; (3) the renamed `index_sets` merge into the mounting
# registry, deep-equal-or-`subsystem_index_set_conflict`.
#
# Julia used to inline this form with a raw pre-pass that deferred all of §9.7
# to the root, so step (1) never ran and step (3) skipped every axis whose
# `size` was still a metaparameter expression. These tests pin the closed gap
# AND the behaviour that must not change with it: the conflict still fires, and
# the documents that redeclare everything today keep loading unchanged. Ported
# from `pkg/earthsci-ast-rs/tests/toplevel_mount_edge_pipeline.rs`.

using Test
using JSON3
using EarthSciAST
using EarthSciAST: ExpressionTemplateError, ERROR_CODES, serialize_esm_file

include("testutils.jl")  # TESTUTILS_REPO_ROOT

# A leaf whose single axis is sized by the leaf's OWN metaparameter. The rest of
# the file is the minimum that makes it a loadable component.
const _SELF_CONTAINED_LEAF = """
{
  "esm": "1.0.0",
  "metadata": {"name": "leaf"},
  "metaparameters": {"NLEV": {"type": "integer", "default": 4}},
  "index_sets": {"lev": {"kind": "interval", "size": "NLEV"}},
  "models": {"Column": {
    "variables": {"u": {"type":"unknown","units":"1","shape":["lev"],"default":1.0}},
    "equations": [{"lhs": {"op":"D","args":["u"],"wrt":"t"},
                   "rhs": {"op":"*","args":[-1.0,"u"]}}]}}}
"""

# A leaf with NO §9.7 machinery whose axis is sized by a name only an ASSEMBLER
# can declare — the shape of the verbose hand-written mounts written against the
# old behaviour.
const _ASSEMBLER_SCOPED_LEAF = """
{
  "esm": "1.0.0",
  "metadata": {"name": "leaf"},
  "index_sets": {"rows": {"kind": "interval", "size": "n_rows"}},
  "models": {"Census": {
    "variables": {"u": {"type":"unknown","units":"1","shape":["rows"],"default":1.0}},
    "equations": [{"lhs": {"op":"D","args":["u"],"wrt":"t"},
                   "rhs": {"op":"*","args":[-1.0,"u"]}}]}}}
"""

_tmp_write(dir, name, body) = (write(joinpath(dir, name), body); joinpath(dir, name))

_err_or_nothing(f) = try
    f()
    nothing
catch e
    e
end

@testset "§4.7 edge pipeline at a top-level models.<k> {ref} mount" begin

    @testset "a metaparameter-sized leaf axis folds at the edge and merges" begin
        # Step (1) + (3): §9.7.5's promise, "the importing model's variables may
        # be shaped over the mesh file's axes WITHOUT redeclaring them, the mesh
        # file stays the source of truth for its own sizes". The importer
        # declares no `index_sets` at all and the leaf's axis arrives folded to
        # the LEAF's own default — not skipped, not resolved in the root's scope.
        dir = mktempdir()
        _tmp_write(dir, "leaf.esm", _SELF_CONTAINED_LEAF)
        host = _tmp_write(dir, "host.esm",
            """{"esm":"1.0.0","metadata":{"name":"host"},
                "models":{"M":{"ref":"./leaf.esm"}}}""")
        f = EarthSciAST.load_path(host)
        @test f.index_sets["lev"].size == 4
        # The mount is a real splice shaped over the merged axis.
        @test f.models["M"] isa EarthSciAST.Model
        @test f.models["M"].variables["u"].shape == ["lev"]
    end

    @testset "edge `bindings` close the leaf at a top-level mount" begin
        # Step (1), §9.7.6 binding site 3. Before the edge ran the close,
        # `bindings` at this mount form were read by nobody.
        dir = mktempdir()
        _tmp_write(dir, "leaf.esm", _SELF_CONTAINED_LEAF)
        host = _tmp_write(dir, "host.esm",
            """{"esm":"1.0.0","metadata":{"name":"host"},
                "models":{"M":{"ref":"./leaf.esm","bindings":{"NLEV":9}}}}""")
        f = EarthSciAST.load_path(host)
        @test f.index_sets["lev"].size == 9

        # A binding VALUE is a metaparameter EXPRESSION folded against the
        # MOUNTING document's closed environment (esm-spec §9.7.6) — the one use
        # that environment has at this edge.
        _tmp_write(dir, "expr.esm",
            """{"esm":"1.0.0","metadata":{"name":"expr"},
                "metaparameters":{"NX":{"type":"integer","default":3},
                                  "NY":{"type":"integer","default":5}},
                "models":{"M":{"ref":"./leaf.esm",
                               "bindings":{"NLEV":{"op":"*","args":["NX","NY"]}}}}}""")
        @test EarthSciAST.load_path(joinpath(dir, "expr.esm")).index_sets["lev"].size == 15
    end

    @testset "a folded leaf axis still collides loudly" begin
        # FALSIFICATION 1 — the merge must not become permissive. A mounted leaf
        # whose axis collides non-deep-equal with the importer's own declaration
        # is still a load-time `subsystem_index_set_conflict`. The collision is
        # now reachable on an axis it could not reach before: one the edge just
        # FOLDED.
        dir = mktempdir()
        _tmp_write(dir, "leaf.esm", _SELF_CONTAINED_LEAF)
        host = _tmp_write(dir, "host.esm",
            """{"esm":"1.0.0","metadata":{"name":"host"},
                "index_sets":{"lev":{"kind":"interval","size":59}},
                "models":{"M":{"ref":"./leaf.esm"}}}""")
        err = _err_or_nothing(() -> EarthSciAST.load_path(host))
        @test err isa ExpressionTemplateError
        @test err.code == ERROR_CODES.SUBSYSTEM_INDEX_SET_CONFLICT
        @test occursin("index_set_rename", err.message)   # the remedy
    end

    @testset "an assembler-scoped axis merges with or without restatement" begin
        # FALSIFICATION 2 — backward compatibility, the case that matters most.
        # A leaf that is NOT self-contained (its axis is sized by a name only the
        # assembler declares) has no metaparameters to close, so nothing folds at
        # the edge and the symbolic `size` merges up for the ROOT's close to
        # resolve. That is the shape of every verbose assembly written against
        # the old behaviour: it must keep loading whether it restates the leaf's
        # axis byte-identically or not, and both spellings must agree.
        #
        # Rust agrees on both halves (it merges at the same point: on the raw
        # document, before the mounting document's own close). PYTHON REFUSES the
        # VERBOSE half — it merges after its close, so it compares the host's
        # already-folded `size: 7` against the leaf's `size: "n_rows"` and raises
        # `subsystem_index_set_conflict`. That verdict split is recorded, not
        # fixed, in ESM_COMPLIANCE_VALIDATION_MATRIX.md BEHAV-04-D-003; the terse
        # half — the spelling this change exists to make possible — loads in all
        # three. Pinned here so the split is visible if the ruling goes the other
        # way.
        dir = mktempdir()
        _tmp_write(dir, "leaf.esm", _ASSEMBLER_SCOPED_LEAF)
        verbose = _tmp_write(dir, "verbose.esm",
            """{"esm":"1.0.0","metadata":{"name":"verbose"},
                "metaparameters":{"n_rows":{"type":"integer","default":7}},
                "index_sets":{"rows":{"kind":"interval","size":"n_rows"}},
                "models":{"M":{"ref":"./leaf.esm"}}}""")
        terse = _tmp_write(dir, "terse.esm",
            """{"esm":"1.0.0","metadata":{"name":"terse"},
                "metaparameters":{"n_rows":{"type":"integer","default":7}},
                "models":{"M":{"ref":"./leaf.esm"}}}""")
        a = EarthSciAST.load_path(verbose)
        b = EarthSciAST.load_path(terse)
        @test a.index_sets["rows"].size == 7
        @test b.index_sets["rows"].size == 7
        @test serialize_esm_file(a)["index_sets"] == serialize_esm_file(b)["index_sets"]
    end

    @testset "a leaf with machinery is strict about an assembler-scoped size" begin
        # The strictness boundary the close introduces, pinned so it is visible
        # rather than discovered. §9.7.6 site 3 resolves a mounted leaf "as a
        # complete document and folded to concrete integers at the mount", so the
        # leaf's OWN close is strict: once the leaf has any §9.7 machinery to
        # resolve, an axis sized by a name the leaf does not declare is
        # `metaparameter_unbound` AT THE EDGE — it never reaches the mounting
        # document's close. A leaf with NO machinery has no close to be strict
        # about, so the same size merges symbolically (the testset above). Python
        # returns the same verdict.
        dir = mktempdir()
        _tmp_write(dir, "leaf.esm", """
        {
          "esm": "1.0.0",
          "metadata": {"name": "leaf"},
          "metaparameters": {"UNRELATED": {"type": "integer", "default": 1}},
          "index_sets": {"rows": {"kind": "interval", "size": "n_rows"}},
          "models": {"Census": {
            "variables": {"u": {"type":"unknown","units":"1","shape":["rows"],"default":1.0}},
            "equations": [{"lhs": {"op":"D","args":["u"],"wrt":"t"},
                           "rhs": {"op":"*","args":[-1.0,"u"]}}]}}}
        """)
        host = _tmp_write(dir, "host.esm",
            """{"esm":"1.0.0","metadata":{"name":"host"},
                "metaparameters":{"n_rows":{"type":"integer","default":7}},
                "models":{"M":{"ref":"./leaf.esm"}}}""")
        err = _err_or_nothing(() -> EarthSciAST.load_path(host))
        # A proper diagnostic, not a bare `MethodError: no method matching Int64(::String)`.
        @test err isa ExpressionTemplateError
        @test err.code == ERROR_CODES.METAPARAMETER_UNBOUND
        @test occursin("n_rows", err.message)
    end

    @testset "an assembler's own default never overrides a leaf's own" begin
        # FALSIFICATION 5 — the backfill must not reach past the loader API into
        # the mounting document's OWN declared defaults.
        #
        # §9.7.6 site 4 is the loader API; a mounting document's `metaparameters`
        # defaults are site 5, its own close, and they are NOT a binding on
        # anything it mounts. Forwarding them would let an assembler's unrelated
        # `NLEV` silently resize a leaf axis the edge never bound — and give a
        # DIFFERENT answer from the one the same leaf gets at a `subsystems.<k>`
        # mount, which is precisely what §4.7 forbids. Python backfills from its
        # `loader_metaparameters` only; this pins Julia to that.
        dir = mktempdir()
        _tmp_write(dir, "leaf.esm", _SELF_CONTAINED_LEAF)
        # The assembler happens to declare a metaparameter of the SAME NAME, for
        # its own purposes, and does not bind it on the edge.
        top = _tmp_write(dir, "top.esm",
            """{"esm":"1.0.0","metadata":{"name":"top"},
                "metaparameters":{"NLEV":{"type":"integer","default":12}},
                "models":{"M":{"ref":"./leaf.esm"}}}""")
        # The same leaf, the same assembler, through the OTHER attachment point.
        sub = _tmp_write(dir, "sub.esm",
            """{"esm":"1.0.0","metadata":{"name":"sub"},
                "metaparameters":{"NLEV":{"type":"integer","default":12}},
                "models":{"Host":{
                  "subsystems":{"M":{"ref":"./leaf.esm"}},
                  "variables":{"q":{"type":"unknown","units":"1","default":1.0}},
                  "equations":[{"lhs":{"op":"D","args":["q"],"wrt":"t"},
                                "rhs":{"op":"*","args":[-1.0,"q"]}}]}}}""")
        a = EarthSciAST.load_path(top)
        b = EarthSciAST.load_path(sub)
        @test a.index_sets["lev"].size == 4        # the LEAF's own default wins
        @test a.index_sets["lev"].size == b.index_sets["lev"].size   # §4.7
    end

    @testset "the loader API backfills a leaf and an edge binding outranks it" begin
        # FALSIFICATION 6 — the backfill's precedence, both halves.
        #
        # The loader API (§9.7.6 site 4) DOES reach a leaf, for the names the
        # leaf declares, so a bare `{ref}` mount still inherits the caller's grid
        # instead of falling to the leaf's defaults. An explicit edge `bindings`
        # entry (site 3) outranks it.
        #
        # The host must DECLARE a name for the loader API to bind it — binding an
        # undeclared one is `template_import_unknown_name` at the root, before
        # any mount is reached. So the API bindings are always a subset of what
        # the host declares, and what the testset above forbids forwarding is
        # precisely the remainder: the host's own DEFAULTS.
        dir = mktempdir()
        _tmp_write(dir, "leaf.esm", _SELF_CONTAINED_LEAF)
        bare = _tmp_write(dir, "bare.esm",
            """{"esm":"1.0.0","metadata":{"name":"bare"},
                "metaparameters":{"NLEV":{"type":"integer","default":12}},
                "models":{"M":{"ref":"./leaf.esm"}}}""")
        bound = _tmp_write(dir, "bound.esm",
            """{"esm":"1.0.0","metadata":{"name":"bound"},
                "metaparameters":{"NLEV":{"type":"integer","default":12}},
                "models":{"M":{"ref":"./leaf.esm","bindings":{"NLEV":7}}}}""")
        api = Dict("NLEV" => 9)
        @test EarthSciAST.load_path(bare; metaparameters=api).index_sets["lev"].size == 9
        @test EarthSciAST.load_path(bound; metaparameters=api).index_sets["lev"].size == 7
        # And with the SAME host, no API binding: the host's own default of 12
        # must NOT reach the leaf.
        @test EarthSciAST.load_path(bare).index_sets["lev"].size == 4

        # A name the LEAF does not declare is never forwarded, so it cannot raise
        # `template_import_unknown_name` against the leaf.
        other = _tmp_write(dir, "other.esm",
            """{"esm":"1.0.0","metadata":{"name":"other"},
                "metaparameters":{"NROWS":{"type":"integer","default":2}},
                "models":{"M":{"ref":"./leaf.esm"}}}""")
        @test EarthSciAST.load_path(other;
            metaparameters=Dict("NROWS" => 3)).index_sets["lev"].size == 4
    end

    @testset "a concrete restatement of a symbolic leaf axis collides" begin
        # FALSIFICATION 7 — the OTHER new refusal, pinned so it is visible rather
        # than discovered.
        #
        # On the no-machinery path a symbolic `size` reaches the merge unfolded,
        # and `_merge_native_index_sets!` compares declarations structurally. So
        # the idempotence of a restatement is SYNTACTIC there: restating the
        # leaf's axis verbatim merges clean (the testset above), but restating it
        # with the concrete number the name folds to is a conflict — even though
        # the two say the same thing once the root closes. This loaded before the
        # edge pipeline ran here. Python refuses it identically, so it is a
        # convergence, not a divergence.
        dir = mktempdir()
        _tmp_write(dir, "leaf.esm", _ASSEMBLER_SCOPED_LEAF)
        host = _tmp_write(dir, "host.esm",
            """{"esm":"1.0.0","metadata":{"name":"host"},
                "metaparameters":{"n_rows":{"type":"integer","default":7}},
                "index_sets":{"rows":{"kind":"interval","size":7}},
                "models":{"M":{"ref":"./leaf.esm"}}}""")
        err = _err_or_nothing(() -> EarthSciAST.load_path(host))
        # A stable code, not a bare `MethodError: no method matching Int64(::String)`.
        @test err isa ExpressionTemplateError
        @test err.code == ERROR_CODES.SUBSYSTEM_INDEX_SET_CONFLICT
        @test occursin("rows", err.message)
    end

    @testset "§9.7.10 form A injects into the leaf at a top-level mount" begin
        # Step (1) again: the edge's `expression_template_imports` go into the
        # LEAF's own scope BEFORE it resolves, so the §9.6.3 fixpoint lowers its
        # rewrite-targets at the mount — the same thing the `subsystems.<k>` edge
        # does with the same fixtures (`scope_injection_test.jl`, "form A"). The
        # inliner used to append them to the spliced model instead and defer the
        # resolution to the root, which is observationally close but is not the
        # edge pipeline: nothing of the leaf closed at the mount.
        conf = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                        "expression_templates", "inject_subsystem_ref")
        dir = mktempdir()
        host = _tmp_write(dir, "host.esm", """
        {"esm":"1.0.0","metadata":{"name":"toplevel_inject"},
         "models":{"Runoff":{
           "ref":"$(joinpath(conf, "leaf.esm"))",
           "expression_template_imports":[
             {"ref":"$(joinpath(conf, "central_D_lon_zero_grad_bc.esm"))",
              "only":["central_D_lon_zero_grad_bc"],
              "bindings":{"NLON":288,"NLAT":181}}]}}}""")
        f = withenv("ESS_TEMPLATE_REF_DISABLE" => "1") do
            EarthSciAST.load_path(host)
        end
        # The agnostic leaf's `D(c, wrt: lon)` is lowered by the injected rule.
        @test f.models["Runoff"].equations[1].rhs.args[2].op == "makearray"
        # The injected library brought its grid into the importing registry.
        @test f.index_sets["lon"].size == 288
        @test f.index_sets["lat"].size == 181
    end

    @testset "a consumed mount edge does not survive parse → emit" begin
        # esm-spec §4.7 "Round trip": a mount edge is consumed at load, so
        # `bindings` / `index_set_rename` must not survive `parse → emit`, and
        # the emitted document carries the inlined component with its axes
        # already spelled under the post-rename names — so a second load has no
        # edge left to rename and reaches the same registry.
        dir = mktempdir()
        _tmp_write(dir, "leaf.esm", _SELF_CONTAINED_LEAF)
        host = _tmp_write(dir, "host.esm",
            """{"esm":"1.0.0","metadata":{"name":"host"},
                "models":{"M":{"ref":"./leaf.esm","bindings":{"NLEV":6},
                               "index_set_rename":{"lev":"soil.lev"}}}}""")
        first_load = EarthSciAST.load_path(host)
        @test first_load.index_sets["soil.lev"].size == 6
        @test !haskey(first_load.index_sets, "lev")
        @test first_load.models["M"].variables["u"].shape == ["soil.lev"]
        emitted = JSON3.write(serialize_esm_file(first_load))
        @test !occursin("index_set_rename", emitted)
        @test !occursin("\"bindings\"", emitted)
        @test occursin("soil.lev", emitted)

        again = _tmp_write(dir, "again.esm", emitted)
        second = EarthSciAST.load_path(again)
        @test second.index_sets["soil.lev"].size == 6
        @test JSON3.write(serialize_esm_file(second)) == emitted
    end
end
