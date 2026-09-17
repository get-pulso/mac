#!/bin/zsh

set -euo pipefail

project_root=${0:A:h:h}
web_root=${project_root:h}/web
api_url=http://localhost:3001/api/native/config
log_path=/tmp/firstlight-web.log
launch_label=sh.firstlight.local-api
db_container=firstlight-dev-db

api_is_ready() {
    local response
    response=$(curl -fsS --connect-timeout 1 --max-time 3 "$api_url" 2>/dev/null) || return 1
    grep -Eq '"publishableKey"[[:space:]]*:[[:space:]]*"pk_(test|live)_' <<<"$response"
}

database_is_ready() {
    docker exec "$db_container" pg_isready -q -h 127.0.0.1 -U postgres 2>/dev/null
}

# web/.env points the API at the development database, a Postgres container
# on the image production runs. Docker does not start at login here.
ensure_database() {
    if ! command -v docker >/dev/null; then
        print -u2 "Docker is missing; the Firstlight development database runs in it."
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        open -ga Docker
        # A deadline, not a count: `docker info` itself can take seconds while
        # the engine is coming up.
        local deadline=$(( $(date +%s) + 180 ))
        until docker info >/dev/null 2>&1; do
            if (( $(date +%s) >= deadline )); then
                print -u2 "Docker did not start within 3 minutes; the Firstlight development database runs in it."
                exit 1
            fi
            sleep 1
        done
    fi
    if ! docker container inspect "$db_container" >/dev/null 2>&1; then
        print -u2 "Container $db_container is missing; web/README.md explains how to recreate it."
        exit 1
    fi
    if database_is_ready; then
        return
    fi
    docker start "$db_container" >/dev/null
    for _ in {1..120}; do
        if database_is_ready; then
            return
        fi
        sleep 0.25
    done
    print -u2 "Database $db_container did not become ready."
    exit 1
}

ensure_database

if api_is_ready; then
    exit 0
fi

listener_pid=$(lsof -nP -tiTCP:3001 -sTCP:LISTEN 2>/dev/null | head -n 1 || true)
if [ -n "$listener_pid" ]; then
    for _ in {1..120}; do
        if api_is_ready; then
            exit 0
        fi
        sleep 0.25
    done
    print -u2 "Port 3001 is owned by an unhealthy process ($listener_pid)."
    exit 1
fi

if [ ! -d "$web_root/node_modules" ]; then
    print -u2 "Firstlight API dependencies are missing in $web_root."
    exit 1
fi

launchctl remove "$launch_label" 2>/dev/null || true
launch_command="cd ${(q)web_root} && NEXT_DIST_DIR=.next-firstlight-local exec pnpm exec next dev --turbopack -p 3001 >>${(q)log_path} 2>&1"
launchctl submit -l "$launch_label" -- /bin/zsh -lc "$launch_command"

for _ in {1..120}; do
    if api_is_ready; then
        exit 0
    fi
    sleep 0.25
done

print -u2 "Firstlight API did not become ready on port 3001."
tail -n 30 "$log_path" >&2 || true
exit 1
