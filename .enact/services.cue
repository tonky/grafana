package enact

import "github.com/grafana/grafana:enve"

// The services are enve's (enve.cue at the repository root): one definition of ports,
// commands and setup for `enve up` and for enact's jobs alike.
grafana: services: enve.profiles.dev.services

grafana: services: {
	postgres: enact: kind: "postgres"
	mysql: enact: kind:    "mysql"
}

pipeline: services: grafana.services
