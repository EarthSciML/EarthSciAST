//! `esm-narrative`: build narrative Markdown pages into a documentation site.
//!
//! Each page under the source directory becomes three things: a Markdown page
//! with its mathematics, test results and figures filled in; the `.esm` file it
//! defines, served as a download; and an exit code, so that an invalid model or
//! a failing test stops a deploy.
//!
//! A page `decay.md` is written as a Hugo leaf bundle, `decay/index.md`, with
//! `decay.esm` beside it. Hugo publishes the file next to the page, so the
//! download link is just `decay.esm`, and it resolves under whatever base URL
//! the site is served from. A section page, `_index.md`, keeps its name; its
//! file goes beside it in the section's directory.
//!
//! ```text
//! esm-narrative build --source docs/narrative --output docs/content/generated/narrative
//! esm-narrative build --check     # CI: is the generated output current?
//! esm-narrative build --watch     # while writing
//! ```

use std::collections::BTreeMap;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, SystemTime};

use clap::{Args, Parser, Subcommand};
use earthsci_narrative::build::{BuildOptions, build_value};
use earthsci_narrative::diagnostic::Severity;
use earthsci_narrative::markdown::{self, RenderOptions};

#[derive(Parser)]
#[command(
    name = "esm-narrative",
    about = "Build narrative EarthSciAST models written in Markdown",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Build every page under the source directory.
    Build(Build),
}

#[derive(Args)]
struct Build {
    /// The directory of narrative Markdown pages.
    #[arg(long, default_value = "docs/narrative")]
    source: PathBuf,
    /// Where the built pages go.
    #[arg(long, default_value = "docs/content/generated/narrative")]
    output: PathBuf,
    /// Report what would change without writing anything. Stale output is an
    /// error, which is what CI checks.
    #[arg(long)]
    check: bool,
    /// Rebuild whenever a source page changes.
    #[arg(long, conflicts_with = "check")]
    watch: bool,
    /// Do not run the tests or the analyses. Faster, and no figures.
    #[arg(long)]
    no_run: bool,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let Command::Build(build) = &cli.command;
    if build.watch {
        return watch(build);
    }
    match run(build) {
        Ok(report) => {
            report.print();
            if report.failed() {
                ExitCode::FAILURE
            } else {
                ExitCode::SUCCESS
            }
        }
        Err(e) => {
            eprintln!("esm-narrative: {e}");
            ExitCode::from(2)
        }
    }
}

/// What one build did.
#[derive(Default)]
struct Report {
    pages: usize,
    errors: usize,
    warnings: usize,
    /// Written files, or, under `--check`, the ones that are out of date.
    changed: Vec<PathBuf>,
    /// Whether this was a `--check` run, where a change is a failure.
    checking: bool,
}

impl Report {
    fn failed(&self) -> bool {
        self.errors > 0 || (self.checking && !self.changed.is_empty())
    }

    fn print(&self) {
        if self.checking && !self.changed.is_empty() {
            eprintln!(
                "{} generated file(s) are out of date; run `esm-narrative build`:",
                self.changed.len()
            );
            for path in &self.changed {
                eprintln!("  {}", path.display());
            }
        }
        let mut line = format!("{} page(s)", self.pages);
        if !self.checking {
            line.push_str(&format!(", {} file(s) written", self.changed.len()));
        }
        if self.errors > 0 {
            line.push_str(&format!(", {} error(s)", self.errors));
        }
        if self.warnings > 0 {
            line.push_str(&format!(", {} warning(s)", self.warnings));
        }
        eprintln!("esm-narrative: {line}");
    }
}

fn run(build: &Build) -> Result<Report, String> {
    let mut report = Report {
        checking: build.check,
        ..Report::default()
    };
    for source in pages(&build.source)? {
        build_page(build, &source, &mut report)?;
    }
    Ok(report)
}

/// Every `.md` file under `dir`, in a stable order.
fn pages(dir: &Path) -> Result<Vec<PathBuf>, String> {
    if !dir.exists() {
        return Err(format!("no such directory: {}", dir.display()));
    }
    let mut found = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(next) = stack.pop() {
        let entries = fs::read_dir(&next).map_err(|e| format!("{}: {e}", next.display()))?;
        for entry in entries {
            let path = entry.map_err(|e| e.to_string())?.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|e| e == "md") {
                found.push(path);
            }
        }
    }
    found.sort();
    Ok(found)
}

fn build_page(build: &Build, source: &Path, report: &mut Report) -> Result<(), String> {
    let text = fs::read_to_string(source).map_err(|e| format!("{}: {e}", source.display()))?;
    let relative = source.strip_prefix(&build.source).unwrap_or(source);
    let name = relative
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let page = markdown::parse(&text, &relative.to_string_lossy(), &name);

    let opts = BuildOptions {
        run_tests: !build.no_run,
        run_analyses: !build.no_run,
        render_svg: !build.no_run,
        ..BuildOptions::default()
    };
    let mut out = build_value(page.document(), &opts);
    // A directive that could not be read never reached the builder, so its
    // problems are added here to be counted and shown with the rest.
    out.diagnostics.extend(page.diagnostics.iter().cloned());

    // `decay.md` becomes the bundle `decay/index.md`; `_index.md` stays.
    let page_path = if name == "_index" {
        build.output.join(relative)
    } else {
        build
            .output
            .join(relative.with_extension(""))
            .join("index.md")
    };
    let esm_name = format!("{name}.esm");
    let esm_path = page_path.with_file_name(&esm_name);
    let rendered = markdown::render(
        &page,
        &out,
        &RenderOptions {
            esm_href: Some(esm_name.clone()),
            esm_name: esm_name.clone(),
            generated_by: Some(format!(
                "Generated by esm-narrative from {}. Do not edit.",
                relative.display()
            )),
        },
    );

    report.pages += 1;
    for d in &out.diagnostics {
        match d.severity {
            Severity::Error => report.errors += 1,
            Severity::Warning => report.warnings += 1,
        }
        eprintln!("{d}");
    }

    // The page is written even when it has errors: it shows them where they
    // happened, which is what a local preview is for. CI fails on the exit
    // code, so nothing broken is deployed.
    write(build, &page_path, &rendered, report)?;
    // A page that declares nothing — a reference page of examples, say — has
    // no model to download.
    if !out.esm.is_null() && !page.elements.is_empty() {
        let esm = serde_json::to_string_pretty(&out.esm).map_err(|e| e.to_string())?;
        write(build, &esm_path, &format!("{esm}\n"), report)?;
    }
    Ok(())
}

/// Write a file, or, under `--check`, note that it would have changed.
fn write(build: &Build, path: &Path, content: &str, report: &mut Report) -> Result<(), String> {
    if fs::read_to_string(path).is_ok_and(|old| old == content) {
        return Ok(());
    }
    report.changed.push(path.to_path_buf());
    if build.check {
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    fs::write(path, content).map_err(|e| format!("{}: {e}", path.display()))
}

/// Rebuild whenever a source file's modification time changes.
///
/// Polling rather than watching the filesystem keeps this to the standard
/// library: a documentation tree is small, and a third of a second is well
/// inside the time it takes to switch to a browser.
fn watch(build: &Build) -> ExitCode {
    let mut seen: BTreeMap<PathBuf, SystemTime> = BTreeMap::new();
    eprintln!(
        "esm-narrative: watching {} — press Ctrl-C to stop",
        build.source.display()
    );
    loop {
        let stamps = match pages(&build.source).and_then(stamps) {
            Ok(stamps) => stamps,
            Err(e) => {
                eprintln!("esm-narrative: {e}");
                return ExitCode::from(2);
            }
        };
        if stamps != seen {
            seen = stamps;
            match run(build) {
                Ok(report) => report.print(),
                Err(e) => eprintln!("esm-narrative: {e}"),
            }
            let _ = std::io::stderr().flush();
        }
        std::thread::sleep(Duration::from_millis(333));
    }
}

fn stamps(paths: Vec<PathBuf>) -> Result<BTreeMap<PathBuf, SystemTime>, String> {
    paths
        .into_iter()
        .map(|path| {
            let at = fs::metadata(&path)
                .and_then(|m| m.modified())
                .map_err(|e| format!("{}: {e}", path.display()))?;
            Ok((path, at))
        })
        .collect()
}
