#!/bin/bash
set -e

API_BASE="http://fi10.bot-hosting.net:21922/api"
INSTALL_DIR="/opt/mypi"
APPS_DIR="$INSTALL_DIR/apps"

mkdir -p "$INSTALL_DIR"
mkdir -p "$APPS_DIR"

SCRIPT_PATH="$(realpath "$0")"
TARGET_PATH="$INSTALL_DIR/installer.sh"

if [ "$SCRIPT_PATH" != "$TARGET_PATH" ]; then
    sudo cp "$SCRIPT_PATH" "$TARGET_PATH"
    sudo chmod +x "$TARGET_PATH"
    sudo ln -sf "$TARGET_PATH" /usr/local/bin/MyPi
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
    elif ls "$APP_PATH"/*.py > /dev/null 2>&1; then
        echo "python"
    else
        echo "unknown"
    fi
}

install_dependencies() {
    APP_PATH="$1"
    TYPE=$(detect_type "$APP_PATH")

    if [ "$TYPE" == "node" ]; then
        cd "$APP_PATH"
        npm install
        cd "$INSTALL_DIR"
    elif [ "$TYPE" == "python" ]; then
        if [ -f "$APP_PATH/requirements.txt" ]; then
            cd "$APP_PATH"
            python3 -m venv venv
            source venv/bin/activate
            pip install -r requirements.txt
            deactivate
            cd "$INSTALL_DIR"
        fi
    fi
}

download_zip() {
    APP_NAME="$1"
    OUTPUT="$2"
    curl -L "$API_BASE/$APP_NAME/download" -o "$OUTPUT"
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

run_app() {
    APP_NAME="$1"
    APP_PATH="$APPS_DIR/$APP_NAME"

    if [ ! -d "$APP_PATH" ]; then
        echo "App not installed."
        exit 1
    fi

    TYPE=$(detect_type "$APP_PATH")

    if [ "$TYPE" == "node" ]; then
        cd "$APP_PATH"
        node index.js
    elif [ "$TYPE" == "python" ]; then
        cd "$APP_PATH"
        if [ -d "venv" ]; then
            source venv/bin/activate
        fi
        MAIN_FILE=$(ls *.py | head -1)
        python3 "$MAIN_FILE"
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
    for APP in $(ls "$APPS_DIR"); do
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
        echo "  MyPi update <app>        # update from server"
        echo "  MyPi update-all          # update all installed apps"
        echo "  MyPi run <app>           # run app"
        ;;
esac
