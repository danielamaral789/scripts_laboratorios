#!/usr/bin/env bash
set -euo pipefail

APP_NAME="backstage"
APP_DIR="/opt/${APP_NAME}"          # destino no disco novo (sdb1)
HOME_LINK="$HOME/${APP_NAME}"       # atalho conveniente
LOG_FILE="$APP_DIR/yarn_install.log"
NODE_HEAP_MB="${NODE_HEAP_MB:-4096}"  # ajuste para 6144/8192 se necessário

log()  { printf "\n\033[1;32m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\n\033[1;31m[ERR]\033[0m  %s\n" "$*"; }

[[ "${EUID}" -eq 0 ]] && { warn "Rode como usuário normal (nvm é per-user). Continuando em 3s…"; sleep 3; }

# 0) Dependências base
log "Instalando dependências do sistema (pode pedir sudo)…"
sudo apt update -y
sudo apt install -y build-essential python3 make g++ git ca-certificates curl jq

# 1) Desligar Corepack e limpar vestígios
log "Limpando Corepack e caches…"
if command -v corepack >/dev/null 2>&1; then corepack disable || true; fi
rm -rf "$HOME/.cache/corepack" "$HOME/.yarn" "$HOME/.yarnrc.yml" 2>/dev/null || true
npm uninstall -g corepack yarn 2>/dev/null || true
sudo chown -R "$USER:$USER" "$HOME/.npm" "$HOME/.config" "$HOME/.cache" "$HOME/.nvm" 2>/dev/null || true

# 2) nvm + Node 20 LTS
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  log "Instalando nvm…"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
# shellcheck disable=SC1090
. "$NVM_DIR/nvm.sh"
log "Ativando Node 20 LTS…"
nvm install 20 >/dev/null
nvm use 20 >/dev/null
log "Node: $(node -v) | npm: $(npm -v)"

# 3) Yarn 1 (classic) via npm global — SEM Corepack
log "Instalando Yarn 1.22.22 via npm global…"
export PATH="$(npm prefix -g)/bin:$PATH"; hash -r
npm i -g yarn@1.22.22 >/dev/null
hash -r
YV="$(yarn -v || true)"
[[ "$YV" =~ ^1\. ]] || { err "Esperava Yarn 1.x, mas tenho '$YV'"; exit 1; }
log "Yarn: $YV"

# 4) Preparar /opt/backstage e LIMPAR ~/backstage antes do scaffold
log "Preparando diretórios…"
sudo mkdir -p /opt
# limpa /opt/backstage se existir
if [[ -e "$APP_DIR" ]]; then
  if [[ -O "$APP_DIR" ]]; then rm -rf "$APP_DIR"; else sudo rm -rf "$APP_DIR"; fi
fi
# limpa ~/backstage (symlink/arquivo/diretório) para o scaffold não falhar
if [[ -L "$HOME_LINK" || -f "$HOME_LINK" ]]; then
  rm -f "$HOME_LINK"
elif [[ -d "$HOME_LINK" ]]; then
  rm -rf "$HOME_LINK"
fi

# 5) Scaffold do Backstage (sem instalar dependências)
log "Gerando projeto Backstage (latest, --skip-install)…"
cd ~
printf "%s\n" "$APP_NAME" | npx --yes @backstage/create-app@latest --skip-install > /tmp/create_app.log 2>&1 || {
  err "Falha ao criar app. Veja /tmp/create_app.log"
  exit 1
}

# 6) Mover para /opt e criar symlink em ~/
[[ -d "$HOME/$APP_NAME" ]] || { err "Pasta $HOME/$APP_NAME não encontrada. Veja /tmp/create_app.log"; exit 1; }
sudo mv "$HOME/$APP_NAME" "$APP_DIR"
sudo chown -R "$USER:$USER" "$APP_DIR"
ln -s "$APP_DIR" "$HOME_LINK"
cd "$APP_DIR"

# 7) Remover Yarn Berry e limpar 'packageManager' com jq (root + subpastas)
log "Removendo artefatos Yarn Berry e limpando 'packageManager'…"
rm -rf .yarn .yarnrc.yml .yarnrc .pnp.cjs .pnp.data.json .pnp.loader.mjs .pnp.loader.js || true
find . -name package.json -type f -print0 \
  | xargs -0 -I{} bash -lc 'tmp=$(mktemp); jq "del(.packageManager)" "{}" > "$tmp" && mv "$tmp" "{}"'

# 8) Validar JSON (root e subpastas)
log "Validando JSON…"
node -e 'const fs=require("fs"); JSON.parse(fs.readFileSync("./package.json"))' \
  || { err "package.json (root) inválido"; exit 1; }
node -e 'const fs=require("fs"),path=require("path");let bad=0;function scan(d){for(const e of fs.readdirSync(d,{withFileTypes:true})){if(e.name==="node_modules"||e.name===".git")continue;const p=path.join(d,e.name); if(e.isDirectory())scan(p); else if(e.isFile()&&e.name==="package.json"){try{JSON.parse(fs.readFileSync(p))}catch(err){bad++;console.log(\"INVALID:\",p)}}} } scan(\".\"); if(bad){process.exit(1)}' \
  || { err "Há package.json inválido em subpastas"; exit 1; }

# 9) Instalar dependências com heap extra e logar
log "Instalando dependências (log em $LOG_FILE)…"
export NODE_OPTIONS="--max-old-space-size=${NODE_HEAP_MB}"
rm -rf node_modules yarn.lock
YARN_IGNORE_PATH=1 yarn install 2>&1 | tee "$LOG_FILE"

# 10) Finalização
log "Concluído! Para iniciar o servidor de desenvolvimento:"
echo "    cd \"$APP_DIR\" && YARN_IGNORE_PATH=1 yarn start"
echo "    (URL: http://localhost:3000)"
echo "Link prático: ~/backstage -> $APP_DIR"
