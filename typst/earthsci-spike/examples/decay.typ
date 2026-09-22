#import "../lib.typ": *
#set page(width: 16cm, height: auto, margin: 1cm)

= earthsci plugin spike

Plugin version: #version()

#let eq = render("D(N, t) = -lambda*N")
- ASCII: #raw(eq.ascii)
- Unicode: #eq.unicode
- LaTeX: #raw(eq.latex)

#let model = read("decay.esm")
#let v = validate(model)
Valid: #v.is_valid (#v.structural_errors.len() structural errors, #v.unit_warnings.len() unit warnings)

#let sol = solve(model, t_end: 50, outputPoints: 51)
Return code: #sol.retcode. $N(50) = #calc.round(sol.state.at(0).last(), digits: 6)$, analytical $100 e^(-5) = #calc.round(100 * calc.exp(-5), digits: 6)$.

#lineplot(sol.time, sol.state.at(0))
