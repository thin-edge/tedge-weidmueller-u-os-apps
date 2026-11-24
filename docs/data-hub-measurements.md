# Weidmueller Data Hub → thin-edge.io measurements

This document describes how values from the u-OS Data Hub REST API are
published as thin-edge.io measurements, and how to configure or change that
behavior.

## How it works

```
u-OS Data Hub REST API  --(poll, every 10s)-->  data-hub-measurements flow (tedge-mapper local)  --(MQTT)-->  mosquitto  --(c8y mapper)-->  Cumulocity
```

This is implemented as a [thin-edge %%te%% flow](https://thin-edge.github.io/thin-edge.io/extend/flows/)
rather than a custom long-running service:

1. `build/image/flows/data-hub-measurements/flow.toml` defines an
   `input.process` connector that runs
   `build/image/flows/data-hub-measurements/poll.sh` every 10 seconds. This
   flow is loaded by `tedge-mapper local`, which runs as its own s6-overlay
   service (`build/image/s6/mapper-local/`) alongside the container's
   existing C8y mapper.
2. Each invocation of `poll.sh` authenticates against the Data Hub with an
   OAuth2 client-credentials grant (cached token, see
   `build/image/lib/data-hub-client.sh`), then fetches the current value of
   each configured `r`/`rw` variable via:
   `GET $DATA_HUB_HOST/u-os-hub/api/v1/providers/<provider>/variables/<key>`
   (the provider comes from that variable's own mapping entry, see below —
   different entries can point at different providers).
3. Values that don't parse as a number are logged and skipped (thin-edge
   measurements must be numeric).
4. All remaining values are combined into one thin-edge JSON measurement and
   printed to stdout, e.g. `{"temp":{"value":23.7},"humidity":{"value":48}}`.
   The flow has no transformation steps, so this line is published
   **unchanged**, **not retained**, straight to `output.mqtt.topic`
   (`te/device/main///m/data_hub`) — there's nothing to reshape since
   `poll.sh` already emits the finished measurement JSON.
5. thin-edge.io's built-in Cumulocity mapper (already running in this
   container) picks that topic up automatically and forwards it to
   Cumulocity as a measurement of type `data_hub`, with one series per key
   (`temp`, `humidity`, ...).

If it isn't configured (see below), `poll.sh` exits immediately without
printing anything — nothing is published that cycle, and nothing is logged
(this runs every 10s regardless, so logging "disabled" every cycle would
just be noise; unlike the previous long-running-service design, there's no
single "started up" moment to log it once).

## Configuring which values get published

There are two independent configuration surfaces, deliberately split by who
needs to touch them:

| What | Where | Who can change it |
|---|---|---|
| OAuth2 credentials (`DATA_HUB_CLIENT_ID`, `DATA_HUB_CLIENT_SECRET`) | u-OS app settings (env vars, `build/package/manifest.tmpl.json`) | Whoever has u-OS App Settings access |
| Which variables to poll/publish | Cumulocity **Configuration Management**, type `data_hub_mapping` | Any Cumulocity user with Configuration Management access - **no u-OS App Settings access needed** |

Credentials stay as u-OS settings (env vars) on purpose - they're secrets,
and Configuration Management files aren't a secret store. The variable list
is exactly the kind of thing a cloud-side operator wants to change often
without touching the device/app admin surface, so it's a plain config file
instead:

1. **Find candidate variables**: Device Management > your device >
   Configuration > type `data_hub_variables` > **Get snapshot** - shows the
   full catalog every referenced provider offers (see "Discovering
   variables from Cumulocity" below).
2. **Edit the mapping**: create/edit a local text file with one entry per
   line, `provider:key[:mode]` (`#` starts a comment, blank lines ignored),
   e.g.:
   ```
   plc1:temp:r
   plc1:humidity:r
   io_link_1:setpoint:rw
   ```
3. **Push it**: Configuration > type `data_hub_mapping` > upload that file >
   **Send configuration to device**. thin-edge writes it to
   `/data/tedge/data-hub-mapping.conf` on the device (`DATA_HUB_MAPPING_PATH`
   if overridden).
4. `poll.sh` re-reads that file **every cycle** (every 10s) - no restart,
   no rebuild. It's not a u-OS setting, so changing it does not restart the
   app container either.

Any config type registered in `tedge-configuration-plugin.toml` is
readable *and* writable via Cumulocity Configuration Management by
default (verified against the thin-edge.io source - there's no per-entry
read-only flag; it's a single tenant-wide `c8y.enable.config_update`
toggle, on by default). The `data_hub_variables` snapshot type is
technically writable too, but pointless to push to - `poll.sh` overwrites
it again on its very next cycle.

Each mapping entry is `provider:key` or `provider:key:mode`, where `mode`
is one of:

- `r` (default if omitted) — read-only: polled every cycle and folded into
  the combined `data_hub` measurement.
- `w` — write-capable: parsed and validated, but **not** polled/published.
  There is no automatic write trigger yet (see "Read/write modes" below).
- `rw` — both: polled/published like `r`, and available for a future write
  trigger.

Entries can point at different providers, so telemetry from multiple
PLC/IO-Link providers can be combined in one measurement. Malformed entries
(missing provider/key, or an unrecognized mode) are logged and skipped
without affecting the rest of the list.

The poll interval is **not** configurable via Configuration Management or a
u-OS setting - it's fixed in `flow.toml`'s `interval = "10s"`. `flow.toml`
values aren't shell-env/config-file substitutable (only `${params.*}`
template values are, via a `params.toml` next to the flow - a mechanism
Configuration Management could in principle also target, but that's not
wired up here), so changing it means editing `flow.toml` and rebuilding the
image.

Note: `DATA_HUB_CLIENT_ID`/`DATA_HUB_CLIENT_SECRET` are shared with the
existing hardware/firmware inventory lookup
(`build/image/startup-publish-inventory.sh`), which uses the separate
`DATA_HUB_PROVIDER` variable (default `u_os_adm`) for that one-shot lookup.

### Read/write modes

`w`/`rw` entries cause `poll.sh` to request an OAuth2 token with the
`hub.variables.readwrite` scope instead of `hub.variables.readonly` (a
readwrite token also satisfies reads, so this is a one-time decision made
fresh on every invocation, not per-variable). This provisions
`data_hub_set_variable <provider> <key> <value>` in
`build/image/lib/data-hub-client.sh` — a primitive that does a plain
`POST .../providers/<provider>/variables/<key>` write — and the standalone
`data-hub-set-variable.sh` CLI (see below) for manually exercising it.

**No automatic write trigger exists yet** — nothing currently calls
`data_hub_set_variable` on its own. Wiring up a real trigger (a Cumulocity
operation, a local MQTT command topic, etc.) that decides *when* and *with
what value* to write is deliberately left to a future change; this change
only adds the config parsing and the write primitive so that future work
doesn't have to touch the OAuth2/token-scope plumbing again.

### Discovering available variables

Before writing a mapping entry, you often want to know what a
provider actually offers. `data_hub_list_variables <provider> [prefixes]
[definition]` in `data-hub-client.sh` wraps `GET
/providers/<provider>/variables`, and the standalone
`data-hub-list-variables.sh` CLI exposes it directly:

```sh
# all variables + current values for a provider
docker exec <container> data-hub-list-variables.sh plc1

# filter by key prefix (comma-separated), e.g. only digital_nameplate.*
docker exec <container> data-hub-list-variables.sh plc1 digital_nameplate

# include each variable's definition (access_type, data_type, experimental)
# - this tells you which keys are actually READ_WRITE before you configure
# them as "w"/"rw" and get a 405 back
docker exec <container> data-hub-list-variables.sh plc1 '' true
```

`data_hub_list_variables` returns the raw JSON array from the API rather
than extracting a single value (unlike `data_hub_get_variable`), since the
shape depends on whether `definition` was requested.

### Discovering variables from Cumulocity (no docker exec needed)

Every poll cycle, `poll.sh` also refreshes a
snapshot file at `DATA_HUB_VARIABLES_SNAPSHOT_PATH` (default
`/data/tedge/data-hub-variables.yaml`) containing the **full** variable list
(with definitions) for every provider referenced anywhere in the current
mapping — not just the configured keys. This is the same data
`data_hub_list_variables <provider> "" true` returns, merged across all
referenced providers into one `{"<provider>": [...], ...}` document.

That path is registered as a thin-edge configuration type
(`build/image/tedge-configuration-plugin.toml`, type `data_hub_variables`),
so it shows up in Cumulocity's Device Management > Configuration tab like
any other config file: click **Get snapshot** to download the current file
without touching the container at all. This is the read-only-in-practice
counterpart to `data_hub_mapping` (above) — pushing a new file to
`data_hub_variables` via "Send configuration to device" is technically
possible (see above) but pointless, since `poll.sh` regenerates and
overwrites it every cycle regardless of what was pushed. The file is
(re-)registered at container startup by `ensure_config_type` in
`startup-publish-inventory.sh` (for **both** `data_hub_variables` and
`data_hub_mapping`), following the same pattern already used for the
`default` config type — needed because `tedge-configuration-plugin.toml` is
(re)written by thin-edge itself and a purely build-time entry isn't
guaranteed to survive that.

The content is plain `jq`-formatted JSON despite the `.yaml` extension/config
type name — valid JSON is valid YAML, so this avoids pulling in a YAML
library just for formatting. If a provider fails to respond, it's logged
and simply omitted from that cycle's snapshot rather than failing the whole
write.

## Changing the behavior (code changes)

All logic lives in `build/image/flows/data-hub-measurements/poll.sh` (payload
building, invoked once per `flow.toml` interval, no loop of its own) and
`build/image/lib/data-hub-client.sh` (the shared Data Hub HTTP client, also
used by the inventory script).

- **Measurement topic/type**: change `output.mqtt.topic` in `flow.toml`
  (currently `te/device/main///m/data_hub`, where `data_hub` is the
  Cumulocity measurement type). No JS transformation step is involved -
  `poll.sh`'s stdout is published unchanged.
- **Poll interval**: change `interval` in `flow.toml` (see "Configuring
  which values get published" above for why this isn't an env var).
- **Measurement key collisions**: measurement series names are the bare
  `key`, not `provider:key`. If two entries from different providers use the
  same key, they collide in the combined payload (last one wins) — rename
  one of the keys, or namespace them yourself, if that's a problem.
- **Wiring up a write trigger**: `data_hub_set_variable` (in
  `data-hub-client.sh`) is ready to call, but nothing calls it automatically
  yet. A future change needs to decide what triggers a write (Cumulocity
  operation, local MQTT topic, ...) and hook it up — see "Read/write modes"
  above.
- **Non-numeric values**: `is_number()` in `poll.sh` filters out non-numeric
  values before publishing (thin-edge measurements require numbers). If you
  need to forward text/state values, publish them as a twin/inventory
  fragment instead (see `publish_if_configured()` in
  `startup-publish-inventory.sh` for that pattern), not as a measurement.
- **Retained vs non-retained**: `output.mqtt` in `flow.toml` publishes
  without the retain flag by default (matches thin-edge convention:
  measurements are a time series, not current-state). Twin data in the
  inventory script uses `-r` because it represents current state.

## Verifying it locally

Build and run the image, then, with the container running:

```sh
# tail poll.sh's own log lines (still tagged [datahub-measurements],
# now emitted by the mapper-local process instead of a dedicated service)
docker logs <container> 2>&1 | grep datahub-measurements

# watch what actually gets published on the broker
docker exec <container> tedge mqtt sub 'te/device/main///m/data_hub'

# exercise the flow directly, without a live MQTT connection or device
tedge flows test --flows-dir build/image/flows/data-hub-measurements/
```

If nothing is published, remember `poll.sh` logs nothing at all when
unconfigured (see "How it works" above) - check that
`/data/tedge/data-hub-mapping.conf` actually has uncommented entries
(`docker exec <container> cat /data/tedge/data-hub-mapping.conf`) and that
the OAuth2 client ID/secret are set, then look for per-entry failures (fetch
errors, non-numeric values, malformed entries) in the log.

### Testing the write primitive

There's no automatic trigger yet, so test `data_hub_set_variable` directly:

```sh
# via the shell lib (also validates the container's OAuth2 client actually
# has the hub.variables.readwrite scope)
docker exec <container> data-hub-set-variable.sh <provider> <key> <json-value>
docker exec <container> data-hub-set-variable.sh io_link_1 setpoint 42
docker exec <container> data-hub-set-variable.sh scada alarm_ack true

# independently, a raw curl request bypassing the shell lib entirely - useful
# to isolate "is my OAuth2 client's readwrite scope actually granted" from
# "is my shell code right"
TOKEN=$(curl -sk -X POST https://host.docker.internal/oauth2/token \
  -d grant_type=client_credentials -d client_id=... -d client_secret=... \
  -d scope=hub.variables.readwrite | jq -r .access_token)
curl -sk -X POST https://host.docker.internal/u-os-hub/api/v1/providers/<provider>/variables/<key> \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"key":"<key>","value":42}' -w '\nHTTP %{http_code}\n'
```

A `405` means the variable is read-only at the Data Hub side; check its
`access_type` via `GET .../variables/<key>?definition=true`.

## API reference

The Variable-HTTP-API endpoints used here (`GET`/`POST`
`/u-os-hub/api/v1/providers/{provider}/variables/{key}`) are specified in
the `u-os-hub-api` repo (github.com/weidmueller/u-os-hub-api,
`variable-http-openapi.yaml`), tagged per u-OS release. Check that spec
before changing endpoint paths, OAuth2 scopes, or response/request shapes in
`build/image/lib/data-hub-client.sh`.
