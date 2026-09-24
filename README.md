# codex-wsl-router-kit

Helper scripts to use **other models (DeepSeek, Kimi, Claude, OpenRouter, …) inside the
ChatGPT/Codex desktop app and the Codex VS Code extension on Windows + WSL**, while staying
signed in with your ChatGPT subscription. You pick GPT or an external model per task in the
normal model picker, which makes an external model a handy fallback when you hit your plan's
usage limits.

It wraps [codex-router](https://github.com/duolahypercho/codex-router) and adds the
WSL-specific fixes and a self-diagnosing check/repair script, because the Windows + WSL
combination breaks in several non-obvious ways (see [Why](#why-this-exists)).

> Unofficial. Not affiliated with OpenAI or the codex-router authors. It edits your Codex
> config (always with a backup first); read the scripts before running them.

## Requirements

- Windows 11 with WSL2 and an Ubuntu-style distro, **systemd enabled** in WSL
- ChatGPT/Codex desktop app with **Settings → "Run Codex in WSL"** turned on
- Inside WSL: `git`, `curl`, **Node.js 22.19+** (24 LTS recommended), and **uv** or `python3-venv`
  (the installer offers to install uv for you)
- An API key for the provider(s) you want (e.g. DeepSeek)
- Optional: VS Code with the Codex (`openai.chatgpt`) extension, used locally or via Remote-WSL

## Quick start

1. Clone or download this repo into a **Windows** folder (e.g. `C:\Users\you\codex-wsl-router-kit`)
   so the `.cmd` files can be double-clicked.
2. Double-click **`Install Codex Router.cmd`**. It checks prerequisites, backs up
   `config.toml`, runs codex-router's official guided installer (choose your provider and paste
   the key, input is hidden) and enables "use the router while signed in to ChatGPT".
3. Open the desktop app, start a **new** task and choose e.g. **DeepSeek V4.1 Flash (API)** in the
   model picker.
4. VS Code (optional): double-click **`Setup VS Code Codex.cmd`**, then fully restart VS Code.
5. Double-click **`Check Codex Setup.cmd`**. Everything should be green.

The `.cmd` launchers run the matching script in your **default** WSL distro. To use another one,
set a Windows env var: `setx CODEX_WSL_DISTRO Ubuntu-24.04`. You can also run any script
directly from a WSL shell: `bash scripts/check.sh`.

## Scripts

| Double-click | Script | What it does |
| --- | --- | --- |
| `Install Codex Router.cmd` | `scripts/setup.sh` | One-time router install with preflight checks and config backup |
| `Refresh Codex Router.cmd` | `scripts/refresh.sh` | Rebuild the model list after app updates or when models are missing; closes and reopens the app |
| `Check Codex Setup.cmd` | `scripts/check.sh` | **Diagnose everything, change nothing.** Run this first when something breaks |
| `Fix Codex Setup.cmd` | `scripts/check.sh --fix` | Same checks, repairs what it can (backs up `config.toml` first) |
| `Setup VS Code Codex.cmd` | `scripts/setup-vscode.sh` | Make the VS Code extension share the desktop config, login and router |
| `Fix Codex Sandbox.cmd` | `scripts/fix-sandbox.sh` | Options for the "mountinfo path is not absolute" sandbox bug |
| `Codex Versions.cmd` | `scripts/codex-override.sh status` | Bundled vs override Codex versions and sandbox status |
| `Collect Codex Logs.cmd` | `scripts/collect-logs.sh` | Copy redacted VS Code/Codex logs to `logs/` for troubleshooting |
| `Uninstall Codex Router.cmd` | `scripts/uninstall.sh` | Remove the router and, optionally, the VS Code and IPC changes |

Other commands (from WSL):

```bash
bash scripts/router.sh status | doctor | doctor --fix | providers | update
bash scripts/router.sh provider-key <provider> set     # add another provider's API key
bash scripts/router.sh test-model deepseek/deepseek-v4.1-flash
bash scripts/codex-override.sh status | vscode-on | vscode-off | update
bash scripts/tooltest.sh <path-to-codex> [code|direct]   # tool-call test with a local mock model
```

### What `check.sh` verifies

1. `config.toml` parses
2. no `forced_login_method` / `preferred_auth_method` (these block ChatGPT sign-in)
3. the desktop app still runs Codex in WSL
4. the router entries in `config.toml` (local base URL, Linux catalog path, `codex-router-signed` provider)
5. the router service is running and answering
6. VS Code: "Run Codex in WSL" on, `CODEX_HOME` / `CODEX_SQLITE_HOME` for login shells and the
   Remote-WSL server, IPC socket folder, `chatgpt.cliExecutable`
   - **6b** starts `codex app-server` exactly the way the extension does and checks it answers
   - **6c** runs a real tool call against a local mock model (no API cost, no account): once the
     way GPT-6 models do it ("code mode", needs `codex-code-mode-host`) and once the way
     DeepSeek/routed models do it (plain `exec_command`), both through the sandbox
7. sandbox self-test of the desktop, VS Code and override Codex binaries
   - **7b** `/etc/fstab` entries that make WSL print `Processing /etc/fstab with mount -a failed`
8. errors in the VS Code Codex log since Codex last started

## Why this exists

Each of these was hit and fixed while building this kit:

| Symptom | Cause | Handled by |
| --- | --- | --- |
| Desktop app stuck on **"Unable to load sign-in requirements"**, even after reinstalling | `%USERPROFILE%\.codex\config.toml` (it survives uninstalls) contains `forced_login_method = "api"` and `preferred_auth_method = "apikey"`, e.g. from DeepSeek's official Codex setup guide | `check.sh` step 2 (`--fix` removes them) |
| Router installed but models missing or the app fails | The app runs Codex **inside WSL**, so the catalog path must be a Linux path and the router must listen inside WSL | Router installed in WSL, state kept in `~/.local/state/codex-router` |
| Scripts can't find Node/uv when launched from Windows | `wsl.exe` starts a non-interactive shell, so `~/.bashrc` (nvm) never runs; a Windows `uv.exe` doesn't count | `env.sh` finds nvm/fnm/uv itself; the installer offers to install uv in WSL |
| Shell commands fail with `error building bubblewrap command: mountinfo path is not absolute` | Codex bug [#46110](https://github.com/openai/codex/issues/46110) in 0.155.x (bundled with app/extension 26.917.x), triggered by running Docker containers or snapd. Fixed in Codex CLI 0.156+ | VS Code: `codex-override.sh vscode-on` sets `chatgpt.cliExecutable` to the newest stable CLI. Desktop: stop containers or wait for an app update (`check.sh` tells you when) |
| VS Code extension reads a different config | In WSL mode the extension uses the WSL `~/.codex` unless `CODEX_HOME` is set, and Remote-WSL windows take their env from `~/.vscode-server/server-env-setup`, not `~/.profile` | `setup-vscode.sh` sets both |
| GPT-6 models answer "the command runner fails because its code-mode host executable is missing" (DeepSeek works) | GPT-6 models use Codex "code mode" (`tool_mode = code_mode_only`), which spawns `codex-code-mode-host` from next to the Codex binary. A bare `codex` binary doesn't include it | The override installs the official full `codex-package` (`bin/codex` + `bin/codex-code-mode-host` + `codex-resources/bwrap` + `codex-path/rg`) and tests both tool styles before switching |
| Extension loads forever after setting `chatgpt.cliExecutable` | A `\\wsl.localhost\…` path can't be started in Remote-WSL windows | A plain Linux path is used (works in both window types) |
| Log shows `listen ENOTSUP … /.codex/ipc/ipc.sock` | `/mnt/c` can't hold Unix sockets | `codex-ipc-bind.service` bind-mounts a Linux folder over `.codex/ipc` (an `/etc/fstab` entry runs too early in WSL) |
| Extension loads forever, log shows `failed to initialize sqlite state runtime` | Linux Codex can't open the SQLite state that the Windows runtime left in the shared home | `CODEX_SQLITE_HOME=~/.local/state/codex-sqlite` for VS Code and WSL shells |

## What gets changed

| Where | What |
| --- | --- |
| `%USERPROFILE%\.codex\config.toml` | router blocks marked `codex-router-managed` (backup: `config.toml.<date>.pre-codex-router.bak`) |
| WSL `~/.profile`, `~/.vscode-server/server-env-setup` | block marked `codex-router: shared Codex home` exporting `CODEX_HOME` and `CODEX_SQLITE_HOME` (only if not already set) |
| WSL `/etc/systemd/system/codex-ipc-bind.service` | bind-mounts `~/.local/state/codex-ipc` over `.codex/ipc` |
| VS Code `settings.json` | `chatgpt.runCodexInWindowsSubsystemForLinux: true`, optionally `chatgpt.cliExecutable` (backup next to it) |
| WSL `~/.local/state/codex-router` | router API keys and merged model catalog (0600 permissions) |
| WSL `~/.local/state/codex-sqlite` | SQLite state for VS Code / WSL-shell Codex |
| WSL `~/.local/share/codex-override` | optional newer official Codex package used by VS Code (`current/bin/codex`) |

Notes:

- Your VS Code thread list is kept separate from the desktop app's (the thread files themselves are
  shared), so two different Codex versions never migrate the same database.
- If you turn **off** "Run Codex in WSL" in the desktop app or VS Code, run the uninstaller first:
  the catalog path in `config.toml` is a Linux path that Windows-native Codex can't read.
- A codex-router update can require `Refresh Codex Router.cmd`, because Codex only reads the
  model catalog at startup.

## Troubleshooting

1. Run **`Check Codex Setup.cmd`** and read the red lines. Most say how to fix them.
2. Run **`Fix Codex Setup.cmd`** for the auto-fixable ones.
3. For VS Code problems, run **`Collect Codex Logs.cmd`** and look in `logs/<date>/`, where
   tokens and keys are redacted.
4. To get VS Code working quickly, `bash scripts/codex-override.sh vscode-off` goes back to
   the extension's bundled Codex.

## Uninstall

Double-click **`Uninstall Codex Router.cmd`**. It runs codex-router's uninstaller, offers to restore
the pre-router `config.toml` backup and to remove the VS Code env blocks, the `cliExecutable`
override and the IPC bind-mount service.

## Security

- Provider keys are entered through codex-router's hidden prompt and stored in WSL with 0600
  permissions, never in this repo or in `config.toml`.
- `config.env` and `logs/` are git-ignored. `collect-logs.sh` redacts API keys, OAuth tokens and
  the router's capability URL, but review the logs before sharing them anyway.

## Credits

- [codex-router](https://github.com/duolahypercho/codex-router) (MIT) does the actual routing
- [OpenAI Codex](https://github.com/openai/codex)
