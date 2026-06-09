# Grok Build PC Optimizer

Tune your Windows workstation for [Grok Build](https://x.ai) AI coding — faster terminal, smarter config, fewer OS bottlenecks.

## Your System (baseline)

| Component | Value |
|-----------|-------|
| CPU | AMD Ryzen 9 5950X (16C / 32T) |
| RAM | 32 GB |
| GPU | AMD Radeon RX 6900 XT |
| OS | Windows 11 Education (Build 26200) |
| Storage | C: 626 GB free · E: 1.8 TB free |
| Grok | 0.2.38 |
| Terminal | Windows Terminal |
| Dev tools | Git, Node 24, Python 3.12, Rust 1.96 |

**Status:** All optimizations applied. Power plan **Balanced**, `COLORTERM=truecolor` set, Defender exclusions active. Restart terminal, then run `/terminal-setup` in Grok.

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

After applying, restart your terminal and launch Grok:

```powershell
grok --cwd C:\Projects\grok-build-optimizer
```

Inside Grok, run `/terminal-setup` to verify terminal detection and colors.

## What Gets Optimized

| Area | Action |
|------|--------|
| Power plan | Power Saver → Balanced |
| PATH | Ensures `%USERPROFILE%\.grok\bin` is on User PATH |
| Terminal | Sets `COLORTERM=truecolor` for accurate Grok TUI colors |
| Grok config | Merges recommended timeouts, subagents, notifications |
| Defender | Optional exclusions for `.grok`, `Projects`, npm/pip caches |

## Optimization Checklist

- [x] Run baseline audit
- [x] Switch off Power Saver (now Balanced)
- [x] Apply user-level optimizations (PATH, COLORTERM, Grok config)
- [x] Defender exclusions (applied via elevated script)
- [x] Startup cleanup (Adobe sync, Edge auto-launch, Jitsi Meet)
- [x] Rust installed (rustc 1.96, cargo on PATH)
- [ ] **Reboot PC** (required for WSL)
- [ ] Enable **AMD-V / SVM** in BIOS if WSL still fails after reboot
- [ ] Run `.\scripts\setup-wsl-post-reboot.ps1` to install Ubuntu
- [ ] Restart terminal, then run `/terminal-setup` in Grok
- [x] Re-run audit
- [ ] Fine-tune `~/.grok/config.toml` for your workflow

## Project Structure

```
grok-build-optimizer/
├── AGENTS.md              # Grok project rules
├── config/
│   └── recommended-grok-config.toml
├── reports/               # Audit output (gitignored)
└── scripts/
    ├── audit-system.ps1
    ├── apply-optimizations.ps1
    ├── cleanup-startup.ps1
    ├── setup-dev-tools.ps1
    └── setup-wsl-post-reboot.ps1
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

Rust is ready (`rustc 1.96`). WSL 2.7.3 is installed but **blocked**: virtualization is off in BIOS.

**Your board:** ASUS ROG CROSSHAIR VIII IMPACT

1. Restart and press **DEL** or **F2** to enter BIOS
2. **Advanced** → **CPU Configuration** → **SVM Mode** → **Enabled**
   (alternate: **Advanced** → **AMD CBS** → **CPU Common Options** → **SVM Mode**)
3. Press **F10** to save and reboot
4. Then run:

```powershell
.\scripts\enable-virtualization.ps1    # verify Windows side (admin)
.\scripts\setup-wsl-post-reboot.ps1  # install Ubuntu
```

## Manual Tweaks (optional)

- **Windows Terminal**: In profile settings, set default directory to `C:\Projects` and font size to taste.
- **Grok launch**: `grok --cwd C:\Projects\your-app` keeps sessions scoped to real projects.
- **Memory**: Enable cross-session memory with `GROK_MEMORY=1` once you are comfortable with it.

## Note on Home Directory Git

Your home folder (`C:\Users\lauri`) was initialized as a git repo earlier. That is usually unintended. Consider removing it:

```powershell
Remove-Item -Recurse -Force C:\Users\lauri\.git
```

Only do this if you did not mean to track your entire home directory.