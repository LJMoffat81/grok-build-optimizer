# Grok Build PC Optimizer

This project tunes a Windows workstation for Grok Build AI development.

## Goals

1. Maximize terminal responsiveness and Grok TUI quality (Windows Terminal, truecolor, notifications).
2. Reduce OS-level bottlenecks (power plan, disk I/O, background apps, Defender scan interference).
3. Keep Grok config aligned with a fast local dev workflow (subagents, tool timeouts, PATH).
4. Track every change with auditable before/after reports.

## Rules

- Run `scripts/audit-system.ps1` before and after any optimization batch; save output under `reports/`.
- Prefer reversible, documented changes. Never disable security features without explicit user approval.
- Use `-WhatIf` on `scripts/apply-optimizations.ps1` first; apply only after the user confirms.
- Do not store secrets (API keys, tokens) in this repo.
- Windows-specific: test changes against Grok 0.2.x on Windows 11 with Windows Terminal.

## Workflow

1. Audit → review findings → apply safe optimizations → re-audit → update README status table.