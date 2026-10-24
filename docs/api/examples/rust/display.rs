//! Render equations and expressions for people: Unicode, LaTeX and plain text.

use earthsci_ast::{load_path, to_ascii, to_latex, to_unicode};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: display ops=to_unicode,to_latex,to_ascii
    let doc = load_path(fixture("decay.esm"))?;
    let model = &doc.models.as_ref().unwrap()["Decay"];
    let decay = &model.equations[0];

    let unicode = to_unicode(decay);
    let latex = to_latex(decay);
    let ascii = to_ascii(decay);
    println!("{unicode}\n{latex}\n{ascii}");
    assert_eq!(ascii, "D(N)/Dt = (-lambda) * N");
    assert!(unicode.contains('λ'));
    assert!(latex.contains("\\lambda"));

    // The same functions take a single expression, or a whole model (which
    // renders a summary).
    assert_eq!(to_ascii(&model.equations[1].rhs), "log(2) / lambda");
    assert!(to_unicode(model).contains("half_life"));
    // endregion

    Ok(())
}
