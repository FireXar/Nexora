# ==========================================================
#  Módulo Xray (VLESS sobre WebSocket)
#  Se instala desde el repositorio oficial XTLS/Xray-core y se
#  verifica el SHA-256 contra el .dgst publicado en la release.
# ==========================================================
XRAY_BIN="/usr/local/bin/xray"
XRAY_ASSETS="/usr/local/share/xray"
XRAY_CFG_DIR="${APP_DIR}/xray"
XRAY_CFG="${XRAY_CFG_DIR}/config.json"
XRAY_SVC="${APP_ID}-xray"
XRAY_PY="${MOD_DIR}/xray-cfg.py"

xray_installed() { [[ -x "$XRAY_BIN" && -f "$XRAY_CFG" ]]; }
xray_restart()   { systemctl restart "$XRAY_SVC" 2>/dev/null; }

xray_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "64";;
        aarch64|arm64) echo "arm64-v8a";;
        *) echo "";;
    esac
}

xray_link() {   # xray_link <uuid> <nombre>
    local port path enc
    read -r port path < <(python3 "$XRAY_PY" info "$XRAY_CFG")
    enc="${path//\//%2F}"
    echo "vless://$1@$(get_ip):${port}?encryption=none&security=none&type=ws&path=${enc}#$2"
}

xray_install() {
    header "INSTALAR XRAY (VLESS + WebSocket)"
    local arch p w tag tmp base want have c
    arch=$(xray_arch)
    [[ -z "$arch" ]] && { err "Arquitectura no soportada: $(uname -m)"; pause; return; }

    read -rp " Puerto público [8080]: " p; p=${p:-8080}
    read -rp " Path WebSocket [/ws]: " w; w=${w:-/ws}
    is_num "$p" || { err "Puerto inválido"; pause; return; }
    [[ "$w" == /* ]] || w="/$w"
    if ss -tln | awk '{print $4}' | grep -q ":$p\$"; then
        err "El puerto $p ya está en uso"; pause; return
    fi

    apt-get install -y curl unzip python3 >/dev/null 2>&1

    echo " Consultando la última versión..."
    tag=$(curl -fsSL --max-time 15 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
          | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null)
    [[ -z "$tag" ]] && { err "No pude consultar GitHub (¿sin internet?)"; pause; return; }
    ok "Versión: $tag"

    tmp=$(mktemp -d)
    base="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch}.zip"
    curl -fsSL --max-time 180 -o "$tmp/xray.zip" "$base" \
        || { err "Falló la descarga"; rm -rf "$tmp"; pause; return; }
    curl -fsSL --max-time 30 -o "$tmp/xray.dgst" "${base}.dgst" 2>/dev/null

    want=$(grep -iE 'SHA2?-?256' "$tmp/xray.dgst" 2>/dev/null | head -1 | awk '{print $NF}')
    have=$(sha256sum "$tmp/xray.zip" | awk '{print $1}')
    if [[ -n "$want" && "$want" == "$have" ]]; then
        ok "Checksum SHA-256 verificado"
    else
        warn "No se pudo verificar el checksum (esperado: ${want:-n/d})."
        read -rp " ¿Continuar igual? [s/N]: " c
        [[ "$c" =~ ^[sS]$ ]] || { rm -rf "$tmp"; return; }
    fi

    unzip -qo "$tmp/xray.zip" -d "$tmp/x"
    install -m 755 "$tmp/x/xray" "$XRAY_BIN"
    mkdir -p "$XRAY_ASSETS" "$XRAY_CFG_DIR"
    cp -f "$tmp"/x/geo*.dat "$XRAY_ASSETS/" 2>/dev/null
    rm -rf "$tmp"

    python3 "$XRAY_PY" init "$XRAY_CFG" "$p" "$w"
    chown root:nogroup "$XRAY_CFG_DIR" "$XRAY_CFG"
    chmod 750 "$XRAY_CFG_DIR"; chmod 640 "$XRAY_CFG"

    if ! XRAY_LOCATION_ASSET="$XRAY_ASSETS" "$XRAY_BIN" run -test -config "$XRAY_CFG" >/dev/null 2>&1; then
        err "La configuración generada no pasó la validación de Xray"; pause; return
    fi

    cat > "/etc/systemd/system/${XRAY_SVC}.service" <<EOF
[Unit]
Description=${APP_NAME} Xray
After=network.target

[Service]
User=nobody
Group=nogroup
Environment=XRAY_LOCATION_ASSET=${XRAY_ASSETS}
ExecStart=${XRAY_BIN} run -config ${XRAY_CFG}
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$XRAY_SVC" >/dev/null 2>&1
    open_port "$p"
    touch "$XRAY_DB"
    if systemctl is-active --quiet "$XRAY_SVC"; then
        ok "Xray activo en el puerto $p (path $w)"
    else
        err "No pudo iniciar. Revisa: journalctl -u $XRAY_SVC -n 20"
    fi
    pause
}

xray_add() {
    header "XRAY · CREAR CLIENTE"
    xray_installed || { err "Instala Xray primero"; pause; return; }
    local n d uuid exp
    read -rp " Nombre (a-z, 0-9, _ -): " n
    [[ "$n" =~ ^[A-Za-z0-9_-]{2,20}$ ]] || { err "Nombre inválido"; pause; return; }
    grep -q "^$n|" "$XRAY_DB" && { err "Ya existe"; pause; return; }
    read -rp " Días de duración: " d
    is_num "$d" || { err "Número inválido"; pause; return; }

    uuid=$(cat /proc/sys/kernel/random/uuid)
    exp=$(date -d "+$d days" +%F)
    python3 "$XRAY_PY" add "$XRAY_CFG" "$uuid" "$n" || { err "No se pudo agregar"; pause; return; }
    echo "$n|$uuid|$exp|$(date +%F)" >> "$XRAY_DB"
    xray_restart

    header "CLIENTE CREADO"
    echo -e " Nombre : ${G}$n${W}"
    echo -e " UUID   : ${G}$uuid${W}"
    echo -e " Expira : ${G}$exp${W}"
    echo; echo -e " ${Y}Enlace:${W}"; xray_link "$uuid" "$n"
    pause
}

xray_remove() {
    header "XRAY · ELIMINAR CLIENTE"
    xray_installed || { err "Instala Xray primero"; pause; return; }
    local n; read -rp " Nombre: " n
    grep -q "^$n|" "$XRAY_DB" || { err "No existe"; pause; return; }
    python3 "$XRAY_PY" remove "$XRAY_CFG" "$n"
    grep -v "^$n|" "$XRAY_DB" > "$XRAY_DB.tmp"; mv "$XRAY_DB.tmp" "$XRAY_DB"
    xray_restart; ok "Eliminado: $n"; pause
}

xray_list() {
    header "XRAY · CLIENTES"
    xray_installed || { err "Instala Xray primero"; pause; return; }
    local hoy col n u e c; hoy=$(date +%F)
    printf " ${Y}%-16s %-12s %s${W}\n" NOMBRE EXPIRA UUID
    while IFS='|' read -r n u e c; do
        [[ -z "$n" ]] && continue
        col=$G; [[ "$e" < "$hoy" ]] && col=$R
        printf " ${col}%-16s %-12s %s${W}\n" "$n" "$e" "$u"
    done < "$XRAY_DB"
    pause
}

xray_link_menu() {
    header "XRAY · VER ENLACE"
    xray_installed || { err "Instala Xray primero"; pause; return; }
    local n u; read -rp " Nombre: " n
    u=$(awk -F'|' -v n="$n" '$1==n{print $2}' "$XRAY_DB")
    [[ -z "$u" ]] && { err "No existe"; pause; return; }
    echo; xray_link "$u" "$n"; pause
}

xray_cleanup() {   # silencioso; lo llama el cron con --clean
    xray_installed || return 0
    local hoy changed=0 n u e c; hoy=$(date +%F)
    [[ -f "$XRAY_DB" ]] || return 0
    while IFS='|' read -r n u e c; do
        [[ -z "$n" ]] && continue
        if [[ "$e" < "$hoy" ]]; then
            python3 "$XRAY_PY" remove "$XRAY_CFG" "$n"
            grep -v "^$n|" "$XRAY_DB" > "$XRAY_DB.tmp"; mv "$XRAY_DB.tmp" "$XRAY_DB"
            echo "xray expirado eliminado: $n"; changed=1
        fi
    done < <(cat "$XRAY_DB")
    [[ $changed -eq 1 ]] && xray_restart
    return 0
}

xray_uninstall() {
    header "DESINSTALAR XRAY"
    read -rp " Escribe SI para confirmar: " c
    [[ "$c" == "SI" ]] || return
    systemctl disable --now "$XRAY_SVC" 2>/dev/null
    rm -f "/etc/systemd/system/${XRAY_SVC}.service" "$XRAY_BIN"
    rm -rf "$XRAY_CFG_DIR" "$XRAY_ASSETS" "$XRAY_DB"
    systemctl daemon-reload; ok "Xray desinstalado"; pause
}

menu_xray() {
    local o st
    while true; do
        header "XRAY · VLESS + WebSocket"
        if xray_installed && systemctl is-active --quiet "$XRAY_SVC"; then st="${G}● activo${W}"
        elif xray_installed; then st="${R}● detenido${W}"
        else st="${Y}no instalado${W}"; fi
        echo -e " Estado: $st"; line
        echo -e " ${G}1)${W} Instalar Xray"
        echo -e " ${G}2)${W} Crear cliente"
        echo -e " ${G}3)${W} Eliminar cliente"
        echo -e " ${G}4)${W} Listar clientes"
        echo -e " ${G}5)${W} Ver enlace de un cliente"
        echo -e " ${G}6)${W} Desinstalar Xray"
        echo -e " ${G}0)${W} Volver"; line
        read -rp " Opción: " o
        case $o in
            1) xray_install;; 2) xray_add;; 3) xray_remove;;
            4) xray_list;; 5) xray_link_menu;; 6) xray_uninstall;;
            0) return;;
        esac
    done
}
