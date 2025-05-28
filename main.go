package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"
	"text/template"
	"time"
)

type Manifest struct {
	ImageName    string
	ImageVersion string
	Version      string
}

type SourceCredentials struct {
	Username      string `json:"username,omitempty"`
	Password      string `json:"password,omitempty"`
	ServerAddress string `json:"serveraddress,omitempty"`
	PlainHTTP     bool   `json:"plain-http,omitempty"`
	Insecure      bool   `json:"insecure,omitempty"`
}

type TargetCredentials struct {
	Username       string `json:"username,omitempty"`
	Password       string `json:"password,omitempty"`
	RepositoryName string `json:"repositoryname,omitempty"`
	PlainHTTP      bool   `json:"plain-http,omitempty"`
	Insecure       bool   `json:"insecure,omitempty"`
}

func MustWriteToFile(v any, filename string) {
	log.Printf("✍️ Creating file: %s", filename)
	b, err := json.Marshal(v)
	if err != nil {
		log.Fatalf("Failed to marshal json. err=%s", err)
	}
	if err := os.WriteFile(filename, b, 0644); err != nil {
		log.Fatalf("Failed to write to file. err=%s", err)
	}
	return
}

func IsLocalHost(v string) bool {
	commonLocalHostValues := []string{
		"localhost",
		"127.0.0.1",
		"host.docker.internal",
		"host.container.internal",
	}
	for _, localHostValue := range commonLocalHostValues {
		if strings.Contains(v, localHostValue) {
			return true
		}
	}
	return false
}

func getEnvOrDefault(key string, defaultValue string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultValue
}

func runCommand(name string, args ...string) error {
	cmd := exec.Command(
		name,
		args...,
	)
	var stdBuffer bytes.Buffer
	mw := io.MultiWriter(os.Stdout, &stdBuffer)
	cmd.Stdout = mw
	cmd.Stderr = mw
	return cmd.Run()
}

func GenerateManifest(manifest Manifest, filename string, out string) error {
	log.Printf("✍️ Creating app manifest from template: %s", out)
	tmpl, err := template.ParseFiles(filename)
	if err != nil {
		log.Printf("Failed to parse files. err=%s", err)
		return err
	}

	fileP, err := os.OpenFile(out, os.O_TRUNC|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer fileP.Close()
	return tmpl.Execute(fileP, manifest)
}

func main() {
	log.Printf("🚀 Building u-OS Application")

	cwd, err := os.Getwd()
	if err != nil {
		log.Fatalf("Could not get current working directory. err=%s", err)
	}

	manifest := Manifest{
		ImageName: getEnvOrDefault("IMAGE_NAME", "u-os-image-thin-edge"),
		// TODO: Should the image version and app version differ, is there any advantage to this?
		ImageVersion: getEnvOrDefault("VERSION", "0.0.0-1"),
		Version:      getEnvOrDefault("VERSION", "0.0.0-1"),
	}
	if manifestErr := GenerateManifest(manifest, "build/package/manifest.tmpl.json", "build/package/manifest.json"); manifestErr != nil {
		log.Fatalf("Failed to generate app manifest. err=%s", manifestErr)
	}

	// source repository (where the unpackaged container image is stored)
	sourceContainerRegistry := getEnvOrDefault("CONTAINER_REGISTRY", "")
	sourceCredentials := SourceCredentials{
		Username:      getEnvOrDefault("CONTAINER_REGISTRY_USERNAME", ""),
		Password:      getEnvOrDefault("CONTAINER_REGISTRY_PASSWORD", ""),
		ServerAddress: sourceContainerRegistry,
		PlainHTTP:     IsLocalHost(sourceContainerRegistry),
		Insecure:      IsLocalHost(sourceContainerRegistry),
	}

	// u-OS repository credentials
	uOSContainerRegistry := getEnvOrDefault("U_OS_REGISTRY", sourceContainerRegistry)
	targetCredentials := TargetCredentials{
		RepositoryName: getEnvOrDefault("U_OS_REGISTRY_NAME", "u-os-22/u-os-app-thin-edge"),
		Username:       getEnvOrDefault("U_OS_REGISTRY_USERNAME", sourceCredentials.Username),
		Password:       getEnvOrDefault("U_OS_REGISTRY_PASSWORD", sourceCredentials.Password),
		PlainHTTP:      IsLocalHost(uOSContainerRegistry),
		Insecure:       IsLocalHost(uOSContainerRegistry),
	}

	MustWriteToFile(sourceCredentials, "build/package/source-credentials.json")
	MustWriteToFile(targetCredentials, "build/package/target-credentials.json")

	for _, subcommand := range os.Args[1:] {
		switch subcommand {
		case "build":
			log.Printf("🏗️ Build container image")

			if cmdErr := runCommand(
				"docker", "buildx", "build",
				"--build-arg", "BUILDKIT_MULTI_PLATFORM=1",
				"--build-arg", fmt.Sprintf("BUILD_DATE=%s", time.Now().Format("2006-01-02T15:04:05Z")),
				"--build-arg", fmt.Sprintf("IMAGE_NAME=%s:%s", manifest.ImageName, manifest.ImageVersion),
				"--file", "build/image/raw.Dockerfile",
				"--platform", "linux/arm/v7,linux/arm64",
				"--output=type=registry,registry.insecure="+fmt.Sprintf("%v", sourceCredentials.Insecure),
				"--push",
				"-t", fmt.Sprintf("%s/%s:%s", sourceContainerRegistry, manifest.ImageName, manifest.ImageVersion),
				"build/image",
			); cmdErr != nil {
				log.Fatalf("Failed to create/push app to u-OS Registry. err=%s", cmdErr)
			}
		case "pack":
			log.Printf("📦 Creating and pushing app to u-OS Registry: %s", uOSContainerRegistry)
			if cmdErr := runCommand(
				"docker",
				"run",
				"--rm",
				"--pull=always",
				"--network=host",
				"--add-host=host.docker.internal:host-gateway",
				"--mount", fmt.Sprintf("src=%s/build/package,target=/tmp/addon,type=bind", cwd),
				"-e", fmt.Sprintf("DEFAULT_REGISTRY_SERVER_ADDRESS=%s", uOSContainerRegistry),
				"wmucdev.azurecr.io/u-control/uc-aom-packager:0",
				"uc-aom-packager",
				"push",
				"-m", "/tmp/addon",
				"-s", "/tmp/addon/source-credentials.json",
				"-t", "/tmp/addon/target-credentials.json",
				"-vvv",
			); cmdErr != nil {
				log.Fatalf("Failed to create/push app to u-OS Registry. err=%s", cmdErr)
			}
		case "export":
			log.Printf("💾 Exporting SWU file for the app from the u-OS Registry: %s", uOSContainerRegistry)
			if cmdErr := runCommand(
				"docker",
				"run",
				"--rm",
				"--pull=always",
				"--network=host",
				"--add-host=host.docker.internal:host-gateway",
				"--mount", fmt.Sprintf("src=%s/build,target=/tmp/addon,type=bind", cwd),
				"-e", fmt.Sprintf("DEFAULT_REGISTRY_SERVER_ADDRESS=%s", uOSContainerRegistry),
				"wmucdev.azurecr.io/u-control/uc-aom-packager:0",
				"uc-aom-packager",
				"export",
				"-m", "/tmp/addon",
				"-t", "/tmp/addon/target-credentials.json",
				"-o", "/tmp/addon/swu",
				"--version", manifest.Version,
				"-vvv",
			); cmdErr != nil {
				log.Fatalf("Failed to create/push app to u-OS Registry. err=%s", cmdErr)
			}
		}
	}

	fmt.Sprintf("✅ Successful")
}
