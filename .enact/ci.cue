package enact

import (
	"enact.dev/schema"
	"github.com/grafana/grafana:enve"
)

let J = pipeline.#jobs

_stages: [
	{name: "preflight", select: [J.lint, J.typecheck], fail_fast: true, services: "disabled"},
	{name: "tests", matrix: true, select: [J.test], fail_fast: false, services: "on_demand"},
]

// Services from enve.cue at the repository root, typed for enact.
grafana: services: enve.profiles.dev.services & {
	postgres: enact: kind: "postgres"
	mysql: enact: kind:    "mysql"
}

pipeline: schema.#Pipeline & {
	name:        "grafana"
	description: "Grafana: Go backend, pnpm-workspace frontend, database integration suites"
	workspace_scope: include: [".enact", "cue.mod", "enve.cue", "enve.lock", "helpers"]
	services: grafana.services
	// CI's matrix jobs install the pnpm workspace (pnpm-lock.yaml) before the frontend's tasks.
	toolchain: node: package_manager: "pnpm"
	ci: {
		soft_placement: {fallback_seconds: 15}
		diagnostic_paths: [
			".enact/state/diagnostics/grafana-e2e/*/results/**",
			".enact/state/diagnostics/grafana-e2e/*/grafana-server.log",
		]
		rerun: {labels: ["rerun", "showcase"], branch_prefixes: ["showcase/"]}
		remote_cache: {
			secrets: {bucket: "R2_BUCKET", access_key_id: "R2_ACCESS_KEY_ID", secret_access_key: "R2_SECRET_ACCESS_KEY"}
			public_url: "https://cache.tonky.dev"
			public_key: "enve-r2-1:ckHPTeWVef6mba+1AwWHjKYCsUWKPfP9IXPm5YXNoHg="
			repo:       "tonky/grafana"
			branch:     "perf/ci-showcase"
		}
		// Runner sizes within ibp8/mac1 shared host budget (agentic/KNOWLEDGE.md tonky-ci).
		concurrency: {max_parallel_jobs: 20}
		workers: {
			github: {
				preset: "github-public", labels: ["ubuntu-24.04"]
				tier: "on_demand", available: 20, cost_per_min: 0
				setup_overhead_sec: 300
				timeout_minutes: 90
			}
		}
	}
	workflows: {
		ci: {
			layout:   "staged"
			services: "on_demand"
			triggers: {
				push: branches:         ["main", "perf/ci-showcase"]
				pull_request: branches: ["main", "perf/ci-showcase"]
			}
			stages: _stages
		}
		local: {
			layout:   "staged"
			services: "on_demand"
			stages:   _stages
		}
	}
}
