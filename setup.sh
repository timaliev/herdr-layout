#!/usr/bin/env bash
# set -euo pipefail

# ── Herdr Layout Startup Script ───────────────────────────────
# Reads $CONFIG_FILE_NAME via yq and creates workspaces, tabs, panes,
# and runs commands. Idempotent: skips workspaces, tabs that already
# exist (by label match) so snapshot-restored sessions aren't
# duplicated.
# ───────────────────────────────────────────────────────────────
# Dependencies:
# - yq (https://github.com/mikefarah/yq/releases/latest)

HERDR="${HERDR_BIN_PATH:-herdr}"

if ! command -v yq &>/dev/null; then
  # yq is not installed in default paths
  # download it or use already downloaded
  YQ_BIN="${HERDR_PLUGIN_ROOT:-$HOME/.config/herdr/plugins}/bin"
  if [[ -d "$YQ_BIN" ]]; then
    # Prepend plugin bin dir to PATH so previous yq bootstrap survives
      export PATH="$YQ_BIN:$PATH"
  fi
fi

# ── ensure yq is available ────────────────────────────────────

if ! command -v yq &>/dev/null; then
  # if still not found -- download
  YQ_VERSION="v4.53.2"
  echo "[layout] yq not found — downloading yq ${YQ_VERSION}..." >&2

  case "$(uname -s)" in
    Darwin)  YQ_PLATFORM="darwin_amd64";;
    Linux)   YQ_PLATFORM="linux_amd64";;
    *)
      echo "[layout] ✗ unsupported platform: $(uname -s)" >&2
      exit 1
      ;;
  esac

  # Detect arm64
  if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
    YQ_PLATFORM="${YQ_PLATFORM%amd64}arm64"
  fi

  mkdir -p "$YQ_BIN"

  if command -v curl &>/dev/null; then
    curl -fsSL "$YQ_URL" -o "$YQ_BIN/yq" || {
      echo "[layout] ✗ failed to download yq (network unavailable?)" >&2
      exit 1
    }
  elif command -v wget &>/dev/null; then
    wget -q "$YQ_URL" -O "$YQ_BIN/yq" || {
      echo "[layout] ✗ failed to download yq (network unavailable?)" >&2
      exit 1
    }
  else
    echo "[layout] ✗ need curl or wget to download yq" >&2
    exit 1
  fi

  chmod +x "$YQ_BIN/yq"
  echo "[layout] → yq installed to $YQ_BIN/yq" >&2
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

# echo "[layout: debug] HERDR=$HERDR | CONFIG_DIR=$CONFIG_DIR | CONFIG=$CONFIG | CONFIG_FILE_NAME=$CONFIG_FILE_NAME" >&2

if [[ ! -f "$CONFIG" ]]; then
  echo "[layout] ${CONFIG_FILE_NAME:-config.yaml} for session '$SESSION' not found in $CONFIG_DIR — nothing to do" >&2
  echo "[layout] HERDR_PLUGIN_CONFIG_DIR=${HERDR_PLUGIN_CONFIG_DIR}" >&2
  exit 1
elif ! "$YQ" eval 'true' "$CONFIG" >/dev/null; then
  echo "[layout] error parsing configuration in $CONFIG" >&2
  exit 0
fi

# Query yq and return raw string (no quotes, no null)
function yq_raw() {
  "$YQ" -r "$1" "$CONFIG" 2>/dev/null || true
}

SESSION_LABEL=$(yq_raw '.session.label')
if [[ "$SESSION_LABEL" == "null" ]]; then
  echo "[layout] setting terminal title to herdr: $SESSION"
  "$HERDR" --session "$SESSION" terminal title set "herdr: $SESSION" >/dev/null 2>&1
else
  echo "[layout] setting terminal title to herdr: $SESSION_LABEL"
  "$HERDR" --session "$SESSION" terminal title set "herdr: $SESSION_LABEL" >/dev/null 2>&1
fi

# Check if a workspace with this label already exists
function workspace_exists() {
  local label="$1"
  "$HERDR" --session "$SESSION" workspace list 2>/dev/null | \
    "$YQ" -r '.result.workspaces[]?.label // ""' | grep -qFx "$label"
}

# Get first workspace ID by label
function workspace_id_by_label() {
  local label="$1"
  "$HERDR" --session "$SESSION" workspace list 2>/dev/null | \
    "$YQ" -r "[.result.workspaces[] | select(.label == \"$label\") | .workspace_id // \"\"][0]" 2>/dev/null || true
}

# Check if a tab with this label already exists in some workspace
function tab_exists() {
  local workspace="$1"
  local label="$2"
  "$HERDR" --session "$SESSION" tab list --workspace "$workspace" 2>/dev/null | \
    "$YQ" -r '.result.tabs[]?.label // ""' 2>/dev/null | grep -qFx "$label"
}

# Get first tab ID by label for some workspace
function tab_id_by_label() {
  local workspace="$1"
  local label="$2"
  "$HERDR" --session "$SESSION" tab list --workspace "$workspace" 2>/dev/null | \
    "$YQ" -r "[.result.tabs[] | select(.label == \"$label\") | .tab_id // \"\"][0]" 2>/dev/null
}

# After layout is applied, close workspaces not in config
# Call without parameters once after all workspace config is applied but before focusing
cleanup_stray_workspaces() {
  # Works only in strict mode
  if [[ "${CONFIG_MODE:-}" != "strict" ]]; then
    return
  fi
  # Build list of expected workspace labels from config
  local expected
  expected=$(yq_raw '.workspaces[].name' | sort)

  # Close any workspace whose label isn't in the expected set
  "$HERDR" --session "$SESSION" workspace list 2>/dev/null | \
    "$YQ" -r '.result.workspaces[] | .workspace_id + " " + .label' | \
    while read -r id label; do
      if ! echo "$expected" | grep -qFx "$label"; then
        echo "[layout] strict mode is ON -- closing stray workspace: $id ($label)"
        "$HERDR" --session "$SESSION" workspace close "$id" >/dev/null 2>&1 || true
      fi
    done
}

# After layout is applied, close tabs not in config
# Call per workspace after tabs are ensured:
# cleanup_stray_tabs "$WS_ID" ".workspaces[$ws_idx]"
cleanup_stray_tabs() {
  # Works only in strict mode
  if [[ "${CONFIG_MODE:-}" != "strict" ]]; then
    return
  fi
  local workspace_id="$1"
  local workspace_yaml_path="$2"
  # Build list of expected tabs in workspace labels from config
  local expected
  expected=$(yq_raw "${workspace_yaml_path}.tabs[].label // \"\"" | sort)

  # Close any tabs whose label isn't in the expected set
  "$HERDR" --session "$SESSION" tab list --workspace "$workspace_id" 2>/dev/null | \
    "$YQ" -r '.result.tabs[] | .tab_id + " " + .label' | \
    while read -r tab_id label; do
      if ! echo "$expected" | grep -qFx "$label"; then
        echo "[layout] strict mode is ON -- closing stray tab: $tab_id ($label)"
      "$HERDR" --session "$SESSION" tab close "$tab_id" >/dev/null 2>&1 || true
      fi
    done
}

# After tab layout is applied but before focus
# close panes not in config
# cleanup_stray_panes "$TAB_ID" ".workspaces[$ws_idx].tabs[$tab_idx]"
cleanup_stray_panes() {
  # Works only in strict mode
  if [[ "${CONFIG_MODE:-}" != "strict" ]]; then
    return
  fi
  local tab_id="$1"
  local yaml_path="$2"          # e.g. ".workspaces[0].tabs[1]"
  local expected_panes current_panes
  expected_panes=$(yq_raw "${yaml_path}.panes | length // 0")

  # Get actual pane IDs for this tab, skip first N (= expected count)
  "$HERDR" --session "$SESSION" pane list 2>/dev/null | \
    "$YQ" -r ".result.panes[] | select(.tab_id == \"$tab_id\") | .pane_id" | \
    tail -n +$((expected_panes + 1)) | \
    while read -r pane_id; do
      echo "[layout] strict mode is ON -- closing stray pane: $pane_id"
      "$HERDR" --session "$SESSION" pane close "$pane_id" >/dev/null 2>&1 || true
    done
}

function skip_agent_run() {
  local PANE_ID=$1

  # Check if agent was restored by herdr session resume
    RESTORED_AGENT=$("$HERDR" --session "$SESSION" pane get "$PANE_ID" 2>/dev/null | \
      "$YQ" -r '.result.pane.agent // ""')

    if [[ -n "$RESTORED_AGENT" && "$RESTORED_AGENT" != "null" ]]; then
      echo "[layout]       → agent '$RESTORED_AGENT' already restored for pane $PANE_ID, need to skip any commands run for this pane"
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

# ── wait for session restore ──────────────────────────────────
# Herdr session restore is async — plugin startup may fire before
# restored workspaces appear in `workspace list`, causing duplicates.
# Poll until the workspace list stabilizes (or timeout).
SESSION_WAIT_TIMEOUT=10
for ((i=0; i<SESSION_WAIT_TIMEOUT; i++)); do
  WS_COUNT=$("$HERDR" --session "$SESSION" workspace list 2>/dev/null | \
    "$YQ" -r '.result.workspaces | length // 0' 2>/dev/null || echo 0)
  if [[ "$WS_COUNT" -gt 0 ]]; then
    echo "[layout] Session restore: $WS_COUNT workspace(s) detected after ${i}s"
    break
  fi
  sleep 1
done

# ── parse and apply ───────────────────────────────────────────

WORKSPACE_COUNT=$(yq_raw '.workspaces | length')
if [[ -z "$WORKSPACE_COUNT" || "$WORKSPACE_COUNT" == "null" || "$WORKSPACE_COUNT" -eq 0 ]]; then
  echo "[layout] No workspaces defined in $CONFIG_FILE_NAME" >&2
  exit 0
else
  echo "[layout] $WORKSPACE_COUNT workspaces defined in $CONFIG_FILE_NAME"
fi

CONFIG_MODE=$(yq_raw '.mode')

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

  if [[ "$ws_idx" -eq 0 ]]; then
    # Fist workspace -- default
    # Check if it is named according to config.yaml
    # If strict mode is one -- replace with configuration in config.yaml
    WS_ID=$("$HERDR" --session "$SESSION" workspace list 2>/dev/null | \
      "$YQ" -r '.result.workspaces[0].workspace_id')
    if [[ $CONFIG_MODE == "strict" ]]; then
      "$HERDR" --session "$SESSION" workspace rename "$WS_ID" "$WS_NAME" >/dev/null 2>&1
    fi
  else
    # Create workspaces
    if workspace_exists "$WS_NAME"; then
      echo "[layout]  → workspace '$WS_NAME': already exists"
      WS_ID=$(workspace_id_by_label "$WS_NAME")
      if [[ "$WS_FOCUS" == "true" ]]; then
        FOCUS_WORKSPACE=$WS_ID
      fi
    else
      # Create workspace
      echo "[layout]  → creating workspace '$WS_NAME'"
      WS_JSON=$("$HERDR" --session "$SESSION" workspace create --label "$WS_NAME" --cwd "$WS_ROOT" --no-focus 2>&1)
      WS_ID=$(echo "$WS_JSON" | "$YQ" '.result.workspace.workspace_id // ""')
      if [[ -z "$WS_ID" || "$WS_ID" == "null" ]]; then
        echo "[layout]  ✗ workspace '$WS_NAME': failed to create: $WS_JSON" >&2
        continue
      else
        echo "[layout]  ✓ workspace '$WS_NAME': created successfully"
      fi
    fi
  fi

  if [[ "$WS_FOCUS" == "true" ]]; then
    FOCUS_WORKSPACE="$WS_ID"
  fi

  TAB_COUNT=$(yq_raw ".workspaces[$ws_idx].tabs | length")
  if [[ -z "$TAB_COUNT" || "$TAB_COUNT" == "null" ]]; then
    TAB_COUNT=0
    echo "[layout]  → workspace '$WS_NAME': no tabs defined"
    continue
  fi

  PREV_PANE_ID=""  # last pane in previous tab (for split chains within a tab)

  for ((tab_idx = 0; tab_idx < TAB_COUNT; tab_idx++)); do
    TAB_LABEL=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].label")
    TAB_CWD=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].cwd")
    TAB_FOCUS=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].focus")
    ROOT_PANE=""
    TAB_ID=""

    echo "[layout]  Tab: $TAB_LABEL"

    if [[ "$tab_idx" -eq 0 ]]; then
      # First tab: use root pane from workspace create
      # Check if it is named according to config.yaml
      # If strict mode is one -- replace with configuration in config.yaml
      TAB_ID=$("$HERDR" --session "$SESSION" tab list --workspace "$WS_ID" 2>/dev/null | \
        "$YQ" -r '.result.tabs[0].tab_id')
      if [[ $CONFIG_MODE == "strict" ]]; then
        "$HERDR" --session "$SESSION" tab rename "${TAB_ID}" "$TAB_LABEL" >/dev/null 2>&1
      fi
      ROOT_PANE=$("$HERDR" --session "$SESSION" pane list --workspace "$WS_ID" 2>/dev/null | \
        "$YQ" -r "[.result.panes[] | select(.tab_id == \"${TAB_ID}\")][0].pane_id" 2>/dev/null)
    else
      if tab_exists "$WS_ID" "$TAB_LABEL"; then
        TAB_ID=$(tab_id_by_label "$WS_ID" "$TAB_LABEL")
        ROOT_PANE=$("$HERDR" --session "$SESSION" pane list --workspace "$WS_ID" 2>/dev/null | \
          "$YQ" -r "[.result.panes[] | select(.tab_id == \"$TAB_ID\")][0].pane_id" 2>/dev/null)

        if [[ -n "$ROOT_PANE" && "$ROOT_PANE" != "null" ]]; then
          echo "[layout]    → tab '$TAB_LABEL' exists"
        fi
      else
        # Create new tab
        echo "[layout]    → creating tab '$TAB_LABEL'"
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
          echo "[layout]    ✗ tab '$TAB_LABEL': failed to create: $TAB_JSON" >&2
          continue
        else
          echo "[layout]    ✓ tab '$TAB_LABEL': created successfully"
        fi
      fi
    fi

    if [[ "$TAB_FOCUS" == "true" ]]; then
      FOCUS_TAB="$TAB_ID"
    fi

    if [[ -z "$ROOT_PANE" || "$ROOT_PANE" == "null" ]]; then
      echo "[layout]    ✗ tab $TAB_LABEL: failed to get root pane" >&2
      continue
    fi

    PANE_COUNT=$(yq_raw ".workspaces[$ws_idx].tabs[$tab_idx].panes | length")
    if [[ -z "$PANE_COUNT" || "$PANE_COUNT" == "null" ]]; then
      echo "[layout]    ✗ tab $TAB_LABEL: no panes defined" >&2
      PANE_COUNT=0
      continue
    fi

    CURRENT_TAB_PANES_COUNT=$("$HERDR" --session "$SESSION" pane list --workspace "$WS_ID" 2>/dev/null | \
      "$YQ" -r "[.result.panes[] | select(.tab_id == \"$TAB_ID\") | .pane_id] | length")
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
            echo "[layout]      ✗ pane $pane_idx ($PANE_ID): failed to split pane: $SPLIT_JSON" >&2
            continue
          fi
        else
          PANE_ID=$("$HERDR" --session "$SESSION" pane list --workspace "$WS_ID" 2>/dev/null | \
            $YQ -r "[.result.panes[] | select(.tab_id == \"$TAB_ID\") | .pane_id][$pane_idx]")
        fi
      fi

      # cwd to tab's default in strict mode
      if [[ $CONFIG_MODE == "strict" && "$PANE_CWD" == "null" ]]; then
        PANE_CWD=${TAB_CWD_EXPANDED:-$TAB_CWD}
      fi
      # Got to working directory
      if [[ -n "${PANE_CWD:-}" && "$PANE_CWD" != "null" && "$PANE_CWD" != '""' ]]; then
        echo "[layout]      → pane $pane_idx ($PANE_ID): changing directory to: $PANE_CWD"
        "$HERDR" --session "$SESSION" pane run "$PANE_ID" "cd $PANE_CWD" >/dev/null 2>&1 || true
      fi

      # Skip pane's run if agent is already running
      if skip_agent_run "$PANE_ID"; then
        PANE_CMD="null"
      fi
      # Run command if non-empty
      if [[ -n "${PANE_CMD:-}" && "$PANE_CMD" != "null" && "$PANE_CMD" != '""' && -n "$(echo "$PANE_CMD" | tr -d '"' | tr -d ' ')" ]]; then
        echo "[layout]      → pane $pane_idx ($PANE_ID): running: ${PANE_CMD:0:80}"
        "$HERDR" --session "$SESSION" pane run "$PANE_ID" "$PANE_CMD" >/dev/null 2>&1 || true
      fi

      # Wait for pattern if configured
      if [[ -n "${PANE_WAIT_MATCH:-}" && "$PANE_WAIT_MATCH" != "null" ]]; then
        TIMEOUT="${PANE_WAIT_TIMEOUT:-30000}"
        echo "[layout]      → pane $pane_idx ($PANE_ID): waiting for: $PANE_WAIT_MATCH (timeout: ${TIMEOUT}ms)"
        "$HERDR" --session "$SESSION" wait output "$PANE_ID" --match "$PANE_WAIT_MATCH" --timeout "$TIMEOUT" >/dev/null 2>&1 || true
      fi

      CURRENT_PANE="$PANE_ID"
      if [[ "$PANE_FOCUS" == "true" ]]; then
        FOCUS_PANE="$PANE_ID"
        FOCUS_PANE_DIRECTION=${PANE_SPLIT:-down}
      fi
    done

    cleanup_stray_panes "$TAB_ID" ".workspaces[$ws_idx].tabs[$tab_idx]"

    if [[ -n "$FOCUS_PANE" ]]; then
      echo "[layout]      → Focusing pane: $FOCUS_PANE"
      "$HERDR" --session "$SESSION" pane focus --direction "$FOCUS_PANE_DIRECTION" --pane "$FOCUS_PANE" >/dev/null 2>&1 || true
    fi
  done

  cleanup_stray_tabs "$WS_ID" ".workspaces[$ws_idx]"

  if [[ -n "$FOCUS_TAB" ]]; then
    echo "[layout]    → Focusing tab: $FOCUS_TAB"
    "$HERDR" --session "$SESSION" tab focus "$FOCUS_TAB" >/dev/null 2>&1 || true
  fi
done

cleanup_stray_workspaces

# ── apply focus ───────────────────────────────────────────────

if [[ -n "$FOCUS_WORKSPACE" ]]; then
  echo "[layout] Focusing workspace: $FOCUS_WORKSPACE"
  "$HERDR" --session "$SESSION" workspace focus "$FOCUS_WORKSPACE" >/dev/null 2>&1|| true
fi

echo "[layout] Done."
