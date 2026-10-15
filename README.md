# Nexora

Panel en Bash para administrar usuarios SSH (vencimiento y límite de
conexiones), túneles y Xray en un VPS Debian/Ubuntu.

## Instalar

```bash
git clone https://github.com/FireXar/Nexora.git
cd Nexora
bash install.sh
nexora
```

## Qué incluye

| Menú | Función |
|---|---|
| Usuarios SSH | Crear, eliminar, renovar, límite, bloquear, listar, conectados, limpiar expirados |
| Servicios | Dropbear, Stunnel (SSL), proxy WebSocket → SSH, puerto SSH, banner, estado |
| Xray (VLESS) | Instala Xray con checksum verificado, clientes con vencimiento, enlaces `vless://` |
| Sistema | Info, BBR, swap, update, limpieza automática, actualizar desde GitHub, desinstalar |

## Estructura

```
install.sh          instalador
core/               config, interfaz y menús (usuarios, servicios, sistema)
modules/            módulos que se cargan solos (xray.sh, ws-proxy.py, xray-cfg.py)
NOTICE.md           software de terceros que se instala (no se redistribuye)
```

## Configuración de marca

Todo en `core/config.sh`: `APP_NAME`, `APP_ID`, `APP_AUTHOR` y `APP_REPO`.

## Agregar un módulo

1. Crea `modules/mimodulo.sh` con tus funciones y un `menu_mimodulo`.
2. Agrega una línea en `core/menu.sh` para abrirlo.
3. Si necesita limpieza diaria, define `mimodulo_cleanup` y llámala en `--clean`.

## Flujo de trabajo con Git

```bash
# en tu PC
git add . && git commit -m "Describe el cambio" && git push

# en el VPS (o desde el menú: Sistema → Actualizar)
nexora      # Sistema → 6) Actualizar
```

## Seguridad

- Xray corre como usuario `nobody`, no como root.
- Las descargas se verifican con SHA-256 cuando el proyecto publica checksum.
- Nexora no desactiva el firewall ni borra logs del sistema.
- Nunca subas claves, tokens ni certificados al repositorio (`.gitignore` ya los excluye).
