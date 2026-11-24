//! The commands that read a document and report on it without integrating
//! it: `validate`, `pretty`, `extract`, `diff`, `stoich`, `graph`, `convert`,
//! `info`, `units`, `validate-fixtures` and `round-trip`.

use earthsci_ast::{
    EquationDimensionVerdict, ExpressionGraphOptions, StructuralErrorCode, Unit, UnitError,
    component_exists, component_graph, equation_dimension_verdict_with_operators, expression_graph,
    expression_graph_with_options, model_unit_env, parse_unit, stoichiometric_matrix, to_json,
    to_json_compact, validate, validate_text,
};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use crate::args::{ConvertFormat, GraphFormat, GraphLevel, MathFormat};
use crate::esm_impl::{fail, fail_silent};
use crate::input::{collect_esm_files, load_at, read_input};

pub(crate) fn analyze_model_units(esm_file: &earthsci_ast::EsmFile) {
    if let Some(ref models) = esm_file.models {
        for (model_id, model) in models {
            println!("Model: {model_id}");

            // Analyze variable units
            let mut unit_count = 0;
            for (var_name, var) in &model.variables {
                if let Some(ref units) = var.units {
                    println!("  Variable {var_name}: {var_name} [{units}]");
                    unit_count += 1;
                } else {
                    println!("  Variable {var_name}: {var_name} [no units specified]");
                }
            }

            println!(
                "  {} out of {} variables have units specified",
                unit_count,
                model.variables.len()
            );

            for (i, equation, verdict) in model_equation_verdicts(esm_file, model_id, model) {
                let label = match equation_lhs_label(&equation.lhs) {
                    Some(lhs) => format!("Equation {} ({lhs})", i + 1),
                    None => format!("Equation {}", i + 1),
                };
                match verdict {
                    EquationDimensionVerdict::Consistent(dim) => {
                        println!("  {label}: consistent [{dim}]");
                    }
                    EquationDimensionVerdict::Mismatch(messages) => {
                        println!("  {label}: MISMATCH — {}", messages.join("; "));
                    }
                    EquationDimensionVerdict::NotChecked(reason) => {
                        println!("  {label}: NOT CHECKED — {reason}");
                    }
                }
            }
        }
    }
}

/// The dimensional analyser's verdict on each of the equations of `model`,
/// the document's model `model_id`, judged against the same unit environment
/// and operator registry `validate` uses.
pub(crate) fn model_equation_verdicts<'m>(
    esm_file: &earthsci_ast::EsmFile,
    model_id: &str,
    model: &'m earthsci_ast::Model,
) -> Vec<(usize, &'m earthsci_ast::Equation, EquationDimensionVerdict)> {
    let (env, _) = model_unit_env(esm_file, model);
    let operators = esm_file.component_operators(&format!("models.{model_id}"));
    model
        .equations
        .iter()
        .enumerate()
        .map(|(i, eq)| {
            (
                i,
                eq,
                equation_dimension_verdict_with_operators(eq, &env, &operators),
            )
        })
        .collect()
}

/// A short name for an equation's left-hand side: `x` or `D(x)`.
pub(crate) fn equation_lhs_label(lhs: &earthsci_ast::Expr) -> Option<String> {
    match lhs {
        earthsci_ast::Expr::Variable(name) => Some(name.clone()),
        earthsci_ast::Expr::Operator(op) if op.op == "D" => match op.args.first() {
            Some(earthsci_ast::Expr::Variable(name)) => Some(format!("D({name})")),
            _ => None,
        },
        _ => None,
    }
}

pub(crate) fn analyze_reaction_system_units(
    esm_file: &earthsci_ast::EsmFile,
    validation: &earthsci_ast::ValidationResult,
) {
    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        for (rs_id, rs) in reaction_systems {
            println!("Reaction System: {rs_id}");

            // Analyze species units
            let mut species_with_units = 0;
            for (species_name, species) in &rs.species {
                if let Some(ref units) = species.units {
                    println!("  Species {species_name}: [{units}]");
                    species_with_units += 1;
                } else {
                    println!("  Species {species_name}: [no units]");
                }
            }

            println!(
                "  {} out of {} species have units specified",
                species_with_units,
                rs.species.len()
            );

            for (i, verdict) in reaction_rate_verdicts(rs_id, rs, validation) {
                match verdict {
                    RateVerdict::Consistent => println!(
                        "  Reaction {} rate: no stoichiometric mismatch found",
                        i + 1
                    ),
                    RateVerdict::Mismatch(message) => {
                        println!("  Reaction {} rate: MISMATCH — {message}", i + 1);
                    }
                    RateVerdict::NotChecked(reason) => {
                        println!("  Reaction {} rate: NOT CHECKED — {reason}", i + 1);
                    }
                }
            }
        }
    }
}

/// The dimensional analyser's verdict on one reaction's rate expression.
pub(crate) enum RateVerdict {
    /// The rate's dimension resolved and no stoichiometric mismatch was found.
    Consistent,
    /// A provable mismatch: either the stoichiometric one `validate` reports, or
    /// an inconsistency between the rate expression's own operands.
    Mismatch(String),
    /// The rate's dimension could not be determined, so nothing was compared.
    NotChecked(String),
}

/// Judge every reaction's rate in `rs`, paired with its 0-based index.
///
/// The stoichiometric rate check lives in `validate`; its findings are keyed by
/// the reaction's JSON Pointer, so they are read back out of `validation`
/// rather than recomputed. A rate whose own operands are provably incompatible
/// is a MISMATCH too — the analyser did reach a verdict — and only an
/// undeterminable dimension is "not checked".
pub(crate) fn reaction_rate_verdicts(
    rs_id: &str,
    rs: &earthsci_ast::ReactionSystem,
    validation: &earthsci_ast::ValidationResult,
) -> Vec<(usize, RateVerdict)> {
    let env: HashMap<String, Unit> = rs
        .species
        .iter()
        .map(|(name, s)| (name, &s.units))
        .chain(rs.parameters.iter().map(|(name, p)| (name, &p.units)))
        .filter_map(|(name, units)| {
            let unit = parse_unit(units.as_deref()?).ok()?;
            Some((name.clone(), unit))
        })
        .collect();
    rs.reactions
        .iter()
        .enumerate()
        .map(|(i, reaction)| {
            let path = format!("/reaction_systems/{rs_id}/reactions/{i}");
            let mismatches: Vec<&str> = validation
                .structural_errors
                .iter()
                .filter(|e| {
                    e.path == path && matches!(e.code, StructuralErrorCode::UnitInconsistency)
                })
                .map(|e| e.message.as_str())
                .collect();
            if !mismatches.is_empty() {
                return (i, RateVerdict::Mismatch(mismatches.join("; ")));
            }
            match Unit::propagate(&reaction.rate, &env) {
                Ok(_) => (i, RateVerdict::Consistent),
                Err(UnitError::DimensionMismatch(message)) => (i, RateVerdict::Mismatch(message)),
                Err(e) => (i, RateVerdict::NotChecked(e.to_string())),
            }
        })
        .collect()
}

/// Print the semantic comparison of two loaded files (canonical-JSON
/// equality plus a coarse structural breakdown on divergence). Returns true
/// when the files are semantically identical; the caller decides whether a
/// divergence is a failing exit.
pub(crate) fn semantic_compare(
    esm_file1: &earthsci_ast::EsmFile,
    esm_file2: &earthsci_ast::EsmFile,
) -> Result<bool, Box<dyn std::error::Error>> {
    let json1 = serde_json::to_value(esm_file1)?;
    let json2 = serde_json::to_value(esm_file2)?;

    if json1 == json2 {
        println!("✓ Files are semantically identical");
        return Ok(true);
    }
    println!("✗ Files differ semantically");

    // Basic structural comparison
    if esm_file1.esm != esm_file2.esm {
        println!("  ESM version: {} vs {}", esm_file1.esm, esm_file2.esm);
    }

    let models1_count = esm_file1.models.as_ref().map(|m| m.len()).unwrap_or(0);
    let models2_count = esm_file2.models.as_ref().map(|m| m.len()).unwrap_or(0);
    if models1_count != models2_count {
        println!("  Model count: {models1_count} vs {models2_count}");
    }

    let rs1_count = esm_file1
        .reaction_systems
        .as_ref()
        .map(|rs| rs.len())
        .unwrap_or(0);
    let rs2_count = esm_file2
        .reaction_systems
        .as_ref()
        .map(|rs| rs.len())
        .unwrap_or(0);
    if rs1_count != rs2_count {
        println!("  Reaction system count: {rs1_count} vs {rs2_count}");
    }

    Ok(false)
}

// === Per-subcommand handlers ===============================================

pub(crate) fn run_validate(file: PathBuf, verbose: bool) -> Result<(), Box<dyn std::error::Error>> {
    let content = read_input(&file)?;

    // Perform complete validation (schema + structural). Anchor relative
    // §4.7/§9.7 refs at the input file's own directory when validating a
    // real path so a document with relative refs is not spuriously
    // rejected (stdin has no directory → process CWD).
    let base_dir = file.parent();
    let validation_result = validate_text(&content, base_dir);

    if validation_result.is_valid {
        println!("✓ Validation passed");
        if verbose
            && (!validation_result.unit_warnings.is_empty()
                || !validation_result.warnings.is_empty())
        {
            println!("Warnings:");
            for warning in &validation_result.warnings {
                println!("  ⚠ [{}] {}", warning.code, warning.message);
            }
            for warning in &validation_result.unit_warnings {
                // `message` is the exact string this line printed when
                // `unit_warnings` was a `Vec<String>`; the record's `path` /
                // `code` are for machine consumers.
                println!("  ⚠ {}", warning.message);
            }
        }
    } else {
        println!("✗ Validation failed");

        if !validation_result.schema_errors.is_empty() {
            println!("Schema errors:");
            for error in &validation_result.schema_errors {
                println!("  ✗ {}: {}", error.path, error.message);
            }
        }

        if !validation_result.structural_errors.is_empty() {
            println!("Structural errors:");
            for error in &validation_result.structural_errors {
                if verbose {
                    println!("  ✗ {} ({}): {}", error.path, error.code, error.message);
                    if !error.details.is_null() {
                        println!("    Details: {}", error.details);
                    }
                } else {
                    println!("  ✗ {}: {}", error.path, error.message);
                }
            }
        }
        return Err(fail_silent());
    }
    Ok(())
}

pub(crate) fn run_pretty(
    file: PathBuf,
    format: MathFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let content = read_input(&file)?;
    let esm_file = load_at(&file, &content)?;

    // An expression or an equation, printed with its own names declared.
    let render = |value: serde_json::Value| {
        let names = earthsci_ast::expression_names(&value);
        earthsci_ast::print_math(&value, &names, format.into())
    };

    println!("Displaying expressions in {}:", file.display());

    // Print model equations
    if let Some(ref models) = esm_file.models {
        for (model_id, model) in models {
            println!(
                "\nModel: {} ({})",
                model_id,
                model.name.as_deref().unwrap_or("unnamed")
            );
            for (i, equation) in model.equations.iter().enumerate() {
                let equation = serde_json::json!({
                    "lhs": serde_json::to_value(&equation.lhs)?,
                    "rhs": serde_json::to_value(&equation.rhs)?,
                });
                println!("  Eq {}: {}", i + 1, render(equation));
            }
        }
    }

    // Print reaction rates
    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        for (rs_id, rs) in reaction_systems {
            println!("\nReaction System: {rs_id}");
            for (i, reaction) in rs.reactions.iter().enumerate() {
                let rate = render(serde_json::to_value(&reaction.rate)?);
                println!("  Reaction {}: rate = {}", i + 1, rate);
            }
        }
    }
    Ok(())
}

pub(crate) fn run_extract(
    file: PathBuf,
    component: String,
    output: Option<PathBuf>,
) -> Result<(), Box<dyn std::error::Error>> {
    let content = read_input(&file)?;
    let esm_file = load_at(&file, &content)?;

    // Check if component exists
    if !component_exists(&esm_file, &component) {
        return Err(fail(format!(
            "Component '{component}' not found in the ESM file"
        )));
    }

    // Create a new ESM file with just the requested component. The extracted
    // component is a NEW document. Any template call sites it had were
    // already expanded at load, and metaparameters already folded, so it
    // declares neither.
    let mut extracted_esm = earthsci_ast::EsmFile {
        esm: esm_file.esm.clone(),
        metadata: esm_file.metadata.clone(),
        // Document-scoped registry (v0.8.0): preserve it on the
        // extracted component so its `{ "from": <set> }` ranges resolve.
        index_sets: esm_file.index_sets.clone(),
        domain: esm_file.domain.clone(),
        ..Default::default()
    };

    // Extract the specific component
    if let Some(ref models) = esm_file.models
        && let Some(model) = models.get(&component)
    {
        let mut extracted_models = indexmap::IndexMap::new();
        extracted_models.insert(component.clone(), model.clone());
        extracted_esm.models = Some(extracted_models);
    }

    if let Some(ref reaction_systems) = esm_file.reaction_systems
        && let Some(rs) = reaction_systems.get(&component)
    {
        let mut extracted_rs = indexmap::IndexMap::new();
        extracted_rs.insert(component.clone(), rs.clone());
        extracted_esm.reaction_systems = Some(extracted_rs);
    }

    if let Some(ref data_sources) = esm_file.data_sources
        && let Some(dl) = data_sources.get(&component)
    {
        let mut extracted_dl = indexmap::IndexMap::new();
        extracted_dl.insert(component.clone(), dl.clone());
        extracted_esm.data_sources = Some(extracted_dl);
    }

    let output_content = to_json(&extracted_esm)?;

    if let Some(output_path) = output {
        fs::write(&output_path, output_content)?;
        println!(
            "Extracted component '{}' to {}",
            component,
            output_path.display()
        );
    } else {
        print!("{output_content}");
    }
    Ok(())
}

pub(crate) fn run_diff(file1: PathBuf, file2: PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let content1 = read_input(&file1)?;
    let content2 = read_input(&file2)?;
    let esm_file1 = load_at(&file1, &content1)?;
    let esm_file2 = load_at(&file2, &content2)?;

    println!("Comparing {} and {}:", file1.display(), file2.display());

    if !semantic_compare(&esm_file1, &esm_file2)? {
        return Err(fail_silent());
    }
    Ok(())
}

pub(crate) fn run_stoich(file: PathBuf, system: String) -> Result<(), Box<dyn std::error::Error>> {
    let content = read_input(&file)?;
    let esm_file = load_at(&file, &content)?;

    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        if let Some(rs) = reaction_systems.get(&system) {
            println!("Stoichiometric matrix for reaction system '{system}':");

            // The matrix is the LIBRARY's `stoichiometric_matrix`, not a second
            // computation. This used to rebuild it by hand from a SORTED
            // species order, which was harmless while the library sorted too and
            // wrong the moment it stopped: species order is declaration order in
            // every binding now (API_SPEC.md §5.10), so a hand-rolled sort here
            // would print the rows of one matrix under the column labels of
            // another.
            //
            // The library returns species-by-reaction; this view is its
            // TRANSPOSE — one line per reaction, one column per species — which
            // is a presentation choice, not a second answer.
            let matrix = stoichiometric_matrix(rs);
            let species: Vec<&String> = rs.species.keys().collect();

            print!("{:>15}", "");
            for name in &species {
                print!("{name:>10}");
            }
            println!();

            for reaction_idx in 0..rs.reactions.len() {
                print!("Reaction {:>3}:", reaction_idx + 1);
                for row in &matrix {
                    print!("{:>10.1}", row[reaction_idx]);
                }
                println!();
            }
        } else {
            return Err(fail(format!("Reaction system '{system}' not found")));
        }
    } else {
        return Err(fail("No reaction systems found in the file"));
    }
    Ok(())
}

/// Render a graph in one of the three §4.8.3 formats.
///
/// The renderers are the LIBRARY's — `earthsci_ast::to_dot` / `to_mermaid` /
/// `to_json_graph`, generic over the `Graph` trait that both `ComponentGraph`
/// and `ExpressionGraph` implement. This subcommand used to roll its own, which
/// made `esm graph` a SECOND, unpinned renderer of the same graphs, and the two
/// had drifted: the CLI wrote `[label="x", shape=y]` where the library writes
/// `[label="x" shape=y]`, it interpolated ids and labels without `escape_dot` /
/// `mermaid_label` (so a component name containing a quote produced malformed
/// DOT), and its `--format json` emitted a different document entirely — node
/// key `type` instead of `component_type`, edge keys `from`/`to`/`type` instead
/// of `source`/`target`/`data`, no `metadata`, and no `adjacency` map at all,
/// even though esm-libraries-spec §5.4.5 calls that output "JSON adjacency
/// list".
///
/// Phase 6 made the library renderers canonical and pinned them with
/// `tests/conformance/graph/cases.json`. A second path to the same renderings is
/// the defect §8 item 8 removed from Go; this removes it from the CLI.
pub(crate) fn render_graph<G: earthsci_ast::Graph>(graph: &G, format: GraphFormat) {
    match format {
        GraphFormat::Dot => println!("{}", earthsci_ast::to_dot(graph)),
        GraphFormat::Mermaid => println!("{}", earthsci_ast::to_mermaid(graph)),
        GraphFormat::Json => println!("{}", earthsci_ast::to_json_graph(graph)),
    }
}

pub(crate) fn run_graph(
    file: PathBuf,
    level: GraphLevel,
    format: GraphFormat,
    system: Option<String>,
) -> Result<(), Box<dyn std::error::Error>> {
    let content = read_input(&file)?;
    let esm_file = load_at(&file, &content)?;

    match level {
        GraphLevel::Component => render_graph(&component_graph(&esm_file), format),
        GraphLevel::Expression => {
            // Both forms esm-libraries-spec §5.4.5 documents. `--level=expression`
            // used to print "not yet implemented" and exit 1 — writing it meant
            // writing a second expression renderer, which routing through the
            // library makes unnecessary.
            match system {
                // A single named system: the ExpressionGraphInput impls for
                // Model and ReactionSystem.
                Some(name) => {
                    if let Some(model) = esm_file.models.as_ref().and_then(|m| m.get(&name)) {
                        render_graph(&expression_graph(model), format)
                    } else if let Some(rs) = esm_file
                        .reaction_systems
                        .as_ref()
                        .and_then(|r| r.get(&name))
                    {
                        render_graph(&expression_graph(rs), format)
                    } else {
                        return Err(fail(format!(
                            "Unsupported system: {name}. Name a model or reaction system \
                             declared in this file."
                        )));
                    }
                }
                // "all systems merged": the whole-document graph with
                // `variable_map` coupling folded into cross-system edges.
                None => render_graph(
                    &expression_graph_with_options(
                        &esm_file,
                        &ExpressionGraphOptions {
                            merge_coupled: true,
                        },
                    ),
                    format,
                ),
            }
        }
    }
    Ok(())
}

pub(crate) fn run_convert(
    input: PathBuf,
    output: Option<PathBuf>,
    to: ConvertFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let content = read_input(&input)?;
    let esm_file = load_at(&input, &content)?;

    let output_content = match to {
        ConvertFormat::Json => to_json(&esm_file)?,
        ConvertFormat::CompactJson => to_json_compact(&esm_file)?,
        ConvertFormat::Markdown | ConvertFormat::Typst => {
            let format = match to {
                ConvertFormat::Markdown => earthsci_ast::DocumentFormat::Markdown,
                _ => earthsci_ast::DocumentFormat::Typst,
            };
            match serde_json::from_str::<serde_json::Value>(&to_json(&esm_file)?)? {
                serde_json::Value::Object(doc) => earthsci_ast::print_document(&doc, format),
                _ => return Err(fail("the document is not a JSON object")),
            }
        }
    };

    if let Some(output_path) = output {
        fs::write(&output_path, output_content)?;
        println!("Converted {} to {}", input.display(), output_path.display());
    } else {
        print!("{output_content}");
    }
    Ok(())
}

pub(crate) fn run_info(file: PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let content = read_input(&file)?;
    let esm_file = load_at(&file, &content)?;

    println!("ESM File Information for: {}", file.display());
    println!("ESM Version: {}", esm_file.esm);

    if let Some(ref name) = esm_file.metadata.name {
        println!("Model Name: {name}");
    }
    if let Some(ref description) = esm_file.metadata.description {
        println!("Description: {description}");
    }
    if let Some(ref authors) = esm_file.metadata.authors {
        println!("Authors: {}", authors.join(", "));
    }

    if let Some(ref models) = esm_file.models {
        println!("Models: {} component(s)", models.len());
        for (id, model) in models {
            println!(
                "  - {} ({} vars, {} eqs)",
                id,
                model.variables.len(),
                model.equations.len()
            );
        }
    }

    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        println!("Reaction Systems: {} component(s)", reaction_systems.len());
        for (id, rs) in reaction_systems {
            println!(
                "  - {} ({} species, {} reactions)",
                id,
                rs.species.len(),
                rs.reactions.len()
            );
        }
    }

    if let Some(ref data_sources) = esm_file.data_sources {
        println!("Data Loaders: {} component(s)", data_sources.len());
    }

    if let Some(operators) = esm_file
        .expression_templates
        .as_ref()
        .and_then(|o| o.as_object())
    {
        println!("Operators: {} definition(s)", operators.len());
    }

    if let Some(ref coupling) = esm_file.coupling {
        println!("Coupling Rules: {} rule(s)", coupling.len());
    }
    Ok(())
}

/// The distinct unit strings declared across all model variables and
/// reaction-system species, sorted for stable output.
pub(crate) fn collect_unit_types(esm_file: &earthsci_ast::EsmFile) -> Vec<String> {
    let mut units = std::collections::BTreeSet::new();
    for model in esm_file.models.iter().flat_map(|m| m.values()) {
        units.extend(model.variables.values().filter_map(|v| v.units.clone()));
    }
    for rs in esm_file.reaction_systems.iter().flat_map(|r| r.values()) {
        units.extend(rs.species.values().filter_map(|s| s.units.clone()));
    }
    units.into_iter().collect()
}

pub(crate) fn run_units(file: PathBuf, check: bool) -> Result<(), Box<dyn std::error::Error>> {
    let content = read_input(&file)?;
    let esm_file = load_at(&file, &content)?;

    println!("Units Analysis for: {}", file.display());

    if check {
        println!("\n=== DIMENSIONAL CONSISTENCY CHECK ===");
        // A provable mismatch or an unresolvable unit string is a structural
        // error, not a warning (esm-spec §4.8.4).
        let validation_result = validate(&esm_file);
        let unit_errors: Vec<_> = validation_result
            .structural_errors
            .iter()
            .filter(|e| {
                matches!(
                    e.code,
                    StructuralErrorCode::UnitInconsistency | StructuralErrorCode::UnitParseError
                )
            })
            .collect();

        let mut error_lines: Vec<String> = unit_errors
            .iter()
            .map(|e| format!("{}: {}", e.path, e.message))
            .collect();

        let (mut consistent, mut mismatched, mut not_checked) = (0, 0, 0);
        for (model_id, model) in esm_file.models.iter().flatten() {
            for (_, _, verdict) in model_equation_verdicts(&esm_file, model_id, model) {
                match verdict {
                    EquationDimensionVerdict::Consistent(_) => consistent += 1,
                    EquationDimensionVerdict::Mismatch(_) => mismatched += 1,
                    EquationDimensionVerdict::NotChecked(_) => not_checked += 1,
                }
            }
        }

        // Reaction rates are judged here too. `validate` routes only the
        // STOICHIOMETRIC rate check to a structural error, so a rate whose own
        // operands are provably incompatible reaches no error list — and
        // reporting it in the reaction report while `--check` calls the document
        // consistent would be the same wrong-way-round confidence #303 is about.
        let (mut rates_ok, mut rates_bad, mut rates_unchecked) = (0, 0, 0);
        for (rs_id, rs) in esm_file.reaction_systems.iter().flat_map(|m| m.iter()) {
            for (i, verdict) in reaction_rate_verdicts(rs_id, rs, &validation_result) {
                match verdict {
                    RateVerdict::Consistent => rates_ok += 1,
                    RateVerdict::Mismatch(message) => {
                        rates_bad += 1;
                        let line = format!("/reaction_systems/{rs_id}/reactions/{i}: {message}");
                        if !error_lines.contains(&line) {
                            error_lines.push(line);
                        }
                    }
                    RateVerdict::NotChecked(_) => rates_unchecked += 1,
                }
            }
        }

        if !error_lines.is_empty() {
            println!("Unit errors:");
            for line in &error_lines {
                println!("  ✗ {line}");
            }
        }
        if !validation_result.unit_warnings.is_empty() {
            println!("Unit warnings:");
            for warning in &validation_result.unit_warnings {
                println!("  ⚠ {}", warning.message);
            }
        }

        println!(
            "Equations: {consistent} consistent, {mismatched} mismatched, {not_checked} not checked"
        );
        if rates_ok + rates_bad + rates_unchecked > 0 {
            println!(
                "Reaction rates: {rates_ok} consistent, {rates_bad} mismatched, {rates_unchecked} not checked"
            );
        }

        // The exit status follows the verdicts this command just printed, not
        // only `validate`'s error list, so the two can never disagree.
        if !error_lines.is_empty() || mismatched > 0 || rates_bad > 0 {
            return Err(fail_silent());
        }
        if not_checked == 0 && rates_unchecked == 0 {
            println!("✓ All units are dimensionally consistent");
        } else {
            println!(
                "✓ No dimensional mismatch found; run without --check to see why equations were not checked"
            );
        }
    } else {
        println!("\n=== COMPREHENSIVE UNIT ANALYSIS ===");

        // Analyze units in all components
        let validation_result = validate(&esm_file);
        analyze_model_units(&esm_file);
        analyze_reaction_system_units(&esm_file, &validation_result);

        // Unit system summary
        println!("\n=== UNIT SYSTEM SUMMARY ===");
        let unit_summary = collect_unit_types(&esm_file);

        if unit_summary.is_empty() {
            println!("No units specified in the model");
        } else {
            println!("Unit types found:");
            for unit_type in &unit_summary {
                println!("  - {unit_type}");
            }

            // Unit system recommendations
            println!("\n=== RECOMMENDATIONS ===");
            if unit_summary.contains(&"m".to_string()) && unit_summary.contains(&"cm".to_string()) {
                println!("⚠ Mixed length units detected (m, cm) - consider standardizing");
            }
            if unit_summary.contains(&"s".to_string()) && unit_summary.contains(&"min".to_string())
            {
                println!("⚠ Mixed time units detected (s, min) - consider standardizing");
            }

            // Check for SI compliance
            let si_base_units = ["m", "kg", "s", "A", "K", "mol", "cd"];
            let using_si = unit_summary
                .iter()
                .any(|u| si_base_units.contains(&u.as_str()));
            if using_si {
                println!("✓ SI base units detected - good for scientific consistency");
            } else {
                println!("ℹ Consider using SI base units for scientific consistency");
            }
        }
    }
    Ok(())
}

pub(crate) fn run_validate_fixtures(
    directory: PathBuf,
    recursive: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    println!("Validating fixtures in: {}", directory.display());
    println!("Recursive: {recursive}");

    if !directory.is_dir() {
        return Err(fail(format!(
            "Directory does not exist: {}",
            directory.display()
        )));
    }

    let mut files = Vec::new();
    collect_esm_files(&directory, recursive, &mut files)?;
    files.sort();

    if files.is_empty() {
        println!("No .esm files found");
    }

    let mut passed = 0usize;
    let mut failed = 0usize;
    for path in &files {
        let content = match fs::read_to_string(path) {
            Ok(c) => c,
            Err(e) => {
                println!("✗ {} (cannot read: {e})", path.display());
                failed += 1;
                continue;
            }
        };
        let result = validate_text(&content, path.parent());
        if result.is_valid {
            println!("✓ {}", path.display());
            passed += 1;
        } else {
            let n = result.schema_errors.len() + result.structural_errors.len();
            println!("✗ {} ({n} error(s))", path.display());
            failed += 1;
        }
    }

    println!("\n{passed} passed, {failed} failed ({} total)", files.len());
    if failed > 0 {
        return Err(fail_silent());
    }
    Ok(())
}

pub(crate) fn run_round_trip(
    file: PathBuf,
    rounds: usize,
) -> Result<(), Box<dyn std::error::Error>> {
    println!(
        "Round-trip test for: {} ({} rounds)",
        file.display(),
        rounds
    );

    let original_content = read_input(&file)?;
    let mut content = original_content.clone();

    // esm-spec §4.7 / §8.2.1 both anchor on the directory of the REFERENCING
    // FILE. This command used to `load_string` with no base, so every relative
    // `ref` resolved against the process working directory instead — a document
    // that `validate` and `test` loaded fine failed to round-trip unless you
    // happened to `cd` into its directory first (downstream finding F7). With
    // §8.2.1 in place that would have been worse than cosmetic: a relative
    // `url_template` would have meant one thing under `validate` and another
    // here, which is the bug class §8.2.1 exists to close. Every round uses the
    // file's own directory, including the rounds that load EMITTED text — that
    // text stands in for the same file, so it must resolve against the same
    // base.
    let opts = earthsci_ast::LoadOptions {
        base_path: Some(
            file.parent()
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or_else(|| std::path::Path::new("."))
                .to_path_buf(),
        ),
        ..Default::default()
    };

    for round in 1..=rounds {
        // Load
        let esm_file = earthsci_ast::load_string_with_options(&content, &opts)
            .map_err(|e| fail(format!("Round {round}: Load failed: {e}")))?;

        // Save
        content =
            to_json(&esm_file).map_err(|e| fail(format!("Round {round}: Save failed: {e}")))?;

        println!("Round {round}: OK");
    }

    // Check if final content matches original (semantically)
    let original_esm = earthsci_ast::load_string_with_options(&original_content, &opts)?;
    let final_esm = earthsci_ast::load_string_with_options(&content, &opts)?;

    let original_json = serde_json::to_value(&original_esm)?;
    let final_json = serde_json::to_value(&final_esm)?;

    if original_json == final_json {
        println!("✓ Round-trip fidelity maintained");
    } else {
        println!("✗ Round-trip fidelity lost");
        return Err(fail_silent());
    }
    Ok(())
}
