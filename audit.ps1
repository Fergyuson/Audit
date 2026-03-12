param(
    [string]$ProjectsDir = '',
    [string]$ReportsDir = '',
    [int]$BasePort = 9100,
    [int]$Runs = 3,
    [string]$Browsers = 'chrome,edge',
    [string]$Presets = 'desktop,mobile',
    [string]$HtmlFile = 'index.php',
    [string]$ProjectName = ''
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ProjectsDir) { $ProjectsDir = Join-Path $toolDir 'projects' }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $ReportsDir) { $ReportsDir = Join-Path $toolDir "reports\$timestamp" }
$ProjectsDir = [System.IO.Path]::GetFullPath($ProjectsDir)
$ReportsDir = [System.IO.Path]::GetFullPath($ReportsDir)
$nginxConf = Join-Path $toolDir 'docker\nginx.conf'
$sslDir = Join-Path $toolDir 'docker\ssl'
$stubsDir = Join-Path $toolDir 'stubs'

# ============================================================
#  PREREQUISITES
# ============================================================

$prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
& docker info *> $null; $dockerOk = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prev
if (-not $dockerOk) {
    Write-Output 'ERROR: Docker is not running. Start Docker Desktop and retry.'
    exit 1
}

# Generate self-signed TLS cert for HTTP/2 (once)
if (-not (Test-Path (Join-Path $sslDir 'cert.pem'))) {
    New-Item -ItemType Directory -Force -Path $sslDir | Out-Null
    $sslFwd = $sslDir -replace '\\', '/'
    Write-Output 'Generating self-signed TLS certificate for HTTP/2...'
    $prev2 = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    & docker run --rm -v "${sslFwd}:/certs" alpine/openssl `
        req -x509 -nodes -days 3650 -newkey rsa:2048 `
        -keyout /certs/key.pem -out /certs/cert.pem `
        -subj "/CN=localhost" *> $null
    $ErrorActionPreference = $prev2
    if (-not (Test-Path (Join-Path $sslDir 'cert.pem'))) {
        throw 'Failed to generate TLS certificate. Make sure Docker is running.'
    }
    Write-Output '  TLS cert ready'
}

function Get-BrowserPath {
    param([string]$Browser)
    if ($Browser -eq 'chrome') {
        $paths = @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
        )
    } else {
        $paths = @(
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
            "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
        )
    }
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return $null
}

function Get-LighthouseCmd {
    if (Get-Command lighthouse -EA SilentlyContinue) { return 'lighthouse' }
    if (Get-Command npx -EA SilentlyContinue) { return 'npx' }
    throw 'Lighthouse not found. Run: npm i -g lighthouse'
}

$lhCmd = Get-LighthouseCmd

$browserList = $Browsers -split ','
$availBrowsers = @()
foreach ($b in $browserList) {
    $bp = Get-BrowserPath $b
    if ($bp) { $availBrowsers += [pscustomobject]@{ Name = $b; Path = $bp } }
    else { Write-Output "[warn] $b not found, skipping" }
}
if ($availBrowsers.Count -eq 0) { throw 'No browsers (chrome/edge) found.' }

# ============================================================
#  PREPARE AUDIT HTML
# ============================================================

function New-AuditHtml {
    param([string]$ProjectDir, [string]$HtmlFile, [string]$StubsDir)

    $srcPath = Join-Path $ProjectDir $HtmlFile
    if (-not (Test-Path $srcPath)) { return $null }

    $content = Get-Content -Raw -Path $srcPath -Encoding UTF8
    $regOpts = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Singleline'

    $content = [regex]::Replace($content, '<\?=\s*\$\w*[Jj]son\s*\?>', '{}', $regOpts)
    $content = [regex]::Replace($content, '<\?.*?\?>', '', $regOpts)

    $fileMap = @{
        '{_from_file:showcases_v2_file_path}'                = '/lighthouse-stubs/showcases_v2.module.js'
        '{_from_file:universal_widget_combined_file_path}'    = '/lighthouse-stubs/universal_widget_combined.module.js'
        '{_from_file:form_mask_file_path}'                   = '/lighthouse-stubs/form_mask.module.js'
        '{_from_file:showcases_v2_api_link}'                 = '/lighthouse-stubs/showcases_v2_api.json'
    }
    foreach ($key in $fileMap.Keys) { $content = $content.Replace($key, $fileMap[$key]) }

    $tokenMap = @{
        '{subid}' = 'subid_local'; '{_subid}' = 'subid_local'
        '{pixid}' = 'pixid_local'; '{_token}' = 'token_local'
        '{_offer_id}' = 'offer_local'; '{offer_id}' = 'offer_local'
        '{_campaign_name}' = 'campaign_local'; '{_campaign_id}' = 'campaign_local'
        '{_country}' = 'PE'; '{country}' = 'PE'
        '{ymc}' = 'ymc_local'; '{gua}' = 'gua_local'; '{tpixid}' = 'tpixid_local'
    }
    foreach ($key in $tokenMap.Keys) { $content = $content.Replace($key, $tokenMap[$key]) }

    $content = $content.Replace('../../lander/mv/counters/first.min.js', '/lighthouse-stubs/first.min.js')

    # Copy stubs into project if not present
    $projStubs = Join-Path $ProjectDir 'lighthouse-stubs'
    if (-not (Test-Path $projStubs)) {
        Copy-Item -Path $StubsDir -Destination $projStubs -Recurse -Force
    }

    $outPath = Join-Path $ProjectDir '.lh.audit.html'
    [System.IO.File]::WriteAllText($outPath, $content, [System.Text.UTF8Encoding]::new($false))
    return $outPath
}

# ============================================================
#  DOCKER NGINX
# ============================================================

function Start-NginxContainer {
    param([string]$Name, [string]$ProjectDir, [int]$Port, [string]$ConfPath, [string]$SslDir)

    $containerName = "lh-audit-${Name}"
    $prev2 = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    & docker rm -f $containerName *> $null
    $ErrorActionPreference = $prev2

    $projFwd = $ProjectDir -replace '\\', '/'
    $confFwd = $ConfPath -replace '\\', '/'
    $sslFwd = $SslDir -replace '\\', '/'

    $dockerOut = & docker run -d --name $containerName `
        -p "${Port}:443" `
        -v "${projFwd}:/usr/share/nginx/html:ro" `
        -v "${confFwd}:/etc/nginx/conf.d/default.conf:ro" `
        -v "${sslFwd}:/etc/nginx/ssl:ro" `
        nginx:1.27-alpine 2>&1

    if ($LASTEXITCODE -ne 0) { throw "Failed to start nginx for $Name : $dockerOut" }

    $url = "https://localhost:$Port"
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        # Check via container itself — avoids self-signed cert issues on host
        $prev3 = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
        & docker exec $containerName wget -q -O /dev/null --no-check-certificate https://127.0.0.1/ *> $null
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prev3
        if ($exitCode -eq 0) {
            Write-Output "  nginx up: $url (HTTPS + HTTP/2)"
            return $containerName
        }
        Start-Sleep -Seconds 1
    }
    throw "nginx not reachable at $url within 30s"
}

function Stop-Container {
    param([string]$ContainerName)
    $prev2 = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    & docker rm -f $ContainerName *> $null
    $ErrorActionPreference = $prev2
}

# ============================================================
#  LIGHTHOUSE AUDIT
# ============================================================

function Invoke-Audit {
    param([string]$Url, [string]$OutDir, [int]$Runs, [string]$Presets)

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $presetList = $Presets -split ','
    $jobs = @(); $meta = @()

    foreach ($bInfo in $availBrowsers) {
        foreach ($preset in $presetList) {
            for ($r = 1; $r -le $Runs; $r++) {
                $base = "lighthouse-${ts}-$($bInfo.Name)-${preset}-run${r}"
                $rp = Join-Path $OutDir "${base}.json"

                $lhArgs = @($Url, '--output=json', '--output=html',
                    "--output-path=$rp", '--quiet',
                    '--chrome-flags=--headless=new --no-sandbox --disable-dev-shm-usage --ignore-certificate-errors',
                    "--chrome-path=$($bInfo.Path)")
                if ($preset -eq 'desktop') { $lhArgs += '--preset=desktop' }

                $useNpx = ($lhCmd -eq 'npx')
                $cmd = $lhCmd

                $job = Start-Job -ScriptBlock {
                    param($c, $npx, $a)
                    if ($npx) { & $c lighthouse @a 2>&1 } else { & $c @a 2>&1 }
                } -ArgumentList $cmd, $useNpx, $lhArgs

                $jobs += $job
                $meta += [pscustomobject]@{
                    Browser = $bInfo.Name; Preset = $preset; Run = $r
                    Job = $job; Path = $rp
                }
            }
        }
    }

    Write-Output "  $($jobs.Count) Lighthouse runs in parallel..."
    $jobs | Wait-Job -Timeout 600 | Out-Null

    $reports = @()
    foreach ($m in $meta) {
        $j = $m.Job
        if ($j.State -ne 'Completed') {
            Write-Output "  [$($m.Browser)/$($m.Preset)] run $($m.Run) FAILED ($($j.State))"
            Receive-Job $j -EA SilentlyContinue | Out-Null
            Remove-Job $j -Force -EA SilentlyContinue; continue
        }
        Receive-Job $j | Out-Null; Remove-Job $j -Force -EA SilentlyContinue

        $jsonPath = $null
        foreach ($c in @($m.Path, ($m.Path -replace '\.json$', '.report.json'))) {
            if (Test-Path $c) { $jsonPath = $c; break }
        }
        $htmlR = $m.Path -replace '\.json$', '.html'
        $htmlPath = $null
        foreach ($c in @($htmlR, ($htmlR -replace '\.html$', '.report.html'))) {
            if (Test-Path $c) { $htmlPath = $c; break }
        }
        if (-not $jsonPath) { continue }

        $data = Get-Content -Raw $jsonPath | ConvertFrom-Json
        $cats = $data.categories; $aud = $data.audits
        $reports += [pscustomobject]@{
            Browser = $m.Browser; Preset = $m.Preset; Run = $m.Run
            Json = $jsonPath; Html = $htmlPath
            Performance   = [math]::Round(($cats.performance.score * 100), 0)
            Accessibility = [math]::Round(($cats.accessibility.score * 100), 0)
            BestPractices = [math]::Round(($cats.'best-practices'.score * 100), 0)
            SEO           = [math]::Round(($cats.seo.score * 100), 0)
            FCP = $aud.'first-contentful-paint'.numericValue
            LCP = $aud.'largest-contentful-paint'.numericValue
            TBT = $aud.'total-blocking-time'.numericValue
            CLS = $aud.'cumulative-layout-shift'.numericValue
            SI  = $aud.'speed-index'.numericValue
        }
        Write-Output "  [$($m.Browser)/$($m.Preset)] run $($m.Run): Perf=$($reports[-1].Performance) A11y=$($reports[-1].Accessibility) BP=$($reports[-1].BestPractices) CLS=$($reports[-1].CLS)"
    }

    return $reports
}

# ============================================================
#  SUMMARY
# ============================================================

function Write-ProjectSummary {
    param($Reports, [string]$OutDir, [string]$Url, [string]$Presets, [string]$Browsers, [int]$Runs)

    $path = Join-Path $OutDir 'lighthouse-summary.md'
    $presetList = $Presets -split ','

    $lines = @("# Lighthouse Summary", '',
        "- URL: $Url", "- Presets: $Presets", "- Browsers: $Browsers",
        "- Runs per combo: $Runs", "- Total runs: $($Reports.Count)",
        "- Server: nginx + gzip (Docker)",
        "- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", '')

    foreach ($preset in $presetList) {
        $lines += "# $($preset.ToUpper())"; $lines += ''
        foreach ($browser in ($Reports | Where-Object { $_.Preset -eq $preset } | Select-Object -ExpandProperty Browser -Unique)) {
            $br = @($Reports | Where-Object { $_.Browser -eq $browser -and $_.Preset -eq $preset })
            $lines += "## $($browser.ToUpper())"; $lines += ''
            $lines += '| Category | Min | Median | Max |'
            $lines += '|----------|-----|--------|-----|'
            foreach ($cat in @('Performance', 'Accessibility', 'BestPractices', 'SEO')) {
                $vals = @($br | ForEach-Object { $_.$cat }) | Sort-Object
                $lines += "| $cat | $($vals[0]) | $($vals[[math]::Floor($vals.Count/2)]) | $($vals[-1]) |"
            }
            $lines += ''; $lines += '### Metrics (avg)'; $lines += ''
            foreach ($m in @('FCP','LCP','TBT','SI')) {
                $avg = [math]::Round(($br | Measure-Object -Property $m -Average).Average, 0)
                $lines += "- ${m}: ${avg} ms"
            }
            $lines += "- CLS: $([math]::Round(($br | Measure-Object -Property CLS -Average).Average, 3))"
            $lines += ''
            foreach ($r in $br) { $lines += "- Run $($r.Run): $($r.Html)" }
            $lines += ''
        }
    }

    $lines | Set-Content -Path $path -Encoding UTF8
    return $path
}

# ============================================================
#  MAIN
# ============================================================

if (-not (Test-Path $ProjectsDir)) {
    New-Item -ItemType Directory -Force -Path $ProjectsDir | Out-Null
    Write-Output "Created projects dir: $ProjectsDir"
    Write-Output "Drop your offer folders there and rerun."
    exit 0
}

# Find projects
$projects = @()
if ($ProjectName) {
    $single = Join-Path $ProjectsDir $ProjectName
    if (Test-Path $single) { $projects += Get-Item $single }
    else { throw "Project not found: $single" }
} else {
    # Check if ProjectsDir itself has index.php (single project mode)
    if (Test-Path (Join-Path $ProjectsDir $HtmlFile)) {
        $projects += Get-Item $ProjectsDir
    } else {
        Get-ChildItem -Path $ProjectsDir -Directory | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName $HtmlFile)) { $projects += $_ }
        }
    }
}

if ($projects.Count -eq 0) {
    Write-Output "No projects with $HtmlFile found in $ProjectsDir"
    Write-Output "Drop offer folders into: $ProjectsDir"
    exit 0
}

New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null

Write-Output ''
Write-Output '================================================================'
Write-Output '  Lighthouse Audit Tool'
Write-Output '================================================================'
Write-Output "Projects:   $($projects.Count)"
Write-Output "Browsers:   $($availBrowsers | ForEach-Object { $_.Name }) "
Write-Output "Presets:    $Presets"
Write-Output "Runs:       $Runs"
Write-Output "Reports:    $ReportsDir"
Write-Output "Server:     nginx:1.27-alpine + gzip + HTTPS/HTTP2 (Docker)"
Write-Output ''
foreach ($p in $projects) { Write-Output "  - $($p.Name)" }
Write-Output ''

$results = @()
$portIdx = 0
$startTime = Get-Date

foreach ($project in $projects) {
    $portIdx++
    $port = $BasePort + $portIdx - 1
    $name = $project.Name
    $projDir = $project.FullName
    $projReports = Join-Path $ReportsDir $name
    $url = "https://localhost:$port"
    $containerName = "lh-audit-${name}"
    $auditHtml = $null

    Write-Output "[$name] port=$port"

    try {
        # 1. Prepare clean HTML
        $auditHtml = New-AuditHtml -ProjectDir $projDir -HtmlFile $HtmlFile -StubsDir $stubsDir
        if ($auditHtml) {
            Write-Output "  prepared .lh.audit.html"
        } else {
            throw "$HtmlFile not found in $projDir"
        }

        # 2. Start nginx (HTTPS + HTTP/2)
        $containerName = Start-NginxContainer -Name $name -ProjectDir $projDir -Port $port -ConfPath $nginxConf -SslDir $sslDir

        # 3. Run Lighthouse
        $reports = Invoke-Audit -Url $url -OutDir $projReports -Runs $Runs -Presets $Presets

        if ($reports.Count -eq 0) { throw 'No successful runs' }

        # 4. Write summary
        $summaryPath = Write-ProjectSummary -Reports $reports -OutDir $projReports `
            -Url $url -Presets $Presets -Browsers $Browsers -Runs $Runs

        $perfVals = @($reports | Where-Object { $_.Preset -eq ($Presets -split ',')[0] } | ForEach-Object { $_.Performance }) | Sort-Object
        $perfMedian = if ($perfVals.Count -gt 0) { $perfVals[[math]::Floor($perfVals.Count/2)] } else { '-' }

        $results += [pscustomobject]@{
            Name = $name; Status = 'OK'; Port = $port
            PerfMedian = $perfMedian; Summary = $summaryPath
        }
        Write-Output "[$name] OK  Perf(median)=$perfMedian"
    }
    catch {
        $results += [pscustomobject]@{
            Name = $name; Status = 'FAIL'; Port = $port
            PerfMedian = '-'; Summary = ''; Error = "$_"
        }
        Write-Output "[$name] FAIL: $_"
    }
    finally {
        Stop-Container $containerName
        if ($auditHtml -and (Test-Path $auditHtml)) {
            Remove-Item $auditHtml -Force -EA SilentlyContinue
        }
        $projStubs = Join-Path $projDir 'lighthouse-stubs'
        if (Test-Path $projStubs) { Remove-Item $projStubs -Recurse -Force -EA SilentlyContinue }
    }
}

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

# Batch summary
$batchSummary = Join-Path $ReportsDir 'batch-summary.md'
$bLines = @()
$bLines += '# Lighthouse Batch Summary'
$bLines += ''
$bLines += "- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$bLines += "- Projects: $($projects.Count)"
$bLines += "- Browsers: $Browsers"
$bLines += "- Presets: $Presets"
$bLines += "- Runs: $Runs"
$bLines += "- Server: nginx + gzip (Docker)"
$bLines += "- Time: ${elapsed}s"
$bLines += ''
$bLines += '| Project | Status | Perf (median) | Summary |'
$bLines += '|---------|--------|---------------|---------|'
foreach ($r in $results) {
    $sumCell = if ($r.Summary) { $r.Summary } else { '-' }
    $bLines += "| $($r.Name) | $($r.Status) | $($r.PerfMedian) | $sumCell |"
}
$bLines | Set-Content -Path $batchSummary -Encoding UTF8

Write-Output ''
Write-Output '================================================================'
Write-Output "  DONE in ${elapsed}s"
Write-Output '================================================================'
Write-Output ''
foreach ($r in $results) {
    $icon = if ($r.Status -eq 'OK') { 'OK' } else { 'FAIL' }
    Write-Output "  $($r.Name): $icon  Perf=$($r.PerfMedian)"
}
Write-Output ''
Write-Output "Reports:  $ReportsDir"
Write-Output "Summary:  $batchSummary"