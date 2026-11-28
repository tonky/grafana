// Upstream's own module (cue.mod/module.cue at the pinned revision), which its CUE codegen
// loads: apply-overlay.sh keeps it, so the overlay evaluates under the same name.
module: "github.com/grafana/grafana"
language: {
	version: "v0.11.0"
}
