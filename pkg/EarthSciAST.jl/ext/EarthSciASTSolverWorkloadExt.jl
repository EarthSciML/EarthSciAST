"""
    EarthSciASTSolverWorkloadExt

A precompile workload, and nothing else: it builds, solves and runs the inline
tests of two small documents so that the build, solve and inline-test path is
compiled into a package image instead of on the first call of every session
that loads a solver.

Why this lives in an extension rather than in the core's own workload
(`src/precompile_workload.jl`): loading the solver stack invalidates most of
that path. SciMLBase, the OrdinaryDiffEq packages and ForwardDiff each add
methods (to `show`, `can_setindex`, `promote_rule`, the SparseArrays array
traits, and EarthSciAST's own `_value` through `EarthSciASTForwardDiffExt`) that
the core's less precisely inferred code has backedges to, so code the core image
cached is thrown away the moment a solver is loaded and is compiled again on
first use. An extension is precompiled with its triggers loaded, so what it
caches is compiled against the methods a solving session actually has.

The triggers are the packages whose methods have to be present for the cached
code to survive loading, which is also the shared solver environment the
conformance adapters use (`scripts/compiler_agreement_env`). ForwardDiff is a
dependency of OrdinaryDiffEqRosenbrock, so naming it adds no requirement; it is
named so that `EarthSciASTForwardDiffExt`, whose `_value` method invalidates
much of the build path, is loaded while this extension precompiles. A session
that loads further packages that invalidate the same code (ModelingToolkit,
Reactant) pays the first-call cost again for whatever they invalidate.

The model right-hand sides are `RuntimeGeneratedFunction`s created per document
at build time, so their bodies are never cached; what is cached is the builder,
the problem construction around them, and the solver and inline-test machinery
specialized on the wrapper types they share.
"""
module EarthSciASTSolverWorkloadExt

using EarthSciAST: EarthSciAST
import SciMLBase
import ForwardDiff
import OrdinaryDiffEqTsit5
import OrdinaryDiffEqRosenbrock
using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    # An array model: `faq` equations with and without a `filter`, an array
    # observed read through `index`, and inline assertions at coordinates.
    array_doc = """
    {"esm": "1.2.0", "metadata": {"name": "workload_array"},
     "index_sets": {"x": {"kind": "interval", "size": 5}},
     "models": {"M": {
       "variables": {
         "a": {"type": "unknown", "units": "1", "shape": ["x"], "default": 0.0},
         "b": {"type": "unknown", "units": "1", "shape": ["x"], "default": 0.0},
         "w": {"type": "unknown", "units": "1", "shape": ["x"]}
       },
       "equations": [
         {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                  "expr": {"op": "D", "args": [{"op": "index", "args": ["a", "i"]}], "wrt": "t"}},
          "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                  "expr": {"op": "+", "args": [{"op": "*", "args": [2, "i"]}, 1]},
                  "filter": {"op": ">=", "args": ["i", 3]}}},
         {"lhs": "w", "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                  "expr": {"op": "*", "args": [10, "i"]}, "filter": {"op": "<=", "args": ["i", 2]}}},
         {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                  "expr": {"op": "D", "args": [{"op": "index", "args": ["b", "i"]}], "wrt": "t"}},
          "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                  "expr": {"op": "index", "args": ["w", "i"]}}}
       ],
       "tests": [{"id": "t1", "time_span": {"start": 0.0, "end": 1.0},
                  "assertions": [{"variable": "a", "time": 1.0, "expected": 7.0, "coords": {"x": 3}},
                                 {"variable": "w", "time": 1.0, "expected": 10.0, "coords": {"x": 1}}]}]
     }}}
    """
    # A scalar model: a parameter, a state, an observed, and an inline test
    # that overrides the parameter.
    scalar_doc = """
    {"esm": "1.2.0", "metadata": {"name": "workload_scalar"},
     "models": {"M": {
       "variables": {
         "k": {"type": "parameter", "units": "1/s", "default": 0.5},
         "y": {"type": "unknown", "units": "1", "default": 1.0},
         "z": {"type": "unknown", "units": "1"}
       },
       "equations": [
         {"lhs": {"op": "D", "args": ["y"], "wrt": "t"},
          "rhs": {"op": "-", "args": [{"op": "*", "args": ["k", "y"]}]}},
         {"lhs": "z", "rhs": {"op": "*", "args": [2, "y"]}}
       ],
       "tests": [{"id": "t1", "time_span": {"start": 0.0, "end": 1.0},
                  "parameter_overrides": {"k": 1.0},
                  "assertions": [{"variable": "y", "time": 1.0, "expected": 0.36787944117144233},
                                 {"variable": "z", "time": 1.0, "expected": 0.7357588823428847}]}]
     }}}
    """
    @compile_workload begin
        for json in (array_doc, scalar_doc)
            file = EarthSciAST.load_string(json)
            for compiler in (:interpreter, :native)
                prob = EarthSciAST.esm_problem(file, (0.0, 1.0); compiler)
                SciMLBase.solve(
                    prob, OrdinaryDiffEqTsit5.Tsit5();
                    reltol = 1.0e-8, abstol = 1.0e-10
                )
                EarthSciAST.run_inline_tests(
                    file; model_name = "M", alg = OrdinaryDiffEqTsit5.Tsit5(),
                    reltol = 1.0e-8, abstol = 1.0e-10, compiler
                )
            end
        end
    end
end

end # module EarthSciASTSolverWorkloadExt
