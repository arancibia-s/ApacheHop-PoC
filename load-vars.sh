#!/bin/sh
# Se ejecuta antes de que Hop registre el proyecto (via HOP_CUSTOM_ENTRYPOINT_EXTENSION_SHELL_FILE_PATH).
# Lee las credenciales desde las variables de entorno del contenedor (nunca desde un archivo horneado
# en la imagen: en local vienen de "docker run -e", en produccion de Secrets Manager / Secret Manager)
# y las escribe en el hop-config.json de la instalacion de Hop del contenedor — el mismo mecanismo que
# usa load-vars.ps1 en local, solo que en bash+jq en vez de PowerShell.
set -e

CONFIG_FILE="/opt/hop/config/hop-config.json"

set_var() {
  name="$1"
  value="$2"
  tmp="$(mktemp)"
    jq --arg name "$name" --arg value "$value" '
    (.variables //= [])
    | if (.variables | map(select(.name == $name)) | length) > 0
      then .variables |= map(if .name == $name then .value = $value else . end)
      else .variables += [{name: $name, value: $value, description: "Credencial de runtime - registrada por register-vars.sh"}]
      end
  ' "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

for var in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD; do
  eval value=\$$var
  if [ -n "$value" ]; then
    echo "Registrando $var ..."
    set_var "$var" "$value"
  else
    echo "!! $var no esta seteada en el entorno del contenedor."
  fi
done