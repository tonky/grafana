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
		concurrency: max_parallel_jobs: 16
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
				push: branches: ["main", "perf/ci-showcase"]
				pull_request: branches: ["main"]
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
