#!/usr/bin/env bash
# Runs one Go suite's packages as upstream CI does (backend-unit-tests.yml,
# pr-test-integration.yml), from the repository root in workspace mode.
#
#   helpers/go-test.sh <base|backend|integration> <shard index> <shard total> [target...]
#
# Targets are import paths (go-packages.sh selects them) or changed _test.go files, which
# stand for their package; enact has already split them across the shards. With none (a
# whole-suite run) this shard takes its share of every package of the suite.
#
# integration runs `-run ^TestIntegration` against GRAFANA_TEST_DB (sqlite by default). The
# suites' databases have fixed names (grafanatest, grafana_tests), so shards on one host
# take turns at a database server; CI's shards each have their own. Each runs with
# -count=1: the suites read their database from the environment, which Go's test cache
# doesn't key on, so a cached result of one database would stand in for another's. Tests
# that start containers themselves (the remote-Alertmanager scenarios, grafana/e2e) are
# skipped by name and named on stderr: nothing here runs Docker. Packages whose every test
# shares a container go-packages.sh leaves out.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

suite="${1:?usage: go-test.sh <base|backend|integration> <shard index> <shard total> [target...]}"
shard_index="${2:?shard index}"
shard_total="${3:?shard total}"
shift 3

module="$(awk '$1 == "module" {print $2; exit}' go.mod)"
packages=()
tests=()
if [[ $# -gt 0 ]]; then
    while IFS= read -r target; do
        case "${target}" in
            *::*)
                dir="${target%%::*}"
                dir="${dir#./}"
                [[ "${dir}" == "." || -z "${dir}" ]] && packages+=("${module}") || packages+=("${module}/${dir}")
                tname="${target#*::}"
                tname="${tname%%/*}"
                tests+=("${tname}")
                ;;
            *.go)
                dir="$(dirname "${target}")"
                [[ "${dir}" == "." ]] && packages+=("${module}") || packages+=("${module}/${dir}")
                ;;
            *) packages+=("${target}") ;;
        esac
    done < <(for t in "$@"; do case "${t}" in *.go) repo_paths "${t}" ;; *) echo "${t}" ;; esac; done | sort -u)
else
    # The suite's packages, listed in full first: a listing that fails or finds nothing fails
    # the shard (read through `< <(...)`, its failure once left an empty list that passed).
    suite_packages="$(helpers/go-packages.sh "${suite}")"
    if [[ -z "${suite_packages}" ]]; then
        echo "go-test.sh: go-packages.sh listed no ${suite} package" >&2
        exit 1
    fi
    while IFS= read -r pkg; do packages+=("${pkg}"); done < <(echo "${suite_packages}" \
        | awk -v shard="${shard_index}" -v total="${shard_total}" '(NR - 1) % total == shard - 1')
    if [[ ${#packages[@]} -eq 0 ]]; then
        # More shards than packages: partitioning left this one none. It ran nothing.
        echo "go-test.sh: shard ${shard_index}/${shard_total}: no ${suite} package after partitioning $(echo "${suite_packages}" | wc -l | tr -d ' ') (ran nothing)"
        exit 0
    fi
fi
# shellcheck disable=SC2207
packages=($(printf '%s\n' "${packages[@]}" | sort -u))
run_pattern=""
if [[ ${#tests[@]} -gt 0 ]]; then
    run_pattern="^($(printf '%s\n' "${tests[@]}" | sort -u | paste -sd '|' -))\$"
fi
label="${suite}"
[[ "${suite}" == integration ]] && label="${suite} on ${GRAFANA_TEST_DB:-sqlite}"
echo "🧪 ${label}: ${#packages[@]} package(s), shard ${shard_index}/${shard_total}"

# The TestIntegration functions whose own body starts a container scenario (grafana/e2e's
# NewScenario, through the alerting suite's NewAlertmanagerScenario).
docker_tests() {
    local pkg dir f files=()
    for pkg in "${packages[@]}"; do
        dir="${pkg#"${module}"}"
        dir="${dir#/}"
        dir="${dir:-.}"
        for f in "${dir}"/*_test.go; do
            [[ -f "${f}" ]] && files+=("${f}")
        done
    done
    [[ ${#files[@]} -gt 0 ]] || return 0
    { grep -lsE 'NewAlertmanagerScenario|e2e\.NewScenario' "${files[@]}" 2>/dev/null || true; } | while IFS= read -r file; do
        awk '
            /^func / { name = ($0 ~ /^func TestIntegration[A-Za-z0-9_]*\(/) ? $2 : ""; sub(/\(.*/, "", name) }
            name != "" && /NewAlertmanagerScenario|e2e\.NewScenario/ { print name; name = "" }
        ' "${file}"
    done | sort -u
}

case "${suite}" in
    base | backend)
        extra=()
        [[ -n "${ENACT_FOOTPRINT_DIR:-}" || -n "${run_pattern}" ]] && extra+=(-count=1)
        [[ -n "${run_pattern}" ]] && extra+=(-run "${run_pattern}")
        exec go test -vet=off -short -timeout=30m ${extra[@]+"${extra[@]}"} "${packages[@]}"
        ;;
    integration)
        db="${GRAFANA_TEST_DB:-sqlite}"
        run_re="${run_pattern:-^TestIntegration}"
        skip="$(docker_tests)"
        if [[ -n "${skip}" ]]; then
            echo "go-test.sh: $(echo "${skip}" | wc -l | tr -d ' ') integration test(s) start a Docker container, skipped: $(echo "${skip}" | paste -sd ' ' -)" >&2
            skip="^($(echo "${skip}" | paste -sd '|' -))\$"
        else
            skip='^$'
        fi
        if [[ "${db}" == sqlite ]]; then
            exec go test -vet=off -count=1 -timeout=12m -run "${run_re}" -skip "${skip}" "${packages[@]}"
        fi
        # Compile first, as upstream does, so the turn at the database is the tests' alone.
        go test -vet=off -run='^$' "${packages[@]}" >/dev/null
        # One lock per database server (its port), host-wide. /tmp, not TMPDIR: callers export
        # different ones. The kernel releases a flock with its holder, however it dies: a killed
        # Linux job is SIGKILLed (bwrap's --die-with-parent), so no cleanup trap runs, and a
        # lock directory's stale-pid takeover trusts a pid the host may have reused. flock is
        # the env's.
        locks="/tmp/grafana-locks-$(id -u)"
        mkdir -p "${locks}"
        case "${db}" in
            postgres) port="${POSTGRES_PORT:-}" ;;
            mysql) port="${MYSQL_PORT:-}" ;;
            *) port="" ;;
        esac
        exec 9>>"${locks}/${db}-tests-${port}.flock"
        flock 9
        # Held by this script alone: a process the tests leave running doesn't keep it.
        go test -vet=off -count=1 -p=1 -timeout=12m -run "${run_re}" -skip "${skip}" "${packages[@]}" 9>&-
        ;;
    *)
        echo "unknown suite: ${suite}" >&2
        exit 2
        ;;
esac
