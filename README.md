# herdr-layout

**Declarative herdr session layouts — describe workspaces, tabs, panes, and commands in YAML. Apply on startup or on demand. Save running sessions back to config.**

A [herdr](https://herdr.dev) plugin inspired by [tmuxinator](https://github.com/tmuxinator/tmuxinator) and [herdr-spreader](https://github.com/yuk1ty/herdr-spreader). Describe your session layout once, reproduce it every time herdr starts — or capture a running session to YAML with one action.

```yaml
# config-personal.yaml — placed in herdr plugin config dir
session:
  name: personal
  label: "my personal"
mode: non-strict
workspaces:
  - name: "Local chore"
    root: ~
    tabs:
      - label: "1"
        cwd: ~/.config
        panes:
          - command: ""
      - label: "2"
        cwd: ~/.config/atuin
        panes:
          - command: ""
      - label: Downloads
        cwd: ~/Downloads
        panes:
          - command: ""
```

On herdr startup, the plugin detects which session it's in (by matching `session.name` in the config against the current session name), finds the right `config-<session>.yaml`, and applies the layout: creates workspaces, tabs, and panes, runs commands, and sets focus — **idempotently** (skips what already exists).

## Features

- **Session-aware** — each config file targets a specific herdr session (`config-default.yaml`, `config-personal.yaml`, etc.). The plugin auto-selects the right one.
- **Startup hook** — layout is applied automatically when herdr starts the session.
- **Save action** — capture the current session layout to YAML with one command. Mirror workspaces auto-excluded.
- **Idempotent** — safe to run repeatedly; existing workspaces, tabs, and panes are reused, not duplicated.
- **Two modes** — `non-strict` adds config on top of existing state; `strict` tears down anything not in the config.
- **Agent-aware** — skips re-launching agents that herdr's session restore already brought back.
- **Split detection** — `save.sh` reads actual split direction and ratio from `herdr pane layout`.
- **Self-bootstrapping** — auto-downloads [yq](https://github.com/mikefarah/yq) if not installed.
- **Runs as a herdr plugin** — no separate binary needed; plain bash.

## Installation

Assuming `herdr` was already run and created `~/.config/herdr/` directory:

```bash
git clone https://github.com/timaliev/herdr-layout.git ~/.config/herdr/plugins/layout
herdr plugin link ~/.config/herdr/plugins/layout
herdr server reload-config
```

Create the config directory:

```bash
mkdir -p "$(herdr plugin config-dir layout)"
```

Place a `config-<session>.yaml` file directly in that directory (see [Configuration](#configuration)).

## Usage

### Apply layout (startup or manual)

Layout is applied automatically on herdr startup via the `[[startup]]` hook . To apply manually:

```bash
herdr plugin action invoke layout.apply
```

Apply will run if `$HERDR_PLUGIN_CONFIG_DIR/config-<session>.yaml` is present. Without configuration file plugin will silently fail. To find current configuration directory for plugin run `herdr plugin config-dir layout`. To see plugin logs, run `herdr plugin log`.

### Save current layout

Captures the running session to YAML:

```bash
herdr plugin action invoke layout.save
```

Output: `$HERDR_PLUGIN_CONFIG_DIR/config-<session>.yaml`  
A timestamped backup of the previous file is created at `config-<session>.yaml-<ISO-date>.backup~` before overwriting.

### Keybindings

Add to `~/.config/herdr/config.toml`:

```toml
# Apply layout
[[keys.command]]
key = "prefix+shift+a"
type = "plugin_action"
command = "layout.apply"
description = "apply session layout"

# Save layout
[[keys.command]]
key = "prefix+shift+s"
type = "plugin_action"
command = "layout.save"
description = "save session layout"
```

Then `herdr server reload-config`.

### Workflow: new session from scratch

```bash
# 1. Start a fresh named session
herdr --session myproject

# 2. Set up your workspace, tabs, panes, agents manually
#    (or run layout.apply with an existing config)

# 3. Save the layout
herdr plugin action invoke layout.save

# 4. Next startup: layout auto-applies from config-myproject.yaml
```

## Configuration reference

Config files live in `$HERDR_PLUGIN_CONFIG_DIR` (run `herdr plugin config-dir layout` to find it). Files are named `config-<session>.yaml`.

### Top-level

| Key | Type | Description |
|---|---|---|
| `session.name` | string | Herdr session name this config targets (`default`, `personal`, etc.). Used for auto-selection. |
| `session.label` | string | Human-readable label shown in terminal title. |
| `mode` | string | `non-strict` (default) — add to existing state. `strict` — close workspaces/tabs/panes not in config. |
| `workspaces` | list | Workspace definitions, in order. |

### Workspace

| Key | Type | Default | Description |
|---|---|---|---|
| `name` | string (required) | — | Label for the workspace. |
| `root` | path | `~` | Base working directory. `~` expanded to `$HOME`. |
| `focus` | boolean | `false` | Focus this workspace after layout is applied. |
| `tabs` | list | — | Tab definitions. |

### Tab

| Key | Type | Default | Description |
|---|---|---|---|
| `label` | string (required) | — | Tab label. |
| `cwd` | path | workspace `root` | Working directory for this tab's panes. Supports `~` and relative paths. |
| `focus` | boolean | `false` | Focus this tab after layout is applied. |
| `panes` | list | — | Pane definitions. First pane reuses the tab's root pane. |

### Pane

| Key | Type | Default | Description |
|---|---|---|---|
| `command` | string | `""` (shell) | Command to run. Use agent name for AI agents (`pi`, `codex`, `claude`). Empty = plain shell. |
| `cwd` | path | tab `cwd` | Working directory. `~` and relative paths supported. |
| `split` | `right` \| `down` | `down` | Split direction from previous pane. Ignored for first pane in tab. |
| `ratio` | float | `0.5` | Size ratio for the split (e.g. `0.3` = 30% to new pane). |
| `focus` | boolean | `false` | Focus this pane after layout is applied. |
| `wait_for.match` | string | — | Substring to wait for in pane output before continuing to next pane. |
| `wait_for.timeout_ms` | integer | `30000` | Timeout in ms for `wait_for.match`. |

### Example: multi-workspace with agents

```yaml
session:
  name: default
  label: "dev"
mode: non-strict
workspaces:
  - name: AI
    root: ~
    focus: true
    tabs:
      - label: "1"
        panes:
          - command: pi
            focus: true
      - label: "2"
        panes:
          - command: pi

  - name: frontend
    root: ~/code/my-project
    tabs:
      - label: editor
        cwd: ./src
        panes:
          - command: nvim
          - split: down
            ratio: 0.3
            command: npm run dev
            wait_for:
              match: "ready"
              timeout_ms: 10000
```

## How it works

`setup.sh` (apply) and `save.sh` (save) drive the `herdr` CLI — no private API.

### Apply flow

1. Detect current herdr session from `$HERDR_SOCKET_PATH`.
2. Find matching `config-<session>.yaml` in the plugin config directory.
3. Set terminal title from `session.label` (or `session.name` if no label).
4. Wait for session restore to populate workspaces (up to 10s) and agents (up to 15s).
5. Build a map of restored agents by pane ID (to skip re-launching them).
6. For each workspace in config:
   - **Non-strict**: find existing workspace by label match → reuse it; if not found → create new.
   - **Strict**: create new workspace, then close all previously-existing workspaces.
7. For each tab: find existing tab by label match → reuse it (non-strict), or create new (strict/not found). In strict mode, close the old first tab after creating the new one.
8. For each pane: first pane is the tab's root pane; subsequent panes split from it (direction and ratio from config). Set cwd, run command (skipped if agent will be restored by session resume).
9. Apply focus in order: pane → tab → workspace.

### Save flow

1. Read all workspaces from the session, skip mirror-plugin workspaces (detected by pane `foreground_cwd` containing `.mirror-pane`).
2. For each tab, get `pane layout` from the first pane to detect split direction and ratio for subsequent panes.
3. Detect agent type for each pane via `herdr pane get`.
4. Write YAML, omitting defaults (cwd same as parent, split `down`, ratio `0.5`).
5. Create a timestamped backup of the previous config file before overwriting.

## Related projects

- **[herdr-spreader](https://github.com/yuk1ty/herdr-spreader)** — the original Rust-based herdr layout tool. More features (env vars, dry-run, strict validation) but not session-aware and doesn't run on startup. This plugin was inspired by it and uses compatible YAML structure.

## Requirements

- herdr ≥ 0.7.0
- bash, curl (for yq bootstrap)
- [yq](https://github.com/mikefarah/yq) ≥ 4.0 (auto-downloaded if missing)

## License

[MIT](./LICENSE)
