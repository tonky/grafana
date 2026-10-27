package enact

let J = pipeline.#jobs

_stages: [
	{
		name: "preflight"
		select: [J.lint, J.typecheck]
		fail_fast: true
		services:  "disabled"
	},
	{
		name:      "tests"
		matrix:    true
		select: [J.test]
		fail_fast: false
		services:  "on_demand"
	},
]
