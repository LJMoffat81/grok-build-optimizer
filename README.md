# Grok Build PC Optimizer

Tune your Windows workstation for [Grok Build](https://x.ai) AI coding — faster terminal, smarter config, fewer OS bottlenecks.

## Your System (baseline)

| Component | Value |
|-----------|-------|
| CPU | AMD Ryzen 9 5950X (16C / 32T) |
| RAM | 32 GB |
| GPU | AMD Radeon RX 6900 XT |
| OS | Windows 11 Education (Build 26200) |
| Storage | C: 647 GB free · E: 1.8 TB free |
| Grok | 1.0.4 |
| Terminal | Windows Terminal |
| Dev tools | Git, Node 24, Python 3.12, Rust 1.96 |

**Status:** User-level optimizations applied. Power plan **High Performance**, `COLORTERM=truecolor` set, default model **grok-4.6**. **BIOS SVM is still off** — Ubuntu WSL2 is installed but will not run until you enable SVM and reboot.

## Quick Start

```powershell
cd C:\Projects\grok-build-optimizer

# 1. Baseline audit (no admin needed)
.\scripts\audit-system.ps1

# 2. Preview optimizations (admin required)
.\scripts\apply-optimizations.ps1 -WhatIf

# 3. Apply safe optimizations (admin required)
.\scripts\apply-optimizations.ps1
```

Launch Grok from the project:

```powershell
.\scripts\launch-grok.ps1
```

Inside Grok, run `/doctor` (alias `/terminal-setup`) to verify terminal detection and colors.

## Junk cleanup

The old `pc-cleanup` folder lives here now. It still refuses to touch Documents, Pictures, Desktop, Videos, or project folders. Cleanup logs and undo backups go in `logs\` (gitignored).

Double-click **Clean My PC** on the Desktop, or:

```powershell
cd C:\Projects\grok-build-optimizer
.\scripts\pc-cleanup.ps1 -Scan
.\scripts\pc-cleanup.ps1 -Clean -WhatIf
.\scripts\pc-cleanup.ps1 -Optimize -WhatIf
.\scripts\pc-cleanup.ps1 -Optimize -Extras
.\scripts\pc-cleanup.ps1 -Undo
```

High Performance power plan changes go through `scripts\power-plan.ps1`. Both this cleanup optimizer and `apply-optimizations.ps1 -HighPerformance` call that one script.

## What Gets Optimized

| Area | Action |
|------|--------|
| Power plan | Power Saver → Balanced (or High Performance with `-HighPerformance`) |
| PATH | Ensures `%USERPROFILE%\.grok\bin` is on User PATH |
| Terminal | Sets `COLORTERM=truecolor` for accurate Grok TUI colors |
| Grok config | Merges recommended 1.0.x timeouts, subagents, notifications; upgrades retired model IDs |
| Defender | Optional exclusions for `.grok`, `Projects`, npm/pip caches |

## Optimization Checklist

- [x] Run baseline audit
- [x] Switch off Power Saver (now High Performance)
- [x] Apply user-level optimizations (PATH, COLORTERM, Grok config)
- [x] Defender exclusions (applied via elevated script)
- [x] Startup cleanup (Adobe sync, Edge auto-launch, Jitsi Meet)
- [x] Rust installed (rustc 1.96, cargo on PATH)
- [ ] Enable SVM in BIOS (still off — WSL2 cannot run)
- [x] Ubuntu 26.04 LTS installed (stopped until SVM is on)
- [ ] Workstation verified (blocked on BIOS SVM)
- [ ] Run `/doctor` in Grok TUI (optional visual check)
- [x] Re-run audit (2026-08-17)
- [x] Fine-tune `~/.grok/config.toml` for Grok 1.0.4 (`grok-4.6`)

## Project Structure

```
grok-build-optimizer/
├── AGENTS.md              # Grok project rules
├── config/
│   └── recommended-grok-config.toml
├── logs/                  # Cleanup logs and undo backups (gitignored)
├── reports/               # Audit output (gitignored)
└── scripts/
    ├── audit-system.ps1
    ├── apply-optimizations.ps1
    ├── Clean-My-PC.bat
    ├── cleanup-startup.ps1
    ├── enable-virtualization.ps1
    ├── launch-grok.ps1
    ├── optimize.ps1
    ├── pc-cleanup.ps1
    ├── power-plan.ps1
    ├── setup-dev-tools.ps1
    ├── setup-wsl-post-reboot.ps1
    └── status.ps1
```

## Startup Cleanup

Disabled 3 safe startup items (backup in `reports/startup-backup-*`):
- Adobe Acrobat Synchronizer
- Microsoft Edge auto-launch
- Jitsi Meet shortcut

To also disable Teams and MuseHub:

```powershell
.\scripts\cleanup-startup.ps1 -IncludeOptional
```

## WSL + Rust

Rust (`rustc 1.96`) and **Ubuntu 26.04 LTS** are installed. WSL2 will not start until **SVM Mode** is enabled in BIOS (ASUS ROG CROSSHAIR VIII IMPACT: Advanced → CPU Configuration → SVM Mode → Enabled → F10).

```powershell
.\scripts\status.ps1   # check all optimizations
wsl -d Ubuntu          # Linux shell — after SVM is on
```

## Manual Tweaks (optional)

- **Windows Terminal**: In profile settings, set default directory to `C:\Projects` and font size to taste.
- **Grok launch**: `grok --cwd C:\Projects\your-app` keeps sessions scoped to real projects.
- **Memory**: Enable cross-session memory with `GROK_MEMORY=1` once you are comfortable with it.

