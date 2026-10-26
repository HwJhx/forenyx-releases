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
#   <根目录>/                  账号级——授权文件与心跳缓存，所有智能体共用
#   <根目录>/<AGENT_NAME>/     本智能体——bin/ libexec/ agent/
# 根目录默认 ~/.forenyx，安装时可用 --prefix 指定；卸载按与安装器相同的规则找到它（§3.2）。
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

# 本仓库卸载的智能体。**必须定义在下面这些路径推导之前** —— 放晚了
# AGENT_HOME 会算成 "~/.forenyx/"（名字为空），而后面有 rm -rf "$AGENT_HOME"，
# 那就是把整个 ~/.forenyx 连同授权文件一起删掉，且 shell 全程不报错。
AGENT_NAME="fnx_dv"

# AGENT_NAME 为空是致命的：路径会算成 "~/.forenyx/"，而下面有 rm -rf 作用在它上面 ——
# 等于把整个 ~/.forenyx 连同机器级授权文件一起删掉，shell 全程不报错。上面那句注释
# 只是约定，约定挡不住派生新智能体时改错这一行、或者有人把定义往下挪，所以这里再拦一道。
if [ -z "$AGENT_NAME" ]; then
    echo -e "${RED}❌ AGENT_NAME 为空，拒绝继续 —— 否则 rm -rf 会作用到整个 ~/.forenyx。${NC}"
    exit 1
fi

# --prefix：安装时指定过位置、而配置记录又被删掉时用它指明（§3.7）。
PREFIX_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            if [ -z "${2:-}" ]; then echo "错误：--prefix 后面要跟安装目录" >&2; exit 1; fi
            PREFIX_ARG="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# >>> ROOT_FN_BEGIN
# 安装根目录（默认 ~/.forenyx，可用 --prefix 指定）的查找、识别、所有者与权限、上级目录、
# shell 配置记录。设计见 docs/claude/install-prefix-plan.md §3.2–3.5、§3.7、§3.8。
#
# 本段在 install-release.sh、uninstall-release.sh、install-python-deps.sh 里各有一份
# **逐字相同**的副本——它们都以单文件分发（curl | bash 或随包），没法 source 公共文件。
# 由 scripts/check-script-copies.mjs 按标记行核对，改这里要同步三处。安装器生成的
# wrapper 用 declare -p / declare -f 原样带上。**勿删标记行。**
#
# 兼容 macOS 自带的 bash 3.2：不用关联数组、不用 ${var,,}。
# 调用前需已设好 AGENT_NAME（PATH 记录按智能体区分）。

FNX_RC_FILES=".bashrc .bash_profile .zshrc .cshrc .tcshrc"
FNX_PATH_MARK_PREFIX="# Forenyx AI CLI PATH configuration"
FNX_HOME_MARK="# Forenyx AI root"
FNX_ROOT_MARKER=".forenyx_root"

# perl 部分。安装器本来就依赖 perl（ENV_PL），这里不再引入别的工具。
#   realpath：绝对路径 → 物理路径（逐级解析符号链接与 ..；不存在的部分按字面拼接）
#   rc_homes：列出配置文件里安装器写下的 FORENYX_HOME 记录的值
#   rc_edit ：按标记增删 PATH 行与 FORENYX_HOME 行，结果写到标准输出
FNX_PL='
use strict; use warnings;
my $m = $ENV{FNXMODE} // "";
if ($m eq "realpath") {
    require Cwd;
    my $p = $ENV{FNXPATH} // ""; exit 2 unless $p =~ m{^/};
    my $cur = "/";
    for my $c (split m{/}, $p) {
        next if $c eq "" || $c eq ".";
        if ($c eq "..") { $cur =~ s{/[^/]*\z}{}; $cur = "/" if $cur eq ""; next; }
        my $nxt = $cur eq "/" ? "/$c" : "$cur/$c";
        if (-e $nxt) { my $r = Cwd::realpath($nxt); $cur = defined $r ? $r : $nxt; }
        else { $cur = $nxt; }
    }
    print "$cur\n"; exit 0;
}
my $hmark = $ENV{FNXHOMEMARK}; my $pmark = $ENV{FNXPATHMARK};
my $agent = $ENV{FNXAGENT} // "";
sub trimws { my $s = shift; $s =~ s/^\s+//; $s =~ s/\s+\z//; return $s; }
sub homeval {
    my $l = trimws(shift);
    return $2 if $l =~ /^export\s+FORENYX_HOME=(["\x27]?)(.*?)\1$/;
    return $2 if $l =~ /^setenv\s+FORENYX_HOME\s+(["\x27]?)(.*?)\1$/;
    return undef;
}
sub is_agent_path {
    my $l = shift;
    return 0 if $agent eq "";
    return ($l =~ /PATH/ && index($l, "/$agent/bin") >= 0) ? 1 : 0;
}
local $/; my $c = <STDIN>; $c = "" unless defined $c;
my @e = split /\n/, $c, -1; my $nl = 0;
if (@e && $e[-1] eq "") { pop @e; $nl = 1; }
if ($m eq "rc_homes") {
    for (my $i = 0; $i < @e; $i++) {
        next unless trimws($e[$i]) eq $hmark && $i + 1 < @e;
        my $v = homeval($e[$i + 1]); print "$v\n" if defined $v;
    }
    exit 0;
}
exit 2 unless $m eq "rc_edit";
my $pmode = $ENV{FNXPATHMODE} // "keep";      # keep | del | set
my $pline = $ENV{FNXPATHLINE} // "";
my $padd  = $ENV{FNXPATHADD} // "0";
my $hdelall = $ENV{FNXHOMEDELALL} // "0";
my %hdel = map { $_ => 1 } grep { $_ ne "" } split /\n/, ($ENV{FNXHOMEDEL} // "");
my $hline = $ENV{FNXHOMELINE} // "";
my $hadd  = $ENV{FNXHOMEADD} // "0";
my $pmark_agent = "$pmark ($agent)";
my @out; my $pfound = 0; my $hkept = 0;
sub drop_blank_before { pop @out if @out && $out[-1] =~ /^\s*$/; }
for (my $i = 0; $i < @e; $i++) {
    my $t = trimws($e[$i]);
    if ($agent ne "" && $t eq $pmark_agent) {
        my $pair = ($i + 1 < @e && is_agent_path($e[$i + 1])) ? 1 : 0;
        if ($pmode eq "del") { drop_blank_before(); $i++ if $pair; next; }
        if ($pmode eq "set") {
            if ($pfound) { drop_blank_before(); $i++ if $pair; next; }
            push @out, $e[$i], $pline; $pfound = 1; $i++ if $pair; next;
        }
        push @out, $e[$i]; next;
    }
    if ($pmode ne "keep" && is_agent_path($e[$i]) && index($e[$i], "forenyx/$agent/bin") >= 0) {
        # 0.4.9 及以前没有配套标记、或标记被手工删掉的旧 PATH 行
        if ($pmode eq "set" && !$pfound) { push @out, $pmark_agent, $pline; $pfound = 1; }
        next;
    }
    if ($t eq $hmark && $i + 1 < @e && defined homeval($e[$i + 1])) {
        my $v = homeval($e[$i + 1]);
        if ($hdelall eq "1" || $hdel{$v}) { drop_blank_before(); $i++; next; }
        if ($hline ne "") {
            if ($hkept) { drop_blank_before(); $i++; next; }
            push @out, $e[$i], $hline; $hkept = 1; $i++; next;
        }
        push @out, $e[$i], $e[$i + 1]; $hkept = 1; $i++; next;
    }
    push @out, $e[$i];
}
if ($pmode eq "set" && $padd eq "1" && !$pfound) { push @out, "", $pmark_agent, $pline; $nl = 1; }
if ($hline ne "" && $hadd eq "1" && !$hkept) { push @out, "", $hmark, $hline; $nl = 1; }
if (@out) { my $o = join("\n", @out); $o .= "\n" if $nl; print $o; }
'

# ~ 展开、相对路径转绝对，再取物理路径。参数为空时输出空。
fnx_realpath() {
    local p="$1"
    [ -n "$p" ] || return 0
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p#\~/}" ;;
    esac
    case "$p" in
        /*) ;;
        *) p="$PWD/$p" ;;
    esac
    FNXMODE=realpath FNXPATH="$p" perl -e "$FNX_PL"
}

fnx_my_uid() { id -u; }
fnx_uid_of() { ls -ldn "$1" 2>/dev/null | awk '{print $3}'; }
fnx_mode_of() { ls -ld "$1" 2>/dev/null | awk '{print substr($1, 1, 10)}'; }

# 有没有额外 ACL。macOS 上 ls -ld 的第 11 位遇到扩展属性显示 @，会盖住 ACL 的 +，
# 所以用 ls -lde 看有没有 ACL 条目；Linux 看第 11 位是不是 +。
fnx_has_acl() {
    if [ "$(uname)" = "Darwin" ]; then
        [ -n "$(ls -lde "$1" 2>/dev/null | sed -n '2p')" ]
    else
        [ "$(ls -ld "$1" 2>/dev/null | awk '{print substr($1, 11, 1)}')" = "+" ]
    fi
}

# 清除额外 ACL（Linux 的 -k 清目录默认 ACL，只用 -b 会留下，新文件仍会继承）。
# 清除后仍有 ACL 返回 1。
fnx_clear_acl() {
    fnx_has_acl "$1" || return 0
    if [ "$(uname)" = "Darwin" ]; then
        chmod -N "$1" 2>/dev/null || true
    elif command -v setfacl >/dev/null 2>&1; then
        setfacl -b -k "$1" 2>/dev/null || true
    fi
    ! fnx_has_acl "$1"
}

# 是不是 Forenyx 安装根目录：有标记文件；或者是 0.4.9 及以前的旧根目录（没有标记），
# 认得出的痕迹只取本产品特有的——裸 .env 太常见，必须带有 FORENYX_CLIENT_ID。
fnx_is_root() {
    local d="$1" a
    [ -d "$d" ] || return 1
    [ -f "$d/$FNX_ROOT_MARKER" ] && return 0
    [ -f "$d/forenyx.lic" ] && return 0
    [ -f "$d/forenyx-hostid.sh" ] && return 0
    [ -f "$d/.env" ] && grep -q 'FORENYX_CLIENT_ID=' "$d/.env" 2>/dev/null && return 0
    for a in "$d"/*/libexec/package.json; do
        [ -f "$a" ] && grep -q '"piConfig"' "$a" 2>/dev/null && return 0
    done
    return 1
}

# 标记文件里的某个字段（key=value，取第一个）。
fnx_marker_get() {
    [ -f "$1/$FNX_ROOT_MARKER" ] || return 0
    sed -n "s/^$2=//p" "$1/$FNX_ROOT_MARKER" 2>/dev/null | head -n 1
}

# 根目录属于当前账号：目录所有者是自己；已有标记文件的话，它是普通文件（不是符号链接）、
# 所有者是自己、里面记的 UID 也是自己（§3.3 所有者校验）。只看文本里的 UID 不够：
# 他人能写进根目录时可以伪造一份标记，连同其中的风险记录。
fnx_root_mine() {
    local d="$1" me uid m="$1/$FNX_ROOT_MARKER"
    me=$(fnx_my_uid)
    [ "$(fnx_uid_of "$d")" = "$me" ] || return 1
    if [ -e "$m" ] || [ -L "$m" ]; then
        [ -L "$m" ] && return 1
        [ "$(fnx_uid_of "$m")" = "$me" ] || return 1
    fi
    uid=$(fnx_marker_get "$d" uid)
    [ -z "$uid" ] || [ "$uid" = "$me" ]
}

# 根目录里授权相关的文件（标记、.env、授权文件）已存在却不是「本人的、只有一个链接的
# 普通文件」时，逐行输出 `ls -ld` 的结果。安装器读写这些文件时会顺着符号链接、硬链接
# 写到根目录之外；不属于自己的文件改不了权限、内容也可能被换过；目录等非普通文件到
# 写入时才失败，留下装了一半的状态。所以安装前一律拒绝。
fnx_sensitive_problems() {
    local r="$1" f me
    me=$(fnx_my_uid)
    for f in "$r/$FNX_ROOT_MARKER" "$r/.env" "$r/forenyx.lic"; do
        if [ -L "$f" ]; then
            ls -ld "$f" 2>/dev/null
        elif [ -e "$f" ]; then
            if [ ! -f "$f" ] || [ "$(fnx_uid_of "$f")" != "$me" ] \
                || [ "$(ls -ldn "$f" 2>/dev/null | awk '{print $2}')" != "1" ]; then
                ls -ld "$f" 2>/dev/null
            fi
        fi
    done
}

# shell 配置文件是 csh 语法吗
fnx_rc_is_csh() { case "$1" in *.cshrc|*.tcshrc) return 0 ;; esac; return 1; }

# 各配置文件里安装器写下的 FORENYX_HOME 记录的值，逐行输出。
fnx_rc_homes() {
    local f
    for f in $FNX_RC_FILES; do
        [ -f "$HOME/$f" ] || continue
        FNXMODE=rc_homes FNXHOMEMARK="$FNX_HOME_MARK" FNXPATHMARK="$FNX_PATH_MARK_PREFIX" FNXAGENT="" \
            perl -e "$FNX_PL" < "$HOME/$f"
    done
}

# 改一个配置文件。参数：文件，其余按 KEY=VALUE 传给 rc_edit（FNXPATHMODE 等）。
# 内容不变就不写；写回保留原文件的权限与属主（cat >），写失败保持原样并返回 1。
fnx_rc_edit() {
    local f="$1" tmp
    shift
    tmp=$(mktemp "${TMPDIR:-/tmp}/forenyx-rc.XXXXXX") || return 1
    if [ -f "$f" ]; then
        if ! env "$@" FNXMODE=rc_edit FNXHOMEMARK="$FNX_HOME_MARK" FNXPATHMARK="$FNX_PATH_MARK_PREFIX" \
            FNXAGENT="$AGENT_NAME" perl -e "$FNX_PL" < "$f" > "$tmp"; then
            rm -f "$tmp"; echo "读取 $f 失败，未改动" >&2; return 1
        fi
        if cmp -s "$f" "$tmp"; then rm -f "$tmp"; return 0; fi
    else
        if ! env "$@" FNXMODE=rc_edit FNXHOMEMARK="$FNX_HOME_MARK" FNXPATHMARK="$FNX_PATH_MARK_PREFIX" \
            FNXAGENT="$AGENT_NAME" perl -e "$FNX_PL" < /dev/null > "$tmp"; then
            rm -f "$tmp"; return 1
        fi
        [ -s "$tmp" ] || { rm -f "$tmp"; return 0; }
    fi
    if ! cat "$tmp" > "$f"; then rm -f "$tmp"; echo "写入 $f 失败" >&2; return 1; fi
    rm -f "$tmp"
}

# 所有配置文件里删掉本智能体的 PATH 行（卸载用）。
fnx_rc_remove_path() {
    local f
    for f in $FNX_RC_FILES; do
        [ -f "$HOME/$f" ] || continue
        fnx_rc_edit "$HOME/$f" FNXPATHMODE=del || true
    done
}

# 找本账号已有的根目录。输出变量：
#   FNX_EXISTING      已有的根目录（去重，换行分隔）
#   FNX_STALE_VALUES  指向不存在或不是根目录的记录值（环境变量与配置文件，换行分隔）
#   FNX_FOREIGN       指到了、是根目录、却不属于当前账号的目录（换行分隔）
# 过期的只提示，不在这里改配置文件。
fnx_find_roots() {
    local cands="" v p
    FNX_EXISTING=""; FNX_STALE_VALUES=""; FNX_FOREIGN=""
    if [ -n "${FORENYX_HOME:-}" ]; then cands="$FORENYX_HOME"; fi
    cands="$cands
$(fnx_rc_homes)
$HOME/.forenyx"
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        p=$(fnx_realpath "$v")
        if [ -z "$p" ] || ! fnx_is_root "$p"; then
            if [ "$v" != "$HOME/.forenyx" ]; then
                case "
$FNX_STALE_VALUES
" in *"
$v
"*) ;; *) FNX_STALE_VALUES="${FNX_STALE_VALUES:+$FNX_STALE_VALUES
}$v" ;; esac
            fi
            continue
        fi
        if ! fnx_root_mine "$p"; then
            case "
$FNX_FOREIGN
" in *"
$p
"*) ;; *) FNX_FOREIGN="${FNX_FOREIGN:+$FNX_FOREIGN
}$p" ;; esac
            continue
        fi
        case "
$FNX_EXISTING
" in *"
$p
"*) ;; *) FNX_EXISTING="${FNX_EXISTING:+$FNX_EXISTING
}$p" ;; esac
    done <<FNXEOF
$cands
FNXEOF
}

# 有问题的上级目录：从根目录的上一级逐级到 /，每一级须所有者为本人或 root，
# 且组与其他人不可写（带 ACL 的按可写处理）——设了 sticky 位的除外。
# 只查已存在的上级（不存在的那几级会由安装器以 umask 077 创建）。
# 逐行输出「路径|UID|组可写|其他人可写|sticky|ACL」（后四项为 0/1）。
fnx_parent_risks() {
    local r="$1" d me uid mode gw ow st acl
    me=$(fnx_my_uid)
    d="${r%/*}"; [ -n "$d" ] || d="/"
    while :; do
        if [ -d "$d" ]; then
            uid=$(fnx_uid_of "$d"); mode=$(fnx_mode_of "$d")
            gw=0; ow=0; st=0; acl=0
            [ "$(printf '%s' "$mode" | cut -c6)" = "w" ] && gw=1
            [ "$(printf '%s' "$mode" | cut -c9)" = "w" ] && ow=1
            case "$(printf '%s' "$mode" | cut -c10)" in t|T) st=1 ;; esac
            fnx_has_acl "$d" && acl=1
            if [ "$st" = "0" ] && { [ "$gw" = "1" ] || [ "$ow" = "1" ] || [ "$acl" = "1" ] \
                || { [ "$uid" != "$me" ] && [ "$uid" != "0" ]; }; }; then
                printf '%s|%s|%s|%s|%s|%s\n' "$d" "$uid" "$gw" "$ow" "$st" "$acl"
            elif [ "$st" = "1" ] && [ "$uid" != "$me" ] && [ "$uid" != "0" ]; then
                # sticky 只挡别人改名删除不属于他的目录项；目录所有者本人仍可以，
                # 所以由他人所有的上级目录即使有 sticky 也算有问题
                printf '%s|%s|%s|%s|%s|%s\n' "$d" "$uid" "$gw" "$ow" "$st" "$acl"
            fi
        fi
        [ "$d" = "/" ] && break
        d="${d%/*}"; [ -n "$d" ] || d="/"
    done
}

# 写标记文件：账号、UID、根目录。权限 600。参数：根目录。
fnx_marker_write() {
    local r="$1" tmp
    tmp=$(mktemp "$r/$FNX_ROOT_MARKER.XXXXXX") || return 1
    {
        echo "# Forenyx AI 安装根目录标记，请勿删除（docs/claude/install-prefix-plan.md §3.3）"
        echo "user=${USER:-$(id -un)}"
        echo "uid=$(fnx_my_uid)"
        echo "root=$r"
    } > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$r/$FNX_ROOT_MARKER"
}

# 上级目录他人可写时提示：他人可以把安装目录改名、再放一个同名目录。
# 只提示、不拦（2026-10-26 用户决定，替代原先「自定义位置默认拒绝、--allow-shared-parent
# 放行并记录」的做法，见方案第 9 节决定事项 4）。不改任何东西，总是返回 0。
fnx_parent_warn() {
    local r="$1" risks line
    risks=$(fnx_parent_risks "$r")
    [ -n "$risks" ] || return 0
    echo -e "\033[0;33m⚠ 安装目录的上级目录可被他人改名或删除，存在被替换的风险：\033[0m" >&2
    while IFS='|' read -r line _; do
        [ -n "$line" ] && echo "    $(ls -ld "$line" 2>/dev/null)" >&2
    done <<FNXEOF
$risks
FNXEOF
    echo "  继续。建议请管理员处理上述目录：所有者改为本人或 root，并只让所有者能写入（或设 sticky 位）。" >&2
    return 0
}
# 卸载、装依赖用：只找**已有的**根目录，不新建（§3.2 末段）。参数：--prefix 的值（可空）。
# 找到返回 0，结果在 FNX_LOCATED；没装过返回 2；有冲突返回 1（已打印原因）。
fnx_locate_existing() {
    local want="" n
    FNX_LOCATED=""
    if [ -n "$1" ]; then
        want=$(fnx_realpath "$1")
        [ -n "$want" ] || { echo "❌ 无法解析 --prefix 指定的路径：$1" >&2; return 1; }
    fi
    fnx_find_roots
    if [ -n "$FNX_FOREIGN" ]; then
        echo "❌ 找到的 Forenyx 安装目录不属于当前账号（$(id -un)），已停止，未做任何改动：" >&2
        printf '%s\n' "$FNX_FOREIGN" | sed 's|^|     |' >&2
        return 1
    fi
    n=$(printf '%s\n' "$FNX_EXISTING" | grep -c . || true)
    if [ "$n" -gt 1 ]; then
        echo "❌ 当前账号有不止一个 Forenyx 安装目录，无法确定用哪一个，已停止：" >&2
        printf '%s\n' "$FNX_EXISTING" | sed 's|^|     |' >&2
        echo "   请删掉不用的目录，或修正环境变量 FORENYX_HOME 与 shell 配置文件里的「${FNX_HOME_MARK}」记录后重试。" >&2
        return 1
    fi
    if [ -n "$want" ]; then
        if [ "$n" = "1" ] && [ "$FNX_EXISTING" != "$want" ]; then
            echo "❌ 当前账号装在 ${FNX_EXISTING}，不是 --prefix 指定的 ${want}，已停止。" >&2
            return 1
        fi
        if [ "$n" = "0" ]; then
            fnx_is_root "$want" || return 2
            if ! fnx_root_mine "$want"; then
                echo "❌ $want 不属于当前账号（$(id -un)），已停止，未做任何改动。" >&2
                return 1
            fi
        fi
        FNX_LOCATED="$want"
        return 0
    fi
    [ "$n" = "1" ] || return 2
    FNX_LOCATED="$FNX_EXISTING"
}

# 卸载、装依赖前检查根目录与其中授权相关文件：所有者是本人、组与其他人不可写、
# 没有额外 ACL（§3.3 权限：只检查，不去改）。参数：根目录、是否默认根目录(0/1)。
# 自定义根目录不满足返回 1；默认根目录只警告（0.4.9 的 ~/.forenyx 可能随 umask 组可写，
# 清不掉的 ACL 也是接受的残余风险，不能因此卸不掉）。
fnx_perm_check() {
    local r="$1" is_default="$2" f m me bad=""
    me=$(fnx_my_uid)
    for f in "$r" "$r/$FNX_ROOT_MARKER" "$r/.env" "$r/forenyx.lic"; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        m=$(fnx_mode_of "$f")
        if [ -L "$f" ] || [ "$(fnx_uid_of "$f")" != "$me" ] || [ "$(printf '%s' "$m" | cut -c6)" = "w" ] \
            || [ "$(printf '%s' "$m" | cut -c9)" = "w" ] || fnx_has_acl "$f"; then
            bad="$bad
    $(ls -ld "$f" 2>/dev/null)"
        fi
    done
    [ -n "$bad" ] || return 0
    if [ "$is_default" = "1" ]; then
        echo -e "\033[0;33m⚠ 以下文件可被其他账号写入、不属于你或是符号链接：$bad\033[0m" >&2
        return 0
    fi
    echo -e "\033[0;31m❌ 以下文件可被其他账号写入、不属于你或是符号链接，其中内容可能已被替换。已停止，未做任何改动：\033[0m$bad" >&2
    echo "   请确认内容无误、收紧权限（目录 chmod 700，文件 chmod 600，并清除 ACL）后重试。" >&2
    return 1
}
# <<< ROOT_FN_END

# 交互输入统一走这里。`curl … | bash` 时 stdin 是脚本自己，直接 read 会把脚本
# 正文读进变量，所以优先用 /dev/tty；没有 tty、脚本从文件执行的场合（CI、容器）退回 stdin；
# 没有 tty 而脚本又来自 stdin 时不读，按默认值。
ask() {
    local __var="$1" __prompt="$2" __reply=""
    if [ -c /dev/tty ] && { : < /dev/tty; } 2>/dev/null; then
        printf "%b" "$__prompt" > /dev/tty
        IFS= read -r __reply < /dev/tty || __reply=""
    elif { [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = main ]; } \
         && [ -z "${BASH_EXECUTION_STRING+x}" ]; then
        # 没有终端，而且脚本本身是经管道从 stdin 读进来的（curl … | bash；这时 BASH_SOURCE[0]
        # 在 bash 3.2 为空、在 bash 5 为 main）。bash -c 执行时 BASH_SOURCE[0] 在 bash 3.2 下
        # 也为空，但会设置 BASH_EXECUTION_STRING，stdin 可以照常读，靠它区分。stdin 里剩下的
        # 是脚本正文，读它会把正文当成答案，还会吞掉后面的卸载步骤。不读，按默认值处理。
        printf "%b（没有终端，按默认）\n" "$__prompt"
    else
        printf "%b" "$__prompt"
        IFS= read -r __reply || __reply=""
    fi
    printf -v "$__var" '%s' "$__reply"
}

# y/n 问题只接受 y/n（yes/no，大小写均可）或回车取默认，其他输入提示后重问。
# 原先只认 y：「保留数据？」手滑输错一个字母就当成「不保留」，整个智能体目录被删。
# ask 读到输入结束时返回空串，按默认处理，不会死循环。
ask_yn() {
    local __var="$1" __prompt="$2" __default="$3" __r=""
    while :; do
        ask __r "$__prompt"
        case "$(printf '%s' "${__r:-$__default}" | tr 'A-Z' 'a-z')" in
            y|yes) printf -v "$__var" '%s' y; return 0 ;;
            n|no) printf -v "$__var" '%s' n; return 0 ;;
            *) echo -e "${YELLOW}  请输入 y 或 n（直接回车为 ${__default}）。${NC}" ;;
        esac
    done
}

echo -e "${RED}${BOLD}=====================================================${NC}"
echo -e "${RED}${BOLD}      Uninstalling Forenyx AI — ${AGENT_NAME}${NC}"
echo -e "${RED}${BOLD}=====================================================${NC}"

# ---------------------------------------------------------------------------
# 找安装根目录（默认 ~/.forenyx，或安装时 --prefix 指定的位置，§3.2、§3.7）
# ---------------------------------------------------------------------------
fnx_rc=0
fnx_locate_existing "$PREFIX_ARG" || fnx_rc=$?
if [ "$fnx_rc" = "1" ]; then
    exit 1
fi
if [ "$fnx_rc" = "2" ] || [ ! -d "$FNX_LOCATED/$AGENT_NAME" ]; then
    echo -e "${YELLOW}$AGENT_NAME is not installed (no $AGENT_NAME found in ${FNX_LOCATED:-${PREFIX_ARG:-~/.forenyx}}).${NC}"
    # 安装目录已被手工删掉时，配置文件里可能还留着本智能体的 PATH 行，顺手清掉
    fnx_rc_remove_path
    exit 0
fi
FORENYX_ROOT="$FNX_LOCATED"
IS_DEFAULT_ROOT=0
ROOT_SHOW="$FORENYX_ROOT"
if [ "$FORENYX_ROOT" = "$(fnx_realpath "$HOME/.forenyx")" ]; then
    IS_DEFAULT_ROOT=1
    ROOT_SHOW="~/.forenyx"
fi
AGENT_HOME="$FORENYX_ROOT/$AGENT_NAME"
BIN_DIR="$AGENT_HOME/bin"
LIBEXEC_DIR="$AGENT_HOME/libexec"

# 删除任何东西之前的检查（§3.3、§3.7）：根目录或授权文件他人可写时内容可能已被替换
fnx_perm_check "$FORENYX_ROOT" "$IS_DEFAULT_ROOT" || exit 1
echo -e "  Install root: ${CYAN}$ROOT_SHOW${NC}"

# ---------------------------------------------------------------------------
# 1. 删除本智能体
# ---------------------------------------------------------------------------
echo -e "${YELLOW}Would you like to keep your custom skills and configuration data?${NC}"
echo -e "  Skills path:         $ROOT_SHOW/$AGENT_NAME/agent/skills/custom/"
echo -e "  Configurations path: $ROOT_SHOW/$AGENT_NAME/agent/ (settings.json, auth.json, sessions/)"
ask_yn KEEP_DATA "Keep these files? (y/n, default: y): " y

if [ "$KEEP_DATA" = "y" ]; then
    echo -e "${BLUE}Keeping configurations and skills. Cleaning binaries...${NC}"
    rm -rf "$BIN_DIR" "$LIBEXEC_DIR"
    echo -e "  - Cleared binaries and wrappers (kept $ROOT_SHOW/$AGENT_NAME/agent/)."
else
    echo -e "${RED}Deleting all $AGENT_NAME data...${NC}"
    rm -rf "$AGENT_HOME"
    echo -e "  - Cleared $ROOT_SHOW/$AGENT_NAME/."
fi

# ---------------------------------------------------------------------------
# 2. 清 PATH —— 所有常见配置文件里本智能体的 PATH 行（§3.5）
# ---------------------------------------------------------------------------
# 按标记删，不按路径字符串——根目录不一定叫 forenyx。别的智能体的行与 FORENYX_HOME
# 记录不动：留着记录，下次不带 --prefix 重装仍能回到这个根目录。
echo -e "${BLUE}Cleaning up PATH environment variables...${NC}"
fnx_rc_remove_path
echo -e "  - Removed $AGENT_NAME PATH configuration from shell config files."

# ---------------------------------------------------------------------------
# 3. 机器级授权：只在本机再没有智能体时才问
# ---------------------------------------------------------------------------
# 判据用 libexec/ 而不是目录名：保留数据卸载会留下 agent/，那不算还装着；
# 用户自己在根目录下建的杂物也不该被当成智能体。
REMAINING=0
for d in "$FORENYX_ROOT"/*/; do
    if [ -d "${d}libexec" ]; then
        REMAINING=$((REMAINING + 1))
    fi
done

if [ "$REMAINING" -gt 0 ]; then
    echo -e "  - 本机还有 $REMAINING 个智能体，保留共用的 $ROOT_SHOW/forenyx.lic 与 .env。"
elif [ -f "$FORENYX_ROOT/forenyx.lic" ] || [ -f "$FORENYX_ROOT/.env" ]; then
    echo -e "${YELLOW}本机已无其它智能体。是否一并删除授权文件与授权配置？${NC}"
    echo -e "  $ROOT_SHOW/forenyx.lic, $ROOT_SHOW/.env"
    echo -e "${YELLOW}  删除后重装需要重新激活；内网机器需要重新向管理员申请 .lic。${NC}"
    ask_yn DEL_LIC "Delete license data? (y/n, default: n): " n
    if [ "$DEL_LIC" = "y" ]; then
        rm -f "$FORENYX_ROOT/forenyx.lic" "$FORENYX_ROOT/.env" \
              "$FORENYX_ROOT/.heartbeat_cache" "$FORENYX_ROOT/.offline_runs" \
              "$FORENYX_ROOT/.offline_batch" "$FORENYX_ROOT/.license_state" \
              "$FORENYX_ROOT/.heartbeat_probe"
        echo -e "  - Cleared license data."
    else
        echo -e "  - Kept license data."
    fi
fi

echo -e "${GREEN}${BOLD}=====================================================${NC}"
echo -e "${GREEN}${BOLD}      $AGENT_NAME has been successfully uninstalled!${NC}"
echo -e "${GREEN}${BOLD}=====================================================${NC}"
# 告诉用户留下了什么（§3.7）。标记文件 .forenyx_root 不删：留着它，重装时才认得出这里。
if [ -d "$FORENYX_ROOT" ] && [ -n "$(ls -A "$FORENYX_ROOT" 2>/dev/null)" ]; then
    echo -e "Install root $ROOT_SHOW is kept: $(ls -A "$FORENYX_ROOT" 2>/dev/null | tr '\n' ' ')"
    echo -e "  Reinstalling will go back there. To remove everything: ${CYAN}rm -rf $ROOT_SHOW${NC}"
fi
echo -e "Please open a new terminal to refresh your environment."
echo -e "====================================================="
