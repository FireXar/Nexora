# ==========================================================
#  Módulo BHTTP (relé para DTunnel)
#
#  - El código fuente se descarga solo desde el repositorio de su autor y se
#    compara con la huella del código que revisamos. Si cambió, te avisa.
#  - Se COMPILA en tu servidor con Go oficial (huella verificada) y el
#    resultado corre como usuario sin privilegios.
#  - Nexora no incluye ese código en tu repositorio.
#  - Si ya tenés la carpeta bilola_go_port en /root, usa esa en vez de descargar.
# ==========================================================
BH_SVC="${APP_ID}-bhttp"
BH_UNIT="/etc/systemd/system/${BH_SVC}.service"
BH_DIR="${APP_DIR}/bhttp"
BH_SRC="${BH_DIR}/src"
BH_BIN="${BH_DIR}/bilola-server"
BH_GO="${BH_DIR}/go"
BH_CONF="${DB_DIR}/bhttp.conf"
BH_STAGE_DEFAULT="/root/bilola_go_port"
BH_ZIP_URL="https://github.com/karl1999x/PandaScript/raw/refs/heads/main/SCRIPTS/btun-full-install.zip"
BH_PINNED_FP="d2cf5ac6901e28469edc9fcfc2aec3bafe3f14bf16d93e4055b3fb8c05dfd4ad"   # código revisado (v1.0.44)
BH_FETCH_DIR=""; BH_FETCH_TMP=""

bh_installed()  { [[ -x "$BH_BIN" ]]; }
bh_conf_get()   { grep -E "^$1=" "$BH_CONF" 2>/dev/null | cut -d= -f2-; }
bh_go_arch()    { case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) echo "";; esac; }
bh_ssh_port()   {
    local p; p=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    echo "${p:-22}"
}
bh_listen_arg() { local p out=""; for p in $1; do out+="0.0.0.0:$p,"; done; echo "${out%,}"; }

# Revisión rápida del código que se va a compilar (solo lo que entra al programa)
bh_audit() {
    local dir="$1" bad=0 hits d
    local targets=()
    for d in cmd/bilola-server internal/bhttp internal/xhttp; do
        [[ -d "$dir/$d" ]] && targets+=("$dir/$d")
    done
    (( ${#targets[@]} > 0 )) || { err "No encuentro las carpetas del programa"; return 1; }

    hits=$(grep -rlE 'os/exec|exec\.Command|syscall\.Exec' --include='*.go' "${targets[@]}" 2>/dev/null | grep -v '_test\.go')
    if [[ -n "$hits" ]]; then warn "El código ejecuta comandos del sistema en:"; echo "$hits" | sed 's/^/      /'; bad=1; fi

    hits=$(grep -rnoE 'https?://[A-Za-z0-9._/:?=&%-]+' --include='*.go' "${targets[@]}" 2>/dev/null | grep -v '_test\.go')
    if [[ -n "$hits" ]]; then warn "El código contiene direcciones web:"; echo "$hits" | head -5 | sed 's/^/      /'; bad=1; fi

    (( bad == 0 )) && ok "Revisión rápida: sin ejecución de comandos ni direcciones web"
    return $bad
}

# Huella del código que se compila (para anotarla y comparar en el futuro)
bh_fingerprint() {
    ( cd "$1" && find go.mod cmd/bilola-server internal/bhttp internal/xhttp -type f 2>/dev/null \
        | LC_ALL=C sort | xargs sha256sum | sha256sum | awk '{print $1}' )
}

# Descarga el paquete y deja el código en $BH_FETCH_DIR
bh_fetch_source() {
    local tmp
    apt-get install -y curl unzip >/dev/null 2>&1
    tmp=$(mktemp -d)
    echo " Descargando el paquete (unos 17 MB)..."
    curl -fsSL --max-time 300 -o "$tmp/pkg.zip" "$BH_ZIP_URL" \
        || { err "No pude descargar el paquete"; rm -rf "$tmp"; return 1; }
    unzip -q -o "$tmp/pkg.zip" 'BTUN/sources/bilola_go_port/*' -d "$tmp/x" 2>/dev/null
    if [[ ! -f "$tmp/x/BTUN/sources/bilola_go_port/go.mod" ]]; then
        err "El paquete no trae el código esperado"; rm -rf "$tmp"; return 1
    fi
    BH_FETCH_DIR="$tmp/x/BTUN/sources/bilola_go_port"; BH_FETCH_TMP="$tmp"
}

# Elige el Go a descargar desde el JSON oficial:  bh_go_pick <json> <arch> → "archivo sha256"
bh_go_pick() {
    python3 - "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for rel in data:
    if not rel.get("stable"):
        continue
    for f in rel.get("files", []):
        if f.get("os") == "linux" and f.get("arch") == sys.argv[2] and f.get("kind") == "archive":
            print(f["filename"], f["sha256"])
            sys.exit(0)
sys.exit(1)
PY
}

bh_get_go() {
    local arch tmp pick file want have
    arch=$(bh_go_arch)
    [[ -z "$arch" ]] && { err "Arquitectura no soportada: $(uname -m)"; return 1; }
    apt-get install -y curl python3 >/dev/null 2>&1
    tmp=$(mktemp -d)
    echo " Consultando la versión oficial de Go..."
    curl -fsSL --max-time 20 "https://go.dev/dl/?mode=json" -o "$tmp/go.json" \
        || { err "No pude consultar go.dev"; rm -rf "$tmp"; return 1; }
    pick=$(bh_go_pick "$tmp/go.json" "$arch") \
        || { err "No encontré una versión de Go para $arch"; rm -rf "$tmp"; return 1; }
    file=${pick%% *}; want=${pick##* }
    echo " Descargando $file (unos 70 MB)..."
    curl -fsSL --max-time 900 -o "$tmp/go.tgz" "https://go.dev/dl/$file" \
        || { err "Falló la descarga de Go"; rm -rf "$tmp"; return 1; }
    have=$(sha256sum "$tmp/go.tgz" | awk '{print $1}')
    if [[ "$have" != "$want" ]]; then
        err "La huella de Go no coincide con la oficial; se cancela"; rm -rf "$tmp"; return 1
    fi
    ok "Huella SHA-256 de Go verificada"
    mkdir -p "$BH_DIR"; rm -rf "$BH_GO"
    tar -xzf "$tmp/go.tgz" -C "$tmp" && mv "$tmp/go" "$BH_GO"
    rm -rf "$tmp"
}

# Ejecuta Go dentro del código, aislado (sin red, sin descargas de módulos)
bh_go() {   # bh_go <carpeta_temporal> <argumentos de go...>
    local t="$1"; shift
    ( cd "$BH_SRC" && HOME="$t" GOCACHE="$t/cache" GOPATH="$t/gopath" \
        GOTOOLCHAIN=local GOPROXY=off CGO_ENABLED=0 "$BH_GO/bin/go" "$@" )
}

bh_selftest() {
    local t; t=$(mktemp -d)
    echo " Corriendo las pruebas del código..."
    if timeout 300 bash -c "$(declare -f bh_go); BH_SRC='$BH_SRC' BH_GO='$BH_GO'; bh_go '$t' test ./internal/bhttp/ >/dev/null 2>&1"; then
        ok "Las pruebas del código pasaron"; rm -rf "$t"; return 0
    fi
    rm -rf "$t"; return 1
}

bh_build() {
    local t out; t=$(mktemp -d); out="$t/bilola-server"
    echo " Compilando (puede tardar uno o dos minutos)..."
    if ! bh_go "$t" build -trimpath -o "$out" ./cmd/bilola-server; then
        err "Falló la compilación"; rm -rf "$t"; return 1
    fi
    install -m 755 -o root -g root "$out" "$BH_BIN"
    rm -rf "$t"; ok "Programa compilado"
}

bh_write_unit() {   # bh_write_unit <puertos> <puerto_ssh>
    cat > "$BH_UNIT" <<EOF
[Unit]
Description=${APP_NAME} BHTTP (relé a SSH)
After=network.target ssh.service

[Service]
User=nobody
Group=nogroup
ExecStart=${BH_BIN} --listen $(bh_listen_arg "$1") --target 127.0.0.1:$2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

# Escribe el servicio, lo inicia y guarda la configuración (sin preguntar nada)
bh_apply() {   # bh_apply <puertos> <puerto_ssh>
    local p
    bh_write_unit "$1" "$2"
    printf 'ports=%s\nssh=%s\n' "$1" "$2" > "$BH_CONF"
    systemctl daemon-reload
    systemctl enable "$BH_SVC" >/dev/null 2>&1
    systemctl restart "$BH_SVC"
    for p in $1; do open_port "$p"; done
    if svc_on "$BH_SVC"; then ok "BHTTP activo en: $1  →  SSH 127.0.0.1:$2"
    else err "No pudo iniciar. Revisá: journalctl -u $BH_SVC -n 20"; fi
}

# Pregunta puertos y destino; devuelve los valores en BH_ASK_PORTS / BH_ASK_SSH
bh_ask() {
    local ports ssh p c
    ssh=$(bh_conf_get ssh); ssh=${ssh:-$(bh_ssh_port)}
    ports=$(bh_conf_get ports); ports=${ports:-8080}
    read -rp " Puertos de BHTTP, separados por espacio [$ports]: " c; ports=${c:-$ports}
    for p in $ports; do
        if ! { is_num "$p" && (( p >= 1 && p <= 65535 )); }; then err "Puerto inválido: $p"; return 1; fi
        if port_busy "$p" bilola; then err "El puerto $p ya está en uso"; return 1; fi
    done
    read -rp " ¿A qué puerto SSH se redirige el tráfico? [$ssh]: " c; ssh=${c:-$ssh}
    if ! { is_num "$ssh" && (( ssh >= 1 && ssh <= 65535 )); }; then err "Puerto SSH inválido"; return 1; fi
    BH_ASK_PORTS="$ports"; BH_ASK_SSH="$ssh"
}

bh_configure() {   # cambiar puertos o destino
    bh_ask || { pause; return 1; }
    bh_apply "$BH_ASK_PORTS" "$BH_ASK_SSH"; pause
}

bhttp_install() {
    header "BHTTP · INSTALAR"
    local stage c fp fetched=0
    if bh_installed; then
        read -rp " Ya está compilado. ¿Recompilar desde el código? [s/N]: " c
        if [[ ! "$c" =~ ^[sS]$ ]]; then bh_configure; return; fi
    fi

    bh_ask || { pause; return; }
    echo

    if [[ -d "$BH_STAGE_DEFAULT" ]]; then
        stage="$BH_STAGE_DEFAULT"; echo " Usando el código local: $stage"
    else
        bh_fetch_source || { pause; return; }
        stage="$BH_FETCH_DIR"; fetched=1
    fi
    if [[ ! -f "$stage/go.mod" || ! -d "$stage/cmd/bilola-server" ]]; then
        err "No encuentro go.mod y cmd/bilola-server en $stage"
        [[ $fetched -eq 1 ]] && rm -rf "$BH_FETCH_TMP"; pause; return
    fi

    if ! bh_audit "$stage"; then
        read -rp " ¿Continuar igual? [s/N]: " c
        [[ "$c" =~ ^[sS]$ ]] || { warn "Cancelado"; [[ $fetched -eq 1 ]] && rm -rf "$BH_FETCH_TMP"; pause; return; }
    fi
    fp=$(bh_fingerprint "$stage")
    if [[ "$fp" == "$BH_PINNED_FP" ]]; then
        ok "El código es idéntico al que revisamos"
    else
        warn "El código CAMBIÓ respecto de la versión que revisamos."
        echo -e " Obtenida : ${Y}${fp}${W}"
        echo -e " Revisada : ${Y}${BH_PINNED_FP}${W}"
        read -rp " ¿Compilar igual? [s/N]: " c
        [[ "$c" =~ ^[sS]$ ]] || { warn "Cancelado"; [[ $fetched -eq 1 ]] && rm -rf "$BH_FETCH_TMP"; pause; return; }
    fi

    mkdir -p "$BH_DIR"; rm -rf "$BH_SRC"; mkdir -p "$BH_SRC"
    cp -r "$stage"/. "$BH_SRC"/
    [[ $fetched -eq 1 ]] && rm -rf "$BH_FETCH_TMP"
    chown -R root:root "$BH_DIR"; chmod 755 "$BH_DIR"

    bh_get_go || { rm -rf "$BH_SRC"; pause; return; }
    if ! bh_selftest; then
        warn "Las pruebas del código no pasaron."
        read -rp " ¿Compilar igual? [s/N]: " c
        [[ "$c" =~ ^[sS]$ ]] || { rm -rf "$BH_GO" "$BH_SRC"; warn "Cancelado"; pause; return; }
    fi
    bh_build || { rm -rf "$BH_GO"; pause; return; }
    rm -rf "$BH_GO"; ok "Go se eliminó (ya no hace falta para correr el programa)"
    echo "$fp" > "$BH_DIR/source.sha256"
    echo
    bh_apply "$BH_ASK_PORTS" "$BH_ASK_SSH"
    pause
}

bhttp_logs() {
    header "BHTTP · REGISTROS"
    journalctl -u "$BH_SVC" -n 40 --no-pager 2>/dev/null || warn "No hay registros todavía"
    pause
}

bhttp_uninstall() {
    header "BHTTP · DESINSTALAR"; confirm_si || return
    systemctl disable --now "$BH_SVC" 2>/dev/null
    rm -f "$BH_UNIT"; rm -rf "$BH_DIR" "$BH_CONF"
    systemctl daemon-reload; ok "BHTTP desinstalado"; pause
}

bhttp_menu() {
    local o st
    while true; do
        header "BHTTP · RELÉ PARA DTUNNEL"
        if svc_on "$BH_SVC"; then st="${G}● ACTIVO${W}  ${DIM}puertos $(bh_conf_get ports)${W}"
        elif bh_installed; then st="${R}● DETENIDO${W}"
        else st="${Y}no instalado${W}"; fi
        echo -e " Estado: $st"; thin
        item 1 "Instalar / recompilar"
        item 2 "Cambiar puertos o destino SSH"
        item 3 "Iniciar o detener"
        item 4 "Ver registros"
        item 5 "Desinstalar"
        item 0 "Volver"; line
        echo -ne " ${Y}❯${W} Opción: "; read -r o
        case $o in
            1) bhttp_install;;
            2) if bh_installed; then header "BHTTP · CONFIGURAR"; bh_configure; else err "Instalá BHTTP primero"; sleep 1; fi;;
            3) if bh_installed; then svc_toggle "$BH_SVC"; else err "Instalá BHTTP primero"; sleep 1; fi;;
            4) bhttp_logs;;
            5) bhttp_uninstall;;
            0) return;;
        esac
    done
}
