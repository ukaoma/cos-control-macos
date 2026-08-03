#!/bin/zsh
# Ad-hoc release wrapper — the ONLY shipping path this project has.
#
# There is no Apple Developer ID on this machine (documented decision,
# 2026-07-27): every shipped COS Control since 0.2.3, including the live
# 0.3.0, is ad-hoc signed and installs with the documented one-time
# `xattr -cr` quarantine workaround from gotcos.com/control. The
# COS_SIGN_IDENTITY gate in build-release.sh describes an identity this
# project does not possess; this wrapper is the honest front door.
set -euo pipefail
export COS_ALLOW_ADHOC=1
exec zsh "${0:A:h}/build-release.sh" "$@"
