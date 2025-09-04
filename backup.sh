#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# CONFIG PAR DÉFAUT
# =========================
BACKUP_DIR="${BACKUP_DIR:-./backups}"         # Dossier local où stocker les backups
RETENTION_DAYS="${RETENTION_DAYS:-7}"         # Rétention des backups (jours)

# Noms de service/volumes d'après ton docker-compose
COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"  # ou "docker-compose" si ancien binaire
DB_SERVICE="${DB_SERVICE:-db}"
WEB_SERVICE="${WEB_SERVICE:-web}"

MEDIA_VOLUME="${MEDIA_VOLUME:-django_media}"
STATIC_VOLUME="${STATIC_VOLUME:-django_static}"

# Variables DB (doivent correspondre à ton .env / compose)
POSTGRES_DB="${POSTGRES_DB:-bookstore}"
POSTGRES_USER="${POSTGRES_USER:-django}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-django}"

# =========================
# FONCTIONS
# =========================
log() { printf "\033[1;36m[INFO]\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Commande requise introuvable: $1"; exit 1; } }

timestamp() { date +"%Y%m%d-%H%M%S"; }

# Sauvegarde d'un volume Docker -> tar.gz
backup_volume() {
  local volume_name="$1"
  local dest_tar="$2"
  # On lance un conteneur éphémère pour lire le volume et tar son contenu
  docker run --rm \
    -v "${volume_name}":/data:ro \
    -v "$(realpath "$BACKUP_DIR")":/backup \
    alpine:3 sh -c "cd /data && tar -czf /backup/$(basename "$dest_tar") ."
}

# =========================
# PRÉREQUIS
# =========================
need_cmd docker
mkdir -p "$BACKUP_DIR"

# Vérifier que les services tournent (utile pour pg_dump)
if ! $COMPOSE_CMD ps | grep -q "$DB_SERVICE"; then
  err "Le service DB ('$DB_SERVICE') n'est pas détecté. Lance d'abord: $COMPOSE_CMD up -d"
  exit 1
fi

# =========================
# DÉBUT BACKUP
# =========================
DATE="$(timestamp)"
DB_SQL="${BACKUP_DIR}/db_${POSTGRES_DB}_${DATE}.sql.gz"
MEDIA_TAR="${BACKUP_DIR}/media_${DATE}.tar.gz"
STATIC_TAR="${BACKUP_DIR}/static_${DATE}.tar.gz"
MANIFEST="${BACKUP_DIR}/manifest_${DATE}.txt"

log "Démarrage du backup — $(date)"
log "Dossier: ${BACKUP_DIR}"

# 1) Backup PostgreSQL via pg_dump (cohérent)
log "Backup base PostgreSQL '${POSTGRES_DB}' via pg_dump..."
# On injecte le mot de passe uniquement pour la commande
$COMPOSE_CMD exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_SERVICE" \
  sh -lc "pg_dump -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' | gzip -c" > "$DB_SQL"
ok "DB sauvegardée -> $DB_SQL"

# 2) Backup volume MEDIA
log "Backup volume media '${MEDIA_VOLUME}'..."
backup_volume "$MEDIA_VOLUME" "$MEDIA_TAR"
ok "MEDIA sauvegardé -> $MEDIA_TAR"

# 3) Backup volume STATIC
log "Backup volume static '${STATIC_VOLUME}'..."
backup_volume "$STATIC_VOLUME" "$STATIC_TAR"
ok "STATIC sauvegardé -> $STATIC_TAR"

# 4) Manifeste
log "Écriture du manifeste..."
{
  echo "Date: $(date)"
  echo "DB:    $DB_SQL"
  echo "MEDIA: $MEDIA_TAR"
  echo "STATIC:$STATIC_TAR"
  echo "Compose cmd: $COMPOSE_CMD"
  echo "Services: DB=$DB_SERVICE WEB=$WEB_SERVICE"
} > "$MANIFEST"
ok "Manifest -> $MANIFEST"

# 5) Rétention
log "Nettoyage des backups de plus de ${RETENTION_DAYS} jours..."
find "$BACKUP_DIR" -type f -mtime "+${RETENTION_DAYS}" -name '*.gz' -delete || true
find "$BACKUP_DIR" -type f -mtime "+${RETENTION_DAYS}" -name 'manifest_*.txt' -delete || true
ok "Rétention OK"

ok "Backup terminé ✅"
