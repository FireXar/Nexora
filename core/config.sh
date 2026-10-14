# ==========================================================
#  CONFIGURACIÓN Y MARCA
# ==========================================================
APP_NAME="Nexora"
APP_ID="nexora"
APP_VER="1.1.0"
APP_AUTHOR="FireXar"

# Repo desde donde se actualiza (opción "Actualizar" del menú Sistema)
APP_REPO="https://github.com/FireXar/Nexora.git"

APP_DIR="/etc/${APP_ID}"
DB_DIR="${APP_DIR}/db"
USERS_DB="${DB_DIR}/users.db"      # usuario|expira|limite|creado
XRAY_DB="${DB_DIR}/xray.db"        # nombre|uuid|expira|creado
MOD_DIR="${APP_DIR}/modules"
SRC_DIR="/opt/${APP_ID}-src"       # copia del repo usada para actualizar
BIN_LINK="/usr/local/bin/${APP_ID}"
