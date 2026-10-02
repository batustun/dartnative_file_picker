#!/usr/bin/env bash
#
# The local quality gate for file_picker.
#
# There is no CI on this repository by design, so this script is the gate. It
# stops at the first failure and never hides a command's output: a failure you
# cannot read is a failure you cannot fix.
#
#   ./tool/check.sh          everything, including the example app builds
#   ./tool/check.sh --fast   skip the example app builds (the slow part)
#
# Every command here was verified to exist in dn 1.0.0. In particular there is
# no `dn format` and no publish dry-run, so formatting goes through the SDK's own
# Dart and `dn plugin build` stands in as the pre-publication gate.

set -euo pipefail

FAST=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    -h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# ── Locate the toolchain ──────────────────────────────────────────────────────
# The installer appends ~/zero/bin to the shell profile, which a non-interactive
# shell may not have loaded.

if ! command -v dn >/dev/null 2>&1; then
  if [ -x "$HOME/zero/bin/dn" ]; then
    PATH="$HOME/zero/bin:$PATH"
  else
    echo "error: the dn CLI was not found." >&2
    echo "  Install it: curl -fsSL https://cdn.dartnative.com/install.sh | sh" >&2
    exit 1
  fi
fi
export PATH

# Use the SDK's own Dart for formatting so the result is identical everywhere,
# rather than whatever Dart or Flutter happens to be first on PATH.
DART="$(dirname "$(command -v dn)")/dart"
[ -x "$DART" ] || DART="dart"

STEP=0
step() {
  STEP=$((STEP + 1))
  printf '\n\033[1m[%d/%d] %s\033[0m\n' "$STEP" "$TOTAL" "$1"
}

TOTAL=5
[ "$FAST" -eq 0 ] && TOTAL=7

echo "file_picker — local quality gate"
dn --version | head -1

# ── 1. Formatting ─────────────────────────────────────────────────────────────

step "format check (no dn format exists; using the SDK's dart)"
"$DART" format --output=none --set-exit-if-changed .

# ── 2. Dependencies ───────────────────────────────────────────────────────────

step "dn pub get"
dn pub get

# ── 3. Static analysis ────────────────────────────────────────────────────────
# dn analyze treats infos AND warnings as fatal by default. Left that way on
# purpose: a published plugin with a dirty analyzer is a published plugin with a
# latent bug.

step "dn analyze"
dn analyze --no-pub

# ── 4. Unit tests ─────────────────────────────────────────────────────────────

step "dn test"
dn test --no-pub

# ── 5. Native compilation, both platforms ─────────────────────────────────────
# The real gate: compiles the Swift into an xcframework and the Kotlin plus C++
# into an aar. Contacts no registry, so it is safe to run as often as you like.
# --owner avoids depending on a configured git remote.

step "dn plugin build (iOS xcframework + Android aar)"
dn plugin build --owner "${DARTPUB_OWNER:-batustun}"

if [ "$FAST" -eq 1 ]; then
  printf '\n\033[32m✓ fast checks passed\033[0m (example app builds skipped)\n'
  exit 0
fi

# ── 6. Example app, Android ───────────────────────────────────────────────────
# Proves the plugin links into a real app: the Kotlin plugin class is registered,
# the .so is packaged, and the generated registrant calls loadSymbols().

step "example app: Android debug APK"
cd "$ROOT/example"
dn pub get
dn build apk --debug

# ── 7. Example app, iOS ───────────────────────────────────────────────────────

step "example app: iOS device build"
if [ "$(uname -s)" != "Darwin" ]; then
  echo "SKIPPED: iOS builds require macOS with Xcode."
  echo "         This is a MANUAL CHECK owed on a Mac before release."
else
  dn build ios --debug --no-codesign
fi

cd "$ROOT"

# ── Done ──────────────────────────────────────────────────────────────────────

cat <<'SUMMARY'

✓ AUTOMATED LOCAL CHECKS PASSED

Still owed before a release, and not automatable:

  MANUAL DEVICE CHECKS   doc/manual-test-matrix.md
                         Run the example on a real iPhone and a real Android
                         device. The simulator and emulator have no cloud
                         providers, so they cannot exercise the cases that
                         actually break: Drive, iCloud, unknown sizes, very
                         large files, and a hot restart with the picker open.

  PUBLICATION REVIEW     the checklist in CONTRIBUTING.md and the README's
                         Limitations section. `dn plugin publish` is
                         irreversible and has no dry-run flag.
SUMMARY
