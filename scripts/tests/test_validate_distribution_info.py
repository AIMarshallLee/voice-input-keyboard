import plistlib
import tempfile
import unittest
from pathlib import Path

from scripts.validate_distribution_info import validate_info_plist


class DistributionInfoValidationTests(unittest.TestCase):
    def write_plist(self, background_modes):
        temp_dir = tempfile.TemporaryDirectory()
        path = Path(temp_dir.name) / "Info.plist"
        with path.open("wb") as handle:
            plistlib.dump({"UIBackgroundModes": background_modes}, handle)
        self.addCleanup(temp_dir.cleanup)
        return path

    def test_rejects_invalid_picture_in_picture_background_mode(self):
        path = self.write_plist(["audio", "picture-in-picture"])

        with self.assertRaisesRegex(ValueError, "picture-in-picture"):
            validate_info_plist(path)

    def test_accepts_audio_background_mode_for_picture_in_picture(self):
        path = self.write_plist(["audio"])

        validate_info_plist(path)


if __name__ == "__main__":
    unittest.main()
