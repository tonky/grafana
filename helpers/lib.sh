# Sourced by the job helpers. enact runs a job from its component's directory and may
# rewrite a repository path in the command to reach it from there (`packages/x` becomes
# `../../packages/x`); the helpers take paths either way and work from the repository root.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"   # sets GRAFANA_ROOT, cds there
#   repo_paths <path>...                              # one repository-relative path per line
#   go_workspace_modules                              # go.work's `use` directories, space-separated
#   go_foreign_modules                                # directories of the go.mod files go.work leaves out
#   tree_find <find expression>                       # find . <expression>, files vanishing mid-walk tolerated

caller_dir="${PWD}"
GRAFANA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${GRAFANA_ROOT}"

# Pure string normalisation: a changed file may no longer exist, and macOS has no
# `realpath -m`.
repo_paths() {
    [[ $# -gt 0 ]] || return 0
    printf '%s\n' "$@" | awk -v here="${caller_dir}" -v root="${GRAFANA_ROOT}" '
        {
            p = ($0 ~ /^\//) ? $0 : here "/" $0
            n = split(p, part, "/"); k = 0
            for (i = 1; i <= n; i++) {
                if (part[i] == "" || part[i] == ".") continue
                if (part[i] == "..") { if (k > 0) k--; continue }
                seg[++k] = part[i]
            }
            out = ""
            for (i = 1; i <= k; i++) out = out "/" seg[i]
            if (out == root) print "."
            else if (index(out, root "/") == 1) print substr(out, length(root) + 2)
            else print out
        }'
}

go_workspace_modules() {
    awk '
        /^use[ \t]*\(/ {block = 1; next}
        block && /^\)/ {block = 0}
        block || /^use[ \t]/ {
            sub(/\/\/.*/, ""); sub(/^use[ \t]*/, "")
            gsub(/[ \t]/, ""); sub(/^\.\//, "")
            if ($0 != "") printf "%s ", $0
        }' go.work
}

# `find . <expression>`. A file can vanish while find walks the tree (another process's
# scratch directory, a test's tempdir): only that error passes, any other fails it.
tree_find() {
    local errors status=0
    errors="$(mktemp)"
    find . "$@" 2>"${errors}" || status=$?
    if [[ ${status} -ne 0 ]] && grep -qv 'No such file or directory' "${errors}"; then
        cat "${errors}" >&2
        rm -f "${errors}"
        return "${status}"
    fi
    rm -f "${errors}"
}

# Tools pinned in their own modules (.citools/src/*), devenv's, hack, scripts/*, the wire
# fork: no suite's and no lint's (upstream's go-lint lints `go list -m`).
go_foreign_modules() {
    local workspace
    workspace="$(go_workspace_modules)"
    tree_find \( -name node_modules -o -name testdata -o -name '.?*' -a ! -name .citools \) -prune -o -name go.mod -print \
        | sed -e 's|^\./||' -e 's|/\{0,1\}go\.mod$||' \
        | awk -v ws="${workspace}" 'BEGIN {n = split(ws, w, " "); for (i = 1; i <= n; i++) in_ws[w[i]] = 1}
            $0 != "" && !($0 in in_ws)' | tr '\n' ' '
}

