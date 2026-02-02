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

## Progress Output

Throughout execution, output structured progress text so the user can follow along. Use these patterns:

- **Phase banners** — output at the start of each phase:
  ```
  ━━━ Phase A: Create the VM (Steps 1-7) ━━━
  ```
- **Step headers** — output before each step's tool calls:
  ```
  ▸ Step N/13: Description...
  ```
- **Completion markers** — output after each step succeeds:
  ```
  ✔ Step N complete: Result summary
  ```
- **Polling status** — output on each poll iteration during waits:
  ```
  ↻ VM status: provisioning — macOS installing [3m 30s elapsed]
  ```
- **Expected timeouts** — output when a known-benign timeout occurs:
  ```
  ◷ Step N: Expected timeout (reason). Proceeding.
  ```
- **Warnings** — output on recoverable errors:
  ```
  ⚠ Step N: Error description — retrying...
  ```

### Elapsed time tracking

Before any long operation (VM creation, install.sh, fresh.sh), capture the start time:

```bash
date +%s
```

During polling loops, capture the current time and compute elapsed:

```bash
date +%s
```

Then calculate: `elapsed = current - start`, `mins = elapsed / 60`, `secs = elapsed % 60`, and include `[Xm Ys elapsed]` in polling output.

## Procedure

### Phase A: Create the VM

**Output:** `━━━ Phase A: Create the VM (Steps 1-7) ━━━`

#### Step 1: Prerequisites

**Output:** `▸ Step 1/13: Downloading prerequisites...`

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

**Output on success:** `✔ Step 1 complete: Prerequisites ready`

#### Step 2: Check for existing VM

**Output:** `▸ Step 2/13: Checking for existing VM...`

```
mcp__lume__lume_list_vms()
```

If `dev-vm` already exists:
1. Try `mcp__lume__lume_stop_vm(name="dev-vm")` once
2. If that fails, kill processes: `ps aux | grep "lume.*dev-vm" | grep -v grep` then `kill` the PIDs
3. Wait 5 seconds, verify processes are gone
4. `mcp__lume__lume_delete_vm(name="dev-vm")`

**Output on success:** `✔ Step 2 complete: No conflicting VM` or `✔ Step 2 complete: Existing VM cleaned up`

#### Step 3: Create VM via CLI

**Output:** `▸ Step 3/13: Creating VM (this is the longest step)...`

**IMPORTANT:** Use the `lume` CLI directly, NOT the MCP tool. Run as a background task:

Capture the start time first:

```bash
date +%s
```

Then create the VM:

```bash
lume create --ipsw latest --disk-size 50GB \
  --unattended /tmp/lume-unattended-tahoe.yml --no-display dev-vm
```

Run with `run_in_background: true` and `timeout: 600000`.

**Output** the following info box immediately after launching the background task:

```
┌─────────────────────────────────────────────────────────┐
│  VM creation started. This runs 3 stages:               │
│    1. Download macOS IPSW (~13-16 GB)                   │
│    2. Install macOS to virtual disk                     │
│    3. VNC automation for Setup Assistant                 │
│  Polling every 90s until complete...                    │
└─────────────────────────────────────────────────────────┘
```

#### Step 4: Monitor progress

**Output:** `▸ Step 4/13: Monitoring VM creation...`

Poll `mcp__lume__lume_get_vm(name="dev-vm")` every 90 seconds. On each poll, also run `date +%s` and compute elapsed time from the start captured in Step 3.

Progress indicators:

| Status | Meaning |
|--------|---------|
| `provisioning` / `ipsw_install` | macOS installing (~5 min after download) |
| `running` / `sshAvailable: false` | VNC automation in progress (~15 min) |
| `running` / `sshAvailable: true` | SSH health check passed |
| `stopped` | Done, ready to start |

**Output** on each poll iteration — map the VM status to a human-readable description using the table above:

```
↻ VM status: <status> — <meaning from table> [Xm Ys elapsed]
```

When the VM reaches `stopped` status:

```
✔ Step 4 complete: VM created successfully [Xm Ys total]
```

**Note:** Background task output is buffered — the output file stays empty until completion. Use `mcp__lume__lume_get_vm` polling, not `tail`.

#### Step 5: Start VM with shared directory

**Output:** `▸ Step 5/13: Starting VM with shared directory...`

Once the background task completes (VM status is `stopped`), start the VM via CLI:

**IMPORTANT:** Do NOT use `mcp__lume__lume_run_vm` with `shared_dir` — it silently fails. Use CLI:

```bash
lume run --shared-dir $HOME/shared --no-display dev-vm 2>&1 &
sleep 30
```

**Output on success:** `✔ Step 5 complete: VM started`

#### Step 6: Verify SSH

**Output:** `▸ Step 6/13: Verifying SSH access...`

```
mcp__lume__lume_exec(name="dev-vm", command="whoami")
```

Expected: `lume`

**Output on success:** `✔ Step 6 complete: SSH connected (user: lume)`

#### Step 7: Verify shared directory

**Output:** `▸ Step 7/13: Verifying shared directory...`

```
mcp__lume__lume_exec(name="dev-vm", command="ls /Volumes/")
```

Expected: `My Shared Files` in the output. Do NOT rely on `sharedDirectories` field in `mcp__lume__lume_get_vm` — it may show `null` even when working.

**Output on success:** `✔ Step 7 complete: Shared directory mounted`

---

### Phase B: Run Dotfiles Inside VM

**Output:** `━━━ Phase B: Run Dotfiles Inside VM (Steps 8-13) ━━━`

#### Step 8: Set up passwordless sudo

**Output:** `▸ Step 8/13: Configuring passwordless sudo...`

The dotfiles install.sh prompts for sudo. Set up NOPASSWD so it works non-interactively:

```
mcp__lume__lume_exec(name="dev-vm", command="echo 'lume' | sudo -S sh -c 'echo \"lume ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/lume && chmod 0440 /etc/sudoers.d/lume'")
```

Verify:

```
mcp__lume__lume_exec(name="dev-vm", command="sudo whoami")
```

Expected: `root` (no password prompt)

**Output on success:** `✔ Step 8 complete: Passwordless sudo configured`

#### Step 9: Run install.sh (dotfiles one-liner)

**Output:** `▸ Step 9/13: Running dotfiles install.sh inside VM...`

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

**Output on timeout/error:** `◷ Step 9: Expected timeout (exec claude --init hangs in headless SSH). Dotfiles installed. Proceeding.`

#### Step 10: Run fresh.sh (module installation)

**Output:** `▸ Step 10/13: Launching fresh.sh (9 modules)...`

Capture start time for fresh.sh elapsed tracking:

```bash
date +%s
```

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

**Output:** `▸ Step 11/13: Monitoring fresh.sh modules...`

Poll every 60-90 seconds. On each poll, run `date +%s` and compute elapsed from the start captured in Step 10.

```
mcp__lume__lume_exec(name="dev-vm", command="tail -20 /tmp/fresh-install.log")
```

```
mcp__lume__lume_exec(name="dev-vm", command="pgrep -f fresh.sh && echo RUNNING || echo DONE")
```

**Module detection:** Parse the log output for module indicators. The modules log lines containing their names (`01-xcode-cli` through `09-dock`). Determine which module is currently running or was the last to complete.

**Output** on each poll iteration:

```
↻ fresh.sh: Module N/9 (module-name) [Xm Ys elapsed]
```

For example: `↻ fresh.sh: Module 5/9 (05-brewfile) [8m 30s elapsed]`

Continue polling until `DONE`. Also look for the summary output in the log:
- `Dotfiles Setup Summary` — modules finished
- `Succeeded:` / `Failed:` / `Skipped:` — per-module results

**Output on completion:** `✔ Step 11 complete: fresh.sh finished — N succeeded, N failed, N skipped [Xm Ys total]`

#### Step 12: Verify installation

**Output:** `▸ Step 12/13: Verifying installation...`

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

**Output on success:** `✔ Step 12 complete: Installation verified`

#### Step 13: Show summary

**Output:** `▸ Step 13/13: Generating summary...`

Get the VM IP:

```
mcp__lume__lume_get_vm(name="dev-vm")
```

**Output** the following box-drawing summary (fill in `<IP>` from the get_vm result):

```
┌─────────────────────────────────────────────────────────┐
│  ✔ VM Bootstrap Complete                                │
├─────────────────────────────────────────────────────────┤
│  VM Name:          dev-vm                               │
│  IP Address:       <IP>                                 │
│  SSH User:         lume                                 │
│  SSH Password:     lume                                 │
│  SSH Command:      ssh lume@<IP>                        │
│  Shared Dir (host):  ~/shared                           │
│  Shared Dir (guest): /Volumes/My Shared Files           │
├─────────────────────────────────────────────────────────┤
│  Manual steps remaining:                                │
│    1. ssh lume@<IP>  (password: lume)                   │
│    2. Run `claude` to authenticate via browser          │
│    3. ssh-keygen -t ed25519 -C "your@email.com"        │
│    4. cat ~/.ssh/id_ed25519.pub | pbcopy → add to GH   │
└─────────────────────────────────────────────────────────┘
```

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
