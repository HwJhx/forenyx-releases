#!/bin/bash

# =============================================================================
# Forenyx AI Uninstaller (Commercial Closed-Source Version)
# =============================================================================
# Supported OS: macOS, Linux
#
# 本脚本与 install-release.sh 一一对应：安装脚本头上写死装哪个智能体，卸载脚本
# 就写死卸哪个。派生新智能体时两个脚本一起改 AGENT_NAME。
#
# 目录分两层：
#   ~/.forenyx/                机器级——授权文件与心跳缓存，所有智能体共用
#   ~/.forenyx/<AGENT_NAME>/   本智能体——bin/ libexec/ agent/
#
# 所以卸载只动自己那一层。机器级的授权**不跟着删**——删了本机其余智能体会全部
# 启动不了，报的还是"授权校验失败"，现场根本联想不到是卸别人时删的。只有在本机
# 确实一个智能体都不剩时，才问一句要不要清。
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

AGENT_NAME="fnx_dv"
FORENYX_ROOT="$HOME/.forenyx"
AGENT_HOME="$FORENYX_ROOT/$AGENT_NAME"
BIN_DIR="$AGENT_HOME/bin"
LIBEXEC_DIR="$AGENT_HOME/libexec"

# 交互输入统一走这里。`curl … | bash` 时 stdin 是脚本自己，直接 read 会把脚本
# 正文读进变量，所以优先用 /dev/tty；没有 tty 的场合（CI、容器）退回 stdin。
ask() {
    local __var="$1" __prompt="$2" __reply=""
    if [ -c /dev/tty ] && { : < /dev/tty; } 2>/dev/null; then
        printf "%b" "$__prompt" > /dev/tty
        IFS= read -r __reply < /dev/tty || __reply=""
    else
        printf "%b" "$__prompt"
        IFS= read -r __reply || __reply=""
    fi
    printf -v "$__var" '%s' "$__reply"
}

echo -e "${RED}${BOLD}=====================================================${NC}"
echo -e "${RED}${BOLD}      Uninstalling Forenyx AI — ${AGENT_NAME}${NC}"
echo -e "${RED}${BOLD}=====================================================${NC}"

if [ ! -d "$AGENT_HOME" ]; then
    echo -e "${YELLOW}$AGENT_NAME is not installed (~/.forenyx/$AGENT_NAME not found).${NC}"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. 删除本智能体
# ---------------------------------------------------------------------------
echo -e "${YELLOW}Would you like to keep your custom skills and configuration data?${NC}"
echo -e "  Skills path:         ~/.forenyx/$AGENT_NAME/agent/skills/custom/"
echo -e "  Configurations path: ~/.forenyx/$AGENT_NAME/agent/ (settings.json, auth.json, sessions/)"
ask KEEP_DATA "Keep these files? (y/n, default: y): "
KEEP_DATA=${KEEP_DATA:-y}

if [ "$KEEP_DATA" = "y" ] || [ "$KEEP_DATA" = "Y" ]; then
    echo -e "${BLUE}Keeping configurations and skills. Cleaning binaries...${NC}"
    rm -rf "$BIN_DIR" "$LIBEXEC_DIR"
    echo -e "  - Cleared binaries and wrappers (kept ~/.forenyx/$AGENT_NAME/agent/)."
else
    echo -e "${RED}Deleting all $AGENT_NAME data...${NC}"
    rm -rf "$AGENT_HOME"
    echo -e "  - Cleared ~/.forenyx/$AGENT_NAME/."
fi

# ---------------------------------------------------------------------------
# 2. 清 PATH —— 只清本智能体那一行
# ---------------------------------------------------------------------------
echo -e "${BLUE}Cleaning up PATH environment variables...${NC}"
SHELL_NAME=$(basename "$SHELL")
case "$SHELL_NAME" in
    zsh)      RC_FILE="$HOME/.zshrc" ;;
    bash)     [ -f "$HOME/.bash_profile" ] && RC_FILE="$HOME/.bash_profile" || RC_FILE="$HOME/.bashrc" ;;
    csh|tcsh) [ -f "$HOME/.tcshrc" ] && RC_FILE="$HOME/.tcshrc" || RC_FILE="$HOME/.cshrc" ;;
    *)        RC_FILE="$HOME/.bashrc" ;;
esac

# 匹配必须带上智能体名。原先匹配 "forenyx/bin"，多智能体下会把同机其它智能体的
# PATH 一并删掉——卸一个，剩下的全都调不起来。
PATH_PAT="forenyx/$AGENT_NAME/bin"
if [ -f "$RC_FILE" ] && grep -q "$PATH_PAT" "$RC_FILE"; then
    TEMP_RC=$(mktemp)
    # `grep -v` 过滤后一行不剩时返回 1，在 set -e 下会掐断脚本（rc 文件里只有这
    # 两行时就会发生），故显式 || true。
    grep -v "$PATH_PAT" "$RC_FILE" \
        | grep -v "# Forenyx AI CLI PATH configuration ($AGENT_NAME)" > "$TEMP_RC" || true
    cat "$TEMP_RC" > "$RC_FILE"
    rm -f "$TEMP_RC"
    echo -e "  - Removed $AGENT_NAME PATH configuration from $RC_FILE."
else
    echo -e "  - No $AGENT_NAME PATH configuration found in $RC_FILE."
fi

# ---------------------------------------------------------------------------
# 3. 机器级授权：只在本机再没有智能体时才问
# ---------------------------------------------------------------------------
# 判据用 libexec/ 而不是目录名：保留数据卸载会留下 agent/，那不算还装着；
# 用户自己在 ~/.forenyx/ 下建的杂物也不该被当成智能体。
REMAINING=0
for d in "$FORENYX_ROOT"/*/; do
    if [ -d "${d}libexec" ]; then
        REMAINING=$((REMAINING + 1))
    fi
done

if [ "$REMAINING" -gt 0 ]; then
    echo -e "  - 本机还有 $REMAINING 个智能体，保留共用的 ~/.forenyx/forenyx.lic 与 .env。"
elif [ -f "$FORENYX_ROOT/forenyx.lic" ] || [ -f "$FORENYX_ROOT/.env" ]; then
    echo -e "${YELLOW}本机已无其它智能体。是否一并删除授权文件与授权配置？${NC}"
    echo -e "  ~/.forenyx/forenyx.lic, ~/.forenyx/.env"
    echo -e "${YELLOW}  删除后重装需要重新激活；内网机器需要重新向管理员申请 .lic。${NC}"
    ask DEL_LIC "Delete license data? (y/n, default: n): "
    if [ "$DEL_LIC" = "y" ] || [ "$DEL_LIC" = "Y" ]; then
        rm -f "$FORENYX_ROOT/forenyx.lic" "$FORENYX_ROOT/.env" \
              "$FORENYX_ROOT/.heartbeat_cache" "$FORENYX_ROOT/.offline_runs" \
              "$FORENYX_ROOT/.license_state"
        echo -e "  - Cleared license data."
        rmdir "$FORENYX_ROOT" 2>/dev/null && echo -e "  - Removed empty ~/.forenyx/." || true
    else
        echo -e "  - Kept license data."
    fi
fi

echo -e "${GREEN}${BOLD}=====================================================${NC}"
echo -e "${GREEN}${BOLD}      $AGENT_NAME has been successfully uninstalled!${NC}"
echo -e "${GREEN}${BOLD}=====================================================${NC}"
echo -e "Please run the following to refresh your current terminal environment:"
echo -e "  ${CYAN}${BOLD}source $RC_FILE${NC}"
echo -e "====================================================="
