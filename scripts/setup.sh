#!/usr/bin/env bash
# First-time setup for the monitoring stack.
# Run: bash scripts/setup.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn] ${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ── Prerequisite checks ────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || error "docker not found — install Docker Desktop or Docker Engine first."
docker compose version >/dev/null 2>&1 || error "docker compose v2 not found — upgrade Docker."

# ── .env ──────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
  cp .env.example .env
  warn ".env created from .env.example"
  warn "Edit .env with your real values before running 'make up'."
else
  info ".env already exists — skipping copy"
fi

# ── .htpasswd (basic auth for Prometheus & Alertmanager) ──────────────────
if [ ! -s nginx/.htpasswd ]; then
  info "Creating Prometheus/Alertmanager basic-auth credentials..."
  read -rp "  Username [admin]: " HTUSER
  HTUSER="${HTUSER:-admin}"

  # Use Docker to avoid requiring htpasswd locally
  HTPASS=$(docker run --rm -it httpd:alpine htpasswd -nbB "$HTUSER" "" 2>/dev/null | tr -d '\r')
  # The above generates a hash for an empty password; prompt for a real one:
  read -rsp "  Password: " HTPASSWORD; echo
  HTPASS=$(docker run --rm httpd:alpine sh -c "htpasswd -nbB '$HTUSER' '$HTPASSWORD'" | tr -d '\r')
  echo "$HTPASS" > nginx/.htpasswd
  info "Written nginx/.htpasswd"
else
  info "nginx/.htpasswd already exists — skipping"
fi

# ── SSL directory ─────────────────────────────────────────────────────────
mkdir -p nginx/ssl
info "nginx/ssl/ directory ready (place fullchain.pem + privkey.pem here for HTTPS)"

# ── Validate configs before first start ───────────────────────────────────
info "Validating Prometheus config..."
docker run --rm \
  -v "$REPO_ROOT/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus:v2.53.0 promtool check config /etc/prometheus/prometheus.yml \
  && info "prometheus.yml OK" || error "prometheus.yml failed validation"

info "Validating alerting rules..."
docker run --rm \
  -v "$REPO_ROOT/prometheus/rules:/rules:ro" \
  prom/prometheus:v2.53.0 promtool check rules /rules/*.yml \
  && info "Rules OK" || error "Rule files failed validation"

info "Validating alertmanager config..."
docker run --rm \
  -v "$REPO_ROOT/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" \
  prom/alertmanager:v0.27.0 amtool check-config /etc/alertmanager/alertmanager.yml \
  && info "alertmanager.yml OK" || warn "alertmanager.yml validation failed (check SMTP/Slack placeholders)"

# ── Pull images ───────────────────────────────────────────────────────────
info "Pulling images (this may take a few minutes)..."
docker compose --env-file .env pull

echo ""
info "Setup complete."
echo ""
echo "  Start the stack:    make up"
echo "  View logs:          make logs"
echo "  Open dashboard:     make open"
echo ""
echo "  Service URLs (after 'make up'):"
echo "    Uptime Kuma  →  http://localhost/"
echo "    Grafana      →  http://localhost/grafana/"
echo "    Prometheus   →  http://localhost/prometheus/   (basic auth)"
echo "    Alertmanager →  http://localhost/alertmanager/ (basic auth)"
echo ""
echo "  Recommended Grafana dashboards to import by ID:"
echo "    1860  — Node Exporter Full"
echo "    893   — Docker and System Monitoring (cAdvisor)"
echo "    3662  — Prometheus 2.0 Overview"
