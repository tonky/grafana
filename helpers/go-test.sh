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
# Packages a target names whole (an import path, a _test.go file): they run every test. A
# package named only through `<dir>::<Test>` targets runs those tests alone.
whole=()
declare -A pkg_tests=()
has_named=0
if [[ $# -gt 0 ]]; then
    while IFS= read -r target; do
        case "${target}" in
            *::*)
                dir="${target%%::*}"
                dir="${dir#./}"
                [[ "${dir}" == "." || -z "${dir}" ]] && pkg="${module}" || pkg="${module}/${dir}"
                packages+=("${pkg}")
                tname="${target#*::}"
                tname="${tname%%/*}"
                pkg_tests["${pkg}"]+="${tname}"$'\n'
                has_named=1
                ;;
            *.go)
                dir="$(dirname "${target}")"
                [[ "${dir}" == "." ]] && pkg="${module}" || pkg="${module}/${dir}"
                packages+=("${pkg}")
                whole+=("${pkg}")
                ;;
            *) packages+=("${target}"); whole+=("${target}") ;;
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
declare -A in_whole=()
if [[ ${#whole[@]} -gt 0 ]]; then
    # shellcheck disable=SC2207
    whole=($(printf '%s\n' "${whole[@]}" | sort -u))
    for pkg in "${whole[@]}"; do
        in_whole["${pkg}"]=1
        echo "# [enact:go-whole-package] ${pkg}"
    done
fi
partial=()
for pkg in "${packages[@]}"; do
    [[ -n "${in_whole[${pkg}]:-}" ]] || partial+=("${pkg}")
done

# Linux caps any single argv string at MAX_ARG_STRLEN (131072 bytes). Large collapsed shards
# can carry thousands of `<dir>::<Test>` targets whose combined `-run` regex exceeds 128 KiB
# (`E2BIG`). Group named tests by partial package and chunk invocations under 60 KiB.
MAX_RUN_ARG_BYTES="${GRAFANA_GO_MAX_RUN_ARG_BYTES:-60000}"

run_named_chunks() {
    local lock_fd="${1}"
    shift
    local base_cmd=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        base_cmd+=("$1")
        shift
    done
    shift # consume "--"
    local chunk_pkgs=()
    local chunk_names=""
    local chunk_bytes=4 # "^()$"
    local overall_status=0

    flush_chunk() {
        [[ ${#chunk_pkgs[@]} -gt 0 ]] || return 0
        local pat
        pat="^($(printf '%s' "${chunk_names}" | sort -u | paste -sd '|' -))\$"
        if [[ "${lock_fd}" == "9" ]]; then
            "${base_cmd[@]}" -run "${pat}" "${chunk_pkgs[@]}" 9>&- || overall_status=$?
        else
            "${base_cmd[@]}" -run "${pat}" "${chunk_pkgs[@]}" || overall_status=$?
        fi
        chunk_pkgs=()
        chunk_names=""
        chunk_bytes=4
    }

    local pkg raw uniq_names name add_bytes
    for pkg in "$@"; do
        raw="${pkg_tests[${pkg}]:-}"
        [[ -n "${raw}" ]] || continue
        uniq_names="$(printf '%s' "${raw}" | sort -u)"
        add_bytes=$(( ${#uniq_names} + 1 ))
        if [[ ${add_bytes} -gt ${MAX_RUN_ARG_BYTES} ]]; then
            # Single package exceeds budget: split its test names into separate `-run` chunks.
            flush_chunk
            local sub_names="" sub_bytes=4
            while IFS= read -r name; do
                [[ -n "${name}" ]] || continue
                if [[ -n "${sub_names}" && $(( sub_bytes + ${#name} + 1 )) -gt ${MAX_RUN_ARG_BYTES} ]]; then
                    chunk_pkgs=("${pkg}")
                    chunk_names="${sub_names}"
                    flush_chunk
                    sub_names=""
                    sub_bytes=4
                fi
                sub_names+="${name}"$'\n'
                sub_bytes=$(( sub_bytes + ${#name} + 1 ))
            done <<< "${uniq_names}"
            if [[ -n "${sub_names}" ]]; then
                chunk_pkgs=("${pkg}")
                chunk_names="${sub_names}"
                flush_chunk
            fi
            continue
        fi
        if [[ ${#chunk_pkgs[@]} -gt 0 && $(( chunk_bytes + add_bytes )) -gt ${MAX_RUN_ARG_BYTES} ]]; then
            flush_chunk
        fi
        chunk_pkgs+=("${pkg}")
        chunk_names+="${uniq_names}"$'\n'
        chunk_bytes=$(( chunk_bytes + add_bytes ))
    done
    flush_chunk
    return "${overall_status}"
}

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
    { grep -lsE 'NewAlertmanagerScenario|e2e\.NewScenario|StartPublicGitRemote' "${files[@]}" 2>/dev/null || true; } | while IFS= read -r file; do
        awk '
            /^func / { name = ($0 ~ /^func TestIntegration[A-Za-z0-9_]*\(/) ? $2 : ""; sub(/\(.*/, "", name) }
            name != "" && /NewAlertmanagerScenario|e2e\.NewScenario|StartPublicGitRemote/ { print name; name = "" }
        ' "${file}"
    done | sort -u
}

case "${suite}" in
    base | backend)
        extra=()
        [[ -n "${ENACT_FOOTPRINT_DIR:-}" || "${has_named}" -eq 1 ]] && extra+=(-count=1)
        # The recall harness reads each test's own outcome (`--- PASS: TestX`).
        [[ -n "${ENACT_TEST_VERBOSE:-}" ]] && extra+=(-v)
        if [[ "${has_named}" -eq 1 ]]; then
            # A shard with named targets (possibly mixed with whole-package targets): run
            # whole-selected packages without `-run`, and run named-only packages in argv-safe
            # chunks so `-run` never exceeds Linux's 128 KiB MAX_ARG_STRLEN.
            status=0
            if [[ ${#whole[@]} -gt 0 ]]; then
                go test -vet=off -short -timeout=30m ${extra[@]+"${extra[@]}"} "${whole[@]}" || status=$?
            fi
            if [[ ${#partial[@]} -gt 0 ]]; then
                run_named_chunks "" go test -vet=off -short -timeout=30m ${extra[@]+"${extra[@]}"} -- "${partial[@]}" || status=$?
            fi
            exit "${status}"
        fi
        exec go test -vet=off -short -timeout=30m ${extra[@]+"${extra[@]}"} "${packages[@]}"
        ;;
    integration)
        db="${GRAFANA_TEST_DB:-sqlite}"
        # enve.cue's PGVECTOR_TEST_DB names the postgres service's vector database, which only
        # the postgres suite starts: elsewhere the pgvector tests (resource's shared vector
        # store) would dial a server that isn't there instead of skipping.
        [[ "${db}" == postgres ]] || unset PGVECTOR_TEST_DB
        skip="$(docker_tests)"
        if [[ -n "${skip}" ]]; then
            echo "go-test.sh: $(echo "${skip}" | wc -l | tr -d ' ') integration test(s) start a Docker container, skipped: $(echo "${skip}" | paste -sd ' ' -)" >&2
            skip="^($(echo "${skip}" | paste -sd '|' -))\$"
        else
            skip='^$'
        fi
        run_integration() {
            local lock_fd="${1}"
            shift
            if [[ "${has_named}" -eq 1 ]]; then
                # A shard with named targets (possibly mixed with whole-package targets): run
                # whole-selected packages with `^TestIntegration` and named-only packages in
                # argv-safe chunks so `-run` never exceeds Linux's 128 KiB MAX_ARG_STRLEN.
                local status=0
                if [[ ${#whole[@]} -gt 0 ]]; then
                    if [[ "${lock_fd}" == "9" ]]; then
                        go test -vet=off -count=1 "$@" ${ENACT_TEST_VERBOSE:+-v} -timeout=12m -run '^TestIntegration' -skip "${skip}" "${whole[@]}" 9>&- || status=$?
                    else
                        go test -vet=off -count=1 "$@" ${ENACT_TEST_VERBOSE:+-v} -timeout=12m -run '^TestIntegration' -skip "${skip}" "${whole[@]}" || status=$?
                    fi
                fi
                if [[ ${#partial[@]} -gt 0 ]]; then
                    run_named_chunks "${lock_fd}" go test -vet=off -count=1 "$@" ${ENACT_TEST_VERBOSE:+-v} -timeout=12m -skip "${skip}" -- "${partial[@]}" || status=$?
                fi
                return "${status}"
            fi
            if [[ "${lock_fd}" == "9" ]]; then
                go test -vet=off -count=1 "$@" ${ENACT_TEST_VERBOSE:+-v} -timeout=12m -run '^TestIntegration' -skip "${skip}" "${packages[@]}" 9>&-
            else
                exec go test -vet=off -count=1 "$@" ${ENACT_TEST_VERBOSE:+-v} -timeout=12m -run '^TestIntegration' -skip "${skip}" "${packages[@]}"
            fi
        }
        if [[ "${db}" == sqlite ]]; then
            run_integration ""
            exit $?
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
        run_integration "9" -p=1
        ;;
    *)
        echo "unknown suite: ${suite}" >&2
        exit 2
        ;;
esac
