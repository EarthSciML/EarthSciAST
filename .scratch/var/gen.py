import json, os
OUT = os.path.dirname(os.path.abspath(__file__))

def doc(name, variables, equations, index_sets=None, end=60.0, var="T", coords=None):
    d = {"esm":"1.0.0",
         "metadata":{"name":name,"description":"probe","license":"MIT"},
         "models":{"M":{"variables":variables,"equations":equations,
           "tests":[{"id":"t1","description":"run","time_span":{"start":0.0,"end":end},
             "assertions":[dict({"variable":var,"time":end,"expected":0.0,
                                 "tolerance":{"abs":1e9}}, **({"coords":coords} if coords else {}))]}]}}}
    if index_sets: d["index_sets"] = index_sets
    return d

FORCE = {"op":"+","args":["Tsfc0",{"op":"*","args":["amp",
          {"op":"sin","args":[{"op":"*","args":["omega","t"]}]}]}]}
P = {"omega":{"type":"parameter","units":"1/s","default":7.27220521664304e-05},
     "amp":{"type":"parameter","units":"K","default":10.0},
     "Tsfc0":{"type":"parameter","units":"K","default":288.0},
     "rlx":{"type":"parameter","units":"1/s","default":1.0e-3}}

def scalar(alias_rhs, extra_eq_prefix=""):
    v = dict(P)
    v["Tsfc"] = {"type":"unknown","units":"K"}
    v["Tsfc_raw"] = {"type":"unknown","units":"K"}
    v["T"] = {"type":"unknown","units":"K","default":288.0}
    eqs = [{"lhs":"Tsfc_raw","rhs":FORCE},
           {"lhs":"Tsfc","rhs":alias_rhs},
           {"lhs":{"op":"D","args":["T"],"wrt":"t"},
            "rhs":{"op":"*","args":["rlx",{"op":"-","args":["Tsfc","T"]}]}}]
    return v, eqs

# S1: pure scalar consumer, bare alias
v,e = scalar("Tsfc_raw")
json.dump(doc("s1_bare_alias_scalar", v, e), open(f"{OUT}/s1_bare_alias_scalar.esm","w"), indent=1)

# S2: same but alias body is non-trivial arithmetic (emits an instruction)
v,e = scalar({"op":"*","args":["Tsfc_raw",1.0]})
json.dump(doc("s2_arith_alias_scalar", v, e), open(f"{OUT}/s2_arith_alias_scalar.esm","w"), indent=1)

# S3: direct (no alias) scalar control
v = dict(P); v["Tsfc"]={"type":"unknown","units":"K"}; v["T"]={"type":"unknown","units":"K","default":288.0}
e = [{"lhs":"Tsfc","rhs":FORCE},
     {"lhs":{"op":"D","args":["T"],"wrt":"t"},
      "rhs":{"op":"*","args":["rlx",{"op":"-","args":["Tsfc","T"]}]}}]
json.dump(doc("s3_direct_scalar", v, e), open(f"{OUT}/s3_direct_scalar.esm","w"), indent=1)

# S4: bare alias, but alias name sorts AFTER the producer ("Zsfc" > "Tsfc_raw")
v = dict(P)
v["Tsfc_raw"]={"type":"unknown","units":"K"}; v["Zsfc"]={"type":"unknown","units":"K"}
v["T"]={"type":"unknown","units":"K","default":288.0}
e = [{"lhs":"Tsfc_raw","rhs":FORCE},{"lhs":"Zsfc","rhs":"Tsfc_raw"},
     {"lhs":{"op":"D","args":["T"],"wrt":"t"},
      "rhs":{"op":"*","args":["rlx",{"op":"-","args":["Zsfc","T"]}]}}]
json.dump(doc("s4_alias_sorts_after", v, e), open(f"{OUT}/s4_alias_sorts_after.esm","w"), indent=1)

# S5: bare alias of a PARAMETER (no t dependence at all)
v = dict(P); v["Tsfc"]={"type":"unknown","units":"K"}; v["T"]={"type":"unknown","units":"K","default":288.0}
e = [{"lhs":"Tsfc","rhs":"Tsfc0"},
     {"lhs":{"op":"D","args":["T"],"wrt":"t"},
      "rhs":{"op":"*","args":["rlx",{"op":"-","args":["Tsfc","T"]}]}}]
json.dump(doc("s5_alias_of_param", v, e), open(f"{OUT}/s5_alias_of_param.esm","w"), indent=1)

# S6: bare alias directly of t
v = dict(P); v["Tsfc"]={"type":"unknown","units":"K"}; v["T"]={"type":"unknown","units":"K","default":288.0}
e = [{"lhs":"Tsfc","rhs":"t"},
     {"lhs":{"op":"D","args":["T"],"wrt":"t"},
      "rhs":{"op":"*","args":["rlx",{"op":"-","args":["Tsfc","T"]}]}}]
json.dump(doc("s6_alias_of_time", v, e), open(f"{OUT}/s6_alias_of_time.esm","w"), indent=1)

# S7: bare alias of a STATE variable
v = dict(P); v["Tsfc"]={"type":"unknown","units":"K"}; v["T"]={"type":"unknown","units":"K","default":288.0}
e = [{"lhs":"Tsfc","rhs":"T"},
     {"lhs":{"op":"D","args":["T"],"wrt":"t"},
      "rhs":{"op":"*","args":["rlx",{"op":"-","args":[{"op":"*","args":["Tsfc",0.5]},"T"]}]}}]
json.dump(doc("s7_alias_of_state", v, e), open(f"{OUT}/s7_alias_of_state.esm","w"), indent=1)
print("ok")
