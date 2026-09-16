#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h:h}/playground/onboarding-shader
derived_data_path=/tmp/pulso-derived-local
signing_identity="Developer ID Application: 21st Labs Inc. (25UG4QYN9F)"
canonical_app="$derived_data_path/Playground/Products/Debug/PulsoOnboardingPlayground.app"
build_lock=/tmp/pulso-local-build.lock

if ! mkdir "$build_lock" 2>/dev/null; then
    print -u2 "Another canonical Pulso build is already running."
    exit 1
fi
trap 'rmdir "$build_lock" 2>/dev/null || true' EXIT

if ! security find-identity -v -p codesigning | rg -F "$signing_identity" >/dev/null; then
    print -u2 "Missing signing identity: $signing_identity"
    exit 1
fi

cd "$project_root"
xcodegen generate
xcodebuild -project PulsoOnboardingPlayground.xcodeproj \
    -scheme PulsoOnboardingPlayground -configuration Debug \
    -derivedDataPath "$derived_data_path" \
    "SYMROOT=$derived_data_path/Playground/Products" \
    "OBJROOT=$derived_data_path/Playground/Intermediates" \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=25UG4QYN9F \
    "CODE_SIGN_IDENTITY=$signing_identity" "OTHER_CODE_SIGN_FLAGS=--timestamp=none" build

signing_details=$(codesign -dv --verbose=4 "$canonical_app" 2>&1)
if ! rg -F "Authority=$signing_identity" <<<"$signing_details" >/dev/null ||
   ! rg -F "TeamIdentifier=25UG4QYN9F" <<<"$signing_details" >/dev/null; then
    print -u2 "Playground failed Developer ID verification."
    exit 1
fi
codesign --verify --deep --strict "$canonical_app"
rmdir "$build_lock"
trap - EXIT

if [[ "${1:-}" == "--verify-shader" ]]; then
    exec "$canonical_app/Contents/MacOS/PulsoOnboardingPlayground" "$@"
fi

# Replace only the lab, never the signed-in Pulso application.
playground_process_pattern='/PulsoOnboardingPlayground[.]app/Contents/MacOS/PulsoOnboardingPlayground([[:space:]]|$)'
for pid in ${(f)$(pgrep -f "$playground_process_pattern" || true)}; do
    [[ -n "$pid" ]] || continue
    command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    if [[ "$command" == */PulsoOnboardingPlayground.app/Contents/MacOS/PulsoOnboardingPlayground ]] ||
       [[ "$command" == */PulsoOnboardingPlayground.app/Contents/MacOS/PulsoOnboardingPlayground\ * ]]; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
done
for _ in {1..30}; do
    pgrep -f "$playground_process_pattern" >/dev/null || break
    sleep 0.1
done
if pgrep -f "$playground_process_pattern" >/dev/null; then
    print -u2 "The previous shader playground is still running."
    exit 1
fi
if [[ "${1:-}" == "--verify-window" ]]; then
    exec "$canonical_app/Contents/MacOS/PulsoOnboardingPlayground" "$@"
fi
open -n "$canonical_app" --args "$@"
print "$canonical_app"
