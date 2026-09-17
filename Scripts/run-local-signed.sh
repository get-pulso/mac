#!/bin/zsh

set -euo pipefail

project_root=${0:A:h:h}

# The isolated shader lab uses the same signing identity and canonical build
# directory, without starting the API or replacing the main Firstlight application.
if [[ "${1:-}" == "--onboarding-playground" ]]; then
    shift
    exec /bin/zsh "$project_root/Scripts/run-onboarding-playground-signed.sh" "$@"
fi

canonical_app=/tmp/firstlight-derived-local/Build/Products/Debug/Firstlight.app
canonical_executable=/private/tmp/firstlight-derived-local/Build/Products/Debug/Firstlight.app/Contents/MacOS/Firstlight
canonical_process_pattern='^/private/tmp/firstlight-derived-local/Build/Products/Debug/Firstlight\.app/Contents/MacOS/Firstlight($| )'

"$project_root/Scripts/ensure-local-api.sh"
"$project_root/Scripts/build-local-signed.sh"

# Replace only this local build. The installed Firstlight is a separate
# application, signed in as its own account: closing it is not ours to do.
for pid in ${(f)$(pgrep -f "$canonical_process_pattern" || true)}; do
    [ -n "$pid" ] || continue
    command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    if [[ "$command" == "$canonical_executable" || "$command" == "$canonical_executable "* ]]; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
done

for _ in {1..30}; do
    pgrep -f "$canonical_process_pattern" >/dev/null || break
    sleep 0.1
done

# LaunchServices may briefly retain the terminated process and return -600.
# Retry the same signed bundle, never another build or an unsigned executable.
launch_local_copy() {
    if (( $# > 0 )); then
        open -n "$canonical_app" --args "$@"
    else
        open -n "$canonical_app"
    fi
}
for launch_attempt in {1..3}; do
    if launch_local_copy "$@"; then break; fi
    sleep 1
    if pgrep -f "$canonical_process_pattern" >/dev/null; then
        break
    fi
done

for _ in {1..30}; do
    if pgrep -f "$canonical_process_pattern" >/dev/null; then
        print "$canonical_app"
        exit 0
    fi
    sleep 0.1
done

print -u2 "Firstlight did not start from the canonical signed build."
exit 1
