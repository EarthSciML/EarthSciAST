# Where the closed-template benchmark harnesses find their documents. None are
# committed: generate.py and generate_p4.py write them.
#
#   bench_docs(generator, dir, args; env, name, prefix)
#
# With `dir` given (an explicit directory argument), the documents must
# already be there: if no file starts with `prefix`, it stops with the command
# that writes them. With `dir === nothing`, it runs `generator` with `args`
# into `\$env`, else `<tempdir()>/<name>` (tempdir() honours TMPDIR), and
# returns that directory.

function bench_docs(generator, dir, args; env, name, prefix)
    script = joinpath(@__DIR__, generator)
    if dir === nothing
        dir = get(ENV, env, joinpath(tempdir(), name))
        run(`python3 $script --out $dir $args`)
        return dir
    end
    if !isdir(dir) || !any(startswith(prefix), readdir(dir))
        error("no $(prefix)* documents in $dir; write them with:\n    python3 $script --out $dir $(join(args, ' '))")
    end
    return dir
end
