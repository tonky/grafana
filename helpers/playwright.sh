#!/usr/bin/env bash
# Runs the Playwright E2E suite (or selected specs) from the repository root.
#
#   helpers/playwright.sh <shard index> <shard total> [target...]
#
# When all targets are under e2e-playwright/unauthenticated/ (such as the store browser
# readiness probe) or GRAFANA_E2E_SKIP_SERVER=1 is set, Playwright runs directly without
# starting grafana-server. Otherwise, if GRAFANA_URL is not already set, this helper
# launches grafana-server from what e2e:build built (helpers/e2e-build.sh, the job's
# outputs) on an ephemeral localhost port, in a run directory of its own, and waits for
# /api/health before invoking Playwright.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

shard_index="${1:-1}"
shard_total="${2:-1}"
shift 2 || true

targets=()
for arg in "$@"; do
    arg="${arg#./}"
    arg="${arg#../}"
    case "${arg}" in
        e2e-playwright/*) targets+=("${arg}") ;;
        *) targets+=("e2e-playwright/${arg}") ;;
    esac
done

all_unauthenticated=0
if [[ ${#targets[@]} -gt 0 ]]; then
    all_unauthenticated=1
    for t in "${targets[@]}"; do
        if [[ "${t}" != e2e-playwright/unauthenticated/* ]]; then
            all_unauthenticated=0
            break
        fi
    done
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/grafana-e2e.XXXXXX")"
TMPDIR="${work}"
export TMPDIR
# start-server's run directory (RUNDIR, relative to the repository root: it is also its
# HOME_PATH under $PWD), one per shard: its default, scripts/grafana-server/tmp, is one
# directory every shard on the host would share, each start wiping the others' server.
rundir=".enact/state/grafana-e2e/server-${shard_index}-$$"
server_pid=""

cleanup() {
    if [[ -f "${rundir}/pid" ]]; then
        kill "$(cat "${rundir}/pid")" 2>/dev/null || true
    fi
    if [[ -n "${server_pid}" ]]; then
        kill "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
    fi
    rm -rf "${work}" "${rundir}"
}
trap cleanup EXIT

allocate_port() {
    node -e '
        const s = require("net").createServer();
        s.listen(0, "127.0.0.1", () => {
            console.log(s.address().port);
            s.close();
        });
    '
}

# What e2e:build builds (this component's `build` job, which `test` needs): enact builds it
# once per run, or restores it in CI, before any shard starts.
require_built() {
    local missing=()
    for path in bin/grafana public/build data/plugins-bundled; do
        [[ -e "${path}" ]] || missing+=("${path}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "playwright.sh: not built: ${missing[*]}; run e2e:build (helpers/e2e-build.sh) first" >&2
        return 1
    fi
    # start-server runs `make build-catalog-plugins-data`, whose stamp is older than the
    # Makefile and the scripts it depends on in a checkout made after the build (a restore):
    # make would download the plugins again, under every shard's running server.
    touch data/plugins-bundled/.platform-*.stamp
}

ensure_server() {
    local port
    port="$(allocate_port)"
    require_built
    rm -rf "${rundir}"
    mkdir -p "$(dirname "${rundir}")"
    # start-server stops an image-renderer container with the host's docker: a missing socket
    # fails it at once, where an unresponsive daemon would hang the start.
    DOCKER_HOST="unix://${work}/no-docker.sock" PORT="${port}" GF_SERVER_HTTP_PORT="${port}" \
        RUNDIR="${rundir}" ./scripts/grafana-server/start-server >"${work}/grafana-server.log" 2>&1 &
    server_pid=$!
    for _ in $(seq 1 60); do
        if curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1; then
            export GRAFANA_URL="http://127.0.0.1:${port}"
            return 0
        fi
        sleep 1
    done
    cat "${work}/grafana-server.log" >&2 || true
    echo "playwright.sh: timed out waiting for grafana-server on port ${port}" >&2
    return 1
}

if [[ -z "${GRAFANA_URL:-}" ]]; then
    if [[ "${all_unauthenticated}" -eq 1 || "${GRAFANA_E2E_SKIP_SERVER:-}" == "1" ]]; then
        export GRAFANA_URL="http://127.0.0.1:3001"
    else
        ensure_server
    fi
fi

args=(
    playwright test
    --grep-invert @cloud-plugins
    --reporter=list
    "--output=${work}/results"
)
if [[ ${#targets[@]} -eq 0 && "${shard_total}" -gt 1 ]]; then
    args+=("--shard=${shard_index}/${shard_total}")
fi
if [[ "${all_unauthenticated}" -eq 1 ]]; then
    args+=(--project=unauthenticated)
fi
if [[ ${#targets[@]} -gt 0 ]]; then
    args+=("${targets[@]}")
fi

NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }-C @grafana-app/source" yarn "${args[@]}"
