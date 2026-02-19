#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

API_BASE="http://fi10.bot-hosting.net:21922/api"
INSTALL_DIR="/opt/mypi"
APPS_DIR="$INSTALL_DIR/apps"

mkdir -p "$INSTALL_DIR"
mkdir -p "$APPS_DIR"

SCRIPT_PATH="$(realpath "$0")"
TARGET_PATH="$INSTALL_DIR/installer.sh"

if [ "$SCRIPT_PATH" != "$TARGET_PATH" ]; then
    cp "$SCRIPT_PATH" "$TARGET_PATH"
    chmod +x "$TARGET_PATH"
    ln -sf "$TARGET_PATH" /usr/local/bin/MyPi
    echo "Installer moved to $TARGET_PATH"
    echo "You can now run: sudo MyPi <command>"
    exit 0
fi

get_server_apps() {
    curl -s "$API_BASE/list" | tr -d '[]" ' | tr ',' '\n'
}

is_valid_app() {
    APP="$1"
    SERVER_APPS=$(get_server_apps)
    echo "$SERVER_APPS" | grep -Fxq "$APP"
}

detect_type() {
    APP_PATH="$1"
    if [ -f "$APP_PATH/package.json" ]; then
        echo "node"
    elif [ -f "$APP_PATH/requirements.txt" ]; then
        echo "python"
    else
        echo "unknown"
    fi
}

ensure_node() {
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        echo "Node.js and npm not found. Installing..."
        if [ -x "$(command -v apt)" ]; then
            apt update && apt install -y nodejs npm
        elif [ -x "$(command -v yum)" ]; then
            yum install -y epel-release
            yum install -y nodejs npm
        else
            echo "Unsupported package manager. Please install Node.js and npm manually."
            exit 1
        fi
        echo "Node.js and npm installed successfully."
    fi
}

ensure_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Python3 not found. Installing..."
        if [ -x "$(command -v apt)" ]; then
            apt update && apt install -y python3 python3-venv python3-pip
        elif [ -x "$(command -v yum)" ]; then
            yum install -y python3 python3-venv python3-pip
        else
            echo "Unsupported package manager. Please install Python3 manually."
            exit 1
        fi
        echo "Python3 installed successfully."
    fi
}

install_dependencies() {
    APP_PATH="$1"
    TYPE=$(detect_type "$APP_PATH")

    if [ "$TYPE" == "node" ]; then
        ensure_node
        if [ -f "$APP_PATH/package.json" ]; then
            echo "Node.js dependencies detected."
            read -p "Install npm dependencies? (yes/no): " CONFIRM
            if [ "$CONFIRM" = "yes" ]; then
                cd "$APP_PATH"
                npm install
                cd "$INSTALL_DIR"
            fi
        fi
    elif [ "$TYPE" == "python" ]; then
        ensure_python
        if [ -f "$APP_PATH/requirements.txt" ]; then
            echo "Python dependencies detected."
            read -p "Create venv and install requirements.txt? (yes/no): " CONFIRM
            if [ "$CONFIRM" = "yes" ]; then
                cd "$APP_PATH"
                python3 -m venv venv
                source venv/bin/activate
                pip install -r requirements.txt
                deactivate
                cd "$INSTALL_DIR"
            fi
        fi
    fi
}

download_zip() {
    APP_NAME="$1"
    OUTPUT="$2"

    HTTP_CODE=$(curl -L -s -w "%{http_code}" "$API_BASE/$APP_NAME/download" -o "$OUTPUT")

    if [ "$HTTP_CODE" != "200" ]; then
        echo "Download failed. Server returned HTTP $HTTP_CODE"
        rm -f "$OUTPUT"
        exit 1
    fi

    FILE_TYPE=$(file -b "$OUTPUT")
    if [[ "$FILE_TYPE" != *"Zip archive"* ]]; then
        echo "Downloaded file is not a valid zip archive."
        rm -f "$OUTPUT"
        exit 1
    fi
}

install_app() {
    APP_NAME="$1"

    if ! is_valid_app "$APP_NAME"; then
        echo "App '$APP_NAME' not available on server."
        exit 1
    fi

    APP_PATH="$APPS_DIR/$APP_NAME"
    ZIP_PATH="$APPS_DIR/$APP_NAME.zip"

    echo "Installing $APP_NAME..."
    download_zip "$APP_NAME" "$ZIP_PATH"
    mkdir -p "$APP_PATH"
    unzip -o "$ZIP_PATH" -d "$APP_PATH" > /dev/null
    rm "$ZIP_PATH"

    install_dependencies "$APP_PATH"
    echo "$APP_NAME installed successfully."
}

update_app() {
    APP_NAME="$1"
    if ! is_valid_app "$APP_NAME"; then
        echo "App '$APP_NAME' not available on server."
        exit 1
    fi

    APP_PATH="$APPS_DIR/$APP_NAME"
    INFO_PATH="$APP_PATH/info.json"
    ZIP_PATH="$APPS_DIR/$APP_NAME.zip"

    if [ ! -f "$INFO_PATH" ]; then
        echo "App not installed. Use 'install' first."
        exit 1
    fi

    CURRENT_VERSION=$(grep '"version"' "$INFO_PATH" | head -1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

    HTTP_CODE=$(curl -s -X POST "$API_BASE/$APP_NAME/update" \
        -H "Content-Type: application/json" \
        -d "{\"version\":\"$CURRENT_VERSION\"}" \
        -o "$ZIP_PATH" \
        -w "%{http_code}")

    if [ "$HTTP_CODE" == "204" ]; then
        echo "$APP_NAME is already up to date."
        rm -f "$ZIP_PATH"
        return
    fi

    if [ -f "$ZIP_PATH" ]; then
        unzip -o "$ZIP_PATH" -d "$APP_PATH" > /dev/null
        rm "$ZIP_PATH"
        install_dependencies "$APP_PATH"
        echo "$APP_NAME updated successfully."
    else
        echo "Update failed for $APP_NAME."
    fi
}

update_installer() {
    echo "Updating installer..."
    TEMP_PATH="/tmp/mypi_installer.sh"
    curl -L "$API_BASE/installer/download" -o "$TEMP_PATH"
    if [ -f "$TEMP_PATH" ]; then
        mv "$TEMP_PATH" "$TARGET_PATH"
        chmod +x "$TARGET_PATH"
        echo "Installer updated successfully."
    else
        echo "Failed to update installer."
    fi
}

uninstall_app() {
    APP_NAME="$1"
    APP_PATH="$APPS_DIR/$APP_NAME"

    if [ ! -d "$APP_PATH" ]; then
        echo "App not installed."
        exit 1
    fi

    rm -rf "$APP_PATH"
    echo "$APP_NAME uninstalled successfully."
}

clear_all() {
    echo "WARNING: This will remove ALL installed apps."
    read -p "Type 'yes' to confirm: " CONFIRM
    if [ "$CONFIRM" = "yes" ]; then
        rm -rf "$APPS_DIR"
        mkdir -p "$APPS_DIR"
        echo "All apps removed."
    else
        echo "Cancelled."
    fi
}

run_app() {
    APP_NAME="$1"
    APP_PATH="$APPS_DIR/$APP_NAME"

    if [ ! -d "$APP_PATH" ]; then
        echo "App not installed."
        exit 1
    fi

    TYPE=$(detect_type "$APP_PATH")
    cd "$APP_PATH"

    if [ "$TYPE" == "node" ]; then
        ensure_node
        if [ -f "index.js" ]; then
            node index.js
        else
            echo "index.js not found."
        fi
    elif [ "$TYPE" == "python" ]; then
        ensure_python
        if [ -f "app.py" ]; then
            if [ -d "venv" ]; then
                source venv/bin/activate
            fi
            python3 app.py
        else
            echo "app.py not found."
        fi
    else
        echo "Unknown app type."
    fi
}

list_apps() {
    echo "Installed apps:"
    ls "$APPS_DIR"
}

list_server_apps() {
    echo "Apps available on server:"
    get_server_apps
}

update_all_apps() {
    SERVER_APPS=$(get_server_apps)
    for APP in $(ls "$APPS_DIR" 2>/dev/null); do
        if echo "$SERVER_APPS" | grep -Fxq "$APP"; then
            update_app "$APP"
        else
            echo "Skipping $APP (not on server)"
        fi
    done
}

case "$1" in
    install)
        install_app "$2"
        ;;
    update)
        update_app "$2"
        ;;
    update-all)
        update_all_apps
        ;;
    update-installer)
        update_installer
        ;;
    uninstall)
        uninstall_app "$2"
        ;;
    clear)
        clear_all
        ;;
    run)
        run_app "$2"
        ;;
    list)
        list_apps
        ;;
    server)
        list_server_apps
        ;;
    *)
        echo "Usage:"
        echo "  MyPi server              # list apps on server"
        echo "  MyPi list                # list installed apps"
        echo "  MyPi install <app>       # install from server"
        echo "  MyPi uninstall <app>     # uninstall app"
        echo "  MyPi update <app>        # update app"
        echo "  MyPi update-all          # update all installed apps"
        echo "  MyPi update-installer    # update this installer"
        echo "  MyPi clear               # remove ALL apps"
        echo "  MyPi run <app>           # run app"
        ;;
esac
