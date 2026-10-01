#!/usr/bin/env python3
"""Fail closed when any production-family client can leave its data plane."""

from __future__ import annotations

import re
from pathlib import Path

WORKFLOWS = (
    "android-internal-auto",
    "ios-prod-testflight",
    "android-prod-internal",
    "ios-prod-patch",
    "android-prod-patch",
    "macos-prod-appstore",
)
# Personal builds are NOT production-family artifacts. INV-DATA-1 allows a
# separate app identity with its own credentials to use non-production
# services, provided it never reuses a production-family identity. Each entry
# pins that separate identity plus the explicit personal routing contract
# (the `personal` app profile and a CI-provided API host), so the workflow can
# neither drift back onto the production plane by accident nor impersonate it.
PERSONAL_WORKFLOWS = {
    "ios-internal-auto": "com.casonclark.omi",
}
PERSONAL_API_BASE_URL_ASSIGNMENT = "${API_BASE_URL:?Codemagic app_env must set API_BASE_URL}"
PERSONAL_REQUIRED_FRAGMENTS = (
    "--dart-define=OMI_APP_PROFILE=personal",
    "--dart-define=OMI_API_BASE_URL=$API_BASE_URL",
)
PRODUCTION_FAMILY_IOS_BUNDLE_IDENTIFIER_PREFIX = "com.friend-app-with-wearable."
OTHER_APP_PROFILE_PATTERN = re.compile(r"OMI_APP_PROFILE=(?!personal\b)")
DESKTOP_WORKFLOW = "omi-desktop-swift-release"
PIN = "https://api.omi.me/"
DESKTOP_PIN = "https://api.omi.me"
DESKTOP_BACKEND_PIN = "https://desktop-backend-hhibjajaja-uc.a.run.app/"
RETIRED_GKE_DESKTOP_BACKEND_CHART_ROOTS = (
    "backend/charts",
    "desktop/macos/charts",
)
RETIRED_GKE_DESKTOP_BACKEND_WORKFLOW_ROOT = ".github/workflows"
RETIRED_GKE_DESKTOP_BACKEND_MANIFEST_SUFFIXES = {".tpl", ".yaml", ".yml"}
RETIRED_GKE_DESKTOP_BACKEND_MARKERS = ("desktop-api.omi.me", "desktop-backend")
GKE_WORKFLOW_MARKERS = ("gcloud container clusters", "helm ", "kubectl ")
LEGACY_BETA_ROUTING_PATHS = (
    "codemagic.yaml",
    "app/lib/env/dev_env.dart",
    "app/lib/env/prod_env.dart",
    "app/lib/main.dart",
    "app/lib/utils/environment_detector.dart",
    "desktop/macos/Desktop/Sources/DesktopBackendEnvironment.swift",
)
FORBIDDEN_ROUTING_TOKENS = (
    "OMI_BETA_RELEASE_RING",
    "api-beta.omi.me",
    "STAGING_API_URL",
)
REQUIRED_PRODUCTION_FRAGMENTS = {
    "desktop/macos/Desktop/Sources/AppBuild.swift": (
        'productionBundleIdentifier = "com.omi.computer-macos"',
        "externalPreviewBundleIdentifierPrefix",
    ),
    "desktop/macos/Desktop/Sources/GoogleService-Info.plist": (
        "<string>based-hardware</string>",
    ),
}
CANONICAL_MACOS_PRODUCTION_BUNDLE_IDENTIFIER = "com.omi.computer-macos"
# INV-BETA-1: the side-by-side Omi Beta app is the single sanctioned second
# production identity (founder decision, 2026-07-22). Any other divergent
# identity remains rejected.
SANCTIONED_MACOS_PRODUCTION_BUNDLE_IDENTIFIERS = {
    CANONICAL_MACOS_PRODUCTION_BUNDLE_IDENTIFIER,
    "com.omi.computer-macos.beta",
}
MACOS_PRODUCTION_BUNDLE_IDENTIFIER_PATTERN = re.compile(r'"(com\.omi\.computer-macos(?:\.[^"]+)?)"')


def _workflow_block(text: str, workflow: str) -> str | None:
    match = re.search(rf"(?ms)^  {re.escape(workflow)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text)
    return match.group(1) if match else None


def _retired_gke_desktop_backend_manifests(root: Path) -> list[Path]:
    retired_manifests = []
    for chart_root in RETIRED_GKE_DESKTOP_BACKEND_CHART_ROOTS:
        manifests_root = root / chart_root
        if not manifests_root.is_dir():
            continue
        for manifest in manifests_root.rglob("*"):
            if not manifest.is_file() or manifest.suffix not in RETIRED_GKE_DESKTOP_BACKEND_MANIFEST_SUFFIXES:
                continue
            source = manifest.read_text(encoding="utf-8")
            if any(marker in source for marker in RETIRED_GKE_DESKTOP_BACKEND_MARKERS):
                retired_manifests.append(manifest.relative_to(root))

    workflow_root = root / RETIRED_GKE_DESKTOP_BACKEND_WORKFLOW_ROOT
    if workflow_root.is_dir():
        for workflow in workflow_root.glob("*.y*ml"):
            source = workflow.read_text(encoding="utf-8")
            if (
                any(marker in source for marker in RETIRED_GKE_DESKTOP_BACKEND_MARKERS)
                and any(marker in source for marker in GKE_WORKFLOW_MARKERS)
            ):
                retired_manifests.append(workflow.relative_to(root))
    return retired_manifests


def _validate_personal_workflow(workflow: str, bundle_identifier: str, block: str | None) -> list[str]:
    if block is None:
        return [f"missing personal workflow {workflow}"]
    errors: list[str] = []
    # The fail-fast `${VAR:?message}` expansion contains spaces, so match the full value.
    assignments = re.findall(r"(?m)^\s*echo API_BASE_URL=(.+?) >> \.env\s*$", block)
    if assignments != [PERSONAL_API_BASE_URL_ASSIGNMENT]:
        errors.append(
            f"{workflow} is a personal build and must contain exactly one "
            f"API_BASE_URL={PERSONAL_API_BASE_URL_ASSIGNMENT} assignment"
        )
    for fragment in PERSONAL_REQUIRED_FRAGMENTS:
        if block.count(fragment) != 1:
            errors.append(f"{workflow} is a personal build and must pass {fragment} exactly once")
    if OTHER_APP_PROFILE_PATTERN.search(block):
        errors.append(f"{workflow} is a personal build and must not select another OMI_APP_PROFILE")
    if PIN in block:
        errors.append(f"{workflow} is a personal build and must not route to the production API {PIN}")
    bundle_identifiers = re.findall(r"--ios-bundle-id=([^\s\\]+)", block)
    if bundle_identifier not in bundle_identifiers:
        errors.append(f"{workflow} is a personal build and must keep its separate iOS identity {bundle_identifier}")
    for candidate in bundle_identifiers:
        if candidate.startswith(PRODUCTION_FAMILY_IOS_BUNDLE_IDENTIFIER_PREFIX):
            errors.append(f"{workflow} is a personal build and must not reuse production-family identity {candidate}")
    return errors


def validate(root: Path) -> list[str]:
    text = (root / "codemagic.yaml").read_text(encoding="utf-8")
    errors: list[str] = []
    for manifest in _retired_gke_desktop_backend_manifests(root):
        errors.append(
            f"{manifest} declares retired GKE desktop-backend ownership; production desktop-backend is Cloud Run"
        )
    for workflow in WORKFLOWS:
        block = _workflow_block(text, workflow)
        assignments = re.findall(r"(?m)^\s*echo API_BASE_URL=([^\s]+) >> \.env\s*$", block or "")
        if assignments != [PIN]:
            errors.append(
                f"{workflow} must contain exactly one immutable API_BASE_URL=https://api.omi.me/ assignment"
            )
    for workflow, bundle_identifier in PERSONAL_WORKFLOWS.items():
        errors.extend(_validate_personal_workflow(workflow, bundle_identifier, _workflow_block(text, workflow)))
    desktop_block = _workflow_block(text, DESKTOP_WORKFLOW)
    desktop_bundle_identifiers = re.findall(
        r"(?m)^\s*BUNDLE_ID:\s*[\"']?([^\"'\s]+)[\"']?\s*$", desktop_block or ""
    )
    if desktop_bundle_identifiers != [CANONICAL_MACOS_PRODUCTION_BUNDLE_IDENTIFIER]:
        errors.append(
            f"{DESKTOP_WORKFLOW} must contain exactly one immutable "
            f"BUNDLE_ID={CANONICAL_MACOS_PRODUCTION_BUNDLE_IDENTIFIER} assignment"
        )
    desktop_assignments = re.findall(r"(?m)^\s*OMI_PYTHON_API_URL:\s*[\"']?([^\"'\s]+)[\"']?\s*$", desktop_block or "")
    if desktop_assignments != [DESKTOP_PIN]:
        errors.append(
            f"{DESKTOP_WORKFLOW} must contain exactly one immutable OMI_PYTHON_API_URL=https://api.omi.me assignment"
        )
    desktop_backend_assignments = re.findall(
        r"(?m)^\s*OMI_DESKTOP_API_URL:\s*[\"']?([^\"'\s]+)[\"']?\s*$", desktop_block or ""
    )
    if desktop_backend_assignments != [DESKTOP_BACKEND_PIN]:
        errors.append(
            f"{DESKTOP_WORKFLOW} must contain exactly one immutable "
            "OMI_DESKTOP_API_URL=https://desktop-backend-hhibjajaja-uc.a.run.app/ assignment"
        )
    for relative_path in LEGACY_BETA_ROUTING_PATHS:
        source_path = root / relative_path
        if not source_path.is_file():
            errors.append(f"missing protected production-routing source {relative_path}")
            continue
        source = source_path.read_text(encoding="utf-8")
        for token in FORBIDDEN_ROUTING_TOKENS:
            if token in source:
                errors.append(f"{relative_path} must not contain legacy beta/staging routing token {token}")
    for relative_path, required_fragments in REQUIRED_PRODUCTION_FRAGMENTS.items():
        source_path = root / relative_path
        if not source_path.is_file():
            errors.append(f"missing protected production identity source {relative_path}")
            continue
        source = source_path.read_text(encoding="utf-8")
        for fragment in required_fragments:
            if fragment not in source:
                errors.append(f"{relative_path} must retain protected production identity fragment {fragment!r}")
        if relative_path == "desktop/macos/Desktop/Sources/AppBuild.swift":
            for bundle_identifier in MACOS_PRODUCTION_BUNDLE_IDENTIFIER_PATTERN.findall(source):
                if bundle_identifier not in SANCTIONED_MACOS_PRODUCTION_BUNDLE_IDENTIFIERS:
                    errors.append(
                        f"{relative_path} must not define divergent production-family bundle identity "
                        f"{bundle_identifier!r}"
                    )
    return errors


if __name__ == "__main__":
    raise SystemExit(1 if validate(Path(".")) else 0)
