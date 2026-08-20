# Compatibility matrix

Chinese companion: [README.zh.md](README.zh.md).

`matrix.json` schema 3 separates one runtime contract from its exact client-version eligibility entries. A runtime contract owns the client profile, pool, model, route, capabilities, and typed wire contract. Each version entry owns its family, exact version, install source, static level, and evidence identity. Runtime lookup uses only profile, model, and upstream API; neither Codex nor Claude Code is routed by an exact client version. This prevents multiple versions of the same request contract from creating duplicate Gateway route keys while retaining auditable fixed-CLI release evidence. A non-committed release-evidence attestation can derive `verified_native` for one immutable Gateway build after clean fixed-CLI evidence passes. Controlled real-Copilot checks are optional manual validation and do not block release attestation.

## Current status

The implementation baseline is matrix revision `phase7c-2026-08-18.1`, development candidate build `2026.08.18.1`, and schema 19. Effective release status is intentionally not inferred from this repository: it is derived only from an external attestation bound to an immutable release manifest, reports, and the same matrix payload.

- Codex 0.147.0 with `gpt-5.5 -> gpt-5.5 / responses` is statically `candidate_native`. An immutable release may derive a higher effective level only through the required attestation; a successful model discovery or live generation never changes the static level.
- Claude Code `2.1.225`, `2.1.226`, and `2.1.233` share one `claude-sonnet-4-20250514 / anthropic_messages` runtime contract, but all three are `unsupported`: after an initial Sonnet turn, their observed `--resume` request selects `claude-opus-5`. The matrix has no matching Opus contract, catalog entry, profile, pool, or entitlement evidence, so it fails closed rather than claiming the Sonnet contract. `count_tokens` remains unsupported.
- The Codex catalog publishes only the exact verified mapping and conservative capability metadata. Model refresh or one successful live generation does not upgrade the compatibility level.
- Release-evidence schema 2 requires a clean fixed-CLI report and treats the target-environment report as optional. Fake CLI report schema 6 records both CLI and runtime command/version/SHA-256 provenance.
- The target collector and validator cover every active and binding-reserved pool account without exporting credentials. A temporary validated report is development evidence only until it is bound to an immutable build, schema, and matrix entry.
- Schema 19 contains the constrained capability snapshot, manual-refresh request, client-profile entitlement policy, and `missing|upstream|estimated` usage-source contracts. The unused client-profile protocol fields were removed: the request endpoint defines the downstream protocol and the matrix defines formal client compatibility. Missing usage is omitted from client responses and retains its maximum budget reservation; provider attempts and the usage ledger preserve the source. Worker populates native-candidate targets; Admin and Dashboard expose account/pool evidence and asynchronous refresh. `require_fresh` profiles publish one immutable request allowlist to ordinary, sticky, required-account, rebinding, budget retry, and binding create/restore paths. The Kubernetes production Copilot overlay enables the Worker role; fake-provider overlays keep it disabled.

These contracts remain folded into schema 19. Development databases that recorded a previous migration 019 checksum must be rebuilt. Each new immutable release must supply new clean fixed-CLI evidence and an attestation before it can derive an effective `verified_native` level.

Run `make compat-validate` for the static contract and repository schema check. Run `make compat-release-validate` before release; attestation creation or validation fails when fixed-CLI evidence is missing, stale, incomplete, or bound to another build, schema, matrix payload, or release manifest. The fake report must exactly cover every required P0 scenario for the matrix's CLI family and version.

Collect the deterministic candidate report before promotion. Fake report schema 6 records `scenario_coverage`, each scenario's workflow execution, and exact CLI/runtime command/version/SHA-256 provenance. The validator derives each scenario and the aggregate coverage from the versioned contract, rather than trusting a report-provided release claim. The collector reads a non-committed `0600` manifest that binds every matrix version entry to an absolute CLI executable and runtime executable. It never resolves a candidate CLI from the ambient `PATH`. A missing, skipped, failed, mismatched, or digest-drifted entry prevents report publication. Claude Code registers 17 `cli_end_to_end` scenarios, including empty stream, premature EOF, and duplicate terminal recovery. Codex 0.147.0 has been observed to use streaming Responses, so `text_non_stream`, `serial_tool`, `parallel_tool`, and `tool_result_continuation` remain component-only. Its local dynamic tools use an app-server JSON-RPC callback that is not available through this HTTP Responses Gateway; the candidate catalog therefore disables `function_tools`. The current dirty `dev` report is development evidence only; a release requires a clean immutable build to regenerate `cli_end_to_end` evidence.

The manifest is an external, `0600` JSON file. It is a provenance input, not a credential file, but it is still not committed because it contains host-local absolute paths and mutable binary digests:

```json
{
	"schema_version": 1,
	"entries": [
		{
			"matrix_entry_id": "claude-code-2.1.226-claude-sonnet-4-20250514",
			"command": "claude",
			"path": "/secure/cli/claude-2.1.226/bin/claude",
			"version": "2.1.226",
			"sha256": "<64 lowercase hex characters>",
			"runtime": {
				"command": "node",
				"path": "/secure/node/bin/node",
				"version": "v24.16.0",
				"sha256": "<64 lowercase hex characters>"
			}
		}
	]
}
```

```sh
COMPAT_GATEWAY_BUILD=dev \
COMPAT_FAKE_CLI_REPORT=/tmp/ghcp-compat-fake-cli.json \
COMPAT_CLI_BINARIES_FILE=/secure/ghcp-cli-binaries.json \
make compat-fake-collect
```

`dev` is suitable only for candidate validation. A release run must use the same immutable `APP_VERSION` in the matrix, fake-CLI report, and `RELEASE_APP_VERSION` in `release-manifest.env`. Reports are sanitized, time-limited release inputs and must not be committed. A deployed Gateway and environment report may be checked manually, but neither is a release input unless an operator explicitly chooses to bind that report.

`make compat-test` uses the same manifest-aware collector for the matrix's current candidate entries. Supply `COMPAT_GATEWAY_BUILD` and `COMPAT_CLI_BINARIES_FILE`; a missing manifest is an error, rather than permission to select an arbitrary CLI from `PATH`.

Optional target-environment validation uses the strict schema 5 `internal/compatibility.EnvironmentReport` contract. It binds stable client-profile and pool names to runtime IDs, requires `model_entitlement_policy=require_fresh`, then binds every active pool account (including binding reservations) to the matrix model/API. It reads the deployed Gateway identity from `/version`, checks each account's Copilot model visibility and sends a minimal non-streaming Provider probe, then sends one authenticated minimal request through the deployed Gateway for each native matrix entry. The scoped Gateway keys are read from a controlled JSON file such as `{"codex-candidate":"<gateway-key>"}` and never enter the report or logs. This check is manual and optional; streaming, tools, and reasoning remain separate fixed-CLI gates.

Collect and independently validate a report from a host configured exactly like the target worker:

```sh
COMPAT_GATEWAY_URL=http://localhost:8000 \
COMPAT_GATEWAY_PROFILE_KEYS_FILE=/secure/ghcp-compat-profile-keys.json \
COMPAT_ENVIRONMENT_REPORT=/tmp/ghcp-compat-environment.json \
make compat-target-collect
```

The command requires the target's normal PostgreSQL, credential-encryption, GitHub auth, and `PROVIDER=copilot` configuration. It reads the deployed Gateway build from `/version`, reads the deployed schema from `migration_history`, requires one uniquely named and isolated enabled profile/pool per native matrix entry, and requires an explicit catalog `upstream_api`. For every active account it fetches that account's Copilot `/models` catalog and sends a minimal live request through the existing provider probe. Any failure prevents report publication.

After both reports are collected, create an external release-evidence attestation. It binds the exact matrix, release manifest, reports, report timestamps, and report SHA-256 values without modifying the frozen matrix after collection:

```sh
COMPAT_RELEASE_MANIFEST=/secure/release-manifest.env \
COMPAT_FAKE_CLI_REPORT=/secure/ghcp-compat-fake-cli.json \
COMPAT_RELEASE_EVIDENCE=/secure/ghcp-release-evidence.json \
make compat-evidence-create
```

Validate the same immutable release set with the attestation:

```sh
COMPAT_RELEASE_MANIFEST=/secure/release-manifest.env \
COMPAT_FAKE_CLI_REPORT=/secure/ghcp-compat-fake-cli.json \
COMPAT_RELEASE_EVIDENCE=/secure/ghcp-release-evidence.json \
make release-validate
```

The worker image also contains the collector and matrix for deployment-local collection. Mount the profile-key file only for this controlled operation:

```sh
/bin/compatcollect \
	-matrix /srv/ghcp/compatibility/matrix.json \
	-gateway-url http://gateway:8000 \
	-gateway-profile-keys-file /secure/ghcp-compat-profile-keys.json \
	-output /tmp/ghcp-compat-environment.json
```

The example uses the Compose service name. Use `http://ghcp-gateway:8000` inside the Kubernetes namespace. The general worker mounts an ephemeral writable `/tmp`; copy the sanitized file out of the workload before the Pod is replaced, then validate it with `COMPAT_ENVIRONMENT_REPORT=/tmp/ghcp-compat-environment.json make compat-target-validate`. Operators may bind that optional report by also setting `COMPAT_ENVIRONMENT_REPORT` for attestation creation and release validation.

The matrix, reports, and release-evidence attestation must never contain credentials, authorization headers, prompts, tool arguments, or raw upstream response bodies.