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

script_start="$(date +%s)"

log_phase() {
    local phase="$1" event="$2"
    shift 2
    local now
    now="$(date +%s)"
    if [[ $# -gt 0 ]]; then
        echo "[playwright] phase=${phase} event=${event} ts=${now} elapsed_s=$((now - script_start)) $*" >&2
    else
        echo "[playwright] phase=${phase} event=${event} ts=${now} elapsed_s=$((now - script_start))" >&2
    fi
}

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

# Keep only browser evidence and the server log, never its data, copied binaries,
# plugins or browser profiles. Each invocation owns its shard directory.
preserve_diagnostics() {
    local destination=".enact/state/diagnostics/grafana-e2e/shard-${shard_index}-$$"
    [[ -d "${work}/results" || -f "${work}/grafana-server.log" ]] || return 0
    mkdir -p "${destination}" || return
    if [[ -d "${work}/results" ]]; then
        cp -R "${work}/results" "${destination}/" || return
    fi
    if [[ -f "${work}/grafana-server.log" ]]; then
        cp "${work}/grafana-server.log" "${destination}/" || return
    fi
    echo "playwright.sh: failure diagnostics: ${destination}" >&2
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -f "${rundir}/pid" ]]; then
        kill "$(cat "${rundir}/pid")" 2>/dev/null || true
    fi
    if [[ -n "${server_pid}" ]]; then
        kill "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
    fi
    if [[ "${status}" -ne 0 ]]; then
        if ! preserve_diagnostics; then
            echo "playwright.sh: could not preserve failure diagnostics" >&2
        fi
    fi
    rm -rf "${work}" "${rundir}" || true
    exit "${status}"
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
    for path in bin/grafana public/build public/build-swagger/assets-manifest.json data/plugins-bundled; do
        [[ -e "${path}" ]] || missing+=("${path}")
    done
    # pnpm build also builds these standalone core plugins. Without their dist
    # metadata Grafana advertises a legacy core:plugin module the bundle lacks.
    local plugin artifact
    for plugin in azuremonitor grafana-testdata-datasource graphite; do
        for artifact in plugin.json module.js; do
            path="public/app/plugins/datasource/${plugin}/dist/${artifact}"
            [[ -f "${path}" ]] || missing+=("${path}")
        done
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
    local port build_start build_end server_start server_end
    port="$(allocate_port)"
    build_start="$(date +%s)"
    require_built
    build_end="$(date +%s)"
    log_phase require_built done "duration_s=$((build_end - build_start))"
    rm -rf "${rundir}"
    mkdir -p "$(dirname "${rundir}")"
    server_start="$(date +%s)"
    log_phase server_ready start "port=${port}"
    # start-server stops an image-renderer container with the host's docker: a missing socket
    # fails it at once, where an unresponsive daemon would hang the start.
    DOCKER_HOST="unix://${work}/no-docker.sock" PORT="${port}" GF_SERVER_HTTP_PORT="${port}" \
        GF_SERVER_ROOT_URL="http://127.0.0.1:${port}/" \
        RUNDIR="${rundir}" ./scripts/grafana-server/start-server >"${work}/grafana-server.log" 2>&1 &
    server_pid=$!
    for _ in $(seq 1 60); do
        if curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1; then
            server_end="$(date +%s)"
            log_phase server_ready done "port=${port} duration_s=$((server_end - server_start))"
            export GRAFANA_URL="http://127.0.0.1:${port}"
            return 0
        fi
        sleep 1
    done
    server_end="$(date +%s)"
    log_phase server_ready timeout "port=${port} duration_s=$((server_end - server_start))"
    cat "${work}/grafana-server.log" >&2 || true
    echo "playwright.sh: timed out waiting for grafana-server on port ${port}" >&2
    return 1
}

modules_yaml="missing"
if [[ -f node_modules/.modules.yaml ]]; then
    modules_yaml="present"
fi

# Direct invocation requires a prepared node install with all three:
#   1. ENACT_PREPARED names `node` (comma-separated token match, matching enact-core),
#   2. staged Playwright binary, package metadata, and pnpm .modules.yaml exist, and
#   3. installed @playwright/test version matches root package.json and .modules.yaml is
#      not older than package.json or pnpm-lock.yaml.
playwright_mode="pnpm-exec"
playwright_reason="unprepared"
check_direct_playwright() {
    local prepared_norm="${ENACT_PREPARED:-}"
    prepared_norm="${prepared_norm//[[:space:]]/}"
    if [[ ",${prepared_norm}," != *",node,"* ]]; then
        playwright_reason="unprepared"
        return 1
    fi
    if [[ ! -x node_modules/.bin/playwright || ! -f node_modules/@playwright/test/package.json || ! -f node_modules/.modules.yaml ]]; then
        playwright_reason="missing_artifacts"
        return 1
    fi
    if [[ ! -f package.json ]]; then
        playwright_reason="missing_package_json"
        return 1
    fi
    if [[ package.json -nt node_modules/.modules.yaml ]] || { [[ -f pnpm-lock.yaml ]] && [[ pnpm-lock.yaml -nt node_modules/.modules.yaml ]]; }; then
        playwright_reason="stale_modules_yaml"
        return 1
    fi
    local want_pw got_pw
    want_pw="$(jq -r '.devDependencies["@playwright/test"] // .dependencies["@playwright/test"] // empty' package.json 2>/dev/null || true)"
    got_pw="$(jq -r '.version // empty' node_modules/@playwright/test/package.json 2>/dev/null || true)"
    if [[ -z "${want_pw}" || -z "${got_pw}" || "${want_pw}" != "${got_pw}" ]]; then
        playwright_reason="version_mismatch"
        return 1
    fi
    playwright_reason="verified"
    return 0
}
if check_direct_playwright; then
    playwright_mode="direct"
fi
log_phase install_check done "prepared=${ENACT_PREPARED:-none} modules_yaml=${modules_yaml} mode=${playwright_mode} reason=${playwright_reason}"

if [[ -z "${GRAFANA_URL:-}" ]]; then
    if [[ "${all_unauthenticated}" -eq 1 || "${GRAFANA_E2E_SKIP_SERVER:-}" == "1" ]]; then
        export GRAFANA_URL="http://127.0.0.1:3001"
        log_phase server_ready skipped "reason=unauthenticated_or_skip_env"
    else
        ensure_server
    fi
else
    log_phase server_ready skipped "reason=external_grafana_url"
fi

live_cpus() {
    local cpus
    cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
    if [[ -r /sys/fs/cgroup/cpu.max ]]; then
        local quota period
        read -r quota period < /sys/fs/cgroup/cpu.max || true
        if [[ "${quota:-max}" != "max" && -n "${period:-}" && "${period}" -gt 0 ]]; then
            local cg_cpus=$(( (quota + period - 1) / period ))
            if [[ "${cg_cpus}" -gt 0 && "${cg_cpus}" -lt "${cpus}" ]]; then
                cpus="${cg_cpus}"
            fi
        fi
    fi
    echo "${cpus}"
}

pw_live_cpus="$(live_cpus)"
pw_reserved_cpus="${ENACT_WORKER_CPUS:-}"
pw_effective_cpus="${pw_live_cpus}"
if [[ "${pw_reserved_cpus}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    pw_reserved_int="${pw_reserved_cpus%%.*}"
    if [[ "${pw_reserved_int}" -gt 0 && "${pw_reserved_int}" -lt "${pw_effective_cpus}" ]]; then
        pw_effective_cpus="${pw_reserved_int}"
    fi
fi

pw_workers="${PLAYWRIGHT_WORKERS:-}"
if [[ -z "${pw_workers}" ]]; then
    if [[ "${pw_effective_cpus}" -le 4 ]]; then
        pw_workers=2
    fi
fi

args=(
    test
    --grep-invert @cloud-plugins
    --reporter=list
    "--output=${work}/results"
)
if [[ -n "${pw_workers}" ]]; then
    args+=("--workers=${pw_workers}")
fi
if [[ ${#targets[@]} -eq 0 && "${shard_total}" -gt 1 ]]; then
    args+=("--shard=${shard_index}/${shard_total}")
fi
if [[ "${all_unauthenticated}" -eq 1 ]]; then
    args+=(--project=unauthenticated)
fi
if [[ ${#targets[@]} -gt 0 ]]; then
    args+=("${targets[@]}")
fi

pw_start="$(date +%s)"
log_phase playwright_test start "mode=${playwright_mode} shard=${shard_index}/${shard_total} targets=${#targets[@]} workers=${pw_workers:-config} reserved_cpus=${pw_reserved_cpus:-none} live_cpus=${pw_live_cpus} effective_cpus=${pw_effective_cpus}"
pw_rc=0
if [[ "${playwright_mode}" == "direct" ]]; then
    # Use the staged root Playwright binary directly so pnpm never triggers a
    # redundant workspace install when node_modules is already linked.
    PATH="${PWD}/node_modules/.bin:${PATH}" \
        NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }-C @grafana-app/source" \
        ./node_modules/.bin/playwright "${args[@]}" || pw_rc=$?
else
    NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }-C @grafana-app/source" \
        pnpm exec playwright "${args[@]}" || pw_rc=$?
fi
pw_end="$(date +%s)"
log_phase playwright_test done "mode=${playwright_mode} status=${pw_rc} duration_s=$((pw_end - pw_start))"
exit "${pw_rc}"
