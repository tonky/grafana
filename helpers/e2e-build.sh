#!/usr/bin/env bash
# e2e:build, what every Playwright shard runs against, built once (the job's `outputs`;
# upstream's build-backend and build-frontend jobs): grafana-server (bin/grafana), the
# frontend bundle (public/build), standalone core plugin distributions (public/app/plugins/
# datasource/*/dist), the test plugins (e2e-playwright/test-plugins/*/dist) and
# the catalog plugins start-server links (data/plugins-bundled, a download).
set -euo pipefail
export pnpm_config_verify_deps_before_run=false
[[ -n "${ENACT_PNPM_STORE:-}" ]] && export pnpm_config_store_dir="${ENACT_PNPM_STORE}"

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

script_start="$(date +%s)"

run_phase() {
    local name="$1"
    shift
    local start end dur elapsed rc=0
    start="$(date +%s)"
    echo "[e2e-build] phase=${name} event=start ts=${start} elapsed_s=$((start - script_start))" >&2
    "$@" || rc=$?
    end="$(date +%s)"
    dur=$((end - start))
    elapsed=$((end - script_start))
    echo "[e2e-build] phase=${name} event=done status=${rc} ts=${end} duration_s=${dur} elapsed_s=${elapsed}" >&2
    return "${rc}"
}

modules_yaml="missing"
if [[ -f node_modules/.modules.yaml ]]; then
    modules_yaml="present"
fi
echo "[e2e-build] phase=install_check event=done ts=${script_start} prepared=${ENACT_PREPARED:-none} modules_yaml=${modules_yaml}" >&2

run_phase build-go make build-go
run_phase build-frontend pnpm run build
run_phase build-swagger pnpm run build:swagger
run_phase e2e-plugin-build pnpm run e2e:plugin:build
run_phase build-catalog-plugins-data make build-catalog-plugins-data

script_end="$(date +%s)"
echo "[e2e-build] phase=total event=done ts=${script_end} duration_s=$((script_end - script_start))" >&2
