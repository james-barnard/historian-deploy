# Historian Deploy

Production deployment, operations, and update infrastructure for the Historian appliance.

No app source code. No dev tooling. Just production orchestration.

---

## Architecture

```
DEV MAC                         AWS                          DEVICE
───────                         ───                          ──────
                                                             
hist-release                    S3 (private)                 historian-updater.timer
  ↓ build + sign                  ↑ tarball + sig              ↓ every 4h
  ↓ upload                      API Gateway                  POST telemetry → Lambda
  └──→ s3://historian-releases/   ↓                            ↓
                                check-update Lambda          download presigned URL
                                  ↓ verify token               ↓
                                  ↓ log telemetry            verify Ed25519 sig
                                  ↓ check rollout %          verify SHA256
                                  └─→ presigned URL          extract → validate → swap
                                                             hist deploy

register-release Lambda                                     
  ← S3 event on .tar.gz upload                              historian-watchdog.service
  → DynamoDB at 0% rollout                                    ↓ 30s health loop
                                                               auto-restart on failure
```

---

## Repository Contents

| Path | Purpose | Runs On |
|---|---|---|
| `bin/hist` | Production CLI (status, deploy, logs, health, update) | Device |
| `bin/historian-provision` | Factory provisioner — bare metal to smoke-tested appliance | Device |
| `bin/hist-release` | Release packager — build, sign, upload to S3 | Dev Mac |
| `lib/provisioner.rb` | 6-phase provisioning pipeline | Device |
| `lib/deployment_orchestrator.rb` | Multi-phase Docker Compose deployment from `deployment.lock` | Device |
| `lib/service_manager.rb` | Service lifecycle (start/stop/restart/health), migrations, model pulls | Device |
| `lib/service.rb` | Individual service abstraction | Device |
| `lib/updater.rb` | Pull-only update pipeline (S3 → verify → apply) | Device |
| `lib/watchdog.rb` | Container health monitor with lockfile coordination | Device |
| `lib/watchdog_daemon.rb` | Watchdog process entry point | Device |
| `lib/telemetry.rb` | Appliance health snapshots (no PII, no content) | Device |
| `lib/release_packager.rb` | Tarball + manifest + sign + upload pipeline | Dev Mac |
| `systemd/` | Systemd units: watchdog, updater, performance | Device |
| `lambda/` | AWS Lambda functions + SAM template | AWS |
| `docs/` | Flash guide and hardware documentation | Reference |
| `compose.registry.yml` | Docker Compose for production services (10 containers) | Device |
| `deployment.lock` | Pinned image digests per release | Device |
| `services.yml` | Service definitions, health checks, and Ollama model config | Device |
| `platform_manifest.yml` | Hardware detection, platform config (Jetson / GX10) | Device |
| `gx10-performance.sh` | GPU clock-locking script for consistent inference | Device |
| `prod.env.example` | Template for production environment variables | Device |
| `update_config.yml.example` | Template for device update/registration config | Device |
| `VERSION` | Current release version | Both |

### Device Filesystem

```
/opt/historian/         ← this repo (installed by provisioner)
/data/historian/        ← persistent data (vault, databases, models, SSL, soundtracks)
/logs/historian/        ← application logs
```

---

## Services (10 containers)

| Service | Image | Purpose |
|---|---|---|
| `redis` | `redis:7` | Cache and job queue |
| `ollama` | `ollama/ollama:latest` | AI model server (70B models on GX10) |
| `asr` | `historian-asr` | Automatic Speech Recognition |
| `chroma-db` | `historian-chroma-db` | ChromaDB vector database |
| `embed` | `historian-embed` | Text embedding service |
| `app` | `historian-app` | Main Historian application |
| `app-proxy` | `historian-app-proxy` | Nginx reverse proxy + SSL termination |
| `sidekiq` | `historian-app` (shared image) | Background job processor |
| `audio-gateway` | `historian-audio-gateway` | WebSocket voice gateway |
| `historian-tts` | `historian-tts` | NeMo FastPitch + HiFi-GAN TTS |

---

## How To: Factory Provisioning

### Prerequisites

- Freshly flashed Jetson/GX10 with JetPack (see `docs/flash_guide.md`)
- Network connectivity to the device (SSH + internet for GitHub/Docker)
- `FACTORY_SECRET` env var for device registration
- `GHCR_TOKEN` env var (GitHub PAT with `read:packages` scope)

### Steps

```bash
# 1. SSH into the device
ssh historian@<DEVICE_IP>

# 2. Clone the deploy repo
git clone https://github.com/james-barnard/historian-deploy.git
cd historian-deploy

# 3. Run the provisioner
sudo FACTORY_SECRET=your_secret GHCR_TOKEN=ghp_xxx bin/historian-provision

# This runs 6 phases:
#   Phase 1: VALIDATE   — arch, disk, Docker
#   Phase 2: INSTALL    — system packages, NVIDIA runtime, GHCR login, Ruby deps
#   Phase 3: CONFIGURE  — rsync to /opt/historian, directories, permission healing,
#                         SSL, systemd services, hist CLI, device registration
#   Phase 4: DEPLOY     — pull images, start containers, pull Ollama models
#   Phase 5: SMOKE TEST — verify all 7 service endpoints
#   Phase 6: SEAL       — shut down services for shipping
```

### Provisioner Options

```bash
sudo bin/historian-provision                    # Full auto-detect
sudo bin/historian-provision --platform gx10    # Force platform
sudo bin/historian-provision --dry-run           # Preview without changes
sudo bin/historian-provision --skip-deploy       # Install only, no containers
sudo bin/historian-provision --skip-seal         # Leave services running
```

---

## How To: Deploy (on device)

The deployment orchestrator (`hist deploy`) runs a multi-phase lifecycle:

```
Phase 1: Validate deployment.lock
Phase 2: Show deployment plan (services + digests)
Phase 3: Pull images (parallel, with retry + exponential backoff)
Phase 4: Setup data directories (permission healing via ephemeral root container)
Phase 5: Setup system services:
           • WiFi scan on-demand (systemd path unit from historian repo)
           • Watcher USB auto-pairing (udev rules from historian repo)
           • GX10 performance tuning (Tegra-only)
Phase 6: Database migrations + schema verification
Phase 7: Smart restart (only recreates containers with changed digests)
Phase 8: Ollama optimizations + model pulls
Phase 9: Validate all containers running with correct versions
```

### Permission Healing

When Docker auto-creates host-mounted volumes, it creates them as `root`. The orchestrator detects this and runs an ephemeral Alpine container to `chmod 777` the directory, so non-root container users (e.g., `audio-gateway` UID 1000) can write to it.

### Host-Level Service Installation

The orchestrator installs systemd units and udev rules from this repo's own `systemd/` and `bin/` directories:

- **WiFi scan**: `systemd/historian-wifi-scan.path` + `.service` + `bin/historian-wifi-scan` — triggered on-demand via file watch
- **Watcher pairing**: `systemd/99-historian-watcher.rules` + `systemd/historian-pair@.service` + `bin/historian-pair-device` — auto-pairs USB devices via udev

---

## How To: Create a Release

### One-Time Setup

```bash
# 1. Generate Ed25519 signing keypair
mkdir -p ~/.historian
openssl genpkey -algorithm ed25519 -out ~/.historian/update-signing.key
openssl pkey -in ~/.historian/update-signing.key -pubout -out keys/update-signing.pub

# 2. Deploy AWS infrastructure
cd lambda
sam build && sam deploy

# 3. Configure AWS CLI with the release uploader credentials
# (SAM outputs the access key and secret)
aws configure --profile historian-release
```

### Release Workflow

```bash
# 1. Bump version
echo "1.4.0" > VERSION

# 2. Update deployment.lock (after building + pushing new Docker images)
#    This is done from the main historian repo with `hist deploy --build`

# 3. Build, sign, and upload the release
bin/hist-release

# Output:
#   ✦ Packaging 26 files
#   ✦ Generated update_manifest.yml (26 checksums)
#   ✦ Created historian-v1.4.0.tar.gz (54KB)
#   ✦ Signing with Ed25519
#   ✦ Uploading to s3://historian-releases/v1.4.0/
#   ✅ RELEASE COMPLETE
#   Rollout: 0%

# 4. Staged rollout
bin/hist-release rollout 1.4.0 --percent 10     # 10% canary
bin/hist-release rollout 1.4.0 --percent 50     # 50% wider
bin/hist-release rollout 1.4.0 --percent 100    # Full fleet

# 5. Kill switch (if something goes wrong)
bin/hist-release rollout 1.4.0 --percent 0      # Halt immediately
```

### Release Options

```bash
bin/hist-release --dry-run              # Preview what would be packaged
bin/hist-release --skip-upload          # Build and sign locally only
bin/hist-release --version 1.4.0        # Explicit version
bin/hist-release --min-version 1.3.0    # Require devices be on 1.3.0+
```

---

## How To: Daily Operations (on device)

```bash
hist status              # All service status
hist health              # Health check all services
hist deploy              # Deploy from deployment.lock
hist logs app            # View app logs
hist logs audio-gateway  # View gateway logs
hist update              # Check for updates now
hist update --now        # Force update check
hist status --telemetry  # Show what gets sent during update check-ins
hist start [service]     # Start all or one service
hist stop [service]      # Stop all or one service
hist restart [service]   # Restart all or one service
```

---

## Update Package Format

Each release is a signed tarball uploaded to S3:

```
s3://historian-releases/
  v1.3.0/
    historian-v1.3.0.tar.gz       ← signed tarball
    historian-v1.3.0.tar.gz.sig   ← Ed25519 signature
  v1.4.0/
    historian-v1.4.0.tar.gz
    historian-v1.4.0.tar.gz.sig
```

Inside the tarball, `update_manifest.yml` controls validation:

```yaml
version: "1.4.0"
min_version: "1.3.0"         # Devices below this must update incrementally
built_at: "2026-03-20T18:00:00Z"
deploy_repo_commit: "d8c7fad"
source_repo:
  commit: "e49a0aef"
  tag: "v1.4.0"
hooks:
  pre_deploy: null            # Optional: script to run before deploy
  post_deploy: null           # Optional: script to run after deploy
checksums:
  bin/hist: "sha256:abc123..."
  lib/updater.rb: "sha256:def456..."
  deployment.lock: "sha256:789..."
  # ... every file individually checksummed
```

---

## Bare-Metal Services

Four systemd services run outside Docker on the device:

```
historian-watchdog.service      Always-on, 30s health loop
                                Stands down when /var/run/historian-updating.lock exists
                                Auto-restarts crashed containers (3 attempts per 5 min)

historian-updater.timer         Fires every 4 hours (30-min random jitter)
historian-updater.service       Oneshot: check → download → verify → swap → deploy
                                Creates lockfile so watchdog stands down

historian-performance.service   GPU clock locking for consistent inference (Tegra only)

historian-wifi-scan.path        Watches for scan-request file; triggers nmcli scan
historian-wifi-scan.service     Oneshot: runs WiFi scan script when .path fires
```

---

## Supported Platforms

| Platform | RAM | GPU | Ollama Models |
|---|---|---|---|
| Jetson Orin Nano | 8 GB | Shared VRAM | `llama3.2:3b` |
| Asus Ascent GX10 | 128 GB | Shared VRAM | `llama3.1:70b-instruct-q4_K_M` |

Platform auto-detection uses `/etc/nv_tegra_release` + RAM thresholds. Override with `--platform`.

---

## Security Model

- **Pull-only** — the device initiates all connections. No SSH, no inbound ports, no push.
- **Signed packages** — Ed25519 signatures verified against a public key baked in at factory.
- **Private S3** — all public access blocked. Devices access via time-limited presigned URLs.
- **Device tokens** — each device gets a unique token at provisioning time.
- **Transparent telemetry** — `hist status --telemetry` shows the exact JSON payload. Only appliance vitals (version, uptime, disk, service health). Never content, never PII.

---

## AWS Infrastructure

Provisioned via SAM (`lambda/template.yml`):

```bash
cd lambda && sam build && sam deploy
```

| Resource | Type | Purpose |
|---|---|---|
| `historian-update-api` | API Gateway | `POST /v1/check-update`, `/v1/register-device` |
| `historian-check-update` | Lambda (Ruby 3.3) | Device check-in, presigned URL |
| `historian-register-device` | Lambda (Ruby 3.3) | Factory provisioning, idempotent |
| `historian-register-release` | Lambda (Ruby 3.3) | S3 event → DynamoDB |
| `historian-releases` | S3 Bucket | Signed tarballs |
| `historian-releases` | DynamoDB | Release registry + rollout % |
| `historian-devices` | DynamoDB | Device registry + telemetry |
| `historian-release-uploader` | IAM User | Scoped S3 + DynamoDB access |
