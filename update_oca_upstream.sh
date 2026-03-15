#!/bin/bash

# Script para actualizar repositorios desde upstream (OCA) mediante SSH
# Uso: ./update_oca_upstream.sh

# Timeout para git fetch (segundos); evita quedarse colgado por problemas de red
FETCH_TIMEOUT=300

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

LOG_INCOHERENCIAS="/var/log/odoo/repos_con_divergencias_${BRANCH}.log"
echo "Preparando log en $LOG_INCOHERENCIAS ..."
> "$LOG_INCOHERENCIAS" || { echo "Error: no se puede escribir en $LOG_INCOHERENCIAS (¿permisos? ¿sudo?)"; exit 1; }
MAX_SIZE=1024 # 1 MB en KB
MAX_ARCHIVOS=5 # Guardar hasta 5 rotaciones antiguas

if [ -f "$LOG_INCOHERENCIAS" ]; then
    TAMANO=$(du -k "$LOG_INCOHERENCIAS" | cut -f1)
    if [ "$TAMANO" -gt "$MAX_SIZE" ]; then
        echo "--- Rotando log de divergencias (Superado 1MB) ---"
        # Desplazar archivos antiguos (.4 -> .5, .3 -> .4, etc.)
        for i in $(seq $((MAX_ARCHIVOS-1)) -1 1); do
            [ -f "${LOG_INCOHERENCIAS}.$i" ] && mv "${LOG_INCOHERENCIAS}.$i" "${LOG_INCOHERENCIAS}.$((i+1))"
        done
        # Renombrar el actual a .1
        mv "$LOG_INCOHERENCIAS" "${LOG_INCOHERENCIAS}.1"
        # Crear el nuevo vacío
        touch "$LOG_INCOHERENCIAS"
    fi
fi
# Función para actualizar un repo
update_repo() {
    local repo_path=$1
    local repo_name=$(basename "$repo_path")
    
    if [ -d "$repo_path/.git" ]; then
       cd "$repo_path" || return
       # 1. Traer novedades sin tocar nada
        echo "   Fetching upstream/$BRANCH en $repo_name (timeout ${FETCH_TIMEOUT}s) ..."
        if ! timeout "$FETCH_TIMEOUT" git fetch upstream "$BRANCH"; then
            echo "   [ERROR] Timeout o fallo de conexión al hacer fetch de $repo_name. Comprueba la red y vuelve a ejecutar el script."
            cd - > /dev/null || true
            exit 1
        fi

        # 2. Comprobar incoherencias (¿Hay commits en local que no están en upstream?)
        # Esto detecta si la OCA ha hecho un "force push" o si tu rama divergió.
        BEHIND=$(git rev-list HEAD..upstream/"$BRANCH" --count)
        AHEAD=$(git rev-list upstream/"$BRANCH"..HEAD --count)
        
        if [ "$AHEAD" -gt 0 ]; then
            echo "[ALERTA] $repo_name tiene $AHEAD commits divergentes. Registrando..."
            echo "$(date '+%Y-%m-%d %H:%M:%S') - REPO: $repo_name - Divergencia: $AHEAD commits por delante/distintos de la OCA" >> "$LOG_INCOHERENCIAS"
        fi

        # 3. Aplicar el reset para unificar
        echo "--- Sincronizando $repo_name ---"
        if git reset --hard "upstream/$BRANCH" > /dev/null 2>&1; then
            echo "   [OK] $repo_name ahora es idéntico a la OCA."
            git push origin "$BRANCH" --force > /dev/null 2>&1
        else
            echo "   [ERROR] Fallo crítico al resetear $repo_name."
        fi
    fi
}

# Actualizar core (OCB) — suele ser el más pesado
echo "--- Repo core: $DIR_CORE ---"
echo "    (El core tiene muchos cambios; el fetch puede tardar varios minutos.)"
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