#!/bin/bash
set -euo pipefail

found=0
while IFS= read -r forbidden; do
  if /usr/bin/grep -REn --include='*.swift' "$forbidden" KeyboardExtension; then
    found=1
  fi
done <<'PATTERNS'
extensionContext[[:space:]]*\??[[:space:]]*\.open
UIApplication([^[:alnum:]_]|$).*\.open
openURL
NSSelectorFromString
sel_registerName
\.perform[[:space:]]*\(
\.responds[[:space:]]*\([[:space:]]*to:
responder[[:space:]]*=.*\.next
DictationConstants\.buildDictationURL
PATTERNS

if [ "$found" -ne 0 ]; then
  echo "Unsupported keyboard-to-host launch API found" >&2
  exit 1
fi

echo "Keyboard distribution launch gate passed"
