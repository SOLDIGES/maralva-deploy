#!/bin/bash

# Script para actualizar repositorios desde upstream (OCA) mediante SSH
# Uso: ./update_oca_upstream.sh

echo "ADVERTENCIA: Esta actualización traerá cambios desde OCA que podrían afectar bases de datos existentes."
echo "REALIZAR SNAPSHOT DE LA MAQUINA VIRTUAL ANTES DE CONTINUAR."

# Verificación de seguridad: Instantánea de la VM
echo "POR SEGURIDAD: ¿Has realizado una instantánea de la máquina virtual? (sí/no)"
read -p "Respuesta: " snapshot
if [[ "$snapshot" != "sí" && "$snapshot" != "si" && "$snapshot" != "yes" && "$snapshot" != "y" ]]; then
    echo "Operación cancelada. Realiza una instantánea antes de continuar."
    exit 1
fi

read -p "Rama de Odoo/OCA (ej. 18.0, 19.0) [18.0]: " BRANCH
BRANCH=${BRANCH:-18.0}
BRANCH_DOMAIN=$(echo "$BRANCH" | cut -d. -f1)
BASE_INSTANCIA="/opt/odoo/$BRANCH_DOMAIN"
DIR_CORE="$BASE_INSTANCIA/odoo"
DIR_OCA="$BASE_INSTANCIA/oca"
LISTA_REPOS="$(pwd)/reposoca.txt"

if [ ! -f "$LISTA_REPOS" ]; then
    echo "Error: No se encuentra $LISTA_REPOS"
    exit 1
fi

echo "--- Actualizando repositorios desde upstream (OCA) para rama $BRANCH ---"

# Función para actualizar un repo
update_repo() {
    local repo_path=$1
    local repo_name=$(basename "$repo_path")
    
    if [ -d "$repo_path/.git" ]; then
        echo "--- Actualizando $repo_name ---"
        cd "$repo_path"
        if git pull upstream "$BRANCH"; then
            echo "   [OK] $repo_name actualizado desde upstream."
        else
            echo "   [ERROR] Falló la actualización de $repo_name. Revisa logs."
        fi
    else
        echo "   [SKIP] $repo_name no es un repositorio Git."
    fi
}

# Actualizar core (OCB)
update_repo "$DIR_CORE"

# Actualizar repos OCA desde lista
while IFS= read -r repo || [ -n "$repo" ]; do
    [[ -z "$repo" || "$repo" =~ ^# ]] && continue
    
    TARGET_DIR="$DIR_OCA/${repo}"
    update_repo "$TARGET_DIR"
done < "$LISTA_REPOS"

echo "--- Actualización desde upstream completada ---"
echo "IMPORTANTE: Revisa si hay cambios que puedan afectar bases de datos existentes."
echo "Considera hacer backup antes de reiniciar Odoo."