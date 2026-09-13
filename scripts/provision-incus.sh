#!/usr/bin/env bash
set -Eeuo pipefail

# Provisiona o executor local alt-claude-slave em um container Incus.
# Execute este script no host T610.
#
# Variaveis opcionais:
#   CONTAINER_NAME=alt-claude-slave
#   INCUS_IMAGE=images:ubuntu/24.04
#   STORAGE_POOL=default
#   CPU_LIMIT=12
#   MEMORY_LIMIT=48GiB
#   REPO_URL=https://github.com/EDortta/alt-claude-slave.git
#   SSH_PUBLIC_KEY_FILE=/home/esteban/.ssh/id_ed25519.pub
#   ADOPT_EXISTING=1   # somente se voce confirmar que o container homonimo e o correto

readonly CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
readonly INCUS_IMAGE="${INCUS_IMAGE:-images:ubuntu/24.04}"
readonly CPU_LIMIT="${CPU_LIMIT:-12}"
readonly MEMORY_LIMIT="${MEMORY_LIMIT:-48GiB}"
readonly REPO_URL="${REPO_URL:-https://github.com/EDortta/alt-claude-slave.git}"
readonly SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-}"
readonly ADOPT_EXISTING="${ADOPT_EXISTING:-0}"

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERRO: %s\n' "$*" >&2
  exit 1
}

command -v incus >/dev/null 2>&1 || die "Incus nao foi encontrado no T610."
incus info >/dev/null 2>&1 || die "O usuario atual nao consegue acessar o Incus."

if [[ -n "$SSH_PUBLIC_KEY_FILE" && ! -f "$SSH_PUBLIC_KEY_FILE" ]]; then
  die "Chave publica inexistente: $SSH_PUBLIC_KEY_FILE"
fi

storage_pool="${STORAGE_POOL:-}"
if [[ -z "$storage_pool" ]]; then
  storage_pool="$(incus profile device get default root pool 2>/dev/null || true)"
fi
if [[ -z "$storage_pool" ]]; then
  storage_pool="$(incus storage list --format csv -c n | sed -n '1p')"
fi
[[ -n "$storage_pool" ]] || die "Nao foi possivel detectar um storage pool do Incus. Use STORAGE_POOL=nome."
incus storage show "$storage_pool" >/dev/null 2>&1 || die "Storage pool inexistente: $storage_pool"

volume_exists() {
  incus storage volume show "$storage_pool" "$1" >/dev/null 2>&1
}

instance_exists() {
  incus info "$CONTAINER_NAME" >/dev/null 2>&1
}

device_exists() {
  incus config device get "$CONTAINER_NAME" "$1" source >/dev/null 2>&1
}

ensure_volume() {
  local volume="$1"
  if ! volume_exists "$volume"; then
    log "Criando volume persistente $volume"
    incus storage volume create "$storage_pool" "$volume"
  fi
}

ensure_device() {
  local device="$1"
  local volume="$2"
  local path="$3"

  if ! device_exists "$device"; then
    log "Anexando $volume em $path"
    incus config device add "$CONTAINER_NAME" "$device" disk \
      pool="$storage_pool" source="$volume" path="$path"
  fi
}

for suffix in repos models state; do
  ensure_volume "${CONTAINER_NAME}-${suffix}"
done

if ! instance_exists; then
  log "Criando container $CONTAINER_NAME"
  incus launch "$INCUS_IMAGE" "$CONTAINER_NAME" \
    --storage "$storage_pool" \
    -c "limits.cpu=$CPU_LIMIT" \
    -c "limits.memory=$MEMORY_LIMIT" \
    -c "limits.memory.swap=false" \
    -c "security.privileged=false" \
    -c "security.nesting=false" \
    -c "boot.autostart=true" \
    -c "user.alt-claude-slave=managed"
else
  managed_marker="$(incus config get "$CONTAINER_NAME" user.alt-claude-slave || true)"
  if [[ "$managed_marker" != "managed" && "$ADOPT_EXISTING" != "1" ]]; then
    die "Ja existe um container $CONTAINER_NAME nao criado por este script. Use outro CONTAINER_NAME ou confirme com ADOPT_EXISTING=1."
  fi

  log "Reutilizando container existente $CONTAINER_NAME"
  incus config set "$CONTAINER_NAME" \
    "limits.cpu=$CPU_LIMIT" \
    "limits.memory=$MEMORY_LIMIT" \
    "limits.memory.swap=false" \
    "security.privileged=false" \
    "security.nesting=false" \
    "boot.autostart=true" \
    "user.alt-claude-slave=managed"

  status="$(incus info "$CONTAINER_NAME" | awk '/^Status:/ {print $2}')"
  if [[ "$status" != "RUNNING" ]]; then
    incus start "$CONTAINER_NAME"
  fi
fi

ensure_device slave-repos "${CONTAINER_NAME}-repos" /srv/alt-claude/repos
ensure_device slave-models "${CONTAINER_NAME}-models" /srv/alt-claude/models
ensure_device slave-state "${CONTAINER_NAME}-state" /srv/alt-claude/state

log "Aguardando o container inicializar"
for _ in $(seq 1 60); do
  if incus exec "$CONTAINER_NAME" -- true >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
incus exec "$CONTAINER_NAME" -- true >/dev/null 2>&1 || die "O container nao respondeu em 60 segundos."

log "Instalando dependencias e preparando o executor"
incus exec "$CONTAINER_NAME" -- bash -s -- "$REPO_URL" <<'PROVISION'
set -Eeuo pipefail

repo_url="$1"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  bash ca-certificates cmake curl g++ git jq libopenblas-dev libssl-dev \
  make openssh-server pkg-config python3 python3-venv rsync

if ! id slave >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash slave
fi

install -d -o slave -g slave -m 0750 \
  /srv/alt-claude/repos \
  /srv/alt-claude/models \
  /srv/alt-claude/state

repo_dir=/srv/alt-claude/repos/alt-claude-slave
if [[ -d "$repo_dir/.git" ]]; then
  runuser -u slave -- git -C "$repo_dir" pull --ff-only
else
  runuser -u slave -- git clone "$repo_url" "$repo_dir"
fi

llama_src=/home/slave/.local/src/llama.cpp
llama_install=/home/slave/.local/opt/llama.cpp
install -d -o slave -g slave "$(dirname "$llama_src")" "$llama_install/bin"

if [[ -d "$llama_src/.git" ]]; then
  runuser -u slave -- env HOME=/home/slave git -C "$llama_src" pull --ff-only
else
  runuser -u slave -- env HOME=/home/slave \
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$llama_src"
fi

runuser -u slave -- env HOME=/home/slave \
  cmake -S "$llama_src" -B "$llama_src/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON \
  -DGGML_BLAS=ON \
  -DGGML_BLAS_VENDOR=OpenBLAS
runuser -u slave -- env HOME=/home/slave \
  cmake --build "$llama_src/build" --config Release --parallel "$(nproc)"

for binary in llama-cli llama-server llama-bench; do
  runuser -u slave -- install -m 0755 \
    "$llama_src/build/bin/$binary" "$llama_install/bin/$binary"
done

cat >/etc/profile.d/alt-claude-slave.sh <<'ENVIRONMENT'
export LLAMA_CACHE=/srv/alt-claude/models
export LLAMA_BIN=/home/slave/.local/opt/llama.cpp/bin
ENVIRONMENT
chmod 0644 /etc/profile.d/alt-claude-slave.sh

install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/90-alt-claude-slave.conf <<'SSHD'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers slave
SSHD

systemctl enable --now ssh
PROVISION

if [[ -n "$SSH_PUBLIC_KEY_FILE" ]]; then
  log "Instalando a chave publica para o usuario slave"
  incus exec "$CONTAINER_NAME" -- install -d -o slave -g slave -m 0700 /home/slave/.ssh
  incus file push "$SSH_PUBLIC_KEY_FILE" "$CONTAINER_NAME/home/slave/.ssh/authorized_keys"
  incus exec "$CONTAINER_NAME" -- chown slave:slave /home/slave/.ssh/authorized_keys
  incus exec "$CONTAINER_NAME" -- chmod 0600 /home/slave/.ssh/authorized_keys
  incus exec "$CONTAINER_NAME" -- systemctl restart ssh
fi

container_addresses="$(incus list "$CONTAINER_NAME" --format csv -c 4 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

log "Provisionamento concluido"
printf 'Container:  %s\n' "$CONTAINER_NAME"
printf 'Storage:    %s\n' "$storage_pool"
printf 'Enderecos:  %s\n' "${container_addresses:-consulte com: incus list $CONTAINER_NAME}"
printf '\nEntrar no container:\n  incus exec %s -- su - slave\n' "$CONTAINER_NAME"
printf '\nListar modelos:\n  incus exec %s -- su - slave -c '\''cd /srv/alt-claude/repos/alt-claude-slave && ./slave models'\''\n' "$CONTAINER_NAME"
printf '\nPrimeiro benchmark:\n  incus exec %s -- su - slave -c '\''cd /srv/alt-claude/repos/alt-claude-slave && ./slave benchmark qwen-coder-3b'\''\n' "$CONTAINER_NAME"

if [[ -z "$SSH_PUBLIC_KEY_FILE" ]]; then
  printf '\nLogin SSH direto no container nao foi configurado porque SSH_PUBLIC_KEY_FILE nao foi informado.\n'
  printf 'O acesso por incus exec no host continua disponivel normalmente.\n'
fi
