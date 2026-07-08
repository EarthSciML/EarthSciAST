#!/usr/bin/env python3
"""
Package Signature Verification System

This tool handles cryptographic verification of package signatures to ensure
package authenticity and integrity for the EarthSciAST project.

Supports GPG signatures, checksums, and package registry verification.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import urllib.request
from typing import Dict, Optional, Any
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)


class SignatureVerificationError(Exception):
    """Custom exception for signature verification errors."""

    pass


class PackageSignatureVerifier:
    """Handles package signature verification and integrity checking."""

    def __init__(self, config_path: Optional[str] = None):
        self.config = self._load_config(config_path)
        self.results = {}

    def _load_config(self, config_path: Optional[str]) -> Dict[str, Any]:
        """Load signature verification configuration."""
        default_config = {
            "trusted_keys": {"julia": [], "npm": [], "pypi": [], "rust": []},
            "verification_methods": {
                "gpg_signature": True,
                "checksum_verification": True,
                "registry_verification": True,
                "package_integrity": True,
            },
            "hash_algorithms": ["sha256", "sha512"],
            "signature_files": [".sig", ".asc", ".sign"],
            "checksum_files": ["checksums.txt", "SHA256SUMS", "CHECKSUMS"],
        }

        if config_path and os.path.exists(config_path):
            try:
                with open(config_path, "r") as f:
                    user_config = json.load(f)
                default_config.update(user_config)
            except Exception as e:
                logger.warning(f"Failed to load signature config from {config_path}: {e}")

        return default_config

    def verify_package_signature(self, package_path: str, package_type: str) -> Dict[str, Any]:
        """Verify package signature and integrity."""
        logger.info(f"Verifying signature for {package_type} package: {package_path}")

        result = {
            "package_path": package_path,
            "package_type": package_type,
            "verification_status": "unknown",
            "checks": {},
            "signatures_found": [],
            "checksums": {},
            "warnings": [],
            "errors": [],
        }

        try:
            # Generate package checksums
            result = self._generate_checksums(package_path, result)

            # Look for signature files
            result = self._find_signatures(package_path, result)

            # Verify GPG signatures if found
            if result["signatures_found"]:
                result = self._verify_gpg_signatures(package_path, result)

            # Verify package registry information
            result = self._verify_registry_info(package_path, package_type, result)

            # Generate package manifest
            result = self._generate_package_manifest(package_path, result)

            # Determine verification status
            result["verification_status"] = self._determine_verification_status(result)

        except Exception as e:
            result["verification_status"] = "error"
            result["errors"].append(str(e))
            logger.error(f"Error verifying {package_path}: {e}")

        return result

    def _generate_checksums(self, package_path: str, result: Dict[str, Any]) -> Dict[str, Any]:
        """Generate checksums for all files in the package."""
        checksums = {}

        try:
            for algorithm in self.config["hash_algorithms"]:
                checksums[algorithm] = {}

                for root, dirs, files in os.walk(package_path):
                    for file in files:
                        file_path = os.path.join(root, file)
                        relative_path = os.path.relpath(file_path, package_path)

                        try:
                            with open(file_path, "rb") as f:
                                if algorithm == "sha256":
                                    hasher = hashlib.sha256()
                                elif algorithm == "sha512":
                                    hasher = hashlib.sha512()
                                elif algorithm == "md5":
                                    hasher = hashlib.md5()
                                else:
                                    continue

                                for chunk in iter(lambda: f.read(4096), b""):
                                    hasher.update(chunk)

                                checksums[algorithm][relative_path] = hasher.hexdigest()

                        except (OSError, IOError) as e:
                            result["warnings"].append(f"Could not read file {relative_path}: {e}")

            result["checksums"] = checksums
            result["checks"]["checksum_generation"] = "passed"

        except Exception as e:
            result["errors"].append(f"Failed to generate checksums: {e}")
            result["checks"]["checksum_generation"] = "failed"

        return result

    def _find_signatures(self, package_path: str, result: Dict[str, Any]) -> Dict[str, Any]:
        """Find signature files in the package."""
        signatures_found = []

        try:
            for root, dirs, files in os.walk(package_path):
                for file in files:
                    file_path = os.path.join(root, file)
                    relative_path = os.path.relpath(file_path, package_path)

                    # Check for signature file extensions
                    for sig_ext in self.config["signature_files"]:
                        if file.endswith(sig_ext):
                            signatures_found.append(
                                {
                                    "path": relative_path,
                                    "type": "gpg_signature",
                                    "target_file": file.replace(sig_ext, "")
                                    if sig_ext in file
                                    else None,
                                }
                            )

                    # Check for checksum files
                    if file in self.config["checksum_files"]:
                        signatures_found.append(
                            {"path": relative_path, "type": "checksum_file", "target_file": None}
                        )

            result["signatures_found"] = signatures_found
            if signatures_found:
                result["checks"]["signature_discovery"] = "passed"
            else:
                result["warnings"].append("No signature files found")
                result["checks"]["signature_discovery"] = "warning"

        except Exception as e:
            result["errors"].append(f"Failed to search for signatures: {e}")
            result["checks"]["signature_discovery"] = "failed"

        return result

    def _verify_gpg_signatures(self, package_path: str, result: Dict[str, Any]) -> Dict[str, Any]:
        """Verify GPG signatures if GPG is available."""
        gpg_signatures = [s for s in result["signatures_found"] if s["type"] == "gpg_signature"]

        if not gpg_signatures:
            result["checks"]["gpg_verification"] = "skipped"
            return result

        try:
            # Check if GPG is available
            subprocess.run(["gpg", "--version"], capture_output=True, check=True)

            verified_signatures = 0
            failed_signatures = 0

            for signature in gpg_signatures:
                sig_path = os.path.join(package_path, signature["path"])
                target_file = signature.get("target_file")

                if target_file:
                    target_path = os.path.join(package_path, target_file)
                    if not os.path.exists(target_path):
                        result["warnings"].append(
                            f"Target file for signature not found: {target_file}"
                        )
                        continue

                    try:
                        # Verify signature
                        cmd = ["gpg", "--verify", sig_path, target_path]
                        proc = subprocess.run(cmd, capture_output=True, text=True)

                        if proc.returncode == 0:
                            verified_signatures += 1
                            logger.info(f"GPG signature verified: {signature['path']}")
                        else:
                            failed_signatures += 1
                            result["warnings"].append(
                                f"GPG signature verification failed: {signature['path']}"
                            )

                    except subprocess.SubprocessError as e:
                        result["warnings"].append(
                            f"GPG verification error for {signature['path']}: {e}"
                        )
                        failed_signatures += 1

            if verified_signatures > 0 and failed_signatures == 0:
                result["checks"]["gpg_verification"] = "passed"
            elif verified_signatures > 0:
                result["checks"]["gpg_verification"] = "warning"
            else:
                result["checks"]["gpg_verification"] = "failed"

        except subprocess.CalledProcessError:
            result["warnings"].append("GPG not available for signature verification")
            result["checks"]["gpg_verification"] = "skipped"
        except Exception as e:
            result["errors"].append(f"GPG verification failed: {e}")
            result["checks"]["gpg_verification"] = "failed"

        return result

    def _verify_registry_info(
        self, package_path: str, package_type: str, result: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Verify package information against official registries."""
        try:
            package_info = self._extract_package_info(package_path, package_type)

            if not package_info:
                result["warnings"].append(
                    "Could not extract package information for registry verification"
                )
                result["checks"]["registry_verification"] = "warning"
                return result

            package_name = package_info.get("name")
            package_version = package_info.get("version")

            if not package_name or not package_version:
                result["warnings"].append(
                    "Package name or version not found for registry verification"
                )
                result["checks"]["registry_verification"] = "warning"
                return result

            # Verify against registry (simplified check)
            registry_url = self.config["package_repos"].get(package_type.replace("-", "_"))
            if registry_url:
                registry_verified = self._check_registry(
                    package_name, package_version, package_type, registry_url
                )
                if registry_verified:
                    result["checks"]["registry_verification"] = "passed"
                else:
                    result["warnings"].append(
                        f"Package {package_name}@{package_version} not found in {package_type} registry"
                    )
                    result["checks"]["registry_verification"] = "warning"
            else:
                result["warnings"].append(f"No registry URL configured for {package_type}")
                result["checks"]["registry_verification"] = "skipped"

        except Exception as e:
            result["errors"].append(f"Registry verification failed: {e}")
            result["checks"]["registry_verification"] = "failed"

        return result

    def _extract_package_info(
        self, package_path: str, package_type: str
    ) -> Optional[Dict[str, str]]:
        """Extract package name and version from package files."""
        try:
            if package_type == "julia":
                project_toml = os.path.join(package_path, "Project.toml")
                if os.path.exists(project_toml):
                    import toml

                    with open(project_toml, "r") as f:
                        data = toml.load(f)
                    return {"name": data.get("name"), "version": data.get("version")}

            elif package_type == "python":
                pyproject_toml = os.path.join(package_path, "pyproject.toml")
                if os.path.exists(pyproject_toml):
                    import toml

                    with open(pyproject_toml, "r") as f:
                        data = toml.load(f)
                    project = data.get("project", {})
                    return {"name": project.get("name"), "version": project.get("version")}

            elif package_type in ["npm", "typescript"]:
                package_json = os.path.join(package_path, "package.json")
                if os.path.exists(package_json):
                    with open(package_json, "r") as f:
                        data = json.load(f)
                    return {"name": data.get("name"), "version": data.get("version")}

            elif package_type == "rust":
                cargo_toml = os.path.join(package_path, "Cargo.toml")
                if os.path.exists(cargo_toml):
                    import toml

                    with open(cargo_toml, "r") as f:
                        data = toml.load(f)
                    package = data.get("package", {})
                    return {"name": package.get("name"), "version": package.get("version")}

        except Exception as e:
            logger.warning(f"Failed to extract package info: {e}")

        return None

    def _check_registry(
        self, package_name: str, package_version: str, package_type: str, registry_url: str
    ) -> bool:
        """Check if package exists in registry (simplified implementation)."""
        try:
            if package_type == "npm":
                url = f"https://registry.npmjs.org/{package_name}/{package_version}"
            elif package_type == "python":
                url = f"https://pypi.org/pypi/{package_name}/{package_version}/json"
            elif package_type == "rust":
                url = f"https://crates.io/api/v1/crates/{package_name}/{package_version}"
            else:
                return False  # Registry check not implemented for this type

            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=10) as response:
                return response.getcode() == 200

        except Exception as e:
            logger.warning(f"Registry check failed for {package_name}@{package_version}: {e}")
            return False

    def _generate_package_manifest(
        self, package_path: str, result: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Generate a comprehensive package manifest."""
        manifest = {
            "package_path": package_path,
            "scan_timestamp": result.get("scan_timestamp", "unknown"),
            "files": {},
            "total_files": 0,
            "total_size": 0,
        }

        try:
            for root, dirs, files in os.walk(package_path):
                for file in files:
                    file_path = os.path.join(root, file)
                    relative_path = os.path.relpath(file_path, package_path)

                    try:
                        stat_info = os.stat(file_path)
                        manifest["files"][relative_path] = {
                            "size": stat_info.st_size,
                            "modified": stat_info.st_mtime,
                            "permissions": oct(stat_info.st_mode)[-3:],
                        }
                        manifest["total_files"] += 1
                        manifest["total_size"] += stat_info.st_size

                    except (OSError, IOError):
                        continue

            result["package_manifest"] = manifest
            result["checks"]["manifest_generation"] = "passed"

        except Exception as e:
            result["errors"].append(f"Failed to generate package manifest: {e}")
            result["checks"]["manifest_generation"] = "failed"

        return result

    def _determine_verification_status(self, result: Dict[str, Any]) -> str:
        """Determine overall verification status."""
        if result["errors"]:
            return "error"

        checks = result["checks"]
        passed_checks = sum(1 for status in checks.values() if status == "passed")
        failed_checks = sum(1 for status in checks.values() if status == "failed")
        total_checks = len([c for c in checks.values() if c != "skipped"])

        if failed_checks > 0:
            return "failed"

        if passed_checks == total_checks and not result["warnings"]:
            return "verified"
        elif passed_checks >= total_checks // 2:
            return "partial"
        else:
            return "unverified"

    def create_signature(self, package_path: str, key_id: Optional[str] = None) -> Dict[str, Any]:
        """Create GPG signature for a package."""
        result = {
            "package_path": package_path,
            "signature_created": False,
            "signature_files": [],
            "errors": [],
        }

        try:
            # Create signatures for key package files
            key_files = []

            # Find manifest files
            for root, dirs, files in os.walk(package_path):
                for file in files:
                    if file in ["package.json", "pyproject.toml", "Cargo.toml", "Project.toml"]:
                        key_files.append(os.path.join(root, file))

            if not key_files:
                result["errors"].append("No key package files found to sign")
                return result

            for file_path in key_files:
                try:
                    sig_path = file_path + ".sig"
                    cmd = ["gpg", "--detach-sign", "--armor"]

                    if key_id:
                        cmd.extend(["--local-user", key_id])

                    cmd.extend(["--output", sig_path, file_path])

                    proc = subprocess.run(cmd, capture_output=True, text=True)

                    if proc.returncode == 0:
                        result["signature_files"].append(sig_path)
                        result["signature_created"] = True
                        logger.info(f"Created signature: {sig_path}")
                    else:
                        result["errors"].append(
                            f"Failed to create signature for {file_path}: {proc.stderr}"
                        )

                except subprocess.SubprocessError as e:
                    result["errors"].append(f"GPG signing error for {file_path}: {e}")

        except Exception as e:
            result["errors"].append(f"Signature creation failed: {e}")

        return result

    def verify_all_packages(self, packages_dir: str = "pkg") -> Dict[str, Any]:
        """Verify signatures for all packages in the project."""
        if not os.path.exists(packages_dir):
            raise SignatureVerificationError(f"Packages directory not found: {packages_dir}")

        package_mapping = {
            "EarthSciAST.jl": "julia",
            "earthsci-ast-py": "python",
            "earthsci-ast-ts": "npm",
            "earthsci-ast-editor": "npm",
            "earthsci-ast-rs": "rust",
        }

        results = {
            "verification_summary": {
                "total_packages": 0,
                "verified": 0,
                "partial": 0,
                "unverified": 0,
                "failed": 0,
                "errors": 0,
            },
            "packages": {},
        }

        for package_name, package_type in package_mapping.items():
            package_path = os.path.join(packages_dir, package_name)
            if os.path.exists(package_path):
                result = self.verify_package_signature(package_path, package_type)
                results["packages"][package_name] = result

                # Update summary
                results["verification_summary"]["total_packages"] += 1
                status = result["verification_status"]
                results["verification_summary"][status] = (
                    results["verification_summary"].get(status, 0) + 1
                )

        return results


def main():
    """Main entry point for the signature verifier."""
    parser = argparse.ArgumentParser(description="Package Signature Verification System")
    parser.add_argument(
        "--packages-dir",
        default="pkg",
        help="Directory containing packages to verify (default: pkg)",
    )
    parser.add_argument("--config", help="Path to signature verification configuration file")
    parser.add_argument(
        "--output",
        default="signature-verification-report.json",
        help="Output file for verification results",
    )
    parser.add_argument(
        "--create-signatures", action="store_true", help="Create GPG signatures for packages"
    )
    parser.add_argument("--key-id", help="GPG key ID to use for signing")
    parser.add_argument("--package", help="Verify a specific package only")
    parser.add_argument(
        "--package-type",
        choices=["julia", "python", "npm", "rust"],
        help="Type of package when verifying specific package",
    )

    args = parser.parse_args()

    try:
        verifier = PackageSignatureVerifier(args.config)

        if args.create_signatures:
            # Create signatures mode
            if args.package:
                result = verifier.create_signature(args.package, args.key_id)
                print(f"Signature creation result: {result}")
            else:
                print("Creating signatures for all packages...")
                # Implementation for creating signatures for all packages
                package_mapping = {
                    "EarthSciAST.jl": "julia",
                    "earthsci-ast-py": "python",
                    "earthsci-ast-ts": "npm",
                    "earthsci-ast-editor": "npm",
                    "earthsci-ast-rs": "rust",
                }

                for package_name in package_mapping:
                    package_path = os.path.join(args.packages_dir, package_name)
                    if os.path.exists(package_path):
                        result = verifier.create_signature(package_path, args.key_id)
                        print(f"Signatures for {package_name}: {result}")

        else:
            # Verification mode
            if args.package:
                if not args.package_type:
                    print("Error: --package-type required when verifying specific package")
                    sys.exit(1)

                result = verifier.verify_package_signature(args.package, args.package_type)
                results = {"packages": {args.package: result}}
            else:
                results = verifier.verify_all_packages(args.packages_dir)

            # Save results
            with open(args.output, "w") as f:
                json.dump(results, f, indent=2, default=str)

            # Print summary
            if "verification_summary" in results:
                summary = results["verification_summary"]
                print("\nSignature Verification Summary:")
                print(f"Total packages: {summary['total_packages']}")
                print(f"Verified: {summary.get('verified', 0)}")
                print(f"Partial: {summary.get('partial', 0)}")
                print(f"Unverified: {summary.get('unverified', 0)}")
                print(f"Failed: {summary.get('failed', 0)}")
                print(f"Errors: {summary.get('errors', 0)}")

            print(f"\nDetailed results saved to: {args.output}")

    except KeyboardInterrupt:
        print("\nVerification interrupted by user")
        sys.exit(130)
    except Exception as e:
        logger.error(f"Signature verification failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
