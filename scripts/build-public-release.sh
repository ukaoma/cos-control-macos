#!/bin/zsh
# The customer download path must never silently fall back to a local identity.
set -euo pipefail
ROOT="${0:A:h:h}"
if [[ "${COS_SIGN_IDENTITY:-}" != "Developer ID Application: "* ]] || [[ -z "${COS_NOTARY_PROFILE:-}" ]]; then
  print -u2 'Public release needs COS_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" and COS_NOTARY_PROFILE.'
  print -u2 'Enroll at https://developer.apple.com/programs/enroll/, then configure the certificate and notarytool Keychain profile.'
  exit 66
fi
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -qF "\"$COS_SIGN_IDENTITY\""; then
  print -u2 'The configured Developer ID identity and private key are not available in this Keychain.'
  exit 67
fi
unset COS_LOCAL_SIGN_IDENTITY COS_ALLOW_ADHOC
export COS_BUILD_DIST_DIR="${COS_BUILD_DIST_DIR:-$ROOT/dist/public}"
exec zsh "$ROOT/scripts/build-release.sh" "$@"
