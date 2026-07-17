# CDE UI Display Test Matrix

Use this checklist when validating responsive layout changes across display sizes and DPI settings.

## Environment matrix

| ID | Resolution | DPI scale | Mode | Priority |
|----|------------|-----------|------|----------|
| T1 | 1024 x 768 | 100% | WinPE | Required |
| T2 | 1366 x 768 | 100% | Windows desktop | Required |
| T3 | 1920 x 1080 | 100% | Windows desktop | Required |
| T4 | 1920 x 1080 | 125% | Windows desktop | Required |
| T5 | 1920 x 1080 | 150% | Windows desktop | Required |
| T6 | 3840 x 2160 | 150% | Windows desktop | Recommended |
| T7 | 3840 x 2160 | 200% | Windows desktop | Recommended |
| T8 | Dual monitor | 100% + 150% | Drag window between displays | Recommended |
| T9 | Any | Change while running | Settings > Display scale change | Recommended |

## Shell checks (all environments)

- [ ] Sidebar toggle collapses to icon rail (56px) and expands to full labels (220px)
- [ ] All nav destinations reachable when collapsed (tooltips visible on hover)
- [ ] All nav destinations reachable when expanded without clipping
- [ ] Sidebar scrolls when content exceeds viewport; scrollbar visible (12px)
- [ ] Header info bar scrolls horizontally when work order / metrics overflow
- [ ] Window respects min size and remains usable at `ShellMinWidth` / `ShellMinHeight`
- [ ] WinPE: starts collapsed/compact when work area height < 720px
- [ ] Auto-collapse below 1200px window width unless user manually toggles sidebar

## View checks

### Hijack & Scam Repair
- [ ] Toolbar buttons wrap on narrow widths (no horizontal clip)
- [ ] Findings grid and Finding Details resize via GridSplitter (both remain visible)
- [ ] Expanding Quick Repairs does not cover Finding Details
- [ ] Scan log and Quick Repairs footer remain reachable
- [ ] Finding Details scrolls when content is long

### Uninstall Manager
- [ ] All DataGrid columns visible or horizontally scrollable
- [ ] Uninstall / Force Remove buttons visible in ACTIONS column

### Diag & Repair
- [ ] Profile radios, hardware test buttons, CST scan, and progress wrap on narrow widths
- [ ] Test tree scrolls vertically in remaining space

### Process Analyzer
- [ ] Header action buttons wrap
- [ ] Process list + detail resize via GridSplitter (AvalonDock prototype deferred — named control scope)
- [ ] Process grid horizontal scroll on narrow widths
- [ ] Selected-process Network connections and Module anomalies sections remain reachable and scroll correctly

### CST Scan Results
- [ ] Primary Findings grid retains vertical and horizontal scrolling at the default window size
- [ ] **Suppressed audit Findings** appears as one collapsed line at the bottom of Findings when suppressed rows exist
- [ ] Expanding suppressed findings reveals a usable review-only grid; collapsing restores primary-findings space
- [ ] Suppressed line is absent when the scan has no suppressed audit rows

### Workflow views (OS Repair, Malware Cleanup, Backup, Post-Op, etc.)
- [ ] OUTPUT status bars wrap instead of clipping
- [ ] ResponsiveToolbar controls wrap button rows

## Regression pass views

- [ ] Startup Manager (tabs + filter toolbar + grids)
- [ ] System Health Check picker (preset toolbar wraps)
- [ ] System Health results (selected left card shows blue tint/border/left accent + VIEWING badge; only one DETAILED RESULTS heading; rich detail remains readable below scored findings)
- [ ] S.M.A.R.T. Analyzer (drive selector wraps)
- [ ] File Manager (panes fill height)
- [ ] Temp File Cleaner (header + drive scope + status)

## Pass criteria

A test passes when:
1. No critical button or label is permanently clipped without scroll/wrap alternative
2. User can complete primary workflow actions at minimum supported size
3. Text remains readable at 150%+ DPI (no blur from manual scaling transforms)

## Automated smoke (developer)

```powershell
dotnet build "Toolkit\App\ToolkitGUI\ToolkitGUI.csproj" -c Release
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Toolkit\App\Publish-ToolkitGUI.ps1"
```

After publish, launch `Toolkit\CDE.exe` and run T2 + T3 + T4 manually.
