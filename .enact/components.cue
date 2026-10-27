package enact

import (
	"list"
	"strings"
)

// Grafana's components, as its CI splits the work (.github/workflows: backend-unit-tests,
// pr-test-integration, pr-frontend-unit-tests, frontend-lint, go-lint): one Go backend whose
// packages import each other across the root module and apps/* both ways (one component,
// narrowed by package), the platform modules under pkg/ that require nothing of it (`base`),
// the database suites, the root jest project's packages and app, and the decoupled plugins
// with their own jest. Every tracked file is some component's: what runs no task is
// `repository`'s. depends_on names components by name (string literals: references copy
// structs, which CUE unifies at every hop).

// go.work's modules under pkg/: none requires the root module (their go.mod), so nothing
// of the backend reaches them. Each needs every other workspace module checked out:
// go.work names them all.
let baseModules = [
	"pkg/apimachinery",
	"pkg/apiserver",
	"pkg/build/wire",
	"pkg/codegen",
	"pkg/infra/features",
	"pkg/plugins",
	"pkg/plugins/codegen",
	"pkg/storage/unified/resource/kv",
	"pkg/storage/unified/resourcepb",
	"pkg/util/sqlite",
]

// What the backend's packages build from and their tests read, beside pkg/ and apps/:
// upstream's `backend` change filter (.github/actions/change-detection), and the files the
// tests open (conf/defaults.ini, public/views, devenv/dev-dashboards, plugin.json files).
let backendSources = [
	"pkg/**",
	"apps/**",
	"**/*.go",
	"embed.go",
	"kinds/**",
	"conf/**",
	"emails/**",
	"public/emails/**",
	"public/views/**",
	"public/dashboards/**",
	"public/app/plugins/**/plugin.json",
	"devenv/dev-dashboards/**",
	"devenv/dev-dashboards-without-uid/**",
	"devenv/jsonnet/**",
	"devenv/scopes/**",
	"devenv/secrets/**",
]
let backendTrees = [
	"pkg",
	"apps",
	"kinds",
	"conf",
	"emails",
	"public/emails",
	"public/views",
	"public/dashboards",
	"public/app/plugins",
	"public/api-enterprise-spec.json",
	"public/api-merged.json",
	"packages/grafana-schema/src",
	"devenv",
]

// A Go file stands for its package and the packages building from it (go-packages.sh), a
// testdata file for its package's tests, a nested module's go.mod for all of its packages,
// another file under pkg/ or apps/ for the package above it (an embedded or generated
// file). Anything else of the suite's (conf/, public/) runs it whole.
let goRules = {
	_suite: string
	out: [
		{match: ["**/*.go", "**/go.mod", "**/go.sum", "pkg/**", "apps/**"], command: "helpers/go-packages.sh \(_suite) {changed_files}"},
		// Docs and lint or mock configuration reach no test (ignore decides before the rule
		// above sees them).
		{match: ["**/*.md", "**/.golangci.yml", "**/.mockery.yaml", "**/.mockery.yml"], action: "ignore"},
	]
}

// pr-go-workspace-check.yml: verifies every go.work module's go.mod/go.sum and
// go.work.sum stay tidy and in sync with scripts/go-workspace/update-workspace.sh.
let goWorkspaceVerify = {
	_include: [...string]
	out: {
		name:    "go-workspace"
		command: "bash scripts/go-workspace/update-workspace.sh && git diff --exit-code -- go.mod go.sum '**/go.mod' '**/go.sum' go.work go.work.sum"
		filter: {
			include:  _include
			on_empty: "skip"
		}
		timeout: "10m"
	}
}

// go-lint.yml: gofmt and golangci-lint over the changed files' packages; golangci-lint
// type-checks them, which takes a runner's memory.
let goLint = {
	_more: *[] | [...{}]
	out: {
		direct: true
		resources: {cpus: 4, memory_mb: 12288}
		tasks: list.Concat([[{
			command: "helpers/go-lint.sh {changed_files}"
			filter: {include: ["**/*.go"], on_empty: "skip"}
			timeout: "20m"
		}], _more])
	}
}

// The frontend tests that compare the frontend's dashboard transforms with the Go
// migration's outputs, which `make generate-golden-files` writes (gitignored): upstream's
// frontend jobs need its generate-golden-files job. They are `dashboard-golden`'s.
let goldenTests = [
	"public/app/features/dashboard/api/ResponseTransformersToBackend.test.ts",
	"public/app/features/dashboard/state/DashboardMigratorToBackend.devDashboards.test.ts",
	"public/app/features/dashboard-scene/serialization/transformSaveModelV1ToV2.test.ts",
	"public/app/features/dashboard-scene/serialization/transformSaveModelV2ToV1.test.ts",
	"public/app/features/dashboard-scene/v2schema/dashboardV2Schema.corpus.test.ts",
]

// The frontend's tests, as jest.sh takes them: public/app's, the API docs page's and the
// scripts', less the golden ones (dashboard-golden's). The decoupled plugins' are their own
// jest projects' (jest.config.js leaves them out).
let frontendTests = "public/app public/swagger scripts/tests \(strings.Join([for t in goldenTests {"'!" + t + "'"}], " "))"

// The databases of upstream's integration jobs, as enve services.
let databases = {
	sqlite: {}
	postgres: {postgres: grafana.services.postgres}
	mysql: {mysql: grafana.services.mysql}
}
let databaseSetup = {
	sqlite: []
	postgres: ["devenv/docker/blocks/postgres_tests/**"]
	mysql: ["devenv/docker/blocks/mysql_tests/**"]
}

// The root jest project (jest.config.js) runs every package's tests and the app's from the
// repository root; jest.sh takes component-relative paths.
let jestTest = {
	_up: string
	out: {
		command: "\(_up)helpers/jest.sh \(_up). {shard_index} {shard_total} . -- {relative_targets}"
		timeout: "30m"
	}
}
let jestResources = {cpus: 2, memory_mb: 6144}

// A changed file selects the component's tests jest relates to it (jest-related.sh: jest
// --listTests --findRelatedTests when enact plans), a changed test itself; a file no test
// imports selects none. jest's graph stops at another package's import, so a dependency's
// change runs the suite whole (no rule matches it), unless jestIgnore decides it. No test
// imports the package's manifest and jest configuration, which shape every test: they run
// the suite whole. The build's configuration no test loads. `_project` is the jest
// project's directory (the root project's, or the component's own config). jest needs the
// installed workspace, which CI's detect job lacks: the job selects after its prepare
// (select_in_job).
let jestScope = {
	_root:    string
	_project: *"." | string
	out: {
		fallback:      "none"
		select_in_job: true
		tests: ["\(_root)/**/*.test.{ts,tsx,js,jsx}"]
		rules: [
			{match: ["\(_root)/{package.json,tsconfig*.json,jest.config.js,jest-setup.js}"], action: "full_component"},
			{match: ["\(_root)/**/*.{ts,tsx,js,jsx,mjs,cjs,json}"], command: "helpers/jest-related.sh \(_project) \(_root) -- {changed_files}"},
			{match: ["\(_root)/{project.json,rollup.config.ts,webpack.config.ts,i18next.config.ts}"], action: "ignore"},
			jestIgnore,
		]
	}
}
// What no jest test loads, whichever component's file it is (an ignore decides a
// dependency's file too): docs, styles and images (jest.config.js maps them to mocks), the
// assets the server serves, the translation catalogs (setupTests.ts inits i18next
// without resources; jest would relate a catalog to every test through the loader's
// dynamic import), and js-root's lint-only configuration (eslint's suppressions change with
// most lint fixes: they ran every jest suite whole).
let jestIgnore = {
	match: [
		"**/*.{md,mdx,scss,css,svg,png,jpg,gif}",
		"public/app/**/*.{html,txt}",
		"public/{boot,fonts,img,locales,maps,gazetteer,sass}/**",
		"public/robots.txt",
		"{eslint.config.js,eslint-suppressions.json,.prettierrc.js,.prettierignore,stylelint.config.js,knip.config.ts,.madgerc,.levignore.js}",
	]
	action: "ignore"
}
// frontend-lint.yml's prettier and eslint over the changed files: eslint's type-aware rules
// load the TypeScript program.
let frontendLint = {
	_up:   string
	_more: *[] | [...{}]
	out: {
		direct: true
		resources: {cpus: 2, memory_mb: 6144}
		tasks: list.Concat([[{
			command: "\(_up)helpers/frontend-lint.sh {relative_changed_files}"
			filter: {
				include: ["**/*.{ts,tsx,js,jsx,mjs,cjs,json,scss,md,mdx}"]
				on_empty: "skip"
			}
		}], _more])
	}
}

// frontend-lint.yml's `yarn themes-generate` check: verifies the generated Sass stylesheets
// (public/sass/grafana.{dark,light}.css) and @grafana/data's theme JSON schema
// (packages/grafana-data/src/themes/schema.generated.json) match their theme sources.
let themesVerify = {
	_cwd:     *"" | string
	_up:      *"" | string
	_include: [...string]
	out: {
		name:    "themes-generate"
		command: "yarn\(_cwd) themes-generate && git diff --exit-code -- \(_up)public/sass/grafana.dark.css \(_up)public/sass/grafana.light.css \(_up)packages/grafana-data/src/themes/schema.generated.json"
		filter: {
			include:  _include
			on_empty: "skip"
		}
	}
}

// i18n-verify.yml and Makefile `i18n-extract`: verifies extracted en-US translation
// catalogs are in sync with `t()` / `<Trans>` calls without writing to disk.
let rootI18nVerify = {
	_cwd:     *"" | string
	_include: [...string]
	_exclude: *[] | [...string]
	out: {
		name:    "i18n-verify"
		command: "LANG=en_US.UTF-8 yarn\(_cwd) run i18next-cli extract --sync-primary --ci --dry-run"
		filter: {
			include: _include
			if len(_exclude) > 0 {
				exclude: _exclude
			}
			on_empty: "skip"
		}
	}
}

let workspaceI18nVerify = {
	_root:    string
	_catalog: string
	out: {
		name:    "i18n-verify"
		command: "LANG=en_US.UTF-8 yarn run i18n-extract --ci --dry-run"
		filter: {
			include: [
				"\(_root)/i18next.config.ts",
				"\(_root)/**/*.{ts,tsx}",
				"\(_root)/\(_catalog)",
			]
			on_empty: "skip"
		}
	}
}

// frontend-lint.yml's `yarn-install-validation`: verifies workspace manifests and lockfile
// satisfy yarn.config.cjs's constraints (`yarn constraints`).
let yarnConstraintsVerify = {
	_include: [...string]
	out: {
		name:    "yarn-constraints"
		command: "yarn constraints"
		filter: {
			include:  _include
			on_empty: "skip"
		}
		timeout: "5m"
	}
}

// A package's `tsc --noEmit`: the program spans the workspace packages it imports (their
// sources, through the `@grafana-app/source` condition).
let tscJob = {
	_command: string
	direct:   true
	resources: {cpus: 2, memory_mb: 6144}
	tasks: [{command: _command, timeout: "20m"}]
}

// The workspace packages under packages/ with tests or types of their own: name, directory,
// the workspace packages their package.json depends on (dependencies, peer and dev: their
// tests import all three), and test shards.
let packages = {
	[string]: {dir: string, deps: [...string], shards: *1 | int, tests: *true | bool, typecheck: *true | bool, lint_more: *[] | [...{}]}
	"@grafana/i18n": {dir: "grafana-i18n", deps: []}
	"@grafana/schema": {dir: "grafana-schema", deps: [], tests: false}
	"@grafana/e2e-selectors": {dir: "grafana-e2e-selectors", deps: []}
	"@grafana/data": {
		dir:    "grafana-data"
		deps:   ["@grafana/i18n", "@grafana/schema"]
		shards: 2
		lint_more: [
			(themesVerify & {
				_cwd:     " --cwd ../.."
				_up:      "../../"
				_include: ["packages/grafana-data/src/themes/**", "packages/grafana-data/scripts/generateSchema.ts"]
			}).out,
			(rootI18nVerify & {
				_cwd:     " --cwd ../.."
				_include: ["packages/grafana-data/**/*.{ts,tsx}"]
			}).out,
		]
	}
	// Its tests import @grafana/test-utils too (a dev dependency), which imports
	// @grafana/runtime, which depends on it: an edge to the test utilities would close a
	// cycle. A change there runs the ui tests that import it only through the frontend.
	"@grafana/ui": {
		dir:    "grafana-ui"
		deps:   ["@grafana/data", "@grafana/e2e-selectors", "@grafana/i18n", "@grafana/schema"]
		shards: 4
		lint_more: [
			(rootI18nVerify & {
				_cwd:     " --cwd ../.."
				_include: ["packages/grafana-ui/**/*.{ts,tsx}"]
			}).out,
		]
	}
	"@grafana/runtime": {dir: "grafana-runtime", deps: ["@grafana/data", "@grafana/e2e-selectors", "@grafana/schema", "@grafana/ui"]}
	"@grafana/api-clients": {dir: "grafana-api-clients", deps: ["@grafana/runtime"]}
	"@grafana/alerting": {
		dir:  "grafana-alerting"
		deps: ["@grafana/api-clients", "@grafana/data", "@grafana/i18n", "@grafana/runtime", "@grafana/test-utils", "@grafana/ui"]
		lint_more: [
			(workspaceI18nVerify & {
				_root:    "packages/grafana-alerting"
				_catalog: "src/locales/en-US/grafana-alerting.json"
			}).out,
		]
	}
	"@grafana/flamegraph": {dir: "grafana-flamegraph", deps: ["@grafana/data", "@grafana/test-utils", "@grafana/ui"]}
	"@grafana/o11y-ds-frontend": {dir: "grafana-o11y-ds-frontend", deps: ["@grafana/data", "@grafana/e2e-selectors", "@grafana/plugin-compat", "@grafana/runtime", "@grafana/ui"]}
	// Its typecheck script is empty.
	"@grafana/openapi": {dir: "grafana-openapi", deps: [], typecheck: false}
	"@grafana/plugin-compat": {dir: "grafana-plugin-compat", deps: ["@grafana/data", "@grafana/runtime", "@grafana/schema"]}
	"@grafana/sql": {
		dir:  "grafana-sql"
		deps: ["@grafana/data", "@grafana/e2e-selectors", "@grafana/i18n", "@grafana/runtime", "@grafana/ui"]
		lint_more: [
			(workspaceI18nVerify & {
				_root:    "packages/grafana-sql"
				_catalog: "src/locales/en-US/grafana-sql.json"
			}).out,
		]
	}
	// The eslint rules the repository lints with (`link:` devDependency): their own tests.
	"@grafana/eslint-plugin": {dir: "grafana-eslint-rules", deps: []}
}

// The decoupled plugins: workspace packages with their own jest config (`yarn run
// test:ci`, plugin:test:ci), which jest.config.js leaves out.
let plugins = {
	[string]: {dir: string, deps: [...string], shards: *1 | int, lint_more: *[] | [...{}]}
	"@grafana-plugins/grafana-azure-monitor-datasource": {
		dir:    "azuremonitor"
		deps:   ["@grafana/data", "@grafana/e2e-selectors", "@grafana/i18n", "@grafana/plugin-configs", "@grafana/runtime", "@grafana/schema", "@grafana/test-utils", "@grafana/ui"]
		shards: 2
		lint_more: [
			(workspaceI18nVerify & {
				_root:    "public/app/plugins/datasource/azuremonitor"
				_catalog: "locales/en-US/grafana-azure-monitor-datasource.json"
			}).out,
		]
	}
	"@grafana-plugins/grafana-testdata-datasource": {dir: "grafana-testdata-datasource", deps: ["@grafana/data", "@grafana/e2e-selectors", "@grafana/plugin-configs", "@grafana/runtime", "@grafana/schema", "@grafana/ui"]}
	"@grafana-plugins/graphite": {dir: "graphite", deps: ["@grafana/data", "@grafana/plugin-configs", "@grafana/runtime", "@grafana/schema", "@grafana/ui"]}
}

pipeline: {
	// `make -C apps/dashboard generate-golden-files` writes the migration and conversion
	// golden JSON files (git-ignored under apps/dashboard/pkg/migration/.gitignore) that
	// dashboard-golden's parity tests read.
	analysis: derived: [{
		outputs: [
			"apps/dashboard/pkg/migration/testdata/output/**",
			"apps/dashboard/pkg/migration/testdata/dev-dashboards-output/**",
			"apps/dashboard/pkg/migration/conversion/testdata/output/**",
			"apps/dashboard/pkg/migration/conversion/testdata/migrated_dashboards_output/**",
		]
		inputs: [
			"apps/dashboard/Makefile",
			"apps/dashboard/go.mod",
			"apps/dashboard/go.sum",
			"apps/dashboard/pkg/apis/**",
			"apps/dashboard/pkg/migration/**",
		]
		exclude: [
			"apps/dashboard/pkg/migration/testdata/output/**",
			"apps/dashboard/pkg/migration/testdata/dev-dashboards-output/**",
			"apps/dashboard/pkg/migration/conversion/testdata/output/**",
			"apps/dashboard/pkg/migration/conversion/testdata/migrated_dashboards_output/**",
		]
	}]

	components: {
		// What every component runs with: the environment, the pipeline and CI, and the
		// services' setup. Files only one ecosystem's components use are go-root's or
		// js-root's.
		root: {
			title: "Environment, pipeline and CI"
			root:  "."
			watch_paths: [
				"enve.cue",
				"enve.lock",
				".enact/**",
				// Upstream's module, which enve and enact load the pipeline through; the root
				// Go package embeds it too (embed.go).
				"cue.mod/**",
				".github/workflows/ci.yml",
				// The enact and enve builds the fork commits for its CI (scripts/fork-push.sh).
				"bin/linux-x86_64/**",
				"bin/linux-aarch64/**",
				"helpers/lib.sh",
				"helpers/postgres-setup.sh",
				"helpers/mysql-setup.sh",
				".gitattributes",
				".gitignore",
				".ignore",
				".editorconfig",
				// Grafana's run state (git-ignored), harness to every footprint: tests that
				// load the config from the repository append to and read back
				// data/log/grafana.log (LEARNINGS.md 15).
				"data/**",
			]
		}

		// The Go workspace, its pinned tools and the Makefile (Go builds and codegen): a
		// change runs every Go suite whole, as upstream's do.
		"go-root": {
			title:      "Go workspace and tooling"
			technology: "go"
			root:       "."
			watch_paths: [
				"go.mod",
				"go.sum",
				"go.work",
				"go.work.sum",
				"Makefile",
				".golangci.yml",
				".air.toml",
				".citools/**",
				"pkg/ruleguard.rules.go",
				"hack/**",
				"tools/**",
				"scripts/ci/backend-tests/**",
				"scripts/go-workspace/**",
				"scripts/modowners/**",
				"helpers/go-packages.sh",
				"helpers/go-test.sh",
				"helpers/go-lint.sh",
			]
			depends_on: ["root"]
			// go.work names every workspace module and go.mod replaces with them: a Go
			// command fails unless all of them are checked out, and `go mod tidy` on the
			// root module reads every package and go:embed directory of the repo.
			workspace_scope: include: [
				"pkg",
				"apps",
				"kinds",
				"devenv",
				"public/app/plugins",
				"hack",
				"tools",
				"scripts",
				".citools",
				"embed.go",
			]
			jobs: lint: {
				direct: true
				resources: {cpus: 4, memory_mb: 8192}
				tasks: [
					{
						name:    "modowners"
						command: "go run scripts/modowners/modowners.go check go.mod"
						filter: {
							include: ["go.mod", "scripts/modowners/**"]
							on_empty: "skip"
						}
						timeout: "5m"
					},
					(goWorkspaceVerify & {
						_include: ["go.mod", "go.sum", "go.work", "go.work.sum", "scripts/go-workspace/**"]
					}).out,
				]
			}
		}

		// The yarn workspace, the root jest project's setup and the shared frontend
		// configuration: a change runs every frontend suite whole, as upstream's
		// `frontend` filter does.
		"js-root": {
			title: "Yarn workspace and frontend tooling"
			// The packages depending on it get the yarn install.
			technology: "typescript"
			root:       "."
			watch_paths: [
				"package.json",
				"yarn.lock",
				".yarnrc.yml",
				".yarn/**",
				"yarn.config.cjs",
				"nx.json",
				"project.json",
				".nvmrc",
				".browserslistrc",
				"tsconfig.json",
				"tsconfig.smoke.json",
				"jest.config.js",
				"jest.config.codeowner.js",
				"eslint.config.js",
				"eslint-suppressions.json",
				".prettierrc.js",
				".prettierignore",
				"stylelint.config.js",
				"knip.config.ts",
				"i18next.config.ts",
				".madgerc",
				".levignore.js",
				".nxignore",
				"scripts/tsconfig.base.json",
				"scripts/webpack/**",
				"scripts/rspack/**",
				"scripts/release/**",
				"scripts/cli/**",
				"scripts/codemods/**",
				"scripts/codeowners-manifest/**",
				"scripts/*.js",
				"scripts/*.ts",
				"scripts/tests/**",
				"scripts/docs/**",
				"packages/README.md",
				"packages/rollup.config.parts.ts",
				// Vendored forks installed through the lockfile's resolutions.
				"packages/get-document/**",
				"packages/mapbox-jsonlint-lines-primitives/**",
				// The root jest project's setup (jest.config.js `setupFiles`, `resolver`,
				// `moduleNameMapper`) and what it imports from the packages: every test of
				// the project runs it.
				"public/test/**",
				"packages/grafana-runtime/src/services/pluginExtensions/usePluginComponents.ts",
				"packages/grafana-test-utils/src/matchers/**",
				"packages/grafana-api-clients/src/clients/rtkq/folder/v1beta1/**",
				"public/app/core/app_events.ts",
				"public/app/features/dashboard/api/DashboardAPIVersionResolver.ts",
				"public/app/features/dashboard-scene/saving/__mocks__/createDetectChangesWorker.ts",
				"public/app/features/plugins/extensions/useLoadAppPlugins.tsx",
				"public/app/features/plugins/extensions/usePluginComponents.tsx",
				"helpers/jest.sh",
				"helpers/jest-related.sh",
				"helpers/jest-filter.cjs",
				"helpers/jest-attribution.cjs",
				"helpers/frontend-lint.sh",
				"helpers/plugin-typecheck.sh",
			]
			depends_on: ["root"]
			// The root jest project's setup and yarn's workspace: jest-setup.ts and setupTests.ts
			// import the app (app_events, the store, the dashboard API), whose imports reach
			// most of public/app; scripts/cli is setupTests'; `yarn install --immutable`
			// resolves every workspace's manifest (package.json `workspaces`: packages, the
			// decoupled plugins under public, e2e's test plugins); .yarn holds yarn's release.
			// public/app/core/utils/shortLinks.ts imports the short URL app's generated types, and
			// dashboardSchemaFetcher.test.ts the dashboard conversion's committed input fixtures.
			workspace_scope: include: [".yarn", "scripts", "public", "apps/shorturl/plugin/src", "apps/dashboard/pkg/migration/conversion/testdata/input", "packages", "e2e-playwright/test-plugins"]
			jobs: lint: (frontendLint & {
				_up: ""
				_more: [
					{
						name:    "yarn-dedupe"
						command: "yarn dedupe --check"
						filter: {
							include: ["package.json", "yarn.lock", ".yarnrc.yml"]
							on_empty: "skip"
						}
						timeout: "5m"
					},
					(yarnConstraintsVerify & {
						_include: ["package.json", "yarn.lock", "yarn.config.cjs"]
					}).out,
					(themesVerify & {
						_include: ["scripts/cli/generateSassVariableFiles.ts", "scripts/cli/themeTemplates/**"]
					}).out,
					(rootI18nVerify & {
						_include: ["i18next.config.ts"]
					}).out,
				]
			}).out
			jobs: typecheck: {
				direct: true
				resources: {cpus: 2, memory_mb: 6144}
				tasks: [{
					name:    "typecheck:smoke"
					command: "yarn run typecheck:smoke"
					filter: {
						include: [
							"tsconfig.smoke.json",
							"scripts/tsconfig.base.json",
							"scripts/cuj-smoke.ts",
						]
						on_empty: "skip"
					}
					timeout: "5m"
				}]
			}
		}

		// The platform modules: identity, the API server, the plugin SDK, unified storage's
		// data model and its kv store, sqlite.
		base: {
			title:      "Go platform modules"
			technology: "go"
			root:       "."
			watch_paths: [for m in baseModules {"\(m)/**"}]
			depends_on: ["go-root"]
			resources: {cpus: 4, memory_mb: 8192}
			shards:   2
			recorder: "trace"
			jobs: lint: (goLint & {
				_more: [
					(goWorkspaceVerify & {
						_include: [for m in baseModules {"\(m)/go.{mod,sum}"}]
					}).out,
				]
			}).out
			test: {
				command: "helpers/go-test.sh base {shard_index} {shard_total} {targets}"
				timeout: "30m"
			}
			target_scope: {
				fallback: "none"
				tests: [for m in baseModules {"\(m)/**/*_test.go"}]
				// `-short` skips them: integration-<db>:test runs them.
				exclude_test_names: "^TestIntegration"
				rules: (goRules & {_suite: "base"}).out
			}
		}

		// Upstream's backend unit tests: `go test -short` of every package with tests, in
		// 8 shards (backend-unit-tests.yml).
		backend: {
			title:      "Go backend (root module and apps)"
			technology: "go"
			root:       "."
			watch_paths: backendSources
			depends_on: ["go-root", "base"]
			workspace_scope: include: backendTrees
			resources: {cpus: 4, memory_mb: 12288}
			shards:   8
			recorder: "trace"
			// A recording runs one traced `go test -run` at a time: ~1.2 cores, 1-2.3 GB
			// peaks. At the test size (x2 RAM: 24 GB) its 8 shards ran one at a time.
			record_resources: {cpus: 1.5, memory_mb: 3072}
			jobs: lint: (goLint & {
				_more: [
					(goWorkspaceVerify & {
						_include: ["{pkg,apps}/**/go.{mod,sum}"]
					}).out,
					{
						name:    "wire"
						command: "make gen-go && git diff --exit-code -- pkg/server/wire_gen.go pkg/server/bootstrap/wire/"
						filter: {
							include: ["pkg/build/wire/**", "pkg/server/**"]
							on_empty: "skip"
						}
						timeout: "10m"
					},
					{
						name:    "codegen"
						command: "make fix-cue && git diff --exit-code -- '**/*.cue' && CODEGEN_VERIFY=1 make gen-cue && git diff --exit-code -- apps/dashboard/pkg/apis/dashboard/ && CODEGEN_VERIFY=1 make gen-jsonnet && git diff --exit-code -- devenv/ && CODEGEN_VERIFY=1 make gen-app-manifests-unistore"
						filter: {
							include: [
								"kinds/**",
								"pkg/codegen/**",
								"pkg/kindsys/**",
								"pkg/plugins/codegen/**",
								"public/app/plugins/gen.go",
								"public/app/plugins/**/plugin.json",
								"apps/**/*.cue",
								"devenv/jsonnet/**",
								"devenv/dev-dashboards/**",
								"pkg/storage/unified/resource/**",
							]
							on_empty: "skip"
						}
						timeout: "15m"
					},
					{
						name:    "swagger"
						command: "bash -c 'trap \"git checkout -- public/api-merged.json 2>/dev/null || true; rm -f public/api-spec.json\" EXIT; make swagger-gen'"
						filter: {
							include: [
								"pkg/api/**",
								"pkg/server/**",
								"pkg/services/ngalert/api/**",
							]
							on_empty: "skip"
						}
						timeout: "15m"
					},
				]
			}).out
			test: {
				command: "helpers/go-test.sh backend {shard_index} {shard_total} {targets}"
				timeout: "45m"
			}
			target_scope: {
				fallback: "none"
				tests: ["{pkg,apps}/**/*_test.go"]
				// `-short` skips them: integration-<db>:test runs them, of the files both
				// suites share.
				exclude_test_names: "^TestIntegration"
				// go-packages.sh leaves the platform modules to base:test, so a test is one
				// suite's (a retrace replaces its target's footprint, never unions suites).
				not_run: list.Concat([_backendNotRun, [{
					reason: "a platform module's: base:test runs it"
					tests: [for m in baseModules {"\(m)/**/*_test.go"}]
				}]])
				rules: (goRules & {_suite: "backend"}).out
			}
		}

		// pr-test-integration.yml: the `TestIntegration` tests of every workspace module, on
		// sqlite and against PostgreSQL and MySQL (GRAFANA_TEST_DB).
		for db, dbServices in databases {
			"integration-\(db)": {
				title:      "Integration tests (\(db))"
				technology: "go"
				root:       "."
				watch_paths: list.Concat([backendSources, databaseSetup[db]])
				depends_on: ["go-root", "base"]
				workspace_scope: include: backendTrees
				// A server-backed shard runs one package at a time (-p=1) and averages under 1.5
				// cpus (mysql 0.7, postgres 1.4); sqlite runs packages in parallel (3-4).
				resources: {cpus: [if db == "sqlite" {4}, 2][0], memory_mb: 8192}
				shards: [if db == "sqlite" {4}, 8][0]
				if db == "sqlite" {
					recorder: "trace"
					// One traced `go test -run` at a time, as backend's recording.
					record_resources: {cpus: 1.5, memory_mb: 4096}
				}
				services: dbServices
				test: {
					command: "helpers/go-test.sh integration {shard_index} {shard_total} {targets}"
					timeout: "60m"
					if db != "sqlite" {
						env: GRAFANA_TEST_DB: db
					}
				}
				target_scope: {
					fallback: "none"
					tests:    _integrationTests
					// go-test.sh's `-run '^TestIntegration'`: its files' other tests are
					// backend's (or base's).
					test_names: "^TestIntegration"
					if db != "sqlite" {
						footprints_from: "integration-sqlite:test"
					}
					rules: (goRules & {_suite: "integration"}).out
				}
			}
		}

		for name, p in packages {
			(name): {
				title:      "\(name) package"
				technology: "typescript"
				root:       "packages/\(p.dir)"
				depends_on: list.Concat([["js-root"], p.deps])
				if p.typecheck {
					jobs: typecheck: tscJob & {_command: "yarn run typecheck"}
				}
				jobs: lint: (frontendLint & {
					_up: "../../"
					_more: list.Concat([
						p.lint_more,
						[(yarnConstraintsVerify & {_include: ["packages/\(p.dir)/package.json"]}).out],
					])
				}).out
				// A jest shard's workers transform TypeScript in parallel.
				resources: jestResources
				if p.tests {
					recorder: "own_linux"
					recorded_by: ["enact-node"]
					test:     (jestTest & {_up: "../../"}).out
					shards:   p.shards
					target_scope: (jestScope & {_root: "packages/\(p.dir)"}).out
				}
			}
		}

		// The test utilities have a jest config of their own (packages:test:ci).
		"@grafana/test-utils": {
			title:      "@grafana/test-utils package"
			technology: "typescript"
			root:       "packages/grafana-test-utils"
			depends_on: ["js-root", "@grafana/api-clients", "@grafana/runtime"]
			resources: jestResources
			jobs: typecheck: tscJob & {_command: "yarn run typecheck"}
			jobs: lint: (frontendLint & {
				_up:   "../../"
				_more: [(yarnConstraintsVerify & {_include: ["packages/grafana-test-utils/package.json"]}).out]
			}).out
			recorder: "own_linux"
			recorded_by: ["enact-node"]
			test: {
				command: "../../helpers/jest.sh . {shard_index} {shard_total} . -- {relative_targets}"
				timeout: "20m"
			}
			target_scope: (jestScope & {_root: "packages/grafana-test-utils", _project: "packages/grafana-test-utils"}).out
		}

		// The decoupled plugins' build and jest configuration.
		"@grafana/plugin-configs": {
			title:      "@grafana/plugin-configs package"
			technology: "typescript"
			root:       "packages/grafana-plugin-configs"
			depends_on: ["js-root"]
			jobs: lint: (frontendLint & {
				_up:   "../../"
				_more: [(yarnConstraintsVerify & {_include: ["packages/grafana-plugin-configs/package.json"]}).out]
			}).out
		}

		for name, p in plugins {
			(name): {
				title:      "\(name) (decoupled plugin)"
				technology: "typescript"
				root:       "public/app/plugins/datasource/\(p.dir)"
				depends_on: list.Concat([["js-root"], p.deps])
				// Upstream's root `tsc` checks them (tsconfig.json includes public/app): that
				// program narrowed to the plugin. Their own tsconfig.json (the plugin build's,
				// TypeScript 6) fails at the pin.
				jobs: typecheck: tscJob & {_command: "../../../../../helpers/plugin-typecheck.sh ."}
				jobs: lint: (frontendLint & {
					_up: "../../../../../"
					_more: list.Concat([
						p.lint_more,
						[(yarnConstraintsVerify & {_include: ["public/app/plugins/datasource/\(p.dir)/package.json"]}).out],
					])
				}).out
				shards: p.shards
				resources: jestResources
				recorder:  "own_linux"
				recorded_by: ["enact-node"]
				test: {
					command: "../../../../../helpers/jest.sh . {shard_index} {shard_total} . -- {relative_targets}"
					timeout: "20m"
				}
				target_scope: (jestScope & {_root: "public/app/plugins/datasource/\(p.dir)", _project: "public/app/plugins/datasource/\(p.dir)"}).out
			}
		}

		// The app: public/app but the decoupled plugins, and the static assets it ships.
		// Upstream's 16-shard `yarn run test:ci` over the root jest project, less the
		// packages' tests, which are theirs.
		frontend: {
			title:      "Frontend app"
			technology: "typescript"
			root:       "."
			watch_paths: [
				"public/app/{api,core,extensions,features,routes,store,types}/**",
				"public/app/plugins/panel/**",
				"public/app/plugins/datasource/{alertmanager,dashboard,grafana,mixed}/**",
				"public/app/{AppWrapper.tsx,app.ts,dev-utils.ts,dev.ts,index.ts,initApp.ts,initPreferences.ts,initPreferences.test.ts,legacyAPIHandling.ts,legacyAPIHandling.test.ts,polyfills.ts}",
				"public/{boot,fonts,img,lib,locales,maps,gazetteer,sass,swagger,vendor}/**",
				"public/{api-enterprise-spec.json,api-merged.json,openapi3.json,mockServiceWorker.js,robots.txt}",
				// The short URL app's generated client types (core/utils/shortLinks.ts).
				"apps/shorturl/plugin/src/**",
			]
			depends_on: ["js-root", "@grafana/alerting", "@grafana/api-clients", "@grafana/data", "@grafana/e2e-selectors", "@grafana/flamegraph", "@grafana/i18n", "@grafana/o11y-ds-frontend", "@grafana/runtime", "@grafana/schema", "@grafana/sql", "@grafana/ui", "@grafana/test-utils"]
			resources: {cpus: 4, memory_mb: 8192}
			shards: 8
			jobs: lint: (frontendLint & {
				_up: ""
				_more: [
					(themesVerify & {
						_include: ["public/sass/**"]
					}).out,
					(rootI18nVerify & {
						_include: [
							"public/locales/en-US/grafana.json",
							"public/**/*.{ts,tsx}",
						]
						_exclude: [
							"public/lib/monaco/**",
							"public/app/extensions/**",
							"public/app/plugins/datasource/**",
						]
					}).out,
				]
			}).out
			// frontend-lint.yml's typecheck: the root project, every package's sources
			// included (the `@grafana-app/source` condition) and the CUJ smoke drivers
			// (tsconfig.smoke.json). tsc is TypeScript 7 (native): 7.2 GiB peak RSS, cold;
			// upstream gives Node an 8 GiB heap on its `ubuntu-x64` runner. Sized to fit the
			// 13G `standard` worker the preflight stage runs on (a tonky-ci slot).
			jobs: typecheck: {
				direct: true
				resources: {cpus: 4, memory_mb: 9216}
				tasks: [
					{command: "yarn tsc --noEmit", timeout: "30m"},
					{
						name:    "typecheck:smoke"
						command: "yarn run typecheck:smoke"
						filter: {
							include: [
								"public/app/core/journeys/__smoke__/**/*.ts",
								"public/app/core/journeys/*.smoke.ts",
							]
							on_empty: "skip"
						}
						timeout: "5m"
					},
				]
			}
			recorder: "own_linux"
			recorded_by: ["enact-node"]
			// A recording attributes one test file at a time: ~1.2 cores, 1.6-2.2 GB peaks.
			// At the test size (x2 RAM: 16 GB) its 8 shards ran one at a time (~30 min).
			record_resources: {cpus: 1.5, memory_mb: 3072}
			test: {
				command: "helpers/jest.sh . {shard_index} {shard_total} \(frontendTests) -- {targets}"
				timeout: "45m"
			}
			target_scope: {
				fallback:      "none"
				select_in_job: true // jest-related.sh needs node_modules (jestScope)
				tests: [
					"public/app/{api,core,extensions,features,routes,store,types}/**/*.test.{ts,tsx,js,jsx}",
					"public/app/plugins/panel/**/*.test.{ts,tsx,js,jsx}",
					"public/app/plugins/datasource/{alertmanager,dashboard,grafana,mixed}/**/*.test.{ts,tsx,js,jsx}",
					"public/app/{initPreferences,legacyAPIHandling}.test.ts",
					"public/swagger/**/*.test.{ts,tsx,js,jsx}",
				]
				exclude: goldenTests
				rules: [
					// Modules the tests import: a changed one selects the tests jest relates to
					// it (jestScope), none when no test imports it: most core plugins'
					// plugin.json (the Go backend reads them), the API specs (the docs page
					// fetches them by URL).
					{
						match: [
							"public/{app,swagger,vendor,lib}/**/*.{ts,tsx,js,jsx,mjs,cjs,json}",
							"public/{api-enterprise-spec.json,api-merged.json,openapi3.json,mockServiceWorker.js}",
							"apps/shorturl/plugin/src/**",
						]
						command: "helpers/jest-related.sh . \(frontendTests) -- {changed_files}"
					},
					jestIgnore,
				]
			}
		}

		// The bridge of the two ecosystems: the Go migration's golden outputs (apps/dashboard,
		// which imports only base's apimachinery) and the frontend tests reading them.
		"dashboard-golden": {
			title:      "Dashboard migration golden files"
			technology: ["go", "typescript"]
			root:       "."
			watch_paths: list.Concat([[
				"apps/dashboard/Makefile",
				"apps/dashboard/go.mod",
				"apps/dashboard/go.sum",
				"apps/dashboard/pkg/apis/**",
				"apps/dashboard/pkg/migration/**",
				"helpers/dashboard-golden.sh",
			], goldenTests])
			depends_on: ["frontend", "base"]
			resources: {cpus: 4, memory_mb: 8192}
			recorder:  "own_linux"
			test: {
				command: "helpers/dashboard-golden.sh {targets}"
				timeout: "20m"
			}
			target_scope: {
				fallback: "none"
				tests: goldenTests
				rules: [
					// A change to the Go side changes the outputs: every golden test.
					{match: ["apps/dashboard/**"], action: "full_component"},
					// A changed golden test stands for itself. (A frontend module is a
					// dependency's file: its change runs every golden test.)
					{match: goldenTests, command: "echo {changed_files}"},
					{match: ["helpers/dashboard-golden.sh"], action: "full_component"},
					// The frontend's files no test loads (the locale catalogs, styles,
					// assets) change no golden output.
					jestIgnore,
				]
			}
		}

		// The Playwright suites and their test plugins (the browser is enve's
		// pkgs.#PlaywrightBrowsers).
		e2e: {
			title: "End-to-end tests (Playwright)"
			root:  "e2e-playwright"
			watch_paths: ["e2e-playwright/**", "playwright.config.ts", "playwright.storybook.config.ts", "helpers/playwright.sh", "helpers/e2e-build.sh"]
			depends_on: ["backend", "frontend"]
			resources: {cpus: 4, memory_mb: 8192}
			shards: 4
			jobs: {
				lint: (frontendLint & {_up: "../"}).out
				// What every shard runs against, built once (upstream's build-backend and
				// build-frontend jobs): CI builds it in a job of its own, cached under its
				// key, and each shard restores it.
				build: {
					services: false
					resources: {cpus: 4, memory_mb: 12288}
					outputs: {
						paths: ["bin/grafana", "public/build", "e2e-playwright/test-plugins/*/dist", "data/plugins-bundled"]
						// The backend's and the frontend's sources, the test plugins' and the
						// top-level manifests and configs (go.mod, package.json, yarn.lock, nx.json,
						// the Makefile, ...).
						key: ["*", ".yarn/**", "apps/**", "cue.mod/**", "kinds/**", "packages/**", "pkg/**", "public/**", "scripts/**", "e2e-playwright/test-plugins/**", "helpers/e2e-build.sh"]
					}
					tasks: [{command: "../helpers/e2e-build.sh", timeout: "40m"}]
				}
				test: {
					needs: ["build"]
					tasks: [{
						command: "../helpers/playwright.sh {shard_index} {shard_total} {relative_targets}"
						timeout: "45m"
					}]
				}
			}
			workspace_scope: {
				include: [
					"e2e-playwright",
					"playwright.config.ts",
					"playwright.storybook.config.ts",
					"conf",
					"devenv",
					"emails",
					"public",
					"packages",
					"scripts",
					"pkg",
					"apps",
					"kinds",
					"embed.go",
					"Makefile",
					"go.mod",
					"go.sum",
					"go.work",
					"go.work.sum",
				]
				include_dependencies: true
			}
			target_scope: {
				fallback: "all"
				tests: ["e2e-playwright/**/*.spec.ts"]
				not_run: [{
					tests: [
						"e2e-playwright/cloud-plugins-suite/azure-monitor.spec.ts",
						"e2e-playwright/dashboards-search-suite/dashboards-search.spec.ts",
						"e2e-playwright/plugin-e2e/cloudmonitoring/cloudmonitoring.spec.ts",
						"e2e-playwright/plugin-e2e/loki/loki.spec.ts",
						"e2e-playwright/storybook/verify.spec.ts",
					]
					reason: "Specs outside playwright.config.ts or skipped by --grep-invert @cloud-plugins (cloud-plugins-suite is @cloud-plugins; storybook runs under playwright.storybook.config.ts; dashboards-search-suite, cloudmonitoring, and loki have no project in playwright.config.ts)"
				}]
				rules: [
					{match: ["e2e-playwright/**/*.ts"], engine: "typescript"},
					jestIgnore,
				]
			}
		}

		// No task: documentation, release and packaging, upstream's own CI and bots, and
		// development setups.
		repository: {
			title: "Docs, packaging, upstream CI and dev setups"
			root:  "."
			watch_paths: [
				"*.md",
				"LICENSE",
				"docs/**",
				"contribute/**",
				".changelog-archive/**",
				".github/**",
				".claude/**",
				".vscode/**",
				".zed/**",
				".vim/**",
				"local/**",
				"devenv/**",
				"packaging/**",
				"grafana-mixin/**",
				// The release, packaging and CI shell scripts; the TypeScript ones are js-root's.
				"scripts/*.sh",
				"scripts/*.py",
				"scripts/catalog-plugins-defaults",
				"scripts/build/**",
				"scripts/grafana-server/**",
				"scripts/helpers/**",
				"scripts/verify-repo-update/**",
				"scripts/ci/**",
				"Dockerfile",
				".dockerignore",
				".policy.yml",
				".policy.yml.tmpl",
				".vale.ini",
				"crowdin.yml",
				"relyance.yaml",
				"latest.json",
				"lefthook.yml",
				"lefthook.rc",
				"mise.toml",
			]
			depends_on: ["root"]
		}
	}
}
