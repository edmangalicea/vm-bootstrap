#!/bin/bash
# host-setup.sh — One-liner bootstrap for macOS Tahoe VM creation
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/edmangalicea/vm-bootstrap/main/host-setup.sh)"
#
# This script runs on a fresh macOS Tahoe host and:
#   1. Installs Xcode CLT, Homebrew, sshpass, Lume, Claude Code
#   2. Writes Claude Code config (MCP, permissions, vm-bootstrap skill)
#   3. Launches Claude Code which creates a VM and runs dotfiles inside it

set -euo pipefail

LOG="$HOME/.vm-bootstrap.log"

# ── Logging ──────────────────────────────────────────────────────────────────

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s]  INFO  %s\n' "$(_ts)" "$*" | tee -a "$LOG"; }
warn() { printf '[%s]  \033[1;33mWARN\033[0m  %s\n' "$(_ts)" "$*" | tee -a "$LOG"; }
fail() { printf '[%s]  \033[1;31mFAIL\033[0m  %s\n' "$(_ts)" "$*" | tee -a "$LOG"; }
die()  { fail "$*"; exit 1; }

log "vm-bootstrap started"
log "macOS version: $(sw_vers -productVersion) ($(uname -m))"

# ── Preflight ────────────────────────────────────────────────────────────────

if [[ "$(uname -m)" != "arm64" ]]; then
  die "This script requires Apple Silicon (arm64). Detected: $(uname -m)"
fi

log "Checking network connectivity..."
if ! curl -sfI https://github.com --max-time 10 &>/dev/null; then
  die "Cannot reach github.com — check your internet connection"
fi
log "Network OK"

# ── Xcode Command Line Tools ────────────────────────────────────────────────

if ! xcode-select -p &>/dev/null; then
  log "Installing Xcode Command Line Tools..."

  # Try non-interactive install via softwareupdate first
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  CLT_LABEL=$(softwareupdate -l 2>/dev/null | grep -B 1 -E 'Command Line Tools' | grep -o 'Label: .*' | sed 's/Label: //' | head -1)

  if [[ -n "$CLT_LABEL" ]]; then
    log "Installing via softwareupdate: $CLT_LABEL"
    softwareupdate -i "$CLT_LABEL" --verbose 2>&1 | tee -a "$LOG"
  else
    log "softwareupdate label not found, falling back to xcode-select --install"
    xcode-select --install 2>/dev/null
    log "Waiting for Xcode CLT installer to complete (follow the GUI prompt)..."
  fi

  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

  # Wait for installation to complete
  until xcode-select -p &>/dev/null; do
    sleep 5
  done
  log "Xcode Command Line Tools installed"
else
  log "Xcode Command Line Tools already installed"
fi

# ── Homebrew ─────────────────────────────────────────────────────────────────

if ! command -v brew &>/dev/null && [[ ! -x /opt/homebrew/bin/brew ]] && [[ ! -x /usr/local/bin/brew ]]; then
  log "Installing Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>&1 | tee -a "$LOG"
  log "Homebrew installed"
else
  log "Homebrew already installed"
fi

# Ensure brew is on PATH for the rest of the script
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"

# Persist Homebrew PATH to shell profile (idempotent)
BREW_SHELLENV_LINE='eval "$(/opt/homebrew/bin/brew shellenv zsh)"'
if ! grep -qF "$BREW_SHELLENV_LINE" "$HOME/.zprofile" 2>/dev/null; then
  log "Adding Homebrew to ~/.zprofile..."
  echo >> "$HOME/.zprofile"
  echo "$BREW_SHELLENV_LINE" >> "$HOME/.zprofile"
fi

# ── sshpass ──────────────────────────────────────────────────────────────────

if ! command -v sshpass &>/dev/null; then
  log "Installing sshpass..."
  brew install sshpass 2>&1 | tee -a "$LOG"
  log "sshpass installed"
else
  log "sshpass already installed"
fi

# ── Lume ─────────────────────────────────────────────────────────────────────

# Ensure ~/.local/bin is on PATH for the rest of the script
export PATH="$HOME/.local/bin:$PATH"

if ! command -v lume &>/dev/null && [[ ! -x "$HOME/.local/bin/lume" ]]; then
  log "Installing Lume..."
  curl -fsSL https://raw.githubusercontent.com/trycua/cua/main/libs/lume/scripts/install.sh | bash 2>&1 | tee -a "$LOG"
  log "Lume installed"
else
  log "Lume already installed"
fi

# Verify lume is available
if ! command -v lume &>/dev/null; then
  die "Lume installation failed — 'lume' not found on PATH"
fi

LUME_PATH="$(command -v lume)"
log "Lume path: $LUME_PATH"

# ── Claude Code ──────────────────────────────────────────────────────────────

if ! command -v claude &>/dev/null && [[ ! -x "$HOME/.local/bin/claude" ]]; then
  log "Installing Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash 2>&1 | tee -a "$LOG"
  export PATH="$HOME/.claude/bin:$HOME/.local/bin:$PATH"
  log "Claude Code installed"
else
  log "Claude Code already installed"
fi

if ! command -v claude &>/dev/null; then
  die "Claude Code installation failed — 'claude' not found on PATH"
fi

log "Claude Code version: $(claude --version 2>/dev/null || echo 'unknown')"

# Persist ~/.local/bin to PATH in shell profile (idempotent)
LOCAL_BIN_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qF "$LOCAL_BIN_LINE" "$HOME/.zshrc" 2>/dev/null; then
  log "Adding ~/.local/bin to ~/.zshrc..."
  echo >> "$HOME/.zshrc"
  echo "$LOCAL_BIN_LINE" >> "$HOME/.zshrc"
fi

# ── Shared directory ─────────────────────────────────────────────────────────

mkdir -p "$HOME/shared"
log "Shared directory ready: ~/shared"

# ── Claude Code configuration ───────────────────────────────────────────────

# MCP config — Lume server
log "Writing MCP config..."
mkdir -p "$HOME"
cat > "$HOME/.mcp.json" << MCPEOF
{
  "mcpServers": {
    "lume": {
      "command": "$LUME_PATH",
      "args": ["serve", "--mcp"]
    }
  }
}
MCPEOF
log "MCP config written to ~/.mcp.json"

# Claude Code settings — allow all permissions
log "Writing Claude Code settings..."
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" << 'SETTINGSEOF'
{
  "permissions": {
    "allow": [
      "*"
    ],
    "deny": []
  }
}
SETTINGSEOF
log "Settings written to ~/.claude/settings.json"

# Download vm-bootstrap skill
log "Downloading vm-bootstrap skill..."
mkdir -p "$HOME/.claude/commands"
curl -fsSL "https://raw.githubusercontent.com/edmangalicea/vm-bootstrap/main/claude-config/commands/vm-bootstrap.md" \
  -o "$HOME/.claude/commands/vm-bootstrap.md" 2>&1 | tee -a "$LOG"

if [[ ! -s "$HOME/.claude/commands/vm-bootstrap.md" ]]; then
  die "Failed to download vm-bootstrap skill"
fi
log "vm-bootstrap skill installed to ~/.claude/commands/vm-bootstrap.md"

# ── Launch Claude Code ───────────────────────────────────────────────────────

log "Launching Claude Code..."

# Check if Claude Code is authenticated by testing a trivial non-interactive command.
# If not authenticated, launch interactively so the user can complete browser-based login.
if claude --dangerously-skip-permissions -p "echo hello" &>/dev/null; then
  log "Claude Code is authenticated. Running vm-bootstrap..."
  exec claude --dangerously-skip-permissions -p "Run /vm-bootstrap"
else
  log "Claude Code is not yet authenticated."
  log "Please complete browser-based login, then run /vm-bootstrap inside Claude Code."
  exec claude --dangerously-skip-permissions
fi
