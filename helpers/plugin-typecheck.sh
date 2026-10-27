#!/usr/bin/env bash
# A decoupled plugin's typecheck: upstream's root `tsc --noEmit` (frontend-lint.yml), which
# checks the plugins with the app, narrowed to one plugin. The plugins have no typecheck
# script: their own tsconfig.json (the plugin build's, TypeScript 6 through
# @grafana/plugin-configs) fails at the pin, and `yarn tsc` in their workspace finds no
# compiler (their `typescript` devDependency is never installed beside the root's alias).
#
#   helpers/plugin-typecheck.sh <plugin dir>
#
# The program is the root tsconfig.json's with the plugin's files in place of public/app's,
# plus the ambient declarations the root program includes (public/app's .d.ts files, the test
# setup, the packages' typings). Its compiler is the root's (TypeScript 7, native).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

plugin="$(repo_paths "${1:?usage: plugin-typecheck.sh <plugin dir>}")"
[[ -d "${plugin}" ]] || { echo "plugin-typecheck.sh: no directory ${plugin}" >&2; exit 2; }
config_dir="$(mktemp -d)"
trap 'rm -rf "${config_dir}"' EXIT
root="${GRAFANA_ROOT}"
cat >"${config_dir}/tsconfig.json" <<EOF
{
  "extends": "${root}/tsconfig.json",
  "compilerOptions": {"incremental": false, "noEmit": true, "typeRoots": ["${root}/node_modules/@types"]},
  "include": [
    "${root}/${plugin}/**/*.ts*",
    "${root}/public/app/**/*.d.ts",
    "${root}/public/test/**/*.ts*",
    "${root}/public/vendor/**/*.ts",
    "${root}/packages/grafana-data/typings",
    "${root}/packages/grafana-ui/src/types"
  ],
  "exclude": ["${root}/public/app/**/webpack.config.ts", "${root}/public/app/**/__smoke__/**", "${root}/public/app/**/*.smoke.ts"]
}
EOF
echo "🔎 tsc --noEmit: the root program narrowed to ${plugin}" >&2
yarn tsc --noEmit -p "${config_dir}/tsconfig.json"
