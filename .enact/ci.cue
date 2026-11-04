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
	description: "Grafana: Go backend, yarn-workspace frontend, database integration suites"
	workspace_scope: include: [".enact", "cue.mod", "enve.cue", "enve.lock", "helpers"]
	services: grafana.services
	// CI's matrix jobs install the yarn workspace (yarn.lock) before the frontend's tasks.
	toolchain: node: package_manager: "yarn"
	ci: {
		rerun: {labels: ["rerun", "showcase"], branch_prefixes: ["showcase/"]}
		concurrency: max_parallel_jobs: 16
		remote_cache: {
			secrets: {bucket: "R2_BUCKET", access_key_id: "R2_ACCESS_KEY_ID", secret_access_key: "R2_SECRET_ACCESS_KEY"}
			public_url: "https://pub-30fd937eb7634039b8c49d49bfec91a9.r2.dev"
			public_key: "enve-r2-1:ckHPTeWVef6mba+1AwWHjKYCsUWKPfP9IXPm5YXNoHg="
			repo:       "tonky/grafana"
			branch:     "perf/ci-showcase"
		}
		// Runner sizes within ibp8/mac1 shared host budget (agentic/KNOWLEDGE.md tonky-ci).
		workers: {
			standard: {
				labels:          ["self-hosted", "Linux", "X64", "tonky-ci"]
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.010
				timeout_minutes: 60
				pool: {
					cpus:      14
					memory_mb: 28672
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
						"tonky-ci-l": {cpus: 6, memory_mb: 13312}
					}
				}
			}
			arm64: {
				labels:          ["self-hosted", "Linux", "ARM64", "tonky-ci"]
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.008
				timeout_minutes: 60
				pool: {
					cpus:      4
					memory_mb: 8192
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
					}
				}
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
		nightly: {
			layout:   "staged"
			scope:    "all"
			services: "on_demand"
			triggers: {
				schedule: ["0 3 * * *"]
				workflow_dispatch: true
			}
			stages: [
				{name: "tests", matrix: true, select: [J.test], fail_fast: false, services: "on_demand"},
			]
		}
	}
}
