#!/bin/zsh
# THROWAWAY QA BUILDS ONLY. This is NOT the shipping path, and it has not
# been since 0.5.107 (build 145).
#
# There is still no Apple Developer ID on this machine (2026-07-27), but the
# project DOES have a stable self-signed identity, "COS Control Local", and
# every published build since 0.5.107 is signed with it. That identity is what
# keeps a user's Accessibility grant alive across updates: macOS keys TCC to
# the designated requirement, and ad-hoc signing re-keys it on every single
# build, stranding the grant while System Settings still shows the toggle ON.
#
# The header this file used to carry described it as the project's sole
# release route. That was written before 0.5.107 and was never updated. On
# 2026-09-01 it did exactly what a stale rationale does: it read as
# authoritative, a build made through here was installed over a release, and
# it broke Accessibility on a machine that already had a working grant.
#
# build-release.sh now adopts the stable identity automatically and ignores
# COS_ALLOW_ADHOC whenever that identity exists, so this wrapper produces an
# ad-hoc build ONLY on a machine that has no stable identity to begin with.
# Do not install its output over a release.
set -euo pipefail
export COS_ALLOW_ADHOC=1
exec zsh "${0:A:h}/build-release.sh" "$@"
