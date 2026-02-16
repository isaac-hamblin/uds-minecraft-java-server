# Minecraft Java (UDS Bundle)

This repo deploys a Minecraft Java server on a local k3d cluster using UDS.
The server jar is downloaded during the build step and baked into the Zarf package so the cluster doesn’t need internet at runtime.

## What you need installed

* Docker
* k3d
* kubectl
* zarf
* uds
* jq + curl

---

## 1) Create the cluster

From the repo root:

```bash
k3d cluster create --config cluster-config.yaml
```

---

## 2) Init Zarf

```bash
zarf init --confirm
```

---

## 3) Build the package (downloads the latest server jar)



```bash
chmod +x scripts/build-minecraft-zarf.sh
```

Build + create the UDS bundle artifact:

```bash
./scripts/build-minecraft-zarf.sh --uds-create
```

(If you want the latest snapshot instead of the latest release:)

```bash
./scripts/build-minecraft-zarf.sh --snapshot --uds-create
```

---

## 4) Deploy

```bash
UDS_CONFIG=uds-config.yaml uds deploy uds-bundle-minecraft-bundle-amd64-0.0.1.tar.zst --confirm
```

---

## 5) Check it’s running

```bash
kubectl -n minecraft get pods
kubectl -n minecraft logs deploy/minecraft-java --tail=50
```
---

## 6) Connect

From Minecraft Java Edition add a server or use Direct Connect

* On the same machine: `127.0.0.1:25565`
* From another device on your network: `<your PC’s LAN IP>:25565`



---

## Updating the server later

Just run the build script again and redeploy:

```bash
./scripts/build-minecraft-zarf.sh --uds-create
UDS_CONFIG=uds-config.yaml uds deploy uds-bundle-minecraft-bundle-amd64-0.0.1.tar.zst --confirm
```
