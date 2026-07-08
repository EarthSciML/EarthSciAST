# Security Policy

## Package Verification and Security Scanning

This document describes the security measures implemented for the EarthSciAST project to ensure package integrity, authenticity, and safety across all supported language ecosystems.

## Overview

The EarthSciAST project implements comprehensive security scanning and package verification for all distributed packages:

- **Julia**: EarthSciAST.jl
- **Python**: earthsci_ast
- **TypeScript/JavaScript**: @earthsciml/ast, earthsci-ast-editor
- **Rust**: earthsci-ast

## Security Tools

### 1. Package Security Scanner (`scripts/package-security-scanner.py`)

A comprehensive security scanner that performs:

- **Vulnerability Scanning**: Checks for known security vulnerabilities in dependencies
- **License Compliance**: Validates package licenses against allowed list
- **File Integrity**: Calculates checksums and detects suspicious files
- **Permission Checking**: Identifies overly permissive file permissions
- **Dependency Analysis**: Scans package dependencies for security issues

#### Supported Vulnerability Databases

- [OSV Database](https://osv.dev/)
- [GitHub Advisory Database](https://github.com/advisories/)
- [CVE Database](https://cve.mitre.org/)
- [RustSec Advisory Database](https://rustsec.org/)
- [npm Security Advisories](https://www.npmjs.com/advisories)

#### Usage

```bash
# Scan all packages
python3 scripts/package-security-scanner.py

# Scan specific package
python3 scripts/package-security-scanner.py --package pkg/earthsci-ast-py --package-type python

# Use custom configuration
python3 scripts/package-security-scanner.py --config .security-config.json

# Fail on warnings
python3 scripts/package-security-scanner.py --fail-on-warnings
```

### 2. Package Signature Verifier (`scripts/package-signature-verifier.py`)

Handles cryptographic verification of package signatures:

- **GPG Signature Verification**: Verifies GPG signatures if present
- **Checksum Validation**: Validates package integrity using cryptographic hashes
- **Registry Verification**: Cross-references packages with official registries
- **Package Manifest Generation**: Creates comprehensive package manifests

#### Usage

```bash
# Verify all packages
python3 scripts/package-signature-verifier.py

# Create signatures for packages
python3 scripts/package-signature-verifier.py --create-signatures --key-id YOUR_GPG_KEY

# Verify specific package
python3 scripts/package-signature-verifier.py --package pkg/earthsci-ast-py --package-type python
```

## Security Configuration

The security system is configured via `.security-config.json`:

```json
{
  "allowed_licenses": [
    "MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause",
    "GPL-3.0", "LGPL-3.0", "ISC", "CC0-1.0"
  ],
  "security_policies": {
    "require_signature": true,
    "max_vulnerability_score": 7.0,
    "block_deprecated_packages": true,
    "require_license": true,
    "scan_dependencies": true
  }
}
```

## CI/CD Integration

### Automated Security Scanning

Security scans are automatically triggered:

- **On Push**: When package files are modified
- **On Pull Request**: For all PRs affecting packages
- **Daily Schedule**: Comprehensive scans at 2 AM UTC
- **Manual Trigger**: Via GitHub Actions workflow_dispatch

### Release Pipeline Integration

The security system integrates with the automated release pipeline:

1. **Pre-release Scan**: All packages are scanned before release
2. **Vulnerability Blocking**: High-severity vulnerabilities block releases
3. **Signature Generation**: Packages are signed during release process
4. **Integrity Verification**: Package checksums are verified

### GitHub Actions Workflows

- **`.github/workflows/security-scan.yml`**: Main security scanning workflow
- Integration with existing workflows:
  - `integrated-release-pipeline.yml`
  - `release-publish.yml`
  - `conformance-testing.yml`

## Security Policies

### Vulnerability Management

1. **Critical Vulnerabilities (CVSS 9.0-10.0)**:
   - Block all releases
   - Create immediate security issue
   - Require hotfix release

2. **High Vulnerabilities (CVSS 7.0-8.9)**:
   - Block releases by default
   - Allow override with justification
   - Require tracking issue

3. **Medium/Low Vulnerabilities (CVSS < 7.0)**:
   - Generate warnings
   - Track for future resolution
   - Include in regular maintenance

### License Compliance

Allowed licenses (automatically checked):
- MIT
- Apache-2.0
- BSD variants (2-Clause, 3-Clause)
- GPL-3.0 / LGPL-3.0
- ISC
- CC0-1.0
- Unlicense

### Package Signing

- **Recommended**: All packages should include GPG signatures
- **Required for Production**: Binary releases must be signed
- **Key Management**: Use dedicated signing keys for releases
- **Verification**: All signatures verified before distribution

## Security Incident Response

### Reporting Security Issues

**DO NOT** create public GitHub issues for security vulnerabilities.

Instead, report security issues via:
- Email: [security contact to be configured]
- GitHub Security Advisories (preferred)

### Response Process

1. **Acknowledgment**: Within 24 hours
2. **Assessment**: Severity and impact analysis within 48 hours
3. **Patching**: Critical issues patched within 72 hours
4. **Disclosure**: Coordinated disclosure after patches are available

## Compliance and Auditing

### Regular Security Reviews

- **Monthly**: Dependency vulnerability scans
- **Quarterly**: Security policy reviews
- **Annually**: Comprehensive security audits

### Audit Trails

All security-related activities are logged:
- Security scan results (retained 30 days)
- Signature verification logs
- Policy compliance reports
- Vulnerability response actions

### Compliance Frameworks

The security system supports compliance with:
- NIST Cybersecurity Framework
- OWASP Top 10
- Supply Chain Security best practices
- Open Source Security practices

## Security Tools and Dependencies

### Language-Specific Tools

#### Python
- **safety**: Vulnerability scanning
- **bandit**: Static security analysis
- **semgrep**: Advanced pattern matching

#### Node.js/TypeScript
- **npm audit**: Built-in vulnerability scanning
- **audit-ci**: CI/CD security checks

#### Rust
- **cargo audit**: Rust vulnerability database
- **cargo deny**: Dependency policy enforcement

#### Julia
- Built-in package manager security features
- Custom vulnerability checking

### Infrastructure Security

- **Binary Verification**: All distributed binaries include checksums
- **Supply Chain Protection**: Dependencies verified and pinned
- **Secret Scanning**: Automated detection of exposed secrets

## Best Practices

### For Contributors

1. **Dependency Updates**: Keep dependencies current
2. **Security Patches**: Apply security updates promptly
3. **Code Review**: Security-focused code reviews
4. **Testing**: Include security tests in test suites

### For Users

1. **Verification**: Always verify package signatures when available
2. **Updates**: Keep packages updated to latest versions
3. **Monitoring**: Monitor for security advisories
4. **Reporting**: Report suspected security issues promptly

## Configuration Examples

### Custom Security Configuration

```json
{
  "vulnerability_databases": [
    "https://osv.dev/",
    "https://github.com/advisories/"
  ],
  "security_policies": {
    "max_vulnerability_score": 6.0,
    "block_deprecated_packages": true,
    "require_license": true
  },
  "excluded_paths": [
    "*/test/*",
    "*/docs/*"
  ]
}
```

### GPG Key Setup for Signing

```bash
# Generate signing key
gpg --full-generate-key

# Export public key
gpg --armor --export your-email@domain.com > public-key.asc

# Sign packages
python3 scripts/package-signature-verifier.py --create-signatures --key-id YOUR_KEY_ID
```

## Contact

For security-related questions or concerns:
- Create a GitHub Discussion for general security questions
- Use GitHub Security Advisories for vulnerability reports
- Check existing security scan results in GitHub Actions

---

*This security policy is regularly reviewed and updated as the project evolves.*