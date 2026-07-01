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
LIBEXEC_DIR="$FORENYX_DIR/libexec"
AGENT_DIR="$FORENYX_DIR/agent"

mkdir -p "$FORENYX_DIR"
mkdir -p "$BIN_DIR"
mkdir -p "$LIBEXEC_DIR"
# Built-in skills are shipped as an encrypted blob (skills.pack), not plaintext.
# Only the user's own custom skills live under agent/skills.
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
LATEST_VERSION=$(echo "$VERSION_DATA" | grep '"version"' | head -n 1 | cut -d'"' -f4)

if [ -z "$LATEST_VERSION" ]; then
    echo -e "${RED}Error: Could not parse version from version.json${NC}"
    exit 1
fi

TARBALL_NAME="forenyx-$PLATFORM.tar.gz"
DOWNLOAD_URL="https://github.com/$RELEASES_REPO/releases/download/$LATEST_VERSION/$TARBALL_NAME"

echo -e "  - Downloading version ${GREEN}$LATEST_VERSION${NC} from $DOWNLOAD_URL..."
TMP_TARBALL="/tmp/$TARBALL_NAME"

# Download with curl
if ! curl -f -L --progress-bar "$DOWNLOAD_URL" -o "$TMP_TARBALL"; then
    echo -e "${RED}Error: Download failed! Please check your network connection or verify the release asset is uploaded.${NC}"
    exit 1
fi

echo -e "  - Extracting to $LIBEXEC_DIR..."
# Clean old installation binaries first
rm -rf "$LIBEXEC_DIR"/*

# Extract tarball.
# The tarball contains a folder named "forenyx", inside which has all the files.
if ! tar -xzf "$TMP_TARBALL" -C /tmp/; then
    echo -e "${RED}Error: Failed to extract installation archive.${NC}"
    rm -f "$TMP_TARBALL"
    exit 1
fi

# Move contents to ~/.forenyx/libexec/
if ! cp -rf /tmp/forenyx/* "$LIBEXEC_DIR/"; then
    echo -e "${RED}Error: Failed to copy binaries to installation folder.${NC}"
    rm -rf /tmp/forenyx "$TMP_TARBALL"
    exit 1
fi
rm -rf /tmp/forenyx "$TMP_TARBALL"

# Deploy Builtin Skills
# Built-in skills ship as an encrypted blob (skills.pack) that stays alongside the
# binary in $LIBEXEC_DIR; the CLI decrypts it to a temp dir at runtime. We no longer
# extract browsable plaintext skills into ~/.forenyx/agent/skills/builtin.
echo -e "  - Installing encrypted built-in skills..."
# Remove any legacy plaintext built-in skills from previous versions.
rm -rf "$AGENT_DIR/skills/builtin"
# Drop a stray plaintext skills/ dir if an older tarball shipped one.
rm -rf "$BIN_DIR/skills"
rm -rf "$LIBEXEC_DIR/skills"
# Initialize Global Env Config
GLOBAL_ENV_FILE="$FORENYX_DIR/.env"
if [ ! -f "$GLOBAL_ENV_FILE" ]; then
    echo -e "  - Initializing global user configuration file ~/.forenyx/.env..."
    cat << 'EOF' > "$GLOBAL_ENV_FILE"
# =============================================================================
# Forenyx AI Global Configurations (.env)
# =============================================================================
OPENAI_API_KEY="YOUR-API-KEY"
OPENAI_API_BASE="https://api.siliconflow.cn"
ARK_MODEL_NAME='Qwen/Qwen3.5-397B-A17B'
MAX_OUTPUT_TOKENS=32768
TEMPERATURE=0.1
EOF
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
LIBEXEC_DIR="$FORENYX_DIR/libexec"
AGENT_DIR="$FORENYX_DIR/agent"

## Command interceptors
case "$1" in
    --version|-v)
        if [ -f "$LIBEXEC_DIR/package.json" ]; then
            CURRENT_VERSION=$(grep -A 3 '"piConfig"' "$LIBEXEC_DIR/package.json" | grep '"version"' | cut -d'"' -f4)
        else
            CURRENT_VERSION="unknown"
        fi
        
        RELEASES_REPO="HwJhx/forenyx-releases"
        VERSION_URL="https://raw.githubusercontent.com/$RELEASES_REPO/main/version.json"
        
        echo -e "forenyx $CURRENT_VERSION (based on pi v0.79.10)"
        
        # Check remote version with a tight 2s connect timeout so offline systems don't block
        VERSION_DATA=$(curl -fsSL --connect-timeout 2 --max-time 3 "$VERSION_URL" 2>/dev/null || echo "")
        
        if [ -n "$VERSION_DATA" ]; then
            LATEST_VERSION=$(echo "$VERSION_DATA" | grep '"version"' | head -n 1 | cut -d'"' -f4)
            CUR_VER_CLEAN=$(echo "$CURRENT_VERSION" | tr -d 'v[:space:]')
            LAT_VER_CLEAN=$(echo "$LATEST_VERSION" | tr -d 'v[:space:]')
            
            if [ "$CUR_VER_CLEAN" = "$LAT_VER_CLEAN" ]; then
                echo -e "\033[1;92m✓ You are already on the latest version.\033[0m"
            else
                echo -e "\033[0;33m⚠️ New version \033[1;92m$LATEST_VERSION\033[0;33m is available. Run \033[1;36mforenyx update\033[0;33m to upgrade.\033[0m"
            fi
        else
            echo -e "\033[0;90mNote: Failed to connect to the update server. Skipping update check.\033[0m"
        fi
        exit 0
        ;;
    update)
        echo -e "\033[0;36m=====================================================\033[0m"
        echo -e "\033[0;36m\033[1m           Updating Forenyx AI Client                \033[0m"
        echo -e "\033[0;36m=====================================================\033[0m"
        
        RELEASES_REPO="HwJhx/forenyx-releases"
        VERSION_URL="https://raw.githubusercontent.com/$RELEASES_REPO/main/version.json"
        
        VERSION_DATA=$(curl -fsSL --connect-timeout 5 "$VERSION_URL" || echo "")
        if [ -z "$VERSION_DATA" ]; then
            echo -e "\033[0;31mError: Failed to fetch version info from $VERSION_URL\033[0m"
            exit 1
        fi
        
        LATEST_VERSION=$(echo "$VERSION_DATA" | grep '"version"' | head -n 1 | cut -d'"' -f4)
        if [ -z "$LATEST_VERSION" ]; then
            echo -e "\033[0;31mError: Could not parse version from version.json\033[0m"
            exit 1
        fi
        
        # Check current version and skip if it's already the latest
        if [ -f "$LIBEXEC_DIR/package.json" ]; then
            CURRENT_VERSION=$(grep -A 3 '"piConfig"' "$LIBEXEC_DIR/package.json" | grep '"version"' | cut -d'"' -f4)
        else
            CURRENT_VERSION="unknown"
        fi
        
        CUR_VER_CLEAN=$(echo "$CURRENT_VERSION" | tr -d 'v[:space:]')
        LAT_VER_CLEAN=$(echo "$LATEST_VERSION" | tr -d 'v[:space:]')
        
        if [ "$CUR_VER_CLEAN" = "$LAT_VER_CLEAN" ]; then
            echo -e "\033[1;92m✓ You are already on the latest version ($CURRENT_VERSION). No update required.\033[0m"
            exit 0
        fi
        
        # Divergence detected: fetch and execute the latest install script to achieve a full self-update securely.
        echo -e "New version \033[1;32m$LATEST_VERSION\033[0m is available. Pulling the installer..."
        if ! curl -fsSL --connect-timeout 5 "https://raw.githubusercontent.com/$RELEASES_REPO/main/install.sh" | bash; then
            echo -e "\033[0;31mError: Update failed during execution of the remote install script.\033[0m"
            exit 1
        fi
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
            rm -rf "$BIN_DIR" "$LIBEXEC_DIR"
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
export PI_PACKAGE_DIR="$LIBEXEC_DIR"
exec "$LIBEXEC_DIR/forenyx-cli" "$@"
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
