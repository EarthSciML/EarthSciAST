# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a security vulnerability. Report it
privately through GitHub instead: on the repository's **Security** tab, choose
**Report a vulnerability**.

## Dependency monitoring

Dependencies are watched by GitHub rather than by a scanner in this repository:

- **Dependabot alerts** flag any dependency with a published advisory, in every
  language package (Julia, Python, TypeScript, Rust and Go). When a fixed
  version exists, Dependabot opens the pull request that moves to it.
- **Dependabot version updates** (`.github/dependabot.yml`) open grouped weekly
  pull requests that keep dependencies and GitHub Actions current.
- **Dependency review** (`.github/workflows/dependency-review.yml`) runs on every
  pull request and fails it only when the pull request itself adds a runtime
  dependency with a high or critical advisory. An advisory published against a
  dependency already on `main` shows up as an alert, not as a failing check on
  unrelated pull requests.

Before a release, check the Dependabot alerts and resolve any high or critical
ones.
