#!/usr/bin/env bash
# The tests a jest component's change selects (its target_scope rule command, run when enact
# plans): the component's tests jest relates to the changed files, by jest's own module
# graph (`jest --listTests --findRelatedTests`, through jest.sh, so the selection is what the
# run takes). A file no test imports selects none: no test of the component can tell its
# change, and the job is left out instead of failing on targets that test nothing (a core
# plugin's plugin.json, which the Go backend reads and its suites select; the API specs
# under public/, which the API docs page fetches by URL).
#
#   helpers/jest-related.sh <project> <tests>... -- <changed file>...
#
# <project> and <tests> are the component's jest.sh arguments, the changed files
# repository-relative (enact's {changed_files}). Prints one repository-relative test file
# per line.
#
# jest needs the yarn workspace installed, so the components' target_scope selects in the
# job (`select_in_job`): enact runs this after the job's prepare, never in CI's detect job,
# which installs nothing. Without node_modules there is no graph to ask, and it fails (the
# job then runs its suite whole).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

args=()
while [[ $# -gt 0 && "$1" != "--" ]]; do args+=("$1"); shift; done
[[ $# -gt 0 ]] && shift
[[ ${#args[@]} -ge 2 ]] || { echo "usage: jest-related.sh <project> <tests>... -- <changed file>..." >&2; exit 2; }
[[ $# -gt 0 ]] || exit 0

if [[ ! -d node_modules/jest ]]; then
    echo "jest-related.sh: no node_modules/jest: install the yarn workspace first" >&2
    exit 1
fi

# jest prints absolute paths, resolved (macOS's /tmp is /private/tmp); its warnings
# (jest-haste-map's) share stdout and start otherwise.
listed="$(JEST_LIST=1 enve run --locked -q -- helpers/jest.sh "${args[0]}" 1 1 "${args[@]:1}" -- "$@")"
logical="${GRAFANA_ROOT}/"
physical="$(pwd -P)/"
while IFS= read -r line; do
    case "${line}" in
        "${logical}"*) printf '%s\n' "${line#"${logical}"}" ;;
        "${physical}"*) printf '%s\n' "${line#"${physical}"}" ;;
        /*) echo "jest-related.sh: ${line} is outside ${GRAFANA_ROOT}" >&2; exit 1 ;;
    esac
done <<<"${listed}" | sort -u
