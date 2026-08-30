#!/usr/bin/env python3
"""Validate one CoreDevice install receipt and its independent app inventory."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import pathlib
import re
import sys
import urllib.parse
import uuid
from typing import Any


MAX_JSON_BYTES = 1_048_576
MAX_JSON_NODES = 20_000
MAX_JSON_DEPTH = 32
BUNDLE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,254}$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
BUILD = re.compile(r"^[0-9]{1,18}$")


class InstallReceiptError(RuntimeError):
    pass


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InstallReceiptError(f"duplicate JSON member: {key}")
        result[key] = value
    return result


def _reject_nonfinite(value: str) -> Any:
    raise InstallReceiptError(f"non-finite JSON number: {value}")


def _bounded_json(path: pathlib.Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise InstallReceiptError("CoreDevice JSON input is missing or unsafe")
    size = path.stat().st_size
    if not 1 <= size <= MAX_JSON_BYTES:
        raise InstallReceiptError("CoreDevice JSON input has an invalid size")
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicates,
            parse_constant=_reject_nonfinite,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise InstallReceiptError("CoreDevice JSON input is invalid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise InstallReceiptError("CoreDevice JSON root must be an object")
    pending: list[tuple[Any, int]] = [(value, 0)]
    nodes = 0
    while pending:
        item, depth = pending.pop()
        nodes += 1
        if nodes > MAX_JSON_NODES or depth > MAX_JSON_DEPTH:
            raise InstallReceiptError("CoreDevice JSON structure exceeds safety limits")
        if isinstance(item, dict):
            pending.extend((child, depth + 1) for child in item.values())
        elif isinstance(item, list):
            pending.extend((child, depth + 1) for child in item)
        elif not isinstance(item, (str, int, float, bool, type(None))):
            raise InstallReceiptError("CoreDevice JSON contains an unsupported value")
    return value


def _successful_result(document: dict[str, Any], command: str) -> dict[str, Any]:
    if set(document) != {"info", "result"}:
        raise InstallReceiptError(f"{command} JSON envelope is not exact")
    info = document.get("info")
    result = document.get("result")
    required_info = {"arguments", "commandType", "environment", "jsonVersion", "outcome", "version"}
    if not isinstance(info, dict) or set(info) != required_info:
        raise InstallReceiptError(f"{command} JSON metadata is not exact")
    if info.get("outcome") != "success" or not isinstance(info.get("jsonVersion"), int):
        raise InstallReceiptError(f"{command} did not report a successful typed result")
    if not isinstance(result, dict):
        raise InstallReceiptError(f"{command} result is not an object")
    return result


def _canonical_file_url(value: Any, expected_name: str) -> str:
    if not isinstance(value, str) or not 1 <= len(value) <= 4096:
        raise InstallReceiptError("installed application URL is invalid")
    parsed = urllib.parse.urlsplit(value)
    if (
        parsed.scheme != "file"
        or parsed.netloc not in {"", "localhost"}
        or parsed.query
        or parsed.fragment
        or not parsed.path.startswith("/")
        or pathlib.PurePosixPath(urllib.parse.unquote(parsed.path)).name != expected_name
    ):
        raise InstallReceiptError("installed application URL does not identify the expected app path")
    return value


def _persistent_identifier(value: Any) -> str:
    if not isinstance(value, str) or not 16 <= len(value) <= 4096 or any(char.isspace() for char in value):
        raise InstallReceiptError("launchServicesIdentifier is missing or invalid")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise InstallReceiptError("launchServicesIdentifier is not canonical base64") from error
    if not 8 <= len(decoded) <= 3072 or base64.b64encode(decoded).decode("ascii") != value:
        raise InstallReceiptError("launchServicesIdentifier is not canonical base64")
    return value


def validate_install(
    receipt_path: pathlib.Path,
    inventory_path: pathlib.Path,
    *,
    bundle_id: str,
    version: str,
    build: str,
    installation_name: str,
) -> str:
    if BUNDLE_ID.fullmatch(bundle_id) is None:
        raise InstallReceiptError("expected bundle identifier is invalid")
    if VERSION.fullmatch(version) is None or BUILD.fullmatch(build) is None:
        raise InstallReceiptError("expected application version/build is invalid")
    if (
        pathlib.PurePosixPath(installation_name).name != installation_name
        or not installation_name.endswith(".app")
        or not 5 <= len(installation_name) <= 255
    ):
        raise InstallReceiptError("expected installation name is invalid")

    receipt = _successful_result(_bounded_json(receipt_path), "install")
    if set(receipt) != {"deviceIdentifier", "installedApplications"}:
        raise InstallReceiptError("install result fields are not exact")
    installed = receipt.get("installedApplications")
    if not isinstance(installed, list) or len(installed) != 1 or not isinstance(installed[0], dict):
        raise InstallReceiptError("install receipt must contain exactly one installed application")
    app = installed[0]
    required_install = {
        "bundleID", "installationURL", "launchServicesIdentifier",
        "databaseUUID", "databaseSequenceNumber",
    }
    if not required_install.issubset(app) or not set(app).issubset(required_install | {"options"}):
        raise InstallReceiptError("installed application receipt fields are not exact")
    if app.get("bundleID") != bundle_id:
        raise InstallReceiptError("install receipt bundle identifier does not match")
    installation_url = _canonical_file_url(app.get("installationURL"), installation_name)
    persistent_identifier = _persistent_identifier(app.get("launchServicesIdentifier"))
    try:
        uuid.UUID(str(app.get("databaseUUID")))
    except (ValueError, AttributeError) as error:
        raise InstallReceiptError("install receipt database UUID is invalid") from error
    sequence = app.get("databaseSequenceNumber")
    if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence < 0:
        raise InstallReceiptError("install receipt database sequence is invalid")

    inventory = _successful_result(_bounded_json(inventory_path), "post-install inventory")
    required_inventory = {
        "apps", "defaultAppsIncluded", "deviceIdentifier", "hiddenAppsIncluded",
        "internalAppsIncluded", "matchingBundleIdentifier", "removableAppsIncluded",
    }
    if set(inventory) != required_inventory:
        raise InstallReceiptError("post-install inventory result fields are not exact")
    if inventory.get("deviceIdentifier") != receipt.get("deviceIdentifier"):
        raise InstallReceiptError("install receipt and inventory identify different devices")
    if inventory.get("matchingBundleIdentifier") != bundle_id:
        raise InstallReceiptError("post-install inventory filter does not match the protected bundle")
    inventory_apps = inventory.get("apps")
    if not isinstance(inventory_apps, list) or len(inventory_apps) != 1 or not isinstance(inventory_apps[0], dict):
        raise InstallReceiptError("post-install inventory must contain exactly one application")
    inventory_app = inventory_apps[0]
    allowed_app_fields = {
        "appClip", "appGroupIdentifiers", "builtByDeveloper", "bundleContainerPath",
        "bundleIdentifier", "bundleVersion", "containerAccessible", "dataContainerPath",
        "defaultApp", "groupContainerPaths", "hidden", "internalApp", "name",
        "removable", "url", "version",
    }
    required_app_fields = {
        "appClip", "builtByDeveloper", "bundleIdentifier", "bundleVersion",
        "defaultApp", "hidden", "internalApp", "name", "removable", "url", "version",
    }
    if not required_app_fields.issubset(inventory_app) or not set(inventory_app).issubset(allowed_app_fields):
        raise InstallReceiptError("post-install application fields are not exact")
    if (
        inventory_app.get("bundleIdentifier") != bundle_id
        or inventory_app.get("version") != version
        or inventory_app.get("bundleVersion") != build
        or inventory_app.get("builtByDeveloper") is not True
        or inventory_app.get("appClip") is not False
        or inventory_app.get("defaultApp") is not False
        or inventory_app.get("internalApp") is not False
        or inventory_app.get("removable") is not True
    ):
        raise InstallReceiptError("post-install application identity does not match the protected candidate")
    if _canonical_file_url(inventory_app.get("url"), installation_name) != installation_url:
        raise InstallReceiptError("post-install application path does not match the install receipt")
    return persistent_identifier


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=pathlib.Path)
    parser.add_argument("--inventory", required=True, type=pathlib.Path)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--installation-name", required=True)
    arguments = parser.parse_args()
    print(
        validate_install(
            arguments.receipt,
            arguments.inventory,
            bundle_id=arguments.bundle_id,
            version=arguments.version,
            build=arguments.build,
            installation_name=arguments.installation_name,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except InstallReceiptError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None
