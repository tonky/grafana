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
	workspace_scope: {
		include: [".enact", "cue.mod", "enve.cue", "enve.lock", "helpers"]
		// Per-revision generated integration test inventory: excluded from component change
		// matching so parent->child inventory diffs never trigger `root` in Detect.
		ignore: [".enact/go_integration_inventory.cue"]
	}
	services: grafana.services
	// CI's matrix jobs install the pnpm workspace (pnpm-lock.yaml) before the frontend's tasks.
	toolchain: node: package_manager: "pnpm"
	ci: {
		soft_placement: {fallback_seconds: 15}
		scheduler: {makespan_tolerance: 1.05, default_task_sec: 180}
		history: {workflow: ".github/workflows/ci.yml"}
		diagnostic_paths: [
			".enact/state/diagnostics/grafana-e2e/*/results/**",
			".enact/state/diagnostics/grafana-e2e/*/grafana-server.log",
		]
		rerun: {labels: ["rerun", "showcase"], branch_prefixes: ["showcase/"]}
		remote_cache: {
			secrets: {
				bucket:                 "R2_BUCKET"
				access_key_id:          "R2_ACCESS_KEY_ID"
				secret_access_key:      "R2_SECRET_ACCESS_KEY"
				read_access_key_id:     "R2_READ_ACCESS_KEY_ID"
				read_secret_access_key: "R2_READ_SECRET_ACCESS_KEY"
			}
			public_url: "https://cache.tonky.dev"
			public_key: "enve-r2-1:ckHPTeWVef6mba+1AwWHjKYCsUWKPfP9IXPm5YXNoHg="
			repo:       "tonky/grafana"
			branch:     "perf/ci-showcase"
		}
		allow_broad: branch_prefixes: ["mirror-broad/"]
		// Runner pools calibrated from measured Grafana/PostHog/n8n runs (agentic/KNOWLEDGE.md tonky-ci).
		workers: {
			github: {
				// Standard public capacity; one declared image shares the account quota.
				preset: "github-public", labels: ["ubuntu-24.04"], quota_group: "github-public"
				tier: "on_demand", available: 20, cost_per_min: 0
				// Calibrated from measured 58-87s cold preparation on ubuntu-24.04.
				setup_overhead_sec: 80
				throughput:         0.75
				timeout_minutes:    90
			}
			standard: {
				labels:          ["self-hosted", "Linux", "X64", "tonky-ci"]
				host_id:         "ibp8"
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.010
				throughput:      1.0
				timeout_minutes: 90
				pool: {
					cpus:      14
					memory_mb: 28672
					quantization: {
						label_prefix:       "tonky-ci"
						cpu_step:           1
						memory_step_mb:     1024
						runtime_reserve_mb: 2048
						min: {cpus: 1, memory_mb: 4096}
						max: {cpus: 6, memory_mb: 13312}
						control: {cpus: 2, memory_mb: 4096}
					}
				}
			}
			arm64: {
				labels:          ["self-hosted", "Linux", "ARM64", "tonky-ci"]
				host_id:         "mac1"
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.010
				throughput:      1.35
				timeout_minutes: 90
				pool: {
					cpus:      16
					memory_mb: 36864
					quantization: {
						label_prefix:       "tonky-ci"
						cpu_step:           1
						memory_step_mb:     1024
						runtime_reserve_mb: 2048
						min: {cpus: 1, memory_mb: 4096}
						max: {cpus: 6, memory_mb: 13312}
						control: {cpus: 2, memory_mb: 4096}
					}
				}
			}
			l7: {
				// A second X64 host (16t, ~13 GiB free), up to 8c/8G allocations when idle.
				// A gate lane holding l7 drains its dispatcher to zero.
				labels: ["self-hosted", "Linux", "X64", "tonky-ci"], host_id: "l7", tier: "dedicated", available: 1, cost_per_min: 0.006, throughput: 0.95, timeout_minutes: 90
				pool: {
					cpus: 16, memory_mb: 13312
					quantization: {
						label_prefix:       "tonky-ci"
						cpu_step:           1
						memory_step_mb:     1024
						runtime_reserve_mb: 2048
						min: {cpus: 1, memory_mb: 4096}
						max: {cpus: 8, memory_mb: 8192}
						control: {cpus: 2, memory_mb: 4096}
					}
				}
			}
		}
	}
	workflows: {
		ci: {
			layout:      "staged"
			services:    "on_demand"
			concurrency: {scope: "branch", cancel_in_progress: true}
			triggers: {
				push: branches:         ["main", "master", "perf/ci-showcase"]
				pull_request: branches: ["main", "master", "perf/ci-showcase"]
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
