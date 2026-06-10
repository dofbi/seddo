#!/usr/bin/env bash
# seddo — Agent coordination via GitHub Gist
# Wolof: séddo = partager, la répartition
# A seddo is a sharing space where agents exchange tasks, knowledge, and progress.
#
# Architecture:
#   ~/.seddo/                    → multi-seddo workspace
#   ~/.seddo/active              → name of the active seddo
#   ~/.seddo/<name>/config       → per-seddo config (gist IDs, role, etc.)
#   ~/.seddo/<name>/state.json   → hub/spoke + fork registry
#
# Role:
#   - HUB: created the original gist, owns the canonical source
#   - SPOKE: forked the gist, syncs via hub → spoke pull, spoke → hub push

set -euo pipefail

SEDDO_ROOT="${SEDDO_ROOT:-$HOME/.seddo.d}"
SEDDO_ACTIVE_FILE="${SEDDO_ROOT}/active"
SEDDO_VERSION="2.0.0"

# Per-seddo paths (set by load_config)
seddo_name=""
seddo_config=""
seddo_state=""

# Active seddo config (from files)
GIST_ID=""
AGENT_NAME=""
ROLE=""           # hub | spoke
FORK_OF=""        # gist ID of hub (for spokes)
FORK_GIST_ID=""   # our fork's gist ID (for spokes)
GH_USER=""

# ─── Timestamp ───────────────────────────────────────────
now() { date -u +"%Y-%m-%dT%H:%MZ"; }

# ─── Config I/O ──────────────────────────────────────────
ensure_seddo_root() {
  # Auto-migrate old ~/.seddo file to new directory structure
  if [[ -f "$HOME/.seddo" ]] && [[ ! -d "$SEDDO_ROOT" ]]; then
    local old_gist_id old_agent_name old_swarm_name old_gist_url
    old_gist_id=$(grep '^SWARM_GIST_ID=' "$HOME/.seddo" 2>/dev/null | cut -d= -f2-)
    old_agent_name=$(grep '^AGENT_NAME=' "$HOME/.seddo" 2>/dev/null | cut -d= -f2-)
    old_swarm_name=$(grep '^SWARM_NAME=' "$HOME/.seddo" 2>/dev/null | cut -d= -f2-)
    old_gist_url=$(grep '^GIST_URL=' "$HOME/.seddo" 2>/dev/null | cut -d= -f2-)

    if [[ -n "$old_gist_id" ]]; then
      echo "📦 Auto-migrating old seddo config to new format..."
      mkdir -p "$SEDDO_ROOT"
      local seddo_dir="${SEDDO_ROOT}/${old_swarm_name}"
      mkdir -p "$seddo_dir"
      cat > "$seddo_dir/config" << EOF
GIST_ID=${old_gist_id}
GIST_URL=${old_gist_url}
AGENT_NAME=${old_agent_name}
ROLE=hub
FORK_OF=
FORK_GIST_ID=
EOF
      echo "${old_swarm_name}" > "$SEDDO_ROOT/active"
      local bak_ts
      bak_ts=$(date +%s)
      mv "$HOME/.seddo" "$HOME/.seddo.bak.${bak_ts}"
      echo "   ✅ Migrated: ${old_swarm_name}"
      echo "   📁 Old config backed up to ~/.seddo.bak.${bak_ts}"
    fi
  fi
  mkdir -p "$SEDDO_ROOT"
}

load_active_seddo() {
  if [[ ! -f "$SEDDO_ACTIVE_FILE" ]]; then return 1; fi
  seddo_name=$(cat "$SEDDO_ACTIVE_FILE")
  load_seddo_config "$seddo_name"
}

load_seddo_config() {
  local name="$1"
  seddo_config="${SEDDO_ROOT}/${name}/config"
  seddo_state="${SEDDO_ROOT}/${name}/state.json"

  if [[ -f "$seddo_config" ]]; then
    GIST_ID=$(grep '^GIST_ID=' "$seddo_config" | cut -d= -f2-)
    AGENT_NAME=$(grep '^AGENT_NAME=' "$seddo_config" | cut -d= -f2-)
  fi
  GIST_ID="${GIST_ID:-${SWARM_GIST_ID:-}}"
  AGENT_NAME="${AGENT_NAME:-${SEDDO_AGENT:-}}"
  ROLE=$(grep '^ROLE=' "$seddo_config" 2>/dev/null | cut -d= -f2- || echo "hub")
  FORK_OF=$(grep '^FORK_OF=' "$seddo_config" 2>/dev/null | cut -d= -f2- || echo "")
  FORK_GIST_ID=$(grep '^FORK_GIST_ID=' "$seddo_config" 2>/dev/null | cut -d= -f2- || echo "")
}

save_seddo_config() {
  local name="$1"
  seddo_config="${SEDDO_ROOT}/${name}/config"
  mkdir -p "$(dirname "$seddo_config")"
  cat > "$seddo_config"
  # Set as active
  echo "$name" > "$SEDDO_ACTIVE_FILE"
  seddo_name="$name"
}

save_state_json() {
  local name="$1"
  local state_file="${SEDDO_ROOT}/${name}/state.json"
  mkdir -p "$(dirname "$state_file")"
  cat > "$state_file"
}

# ─── Prerequisites ───────────────────────────────────────
require_gh() {
  if ! command -v gh &>/dev/null; then
    echo "❌ gh (GitHub CLI) not found."
    echo "   Install: https://cli.github.com/"
    exit 1
  fi
  if ! gh auth status &>/dev/null 2>&1; then
    echo "❌ gh not authenticated. Run: gh auth login"
    exit 1
  fi
}

require_seddo() {
  if [[ -z "$seddo_name" ]]; then
    echo "❌ No active seddo."
    echo "   Run: seddo list   (to see available seddos)"
    echo "   Run: seddo init   (to create a new seddo)"
    echo "   Run: seddo join   (to join an existing seddo)"
    exit 1
  fi
}

require_role() {
  if [[ -z "$ROLE" ]]; then
    echo "❌ No role configured for seddo « $seddo_name »"
    exit 1
  fi
}

# ─── Gist helpers ───────────────────────────────────────
extract_gist_id() {
  local url="$1"
  local id
  id=$(echo "$url" | grep -oP '[a-f0-9]{32}' | head -1)
  [[ -n "$id" ]] && echo "$id" && return
  id=$(echo "$url" | grep -oP '[a-f0-9]{20,}' | head -1)
  [[ -n "$id" ]] && echo "$id" && return
  return 1
}

# Fetch a gist file (raw text)
fetch_file() {
  local gist_id="${1:-$GIST_ID}"
  local filename="$2"
  gh gist view "$gist_id" -f "$filename" 2>/dev/null || echo ""
}

# Fetch all gist files (raw)
fetch_all() {
  local gist_id="${1:-$GIST_ID}"
  gh gist view "$gist_id" --raw
}

# Edit a gist file via PATCH (pure bash + gh)
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

edit_file() {
  local gist_id="${1:-$GIST_ID}"
  local filename="$2"
  local content="$3"
  local esc_name esc_content
  esc_name=$(json_escape "$filename")
  esc_content=$(json_escape "$content")
  printf '{"files":{"%s":{"content":"%s"}}}' "$esc_name" "$esc_content" \
    | gh api --method PATCH "/gists/${gist_id}" --input - >/dev/null
}

# Update a field in a task block
update_task_field() {
  local content="$1"
  local task_id="$2"
  local field="$3"
  local value="$4"
  echo "$content" | awk -v tid="$task_id" -v fld="$field" -v val="$value" '
    /^### / { in_task = ($0 ~ "### " tid ":") }
    in_task && $0 ~ "^- " fld ":" { sub("^- " fld ":.*", "- " fld ": " val) }
    { print }
  '
}

# Fork a gist (POST /gists/:id/forks) — returns fork gist JSON
fork_gist() {
  local gist_id="$1"
  local fork_info
  fork_info=$(curl -s -X POST \
    -H "Authorization: Bearer $(gh auth token)" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/gists/${gist_id}/forks")
  echo "$fork_info"
}

# Get list of forks for a gist
list_forks() {
  local gist_id="$1"
  gh api --paginate "/gists/${gist_id}/forks" 2>/dev/null || echo "[]"
}

# Get current GitHub user
get_gh_user() {
  gh api user --jq .login 2>/dev/null || echo ""
}

# ─── Registry helpers ───────────────────────────────────
# REGISTRY.md lives in the hub gist and lists all spokes/forks
update_registry_in_hub() {
  local agent_name="$1"
  local fork_gist_id="$2"
  local fork_gist_url="$3"

  local registry
  registry=$(fetch_file "$GIST_ID" "REGISTRY.md")

  # Check if already registered
  if echo "$registry" | grep -q "| @${agent_name} "; then
    # Update existing row
    echo "   (already registered in REGISTRY.md)"
    return
  fi

  local ts
  ts=$(now)
  local row="| @${agent_name} | ${fork_gist_id} | ${fork_gist_url} | ${ts} |"
  local nl=$'\n'

  if [[ -z "$registry" ]] || ! echo "$registry" | grep -q "^| Agent"; then
    # Create header
    registry="# Registry — ${seddo_name}${nl}${nl}| Agent | Fork Gist ID | Fork URL | Registered |${nl}|-------|-------------|----------|-------------|"
  fi

  edit_file "$GIST_ID" "REGISTRY.md" "${registry}${nl}${row}"
}

# ─── COMMANDS ───────────────────────────────────────────

# ── seddo init ──────────────────────────────────────────
cmd_init() {
  echo "🤝 Seddo — Create a new coordination space"
  echo "   (wolof: séddo = partager)"
  echo ""

  require_gh

  GH_USER=$(get_gh_user)
  echo "✅ Authenticated as: @${GH_USER}"
  echo ""

  # Check gist creation permission
  echo "🔍 Testing GitHub permissions..."
  local test_tmp
  test_tmp=$(mktemp)
  echo "seddo-test" > "$test_tmp"
  local test_url
  test_url=$(gh gist create -d "seddo-test" -f "test.md" < "$test_tmp" 2>&1 | head -1)
  rm -f "$test_tmp"

  if [[ -z "$test_url" ]]; then
    echo "❌ Cannot create gists. Check gist scope: gh auth status"
    exit 1
  fi
  local test_id
  test_id=$(extract_gist_id "$test_url")
  gh gist delete "$test_id" --yes &>/dev/null || true
  echo "✅ Secret gist creatable"
  echo ""

  # Interactive setup
  echo "📂 Seddo name? (no spaces, used as folder name)"
  read -rp "   → " name_input
  name_input="${name_input:-seddo}"
  name_input=$(echo "$name_input" | tr -cd 'a-zA-Z0-9_-')
  if [[ -z "$name_input" ]]; then
    echo "❌ Invalid name."
    exit 1
  fi

  if [[ -d "${SEDDO_ROOT}/${name_input}" ]]; then
    echo "⚠️  Seddo « ${name_input} » already exists locally."
    read -rp "   Overwrite? [y/N] → " confirm
    [[ "$confirm" != "y" ]] && exit 0
  fi

  echo ""
  echo "👤 Agent name? (your identity in this seddo)"
  local detected=""
  if [[ -n "$AGENT_NAME" ]]; then
    detected="$AGENT_NAME"
  elif [[ -d "$HOME/.claude" ]]; then
    detected="claude-code"
  elif command -v openclaw &>/dev/null; then
    detected="kocc"
  elif [[ -d "$HOME/.opencode" ]]; then
    detected="opencode"
  fi
  echo "   (Enter for: ${detected:-agent})"
  read -rp "   → " agent_input
  local agent_name="${agent_input:-${detected:-agent}}"

  echo ""
  echo "📋 Other agents in this seddo? (comma-separated, optional)"
  read -rp "   → " other_agents

  echo ""
  echo "🤖 Creating hub gist..."

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local templates_dir="${script_dir}/../templates"

  # Build gist files
  local protocol inbox tasks lessons activity registry
  protocol=$(sed "s/{{SWARM_NAME}}/${name_input}/g" "${templates_dir}/PROTOCOL.md")
  inbox=$(sed "s/{{SWARM_NAME}}/${name_input}/g" "${templates_dir}/INBOX.md")
  tasks=$(sed "s/{{SWARM_NAME}}/${name_input}/g" "${templates_dir}/TASKS.md")
  lessons=$(sed "s/{{SWARM_NAME}}/${name_input}/g" "${templates_dir}/LESSONS.md")

  local ts
  ts=$(now)
  activity="# Activity — ${name_input}${nl}${nl}${ts} @${agent_name} — Seddo « ${name_input} » created (hub) 🤝${nl}"
  registry="# Registry — ${name_input}${nl}${nl}| Agent | Fork Gist ID | Fork URL | Registered |${nl}|-------|-------------|----------|-------------|${nl}| @${agent_name} | (hub) | (hub) | ${ts} |"

  # Create gist with all files
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s\n' "$protocol" > "$tmpdir/PROTOCOL.md"
  printf '%s\n' "# Roster — ${name_input}${nl}${nl}| Agent | Capacités | Localisation |${nl}|-------|-------------|-------------|" > "$tmpdir/ROSTER.md"
  printf '%s\n' "$inbox" > "$tmpdir/INBOX.md"
  printf '%s\n' "$tasks" > "$tmpdir/TASKS.md"
  printf '%s\n' "$lessons" > "$tmpdir/LESSONS.md"
  printf '%s\n' "$activity" > "$tmpdir/ACTIVITY.md"
  printf '%s\n' "$registry" > "$tmpdir/REGISTRY.md"

  local gist_url
  gist_url=$(gh gist create \
    -d "🤝 Seddo: ${name_input} (hub)" \
    "$tmpdir/PROTOCOL.md" \
    "$tmpdir/ROSTER.md" \
    "$tmpdir/INBOX.md" \
    "$tmpdir/TASKS.md" \
    "$tmpdir/LESSONS.md" \
    "$tmpdir/ACTIVITY.md" \
    "$tmpdir/REGISTRY.md" \
    2>&1 | head -1)
  rm -rf "$tmpdir"

  local gist_id
  gist_id=$(extract_gist_id "$gist_url")

  if [[ -z "$gist_id" ]]; then
    echo "❌ Failed to create gist."
    exit 1
  fi

  local canonical_url="https://gist.github.com/${gist_id}"
  [[ -n "$GH_USER" ]] && canonical_url="https://gist.github.com/${GH_USER}/${gist_id}"

  # Save config
  ensure_seddo_root
  save_seddo_config "$name_input" <<EOF
GIST_ID=${gist_id}
GIST_URL=${canonical_url}
AGENT_NAME=${agent_name}
ROLE=hub
FORK_OF=
FORK_GIST_ID=
EOF

  save_state_json "$name_input" <<EOF
{
  "role": "hub",
  "gist_id": "${gist_id}",
  "gist_url": "${canonical_url}",
  "created_at": "${ts}",
  "forks": []
}
EOF

  echo ""
  echo "✅ Hub seddo « ${name_input} » created!"
  echo "   Gist ID : ${gist_id}"
  echo "   URL     : ${canonical_url}"
  echo "   Role    : HUB (you own the canonical source)"
  echo ""

  if [[ -n "$other_agents" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔑 JOIN TOKEN — share with other agents:"
    echo ""
    echo "   seddo join ${gist_id}"
    echo ""
    echo "   They will be prompted for their agent name,"
    echo "   then the script will fork this gist automatically."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
  fi

  echo "Next steps:"
  echo "  seddo list      — verify seddo is active"
  echo "  seddo sync      — read all files"
  echo "  seddo inbox     — check messages"
}

# ── seddo join ──────────────────────────────────────────
cmd_join() {
  local input="${1:-}"
  require_gh

  if [[ -z "$input" ]]; then
    echo "Usage: seddo join <gist-id-or-url>"
    exit 1
  fi

  GH_USER=$(get_gh_user)
  local hub_gist_id
  hub_gist_id=$(extract_gist_id "$input")
  if [[ -z "$hub_gist_id" ]]; then
    hub_gist_id="$input"
  fi

  echo "🔍 Connecting to hub gist ${hub_gist_id:0:8}..."

  # Verify we can read the hub
  local raw
  raw=$(gh gist view "$hub_gist_id" --raw 2>/dev/null) || {
    echo "❌ Cannot access gist: ${hub_gist_id}"
    exit 1
  }

  # Detect seddo name from gist content
  local swarm_name
  swarm_name=$(echo "$raw" | grep -m1 '^# Roster\|^# Protocol\|^# Tasks\|^# .*—' \
    | head -1 | sed 's/^# //' | sed 's/ —.*//' | xargs)
  [[ -z "$swarm_name" ]] && swarm_name="seddo"

  # Detect agent name
  local detected=""
  if [[ -n "$AGENT_NAME" ]]; then
    detected="$AGENT_NAME"
  elif [[ -d "$HOME/.claude" ]]; then
    detected="claude-code"
  elif command -v openclaw &>/dev/null; then
    detected="kocc"
  elif [[ -d "$HOME/.opencode" ]]; then
    detected="opencode"
  fi

  echo "✅ Hub gist accessible: ${swarm_name}"
  echo ""
  echo "👤 Your agent name?"
  echo "   (Enter for: ${detected:-agent})"
  read -rp "   → " agent_input
  local agent_name="${agent_input:-${detected:-agent}}"

  echo ""
  echo "🔱 Forking hub gist (this gives you write access)..."
  local fork_json
  fork_json=$(fork_gist "$hub_gist_id")

  local fork_id
  fork_id=$(echo "$fork_json" | grep -oP '"id":\s*"\K[a-f0-9]{32}' | head -1)
  local fork_url
  fork_url=$(echo "$fork_json" | grep -oP '"html_url":\s*"\Khttps://gist.github.com[^"]+' | head -1)

  if [[ -z "$fork_id" ]]; then
    echo "❌ Fork failed. Check your GitHub token scope (needs gist)."

    # Try to be more informative
    local fork_error
    fork_error=$(echo "$fork_json" | grep -oP '"message":\s*"\K[^"]+' | head -1)
    [[ -n "$fork_error" ]] && echo "   GitHub said: $fork_error"
    exit 1
  fi

  echo "✅ Fork created: ${fork_id:0:8}..."

  # Save config BEFORE writing to fork (spoke mode)
  ensure_seddo_root

  # Determine local seddo name (unique per machine)
  local local_name="${swarm_name}"
  local counter=1
  while [[ -d "${SEDDO_ROOT}/${local_name}" ]] && [[ "$counter" -lt 100 ]]; do
    local_name="${swarm_name}-${counter}"
    ((counter++))
  done

  local canonical_url="https://gist.github.com/${fork_id}"
  [[ -n "$GH_USER" ]] && canonical_url="https://gist.github.com/${GH_USER}/${fork_id}"

  save_seddo_config "$local_name" <<EOF
GIST_ID=${fork_id}
GIST_URL=${canonical_url}
AGENT_NAME=${agent_name}
ROLE=spoke
FORK_OF=${hub_gist_id}
FORK_GIST_ID=${fork_id}
EOF

  save_state_json "$local_name" <<EOF
{
  "role": "spoke",
  "gist_id": "${fork_id}",
  "gist_url": "${canonical_url}",
  "hub_gist_id": "${hub_gist_id}",
  "joined_at": "$(now)",
  "agent_name": "${agent_name}"
}
EOF

  echo ""
  echo "✅ Joined seddo « ${local_name} » as @${agent_name}"
  echo "   Role    : SPOKE (fork of hub)"
  echo "   Hub     : ${hub_gist_id}"
  echo "   Your fork: ${fork_id}"
  echo ""
  echo "   Local name: ${local_name}"
  echo "   (Each machine uses its own fork — no conflict!)"
  echo ""
  echo "Next steps:"
  echo "  seddo sync      — pull from your fork"
  echo "  seddo inbox     — check messages"
  echo "  seddo tasks     — check tasks"
  echo ""
  echo "📤 To receive updates from hub:"
  echo "   seddo sync --pull-hub   (pull latest from hub gist)"
  echo "   seddo sync --push-hub   (push your fork changes to hub)"
}

# ── seddo list ──────────────────────────────────────────
cmd_list() {
  ensure_seddo_root

  local active_name=""
  if [[ -f "$SEDDO_ACTIVE_FILE" ]]; then
    active_name=$(cat "$SEDDO_ACTIVE_FILE")
  fi

  echo "🤝 Seddo workspaces"
  echo "   Root: ${SEDDO_ROOT}"
  echo ""

  local found=false
  for dir in "$SEDDO_ROOT"/*/; do
    [[ -d "$dir" ]] || continue
    [[ -f "${dir}config" ]] || continue

    local name
    name=$(basename "$dir")
    local is_active="  "
    [[ "$name" == "$active_name" ]] && is_active="⭐"

    local role
    role=$(grep '^ROLE=' "${dir}config" 2>/dev/null | cut -d= -f2- || echo "?")
    local gist_id
    gist_id=$(grep '^GIST_ID=' "${dir}config" 2>/dev/null | cut -d= -f2- | cut -c1-8)
    local agent
    agent=$(grep '^AGENT_NAME=' "${dir}config" 2>/dev/null | cut -d= -f2-)

    echo " ${is_active} ${name}"
    echo "    Role  : ${role}"
    echo "    Agent : @${agent}"
    echo "    Gist  : ${gist_id}..."
    echo ""

    found=true
  done

  if ! $found; then
    echo "   No seddos found."
    echo "   Run: seddo init   (create a new hub)"
    echo "   Run: seddo join   (join an existing seddo)"
  fi
}

# ── seddo switch ────────────────────────────────────────
cmd_switch() {
  local name="$1"
  if [[ -z "$name" ]]; then
    echo "Usage: seddo switch <seddo-name>"
    echo "   Available seddos:"
    ls "$SEDDO_ROOT" 2>/dev/null | grep -v '^active$' || true
    exit 1
  fi

  if [[ ! -d "${SEDDO_ROOT}/${name}" ]]; then
    echo "❌ Seddo « ${name} » not found."
    exit 1
  fi

  echo "$name" > "$SEDDO_ACTIVE_FILE"
  load_seddo_config "$name"

  local role_display="HUB"
  [[ "$ROLE" == "spoke" ]] && role_display="SPOKE"
  echo "✅ Switched to « ${name} » (${role_display})"
  echo "   Gist ID : ${GIST_ID:0:8}..."
  echo "   Agent   : @${AGENT_NAME}"
}

# ── seddo remove ─────────────────────────────────────────
cmd_remove() {
  local name="$1"
  if [[ -z "$name" ]]; then
    echo "Usage: seddo remove <seddo-name>"
    exit 1
  fi

  if [[ ! -d "${SEDDO_ROOT}/${name}" ]]; then
    echo "❌ Seddo « ${name} » not found."
    exit 1
  fi

  local active_name=""
  [[ -f "$SEDDO_ACTIVE_FILE" ]] && active_name=$(cat "$SEDDO_ACTIVE_FILE")

  echo "⚠️  This only removes the LOCAL workspace (${SEDDO_ROOT}/${name}/)."
  echo "   The GitHub gist/fork is NOT deleted."
  echo ""
  read -rp "   Remove « ${name} »? [y/N] → " confirm
  [[ "$confirm" != "y" ]] && exit 0

  rm -rf "${SEDDO_ROOT}/${name}"
  echo "✅ Removed « ${name} » locally."

  if [[ "$name" == "$active_name" ]]; then
    rm -f "$SEDDO_ACTIVE_FILE"
    echo "   (was active — no active seddo now)"
  fi
}

# ── seddo status ────────────────────────────────────────
cmd_status() {
  require_seddo
  require_role

  local role_display="HUB"
  [[ "$ROLE" == "spoke" ]] && role_display="SPOKE (fork)"

  echo "🤝 Seddo: ${seddo_name}"
  echo "   Role    : ${role_display}"
  echo "   Agent   : @${AGENT_NAME}"
  echo "   Gist    : ${GIST_ID}"
  echo ""

  if [[ "$ROLE" == "spoke" ]]; then
    echo "   Hub gist: ${FORK_OF}"
    echo "   Your fork: ${GIST_ID}"
    echo ""
    echo "   Sync commands:"
    echo "   - seddo sync --pull-hub   → pull from hub into your fork"
    echo "   - seddo sync --push-hub   → push your fork to hub"
    echo "   - seddo sync              → sync your fork (default)"
  else
    echo "   Hub gist: ${GIST_ID} (you own it)"
    echo ""
    echo "   Sync commands:"
    echo "   - seddo sync              → pull from all registered forks"
    echo "   - seddo sync --registry  → show registered forks"
  fi

  echo ""
  echo "📋 Quick view (last 30 lines of ACTIVITY.md):"
  echo ""
  local activity
  activity=$(fetch_file "ACTIVITY.md")
  echo "${activity}" | tail -30
}

# ── seddo sync ──────────────────────────────────────────
cmd_sync() {
  require_seddo
  require_role

  local mode="${2:-}"
  local ts
  ts=$(now)

  if [[ "$ROLE" == "spoke" ]]; then
    # SPOKE: sync with hub
    if [[ "$mode" == "--pull-hub" ]] || [[ -z "$mode" ]]; then
      echo "🔄 [SPOKE] Pulling from hub gist..."
      local hub_content
      hub_content=$(fetch_file "$FORK_OF" "ACTIVITY.md")
      echo "   Hub activity (last 10):"
      echo "${hub_content}" | tail -10
      echo ""
      echo "   Note: For full sync, pull each file you need from the hub."
      echo "   Your fork is at: ${GIST_ID}"
    fi

    if [[ "$mode" == "--push-hub" ]]; then
      echo "⚠️  [SPOKE] Cannot push directly to hub (hub owns the gist)."
      echo "   Your changes stay in your fork: ${GIST_ID}"
      echo "   Hub agents will pull from their gist (hub) during sync."
      echo "   They will NOT see your fork changes automatically."
      echo ""
      echo "   To share: seddo send @hub-agent <message>"
      echo "   Or: open a PR / fork the hub again with fresh changes."
    fi

    if [[ -z "$mode" ]]; then
      echo "🔄 [SPOKE] Syncing your fork..."
      echo "   Fork gist: ${GIST_ID}"
      echo "   (Read/Write on your fork, Read on hub)"
    fi
  else
    # HUB: collect from forks via REGISTRY.md
    echo "🔄 [HUB] Syncing..."
    local registry
    registry=$(fetch_file "$GIST_ID" "REGISTRY.md")

    if [[ -z "$registry" ]] || ! echo "$registry" | grep -q "^|"; then
      echo "   No forks registered in REGISTRY.md."
      echo "   (Other agents will join via seddo join and register themselves)"
    else
      echo "   Registered forks:"
      echo "$registry" | grep "^|" | tail -n +3
    fi
  fi

  echo ""
  echo "✅ Sync complete for ${seddo_name}"
}

# ── seddo inbox ──────────────────────────────────────────
cmd_inbox() {
  require_seddo
  echo "📥 Inbox — ${seddo_name}"
  echo ""
  fetch_file "INBOX.md"
}

# ── seddo send ──────────────────────────────────────────
cmd_send() {
  local target="$1"
  shift
  local message="$*"
  require_seddo

  local ts
  ts=$(now)
  local gist_to_write="$GIST_ID"

  local current_inbox
  current_inbox=$(fetch_file "$gist_to_write" "INBOX.md")
  local new_msg="→ ${target} : ${message} — @${AGENT_NAME} ${ts}"
  edit_file "$gist_to_write" "INBOX.md" "${current_inbox}"$'\n'"${new_msg}"

  local current_activity
  current_activity=$(fetch_file "$gist_to_write" "ACTIVITY.md")
  edit_file "$gist_to_write" "ACTIVITY.md" "${current_activity}"$'\n'"${ts} @${AGENT_NAME} — Message sent to ${target}"

  echo "✅ Message sent to ${target} (via ${gist_to_write:0:8}...)"
}

# ── seddo tasks ─────────────────────────────────────────
cmd_tasks() {
  require_seddo
  echo "📋 Tasks — ${seddo_name}"
  echo ""
  fetch_file "TASKS.md"
}

# ── seddo add ───────────────────────────────────────────
cmd_add() {
  local title="${1:-}"
  local priority="${2:-MEDIUM}"
  local assigned="${3:-@any}"
  require_seddo

  if [[ -z "$title" ]]; then
    echo "Usage: seddo add \"task title\" [PRIORITY] [@agent]"
    exit 1
  fi

  local ts
  ts=$(now)

  local current_tasks
  current_tasks=$(fetch_file "$GIST_ID" "TASKS.md")
  local count
  count=$(echo "$current_tasks" | grep -c '^### T-' || true)
  local task_id
  task_id=$(printf "T-%03d" "$((count + 1))")

  local new_task="
### ${task_id}: ${title}
- status: DRAFT
- assigned: ${assigned}
- priority: ${priority}
- input: ${title}
- output:
- created: ${ts} by @${AGENT_NAME}
- updated: ${ts}
"
  edit_file "$GIST_ID" "TASKS.md" "${current_tasks}${new_task}"

  local current_activity
  current_activity=$(fetch_file "$GIST_ID" "ACTIVITY.md")
  edit_file "$GIST_ID" "ACTIVITY.md" "${current_activity}"$'\n'"${ts} @${AGENT_NAME} — Task ${task_id} created: ${title}"

  echo "✅ Task ${task_id} created: ${title}"
}

# ── seddo claim ─────────────────────────────────────────
cmd_claim() {
  local task_id="${1:-}"
  require_seddo

  if [[ -z "$task_id" ]]; then
    echo "Usage: seddo claim T-XXX"
    exit 1
  fi

  local ts
  ts=$(now)
  local current_tasks
  current_tasks=$(fetch_file "$GIST_ID" "TASKS.md")

  local updated
  updated=$(update_task_field "$current_tasks" "$task_id" "status" "ASSIGNED")
  updated=$(update_task_field "$updated" "$task_id" "assigned" "@${AGENT_NAME}")
  updated=$(update_task_field "$updated" "$task_id" "updated" "$ts")

  edit_file "$GIST_ID" "TASKS.md" "$updated"

  local current_activity
  current_activity=$(fetch_file "$GIST_ID" "ACTIVITY.md")
  edit_file "$GIST_ID" "ACTIVITY.md" "${current_activity}"$'\n'"${ts} @${AGENT_NAME} — Task ${task_id} claimed"

  echo "✅ Task ${task_id} claimed by @${AGENT_NAME}"
}

# ── seddo update ────────────────────────────────────────
cmd_update() {
  local task_id="${1:-}"
  local new_status="${2:-WIP}"
  require_seddo

  if [[ -z "$task_id" ]]; then
    echo "Usage: seddo update T-XXX [STATUS]"
    exit 1
  fi

  local ts
  ts=$(now)
  local current_tasks
  current_tasks=$(fetch_file "$GIST_ID" "TASKS.md")

  local updated
  updated=$(update_task_field "$current_tasks" "$task_id" "status" "$new_status")
  updated=$(update_task_field "$updated" "$task_id" "updated" "$ts")

  edit_file "$GIST_ID" "TASKS.md" "$updated"

  local current_activity
  current_activity=$(fetch_file "$GIST_ID" "ACTIVITY.md")
  edit_file "$GIST_ID" "ACTIVITY.md" "${current_activity}"$'\n'"${ts} @${AGENT_NAME} — Task ${task_id} → ${new_status}"

  echo "✅ Task ${task_id} → ${new_status}"
}

# ── seddo done ──────────────────────────────────────────
cmd_done() {
  local task_id="${1:-}"
  shift
  local output="${*:-done}"
  require_seddo

  local ts
  ts=$(now)
  local current_tasks
  current_tasks=$(fetch_file "$GIST_ID" "TASKS.md")

  local updated
  updated=$(update_task_field "$current_tasks" "$task_id" "status" "DONE")
  updated=$(update_task_field "$updated" "$task_id" "output" "$output")
  updated=$(update_task_field "$updated" "$task_id" "updated" "$ts")

  edit_file "$GIST_ID" "TASKS.md" "$updated"

  local current_activity
  current_activity=$(fetch_file "$GIST_ID" "ACTIVITY.md")
  edit_file "$GIST_ID" "ACTIVITY.md" "${current_activity}"$'\n'"${ts} @${AGENT_NAME} — Task ${task_id} DONE: ${output}"

  echo "✅ Task ${task_id} marked DONE"
}

# ── seddo lesson ────────────────────────────────────────
cmd_lesson() {
  local text="${1:-}"
  local category="${2:-process}"
  require_seddo

  if [[ -z "$text" ]]; then
    echo "Usage: seddo lesson \"what you learned\" [category]"
    exit 1
  fi

  local ts
  ts=$(now)
  local current
  current=$(fetch_file "$GIST_ID" "LESSONS.md")
  local count
  count=$(echo "$current" | grep -c '^### L-' || true)
  local lesson_id
  lesson_id=$(printf "L-%03d" "$((count + 1))")

  local new_lesson="
### ${lesson_id}: ${text} — @${AGENT_NAME} ${ts}
- category: ${category}
- context:
- lesson: ${text}
"
  edit_file "$GIST_ID" "LESSONS.md" "${current}${new_lesson}"
  echo "✅ Lesson ${lesson_id} added"
}

# ── seddo log ────────────────────────────────────────────
cmd_log() {
  require_seddo
  echo "📜 Activity Log — ${seddo_name}"
  echo ""
  fetch_file "ACTIVITY.md"
}

# ── seddo info ──────────────────────────────────────────
cmd_info() {
  require_seddo

  echo "🤝 Seddo: ${seddo_name}"
  echo "   Role  : ${ROLE}"
  echo "   Agent : @${AGENT_NAME}"
  echo "   Gist  : ${GIST_ID}"
  echo "   URL   : $(grep '^GIST_URL=' "$seddo_config" 2>/dev/null | cut -d= -f2-)"
  echo ""
  echo "   Config : ${seddo_config}"
  echo "   State  : ${seddo_state}"
}

# ── seddo doctor ────────────────────────────────────────
cmd_doctor() {
  echo "🔍 Seddo Doctor v${SEDDO_VERSION}"
  echo ""

  echo "✅ bash ${BASH_VERSION}"

  if command -v gh &>/dev/null; then
    echo "✅ gh: $(gh --version | head -1)"
  else
    echo "❌ gh not installed"
  fi

  if gh auth status &>/dev/null 2>&1; then
    local user
    user=$(get_gh_user)
    echo "✅ gh authenticated as @${user}"
  else
    echo "❌ gh not authenticated"
  fi

  echo ""
  echo "📁 Seddo root: ${SEDDO_ROOT}"
  ensure_seddo_root

  if [[ -f "$SEDDO_ACTIVE_FILE" ]]; then
    local active
    active=$(cat "$SEDDO_ACTIVE_FILE")
    echo "⭐ Active seddo: ${active}"

    load_seddo_config "$active"
    echo "   Role  : ${ROLE}"
    echo "   Agent : @${AGENT_NAME}"
    echo "   Gist  : ${GIST_ID:0:8}..."

    if [[ -n "$GIST_ID" ]] && gh gist view "$GIST_ID" &>/dev/null 2>&1; then
      echo "   ✅ Gist accessible"
    else
      echo "   ❌ Cannot access gist"
    fi
  else
    echo "⚠️  No active seddo"
    echo "   Run: seddo init   or   seddo join <gist-id>"
  fi

  echo ""
  echo "   Available seddos:"
  for dir in "$SEDDO_ROOT"/*/; do
    [[ -d "$dir" ]] && [[ -f "${dir}config" ]] && echo "   - $(basename "$dir")"
  done
}

# ─── MAIN ──────────────────────────────────────────────

# Load active seddo if any
load_active_seddo 2>/dev/null || true

case "${1:-help}" in
  init)          cmd_init "${2:-}" ;;
  join)          cmd_join "${2:-}" ;;
  list)          cmd_list ;;
  switch)        cmd_switch "${2:-}" ;;
  remove)        cmd_remove "${2:-}" ;;
  status)        cmd_status ;;
  sync)          cmd_sync "${2:-}" "${3:-}" ;;
  inbox)         cmd_inbox ;;
  send)          cmd_send "$2" "${@:3}" ;;
  tasks)         cmd_tasks ;;
  add)           cmd_add "${2:-}" "${3:-MEDIUM}" "${4:-@any}" ;;
  claim)         cmd_claim "${2:-}" ;;
  update)        cmd_update "${2:-}" "${3:-WIP}" ;;
  done)          cmd_done "${2:-}" "${@:3}" ;;
  lesson)        cmd_lesson "${2:-}" "${2:-process}" ;;
  log)           cmd_log ;;
  info)          cmd_info ;;
  doctor)        cmd_doctor ;;
  help|--help)
    echo "🤝 Seddo v${SEDDO_VERSION} — Agent coordination via GitHub Gist"
    echo "   (wolof: séddo = partager. A seddo is a shared space)"
    echo ""
    echo "Usage: seddo <command> [args]"
    echo ""
    echo "Setup:"
    echo "  init                  Create a new hub seddo (creates a gist)"
    echo "  join <gist-id>        Fork and join an existing seddo"
    echo "  list                  Show all seddos on this machine"
    echo "  switch <name>         Switch to another seddo"
    echo "  remove <name>         Remove a seddo workspace (local only)"
    echo ""
    echo "Work:"
    echo "  sync [--pull-hub|--push-hub]  Sync (spoke: pull/push hub; hub: show forks)"
    echo "  inbox                 Read messages"
    echo "  send @agent msg       Send a message"
    echo "  tasks                 List tasks"
    echo "  add \"title\" [PRI] [@agent]  Create a task"
    echo "  claim T-XXX           Claim a task"
    echo "  update T-XXX STATUS   Update task status"
    echo "  done T-XXX [output]   Mark task as DONE"
    echo "  lesson \"text\" [cat]  Share a lesson"
    echo "  log                   Show activity log"
    echo ""
    echo "Info:"
    echo "  status                Show current seddo status"
    echo "  info                  Show local config"
    echo "  doctor                Check installation"
    echo "  help                  This help"
    echo ""
    echo "Environment:"
    echo "  SEDDO_ROOT            Workspace root (default: ~/.seddo)"
    echo "  SWARM_GIST_ID         Override gist ID"
    echo "  SEDDO_AGENT           Override agent name"
    ;;
esac