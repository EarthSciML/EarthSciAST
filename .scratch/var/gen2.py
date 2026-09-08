import json, os, sys
OUT = os.path.dirname(os.path.abspath(__file__))
FORCE = {"op":"+","args":["Tsfc0",{"op":"*","args":["amp",
          {"op":"sin","args":[{"op":"*","args":["omega","t"]}]}]}]}
P = {"kappa":{"type":"parameter","units":"1/s","default":2.0e-3},
     "omega":{"type":"parameter","units":"1/s","default":7.27220521664304e-05},
     "amp":{"type":"parameter","units":"K","default":10.0},
     "Tsfc0":{"type":"parameter","units":"K","default":288.0},
     "rlx":{"type":"parameter","units":"1/s","default":1.0e-3}}

def tend(N, sfc_name):
    T = lambda i: {"op":"index","args":["T",i]}
    kdn = {"op":"max","args":[1,{"op":"-","args":["k",1]}]}
    kup = {"op":"min","args":[N,{"op":"+","args":["k",1]}]}
    lap = {"op":"-","args":[{"op":"+","args":[T(kdn),T(kup)]},{"op":"*","args":[2.0,T("k")]}]}
    sfc = {"op":"ifelse","args":[{"op":"==","args":["k",1]},
                                 {"op":"-","args":[sfc_name,T("k")]},0.0]}
    body = {"op":"+","args":[{"op":"*","args":["kappa",lap]},{"op":"*","args":["rlx",sfc]}]}
    return {"op":"aggregate","output_idx":["k"],"args":[],
            "ranges":{"k":{"from":"lev"}},"expr":body}

def write(name, variables, equations, N, end=60.0):
    d = {"esm":"1.0.0","metadata":{"name":name,"description":"probe","license":"MIT"},
         "index_sets":{"lev":{"kind":"interval","size":N}},
         "models":{"M":{"variables":variables,"equations":equations,
           "tests":[{"id":"t1","description":"run","time_span":{"start":0.0,"end":end},
             "assertions":[{"variable":"T","time":end,"coords":{"lev":1},
                            "expected":0.0,"tolerance":{"abs":1e9}}]}]}}}
    json.dump(d, open(f"{OUT}/{name}.esm","w"), indent=1)

def base(N):
    v = dict(P)
    v["T"] = {"type":"unknown","units":"K","shape":["lev"],"default":288.0}
    v["dTdt"] = {"type":"unknown","units":"K/s","shape":["lev"]}
    return v

for N in (4, 59):
    # A1: array consumer + bare alias
    v = base(N); v["Tsfc"]={"type":"unknown","units":"K"}; v["Tsfc_raw"]={"type":"unknown","units":"K"}
    e = [{"lhs":"Tsfc_raw","rhs":FORCE},{"lhs":"Tsfc","rhs":"Tsfc_raw"},
         {"lhs":"dTdt","rhs":tend(N,"Tsfc")},
         {"lhs":{"op":"D","args":["T"],"wrt":"t"},"rhs":"dTdt"}]
    write(f"a1_bare_alias_N{N}", v, e, N)
    # A2: arith alias
    v = base(N); v["Tsfc"]={"type":"unknown","units":"K"}; v["Tsfc_raw"]={"type":"unknown","units":"K"}
    e = [{"lhs":"Tsfc_raw","rhs":FORCE},{"lhs":"Tsfc","rhs":{"op":"*","args":["Tsfc_raw",1.0]}},
         {"lhs":"dTdt","rhs":tend(N,"Tsfc")},
         {"lhs":{"op":"D","args":["T"],"wrt":"t"},"rhs":"dTdt"}]
    write(f"a2_arith_alias_N{N}", v, e, N)
    # A3: direct control
    v = base(N); v["Tsfc"]={"type":"unknown","units":"K"}
    e = [{"lhs":"Tsfc","rhs":FORCE},{"lhs":"dTdt","rhs":tend(N,"Tsfc")},
         {"lhs":{"op":"D","args":["T"],"wrt":"t"},"rhs":"dTdt"}]
    write(f"a3_direct_N{N}", v, e, N)
    # A4: bare alias consumed DIRECTLY by the D rule (no dTdt observed)
    v = dict(P); v["T"]={"type":"unknown","units":"K","shape":["lev"],"default":288.0}
    v["Tsfc"]={"type":"unknown","units":"K"}; v["Tsfc_raw"]={"type":"unknown","units":"K"}
    e = [{"lhs":"Tsfc_raw","rhs":FORCE},{"lhs":"Tsfc","rhs":"Tsfc_raw"},
         {"lhs":{"op":"D","args":["T"],"wrt":"t"},"rhs":tend(N,"Tsfc")}]
    write(f"a4_alias_into_D_N{N}", v, e, N)
print("ok")
