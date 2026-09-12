set -e
cd /projects/illinois/eng/cee/ctessum/ctessum/code/EarthSciAST/.prfix/juliaudit/.ciaudit
for rep in 1 2; do
  for mode in nocov cov; do
    if [ $mode = cov ]; then FLAGS="--code-coverage=@/projects/illinois/eng/cee/ctessum/ctessum/code/EarthSciAST/.prfix/juliaudit/pkg/EarthSciAST.jl"; else FLAGS=""; fi
    /usr/bin/time -f "TIMING $rep $mode real=%e user=%U" julia --startup-file=no --project=env --check-bounds=yes $FLAGS runtests_subset.jl /projects/illinois/eng/cee/ctessum/ctessum/code/EarthSciAST/.prfix/juliaudit/pkg/EarthSciAST.jl/test cg_foreign_scratch_test.jl direct_class_emission_test.jl cross_eq_class_emission_test.jl 2>&1 | grep -E "Test Summary|TIMING|^  |\|" | grep -E "TIMING|s$" 
  done
done
