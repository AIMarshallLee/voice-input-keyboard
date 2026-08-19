#!/usr/bin/env python3
import re
import os
import sys

pp_app = os.environ.get('PP_UUID_APP', '')
pp_kb = os.environ.get('PP_UUID_KB', '')

print(f"App UUID: {pp_app}")
print(f"Keyboard UUID: {pp_kb}")

if not pp_app or not pp_kb:
    print("ERROR: Missing PP_UUID_APP or PP_UUID_KB environment variables")
    sys.exit(1)

pbxproj_path = 'VoType.xcodeproj/project.pbxproj'

with open(pbxproj_path, 'r') as f:
    content = f.read()

# Log current state
app_matches = re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = "com\.voiceinput\.app";', content)
kb_matches = re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = "com\.voiceinput\.votype\.keyboard";', content)
print(f"Found {len(app_matches)} app bundle ID matches")
print(f"Found {len(kb_matches)} keyboard bundle ID matches")

# Clear all PROVISIONING_PROFILE_SPECIFIER and PROVISIONING_PROFILE
content = re.sub(r'PROVISIONING_PROFILE_SPECIFIER = "[^"]*";', 'PROVISIONING_PROFILE_SPECIFIER = "";', content)
content = re.sub(r'PROVISIONING_PROFILE = "[^"]*";', 'PROVISIONING_PROFILE = "";', content)

# Inject PROVISIONING_PROFILE after each target's bundle ID
app_replacement = f'PRODUCT_BUNDLE_IDENTIFIER = com.daseanle.votype;\n\t\t\t\tPROVISIONING_PROFILE = "{pp_app}";'
kb_replacement = f'PRODUCT_BUNDLE_IDENTIFIER = com.daseanle.votype.keyboard;\n\t\t\t\tPROVISIONING_PROFILE = "{pp_kb}";'

content = content.replace('PRODUCT_BUNDLE_IDENTIFIER = com.daseanle.votype;', app_replacement)
content = content.replace('PRODUCT_BUNDLE_IDENTIFIER = com.daseanle.votype.keyboard;', kb_replacement)

with open(pbxproj_path, 'w') as f:
    f.write(content)

# Verify
with open(pbxproj_path, 'r') as f:
    verify = f.read()

app_pp_count = verify.count(f'PROVISIONING_PROFILE = "{pp_app}";')
kb_pp_count = verify.count(f'PROVISIONING_PROFILE = "{pp_kb}";')
print(f"Verification: App PP injected {app_pp_count} times, Keyboard PP injected {kb_pp_count} times")
print("Done!")
