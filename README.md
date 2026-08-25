## thin-edge.io app for Weidmuller u-OS

This repository packages thin-edge.io as a Weidmuller u-OS add-on.

It provides a small Go-based build orchestrator that can:

- build and push a multi-arch container image
- create and push a u-OS add-on package
- export a SWU artifact

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

- `VERSION` (default: `2.0.1-1`)
- `IMAGE_NAME` (default: `u-os-app-thin-edge`)
- `CONTAINER_REGISTRY` (source registry for raw image)
- `CONTAINER_REGISTRY_USERNAME`
- `CONTAINER_REGISTRY_PASSWORD`
- `U_OS_REGISTRY` (target registry for packaged app)
- `U_OS_REGISTRY_NAME` (default: `posuma/u-os-app-thin-edge`)
- `U_OS_REGISTRY_USERNAME`
- `U_OS_REGISTRY_PASSWORD`
- `UC_AOM_PACKAGER_VERSION` (default: `0.8.0`)

## Local helper commands

Create local tooling and registry:

```sh
just install-tools
just create-local-registry
```
