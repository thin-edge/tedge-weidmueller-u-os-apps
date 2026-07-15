
set dotenv-load

IMAGE_NAME := env("IMAGE_NAME", "u-os-app-thin-edge")

# Application semver version, e.g. 2.0.1-3 or 2.0.1-3-rc.1
VERSION := env("VERSION", "2.0.1-3")

# On macOS it needs to use the docker host's registry name as docker
REGISTRY := env("REGISTRY", if os() == "macos" { "host.docker.internal:5001" } else { "127.0.0.1:5001" })

# Install cross-platform tools
install-tools:
    docker run --privileged --rm tonistiigi/binfmt --install all

# Create a local container registry
create-local-registry:
    docker run -d --env REGISTRY_HTTP_SECRET="$(hostname)" --restart always -p 127.0.0.1:5001:5000 --name registry registry:2

run *ARGS:
    env
    go run main.go -- {{ARGS}}
