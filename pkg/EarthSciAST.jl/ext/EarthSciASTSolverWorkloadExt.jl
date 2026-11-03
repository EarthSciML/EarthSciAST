# A precompile workload for what needs a solver, solving and the inline tests,
# compiled with the solver loaded so that its cache matches a solving session.
module EarthSciASTSolverWorkloadExt

using EarthSciAST: EarthSciAST, esm_problem, load_string, run_inline_tests
using OrdinaryDiffEqTsit5: Tsit5
using PrecompileTools: @compile_workload
using SciMLBase: solve

@compile_workload for json in EarthSciAST._WORKLOAD_DOCS, compiler in (:interpreter, :native)
    file = load_string(json)
    solve(esm_problem(file, (0.0, 1.0); compiler), Tsit5())
    run_inline_tests(file; model_name = "M", alg = Tsit5(), compiler)
end

end
