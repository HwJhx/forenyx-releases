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

# Reset terminal colors on exit to prevent terminal color pollution
trap 'echo -ne "${NC}"' EXIT

# >>> HOSTID_FN_BEGIN
# 本段由 scripts/gen-hostid-tool.sh 原样提取，生成独立的 dist/forenyx-hostid.sh。
# 客户在安装前运行那个脚本取得 client_id，报给发码台换取 .lic —— 两处必须算出
# 完全一致的值，否则会出现"签发时报的 ID ≠ 安装后写入 .env 的 ID"，导致 .lic
# 永远验不过且现场极难定位。因此本函数必须保持自包含：只用标准命令，不引用本
# 脚本里的任何其他变量或函数。**勿删标记行。**
get_machine_id() {
    local machine_id=""
    if [ "$(uname)" = "Darwin" ]; then
        # 必须用 -F'"' 分割。ioreg 的输出形如
        #     "IOPlatformUUID" = "1DEACBBD-B4AB-55FD-B6FD-800E3B7F640C"
        # 默认空白分隔时 $4 是空的（$3 才是带引号的 UUID），此前一直取空值、
        # 每次都白白落到下面的 system_profiler 兜底——慢约 1 秒且会打诊断信息。
        # 两条路径取到的是同一个 UUID，故本修复不改变任何已有的 client_id。
        machine_id=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/ {print $4}' || echo "")
        if [ -z "$machine_id" ]; then
            # 2>/dev/null 必须加在 system_profiler 上而不是 awk 上，否则它的
            # 诊断信息会漏到 stderr，污染 forenyx-hostid.sh 的输出
            machine_id=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/UUID/ {print $3}' || echo "")
        fi
    else
        if [ -f /etc/machine-id ]; then
            machine_id=$(cat /etc/machine-id 2>/dev/null || echo "")
        elif [ -f /var/lib/dbus/machine-id ]; then
            machine_id=$(cat /var/lib/dbus/machine-id 2>/dev/null || echo "")
        fi
        if [ -z "$machine_id" ]; then
            local mac_addr=$(cat /sys/class/net/*/address | grep -v '00:00:00:00:00:00' | head -n 1 2>/dev/null || echo "")
            if [ -n "$mac_addr" ]; then
                machine_id=$(echo "$mac_addr" | md5sum | awk '{print $1}' 2>/dev/null || echo "")
            fi
        fi
    fi
    
    # 加上当前登录的 Linux 用户名，进行跨平台 MD5 联合哈希，精细化锁定到具体账户
    local combined_raw="${machine_id}:${USER}"
    local hashed_id=""
    if command -v md5sum >/dev/null 2>&1; then
        hashed_id=$(echo -n "$combined_raw" | md5sum | awk '{print $1}')
    elif command -v md5 >/dev/null 2>&1; then
        hashed_id=$(echo -n "$combined_raw" | md5)
    else
        hashed_id=$(echo -n "$combined_raw" | base64 | tr -d '=+/' | cut -c1-32)
    fi
    echo "$hashed_id" | tr -d '[:space:]'
}
# <<< HOSTID_FN_END

# --print-client-id：只算不装，打印 client_id 后退出。
# 供两处使用：① 与 forenyx-hostid.sh 做一致性断言（防止两边算法漂移）；
# ② 已安装的机器上自查当前指纹。放在参数解析之前，避免走完整个安装流程。
if [ "${1:-}" = "--print-client-id" ]; then
    # 必须先摘掉退出时重置颜色的 trap（见文件开头），否则输出末尾会多一个
    # \033[0m，让调用方的字符串比对失败——一致性断言正是这么误报过 DRIFT 的。
    trap - EXIT
    get_machine_id
    exit 0
fi

USER_LICENSE=""
# Parse command line options
# 离线模式：从本地离线包安装，全程不联网。
# BUNDLE_DIR 默认取本脚本所在目录 —— 离线包里脚本和 tarball 是并排放的，
# 客户解开包后直接 ./install-release.sh --offline 即可，不必再指定路径。
OFFLINE_MODE=0
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --license)
            USER_LICENSE="$2"
            shift 2
            ;;
        --offline)
            OFFLINE_MODE=1
            shift
            ;;
        --bundle)
            BUNDLE_DIR="$2"
            OFFLINE_MODE=1
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# 本仓库构建的智能体。定义必须早于任何用到它的输出——横幅在前、定义在后会打出
# "Forenyx AI — "（名字是空的），而且 shell 不会报错。
AGENT_NAME="fnx_dv"

echo -e "${CYAN}${BOLD}=====================================================${NC}"
echo -e "${CYAN}${BOLD}        Installing Forenyx AI — ${AGENT_NAME}${NC}"
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
# 目录分两层。
#
# `~/.forenyx/` 是**机器级**的：授权文件、心跳缓存、client_id 都放这里，规划中的
# 五个智能体（fnx_spec / fnx_arch / fnx_rtl / fnx_dv / fnx_sw）共用同一张授权、
# 同一次心跳。这不只是省事——每个智能体各自心跳的话，服务端会把一台机器看成
# 五个客户端，席位审计和吊销判定都会错。
#
# 而且这几个路径在 license-guard.ts 里是写死的（`join(homedir(), ".forenyx")`，
# 没有环境变量开关），搬下去授权直接失效。
#
# `~/.forenyx/<智能体名>/` 才是单个智能体自己的：程序本体、wrapper、用户数据。
# 派生新智能体只需要改 AGENT_NAME 一处。
# 本仓库构建的智能体。**必须与 packages/coding-agent/package.json 的
# piConfig.agentName 一致** —— 那是二进制自带的身份，横幅与 --version 从它来；
# 这里的值定目录名、命令名与 PATH。安装脚本在下载解包之前就要用它定目录，
# 没法反过来从 package.json 读，所以两处都写、装完再校验（见第 4 步之后）。
FORENYX_ROOT="$HOME/.forenyx"
FORENYX_DIR="$FORENYX_ROOT/$AGENT_NAME"
BIN_DIR="$FORENYX_DIR/bin"
LIBEXEC_DIR="$FORENYX_DIR/libexec"
AGENT_DIR="$FORENYX_DIR/agent"

# 提前退出前把 stdin 读完再走。
#
# 本脚本常以 `curl … | bash -s --` 运行，此时 stdin 就是脚本正文本身。中途 exit
# 会让 bash 不再读，curl 写不完管道 → "curl: (23) Failed writing body"。那行噪音
# 出现在我们自己打印的说明下面，看起来像真出了错，会盖过真正要看的提示。
#
# `[ -t 0 ]` 是必需的：直接 `bash install.sh` 跑时 stdin 是终端，无脑 cat 会挂住。
abort() {
    [ -t 0 ] || cat >/dev/null 2>&1 || true
    exit "${1:-1}"
}

# ---------------------------------------------------------------------------
# 旧版布局拦截
#
# v0.4.1 及更早把单个智能体直接摊在 ~/.forenyx 下（bin/ libexec/ agent/）。
# 新版每个智能体一个子目录，两者并存会出事而且**不会报错**：
#   · 老的 forenyx 命令原地不动，版本永远停在旧值 → 每次 update 都说"有新版本"
#     并重装一遍，无限循环；
#   · 用户的 auth.json / sessions 留在老 agent/ 里，新智能体读不到，要重新登录；
#   · .bashrc 里两条 PATH 并存。
#
# 所以宁可停下来让人处理，也不要装出这么一摊。这不是临时迁移垫片——以后任何
# 版本装到老布局上都该拦。
# ---------------------------------------------------------------------------
if [ -d "$FORENYX_ROOT/libexec" ] && [ ! -d "$FORENYX_DIR/libexec" ]; then
    echo -e "${RED}❌ 检测到旧版目录布局：$FORENYX_ROOT/libexec${NC}"
    echo -e "${YELLOW}   新版把每个智能体装进 ~/.forenyx/<智能体名>/，与旧布局不能并存。${NC}"
    echo
    echo -e "   请先清理旧版："
    echo -e "     ${CYAN}${AGENT_NAME} uninstall${NC}   （选择不保留数据，或按下面手工清）"
    echo -e "   手工清理："
    echo -e "     ${CYAN}rm -rf ~/.forenyx/bin ~/.forenyx/libexec${NC}"
    echo -e "     然后删掉 ~/.bashrc（或 .zshrc）里这一行："
    echo -e "     ${CYAN}export PATH=\"\$HOME/.forenyx/bin:\$PATH\"${NC}"
    echo
    echo -e "${YELLOW}   旧版的用户数据在 ~/.forenyx/agent/，新版不会自动搬。${NC}"
    echo -e "   需要保留 API key 与会话历史的话，清理完再执行一次本脚本，装好后："
    echo -e "     ${CYAN}cp -r ~/.forenyx/agent/. ~/.forenyx/$AGENT_NAME/agent/${NC}"
    echo
    echo -e "${YELLOW}   授权文件 ~/.forenyx/forenyx.lic 与 .env 不用动，新版仍然用它们。${NC}"
    abort 1
fi

mkdir -p "$FORENYX_ROOT"
mkdir -p "$FORENYX_DIR"
mkdir -p "$BIN_DIR"
mkdir -p "$LIBEXEC_DIR"
# Built-in skills are shipped as an encrypted blob (skills.pack), not plaintext.
# Only the user's own custom skills live under agent/skills.
mkdir -p "$AGENT_DIR/skills/custom"

# 3. Download and Extract Binary Package
if [ "$OFFLINE_MODE" = "1" ]; then
    echo -e "${BLUE}[3/5] Installing from offline bundle...${NC}"
else
    echo -e "${BLUE}[3/5] Downloading pre-compiled binaries...${NC}"
fi

# Fetch version config to download the target release
RELEASES_REPO="HwJhx/forenyx-releases"

# ---------------------------------------------------------------------------
# 离线安装：跳过全部联网步骤（授权校验、版本查询、下载），改用本地离线包。
#
# 分成两条完全不相交的路径而不是在原路径上打补丁，是因为在线路径里有一段
# 105 秒的退避重试（15+30+60），离线环境下它必然全部走完才失败，而且提示是
# "授权服务正在唤醒中" —— 对着一台根本没有网的机器说这句话只会把人带偏。
# ---------------------------------------------------------------------------
if [ "$OFFLINE_MODE" = "1" ]; then
    TMP_TARBALL="$BUNDLE_DIR/forenyx-$PLATFORM.tar.gz"

    if [ ! -f "$TMP_TARBALL" ]; then
        echo -e "${RED}❌ 错误: 离线包中未找到 forenyx-$PLATFORM.tar.gz${NC}"
        echo -e "${YELLOW}ℹ 查找目录: $BUNDLE_DIR${NC}"
        echo -e "  本机架构为 ${CYAN}$PLATFORM${NC}，请确认拿到的是对应平台的离线包。"
        echo -e "  离线包内已有的文件："
        ls -1 "$BUNDLE_DIR"/forenyx-*.tar.gz 2>/dev/null | sed 's|.*/|    - |' || echo "    (无)"
        exit 1
    fi

    # 校验和用于发现传输损坏（U 盘、内网中转都可能出错）。
    # 它不防篡改 —— SHA256SUMS 和包在一起，能改包的人也能改它。
    if [ -f "$BUNDLE_DIR/SHA256SUMS" ]; then
        echo -e "  - Verifying package integrity..."
        SUM_CMD=""
        if command -v sha256sum >/dev/null 2>&1; then
            SUM_CMD="sha256sum"
        elif command -v shasum >/dev/null 2>&1; then
            SUM_CMD="shasum -a 256"
        fi
        if [ -n "$SUM_CMD" ]; then
            EXPECTED=$(grep "forenyx-$PLATFORM.tar.gz" "$BUNDLE_DIR/SHA256SUMS" | awk '{print $1}')
            ACTUAL=$($SUM_CMD "$TMP_TARBALL" | awk '{print $1}')
            if [ -n "$EXPECTED" ] && [ "$EXPECTED" != "$ACTUAL" ]; then
                echo -e "${RED}❌ 错误: 离线包校验失败，文件可能在传输中损坏。${NC}"
                echo -e "  期望: $EXPECTED"
                echo -e "  实际: $ACTUAL"
                exit 1
            fi
            echo -e "  - ${GREEN}✓ 校验通过${NC}"
        else
            echo -e "${YELLOW}  - 未找到 sha256sum/shasum，跳过完整性校验${NC}"
        fi
    fi

    CLIENT_ID=$(get_machine_id)
    if [ -z "$CLIENT_ID" ]; then
        CLIENT_ID="unknown-client"
    fi
    # 离线部署必须带真实授权码。
    #
    # 早先这里默认写占位符 OFFLINE，因为当时离线机器完全不发心跳，占位符无人过问。
    # 现在离线也走同一条校验流程（只是超时更短），一旦机器哪天接通外网，服务端
    # 查无此码就会返回 403 —— 把装得好好的机器判成无权使用。
    #
    # 这条不增加客户负担：签发 .lic 本来就需要一个真实授权码，客户手上一定有。
    if [ -z "$USER_LICENSE" ]; then
        echo -e "${RED}❌ 离线安装必须提供授权码${NC}"
        echo -e "${YELLOW}   用法: $0 --offline --bundle <离线包目录> --license FNX-XXXX-XXXX-XXXX${NC}"
        echo -e "   授权码就是当初换取 forenyx.lic 时用的那一个。"
        exit 1
    fi
    EXPIRE_DISPLAY=""

    echo -e "  - Extracting to $LIBEXEC_DIR..."
    rm -rf "$LIBEXEC_DIR"/*
    rm -rf /tmp/forenyx
    if ! tar -xzf "$TMP_TARBALL" -C /tmp/; then
        echo -e "${RED}Error: Failed to extract installation archive.${NC}"
        exit 1
    fi
    if ! cp -rf /tmp/forenyx/* "$LIBEXEC_DIR/"; then
        echo -e "${RED}Error: Failed to copy binaries to installation folder.${NC}"
        rm -rf /tmp/forenyx
        exit 1
    fi
    # 只清理解包出来的临时目录。TMP_TARBALL 此时指向离线包自身，
    # 删掉的话客户就没法重装或回滚了。
    rm -rf /tmp/forenyx

    # fd / ripgrep 装到 CLI 查找工具的第一顺位目录（getBinDir() = $AGENT_DIR/bin）。
    # 缺了它们不是功能降级 —— find 和 grep 两个工具会直接报错，agent 基本不可用。
    # 在线安装时 CLI 自己从 GitHub 下载，离线只能随包带。
    TOOLS_SRC="$BUNDLE_DIR/tools/$PLATFORM"
    if [ -d "$TOOLS_SRC" ]; then
        echo -e "  - Installing bundled tools (fd, rg) to $AGENT_DIR/bin..."
        mkdir -p "$AGENT_DIR/bin"
        for t in fd rg; do
            if [ -f "$TOOLS_SRC/$t" ]; then
                cp -f "$TOOLS_SRC/$t" "$AGENT_DIR/bin/$t"
                chmod +x "$AGENT_DIR/bin/$t"
            else
                echo -e "${YELLOW}  - 警告: 离线包中缺少 $t，文件查找/文本搜索功能将不可用${NC}"
            fi
        done
    else
        echo -e "${YELLOW}  - 警告: 离线包中未包含 $PLATFORM 的 fd/rg${NC}"
        echo -e "${YELLOW}    该包由旧版打包脚本生成。请用新版 make-offline-bundle.sh 重新打包，${NC}"
        echo -e "${YELLOW}    否则 ${AGENT_NAME} 的文件查找与文本搜索功能会报错。${NC}"
    fi

    # ---- hostid 采集工具 ----
    # 客户端在缺少授权文件时会提示"运行安装目录下的 forenyx-hostid.sh"，
    # 所以它必须真的在那儿。离线包里带了一份，装进去即可。
    if [ -f "$BUNDLE_DIR/forenyx-hostid.sh" ]; then
        cp -f "$BUNDLE_DIR/forenyx-hostid.sh" "$FORENYX_ROOT/forenyx-hostid.sh"
        chmod +x "$FORENYX_ROOT/forenyx-hostid.sh"
    fi

    # ---- 授权文件 ----
    # 离线机器没有第二次机会：它连不上服务端，拿不到 .lic 就永远启动不了。
    # 在线分支可以"这次没拿到、下次心跳补上"，这里不行，所以缺失必须当场报错，
    # 而不是像在线那样静默跳过。
    #
    # 不校验签名 —— 私钥在服务端，安装脚本手里只有公钥能做的事，
    # 而验签本来就是客户端启动时要做的。这里只保证文件确实落到位。
    if [ -f "$BUNDLE_DIR/forenyx.lic" ]; then
        if cp -f "$BUNDLE_DIR/forenyx.lic" "$FORENYX_ROOT/forenyx.lic.tmp" \
           && chmod 600 "$FORENYX_ROOT/forenyx.lic.tmp" \
           && mv -f "$FORENYX_ROOT/forenyx.lic.tmp" "$FORENYX_ROOT/forenyx.lic"; then
            echo -e "  - ${GREEN}✓ 已安装授权文件 $FORENYX_ROOT/forenyx.lic${NC}"
        else
            rm -f "$FORENYX_ROOT/forenyx.lic.tmp"
            echo -e "${RED}❌ 授权文件写入失败: $FORENYX_ROOT/forenyx.lic${NC}"
            echo -e "${YELLOW}   请检查磁盘空间与目录权限后重装。离线机器缺少该文件将无法启动。${NC}"
            exit 1
        fi
    elif [ -f "$FORENYX_ROOT/forenyx.lic" ]; then
        # 重装/升级场景：包里没带，但机器上已经有一份（上次安装或心跳留下的）。
        # 保留它，别把能用的机器装成不能用的。
        echo -e "  - ${CYAN}ℹ 离线包未附带授权文件，沿用本机已有的 forenyx.lic${NC}"
    else
        echo -e "${YELLOW}⚠ 离线包内没有授权文件（forenyx.lic），本机也没有。${NC}"
        echo -e "${YELLOW}   安装可以完成，但 ${AGENT_NAME} 启动时会因缺少授权而退出。${NC}"
        echo -e "${YELLOW}   请把安装目录下 forenyx-hostid.sh 的输出发给管理员换取授权文件，${NC}"
        echo -e "${YELLOW}   拿到后放到 $FORENYX_ROOT/forenyx.lic（权限 600）即可。${NC}"
    fi
else

# License Verification
if [ -z "$USER_LICENSE" ] && [ -f "$FORENYX_ROOT/.env" ]; then
    USER_LICENSE=$(grep "^FORENYX_LICENSE_KEY=" "$FORENYX_ROOT/.env" | cut -d'=' -f2 | tr -d '[:space:]' | tr -d '"' | tr -d "'")
fi

if [ -z "$USER_LICENSE" ]; then
    if [ ! -t 0 ] && [ ! -c /dev/tty ]; then
        echo -e "${RED}❌ 错误: 本地未检测到已绑定的授权激活码（License Key）。${NC}"
        echo -e "${YELLOW}ℹ 提示: v0.3.1 引入了全新的商业授权校验机制。${NC}"
        echo -e "请在您的终端上手工重新运行以下命令以输入您的 License Key 进行首次激活绑定："
        echo -e "  ${CYAN}curl -fsSL https://raw.githubusercontent.com/$RELEASES_REPO/main/install.sh | bash${NC}"
        exit 1
    fi
    echo -e "${YELLOW}💬 请输入您的 Forenyx AI 商业授权激活码 (License Key):${NC}"
    read -rp "> " USER_LICENSE < /dev/tty
    USER_LICENSE=$(echo "$USER_LICENSE" | tr -d '[:space:]')
fi

if [ -z "$USER_LICENSE" ]; then
    echo -e "${RED}❌ 错误: 授权激活码不能为空！${NC}"
    exit 1
fi

LICENSE_SERVER="https://dsvtcqycopcyzuzkgikv.supabase.co/functions/v1/verify"
echo -e "  - 正在向授权服务器验证激活码，请稍候..."

CLIENT_ID=$(get_machine_id)
if [ -z "$CLIENT_ID" ]; then
    CLIENT_ID="unknown-client"
fi

# 授权服务跑在 Supabase 上，项目从休眠中唤醒需要约 1-2 分钟，期间网关会返回
# 503/504，数据库尚未就绪时 Edge Function 自身也会返回 500。这类都是临时故障，
# 自动退避重试即可，不该让用户看到崩溃或"请联系管理员"。
# 而 400/403 是真实的授权错误（激活码无效、设备指纹不符等），必须立即失败、不重试。
request_license_server() {
    local attempt=1
    local max_attempts=4
    local delay=15

    while :; do
        HTTP_CODE=$(curl -s -o "$RESP_BODY_FILE" -w "%{http_code}" \
          --max-time 30 \
          -X POST \
          -H "Content-Type: application/json" \
          -d "{\"license_number\":\"$USER_LICENSE\",\"platform\":\"$PLATFORM\",\"client_id\":\"$CLIENT_ID\",\"user_name\":\"$USER\"}" \
          "$LICENSE_SERVER" 2>/dev/null) || HTTP_CODE="000"

        case "$HTTP_CODE" in
            000|408|429|500|502|503|504)
                if [ "$attempt" -ge "$max_attempts" ]; then
                    return 1
                fi
                if [ "$attempt" -eq 1 ]; then
                    echo -e "${YELLOW}⏳ 授权服务正在唤醒中，${delay} 秒后自动重试... (${attempt}/${max_attempts})${NC}"
                else
                    echo -e "${YELLOW}⏳ 仍未就绪，${delay} 秒后重试... (${attempt}/${max_attempts})${NC}"
                fi
                sleep "$delay"
                attempt=$((attempt + 1))
                delay=$((delay * 2))
                ;;
            *)
                return 0
                ;;
        esac
    done
}

RESP_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/forenyx-license.XXXXXX")
HTTP_CODE="000"

if ! request_license_server; then
    rm -f "$RESP_BODY_FILE"
    echo ""
    if [ "$HTTP_CODE" = "000" ]; then
        echo -e "${RED}❌ 无法连接授权服务器。${NC}"
        echo -e "${YELLOW}ℹ 可能原因: 本地网络不通、DNS 解析失败或被代理拦截。${NC}"
        echo -e "  请检查网络后重新执行安装/更新命令。"
    else
        echo -e "${RED}❌ 授权服务暂时不可用（HTTP ${HTTP_CODE}）。${NC}"
        echo -e "${YELLOW}ℹ 这通常是服务正在唤醒，一般 1-2 分钟内自动恢复。${NC}"
        echo -e "  请稍候片刻后重新执行安装/更新命令即可，无需任何额外操作。"
    fi
    exit 1
fi

RESPONSE=$(cat "$RESP_BODY_FILE" 2>/dev/null || echo "")
rm -f "$RESP_BODY_FILE"

DOWNLOAD_URL=""
ERR_MSG=""
EXPIRE_DISPLAY=""

if [ -z "$RESPONSE" ]; then
    ERR_MSG="授权服务器返回了空响应（HTTP ${HTTP_CODE}），请稍后重试。"
else
    if command -v python3 >/dev/null 2>&1; then
        DOWNLOAD_URL=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('download_url', ''))" 2>/dev/null || echo "")
        ERR_MSG=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('error', ''))" 2>/dev/null || echo "")
        EXPIRE_DISPLAY=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('expires_at', ''))" 2>/dev/null || echo "")
    else
        DOWNLOAD_URL=$(echo "$RESPONSE" | grep -o '"download_url":"[^"]*' | cut -d'"' -f4 || echo "")
        ERR_MSG=$(echo "$RESPONSE" | grep -o '"error":"[^"]*' | cut -d'"' -f4 || echo "")
        EXPIRE_DISPLAY=$(echo "$RESPONSE" | grep -o '"expires_at":"[^"]*' | cut -d'"' -f4 || echo "")
    fi
fi

if [ -n "$ERR_MSG" ] || [ -z "$DOWNLOAD_URL" ]; then
    [ -z "$ERR_MSG" ] && ERR_MSG="校验失败，无法签发下载链接（HTTP ${HTTP_CODE}）。请联系管理员。"
    echo -e "${RED}❌ 激活失败: $ERR_MSG${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# 落盘服务端随激活下发的签名授权文件 .lic
#
# 客户端断网期间凭它自证授权；没有它，切 enforce 后的版本一律拒绝启动。
#
# **为什么装的时候就要写，而不是等第一次心跳。** 若只靠心跳，客户刚装完、第一次
# 启动恰好撞上云端故障或网络抖动就拿不到 .lic，于是"付了钱、装成功了，却打不开"
# —— 而原因还在我们这边。激活这一步已经完成鉴权与绑定，顺手落一份即可关掉这个窗口。
#
# 三条：
#   1. **失败不阻断安装**。老版本服务端不返回该字段是正常情况（纯增量），
#      客户端也能靠后续心跳补上，为它中断安装得不偿失。
#   2. 权限 600 —— 与客户端 saveLicFile 一致，避免同机其他用户读写。
#   3. 无 python3 时跳过。用 grep 抠嵌套 JSON 太脆，宁可不写、留给心跳补。
# -----------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    if echo "$RESPONSE" | python3 -c "
import sys, json, os
d = json.load(sys.stdin)
f = d.get('license_file')
if not isinstance(f, dict):
    raise SystemExit(1)
path = os.path.expanduser('~/.forenyx/forenyx.lic')
tmp = path + '.tmp'
with open(tmp, 'w') as fh:
    json.dump(f, fh, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)          # 原子替换，避免读到半截文件
" 2>/dev/null; then
        echo -e "  - ${GREEN}✓ 已写入授权文件 ~/.forenyx/forenyx.lic${NC}"
    fi
fi

# 有效期信息拼进同一行，避免与下方提示重复成两行
if [ -n "$EXPIRE_DISPLAY" ]; then
    echo -e "  - ${GREEN}✓ 授权码验证成功！已换取专用下载链接。（有效期至：${EXPIRE_DISPLAY}）${NC}"
else
    echo -e "  - ${GREEN}✓ 授权码验证成功！已换取专用下载链接。${NC}"
fi

TARBALL_NAME="forenyx-$PLATFORM.tar.gz"
echo -e "  - Downloading binaries from $DOWNLOAD_URL..."
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

# Move contents to $LIBEXEC_DIR/
if ! cp -rf /tmp/forenyx/* "$LIBEXEC_DIR/"; then
    echo -e "${RED}Error: Failed to copy binaries to installation folder.${NC}"
    rm -rf /tmp/forenyx "$TMP_TARBALL"
    exit 1
fi
rm -rf /tmp/forenyx "$TMP_TARBALL"

fi  # end of online/offline branch

# Deploy Builtin Skills
# Built-in skills ship as an encrypted blob (skills.pack) that stays alongside the
# binary in $LIBEXEC_DIR; the CLI decrypts it to a temp dir at runtime. We no longer
# extract browsable plaintext skills into $AGENT_DIR/skills/builtin.
echo -e "  - Installing encrypted built-in skills..."
# Remove any legacy plaintext built-in skills from previous versions.
rm -rf "$AGENT_DIR/skills/builtin"
# Drop a stray plaintext skills/ dir if an older tarball shipped one.
rm -rf "$BIN_DIR/skills"
rm -rf "$LIBEXEC_DIR/skills"
# Initialize Global Env Config
GLOBAL_ENV_FILE="$FORENYX_ROOT/.env"
if [ ! -f "$GLOBAL_ENV_FILE" ]; then
    echo -e "  - Initializing global user configuration file ~/.forenyx/.env..."
    cat << EOF > "$GLOBAL_ENV_FILE"
# =============================================================================
# Forenyx AI Global Configurations (.env)
# =============================================================================
FORENYX_LICENSE_KEY=$USER_LICENSE
FORENYX_CLIENT_ID=$CLIENT_ID
OPENAI_API_KEY=
OPENAI_API_BASE="https://api.siliconflow.cn"
ARK_MODEL_NAME='Qwen/Qwen3.8-27B'
MAX_OUTPUT_TOKENS=32768
TEMPERATURE=0.1
EOF
else
    # 授权码：**存在也要覆盖**，不能只在缺失时写。
    #
    # 客户续费换新码后会重跑本脚本，激活（verify）用的是命令行传进来的新码、
    # 且服务端确实完成了绑定；但 .env 里若仍是旧码，客户端每次心跳都拿旧码去问，
    # 旧码已到期 → 直接被拒。表现是"刚续完费、装也装成功了，却打不开"，
    # 而错误信息指向授权到期，现场极难联想到是 .env 没更新。
    #
    # 早先写成"缺失才补"是为了不覆盖用户手工改过的其它配置——但那只该保护
    # OPENAI_API_KEY 之类，不该保护授权码：授权码的权威来源就是本次命令行入参。
    if grep -q "^FORENYX_LICENSE_KEY=" "$GLOBAL_ENV_FILE"; then
        OLD_LICENSE=$(grep "^FORENYX_LICENSE_KEY=" "$GLOBAL_ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d '[:space:]"'"'"'')
        if [ "$OLD_LICENSE" != "$USER_LICENSE" ]; then
            echo -e "  - 授权码已变更，更新 ~/.forenyx/.env（$OLD_LICENSE → $USER_LICENSE）"
            # 用 | 作分隔符：授权码不含 |，而 / 在某些环境变量值里会出现
            sed -i.bak "s|^FORENYX_LICENSE_KEY=.*|FORENYX_LICENSE_KEY=$USER_LICENSE|" "$GLOBAL_ENV_FILE" \
                && rm -f "$GLOBAL_ENV_FILE.bak"
        fi
    else
        echo -e "  - Saving license key to ~/.forenyx/.env..."
        echo "FORENYX_LICENSE_KEY=$USER_LICENSE" >> "$GLOBAL_ENV_FILE"
    fi

    # client_id 相反：**存在就绝不能改**。它在首次安装时算出并与服务端绑定，
    # 重算会得到不同的值（machine-id 或 $USER 变化都会），导致心跳 403「跨设备冒用」。
    if ! grep -q "^FORENYX_CLIENT_ID=" "$GLOBAL_ENV_FILE"; then
        echo "FORENYX_CLIENT_ID=$CLIENT_ID" >> "$GLOBAL_ENV_FILE"
    fi
fi

# wrapper 靠这个标记跳过版本检查与在线更新。离线机器上那些 curl 只会白等超时，
# 还会把"连不上更新服务器"这种正常状态报成异常。
if [ "$OFFLINE_MODE" = "1" ]; then
    if ! grep -q "^FORENYX_OFFLINE=" "$GLOBAL_ENV_FILE"; then
        echo "FORENYX_OFFLINE=1" >> "$GLOBAL_ENV_FILE"
    fi
else
    # 从离线转回在线安装时要清掉，否则更新功能会一直被禁用
    sed -i.bak '/^FORENYX_OFFLINE=/d' "$GLOBAL_ENV_FILE" 2>/dev/null || true
    rm -f "$GLOBAL_ENV_FILE.bak"
fi

# 校验：安装脚本写的 AGENT_NAME 与二进制自带的 piConfig.agentName 必须一致。
# 不一致的话，目录和命令叫 A、横幅和 --version 叫 B，排查时会非常费解。
BUILT_AGENT=$(sed -n '/"piConfig"[[:space:]]*:/,/}/p' "$LIBEXEC_DIR/package.json" 2>/dev/null \
    | grep '"agentName"[[:space:]]*:' | head -1 | cut -d'"' -f4)
if [ -n "$BUILT_AGENT" ] && [ "$BUILT_AGENT" != "$AGENT_NAME" ]; then
    echo -e "${RED}❌ 智能体名不一致：安装脚本写的是 '$AGENT_NAME'，"
    echo -e "   而下载到的二进制自带的是 '$BUILT_AGENT'。${NC}"
    echo -e "${YELLOW}   多半是装错了发布仓库，或两个仓库的版本没对齐。已中止，未改动 PATH。${NC}"
    abort 1
fi

# 4. Generate Forenyx CLI Shell Wrapper
echo -e "${BLUE}[4/5] Creating command wrapper...${NC}"
# 命令名与目录名同名（fnx_dv）。五个智能体各有自己的 bin/，若都叫 forenyx
# 就会在 PATH 里互相遮蔽——谁先在 PATH 里谁赢，而且看不出赢的是哪个。
WRAPPER_FILE="$BIN_DIR/$AGENT_NAME"

# 头几行要展开 $AGENT_NAME，故用未加引号的 heredoc；其余部分保持 'EOF'
# 引用，避免 wrapper 自己的变量在生成时就被求值。
cat << EOF > "$WRAPPER_FILE"
#!/bin/bash

# =============================================================================
# Forenyx AI Wrapper — 智能体 $AGENT_NAME
# =============================================================================

AGENT_NAME="$AGENT_NAME"
EOF

cat << 'EOF' >> "$WRAPPER_FILE"
# 机器级：授权文件与心跳缓存，所有智能体共用。license-guard.ts 里写死了这个
# 位置，不要改。
FORENYX_ROOT="$HOME/.forenyx"
# 本智能体自己的根
FORENYX_DIR="$FORENYX_ROOT/$AGENT_NAME"
BIN_DIR="$FORENYX_DIR/bin"
LIBEXEC_DIR="$FORENYX_DIR/libexec"
AGENT_DIR="$FORENYX_DIR/agent"

# 用户数据目录交给 CLI。不设这个变量的话 getAgentDir() 会退回写死的
# ~/.forenyx/agent，五个智能体的会话与设置就全挤在同一个目录里。
export FORENYX_CODING_AGENT_DIR="$AGENT_DIR"
# 启动横幅与 --version 要标出当前是哪个智能体。几个智能体共用同一套引擎、
# 版本号往往一样，只打产品名的话同时开两个终端分不出自己在哪个里面。
export FORENYX_AGENT_NAME="$AGENT_NAME"

# 从 libexec/package.json 的 piConfig 块里取一个字段。
#
# 原先用 `grep -A 3 '"piConfig"'` 取版本号——那是按"piConfig 正好 3 个字段"写死的，
# 往里加一个字段就可能把 version 挤出窗口，而且不会报错，只会安静地取到空值。
# 改成按 piConfig 的 { … } 范围取，字段数和顺序都不再相关。
piconfig_field() {
    [ -f "$LIBEXEC_DIR/package.json" ] || return 0
    sed -n '/"piConfig"[[:space:]]*:/,/}/p' "$LIBEXEC_DIR/package.json" \
        | grep "\"$1\"[[:space:]]*:" | head -1 | cut -d'"' -f4
}

# 产品展示名。唯一真源是 package.json 的 piConfig.displayName（CLI 侧读的也是它），
# 取不到才回退——别在这里写死，否则改名时这里会和横幅对不上。
APP_DISPLAY_NAME="$(piconfig_field displayName)"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-ForeNyx CLI}"

# 离线部署标记。由安装脚本 --offline 写入 .env，用于跳过所有联网检查。
IS_OFFLINE=0
if [ -f "$FORENYX_ROOT/.env" ] && grep -q "^FORENYX_OFFLINE=1" "$FORENYX_ROOT/.env" 2>/dev/null; then
    IS_OFFLINE=1
fi

## Command interceptors
case "$1" in
    --version|-v)
        if [ -f "$LIBEXEC_DIR/package.json" ]; then
            CURRENT_VERSION=$(piconfig_field version)
        else
            CURRENT_VERSION="unknown"
        fi

        RELEASES_REPO="HwJhx/forenyx-releases"
        VERSION_URL="https://raw.githubusercontent.com/$RELEASES_REPO/main/version.json"

        echo -e "$APP_DISPLAY_NAME · $AGENT_NAME $CURRENT_VERSION"

        if [ "$IS_OFFLINE" = "1" ]; then
            echo -e "\033[0;90m离线部署，跳过版本检查。\033[0m"
            exit 0
        fi

        # Check remote version with a tight 2s connect timeout so offline systems don't block
        VERSION_DATA=$(curl -fsSL --connect-timeout 2 --max-time 3 "$VERSION_URL" 2>/dev/null || echo "")
        
        if [ -n "$VERSION_DATA" ]; then
            LATEST_VERSION=$(echo "$VERSION_DATA" | grep '"version"' | head -n 1 | cut -d'"' -f4)
            CUR_VER_CLEAN=$(echo "$CURRENT_VERSION" | tr -d 'v[:space:]')
            LAT_VER_CLEAN=$(echo "$LATEST_VERSION" | tr -d 'v[:space:]')
            
            if [ "$CUR_VER_CLEAN" = "$LAT_VER_CLEAN" ]; then
                echo -e "\033[1;92m✓ You are already on the latest version.\033[0m"
            else
                echo -e "\033[0;33m⚠️ New version \033[1;92m$LATEST_VERSION\033[0;33m is available. Run \033[1;36m$AGENT_NAME update\033[0;33m to upgrade.\033[0m"
            fi
        else
            echo -e "\033[0;90mNote: Failed to connect to the update server. Skipping update check.\033[0m"
        fi
        exit 0
        ;;
    update)
        echo -e "\033[0;36m=====================================================\033[0m"
        echo -e "\033[0;36m\033[1m        Updating $APP_DISPLAY_NAME — $AGENT_NAME\033[0m"
        echo -e "\033[0;36m=====================================================\033[0m"

        if [ "$IS_OFFLINE" = "1" ]; then
            echo -e "\033[0;33m本机为离线部署，无法在线更新。\033[0m"
            echo -e "请向管理员索取新版离线安装包，解压后执行："
            echo -e "  \033[0;36m./install-release.sh --offline\033[0m"
            exit 0
        fi

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
            CURRENT_VERSION=$(piconfig_field version)
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
        
        # Load local license key if exists to perform silent upgrade
        LOCAL_LICENSE=""
        if [ -f "$FORENYX_ROOT/.env" ]; then
            LOCAL_LICENSE=$(grep "^FORENYX_LICENSE_KEY=" "$FORENYX_ROOT/.env" | cut -d'=' -f2 | tr -d '[:space:]' | tr -d '"' | tr -d "'")
        fi

        if ! curl -fsSL --connect-timeout 5 "https://raw.githubusercontent.com/$RELEASES_REPO/main/install.sh" | bash -s -- --license "$LOCAL_LICENSE"; then
            echo -e "\033[0;31mError: Update failed during execution of the remote install script.\033[0m"
            exit 1
        fi
        exit 0
        ;;
    uninstall)
        echo -e "\033[0;31m=====================================================\033[0m"
        echo -e "\033[0;31m\033[1m      Uninstalling $APP_DISPLAY_NAME — $AGENT_NAME\033[0m"
        echo -e "\033[0;31m=====================================================\033[0m"
        
        echo -e "  Uninstalling agent: \033[1m$AGENT_NAME\033[0m (~/.forenyx/$AGENT_NAME/)"
        echo -e "\033[0;33mWould you like to keep your custom skills and configuration data?\033[0m"
        echo -e "  Skills path: ~/.forenyx/$AGENT_NAME/agent/skills/custom/"
        echo -e "  Configurations path: ~/.forenyx/$AGENT_NAME/agent/ (settings.json, auth.json, sessions/)"
        echo -en "Keep these files? (y/n, default: y): "
        read -r KEEP_DATA
        KEEP_DATA=${KEEP_DATA:-y}
        
        if [ "$KEEP_DATA" = "y" ] || [ "$KEEP_DATA" = "Y" ]; then
            echo -e "\033[0;34mKeeping configurations and skills. Cleaning binaries...\033[0m"
            rm -rf "$BIN_DIR" "$LIBEXEC_DIR"
            echo -e "  - Cleared binaries and wrappers for $AGENT_NAME."
        else
            echo -e "\033[0;31mDeleting all data for agent $AGENT_NAME...\033[0m"
            rm -rf "$FORENYX_DIR"
            echo -e "  - Cleared ~/.forenyx/$AGENT_NAME/."
        fi

        # 授权是机器级的，几个智能体共用。卸掉一个就删掉它，剩下的全部启动不了；
        # 所以只在**本机已经没有别的智能体**时才提出删除，而且要人明确点头。
        REMAINING=0
        for d in "$FORENYX_ROOT"/*/; do
            if [ -d "${d}libexec" ]; then
                REMAINING=$((REMAINING + 1))
            fi
        done
        if [ "$REMAINING" -gt 0 ]; then
            echo -e "  - 本机还有 $REMAINING 个智能体，保留共用的授权文件 ~/.forenyx/forenyx.lic"
        elif [ -f "$FORENYX_ROOT/forenyx.lic" ] || [ -f "$FORENYX_ROOT/.env" ]; then
            echo -e "\033[0;33m本机已无其它智能体。是否一并删除授权文件与授权配置？\033[0m"
            echo -e "  ~/.forenyx/forenyx.lic, ~/.forenyx/.env"
            echo -e "  \033[0;33m删除后重装需要重新激活（内网机器需重新申请 .lic）。\033[0m"
            echo -en "Delete license data? (y/n, default: n): "
            read -r DEL_LIC
            if [ "$DEL_LIC" = "y" ] || [ "$DEL_LIC" = "Y" ]; then
                rm -f "$FORENYX_ROOT/forenyx.lic" "$FORENYX_ROOT/.env" \
                      "$FORENYX_ROOT/.heartbeat_cache" "$FORENYX_ROOT/.offline_runs"
                echo -e "  - Cleared license data."
            else
                echo -e "  - Kept license data."
            fi
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
        
        # 只删本智能体那一行。原先匹配的是 "forenyx/bin"，在多智能体下会把另外
        # 四个的 PATH 一起删掉——卸一个，五个都用不了。
        PATH_PAT="forenyx/$AGENT_NAME/bin"
        if [ -f "$RC_FILE" ] && grep -q "$PATH_PAT" "$RC_FILE"; then
            TEMP_RC=$(mktemp)
            grep -v "$PATH_PAT" "$RC_FILE" \
                | grep -v "# Forenyx AI CLI PATH configuration ($AGENT_NAME)" > "$TEMP_RC" || true
            cat "$TEMP_RC" > "$RC_FILE"
            rm -f "$TEMP_RC"
            echo -e "  - Removed $AGENT_NAME PATH configuration from $RC_FILE."
        fi
        
        echo -e "\033[0;32m\033[1m$AGENT_NAME has been successfully uninstalled!\033[0m"
        exit 0
        ;;
esac

# Execute actual compiled binary
export PI_PACKAGE_DIR="$LIBEXEC_DIR"

# 上游 pi 用 PI_OFFLINE 统一关掉所有主动联网：tools-manager 跳过 fd/rg 下载
# （离线包已把它们装到 agent/bin，此处只是兜底），version-check 跳过版本查询。
# 必须由 wrapper export —— .env 不会被自动注入进程环境，写在那里不生效。
if [ "$IS_OFFLINE" = "1" ]; then
    export PI_OFFLINE=1
fi

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
        PATH_LINE="export PATH=\"\$HOME/.forenyx/$AGENT_NAME/bin:\$PATH\""
        ;;
    bash)
        if [ -f "$HOME/.bash_profile" ]; then
            RC_FILE="$HOME/.bash_profile"
        else
            RC_FILE="$HOME/.bashrc"
        fi
        PATH_LINE="export PATH=\"\$HOME/.forenyx/$AGENT_NAME/bin:\$PATH\""
        ;;
    csh|tcsh)
        if [ -f "$HOME/.tcshrc" ]; then
            RC_FILE="$HOME/.tcshrc"
        else
            RC_FILE="$HOME/.cshrc"
        fi
        PATH_LINE="setenv PATH \"\$HOME/.forenyx/$AGENT_NAME/bin:\$PATH\""
        ;;
    *)
        RC_FILE="$HOME/.bashrc"
        PATH_LINE="export PATH=\"\$HOME/.forenyx/$AGENT_NAME/bin:\$PATH\""
        ;;
esac

# 按智能体判重。匹配 "forenyx/bin" 的话，装了 fnx_dv 之后再装 fnx_rtl 会被
# 误判成"已配置"，第二个智能体就进不了 PATH。
if [ -f "$RC_FILE" ]; then
    if grep -q "forenyx/$AGENT_NAME/bin" "$RC_FILE"; then
        echo -e "  - Path configuration for $AGENT_NAME already exists in $RC_FILE."
    else
        echo -e "  - Adding $AGENT_NAME to PATH in $RC_FILE..."
        echo -e "\n# Forenyx AI CLI PATH configuration ($AGENT_NAME)\n$PATH_LINE" >> "$RC_FILE"
    fi
else
    echo -e "  - Shell config file $RC_FILE not found. Creating it..."
    echo -e "# Forenyx AI CLI PATH configuration ($AGENT_NAME)\n$PATH_LINE" > "$RC_FILE"
fi

echo -e "${GREEN}${BOLD}=====================================================${NC}"
echo -e "${GREEN}${BOLD}   ${AGENT_NAME} installation finished successfully!${NC}"
echo -e "${GREEN}${BOLD}=====================================================${NC}"
echo -e "To apply the environment changes immediately, please run:"
echo -e "  ${CYAN}${BOLD}source $RC_FILE${NC}"
if [ "$OFFLINE_MODE" = "1" ]; then
    # 离线机器上没有可用的 LLM 配置，不配就会撞上 "No API key found for the
    # selected model"。注意配置入口是 CLI 内的 /login（写 agent/models.json），
    # 不是 ~/.forenyx/.env —— 那个文件不会被注入进程环境，CLI 侧无人读取。
    echo -e "Then, you can start it anywhere by typing:"
    echo -e "  ${CYAN}${BOLD}$AGENT_NAME${NC}"
    echo -e "On first launch, run ${CYAN}${BOLD}/login${NC} to configure your on-premise LLM"
    echo -e "  (base URL, API key, model name)."
    # 离线环境下 forenyx update 会被 wrapper 拦下，这里不能再指向它
    echo -e "This machine is an ${BOLD}offline${NC} deployment; ${CYAN}${AGENT_NAME} update${NC} is unavailable."
    echo -e "To upgrade, obtain a newer offline bundle and run:"
    echo -e "  ${CYAN}${BOLD}./install-release.sh --offline${NC}"
else
    echo -e "Then, you can start it anywhere by typing:"
    echo -e "  ${CYAN}${BOLD}$AGENT_NAME${NC}"
    echo -e "To update ${AGENT_NAME} in the future, simply run:"
    echo -e "  ${CYAN}${BOLD}$AGENT_NAME update${NC}"
fi
echo -e "To uninstall ${AGENT_NAME}, simply run:"
echo -e "  ${CYAN}${BOLD}$AGENT_NAME uninstall${NC}"
echo -e "====================================================="
