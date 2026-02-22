# hassos-addons-vector

Source repository for the **Vector** Home Assistant OS addon. The addon is distributed via [twiebe/hassos-addons](https://github.com/twiebe/hassos-addons).

[Vector](https://vector.dev) is a high-performance observability data pipeline. This addon runs Vector as a Home Assistant OS service, collecting logs from the systemd journal and forwarding them to a configured sink.

## How it works

On startup the addon generates a Vector configuration from your addon options and starts the Vector process. The generated configuration is printed to the addon log at startup (with credentials obfuscated) so you can verify it without needing shell access.

## Sources

Logs are collected from the **systemd journal** (`journald`), which on Home Assistant OS includes all system services, the supervisor, and any Docker containers running as addons.

## Transforms

Two optional transforms can be applied before logs are forwarded:

### Lowercase Field Names

Normalises all field names to lowercase. Journald emits many fields in uppercase (e.g. `CONTAINER_NAME`, `_SYSTEMD_UNIT`). Enabling this makes field names consistent and easier to work with in most log backends.

### Rename Host Field

Vector's journald source attaches the hostname under the field `host`. If your log backend or query conventions expect a different name (e.g. `hostname`), enable this transform and set the desired field name.

The two transforms are independent and can be combined. When both are enabled, lowercase is applied first, then the host field is renamed.

## Sinks

### VictoriaLogs

[VictoriaLogs](https://docs.victoriametrics.com/victorialogs/) exposes an Elasticsearch-compatible bulk ingest API, which is what Vector uses under the hood — the sink type in Vector's config is `elasticsearch`, but the addon models this honestly as `victorialogs` since the configuration (in particular the `query` parameters) is specific to VictoriaLogs and not portable to plain Elasticsearch or OpenSearch.

The following VictoriaLogs-specific query parameters are always set in the generated config:

| Parameter | Value | Purpose |
|---|---|---|
| `_msg_field` | `message` | Tells VictoriaLogs which field contains the log message |
| `_time_field` | `timestamp` | Tells VictoriaLogs which field contains the timestamp |
| `_stream_fields` | auto or configured | Fields used to group logs into streams |

`_stream_fields` is auto-generated based on the active transforms: it uses the host field name (as renamed, if applicable) and `container_name` or `CONTAINER_NAME` depending on whether lowercase is enabled. You can override this by setting the Stream Fields option explicitly.

Compression is fixed at `gzip` and the Elasticsearch healthcheck is disabled — VictoriaLogs does not expose that endpoint.

| Option | Description |
|---|---|
| Endpoint URL | Full URL of your VictoriaLogs ingest endpoint |
| Auth Username | Basic auth username (leave empty to disable) |
| Auth Password | Basic auth password |
| Stream Fields | Override the auto-generated `_stream_fields` value |
| Ignore Fields | Comma-separated list of fields to drop before forwarding (e.g. `log.offset,event.original`) |

### Loki

[Loki](https://grafana.com/oss/loki/) is supported via Vector's native `loki` sink. This includes [Grafana Cloud](https://grafana.com/products/cloud/) hosted Loki.

Stream labels are auto-generated from the active transforms using the same logic as VictoriaLogs stream fields: the host field name and `container_name` / `CONTAINER_NAME` depending on whether lowercase is enabled. Fields used as labels are removed from the log body to avoid duplication. Compression is fixed at `gzip`.

| Option | Description |
|---|---|
| Endpoint URL | Full URL of your Loki endpoint (e.g. `https://logs-prod-us-central1.grafana.net`) |
| Auth Username | Basic auth username — for Grafana Cloud this is your numeric org ID |
| Auth Password | Basic auth password — for Grafana Cloud this is your API token |
| Tenant ID | Sets the `X-Scope-OrgID` header — required for Grafana Cloud and multi-tenant Loki deployments |
| Encoding | Log body encoding: `text` (the `message` field only) or `json` (full structured event) |

## Config override

For use cases not covered by the addon options, you can supply a handwritten Vector configuration file. Enable **Override Config** and set **Override Config Path** to the path of your file (default: `/config/vector.yaml`).

The override file lives in the addon's own config directory, which Home Assistant mounts from `/addon_configs/{repo}_vector/` on the host. You can manage files there via the Samba addon or the Studio Code Server addon.

When override mode is active, **all other addon options are ignored entirely** — the addon copies your file directly to the Vector config location and starts Vector with it. The generated config is not written and no transforms are applied. The override file is still printed to the addon log at startup (with passwords obfuscated).

This is useful when you need additional inputs, complex routing, or full control over the Vector topology.

The override file must be a valid [Vector configuration file](https://vector.dev/docs/reference/configuration/).

## Development

Dev builds are triggered automatically on every push to a non-`main` branch. Images are tagged with the sanitized branch name and pushed to GHCR.

Release builds are triggered when a GitHub release is published. Tag the release with a bare version number (e.g. `0.1.0`). After a successful build the workflow automatically opens a commit in `hassos-addons` bumping the version in `vector/config.yaml`. This requires a `HASSOS_ADDONS_PAT` secret set in this repo with write access to `hassos-addons`.
