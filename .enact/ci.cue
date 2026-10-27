package enact

pipeline: {
	// CI's matrix jobs install the yarn workspace (yarn.lock) before the frontend's tasks.
	toolchain: node: package_manager: "yarn"
	ci: {
		concurrency: {
			max_parallel_jobs: 16
		}
		// The fork's jobs run on the user's tonky-ci fleet, one fresh container per job (enact's
		// .enact/workflows.cue workers `tonky-ci`, `tonky-ci-arm64`): stage jobs on the x86_64
		// slots, matrix rows on the cheapest slot they fit, so small ones take the arm64 slot.
		workers: {
			standard: {
				labels: ["self-hosted", "Linux", "X64", "tonky-ci"]
				tier:            "dedicated"
				available:       2
				cost_per_min:    0.010
				cpus:            6
				memory_mb:       13312
				timeout_minutes: 60
			}
			arm64: {
				labels: ["self-hosted", "Linux", "ARM64", "tonky-ci"]
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.008
				cpus:            4
				memory_mb:       8192
				timeout_minutes: 60
			}
		}
	}
	workflows: {
		ci: {
			layout:   "staged"
			services: "on_demand"
			// The fork's showcase branch runs on push too (workflow_dispatch: the default).
			triggers: {
				push: branches: ["main", "perf/ci-showcase"]
				pull_request: branches: ["main"]
			}
			stages: _stages
		}
	}
}
