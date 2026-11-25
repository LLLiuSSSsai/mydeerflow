# Self-hosted deployment (single server)

GitHub Actions builds the Gateway and frontend images, pushes them to a registry,
and deploys over SSH. The server only pulls and restarts containers. The bundled
`docker/docker-compose.yaml` still owns the runtime wiring; this directory only
adds the image override and the deploy entry point.

```
git push origin main
        │
        ▼
GitHub Actions ── build ──► registry (GHCR or Aliyun ACR)
        │                         │
        ▼                         ▼
SSH deploy ──► /srv/deer-flow ── docker compose pull + up -d
                                        │
                                        ▼
                              Caddy :443 ──► DeerFlow nginx 127.0.0.1:2026
```

## Registry choice

The workflow defaults to GHCR and needs no extra secrets. A server in mainland
China usually pulls GHCR slowly or not at all; Aliyun ACR is the practical
choice there.

For ACR, create a personal (free) ACR instance, a namespace, and two
repositories named `deer-flow-backend` and `deer-flow-frontend`. Then set:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `IMAGE_PREFIX` | `registry.cn-hangzhou.aliyuncs.com/<namespace>/deer-flow` |
| Secret | `REGISTRY_USERNAME` | ACR username |
| Secret | `REGISTRY_PASSWORD` | ACR registry password |

For GHCR, leave `IMAGE_PREFIX` unset and make the packages pullable by the
server. Add `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` only if the default
`GITHUB_TOKEN` push is not enough.

## One-time server setup

Ubuntu 22.04/24.04, 4 vCPU / 8 GB minimum, 8 vCPU / 16 GB recommended. Docker
Compose must be v2.24 or newer.

```bash
# Docker
curl -fsSL https://get.docker.com | sh
sudo systemctl enable --now docker

# Unprivileged deploy user (docker group is root-equivalent; use a dedicated key)
sudo adduser deploy
sudo usermod -aG sudo,docker deploy
sudo -u deploy mkdir -p ~deploy/.ssh
# add the CI public key to /home/deploy/.ssh/authorized_keys

# Repository
sudo mkdir -p /srv/deer-flow
sudo chown deploy:deploy /srv/deer-flow
sudo -u deploy git clone git@github.com:<owner>/<repo>.git /srv/deer-flow
```

Private repositories need a read-only deploy key on the server. The CI key only
needs to run the deploy script over SSH.

### Runtime files

The server keeps configuration and data outside git:

```bash
cd /srv/deer-flow
mkdir -p backend/.deer-flow

# Copy the wizard-produced config and .env from the development machine.
# /srv/deer-flow/.env must contain the model API keys plus the values below.
scp config.yaml deploy@<server>:/srv/deer-flow/backend/.deer-flow/config.yaml
scp .env        deploy@<server>:/srv/deer-flow/.env

# Docker creates a directory if this path is missing, and the Gateway then fails.
printf '{}\n' > backend/.deer-flow/extensions_config.json
```

Append to `/srv/deer-flow/.env`:

```dotenv
BETTER_AUTH_SECRET=<openssl rand -hex 32>
BIND_HOST=127.0.0.1
PORT=2026
DEER_FLOW_HOME=/srv/deer-flow/backend/.deer-flow
DEER_FLOW_CONFIG_PATH=/srv/deer-flow/backend/.deer-flow/config.yaml
DEER_FLOW_EXTENSIONS_CONFIG_PATH=/srv/deer-flow/backend/.deer-flow/extensions_config.json
DEER_FLOW_INTERNAL_AUTH_TOKEN=<openssl rand -hex 32>
# Only needed for manual deploys; CI passes this variable itself.
DEER_FLOW_IMAGE_PREFIX=ghcr.io/<owner>/<repo>
```

Keep `BIND_HOST=127.0.0.1`: DeerFlow's agent can execute commands, so the
Gateway must not be reachable directly. Caddy terminates TLS and is the only
public entry point.

### Registry login

```bash
# GHCR (private package)
echo '<PAT with read:packages>' | docker login ghcr.io -u <github-user> --password-stdin

# Aliyun ACR
echo '<ACR password>' | docker login registry.cn-hangzhou.aliyuncs.com -u <ACR user> --password-stdin
```

### HTTPS

Open 80 and 443 in the cloud security group; leave 2026, 8001 and 3000 closed.
Stop any existing service on 80 before starting Caddy.

```bash
sudo systemctl disable --now nginx   # only if it is not already gone
sudo apt install -y caddy
sudo cp deploy/selfhost/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

`Caddyfile` defaults to `deerflow.<server-ip>.sslip.io`, which resolves to the
server automatically and gets a Let's Encrypt certificate without owning a
domain. For a real domain, set `DEERFLOW_DOMAIN` in the Caddy unit:

```bash
sudo systemctl edit caddy
# [Service]
# Environment=DEERFLOW_DOMAIN=deerflow.example.com
sudo systemctl daemon-reload && sudo systemctl reload caddy
```

## GitHub configuration

Secrets:

| Secret | Purpose |
| --- | --- |
| `DEPLOY_HOST` | Server IP or hostname |
| `DEPLOY_USER` | SSH user, for example `deploy` |
| `DEPLOY_SSH_KEY` | Private key whose public half is in `authorized_keys` |
| `REGISTRY_USERNAME` | Only for ACR or a non-default GHCR account |
| `REGISTRY_PASSWORD` | Only for ACR or a non-default GHCR account |

Variable:

| Variable | Purpose |
| --- | --- |
| `IMAGE_PREFIX` | Registry prefix; unset means `ghcr.io/<owner>/<repo>` |

The optional `production` environment can require manual approval before the
deploy job runs.

## Deploy

The first build must finish before the server can pull. Trigger
`Build and Deploy` manually from the Actions tab, or push to `main`.

```bash
# Manual deploy on the server
cd /srv/deer-flow
DEER_FLOW_IMAGE_PREFIX=ghcr.io/<owner>/<repo> bash deploy/selfhost/deploy.sh
```

Every deploy fetches `origin/main`, pulls the two application images, and waits
for the Gateway and Redis health checks.

## Rollback

Every build is also tagged `sha-<full-commit>`. Redeploy an older one without
rebuilding:

```bash
cd /srv/deer-flow
DEER_FLOW_IMAGE_PREFIX=ghcr.io/<owner>/<repo> \
IMAGE_TAG=sha-<full-commit> bash deploy/selfhost/deploy.sh
```

## Operations

```bash
# Logs
docker compose --env-file .env -p deer-flow \
  -f docker/docker-compose.yaml \
  -f deploy/selfhost/docker-compose.images.yaml \
  logs -f gateway frontend nginx

# Backup (SQLite database, uploads, memory, credentials)
tar czf /var/backups/deer-flow-$(date +%F-%H%M).tgz \
  -C /srv/deer-flow backend/.deer-flow

# Merge new config fields after upgrading the source
cd /srv/deer-flow && bash scripts/config-upgrade.sh
```

`backend/.deer-flow` is the only stateful path. Keep it out of git and back it
up before every deploy. `skills/` is bind-mounted from the checkout, so
`skills/custom/` (gitignored) must be copied or committed separately if the
server needs those skills.
