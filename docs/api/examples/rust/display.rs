//! Print equations and expressions as math for people: LaTeX or Typst.

use earthsci_ast::{DocumentFormat, expression_names, load_path, print_math};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: display ops=print_math,expression_names
    let doc = load_path(fixture("decay.esm"))?;
    let model = &doc.models.as_ref().unwrap()["Decay"];

    // print_math takes the JSON form of an expression or equation, and the
    // names it may use: a run of letters is one name only when declared.
    let decay = serde_json::to_value(&model.equations[0])?;
    let names = expression_names(&decay);
    assert_eq!(names, ["N", "lambda"]);

    let latex = print_math(&decay, &names, DocumentFormat::Markdown);
    let typst = print_math(&decay, &names, DocumentFormat::Typst);
    println!("{latex}\n{typst}");
    assert_eq!(
        latex,
        r"\frac{\mathrm{d} N}{\mathrm{d} t} = \left(-\lambda\right) N"
    );
    assert_eq!(typst, "(dif N)/(dif t) = (-lambda) N");

    // An expression prints the same way, and `Display` is its Typst math.
    let rhs = &model.equations[1].rhs;
    assert_eq!(rhs.to_string(), "ln(2)/lambda");
    // endregion

    Ok(())
}
