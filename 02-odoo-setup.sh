#!/bin/bash

# 1. Configuración dinámica del usuario que ejecuta ---
REAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
# LISTA_REPOS se obtiene de las variables exportadas en install_master.sh

# 2. Variables obtenidas de install_master.sh (BRANCH, ORGANIZACION, ODOO_PORT, ODOO_CHAT_PORT, DOMAIN, LISTA_REPOS, SERVICE_NAME)

# Comprobación básica: este script debe ejecutarse después de install_master.sh
if [ -z "$BRANCH" ] || [ -z "$ORGANIZACION" ] || [ -z "$SERVICE_NAME" ] || [ -z "$LISTA_REPOS" ]; then
	echo "Error: variables necesarias no definidas."
	echo "Este script debe lanzarse mediante install_master.sh, no directamente."
	exit 1
fi

# 3. Definición de la nueva estructura (coincide con install_master.sh)
# Usamos /opt/odoo/BRANCH_DOMAIN, p.ej. /opt/odoo/18, /opt/odoo/19
BASE_INSTANCIA="/opt/odoo/$BRANCH_DOMAIN"
DIR_CORE="$BASE_INSTANCIA/odoo"
DIR_OCA="$BASE_INSTANCIA/oca"
DIR_VENV="$BASE_INSTANCIA/venv"
CONF_FILE="/etc/odoo/$SERVICE_NAME.conf"
LOG_DIR="/var/log/odoo"

# 4. Configurar permisos para el usuario actual y estructura base
# Añadimos al usuario real al grupo odoo sin cambiar su grupo primario
sudo usermod -a -G odoo "$REAL_USER"

echo "--- Preparando estructura de /opt/odoo para $BRANCH ---"
sudo mkdir -p /opt/odoo "$BASE_INSTANCIA" "$DIR_CORE" "$DIR_OCA" "$LOG_DIR" /etc/odoo

# Aseguramos permisos amplios antes de la clonación
sudo chmod -R 775 /opt/odoo

# Código fuente de ESTA instancia: propietario el usuario real, grupo odoo,
# permitiendo usar SSH con GitHub y acceso del usuario odoo por grupo.
sudo chown -R "$REAL_USER":odoo "$BASE_INSTANCIA"
sudo chmod -R 775 "$BASE_INSTANCIA"
# Logs y configs propiedad de odoo
sudo chown -R odoo:odoo "$LOG_DIR" /etc/odoo
sudo chmod -R 750 "$LOG_DIR" /etc/odoo

echo "--- Clonando y configurando Odoo $BRANCH ---"
sudo git config --system --add safe.directory '*'

# 8. Clonar OCB (Core) --- ACTUALIZADO CON ORGANIZACIÓN ---
if [ ! -d "$DIR_CORE/.git" ]; then
	echo "--- Clonando OCB $BRANCH desde $ORGANIZACION ---"
	git clone --depth 1 --branch "$BRANCH" "git@github.com:$ORGANIZACION/OCB.git" "$DIR_CORE"
fi
if [ -d "$DIR_CORE" ]; then
	cd "$DIR_CORE"
	if ! git remote | grep -q "upstream"; then
		echo "---Añadiendo upstream OCA/OCB ---"
		git remote add upstream "git@github.com:OCA/OCB.git"
		# Opcional: Traer metadatos del upstream sin bajar todo el historial
		git fetch --depth 1 upstream "$BRANCH"
	fi
fi

# 9. Clonar repositorios de la lista
if [ -f "$LISTA_REPOS" ]; then
	while IFS= read -r repo || [ -n "$repo" ]; do
		[[ -z "$repo" || "$repo" =~ ^# ]] && continue

		TARGET_DIR="$DIR_OCA/${repo}"
		MY_FORK="git@github.com:$ORGANIZACION/${repo}.git"
		OCA_REPO="git@github.com:OCA/${repo}.git"

		if [ ! -d "$TARGET_DIR" ]; then
			echo "--- Repositorio: $repo ---"
			# Intentar clonar Fork, si falla, clonar OCA (mostrando errores para poder depurar)
			if git clone --depth 1 --branch "$BRANCH" "$MY_FORK" "$TARGET_DIR"; then
				echo "   [OK] Fork de $ORGANIZACION clonado."
			else
				echo "   [!] Fork no encontrado en $ORGANIZACION o error de acceso. Clonando de OCA..."
				git clone --depth 1 --branch "$BRANCH" "$OCA_REPO" "$TARGET_DIR"
			fi
		fi
		# Configuración de remotes
		if [ -d "$TARGET_DIR" ]; then
			cd "$TARGET_DIR"
			# 1. Asegurar que origin es la Organización
			git remote set-url origin "$MY_FORK"
			# 2.- Añadir upstream (OCA) si no existe
			if ! git remote | grep -q "upstream"; then
				git remote add upstream "$OCA_REPO"
				git fetch --depth 1 upstream "$BRANCH"
			fi
		fi
	done < "$LISTA_REPOS"
else
	echo "Error: No existe el archivo $LISTA_REPOS"
	exit 1
fi

# Entorno Virtual y Dependencias (Puntos 11-13)
if [ ! -d "$DIR_VENV" ]; then
	echo "--- Creando entorno virtual en $DIR_VENV ---"
	sudo -u odoo python3 -m venv "$DIR_VENV"
fi
sudo -u odoo "$DIR_VENV/bin/pip" install --upgrade pip
[ -f "$DIR_CORE/requirements.txt" ] && sudo -u odoo "$DIR_VENV/bin/pip" install -r "$DIR_CORE/requirements.txt"

# 14. GENERACIÓN AUTOMÁTICA DEL ODOO.CONF
echo "--- Generando archivo de configuración en $CONF_FILE ---"
ADDONS_PATH="$DIR_CORE/addons"
for d in "$DIR_OCA"/*; do
	[ -d "$d" ] && ADDONS_PATH="$ADDONS_PATH,$d"
done

sudo bash -c "cat > $CONF_FILE <<EOF
[options]
db_user = odoo
http_port = $ODOO_PORT
proxy_mode = True
dbfilter = ^%d$
longpolling_port = $ODOO_CHAT_PORT
addons_path = $ADDONS_PATH
logfile = $LOG_DIR/$SERVICE_NAME.log
xmlrpc_interface = 0.0.0.0
netrpc_interface = 0.0.0.0
workers = 5
EOF"
sudo chown odoo:odoo "$CONF_FILE"
sudo chmod 640 "$CONF_FILE"

# 15. Generar Servicio Systemd ---
FILE_SERVICE="/etc/systemd/system/$SERVICE_NAME.service"

echo "--- Generando archivo de servicio en $FILE_SERVICE ---"
sudo bash -c "cat > $FILE_SERVICE <<EOF
[Unit]
Description=Odoo $BRANCH Service
After=network.target postgresql.service

[Service]
Type=simple
User=odoo
Group=odoo
# Usamos la ruta absoluta del python del venv y del odoo-bin
ExecStart=$DIR_VENV/bin/python3 $DIR_CORE/odoo-bin -c $CONF_FILE
# Esto asegura que si falla, intente reiniciar solo
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF"

# 16. Recargar y arrancar servicio
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"