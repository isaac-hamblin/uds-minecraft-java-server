# Minecraft Java UDS Package

This repo builds a standalone UDS package for a Minecraft Java Edition server. The package is intended to deploy onto a UDS Core cluster, while `bundle/uds-bundle.yaml` keeps a local dev/test path that installs UDS Core first.

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
- Persistent volume: `5Gi` using the cluster default StorageClass
- TCP port: `25565`
- UDS service mesh mode: `ambient`

`online-mode=false` is the air-gapped default. Change it with Helm values if your environment supports Mojang authentication.

## Platform Prerequisite

The Minecraft package owns the application, UDS `Package` CR, and Istio routing resources for TCP `25565`. It does not modify UDS Core's tenant ingress gateway Service.

For LAN or load balancer access, the UDS Core environment must expose Minecraft's TCP port on the tenant ingress gateway. Configure this in the UDS Core/environment bundle, not in the Minecraft package:

```yaml
packages:
  - name: core
    repository: ghcr.io/defenseunicorns/packages/uds/core
    ref: 1.6.0-upstream
    overrides:
      istio-tenant-gateway:
        gateway:
          values:
            - path: "service.ports"
              value:
                - name: status-port
                  port: 15021
                  protocol: TCP
                  targetPort: 15021
                - name: http2
                  port: 80
                  protocol: TCP
                  targetPort: 80
                - name: https
                  port: 443
                  protocol: TCP
                  targetPort: 443
                - name: tcp-minecraft
                  port: 25565
                  protocol: TCP
                  targetPort: 25565
```

Without this platform configuration, the Minecraft pod can be healthy while `:25565` is unreachable from outside the cluster.

## Build The Standalone Package

Build the pinned image and create the Zarf package:

```bash
uds run package
```

The build reads `values/common-values.yaml`, verifies the pinned server jar SHA1 and SHA256, builds `minecraft-java-server:26.1.2`, and creates `zarf-package-minecraft-java-amd64-26.1.2-uds.0.tar.zst`.

## Deploy Onto UDS Core

After the UDS Core platform is ready:

```bash
uds deploy zarf-package-minecraft-java-amd64-26.1.2-uds.0.tar.zst --confirm
```

Check the deployment:

```bash
kubectl -n minecraft get pods
kubectl -n minecraft get package minecraft
kubectl -n minecraft logs deploy/minecraft-java --tail=50
```

If the tenant ingress gateway exposes `25565`, connect from Minecraft Java Edition using the gateway/load balancer address:

```text
<tenant-gateway-external-ip>:25565
```

For a local tunnel test, run `kubectl -n minecraft port-forward svc/minecraft-java 25565:25565` on the same machine as the Minecraft client, then connect to `127.0.0.1:25565`.

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

By default, `persistence.storageClassName` is `null`, so the rendered PVC omits `storageClassName` and Kubernetes uses the cluster default StorageClass. Set it only when a target cluster needs a specific class:

```yaml
persistence:
  storageClassName: openebs-hostpath
```

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
