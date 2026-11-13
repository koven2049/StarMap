#!/usr/bin/env bash
set -euo pipefail
# manage.sh (physical variant) for StarMap preview site — 双形态：
# 生产（mini）= 系统 LaunchDaemon com.koven.starmap-preview（vite preview，
#   127.0.0.1:4173 strictPort，KeepAlive=true；重启免 sudo = kill 后 KeepAlive
#   拉起；真停 = svc-ctl bootout）；Test = 本目录 nohup + pidfile，绝不托管给
#   系统（install-daemon 有章防呆）。
# 实例身份 = 部署盖章：deploy / deploy-local 成功后向目标副本写
#   config/env = production（唯一写入点）；开发检出永远无章 = Test。
# 应用目录：仓内形态在 01_Web/；生产副本 = 01_Web 内容提升到根 + manage.sh，
#   两种布局用 APP_DIR 自动识别，同一个脚本两处通用。
# Label 改名（2026-11-13）：com.starmap.preview → com.koven.starmap-preview。
#   旧 label 的切换（bootout 旧 / install 新 / bootstrap 新）在部署阶段执行。
# Health: vite preview 无 /health 端点，就绪判定 = 根路径有 HTTP 应答。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── deploy-check.sh: conditional source, no-op fallback when no parent repo ──
for _dc in "$SCRIPT_DIR/../coding/deploy-common/deploy-check.sh" \
           "$SCRIPT_DIR/../../ai-projects/coding/deploy-common/deploy-check.sh"; do
  if [[ -f "$_dc" ]]; then
    # shellcheck disable=SC1090
    source "$_dc"
    break
  fi
done
command -v _check_deploy_target &>/dev/null || _check_deploy_target() { :; }

# ── log helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

# ── config ──────────────────────────────────────────────────────────────────
SERVICE="starmap-preview"
PORT=4173
# 仓内形态：应用在 01_Web/；生产形态：应用内容提升到副本根目录。
if [[ -d "$SCRIPT_DIR/01_Web" ]]; then APP_DIR="$SCRIPT_DIR/01_Web"; else APP_DIR="$SCRIPT_DIR"; fi
NODE_BIN="${STARMAP_NODE:-$(command -v node 2>/dev/null || printf '/opt/homebrew/bin/node')}"
VITE_JS="$APP_DIR/node_modules/vite/bin/vite.js"
PIDFILE="$SCRIPT_DIR/run/$SERVICE.pid"
LOGFILE="$SCRIPT_DIR/run/$SERVICE.log"
DEPLOY_CFG="$SCRIPT_DIR/config/deploy.cfg"
# 托管形态：生产（mini）= 系统 LaunchDaemon；Test = nohup + pidfile。
# label 已改名（com.koven.* 进 svc-ctl 免密白名单）；LEGACY_LABEL 仅用于
# 切换过渡期的指引输出，不再被本脚本安装/操作。
LAUNCHD_LABEL="${LAUNCHD_LABEL:-com.koven.starmap-preview}"
LEGACY_LABEL="com.starmap.preview"
PLIST_SRC="$SCRIPT_DIR/deploy/$LAUNCHD_LABEL.plist"
PLIST_DST="/Library/LaunchDaemons/$LAUNCHD_LABEL.plist"
SVC_CTL=/usr/local/bin/svc-ctl
# 进程身份特异片段：launchd 与 nohup 实例的命令行都含本目录 node_modules 下的
# vite.js 绝对路径（目录级唯一；.rsync-exclude 不同步 node_modules）。
PROC_IDENT="$APP_DIR/node_modules"

START_CMD=("$NODE_BIN" "$VITE_JS" preview --host 127.0.0.1 --port "$PORT" --strictPort)

require_app() {
  [[ -f "$VITE_JS" ]] || { log_error "missing $VITE_JS — run ./manage.sh init first (npm install)"; exit 1; }
}
require_dist() {
  [[ -d "$APP_DIR/dist" ]] || { log_error "missing $APP_DIR/dist — run ./manage.sh build first (vite preview serves dist/)"; exit 1; }
}

is_running() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null
}

# 监听 $PORT 的 PID（无监听/无 lsof → 空）。lsof 无匹配退出码 1，须归零防 set -e。
port_listener_pid() {
  command -v lsof &>/dev/null || return 0
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true
}

port_listener_pids() {
  command -v lsof &>/dev/null || return 0
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true
}

# 只保留身份确认的监听 PID：ps 命令行须含本目录 node_modules 下的 vite.js 路径。
# 端口可能被无关进程占用——身份不确认绝不杀（launchd 与 nohup 实例都带该路径）。
confirmed_server_pids() {
  local pid cmdline
  while IFS= read -r pid; do
    if [[ -n "$pid" ]]; then
      cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      if [[ "${cmdline:-}" == *"$PROC_IDENT"* ]]; then
        printf '%s\n' "$pid"
      fi
    fi
  done < <(port_listener_pids)
  return 0
}

alive() { kill -0 "$1" 2>/dev/null; }

# 停一个 PID：先 TERM，等 ${STARMAP_STOP_TERM_WAIT:-3}s 不退再 KILL，再等
# ${STARMAP_STOP_KILL_WAIT:-2}s。仍活着（杀不动/权限不够）返回 1。
stop_pid() {
  local pid="$1" waits="${STARMAP_STOP_TERM_WAIT:-3}" i
  kill -TERM "$pid" 2>/dev/null || true
  for ((i = 0; i < waits * 10; i++)); do alive "$pid" || return 0; sleep 0.1; done
  log_warn "pid $pid ignored SIGTERM — sending SIGKILL …"
  kill -KILL "$pid" 2>/dev/null || true
  waits="${STARMAP_STOP_KILL_WAIT:-2}"
  for ((i = 0; i < waits * 10; i++)); do alive "$pid" || return 0; sleep 0.1; done
  alive "$pid" && return 1
  return 0
}

# 轮询站点根路径直到有 HTTP 应答，超时 ${STARMAP_READY_WAIT:-15}s 返回 1。
# vite preview 没有 /health；无 curl 的机器退化为「确认过的本站监听存在」。
wait_ready() {
  local timeout="${STARMAP_READY_WAIT:-15}" i
  if command -v curl &>/dev/null; then
    for ((i = 0; i < timeout * 2; i++)); do
      curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/" &>/dev/null && return 0
      sleep 0.5
    done
  else
    for ((i = 0; i < timeout * 2; i++)); do
      if [[ -n "$(confirmed_server_pids | head -n 1)" ]]; then return 0; fi
      sleep 0.5
    done
  fi
  return 1
}

# ── 实例身份 = 部署盖章（2026-11-13 规约）──────────────────────────────────
# deploy / deploy-local 成功后在目标副本写 config/env = production（唯一写入点）。
# 两台机器的开发检出永远无章 → 都是 Test。manage.sh 只读章判身份，禁止用
# 主机名 / IP / deploy.cfg 的 env 字段做机器推断。方向单向：源副本带章即拒绝部署。
prod_stamp_file() { printf '%s/config/env' "$SCRIPT_DIR"; }
is_prod_instance() { [[ "$(cat "$(prod_stamp_file)" 2>/dev/null || true)" == production ]]; }
refuse_if_prod_source() {
  is_prod_instance || return 1
  log_error "本目录是生产副本（config/env = production，由 deploy 盖章）——不能作为部署源。"
  log_error "部署请在开发检出执行（均无章 = Test）。"
  return 0
}
system_managed() {
  command -v launchctl &>/dev/null || return 1
  launchctl print "system/$LAUNCHD_LABEL" &>/dev/null
}
# 目录级托管判定：同机 Test 检出与生产副本共用同一个 label——只看 label 会把
# Test 的 start/stop 误判成「生产托管中」。托管 = label 在 system 域 **且**
# 监听进程命令行含本目录 node_modules vite.js（= 本目录的实例正被 Daemon 托管）。
daemon_managed_here() {
  system_managed || return 1
  [[ -n "$(confirmed_server_pids | head -n 1)" ]]
}
# 端口被「别的目录」的本站实例占用（典型：同机生产副本占着端口）。
port_held_elsewhere() {
  local listener; listener="$(port_listener_pid)"
  [[ -n "$listener" ]] || return 1
  [[ -z "$(confirmed_server_pids | head -n 1)" ]]
}
# 免密服务控制：root 所有的 svc-ctl 包装（白名单 label，只开放 bootout/bootstrap/
# kickstart 等动作）。缺失时相关操作降级为指引，不硬错、不假成功。
svc_ctl() { sudo -n "$SVC_CTL" "$@"; }

# 系统域托管守卫（仅当本目录实例被 Daemon 托管时触发）：软停无意义——kill 后
# KeepAlive 立即拉起。真停 = svc_ctl bootout；helper 未装时降级为准确指引。
# 返回码：0=已真停完成；1=非本目录托管（调用方走各自路径）；2=托管但 helper
# 未装、无法免密真停（调用方必须拒绝软停，exit 1）。
guard_prod_daemon_stop() {
  daemon_managed_here || return 1
  if svc_ctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null; then
    sleep 1
    [[ -n "$(confirmed_server_pids | head -n 1)" ]] && stop_pid "$(confirmed_server_pids | head -n 1)" || true
    log_ok "已停用（svc_ctl bootout，语义 = 下线，重启不自启）。重新上线：./manage.sh start（走 bootstrap）。"
    return 0
  fi
  log_warn "本目录实例由系统 LaunchDaemon 托管（KeepAlive），软停会被立即拉起。"
  log_warn "免密真停需一次性安装 svc-ctl helper（root）："
  log_warn "  sudo bash ~/Services/install-svc-ctl.sh"
  log_warn "装好后本命令即可真停；或手动 ! sudo launchctl bootout system/$LAUNCHD_LABEL"
  return 2
}

cmd_init() {
  command -v "$NODE_BIN" >/dev/null 2>&1 || { log_error "node not found ($NODE_BIN)"; exit 1; }
  mkdir -p "$SCRIPT_DIR/run" "$SCRIPT_DIR/config"
  log_step "npm install in ${APP_DIR} …"
  ( cd "$APP_DIR" && npm install --no-audit --no-fund )
  log_ok "dependencies installed"
}

cmd_build() {
  require_app
  log_step "npm run build in ${APP_DIR} …"
  ( cd "$APP_DIR" && npm run build )
  log_ok "build complete: ${APP_DIR}/dist"
}

# Test 形态启动：本目录 nohup + pidfile。
start_service() {
  require_app
  require_dist
  if is_running; then log_ok "Already running (pid $(cat "$PIDFILE")) — idempotent, exit 0"; return 0; fi
  local listener; listener="$(port_listener_pid)"
  if [[ -n "${listener:-}" ]]; then
    if [[ -n "$(confirmed_server_pids | head -n 1)" ]]; then
      log_ok "Port $PORT already served by this dir's instance (pid $listener) — skip second start, exit 0"
      return 0
    fi
    log_error "Port $PORT is occupied by an unknown process (pid $listener) — not starting, not killing."
    return 1
  fi
  rm -f "$PIDFILE"
  log_step "Starting $SERVICE on port $PORT (Test: nohup) …"
  ( cd "$APP_DIR" && nohup "${START_CMD[@]}" >>"$LOGFILE" 2>&1 & echo $! >"$PIDFILE" )
  sleep 2
  if is_running; then
    log_ok "Started.  pid $(cat "$PIDFILE")  →  http://localhost:$PORT"
  else
    log_error "Failed to start. See $LOGFILE"; rm -f "$PIDFILE"; return 1
  fi
  return 0
}

cmd_start() {
  if daemon_managed_here; then
    # 本目录实例由 KeepAlive 保活，start 幂等。
    log_ok "Managed by system LaunchDaemon ($LAUNCHD_LABEL) — instance kept alive; start is a no-op."
    return 0
  fi
  if port_held_elsewhere; then
    log_error "端口 $PORT 已被本站的另一个副本占用（如 ~/Services 生产实例，系统 Daemon 托管）。"
    log_error "Test 与生产同端口不能并存：要跑本目录实例，先去生产副本执行 stop。"
    exit 1
  fi
  # 有章 = 生产副本（此前被 bootout 停用）：走 bootstrap 回托管，而非 nohup。
  if is_prod_instance; then
    require_app
    if svc_ctl bootstrap "system/$LAUNCHD_LABEL" 2>/dev/null; then
      sleep 2
      if wait_ready; then
        log_ok "Started via svc_ctl bootstrap.  pid $(port_listener_pid)  →  http://localhost:$PORT"
        return 0
      fi
      log_error "Bootstrap done but site not responding on port $PORT."
      return 1
    fi
    log_error "免密启动失败：svc-ctl helper 未安装（root 一次性安装）："
    log_error "  sudo bash ~/Services/install-svc-ctl.sh"
    log_error "或手动 ! sudo launchctl bootstrap system $PLIST_DST"
    exit 1
  fi
  start_service || exit 1
}

cmd_stop() {
  # 注意 set -e：guard 的 rc=1/2 是正常返回值，必须用 || 捕获（裸分号接
  # local grc=$? 会被 errexit 直接杀掉脚本）。
  local grc=0
  guard_prod_daemon_stop || grc=$?
  [[ "$grc" -eq 0 ]] && return 0   # guard 已真停
  [[ "$grc" -eq 2 ]] && exit 1     # 托管但 helper 缺失：拒绝假成功
  if port_held_elsewhere; then
    log_error "端口 $PORT 上的实例属于另一个副本（系统 Daemon 托管），不属于本目录——本目录无可停。"
    log_error "要停它：去对应副本目录执行 ./manage.sh stop，或直接 sudo bootout。"
    exit 1
  fi
  # 停止目标 = pidfile 里的 PID + 监听 $PORT 且身份确认的本站进程。
  # 身份不确认（ps 命令行不含本目录 node_modules vite.js）的进程绝不杀。
  local targets=() pid t dup cmdline
  if [[ -f "$PIDFILE" ]]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && alive "$pid"; then
      cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      if [[ "${cmdline:-}" == *"$PROC_IDENT"* ]]; then
        targets+=("$pid")
      else
        log_warn "pidfile pid $pid is not this site's vite process (stale pidfile?) — not killing it."
      fi
    else
      log_warn "Process not running."
    fi
  fi
  while IFS= read -r pid; do
    if [[ -n "$pid" ]]; then
      dup=0
      if [[ ${#targets[@]} -gt 0 ]]; then
        for t in "${targets[@]}"; do
          if [[ "$t" == "$pid" ]]; then dup=1; break; fi
        done
      fi
      if [[ "$dup" != 1 ]]; then targets+=("$pid"); fi
    fi
  done < <(confirmed_server_pids)

  if [[ ${#targets[@]} -eq 0 ]]; then
    log_warn "No pidfile and no confirmed instance on port $PORT — nothing to stop."
    rm -f "$PIDFILE"
    return 0
  fi

  log_step "Stopping $SERVICE (pid ${targets[*]}) …"
  local failed=0
  for pid in "${targets[@]}"; do
    stop_pid "$pid" || { log_error "Could not stop pid $pid."; failed=1; }
  done
  rm -f "$PIDFILE"
  if [[ "$failed" == 1 ]]; then return 1; fi
  # KeepAlive=true 的 launchd 会在老实例死掉的瞬间拉起新实例。若拉起者不是本
  # label（如 label 改名过渡期残留的旧 Daemon），如实给出清理指引。
  local respawned; respawned="$(confirmed_server_pids | head -n 1)"
  if [[ -n "${respawned:-}" ]]; then
    if system_managed; then
      log_ok "Old instance stopped (launchd KeepAlive already respawned pid $respawned)."
    else
      log_warn "实例被杀后立即被拉起（pid ${respawned}）：有系统 Daemon 在保活，但 label ${LAUNCHD_LABEL} 并未加载。"
      log_warn "多半是旧 label（${LEGACY_LABEL}）的 Daemon 残留——真停需 root："
      log_warn "  ! sudo launchctl bootout system/${LEGACY_LABEL} 2>/dev/null; ! sudo launchctl bootout system/${LAUNCHD_LABEL} 2>/dev/null"
    fi
  else
    log_ok "Stopped."
  fi
  return 0
}

cmd_restart() {
  log_step "Restarting $SERVICE …"
  # 本目录实例被系统 Daemon 托管：kill 后 KeepAlive 自动拉起新进程——重启免 sudo；
  # 绝不能 nohup 起第二实例。
  if daemon_managed_here; then
    log_info "system LaunchDaemon owns respawn — killing instance and letting KeepAlive restart it …"
    local pid killed=0
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      stop_pid "$pid" && killed=1 || log_warn "could not stop pid $pid"
    done < <(confirmed_server_pids)
    [[ "$killed" == 1 ]] || { log_error "No confirmed instance to restart."; return 1; }
  elif port_held_elsewhere; then
    log_error "端口 $PORT 被另一副本的实例占用——restart 不越目录杀别的副本的进程。"
    log_error "要重启它：去对应副本目录执行 ./manage.sh restart。"
    exit 1
  else
    local old_pids=" " pid
    while IFS= read -r pid; do
      if [[ -n "$pid" ]]; then old_pids+="$pid "; fi
    done < <(confirmed_server_pids)
    cmd_stop || { log_error "Restart failed: old instance would not stop."; return 1; }
    # 观察窗：外部 KeepAlive（含 label 改名过渡期的旧 Daemon 残留）可能在数秒内
    # 拉起实例。观察到外部拉起就绝不再 nohup 起第二实例（否则抢端口互踩）。
    local grace="${STARMAP_LAUNCHD_GRACE:-5}" i respawned=""
    for ((i = 0; i < grace * 2; i++)); do
      while IFS= read -r pid; do
        if [[ -n "$pid" ]]; then
          if [[ "$old_pids" != *" $pid "* ]]; then respawned="$pid"; break 2; fi
        fi
      done < <(confirmed_server_pids)
      sleep 0.5
    done
    if [[ -n "$respawned" ]]; then
      if system_managed; then
        log_info "Instance respawned externally (launchd KeepAlive, pid $respawned) — not starting a second one."
      else
        log_warn "Instance respawned externally (pid ${respawned}) by a Daemon not named ${LAUNCHD_LABEL}"
        log_warn "（多半是旧 label ${LEGACY_LABEL} 残留）。请按 AGENTS.md 的 label 切换步骤清理，"
        log_warn "本轮把它当作重启结果（代码已随进程重载）。"
      fi
    else
      start_service || { log_error "Restart failed: start failed."; return 1; }
    fi
  fi

  # 站点无应答就不算重启完成。
  log_info "Waiting for site to respond on port $PORT …"
  if wait_ready; then
    local now; now="$(confirmed_server_pids | head -n 1)"
    log_ok "Restarted.  pid ${now:-unknown}  →  http://localhost:$PORT"
    return 0
  fi
  log_error "Restart failed: site not responding after ${STARMAP_READY_WAIT:-15}s."
  return 1
}

cmd_status() {
  local pid="" up="not responding"
  if is_running; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  fi
  if command -v curl &>/dev/null; then
    curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/" &>/dev/null && up="responding" || true
  fi
  local state="not running"
  if [[ "$up" == "responding" ]]; then
    state="running"
    [[ -n "${pid:-}" ]] && state="running (PID $pid)"
  elif [[ -n "${pid:-}" ]]; then
    state="running (PID $pid, no answer)"
  fi
  local failed=0
  echo "┌─ $SERVICE (physical) · port $PORT ─────────────────"
  printf '│ %-9s : %s\n' "Status"  "$state"
  printf '│ %-9s : %s\n' "URL"     "http://localhost:$PORT"
  printf '│ %-9s : %s\n' "Answer"  "$up"
  printf '│ %-9s : %s\n' "App dir" "${APP_DIR#$SCRIPT_DIR/}"
  printf '│ %-9s : %s\n' "Stamp"   "$(is_prod_instance && echo 'production (deployed)' || echo 'none (Test)')"
  if system_managed; then printf '│ %-9s : %s\n' "托管" "LaunchDaemon (system) $LAUNCHD_LABEL"; fi
  echo "└──────────────────────────────────────────────────"
  [[ "$up" == "responding" ]] || failed=1
  [[ -f "$VITE_JS" ]] || { log_warn "node_modules missing — run ./manage.sh init"; failed=1; }
  [[ "$failed" -eq 0 ]] || return 1
  return 0
}

cmd_rebuild() {
  cmd_init
  cmd_build
  cmd_restart
}

cfg_value() {
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$2" | head -n 1
}

# 代码同步 = 01_Web 应用内容 + manage.sh + deploy/（副本两种布局都能跑生命周期）。
# extra（如 --dry-run）必须作用到全部三条 rsync，dry-run 才是真演练。
# ${extra[@]+…} 是 bash 3.2 兼容写法：set -u 下展开空数组会报 unbound variable。
rsync_app() {
  local dest_root="$1"; shift
  local extra=("$@")
  local excl="$SCRIPT_DIR/.rsync-exclude"
  [[ -f "$excl" ]] || { log_error ".rsync-exclude missing — refusing deploy."; exit 1; }
  # extra（如 --delete）只作用于应用目录同步（带 exclude-from 守护）；
  # 下两行是单文件/模板拷贝，不参与 delete 语义，也不允许裸 --delete。
  rsync -az ${extra[@]+"${extra[@]}"} --exclude-from="$excl" "$APP_DIR/" "$dest_root/"
  rsync -az "$SCRIPT_DIR/manage.sh" "$dest_root/"
  rsync -az "$SCRIPT_DIR/deploy/" "$dest_root/deploy/"
}

cmd_deploy() {
  local dry_run=false
  while [[ $# -gt 0 ]]; do case "$1" in -d|--dry-run) dry_run=true;; *) log_error "Unknown opt: $1"; exit 1;; esac; shift; done
  local cfg="$DEPLOY_CFG"
  [[ -f "$cfg" ]] || { log_error "config/deploy.cfg not found — copy config/deploy.cfg.example"; exit 1; }
  local env ssh_target deploy_path
  env="$(cfg_value env "$cfg")"
  ssh_target="$(cfg_value ssh_target "$cfg")"
  deploy_path="$(cfg_value deploy_path "$cfg")"
  [[ -n "$env" && -n "$ssh_target" && -n "$deploy_path" ]] || {
    log_error "deploy.cfg needs env, ssh_target and deploy_path"; exit 1; }
  # 方向单向：源副本带章（生产实例）拒绝作为部署源。
  refuse_if_prod_source && exit 1
  _check_deploy_target "$ssh_target" || { log_error "Same-machine deploy? Use ./manage.sh deploy-local"; exit 1; }

  local sha; sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  log_step "sync $sha to $ssh_target:$deploy_path ($env)"
  ssh -o BatchMode=yes "$ssh_target" "mkdir -p '$deploy_path'" || { log_error "cannot mkdir remote path"; exit 1; }
  if [[ "$dry_run" == true ]]; then
    rsync_app "${ssh_target}:${deploy_path}/" --dry-run
    log_warn "Dry-run only — verify the list has no node_modules/ dist/ config/ secrets; drop -d to deploy for real"
    return 0
  fi
  rsync_app "${ssh_target}:${deploy_path}/"
  if [[ "$dry_run" == true ]]; then
    log_warn "Dry-run only — verify the list has no node_modules/ dist/ config/ secrets; drop -d to deploy for real"
    return 0
  fi
  # 部署盖章：目标副本从此是生产实例（唯一写入点；config/ 被排除不受影响）。
  ssh -o BatchMode=yes "$ssh_target" "mkdir -p '$deploy_path/config' && printf 'production\n' > '$deploy_path/config/env'"
  ssh -o BatchMode=yes "$ssh_target" "printf '%s\n' '$sha' > '$deploy_path/VERSION'"
  log_step "install deps, build and restart on remote"
  ssh -o BatchMode=yes "$ssh_target" "cd '$deploy_path' && npm install --no-audit --no-fund && npm run build && ./manage.sh restart && sleep 3 && ./manage.sh status"
  log_ok "deployed $sha"
}

cmd_deploy_local() {
  # Same-machine deploy front door: dev dir and prod dir on one machine (mini
  # norm). Local rsync, no SSH and no deploy-check gate — that gate blocks
  # "target = this machine", which is exactly the case this command serves.
  local dry_run=false target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dry-run) dry_run=true ;;
      -*) log_error "Unknown option: $1"; exit 1 ;;
      *) [[ -n "$target" ]] && { log_error "Too many arguments: $1"; exit 1; }; target="$1" ;;
    esac; shift
  done
  target="${target:-$HOME/Services/$SERVICE}"
  local excl="$SCRIPT_DIR/.rsync-exclude"
  [[ -f "$excl" ]] || { log_error ".rsync-exclude missing — refusing bare --delete deploy."; exit 1; }
  [[ -d "$target" ]] || { log_error "target dir missing: $target (never auto-created; create it manually if intended)"; exit 1; }
  [[ "$(cd "$target" && pwd)" == "$SCRIPT_DIR" ]] && { log_error "target equals source dir — refusing."; exit 1; }
  refuse_if_prod_source && exit 1
  local args=(--delete)
  [[ "$dry_run" == true ]] && args+=(--dry-run)
  log_info "Deploying (local) → ${target} …"
  rsync_app "$target/" "${args[@]}"
  if [[ "$dry_run" == true ]]; then
    log_warn "Dry-run only — the list must not contain node_modules/ dist/ config/ secrets; drop -d to deploy for real"
  else
    # 部署盖章（唯一写入点，每次部署重盖；config/ 被排除，目标副本 env 不受 rsync 影响）
    mkdir -p "$target/config"; printf 'production\n' > "$target/config/env"
    printf '%s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" > "$target/VERSION"
    log_step "install deps, build and restart on target"
    ( cd "$target" && npm install --no-audit --no-fund && npm run build && ./manage.sh restart )
    log_ok "Deploy complete (stamped production)."
  fi
}

# ── install-daemon / uninstall-daemon：生产托管显式安装 ─────────────────────
# 防呆是本命令的核心：Test（无章）一律拒绝——Test 绝不托管给系统。命令只打印
# 准确的 sudo 指令，脚本自身不越权执行。
cmd_install_daemon() {
  [[ -f "$PLIST_SRC" ]] || { log_error "Missing plist template $PLIST_SRC"; exit 1; }
  if is_prod_instance; then
    log_ok "生产实例（部署章在身）。安装命令（需 root，可用 ! 前缀执行）："
    echo "  sudo install -o root -g wheel -m 644 '$PLIST_SRC' $PLIST_DST"
    echo "  sudo launchctl bootstrap system $PLIST_DST"
    log_info "托管后：restart 免 sudo（kill+KeepAlive）；真停用 ./manage.sh stop（svc-ctl bootout）。"
    log_info "label 改名过渡期若旧 label（${LEGACY_LABEL}）仍在：先 ! sudo launchctl bootout system/${LEGACY_LABEL} 再装新。"
  else
    log_error "拒绝安装：本目录无部署章（config/env ≠ production）——这是 Test 检出，Test 不托管给系统。"
    log_error "生产副本由 deploy/deploy-local 盖章；盖章后在生产副本上执行本命令。"
    exit 1
  fi
}

cmd_uninstall_daemon() {
  if is_prod_instance; then
    log_ok "生产机卸载托管命令（需 root）："
    echo "  sudo launchctl bootout system/$LAUNCHD_LABEL 2>/dev/null"
    echo "  sudo rm $PLIST_DST"
    log_info "卸载后本目录 ./manage.sh start 即回到 Test 形态（nohup）。"
  else
    log_error "本目录无部署章（Test 检出本就不该有托管），无需卸载。"
    exit 1
  fi
}

usage() {
  cat <<'USAGE'
Usage: manage.sh <command> [args]

Manage the StarMap preview site (vite preview, 127.0.0.1:4173). Dual-form
hosting: the production copy on the Mac mini runs as a system LaunchDaemon
stamped config/env=production by deploy; dev checkouts are Test (nohup +
pidfile, never handed to launchd). The app lives in 01_Web/ in this repo; the
production copy is 01_Web content promoted to its root plus this manage.sh.

Commands:
  init               npm install into 01_Web, create run/ and config/ dirs
  build              npm run build into 01_Web/dist (vite preview serves dist/)
  start              start the site (Test: nohup; managed: no-op; stamped: bootstrap)
  stop               stop the site (managed: svc-ctl bootout, honest refusal without it)
  restart            restart (managed: kill + KeepAlive respawn; else stop + start)
  status             instance, port answer, stamp and daemon state (exit 1 when down)
  rebuild            init + build + restart
  deploy [-d]        rsync app + manage.sh to config/deploy.cfg target, stamp,
                     then npm install/build and restart on the remote; -d dry-run
  deploy-local [-d] [path]
                     same-machine deploy; default ~/Services/starmap-preview
                     (must exist); stamps config/env=production on the target
  install-daemon     print the sudo commands to install the system LaunchDaemon
                     (refused on Test checkouts: stamp required)
  uninstall-daemon   print the sudo commands to remove the daemon
  -h, --help         show this help

Examples:
  ./manage.sh status
  ./manage.sh deploy -d
  ./manage.sh deploy-local
USAGE
}

cmd="${1:-}"
case "$cmd" in
  -h|--help|help) usage ;;
  init) cmd_init ;;
  build) cmd_build ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_restart ;;
  status) cmd_status ;;
  rebuild) cmd_rebuild ;;
  deploy) cmd_deploy "$@" ;;
  deploy-local) shift; cmd_deploy_local "$@" ;;
  install-daemon) cmd_install_daemon ;;
  uninstall-daemon) cmd_uninstall_daemon ;;
  help|--help|-h) usage ;;
  *) echo "Usage: manage.sh <command> (see manage.sh --help)" >&2; exit 64 ;;
esac
