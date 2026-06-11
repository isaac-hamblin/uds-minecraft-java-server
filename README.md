# Minecraft Java UDS Package

This repo builds a standalone UDS package for a Minecraft Java Edition server. The package is intended to deploy onto an existing UDS Core cluster, while `bundle/uds-bundle.yaml` keeps a local dev/test path that installs UDS Core first.

The Minecraft server jar is pinned, downloaded during image build, checksum verified, and baked into the package image so the cluster does not need internet access at runtime.

## Tooling

Install:

- Docker
- k3d
- kubectl
- Helm
- jq
- yq
- Zarf `v0.77.0+`
- UDS CLI `v0.32.0+`

## Package Defaults

- Minecraft version: `26.1.2`
- Package version: `26.1.2-uds.0`
- Image: `minecraft-java-server:26.1.2`
- EULA: `TRUE`
- Online mode: `false`
- Memory: `2G`
- Persistent volume: `5Gi` using `local-path`
- TCP port: `25565`
- UDS service mesh mode: `ambient`

`online-mode=false` is the air-gapped default. Change it with Helm values if your environment supports Mojang authentication.

## Build The Standalone Package

Build the pinned image and create the Zarf package:

```bash
uds run package
```

Equivalent direct command:

```bash
scripts/build-minecraft-zarf.sh --package-options "--skip-sbom"
```

The build reads `values/common-values.yaml`, verifies the pinned server jar SHA1 and SHA256, builds `minecraft-java-server:26.1.2`, and creates `zarf-package-minecraft-java-amd64-26.1.2-uds.0.tar.zst`.

## Deploy Onto Existing UDS Core

After UDS Core is already deployed:

```bash
uds deploy zarf-package-minecraft-java-amd64-26.1.2-uds.0.tar.zst --confirm
```

Check the deployment:

```bash
kubectl -n minecraft get pods
kubectl -n minecraft get package minecraft
kubectl -n minecraft logs deploy/minecraft-java --tail=50
```

Connect from Minecraft Java Edition using:

```text
127.0.0.1:25565
```

Use your load balancer or node address instead of `127.0.0.1` when connecting from another machine.

## Local Dev/Test Bundle

Create a local k3d cluster:

```bash
k3d cluster create --config cluster-config.yaml
```

Build the package, create the dev bundle, and deploy it:

```bash
uds run package
uds run bundle
uds deploy bundle/uds-bundle-minecraft-java-dev-amd64-26.1.2-uds.0.tar.zst --confirm
```

The local bundle includes:

- `uds-k3d-dev` `0.20.1-airgap`
- Zarf init `v0.77.0`
- UDS Core `1.6.0-upstream`
- This Minecraft package

The bundle preserves the tenant gateway TCP service port override for Minecraft on `25565`.

## Configuration

Primary package defaults live in `values/common-values.yaml` and `chart/values.yaml`.

Common overrides:

- `minecraft.memory`
- `minecraft.onlineMode`
- `minecraft.javaOpts`
- `minecraft.serverProperties`
- `persistence.size`
- `persistence.storageClassName`
- `gateway.enabled`
- `network.additionalAllow`

## Updating Minecraft

Normal builds are reproducible and do not resolve `latest`. To intentionally update the pinned Minecraft version:

```bash
uds run update-minecraft
```

To pin a specific version:

```bash
scripts/update-minecraft-version.sh --version 26.1.2 --uds-revision 0
```

Review the resulting diff, then rebuild the package.

## Validation

Run static chart validation:

```bash
uds run lint
```

Or directly:

```bash
helm lint chart -f values/common-values.yaml
helm template minecraft-java chart --namespace minecraft -f values/common-values.yaml
```

After a build, confirm the build workflow did not mutate tracked files:

```bash
git diff --exit-code
```
