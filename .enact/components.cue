package enact

import (
	"list"
	"strings"
)

// Grafana's components mirror upstream CI (.github/workflows: backend-unit-tests,
// pr-test-integration, pr-frontend-unit-tests, frontend-lint, go-lint): one Go backend
// across the root module and apps/*, platform modules under pkg/ (`base`), database
// integration suites, workspace packages and app on the root jest project, and decoupled
// plugins with their own jest config. Non-task files belong to `repository`.

let baseModules = [
	"pkg/apimachinery", "pkg/apiserver", "pkg/build/wire", "pkg/codegen", "pkg/infra/features",
	"pkg/plugins", "pkg/plugins/codegen", "pkg/storage/unified/resource/kv",
	"pkg/storage/unified/resourcepb", "pkg/util/sqlite",
]

let backendSources = [
	"pkg/**", "apps/**", "embed.go", "kinds/**", "conf/**", "emails/**",
	"public/emails/**", "public/views/**", "public/dashboards/**", "public/app/plugins/**/plugin.json", "public/app/plugins/**/*.go",
	"devenv/dev-dashboards/**", "devenv/dev-dashboards-without-uid/**", "devenv/docker/blocks/{postgres,mysql}_tests/**", "devenv/jsonnet/**",
	"devenv/scopes/**", "devenv/secrets/**",
]
let backendTrees = [
	"pkg", "apps", "kinds", "conf", "emails", "public/emails", "public/views", "public/dashboards",
	"public/app/plugins", "public/api-enterprise-spec.json", "public/api-merged.json",
	"packages/grafana-schema/src", "packages/grafana-data/src/types/featureToggles.gen.ts",
	"packages/grafana-runtime/src/internal/openFeature",
	"docs/sources/setup-grafana/configure-grafana/feature-toggles/index.md", "devenv", "hack",
]

let goRules = {
	_suite: string
	out: [
		{match: ["**/*.go", "**/go.mod", "**/go.sum", "pkg/**", "apps/**"], command: "helpers/go-packages.sh \(_suite) {changed_files}"},
		{match: ["**/*.md", "**/.golangci.yml", "**/.mockery.yaml", "**/.mockery.yml"], action: "ignore"},
	]
}

let goWorkspaceVerify = {
	_include: [...string]
	out: {
		name:    "go-workspace"
		command: "bash scripts/go-workspace/update-workspace.sh && git diff --exit-code -- go.mod go.sum '**/go.mod' '**/go.sum' go.work go.work.sum"
		filter:  {include: _include, on_empty: "skip"}
		timeout: "10m"
	}
}

let shellcheckVerify = {
	out: {
		name:    "shellcheck"
		command: "find scripts/ -name '*.sh' -type f -exec shellcheck -e SC1071 -e SC2162 '{}' +"
		filter:  {include: ["scripts/**/*.sh"], on_empty: "skip"}
		timeout: "2m"
	}
}

let goLint = {
	_more: *[] | [...{}]
	out: {
		direct:    true
		resources: {cpus: 3, memory_mb: 10240}
		tasks:     list.Concat([[{command: "helpers/go-lint.sh {changed_files}", filter: {include: ["**/*.go"], on_empty: "skip"}, timeout: "20m"}], _more])
	}
}

let goldenTests = [
	"public/app/features/dashboard/api/ResponseTransformersToBackend.test.ts",
	"public/app/features/dashboard/state/DashboardMigratorToBackend.devDashboards.test.ts",
	"public/app/features/dashboard-scene/serialization/transformSaveModelV1ToV2.test.ts",
	"public/app/features/dashboard-scene/serialization/transformSaveModelV2ToV1.test.ts",
	"public/app/features/dashboard-scene/v2schema/dashboardV2Schema.corpus.test.ts",
]

let frontendTests = "public/app public/swagger scripts/tests \(strings.Join([for t in goldenTests {"'!" + t + "'"}], " "))"

let databases = {
	sqlite:   {}
	postgres: {postgres: grafana.services.postgres}
	mysql:    {mysql: grafana.services.mysql}
}
let databaseSetup = {
	sqlite:   []
	postgres: ["devenv/docker/blocks/postgres_tests/**"]
	mysql:    ["devenv/docker/blocks/mysql_tests/**"]
}

let jestTest = {
	_up: string
	out: {command: "\(_up)helpers/jest.sh \(_up). {shard_index} {shard_total} . -- {relative_targets}", timeout: "30m"}
}
let jestResources = {cpus: 2, memory_mb: 6144}

let jestScope = {
	_root:    string
	_project: *"." | string
	out: {
		fallback:      "none"
		select_in_job: true
		tests:         ["\(_root)/**/*.test.{ts,tsx,js,jsx}"]
		rules: [
			{match: ["\(_root)/{package.json,tsconfig*.json,jest.config.js,jest-setup.js}"], action: "full_component"},
			{match: ["\(_root)/**/*.{ts,tsx,js,jsx,mjs,cjs,json}"], command: "helpers/jest-related.sh \(_project) \(_root) -- {changed_files}"},
			{match: ["\(_root)/{project.json,rollup.config.ts,webpack.config.ts,i18next.config.ts}"], action: "ignore"},
			jestIgnore,
		]
	}
}

// An e2e feature area: its paths select its playwright.config.ts suites' specs, as git
// lists them (on a sparse checkout too), the overlay's untracked specs included.
let e2eSuites = {
	match: [...string]
	_suites: [...string]
	out: {
		"match": match
		command: "git ls-files --cached --others --exclude-standard -- " + strings.Join([for suite in _suites {"'e2e-playwright/\(suite)/*.spec.ts'"}], " ")
	}
}

let e2eAreas = [
	{match: ["pkg/services/ngalert/**", "apps/alerting/**", "public/app/features/alerting/**", "packages/grafana-alerting/**"], _suites: ["alerting-suite"]},
	{
		match: ["apps/dashboard/**", "pkg/services/dashboards/**", "pkg/registry/apis/dashboard/**", "public/app/features/dashboard/**", "public/app/features/dashboard-scene/**", "public/app/features/browse-dashboards/**"]
		_suites: ["dashboards-suite", "dashboard-cujs", "dashboard-new-layouts"]
	},
	// Canvas has no suite of its own at the pin (playwright.config.ts names `canvas`, whose
	// directory doesn't exist): its panel and feature run the panels suite.
	{match: ["public/app/plugins/panel/**", "public/app/features/panel/**", "public/app/features/inspector/**", "public/app/features/visualization/**", "public/app/features/canvas/**"], _suites: ["panels-suite"]},
	{match: ["public/app/features/explore/**", "public/app/features/correlations/**"], _suites: ["notebooks-suite"]},
	{match: ["public/app/features/plugins/admin/**", "pkg/services/pluginsintegration/**"], _suites: ["plugin-catalog-suite"]},
	{match: ["pkg/tsdb/azuremonitor/**", "public/app/plugins/datasource/azuremonitor/**"], _suites: ["plugin-e2e/azuremonitor"]},
	{match: ["pkg/tsdb/graphite/**", "public/app/plugins/datasource/graphite/**"], _suites: ["plugin-e2e/graphite"]},
	{
		match: ["e2e-playwright/test-plugins/**", "packages/grafana-runtime/src/services/pluginExtensions/**", "public/app/features/plugins/extensions/**", "packages/grafana-e2e-selectors/**"]
		_suites: ["test-plugins", "plugin-e2e/plugin-e2e-api-tests"]
	},
	{match: ["public/app/core/journeys/**"], _suites: ["journey-tracking"]},
	{match: ["pkg/services/hooks/**", "public/app/features/admin/**"], _suites: ["diagnostics-suite"]},
	{
		match: [for feature in ["annotations", "commandPalette", "connections", "datasources", "expressions", "folders", "library-panels", "live", "logs", "manage-dashboards", "org", "playlist", "profile", "provisioning", "query", "scopes", "search", "serviceaccounts", "support-bundles", "teams", "templating", "transformers", "trails", "users", "variables"] {"public/app/features/\(feature)/**"}]
		_suites: ["various-suite"]
	},
]

let jestIgnore = {
	match: [
		"**/*.{md,mdx,scss,css,svg,png,jpg,gif}", "public/app/**/*.{html,txt}",
		"public/{boot,fonts,img,locales,maps,gazetteer,sass}/**", "public/robots.txt",
		"{eslint.config.js,eslint-suppressions.json,.prettierrc.js,.prettierignore,stylelint.config.js,knip.config.ts,.madgerc,.levignore.js}",
	]
	action: "ignore"
}

let frontendLint = {
	_up:   string
	_more: *[] | [...{}]
	out: {
		direct:    true
		resources: {cpus: 2, memory_mb: 6144}
		tasks:     list.Concat([[{command: "\(_up)helpers/frontend-lint.sh {relative_changed_files}", filter: {include: ["**/*.{ts,tsx,js,jsx,mjs,cjs,json,scss,md,mdx}"], on_empty: "skip"}}], _more])
	}
}

let themesVerify = {
	_cwd:     *"" | string
	_up:      *"" | string
	_include: [...string]
	out: {
		name:    "themes-generate"
		command: "pnpm\(_cwd) run themes-generate && git diff --exit-code -- \(_up)public/sass/grafana.dark.css \(_up)public/sass/grafana.light.css \(_up)packages/grafana-data/src/themes/schema.generated.json"
		filter:  {include: _include, on_empty: "skip"}
	}
}

let rootI18nVerify = {
	_cwd:     *"" | string
	_include: [...string]
	_exclude: *[] | [...string]
	out: {
		name:    "i18n-verify"
		command: "LANG=en_US.UTF-8 pnpm\(_cwd) exec i18next-cli extract --sync-primary --ci --dry-run"
		filter:  {include: _include, if len(_exclude) > 0 {exclude: _exclude}, on_empty: "skip"}
	}
}

let workspaceI18nVerify = {
	_root:    string
	_catalog: string
	out: {
		name:    "i18n-verify"
		command: "LANG=en_US.UTF-8 pnpm run i18n-extract --ci --dry-run"
		filter:  {include: ["\(_root)/i18next.config.ts", "\(_root)/**/*.{ts,tsx}", "\(_root)/\(_catalog)"], on_empty: "skip"}
	}
}

let packedPackageVerify = {
	_dir: string
	out: {
		name:    "packed-packages"
		command: "bash -c 'trap \"rm -rf ./dist ./compiled ./package.tgz\" EXIT; pnpm run build && pnpm pack --out package.tgz && NODE_OPTIONS=\"-C @grafana-app/source\" pnpm exec attw package.tgz --ignore-rules \"false-cjs\" --profile \"node16\" && pnpm exec publint package.tgz'"
		filter:  {include: ["packages/\(_dir)/package.json", "packages/\(_dir)/tsconfig*.json", "packages/\(_dir)/rollup.config.ts", "packages/\(_dir)/src/index.ts"], on_empty: "skip"}
		timeout: "10m"
	}
}

let circularDepsVerify = {
	_include: [...string]
	_exclude: *["**/*.{test,spec}.{ts,tsx}"] | [...string]
	_max:     *0 | int
	out: {
		name: "circular-dependencies"
		if _max == 0 {command: "pnpm exec madge --circular --extensions ts,tsx --no-count --no-spinner ."}
		if _max > 0 {command: "bash -c 'out=$(pnpm exec madge --circular --extensions ts,tsx --no-count --no-spinner . 2>&1) || { count=$(printf \"%s\\n\" \"$out\" | sed -n \"s/.*Found \\([0-9]*\\) circular.*/\\1/p\"); printf \"%s\\n\" \"$out\"; [ -n \"$count\" ] && [ \"$count\" -le \(_max) ]; }'"}
		filter:  {include: _include, exclude: _exclude, on_empty: "skip"}
		timeout: "10m"
	}
}

let tscJob = {
	_command:  string
	direct:    true
	resources: {cpus: 2, memory_mb: 6144}
	tasks:     [{command: _command, timeout: "20m"}]
}

let packages = {
	[string]: {dir: string, deps: [...string], shards: *1 | int, tests: *true | bool, typecheck: *true | bool, packed: *true | bool, max_circular: *0 | int, lint_more: *[] | [...{}]}
	"@grafana/i18n":          {dir: "grafana-i18n", deps: []}
	"@grafana/schema":        {dir: "grafana-schema", deps: [], tests: false}
	"@grafana/e2e-selectors": {dir: "grafana-e2e-selectors", deps: []}
	"@grafana/data": {
		dir: "grafana-data", deps: ["@grafana/i18n", "@grafana/schema"], shards: 2
		lint_more: [
			(themesVerify & {_cwd: " -C ../..", _up: "../../", _include: ["packages/grafana-data/src/themes/**", "packages/grafana-data/scripts/generateSchema.ts"]}).out,
			(rootI18nVerify & {_cwd: " --cwd ../..", _include: ["packages/grafana-data/**/*.{ts,tsx}"]}).out,
		]
	}
	// Its tests import @grafana/test-utils (a dev dependency), which imports
	// @grafana/runtime, which depends on @grafana/ui: adding that edge would close a cycle.
	"@grafana/ui": {
		dir: "grafana-ui", deps: ["@grafana/data", "@grafana/e2e-selectors", "@grafana/i18n", "@grafana/schema"], shards: 4, max_circular: 5
		lint_more: [(rootI18nVerify & {_cwd: " --cwd ../..", _include: ["packages/grafana-ui/**/*.{ts,tsx}"]}).out]
	}
	"@grafana/runtime": {dir: "grafana-runtime", deps: ["@grafana/data", "@grafana/schema", "@grafana/ui"]}
	"@grafana/api-clients": {
		dir: "grafana-api-clients", deps: ["@grafana/runtime"]
		lint_more: [{
			name:    "api-clients"
			command: "pnpm -C ../.. run generate-apis && git diff --exit-code -- src/clients/rtkq ../grafana-openapi/src"
			filter:  {include: ["packages/grafana-api-clients/src/scripts/**", "packages/grafana-api-clients/src/clients/rtkq/**"], on_empty: "skip"}
			timeout: "5m"
		}]
	}
	"@grafana/alerting": {
		dir: "grafana-alerting", deps: ["@grafana/api-clients", "@grafana/data", "@grafana/i18n", "@grafana/runtime", "@grafana/test-utils", "@grafana/ui"]
		lint_more: [(workspaceI18nVerify & {_root: "packages/grafana-alerting", _catalog: "src/locales/en-US/grafana-alerting.json"}).out]
	}
	"@grafana/flamegraph":       {dir: "grafana-flamegraph", deps: ["@grafana/data", "@grafana/test-utils", "@grafana/ui"]}
	"@grafana/o11y-ds-frontend": {dir: "grafana-o11y-ds-frontend", deps: ["@grafana/data", "@grafana/e2e-selectors", "@grafana/plugin-compat", "@grafana/runtime", "@grafana/ui"]}
	"@grafana/openapi": {
		dir: "grafana-openapi", deps: [], typecheck: false
		lint_more: [
			{name: "openapi", command: "pnpm run process-specs && git diff --exit-code -- src/api src/apis", filter: {include: ["packages/grafana-openapi/src/**"], on_empty: "skip"}, timeout: "5m"},
			{name: "api-clients", command: "pnpm -C ../.. run generate-apis && git diff --exit-code -- ../grafana-api-clients/src/clients/rtkq src", filter: {include: ["packages/grafana-openapi/src/apis/**"], on_empty: "skip"}, timeout: "5m"},
		]
	}
	"@grafana/plugin-compat": {dir: "grafana-plugin-compat", deps: ["@grafana/data", "@grafana/runtime", "@grafana/schema"], packed: false}
	"@grafana/sql": {
		dir: "grafana-sql", deps: ["@grafana/data", "@grafana/e2e-selectors", "@grafana/i18n", "@grafana/runtime", "@grafana/ui"]
		lint_more: [(workspaceI18nVerify & {_root: "packages/grafana-sql", _catalog: "src/locales/en-US/grafana-sql.json"}).out]
	}
	"@grafana/eslint-plugin": {dir: "grafana-eslint-rules", deps: [], packed: false}
}

let plugins = {
	[string]: {dir: string, deps: [...string], shards: *1 | int, lint_more: *[] | [...{}]}
	"@grafana-plugins/grafana-azure-monitor-datasource": {
		dir: "azuremonitor", shards: 2
		deps:      ["@grafana/data", "@grafana/e2e-selectors", "@grafana/i18n", "@grafana/plugin-configs", "@grafana/runtime", "@grafana/schema", "@grafana/test-utils", "@grafana/ui"]
		lint_more: [(workspaceI18nVerify & {_root: "public/app/plugins/datasource/azuremonitor", _catalog: "locales/en-US/grafana-azure-monitor-datasource.json"}).out]
	}
	"@grafana-plugins/grafana-testdata-datasource": {dir: "grafana-testdata-datasource", deps: ["@grafana/data", "@grafana/e2e-selectors", "@grafana/plugin-configs", "@grafana/runtime", "@grafana/schema", "@grafana/ui"]}
	"@grafana-plugins/graphite":                    {dir: "graphite", deps: ["@grafana/data", "@grafana/plugin-configs", "@grafana/runtime", "@grafana/schema", "@grafana/ui"]}
}

pipeline: {
	analysis: derived: [
		{
			outputs: ["apps/dashboard/pkg/migration/testdata/output/**", "apps/dashboard/pkg/migration/testdata/dev-dashboards-output/**", "apps/dashboard/pkg/migration/conversion/testdata/output/**", "apps/dashboard/pkg/migration/conversion/testdata/migrated_dashboards_output/**"]
			inputs:  ["apps/dashboard/Makefile", "apps/dashboard/go.mod", "apps/dashboard/go.sum", "apps/dashboard/pkg/apis/**", "apps/dashboard/pkg/migration/**"]
			exclude: ["apps/dashboard/pkg/migration/testdata/output/**", "apps/dashboard/pkg/migration/testdata/dev-dashboards-output/**", "apps/dashboard/pkg/migration/conversion/testdata/output/**", "apps/dashboard/pkg/migration/conversion/testdata/migrated_dashboards_output/**"]
		},
		{
			outputs: ["data", "data/**"]
			inputs:  ["conf/defaults.ini"]
		},
	]

	components: {
		root: {
			title: "Environment, pipeline and CI"
			root:  "."
			watch_paths: [
				"enve.cue", "enve.lock", ".enact/**", "cue.mod/**", ".github/workflows/ci.yml", ".github/workflows/nightly.yml",
				"bin/linux-x86_64/**", "bin/linux-aarch64/**", "bin/macos-aarch64/**", "bin/enact", "bin/enve",
				"helpers/lib.sh", "helpers/postgres-setup.sh", "helpers/mysql-setup.sh",
				".gitattributes", ".gitignore", ".ignore", ".editorconfig", "data/**",
			]
		}

		"go-root": {
			title: "Go workspace and tooling", technology: "go", root: "."
			watch_paths: [
				"go.mod", "go.sum", "go.work", "go.work.sum", "Makefile", ".golangci.yml", ".air.toml",
				".citools/**", "pkg/ruleguard.rules.go", "hack/**", "tools/**",
				"scripts/ci/backend-tests/**", "scripts/go-workspace/**", "scripts/modowners/**", "scripts/openapi3/**",
				"helpers/go-packages.sh", "helpers/go-test.sh", "helpers/go-lint.sh",
			]
			depends_on:      ["root"]
			workspace_scope: include: ["pkg", "apps", "kinds", "devenv", "public/app/plugins", "hack", "tools", "scripts", ".citools", "embed.go"]
			jobs: lint: {
				direct: true, resources: {cpus: 4, memory_mb: 8192}
				tasks: [
					{name: "modowners", command: "go run scripts/modowners/modowners.go check go.mod", filter: {include: ["go.mod", "scripts/modowners/**"], on_empty: "skip"}, timeout: "5m"},
					(goWorkspaceVerify & {_include: ["go.mod", "go.sum", "go.work", "go.work.sum", "scripts/go-workspace/**"]}).out,
					{name: "k8s-codegen", command: "./hack/update-codegen.sh common && git diff --exit-code -- pkg/apimachinery/apis pkg/apimachinery/generated", filter: {include: ["hack/**"], on_empty: "skip"}, timeout: "10m"},
					(shellcheckVerify).out,
				]
			}
		}

		"js-root": {
			title: "pnpm workspace and frontend tooling", technology: "typescript", root: "."
			watch_paths: [
				"package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "patches/**",
				"nx.json", "project.json", ".nvmrc", ".browserslistrc",
				"tsconfig.json", "tsconfig.smoke.json", "jest.config.js", "jest.config.codeowner.js",
				"eslint.config.js", "eslint-suppressions.json", ".prettierrc.js", ".prettierignore",
				"stylelint.config.js", "knip.config.ts", "i18next.config.ts", ".madgerc", ".levignore.js", ".nxignore",
				"scripts/tsconfig.base.json", "scripts/webpack/**", "scripts/rspack/**", "scripts/release/**",
				"scripts/cli/**", "scripts/codemods/**", "scripts/codeowners-manifest/**",
				"scripts/*.js", "scripts/*.mjs", "scripts/*.ts", "scripts/validate-npm-packages.sh", "scripts/tests/**", "scripts/docs/**",
				"packages/README.md", "packages/rollup.config.parts.ts",
				"packages/get-document/**", "packages/mapbox-jsonlint-lines-primitives/**",
				"public/test/**",
				"packages/grafana-runtime/src/services/pluginExtensions/usePluginComponents.ts",
				"packages/grafana-test-utils/src/matchers/**",
				"packages/grafana-api-clients/src/clients/rtkq/folder/v1beta1/**",
				"public/app/core/app_events.ts",
				"public/app/features/dashboard/api/DashboardAPIVersionResolver.ts",
				"public/app/features/dashboard-scene/saving/__mocks__/createDetectChangesWorker.ts",
				"public/app/features/plugins/extensions/useLoadAppPlugins.tsx",
				"public/app/features/plugins/extensions/usePluginComponents.tsx",
				"helpers/jest.sh", "helpers/jest-related.sh", "helpers/jest-filter.cjs",
				"helpers/jest-attribution.cjs", "helpers/frontend-lint.sh", "helpers/plugin-typecheck.sh",
			]
			depends_on:      ["root"]
			workspace_scope: include: ["patches", "scripts", "public", "apps/shorturl/plugin/src", "apps/dashboard/pkg/migration/conversion/testdata/input", "pkg/tests/apis/openapi_snapshots", "packages", "e2e-playwright/test-plugins"]
			jobs: lint: (frontendLint & {
				_up: ""
				_more: [
					{name: "pnpm-dedupe", command: "pnpm dedupe --check", filter: {include: ["package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml"], on_empty: "skip"}, timeout: "5m"},
					(themesVerify & {_include: ["scripts/cli/generateSassVariableFiles.ts", "scripts/cli/themeTemplates/**"]}).out,
					(rootI18nVerify & {_include: ["i18next.config.ts"]}).out,
					{
						name:    "packed-packages"
						command: "bash -c 'trap \"rm -rf ./npm-artifacts packages/*/dist packages/*/compiled\" EXIT; pnpm run packages:build && pnpm run packages:pack && for f in ./npm-artifacts/*.tgz; do NODE_OPTIONS=\"-C @grafana-app/source\" pnpm exec attw \"$f\" --ignore-rules \"false-cjs\" --profile \"node16\" && pnpm exec publint \"$f\" || exit 1; done'"
						filter:  {include: ["packages/rollup.config.parts.ts", "scripts/prepare-npm-package.js", "scripts/pack-npm-packages.mjs", "scripts/validate-npm-packages.sh"], on_empty: "skip"}
						timeout: "15m"
					},
					(circularDepsVerify & {_include: [".madgerc"], _max: 254}).out,
					{name: "test:rspack", command: "pnpm run test:rspack", filter: {include: ["scripts/rspack/**", "package.json", "pnpm-lock.yaml"], on_empty: "skip"}, timeout: "5m"},
					{name: "test:release", command: "pnpm run test:release", filter: {include: ["scripts/release/**", "package.json", "pnpm-lock.yaml"], on_empty: "skip"}, timeout: "5m"},
					(shellcheckVerify).out,
				]
			}).out
			jobs: typecheck: {
				direct: true, resources: {cpus: 2, memory_mb: 6144}
				tasks: [
					{name: "typecheck:smoke", command: "pnpm run typecheck:smoke", filter: {include: ["tsconfig.smoke.json", "scripts/tsconfig.base.json", "scripts/cuj-smoke.ts"], on_empty: "skip"}, timeout: "5m"},
					{name: "typecheck:rspack", command: "pnpm exec tsc --noEmit -p scripts/rspack/tsconfig.json", filter: {include: ["scripts/rspack/**", "scripts/tsconfig.base.json", "tsconfig.json"], on_empty: "skip"}, timeout: "5m"},
					{name: "typecheck:release", command: "pnpm exec tsc --noEmit -p scripts/release/tsconfig.json", filter: {include: ["scripts/release/**", "scripts/tsconfig.base.json", "tsconfig.json"], on_empty: "skip"}, timeout: "5m"},
				]
			}
		}

		base: {
			title: "Go platform modules", kind: "library", domain: "backend", technology: "go", root: "."
			watch_paths: [for m in baseModules {"\(m)/**"}]
			depends_on:  ["go-root"]
			resources:   {cpus: 4, memory_mb: 8192}
			shards:      2
			recorder:    "trace"
			jobs: lint: (goLint & {
				_more: [
					(goWorkspaceVerify & {_include: [for m in baseModules {"\(m)/go.{mod,sum}"}]}).out,
					{name: "k8s-codegen", command: "./hack/update-codegen.sh common && git diff --exit-code -- pkg/apimachinery/apis pkg/apimachinery/generated", filter: {include: ["pkg/apimachinery/apis/**", "pkg/apimachinery/generated/**"], on_empty: "skip"}, timeout: "10m"},
				]
			}).out
			test: {command: "helpers/go-test.sh base {shard_index} {shard_total} {targets}", timeout: "30m"}
			target_scope: {
				fallback:           "none"
				tests:              [for m in baseModules {"\(m)/**/*_test.go"}]
				exclude_test_names: "^TestIntegration"
				rules:              (goRules & {_suite: "base"}).out
			}
		}

		backend: {
			title: "Go backend (root module and apps)", kind: "service", domain: "backend", technology: "go", root: "."
			uses: [{protocol: "ipc", target: "base", title: "Uses apimachinery, apiserver & unified storage"}]
			watch_paths:      backendSources
			depends_on:       ["go-root", "base"]
			workspace_scope:  include: backendTrees
			resources:        {cpus: 3, memory_mb: 10240}
			shards:           8
			recorder:         "trace"
			record_resources: {cpus: 1.5, memory_mb: 3072}
			jobs: lint: (goLint & {
				_more: [
					(goWorkspaceVerify & {_include: ["{pkg,apps}/**/go.{mod,sum}"]}).out,
					{name: "wire", command: "make gen-go && git diff --exit-code -- pkg/server/wire_gen.go pkg/server/bootstrap/wire/", filter: {include: ["pkg/build/wire/**", "pkg/server/**"], on_empty: "skip"}, timeout: "10m"},
					{
						name:    "codegen"
						command: "make fix-cue && git diff --exit-code -- '**/*.cue' && CODEGEN_VERIFY=1 make gen-cue && git diff --exit-code -- apps/dashboard/pkg/apis/dashboard/ && CODEGEN_VERIFY=1 make gen-jsonnet && git diff --exit-code -- devenv/ && CODEGEN_VERIFY=1 make gen-app-manifests-unistore"
						filter: {
							include: ["kinds/**", "pkg/codegen/**", "pkg/kindsys/**", "pkg/plugins/codegen/**", "public/app/plugins/gen.go", "public/app/plugins/**/plugin.json", "apps/**/*.cue", "devenv/jsonnet/**", "devenv/dev-dashboards/**", "pkg/storage/unified/resource/**"]
							on_empty: "skip"
						}
						timeout: "15m"
					},
					{name: "swagger", command: "bash -c 'trap \"git checkout -- public/api-merged.json 2>/dev/null || true; rm -f public/api-spec.json\" EXIT; make swagger-gen'", filter: {include: ["pkg/api/**", "pkg/server/**", "pkg/services/ngalert/api/**"], on_empty: "skip"}, timeout: "15m"},
					{name: "feature-toggles", command: "go test -run '^TestFeatureToggleFiles$' ./pkg/services/featuremgmt/ && git diff --exit-code -- pkg/services/featuremgmt/ packages/grafana-data/src/types/featureToggles.gen.ts packages/grafana-runtime/src/internal/openFeature/ docs/sources/setup-grafana/configure-grafana/feature-toggles/index.md", filter: {include: ["pkg/services/featuremgmt/**"], on_empty: "skip"}, timeout: "5m"},
					{name: "k8s-codegen", command: "bash -c 'pkgs=$(printf \"%s\\n\" {changed_files} | sed -n \"s|^pkg/apis/\\([^/]*\\)/.*|\\1|p; s|^apps/\\([^/]*\\)/pkg/.*|\\1|p; s|^apps/alerting/\\([^/]*\\)/pkg/.*|\\1|p\" | sort -u); if [ -n \"$pkgs\" ]; then for p in $pkgs; do ./hack/update-codegen.sh \"$p\"; done; else ./hack/update-codegen.sh; fi && git diff --exit-code -- pkg/apis pkg/generated apps'", filter: {include: ["pkg/apis/**", "pkg/generated/**", "apps/*/pkg/{apis,generated}/**", "apps/alerting/*/pkg/{apis,generated}/**"], on_empty: "skip"}, timeout: "15m"},
				]
			}).out
			test: {command: "helpers/go-test.sh backend {shard_index} {shard_total} {targets}", timeout: "45m"}
			target_scope: {
				fallback:           "none"
				tests:              ["{pkg,apps}/**/*_test.go"]
				exclude_test_names: "^TestIntegration"
				not_run:            list.Concat([_backendNotRun, [{reason: "a platform module's: base:test runs it", tests: [for m in baseModules if m != "pkg/plugins/codegen" {"\(m)/**/*_test.go"}]}]])
				rules:              (goRules & {_suite: "backend"}).out
			}
		}

		for db, dbServices in databases {
			"integration-\(db)": {
				title: "Integration tests (\(db))", kind: "verification", domain: "verification", technology: "go", root: "."
				watch_paths:     list.Concat([backendSources, databaseSetup[db]])
				depends_on:      ["go-root", "base"]
				workspace_scope: include: backendTrees
				// Pure Go (CGO_ENABLED=0) against services enve.lock has for both Linux
				// architectures, with enact and enve built for both: either pool runs it.
				arch:            "any"
				resources:       {cpus: [if db == "sqlite" {4}, 2][0], memory_mb: 8192}
				shards:          [if db == "sqlite" {4}, 8][0]
				if db == "sqlite" {
					recorder:         "trace"
					record_resources: {cpus: 1.5, memory_mb: 4096}
				}
				services: dbServices
				test:     {command: "helpers/go-test.sh integration {shard_index} {shard_total} {targets}", timeout: "60m", if db != "sqlite" {env: GRAFANA_TEST_DB: db}}
				target_scope: {
					fallback:   "none"
					tests:      _integrationTests
					test_names: "^TestIntegration"
					if db != "sqlite" {footprints_from: "integration-sqlite:test"}
					rules: (goRules & {_suite: "integration"}).out
				}
			}
		}

		for name, p in packages {
			(name): {
				title: "\(name) package", kind: "library", domain: "packages", technology: "typescript", root: "packages/\(p.dir)"
				depends_on: list.Concat([["js-root"], p.deps])
				if p.typecheck {jobs: typecheck: tscJob & {_command: "pnpm run typecheck"}}
				jobs: lint: (frontendLint & {
					_up: "../../"
					_more: list.Concat([
						p.lint_more,
						[
							(circularDepsVerify & {_include: ["packages/\(p.dir)/**/*.{ts,tsx}"], _max: p.max_circular}).out,
						],
						[if p.packed {(packedPackageVerify & {_dir: p.dir}).out}],
					])
				}).out
				resources: jestResources
				if p.tests {
					recorder:     "own_linux"
					recorded_by:  ["enact-node"]
					test:         (jestTest & {_up: "../../"}).out
					shards:       p.shards
					target_scope: (jestScope & {_root: "packages/\(p.dir)"}).out
				}
			}
		}

		"@grafana/test-utils": {
			title: "@grafana/test-utils package", technology: "typescript", root: "packages/grafana-test-utils"
			depends_on: ["js-root", "@grafana/api-clients", "@grafana/runtime"]
			resources:  jestResources
			jobs: typecheck: tscJob & {_command: "pnpm run typecheck"}
			jobs: lint: (frontendLint & {
				_up: "../../"
				_more: [
					(circularDepsVerify & {_include: ["packages/grafana-test-utils/**/*.{ts,tsx}"]}).out,
				]
			}).out
			recorder:     "own_linux"
			recorded_by:  ["enact-node"]
			test:         {command: "../../helpers/jest.sh . {shard_index} {shard_total} . -- {relative_targets}", timeout: "20m"}
			target_scope: (jestScope & {_root: "packages/grafana-test-utils", _project: "packages/grafana-test-utils"}).out
		}

		"@grafana/plugin-configs": {
			title: "@grafana/plugin-configs package", technology: "typescript", root: "packages/grafana-plugin-configs"
			depends_on: ["js-root"]
			jobs: lint: (frontendLint & {
				_up: "../../"
				_more: [
					(circularDepsVerify & {_include: ["packages/grafana-plugin-configs/**/*.{ts,tsx}"]}).out,
				]
			}).out
		}

		for name, p in plugins {
			(name): {
				title: "\(name) (decoupled plugin)", kind: "addon", domain: "plugins", technology: "typescript", root: "public/app/plugins/datasource/\(p.dir)"
				depends_on: list.Concat([["js-root"], p.deps])
				jobs: typecheck: tscJob & {_command: "../../../../../helpers/plugin-typecheck.sh ."}
				jobs: lint: (frontendLint & {
					_up: "../../../../../"
					_more: list.Concat([
						p.lint_more,
						[
							(circularDepsVerify & {_include: ["public/app/plugins/datasource/\(p.dir)/**/*.{ts,tsx}"]}).out,
						],
					])
				}).out
				shards:       p.shards
				resources:    jestResources
				recorder:     "own_linux"
				recorded_by:  ["enact-node"]
				test:         {command: "../../../../../helpers/jest.sh . {shard_index} {shard_total} . -- {relative_targets}", timeout: "20m"}
				target_scope: (jestScope & {_root: "public/app/plugins/datasource/\(p.dir)", _project: "public/app/plugins/datasource/\(p.dir)"}).out
			}
		}

		frontend: {
			title: "Frontend app", kind: "app", domain: "frontend", technology: "typescript", root: "."
			uses: [{protocol: "http", target: "backend", title: "Queries dashboards, alerting & datasource APIs"}]
			watch_paths: [
				"public/app/{api,core,extensions,features,routes,store,types}/**",
				"public/app/plugins/panel/**",
				"public/app/plugins/datasource/{alertmanager,dashboard,grafana,mixed}/**",
				"public/app/{AppWrapper.tsx,app.ts,dev-utils.ts,dev.ts,index.ts,initApp.ts,initPreferences.ts,initPreferences.test.ts,legacyAPIHandling.ts,legacyAPIHandling.test.ts,polyfills.ts}",
				"public/{boot,fonts,img,lib,locales,maps,gazetteer,sass,swagger,vendor}/**",
				"public/{api-enterprise-spec.json,api-merged.json,openapi3.json,mockServiceWorker.js,robots.txt}",
				"apps/shorturl/plugin/src/**",
			]
			depends_on: ["js-root", "@grafana/alerting", "@grafana/api-clients", "@grafana/data", "@grafana/e2e-selectors", "@grafana/flamegraph", "@grafana/i18n", "@grafana/o11y-ds-frontend", "@grafana/runtime", "@grafana/schema", "@grafana/sql", "@grafana/ui", "@grafana/test-utils"]
			resources:  {cpus: 4, memory_mb: 8192}
			shards:     8
			jobs: lint: (frontendLint & {
				_up: ""
				_more: [
					(themesVerify & {_include: ["public/sass/**"]}).out,
					(rootI18nVerify & {
						_include: ["public/locales/en-US/grafana.json", "public/**/*.{ts,tsx}"]
						_exclude: ["public/lib/monaco/**", "public/app/extensions/**", "public/app/plugins/datasource/**"]
					}).out,
					{name: "openapi", command: "pnpm -C packages/grafana-openapi run process-specs && git diff --exit-code -- packages/grafana-openapi/src/api packages/grafana-openapi/src/apis", filter: {include: ["public/openapi3.json"], on_empty: "skip"}, timeout: "5m"},
					{name: "api-clients", command: "pnpm run generate-apis && git diff --exit-code -- packages/grafana-api-clients/src/clients/rtkq packages/grafana-openapi/src", filter: {include: ["public/openapi3.json"], on_empty: "skip"}, timeout: "5m"},
					(circularDepsVerify & {
						_include: ["public/app/**/*.{ts,tsx}"]
						_exclude: ["public/app/plugins/datasource/{azuremonitor,grafana-testdata-datasource,graphite}/**", "**/*.{test,spec}.{ts,tsx}"]
						_max:     254
					}).out,
				]
			}).out
			jobs: typecheck: {
				direct: true, resources: {cpus: 4, memory_mb: 9216}
				tasks: [
					{command: "pnpm exec tsc --noEmit", timeout: "30m"},
					{name: "typecheck:smoke", command: "pnpm run typecheck:smoke", filter: {include: ["public/app/core/journeys/__smoke__/**/*.ts", "public/app/core/journeys/*.smoke.ts"], on_empty: "skip"}, timeout: "5m"},
				]
			}
			recorder:         "own_linux"
			recorded_by:      ["enact-node"]
			record_resources: {cpus: 1.5, memory_mb: 3072}
			test:             {command: "helpers/jest.sh . {shard_index} {shard_total} \(frontendTests) -- {targets}", timeout: "45m"}
			target_scope: {
				fallback:         "none"
				select_in_job:    true
				incidental_reads: ["packages/**/*.test.{ts,tsx}"]
				tests: [
					"public/app/{api,core,extensions,features,routes,store,types}/**/*.test.{ts,tsx,js,jsx}",
					"public/app/plugins/panel/**/*.test.{ts,tsx,js,jsx}",
					"public/app/plugins/datasource/{alertmanager,dashboard,grafana,mixed}/**/*.test.{ts,tsx,js,jsx}",
					"public/app/{initPreferences,legacyAPIHandling}.test.ts",
					"public/swagger/**/*.test.{ts,tsx,js,jsx}",
				]
				exclude: goldenTests
				rules: [
					{
						match:   ["public/{app,swagger,vendor,lib}/**/*.{ts,tsx,js,jsx,mjs,cjs,json}", "public/{api-enterprise-spec.json,api-merged.json,openapi3.json,mockServiceWorker.js}", "apps/shorturl/plugin/src/**"]
						command: "helpers/jest-related.sh . \(frontendTests) -- {changed_files}"
					},
					jestIgnore,
				]
			}
		}

		"dashboard-golden": {
			title: "Dashboard migration golden files", technology: ["go", "typescript"], root: "."
			watch_paths: list.Concat([["apps/dashboard/Makefile", "apps/dashboard/go.mod", "apps/dashboard/go.sum", "apps/dashboard/pkg/apis/**", "apps/dashboard/pkg/migration/**", "helpers/dashboard-golden.sh"], goldenTests])
			depends_on:  ["frontend", "base"]
			resources:   {cpus: 4, memory_mb: 8192}
			recorder:    "own_linux"
			test:        {command: "helpers/dashboard-golden.sh {targets}", timeout: "20m"}
			target_scope: {
				fallback: "none", tests: goldenTests
				rules: [
					{match: ["apps/dashboard/**"], action: "full_component"},
					{match: goldenTests, command: "echo {changed_files}"},
					{match: ["helpers/dashboard-golden.sh"], action: "full_component"},
					jestIgnore,
				]
			}
		}

		e2e: {
			title: "End-to-end tests (Playwright)", kind: "verification", domain: "verification", root: "e2e-playwright"
			watch_paths: ["e2e-playwright/**", "playwright.config.ts", "playwright.storybook.config.ts", "helpers/playwright.sh", "helpers/e2e-build.sh"]
			depends_on:  ["backend", "frontend"]
			resources:   {cpus: 4, memory_mb: 8192}
			shards:      4
			jobs: {
				lint: (frontendLint & {_up: "../"}).out
				build: {
					services: false, resources: {cpus: 4, memory_mb: 12288}
					outputs: {
						paths: ["bin/grafana", "public/build", "public/app/plugins/datasource/*/dist", "e2e-playwright/test-plugins/*/dist", "data/plugins-bundled"]
						key:   ["*", "patches/**", "apps/**", "cue.mod/**", "kinds/**", "packages/**", "pkg/**", "public/**", "scripts/**", "e2e-playwright/test-plugins/**", "helpers/e2e-build.sh"]
					}
					tasks: [{command: "../helpers/e2e-build.sh", timeout: "40m"}]
				}
				test: {needs: ["build"], tasks: [{command: "../helpers/playwright.sh {shard_index} {shard_total} {relative_targets}", timeout: "45m"}]}
			}
			workspace_scope: {
				include:              ["e2e-playwright", "playwright.config.ts", "playwright.storybook.config.ts", "conf", "devenv", "emails", "public", "packages", "scripts", "pkg", "apps", "kinds", "embed.go", "Makefile", "go.mod", "go.sum", "go.work", "go.work.sum"]
				include_dependencies: true
			}
			target_scope: {
				fallback: "all", tests: ["e2e-playwright/**/*.spec.ts"]
				not_run: [{
					tests:  ["e2e-playwright/cloud-plugins-suite/azure-monitor.spec.ts", "e2e-playwright/dashboards-search-suite/dashboards-search.spec.ts", "e2e-playwright/plugin-e2e/cloudmonitoring/cloudmonitoring.spec.ts", "e2e-playwright/plugin-e2e/loki/loki.spec.ts", "e2e-playwright/storybook/verify.spec.ts"]
					reason: "Specs outside playwright.config.ts or skipped by --grep-invert @cloud-plugins (cloud-plugins-suite is @cloud-plugins; storybook runs under playwright.storybook.config.ts; dashboards-search-suite, cloudmonitoring, and loki have no project in playwright.config.ts)"
				}]
				// A change whose every file lies in a feature area runs that area's suites
				// (impl/08); any other file, shared server plumbing included, keeps the suite
				// whole (`fallback: "all"`).
				rules: list.Concat([[
					{match: ["e2e-playwright/**/*.ts"], engine: "typescript"},
					jestIgnore,
					// Go and jest tests and stories build into no server or bundle a spec runs against.
					{match: ["**/*_test.go", "**/*.test.{ts,tsx}", "**/*.stories.{ts,tsx}"], action: "ignore"},
					// The harness every spec runs under.
					{match: ["playwright.config.ts", "helpers/playwright.sh", "helpers/e2e-build.sh"], action: "full_component"},
				], [for area in e2eAreas {(e2eSuites & area).out}]])
			}
		}

		repository: {
			title: "Docs, packaging, upstream CI and dev setups", root: "."
			watch_paths: [
				"*.md", "LICENSE", "docs/**", "contribute/**", ".changelog-archive/**",
				".github/**", ".claude/**", ".vscode/**", ".zed/**", ".vim/**",
				"local/**", "devenv/**", "packaging/**", "grafana-mixin/**",
				"scripts/*.sh", "scripts/*.py", "scripts/catalog-plugins-defaults",
				"scripts/build/**", "scripts/grafana-server/**", "scripts/helpers/**",
				"scripts/verify-repo-update/**", "scripts/ci/**",
				"Dockerfile", ".dockerignore", ".policy.yml", ".policy.yml.tmpl",
				".vale.ini", "crowdin.yml", "relyance.yaml", "latest.json",
				"lefthook.yml", "lefthook.rc", "mise.toml",
			]
			depends_on: ["root"]
			jobs: lint: {
				direct: true, resources: {cpus: 1, memory_mb: 2048}
				tasks: [(shellcheckVerify).out]
			}
		}
	}
}
