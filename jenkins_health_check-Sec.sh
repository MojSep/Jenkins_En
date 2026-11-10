#!/usr/bin/env bash
# ============================================================================
# Jenkins Health & Configuration Audit
# Visit more at https://github.com/MojSep
# ============================================================================
set -o pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

PASS=0; WARN=0; FAIL=0; INFO=0
IS_ROOT=0; [[ $EUID -eq 0 ]] && IS_ROOT=1
HAS_XMLLINT=0; command -v xmllint &>/dev/null && HAS_XMLLINT=1

log_ok()   { printf "${GREEN}[ OK ]${NC} %s\n" "$*"; PASS=$((PASS+1)); }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; WARN=$((WARN+1)); }
log_fail() { printf "${RED}[FAIL]${NC} %s\n" "$*"; FAIL=$((FAIL+1)); }
log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; INFO=$((INFO+1)); }
log_file() { printf "${MAGENTA}[FILE]${NC} %s\n" "$*"; }
section()  { echo; printf "${CYAN}${BOLD}═══ %s ═══${NC}\n" "$*"; }
hint()     { printf "       ${BLUE}→${NC} %s\n" "$*"; }

print_header() {
    printf "${CYAN}${BOLD}"
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║             Jenkins Health & Configuration Audit                     ║
║                                                                      ║
║              Visit more at https://github.com/MojSep                ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
    printf "${NC}"
    printf "${BLUE}Date:${NC} %s  ${BLUE}Host:${NC} %s  ${BLUE}User:${NC} %s\n" \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$(hostname -f 2>/dev/null || hostname)" "$(whoami)"
}

print_footer() {
    echo
    printf "${CYAN}${BOLD}══════════════════ SUMMARY ══════════════════${NC}\n"
    printf "  ${GREEN}PASS: %d${NC}   ${YELLOW}WARN: %d${NC}   ${RED}FAIL: %d${NC}   ${BLUE}INFO: %d${NC}\n" \
        "$PASS" "$WARN" "$FAIL" "$INFO"
    echo
    printf "${CYAN}${BOLD}"
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║              Visit more at https://github.com/MojSep                ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
    printf "${NC}"
    if   [[ $FAIL -gt 0 ]]; then exit 2
    elif [[ $WARN -gt 0 ]]; then exit 1
    else exit 0
    fi
}

check_file() {
    local f=$1 label=$2 required=${3:-true}
    if [[ -f "$f" ]]; then log_ok "$label exists: $f"
    else
        if [[ "$required" == "true" ]]; then log_fail "$label MISSING: $f"
        else log_warn "$label not found (optional): $f"; fi
    fi
}

check_xml_key() {
    local f=$1 tag=$2 label=$3 sev=$4
    [[ ! -f "$f" ]] && return
    local line
    line=$(grep -n "<${tag}" "$f" 2>/dev/null | head -1 | cut -d: -f1)
    if [[ -n "$line" ]]; then
        log_ok "$label at $f:$line"
    else
        case "$sev" in
            fail) log_fail "$label MISSING in $f"; hint "Add <$tag>";;
            warn) log_warn "$label not set in $f";;
            *)    log_info "$label not present (default)";;
        esac
    fi
}

check_xml_value() {
    local f=$1 tag=$2 expected=$3 label=$4
    [[ ! -f "$f" ]] && return
    local line val
    line=$(grep -n "<${tag}>" "$f" 2>/dev/null | head -1 | cut -d: -f1)
    [[ -z "$line" ]] && return
    val=$(sed -n "${line}p" "$f" | sed -E "s|.*<${tag}>([^<]*)</${tag}>.*|\1|")
    if [[ "$val" == "$expected" ]]; then
        log_ok "$label = $val at $f:$line"
    else
        log_warn "$label = $val (recommended: $expected) at $f:$line"
    fi
}

# ============================================================================
print_header

# ---------- 0) Prerequisites ----------
section "0. PREREQUISITES"
command -v java &>/dev/null && log_ok "Java: $(java -version 2>&1 | head -1)" \
    || log_warn "java command not in PATH (Jenkins needs JRE >= 11/17/21)"
command -v curl &>/dev/null && log_ok "curl available" || log_warn "curl missing"
[[ $HAS_XMLLINT -eq 0 ]] && log_info "xmllint not installed (apt install libxml2-utils) - XML syntax checks skipped"
[[ $IS_ROOT -eq 0 ]] && log_warn "Not running as root - some /var/lib/jenkins checks limited"

# ---------- 1) Discover Jenkins home ----------
section "1. JENKINS HOME DETECTION"

JENKINS_HOME=""
for p in /var/lib/jenkins /var/jenkins_home "$HOME/.jenkins" /data/jenkins; do
    if [[ -d "$p" ]] && { [[ -f "$p/config.xml" ]] || [[ -f "$p/jenkins.CLI.xml" ]]; }; then
        JENKINS_HOME="$p"; break
    fi
done
# Env fallback
[[ -z "$JENKINS_HOME" && -n "$JENKINS_HOME_ENV" ]] && JENKINS_HOME="$JENKINS_HOME_ENV"

if [[ -n "$JENKINS_HOME" ]]; then
    log_ok "Jenkins home detected: $JENKINS_HOME"
else
    log_fail "Cannot locate JENKINS_HOME (looked for config.xml)"
    print_footer
fi

# ---------- 2) Critical files ----------
section "2. CRITICAL FILES"

check_file "$JENKINS_HOME/config.xml"                                "Main config.xml"             true
check_file "$JENKINS_HOME/jenkins.model.JenkinsLocationConfiguration.xml" "Jenkins URL config"      false
check_file "$JENKINS_HOME/hudson.tasks.Mailer.xml"                   "Mailer config"               false
check_file "$JENKINS_HOME/hudson.plugins.git.GitSCM.xml"             "Git SCM global config"       false
check_file "$JENKINS_HOME/credentials.xml"                           "Global credentials"          false
check_file "$JENKINS_HOME/secrets/master.key"                        "Master key (secrets)"        true
check_file "$JENKINS_HOME/secrets/hudson.util.Secret"                "Hudson secret"               true
check_file "$JENKINS_HOME/secrets/initialAdminPassword"              "Initial admin password"      false
check_file "$JENKINS_HOME/users"                                     "Users directory (dir)"       false
check_file /etc/default/jenkins                                       "Debian defaults"             false
check_file /etc/sysconfig/jenkins                                     "RHEL sysconfig"              false
check_file /etc/systemd/system/jenkins.service                       "systemd custom unit"         false
check_file /lib/systemd/system/jenkins.service                       "systemd distro unit"         false
check_file /etc/init.d/jenkins                                       "SysV init script"            false

# ---------- 3) Permissions ----------
section "3. FILE PERMISSIONS"

if [[ -d "$JENKINS_HOME" ]]; then
    perm=$(stat -c '%a' "$JENKINS_HOME")
    if (( 8#$perm & 8#007 )); then
        log_warn "$JENKINS_HOME is world-accessible ($perm) - should be 700 or 750"
    else
        log_ok "$JENKINS_HOME permission $perm"
    fi
fi

for sf in "$JENKINS_HOME/secrets/master.key" \
          "$JENKINS_HOME/secrets/hudson.util.Secret" \
          "$JENKINS_HOME/credentials.xml"; do
    [[ -f "$sf" ]] || continue
    p=$(stat -c '%a' "$sf")
    if (( 8#$p & 8#004 )); then
        log_fail "Sensitive file world-readable ($p): $sf"
        hint "chmod 600 $sf"
    elif (( 8#$p & 8#040 )); then
        log_warn "Sensitive file group-readable ($p): $sf"
    else
        log_ok "Sensitive file perms OK ($p): $sf"
    fi
done

# ---------- 4) XML validation ----------
section "4. XML CONFIG VALIDATION"

if $HAS_XMLLINT; then
    for f in "$JENKINS_HOME/config.xml" \
             "$JENKINS_HOME/jenkins.model.JenkinsLocationConfiguration.xml" \
             "$JENKINS_HOME/hudson.tasks.Mailer.xml" \
             "$JENKINS_HOME/credentials.xml"; do
        [[ -f "$f" ]] || continue
        if err=$(xmllint --noout "$f" 2>&1); then
            log_ok "XML valid: $f"
        else
            ln=$(echo "$err" | grep -oE ':[0-9]+:' | head -1 | tr -d ':')
            log_fail "XML INVALID: $f:${ln:-?}  ($err)"
        fi
    done
else
    log_info "xmllint not available - raw XML validation skipped"
fi

# ---------- 5) Key config.xml checks ----------
section "5. CONFIG.XML SECURITY SETTINGS"

CFGXML="$JENKINS_HOME/config.xml"
if [[ -f "$CFGXML" ]]; then
    log_file "File: $CFGXML"

    # useSecurity
    if grep -q "<useSecurity>true</useSecurity>" "$CFGXML"; then
        ln=$(grep -n "<useSecurity>true" "$CFGXML" | head -1 | cut -d: -f1)
        log_ok "Security enabled (useSecurity=true) at $CFGXML:$ln"
    elif grep -q "<useSecurity>" "$CFGXML"; then
        ln=$(grep -n "<useSecurity>" "$CFGXML" | head -1 | cut -d: -f1)
        log_fail "Security DISABLED at $CFGXML:$ln - CRITICAL"
    else
        log_warn "useSecurity not set in $CFGXML (defaults may disable security)"
    fi

    # slaveAgentPort
    if grep -q "<slaveAgentPort>" "$CFGXML"; then
        ln=$(grep -n "<slaveAgentPort>" "$CFGXML" | head -1 | cut -d: -f1)
        val=$(sed -n "${ln}p" "$CFGXML" | sed -E 's|.*<slaveAgentPort>([^<]*)</slaveAgentPort>.*|\1|')
        case "$val" in
            -1|0|"") log_ok "slaveAgentPort disabled or random ($val) at $CFGXML:$ln";;
            *)       log_warn "slaveAgentPort=$val (static TCP port - prefer random/disabled) at $CFGXML:$ln";;
        esac
    fi

    # agent protocols (TLS)
    if grep -q "JNLP4-connect\|JNLP4" "$CFGXML"; then
        log_ok "JNLP4 protocol (encrypted) referenced"
    elif grep -q "JNLP3-connect\|JNLP2-connect\|JNLP-connect" "$CFGXML"; then
        ln=$(grep -nE 'JNLP[23]?-connect' "$CFGXML" | head -1 | cut -d: -f1)
        log_warn "Insecure legacy agent protocol at $CFGXML:$ln"
        hint "Prefer JNLP4-connect (TLS)"
    fi

    # Remember me / CSRF
    if grep -q "<crumbIssuer" "$CFGXML"; then
        log_ok "CSRF crumb issuer configured (XSS/CSRF protection)"
    else
        log_warn "No crumbIssuer in config.xml (CSRF protection may be default)"
    fi

    # CLI / remoting
    if grep -q "<cli>false</cli>\|<disableCli>true" "$CFGXML"; then
        log_ok "CLI disabled in config"
    else
        log_info "CLI may be enabled (default true) - consider disabling"
    fi

    # num executors
    if grep -q "<numExecutors>" "$CFGXML"; then
        ln=$(grep -n "<numExecutors>" "$CFGXML" | head -1 | cut -d: -f1)
        val=$(sed -n "${ln}p" "$CFGXML" | sed -E 's|.*<numExecutors>([^<]*)</numExecutors>.*|\1|')
        (( val > 0 )) && log_info "numExecutors=$val (controller runs builds; recommended 0 in distributed setup) at $CFGXML:$ln" \
                      || log_ok "numExecutors=0 at $CFGXML:$ln"
    fi

    # Quiet period
    if grep -q "<quietPeriod>" "$CFGXML"; then
        ln=$(grep -n "<quietPeriod>" "$CFGXML" | head -1 | cut -d: -f1)
        val=$(sed -n "${ln}p" "$CFGXML" | sed -E 's|.*<quietPeriod>([^<]*)</quietPeriod>.*|\1|')
        log_info "quietPeriod=$val sec at $CFGXML:$ln"
    fi

    # Label / master restrictions
    if grep -q "<label>" "$CFGXML"; then
        log_info "Controller assigned to label (jobs targeting it will run on controller)"
    else
        log_info "No label on controller"
    fi

    # URL
    URLXML="$JENKINS_HOME/jenkins.model.JenkinsLocationConfiguration.xml"
    if [[ -f "$URLXML" ]]; then
        ln=$(grep -n "<jenkinsUrl>" "$URLXML" 2>/dev/null | head -1 | cut -d: -f1)
        if [[ -n "$ln" ]]; then
            val=$(sed -n "${ln}p" "$URLXML" | sed -E 's|.*<jenkinsUrl>([^<]*)</jenkinsUrl>.*|\1|')
            log_info "Jenkins URL = $val at $URLXML:$ln"
            if [[ "$val" == http://* ]]; then
                log_warn "Jenkins URL uses plain HTTP (not HTTPS) - not secure for prod"
            fi
        fi
    fi
fi

# ---------- 6) systemd / init service ----------
section "6. SERVICE HEALTH"

if systemctl cat jenkins.service &>/dev/null; then
    systemctl is-active jenkins &>/dev/null && log_ok "jenkins.service is ACTIVE" \
        || log_fail "jenkins.service is NOT active"
    systemctl is-enabled jenkins &>/dev/null && log_ok "jenkins.service ENABLED at boot" \
        || log_warn "jenkins.service NOT enabled at boot"

    # Drop-ins
    for d in /etc/systemd/system/jenkins.service.d/*.conf; do
        [[ -f "$d" ]] && log_file "Drop-in: $d"
    done
elif [[ -x /etc/init.d/jenkins ]]; then
    if /etc/init.d/jenkins status &>/dev/null; then
        log_ok "jenkins (SysV) running"
    else
        log_warn "jenkins (SysV) not confirmed running"
    fi
else
    log_fail "No systemd unit and no /etc/init.d/jenkins found"
fi

# Defaults file
for df in /etc/default/jenkins /etc/sysconfig/jenkins; do
    [[ -f "$df" ]] || continue
    log_file "Defaults: $df"
    for k in JENKINS_HOME JENKINS_PORT JENKINS_LISTEN_ADDRESS JENKINS_ARGS JAVA_ARGS; do
        ln=$(grep -n "^${k}=" "$df" 2>/dev/null | head -1 | cut -d: -f1)
        if [[ -n "$ln" ]]; then
            val=$(sed -n "${ln}p" "$df")
            log_info "$df:$ln  $val"
            # address binding
            if [[ "$k" == "JENKINS_LISTEN_ADDRESS" && "$val" == *"0.0.0.0"* ]]; then
                log_warn "JENKINS_LISTEN_ADDRESS=0.0.0.0 (public bind) - prefer loopback + reverse proxy"
            fi
        fi
    done
done

# ---------- 7) Port / Endpoint ----------
section "7. LISTENING PORT & HTTP HEALTH"

# discover port
PORT=""
[[ -f /etc/default/jenkins ]] && PORT=$(grep -E '^JENKINS_PORT=' /etc/default/jenkins 2>/dev/null | cut -d= -f2 | tr -d '"' )
[[ -z "$PORT" && -f /etc/sysconfig/jenkins ]] && PORT=$(grep -E '^JENKINS_PORT=' /etc/sysconfig/jenkins 2>/dev/null | cut -d= -f2 | tr -d '"' )
PORT=${PORT:-8080}

if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
    log_ok "Jenkins port ${PORT} is LISTENING"
    ip=$(ss -tln 2>/dev/null | awk -v p=":${PORT}" '$4 ~ p {print $4}')
    log_info "Bind: $ip"
    if [[ "$ip" == "0.0.0.0:${PORT}" || "$ip" == "*:${PORT}" ]]; then
        log_warn "Jenkins bound to 0.0.0.0:${PORT} (public) - consider 127.0.0.1 + reverse proxy"
    fi
else
    log_fail "Jenkins port ${PORT} is NOT listening"
fi

if command -v curl &>/dev/null; then
    # try /login (or /api/json with auth)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}/login" 2>/dev/null)
    case "$code" in
        200)      log_ok "HTTP /login returned 200";;
        401|403)  log_ok "HTTP /login returned $code (auth required - good)";;
        302|301)  log_info "HTTP /login redirects ($code)";;
        000)      log_fail "HTTP /login unreachable on 127.0.0.1:${PORT}";;
        *)        log_warn "HTTP /login returned $code";;
    esac
fi

# ---------- 8) JVM / Heap ----------
section "8. JVM & MEMORY"

pid=$(pgrep -f 'jenkins.*war|jenkins.war' 2>/dev/null | head -1)
if [[ -n "$pid" ]]; then
    log_info "Jenkins PID: $pid"
    heap=$(ps -o args= -p "$pid" 2>/dev/null | grep -oE '\-Xmx[0-9]+[gGmM]' | head -1)
    if [[ -n "$heap" ]]; then
        log_ok "JVM $heap configured"
        val=${heap#-Xmx}; num=${val%[gGmM]}; unit=${val: -1}
        case "$unit" in
            g|G) mb=$((num*1024));;
            m|M) mb=$num;;
        esac
        if (( mb < 1024 )); then
            log_warn "Heap ${heap} < 1GB (likely too small for prod)"
        elif (( mb > 16384 )); then
            log_warn "Heap ${heap} > 16GB (GC pause risk; split controller/agents)"
        else
            log_ok "Heap ${heap} in safe range"
        fi
    else
        log_warn "No -Xmx found in JVM args (may use default)"
    fi
    # process memory
    mem_mb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print int($1/1024)}')
    [[ -n "$mem_mb" ]] && log_info "RSS: ${mem_mb} MB"
    # open files
    of=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
    lim=$(cat /proc/$pid/limits 2>/dev/null | awk '/Max open files/ {print $4}' | head -1)
    log_info "Open files: $of / limit $lim"
    [[ -n "$lim" && "$lim" != "unlimited" ]] && (( of > lim/2 )) 2>/dev/null && \
        log_warn "Open files near limit ($of/$lim)"
else
    log_warn "Jenkins JVM process not found (service may be down)"
fi

# ---------- 9) Plugins ----------
section "9. PLUGINS"

if [[ -d "$JENKINS_HOME/plugins" ]]; then
    count=$(ls -d "$JENKINS_HOME/plugins"/*.jpi "$JENKINS_HOME/plugins"/*.hpi 2>/dev/null | wc -l)
    log_ok "Plugins installed: $count"
    # Failed/disabling
    if ls "$JENKINS_HOME/plugins"/*.failed >/dev/null 2>&1; then
        bad=$(ls "$JENKINS_HOME/plugins"/*.failed 2>/dev/null)
        echo "$bad" | while read -r f; do
            log_fail "Plugin failed: $(basename "$f")"; hint "Check $JENKINS_HOME/plugins/$f"
        done
    else
        log_ok "No .failed plugins"
    fi
    # .jpi.disabled
    dis=$(ls "$JENKINS_HOME/plugins"/*.jpi.disabled "$JENKINS_HOME/plugins"/*.hpi.disabled 2>/dev/null | wc -l)
    (( dis > 0 )) && log_warn "$dis plugin(s) disabled" || true
else
    log_fail "Plugins directory missing: $JENKINS_HOME/plugins"
fi

# ---------- 10) Users & Credentials ----------
section "10. USERS & CREDENTIALS"

if [[ -d "$JENKINS_HOME/users" ]]; then
    ucount=$(find "$JENKINS_HOME/users" -maxdepth 1 -mindepth 1 -type d | wc -l)
    log_ok "Users: $ucount"
    # admin user files present?
    for u in "$JENKINS_HOME/users"/*/config.xml; do
        [[ -f "$u" ]] || continue
        uname_dir=$(basename "$(dirname "$u")")
        if grep -q "<fullName>admin" "$u" 2>/dev/null || [[ "$uname_dir" == "admin" ]]; then
            log_info "Admin user present: $uname_dir"
        fi
    done
else
    log_warn "$JENKINS_HOME/users not found"
fi

# initialAdminPassword — should be removed after setup
if [[ -f "$JENKINS_HOME/secrets/initialAdminPassword" ]]; then
    log_warn "initialAdminPassword file still exists (should be removed after setup)"
    hint "rm $JENKINS_HOME/secrets/initialAdminPassword"
fi

# credentials.xml count
if [[ -f "$JENKINS_HOME/credentials.xml" ]]; then
    ccount=$(grep -c "<com.cloudbees.plugins.credentials.impl" "$JENKINS_HOME/credentials.xml" 2>/dev/null || echo 0)
    log_info "Stored credentials entries: $ccount"
fi

# ---------- 11) Logs ----------
section "11. LOGS"

for lf in /var/log/jenkins/jenkins.log "$JENKINS_HOME/jenkins.log" /var/log/jenkins.log; do
    [[ -f "$lf" ]] || continue
    sz=$(stat -c '%s' "$lf" 2>/dev/null || echo 0)
    if (( sz > 1073741824 )); then
        log_warn "Large log ($(numfmt --to=iec $sz 2>/dev/null)): $lf"
    else
        log_ok "Log: $lf ($(numfmt --to=iec $sz 2>/dev/null))"
    fi
    # recent SEVERE
    sev=$(grep -a "SEVERE" "$lf" 2>/dev/null | tail -3)
    if [[ -n "$sev" ]]; then
        log_warn "Recent SEVERE lines in $lf:"
        echo "$sev" | while read -r l; do hint "${l:0:200}"; done
    fi
    break
done

# ---------- 12) Backups ----------
section "12. BACKUP & MAINTENANCE"

for cand in "$JENKINS_HOME/backup" /var/backups/jenkins "$JENKINS_HOME/jobs"/*/builds; do
    [[ -e "$cand" ]] && log_info "Found: $cand"
done
# Any config backups?
if ls "$JENKINS_HOME"/*.bak 2>/dev/null | head -1 >/dev/null; then
    log_info "Config backups present: $(ls "$JENKINS_HOME"/*.bak 2>/dev/null | wc -l)"
else
    log_warn "No config backups (*.bak) in JENKINS_HOME"
    hint "Take periodic backups of $JENKINS_HOME"
fi

# ---------- 13) Misc security ----------
section "13. ADDITIONAL SECURITY"

# X-Forwarded / reverse proxy hints
if [[ -f "$URLXML" ]] && grep -q "http://" "$URLXML"; then
    log_warn "Jenkins URL uses HTTP; ensure TLS termination at reverse proxy"
fi

# Slave-to-master access control (default 1.614+)
if grep -q "hudson.security.csrf.GlobalCrumbIssuerConfiguration" "$CFGXML" 2>/dev/null; then
    log_ok "GlobalCrumbIssuerConfiguration present"
fi

# Script console exposed?
if grep -q "groovy" "$CFGXML" 2>/dev/null; then
    log_info "Groovy/script references in config.xml - restrict Script Console access"
fi

# ---------- Footer ----------
print_footer
