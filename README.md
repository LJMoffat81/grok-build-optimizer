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
| Dev tools | Git, Node 24, Python 3.12 |

**Status:** Power plan switched to **Balanced**. `COLORTERM=truecolor` set (restart terminal). Defender exclusions still need admin.

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
- [ ] Defender exclusions (requires admin — double-click `scripts/run-admin-optimizations.bat`)
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
    └── apply-optimizations.ps1
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