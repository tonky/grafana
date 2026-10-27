#!/usr/bin/env bash
# Runs one component's jest tests as upstream CI does (pr-frontend-unit-tests.yml): the
# root jest project (jest.config.js: public/app, packages/*, ...) or a decoupled plugin's
# own (`yarn run test:ci` in public/app/plugins/datasource/*).
#
#   helpers/jest.sh <project> <shard index> <shard total> <tests>... -- [target...]
#
# <project> is the directory holding the jest config, <tests> the directories or test files
# that are the component's; a `!`-prefixed one is another component's and left out.
# Targets are the change's files: jest runs the component's tests
# that import them (`--findRelatedTests`, jest's own module graph), and a changed test
# file is its own. enact has split them across the shards already. With none (a
# whole-suite run) this shard takes its share of the component's tests (`--shard`).
#
# jest's graph stops at a workspace package (`@grafana/data` resolves through
# node_modules), so a change in another component's package must not reach here as a
# target: the components' target rules match their own files only, and a dependency's
# change runs the suite whole.
#
# A run that tests nothing fails (jest's default): targets no test relates to, or a component
# with no test. Only a whole-suite shard past the first may draw no file (more shards than
# test files; jest's first shard always draws one) and passes, saying so.
#
# JEST_LIST=1 prints the test files the run would take instead of running them.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

project="$(repo_paths "${1:?usage: jest.sh <project> <shard index> <shard total> <tests>... -- [target...]}")"
shard_index="${2:?shard index}"
shard_total="${3:?shard total}"
shift 3
tests=()
while [[ $# -gt 0 && "$1" != "--" ]]; do tests+=("$1"); shift; done
[[ $# -gt 0 ]] && shift
[[ ${#tests[@]} -gt 0 ]] || { echo "jest.sh: no test directory" >&2; exit 2; }

# Paths from the project's directory, where jest runs.
from_project() {
    repo_paths "$@" | awk -v p="${project}" '
        p == "." { print; next }
        index($0, p "/") == 1 { print substr($0, length(p) + 2); next }
        $0 == p { print "."; next }
        { print "<outside>" $0 }'
}

included=()
excluded=()
for t in "${tests[@]}"; do
    case "${t}" in '!'*) excluded+=("${t#!}") ;; *) included+=("${t}") ;; esac
done
[[ ${#included[@]} -gt 0 ]] || { echo "jest.sh: no test directory" >&2; exit 2; }

targets=()
if [[ $# -gt 0 ]]; then
    while IFS= read -r target; do
        [[ "${target}" == "<outside>"* ]] && { echo "jest.sh: ${target#<outside>} is outside ${project}" >&2; exit 2; }
        targets+=("${target}")
    done < <(from_project "$@")
fi

cd "${project}"

# The regex jest-filter.cjs matches jest's absolute (resolved) test paths with: the project's
# directory, then one alternative per test path (a directory matches what lies under it, a
# file itself), less the excluded ones. `.`, the project's own directory (a decoupled
# project's whole suite), matches every path under it.
escape() { sed -e 's|[.[\*^$()+?{}|]|\\&|g'; }
alternatives() {
    local path alts=()
    while IFS= read -r path; do
        path="${path#./}"
        case "${path}" in
            .) return 0 ;;
            *.ts | *.tsx | *.js | *.jsx) alts+=("$(escape <<<"${path}")\$") ;;
            *) alts+=("$(escape <<<"${path}")/") ;;
        esac
    done < <(from_project "$@")
    local IFS='|'
    echo "(${alts[*]})"
}
base="$(pwd -P | escape)/"
pattern="${base}$(alternatives "${included[@]}")"
if [[ ${#excluded[@]} -gt 0 ]]; then
    pattern="(?!${base}$(alternatives "${excluded[@]}"))${pattern}"
fi
export JEST_PATHS="^${pattern}"
args=(--ci "--maxWorkers=${ENACT_SHARD_WORKERS:-50%}" "--filter=${GRAFANA_ROOT}/helpers/jest-filter.cjs")
[[ "${JEST_LIST:-}" == 1 ]] && args+=(--listTests)
if [[ ${#targets[@]} -gt 0 ]]; then
    echo "🧪 jest (${project}): tests related to ${#targets[@]} file(s)" >&2
    # Recording: each target traced alone; jest-attribution.cjs tells enact the tests it
    # skipped (the trace can't), so their footprints land marked as skipped here.
    if [[ -n "${ENACT_FOOTPRINT_DIR:-}" && -z "${ENACT_FOOTPRINT_TARGETS:-}" && "$(uname -s)" == Linux ]]; then
        export TMPDIR="${ENACT_FOOTPRINT_DIR}/jest-cache"
        mkdir -p "${TMPDIR}"
        yarn jest "${args[@]}" --listTests >/dev/null || true
        status=0
        n=0
        for target in "${targets[@]}"; do
            n=$((n + 1))
            rel_target="${target#./}"
            [[ "${project}" == "." ]] || rel_target="${project}/${rel_target}"
            "${ENACT_EXE:-enact}" trace run --outcomes --shared-tmpdir --no-fingerprint --node-functions \
                --reach-file "${ENACT_FOOTPRINT_DIR}/jest-traced-${n}.json" \
                -t "${rel_target}" -- \
                yarn jest "${args[@]}" --reporters=default "--reporters=${GRAFANA_ROOT}/helpers/jest-attribution.cjs" \
                --passWithNoTests --runTestsByPath "${target}" || status=1
        done
        exit "${status}"
    fi
    exec yarn jest "${args[@]}" --findRelatedTests "${targets[@]}"
fi
echo "🧪 jest (${project}): ${tests[*]}, shard ${shard_index}/${shard_total}" >&2
if [[ "${shard_index}" -gt 1 ]]; then
    echo "jest.sh: shard ${shard_index}/${shard_total} may draw no test file (more shards than files): jest then passes it, running nothing" >&2
    args+=(--passWithNoTests)
fi
exec yarn jest "${args[@]}" "--shard=${shard_index}/${shard_total}"
