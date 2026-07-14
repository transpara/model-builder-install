# Model Builder — Kubernetes Installer

Installs **Model Builder** and the **claude-subscription-gateway** it depends
on to a Kubernetes cluster. Nothing is installed on the host: no Docker, no
Node.js, no Claude CLI. The Claude subscription login lives in a persistent
volume inside the cluster. At the end you will have:

- The **claude-subscription-gateway** running as a cluster-internal service
  (`claude-subscription-gateway:8790`), backed by a Claude Max/Pro subscription
- **Model Builder** running with its UI on `http://<server-ip>:30410`
- A verified end-to-end model generation

```
Browser ──▶ Model Builder (:30410 NodePort) ──▶ Gateway (ClusterIP :8790) ──▶ claude CLI (in-pod) ──▶ Claude subscription
                    │                                  │
                    └── model-data PVC (SQLite)        └── claude-credentials PVC (login)
```

This repository contains the installer script and the deployment manifests
(`deploy/k8s/`). It is public so nothing here needs credentials to download;
the application images are private and need one GitHub token (below).

---

## Quick start

**Have ready before you start:**

- A **GitHub classic PAT with the `read:packages` scope** (lets the cluster
  pull the private application images)
- Your **Claude Max (or Pro) account** login
- **SSH access with sudo** on the target server

**Then, in an SSH session on the server:**

```bash
curl -fsSL https://raw.githubusercontent.com/transpara/model-builder-install/main/install-model-builder.sh \
  -o install-model-builder.sh
chmod +x install-model-builder.sh
./install-model-builder.sh --install-k3s
# omit --install-k3s if the server already runs Kubernetes
```

(Cloning this repository and running `./install-model-builder.sh` from it
works exactly the same; the standalone script fetches the manifests itself.)

**What happens next, in order:**

1. The script installs k3s if needed (sudo), then checks the cluster.
2. It prompts for your GitHub username and PAT (hidden input) to create the
   image pull secret, and generates the gateway's key material. Existing
   secrets are never overwritten on a re-run.
3. It deploys everything and waits; the first image pulls take a few minutes.
4. It runs health checks, then asks:
   `Run 'claude setup-token' in the gateway pod now? [y/N]`. Answer `y`, open
   the URL it prints **in the browser on your own computer** (not the
   server), sign in with the Claude account, and paste the code back into the
   terminal.
5. It wires Model Builder to the gateway automatically, runs a real test
   completion through the whole chain, and prints the UI address
   (`http://<server-ip>:30410`).

The script is idempotent: if anything fails partway, fix the cause (see
Troubleshooting below) and re-run the same command; it picks up where things
stand. You can also run it from any machine whose `kubectl` already reaches
the cluster instead of on the server itself (drop `--install-k3s`).

---

## Using an existing gateway

If a claude-subscription-gateway already runs somewhere reachable, you can
point Model Builder at it instead of installing a second one: deploy only
Model Builder with

```bash
kubectl apply -f deploy/k8s/model-builder.yaml -n model-builder
```

then set its URL and `CSG_API_KEY` in the UI under **Settings → Claude
Gateway**. Requirements:

- The gateway **must run `CSG_ALLOW_TOOLS=true`**, or Model Builder's research
  step silently produces generic results (no error).
- If it lives in another namespace behind a NetworkPolicy, that policy must
  admit traffic from the `model-builder` namespace.

---

## After the install

```bash
# UI
http://<server-ip>:30410

# Logs
kubectl -n model-builder logs -f deploy/model-builder
kubectl -n model-builder logs -f deploy/claude-subscription-gateway

# Gateway admin UI (username admin; password from the gateway-secrets secret)
kubectl -n model-builder port-forward svc/claude-subscription-gateway 8790:8790
# then open http://localhost:8790/admin

# Read the gateway API key back at any time
kubectl -n model-builder get secret gateway-secrets -o jsonpath='{.data.CSG_API_KEY}' | base64 -d

# Update to the latest images
kubectl -n model-builder rollout restart deploy/model-builder deploy/claude-subscription-gateway

# Back up Model Builder's data (runs DB + settings)
kubectl -n model-builder exec deploy/model-builder -- tar czf - -C /data . > model-data-backup.tgz

# Tear everything down (deletes the database and the Claude login too)
kubectl delete namespace model-builder
```

Subscription re-auth, if the login ever expires, is one command:

```bash
kubectl -n model-builder exec -it deploy/claude-subscription-gateway -- claude setup-token
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod stuck `ImagePullBackOff` | The pull secret is missing or wrong, or the PAT expired or lacks `read:packages`. Delete the `ghcr-pull` secret and re-run the script to recreate it. |
| PVC stuck `Pending` | No default StorageClass. `kubectl get sc`; k3s ships one, other clusters need a provisioner. |
| Gateway pod `CrashLoopBackOff`, logs say "CSG_API_KEY is required" | The `gateway-secrets` secret is missing. Re-run the script. |
| Every gateway request returns 401 | Model Builder's saved key does not match the gateway's. Re-run the script; it re-saves the settings from the secret. |
| Gateway 502 / test completion fails | The subscription login is missing or expired. Run the `claude setup-token` command above, then re-run the script to verify. |
| Model Builder: "claude gateway not configured" | Settings were never saved. Re-run the script, or set them in the UI under Settings → Claude Gateway. |
| Research step finds nothing, models are generic | The gateway is not running `CSG_ALLOW_TOOLS=true`. The shipped manifests set it; a reused external gateway may not. |
| UI unreachable on :30410 | NodePort blocked by a host firewall, or wrong server IP. `kubectl -n model-builder get svc model-builder` to confirm, or use `kubectl -n model-builder port-forward svc/model-builder 4010:4010` as a fallback. |
| 503 with Retry-After from the gateway | All concurrency slots busy. Raise `CSG_MAX_CONCURRENCY` in `deploy/k8s/gateway.yaml` and `kubectl apply -k deploy/k8s/`. |

---

## What's in this repo

```
install-model-builder.sh   the installer (self-contained; fetches manifests
                           from this repo when run standalone)
deploy/k8s/                Kubernetes manifests (kustomize):
  gateway.yaml             claude-subscription-gateway Deployment/Service/PVC
  model-builder.yaml       Model Builder Deployment/Service/PVC
  network-policy.yaml      restricts gateway access to the namespace
  namespace.yaml, kustomization.yaml
```

These files are mirrored from the `transpara/model-builder` repository, which
is their source of truth.
