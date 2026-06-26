# Selfhosted Server Monitoring Stack

A production-ready, self-hosted server monitoring stack built with Docker Compose. Covers uptime monitoring, infrastructure metrics, alerting, and dashboards — all behind a single Nginx reverse proxy.

---

## Stack

| Service | Image | Role |
|---|---|---|
| **Uptime Kuma** | `louislam/uptime-kuma:2` | HTTP / TCP / ping uptime monitoring + public status page |
| **Prometheus** | `prom/prometheus:v2.53.0` | Metrics scraping and time-series storage (30-day retention) |
| **Alertmanager** | `prom/alertmanager:v0.27.0` | Alert routing, grouping, and deduplication (email + Slack) |
| **Grafana** | `grafana/grafana:11.1.0` | Dashboards and visualization |
| **Node Exporter** | `prom/node-exporter:v1.8.1` | Host CPU, memory, disk, and network metrics |
| **cAdvisor** | `gcr.io/cadvisor/cadvisor:v0.49.1` | Per-container resource metrics |
| **Nginx** | `nginx:1.27-alpine` | Reverse proxy, SSL termination, rate limiting, basic auth |

---

## Architecture

```
Internet / LAN
      │
  ┌───▼──────────────────────────────────────────┐
  │  Nginx  :80 / :443                           │
  │  rate-limit · SSL · basic-auth on admin UIs  │
  └──┬─────────┬──────────┬──────────────┬───────┘
     │         │          │              │
    /          /grafana/  /prometheus/  /alertmanager/
  (public)   (own auth)  (htpasswd)    (htpasswd)
     │         │          │              │
 Uptime     Grafana   Prometheus   Alertmanager
 Kuma                     │
                    scrapes │
               ┌──────────┴──────────┐
          node-exporter          cadvisor
          (host metrics)     (container metrics)
```

Only Nginx exposes ports to the host. All other services communicate on an internal Docker bridge network (`172.20.0.0/24`).

---

## Prerequisites

- [Docker Engine](https://docs.docker.com/engine/install/) ≥ 24 or [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- Docker Compose v2 (`docker compose version`)
- `make` (Linux/macOS built-in; Windows: use Git Bash, WSL, or [Chocolatey](https://chocolatey.org/) `choco install make`)

> **Windows / Docker Desktop note:** Node Exporter and cAdvisor will report metrics for the WSL2 VM, not the Windows host. All other services work normally.

---

## Quick Start

### 1. Clone

```bash
git clone https://github.com/rejRoky/selfhosted-server-monitoring-stack.git
cd selfhosted-server-monitoring-stack
```

### 2. Configure environment

```bash
cp .env.example .env
```

Open `.env` and set at minimum:

```env
DOMAIN=your.server.com          # or localhost for local dev
GRAFANA_ADMIN_PASSWORD=...      # strong password
TZ=America/New_York             # your timezone
```

### 3. Generate basic-auth credentials

Prometheus and Alertmanager are protected by HTTP basic auth. Generate the credential file:

```bash
docker run --rm httpd:alpine htpasswd -nbB admin "YourPassword" > nginx/.htpasswd
```

Or use the interactive setup script (Linux/macOS/WSL):

```bash
bash scripts/setup.sh
```

### 4. Start the stack

```bash
make up
```

### 5. Open the dashboards

| URL | Service | Auth |
|---|---|---|
| `http://localhost/` | Uptime Kuma | First-run setup wizard |
| `http://localhost/grafana/` | Grafana | `admin` / value from `.env` |
| `http://localhost/prometheus/` | Prometheus | htpasswd credentials |
| `http://localhost/alertmanager/` | Alertmanager | htpasswd credentials |

---

## Configuration

### Environment variables (`.env`)

| Variable | Default | Description |
|---|---|---|
| `DOMAIN` | `localhost` | Server domain for external URLs |
| `TZ` | `UTC` | IANA timezone string |
| `HTTP_PORT` | `80` | Host port for HTTP |
| `HTTPS_PORT` | `443` | Host port for HTTPS |
| `GRAFANA_ADMIN_USER` | `admin` | Grafana admin username |
| `GRAFANA_ADMIN_PASSWORD` | — | **Required.** Grafana admin password |
| `PROMETHEUS_RETENTION` | `30d` | Metrics retention period |
| `PROMETHEUS_RETENTION_SIZE` | `10GB` | Max TSDB size on disk |
| `ENVIRONMENT` | `production` | Label attached to all metrics/alerts |

### Alertmanager (`alertmanager/alertmanager.yml`)

Alertmanager reads its config file directly — shell variable substitution is **not** supported. Edit the file to set your notification channels:

```yaml
global:
  smtp_smarthost: "smtp.yourprovider.com:587"
  smtp_from: "alerts@yourdomain.com"
  smtp_auth_username: "alerts@yourdomain.com"
  smtp_auth_password: "your_smtp_password"
```

To enable Slack alerts, uncomment the `slack_configs` block in `alertmanager/alertmanager.yml` and paste your [Incoming Webhook URL](https://api.slack.com/messaging/webhooks).

### Grafana dashboards

Grafana auto-provisions the Prometheus datasource on first start. To add community dashboards:

1. Open `http://localhost/grafana/` → **Dashboards → Import**
2. Import by ID:

| ID | Dashboard |
|---|---|
| `1860` | Node Exporter Full (host metrics) |
| `893` | Docker & System Monitoring (cAdvisor) |
| `3662` | Prometheus 2.0 Overview |

You can also drop `.json` files into `grafana/provisioning/dashboards/files/` and they will be picked up automatically within 30 seconds.

### HTTPS / SSL

Place your certificates in `nginx/ssl/`:

```
nginx/ssl/
├── fullchain.pem
└── privkey.pem
```

Then uncomment the HTTPS server block in [nginx/conf.d/monitoring.conf](nginx/conf.d/monitoring.conf) and set `DOMAIN` in `.env`.

For [Let's Encrypt](https://letsencrypt.org/) certificates, use [Certbot](https://certbot.eff.org/) or [acme.sh](https://acme.sh/) on the host and mount the output into `nginx/ssl/`.

---

## Alerting Rules

Three rule files ship out of the box:

| File | Covers |
|---|---|
| `prometheus/rules/host.rules.yml` | CPU load, memory, disk space, disk fill prediction, network errors, clock skew |
| `prometheus/rules/containers.rules.yml` | Container restarts, CPU throttling, OOM risk, volume usage |
| `prometheus/rules/services.rules.yml` | Scrape target down, slow scrapes, Prometheus/Alertmanager self-health |

Severity levels: `warning` (batched, every 4 h) and `critical` (immediate, every 1 h until resolved).

---

## Makefile Reference

Run `make` with no arguments to see all available targets.

```
  setup                  First-time setup: create .env, generate htpasswd, create SSL dir
  up                     Start all services (detached)
  down                   Stop all services (volumes are preserved)
  restart                Restart all services
  restart-<service>      Restart a single service (e.g. make restart-grafana)
  pull                   Pull the latest image tags pinned in docker-compose.yml
  update                 Pull latest images and recreate changed containers
  logs                   Follow logs for all services (Ctrl-C to stop)
  logs-<service>         Follow logs for a single service (e.g. make logs-prometheus)
  ps / status            Show running containers and their status
  health                 Print health status of every container
  reload-prometheus      Hot-reload Prometheus config without restart
  reload-nginx           Hot-reload Nginx config without restart
  check-prometheus       Validate prometheus.yml syntax
  check-rules            Validate Prometheus alerting rule files
  check-alertmanager     Validate alertmanager.yml syntax
  backup                 Back up all named volumes to backups/<timestamp>/
  restore                Restore from BACKUP=backups/<timestamp>
  prune                  Remove stopped containers and dangling images
  open                   Open the monitoring dashboard in the default browser
```

---

## Backup & Restore

### Backup

```bash
make backup
# Archives saved to: backups/YYYYMMDD_HHMMSS/
```

For off-site backups, set `BACKUP_DIR` to an external mount:

```bash
BACKUP_DIR=/mnt/nas/monitoring bash scripts/backup.sh
```

Backups older than 7 days are pruned automatically. Override with `BACKUP_KEEP_DAYS=14`.

### Restore

```bash
make restore BACKUP=backups/20240101_120000
```

---

## Project Structure

```
.
├── docker-compose.yml              # Full 7-service stack definition
├── .env.example                    # All configuration variables with defaults
├── Makefile                        # Developer workflow commands
├── alertmanager/
│   └── alertmanager.yml            # Alert routing: email + Slack
├── grafana/
│   ├── grafana.ini                 # Security and server settings
│   └── provisioning/
│       ├── datasources/
│       │   └── prometheus.yml      # Auto-provisioned Prometheus datasource
│       └── dashboards/
│           ├── provider.yml        # Dashboard provider config
│           └── files/              # Drop .json dashboard files here
├── nginx/
│   ├── nginx.conf                  # Global settings, gzip, rate-limit zones
│   ├── conf.d/
│   │   └── monitoring.conf         # Upstreams, server block, location routing
│   └── ssl/                        # Place fullchain.pem + privkey.pem here
├── prometheus/
│   ├── prometheus.yml              # Scrape configs for all exporters
│   └── rules/
│       ├── host.rules.yml          # Host-level alerting rules
│       ├── containers.rules.yml    # Container-level alerting rules
│       └── services.rules.yml      # Service availability alerting rules
└── scripts/
    ├── setup.sh                    # First-time interactive setup
    └── backup.sh                   # Volume backup with retention pruning
```

---

## Production Checklist

- [ ] Set a strong `GRAFANA_ADMIN_PASSWORD` in `.env`
- [ ] Replace default credentials in `nginx/.htpasswd`
- [ ] Set real SMTP credentials in `alertmanager/alertmanager.yml`
- [ ] Set `DOMAIN` to your actual server domain
- [ ] Add SSL certificates to `nginx/ssl/` and enable the HTTPS block
- [ ] Restrict Prometheus and Alertmanager by IP in `nginx/conf.d/monitoring.conf`
- [ ] Import recommended Grafana dashboards (IDs: 1860, 893, 3662)
- [ ] Add monitors in Uptime Kuma for your services
- [ ] Schedule regular backups (`make backup` via cron)

---

## License

MIT
