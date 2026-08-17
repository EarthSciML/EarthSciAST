# ---- Models (copied from test/tree_walk_oop_test.jl) -------------------------
_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_cst(v) = Dict{String,Any}("op" => "const", "value" => v)
_fnop(nm, a...) = Dict{String,Any}("op" => "fn", "name" => nm, "args" => Any[a...])
_ao(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)

_doc(name, vars, eqs; index_sets = nothing) = begin
    d = Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => name),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => vars, "equations" => eqs)))
    index_sets === nothing || (d["index_sets"] = index_sets)
    d
end
_nset(N) = Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => N))
_state(; kw...) = Dict{String,Any}("type" => "state",
                                   (String(k) => v for (k, v) in kw)...)
_param(v) = Dict{String,Any}("type" => "parameter", "default" => v)

function _rd(N)
    stencil = _o("+", _o("-", _ix("c", _o("-", "i", 1.0)), _o("*", 2.0, _ix("c", "i"))),
                 _ix("c", _o("+", "i", 1.0)))
    rate = _o("*", "k_rxn", _o("exp", _o("neg", _o("/", "Ea", "T"))))
    _doc("RD",
        Dict{String,Any}("c" => _state(shape = Any["n"]), "k_diff" => _param(0.1),
                         "k_rxn" => _param(0.3), "Ea" => _param(50.0), "T" => _param(300.0)),
        Any[Dict{String,Any}("lhs" => _ao(_Dt(_ix("c", "i"))),
            "rhs" => _ao(_o("-", _o("*", "k_diff", stencil),
                            _o("*", rate, _o("^", _ix("c", "i"), 2.0)))))];
        index_sets = _nset(N))
end

function _zerod()
    shared = _o("*", _o("exp", _o("neg", _o("/", "Ea", "T"))), _o("*", "x", "y"))
    _doc("Z",
        Dict{String,Any}("x" => _state(default = 0.7), "y" => _state(default = 0.4),
                         "Ea" => _param(50.0), "T" => _param(300.0), "k" => _param(1.3)),
        Any[Dict{String,Any}("lhs" => _Dt("x"), "rhs" => _o("neg", _o("*", "k", shared))),
            Dict{String,Any}("lhs" => _Dt("y"), "rhs" => shared)])
end

_seed(n) = [0.6sin(0.7k) - 0.15 for k in 1:n]

