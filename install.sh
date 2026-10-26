#!/bin/bash

# =============================================================================
# Forenyx AI Installer (Commercial Closed-Source Version)
# =============================================================================
# Supported OS: macOS, Linux
# Dependencies: curl, tar, perl（读写 ~/.forenyx/.env 用，见 ENV_PL）
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

# ~/.forenyx/.env 的读写规则，与客户端 license-guard.ts 的 readEnvValue 保持一致。
# 安装器、wrapper 与客户端各读各的，规则不同就会出现「安装器以为写好了，客户端读到的
# 还是旧值」：手改出缩进行、重复行、带引号的值、BOM 或不间断空格时尤其明显。规则：
#   · 每行先按 JavaScript String.trim() 的空白集合去掉两端（ASCII 空白、BOM、NBSP、
#     Unicode Zs 类空格、U+2028/U+2029）；以「KEY=」开头的才算匹配；
#   · 多行匹配时只认第一行（哪怕它的值是空的，也不再往后找）；
#   · 值取第一个 = 之后，去两端空白，再各去掉开头、结尾的一个引号。
# 这里用 perl 按字节匹配，不依赖 locale。perl 随 macOS 与主流 Linux 基础系统提供。
# 整段脚本存在 ENV_PL 里：wrapper 通过 declare -p / declare -f 原样写入，只保留一份。
ENV_PL='
my $ws = qr/(?:[\t\x0b\f\r ]|\xEF\xBB\xBF|\xC2\xA0|\xE1\x9A\x80|\xE2\x80[\x80-\x8A\xA8\xA9\xAF]|\xE2\x81\x9F|\xE3\x80\x80)/;
sub norm { my $s = shift; $s =~ s/^$ws+//; $s =~ s/$ws+\z//; return $s; }
my $k = $ENV{ENVKEY}; my $m = $ENV{ENVMODE}; my $pre = "$k=";
local $/; my $c = <>; $c = "" unless defined $c;
my @e = split /\n/, $c, -1;
my $nl = 0;
if (@e && $e[-1] eq "") { pop @e; $nl = 1; }
if ($m eq "count") {
    my $n = 0;
    for my $line (@e) { $n++ if index(norm($line), $pre) != 0; }
    print "$n\n";
    exit 0;
}
if ($m eq "get") {
    for my $line (@e) {
        my $t = norm($line);
        next unless index($t, $pre) == 0;
        my $v = norm(substr($t, length $pre));
        $v =~ s/^["\x27]//; $v =~ s/["\x27]\z//;
        print "$v\n";
        exit 0;
    }
    exit 0;
}
if ($m eq "has") {
    for my $line (@e) { exit 0 if index(norm($line), $pre) == 0; }
    exit 1;
}
my $done = 0; my @out;
for my $line (@e) {
    if (index(norm($line), $pre) == 0) {
        if ($m eq "set" && !$done) { push @out, "$k=$ENV{ENVVAL}"; $done = 1; }
        next;
    }
    push @out, $line;
}
if ($m eq "set" && !$done) { push @out, "$k=$ENV{ENVVAL}"; $nl = 1; }
if (@out) { my $o = join("\n", @out); $o .= "\n" if $nl; print $o; }
'

# 自检：用已知输入真正运行 ENV_PL，结果必须是 1。只看 perl 能否运行不够：
# 一个静默退出 0 的 perl 也能通过，那样读出来是空值，写回时会把 .env 清空。
env_selftest() {
    local t got
    t=$(mktemp "${TMPDIR:-/tmp}/forenyx-envtest.XXXXXX") || return 1
    printf '%b' '\xEF\xBB\xBF  FORENYX_OFFLINE=1 \r\nOTHER=0\n' > "$t"
    got=$(ENVMODE=get ENVKEY=FORENYX_OFFLINE perl -e "$ENV_PL" "$t" 2>/dev/null)
    rm -f "$t"
    [ "$got" = "1" ]
}

# 读：打印第一个匹配行的值；没有匹配行时打印空。总是返回 0，调用方在 set -e 下可安全赋值。
env_get() { [ -f "$2" ] || return 0; ENVMODE=get ENVKEY="$1" perl -e "$ENV_PL" "$2"; }
# 有没有任何匹配行（包括值为空的行）。
env_has() { [ -f "$2" ] || return 1; ENVMODE=has ENVKEY="$1" perl -e "$ENV_PL" "$2"; }

# 把临时文件写回原文件，保留原文件的权限与属主；写失败时把原内容恢复回去。
env_commit() {
    local file="$1" tmp="$2" bak
    bak=$(mktemp "$file.bak.XXXXXX") || { rm -f "$tmp"; echo "无法创建备份文件，未改动 $file" >&2; return 1; }
    if [ -f "$file" ] && ! cat "$file" > "$bak"; then
        rm -f "$tmp" "$bak"; echo "无法读取 $file 做备份，未改动" >&2; return 1
    fi
    if cat "$tmp" > "$file"; then
        rm -f "$tmp" "$bak"; return 0
    fi
    # 写入失败：若目标内容与备份一致（比如连打开都失败），原内容没有动，直接清理。
    if [ -f "$file" ] && cmp -s "$file" "$bak"; then
        rm -f "$tmp" "$bak"; echo "写入 $file 失败，原内容未改动" >&2; return 1
    fi
    # 写入中途失败：用备份恢复。恢复成功才删备份；恢复也失败则保留备份，并告诉用户去哪找。
    if [ -f "$file" ] && cat "$bak" > "$file" 2>/dev/null; then
        rm -f "$tmp" "$bak"; echo "写入 $file 失败，已恢复原内容" >&2
    else
        rm -f "$tmp"; echo "写入 $file 失败，且恢复也失败。原内容的备份在：$bak" >&2
    fi
    return 1
}

# 第一个匹配行改写成「KEY=值」，删除其余匹配行（含缩进行）；没有匹配行就追加。
# 只留第一个匹配行是因为客户端取的就是第一个：只改后面的行，前面的旧值照样生效。
# 值走环境变量传入，不经过 shell 或 awk 的转义。
env_set() {
    local key="$1" val="$2" file="$3" tmp
    tmp=$(mktemp "$file.XXXXXX") || return 1
    if ! ENVMODE=set ENVKEY="$key" ENVVAL="$val" perl -e "$ENV_PL" "$file" > "$tmp"; then
        rm -f "$tmp"; echo "读取 $file 失败，未改动" >&2; return 1
    fi
    # 写回前校验新内容：空输出、目标键的值不对、或其他配置行数变了，都说明 perl 没有正确执行。
    # 这类情况绝不能覆盖 .env。（校验与生成都走同一份 ENV_PL；它防的是 perl 异常，不防恶意替换。）
    local got old_n new_n
    got=$(ENVMODE=get ENVKEY="$key" perl -e "$ENV_PL" "$tmp" 2>/dev/null)
    old_n=$(ENVMODE=count ENVKEY="$key" perl -e "$ENV_PL" "$file" 2>/dev/null)
    new_n=$(ENVMODE=count ENVKEY="$key" perl -e "$ENV_PL" "$tmp" 2>/dev/null)
    if [ ! -s "$tmp" ] || [ "$got" != "$val" ] || [ -z "$old_n" ] || [ "$old_n" != "$new_n" ]; then
        rm -f "$tmp"; echo "生成 $file 的新内容校验失败（perl 输出异常），未改动" >&2; return 1
    fi
    env_commit "$file" "$tmp"
}

# 删除所有匹配行（含缩进行、重复行）。
env_del() {
    local key="$1" file="$2" tmp
    [ -f "$file" ] || return 0
    tmp=$(mktemp "$file.XXXXXX") || return 1
    if ! ENVMODE=del ENVKEY="$key" perl -e "$ENV_PL" "$file" > "$tmp"; then
        rm -f "$tmp"; echo "读取 $file 失败，未改动" >&2; return 1
    fi
    env_commit "$file" "$tmp"
}

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

# 缺 perl 时在改动任何文件之前就退出，不留下半装的安装目录与 .env。
# 放在 --print-client-id 之后：那个只读分支不用 perl，缺 perl 时照样要能输出设备标识。
if ! env_selftest; then
    echo "❌ perl 无法正确运行（自检失败）：安装器读写 ~/.forenyx/.env 需要它。请先安装或修复 perl 再重试。" >&2
    exit 1
fi

USER_LICENSE=""
# Parse command line options
# 离线模式：从本地离线包安装，全程不联网。
# BUNDLE_DIR 默认取本脚本所在目录 —— 离线包里脚本和 tarball 是并排放的，
# 客户解开包后直接 ./install-release.sh --offline 即可，不必再指定路径。
OFFLINE_MODE=0
RELEASE_TAG=""
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 安装根目录（docs/claude/install-prefix-plan.md）。不给时按已有安装或默认 ~/.forenyx 确定。
PREFIX_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --license)
            USER_LICENSE="$2"
            shift 2
            ;;
        --prefix)
            if [ -z "${2:-}" ]; then
                echo "错误：--prefix 后面要跟安装目录，例如 --prefix /data/zhang/forenyx" >&2
                exit 1
            fi
            PREFIX_ARG="$2"
            shift 2
            ;;
        --release)
            RELEASE_TAG="$2"
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
            # 不认识的参数一律报错，不跳过：曾有人把 --prefix 漏写成 `--offline /data/zhang`，
            # 被跳过后悄悄装进了默认位置，之后想换位置还得走搬家。这里还没改动任何文件。
            # 先读完 stdin 再退出，理由同下方 abort()（curl | bash 时避免 curl 报写入失败）。
            echo "错误：不认识的参数：$1" >&2
            case "$1" in
                -*) ;;
                *) echo "      要指定安装位置的话，写成：--prefix $1" >&2 ;;
            esac
            echo "      支持的参数：--offline、--prefix <目录>、--license <授权码>、--release <版本>、--bundle <目录>" >&2
            [ -t 0 ] || cat >/dev/null 2>&1 || true
            exit 1
            ;;
    esac
done

# 格式校验放在最前面：拼错一个字符不该让人先等一次授权服务器往返（还可能撞上
# Supabase 冷启动的 15~120 秒退避重试）才被告知。
if [ -n "$RELEASE_TAG" ]; then
    case "$RELEASE_TAG" in
        v[0-9]*.[0-9]*.[0-9]*) ;;
        *)
            echo "错误：--release 格式不对：'$RELEASE_TAG'" >&2
            echo "      应形如 v0.4.1（带 v 前缀的三段版本号）。" >&2
            exit 1
            ;;
    esac
fi

# --release 走的是"向服务端要下载链接再改版本段"这条路，离线安装压根不联网，
# 装哪个版本由包里放的 tarball 决定，两者没法叠加。说清楚，别让人以为生效了。
if [ -n "$RELEASE_TAG" ] && [ "$OFFLINE_MODE" = "1" ]; then
    echo "错误：--release 与 --offline 不能同时使用。" >&2
    echo "      离线安装的版本由离线包内的 tarball 决定。" >&2
    exit 1
fi

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

# 2. Directory Setup
echo -e "${BLUE}[2/5] Setting up directories...${NC}"
# 目录分两层。
#
# 安装根目录（默认 `~/.forenyx/`，可用 --prefix 指定）是**账号级**的：授权文件、
# 心跳缓存、client_id 都放这里，规划中的五个智能体（fnx_spec / fnx_arch / fnx_rtl /
# fnx_dv / fnx_sw）共用同一张授权、同一次心跳。这不只是省事——每个智能体各自心跳
# 的话，服务端会把一台机器看成五个客户端，席位审计和吊销判定都会错。所以一个账号
# 只允许一个根目录，第二个智能体自动装到第一个所在的根目录（§3.2）。
#
# 程序（license-guard.ts）从 wrapper 导出的 FORENYX_HOME 得知根目录，没有时用
# ~/.forenyx（forenyx-root.ts）。
#
# `<根目录>/<智能体名>/` 才是单个智能体自己的：程序本体、wrapper、用户数据。
# 派生新智能体只需要改 AGENT_NAME 一处。
# 本仓库构建的智能体。**必须与 packages/coding-agent/package.json 的
# piConfig.agentName 一致** —— 那是二进制自带的身份，横幅与 --version 从它来；
# 这里的值定目录名、命令名与 PATH。安装脚本在下载解包之前就要用它定目录，
# 没法反过来从 package.json 读，所以两处都写、装完再校验（见第 4 步之后）。
#
# ---- 确定根目录（docs/claude/install-prefix-plan.md §3.2、§3.3）----
# 下面所有判断都在改动任何文件之前完成；不通过就退出，什么都不动。
DEFAULT_ROOT_PHYS=$(fnx_realpath "$HOME/.forenyx")
PREFIX_PHYS=""
if [ -n "$PREFIX_ARG" ]; then
    PREFIX_PHYS=$(fnx_realpath "$PREFIX_ARG")
    if [ -z "$PREFIX_PHYS" ]; then
        echo -e "${RED}❌ 无法解析 --prefix 指定的路径：$PREFIX_ARG${NC}"
        abort 1
    fi
fi

fnx_find_roots
if [ -n "$FNX_FOREIGN" ]; then
    echo -e "${RED}❌ 找到的 Forenyx 安装目录不属于当前账号（$(id -un)）：${NC}"
    printf '%s\n' "$FNX_FOREIGN" | sed 's|^|     |'
    echo -e "${YELLOW}   授权按「机器 + 账号」区分，不能与别的账号共用安装目录。${NC}"
    echo -e "   请检查环境变量 FORENYX_HOME 与 shell 配置文件里的「${FNX_HOME_MARK}」记录。"
    abort 1
fi
if [ -n "$FNX_STALE_VALUES" ]; then
    echo -e "${YELLOW}ℹ 以下安装位置记录已失效（目录不存在或不是 Forenyx 安装目录），已忽略：${NC}"
    printf '%s\n' "$FNX_STALE_VALUES" | sed 's|^|     |'
    if [ -n "${FORENYX_HOME:-}" ] && printf '%s\n' "$FNX_STALE_VALUES" | grep -qxF "$FORENYX_HOME"; then
        echo -e "   当前终端的环境变量 FORENYX_HOME 也指向它；安装完成后请重新打开终端。"
    fi
fi
EXISTING_COUNT=$(printf '%s\n' "$FNX_EXISTING" | grep -c . || true)
if [ "$EXISTING_COUNT" -gt 1 ]; then
    echo -e "${RED}❌ 当前账号有不止一个 Forenyx 安装目录：${NC}"
    printf '%s\n' "$FNX_EXISTING" | sed 's|^|     |'
    echo -e "${YELLOW}   一个账号只能有一个安装目录（各智能体共用一份授权）。请只保留一个：${NC}"
    echo -e "   删掉不用的目录，或修正环境变量 FORENYX_HOME 与 shell 配置文件里的「${FNX_HOME_MARK}」记录后重试。"
    abort 1
fi
if [ -n "$PREFIX_PHYS" ]; then
    if [ "$EXISTING_COUNT" = "1" ] && [ "$FNX_EXISTING" != "$PREFIX_PHYS" ]; then
        echo -e "${RED}❌ 当前账号已经装在 ${FNX_EXISTING}，不能再装到 ${PREFIX_PHYS}。${NC}"
        echo -e "${YELLOW}   一个账号只能有一个安装目录（各智能体共用一份授权）。${NC}"
        echo -e "   要装在原处，用 --prefix ${FNX_EXISTING}（或不写 --prefix）；"
        echo -e "   要换位置，先把整个 $FNX_EXISTING 搬过去（mv），再用新位置重装各个智能体。"
        abort 1
    fi
    ROOT_PHYS="$PREFIX_PHYS"
elif [ "$EXISTING_COUNT" = "1" ]; then
    ROOT_PHYS="$FNX_EXISTING"
else
    ROOT_PHYS="$DEFAULT_ROOT_PHYS"
fi

if [ "$ROOT_PHYS" = "$DEFAULT_ROOT_PHYS" ]; then
    # 默认根目录：wrapper 与 shell 配置里都写作 $HOME/.forenyx（运行时展开），与 0.4.9 相同
    IS_DEFAULT_ROOT=1
    FORENYX_ROOT="$HOME/.forenyx"
    ROOT_SHOW="~/.forenyx"
else
    IS_DEFAULT_ROOT=0
    FORENYX_ROOT="$ROOT_PHYS"
    ROOT_SHOW="$ROOT_PHYS"
    # 这个路径会原样写进 wrapper 与 shell 配置文件，也出现在给用户照抄的命令里
    # （卸载结束时的 rm -rf、--prefix 提示等）：冒号会把 PATH 拆成多段；通配符与 shell
    # 特殊字符照抄时会被展开或解释，rm -rf、chown 可能作用到别的目录。所以一律不允许，
    # 只留字母、数字和 / . _ - + @ % , = ~ 等普通字符（代码审核：通配符路径）。
    case "$ROOT_PHYS" in
        *[[:space:]:\"\'\$\`\\\*\?\[\]\;\&\|\<\>\(\)\{\}\!\#]*)
            echo -e "${RED}❌ 安装目录的路径里不能有空格、冒号、引号、\$、反引号、反斜杠，也不能有 * ? [ ] ; & | < > ( ) { } ! # 等 shell 特殊字符：$ROOT_PHYS${NC}"
            echo -e "   请换一个只含字母、数字和 / . _ - 的路径。"
            abort 1
            ;;
    esac
    if [ -e "$ROOT_PHYS" ] && [ ! -d "$ROOT_PHYS" ]; then
        echo -e "${RED}❌ $ROOT_PHYS 已存在，但不是目录。${NC}"
        abort 1
    fi
    if [ -d "$ROOT_PHYS" ] && ! fnx_is_root "$ROOT_PHYS" \
        && [ -n "$(ls -A "$ROOT_PHYS" 2>/dev/null)" ]; then
        echo -e "${RED}❌ $ROOT_PHYS 不是空目录，也不是 Forenyx 安装目录。${NC}"
        echo -e "${YELLOW}   为免与其中的文件混在一起（卸载时会删除根目录里的 .env 等文件），请指定一个新目录或空目录，${NC}"
        echo -e "   例如 --prefix $ROOT_PHYS/forenyx"
        abort 1
    fi
fi

if [ -d "$ROOT_PHYS" ] && ! fnx_root_mine "$ROOT_PHYS"; then
    echo -e "${RED}❌ 安装目录 $ROOT_SHOW 或其中的标记文件 $FNX_ROOT_MARKER 不属于当前账号（$(id -un)）。${NC}"
    echo -e "${YELLOW}   授权按「机器 + 账号」区分，不能与别的账号共用安装目录。请换一个由你本人创建的目录。${NC}"
    abort 1
fi
# 授权相关文件是符号链接或不属于自己时，在改动任何文件之前停下（默认位置也一样：
# 顺着链接会把授权写到别处，不属于自己的文件到后面设权限时也会失败、留下装了一半的状态）
if [ -d "$ROOT_PHYS" ]; then
    FNX_BAD_FILES=$(fnx_sensitive_problems "$ROOT_PHYS")
    if [ -n "$FNX_BAD_FILES" ]; then
        echo -e "${RED}❌ 安装目录里的以下文件不是你本人的普通文件（符号链接、硬链接、目录或属于他人），已停止，未做任何改动：${NC}"
        printf '%s\n' "$FNX_BAD_FILES" | sed 's|^|     |'
        echo -e "${YELLOW}   请确认内容无误后换成你本人的普通文件（例如 cp 一份再替换），然后重试。${NC}"
        abort 1
    fi
fi

# 上级目录他人可写时，他人可以把根目录改名、再放一个同名目录：只提示，不拦（§3.3）
fnx_parent_warn "$ROOT_PHYS"

# 以上全部通过才开始建目录。umask 077：顺带建出的各级上级目录也只有本人可访问，
# 不会成为新的「他人可写的上级目录」
if ! (umask 077 && mkdir -p "$ROOT_PHYS"); then
    # 最常见的情况是 /data 这类只有 root 能写的位置。给出能直接照做的办法：由管理员建好
    # 安装目录本身并交给本账号（空目录可以直接装）。不建议把上一级交给本账号——
    # --prefix /data/zhang 的上一级是 /data，那不该归某个普通账号。
    echo -e "${RED}❌ 无法创建安装目录 ${ROOT_SHOW}：上一级目录不存在，或你没有写入权限。${NC}"
    echo -e "   请管理员先建好这个目录并交给你（$(id -un)）："
    # 路径按 shell 规则转义后再拼进命令：默认位置的 $HOME 可能含空格、反斜杠。命令作为 %s 的
    # 参数输出，不能交给 echo -e——它会把 %q 产生的 \\ 折叠成 \，照抄后路径就变了。
    fnx_q=$(printf '%q' "$ROOT_PHYS")
    printf "     ${CYAN}%s${NC}\n" "sudo mkdir -p $fnx_q && sudo chown $(id -un) $fnx_q && sudo chmod 700 $fnx_q"
    echo -e "   然后重新执行本命令。也可以换一个你能写入的位置。"
    abort 1
fi
if [ ! -w "$ROOT_PHYS" ]; then
    echo -e "${RED}❌ 安装目录 $ROOT_SHOW 不可写。${NC}"
    abort 1
fi
# 授权文件与 .env 所在的目录只给本人（§3.3 权限）。默认 ~/.forenyx 也一样：
# 0.4.9 由 mkdir -p 创建，umask 为 002 的服务器上同组人可写。
chmod 700 "$ROOT_PHYS"
if ! fnx_clear_acl "$ROOT_PHYS"; then
    if [ "$IS_DEFAULT_ROOT" = "1" ]; then
        echo -e "${YELLOW}⚠ 无法清除 $ROOT_SHOW 上的访问控制列表（ACL），其他账号可能仍能读写其中的授权文件。${NC}"
        echo -e "${YELLOW}  请联系管理员处理（Linux：setfacl -b -k，macOS：chmod -N）。${NC}"
    else
        echo -e "${RED}❌ 无法清除 $ROOT_SHOW 上的访问控制列表（ACL）。${NC}"
        echo -e "   请先手工清除后重试：Linux 用 setfacl -b -k ${ROOT_SHOW}，macOS 用 chmod -N $ROOT_SHOW"
        abort 1
    fi
fi
# 根目录收紧之后再查一次授权相关文件：上面那次检查到收紧之前，组可写的旧根目录里
# 别人仍可能把文件换掉（之后别人就改不了目录里的条目了）。默认根目录清不掉 ACL 时
# 这个窗口一直存在，属于已接受的残余风险（§3.3）。
FNX_BAD_FILES=$(fnx_sensitive_problems "$ROOT_PHYS")
if [ -n "$FNX_BAD_FILES" ]; then
    echo -e "${RED}❌ 安装目录里的以下文件在检查之后被改动，不再是你本人的普通文件，已停止：${NC}"
    printf '%s\n' "$FNX_BAD_FILES" | sed 's|^|     |'
    echo -e "${YELLOW}   可能有人在改动安装目录。除收紧了安装目录本身的权限外未做其他改动，请确认后重试。${NC}"
    abort 1
fi
# 已有的授权相关文件先收紧（写入任何东西之前，§3.3 权限）：清不掉 ACL 时自定义根目录
# 在这里就停下，不留装了一半的状态。新建的文件在安装末尾再设一次。
for fnx_f in "$ROOT_PHYS/$FNX_ROOT_MARKER" "$ROOT_PHYS/.env" "$ROOT_PHYS/forenyx.lic"; do
    [ -f "$fnx_f" ] || continue
    chmod 600 "$fnx_f"
    if ! fnx_clear_acl "$fnx_f"; then
        if [ "$IS_DEFAULT_ROOT" = "1" ]; then
            echo -e "${YELLOW}⚠ 无法清除 $fnx_f 上的访问控制列表（ACL），其他账号可能仍能读写它。请联系管理员处理。${NC}"
        else
            echo -e "${RED}❌ 无法清除 $fnx_f 上的访问控制列表（ACL）。${NC}"
            echo -e "   请先手工清除后重试：Linux 用 setfacl -b -k，macOS 用 chmod -N。"
            abort 1
        fi
    fi
done
if [ ! -f "$ROOT_PHYS/$FNX_ROOT_MARKER" ]; then
    fnx_marker_write "$ROOT_PHYS" || {
        echo -e "${RED}❌ 无法写入 $ROOT_SHOW/$FNX_ROOT_MARKER${NC}"; abort 1; }
fi
echo -e "  - Install root: ${GREEN}$ROOT_SHOW${NC}"

FORENYX_DIR="$FORENYX_ROOT/$AGENT_NAME"
BIN_DIR="$FORENYX_DIR/bin"
LIBEXEC_DIR="$FORENYX_DIR/libexec"
AGENT_DIR="$FORENYX_DIR/agent"

# ---------------------------------------------------------------------------
# 产物身份校验：包/源码自带的 piConfig.agentName 必须等于本脚本的 AGENT_NAME。
#
# **三份安装脚本（install.sh / install-release.sh / install-release_test.sh）各有一份
# 一模一样的副本** —— 它们都以 `curl … | bash` 单文件分发，没法 source 公共文件。
# 改这个函数要改三处。
#
# 拦的是"装成了别的产品"：发布仓库写错、REPO_URL/remote 指向别的智能体、或者本产品
# 某版本的 tar.gz 还没上传、自动路径退到了别的产品的下载地址（真实发生过）。
# 调用点必须在动目标目录**之前**：发现不对时现有安装要一个字节都没被改。
#
# 解析优先 python3。退化的 sed+cut 那套是按引号数字段位置，package.json 一旦压成一行
# 就会取到别的字段的值（实测取到了顶层 "name"），那会让这道闸对所有安装都误报。
# ---------------------------------------------------------------------------
verify_agent_identity() {
    local pkg="$1"
    local built=""
    [ -f "$pkg" ] || return 0        # 没有 package.json（旧版产物）不拦，只是查不了
    if command -v python3 >/dev/null 2>&1; then
        built=$(python3 -c "
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
print((d.get('piConfig') or {}).get('agentName', ''))
" "$pkg" 2>/dev/null || echo "")
    fi
    if [ -z "$built" ]; then
        built=$(grep -o '"agentName"[[:space:]]*:[[:space:]]*"[^"]*"' "$pkg" 2>/dev/null \
            | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    fi
    [ -n "$built" ] || return 0
    if [ "$built" != "$AGENT_NAME" ]; then
        echo -e "${RED}❌ 智能体名不一致：本脚本装的是 '$AGENT_NAME'，"
        echo -e "   而拿到的产物自带的是 '$built'。${NC}"
        echo -e "${YELLOW}   多半是发布仓库/源码仓库指错了产品，或者本版本的安装包还没上传、"
        echo -e "   退到了别的产品的下载地址。已中止，现有安装未被改动。${NC}"
        rm -rf /tmp/forenyx
        abort 1
    fi
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
    echo -e "${YELLOW}   新版把每个智能体装进 $ROOT_SHOW/<智能体名>/，与旧布局不能并存。${NC}"
    echo
    # 旧布局上根本没有 $AGENT_NAME 这个命令——那是这次要装的新命令名。这台机器
    # 手里的是旧 wrapper（历来叫 forenyx）。从磁盘上实际找出来，别让人去敲一个
    # 不存在的命令。
    LEGACY_CMD=""
    for c in "$FORENYX_ROOT"/bin/*; do
        if [ -f "$c" ] && [ -x "$c" ]; then
            LEGACY_CMD="$(basename "$c")"
            break
        fi
    done
    LEGACY_CMD="${LEGACY_CMD:-forenyx}"

    echo -e "   请先清理旧版："
    echo -e "     ${CYAN}${LEGACY_CMD} uninstall${NC}   （选择不保留数据，或按下面手工清）"
    echo -e "   手工清理："
    echo -e "     ${CYAN}rm -rf $ROOT_SHOW/bin $ROOT_SHOW/libexec${NC}"
    echo -e "     然后删掉 ~/.bashrc（或 .zshrc）里这一行："
    echo -e "     ${CYAN}export PATH=\"\$HOME/.forenyx/bin:\$PATH\"${NC}"
    echo
    echo -e "${YELLOW}   旧版的用户数据在 $ROOT_SHOW/agent/，新版不会自动搬。${NC}"
    echo -e "   需要保留 API key 与会话历史的话，清理完再执行一次本脚本，装好后："
    echo -e "     ${CYAN}cp -r $ROOT_SHOW/agent/. $ROOT_SHOW/$AGENT_NAME/agent/${NC}"
    echo
    echo -e "${YELLOW}   授权文件 $ROOT_SHOW/forenyx.lic 与 .env 不用动，新版仍然用它们。${NC}"
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
    # 授权码可选（离线包通用化，docs/claude/offline-generic-bundle-plan.md §3.E）。
    #
    # 通用离线包在拿到授权之前就要能装上：客户先装，再用 hostid 换授权文件、用
    # `<智能体> license import` 导入。不带 --license 时 .env 里不写授权码，客户端
    # 改从已验签的授权文件里取（license-guard.ts 的 resolveCredentials），所以
    # 通网后心跳用的仍是真实授权码，不会出现早先占位符 OFFLINE 被服务端 403 的问题。
    #
    # 授权的强制点在启动时，安装阶段不拦。
    EXPIRE_DISPLAY=""

    echo -e "  - Extracting to $LIBEXEC_DIR..."
    # 同在线分支：先解包验身份，确认是本产品的包再清 $LIBEXEC_DIR。
    # 离线包是人工拷过来的，拷错产品的概率不比自动路径低。
    rm -rf /tmp/forenyx
    if ! tar -xzf "$TMP_TARBALL" -C /tmp/; then
        echo -e "${RED}Error: Failed to extract installation archive.${NC}"
        exit 1
    fi
    verify_agent_identity /tmp/forenyx/package.json
    rm -rf "$LIBEXEC_DIR"/*
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
                echo -e "${YELLOW}  - 警告: 离线包中缺少 ${t}，文件查找/文本搜索功能将不可用${NC}"
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
    # 通用离线包不带授权文件，这是常态：安装照常完成，结束时打印 hostid 与导入方法
    # （见脚本末尾 NEED_LIC）。只有 make-offline-bundle.sh --lic 打出的定制包才带。
    #
    # 带了就必须落到位，写失败当场报错 —— 包里明明有授权，装完却打不开，现场很难
    # 想到是写盘失败。不校验签名：私钥在服务端，验签是客户端启动时的事。
    #
    # 提示里不出现授权文件的存放路径（用户决定 D2）：导入一律走 license import。
    NEED_LIC=0
    if [ -f "$BUNDLE_DIR/forenyx.lic" ]; then
        if cp -f "$BUNDLE_DIR/forenyx.lic" "$FORENYX_ROOT/forenyx.lic.tmp" \
           && chmod 600 "$FORENYX_ROOT/forenyx.lic.tmp" \
           && mv -f "$FORENYX_ROOT/forenyx.lic.tmp" "$FORENYX_ROOT/forenyx.lic"; then
            echo -e "  - ${GREEN}✓ 已安装随包附带的授权文件${NC}"
        else
            rm -f "$FORENYX_ROOT/forenyx.lic.tmp"
            echo -e "${RED}❌ 随包附带的授权文件写入失败${NC}"
            echo -e "${YELLOW}   请检查磁盘空间与目录权限后重装。${NC}"
            exit 1
        fi
    elif [ -f "$FORENYX_ROOT/forenyx.lic" ]; then
        # 重装/升级场景：包里没带，但机器上已经有一份（上次导入、安装或心跳留下的）。
        # 保留它，别把能用的机器装成不能用的。
        echo -e "  - ${CYAN}ℹ 沿用本机已有的授权文件${NC}"
    else
        NEED_LIC=1
    fi
else

# License Verification
if [ -z "$USER_LICENSE" ] && [ -f "$FORENYX_ROOT/.env" ]; then
    USER_LICENSE=$(env_get FORENYX_LICENSE_KEY "$FORENYX_ROOT/.env")
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

# 服务端给的地址从此只作两件事：判定授权是否通过（上面那个 -z 判断），以及在
# 客户端拼不出地址时兜底。真正下载哪个包由本脚本自己决定——见下方「下载地址」。
SERVER_URL="$DOWNLOAD_URL"

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
    # 路径由环境变量传入：根目录可能是 --prefix 指定的（install-prefix-plan.md 实施记录）
    if echo "$RESPONSE" | FNX_LIC_PATH="$FORENYX_ROOT/forenyx.lic" python3 -c "
import sys, json, os
d = json.load(sys.stdin)
f = d.get('license_file')
if not isinstance(f, dict):
    raise SystemExit(1)
path = os.environ['FNX_LIC_PATH']
tmp = path + '.tmp'
with open(tmp, 'w') as fh:
    json.dump(f, fh, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)          # 原子替换，避免读到半截文件
" 2>/dev/null; then
        echo -e "  - ${GREEN}✓ 已写入授权文件 $ROOT_SHOW/forenyx.lic${NC}"
    fi
fi

# 有效期信息拼进同一行，避免与下方提示重复成两行
if [ -n "$EXPIRE_DISPLAY" ]; then
    echo -e "  - ${GREEN}✓ 授权码验证成功！已换取专用下载链接。（有效期至：${EXPIRE_DISPLAY}）${NC}"
else
    echo -e "  - ${GREEN}✓ 授权码验证成功！已换取专用下载链接。${NC}"
fi

TARBALL_NAME="forenyx-$PLATFORM.tar.gz"
# -----------------------------------------------------------------------------
# 下载地址
#
# 由本脚本自己拼，不用服务端返回的那个：
#
#   https://github.com/<RELEASES_REPO>/releases/download/<tag>/forenyx-<平台>.tar.gz
#
# 这么做是为了让「加一个智能体」只涉及本仓库：建发布仓库、改 RELEASES_REPO 常量，
# 服务端一行不用动。服务端返回的 download_url 里本来就是公开的 GitHub 地址，
# 它没有在把关下载——把关的是它前面那一步授权校验。让它同时决定「下载哪个包」，
# 等于把五个智能体的发布路由塞进授权服务，每加一个都要回去改。
#
# 版本从发布仓库的 version.json 取；`--release` 显式指定时以它为准。
# 拼不出来（比如 version.json 拉不到）就退回服务端给的地址，保证不比原先更差。
# -----------------------------------------------------------------------------
TARGET_TAG="$RELEASE_TAG"

if [ -z "$TARGET_TAG" ]; then
    VERSION_JSON=$(curl -fsSL --connect-timeout 10 --max-time 20 \
        "https://raw.githubusercontent.com/$RELEASES_REPO/main/version.json" 2>/dev/null || echo "")
    # 有 python3 就正经解析。退化到 grep 时也要锚定 "version" 后面紧跟的冒号与引号，
    # 否则 note 字段里出现 "version" 字样（发版说明里很常见）就会取到错误的值。
    if command -v python3 >/dev/null 2>&1; then
        TARGET_TAG=$(echo "$VERSION_JSON" | python3 -c \
            "import sys, json; print(json.load(sys.stdin).get('version', ''))" 2>/dev/null || echo "")
    else
        TARGET_TAG=$(echo "$VERSION_JSON" \
            | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
fi

if [ -n "$TARGET_TAG" ]; then
    # tag 一律带 v 前缀；version.json 里万一写成 0.1.0 也能用
    case "$TARGET_TAG" in
        v*) ;;
        *)  TARGET_TAG="v$TARGET_TAG" ;;
    esac
    DOWNLOAD_URL="https://github.com/$RELEASES_REPO/releases/download/$TARGET_TAG/forenyx-$PLATFORM.tar.gz"

    # 先探再下。不探的话，版本不存在时 GitHub 返回的是一个 404 页面，curl -f 报的是
    # "下载失败，请检查网络"——把人指向完全错误的方向。
    if ! curl -fsIL --max-time 20 "$DOWNLOAD_URL" >/dev/null 2>&1; then
        echo -e "${RED}❌ 找不到 $TARGET_TAG 的 $PLATFORM 安装包。${NC}"
        echo -e "${YELLOW}   请确认该版本已发布对应平台的安装包。${NC}"
        if [ -n "$RELEASE_TAG" ]; then
            echo -e "${YELLOW}   可能是 --release 写错了版本号，或该版本没发这个平台的产物。${NC}"
            abort 1
        fi
        echo -e "${YELLOW}   version.json 声明的版本尚未发布附件，改用服务端提供的地址。${NC}"
        DOWNLOAD_URL="$SERVER_URL"
    elif [ -n "$RELEASE_TAG" ]; then
        echo -e "  - ${YELLOW}注意：本次安装的是指定版本 ${TARGET_TAG}，不是云端最新版。${NC}"
        echo -e "    ${YELLOW}启动时仍会提示有新版本；执行 ${AGENT_NAME} update 会升回最新。${NC}"
    fi
else
    echo -e "${YELLOW}⚠ 取不到版本信息，改用服务端提供的下载地址。${NC}"
    DOWNLOAD_URL="$SERVER_URL"
fi

# 打印下载地址时隐去仓库归属，只留路径。
#
# 发布仓库名对客户是实现细节，没必要出现在安装日志里（截图外发、贴issue 时尤其）。
# 注意这只是**不显示**，不是保密：脚本本身是公开 curl 下来的，地址就写在里面。
short_url() {
    local rest="${1#https://github.com/*/*/}"
    # 没匹配上（非 GitHub 地址，如服务端兜底给的）就原样返回，那种情况反而要看全
    [ "$rest" = "$1" ] && printf '%s' "$1" || printf '/%s' "$rest"
}

echo -e "  - Downloading binaries from $(short_url "$DOWNLOAD_URL")..."
TMP_TARBALL="/tmp/$TARBALL_NAME"

# Download with curl
if ! curl -f -L --progress-bar "$DOWNLOAD_URL" -o "$TMP_TARBALL"; then
    echo -e "${RED}Error: Download failed! Please check your network connection or verify the release asset is uploaded.${NC}"
    exit 1
fi

echo -e "  - Extracting to $LIBEXEC_DIR..."
# Extract tarball.
# The tarball contains a folder named "forenyx", inside which has all the files.
#
# **先解到 /tmp 并验身份，再清 $LIBEXEC_DIR。** 顺序反过来的话，下到一个别的产品的
# 包（或者半截文件）就已经把现有安装删干净了，而校验只能在那之后报错、无从回滚。
rm -rf /tmp/forenyx
if ! tar -xzf "$TMP_TARBALL" -C /tmp/; then
    echo -e "${RED}Error: Failed to extract installation archive.${NC}"
    rm -f "$TMP_TARBALL"
    exit 1
fi
verify_agent_identity /tmp/forenyx/package.json

# Clean old installation binaries only after the archive checked out
rm -rf "$LIBEXEC_DIR"/*

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
# 授权码这一行。只有「离线安装且未带 --license」时为空（在线分支在授权校验之前就
# 拒绝了空授权码）：此时不写空的 FORENYX_LICENSE_KEY=，授权码由客户端从导入的授权文件里取。
if [ -n "$USER_LICENSE" ]; then
    LICENSE_LINE="FORENYX_LICENSE_KEY=$USER_LICENSE"
else
    LICENSE_LINE="# FORENYX_LICENSE_KEY 未设置：授权码取自导入的授权文件（$AGENT_NAME license import）"
fi
if [ ! -f "$GLOBAL_ENV_FILE" ]; then
    echo -e "  - Initializing global user configuration file $ROOT_SHOW/.env..."
    cat << EOF > "$GLOBAL_ENV_FILE"
# =============================================================================
# Forenyx AI 全局配置（$ROOT_SHOW/.env）
#
# 本机所有智能体（fnx_dv / fnx_rtl / ...）共用这一份。
# 两组配置作用完全不同，改动前先看清在哪一节。
# =============================================================================

# -----------------------------------------------------------------------------
# 一、授权 —— 请勿手工修改
#
# 由安装脚本写入，license-guard 与 wrapper 按文件读取。
# CLIENT_ID 在首次安装时算出并与服务端绑定：改了或删了会导致心跳返回 403
# 「跨设备冒用」，届时需要联系管理员解绑才能恢复。
# -----------------------------------------------------------------------------
$LICENSE_LINE
FORENYX_CLIENT_ID=$CLIENT_ID

# -----------------------------------------------------------------------------
# 二、文档转换的视觉模型 —— 需要你自己填
#
# 供 ic-docx2md 分析 Word / PDF 里的图片（scripts/docx2md.py 用 python-dotenv
# 直接读本文件）。不填的话该 skill 会在开始前终止并提示来这里配置。
#
# 注意：这与 CLI 对话用的模型是两套配置。对话模型走 CLI 内的 /login，写在
# $ROOT_SHOW/<智能体名>/agent/auth.json，每个智能体各自一份；这里填的只管
# 文档转换，且五个智能体共用。
# -----------------------------------------------------------------------------
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
    #
    # 离线安装未带 --license：删掉旧授权码。授权码改由导入的授权文件提供；留着旧码，
    # 客户端会优先拿它发心跳，与新导入的授权文件不一致时服务端返回 403。删除放在这里
    # （解包与工具安装都已成功之后），中途失败不会先丢掉旧凭据。
    #
    # 匹配允许行首空白、删除所有匹配行：客户端读 .env 时先去掉行首空白再取第一个匹配
    # （license-guard.ts 的 readEnvValue），手改出的缩进行或重复行若漏删，客户端照样读到旧码。
    if [ -z "$USER_LICENSE" ]; then
        if env_has FORENYX_LICENSE_KEY "$GLOBAL_ENV_FILE"; then
            echo -e "  - 未提供授权码，移除 $ROOT_SHOW/.env 中原有的授权码（改由导入的授权文件提供）"
            env_del FORENYX_LICENSE_KEY "$GLOBAL_ENV_FILE" || exit 1
        fi
    elif env_has FORENYX_LICENSE_KEY "$GLOBAL_ENV_FILE"; then
        # 按客户端的读法取「现在生效的旧码」（第一个匹配行，允许缩进与引号），
        # 与它比较；不同就改写第一行、删掉其余匹配行，见 env_set。
        OLD_LICENSE=$(env_get FORENYX_LICENSE_KEY "$GLOBAL_ENV_FILE")
        if [ "$OLD_LICENSE" != "$USER_LICENSE" ]; then
            echo -e "  - 授权码已变更，更新 $ROOT_SHOW/.env（${OLD_LICENSE} → ${USER_LICENSE}）"
            env_set FORENYX_LICENSE_KEY "$USER_LICENSE" "$GLOBAL_ENV_FILE" || exit 1
        fi
    else
        echo -e "  - Saving license key to $ROOT_SHOW/.env..."
        env_set FORENYX_LICENSE_KEY "$USER_LICENSE" "$GLOBAL_ENV_FILE" || exit 1
    fi

    # client_id 相反：**有值就绝不能改**。它在首次安装时算出并与服务端绑定，
    # 重算会得到不同的值（machine-id 或 $USER 变化都会），导致心跳 403「跨设备冒用」。
    #
    # 但「有这一行」不等于「有值」：只看行在不在的话，残留的 `FORENYX_CLIENT_ID=`
    # 空行会让重装永远补不回设备标识，而客户端与 license import 遇到缺设备标识时给出
    # 的恢复办法正是「重新运行安装脚本」。所以按客户端的读法判断（允许行首空白、取第
    # 一个匹配、去引号与空白）：为空或缺失才写入本次算出的值，并先删掉那些空行。
    EXISTING_CID=$(env_get FORENYX_CLIENT_ID "$GLOBAL_ENV_FILE")
    if [ -z "$EXISTING_CID" ]; then
        if env_has FORENYX_CLIENT_ID "$GLOBAL_ENV_FILE"; then
            echo -e "  - $ROOT_SHOW/.env 中的设备标识为空，按本机重新写入"
            env_del FORENYX_CLIENT_ID "$GLOBAL_ENV_FILE" || exit 1
        fi
        env_set FORENYX_CLIENT_ID "$CLIENT_ID" "$GLOBAL_ENV_FILE" || exit 1
    fi
fi

# wrapper 靠这个标记跳过版本检查与在线更新。离线机器上那些 curl 只会白等超时，
# 还会把"连不上更新服务器"这种正常状态报成异常。
#
# 已有这一行但不是 1（手改过，或旧版本留下的 0）时要改成 1：客户端是否启动会话内
# 复查只看它是否恰为 1，不规范化的话离线机器会每 5 分钟发一次必失败的心跳。
#
# 已有就把**每一行**都改写成不缩进的 FORENYX_OFFLINE=1，不能因为「已经有一行 =1」就
# 跳过：客户端去掉行首空白后取第一个匹配，前面若还有一行 =0 就读到 0；而 wrapper 判断
# 离线用的是行首匹配，缩进行它认不出。改写成统一格式两边都能读对。
if [ "$OFFLINE_MODE" = "1" ]; then
    if env_has FORENYX_OFFLINE "$GLOBAL_ENV_FILE"; then
        env_set FORENYX_OFFLINE 1 "$GLOBAL_ENV_FILE" || exit 1
    else
        env_set FORENYX_OFFLINE 1 "$GLOBAL_ENV_FILE" || exit 1
    fi
else
    # 从离线转回在线安装时要清掉，否则更新功能会一直被禁用。
    # 允许行首空白，与上面离线分支一致：客户端读 .env 时先去掉行首空白，手改出的缩进行
    # 若漏删，客户端仍会认为是离线部署（不启动会话内复查）。
    env_del FORENYX_OFFLINE "$GLOBAL_ENV_FILE" || exit 1
fi

# 授权相关文件只给本人读写（§3.3 权限）。.env 此前没有设权限，随 umask，可能组可读写。
# 额外 ACL 一并清除；清不掉时自定义根目录停止，默认根目录警告（接受的残余风险）。
for fnx_f in "$GLOBAL_ENV_FILE" "$FORENYX_ROOT/$FNX_ROOT_MARKER" "$FORENYX_ROOT/forenyx.lic"; do
    [ -f "$fnx_f" ] || continue
    chmod 600 "$fnx_f"
    if ! fnx_clear_acl "$fnx_f"; then
        if [ "$IS_DEFAULT_ROOT" = "1" ]; then
            echo -e "${YELLOW}⚠ 无法清除 $fnx_f 上的访问控制列表（ACL），其他账号可能仍能读写它。请联系管理员处理。${NC}"
        else
            echo -e "${RED}❌ 无法清除 $fnx_f 上的访问控制列表（ACL）。${NC}"
            echo -e "   请先手工清除后重试：Linux 用 setfacl -b -k，macOS 用 chmod -N。"
            exit 1
        fi
    fi
done

# 再查一次装到位的产物。解包时已经查过同一件事（verify_agent_identity），这里查的是
# "cp 之后 libexec 里真正躺着的东西"——cp 拷了一半、或者 libexec 里混进了上一次安装的
# 残留，都只有这一刻看得见。成本是读一个文件。
verify_agent_identity "$LIBEXEC_DIR/package.json"

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

# 安装根目录（docs/claude/install-prefix-plan.md §3.4）：授权文件与心跳缓存，各智能体共用。
#   默认位置：写作 $HOME/.forenyx，运行时按当时的 $HOME 展开，与 0.4.9 相同；
#   --prefix 指定的位置：写死绝对路径（不依赖 shell 配置文件，LSF/bsub 下也找得到文件）。
# 两种都导出 FORENYX_HOME，覆盖终端里继承来的旧值，程序与 wrapper 永远用同一个根目录。
# 路径已在 3.3 中排除了空格、引号、$ 等字符，可以直接放进双引号。
if [ "$IS_DEFAULT_ROOT" = "1" ]; then
    {
        echo '# 安装根目录：默认位置（运行时按 $HOME 展开）'
        echo 'FORENYX_ROOT="$HOME/.forenyx"'
        echo 'FNX_IS_CUSTOM_ROOT=0'
    } >> "$WRAPPER_FILE"
else
    {
        echo "# 安装根目录：安装时用 --prefix 指定。搬动这个目录后要用新位置重新安装（§3.9）"
        echo "FORENYX_ROOT=\"$FORENYX_ROOT\""
        echo 'FNX_IS_CUSTOM_ROOT=1'
    } >> "$WRAPPER_FILE"
fi
echo 'export FORENYX_HOME="$FORENYX_ROOT"' >> "$WRAPPER_FILE"

# 读 .env 的函数与安装器共用同一份（declare 原样输出），规则见 ENV_PL 上方的说明。
declare -p ENV_PL >> "$WRAPPER_FILE"
declare -f env_selftest env_get env_has >> "$WRAPPER_FILE"
# 卸载要做的根目录检查与 shell 配置清理，同样原样带上（ROOT_FN 段）。
declare -p FNX_RC_FILES FNX_PATH_MARK_PREFIX FNX_HOME_MARK FNX_ROOT_MARKER FNX_PL >> "$WRAPPER_FILE"
declare -f fnx_realpath fnx_my_uid fnx_uid_of fnx_mode_of fnx_has_acl fnx_clear_acl fnx_is_root \
    fnx_marker_get fnx_root_mine fnx_sensitive_problems fnx_rc_is_csh fnx_rc_homes fnx_rc_edit fnx_rc_remove_path \
    fnx_perm_check >> "$WRAPPER_FILE"

cat << 'EOF' >> "$WRAPPER_FILE"
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
# 无法判断（perl 自检失败，或 .env 缺失、不可读、读取失败）时 OFFLINE_UNKNOWN=1，各入口据此停止。
# 不能只看 command -v：perl 存在但执行失败时，$(...) 会把错误吞成空值，被误判为在线。
# .env 缺失或不可读时 env_get 会返回成功的空值，不能据此判为在线，所以先单独检查文件。
IS_OFFLINE=0
OFFLINE_UNKNOWN=0
if ! env_selftest; then
    OFFLINE_UNKNOWN=1
elif [ ! -f "$FORENYX_ROOT/.env" ] || [ ! -r "$FORENYX_ROOT/.env" ]; then
    OFFLINE_UNKNOWN=1
elif OFFLINE_VAL=$(env_get FORENYX_OFFLINE "$FORENYX_ROOT/.env"); then
    if [ "$OFFLINE_VAL" = "1" ]; then IS_OFFLINE=1; fi
else
    OFFLINE_UNKNOWN=1
fi

## Command interceptors
case "$1" in
    --version|-v)
        # 读不了 .env 就无法判断是否离线，不能按在线处理去访问网络
        if [ "$OFFLINE_UNKNOWN" = "1" ]; then
            echo "❌ 无法判断离线状态（perl 自检失败，或 $FORENYX_ROOT/.env 缺失、不可读、读取失败）。请检查 perl；若 .env 缺失或不可读，请重新运行安装脚本恢复。" >&2
            exit 1
        fi
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
            LATEST_VERSION=$(echo "$VERSION_DATA" \
            | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
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
        if [ "$OFFLINE_UNKNOWN" = "1" ]; then
            echo "❌ 无法判断离线状态（perl 自检失败，或 $FORENYX_ROOT/.env 缺失、不可读、读取失败）。请检查 perl；若 .env 缺失或不可读，请重新运行安装脚本恢复。" >&2
            exit 1
        fi
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
        
        LATEST_VERSION=$(echo "$VERSION_DATA" \
            | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
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
            LOCAL_LICENSE=$(env_get FORENYX_LICENSE_KEY "$FORENYX_ROOT/.env")
        fi

        # 安装位置（docs/claude/install-prefix-plan.md §3.6）：
        #   自定义根目录 → 传 --prefix，装回原处；
        #   默认根目录 → 不传（与 0.4.9 相同，$HOME 含空格也不受 --prefix 的字符限制），
        #     先清掉 FORENYX_HOME，免得安装器把它当成「已有安装」的线索（wrapper 刚导出的是默认值，
        #     终端里继承来的旧值也一并清掉）。
        FNX_UPDATE_ARGS=(--license "$LOCAL_LICENSE")
        if [ "$FNX_IS_CUSTOM_ROOT" = "1" ]; then
            FNX_UPDATE_ARGS+=(--prefix "$FORENYX_ROOT")
        else
            unset FORENYX_HOME
        fi
        if ! curl -fsSL --connect-timeout 5 "https://raw.githubusercontent.com/$RELEASES_REPO/main/install.sh" | bash -s -- "${FNX_UPDATE_ARGS[@]}"; then
            echo -e "\033[0;31mError: Update failed during execution of the remote install script.\033[0m"
            exit 1
        fi
        exit 0
        ;;
    uninstall)
        echo -e "\033[0;31m=====================================================\033[0m"
        echo -e "\033[0;31m\033[1m      Uninstalling $APP_DISPLAY_NAME — $AGENT_NAME\033[0m"
        echo -e "\033[0;31m=====================================================\033[0m"
        
        # y/n 问题只接受 y/n（yes/no，大小写均可）或回车取默认，其他输入提示后重问。
        # 原先只认 y：「保留数据？」手滑输错一个字母就当成「不保留」，整个智能体目录被删。
        # 读到输入结束（没有终端、管道已空）时按默认处理，不会死循环。
        confirm_yn() {
            local __var="$1" __prompt="$2" __default="$3" __reply
            while :; do
                echo -en "$__prompt"
                if ! read -r __reply; then __reply=""; echo; fi
                case "$(printf '%s' "${__reply:-$__default}" | tr 'A-Z' 'a-z')" in
                    y|yes) printf -v "$__var" '%s' y; return 0 ;;
                    n|no) printf -v "$__var" '%s' n; return 0 ;;
                    *) echo -e "\033[0;33m  请输入 y 或 n（直接回车为 ${__default}）。\033[0m" ;;
                esac
            done
        }

        # ---- 删除任何东西之前的检查（docs/claude/install-prefix-plan.md §3.3、§3.7）----
        FNX_ROOT_SHOW="$FORENYX_ROOT"
        [ "$FNX_IS_CUSTOM_ROOT" = "1" ] || FNX_ROOT_SHOW="~/.forenyx"
        if [ -d "$FORENYX_ROOT" ] && ! fnx_root_mine "$FORENYX_ROOT"; then
            echo -e "\033[0;31m❌ 安装目录 $FNX_ROOT_SHOW 不属于当前账号，已停止，未删除任何文件。\033[0m" >&2
            exit 1
        fi
        fnx_perm_check "$FORENYX_ROOT" "$((1 - FNX_IS_CUSTOM_ROOT))" || exit 1

        echo -e "  Uninstalling agent: \033[1m$AGENT_NAME\033[0m ($FNX_ROOT_SHOW/$AGENT_NAME/)"
        echo -e "\033[0;33mWould you like to keep your custom skills and configuration data?\033[0m"
        echo -e "  Skills path: $FNX_ROOT_SHOW/$AGENT_NAME/agent/skills/custom/"
        echo -e "  Configurations path: $FNX_ROOT_SHOW/$AGENT_NAME/agent/ (settings.json, auth.json, sessions/)"
        confirm_yn KEEP_DATA "Keep these files? (y/n, default: y): " y
        
        if [ "$KEEP_DATA" = "y" ]; then
            echo -e "\033[0;34mKeeping configurations and skills. Cleaning binaries...\033[0m"
            rm -rf "$BIN_DIR" "$LIBEXEC_DIR"
            echo -e "  - Cleared binaries and wrappers for $AGENT_NAME."
        else
            echo -e "\033[0;31mDeleting all data for agent $AGENT_NAME...\033[0m"
            rm -rf "$FORENYX_DIR"
            echo -e "  - Cleared $FNX_ROOT_SHOW/$AGENT_NAME/."
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
            echo -e "  - 本机还有 $REMAINING 个智能体，保留共用的授权文件 $FNX_ROOT_SHOW/forenyx.lic"
        elif [ -f "$FORENYX_ROOT/forenyx.lic" ] || [ -f "$FORENYX_ROOT/.env" ]; then
            echo -e "\033[0;33m本机已无其它智能体。是否一并删除授权文件与授权配置？\033[0m"
            echo -e "  $FNX_ROOT_SHOW/forenyx.lic, $FNX_ROOT_SHOW/.env"
            echo -e "  \033[0;33m删除后重装需要重新激活（内网机器需重新申请 .lic）。\033[0m"
            confirm_yn DEL_LIC "Delete license data? (y/n, default: n): " n
            if [ "$DEL_LIC" = "y" ]; then
                rm -f "$FORENYX_ROOT/forenyx.lic" "$FORENYX_ROOT/.env" \
                      "$FORENYX_ROOT/.heartbeat_cache" "$FORENYX_ROOT/.offline_runs" \
                      "$FORENYX_ROOT/.offline_batch" "$FORENYX_ROOT/.heartbeat_probe" \
                      "$FORENYX_ROOT/.license_state"
                echo -e "  - Cleared license data."
            else
                echo -e "  - Kept license data."
            fi
        fi
        
        # Cleanup PATH：所有常见配置文件里本智能体的 PATH 行都删（§3.5）。按标记删，
        # 不按路径字符串——根目录不一定叫 forenyx。别的智能体的行、FORENYX_HOME 记录不动：
        # 留着记录，下次不带 --prefix 重装仍能回到这个根目录。
        fnx_rc_remove_path
        echo -e "  - Removed $AGENT_NAME PATH configuration from shell config files."

        echo -e "\033[0;32m\033[1m$AGENT_NAME has been successfully uninstalled!\033[0m"
        # 告诉用户留下了什么（§3.7）
        if [ -d "$FORENYX_ROOT" ] && [ -n "$(ls -A "$FORENYX_ROOT" 2>/dev/null)" ]; then
            echo -e "  安装目录 $FNX_ROOT_SHOW 仍保留：$(ls -A "$FORENYX_ROOT" 2>/dev/null | tr '\n' ' ')"
            echo -e "  重装时会自动装回这里；彻底清理请删除整个目录：\033[0;36mrm -rf $FNX_ROOT_SHOW\033[0m"
        fi
        exit 0
        ;;
esac

# 普通启动也必须知道是否离线：缺 perl 时读不了 .env，IS_OFFLINE 只会是 0，
# 上游会去做版本检查或下载工具。无法判断就直接停止，不按在线处理。
# 卸载与 --version/update 已在上面的 case 里处理并退出，不受这里影响。
# `license import` 放行的是这道离线判断：cli.ts 在授权校验之前执行并退出，不经过离线逻辑。
# 注意：普通授权（非 admin）导入仍要读取 .env 中的 client_id，缺失时 CLI 会拒绝并提示重新安装。
# 放行只是不让这道判断拦住离线用户拿到 .lic 后无法导入。--help 暂不放行，见清单记录。
if [ "$OFFLINE_UNKNOWN" = "1" ] && ! { [ "${1:-}" = "license" ] && [ "${2:-}" = "import" ]; }; then
    echo "❌ 无法判断离线状态（perl 自检失败，或 .env 缺失、不可读、读取失败），已停止运行。请检查 perl；若 .env 缺失或不可读，请重新运行安装脚本恢复。" >&2
    exit 1
fi

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
# 按标记改 shell 配置文件（docs/claude/install-prefix-plan.md §3.5）。顺序：
#   1) 删掉指向失效位置的 FORENYX_HOME 记录（所有配置文件）；
#   2) 默认根目录 → 删掉全部 FORENYX_HOME 记录；自定义根目录 → 当前 shell 的配置文件里
#      写入、其余已有记录的文件里就地更新（第二个智能体不带 --prefix 也能找回这里）；
#   3) PATH 行：当前 shell 的配置文件里写入或更新，其余已有本智能体 PATH 行的文件里
#      就地更新——换过位置后，旧文件里不能还指着原来的路径。
SHELL_NAME=$(basename "$SHELL")
case "$SHELL_NAME" in
    zsh) RC_FILE="$HOME/.zshrc" ;;
    bash) if [ -f "$HOME/.bash_profile" ]; then RC_FILE="$HOME/.bash_profile"; else RC_FILE="$HOME/.bashrc"; fi ;;
    csh|tcsh) if [ -f "$HOME/.tcshrc" ]; then RC_FILE="$HOME/.tcshrc"; else RC_FILE="$HOME/.cshrc"; fi ;;
    *) RC_FILE="$HOME/.bashrc" ;;
esac

if [ "$IS_DEFAULT_ROOT" = "1" ]; then
    FNX_BIN_EXPR="\$HOME/.forenyx/$AGENT_NAME/bin"
else
    FNX_BIN_EXPR="$FORENYX_ROOT/$AGENT_NAME/bin"
fi
RC_FAILED=0
for fnx_rc in $FNX_RC_FILES; do
    fnx_f="$HOME/$fnx_rc"
    if fnx_rc_is_csh "$fnx_f"; then
        fnx_pline="setenv PATH \"$FNX_BIN_EXPR:\$PATH\""
        fnx_hline="setenv FORENYX_HOME \"$FORENYX_ROOT\""
    else
        fnx_pline="export PATH=\"$FNX_BIN_EXPR:\$PATH\""
        fnx_hline="export FORENYX_HOME=\"$FORENYX_ROOT\""
    fi
    fnx_add=0
    [ "$fnx_f" = "$RC_FILE" ] && fnx_add=1
    [ -f "$fnx_f" ] || [ "$fnx_add" = "1" ] || continue
    if [ "$IS_DEFAULT_ROOT" = "1" ]; then
        fnx_rc_edit "$fnx_f" FNXHOMEDELALL=1 FNXPATHMODE=set "FNXPATHLINE=$fnx_pline" FNXPATHADD="$fnx_add" \
            || RC_FAILED=1
    else
        fnx_rc_edit "$fnx_f" "FNXHOMEDEL=$FNX_STALE_VALUES" "FNXHOMELINE=$fnx_hline" FNXHOMEADD="$fnx_add" \
            FNXPATHMODE=set "FNXPATHLINE=$fnx_pline" FNXPATHADD="$fnx_add" || RC_FAILED=1
    fi
done
if [ "$RC_FAILED" = "1" ]; then
    echo -e "${YELLOW}⚠ 部分 shell 配置文件没能改动（见上方提示），请手工加入：${NC}"
    echo -e "    ${CYAN}export PATH=\"$FNX_BIN_EXPR:\$PATH\"${NC}"
    [ "$IS_DEFAULT_ROOT" = "1" ] || echo -e "    ${CYAN}export FORENYX_HOME=\"$FORENYX_ROOT\"${NC}"
else
    echo -e "  - $AGENT_NAME PATH configured in $RC_FILE."
fi

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

# 本机还没有授权文件：当场打印 hostid，省掉客户再找脚本、再跑一遍这一步。
# 放在最后，是为了让客户要复制的那一行出现在屏幕最下方，不被安装日志淹没。
if [ "${NEED_LIC:-0}" = "1" ]; then
    echo -e "${YELLOW}${BOLD}本机尚未取得授权，${AGENT_NAME} 现在还不能启动。${NC}"
    echo -e "请按下面「部署信息」末尾的提示把内容发给管理员，换取授权文件，然后执行："
    echo -e "  ${CYAN}${BOLD}${AGENT_NAME} license import <授权文件>${NC}"
    echo -e "（换了账号或换了机器，都需要在那个账号、那台机器上重新获取。）"
    HOSTID_TOOL="$FORENYX_ROOT/forenyx-hostid.sh"
    if [ -x "$HOSTID_TOOL" ]; then
        # 以当前用户运行：client_id 由 machine-id 与 $USER 算出，必须与写入 .env 的一致。
        # 重装时 .env 沿用首次安装算出的值，而 hostid 每次重算；两者若不同（例如中途
        # 改过 machine-id），按 hostid 签出的授权文件在本机永远导不进去，现场极难定位。
        # 读法与客户端一致：允许行首空白、取第一个匹配、去掉引号与空白
        ENV_CID=$(env_get FORENYX_CLIENT_ID "$GLOBAL_ENV_FILE")
        TOOL_CID=$(bash "$HOSTID_TOOL" --raw 2>/dev/null | tr -d '[:space:]')
        if [ -n "$ENV_CID" ] && [ -n "$TOOL_CID" ] && [ "$ENV_CID" != "$TOOL_CID" ]; then
            echo -e "${RED}⚠ 本机设备标识与安装记录不一致（记录 ${ENV_CID:0:8}…，当前 ${TOOL_CID:0:8}…）。${NC}"
            echo -e "${YELLOW}   按下面的信息签发的授权文件将无法导入。请把这两行一并发给管理员处理。${NC}"
        fi
        bash "$HOSTID_TOOL" || echo -e "${YELLOW}⚠ 部署信息采集失败，请联系管理员。${NC}"
    else
        echo -e "${YELLOW}⚠ 离线包内缺少 forenyx-hostid.sh，无法采集部署信息。请向管理员索取该工具。${NC}"
    fi
fi
