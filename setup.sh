#!/usr/bin/env bash
# set -euo pipefail
# set -x
# ── Herdr Layout Startup Script ───────────────────────────────
# Reads $CONFIG_FILE_NAME via yq and creates workspaces, tabs, panes,
# and runs commands. Idempotent: skips workspaces, tabs that already
# exist (by label match) so snapshot-restored sessions aren't
# duplicated.
# ───────────────────────────────────────────────────────────────
# Dependencies:
# - yq (https://github.com/mikefarah/yq/releases/latest)

HERDR="${HERDR_BIN_PATH:-herdr}"
HERDR_CONFIG=$("$HERDR" --help 2>&1 | grep -i "config:" | cut -d' ' -f2)

# ── yq bootstrap ──────────────────────────
YQ_BIN=$(dirname ${HERDR_PLUGIN_ROOT:-$HOME/.config/herdr/plugins/layout})/bin
if ! command -v yq &>/dev/null; then
  # yq is not installed in default paths
  # download it or use already downloaded
  if [[ -d "$YQ_BIN" ]]; then
    # Prepend plugin bin dir to PATH so previous yq bootstrap survives
      export PATH="$YQ_BIN:$PATH"
  fi
fi

# ── ensure yq is available ────────────────────────────────────
if ! command -v yq &>/dev/null; then
  YQ_VERSION="v4.53.2"
  echo "[layout-save] yq not found — downloading yq ${YQ_VERSION}..." >&2
  case "$(uname -s)" in
    Darwin) YQ_PLATFORM="darwin_amd64";;
    Linux)  YQ_PLATFORM="linux_amd64";;
    *)      echo "[layout-save] unsupported platform" >&2; exit 1;;
  esac
  [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]] && YQ_PLATFORM="${YQ_PLATFORM%amd64}arm64"
  mkdir -p "$YQ_BIN"
  curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${YQ_PLATFORM}" -o "$YQ_BIN/yq" || {
    echo "[layout-save] failed to download yq" >&2; exit 1; }
  chmod +x "$YQ_BIN/yq"
  export PATH="$YQ_BIN:$PATH"
fi

# ── helpers ───────────────────────────────────────────────────
export YQ=$(command -v yq 2>/dev/null)

function current_session() {
  if [[ "$HERDR_ENV" != 1 && -z ${HERDR_SOCKET_PATH:-} ]]; then
    # Not inside herdr
    echo "[layout] must be run inside herdr session!" >&2
    exit 127
  fi
  if [[ "$HERDR_SOCKET_PATH" == "$HOME/.config/herdr/herdr.sock" ]]; then
    echo "default"
  else
    basename "$(dirname "$HERDR_SOCKET_PATH")"
  fi
}
SESSION="$(current_session)"
RC=$?
test $RC -ne 0 && exit $RC

function find_config() {
  local dir="${1:-.}"
  local session
  session=$SESSION

  for f in "$dir"/*.yaml "$dir"/*.yml; do
    [[ -f "$f" ]] || continue
    local name
    name=$("$YQ" -r '.session.name // ""' "$f" 2>/dev/null)
    if [[ "$name" == "$session" ]]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr/plugins/config/layout}"
CONFIG=$(find_config "$CONFIG_DIR")
CONFIG_FILE_NAME=$(basename "$CONFIG")

if [[ ! -f "$CONFIG" ]]; then
  echo "[layout] ${CONFIG_FILE_NAME:-config.yaml} for session '$SESSION' not found in $CONFIG_DIR — nothing to do" >&2
  exit 1
elif ! "$YQ" eval 'true' "$CONFIG" >/dev/null; then
  echo "[layout] error parsing configuration in $CONFIG" >&2
  exit 0
fi

# Query yq and return raw string (no quotes, no null)
function yq_raw() {
  "$YQ" -r "$1" "$CONFIG" 2>/dev/null || true
}

SESSION_FILE=""
# Resolve session.json path from $SESSION
if [ "$SESSION" = "default" ]; then
  SESSION_FILE="$HOME/.config/herdr/session.json"
else
  SESSION_FILE="$HOME/.config/herdr/sessions/$SESSION/session.json"
fi
SESSION_LABEL=$(yq_raw '.session.label')
"$HERDR" --session "$SESSION" terminal title clear >/dev/null
if [[ "$SESSION_LABEL" == "null" ]]; then
  echo "[layout] setting terminal title to 'herdr: $SESSION'"
  "$HERDR" --session "$SESSION" terminal title set "herdr: $SESSION" >/dev/null
else
  echo "[layout] setting terminal title to 'herdr: $SESSION_LABEL'"
  "$HERDR" --session "$SESSION" terminal title set "herdr: $SESSION_LABEL" >/dev/null
fi

function skip_agent_run() {
  local pane_id=$1
  local agent="${AGENT_MAP[$pane_id]}"

  # Check if agent was restored by herdr session resume
  echo "[layout]         → agent check for $pane_id: $agent"
  if [[ -n "$agent" && "$agent" != "null" ]]; then
    echo "[layout]         → agent '$agent' will be restored for pane $pane_id, skipping any commands run for this pane"
    return 0
  else
    return 1
  fi
}

# Expand ~ in a path
function expand_path() {
  local path="${1:-}"
  path="${path/#\~/$HOME}"
  echo "${path:-$HOME}"
}

# ── tracked focus targets ─────────────────────────────────────
FOCUS_WORKSPACE=""
FOCUS_TAB=""

# Strict or not
CONFIG_MODE=$(yq_raw '.mode // "any"')
# ── wait for session restore ──────────────────────────────────
# Herdr session restore is async — plugin startup may fire before
# restored workspaces appear in `workspace list`, causing duplicates.
# Poll until the workspace list stabilizes (or timeout).
SESSION_WAIT_TIMEOUT=10
TRY=0
OLD_WS_COUNT=0
for ((i=0; i<SESSION_WAIT_TIMEOUT; i++)); do
  WS_COUNT=$("$HERDR" --session "$SESSION" workspace list 2>/dev/null | \
    "$YQ" -r '.result.workspaces | length // 0' 2>/dev/null || echo 0)
  if [[ "$WS_COUNT" -gt 0 ]]; then
    TRY=$(($TRY + 1))
    if [[ $TRY -lt 3 || $OLD_WS_COUNT -ne $WS_COUNT ]]; then
      OLD_WS_COUNT=$WS_COUNT
      continue
    fi
    echo "[layout] Session restore: $WS_COUNT workspace(s) detected after ${i}s"
    break
  fi
  sleep 1
done
# Check if some agent are to be restored and then wait for them
AGENTS_CHECK=$("$YQ" -r '.session.resume_agents_on_restore // false' "$HERDR_CONFIG")
AGENTS_NUM=0
# Do not wait for agents to restore if mode is strict as they will be overwritten anyway
if [[ "$AGENTS_CHECK" == "true" && "$CONFIG_MODE" != "strict" ]]; then
  # Number of agents sessions to be resumed, break out if 0
  AGENTS_NUM=$("$YQ" -oy eval '[.workspaces[].tabs[].panes[] | select(.agent_session)] | length' "$SESSION_FILE")
  if [[ "$AGENTS_NUM" -gt 0 ]]; then
    AGENT_RESTORE_TIMEOUT=15
    AGENTS_TO_COUNT=0
    # Wait for restore to populate agents
    for ((i=0; i<$AGENT_RESTORE_TIMEOUT; i++)); do
      acount=$("$HERDR" --session "$SESSION" agent list 2>/dev/null | \
        "$YQ" -r '.result.agents | length // 0')
      echo "[layout] Session restore: agents to restore count=$acount"
      [[ "$acount" -gt 0 ]] && break
      echo "[layout] Session restore: waiting for agents to start: ${AGENTS_TO_COUNT}s"
      sleep 1
      AGENTS_TO_COUNT=$(($AGENTS_TO_COUNT + 1))
    done
  fi
fi

# Populate from herdr agent list
declare -A AGENT_MAP      # pane_id → agent_name
declare -A AGENT_SESSION  # pane_id → session_path
declare -A AGENT_SOURCE   # pane_id → source (herdr:pi, etc.)
while IFS=$'\t' read -r pane_id agent session source; do
  AGENT_MAP["$pane_id"]="$agent"
  AGENT_SESSION["$pane_id"]="$session"
  AGENT_SOURCE["$pane_id"]="$source"
done < <(
  herdr --session "$SESSION" agent list 2>/dev/null |
    "$YQ" -r '
      .result.agents[] |
      .pane_id + "\t" +
      (.agent // "") + "\t" +
      (.agent_session.value // "") + "\t" +
      (.agent_session.source // "")
    '
)
# ── parse and apply ───────────────────────────────────────────

WORKSPACE_COUNT=$(yq_raw '.workspaces | length')
if [[ -z "$WORKSPACE_COUNT" || "$WORKSPACE_COUNT" == "null" || "$WORKSPACE_COUNT" -eq 0 ]]; then
  echo "[layout] No workspaces defined in $CONFIG_FILE_NAME" >&2
  exit 0
else
  echo "[layout] $WORKSPACE_COUNT workspaces defined in $CONFIG_FILE_NAME"
fi
declare -A CURRENT_WS_MAP=()
declare -A CURRENT_WS_ARR=()
while read -r ws_count ws_id ws_label; do
  CURRENT_WS_MAP["$ws_id"]="$ws_label"
  CURRENT_WS_ARR["$ws_count"]="$ws_id"
done < <("$HERDR" --session "$SESSION" workspace list 2>/dev/null | \
  "$YQ" -r '.result.workspaces | to_entries[] | "\(.key) \(.value.workspace_id) \(.value.label)"')
CURRENT_WS_COUNT=${#CURRENT_WS_ARR[@]}

if [[ $CONFIG_MODE == "strict" ]]; then
  echo "[layout] strict mode is ON -- workspaces and tabs will be replaced according to $CONFIG_FILE_NAME"
else
  echo "[layout] strict mode is OFF -- workspaces and tabs will be added according to $CONFIG_FILE_NAME"
fi

for ((ws_idx = 0; ws_idx < $WORKSPACE_COUNT; ws_idx++)); do
  WS_NAME=$(yq_raw ".workspaces[$ws_idx].name")
  WS_ROOT=$(expand_path "$(yq_raw ".workspaces[$ws_idx].root")")
  WS_FOCUS=$(yq_raw ".workspaces[$ws_idx].focus")
  WS_ID=""

  echo "[layout] Workspace: $WS_NAME (root: $WS_ROOT)"

  # Check if workspace is named according to config.yaml
  # If not -- create new workspace with the proper name
  # If strict mode is on -- delete original workspace
  WS_EXISTS=$([[ ${CURRENT_WS_MAP[@]} =~ "$WS_NAME" ]] && echo 0 || echo 1)
  if [[ "$WS_EXISTS" -eq 0 && "$CONFIG_MODE" != "strict" ]]; then
    for ((_idx = 0; _idx < $CURRENT_WS_COUNT; _idx++)); do
      _id=${CURRENT_WS_ARR["$_idx"]}
      if [[ ${CURRENT_WS_MAP["$_id"]} == "$WS_NAME" ]]; then
        WS_ID=$_id
        break
      fi
    done
    echo "[layout]  → workspace '$WS_NAME' ($WS_ID): already exists"
  elif [[ "$CONFIG_MODE" == "strict" ]]; then
    # Create new workspace
    echo "[layout]  → workspace '$WS_NAME': creating ..."
    WS_JSON=$("$HERDR" --session "$SESSION" workspace create --label "$WS_NAME" --cwd "$WS_ROOT" --no-focus 2>&1)
    WS_ID=$(echo "$WS_JSON" | "$YQ" '.result.workspace.workspace_id // ""')
    if [[ -z "$WS_ID" || "$WS_ID" == "null" ]]; then
      echo "[layout]  ✗ workspace '$WS_NAME': failed to create: $WS_JSON" >&2
      continue
    else
      echo "[layout]  ✓ workspace '$WS_NAME' ($WS_ID): created successfully"
    fi
    if [[ "$ws_idx" -eq 0 ]]; then
      # Close previous (existing) workspaces in strict mode
      # after creating first new workspace (herdr needs at minimum one workspace)
      # as we will recreate all other workspaces later
      for k in "${!CURRENT_WS_ARR[@]}"; do
        _ws_id=${CURRENT_WS_ARR["$k"]}
        _ws_name=${CURRENT_WS_MAP["$_ws_id"]}
        "$HERDR" --session "$SESSION" workspace close "$_ws_id" >/dev/null || true
        echo "[layout]  → previous existing workspace '$_ws_name' ($_ws_id): closed because of strict mode"
      done
    fi
  else
    echo "[layout]  → workspace '$WS_NAME': creating ..."
    WS_JSON=$("$HERDR" --session "$SESSION" workspace create --label "$WS_NAME" --cwd "$WS_ROOT" --no-focus 2>&1)
    WS_ID=$(echo "$WS_JSON" | "$YQ" '.result.workspace.workspace_id // ""')
    if [[ -z "$WS_ID" || "$WS_ID" == "null" ]]; then
      echo "[layout]  ✗ workspace '$WS_NAME': failed to create: $WS_JSON" >&2
      continue
    else
      echo "[layout]  ✓ workspace '$WS_NAME' ($WS_ID): created successfully"
    fi
  fi

  if [[ "$WS_FOCUS" == "true" ]]; then
    FOCUS_WORKSPACE="$WS_ID"
  fi

  TAB_COUNT=$(yq_raw ".workspaces[$ws_idx].tabs | length")
  if [[ -z "$TAB_COUNT" || "$TAB_COUNT" == "null" ]]; then
    TAB_COUNT=0
    echo "[layout]  → workspace '$WS_NAME': no tabs defined in $CONFIG_FILE_NAME"
    continue
  else
     echo "[layout]  → workspace '$WS_NAME': $TAB_COUNT tabs defined in $CONFIG_FILE_NAME"
  fi

  declare -A CURRENT_TAB_MAP=()
  declare -A CURRENT_TAB_ARR=()
  while read -r tab_count tab_id tab_label; do
    CURRENT_TAB_MAP["$tab_id"]="$tab_label"
    CURRENT_TAB_ARR["$tab_count"]="$tab_id"
  done < <("$HERDR" --session "$SESSION" tab list --workspace "$WS_ID" 2>/dev/null | \
    "$YQ" -r '.result.tabs | to_entries[] | "\(.key) \(.value.tab_id) \(.value.label)"')
  CURRENT_WS_TAB_COUNT=${#CURRENT_TAB_ARR[@]}

  PREV_PANE_ID=""  # last pane in previous tab (for split chains within a tab)

  for ((tab_idx = 0; tab_idx < TAB_COUNT; tab_idx++)); do
    TAB_LABEL=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].label")
    TAB_CWD=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].cwd")
    TAB_FOCUS=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].focus")
    ROOT_PANE=""
    TAB_ID=""
    unset TAB_CWD_EXPANDED

    echo "[layout]  Tab: $TAB_LABEL (cwd: $TAB_CWD)"

    # Check if tab named according to config.yaml is exists
    # Add new one if not
    # If strict mode is on -- replace with configuration in config.yaml
    TAB_EXISTS=$([[ ${CURRENT_TAB_MAP[@]} =~ "$TAB_LABEL" ]] && echo 0 || echo 1)
    if [[ "$TAB_EXISTS" -eq 0 && "$CONFIG_MODE" != "strict" ]]; then
      # If tab(s) exists find least possible index for tabs and use first tab with the required tab label
      for ((_idx = 0; _idx < $CURRENT_WS_TAB_COUNT; _idx++)); do
        _id=${CURRENT_TAB_ARR["$_idx"]}
        if [[ ${CURRENT_TAB_MAP["$_id"]} == "$TAB_LABEL" ]]; then
          TAB_ID=$_id
          break
        fi
      done
      echo "[layout]    → tab '$TAB_LABEL' ($TAB_ID): already exists"
      ROOT_PANE=$("$HERDR" --session "$SESSION" pane list --workspace "$WS_ID" | \
        $YQ -r "[.result.panes[] | select(.tab_id == \"$TAB_ID\")][0] | .pane_id")
    else
      # Create new tab
      # Also applies to strict mode as workspace is recreated already
      echo "[layout]    → tab '$TAB_LABEL': creating ..."
      TAB_ARGS=(--workspace "$WS_ID" --label "$TAB_LABEL" --no-focus)
      if [[ -n "${TAB_CWD:-}" && "$TAB_CWD" != "null" ]]; then
        TAB_CWD_EXPANDED=$(expand_path "$TAB_CWD")
        # Handle relative paths
        if [[ "$TAB_CWD" == ./* ]]; then
          TAB_CWD_EXPANDED="$WS_ROOT/${TAB_CWD#./}"
        fi
        TAB_ARGS+=(--cwd "$TAB_CWD_EXPANDED")
      fi
      TAB_JSON=$("$HERDR" --session "$SESSION" tab create "${TAB_ARGS[@]}" 2>&1)
      TAB_ID=$(echo "$TAB_JSON" | $YQ -r '.result.tab.tab_id')
      ROOT_PANE=$(echo "$TAB_JSON" | $YQ -r '.result.root_pane.pane_id // ""')
      if [[ -z "$TAB_ID" || "$TAB_ID" == "null" ]]; then
        echo "[layout]    ✗ tab '$TAB_LABEL' ($TAB_ID): failed to create: $TAB_JSON" >&2
        continue
      else
        echo "[layout]    ✓ tab '$TAB_LABEL' ($TAB_ID): created successfully"
      fi
      if [[ "$tab_idx" -eq 0 ]]; then
        # Close previous (existing) tabs in strict mode:
        # workspace is new so there are only two tabs, close old one.
        _tab_id=${CURRENT_TAB_ARR["0"]}
        _tab_name=${CURRENT_TAB_MAP["$_tab_id"]}
        "$HERDR" --session "$SESSION" tab close "$_tab_id" >/dev/null || true
        echo "[layout]    → previous existing tab '$_tab_name' ($_tab_id): closed because of strict mode"
      fi
    fi

    if [[ "$TAB_FOCUS" == "true" ]]; then
      FOCUS_TAB="$TAB_ID"
    fi

    if [[ -z "$ROOT_PANE" || "$ROOT_PANE" == "null" ]]; then
      echo "[layout]    ✗ tab '$TAB_LABEL' ($TAB_ID): failed to get root pane" >&2
      continue
    fi

    PANE_COUNT=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].panes | length")
    if [[ -z "$PANE_COUNT" || "$PANE_COUNT" == "null" ]]; then
      echo "[layout]    ✗ tab '$TAB_LABEL' ($TAB_ID): no panes defined" >&2
      PANE_COUNT=0
      continue
    fi
    declare -A CURRENT_TAB_PANES_ARR=()
    while read -r pane_count pane_id; do
      CURRENT_TAB_PANES_ARR["$pane_count"]="$pane_id"
    done < <("$HERDR" --session "$SESSION" pane list --workspace "$WS_ID" 2>/dev/null | \
      "$YQ" -r "[.result.panes[] | select(.tab_id == \"$TAB_ID\")] | to_entries[] | \"\(.key) \(.value.pane_id)\"")
    CURRENT_TAB_PANES_COUNT=${#CURRENT_TAB_PANES_ARR[@]}

    CURRENT_PANE="$ROOT_PANE"
    FOCUS_PANE=""

    for ((pane_idx = 0; pane_idx < PANE_COUNT; pane_idx++)); do
      PANE_CMD=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].panes[$pane_idx].command")
      PANE_CWD=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].panes[$pane_idx].cwd")
      PANE_SPLIT=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].panes[$pane_idx].split")
      PANE_RATIO=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].panes[$pane_idx].ratio")
      PANE_FOCUS=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].panes[$pane_idx].focus")
      PANE_WAIT_MATCH=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].panes[$pane_idx].wait_for.match")
      PANE_WAIT_TIMEOUT=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].panes[$pane_idx].wait_for.timeout_ms")
      PANE_ID=""

      if [[ "$pane_idx" -eq 0 ]]; then
        # First pane is the root pane
        PANE_ID="$ROOT_PANE"
        PANE_FOCUS="null"
        echo "[layout]      → pane $pane_idx ($PANE_ID): root pane"
      else
        # Split from current pane if current pane's index is
        # greater or equal to actual opened panes for this tab
        if [[ "$pane_idx" -ge $CURRENT_TAB_PANES_COUNT ]]; then
          if [[ "$PANE_SPLIT" == "right" || "$PANE_SPLIT" == "down" ]]; then
            SPLIT_DIR="$PANE_SPLIT"
          else
            echo "[layout]      → pane $pane_idx: split direction '$PANE_SPLIT' unknown, defaulting to 'down'" >&2
            SPLIT_DIR="down"
          fi

          SPLIT_ARGS=(--direction "$SPLIT_DIR" --no-focus)
          if [[ -n "${PANE_RATIO:-}" && "$PANE_RATIO" != "null" ]]; then
            SPLIT_ARGS+=(--ratio "$PANE_RATIO")
          fi
          echo "[layout]      → pane $pane_idx: splitting $SPLIT_DIR from '$CURRENT_PANE'"
          SPLIT_JSON=$("$HERDR" --session "$SESSION" pane split "$CURRENT_PANE" "${SPLIT_ARGS[@]}" 2>&1)
          PANE_ID=$(echo "$SPLIT_JSON" | $YQ -r '.result.pane.pane_id // ""')
          if [[ -z "$PANE_ID" || "$PANE_ID" == "null" ]]; then
            echo "[layout]      ✗ pane $pane_idx: failed to split pane: $SPLIT_JSON" >&2
            continue
          fi
          echo "[layout]      ✓ pane $pane_idx ($PANE_ID): split from $CURRENT_PANE successfully"
        else
          PANE_ID=${CURRENT_TAB_PANES_ARR[$pane_idx]}
          echo "[layout]      ✓ pane $pane_idx ($PANE_ID): already exists"
        fi
      fi

      # cwd to tab's default in strict mode
      if [[ $CONFIG_MODE == "strict" && "$PANE_CWD" == "null" ]]; then
        PANE_CWD=${TAB_CWD_EXPANDED:-$WS_ROOT}
      fi
      # Skip all pane's run if agent should be restored
      if [[ "$AGENTS_NUM" -gt 0 ]]; then
        if skip_agent_run "$PANE_ID"; then
          PANE_CWD="null"
          PANE_CMD="null"
        fi
      fi
      # Got to working directory
      if [[ -n "${PANE_CWD:-}" && "$PANE_CWD" != "null" && "$PANE_CWD" != '""' ]]; then
        echo "[layout]      → pane $pane_idx ($PANE_ID): changing directory to: $PANE_CWD"
        "$HERDR" --session "$SESSION" pane run "$PANE_ID" "cd $PANE_CWD" >/dev/null || true
      fi
      # Run command if non-empty
      if [[ -n "${PANE_CMD:-}" && "$PANE_CMD" != "null" && "$PANE_CMD" != '""' && -n "$(echo "$PANE_CMD" | tr -d '"' | tr -d ' ')" ]]; then
        echo "[layout]      → pane $pane_idx ($PANE_ID): running command: ${PANE_CMD:0:80}"
        "$HERDR" --session "$SESSION" pane run "$PANE_ID" "$PANE_CMD" >/dev/null || true
      fi

      # Wait for pattern if configured
      if [[ -n "${PANE_WAIT_MATCH:-}" && "$PANE_WAIT_MATCH" != "null" ]]; then
        TIMEOUT="${PANE_WAIT_TIMEOUT:-30000}"
        echo "[layout]      → pane $pane_idx ($PANE_ID): waiting for: $PANE_WAIT_MATCH (timeout: ${TIMEOUT}ms)"
        "$HERDR" --session "$SESSION" wait output "$PANE_ID" --match "$PANE_WAIT_MATCH" --timeout "$TIMEOUT" >/dev/null || true
      fi

      if [[ "$PANE_FOCUS" == "true" && "$ROOT_PANE" != "$PANE_ID" ]]; then
        # pane is focused from previous pane with direction
        FOCUS_PANE="$CURRENT_PANE"
        FOCUS_PANE_DIRECTION=${PANE_SPLIT:-down}
      else
        # even if focus=true pane was not split so focus ignored
        echo "[layout]      → focus for pane $PANE_ID is ignored -- it is the root (default) pane"
      fi
      CURRENT_PANE="$PANE_ID"
      PANE_FOCUS=""
    done

    if [[ -n "$FOCUS_PANE" ]]; then
      PANE_JSON=$("$HERDR" --session "$SESSION" pane focus --direction "$FOCUS_PANE_DIRECTION" --pane "$FOCUS_PANE" 2>/dev/null)
      focus=($(echo $PANE_JSON |\
        "$YQ" -r '.result.focus | .focused_pane_id + " " + .changed'))
      res=$([[ ${focus[1]} == "true" ]] && echo "success" || echo "failed" )
      if [[ "$res" == "success" ]]; then
        echo "[layout]      → Focused pane: ${focus[0]} - ${res}"
      else
        echo "[layout]      → Focus pane ${res}: ${focus[1]} from $FOCUS_PANE $FOCUS_PANE_DIRECTION"
        echo "[layout]      → Focus pane ${res} diag: ${PANE_JSON}"
      fi
    fi
  done

  if [[ -n "$FOCUS_TAB" ]]; then
    TAB_JSON=$("$HERDR" --session "$SESSION" tab focus "$FOCUS_TAB" 2>/dev/null)
    focus=$(echo $TAB_JSON |\
      "$YQ" -r '.result.tab.focused')
      res=$([[ ${focus} == "true" ]] && echo "success" || echo "failed" )
    if [[ "$res" == "success" ]]; then
      echo "[layout]      → Focused tab: $FOCUS_TAB - ${res}"
    else
      echo "[layout]      → Focus tab ${res}: $FOCUS_TAB"
      echo "[layout]      → Focus tab ${res} diag: ${TAB_JSON}"
    fi
  fi
done

# ── apply focus ───────────────────────────────────────────────

if [[ -n "$FOCUS_WORKSPACE" ]]; then
  echo "[layout] Focusing workspace: $FOCUS_WORKSPACE"
  "$HERDR" --session "$SESSION" workspace focus "$FOCUS_WORKSPACE" >/dev/null || true
fi

echo "[layout] Done."
