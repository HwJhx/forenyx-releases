#!/bin/bash

# =============================================================================
# Forenyx AI Installer (Commercial Closed-Source Version)
# =============================================================================
# Supported OS: macOS, Linux
# Dependencies: curl, tar
# =============================================================================

set -e

# ANSI Color Codes for premium aesthetics
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${CYAN}${BOLD}=====================================================${NC}"
echo -e "${CYAN}${BOLD}           Installing Forenyx AI (Forenyx)            ${NC}"
echo -e "${CYAN}${BOLD}=====================================================${NC}"

# 1. Platform Detection
echo -e "${BLUE}[1/5] Detecting platform architecture...${NC}"
OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH_TYPE=$(uname -m)

PLATFORM=""
case "$OS_TYPE" in
    darwin)
        if [ "$ARCH_TYPE" = "arm64" ]; then
            PLATFORM="darwin-arm64"
        else
            PLATFORM="darwin-x64"
        fi
        ;;
    linux)
        if [ "$ARCH_TYPE" = "x86_64" ]; then
            PLATFORM="linux-x64"
        elif [ "$ARCH_TYPE" = "aarch64" ] || [ "$ARCH_TYPE" = "arm64" ]; then
            PLATFORM="linux-arm64"
        else
            echo -e "${RED}Error: Unsupported Linux architecture: $ARCH_TYPE${NC}"
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}Error: Unsupported OS: $OS_TYPE${NC}"
        exit 1
        ;;
esac

echo -e "  - Platform: ${GREEN}$PLATFORM${NC}"

# 2. Directory Setup
echo -e "${BLUE}[2/5] Setting up directories...${NC}"
FORENYX_DIR="$HOME/.forenyx"
BIN_DIR="$FORENYX_DIR/bin"
AGENT_DIR="$FORENYX_DIR/agent"

mkdir -p "$FORENYX_DIR"
mkdir -p "$BIN_DIR"
mkdir -p "$AGENT_DIR/skills/builtin"
mkdir -p "$AGENT_DIR/skills/custom"

# 3. Download and Extract Binary Package
echo -e "${BLUE}[3/5] Downloading pre-compiled binaries...${NC}"

# Fetch version config to download the target release
RELEASES_REPO="HwJhx/forenyx-releases"
VERSION_URL="https://raw.githubusercontent.com/$RELEASES_REPO/main/version.json"

echo -e "  - Retrieving latest version info..."
VERSION_DATA=$(curl -fsSL "$VERSION_URL" || echo "")

if [ -z "$VERSION_DATA" ]; then
    echo -e "${RED}Error: Failed to fetch version info from $VERSION_URL${NC}"
    exit 1
fi

# Simple JSON parser in shell
LATEST_VERSION=$(echo "$VERSION_DATA" | grep -o '"version": "[^"]*' | grep -o '[^"]$' | tr -d '"')

if [ -z "$LATEST_VERSION" ]; then
    # Fallback regex in case of different formatting
    LATEST_VERSION=$(echo "$VERSION_DATA" | grep -o '"version":\s*"[^"]*"' | head -n1 | cut -d'"' -f4)
fi

if [ -z "$LATEST_VERSION" ]; then
    echo -e "${RED}Error: Could not parse version from version.json${NC}"
    exit 1
fi

TARBALL_NAME="forenyx-$PLATFORM.tar.gz"
DOWNLOAD_URL="https://github.com/$RELEASES_REPO/releases/download/$LATEST_VERSION/$TARBALL_NAME"

echo -e "  - Downloading version ${GREEN}$LATEST_VERSION${NC} from $DOWNLOAD_URL..."
TMP_TARBALL="/tmp/$TARBALL_NAME"

# Download with curl
if ! curl -L --progress-bar "$DOWNLOAD_URL" -o "$TMP_TARBALL"; then
    echo -e "${RED}Error: Download failed! Please check your network connection.${NC}"
    exit 1
fi

echo -e "  - Extracting to $BIN_DIR..."
# Clean old installation binaries first
rm -rf "$BIN_DIR"/*

# Extract tarball.
# The tarball contains a folder named "forenyx", inside which has all the files.
tar -xzf "$TMP_TARBALL" -C /tmp/
# Move contents to ~/.forenyx/bin/
cp -rf /tmp/forenyx/* "$BIN_DIR/"
rm -rf /tmp/forenyx "$TMP_TARBALL"

# Deploy Builtin Skills
echo -e "  - Refreshing system built-in skills..."
rm -rf "$AGENT_DIR/skills/builtin"/*
if [ -d "$BIN_DIR/skills" ]; then
    cp -rf "$BIN_DIR/skills/"* "$AGENT_DIR/skills/builtin/"
    # Remove raw skills folder from bin to keep it clean
    rm -rf "$BIN_DIR/skills"
fi

# 4. Generate Forenyx CLI Shell Wrapper
echo -e "${BLUE}[4/5] Creating command wrapper...${NC}"
WRAPPER_FILE="$BIN_DIR/forenyx"

cat << 'EOF' > "$WRAPPER_FILE"
#!/bin/bash

# =============================================================================
# Forenyx AI Wrapper
# =============================================================================

FORENYX_DIR="$HOME/.forenyx"
BIN_DIR="$FORENYX_DIR/bin"
AGENT_DIR="$FORENYX_DIR/agent"

# Command interceptors
case "$1" in
    update)
        echo -e "\033[0;36m=====================================================\033[0m"
        echo -e "\033[0;36m\033[1m           Updating Forenyx AI Client                \033[0m"
        echo -e "\033[0;36m=====================================================\033[0m"
        
        RELEASES_REPO="HwJhx/forenyx-releases"
        VERSION_URL="https://raw.githubusercontent.com/$RELEASES_REPO/main/version.json"
        
        VERSION_DATA=$(curl -fsSL "$VERSION_URL" || echo "")
        if [ -z "$VERSION_DATA" ]; then
            echo -e "\033[0;31mError: Failed to fetch version info from $VERSION_URL\033[0m"
            exit 1
        fi
        
        LATEST_VERSION=$(echo "$VERSION_DATA" | grep -o '"version":\s*"[^"]*"' | head -n1 | cut -d'"' -f4)
        if [ -z "$LATEST_VERSION" ]; then
            echo -e "\033[0;31mError: Could not parse version from version.json\033[0m"
            exit 1
        fi
        
        # Detect platform
        OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
        ARCH_TYPE=$(uname -m)
        PLATFORM=""
        if [ "$OS_TYPE" = "darwin" ]; then
            [ "$ARCH_TYPE" = "arm64" ] && PLATFORM="darwin-arm64" || PLATFORM="darwin-x64"
        elif [ "$OS_TYPE" = "linux" ]; then
            [ "$ARCH_TYPE" = "x86_64" ] && PLATFORM="linux-x64" || PLATFORM="linux-arm64"
        fi
        
        if [ -z "$PLATFORM" ]; then
            echo -e "\033[0;31mError: Unsupported platform during update.\033[0m"
            exit 1
        fi
        
        TARBALL_NAME="forenyx-$PLATFORM.tar.gz"
        DOWNLOAD_URL="https://github.com/$RELEASES_REPO/releases/download/$LATEST_VERSION/$TARBALL_NAME"
        
        echo -e "Downloading version \033[0;32m$LATEST_VERSION\033[0m..."
        TMP_TARBALL="/tmp/$TARBALL_NAME"
        if ! curl -L --progress-bar "$DOWNLOAD_URL" -o "$TMP_TARBALL"; then
            echo -e "\033[0;31mError: Download failed.\033[0m"
            exit 1
        fi
        
        # Clean current bin files EXCEPT wrapper itself (to avoid script execution interrupt)
        mkdir -p "$BIN_DIR/update_tmp"
        tar -xzf "$TMP_TARBALL" -C "$BIN_DIR/update_tmp/"
        
        # Move everything from update_tmp/forenyx to bin/
        cp -f "$BIN_DIR/update_tmp/forenyx/forenyx-cli" "$BIN_DIR/forenyx-cli" 2>/dev/null || true
        cp -f "$BIN_DIR/update_tmp/forenyx/photon_rs_bg.wasm" "$BIN_DIR/photon_rs_bg.wasm" 2>/dev/null || true
        cp -rf "$BIN_DIR/update_tmp/forenyx/node_modules" "$BIN_DIR/" 2>/dev/null || true
        
        # Refresh builtin skills
        if [ -d "$BIN_DIR/update_tmp/forenyx/skills" ]; then
            rm -rf "$AGENT_DIR/skills/builtin"/*
            cp -rf "$BIN_DIR/update_tmp/forenyx/skills/"* "$AGENT_DIR/skills/builtin/"
        fi
        
        # Cleanup tmp
        rm -rf "$BIN_DIR/update_tmp" "$TMP_TARBALL"
        
        echo -e "\033[0;32m\033[1mForenyx AI has been successfully updated to $LATEST_VERSION!\033[0m"
        exit 0
        ;;
    uninstall)
        echo -e "\033[0;31m=====================================================\033[0m"
        echo -e "\033[0;31m\033[1m          Uninstalling Forenyx AI Client             \033[0m"
        echo -e "\033[0;31m=====================================================\033[0m"
        
        echo -e "\033[0;33mWould you like to keep your custom skills and configuration data?\033[0m"
        echo -e "  Skills path: ~/.forenyx/agent/skills/custom/"
        echo -e "  Configurations path: ~/.forenyx/agent/ (settings.json, auth.json, sessions/)"
        echo -en "Keep these files? (y/n, default: y): "
        read -r KEEP_DATA
        KEEP_DATA=${KEEP_DATA:-y}
        
        if [ "$KEEP_DATA" = "y" ] || [ "$KEEP_DATA" = "Y" ]; then
            echo -e "\033[0;34mKeeping configurations and skills. Cleaning binaries...\033[0m"
            rm -rf "$BIN_DIR"
            echo -e "  - Cleared binaries and wrappers."
        else
            echo -e "\033[0;31mCompletely deleting all Forenyx AI data...\033[0m"
            rm -rf "$FORENYX_DIR"
            echo -e "  - Cleared ~/.forenyx/ directory."
        fi
        
        # Cleanup PATH
        SHELL_NAME=$(basename "$SHELL")
        RC_FILE=""
        case "$SHELL_NAME" in
            zsh) RC_FILE="$HOME/.zshrc" ;;
            bash) [ -f "$HOME/.bash_profile" ] && RC_FILE="$HOME/.bash_profile" || RC_FILE="$HOME/.bashrc" ;;
            csh|tcsh) [ -f "$HOME/.tcshrc" ] && RC_FILE="$HOME/.tcshrc" || RC_FILE="$HOME/.cshrc" ;;
            *) RC_FILE="$HOME/.bashrc" ;;
        esac
        
        if [ -f "$RC_FILE" ] && grep -q "forenyx/bin" "$RC_FILE"; then
            TEMP_RC=$(mktemp)
            grep -v "forenyx/bin" "$RC_FILE" | grep -v "# Forenyx AI CLI PATH configuration" > "$TEMP_RC"
            cat "$TEMP_RC" > "$RC_FILE"
            rm -f "$TEMP_RC"
            echo -e "  - Removed PATH configuration from $RC_FILE."
        fi
        
        echo -e "\033[0;32m\033[1mForenyx AI has been successfully uninstalled!\033[0m"
        exit 0
        ;;
esac

# Execute actual compiled binary
export PI_PACKAGE_DIR="$BIN_DIR"
exec "$BIN_DIR/forenyx-cli" "$@"
EOF

chmod +x "$WRAPPER_FILE"

# 5. Environment PATH Setup
echo -e "${BLUE}[5/5] Configuring shell PATH environment...${NC}"
SHELL_NAME=$(basename "$SHELL")
RC_FILE=""
PATH_LINE=""

case "$SHELL_NAME" in
    zsh)
        RC_FILE="$HOME/.zshrc"
        PATH_LINE="export PATH=\"\$HOME/.forenyx/bin:\$PATH\""
        ;;
    bash)
        if [ -f "$HOME/.bash_profile" ]; then
            RC_FILE="$HOME/.bash_profile"
        else
            RC_FILE="$HOME/.bashrc"
        fi
        PATH_LINE="export PATH=\"\$HOME/.forenyx/bin:\$PATH\""
        ;;
    csh|tcsh)
        if [ -f "$HOME/.tcshrc" ]; then
            RC_FILE="$HOME/.tcshrc"
        else
            RC_FILE="$HOME/.cshrc"
        fi
        PATH_LINE="setenv PATH \"\$HOME/.forenyx/bin:\$PATH\""
        ;;
    *)
        RC_FILE="$HOME/.bashrc"
        PATH_LINE="export PATH=\"\$HOME/.forenyx/bin:\$PATH\""
        ;;
esac

if [ -f "$RC_FILE" ]; then
    if grep -q "forenyx/bin" "$RC_FILE"; then
        echo -e "  - Path configuration already exists in $RC_FILE."
    else
        echo -e "  - Adding PATH to $RC_FILE..."
        echo -e "\n# Forenyx AI CLI PATH configuration\n$PATH_LINE" >> "$RC_FILE"
    fi
else
    echo -e "  - Shell config file $RC_FILE not found. Creating it..."
    echo -e "$PATH_LINE" > "$RC_FILE"
fi

echo -e "${GREEN}${BOLD}=====================================================${NC}"
echo -e "${GREEN}${BOLD}      Forenyx AI installation finished successfully!  ${NC}"
echo -e "${GREEN}${BOLD}=====================================================${NC}"
echo -e "To apply the environment changes immediately, please run:"
echo -e "  ${CYAN}${BOLD}source $RC_FILE${NC}"
echo -e "Then, you can start Forenyx AI anywhere by typing:"
echo -e "  ${CYAN}${BOLD}forenyx${NC}"
echo -e "To update Forenyx AI in the future, simply run:"
echo -e "  ${CYAN}${BOLD}forenyx update${NC}"
echo -e "To uninstall Forenyx AI, simply run:"
echo -e "  ${CYAN}${BOLD}forenyx uninstall${NC}"
echo -e "====================================================="
