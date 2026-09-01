# https://hop.apache.org/tech-manual/latest/docker-container.html

FROM apache/hop:2.18.1

# user para instalar
USER root
# La imagen base usa alpine
RUN apk add --no-cache jq
# user por defecto de la imagen
USER hop 
# /files es el volumen de trabajo del usuario "hop" en la imagen base (lectura/escritura).

COPY --chown=hop:hop ./ /files

# registrar variables de entorno
USER root
RUN chmod +x /files/load-vars.sh
USER hop

# --- Config del proyecto
ENV HOP_PROJECT_FOLDER=/files
ENV HOP_PROJECT_NAME=ApacheHop-mvp
ENV HOP_RUN_CONFIG=local

# Lee las credenciales desde el entorno del contenedor y las escribe en /opt/hop/config/hop-config.json.
ENV HOP_CUSTOM_ENTRYPOINT_EXTENSION_SHELL_FILE_PATH=/files/load-vars.sh

# Qué correr por default (la corrida diaria completa). 
# Para una corrida manual de una sola pieza, no se rebuildea nada: se pisa esta variable en el "docker run"
# (por ejemplo: -e HOP_FILE_PATH=/files/cruises_process_booking_files_into_stg.hpl).
# !! Esto despues lo puedo automatizar 
# Será daily_load eventualmente
ENV HOP_FILE_PATH=/files/hop-mvp/ETLs/Cruises/Bookings/cruise_bookings_main.hwf

# A propósito NO seteamos HOP_ENVIRONMENT_NAME acá: cada corrida tiene que decir
# explícitamente si va contra "dev" o "production" — ver README de este entregable.