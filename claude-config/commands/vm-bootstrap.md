---
name: vm-bootstrap
description: Create an unattended macOS VM via Lume and install dotfiles inside it. Fully automated end-to-end.
allowed-tools: Bash, Read, Glob, Grep, mcp__lume__lume_list_vms, mcp__lume__lume_get_vm, mcp__lume__lume_run_vm, mcp__lume__lume_stop_vm, mcp__lume__lume_delete_vm, mcp__lume__lume_exec, mcp__lume__lume_create_vm
---

# VM Bootstrap: Create VM + Install Dotfiles

This skill creates an unattended macOS Tahoe VM using Lume and runs the existing dotfiles installer inside it. No user interaction required after launch.

## Critical Workarounds

These are hard-won learnings — do NOT deviate from them:

1. **MCP `lume_create_vm` with `unattended` always times out** — Use `lume` CLI via Bash instead
2. **Built-in preset name `tahoe` doesn't resolve** — Download the YAML, pass absolute file path to `--unattended`
3. **MCP `lume_run_vm` with `shared_dir` silently fails** — Use `lume run` CLI instead
4. **MCP `lume_stop_vm` is intermittent** — Kill processes directly as fallback
5. **`mcp__lume__lume_exec` may timeout on long commands** — Run commands in background with nohup, poll log files
6. **install.sh `exec claude --init` will hang in headless SSH** — Expected, proceed to fresh.sh separately
7. **fresh.sh `exec claude --dangerously-skip-permissions` will also hang** — Expected, all 9 modules complete before this line

## Procedure

### Phase A: Create the VM

#### Step 1: Prerequisites

Run these in parallel:

```bash
mkdir -p ~/shared
```

```bash
curl -sL "https://raw.githubusercontent.com/trycua/cua/main/libs/lume/src/Resources/unattended-presets/tahoe.yml" \
  -o /tmp/lume-unattended-tahoe.yml
```

Verify the download:

```bash
test -s /tmp/lume-unattended-tahoe.yml && echo "OK" || echo "FAILED"
```

If download failed, try alternate path:

```bash
curl -sL "https://raw.githubusercontent.com/trycua/cua/main/libs/lume/resources/unattended-tahoe.yml" \
  -o /tmp/lume-unattended-tahoe.yml
```

#### Step 2: Check for existing VM

```
mcp__lume__lume_list_vms()
```

If `dev-vm` already exists:
1. Try `mcp__lume__lume_stop_vm(name="dev-vm")` once
2. If that fails, kill processes: `ps aux | grep "lume.*dev-vm" | grep -v grep` then `kill` the PIDs
3. Wait 5 seconds, verify processes are gone
4. `mcp__lume__lume_delete_vm(name="dev-vm")`

#### Step 3: Create VM via CLI

**IMPORTANT:** Use the `lume` CLI directly, NOT the MCP tool. Run as a background task:

```bash
lume create --ipsw latest --disk-size 50GB \
  --unattended /tmp/lume-unattended-tahoe.yml --no-display dev-vm
```

Run with `run_in_background: true` and `timeout: 600000`.

Tell the user that VM creation is in progress. It downloads the macOS IPSW (~13-16 GB), installs macOS, then runs VNC automation for Setup Assistant.

#### Step 4: Monitor progress

Poll `mcp__lume__lume_get_vm(name="dev-vm")` every 90 seconds.

Progress indicators:

| Status | Meaning |
|--------|---------|
| `provisioning` / `ipsw_install` | macOS installing (~5 min after download) |
| `running` / `sshAvailable: false` | VNC automation in progress (~15 min) |
| `running` / `sshAvailable: true` | SSH health check passed |
| `stopped` | Done, ready to start |

**Note:** Background task output is buffered — the output file stays empty until completion. Use `mcp__lume__lume_get_vm` polling, not `tail`.

#### Step 5: Start VM with shared directory

Once the background task completes (VM status is `stopped`), start the VM via CLI:

**IMPORTANT:** Do NOT use `mcp__lume__lume_run_vm` with `shared_dir` — it silently fails. Use CLI:

```bash
lume run --shared-dir $HOME/shared --no-display dev-vm 2>&1 &
sleep 30
```

#### Step 6: Verify SSH

```
mcp__lume__lume_exec(name="dev-vm", command="whoami")
```

Expected: `lume`

#### Step 7: Verify shared directory

```
mcp__lume__lume_exec(name="dev-vm", command="ls /Volumes/")
```

Expected: `My Shared Files` in the output. Do NOT rely on `sharedDirectories` field in `mcp__lume__lume_get_vm` — it may show `null` even when working.

---

### Phase B: Run Dotfiles Inside VM

#### Step 8: Set up passwordless sudo

The dotfiles install.sh prompts for sudo. Set up NOPASSWD so it works non-interactively:

```
mcp__lume__lume_exec(name="dev-vm", command="echo 'lume' | sudo -S sh -c 'echo \"lume ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/lume && chmod 0440 /etc/sudoers.d/lume'")
```

Verify:

```
mcp__lume__lume_exec(name="dev-vm", command="sudo whoami")
```

Expected: `root` (no password prompt)

#### Step 9: Run install.sh (dotfiles one-liner)

```
mcp__lume__lume_exec(name="dev-vm", command="zsh -c \"$(curl -fsSL https://raw.githubusercontent.com/edmangalicea/dotfiles/main/install.sh)\"")
```

**Expected behavior:** install.sh will:
- Pass preflight checks (network, macOS version)
- `sudo -v` succeeds silently (NOPASSWD configured)
- Install Xcode CLT
- Clone the bare dotfiles repo to `~/.cfg`
- Check out dotfiles into `$HOME`
- Install Claude Code binary
- Hit `exec claude --init` and **hang/timeout** (no browser auth in headless SSH)

When `lume_exec` times out or returns an error at the `exec claude --init` step, **this is expected**. The dotfiles repo is cloned and checked out. Proceed to the next step.

#### Step 10: Run fresh.sh (module installation)

Run fresh.sh in the background to avoid SSH timeout (brew bundle can take 15-30 min):

```
mcp__lume__lume_exec(name="dev-vm", command="nohup zsh -c 'source $HOME/.dotfiles/lib/utils.sh && cd $HOME && $HOME/fresh.sh' > /tmp/fresh-install.log 2>&1 &")
```

fresh.sh runs all 9 modules in order:
1. `01-xcode-cli` — skips (already installed by install.sh)
2. `02-homebrew` — skips (already installed by install.sh)
3. `03-omz` — Oh My Zsh + Powerlevel10k theme
4. `04-rosetta` — Rosetta 2 for Intel app compatibility
5. `05-brewfile` — `brew bundle` with ~/Brewfile (all packages and casks)
6. `06-runtime` — bun, fnm (JS runtimes)
7. `07-directories` — standard directory structure
8. `08-macos-defaults` — system preferences
9. `09-dock` — dock layout

After modules complete, fresh.sh tries `exec claude --dangerously-skip-permissions` which will also fail in headless SSH — this is fine, all modules are already done.

#### Step 11: Poll fresh.sh progress

Poll every 60-90 seconds:

```
mcp__lume__lume_exec(name="dev-vm", command="tail -20 /tmp/fresh-install.log")
```

```
mcp__lume__lume_exec(name="dev-vm", command="pgrep -f fresh.sh && echo RUNNING || echo DONE")
```

Continue polling until `DONE`. Also look for the summary output in the log:
- `Dotfiles Setup Summary` — modules finished
- `Succeeded:` / `Failed:` / `Skipped:` — per-module results

#### Step 12: Verify installation

Run these checks:

```
mcp__lume__lume_exec(name="dev-vm", command="brew list | head -20")
```

```
mcp__lume__lume_exec(name="dev-vm", command="ls ~/.cfg")
```

```
mcp__lume__lume_exec(name="dev-vm", command="ls ~/.dotfiles/modules/")
```

```
mcp__lume__lume_exec(name="dev-vm", command="claude --version 2>/dev/null || echo 'not authenticated'")
```

#### Step 13: Show summary

Get the VM IP:

```
mcp__lume__lume_get_vm(name="dev-vm")
```

Present this summary:

| Field | Value |
|-------|-------|
| **VM Name** | `dev-vm` |
| **IP Address** | *(from get_vm)* |
| **SSH User** | `lume` |
| **SSH Password** | `lume` |
| **SSH Command** | `ssh lume@<IP>` |
| **Shared Dir (host)** | `~/shared` |
| **Shared Dir (guest)** | `/Volumes/My Shared Files` |

**Manual steps remaining:**
1. SSH into VM: `ssh lume@<IP>` (password: `lume`)
2. Run `claude` to authenticate Claude Code via browser
3. Generate SSH key: `ssh-keygen -t ed25519 -C "your@email.com"`
4. Add key to GitHub: `cat ~/.ssh/id_ed25519.pub | pbcopy`

---

## Troubleshooting

### VM creation fails

- **"The file tahoe couldn't be opened"** — YAML not downloaded. Re-run Step 1 curl.
- **"could not load resource bundle"** — Used preset name instead of file path. Use `/tmp/lume-unattended-tahoe.yml`.
- **VM already exists** — Delete it first (Step 2).

### SSH not available after VM starts

1. Wait longer (30-60 seconds after start)
2. Check: `mcp__lume__lume_get_vm(name="dev-vm")` — confirm `sshAvailable: true`
3. Probe port: run `nc -z -w 3 <IP> 22 && echo "SSH open" || echo "SSH closed"` via Bash

### install.sh fails before claude --init

Check the log inside the VM:

```
mcp__lume__lume_exec(name="dev-vm", command="cat ~/.dotfiles-install.log")
```

### fresh.sh hangs or fails

Check the background log:

```
mcp__lume__lume_exec(name="dev-vm", command="tail -50 /tmp/fresh-install.log")
```

Check if it's still running:

```
mcp__lume__lume_exec(name="dev-vm", command="ps aux | grep fresh.sh | grep -v grep")
```

### Cannot stop VM

1. Try `mcp__lume__lume_stop_vm(name="dev-vm")` once
2. If it fails, kill processes:
   ```bash
   ps aux | grep "lume.*dev-vm" | grep -v grep
   kill <PIDs>
   sleep 5
   ps aux | grep "lume.*dev-vm" | grep -v grep || echo "All killed"
   ```

### Shared directory not mounted

If `ls /Volumes/` doesn't show `My Shared Files`:
1. Stop the VM
2. Restart via CLI: `lume run --shared-dir $HOME/shared --no-display dev-vm 2>&1 &`
3. Wait 30 seconds, verify again
