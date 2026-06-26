#!/usr/bin/env bash
# Back up all named Docker volumes to a timestamped directory.
# Usage:
#   bash scripts/backup.sh            # backup to ./backups/<timestamp>/
#   BACKUP_DIR=/mnt/nas bash scripts/backup.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DEST="${BACKUP_DIR:-$REPO_ROOT/backups}/$TIMESTAMP"
COMPOSE_PROJECT=$(docker compose --env-file .env config --format json 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('name','monitoring'))" 2>/dev/null || echo "monitoring")

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[backup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn] ${NC} $*"; }

VOLUMES=(
  uptime_kuma_data
  prometheus_data
  grafana_data
  alertmanager_data
)

info "Destination: $DEST"
mkdir -p "$DEST"

# ── Optional: pause containers for a crash-consistent backup ──────────────
PAUSE_CONTAINERS="${PAUSE_CONTAINERS:-false}"
if [[ "$PAUSE_CONTAINERS" == "true" ]]; then
  warn "Pausing containers for consistent backup..."
  docker compose --env-file .env pause uptime-kuma prometheus grafana alertmanager
  trap 'docker compose --env-file .env unpause uptime-kuma prometheus grafana alertmanager; info "Containers unpaused"' EXIT
fi

# ── Back up each volume ────────────────────────────────────────────────────
for vol in "${VOLUMES[@]}"; do
  FULL_VOL="${COMPOSE_PROJECT}_${vol}"
  # Check volume exists
  if ! docker volume inspect "$FULL_VOL" >/dev/null 2>&1; then
    warn "Volume $FULL_VOL not found — skipping"
    continue
  fi
  info "Archiving $FULL_VOL → $DEST/${vol}.tar.gz"
  docker run --rm \
    --mount "type=volume,source=${FULL_VOL},target=/data,readonly" \
    -v "$DEST:/backup" \
    alpine tar czf "/backup/${vol}.tar.gz" -C /data .
done

# ── Copy config files (not secrets) ──────────────────────────────────────
info "Copying configuration files..."
tar czf "$DEST/config.tar.gz" \
  --exclude='nginx/.htpasswd' \
  --exclude='nginx/ssl' \
  --exclude='.env' \
  prometheus alertmanager grafana nginx Makefile docker-compose.yml

# ── Manifest ──────────────────────────────────────────────────────────────
{
  echo "backup_timestamp=$TIMESTAMP"
  echo "host=$(hostname)"
  echo "compose_project=$COMPOSE_PROJECT"
  echo "volumes=${VOLUMES[*]}"
} > "$DEST/manifest.txt"

BACKUP_SIZE=$(du -sh "$DEST" | cut -f1)
info "Backup complete — $BACKUP_SIZE written to $DEST"

# ── Retention: delete backups older than BACKUP_KEEP_DAYS (default 7) ────
KEEP="${BACKUP_KEEP_DAYS:-7}"
BACKUP_ROOT="${BACKUP_DIR:-$REPO_ROOT/backups}"
if [[ -d "$BACKUP_ROOT" ]]; then
  DELETED=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -mtime +"$KEEP" -print -exec rm -rf {} + 2>/dev/null | wc -l)
  [[ $DELETED -gt 0 ]] && info "Pruned $DELETED backup(s) older than ${KEEP} days"
fi
