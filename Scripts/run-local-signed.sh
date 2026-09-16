#!/bin/zsh

set -euo pipefail

project_root=${0:A:h:h}

# The isolated shader lab uses the same signing identity and canonical build
# directory, without starting the API or replacing the main Pulso application.
if [[ "${1:-}" == "--onboarding-playground" ]]; then
    shift
    exec /bin/zsh "$project_root/Scripts/run-onboarding-playground-signed.sh" "$@"
fi

canonical_app=/tmp/pulso-derived-local/Build/Products/Debug/Pulso.app

"$project_root/Scripts/ensure-local-api.sh"
"$project_root/Scripts/build-local-signed.sh"

for pid in ${(f)$(pgrep -f '/Pulso\.app/Contents/MacOS/Pulso$' || true)}; do
    [ -n "$pid" ] || continue
    command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    if [[ "$command" == */Pulso.app/Contents/MacOS/Pulso ]]; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
done

for _ in {1..30}; do
    pgrep -f '/Pulso\.app/Contents/MacOS/Pulso$' >/dev/null || break
    sleep 0.1
done

open -n "$canonical_app"

for _ in {1..30}; do
    if pgrep -f '^/private/tmp/pulso-derived-local/Build/Products/Debug/Pulso\.app/Contents/MacOS/Pulso$' >/dev/null; then
        print "$canonical_app"
        exit 0
    fi
    sleep 0.1
done

print -u2 "Pulso did not start from the canonical signed build."
exit 1
