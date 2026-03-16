#!/bin/bash
# Variables necesarias: BRANCH (18.0), DOMAIN (maralva.loc), ODOO_PORT, ODOO_CHAT_PORT, BRANCH_CLEAN (180)
NGINX_CONF="/etc/nginx/sites-available/odoo$BRANCH_CLEAN"

echo "--- Configurando Nginx para rama $BRANCH ($DOMAIN) ---"

# Eliminamos el default de Nginx para evitar conflictos de prioridad
sudo rm -f /etc/nginx/sites-enabled/default

sudo bash -c "cat > $NGINX_CONF <<EOF
upstream odoo_backend_$BRANCH_CLEAN {
    server 127.0.0.1:$ODOO_PORT;
}
upstream odoo_chat_$BRANCH_CLEAN {
    server 127.0.0.1:$ODOO_CHAT_PORT;
}

server {
    listen 80;
    # Añadimos el base y el comodín para que Certbot sea feliz
server {
    listen 80;
    server_name maralva$BRANCH_DOMAIN.$DOMAIN *.maralva$BRANCH_DOMAIN.$DOMAIN;
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;
    client_max_body_size 128M;

    # Logs específicos por instancia para no mezclar
    access_log /var/log/nginx/odoo${BRANCH_CLEAN}_access.log;
    error_log /var/log/nginx/odoo${BRANCH_CLEAN}_error.log;

    location /longpolling {
        proxy_pass http://odoo_chat_$BRANCH_CLEAN;
    }

    location / {
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://odoo_backend_$BRANCH_CLEAN;
    }
}
EOF"

# Crear enlace, testear y reiniciar
sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx