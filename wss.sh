#!/bin/bash

# WSSMUX Tunnel Manager
# Developed By _ @AliTabari

# Configuration
CONFIG_DIR="/etc/wssmux"
LOG_DIR="/var/log/wssmux"
SERVICE_FILE="/etc/systemd/system/wssmux.service"
CONFIG_FILE="$CONFIG_DIR/config.env"
INSTALL_LOG="$LOG_DIR/install.log"
CRON_FILE="/etc/cron.d/wssmux-restart"

# Initialize directories and log file FIRST
mkdir -p "$CONFIG_DIR" "$LOG_DIR"
touch "$INSTALL_LOG"

# Color palette
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Logging function with file creation check
log() {
    # Ensure log directory and file exist
    mkdir -p "$LOG_DIR"
    touch "$INSTALL_LOG"
    
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$INSTALL_LOG"
}

# Check root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Please run as root${NC}"
        exit 1
    fi
}

# Detect OS and architecture
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        log "${RED}Unsupported OS${NC}"
        exit 1
    fi
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="arm" ;;
        *) log "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac
}

# Install all dependencies for all architectures
install_deps() {
    log "Installing dependencies for $OS ($ARCH)..."
    
    case $OS in
        ubuntu|debian)
            apt-get update -y
            apt-get install -y nginx curl wget snapd socat cron
            ;;
        centos|rhel|fedora)
            yum update -y
            yum install -y nginx curl wget snapd socat cronie
            ;;
        alpine)
            apk update
            apk add nginx curl wget socat dcron
            ;;
        *)
            log "${RED}Unsupported OS: $OS${NC}"
            exit 1
            ;;
    esac
    
    # Install Certbot via snap
    if ! command -v certbot &> /dev/null; then
        snap install core
        snap refresh core
        snap install --classic certbot
        ln -s /snap/bin/certbot /usr/bin/certbot
    fi
}

# Remove any existing configuration for a domain
remove_domain_config() {
    local domain=$1
    if [ -z "$domain" ]; then
        return
    fi
    
    log "Removing existing configuration for domain: $domain"
    
    # Stop nginx first
    systemctl stop nginx 2>/dev/null || true
    
    # Remove Nginx configuration
    rm -f "/etc/nginx/sites-available/$domain"
    rm -f "/etc/nginx/sites-enabled/$domain"
    
    # Remove any configuration in conf.d that contains the domain
    if [ -d "/etc/nginx/conf.d" ]; then
        find /etc/nginx/conf.d/ -type f -exec grep -l "$domain" {} \; | while read file; do
            log "Removing conf.d file: $file"
            rm -f "$file"
        done
    fi
    
    # Remove SSL certificate
    if certbot certificates 2>/dev/null | grep -q "Certificate Name: $domain"; then
        certbot delete --cert-name "$domain" --non-interactive 2>/dev/null || true
    fi
    
    # Remove certificate directory
    rm -rf "/etc/letsencrypt/live/$domain"
    rm -rf "/etc/letsencrypt/archive/$domain"
    rm -f "/etc/letsencrypt/renewal/$domain.conf"
    
    # Start nginx again
    systemctl start nginx 2>/dev/null || true
}

# Clean up all Nginx configurations
clean_nginx_config() {
    log "Cleaning up all Nginx configurations..."
    
    # Stop nginx
    systemctl stop nginx 2>/dev/null || true
    
    # Remove all site configurations
    rm -f /etc/nginx/sites-enabled/*
    rm -f /etc/nginx/sites-available/*
    
    # Remove all conf.d configurations
    rm -f /etc/nginx/conf.d/*
    
    # Create a minimal default configuration
    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    
    # Test and start nginx
    if nginx -t; then
        systemctl start nginx
        log "${GREEN}Nginx cleaned and started successfully${NC}"
    else
        log "${RED}Nginx configuration test failed after cleanup${NC}"
        exit 1
    fi
}

# Get user input with no defaults
get_user_input() {
    echo -e "${CYAN}${BOLD}=== WSSMUX Tunnel Configuration ===${NC}"
    echo
    
    # Ask if user wants to remove existing configuration
    read -p "Do you want to remove any existing tunnel configuration? (y/n): " remove_existing
    if [[ "$remove_existing" == "y" || "$remove_existing" == "Y" ]]; then
        read -p "Enter domain to remove (leave empty to skip): " domain_to_remove
        if [ -n "$domain_to_remove" ]; then
            remove_domain_config "$domain_to_remove"
        fi
    fi
    
    read -p "Enter server role (iran/foreign): " ROLE
    ROLE=$(echo "$ROLE" | tr '[:upper:]' '[:lower:]')

    if [[ "$ROLE" != "iran" && "$ROLE" != "foreign" ]]; then
        log "${RED}Invalid role. Must be 'iran' or 'foreign'${NC}"
        exit 1
    fi

    read -p "Enter v2ray inbound ports (comma-separated): " V2RAY_PORTS
    read -p "Enter XUI panel port to exclude: " XUI_PORT

    if [ "$ROLE" == "iran" ]; then
        read -p "Enter your domain: " DOMAIN
        read -p "Enter foreign server IP: " FOREIGN_IP
    else
        read -p "Enter the domain used in Iran server: " DOMAIN
        read -p "Enter this foreign server's IP: " FOREIGN_IP
    fi

    # Validate ports
    if ! [[ "$V2RAY_PORTS" =~ ^[0-9,]+$ ]]; then
        log "${RED}Invalid v2ray ports format${NC}"
        exit 1
    fi

    if ! [[ "$XUI_PORT" =~ ^[0-9]+$ ]]; then
        log "${RED}Invalid XUI port${NC}"
        exit 1
    fi

    # Clean up all Nginx configurations first
    clean_nginx_config
    
    # Remove any existing configuration for this domain
    remove_domain_config "$DOMAIN"

    # Ensure config directory exists
    mkdir -p "$CONFIG_DIR"
    
    # Save configuration
    cat > "$CONFIG_FILE" <<EOF
ROLE=$ROLE
DOMAIN=$DOMAIN
FOREIGN_IP=$FOREIGN_IP
V2RAY_PORTS=$V2RAY_PORTS
XUI_PORT=$XUI_PORT
EOF
}

# Create basic Nginx config
create_nginx_base() {
    log "Creating basic Nginx configuration..."
    
    # Remove default configuration
    rm -f /etc/nginx/sites-enabled/default
    
    cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

    ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
    
    if nginx -t; then
        systemctl reload nginx
        log "${GREEN}Basic Nginx configuration created successfully${NC}"
    else
        log "${RED}Nginx configuration test failed${NC}"
        exit 1
    fi
}

# Obtain SSL certificate with forced renewal
obtain_ssl() {
    log "Obtaining SSL certificate for $DOMAIN..."
    
    # Stop nginx first
    systemctl stop nginx
    
    # Remove any existing certificate for this domain
    remove_domain_config "$DOMAIN"
    
    # Obtain new certificate
    if certbot certonly --standalone -d "$DOMAIN" --agree-tos --email admin@"$DOMAIN" --non-interactive --force-renewal; then
        log "${GREEN}SSL certificate obtained successfully${NC}"
    else
        log "${RED}Failed to obtain SSL certificate${NC}"
        systemctl start nginx
        exit 1
    fi
    
    # Verify certificate files exist
    if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] || [ ! -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
        log "${RED}Certificate files not found after issuance${NC}"
        systemctl start nginx
        exit 1
    fi
    
    # Start nginx
    systemctl start nginx
}

# Configure Nginx with SSL
configure_nginx() {
    log "Configuring Nginx with SSL and tunnel..."
    
    # Verify certificate files exist
    if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] || [ ! -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
        log "${RED}Certificate files not found. Cannot configure SSL${NC}"
        exit 1
    fi
    
    cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff;

    # WSSMUX proxy configuration
    location /wssmux {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Block XUI panel access
    location ~* ^/$XUI_PORT/ {
        deny all;
        return 403;
    }
}
EOF

    # Test nginx configuration
    if nginx -t; then
        systemctl reload nginx
        log "${GREEN}Nginx configured successfully with SSL${NC}"
    else
        log "${RED}Nginx configuration test failed${NC}"
        exit 1
    fi
}

# Create systemd service
create_service() {
    log "Creating systemd service..."
    
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"
    
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=WSSMUX Tunnel Service
After=network.target nginx.service

[Service]
User=root
ExecStart=/usr/local/bin/wssmux-tunnel
Restart=always
RestartSec=5
StandardOutput=file:$LOG_DIR/wssmux.log
StandardError=file:$LOG_DIR/wssmux.error.log

[Install]
WantedBy=multi-user.target
EOF

    # Create tunnel script
    cat > "/usr/local/bin/wssmux-tunnel" <<'EOF'
#!/bin/bash
source /etc/wssmux/config.env

# Ensure log directory exists
mkdir -p /var/log/wssmux

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /var/log/wssmux/wssmux.log
}

# Determine target based on role
if [ "$ROLE" == "iran" ]; then
    TARGET="$FOREIGN_IP"
    log "Iran server: Forwarding to foreign server at $TARGET"
else
    TARGET="127.0.0.1"
    log "Foreign server: Forwarding to local services"
fi

# Kill any existing socat processes for our ports
TUNNEL_PORTS=$(echo "$V2RAY_PORTS" | tr ',' ' ')
for port in $TUNNEL_PORTS; do
    if [ "$port" != "$XUI_PORT" ]; then
        pkill -f "socat.*TCP-LISTEN:$port" || true
    fi
done

# Process each port
for port in $TUNNEL_PORTS; do
    if [ "$port" != "$XUI_PORT" ]; then
        log "Setting up tunnel for port $port to $TARGET:$port"
        socat TCP-LISTEN:$port,fork,reuseaddr TCP:$TARGET:$port &
    else
        log "Excluding XUI port $port from tunneling"
    fi
done

log "All tunnels configured. Waiting for connections..."
wait
EOF
    chmod +x "/usr/local/bin/wssmux-tunnel"
    
    systemctl daemon-reload
    systemctl enable wssmux
    systemctl start wssmux
}

# Setup cron job for restart
setup_cron() {
    echo -e "${CYAN}${BOLD}=== Setup Tunnel Restart Schedule ===${NC}"
    echo
    echo -e "${YELLOW}1. Every 1 hour${NC}"
    echo -e "${YELLOW}2. Every 2 hours${NC}"
    echo -e "${YELLOW}3. Every 3 hours${NC}"
    echo -e "${YELLOW}4. Every 6 hours${NC}"
    echo -e "${YELLOW}5. Every 12 hours${NC}"
    echo -e "${RED}6. Disable restart${NC}"
    echo
    read -p "Select option: " cron_option

    case $cron_option in
        1) cron_schedule="0 * * * *" ;;
        2) cron_schedule="0 */2 * * *" ;;
        3) cron_schedule="0 */3 * * *" ;;
        4) cron_schedule="0 */6 * * *" ;;
        5) cron_schedule="0 */12 * * *" ;;
        6) 
            rm -f "$CRON_FILE"
            systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null
            log "Cron job disabled"
            return
            ;;
        *) 
            echo -e "${RED}Invalid option${NC}"
            return
            ;;
    esac

    cat > "$CRON_FILE" <<EOF
$cron_schedule root systemctl restart wssmux > /dev/null 2>&1
EOF
    chmod 0644 "$CRON_FILE"
    
    systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null
    log "Cron job configured: $cron_schedule"
}

# Add new port to tunnel
add_port() {
    echo -e "${CYAN}${BOLD}=== Add New Port to Tunnel ===${NC}"
    echo
    read -p "Enter new port to add: " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid port format${NC}"
        return
    fi

    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        if [[ ",$V2RAY_PORTS," == *",$new_port,"* ]]; then
            echo -e "${YELLOW}Port already exists in tunnel${NC}"
            return
        fi

        # Add new port to config
        updated_ports="${V2RAY_PORTS},${new_port}"
        sed -i "s/V2RAY_PORTS=.*/V2RAY_PORTS=$updated_ports/" "$CONFIG_FILE"
        
        # Restart tunnel service
        systemctl restart wssmux
        log "Added new port $new_port to tunnel"
        echo -e "${GREEN}Port $new_port added successfully${NC}"
    else
        echo -e "${RED}Configuration not found. Please install tunnel first${NC}"
    fi
}

# Professional log viewer
view_logs() {
    echo -e "${CYAN}${BOLD}=== Professional Log Viewer ===${NC}"
    echo
    echo -e "${YELLOW}1. Installation log${NC}"
    echo -e "${YELLOW}2. Service log (live)${NC}"
    echo -e "${YELLOW}3. Service error log (live)${NC}"
    echo -e "${YELLOW}4. Nginx access log (live)${NC}"
    echo -e "${YELLOW}5. Nginx error log (live)${NC}"
    echo -e "${YELLOW}6. Search in logs${NC}"
    echo -e "${WHITE}7. Exit${NC}"
    echo
    read -p "Select log type: " log_choice

    case $log_choice in
        1) [ -f "$INSTALL_LOG" ] && less "$INSTALL_LOG" || echo "Log not found" ;;
        2) [ -f "$LOG_DIR/wssmux.log" ] && tail -f "$LOG_DIR/wssmux.log" || echo "Log not found" ;;
        3) [ -f "$LOG_DIR/wssmux.error.log" ] && tail -f "$LOG_DIR/wssmux.error.log" || echo "Log not found" ;;
        4) [ -f "/var/log/nginx/access.log" ] && tail -f "/var/log/nginx/access.log" || echo "Log not found" ;;
        5) [ -f "/var/log/nginx/error.log" ] && tail -f "/var/log/nginx/error.log" || echo "Log not found" ;;
        6)
            read -p "Enter search term: " search_term
            echo -e "${YELLOW}Searching for '$search_term' in logs...${NC}"
            grep -r "$search_term" "$LOG_DIR/" /var/log/nginx/ 2>/dev/null
            ;;
        7) return ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
}

# Tunnel monitoring
monitor_tunnel() {
    echo -e "${CYAN}${BOLD}=== Tunnel Monitoring ===${NC}"
    echo
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN}Domain: ${WHITE}$DOMAIN${NC}"
        echo -e "${GREEN}Role: ${WHITE}$ROLE${NC}"
        echo -e "${GREEN}Foreign IP: ${WHITE}$FOREIGN_IP${NC}"
        echo -e "${GREEN}V2Ray Ports: ${WHITE}$V2RAY_PORTS${NC}"
        echo -e "${GREEN}XUI Port: ${WHITE}$XUI_PORT${NC}"
        
        echo -e "\n${YELLOW}Service Status:${NC}"
        systemctl status wssmux --no-pager -l
        
        echo -e "\n${YELLOW}Active Connections:${NC}"
        netstat -tuln | grep -E ":($(echo $V2RAY_PORTS | tr ',' '|')))" | awk '{print $4 " -> " $5}'
        
        echo -e "\n${YELLOW}Recent Logs:${NC}"
        tail -10 "$LOG_DIR/wssmux.log"
    else
        echo -e "${RED}Configuration not found. Please install tunnel first${NC}"
    fi
}

# Complete uninstall
uninstall() {
    echo -e "${RED}${BOLD}=== COMPLETE TUNNEL REMOVAL ===${NC}"
    echo
    read -p "Are you sure? This will remove everything (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Operation cancelled"
        return
    fi
    
    log "Uninstalling WSSMUX..."
    
    # Stop and disable service
    systemctl stop wssmux 2>/dev/null
    systemctl disable wssmux 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    
    # Kill any running socat processes
    pkill -f "socat.*TCP-LISTEN" || true
    
    # Remove cron job
    rm -f "$CRON_FILE"
    systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null
    
    # Remove Nginx config and SSL
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        remove_domain_config "$DOMAIN"
    fi
    
    # Remove all files and directories
    rm -rf "$CONFIG_DIR"
    rm -rf "$LOG_DIR"
    rm -f /usr/local/bin/wssmux-tunnel
    
    echo -e "${GREEN}All components removed successfully${NC}"
}

# Main installation function
install() {
    check_root
    detect_os
    install_deps
    get_user_input
    
    # Only configure Nginx on Iran server
    if [ "$ROLE" == "iran" ]; then
        create_nginx_base
        obtain_ssl
        configure_nginx
    fi
    
    create_service
    
    log "${GREEN}Installation completed successfully!${NC}"
    if [ "$ROLE" == "iran" ]; then
        echo -e "${GREEN}Access your tunnel at: ${WHITE}https://$DOMAIN/wssmux${NC}"
    else
        echo -e "${GREEN}Foreign server configured for domain: ${WHITE}$DOMAIN${NC}"
    fi
    echo -e "${YELLOW}XUI panel port ($XUI_PORT) is excluded from tunneling${NC}"
}

# Professional UI Header
show_header() {
    clear
    echo -e "${PURPLE}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║  ███╗   ██╗ ██████╗ ██╗   ██╗ █████╗                                        ║
║  ████╗  ██║██╔═══██╗██║   ██║██╔══██╗                                      ║
║  ██╔██╗ ██║██║   ██║██║   ██║███████║                                      ║
║  ██║╚██╗██║██║   ██║╚██╗ ██╔╝██╔══██║                                      ║
║  ██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║                                      ║
║                                                                              ║
║                          Developed By _ @AliTabari                          ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Professional Menu
show_menu() {
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║${NC} ${YELLOW}🚀  [1] Install Tunnel${NC}$(printf '%*s' $((68-22)) '')${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}║${NC} ${YELLOW}⏰  [2] Setup Restart Schedule${NC}$(printf '%*s' $((68-30)) '')${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}║${NC} ${YELLOW}➕  [3] Add New Port${NC}$(printf '%*s' $((68-20)) '')${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}║${NC} ${YELLOW}📋  [4] View Logs${NC}$(printf '%*s' $((68-17)) '')${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}║${NC} ${YELLOW}📊  [5] Monitor Tunnel${NC}$(printf '%*s' $((68-21)) '')${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}║${NC} ${RED}🗑️  [6] Complete Removal${NC}$(printf '%*s' $((68-24)) '')${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}║${NC} ${WHITE}🚪  [7] Exit${NC}$(printf '%*s' $((68-11)) '')${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${WHITE}Enter your choice [1-7]:${NC} "
}

# Main menu
main_menu() {
    while true; do
        show_header
        show_menu
        read choice
        
        case $choice in
            1) install ;;
            2) setup_cron ;;
            3) add_port ;;
            4) view_logs ;;
            5) monitor_tunnel ;;
            6) uninstall ;;
            7) exit 0 ;;
            *) 
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
        
        read -p "Press Enter to continue..."
    done
}

# Main execution
if [ "$1" = "install" ]; then
    install
elif [ "$1" = "uninstall" ]; then
    uninstall
else
    main_menu
fi
