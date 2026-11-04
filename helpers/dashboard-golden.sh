#!/usr/bin/env bash
# The frontend tests that read the dashboard migration's golden files, as upstream runs
# them (pr-frontend-unit-tests.yml): `make generate-golden-files` in apps/dashboard writes
# the Go migration's and conversion's outputs (gitignored), then jest compares the
# frontend's transforms with them.
#
#   helpers/dashboard-golden.sh [target...]
#
# Targets are changed golden tests, which run alone; with none (a Go change, a frontend
# dependency's) all of them run. JEST_LIST=1 prints the tests it would run (jest.sh).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tests=(
    public/app/features/dashboard/api/ResponseTransformersToBackend.test.ts
    public/app/features/dashboard/state/DashboardMigratorToBackend.devDashboards.test.ts
    public/app/features/dashboard-scene/serialization/transformSaveModelV1ToV2.test.ts
    public/app/features/dashboard-scene/serialization/transformSaveModelV2ToV1.test.ts
    public/app/features/dashboard-scene/v2schema/dashboardV2Schema.corpus.test.ts
)
helpers="${GRAFANA_ROOT}/helpers"
targets=()
[[ $# -gt 0 ]] && while IFS= read -r t; do targets+=("${t}"); done < <(repo_paths "$@")

if [[ "${JEST_LIST:-}" == 1 ]]; then
    exec "${helpers}/jest.sh" . 1 1 "${tests[@]}" -- ${targets[@]+"${targets[@]}"}
fi
echo "🧪 generating the dashboard migration's golden files"
make -C apps/dashboard generate-golden-files
exec "${helpers}/jest.sh" . 1 1 "${tests[@]}" -- ${targets[@]+"${targets[@]}"}
