#!/usr/bin/env bash
# ============================================================================
# ollama-prod.sh v2.0 - Deploy server AI lokal (Ollama) untuk production
#
# Arsitektur:
#   ARTEX --HTTPS+Bearer token--> nginx :8443 --> Ollama 127.0.0.1:11434
#   - Ollama TIDAK terbuka ke jaringan (bind localhost)
#   - nginx: TLS, token auth, IP allowlist, rate limit, hanya route /v1/*
#   - ufw: default deny, hanya IP ARTEX yang boleh ke port proxy
#   - systemd: auto-restart, model di-preload, healthcheck tiap 5 menit
#
# Perintah:
#   sudo ./ollama-prod.sh install        (default)
#   sudo ./ollama-prod.sh status
#   sudo ./ollama-prod.sh rotate-token
#   sudo ./ollama-prod.sh uninstall
#
# Konfigurasi lewat environment variable (semua opsional), contoh:
#   sudo MODEL=gpt-oss:20b ALLOWED_IPS="127.0.0.1" \
#        MGMT_IPS="IP-ADMIN" OLLAMA_VERSION=0.12.0 ./ollama-prod.sh install
# ============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
STATE_DIR="/etc/ollama-prod"
STATE_FILE="${STATE_DIR}/deploy.env"
TOKEN_FILE="${STATE_DIR}/api-token"
TLS_DIR="${STATE_DIR}/tls"
NGINX_CONF="/etc/nginx/conf.d/ollama-proxy.conf"
INSTALL_LOG="/var/log/ollama-prod-install.log"

# ---------- helper output ----------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'printf "\033[1;31m[x]\033[0m Gagal di baris %s (exit %s). Log: %s\n" "$LINENO" "$?" "$INSTALL_LOG" >&2' ERR

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
}

require_root() { [[ $EUID -eq 0 ]] || die "Jalankan sebagai root (sudo $0 ...)"; }

# ---------- konfigurasi (default + override via env) ----------
load_config() {
  MODEL="${MODEL:-gpt-oss:20b}"
  OLLAMA_VERSION="${OLLAMA_VERSION:-}"          # kosong = latest (disarankan pin versi)
  OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-}"    # kosong = default Ollama
  OLLAMA_PORT="${OLLAMA_PORT:-11434}"
  CTX="${CTX:-32768}"
  NUM_PARALLEL="${NUM_PARALLEL:-2}"
  MAX_LOADED_MODELS="${MAX_LOADED_MODELS:-1}"
  KEEP_ALIVE="${KEEP_ALIVE:--1}"                # -1 = model selalu di memori
  FLASH_ATTENTION="${FLASH_ATTENTION:-1}"
  KV_CACHE_TYPE="${KV_CACHE_TYPE:-}"            # q8_0 / q4_0 (hemat VRAM, butuh flash attention)

  ENABLE_PROXY="${ENABLE_PROXY:-1}"             # 0 = tanpa nginx (tanpa auth, TIDAK disarankan)
  PUBLIC_PORT="${PUBLIC_PORT:-8443}"
  TLS="${TLS:-1}"
  TLS_CERT="${TLS_CERT:-}"                      # pakai sertifikat sendiri (opsional)
  TLS_KEY="${TLS_KEY:-}"
  EXTRA_SAN="${EXTRA_SAN:-}"                    # contoh: "DNS:ai.example.local"
  SERVER_ADDR="${SERVER_ADDR:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

  ALLOWED_IPS="${ALLOWED_IPS:-127.0.0.1}"  # IP klien (ARTEX) yang boleh akses
  MGMT_IPS="${MGMT_IPS:-}"                            # IP admin yang boleh SSH (kosong = semua)
  SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
  SKIP_PULL="${SKIP_PULL:-0}"
  MIN_FREE_GB="${MIN_FREE_GB:-40}"
  YES="${YES:-0}"

  if [[ "$ENABLE_PROXY" == "1" ]]; then
    OLLAMA_BIND="127.0.0.1:${OLLAMA_PORT}"
    FW_PORT="$PUBLIC_PORT"
  else
    OLLAMA_BIND="0.0.0.0:${OLLAMA_PORT}"
    FW_PORT="$OLLAMA_PORT"
  fi
  if [[ "$TLS" == "1" ]]; then SCHEME="https"; else SCHEME="http"; fi
}

save_state() {
  mkdir -p "$STATE_DIR"; chmod 750 "$STATE_DIR"
  {
    echo "# Dibuat oleh ollama-prod.sh v${SCRIPT_VERSION} pada $(date -Is)"
    for v in MODEL OLLAMA_PORT CTX ENABLE_PROXY PUBLIC_PORT TLS TLS_CERT TLS_KEY \
             SERVER_ADDR ALLOWED_IPS SCHEME FW_PORT; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "State tidak ditemukan (${STATE_FILE}). Jalankan 'install' dulu."
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

# ---------- preflight ----------
free_gb() {
  local p="$1"
  while [[ ! -d "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
  df -BG --output=avail "$p" | tail -n1 | tr -dc '0-9'
}

preflight() {
  log "Preflight check..."
  command -v systemctl >/dev/null || die "systemd tidak ditemukan"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
      *ubuntu*|*debian*) ;;
      *) warn "OS ${PRETTY_NAME:-unknown} belum diuji; script ini ditargetkan untuk Ubuntu/Debian." ;;
    esac
  fi
  command -v apt-get >/dev/null || die "apt-get dibutuhkan untuk install nginx/ufw"

  local mem_gb
  mem_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
  log "RAM: ${mem_gb} GB"
  (( mem_gb >= 16 )) || warn "RAM < 16 GB; model besar akan sulit jalan."

  local models_path="${OLLAMA_MODELS_DIR:-/usr/share/ollama}"
  local free; free=$(free_gb "$models_path")
  log "Disk bebas di ${models_path}: ${free} GB"
  (( free >= MIN_FREE_GB )) || die "Disk bebas ${free} GB < MIN_FREE_GB=${MIN_FREE_GB}. Set OLLAMA_MODELS_DIR ke disk besar."

  if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
    log "GPU terdeteksi:"
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | sed 's/^/    /'
  else
    warn "GPU NVIDIA TIDAK terdeteksi -> Ollama jalan di CPU (sangat lambat untuk agent)."
    warn "VM Proxmox: pastikan PCI passthrough + driver NVIDIA terpasang."
    if [[ "$YES" != "1" ]]; then
      read -r -p "Lanjut tanpa GPU? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || die "Dibatalkan."
    fi
  fi

  [[ -n "$SERVER_ADDR" ]] || die "SERVER_ADDR tidak terdeteksi, set manual: SERVER_ADDR=10.x.x.x"
  if [[ -z "$OLLAMA_VERSION" ]]; then
    warn "OLLAMA_VERSION tidak di-pin (pakai latest). Untuk production, pin versi, mis. OLLAMA_VERSION=0.12.0"
  fi
  if [[ "$ENABLE_PROXY" != "1" ]]; then
    warn "ENABLE_PROXY=0: Ollama langsung terbuka di jaringan TANPA autentikasi & TLS."
  fi
  if [[ "$TLS" != "1" && "$ENABLE_PROXY" == "1" ]]; then
    warn "TLS=0: token API dikirim plaintext. Hanya pakai di segmen jaringan yang tepercaya."
  fi
}

# ---------- Ollama ----------
installed_ollama_version() {
  command -v ollama >/dev/null || return 0
  ollama --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

install_ollama() {
  local cur; cur="$(installed_ollama_version)"
  if [[ -n "$cur" && ( -z "$OLLAMA_VERSION" || "$cur" == "$OLLAMA_VERSION" ) ]]; then
    log "Ollama ${cur} sudah terpasang, lewati install."
    return
  fi
  log "Install Ollama ${OLLAMA_VERSION:-latest}..."
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates >/dev/null
  if [[ -n "$OLLAMA_VERSION" ]]; then
    curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION="$OLLAMA_VERSION" sh
  else
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  log "Terpasang: ollama $(installed_ollama_version)"
}

configure_ollama() {
  log "Konfigurasi service Ollama..."
  local env_lines=""
  add_env() { env_lines+="Environment=\"$1\""$'\n'; }
  add_env "OLLAMA_HOST=${OLLAMA_BIND}"
  add_env "OLLAMA_CONTEXT_LENGTH=${CTX}"
  add_env "OLLAMA_KEEP_ALIVE=${KEEP_ALIVE}"
  add_env "OLLAMA_NUM_PARALLEL=${NUM_PARALLEL}"
  add_env "OLLAMA_MAX_LOADED_MODELS=${MAX_LOADED_MODELS}"
  add_env "OLLAMA_FLASH_ATTENTION=${FLASH_ATTENTION}"
  [[ -n "$KV_CACHE_TYPE" ]] && add_env "OLLAMA_KV_CACHE_TYPE=${KV_CACHE_TYPE}"

  if [[ -n "$OLLAMA_MODELS_DIR" ]]; then
    mkdir -p "$OLLAMA_MODELS_DIR"
    chown -R ollama:ollama "$OLLAMA_MODELS_DIR"
    add_env "OLLAMA_MODELS=${OLLAMA_MODELS_DIR}"
  fi

  mkdir -p /etc/systemd/system/ollama.service.d
  cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
# Dikelola oleh ollama-prod.sh - jangan edit manual
[Service]
${env_lines}Restart=always
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true
EOF
  systemctl daemon-reload
  systemctl enable ollama >/dev/null 2>&1 || true
  systemctl restart ollama
}

wait_for_ollama() {
  log "Menunggu API Ollama..."
  local i
  for i in $(seq 1 60); do
    curl -fsS -m 3 "http://127.0.0.1:${OLLAMA_PORT}/api/version" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "Ollama tidak merespon. Cek: journalctl -u ollama -n 100 --no-pager"
}

pull_model() {
  if [[ "$SKIP_PULL" == "1" ]]; then warn "SKIP_PULL=1: model tidak diunduh."; return; fi
  log "Download model ${MODEL} (bisa lama)..."
  local n
  for n in 1 2 3; do
    if ollama pull "$MODEL"; then return 0; fi
    warn "Pull gagal (percobaan ${n}/3), ulangi dalam 10 detik..."
    sleep 10
  done
  die "Gagal download model ${MODEL}."
}

# ---------- token & TLS ----------
gen_token() {
  mkdir -p "$STATE_DIR"; chmod 750 "$STATE_DIR"
  if [[ ! -s "$TOKEN_FILE" || "${1:-}" == "force" ]]; then
    ( umask 077; openssl rand -hex 32 > "$TOKEN_FILE" )
    chmod 600 "$TOKEN_FILE"
    log "API token baru dibuat: ${TOKEN_FILE}"
  fi
}

gen_cert() {
  [[ "$TLS" == "1" ]] || return 0
  if [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]]; then
    [[ -r "$TLS_CERT" && -r "$TLS_KEY" ]] || die "TLS_CERT/TLS_KEY tidak terbaca."
    log "Pakai sertifikat TLS yang disediakan."
    return 0
  fi
  TLS_CERT="${TLS_DIR}/server.crt"; TLS_KEY="${TLS_DIR}/server.key"
  if [[ -s "$TLS_CERT" && -s "$TLS_KEY" ]]; then return 0; fi
  log "Generate sertifikat self-signed (10 tahun)..."
  mkdir -p "$TLS_DIR"; chmod 750 "$TLS_DIR"
  local san="IP:${SERVER_ADDR},IP:127.0.0.1,DNS:$(hostname -f 2>/dev/null || hostname)"
  [[ -n "$EXTRA_SAN" ]] && san="${san},${EXTRA_SAN}"
  ( umask 077
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "$TLS_KEY" -out "$TLS_CERT" \
      -subj "/CN=ollama-ai-server/O=Local AI Server" \
      -addext "subjectAltName=${san}" >/dev/null 2>&1 )
  chmod 644 "$TLS_CERT"; chmod 600 "$TLS_KEY"
}

# ---------- nginx reverse proxy ----------
render_nginx() {
  local token; token="$(cat "$TOKEN_FILE")"
  local allow_lines="    allow 127.0.0.1;"$'\n'
  local ip
  IFS=',' read -ra _ips <<< "$ALLOWED_IPS"
  for ip in "${_ips[@]}"; do
    ip="$(echo "$ip" | xargs)"
    [[ -n "$ip" ]] && allow_lines+="    allow ${ip};"$'\n'
  done
  allow_lines+="    deny all;"

  local listen_line ssl_block=""
  if [[ "$TLS" == "1" ]]; then
    listen_line="listen ${PUBLIC_PORT} ssl;"
    ssl_block="    ssl_certificate     ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:ollama_ssl:5m;"
  else
    listen_line="listen ${PUBLIC_PORT};"
  fi

  cat <<EOF
# Dikelola oleh ollama-prod.sh - jangan edit manual (berisi token, perm 600)
map \$http_authorization \$ollama_auth_ok {
    default 0;
    "Bearer ${token}" 1;
}

limit_req_zone \$binary_remote_addr zone=ollama_rl:10m rate=20r/s;

upstream ollama_backend {
    server 127.0.0.1:${OLLAMA_PORT};
    keepalive 16;
}

server {
    ${listen_line}
    server_name _;
    server_tokens off;
${ssl_block}

    # Hanya IP yang diizinkan
${allow_lines}

    client_max_body_size 50m;
    access_log /var/log/nginx/ollama-access.log;
    error_log  /var/log/nginx/ollama-error.log warn;

    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    # Hanya API OpenAI-compatible. /api/pull, /api/delete, dll TIDAK diekspos.
    location /v1/ {
        if (\$ollama_auth_ok = 0) { return 401 "unauthorized\n"; }
        limit_req zone=ollama_rl burst=40 nodelay;

        proxy_pass http://ollama_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Authorization "";

        proxy_buffering off;            # streaming token
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }

    location / { return 403 "forbidden\n"; }
}
EOF
}

setup_proxy() {
  [[ "$ENABLE_PROXY" == "1" ]] || return 0
  log "Setup nginx reverse proxy..."
  apt-get install -y -qq nginx openssl >/dev/null
  gen_token
  gen_cert
  render_nginx > "$NGINX_CONF"
  chmod 600 "$NGINX_CONF"
  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
}

# ---------- firewall ----------
setup_firewall() {
  if [[ "$SKIP_FIREWALL" == "1" ]]; then
    warn "SKIP_FIREWALL=1: firewall tidak diubah. Pastikan port ${FW_PORT} dibatasi di tempat lain."
    return 0
  fi
  log "Konfigurasi firewall (ufw)..."
  apt-get install -y -qq ufw >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  # SSH: jangan sampai terkunci
  local ssh_ports p ip
  ssh_ports="$( (sshd -T 2>/dev/null || true) | awk '$1=="port"{print $2}' | sort -u)"
  [[ -n "$ssh_ports" ]] || ssh_ports="22"
  local mgmt="$MGMT_IPS"
  if [[ -n "$mgmt" && -n "${SSH_CLIENT:-}" ]]; then
    local cur="${SSH_CLIENT%% *}"
    if [[ ",${mgmt}," != *",${cur},"* ]]; then
      warn "IP SSH Anda (${cur}) ditambahkan otomatis ke MGMT_IPS agar tidak terkunci."
      mgmt="${mgmt},${cur}"
    fi
  fi
  for p in $ssh_ports; do
    if [[ -n "$mgmt" ]]; then
      IFS=',' read -ra _m <<< "$mgmt"
      for ip in "${_m[@]}"; do
        ip="$(echo "$ip" | xargs)"; [[ -n "$ip" ]] && ufw allow from "$ip" to any port "$p" proto tcp >/dev/null
      done
    else
      ufw allow "${p}/tcp" >/dev/null
      warn "SSH port ${p} terbuka untuk semua IP. Set MGMT_IPS untuk membatasi."
    fi
  done

  IFS=',' read -ra _c <<< "$ALLOWED_IPS"
  for ip in "${_c[@]}"; do
    ip="$(echo "$ip" | xargs)"; [[ -n "$ip" ]] || continue
    ufw allow from "$ip" to any port "$FW_PORT" proto tcp >/dev/null
    log "Izinkan ${ip} -> ${FW_PORT}/tcp"
  done
  ufw --force enable >/dev/null
}

# ---------- helper: healthcheck, warmup ----------
install_helpers() {
  log "Pasang healthcheck timer dan model warm-up..."
  cat > /usr/local/bin/ollama-healthcheck <<EOF
#!/usr/bin/env bash
# Dikelola oleh ollama-prod.sh
if ! curl -fsS -m 15 http://127.0.0.1:${OLLAMA_PORT}/api/version >/dev/null 2>&1; then
  logger -t ollama-healthcheck "Ollama API tidak merespon, restart service"
  systemctl restart ollama
fi
if command -v nvidia-smi >/dev/null 2>&1 && ! timeout 20 nvidia-smi >/dev/null 2>&1; then
  logger -t ollama-healthcheck "WARNING: nvidia-smi gagal/timeout (cek driver/GPU)"
fi
EOF
  chmod 755 /usr/local/bin/ollama-healthcheck

  cat > /etc/systemd/system/ollama-healthcheck.service <<EOF
[Unit]
Description=Ollama healthcheck

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ollama-healthcheck
EOF
  cat > /etc/systemd/system/ollama-healthcheck.timer <<EOF
[Unit]
Description=Ollama healthcheck tiap 5 menit

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

  local curl_bin; curl_bin="$(command -v curl)"
  cat > /etc/systemd/system/ollama-warmup.service <<EOF
[Unit]
Description=Preload model Ollama (${MODEL}) ke memori
After=ollama.service
Requires=ollama.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${curl_bin} -fsS -m 900 --retry 30 --retry-connrefused --retry-delay 2 -X POST http://127.0.0.1:${OLLAMA_PORT}/api/generate -d '{"model":"${MODEL}","keep_alive":-1}' -o /dev/null

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ollama-healthcheck.timer >/dev/null 2>&1
  systemctl enable ollama-warmup.service >/dev/null 2>&1
  if [[ "$SKIP_PULL" != "1" ]]; then
    log "Preload model ke memori (menunggu sampai selesai)..."
    systemctl restart ollama-warmup.service || warn "Warm-up gagal (VRAM kurang?). Cek: journalctl -u ollama -n 50"
  fi
}

# ---------- tes ----------
curl_api() {  # curl ke endpoint publik dengan trust ke cert kita
  local path="$1"; shift
  local extra=()
  [[ "$TLS" == "1" && -n "${TLS_CERT:-}" ]] && extra=(--cacert "$TLS_CERT")
  curl -sS -m 300 "${extra[@]}" "${SCHEME}://127.0.0.1:${FW_PORT}${path}" "$@"
}

smoke_test() {
  log "Smoke test..."
  if [[ "$ENABLE_PROXY" != "1" ]]; then
    curl -fsS "http://127.0.0.1:${OLLAMA_PORT}/v1/models" >/dev/null && log "OK: /v1/models" || warn "/v1/models gagal"
    return
  fi
  local token code; token="$(cat "$TOKEN_FILE")"

  code=$(curl_api /v1/models -o /dev/null -w '%{http_code}') || true
  [[ "$code" == "401" ]] && log "OK: tanpa token -> 401" || warn "Tanpa token seharusnya 401, dapat: ${code}"

  code=$(curl_api /v1/models -H "Authorization: Bearer ${token}" -o /dev/null -w '%{http_code}') || true
  [[ "$code" == "200" ]] && log "OK: dengan token -> 200" || warn "Dengan token seharusnya 200, dapat: ${code}"

  code=$(curl_api /api/tags -H "Authorization: Bearer ${token}" -o /dev/null -w '%{http_code}') || true
  [[ "$code" == "403" ]] && log "OK: /api/* (admin) diblokir -> 403" || warn "/api/tags seharusnya 403, dapat: ${code}"

  if [[ "$SKIP_PULL" != "1" ]]; then
    local out
    out=$(curl_api /v1/chat/completions -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
      -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Balas satu kata: siap\"}],\"max_tokens\":64}" \
      -w '\nHTTP %{http_code} dalam %{time_total}s' ) || true
    log "Tes chat completion: $(printf '%s' "$out" | tail -n1)"
  fi
}

show_token() {
  if [[ -w /dev/tty ]]; then
    { echo; echo "  API token: $(cat "$TOKEN_FILE")"; echo "  (tidak ditulis ke log; file: ${TOKEN_FILE})"; } > /dev/tty
  else
    echo "  API token ada di: ${TOKEN_FILE} (sudo cat ${TOKEN_FILE})"
  fi
}

summary() {
  cat <<EOF

================================================================
 SELESAI - Ollama production siap  (script v${SCRIPT_VERSION})
================================================================
 Setting di ARTEX (LLM Configuration):
EOF
  if [[ "$ENABLE_PROXY" == "1" ]]; then
    cat <<EOF
   Format   : OpenAI   (BUKAN format Ollama, karena butuh API key)
   Base URL : ${SCHEME}://${SERVER_ADDR}:${PUBLIC_PORT}/v1
   API key  : (token di bawah)
   Model    : ${MODEL}   -> klik refresh model list
EOF
    if [[ "$TLS" == "1" && "$TLS_CERT" == "${TLS_DIR}/server.crt" ]]; then
      cat <<EOF

 Sertifikat self-signed: ARTEX harus mempercayainya.
   scp root@${SERVER_ADDR}:${TLS_CERT} ./ollama-ca.crt
   - Jika ARTEX jalan native: copy ke /usr/local/share/ca-certificates/ lalu
     sudo update-ca-certificates
   - Jika ARTEX jalan di Docker: CA host TIDAK dipakai container. Mount file
     ke container dan set SSL_CERT_FILE, atau pakai sertifikat dari CA internal
     (TLS_CERT/TLS_KEY), atau TLS=0 di segmen jaringan tepercaya.
EOF
    fi
  else
    cat <<EOF
   Format   : Ollama
   Base URL : http://${SERVER_ADDR}:${OLLAMA_PORT}/v1
   (TANPA autentikasi - hanya dilindungi firewall)
EOF
  fi
  cat <<EOF

 Operasional:
   sudo $0 status          # cek kondisi
   sudo $0 rotate-token    # ganti token API
   journalctl -u ollama -f # log Ollama
   tail -f /var/log/nginx/ollama-access.log
   ollama ps               # model yang sedang di memori
 Log install: ${INSTALL_LOG}
================================================================
EOF
}

# ---------- perintah ----------
cmd_install() {
  require_root
  load_config
  mkdir -p "$(dirname "$INSTALL_LOG")"
  exec > >(tee -a "$INSTALL_LOG") 2>&1
  log "ollama-prod.sh v${SCRIPT_VERSION} - $(date -Is)"
  preflight
  save_state
  install_ollama
  configure_ollama
  wait_for_ollama
  setup_proxy
  save_state   # simpan ulang karena TLS_CERT/TLS_KEY bisa terisi otomatis
  setup_firewall
  pull_model
  install_helpers
  smoke_test
  summary
  [[ "$ENABLE_PROXY" == "1" ]] && show_token
  return 0
}

cmd_status() {
  require_root
  load_state
  echo "== Layanan =="
  for s in ollama nginx ollama-warmup ollama-healthcheck.timer; do
    printf '  %-26s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"
  done
  echo "== Versi =="; echo "  ollama $(installed_ollama_version)"
  echo "== Model di memori =="; ollama ps 2>/dev/null | sed 's/^/  /' || true
  echo "== Model terpasang =="; ollama list 2>/dev/null | sed 's/^/  /' || true
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "== GPU =="
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu \
      --format=csv,noheader 2>/dev/null | sed 's/^/  /' || true
  fi
  echo "== Port listen =="; ss -ltnp 2>/dev/null | grep -E ":(${OLLAMA_PORT}|${FW_PORT})\b" | sed 's/^/  /' || true
  echo "== Firewall =="; ufw status 2>/dev/null | sed 's/^/  /' || true
  if [[ "$ENABLE_PROXY" == "1" ]]; then
    local code; code=$(TLS_CERT="${TLS_CERT:-}" curl_api /healthz -o /dev/null -w '%{http_code}' 2>/dev/null || true)
    echo "== Proxy healthz =="; echo "  HTTP ${code:-gagal}"
  fi
}

cmd_rotate() {
  require_root
  load_state
  [[ "$ENABLE_PROXY" == "1" ]] || die "Proxy tidak aktif, tidak ada token."
  gen_token force
  render_nginx > "$NGINX_CONF"; chmod 600 "$NGINX_CONF"
  nginx -t && systemctl reload nginx
  log "Token diganti. Update API key di ARTEX!"
  show_token
}

cmd_uninstall() {
  require_root
  if [[ "${YES:-0}" != "1" ]]; then
    read -r -p "Hapus konfigurasi ollama-prod (proxy, timer, override)? Model & paket Ollama TIDAK dihapus. [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || die "Dibatalkan."
  fi
  systemctl disable --now ollama-healthcheck.timer ollama-warmup.service 2>/dev/null || true
  rm -f /etc/systemd/system/ollama-healthcheck.{service,timer} /etc/systemd/system/ollama-warmup.service \
        /usr/local/bin/ollama-healthcheck /etc/systemd/system/ollama.service.d/override.conf "$NGINX_CONF"
  systemctl daemon-reload
  systemctl restart ollama 2>/dev/null || true
  if command -v nginx >/dev/null; then nginx -t 2>/dev/null && systemctl reload nginx || true; fi
  log "Selesai. State ${STATE_DIR} dan aturan ufw dibiarkan; hapus manual bila perlu."
}

main() {
  case "${1:-install}" in
    install)       cmd_install ;;
    status)        cmd_status ;;
    rotate-token)  cmd_rotate ;;
    uninstall)     cmd_uninstall ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
