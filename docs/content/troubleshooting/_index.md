# Troubleshooting Guide

Common issues and solutions when working with ESM Format libraries.

## Quick Navigation

- [Validation Errors](validation-errors.md) - Fix schema and structural validation issues
- [Expression Issues](expression-issues.md) - Debug mathematical expressions and parsing
- [Performance Problems](performance.md) - Diagnose slow loading or validation
- [Language-Specific Issues](language-specific.md) - Platform and runtime problems

## General Troubleshooting Steps

1. **Check the basics**
   - Is your ESM file valid JSON?
   - Does it pass schema validation?
   - Are all required fields present?

2. **Enable debug output**
   - Most libraries have verbose/debug flags
   - Check error messages carefully
   - Look for line numbers in parse errors

3. **Test with minimal examples**
   - Start with simple, working examples
   - Gradually add complexity
   - Use the examples in this documentation

4. **Check version compatibility**
   - Ensure library versions match
   - Check for breaking changes in updates
   - Use compatible ESM format versions

## Getting Help

If you can't find a solution in this guide:

1. Search existing issues in the [GitHub repository](https://github.com/EarthSciML/EarthSciAST)
2. Create a minimal reproducible example
3. Include error messages and version information
4. File a new issue with your example