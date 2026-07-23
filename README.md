## thin-edge.io app for Weidmuller u-OS

This repository packages thin-edge.io as a Weidmuller u-OS add-on.

It provides a small Go-based build orchestrator that can:

- build and push a multi-arch container image
- create and push a u-OS add-on package
- export a SWU artifact

The packaged container also polls configured u-OS Data Hub variables via its
REST API and republishes them as thin-edge measurements on the local
mosquitto broker, so the built-in thin-edge.io Cumulocity mapper forwards
them on - implemented as a [thin-edge flow](https://thin-edge.github.io/thin-edge.io/extend/flows/)
running under its own `tedge-mapper local` process. Which variables get
polled is controlled from Cumulocity's Configuration Management (not a u-OS
app setting), so it can be changed by anyone with Configuration Management
access, without u-OS App Settings access. See
[docs/data-hub-measurements.md](docs/data-hub-measurements.md) for how this
works and how to configure it.

## Requirements

- Go
- Docker with buildx
- access to source and target registries

## Quick start

Run all steps:

```sh
just run build pack export
```

Or run a subset:

```sh
just run build
just run pack
just run export
```

## Important environment variables

- `VERSION` (default: `2.0.1-10`)
- `IMAGE_NAME` (default: `u-os-app-thin-edge`)
- `CONTAINER_REGISTRY` (source registry for raw image)
- `CONTAINER_REGISTRY_USERNAME`
- `CONTAINER_REGISTRY_PASSWORD`
- `U_OS_REGISTRY` (target registry for packaged app)
- `U_OS_REGISTRY_NAME` (default: `posuma/u-os-app-thin-edge`)
- `U_OS_REGISTRY_USERNAME`
- `U_OS_REGISTRY_PASSWORD`
- `UC_AOM_PACKAGER_VERSION` (default: `0.8.0`)
- `C8Y_HARDWARE_MODEL` (published as `c8y_Hardware.model`)
- `C8Y_HARDWARE_REVISION` (published as `c8y_Hardware.revision`)
- `C8Y_HARDWARE_SERIAL_NUMBER` (published as `c8y_Hardware.serialNumber`)
- `C8Y_FIRMWARE_NAME` (published as `c8y_Firmware.name`)
- `C8Y_FIRMWARE_VERSION` (published as `c8y_Firmware.version`)
- `C8Y_FIRMWARE_URL` (published as `c8y_Firmware.url`)
- `DATA_HUB_CLIENT_ID` / `DATA_HUB_CLIENT_SECRET` (u-OS Data Hub OAuth2 client credentials)

Which variables get polled/published is **not** an env var - it's set via
Cumulocity Configuration Management (type `data_hub_mapping`); see
[docs/data-hub-measurements.md](docs/data-hub-measurements.md). Poll interval
is fixed in `build/image/flows/data-hub-measurements/flow.toml`.

## Local helper commands

Create local tooling and registry:

```sh
just install-tools
just create-local-registry
```
