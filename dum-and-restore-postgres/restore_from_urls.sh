#!/usr/bin/env bash
set -Eeuo pipefail

# Escolhe pg_restore 16 se existir; senão, o padrão do PATH
if command -v /usr/lib/postgresql/16/bin/pg_restore >/dev/null 2>&1; then
  PGRESTORE_BIN="/usr/lib/postgresql/16/bin/pg_restore"
else
  PGRESTORE_BIN="${PGRESTORE_BIN:-pg_restore}"
fi

APPS_CSV="${APPS_CSV:-./apps.csv}"

# Bases SEM /DBNAME ao final
BASE_PROD="postgres://db_admin:0FAzbF036z701dXLS2wsYD4Pa4H@estudologia.c5wpd7lqrh8e.us-west-1.rds.amazonaws.com:5432"
BASE_DEV="postgres://db_devstag_admin:R643Z5Wf3U2IfcTtcphPql8rWmu@estudologia-devstag.c5wpd7lqrh8e.us-west-1.rds.amazonaws.com:5432"

SSL_SUFFIX="?sslmode=require"
JOBS="${JOBS:-4}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Falta '$1' no PATH"; exit 1; }; }
need psql
need curl
# não checamos pg_restore aqui porque vamos usar "$PGRESTORE_BIN"

target_base_for_env() {
  local env="$1"
  if [[ "$env" == "prod" ]]; then
    echo "$BASE_PROD"
  else
    echo "$BASE_DEV"
  fi
}

ensure_db_exists() {
  local base="$1"
  local dbname="$2"
  local admin_url="${base}/postgres${SSL_SUFFIX}"
  local exists
  exists="$(psql "$admin_url" -tAc "SELECT 1 FROM pg_database WHERE datname='${dbname}'" || true)"
  if [[ "$exists" != "1" ]]; then
    echo "Criando database \"${dbname}\"..."
    psql "$admin_url" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${dbname}\";"
  else
    echo "Database \"${dbname}\" já existe."
  fi
}

cleanup_files=()
cleanup() {
  for f in "${cleanup_files[@]:-}"; do
    [[ -f "$f" ]] && rm -f -- "$f" || true
  done
}
trap cleanup EXIT

while IFS=, read -r app env url; do
  # pular cabeçalho e vazios
  [[ "$app" == "app" ]] && continue
  [[ -z "${app// }" ]] && continue

  # normaliza
  app="$(echo "$app" | awk '{$1=$1};1')"
  env="$(echo "$env" | awk '{$1=$1};1')"
  url="$(echo "$url" | awk '{$1=$1};1')"

  [[ -z "$env" || -z "$url" ]] && { echo "[WARN] Linha inválida: $app,$env,$url"; continue; }

  target_base="$(target_base_for_env "$env")"
  dbname="$app"
  target_url="${target_base}/${dbname}${SSL_SUFFIX}"

  ensure_db_exists "$target_base" "$dbname"

  echo "Restaurando $app ($env) -> $target_url"
  export PGOPTIONS='-c statement_timeout=0'

  # 1) Baixar para arquivo temporário (necessário para --jobs)
  dump_file="$(mktemp "/tmp/${app}.XXXXXX.dump")"
  cleanup_files+=("$dump_file")
  echo "[INFO] Baixando backup para $dump_file ..."
  # -L segue redirect; -C - permite retomada se cair
  curl -fL --retry 3 --retry-delay 5 -o "$dump_file" "$url"

  # (Opcional) limpeza “radical” do schema público antes do restore
  # útil se você quer garantir nenhum resquício fora do dump
  # Descomente se desejar:
  # echo "[INFO] Limpando schema public de $dbname ..."
  # psql "$target_url" -v ON_ERROR_STOP=1 -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

  # 2) Restaurar com paralelismo a partir do arquivo
  "$PGRESTORE_BIN" \
    --verbose \
    --clean --if-exists \
    --no-owner --no-acl \
    --jobs "$JOBS" \
    --dbname "$target_url" \
    "$dump_file"

  echo "[OK] $app restaurado."
done < "$APPS_CSV"
