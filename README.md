# Lighthouse Audit Tool

Standalone tool for auditing Keitaro landing pages with production-like metrics.

Uses Docker (nginx + gzip) to serve pages, matching production environment.

## Setup

1. Docker Desktop must be running
2. Lighthouse: `npm i -g lighthouse`
3. Chrome and/or Edge installed

## Usage

### Quick start

1. Drop offer folders into `projects/`
2. Double-click `run.bat`

### PowerShell

```powershell
# Audit all projects in ./projects/
.\audit.ps1

# Custom settings
.\audit.ps1 -Runs 5 -Browsers chrome -Presets "desktop,mobile"

# Single project
.\audit.ps1 -ProjectName "9169_offer_archive"

# Audit folder outside of projects/
.\audit.ps1 -ProjectsDir "C:\path\to\offers"

# Custom reports location
.\audit.ps1 -ReportsDir "C:\my-reports"
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ProjectsDir` | `.\projects` | Folder with offer subfolders |
| `-ReportsDir` | `.\reports\<timestamp>` | Where to save reports |
| `-BasePort` | `9100` | Starting port for nginx containers |
| `-Runs` | `3` | Lighthouse runs per browser/preset combo |
| `-Browsers` | `chrome,edge` | Browsers to test |
| `-Presets` | `desktop` | `desktop`, `mobile`, or `desktop,mobile` |
| `-HtmlFile` | `index.php` | Entry point filename |
| `-ProjectName` | | Run single project by folder name |

## How it works

1. Strips PHP from `index.php` -> creates `.lh.audit.html`
2. Replaces Keitaro `{_from_file:...}` placeholders with local stubs
3. Starts nginx container (gzip, static asset caching)
4. Runs Lighthouse in parallel (all browsers x presets x runs)
5. Generates summary reports
6. Stops container, cleans up

## Output

```
reports/
  20260305-150000/
    batch-summary.md           <- overall results
    project-name/
      lighthouse-summary.md    <- per-project summary
      lighthouse-*-run1.report.html
      lighthouse-*-run1.report.json
      ...
```

## Structure

```
lighthouse-tool/
  projects/          <- drop offer folders here
  reports/           <- results go here
  run.bat            <- double-click launcher
  audit.ps1          <- main script
  docker/
    nginx.conf       <- production-like nginx config
  stubs/             <- Keitaro placeholder stubs
```
