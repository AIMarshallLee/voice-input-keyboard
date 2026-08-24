#!/usr/bin/env python3
import os
import re
import sys
from pathlib import Path
from typing import NoReturn


PROJECT_PATH = Path("VoType.xcodeproj/project.pbxproj")
APP_BUNDLE_ID = "com.daseanle.votype"
KEYBOARD_BUNDLE_ID = "com.daseanle.votype.keyboard"


def fail(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_uuid(name: str, value: str) -> str:
    value = value.strip()
    if not value:
        fail(f"Missing {name}")
    if not re.fullmatch(
        r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
        r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        value,
    ):
        fail(f"{name} is not a provisioning profile UUID")
    return value


def inject_profile(content: str, bundle_id: str, profile_uuid: str) -> tuple[str, int]:
    pattern = re.compile(
        rf'^(?P<indent>[ \t]*)PRODUCT_BUNDLE_IDENTIFIER = "?{re.escape(bundle_id)}"?;$',
        re.MULTILINE,
    )
    matches = list(pattern.finditer(content))
    if not matches:
        fail(f"Bundle ID not found in generated project: {bundle_id}")

    def replacement(match: re.Match[str]) -> str:
        indent = match.group("indent")
        return (
            f"{match.group(0)}\n"
            f'{indent}PROVISIONING_PROFILE = "{profile_uuid}";'
        )

    return pattern.sub(replacement, content), len(matches)


def main() -> None:
    pp_app = validate_uuid("PP_UUID_APP", os.environ.get("PP_UUID_APP", ""))
    pp_keyboard = validate_uuid("PP_UUID_KB", os.environ.get("PP_UUID_KB", ""))
    if pp_app == pp_keyboard:
        fail("App and keyboard provisioning profiles must have different UUIDs")

    if not PROJECT_PATH.is_file():
        fail(f"Generated project not found: {PROJECT_PATH}")

    content = PROJECT_PATH.read_text(encoding="utf-8")

    # Make the script safe to re-run by removing previously injected settings.
    content = re.sub(
        r"^[ \t]*PROVISIONING_PROFILE(?:_SPECIFIER)? = .*;\r?\n",
        "",
        content,
        flags=re.MULTILINE,
    )

    content, app_count = inject_profile(content, APP_BUNDLE_ID, pp_app)
    content, keyboard_count = inject_profile(
        content, KEYBOARD_BUNDLE_ID, pp_keyboard
    )

    expected_app_line = f'PROVISIONING_PROFILE = "{pp_app}";'
    expected_keyboard_line = f'PROVISIONING_PROFILE = "{pp_keyboard}";'
    if content.count(expected_app_line) != app_count:
        fail("App provisioning profile injection verification failed")
    if content.count(expected_keyboard_line) != keyboard_count:
        fail("Keyboard provisioning profile injection verification failed")

    PROJECT_PATH.write_text(content, encoding="utf-8")
    print(
        "Provisioning profiles injected successfully: "
        f"app={app_count}, keyboard={keyboard_count}"
    )


if __name__ == "__main__":
    main()
