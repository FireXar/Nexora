# ==========================================================
# Dominio del VPS: validación, DNS y almacenamiento
# ==========================================================

domain_get() {
    [[ -s "$DOMAIN_FILE" ]] || return 0
    head -n 1 "$DOMAIN_FILE" | tr -d '\r\n'
}

domain_normalize() {
    local d="${1,,}"
    d="${d#http://}"; d="${d#https://}"
    d="${d%%/*}"; d="${d%%:*}"
    d="${d%.}"
    printf '%s' "$d"
}

domain_valid() {
    local d="$1" label
    [[ ${#d} -le 253 && "$d" == *.* ]] || return 1
    [[ "$d" =~ ^[a-z0-9.-]+$ ]] || return 1
    [[ "$d" != .* && "$d" != *..* && "$d" != *.-* && "$d" != *-. ]] || return 1
    IFS='.' read -ra _labels <<< "$d"
    for label in "${_labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}

domain_public_ip() {
    local ip
    ip=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    [[ -n "$ip" ]] || ip=$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')
    [[ -n "$ip" ]] || { declare -F get_ip >/dev/null 2>&1 && get_ip; }
}

# Devuelve éxito solo si al menos un registro A coincide con la IPv4 pública.
domain_check() {
    local domain="$1" server_ip resolved
    server_ip=$(domain_public_ip)
    [[ -n "$server_ip" ]] || { echo "No pude detectar la IP pública del VPS."; return 2; }
    resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    [[ -n "$resolved" ]] || { echo "El dominio todavía no resuelve registros IPv4 (A)."; return 1; }
    if grep -Fxq "$server_ip" <<< "$resolved"; then
        echo "Dominio: $domain"
        echo "IP del VPS: $server_ip"
        echo "IP(s) DNS: $(tr '\n' ' ' <<< "$resolved")"
        return 0
    fi
    echo "La IP del dominio no coincide con la IP pública del VPS."
    echo "IP del VPS: $server_ip"
    echo "IP(s) DNS: $(tr '\n' ' ' <<< "$resolved")"
    return 1
}

domain_save() {
    local domain="$1"
    mkdir -p "$DB_DIR"
    printf '%s\n' "$domain" > "$DOMAIN_FILE"
    chmod 600 "$DOMAIN_FILE"
}

domain_configure_prompt() {
    local entered domain current
    current=$(domain_get)
    echo
    [[ -n "$current" ]] && echo "Dominio actual: $current"
    read -r -p "Escribe el dominio (ej. vpn.midominio.com): " entered
    domain=$(domain_normalize "$entered")
    if [[ -z "$domain" ]]; then
        echo "No se realizaron cambios."
        return 1
    fi
    if ! domain_valid "$domain"; then
        echo "Formato de dominio inválido. Ejemplo: vpn.midominio.com"
        return 1
    fi
    echo
    if domain_check "$domain"; then
        domain_save "$domain"
        echo "Dominio guardado correctamente."
        return 0
    fi
    echo
    echo "No se guardó el dominio. Corrige los registros DNS y vuelve a intentarlo."
    echo "Debe existir un registro A que apunte a la IP pública de este VPS."
    return 1
}

domain_remove() {
    rm -f "$DOMAIN_FILE"
}
