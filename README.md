# vm-bootstrap

One-liner that bootstraps a fresh macOS Tahoe host, creates a Lume VM via Claude Code, and runs dotfiles inside the VM.

## Usage

On a fresh macOS Tahoe machine (Apple Silicon), paste:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/edmangalicea/vm-bootstrap/main/host-setup.sh)"
```

## What it does

1. **Host setup** (`host-setup.sh`): Installs Xcode CLT, Homebrew, sshpass, Lume, and Claude Code on the host
2. **Launches Claude Code** with the `/vm-bootstrap` skill
3. **VM creation**: Claude Code creates an unattended macOS VM via Lume (~25 min)
4. **Dotfiles installation**: Runs the [dotfiles](https://github.com/edmangalicea/dotfiles) `install.sh` and `fresh.sh` inside the VM

## End-to-end flow

```
Fresh macOS Tahoe -> paste one-liner -> host-setup.sh ->
  Xcode CLT -> Homebrew -> sshpass -> Lume -> Claude Code ->
  Claude Code config (MCP + skill + permissions) ->
  Claude Code authenticates (browser) ->
  /vm-bootstrap skill runs ->
    Create unattended VM via Lume CLI ->
    Start VM, verify SSH ->
    Passwordless sudo for lume user ->
    Dotfiles install.sh (clone repo, checkout, install Claude Code) ->
    fresh.sh (9 modules: brew, omz, rosetta, brewfile, runtime, dirs, defaults, dock) ->
  Done.
```

## What gets installed on the host

| Tool | Purpose |
|------|---------|
| Xcode CLT | Build tools, git |
| Homebrew | Package manager |
| sshpass | Required for Lume SSH health checks |
| Lume | macOS VM management (Apple Virtualization) |
| Claude Code | AI-powered orchestration |

## What gets installed in the VM

Everything from the [dotfiles repo](https://github.com/edmangalicea/dotfiles):
- Homebrew + all packages from Brewfile
- Oh My Zsh + Powerlevel10k
- Rosetta 2
- bun, fnm (JS runtimes)
- Standard directory structure
- macOS system preferences
- Dock layout
- Claude Code (binary only — needs manual auth)

## VM details

| Field | Value |
|-------|-------|
| Name | `dev-vm` |
| SSH User | `lume` |
| SSH Password | `lume` |
| Shared Dir (host) | `~/shared` |
| Shared Dir (guest) | `/Volumes/My Shared Files` |

## After completion

SSH into the VM and complete manual steps:

```bash
ssh lume@<IP>  # password: lume

# Authenticate Claude Code
claude

# Generate SSH key
ssh-keygen -t ed25519 -C "your@email.com"

# Add to GitHub
cat ~/.ssh/id_ed25519.pub | pbcopy
```

## Repo structure

```
vm-bootstrap/
├── host-setup.sh                     # One-liner target: host deps + launch Claude Code
├── claude-config/
│   └── commands/
│       └── vm-bootstrap.md           # Claude Code skill: VM creation + dotfiles
└── README.md
```

No code duplication — the existing `install.sh` and `fresh.sh` from the dotfiles repo are run directly inside the VM.
