package enact

import "enact.dev/schema"

pipeline: schema.#Pipeline & {
	name:        "grafana"
	description: "Grafana: Go backend, yarn-workspace frontend, database integration suites"

	// Every job's checkout, beside the pipeline's defaults and its component's cone: the
	// environment, and the helpers (the services' setup runs from them, enve.cue postStart).
	workspace_scope: include: [
		".enact",
		"cue.mod",
		"enve.cue",
		"enve.lock",
		"helpers",
	]
}
