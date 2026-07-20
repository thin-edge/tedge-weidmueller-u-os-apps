# Weidmueller Data Hub → thin-edge.io measurements

This document describes how values from the u-OS Data Hub REST API are
published as thin-edge.io measurements, and how to configure or change that
behavior.

## How it works

```
u-OS Data Hub REST API  --(poll)-->  publish-datahub-measurements.sh  --(MQTT)-->  mosquitto  --(c8y mapper)-->  Cumulocity
```

1. `build/image/publish-datahub-measurements.sh` runs as a long-running
   (`longrun`) s6-overlay service inside the container, started at container
   boot and supervised/restarted by s6 like every other thin-edge.io service.
2. On every cycle it authenticates against the Data Hub with an OAuth2
   client-credentials grant (cached token, see
   `build/image/lib/data-hub-client.sh`), then fetches the current value of
   each configured variable via:
   `GET $DATA_HUB_HOST/u-os-hub/api/v1/providers/$DATA_HUB_MEASUREMENT_PROVIDER/variables/<key>`
3. Values that don't parse as a number are logged and skipped (thin-edge
   measurements must be numeric).
4. All remaining values are combined into one thin-edge JSON measurement and
   published, **not retained**, to the local mosquitto broker:

   ```
   tedge mqtt pub te/device/main///m/data_hub '{"temp":{"value":23.7},"humidity":{"value":48}}'
   ```

5. thin-edge.io's built-in Cumulocity mapper (already running in this
   container) picks that topic up automatically and forwards it to
   Cumulocity as a measurement of type `data_hub`, with one series per key
   (`temp`, `humidity`, ...).

If it isn't configured (see below), the service logs that it's disabled once
and idles — it does not crash-loop or spam logs.

## Configuring which values get published

All configuration is via environment variables, exposed as u-OS app settings
in `build/package/manifest.tmpl.json`:

| Env var | Purpose | Default |
|---|---|---|
| `DATA_HUB_CLIENT_ID` | OAuth2 client ID (Control Center > Identity & access > Clients) | — |
| `DATA_HUB_CLIENT_SECRET` | OAuth2 client secret | — |
| `DATA_HUB_MEASUREMENT_PROVIDER` | Data Hub provider that the variables below belong to (e.g. a PLC/IO-Link provider name) | — |
| `DATA_HUB_VARIABLES` | Comma-separated list of variable keys to poll, e.g. `temp,humidity` | — |
| `DATA_HUB_POLL_INTERVAL` | Poll interval in seconds | `10` |

To change **which** values are published, edit `DATA_HUB_VARIABLES` (add or
remove comma-separated keys). To change **how often**, edit
`DATA_HUB_POLL_INTERVAL`. No code change or rebuild is needed for either —
they take effect on container (re)start.

All values in `DATA_HUB_VARIABLES` are read from the same
`DATA_HUB_MEASUREMENT_PROVIDER` — the poll loop does not split providers per
key. If you need variables from more than one provider, see "Changing the
behavior" below.

Note: `DATA_HUB_CLIENT_ID`/`DATA_HUB_CLIENT_SECRET` are shared with the
existing hardware/firmware inventory lookup
(`build/image/startup-publish-inventory.sh`), which uses the separate
`DATA_HUB_PROVIDER` variable (default `u_os_adm`) for that one-shot lookup.
`DATA_HUB_MEASUREMENT_PROVIDER` is intentionally a different variable so
telemetry and inventory can point at different providers.

## Changing the behavior (code changes)

All logic lives in `build/image/publish-datahub-measurements.sh` (the poll
loop and payload building) and `build/image/lib/data-hub-client.sh` (the
shared Data Hub HTTP client, also used by the inventory script).

- **Measurement topic/type**: change the topic argument passed to
  `tedge mqtt pub` in `publish-datahub-measurements.sh` (currently
  `te/device/main///m/data_hub`, where `data_hub` is the Cumulocity
  measurement type).
- **Per-variable provider**: currently one provider for all variables.
  To support mixed providers, change `DATA_HUB_VARIABLES` parsing to accept
  `provider:key` pairs and pass the per-entry provider to
  `data_hub_get_variable` instead of the single
  `DATA_HUB_MEASUREMENT_PROVIDER`.
- **Non-numeric values**: `is_number()` in `publish-datahub-measurements.sh`
  filters out non-numeric values before publishing (thin-edge measurements
  require numbers). If you need to forward text/state values, publish them
  as a twin/inventory fragment instead (see `publish_if_configured()` in
  `startup-publish-inventory.sh` for that pattern), not as a measurement.
- **Retained vs non-retained**: measurements are published without `-r`
  (matches thin-edge convention: measurements are a time series, not
  current-state). Twin data in the inventory script uses `-r` because it
  represents current state.

## Verifying it locally

Build and run the image, then, with the container running:

```sh
# tail the service's own log lines
docker logs <container> 2>&1 | grep datahub-measurements

# watch what actually gets published on the broker
docker exec <container> tedge mqtt sub 'te/device/main///m/data_hub'
```

If nothing is published, check the log line first — it tells you whether
the service considers itself configured (`DATA_HUB_VARIABLES`,
`DATA_HUB_MEASUREMENT_PROVIDER`, and the OAuth2 client ID/secret must all be
set) before it will poll anything.
