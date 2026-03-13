#!/bin/bash

# Script para actualizar repositorios desde origin (tu organización) mediante SSH
# Uso: ./update_org_origin.sh [rama]
# Si no se especifica rama, usa 18.0 por defecto
# ADVERTENCIA: Esto puede introducir cambios que afecten bases de datos. Haz backup primero.

# Verificación de seguridad: Instantánea de la VM
echo "POR SEGURIDAD: ¿Has realizado una instantánea de la máquina virtual? (sí/no)"
read -p "Respuesta: " snapshot
if [[ "$snapshot" != "sí" && "$snapshot" != "si" && "$snapshot" != "yes" && "$snapshot" != "y" ]]; then
    echo "Operación cancelada. Realiza una instantánea antes de continuar."
    exit 1
fi

BRANCH=${1:-18.0}
BASE_INSTANCIA="/opt/odoo/odoo$BRANCH"
DIR_CORE="$BASE_INSTANCIA/odoo"
DIR_OCA="$BASE_INSTANCIA/oca"
LISTA_REPOS="$(pwd)/reposoca.txt"
SERVICE_NAME="odoo$BRANCH"

if [ ! -f "$LISTA_REPOS" ]; then
    echo "Error: No se encuentra $LISTA_REPOS"
    exit 1
fi

echo "--- Actualizando repositorios desde origin (tu organización) para rama $BRANCH ---"
echo "ADVERTENCIA: Estos cambios pueden afectar bases de datos existentes."
echo "Asegúrate de tener backups y reinicia Odoo después."

read -p "¿Continuar? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Operación cancelada."
    exit 0
fi

# Función para verificar estado del servicio Odoo
check_odoo_service() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "   [OK] Servicio $SERVICE_NAME sigue activo."
        return 0
    else
        echo "   [ERROR] Servicio $SERVICE_NAME caído después de la actualización. Revisa: sudo journalctl -u $SERVICE_NAME"
        return 1
    fi
}

# Función para actualizar un repo
update_repo() {
    local repo_path=$1
    local repo_name=$(basename "$repo_path")
    
    if [ -d "$repo_path/.git" ]; then
        echo "--- Actualizando $repo_name ---"
        cd "$repo_path"
        if sudo -u odoo git pull origin "$BRANCH"; then
            echo "   [OK] $repo_name actualizado desde origin."
            # Verificar servicio después de cada repo para detectar incoherencias tempranas
            if ! check_odoo_service; then
                echo "   [ALERTA] Posible incoherencia detectada tras actualizar $repo_name. Deteniendo actualizaciones."
                return 1
            fi
        else
            echo "   [ERROR] Falló la actualización de $repo_name. Revisa logs."
            return 1
        fi
    else
        echo "   [SKIP] $repo_name no es un repositorio Git."
    fi
    return 0
}

# Actualizar core (si aplica, asumiendo que origin es tu fork de OCB)
if ! update_repo "$DIR_CORE"; then
    echo "Error al actualizar core. Abortando."
    exit 1
fi

# Actualizar repos OCA (tus forks) desde lista
while IFS= read -r repo || [ -n "$repo" ]; do
    [[ -z "$repo" || "$repo" =~ ^# ]] && continue
    
    TARGET_DIR="$DIR_OCA/${repo}"
    if ! update_repo "$TARGET_DIR"; then
        echo "Error al actualizar $repo. Abortando."
        exit 1
    fi
done < "$LISTA_REPOS"

echo "--- Actualización desde origin completada ---"
echo "Verificación final del servicio:"
check_odoo_service
echo "Reinicia el servicio Odoo si es necesario: sudo systemctl restart $SERVICE_NAME"
echo "Monitorea logs: journalctl -u $SERVICE_NAME -f"