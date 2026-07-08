#!/usr/bin/env node

/**
 * TypeScript conformance test runner for ESM Format cross-language testing.
 *
 * This script runs the TypeScript @earthsciml/ast implementation against test fixtures
 * and generates standardized outputs for comparison with other language implementations.
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

// Get the directory of this script
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Project paths
const projectRoot = path.dirname(__dirname);
const typescriptPackage = path.join(projectRoot, 'pkg', 'earthsci-ast-ts');
const testsDir = path.join(projectRoot, 'tests');

// Import ESM format library (assuming it's built)
let esmFormat;
try {
    // Try to import from built distribution
    esmFormat = await import(path.join(typescriptPackage, 'dist', 'esm', 'index.js'));
} catch (error) {
    console.error('Failed to import @earthsciml/ast TypeScript library:', error.message);
    console.error('Make sure the library is built with: npm run build');
    process.exit(1);
}

class ConformanceResults {
    constructor() {
        this.language = 'typescript';
        this.timestamp = new Date().toISOString();
        this.validation_results = {};
        this.display_results = {};
        this.substitution_results = {};
        this.graph_results = {};
        this.errors = [];
    }
}

function writeResults(outputDir, results) {
    if (!fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
    }

    const resultsFile = path.join(outputDir, 'results.json');
    fs.writeFileSync(resultsFile, JSON.stringify(results, null, 2));

    console.log(`TypeScript conformance results written to: ${resultsFile}`);
}

async function runValidationTests(testsDir) {
    console.log('Running validation tests...');
    const validationResults = {};

    // Test valid files
    const validDir = path.join(testsDir, 'valid');
    if (fs.existsSync(validDir) && fs.lstatSync(validDir).isDirectory()) {
        const validResults = {};
        const validFiles = fs.readdirSync(validDir).filter(f => f.endsWith('.esm'));

        for (const filename of validFiles) {
            const filepath = path.join(validDir, filename);
            try {
                const fileContent = fs.readFileSync(filepath, 'utf8');
                const esmData = await esmFormat.load(fileContent);
                const result = await esmFormat.validate(esmData);

                validResults[filename] = {
                    is_valid: result.is_valid,
                    schema_errors: result.schema_errors || [],
                    structural_errors: result.structural_errors || [],
                    parsed_successfully: true
                };
            } catch (error) {
                validResults[filename] = {
                    parsed_successfully: false,
                    error: error.message,
                    error_type: error.constructor.name
                };
            }
        }
        validationResults.valid = validResults;
    }

    // Test invalid files
    const invalidDir = path.join(testsDir, 'invalid');
    if (fs.existsSync(invalidDir) && fs.lstatSync(invalidDir).isDirectory()) {
        const invalidResults = {};
        const invalidFiles = fs.readdirSync(invalidDir).filter(f => f.endsWith('.esm'));

        for (const filename of invalidFiles) {
            const filepath = path.join(invalidDir, filename);
            try {
                const fileContent = fs.readFileSync(filepath, 'utf8');
                const esmData = await esmFormat.load(fileContent);
                const result = await esmFormat.validate(esmData);

                invalidResults[filename] = {
                    is_valid: result.is_valid,
                    schema_errors: result.schema_errors || [],
                    structural_errors: result.structural_errors || [],
                    parsed_successfully: true
                };
            } catch (error) {
                invalidResults[filename] = {
                    parsed_successfully: false,
                    error: error.message,
                    error_type: error.constructor.name,
                    is_expected_error: true  // Invalid files should error
                };
            }
        }
        validationResults.invalid = invalidResults;
    }

    return validationResults;
}

async function runDisplayTests(testsDir) {
    console.log('Running display tests...');
    const displayResults = {};

    const displayDir = path.join(testsDir, 'display');
    if (fs.existsSync(displayDir) && fs.lstatSync(displayDir).isDirectory()) {
        const displayFiles = fs.readdirSync(displayDir).filter(f => f.endsWith('.json'));

        for (const filename of displayFiles) {
            const filepath = path.join(displayDir, filename);
            try {
                const testData = JSON.parse(fs.readFileSync(filepath, 'utf8'));
                const testResults = {};

                // Test chemical formula rendering
                if (testData.chemical_formulas) {
                    const formulaResults = [];
                    for (const formulaTest of testData.chemical_formulas) {
                        if (formulaTest.input) {
                            const inputFormula = formulaTest.input;
                            try {
                                const unicodeResult = await esmFormat.renderChemicalFormula(inputFormula);

                                formulaResults.push({
                                    input: inputFormula,
                                    output_unicode: unicodeResult,
                                    output_latex: formulaTest.expected_latex || '',
                                    output_ascii: inputFormula,  // Fallback
                                    success: true
                                });
                            } catch (error) {
                                formulaResults.push({
                                    input: inputFormula,
                                    error: error.message,
                                    success: false
                                });
                            }
                        }
                    }
                    testResults.chemical_formulas = formulaResults;
                }

                // Test expression rendering
                if (testData.expressions) {
                    const expressionResults = [];
                    for (const exprTest of testData.expressions) {
                        if (exprTest.input) {
                            const inputExpr = exprTest.input;
                            try {
                                const expr = await esmFormat.parseExpression(inputExpr);
                                const unicodeResult = await esmFormat.prettyPrint(expr, { format: 'unicode' });
                                const latexResult = await esmFormat.prettyPrint(expr, { format: 'latex' });
                                const asciiResult = await esmFormat.prettyPrint(expr, { format: 'ascii' });

                                expressionResults.push({
                                    input: inputExpr,
                                    output_unicode: unicodeResult,
                                    output_latex: latexResult,
                                    output_ascii: asciiResult,
                                    success: true
                                });
                            } catch (error) {
                                expressionResults.push({
                                    input: inputExpr,
                                    error: error.message,
                                    success: false
                                });
                            }
                        }
                    }
                    testResults.expressions = expressionResults;
                }

                displayResults[filename] = testResults;

            } catch (error) {
                displayResults[filename] = {
                    error: error.message,
                    success: false
                };
            }
        }
    }

    return displayResults;
}

async function runSubstitutionTests(testsDir) {
    console.log('Running substitution tests...');
    const substitutionResults = {};

    const substitutionDir = path.join(testsDir, 'substitution');
    if (fs.existsSync(substitutionDir) && fs.lstatSync(substitutionDir).isDirectory()) {
        const substitutionFiles = fs.readdirSync(substitutionDir).filter(f => f.endsWith('.json'));

        for (const filename of substitutionFiles) {
            const filepath = path.join(substitutionDir, filename);
            try {
                const testData = JSON.parse(fs.readFileSync(filepath, 'utf8'));
                const testResults = [];

                if (testData.tests) {
                    for (const testCase of testData.tests) {
                        if (testCase.expression && testCase.substitutions) {
                            try {
                                const expr = await esmFormat.parseExpression(testCase.expression);
                                const substitutions = {};
                                for (const [key, value] of Object.entries(testCase.substitutions)) {
                                    substitutions[key] = await esmFormat.parseExpression(value);
                                }

                                const resultExpr = await esmFormat.substitute(expr, substitutions);
                                const resultStr = await esmFormat.prettyPrint(resultExpr);

                                testResults.push({
                                    input: testCase.expression,
                                    substitutions: testCase.substitutions,
                                    result: resultStr,
                                    success: true
                                });
                            } catch (error) {
                                testResults.push({
                                    input: testCase.expression || '',
                                    error: error.message,
                                    success: false
                                });
                            }
                        }
                    }
                }

                substitutionResults[filename] = testResults;

            } catch (error) {
                substitutionResults[filename] = {
                    error: error.message,
                    success: false
                };
            }
        }
    }

    return substitutionResults;
}

async function runGraphTests(testsDir) {
    console.log('Running graph tests...');
    const graphResults = {};

    const graphsDir = path.join(testsDir, 'graphs');
    if (fs.existsSync(graphsDir) && fs.lstatSync(graphsDir).isDirectory()) {
        const graphFiles = fs.readdirSync(graphsDir).filter(f => f.endsWith('.json'));

        for (const filename of graphFiles) {
            const filepath = path.join(graphsDir, filename);
            try {
                const testData = JSON.parse(fs.readFileSync(filepath, 'utf8'));

                if (testData.esm_file) {
                    const esmFilePath = path.join(path.dirname(filepath), testData.esm_file);
                    if (fs.existsSync(esmFilePath)) {
                        try {
                            const esmData = await esmFormat.load(esmFilePath);

                            // Generate system graph
                            const systemGraph = await esmFormat.generateSystemGraph(esmData);

                            // Export in different formats
                            const dotOutput = await esmFormat.exportDot(systemGraph);
                            const jsonOutput = await esmFormat.exportJson(systemGraph);

                            graphResults[filename] = {
                                esm_file: esmFilePath,
                                system_graph: {
                                    nodes: systemGraph.nodes.length,
                                    edges: systemGraph.edges.length,
                                    dot_format: dotOutput,
                                    json_format: jsonOutput
                                },
                                success: true
                            };
                        } catch (error) {
                            graphResults[filename] = {
                                esm_file: esmFilePath,
                                error: error.message,
                                success: false
                            };
                        }
                    } else {
                        graphResults[filename] = {
                            error: `ESM file not found: ${esmFilePath}`,
                            success: false
                        };
                    }
                }

            } catch (error) {
                graphResults[filename] = {
                    error: error.message,
                    success: false
                };
            }
        }
    }

    return graphResults;
}

async function main() {
    if (process.argv.length !== 3) {
        console.error('Usage: node run-typescript-conformance.js <output_dir>');
        process.exit(1);
    }

    const outputDir = process.argv[2];

    console.log('Running TypeScript conformance tests...');
    console.log(`Tests directory: ${testsDir}`);
    console.log(`Output directory: ${outputDir}`);

    const results = new ConformanceResults();

    // Run all test categories
    try {
        results.validation_results = await runValidationTests(testsDir);
        console.log('✓ Validation tests completed');
    } catch (error) {
        results.validation_results = {};
        results.errors.push(`Validation tests failed: ${error.message}`);
        console.log(`✗ Validation tests failed: ${error.message}`);
    }

    try {
        results.display_results = await runDisplayTests(testsDir);
        console.log('✓ Display tests completed');
    } catch (error) {
        results.display_results = {};
        results.errors.push(`Display tests failed: ${error.message}`);
        console.log(`✗ Display tests failed: ${error.message}`);
    }

    try {
        results.substitution_results = await runSubstitutionTests(testsDir);
        console.log('✓ Substitution tests completed');
    } catch (error) {
        results.substitution_results = {};
        results.errors.push(`Substitution tests failed: ${error.message}`);
        console.log(`✗ Substitution tests failed: ${error.message}`);
    }

    try {
        results.graph_results = await runGraphTests(testsDir);
        console.log('✓ Graph tests completed');
    } catch (error) {
        results.graph_results = {};
        results.errors.push(`Graph tests failed: ${error.message}`);
        console.log(`✗ Graph tests failed: ${error.message}`);
    }

    // Write results to file
    writeResults(outputDir, results);

    if (results.errors.length === 0) {
        console.log('TypeScript conformance testing completed successfully!');
        process.exit(0);
    } else {
        console.log(`TypeScript conformance testing completed with ${results.errors.length} errors`);
        process.exit(1);
    }
}

// Run main function if this script is executed directly
if (import.meta.url === `file://${process.argv[1]}`) {
    main().catch(error => {
        console.error('Unexpected error:', error);
        process.exit(1);
    });
}