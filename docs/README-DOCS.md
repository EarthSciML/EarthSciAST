# ESM Format Documentation System

This directory contains the complete documentation system for the ESM Format project, including automated generation tools, validation scripts, and hosting configuration.

## 📁 Documentation Structure

```
docs/
├── README.md                    # Main documentation index
├── _config.yml                  # Jekyll configuration for GitHub Pages
├── api/                         # Auto-generated API reference
│   ├── index.md                 # API index
│   ├── julia.md                 # Julia API reference
│   ├── python.md                # Python API reference
│   ├── typescript.md            # TypeScript API reference
│   └── rust.md                  # Rust API reference
├── examples/                    # Code examples and tutorials
│   ├── index.md                 # Examples index
│   ├── minimal.md               # Minimal example
│   └── atmospheric-chemistry.md # Atmospheric chemistry example
├── getting-started/             # Getting started guides
│   ├── installation.md          # Installation instructions
│   ├── quick-start.md           # Quick start guide
│   ├── julia.md                 # Julia-specific guide
│   ├── python.md                # Python-specific guide
│   ├── typescript.md            # TypeScript-specific guide
│   └── rust.md                  # Rust-specific guide
├── troubleshooting/             # Troubleshooting guides
│   ├── index.md                 # Troubleshooting index
│   ├── validation-errors.md     # Schema validation issues
│   ├── expression-issues.md     # Expression parsing issues
│   ├── performance.md           # Performance problems
│   └── language-specific.md     # Language-specific issues
├── tutorial/                    # In-depth tutorials (placeholders)
├── guides/                      # Best practices guides (placeholders)
└── generated/                   # Auto-generated content
    ├── api-data.json            # Raw API extraction data
    └── cross-language-comparison.md # Cross-language comparison
```

## 🛠️ Documentation Tools

The documentation system includes several automated tools:

### `scripts/generate_docs.py`
**Comprehensive documentation generator**
- Extracts API documentation from all language implementations
- Generates cross-language comparisons
- Creates example documentation from test cases
- Sets up GitHub Actions workflow for automated updates

```bash
# Generate all documentation
python3 scripts/generate_docs.py

# Generate with infrastructure setup
python3 scripts/generate_docs.py --setup-infrastructure
```

### `scripts/docs_maintenance.py`
**Improved documentation maintenance**
- Filtered extraction (excludes dependencies)
- Creates missing placeholder files
- Better handling of cross-references
- Integrated validation

```bash
# Build and maintain documentation
python3 scripts/docs_maintenance.py

# Skip regeneration, just maintain
python3 scripts/docs_maintenance.py --skip-generation
```

### `scripts/validate_docs.py`
**Documentation validation and quality checking**
- Checks for broken internal links
- Validates file references
- Checks API coverage completeness
- Validates cross-language consistency

```bash
# Validate documentation
python3 scripts/validate_docs.py

# Save validation results to JSON
python3 scripts/validate_docs.py --json-output validation-results.json
```

## 🚀 Automated Documentation Pipeline

The documentation system includes a GitHub Actions workflow (`.github/workflows/docs.yml`) that:

1. **Triggers on changes** to:
   - Source code in `pkg/`
   - Documentation in `docs/`
   - Documentation scripts

2. **Generates documentation** automatically:
   - Extracts API references from all languages
   - Updates cross-language comparisons
   - Creates example documentation

3. **Validates and commits** changes:
   - Runs validation checks
   - Commits generated documentation
   - Pushes updates to the repository

## 📚 Documentation Hosting

The documentation is configured for hosting via:

### GitHub Pages
- Configured in `_config.yml`
- Uses Jekyll with Minima theme
- Automatic deployment from main branch

### Local Development
```bash
# Install Jekyll (one-time setup)
gem install bundler jekyll

# Create Gemfile if needed
echo 'source "https://rubygems.org"' > Gemfile
echo 'gem "jekyll"' >> Gemfile
echo 'gem "minima"' >> Gemfile

# Serve locally
cd docs/
bundle exec jekyll serve

# View at http://localhost:4000
```

## 🔧 Maintenance Workflow

### Regular Maintenance
1. **Run the maintenance script** after code changes:
   ```bash
   python3 scripts/docs_maintenance.py
   ```

2. **Validate the documentation**:
   ```bash
   python3 scripts/validate_docs.py
   ```

3. **Review and commit changes**:
   ```bash
   git add docs/
   git commit -m "Update documentation"
   git push
   ```

### Adding New Documentation
1. **Create content** in the appropriate directory
2. **Update navigation** in relevant index files
3. **Test links** with the validation script
4. **Commit changes** for automatic processing

### Troubleshooting Documentation Issues

**Broken links:**
- Run `python3 scripts/validate_docs.py` to identify issues
- Check file paths and ensure referenced files exist
- Update links in source files

**Missing API documentation:**
- Ensure functions/types have proper docstrings
- Check that files are in the correct package directories
- Verify language-specific parsing in maintenance script

**Build failures:**
- Check GitHub Actions workflow logs
- Ensure all dependencies are properly specified
- Validate JSON syntax in configuration files

## 🎯 Best Practices

### Writing Documentation
- **Use clear headings** and consistent formatting
- **Include code examples** with proper syntax highlighting
- **Cross-reference** between languages where applicable
- **Keep examples up-to-date** with current API

### Code Documentation
- **Write comprehensive docstrings** for all public functions
- **Include parameter descriptions** and return types
- **Provide usage examples** in docstrings
- **Use consistent documentation style** within each language

### Maintenance
- **Run validation regularly** to catch issues early
- **Update documentation** when changing APIs
- **Review generated content** for accuracy
- **Test documentation locally** before committing

## 🤝 Contributing to Documentation

1. **Follow the established structure** when adding content
2. **Use the validation tools** to ensure quality
3. **Test examples** to ensure they work
4. **Update cross-references** when adding new content
5. **Submit pull requests** with documentation changes

## 🆘 Support

For documentation system issues:
- **Check validation output** for specific errors
- **Review GitHub Actions logs** for build issues
- **File issues** with reproduction steps
- **Include validation results** when reporting problems

---

*This documentation system is designed to scale with the ESM Format project while maintaining high quality and consistency across all language implementations.*