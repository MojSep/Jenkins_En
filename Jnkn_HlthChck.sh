#!/usr/bin/env bash
#
# jenkins_health_check.sh
# Comprehensive Jenkins Health & Configuration Auditor
#
# Author : MojSep
# Visit  : https://github.com/MojSep
#
# Checks:
#   - Jenkins service state (systemd)
#   - Java version compatibility
#   - Ports (HTTP, JNLP agent)
#   - JENKINS_HOME permissions & structure
#   - Core config files (config.xml, credentials.xml, secrets/*)
#   - XML validity of all config files
#   - Plugin files: existence, integrity (zip CRC), stale/tmp files
#   - Security settings (useSecurity, authorizationStrategy, CSRF, slaveAgentPort)
#   - Secrets file permissions
#   - JVM heap configuration
#   - Disk space
#   - init.groovy.d presence
#   - JCasC (Configuration as Code)
#   - Recent critical log entries
#   - Backup presence
#
# Output: colored status (GREEN=OK, YELLOW=WARN, RED=ERROR)
#         English diagnosis for every problem found.
#
# Usage:
#   sudo ./jenkins_health_check.sh
#   JENKINS_HOME=/opt/jenkins ./jenkins_health_check.sh
#
# Exit codes:
#   0 = all OK
#   1 = warnings only
#   2 = at least one critical error
#

set -o pipefail
set -o nounset

# ─────────────────────────────── Colors ────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─────────────────────────────── Config ────────────────────────────────
JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
JENKINS_SERVICE="${JENKINS_SERVICE:-jenkins}"
JENKINS_PORT="${JENKINS_PORT:-8080}"
AGENT_PORT="${AGENT_PORT:-50000}"
CONFIG_XML="${JENKINS_HOME}/config.xml"
CREDENTIALS_XML="${JENKINS_HOME}/credentials.xml"
LOCATION_XML="${JENKINS_HOME}/jenkins.model.JenkinsLocationConfiguration.xml"

PLUGIN_DIR="${JENKINS_HOME}/plugins"
SECRETS_DIR="${JENKINS_HOME}/secrets"
JOBS_DIR="${JENKINS_HOME}/jobs"
CASC_DIR="${JENKINS_HOME}/casc"
INIT_GROOVY_DIR="${JENKINS_HOME}/init.groovy.d"

OK=0
WARN=0
ERR=0
REPORT_LINES=()

# ─────────────────────────────── Helpers ───────────────────────────────
banner() {
  echo ""
  echo -e "${CYAN}${BOLD}Visit more at https://github.com/MojSep${NC}"
  echo -e "${BLUE}${BOLD}────────────────────────────────────────────────────────────────${NC}"
}

section() {
  echo ""
  echo -e "${BLUE}${BOLD}▶ $1${NC}"
  echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
}

ok()   { OK=$((OK+1));   echo -e "  ${GREEN}[OK]${NC}    $1"; REPORT_LINES+=("OK|$1"); }
warn() { WARN=$((WARN+1)); echo -e "  ${YELLOW}[WARN]${NC}  $1"; REPORT_LINES+=("WARN|$1"); }
err()  { ERR=$((ERR+1));  echo -e "  ${RED}[ERR]${NC}   $1"; REPORT_LINES+=("ERR|$1"); }
info() { echo -e "  ${DIM}[INFO]${NC}  $1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ─────────────────────────── 1. Service State ─────────────────────────
check_service() {
  section "1. Jenkins Service State"

  if ! have systemctl; then
    warn "systemctl not found (non-systemd host). Skipping service checks."
    return
  fi

  if ! systemctl list-unit-files 2>/dev/null | grep -qE "^${JENKINS_SERVICE}\.service"; then
    err "systemd unit '${JENKINS_SERVICE}.service' not found. Jenkins may not be installed or uses a different name."
    return
  fi

  local active enabled
  active=$(systemctl is-active "${JENKINS_SERVICE}" 2>/dev/null || true)
  enabled=$(systemctl is-enabled "${JENKINS_SERVICE}" 2>/dev/null || true)

  case "$active" in
    active)   ok "Jenkins service is running (systemctl is-active: active).";;
    activating) warn "Jenkins service is 'activating' — startup may be hanging. Check: journalctl -u ${JENKINS_SERVICE} -n 200";;
    failed)   err  "Jenkins service is in 'failed' state. Check: journalctl -u ${JENKINS_SERVICE} -n 200";;
    inactive) err  "Jenkins service is 'inactive' (not running). Start with: systemctl start ${JENKINS_SERVICE}";;
    *)        warn "Jenkins service state: ${active}";;
  esac

  case "$enabled" in
    enabled)  ok "Jenkins service is enabled on boot.";;
    disabled) warn "Jenkins service is NOT enabled on boot (enabled: disabled). Run: systemctl enable ${JENKINS_SERVICE}";;
    *)        info "Service enabled state: ${enabled}";;
  esac

  # Restart policy
  if systemctl show "${JENKINS_SERVICE}" -p Restart --value 2>/dev/null | grep -qE "on-failure|always"; then
    ok "systemd Restart policy is set for resilience."
  else
    warn "systemd Restart policy is not 'on-failure'/'always'. Add via: systemctl edit ${JENKINS_SERVICE}"
  fi
}

# ────────────────────────── 2. Java Version ───────────────────────────
check_java() {
  section "2. Java Runtime"

  if ! have java; then
    err "Java not found in PATH. Jenkins requires Java 17 or 21 (LTS 2.479+)."
    return
  fi

  local raw major
  raw=$(java -version 2>&1 | head -n1)
  major=$(echo "$raw" | grep -oE 'version "(1\.)?([0-9]+)' | grep -oE '[0-9]+$' | head -n1)

  if [[ -z "$major" ]]; then
    warn "Could not parse Java version from: $raw"
    return
  fi

  if (( major >= 17 )); then
    ok "Java version ${major} detected (compatible). ${raw}"
  elif (( major == 11 )); then
    warn "Java 11 detected. Jenkins LTS 2.479+ requires Java 17 or 21. Upgrade soon."
  else
    err "Java ${major} is too old for modern Jenkins. Install OpenJDK 17 or 21."
  fi

  # JAVA_HOME check
  if [[ -n "${JAVA_HOME:-}" ]]; then
    ok "JAVA_HOME is set: ${JAVA_HOME}"
  else
    warn "JAVA_HOME is not set. Some plugins/tools may fail. Set it in Jenkins unit Environment."
  fi
}

# ───────────────────────────── 3. Ports ───────────────────────────────
check_ports() {
  section "3. Network Ports"

  if have ss; then
    if ss -ltn "sport = :${JENKINS_PORT}" 2>/dev/null | grep -q LISTEN; then
      ok "Port ${JENKINS_PORT} is listening (Jenkins HTTP)."
    else
      err "Port ${JENKINS_PORT} is NOT listening. Jenkins may be down or bound to a different port."
    fi

    if ss -ltn "sport = :${AGENT_PORT}" 2>/dev/null | grep -q LISTEN; then
      warn "JNLP agent port ${AGENT_PORT} is open. Restrict to internal subnet or disable (slaveAgentPort=-1) if unused."
    else
      info "JNLP agent port ${AGENT_PORT} not listening (expected if using SSH/WebSocket agents)."
    fi
  else
    warn "'ss' not found. Cannot verify listening ports."
  fi
}

# ────────────────────────── 4. JENKINS_HOME ───────────────────────────
check_jhome() {
  section "4. JENKINS_HOME"

  if [[ ! -d "$JENKINS_HOME" ]]; then
    err "JENKINS_HOME '${JENKINS_HOME}' does not exist."
    return
  fi
  ok "JENKINS_HOME exists: ${JENKINS_HOME}"

  local owner perms
  owner=$(stat -c '%U:%G' "$JENKINS_HOME" 2>/dev/null || echo "?")
  perms=$(stat -c '%a' "$JENKINS_HOME" 2>/dev/null || echo "?")

  if [[ "$owner" == "jenkins:jenkins" ]]; then
    ok "JENKINS_HOME owner is jenkins:jenkins."
  else
    warn "JENKINS_HOME owner is '${owner}' (expected jenkins:jenkins). Run: chown -R jenkins:jenkins ${JENKINS_HOME}"
  fi

  case "$perms" in
    750|700) ok "JENKINS_HOME permissions are ${perms} (secure).";;
    755)     warn "JENKINS_HOME permissions are 755 (too open). Recommended: 750.";;
    *)       warn "JENKINS_HOME permissions are ${perms} (non-standard).";;
  esac

  # write test
  if [[ -w "$JENKINS_HOME" ]]; then
    ok "Current user can write to JENKINS_HOME."
  else
    info "Current user cannot write to JENKINS_HOME (run as jenkins or root to check write access)."
  fi
}

# ─────────────────────── 5. Core Configuration Files ──────────────────
check_core_files() {
  section "5. Core Configuration Files"

  local files=(
    "config.xml|${CONFIG_XML}"
    "credentials.xml|${CREDENTIALS_XML}"
    "secrets/master.key|${SECRETS_DIR}/master.key"
    "secrets/hudson.util.Secret|${SECRETS_DIR}/hudson.util.Secret"
    "JenkinsLocationConfiguration|${LOCATION_XML}"
    "init.groovy.d|${INIT_GROOVY_DIR}"
    "jobs|${JOBS_DIR}"
    "plugins|${PLUGIN_DIR}"
  )

  for entry in "${files[@]}"; do
    local name="${entry%%|*}"
    local path="${entry##*|}"
    if [[ -e "$path" ]]; then
      ok "Found ${name} (${path})."
    else
      case "$name" in
        "JenkinsLocationConfiguration"|"init.groovy.d"|"jobs")
          warn "Optional file/dir missing: ${name} (${path})."
          ;;
        *)
          err "Required file/dir missing: ${name} (${path})."
          ;;
      esac
    fi
  done

  # initialAdminPassword should be gone after setup
  if [[ -f "${SECRETS_DIR}/initialAdminPassword" ]]; then
    warn "initialAdminPassword still present. Remove it after completing setup: rm ${SECRETS_DIR}/initialAdminPassword"
  else
    ok "initialAdminPassword removed (setup completed)."
  fi
}

# ────────────────────── 6. XML Validity of Configs ────────────────────
check_xml_validity() {
  section "6. XML Validity (config.xml, credentials.xml, jobs/*/config.xml)"

  if ! have xmllint; then
    warn "'xmllint' not installed (install libxml2-utils / libxml2). Skipping XML validation."
    return
  fi

  local checked=0 failed=0

  for f in "$CONFIG_XML" "$CREDENTIALS_XML" "$LOCATION_XML"; do
    [[ -f "$f" ]] || continue
    checked=$((checked+1))
    if xmllint --noout "$f" 2>/dev/null; then
      ok "XML valid: $f"
    else
      err "XML CORRUPT: $f — Jenkins may fail to start. Restore from .bak or backup."
      failed=$((failed+1))
    fi
  done

  if [[ -d "$JOBS_DIR" ]]; then
    while IFS= read -r jf; do
      checked=$((checked+1))
      if ! xmllint --noout "$jf" 2>/dev/null; then
        err "XML CORRUPT: $jf — job may not load."
        failed=$((failed+1))
      fi
    done < <(find "$JOBS_DIR" -maxdepth 2 -name "config.xml" 2>/dev/null)
    if (( failed == 0 )); then
      ok "All job config.xml files are valid (checked: ${checked})."
    fi
  fi
}

# ────────────────────────────── 7. Plugins ────────────────────────────
check_plugins() {
  section "7. Plugin Files Integrity"

  if [[ ! -d "$PLUGIN_DIR" ]]; then
    err "Plugin directory not found: ${PLUGIN_DIR}"
    return
  fi

  local total jpi_count disabled_count=0 tmp_count=0 corrupt_count=0 zero_count=0

  total=$(find "$PLUGIN_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
  jpi_count=$(find "$PLUGIN_DIR" -maxdepth 1 -type f \( -name "*.jpi" -o -name "*.hpi" \) 2>/dev/null | wc -l)

  info "Total files in plugin dir: ${total} | .jpi/.hpi plugins: ${jpi_count}"

  # Disabled plugins
  disabled_count=$(find "$PLUGIN_DIR" -maxdepth 1 -type f -name "*.disabled" 2>/dev/null | wc -l)
  if (( disabled_count > 0 )); then
    warn "${disabled_count} plugin(s) are disabled (.disabled). If unintentional, review with: ls ${PLUGIN_DIR}/*.disabled"
  else
    ok "No disabled plugins."
  fi

  # Tmp / partial downloads
  tmp_count=$(find "$PLUGIN_DIR" -maxdepth 1 -type f \( -name "*.tmp" -o -name "*.part" -o -name "*.jpi.tmp" \) 2>/dev/null | wc -l)
  if (( tmp_count > 0 )); then
    err "${tmp_count} incomplete plugin download(s) (*.tmp/*.part). Remove and reinstall via PIM. Path: ${PLUGIN_DIR}"
  else
    ok "No incomplete plugin downloads."
  fi

  # Zero-size
  zero_count=$(find "$PLUGIN_DIR" -maxdepth 1 -type f \( -name "*.jpi" -o -name "*.hpi" \) -size 0 2>/dev/null | wc -l)
  if (( zero_count > 0 )); then
    err "${zero_count} plugin file(s) are 0 bytes. These will fail to load."
  else
    ok "No zero-byte plugin files."
  fi

  # Integrity (zip CRC)
  if have unzip; then
    while IFS= read -r jpi; do
      if ! unzip -tqq "$jpi" >/dev/null 2>&1; then
        err "CORRUPT plugin (zip CRC failed): $(basename "$jpi") — reinstall via PIM/mirror."
        corrupt_count=$((corrupt_count+1))
      fi
    done < <(find "$PLUGIN_DIR" -maxdepth 1 -type f \( -name "*.jpi" -o -name "*.hpi" \) 2>/dev/null)
    if (( corrupt_count == 0 )); then
      ok "All .jpi/.hpi files pass zip integrity check (${jpi_count} files)."
    fi
  else
    warn "'unzip' not installed. Skipping plugin zip integrity check (install: apt install unzip / dnf install unzip)."
  fi

  # pinned files (informational)
  local pinned_count
  pinned_count=$(find "$PLUGIN_DIR" -maxdepth 1 -name "*.pinned" 2>/dev/null | wc -l)
  if (( pinned_count > 0 )); then
    info "${pinned_count} plugin(s) pinned (.pinned) — these are excluded from auto-update."
  fi

  # Dependency sanity: any .jpi without a matching .pinned? (not needed)
}

# ─────────────────── 8. Security Settings in config.xml ───────────────
check_security_settings() {
  section "8. Security Settings (config.xml)"

  if [[ ! -r "$CONFIG_XML" ]]; then
    err "Cannot read ${CONFIG_XML} (run as root/sudo). Skipping security checks."
    return
  fi

  # useSecurity
  if grep -q "<useSecurity>true</useSecurity>" "$CONFIG_XML"; then
    ok "useSecurity is enabled."
  else
    err "useSecurity is NOT enabled. Jenkins is in insecure mode. Enable in: Manage Jenkins → Security."
  fi

  # Security realm
  if grep -qE "<securityRealm[^>]*class=\"[^\"]+SecurityRealm\"" "$CONFIG_XML" ||
     grep -q "<securityRealm" "$CONFIG_XML"; then
    local realm
    realm=$(grep -oE '<securityRealm[^>]*class="[^"]+"' "$CONFIG_XML" | head -n1)
    if [[ -n "$realm" ]]; then
      ok "Security realm configured."
    else
      warn "securityRealm present but class not clearly specified. Review config.xml."
    fi
  else
    err "No securityRealm found. Authentication is missing."
  fi

  # Authorization strategy — Unsecured is dangerous
  if grep -q "AuthorizationStrategy\$Unsecured" "$CONFIG_XML" ||
     grep -q "<authorizationStrategy[^>]*Unsecured" "$CONFIG_XML"; then
    err "AuthorizationStrategy is UNSECURED — anyone can do anything. Configure Matrix/Role Strategy immediately."
  elif grep -q "<authorizationStrategy" "$CONFIG_XML"; then
    ok "AuthorizationStrategy is configured (non-Unsecured)."
  else
    warn "No explicit authorizationStrategy — default may be insecure."
  fi

  # slaveAgentPort
  local agent_line agent_port_val
  agent_line=$(grep -oE "<slaveAgentPort>[^<]+</slaveAgentPort>" "$CONFIG_XML" | head -n1)
  if [[ -n "$agent_line" ]]; then
    agent_port_val=$(echo "$agent_line" | sed -E 's/<[^>]+>//g')
    if [[ "$agent_port_val" == "-1" ]]; then
      ok "JNLP agent port is disabled (slaveAgentPort=-1). Best practice."
    elif [[ "$agent_port_val" =~ ^[0-9]+$ ]]; then
      warn "JNLP agent port is ${agent_port_val} — restrict firewall to internal agents only, or use WebSocket/SSH."
    fi
  else
    info "slaveAgentPort not explicitly set in config.xml (Jenkins default applies)."
  fi

  # CSRF protection — presence of crumbIssuer
  if grep -q "<crumbIssuer" "$CONFIG_XML"; then
    if grep -q "DefaultCrumbIssuer" "$CONFIG_XML" || grep -q "StandardCrumbIssuer" "$CONFIG_XML"; then
      ok "CSRF crumb issuer is configured."
    else
      ok "crumbIssuer element present."
    fi
  else
    # absence may mean default CSRF (enabled by default in modern Jenkins) — but we warn
    warn "crumbIssuer not explicit in config.xml. Verify CSRF is enabled: Manage → Security → CSRF Protection."
  fi

  # numExecutors on controller
  local exec_line exec_val
  exec_line=$(grep -oE "<numExecutors>[0-9]+</numExecutors>" "$CONFIG_XML" | head -n1)
  if [[ -n "$exec_line" ]]; then
    exec_val=$(echo "$exec_line" | sed -E 's/<[^>]+>//g')
    if (( exec_val == 0 )); then
      ok "Controller numExecutors=0 (build runs on agents only). Best practice."
    else
      warn "Controller numExecutors=${exec_val}. Recommended: 0 and run builds on agents (stability + security)."
    fi
  else
    info "numExecutors not explicit — default is usually 2 on controller."
  fi

  # JENKINS_URL
  if [[ -f "$LOCATION_XML" ]]; then
    local url
    url=$(grep -oE "<jenkinsUrl>[^<]+</jenkinsUrl>" "$LOCATION_XML" | sed -E 's/<[^>]+>//g')
    if [[ -n "$url" ]]; then
      if [[ "$url" == *"localhost"* || "$url" == *"127.0.0.1"* ]]; then
        warn "Jenkins URL is '${url}' — set public HTTPS URL for correct links in emails/webhooks."
      elif [[ "$url" == https://* ]]; then
        ok "Jenkins URL uses HTTPS: ${url}"
      else
        warn "Jenkins URL is not HTTPS: ${url}"
      fi
    fi
  fi
}

# ────────────────────── 9. Secrets File Permissions ───────────────────
check_secrets_perms() {
  section "9. Secrets File Permissions"

  if [[ ! -d "$SECRETS_DIR" ]]; then
    err "secrets directory not found: ${SECRETS_DIR}"
    return
  fi

  for f in "${SECRETS_DIR}/master.key" "${SECRETS_DIR}/hudson.util.Secret"; do
    [[ -f "$f" ]] || { err "Missing secrets file: $f"; continue; }
    local p owner
    p=$(stat -c '%a' "$f")
    owner=$(stat -c '%U:%G' "$f")
    if [[ "$p" == "600" || "$p" == "400" ]]; then
      ok "$(basename "$f") permissions ${p} (secure)."
    else
      err "$(basename "$f") permissions ${p} (should be 600 or 400). Fix: chmod 600 ${f}"
    fi
    if [[ "$owner" != "jenkins:jenkins" ]]; then
      warn "$(basename "$f") owner ${owner} (expected jenkins:jenkins)."
    fi
  done

  if [[ -f "$CREDENTIALS_XML" ]]; then
    local cp
    cp=$(stat -c '%a' "$CREDENTIALS_XML")
    case "$cp" in
      600|640) ok "credentials.xml permissions ${cp} (acceptable).";;
      644)     warn "credentials.xml permissions 644 (too open). chmod 640 recommended.";;
      *)       warn "credentials.xml permissions ${cp} (review recommended).";;
    esac
  fi
}

# ─────────────────────────── 10. JVM Heap ─────────────────────────────
check_heap() {
  section "10. JVM Heap Configuration"

  local heap=""
  local found_source=""

  # systemd override
  if have systemctl; then
    local env_line
    env_line=$(systemctl show "${JENKINS_SERVICE}" -p Environment --value 2>/dev/null || true)
    heap=$(echo "$env_line" | grep -oE '\-Xmx[0-9]+[gGmM]' | head -n1)
    [[ -n "$heap" ]] && found_source="systemd Environment"

    local exec_line
    exec_line=$(systemctl show "${JENKINS_SERVICE}" -p ExecStart --value 2>/dev/null || true)
    if [[ -z "$heap" ]]; then
      heap=$(echo "$exec_line" | grep -oE '\-Xmx[0-9]+[gGmM]' | head -n1)
      [[ -n "$heap" ]] && found_source="systemd ExecStart"
    fi
  fi

  # /etc/default/jenkins (Debian)
  if [[ -z "$heap" && -f /etc/default/jenkins ]]; then
    heap=$(grep -oE '\-Xmx[0-9]+[gGmM]' /etc/default/jenkins | head -n1)
    [[ -n "$heap" ]] && found_source="/etc/default/jenkins"
  fi

  # /etc/sysconfig/jenkins (RHEL)
  if [[ -z "$heap" && -f /etc/sysconfig/jenkins ]]; then
    heap=$(grep -oE '\-Xmx[0-9]+[gGmM]' /etc/sysconfig/jenkins | head -n1)
    [[ -n "$heap" ]] && found_source="/etc/sysconfig/jenkins"
  fi

  if [[ -z "$heap" ]]; then
    warn "No explicit -Xmx found in service config. Default heap (~256MB) is too small for production."
    return
  fi

  local val unit num_mb
  val=$(echo "$heap" | sed -E 's/-Xmx([0-9]+)([gGmM])/\1 \2/')
  num=$(echo "$val" | awk '{print $1}')
  unit=$(echo "$val" | awk '{print $2}')
  case "$unit" in
    g|G) num_mb=$((num * 1024));;
    m|M) num_mb=$num;;
    *)   num_mb=0;;
  esac

  if (( num_mb >= 4096 )); then
    ok "JVM heap ${heap} (${num_mb}MB) configured via ${found_source}."
  elif (( num_mb >= 2048 )); then
    warn "JVM heap ${heap} (${num_mb}MB) — acceptable for small setups; consider 4g+ for prod."
  elif (( num_mb > 0 )); then
    err "JVM heap ${heap} (${num_mb}MB) is too small for production. Increase -Xmx to >=4g."
  fi

  # G1GC
  local all_opts=""
  if have systemctl; then
    all_opts=$(systemctl show "${JENKINS_SERVICE}" -p Environment -p ExecStart --value 2>/dev/null || true)
  fi
  [[ -f /etc/default/jenkins ]] && all_opts="${all_opts} $(cat /etc/default/jenkins 2>/dev/null || true)"
  [[ -f /etc/sysconfig/jenkins ]] && all_opts="${all_opts} $(cat /etc/sysconfig/jenkins 2>/dev/null || true)"

  if echo "$all_opts" | grep -q "UseG1GC"; then
    ok "G1GC garbage collector enabled."
  else
    warn "UseG1GC not found. Recommended: -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
  fi
}

# ───────────────────────────── 11. Disk ───────────────────────────────
check_disk() {
  section "11. Disk Space"

  if [[ ! -d "$JENKINS_HOME" ]]; then
    return
  fi

  local df_out use_pct avail
  df_out=$(df -h "$JENKINS_HOME" | awk 'NR==2')
  use_pct=$(echo "$df_out" | awk '{print $5}' | tr -d '%')
  avail=$(echo "$df_out" | awk '{print $4}')

  if (( use_pct >= 90 )); then
    err "Disk usage on JENKINS_HOME is ${use_pct}% (avail: ${avail}). Immediate cleanup required."
  elif (( use_pct >= 80 )); then
    warn "Disk usage on JENKINS_HOME is ${use_pct}% (avail: ${avail}). Plan cleanup (buildDiscarder, workspace-cleanup)."
  else
    ok "Disk usage on JENKINS_HOME is ${use_pct}% (avail: ${avail})."
  fi

  # inodes
  local inode_use
  inode_use=$(df -i "$JENKINS_HOME" | awk 'NR==2 {print $5}' | tr -d '%')
  if [[ -n "$inode_use" ]]; then
    if (( inode_use >= 90 )); then
      err "Inode usage on JENKINS_HOME is ${inode_use}%. Too many small files."
    elif (( inode_use >= 80 )); then
      warn "Inode usage on JENKINS_HOME is ${inode_use}%."
    else
      ok "Inode usage on JENKINS_HOME is ${inode_use}%."
    fi
  fi

  # size of plugins dir (info only)
  if [[ -d "$PLUGIN_DIR" ]]; then
    local plugin_size
    plugin_size=$(du -sh "$PLUGIN_DIR" 2>/dev/null | awk '{print $1}')
    info "Plugin directory size: ${plugin_size}"
  fi
}

# ────────────────────── 12. init.groovy.d scripts ─────────────────────
check_init_groovy() {
  section "12. init.groovy.d Scripts"

  if [[ ! -d "$INIT_GROOVY_DIR" ]]; then
    info "No init.groovy.d directory (nothing to check)."
    return
  fi

  local count
  count=$(find "$INIT_GROOVY_DIR" -maxdepth 1 -name "*.groovy" 2>/dev/null | wc -l)
  if (( count == 0 )); then
    ok "init.groovy.d exists but contains no scripts."
    return
  fi

  ok "${count} init.groovy.d script(s) present."

  while IFS= read -r g; do
    local p owner
    p=$(stat -c '%a' "$g")
    owner=$(stat -c '%U' "$g")
    if [[ "$owner" != "jenkins" && "$owner" != "root" ]]; then
      err "init.groovy.d script owned by '${owner}': $(basename "$g") — SECURITY RISK (runs arbitrary code at startup)."
    elif [[ "$p" != "600" && "$p" != "640" && "$p" != "644" ]]; then
      warn "Unusual permission ${p} on init.groovy.d script: $(basename "$g")"
    fi
  done < <(find "$INIT_GROOVY_DIR" -maxdepth 1 -name "*.groovy" 2>/dev/null)
}

# ─────────────────────────── 13. JCasC ────────────────────────────────
check_casc() {
  section "13. Configuration as Code (JCasC)"

  if [[ -d "$CASC_DIR" ]]; then
    ok "JCasC directory exists: ${CASC_DIR}"
    local yaml_count
    yaml_count=$(find "$CASC_DIR" -maxdepth 2 -name "*.yaml" -o -name "*.yml" 2>/dev/null | wc -l)
    if (( yaml_count > 0 )); then
      ok "Found ${yaml_count} JCasC YAML file(s)."
      # basic YAML syntax check if python3 available
      if have python3; then
        while IFS= read -r y; do
          if ! python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" "$y" 2>/dev/null; then
            err "YAML syntax error in JCasC file: $y"
          fi
        done < <(find "$CASC_DIR" -maxdepth 2 \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null)
      fi
    else
      warn "JCasC directory exists but no *.yaml/*.yml found."
    fi
  else
    warn "JCasC directory '${CASC_DIR}' not found. Consider adopting JCasC for reproducible config."
  fi

  # CASC_JENKINS_CONFIG in service
  if have systemctl; then
    if systemctl show "${JENKINS_SERVICE}" -p Environment --value 2>/dev/null | grep -q "CASC_JENKINS_CONFIG"; then
      ok "CASC_JENKINS_CONFIG is set in service environment."
    else
      info "CASC_JENKINS_CONFIG not set in systemd Environment."
    fi
  fi
}

# ──────────────────────── 14. Recent Log Errors ───────────────────────
check_logs() {
  section "14. Recent Critical Log Entries"

  local log_file="${JENKINS_HOME}/log/jenkins.log"
  [[ -f "$log_file" ]] || log_file="/var/log/jenkins/jenkins.log"

  if [[ ! -r "$log_file" ]]; then
    info "Cannot read Jenkins log (${log_file}). Skipping log scan."
    return
  fi

  local patterns='(OutOfMemoryError|Failed to load plugin|ClassNotFoundException|NoClassDefFoundError|UnsupportedClassVersionError|Address already in use|BadPaddingException|XmlPullParserException|SEVERE|ERROR)'
  local hits
  hits=$(grep -cE "$patterns" "$log_file" 2>/dev/null || echo 0)

  if (( hits == 0 )); then
    ok "No critical error patterns in current log."
  elif (( hits < 5 )); then
    warn "${hits} critical line(s) found in ${log_file}. Review: grep -E '${patterns}' ${log_file} | tail -30"
  else
    err "${hits} critical line(s) found in ${log_file}. Investigate immediately."
    grep -E "$patterns" "$log_file" 2>/dev/null | tail -5 | while IFS= read -r l; do
      info "  ${l:0:200}"
    done
  fi

  # last startup marker
  if grep -q "Jenkins is fully up and running" "$log_file" 2>/dev/null; then
    local last_up
    last_up=$(grep "Jenkins is fully up and running" "$log_file" | tail -n1)
    info "Last successful startup: ${last_up:0:120}"
  else
    warn "'Jenkins is fully up and running' marker not found in log — Jenkins may never have completed startup."
  fi
}

# ─────────────────────────── 15. Backup ───────────────────────────────
check_backup() {
  section "15. Backup Presence"

  local candidates=(
    /backup/jenkins
    /var/backups/jenkins
    /opt/backup/jenkins
  )

  local found=""
  for d in "${candidates[@]}"; do
    if [[ -d "$d" ]]; then
      found="$d"
      break
    fi
  done

  if [[ -n "$found" ]]; then
    local newest
    newest=$(find "$found" -maxdepth 1 -type d -name "2*" 2>/dev/null | sort | tail -n1)
    if [[ -n "$newest" ]]; then
      local age_days
      age_days=$(( ( $(date +%s) - $(stat -c %Y "$newest") ) / 86400 ))
      if (( age_days <= 7 )); then
        ok "Recent backup found: ${newest} (${age_days} day(s) old)."
      else
        warn "Most recent backup is ${age_days} days old: ${newest}"
      fi
    else
      warn "Backup directory ${found} exists but no dated subdirectory found."
    fi
  else
    warn "No standard backup directory found (looked in /backup, /var/backups, /opt/backup)."
  fi
}

# ────────────────────────── 16. Summary ───────────────────────────────
print_summary() {
  section "Summary"

  echo ""
  echo -e "  ${GREEN}OK   : ${OK}${NC}"
  echo -e "  ${YELLOW}WARN : ${WARN}${NC}"
  echo -e "  ${RED}ERR  : ${ERR}${NC}"
  echo ""

  if (( ERR > 0 )); then
    echo -e "  ${RED}${BOLD}Result: CRITICAL problems detected — review [ERR] items above.${NC}"
  elif (( WARN > 0 )); then
    echo -e "  ${YELLOW}${BOLD}Result: Warnings only — review [WARN] items and consider fixing.${NC}"
  else
    echo -e "  ${GREEN}${BOLD}Result: All checks passed.${NC}"
  fi
}

# ──────────────────────────── Main ────────────────────────────────────
main() {
  banner

  # Inform running context
  echo -e "${DIM}Host        : $(hostname)${NC}"
  echo -e "${DIM}User        : $(id -un) (uid=$(id -u))${NC}"
  echo -e "${DIM}JENKINS_HOME: ${JENKINS_HOME}${NC}"
  echo -e "${DIM}Service     : ${JENKINS_SERVICE}${NC}"
  echo -e "${DIM}Time        : $(date -u '+%Y-%m-%dT%H:%M:%SZ')${NC}"

  if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${YELLOW}Note: not running as root — some checks (secrets, config.xml) may be skipped.${NC}"
  fi

  check_service
  check_java
  check_ports
  check_jhome
  check_core_files
  check_xml_validity
  check_plugins
  check_security_settings
  check_secrets_perms
  check_heap
  check_disk
  check_init_groovy
  check_casc
  check_logs
  check_backup

  print_summary

  banner
  echo ""

  if (( ERR > 0 )); then exit 2
  elif (( WARN > 0 )); then exit 1
  else exit 0
  fi
}

main "$@"