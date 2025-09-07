#!/usr/bin/env bash
set -Eeuo pipefail

# Entrada e saída
APPS_FILE="${APPS_FILE:-./apps.txt}"
OUT_CSV="${OUT_CSV:-./apps.csv}"

# Paralelismo (quantos backups simultâneos; ajuste se quiser rodar tudo em série)
PARALLEL="${PARALLEL:-3}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Falta '$1' no PATH"; exit 1; }; }
need heroku
need grep
need awk
need xargs
need bash

# Verifica login no Heroku
heroku whoami >/dev/null 2>&1 || { echo "Faça login no Heroku: heroku login"; exit 1; }

# Função para derivar env (ajuste se quiser regras diferentes)
infer_env() {
  local app="$1"
  # Exemplo simples: se nome contiver "-prd" -> prod, senão dev
  if [[ "$app" =~ (prd|prod|production) ]]; then
    echo "prod"
  else
    echo "dev"
  fi
}

# Dispara captura, aguarda terminar e escreve "app,env,url" na saída padrão
process_app() {
  local app="$1"
  local env
  env="$(infer_env "$app")"

  echo "[INFO] Capturando backup para $app ..."
  heroku pg:backups:capture -a "$app"

  echo -n "[INFO] Aguardando backup completar para $app"
  until heroku pg:backups:info -a "$app" | grep -q "Completed"; do
    echo -n "."
    sleep 10
  done
  echo

  local url
  url="$(heroku pg:backups:url -a "$app")"
  if [[ -z "$url" ]]; then
    echo "[ERRO] Não consegui obter URL do backup para $app" >&2
    return 1
  fi

  echo "${app},${env},${url}"
}

export -f process_app infer_env
export HEROKU_DISABLE_TELEMETRY=1

# Cabeçalho do CSV
echo "app,env,url" > "$OUT_CSV"

# Lê apps e processa (ignorando linhas vazias e comentários)
grep -v '^\s*$' "$APPS_FILE" | grep -v '^\s*#' \
| xargs -I{} -P "$PARALLEL" bash -c 'process_app "$@"' _ {} \
>> "$OUT_CSV"

echo "[OK] Gerado: $OUT_CSV"
