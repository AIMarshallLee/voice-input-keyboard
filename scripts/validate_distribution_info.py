import plistlib
import sys
from pathlib import Path


ALLOWED_BACKGROUND_MODES = {
    "audio",
    "bluetooth-central",
    "bluetooth-peripheral",
    "external-accessory",
    "fetch",
    "location",
    "nearby-interaction",
    "network-authentication",
    "newsstand-content",
    "processing",
    "push-to-talk",
    "remote-notification",
    "screen-capture",
    "voip",
}


def validate_info_plist(path):
    with Path(path).open("rb") as handle:
        info = plistlib.load(handle)

    modes = info.get("UIBackgroundModes", [])
    invalid_modes = sorted(set(modes) - ALLOWED_BACKGROUND_MODES)
    if invalid_modes:
        raise ValueError(
            "Invalid UIBackgroundModes value(s): " + ", ".join(invalid_modes)
        )


if __name__ == "__main__":
    try:
        validate_info_plist(sys.argv[1])
    except (IndexError, OSError, plistlib.InvalidFileException, ValueError) as error:
        print(f"Distribution Info.plist validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
