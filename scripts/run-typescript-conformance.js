#!/usr/bin/env node

/**
 * TypeScript conformance producer for ESM Format cross-language testing.
 *
 * Reads the shared CORPUS MANIFEST (`scripts/conformance_corpus.py`) and emits a
 * record for every entry in it. The producer does NOT enumerate the corpus
 * itself: each producer used to walk `tests/valid` / `tests/invalid`
 * NON-recursively and all four skipped the same 69 fixtures — the entire
 * `aggregate` and `template_imports` corpora — plus `lib/**`, which nothing
 * swept at all (audit 2026-07-14, F5; CONFORMANCE_SPEC §2.2.1).
 *
 * Every validation entry runs the full **load → resolve → validate** pipeline.
 * This producer used to call `load(fileContent)` on the file's TEXT, with no
 * base path at all, so no `{ref}` could ever resolve; `validate()` does no file
 * I/O in any binding, so `tests/valid/lib_*_subsystem_inclusion.esm` was
 * structurally unsatisfiable here.
 *
 * See `scripts/run-python-conformance.py` for the emitted wire shape; every
 * producer emits the same one.
 */

import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

const projectRoot = path.dirname(__dirname)
const typescriptPackage = path.join(projectRoot, 'pkg', 'earthsci-ast-ts')

let esm
try {
    esm = await import(path.join(typescriptPackage, 'dist', 'esm', 'index.js'))
} catch (error) {
    console.error('Failed to import @earthsciml/ast TypeScript library:', error.message)
    console.error('Make sure the library is built with: npm run build')
    process.exit(1)
}

/** Normalise a binding error object to the shared wire shape. */
function errorToRecord(err) {
    return {
        path: err?.path ?? '',
        message: err?.message ?? String(err),
        code: err?.code ?? '',
        keyword: err?.keyword ?? err?.code ?? '',
        details: (err?.details && typeof err.details === 'object') ? err.details : {},
    }
}

/**
 * load → resolve → validate every manifest entry.
 *
 * When the load/resolve phase REJECTS a document, `validate()` is still called
 * on the raw document, so a binding that throws early still gets to enumerate
 * its structured `(code, path)` findings for the pin check instead of reporting
 * an opaque exception string.
 */
async function runValidation(manifest) {
    console.log('Running validation sweep...')
    const results = {}

    for (const entry of manifest.validation_files) {
        const filepath = path.join(projectRoot, entry.path)
        const basePath = path.dirname(filepath)
        const record = { schema_errors: [], structural_errors: [] }

        // SCHEMA judges the document AS WRITTEN, so it runs on the raw JSON and
        // runs even when the load phase rejects the file — otherwise a
        // schema-invalid fixture could never have its pinned (keyword, path)
        // findings checked, because the binding would have thrown before
        // enumerating them.
        let text = ''
        try {
            text = fs.readFileSync(filepath, 'utf8')
            record.schema_errors = esm.validateSchema(JSON.parse(text)).map(errorToRecord)
        } catch (error) {
            record.error = error.message
            record.error_type = error?.constructor?.name ?? 'Error'
        }

        // LOAD + RESOLVE: the only phase that does file I/O.
        let esmData = null
        try {
            esmData = esm.load(text, { basePath })
            // `load` is synchronous and cannot do the async file I/O a §4.7
            // subsystem `ref` needs; this is the distinct RESOLVE phase.
            await esm.resolveSubsystemRefs(esmData, basePath)
            record.resolve_ok = true
        } catch (error) {
            record.resolve_ok = false
            if (record.error === undefined) {
                record.error = error.message
                record.error_type = error?.constructor?.name ?? 'Error'
            }
            // A resolve-phase rejection that carries a structured (code, path) —
            // e.g. a RefLoadError for an unresolved or ambiguous §4.7 subsystem
            // `ref` — is a pinned structural finding, not merely an opaque
            // failure. Surface it so the (code, path) pin can match (F-9);
            // otherwise the rejection is recorded only as an exception string.
            if (error?.code && error?.path !== undefined) {
                record.structural_errors.push(errorToRecord(error))
            }
            esmData = null
        }

        // STRUCTURAL judges the RESOLVED form (§4.7 refs spliced in).
        if (esmData !== null) {
            try {
                const result = esm.validate(esmData)
                record.structural_errors = (result.structural_errors || []).map(errorToRecord)
                record.phase = 'validate'
            } catch (error) {
                record.phase = 'validate'
                if (record.error === undefined) {
                    record.error = error.message
                    record.error_type = error?.constructor?.name ?? 'Error'
                }
            }
        } else {
            record.phase = 'load'
        }

        // The verdict is "did this binding accept the document", regardless of
        // WHICH phase answered. A rejection at resolve is still a rejection.
        record.is_valid = record.resolve_ok === true
            && record.schema_errors.length === 0
            && record.structural_errors.length === 0
        record.outcome = record.is_valid ? 'valid' : 'invalid'
        results[entry.id] = record
    }

    return results
}

/**
 * Render every manifest display case in all three formats.
 *
 * This producer used to look for top-level `chemical_formulas` / `expressions`
 * keys that NO fixture in `tests/display/` has, so it emitted nothing at all and
 * the comparator scored the empty intersection as 100% consistent (audit C2).
 * The manifest now hands over already-expanded, id'd cases.
 */
function runDisplay(manifest) {
    console.log('Running display sweep...')
    const results = {}

    for (const testCase of manifest.display_cases) {
        const record = {}
        const errors = {}
        const renderers = {
            unicode: esm.toUnicode,
            latex: esm.toLatex,
            ascii: esm.toAscii,
        }
        for (const [fmt, render] of Object.entries(renderers)) {
            try {
                record[fmt] = render(testCase.input)
            } catch (error) {
                record[fmt] = null
                errors[fmt] = error.message
            }
        }
        if (Object.keys(errors).length > 0) record.errors = errors
        results[testCase.id] = record
    }

    return results
}

/** Apply `substitute` to every manifest substitution case. */
function runSubstitution(manifest) {
    console.log('Running substitution sweep...')
    const results = {}

    for (const testCase of manifest.substitution_cases) {
        try {
            results[testCase.id] = {
                result: esm.substitute(testCase.input, testCase.bindings),
            }
        } catch (error) {
            results[testCase.id] = { result: null, error: error.message }
        }
    }

    return results
}

/**
 * The manifest path is passed by the harness; there is no fallback sweep. A
 * producer that invents its own corpus when the manifest is missing is a
 * producer that can silently under-report coverage. Fail instead.
 */
function loadManifest(outputDir) {
    let manifestPath
    if (process.argv.length >= 4) {
        manifestPath = process.argv[3]
    } else if (process.env.ESM_CONFORMANCE_MANIFEST) {
        manifestPath = process.env.ESM_CONFORMANCE_MANIFEST
    } else {
        manifestPath = path.join(path.dirname(outputDir), 'corpus_manifest.json')
    }

    if (!fs.existsSync(manifestPath)) {
        console.error(`Corpus manifest not found: ${manifestPath}`)
        console.error('Generate it with: python3 scripts/conformance_corpus.py --output <path>')
        process.exit(2)
    }
    return JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
}

async function main() {
    if (process.argv.length < 3) {
        console.error('Usage: node run-typescript-conformance.js <output_dir> [<corpus_manifest.json>]')
        process.exit(1)
    }

    const outputDir = process.argv[2]
    const manifest = loadManifest(outputDir)

    console.log('Running TypeScript conformance producer...')
    console.log(`Output directory: ${outputDir}`)

    const errors = []
    let validationResults = {}
    let displayResults = {}
    let substitutionResults = {}

    try {
        validationResults = await runValidation(manifest)
        console.log(`✓ Validation sweep completed (${Object.keys(validationResults).length} files)`)
    } catch (error) {
        errors.push(`Validation sweep crashed: ${error.message}`)
        console.log(`✗ Validation sweep crashed: ${error.message}`)
    }

    try {
        displayResults = runDisplay(manifest)
        console.log(`✓ Display sweep completed (${Object.keys(displayResults).length} cases)`)
    } catch (error) {
        errors.push(`Display sweep crashed: ${error.message}`)
        console.log(`✗ Display sweep crashed: ${error.message}`)
    }

    try {
        substitutionResults = runSubstitution(manifest)
        console.log(`✓ Substitution sweep completed (${Object.keys(substitutionResults).length} cases)`)
    } catch (error) {
        errors.push(`Substitution sweep crashed: ${error.message}`)
        console.log(`✗ Substitution sweep crashed: ${error.message}`)
    }

    if (!fs.existsSync(outputDir)) fs.mkdirSync(outputDir, { recursive: true })
    const resultsFile = path.join(outputDir, 'results.json')
    fs.writeFileSync(resultsFile, JSON.stringify({
        language: 'typescript',
        timestamp: new Date().toISOString(),
        validation_results: validationResults,
        display_results: displayResults,
        substitution_results: substitutionResults,
        errors,
    }, null, 2))
    console.log(`TypeScript conformance results written to: ${resultsFile}`)

    // A producer CRASH is fatal; a fixture-level divergence is not the
    // producer's verdict to make — the comparator owns that judgement, and it
    // needs every binding's results.json to make it.
    process.exit(errors.length === 0 ? 0 : 1)
}

if (import.meta.url === `file://${process.argv[1]}`) {
    main().catch(error => {
        console.error('Unexpected error:', error)
        process.exit(1)
    })
}
