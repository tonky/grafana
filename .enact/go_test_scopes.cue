package enact

import "list"

// Go _test.go files that `backend:test` (`go test -short` rootless without Docker) does
// not run: Docker container suites (Gitea / Alertmanager), integration-only or external
// service (Redis / Memcached / Postgres / Vertex / Bedrock) suites, and helper-only files.
_backendNotRun: [
	{
		reason: "needs Docker testcontainers (Gitea git server or Alertmanager/Prometheus)"
		tests: [
			"pkg/tests/apis/provisioning/{foldermetadata,git,quota/foldermetadata}/**/*_test.go", "pkg/tests/alertmanager/alertmanager_test.go",
		]
	},
	{
		reason: "integration-only, external service, skipped in short mode, or helper-only _test.go"
		tests: [
			"apps/live/pkg/managedstream/cache_redis_test.go", "pkg/components/imguploader/localuploader_test.go",
			"pkg/infra/filestorage/fs_integration_test.go", "pkg/infra/remotecache/memcached_storage_integration_test.go",
			"pkg/infra/remotecache/redis_storage_integration_test.go", "pkg/registry/apps/annotation/postgres_backfill_integration_test.go",
			"pkg/registry/apps/annotation/postgres_store_test.go", "pkg/registry/apps/annotation/tags_handler_test.go",
			"pkg/server/module_server_test.go", "pkg/services/ngalert/tests/fakes/rules_interface_test.go",
			"pkg/services/provisioning/plugins/config_reader_test.go", "pkg/services/provisioning/utils/utils_test.go",
			"pkg/storage/unified/migrations/registry_test.go", "pkg/storage/unified/migrations/resource_migration_test.go",
			"pkg/storage/unified/migrations/resources_test.go", "pkg/storage/unified/migrations/service_test.go",
			"pkg/storage/unified/migrations/status_reader_test.go", "pkg/storage/unified/migrations/table_locker_test.go",
			"pkg/storage/unified/migrations/validator_test.go", "pkg/storage/unified/search/rerank/provider/provider_test.go",
			"pkg/tests/api/alerting/api_remote_alertmanager_test.go", "pkg/tests/api/alerting/high_availability_test.go",
			"pkg/tests/api/azuremonitor/azuremonitor_test.go", "pkg/tests/apis/folder/folder_tree_test.go",
			"pkg/tests/apis/folder/parity_test.go", "pkg/tests/apis/iam/teambinding/team_binding_integration_test.go",
			"pkg/tests/apis/iam/teambinding/teambinding_test.go", "pkg/util/interface_test.go",
			"pkg/util/ip_address_test.go", "pkg/util/json_test.go",
			"pkg/util/md5_test.go", "pkg/util/reverse_test.go",
			"pkg/util/shortid_generator_test.go", "pkg/util/split_email_test.go",
			"pkg/util/strings_test.go", "pkg/util/svg_test.go",
			"pkg/util/xorm/sequence_test.go", "pkg/util/xorm/session_reset_test.go",
			"pkg/util/xorm/xorm_test.go",
		]
	},
]

// Explicit helper, benchmark, fuzz, and non-`^func TestIntegration` `_test.go` files layered
// on top of the per-revision generated `_generatedIntegrationTests` inventory
// (`go_integration_inventory.cue`).
_integrationTestHelpers: [
	"pkg/api/api_test.go",
	"pkg/api/common_test.go",
	"pkg/api/folder_bench_test.go",
	"pkg/infra/nats/helpers_test.go",
	"pkg/infra/nats/integration_test.go",
	"pkg/registry/apis/provisioning/jobs/sync/manager_kind_conflict_helpers_test.go",
	"pkg/services/accesscontrol/acimpl/service_bench_test.go",
	"pkg/services/accesscontrol/export_test.go",
	"pkg/services/accesscontrol/filter_bench_test.go",
	"pkg/services/accesscontrol/metadata_bench_test.go",
	"pkg/services/accesscontrol/resourcepermissions/api_adapter_bench_test.go",
	"pkg/services/accesscontrol/resourcepermissions/store_bench_test.go",
	"pkg/services/apikey/apikeyimpl/store_test.go",
	"pkg/services/auth/jwt/auth_test.go",
	"pkg/services/auth/jwt/rsa_keys_test.go",
	"pkg/services/auth/jwt/signing_test.go",
	"pkg/services/authz/rbac/legacypermissions/zanzana_test.go",
	"pkg/services/authz/zanzana/server/server_bench_test.go",
	"pkg/services/authz/zanzana/server/server_test.go",
	"pkg/services/ngalert/models/receivers_diff_test.go",
	"pkg/services/ngalert/models/receivers_test.go",
	"pkg/services/ngalert/provisioning/provisioning_test.go",
	"pkg/services/ngalert/state/manager_bench_test.go",
	"pkg/services/ngalert/state/state_bench_test.go",
	"pkg/services/ngalert/store/instance_database_bench_test.go",
	"pkg/services/ngalert/store/provenance/main_test.go",
	"pkg/services/ngalert/store/rules/main_test.go",
	"pkg/services/ngalert/store/rules/range_to_instant_test.go",
	"pkg/services/preference/prefimpl/inmemory_test.go",
	"pkg/services/preference/prefimpl/store_test.go",
	"pkg/services/publicdashboards/internal/service/common_test.go",
	"pkg/services/query/query_test.go",
	"pkg/services/queryhistory/queryhistory_test.go",
	"pkg/services/sqlstore/migrations/usermig/test/user_test.go",
	"pkg/services/tag/tagimpl/store_test.go",
	"pkg/storage/unified/migrations/fake_migrator_test.go",
	"pkg/storage/unified/resource/continue_fuzz_test.go",
	"pkg/storage/unified/resource/keys_fuzz_test.go",
	"pkg/storage/unified/resource/logger_fake_test.go",
	"pkg/storage/unified/resource/notifier_nats_integration_test.go",
	"pkg/storage/unified/resource/storage_backend_gc_test.go",
	"pkg/storage/unified/search/bleve_performance_test.go",
	"pkg/storage/unified/search/fuzz_test.go",
	"pkg/storage/unified/search/remote_index_store_fuzz_test.go",
	"pkg/storage/unified/search/zz_dashboard_provider_test.go",
	"pkg/storage/unified/sql/shorturl_benchmark_test.go",
	"pkg/tests/api/alerting/testenv_shared_test.go",
	"pkg/tests/api/correlations/common_test.go",
	"pkg/tests/apis/iam/authinfo/authinfo_test.go",
	"pkg/tests/apis/iam/resourcepermission/resourcepermission_test.go",
	"pkg/tests/apis/iam/serviceaccount/serviceaccount_test.go",
	"pkg/tests/apis/iam/team/helpers_test.go",
	"pkg/tests/apis/iam/team/team_test.go",
	"pkg/tests/apis/iam/teambinding/teambinding_test.go",
	"pkg/tests/apis/iam/user/user_test.go",
	"pkg/tests/apis/provisioning/apiversion/helper_test.go",
	"pkg/tests/apis/provisioning/collections/helper_test.go",
	"pkg/tests/apis/provisioning/connection/helpers_test.go",
	"pkg/tests/apis/provisioning/connection/oauth_test.go",
	"pkg/tests/apis/provisioning/folderscope/helper_test.go",
	"pkg/tests/apis/provisioning/helper_test.go",
	"pkg/tests/apis/provisioning/jobs/conflict/helpers_test.go",
	"pkg/tests/apis/provisioning/jobs/helpers_test.go",
	"pkg/tests/apis/provisioning/jobs/instanceauth/helpers_test.go",
	"pkg/tests/apis/provisioning/maxfilesize/helper_test.go",
	"pkg/tests/apis/provisioning/nats/helpers_test.go",
	"pkg/tests/apis/provisioning/nats/historicjob/helpers_test.go",
	"pkg/tests/apis/provisioning/nats/relist/helpers_test.go",
	"pkg/tests/apis/provisioning/orgs/helper_test.go",
	"pkg/tests/apis/provisioning/quota/helpers_test.go",
	"pkg/tests/apis/provisioning/resourcekinds/harness_test.go",
	"pkg/tests/apis/provisioning/v1beta1/helper_test.go",
]

// Integration `_test.go` files across Grafana's non-Docker integration packages
// (`integration-sqlite:test`, `integration-postgres:test`, `integration-mysql:test`).
_integrationTests: list.Concat([_generatedIntegrationTests, _integrationTestHelpers])
