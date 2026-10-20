#!/bin/bash
# Instalador. Uso:  bash install.sh   (como root, desde la carpeta del proyecto)
set -e

[[ $EUID -ne 0 ]] && { echo "Ejecuta como root (sudo -i)."; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SRC/core/config.sh"

. /etc/os-release
case "$ID" in
    ubuntu|debian) ;;
    *) echo "Solo Debian/Ubuntu. Detectado: $ID"; exit 1;;
esac

echo ">> Instalando dependencias..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git unzip net-tools iproute2 procps cron openssl python3 figlet ca-certificates cmake build-essential

echo ">> Copiando $APP_NAME a $APP_DIR ..."
mkdir -p "$APP_DIR/core" "$APP_DIR/modules" "$DB_DIR"
cp -f "$SRC"/core/*.sh "$APP_DIR/core/"
cp -f "$SRC"/modules/* "$APP_DIR/modules/"
chmod +x "$APP_DIR"/core/*.sh "$APP_DIR"/modules/*
touch "$USERS_DB"

grep -qx "/bin/false" /etc/shells || echo "/bin/false" >> /etc/shells
ln -sf "$APP_DIR/core/menu.sh" "$BIN_LINK"

# Limpieza diaria de usuarios expirados
echo "0 0 * * * root $BIN_LINK --clean >/dev/null 2>&1" > "/etc/cron.d/${APP_ID}"

echo
echo "✔ $APP_NAME instalado. Escribe:  $APP_ID"
