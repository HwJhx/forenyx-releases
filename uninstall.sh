#!/bin/bash

# =============================================================================
# Forenyx AI Uninstaller (Commercial Closed-Source Version)
# =============================================================================
# Supported OS: macOS, Linux
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

echo -e "${RED}${BOLD}=====================================================${NC}"
echo -e "${RED}${BOLD}          Uninstalling Forenyx AI (Forenyx)          ${NC}"
echo -e "${RED}${BOLD}=====================================================${NC}"

FORENYX_DIR="$HOME/.forenyx"
BIN_DIR="$FORENYX_DIR/bin"
LIBEXEC_DIR="$FORENYX_DIR/libexec"

if [ ! -d "$FORENYX_DIR" ]; then
    echo -e "${YELLOW}Forenyx AI is not installed (~/.forenyx directory not found).${NC}"
    exit 0
fi

# Ask if user wants to keep custom skills and configurations
echo -e "${YELLOW}Would you like to keep your custom skills and configuration data?${NC}"
echo -e "  Skills path: ~/.forenyx/agent/skills/custom/"
echo -e "  Configurations path: ~/.forenyx/agent/ (settings.json, auth.json, sessions/)"
echo -en "Keep these files? (y/n, default: y): "
read -r KEEP_DATA
KEEP_DATA=${KEEP_DATA:-y}

if [ "$KEEP_DATA" = "y" ] || [ "$KEEP_DATA" = "Y" ]; then
    echo -e "${BLUE}Keeping configurations and skills. Cleaning binaries...${NC}"
    rm -rf "$BIN_DIR" "$LIBEXEC_DIR"
    echo -e "  - Cleared binaries and wrappers."
else
    echo -e "${RED}Completely deleting all Forenyx AI data...${NC}"
    rm -rf "$FORENYX_DIR"
    echo -e "  - Cleared ~/.forenyx/ directory."
fi

# Cleanup PATH in shell profile
echo -e "${BLUE}Cleaning up PATH environment variables...${NC}"
SHELL_NAME=$(basename "$SHELL")
RC_FILE=""

case "$SHELL_NAME" in
    zsh)
        RC_FILE="$HOME/.zshrc"
        ;;
    bash)
        if [ -f "$HOME/.bash_profile" ]; then
            RC_FILE="$HOME/.bash_profile"
        else
            RC_FILE="$HOME/.bashrc"
        fi
        ;;
    csh|tcsh)
        if [ -f "$HOME/.tcshrc" ]; then
            RC_FILE="$HOME/.tcshrc"
        else
            RC_FILE="$HOME/.cshrc"
        fi
        ;;
    *)
        RC_FILE="$HOME/.bashrc"
        ;;
esac

if [ -f "$RC_FILE" ]; then
    if grep -q "forenyx/bin" "$RC_FILE"; then
        TEMP_RC=$(mktemp)
        grep -v "forenyx/bin" "$RC_FILE" | grep -v "# Forenyx AI CLI PATH configuration" > "$TEMP_RC"
        cat "$TEMP_RC" > "$RC_FILE"
        rm -f "$TEMP_RC"
        echo -e "  - Removed PATH configuration from $RC_FILE."
    else
        echo -e "  - No Forenyx AI PATH configuration found in $RC_FILE."
    fi
else
    echo -e "  - Shell config file $RC_FILE not found."
fi

echo -e "${GREEN}${BOLD}=====================================================${NC}"
echo -e "${GREEN}${BOLD}      Forenyx AI has been successfully uninstalled!   ${NC}"
echo -e "${GREEN}${BOLD}=====================================================${NC}"
echo -e "Please run the following to refresh your current terminal environment:"
echo -e "  ${CYAN}${BOLD}source $RC_FILE${NC}"
echo -e "====================================================="
