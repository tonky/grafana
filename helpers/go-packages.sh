#!/usr/bin/env bash
# Prints the Go packages of one suite that a change reaches: the packages of the changed
# files and every package building from them, through its code or its tests.
#
#   helpers/go-packages.sh <base|backend|integration> [changed file...]
#
# The suites, as upstream CI splits them (backend-unit-tests.yml, pr-test-integration.yml):
#   base         unit-tested packages of the platform modules under pkg/ that go.work uses
#                (pkg/apimachinery, pkg/apiserver, pkg/plugins, ...): none requires the root
#                module, so nothing outside them reaches them.
#   backend      unit-tested packages of every other workspace module (the root module, apps/*).
#   integration  packages of any workspace module with a `func TestIntegration...`, but those
#                whose tests start a Gitea server in Docker (provisioning's git-sync packages:
#                nanogit's gittest, through testcontainers, shared by every test of the
#                package). Nothing here runs containers; they are named on stderr.
# With no file, prints every package of the suite. A file under a testdata tree belongs to
# the package holding the tree; a module's go.mod or go.sum to every package of the module;
# any other file to the nearest package above it, as if its code changed (it embeds the
# file or its tests read it).
#
# Every workspace module's path is github.com/grafana/grafana/<its directory>, so a
# package's import path is the module's path joined with its directory. enact runs this to
# select targets on the host and in CI's detect job, which has no Go toolchain: it reads the
# import blocks itself. Build constraints are ignored (a file of another platform only adds
# edges), so the selection can only grow.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

suite="${1:?usage: go-packages.sh <base|backend|integration> [file...]}"
shift
case "${suite}" in base | backend | integration) ;; *) echo "unknown suite: ${suite}" >&2; exit 2 ;; esac

module="$(awk '$1 == "module" {print $2; exit}' go.mod)"

workspace="$(go_workspace_modules)"
base_modules="$(printf '%s\n' ${workspace} | awk '/^pkg\//' | tr '\n' ' ')"
# Pruned from the scan.
foreign="$(go_foreign_modules)"

seeds=""
test_seeds=""
module_seeds=""
while IFS= read -r file; do
    case "${file}" in
        *_test.go | */testdata/*) kind=test ;;
        *.go) kind=code ;;
        go.mod | go.sum | */go.mod | */go.sum) kind=module ;;
        # Documentation and lint or mock configuration: no build or test reads them.
        *.md | */.golangci.yml | */.mockery.yaml | */.mockery.yml) continue ;;
        *) kind=asset ;;
    esac
    dir="$(dirname "${file}")"
    dir="${dir%%/testdata*}"
    if [[ "${kind}" == asset ]]; then
        # A file a package embeds (go:embed) or its tests read (a generated registry, a
        # fixture tree): the nearest directory above it holding Go code is that package.
        while [[ "${dir}" != "." ]] && ! compgen -G "${dir}/*.go" >/dev/null; do dir="$(dirname "${dir}")"; done
        [[ "${dir}" == "." ]] && continue
        kind=code
    fi
    [[ "${dir}" == "." ]] && pkg="${module}" || pkg="${module}/${dir}"
    case "${kind}" in
        test) test_seeds+=" ${pkg}" ;;
        code) seeds+=" ${pkg}" ;;
        # A module's requirements: every package of the module builds from them.
        module) module_seeds+=" ${pkg}" ;;
    esac
done < <(repo_paths "$@")
[[ $# -eq 0 || -n "${seeds}${test_seeds}${module_seeds}" ]] || exit 0

prune=(-name testdata -o -name node_modules -o -name '.?*' -o -name '_*')
for dir in ${foreign}; do prune+=(-o -path "./${dir}"); done

# The go tool skips testdata trees and directories starting with `.` or `_`.
tree_find \( "${prune[@]}" \) -prune -o -type f -name '*.go' -print \
    | sed 's|^\./||' \
    | awk -v module="${module}" -v seeds="${seeds}" -v all="$(( $# == 0 ))" \
        -v test_seeds="${test_seeds}" -v module_seeds="${module_seeds}" -v suite="${suite}" \
        -v base_modules="${base_modules}" '
    function package_of(path,    dir) {
        dir = path; sub(/\/[^\/]*$/, "", dir)
        return (dir == path) ? module : module "/" dir
    }
    # Reads one file: its package, the module packages its imports name, and whether it
    # declares an integration test or starts a Gitea container.
    function scan(path,    pkg, test, line, in_block, n, quoted, imp, got) {
        pkg = package_of(path); test = (path ~ /_test\.go$/)
        in_block = 0; imports_done = 0
        while ((got = (getline line < path)) > 0) {
            if (!imports_done) {
                # A generator run with `go run`: no package builds from it.
                if (line ~ /^\/\/go:build/ && line ~ /[ !(]ignore([ )|&]|$)/) { close(path); return }
                sub(/\/\/.*/, "", line)
                if (in_block) {
                    if (line ~ /^[ \t]*\)/) { in_block = 0; continue }
                } else if (line ~ /^import[ \t]*\(/) {
                    in_block = 1; continue
                } else if (line !~ /^import[ \t]/) {
                    # Declarations follow the imports.
                    if (line ~ /^(func|type|var|const)[ \t(]/) {
                        imports_done = 1
                        if (!test || suite != "integration") break
                    } else continue
                }
                if (!imports_done) {
                    n = split(line, quoted, "\"")
                    if (n < 3) continue
                    imp = quoted[2]
                    if (imp != module && index(imp, module "/") != 1) continue
                    if (test) test_imports[pkg, imp] = 1
                    else importers[imp] = importers[imp] " " pkg
                    continue
                }
            }
            if (line ~ /^func TestIntegration/) integration[pkg] = 1
            if (line ~ /NewSharedGitEnv|RunGrafanaWithGitServer|gittest\./) docker[pkg] = 1
        }
        close(path)
        # Gone since it was listed: no package builds from it.
        if (got < 0) return
        packages[pkg] = 1
        if (test) tested[pkg] = 1
    }
    function in_base(pkg,    i, n, mods, prefix) {
        n = split(base_modules, mods, " ")
        for (i = 1; i <= n; i++) {
            prefix = module "/" mods[i]
            if (pkg == prefix || index(pkg, prefix "/") == 1) return 1
        }
        return 0
    }
    function in_suite(pkg) {
        if (suite == "integration") {
            if (!(pkg in integration)) return 0
            if (pkg in docker) { left_out[pkg] = 1; return 0 }
            return 1
        }
        if (!(pkg in tested)) return 0
        return (suite == "base") == in_base(pkg)
    }
    function report(    pkg, n, names) {
        for (pkg in left_out) { n++; names = names " " pkg }
        if (n) print "go-packages.sh: " n " integration package(s) need Docker (a Gitea test container), left out:" names > "/dev/stderr"
    }
    { scan($0) }
    END {
        if (all) {
            for (pkg in packages) if (in_suite(pkg)) print pkg
            report()
            exit
        }
        # Packages built from a changed one (or changed themselves)...
        n = split(seeds, queue, " "); head = 1
        for (i = 1; i <= n; i++) if (queue[i] != "") built[queue[i]] = 1
        m = split(module_seeds, mods, " ")
        for (pkg in packages) for (i = 1; i <= m; i++)
            if (pkg == mods[i] || index(pkg, mods[i] "/") == 1) { if (!(pkg in built)) queue[++n] = pkg; built[pkg] = 1 }
        tail = n
        while (head <= tail) {
            pkg = queue[head++]
            if (pkg == "" || !(pkg in importers)) continue
            m = split(importers[pkg], users, " ")
            for (j = 1; j <= m; j++) if (!(users[j] in built)) { built[users[j]] = 1; queue[++tail] = users[j] }
        }
        # ...and the packages whose tests import one of those.
        for (pkg in built) selected[pkg] = 1
        n = split(test_seeds, own, " ")
        for (i = 1; i <= n; i++) if (own[i] != "") selected[own[i]] = 1
        for (pair in test_imports) {
            split(pair, parts, SUBSEP)
            if (parts[2] in built) selected[parts[1]] = 1
        }
        for (pkg in selected) if ((pkg in packages) && in_suite(pkg)) print pkg
        report()
    }' | sort
