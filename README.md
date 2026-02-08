# EximAI Guardian (Windows)

Defensive monitoring for automation/agent exposures on Windows.

## What it does (MVP)
- Detects if a local control UI (e.g. OpenClaw Gateway on port 19001) becomes reachable from non-loopback interfaces.
- Detects established remote connections to a protected port.
- Baselines + diffs:
  - listening TCP ports
  - scheduled tasks
  - common startup/persistence locations (registry Run keys)
- Alerts:
  - Local: writes to log file
  - Email: optional SMTP alert

> This is a defensive monitoring tool. It is not designed to disable or attack any software.

## Quick start
1. Copy `dist/EximAI-Guardian.zip` to the target Windows machine.
2. Unzip to `C:\Program Files\EximAI\Guardian` (or any folder).
3. Edit `config\guardian.config.json`.
4. Run once to create baseline:
   - `powershell -ExecutionPolicy Bypass -File .\guardian.ps1 -Init`
5. Install as a Scheduled Task (runs every 1 minute):
   - `powershell -ExecutionPolicy Bypass -File .\guardian.ps1 -InstallTask`

## Build ZIP
- `powershell -ExecutionPolicy Bypass -File .\scripts\build-zip.ps1`

## Config
See `config/guardian.config.json`.
