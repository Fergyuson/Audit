param(
    [string]$ProjectsDir = '',
    [string]$ReportsDir = '',
    [int]$BasePort = 9100,
    [int]$Runs = 1,
    [string]$Browsers = 'chrome',
    [string]$Presets = 'desktop,mobile',
    [string]$HtmlFile = 'index.php',
    [string]$ProjectName = '',
    [switch]$SkipAuditBefore,
    [switch]$SkipAuditAfter,
    [switch]$DryRunFonts,
    [switch]$UseDocker,
    [switch]$AggressiveCssPrune,
    [switch]$AggressiveCssDefer,
    [switch]$AggressiveJsPrune,
    [switch]$AggressiveMobile
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ProjectsDir) { $ProjectsDir = Join-Path $toolDir 'projects' }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $ReportsDir) { $ReportsDir = Join-Path $toolDir "reports\fix-$timestamp" }
$ProjectsDir = [System.IO.Path]::GetFullPath($ProjectsDir)
$ReportsDir = [System.IO.Path]::GetFullPath($ReportsDir)
$nginxConf = Join-Path $toolDir 'docker\nginx.conf'
$sslDir = Join-Path $toolDir 'docker\ssl'
$stubsDir = Join-Path $toolDir 'stubs'
$fontScript = Join-Path $toolDir 'scripts\optimize-fonts.js'

# ============================================================
#  HELPERS
# ============================================================

function Backup-File {
    param([string]$Path)
    # No-op: we no longer keep backups — overwrite in place
}

function Get-Html { param([string]$P); return (Get-Content -Raw -Path $P -Encoding UTF8) }
function Set-Html { param([string]$P, [string]$C); [System.IO.File]::WriteAllText($P, $C, [System.Text.UTF8Encoding]::new($false)) }

function Invoke-Native {
    param([string]$Command, [string[]]$Arguments)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $output = & $Command @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Output = $output; ExitCode = $code }
}

function Ensure-Npm {
    param([string]$Name)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    & node -e "try { require('$Name'); process.exit(0) } catch { process.exit(1) }" 2>$null
    $found = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    if (-not $found) {
        Write-Output "    [npm] Installing $Name..."
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
        & npm install --save-dev $Name *> $null
        $ErrorActionPreference = $prev
    }
}

function To-Fwd { param([string]$P); return ($P -replace '\\', '/') }

function Write-ChangeLog {
    param([string]$Label, [string[]]$Changes, [string]$Dir)
    $logPath = Join-Path $Dir 'fix-changelog.md'
    $block = "## $Label -- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n`r`n"
    foreach ($c in $Changes) { $block += "- $c`r`n" }
    if (Test-Path $logPath) {
        $block = [System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::UTF8).TrimEnd() + "`r`n`r`n" + $block
    } else {
        $block = "# Lighthouse Fix Changelog`r`n`r`n" + $block
    }
    [System.IO.File]::WriteAllText($logPath, $block, [System.Text.UTF8Encoding]::new($false))
}

# ============================================================
#  FIX: FONTS
# ============================================================

function Fix-Fonts {
    param([string]$ProjectDir, [string]$ReportDir)

    if (-not (Test-Path $fontScript)) {
        Write-Output "    [fonts] optimize-fonts.js not found, skip"
        return
    }

    $dryFlag = if ($DryRunFonts) { '--dry-run' } else { '' }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $output = & node $fontScript $ProjectDir $dryFlag "--html=$HtmlFile" 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev

    if ($code -ne 0) {
        Write-Output "    [fonts] ERROR: $output"
        return
    }

    try {
        $result = $output | ConvertFrom-Json
    } catch {
        Write-Output "    [fonts] Failed to parse output"
        return
    }

    $mode = if ($DryRunFonts) { 'DRY-RUN' } else { 'APPLIED' }
    Write-Output "    [fonts] ${mode}: @font-face $($result.fontFacesBefore) -> $($result.fontFacesAfter), files $($result.fontFilesTotal) -> $($result.fontFilesTotal - $result.fontFilesUnused), size $($result.fontFilesSizeBeforeKB)KB -> $($result.fontFilesSizeAfterKB)KB"
    Write-Output "    [fonts] font-display:swap added to $($result.addedFontDisplaySwap) @font-face"

    if ($result.keptCombos.Count -gt 0) {
        Write-Output "    [fonts] Kept: $($result.keptCombos -join ', ')"
    }
    if ($result.errors.Count -gt 0) {
        foreach ($e in $result.errors) { Write-Output "    [fonts] Error: $e" }
    }

    if (-not $DryRunFonts) {
        $changes = @(
            "Removed $($result.fontFacesRemoved) unused @font-face declarations",
            "Deleted $($result.fontFilesUnused) unused font files",
            "Added font-display:swap to $($result.addedFontDisplaySwap) @font-face",
            "Font size: $($result.fontFilesSizeBeforeKB)KB -> $($result.fontFilesSizeAfterKB)KB"
        )
        Write-ChangeLog 'optimize_fonts' $changes $ReportDir
    }
}

# ============================================================
#  FIX: WP JUNK
# ============================================================

function Fix-WpJunk {
    param([string]$HtmlPath, [string]$ProjectDir, [string]$ReportDir)
    Backup-File $HtmlPath
    $html = Get-Html $HtmlPath; $changes = @()
    $regSL = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Singleline'

    # --- Safe mode (always) ---

    # Remove WP emoji script
    $emojiScriptPattern = '<script[^>]*>[\s\S]*?_wpemojiSettings[\s\S]*?</script>'
    $emojiMatch = [regex]::Match($html, $emojiScriptPattern, $regSL)
    if ($emojiMatch.Success) {
        $html = $html.Remove($emojiMatch.Index, $emojiMatch.Length)
        $changes += "removed WP emoji script"
    }

    # Remove WP emoji styles
    $emojiStylePattern = '<style[^>]*id\s*=\s*["'']wp-emoji-styles[^"'']*["''][^>]*>[\s\S]*?</style>'
    $emojiStyleMatch = [regex]::Match($html, $emojiStylePattern, $regSL)
    if ($emojiStyleMatch.Success) {
        $html = $html.Remove($emojiStyleMatch.Index, $emojiStyleMatch.Length)
        $changes += "removed WP emoji styles"
    }

    # Remove WP external meta/feed/API links
    $wpLinkPattern = '<link[^>]*(?:rel\s*=\s*["''](?:alternate|EditURI|wlwmanifest|https://api\.w\.org)[^"'']*["'']|href\s*=\s*["''][^"'']*(?:wp-json|xmlrpc|feed)[^"'']*["''])[^>]*/?\s*>'
    $wpLinkMatches = [regex]::Matches($html, $wpLinkPattern, [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
    $wpLinkCount = 0
    foreach ($m in $wpLinkMatches) { $html = $html.Replace($m.Value, ''); $wpLinkCount++ }
    if ($wpLinkCount -gt 0) { $changes += "removed $wpLinkCount WP meta/feed/API links" }

    # Remove generator meta
    $genPattern = '<meta[^>]*name\s*=\s*["'']generator["''][^>]*>'
    $genMatch = [regex]::Match($html, $genPattern, [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
    if ($genMatch.Success) {
        $html = $html.Replace($genMatch.Value, '')
        $changes += "removed generator meta"
    }

    # Remove dns-prefetch for WP domains
    $dnsPrefetchPattern = '<link[^>]*rel\s*=\s*["'']dns-prefetch["''][^>]*href\s*=\s*["''][^"'']*(?:s\.w\.org|wp\.com)[^"'']*["''][^>]*/?\s*>'
    $dnsMatches = [regex]::Matches($html, $dnsPrefetchPattern, [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
    $dnsCount = 0
    foreach ($m in $dnsMatches) { $html = $html.Replace($m.Value, ''); $dnsCount++ }
    if ($dnsCount -gt 0) { $changes += "removed $dnsCount WP dns-prefetch links" }

    # Google Fonts URL optimization (conservative)
    $gfLinkPattern = '<link[^>]*href\s*=\s*["'']([^"'']*fonts\.googleapis\.com/css[^"'']*)[^"'']*["''][^>]*>'
    $gfMatch = [regex]::Match($html, $gfLinkPattern, [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
    if ($gfMatch.Success) {
        $gfUrl = $gfMatch.Groups[1].Value

        # Parse used font-family names from HTML + CSS
        $usedFamilies = @()
        $ffMatches = [regex]::Matches($html, 'font-family\s*:\s*([^;}"'']+)', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
        foreach ($ffm in $ffMatches) {
            $raw = $ffm.Groups[1].Value
            $parts = $raw -split ','
            foreach ($part in $parts) {
                $clean = $part.Trim().Trim('"').Trim("'").Trim()
                if ($clean -and $clean -notmatch '^(sans-serif|serif|monospace|cursive|fantasy|inherit|initial|unset)$') {
                    $usedFamilies += $clean.ToLower()
                }
            }
        }

        # Also scan local CSS files for font-family usage
        $cssLinkMatches = [regex]::Matches($html, '<link[^>]*href\s*=\s*["'']([^"'']+\.css)["''][^>]*>', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
        foreach ($clm in $cssLinkMatches) {
            $cssRel = $clm.Groups[1].Value
            if ($cssRel -match '^https?://') { continue }
            $cssAbs = Join-Path $ProjectDir $cssRel
            if (Test-Path $cssAbs) {
                $cssContent = Get-Content -Raw -Path $cssAbs -Encoding UTF8
                $cssFfMatches = [regex]::Matches($cssContent, 'font-family\s*:\s*([^;}"'']+)', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
                foreach ($cffm in $cssFfMatches) {
                    $raw = $cffm.Groups[1].Value
                    $parts = $raw -split ','
                    foreach ($part in $parts) {
                        $clean = $part.Trim().Trim('"').Trim("'").Trim()
                        if ($clean -and $clean -notmatch '^(sans-serif|serif|monospace|cursive|fantasy|inherit|initial|unset)$') {
                            $usedFamilies += $clean.ToLower()
                        }
                    }
                }
            }
        }
        $usedFamilies = $usedFamilies | Sort-Object -Unique

        # Parse family parameter from Google Fonts URL
        $familyParam = ''
        if ($gfUrl -match '[?&]family=([^&]+)') { $familyParam = $Matches[1] }

        if ($familyParam) {
            $families = [System.Uri]::UnescapeDataString($familyParam) -split '\|'
            $keptFamilies = @()
            $removedCount = 0
            foreach ($fam in $families) {
                $famName = ($fam -split ':')[0].Trim()
                $famNameLower = $famName.ToLower() -replace '\+', ' '
                if ($usedFamilies -contains $famNameLower) {
                    $keptFamilies += $fam
                } else {
                    $removedCount++
                }
            }
            if ($removedCount -gt 0 -and $keptFamilies.Count -gt 0) {
                $newFamilyParam = $keptFamilies -join '|'
                $newUrl = $gfUrl -replace '([?&]family=)[^&]+', "`$1$newFamilyParam"
                $html = $html.Replace($gfUrl, $newUrl)
                $gfUrl = $newUrl
                $changes += "removed $removedCount unused Google Fonts families"
            }
        }

        # display=swap
        if ($gfUrl -match 'display=auto') {
            $newUrl = $gfUrl -replace 'display=auto', 'display=swap'
            $html = $html.Replace($gfUrl, $newUrl)
            $changes += "Google Fonts display=auto -> display=swap"
        }
    }

    # Preconnect for external font origins
    # First, deduplicate existing preconnect tags (remove all but first occurrence per origin)
    $preconnectOrigins = @('https://fonts.googleapis.com', 'https://fonts.gstatic.com')
    foreach ($origin in $preconnectOrigins) {
        $escapedOrigin = [regex]::Escape($origin)
        # Match preconnect links for this origin (with optional trailing slash, crossorigin variants)
        $pcPattern = "<link[^>]*(?:rel\s*=\s*[`"']preconnect[`"'][^>]*href\s*=\s*[`"']${escapedOrigin}/?[`"']|href\s*=\s*[`"']${escapedOrigin}/?[`"'][^>]*rel\s*=\s*[`"']preconnect[`"'])[^>]*/?\s*>"
        $pcMatches = [regex]::Matches($html, $pcPattern, [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
        # Remove duplicates (keep first, remove rest)
        if ($pcMatches.Count -gt 1) {
            for ($i = 1; $i -lt $pcMatches.Count; $i++) {
                $html = $html.Replace($pcMatches[$i].Value, '')
            }
            $changes += "removed $($pcMatches.Count - 1) duplicate preconnect for $origin"
        }
        # Add if missing entirely
        $isReferenced = [regex]::IsMatch($html, $escapedOrigin, [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
        $hasPreconnect = $pcMatches.Count -gt 0
        if ($isReferenced -and -not $hasPreconnect) {
            $crossorigin = if ($origin -match 'gstatic') { ' crossorigin' } else { '' }
            $preconnectTag = "<link rel=`"preconnect`" href=`"$origin`"$crossorigin>"
            $html = $html -replace '(<head[^>]*>)', "`$1`n$preconnectTag"
            $changes += "preconnect: $origin"
        }
    }

    # fetchpriority="high" on LCP candidate image
    # The first large, non-icon, non-hidden image is likely the LCP element.
    # If it has loading="lazy", remove it (lazy on LCP is harmful).
    $imgTags = [regex]::Matches($html, '<img[^>]*>', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
    $lcpCandidate = $null
    foreach ($imgM in $imgTags) {
        $imgTag = $imgM.Value
        # Skip images with fetchpriority already set
        if ($imgTag -match 'fetchpriority\s*=') { continue }
        # Skip hidden images
        if ($imgTag -match '\shidden[\s>]') { continue }
        # Skip SVGs and icon-like images
        $srcM = [regex]::Match($imgTag, 'src\s*=\s*["'']([^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
        if ($srcM.Success) {
            $imgSrc = $srcM.Groups[1].Value
            if ($imgSrc -match '\.svg($|\?)') { continue }
            $imgFilename = [System.IO.Path]::GetFileNameWithoutExtension($imgSrc).ToLower()
            if ($imgFilename -match 'icon|logo|favicon') { continue }
        }
        # Parse width and height
        $imgW = 0; $imgH = 0
        $wM = [regex]::Match($imgTag, 'width\s*=\s*["''](\d+)["'']', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
        $hM = [regex]::Match($imgTag, 'height\s*=\s*["''](\d+)["'']', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
        if ($wM.Success) { $imgW = [int]$wM.Groups[1].Value }
        if ($hM.Success) { $imgH = [int]$hM.Groups[1].Value }
        # Skip small images (width or height < 100)
        if (($imgW -gt 0 -and $imgW -lt 100) -or ($imgH -gt 0 -and $imgH -lt 100)) { continue }
        # Pick first with dimensions >= 200
        if ($imgW -ge 200 -and $imgH -ge 200) {
            $lcpCandidate = $imgTag
            break
        }
    }
    if ($lcpCandidate) {
        $newTag = $lcpCandidate
        # Remove loading="lazy" from LCP candidate (lazy on LCP is harmful)
        if ($newTag -match 'loading\s*=\s*["'']lazy["'']') {
            $newTag = $newTag -replace '\s*loading\s*=\s*["'']lazy["'']', ''
            $changes += "removed loading=lazy from LCP candidate"
        }
        $newTag = $newTag -replace '<img', '<img fetchpriority="high"'
        $html = $html.Replace($lcpCandidate, $newTag)
        $changes += "fetchpriority=high on LCP candidate"
    }

    # --- Aggressive mode (behind -AggressiveJsPrune or -AggressiveMobile) ---
    if ($AggressiveJsPrune -or $AggressiveMobile) {
        $jqMigratePattern = '<script[^>]*src\s*=\s*["''][^"'']*jquery-migrate[^"'']*["''][^>]*>\s*</script>'
        $jqmMatch = [regex]::Match($html, $jqMigratePattern, [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
        if ($jqmMatch.Success) {
            $html = $html.Replace($jqmMatch.Value, '')
            $changes += "removed jquery-migrate (aggressive)"
        }
    }

    Set-Html $HtmlPath $html
    if ($changes.Count -gt 0) { Write-ChangeLog 'fix_wp_junk' $changes $ReportDir }
    Write-Output "    [wp-junk] $($changes.Count) changes"
}

# ============================================================
#  FIX: GIFS -> MP4
# ============================================================

function Fix-Gifs {
    param([string]$HtmlPath, [string]$ProjectDir, [string]$ReportDir)

    # Check for ffmpeg and ffprobe
    $ffmpegCmd = Get-Command ffmpeg -EA SilentlyContinue
    $ffprobeCmd = Get-Command ffprobe -EA SilentlyContinue
    $useDockerFallback = $false

    if (-not $ffmpegCmd -or -not $ffprobeCmd) {
        if ($UseDocker) {
            $useDockerFallback = $true
            Write-Output "    [gifs] ffmpeg not found, using Docker fallback"
        } else {
            Write-Output "    [gifs] SKIP: ffmpeg not found; pass -UseDocker to enable Docker fallback"
            return
        }
    } else {
        Write-Output "    [gifs] ffmpeg found: $($ffmpegCmd.Source)"
    }

    Backup-File $HtmlPath
    $html = Get-Html $HtmlPath; $changes = @()

    $gifMatches = [regex]::Matches($html, '<img[^>]*src=["'']([^"'']*\.gif)["''][^>]*>', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
    $gifIdx = 0
    foreach ($m in $gifMatches) {
        $tag = $m.Value
        $gifSrc = $m.Groups[1].Value
        if ($gifSrc -match '^https?://') { continue }

        $absGif = Join-Path $ProjectDir $gifSrc
        if (-not (Test-Path $absGif)) { continue }

        # Count frames with ffprobe
        $frameCount = 0
        if ($useDockerFallback) {
            $fwd = To-Fwd $ProjectDir
            $relGif = $gifSrc -replace '\\', '/'
            $r = Invoke-Native 'docker' @('run', '--rm', '-v', "${fwd}:/work", 'jrottenberg/ffmpeg:5-alpine',
                '-v', 'error', '-count_frames', '-select_streams', 'v:0',
                '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0', "/work/$relGif")
            if ($r.ExitCode -eq 0) { $frameCount = [int]("$($r.Output)".Trim()) }
        } else {
            $r = Invoke-Native 'ffprobe' @('-v', 'error', '-count_frames', '-select_streams', 'v:0',
                '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0', $absGif)
            if ($r.ExitCode -eq 0) { $frameCount = [int]("$($r.Output)".Trim()) }
        }

        # Static GIF (1 frame) -- skip, Fix-Images handles WebP conversion
        if ($frameCount -le 1) { continue }

        # Animated GIF -> MP4
        $mp4Src = [System.IO.Path]::ChangeExtension($gifSrc, '.mp4')
        $absMp4 = [System.IO.Path]::ChangeExtension($absGif, '.mp4')

        Backup-File $absGif

        if ($useDockerFallback) {
            $fwd = To-Fwd $ProjectDir
            $relGif = $gifSrc -replace '\\', '/'
            $relMp4 = $mp4Src -replace '\\', '/'
            $r = Invoke-Native 'docker' @('run', '--rm', '-v', "${fwd}:/work", 'jrottenberg/ffmpeg:5-alpine',
                '-i', "/work/$relGif", '-movflags', 'faststart', '-pix_fmt', 'yuv420p',
                '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2', '-an', "/work/$relMp4")
        } else {
            $r = Invoke-Native 'ffmpeg' @('-i', $absGif, '-movflags', 'faststart', '-pix_fmt', 'yuv420p',
                '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2', '-an', $absMp4)
        }

        if ($r.ExitCode -ne 0) {
            Write-Output "    [gifs] WARN: ffmpeg failed for $gifSrc"
            continue
        }

        # Parse width/height/class from original img tag
        $wAttr = ''; $hAttr = ''; $classAttr = ''
        $wM = [regex]::Match($tag, 'width\s*=\s*["'']([^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
        $hM = [regex]::Match($tag, 'height\s*=\s*["'']([^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
        $cM = [regex]::Match($tag, 'class\s*=\s*["'']([^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
        if ($wM.Success) { $wAttr = " width=`"$($wM.Groups[1].Value)`"" }
        if ($hM.Success) { $hAttr = " height=`"$($hM.Groups[1].Value)`"" }
        if ($cM.Success) { $classAttr = " class=`"$($cM.Groups[1].Value)`"" }

        $lazyAttr = ''
        if ($gifIdx -gt 0) { $lazyAttr = ' loading="lazy"' }

        $videoTag = "<video autoplay loop muted playsinline data-lh-decorative${wAttr}${hAttr}${classAttr}${lazyAttr}>`n  <source src=`"$mp4Src`" type=`"video/mp4`">`n</video>"
        $html = $html.Replace($tag, $videoTag)
        $changes += "GIF->MP4: $gifSrc ($frameCount frames)"
        $gifIdx++
    }

    Set-Html $HtmlPath $html
    if ($changes.Count -gt 0) { Write-ChangeLog 'fix_gifs' $changes $ReportDir }
    Write-Output "    [gifs] $($changes.Count) changes"
}

# ============================================================
#  FIX: META / SEO
# ============================================================

function Fix-Meta {
    param([string]$HtmlPath, [string]$ReportDir)
    $html = Get-Html $HtmlPath; $changes = @()

    $langM = [regex]::Match($html, '<input[^>]*name=[''"]language[''"][^>]*value=[''"]([^''"]+)[''"]', 'IgnoreCase')
    $lang = if ($langM.Success) { $langM.Groups[1].Value.ToLower() } else { 'en' }
    if ($html -notmatch '<html[^>]*\slang=') {
        $html = $html -replace '<html', "<html lang=`"$lang`""
        $changes += "lang=`"$lang`""
    }

    if ($html -notmatch '<meta\s+name=[''"]description[''"]') {
        $t = [regex]::Match($html, '<title>([^<]+)</title>', 'IgnoreCase')
        $h = [regex]::Match($html, '<h2[^>]*>([^<]+)</h2>', 'IgnoreCase')
        $desc = ''
        if ($t.Success) { $desc = $t.Groups[1].Value.Trim() }
        if ($h.Success) { $desc = if ($desc) { "$desc -- $($h.Groups[1].Value.Trim())" } else { $h.Groups[1].Value.Trim() } }
        if (-not $desc) { $desc = 'Product landing page' }
        if ($desc.Length -gt 160) { $desc = $desc.Substring(0, 157) + '...' }
        $html = $html -replace '(</head>)', "<meta name=`"description`" content=`"$desc`">`n`$1"
        $changes += "meta description"
    }

    if ($html -notmatch '<meta\s+name=[''"]theme-color[''"]') {
        $bg = [regex]::Match($html, 'body\s*\{[^}]*background(?:-color)?\s*:\s*(#[0-9a-fA-F]{3,8})', 'IgnoreCase')
        $color = if ($bg.Success) { $bg.Groups[1].Value } else { '#000000' }
        $html = $html -replace '(</head>)', "<meta name=`"theme-color`" content=`"$color`">`n`$1"
        $changes += "theme-color: $color"
    }

    # viewport (critical for mobile)
    if ($html -notmatch '<meta\s+name=[''"]viewport[''"]') {
        $html = $html -replace '(<meta\s+charset=[^>]+>)', "`$1`n<meta name=`"viewport`" content=`"width=device-width, initial-scale=1`">"
        $changes += "viewport meta"
    }

    Set-Html $HtmlPath $html
    if ($changes.Count -gt 0) { Write-ChangeLog 'inject_meta' $changes $ReportDir }
    Write-Output "    [meta] $($changes.Count) changes"
}

# ============================================================
#  FIX: A11Y
# ============================================================

function Fix-A11y {
    param([string]$HtmlPath, [string]$ReportDir, [string]$JsonPath)
    $html = Get-Html $HtmlPath; $changes = @()

    # img alt
    $noAlt = [regex]::Matches($html, '<img(?![^>]*\salt=)[^>]*>', 'IgnoreCase')
    $c = 0
    foreach ($m in $noAlt) {
        $tag = $m.Value
        $s = [regex]::Match($tag, 'src=[''"]([^''"]+)[''"]', 'IgnoreCase')
        $alt = if ($s.Success) { ([System.IO.Path]::GetFileNameWithoutExtension($s.Groups[1].Value) -replace '[-_]',' ').Trim() } else { 'image' }
        $html = $html.Replace($tag, ($tag -replace '<img', "<img alt=`"$alt`"")); $c++
    }
    if ($c -gt 0) { $changes += "alt on $c <img>" }

    # video controls (skip decorative videos: converted GIFs with autoplay+muted+loop or data-lh-decorative)
    $allNoCtrl = [regex]::Matches($html, '<video(?![^>]*\scontrols)[^>]*>', 'IgnoreCase')
    $c = 0
    foreach ($m in $allNoCtrl) {
        $tag = $m.Value
        if ($tag -match 'data-lh-decorative') { continue }
        if ($tag -match 'autoplay' -and $tag -match 'muted' -and $tag -match 'loop') { continue }
        $html = $html.Replace($tag, ($tag -replace '<video', '<video controls')); $c++
    }
    if ($c -gt 0) { $changes += "controls on $c <video>" }

    # input aria-label
    $noLabel = [regex]::Matches($html, '<input(?![^>]*\saria-label)[^>]*type=[''"](?:text|tel|email|number|password)[''"][^>]*>', 'IgnoreCase')
    $c = 0
    foreach ($m in $noLabel) {
        $tag = $m.Value; if ($tag -match 'aria-label') { continue }
        $ph = [regex]::Match($tag, 'placeholder=[''"]([^''"]+)[''"]', 'IgnoreCase')
        $nm = [regex]::Match($tag, 'name=[''"]([^''"]+)[''"]', 'IgnoreCase')
        $lbl = if ($ph.Success) { $ph.Groups[1].Value } elseif ($nm.Success) { $nm.Groups[1].Value -replace '[-_]',' ' } else { 'input field' }
        $html = $html.Replace($tag, ($tag -replace '<input', "<input aria-label=`"$lbl`"")); $c++
    }
    if ($c -gt 0) { $changes += "aria-label on $c <input>" }

    # mobile-friendly CSS (touch targets, font size, tap spacing)
    if ($html -notmatch 'lighthouse-fix: mobile') {
        $mobileCss = @"

/* lighthouse-fix: mobile touch targets + readability */
a, button, input[type="submit"], input[type="button"], select,
input[type="text"], input[type="tel"], input[type="email"] {
  min-height: 48px; min-width: 48px;
}
/* tap target spacing */
a, button, [role="button"] { margin-bottom: 8px; }
/* minimum readable font size for mobile */
@media (max-width: 768px) {
  body { font-size: max(1em, 16px); -webkit-text-size-adjust: 100%; }
  p, li, td, th, label, span, div { font-size: max(inherit, 12px); }
  input, select, textarea { font-size: 16px; }
}

"@
        $html = $html -replace '(</style>)', "$mobileCss`$1"
        $changes += "mobile CSS (touch targets, font size, tap spacing)"
    }

    # button type
    $noType = [regex]::Matches($html, '<button(?![^>]*\stype=)[^>]*>', 'IgnoreCase')
    $c = 0; foreach ($m in $noType) { $html = $html.Replace($m.Value, ($m.Value -replace '<button', '<button type="button"')); $c++ }
    if ($c -gt 0) { $changes += "type on $c <button>" }

    Set-Html $HtmlPath $html
    if ($changes.Count -gt 0) { Write-ChangeLog 'fix_a11y' $changes $ReportDir }
    Write-Output "    [a11y] $($changes.Count) changes"
}

# ============================================================
#  FIX: IMAGES
# ============================================================

function Fix-Images {
    param([string]$HtmlPath, [string]$ProjectDir, [string]$ReportDir, [int]$WebpQ = 80, [int]$MaxW = 824)

    Ensure-Npm 'sharp'
    Backup-File $HtmlPath
    $html = Get-Html $HtmlPath; $changes = @()

    $imgs = [regex]::Matches($html, '<img[^>]*src=[''"]([^''"]+)[''"][^>]*>', 'IgnoreCase')
    $idx = 0
    foreach ($m in $imgs) {
        $tag = $m.Value; $src = $m.Groups[1].Value; $idx++
        if ($src -match '^(https?://|data:|\.svg$)' -or $src.EndsWith('.svg')) { continue }
        $absPath = Join-Path $ProjectDir $src
        if (-not (Test-Path $absPath)) { continue }
        $ext = [System.IO.Path]::GetExtension($src).ToLower()
        $fwd = To-Fwd $absPath

        # WebP
        $webpSrc = $null
        if ($ext -in @('.png','.jpg','.jpeg')) {
            $wpAbs = [System.IO.Path]::ChangeExtension($absPath, '.webp')
            $wpRel = [System.IO.Path]::ChangeExtension($src, '.webp')
            $wpFwd = To-Fwd $wpAbs
            if (-not (Test-Path $wpAbs)) {
                $nodeJs = "const s=require('sharp');s('$fwd').webp({quality:$WebpQ}).toFile('$wpFwd').then(()=>console.log('ok')).catch(e=>{console.error(e.message);process.exit(1)})"
                $r = Invoke-Native 'node' @('-e', $nodeJs)
                if ($r.ExitCode -eq 0) { $webpSrc = $wpRel; $changes += "WebP: $src" }
            } else { $webpSrc = $wpRel }
        }

        # dimensions
        $w = 0; $h = 0
        $nodeJs = "const s=require('sharp');s('$fwd').metadata().then(m=>console.log(m.width+'x'+m.height)).catch(e=>{console.error(e.message);process.exit(1)})"
        $r = Invoke-Native 'node' @('-e', $nodeJs)
        if ($r.ExitCode -eq 0 -and "$($r.Output)" -match '(\d+)x(\d+)') { $w = [int]$Matches[1]; $h = [int]$Matches[2] }

        # resize
        if ($w -gt $MaxW) {
            $nh = [math]::Round($h * ($MaxW / $w))
            $tmpFwd = $fwd + '.tmp'
            $nodeJs = "const s=require('sharp');const fs=require('fs');s('$fwd').resize($MaxW,$nh).toFile('$tmpFwd').then(()=>{fs.renameSync('$tmpFwd','$fwd');console.log('ok')}).catch(e=>{console.error(e.message);process.exit(1)})"
            $r = Invoke-Native 'node' @('-e', $nodeJs)
            if ($r.ExitCode -eq 0) {
                $changes += "Resize $src ${w}x${h} -> ${MaxW}x${nh}"
                $w = $MaxW; $h = $nh
                if ($webpSrc) {
                    $nodeJs = "const s=require('sharp');s('$fwd').webp({quality:$WebpQ}).toFile('$wpFwd').then(()=>console.log('ok')).catch(e=>{console.error(e.message);process.exit(1)})"
                    Invoke-Native 'node' @('-e', $nodeJs) | Out-Null
                }
            }
        }

        # build new tag
        $nt = $tag
        if ($w -gt 0 -and $h -gt 0) {
            if ($nt -notmatch '\swidth=') { $nt = $nt -replace '<img', "<img width=`"$w`"" }
            if ($nt -notmatch '\sheight=') { $nt = $nt -replace '<img', "<img height=`"$h`"" }
        }
        if ($idx -gt 1 -and $nt -notmatch '\sloading=') { $nt = $nt -replace '<img', '<img loading="lazy"' }

        if ($webpSrc) {
            $escapedWebp = [regex]::Escape($webpSrc)
            if ($html -notmatch "<picture>\s*<source[^>]*$escapedWebp") {
                $html = $html.Replace($tag, "<picture><source srcset=`"$webpSrc`" type=`"image/webp`">$nt</picture>")
            } else { $html = $html.Replace($tag, $nt) }
        } else { $html = $html.Replace($tag, $nt) }
    }

    Set-Html $HtmlPath $html
    if ($changes.Count -gt 0) { Write-ChangeLog 'optimize_images' $changes $ReportDir }
    Write-Output "    [images] $($changes.Count) changes"
}

# ============================================================
#  FIX: ASSETS (CSS/JS minify, defer)
# ============================================================

function Fix-Assets {
    param([string]$HtmlPath, [string]$ProjectDir, [string]$ReportDir)

    Ensure-Npm 'clean-css-cli'; Ensure-Npm 'terser'
    Backup-File $HtmlPath
    $html = Get-Html $HtmlPath; $changes = @()

    # Minify CSS
    $cssLinks = [regex]::Matches($html, '<link[^>]*href=[''"]([^''"]+\.css)[''"][^>]*>', 'IgnoreCase')
    foreach ($m in $cssLinks) {
        $rel = $m.Groups[1].Value; if ($rel -match '^https?://') { continue }
        $absF = Join-Path $ProjectDir $rel; if (-not (Test-Path $absF)) { continue }
        Backup-File $absF
        if ((Get-Content $absF).Count -lt 10) { continue }
        $minF = "${absF}.min.tmp"
        $r = Invoke-Native 'npx' @('cleancss', '-o', $minF, $absF)
        if ($r.ExitCode -eq 0 -and (Test-Path $minF)) {
            $sav = [math]::Round((1 - (Get-Item $minF).Length / (Get-Item $absF).Length) * 100, 1)
            Move-Item $minF $absF -Force; $changes += "Minify CSS $rel (${sav}%)"
        } else { Remove-Item $minF -EA SilentlyContinue }
    }

    # Minify JS
    $jsTags = [regex]::Matches($html, '<script[^>]*src=[''"]([^''"]+\.js)[''"][^>]*>', 'IgnoreCase')
    foreach ($m in $jsTags) {
        $s = $m.Groups[1].Value
        if ($s -match '^https?://' -or $s -match '\.min\.js$' -or $s -match 'counter|first\.min') { continue }
        $absF = Join-Path $ProjectDir $s; if (-not (Test-Path $absF)) { continue }
        Backup-File $absF
        $minF = "${absF}.min.tmp"
        $r = Invoke-Native 'npx' @('terser', $absF, '-o', $minF, '--compress', '--mangle')
        if ($r.ExitCode -eq 0 -and (Test-Path $minF)) {
            $sav = [math]::Round((1 - (Get-Item $minF).Length / (Get-Item $absF).Length) * 100, 1)
            Move-Item $minF $absF -Force; $changes += "Minify JS $s (${sav}%)"
        } else { Remove-Item $minF -EA SilentlyContinue }
    }

    # defer
    $scriptTags = [regex]::Matches($html, '<script[^>]*src=[''"][^''"]+[''"][^>]*>', 'IgnoreCase')
    $dc = 0
    foreach ($m in $scriptTags) {
        $tag = $m.Value
        if ($tag -match '\s(defer|async)[\s>]' -or $tag -match 'type=[''"]module[''"]' -or $tag -match 'counter|first\.min|showcases|mask') { continue }
        $html = $html.Replace($tag, ($tag -replace '<script', '<script defer')); $dc++
    }
    if ($dc -gt 0) { $changes += "defer on $dc <script>" }

    Set-Html $HtmlPath $html
    if ($changes.Count -gt 0) { Write-ChangeLog 'optimize_assets' $changes $ReportDir }
    Write-Output "    [assets] $($changes.Count) changes"
}

# ============================================================
#  FIX: UNUSED CSS (aggressive only)
# ============================================================

function Fix-UnusedCss {
    param([string]$HtmlPath, [string]$ProjectDir, [string]$ReportDir)

    Ensure-Npm 'purgecss'
    Backup-File $HtmlPath
    $html = Get-Html $HtmlPath; $changes = @()

    $cssLinks = [regex]::Matches($html, '<link[^>]*rel=[''"]stylesheet[''"][^>]*href=[''"]([^''"]+\.css)[''"]', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')
    foreach ($m in $cssLinks) {
        $rel = $m.Groups[1].Value
        if ($rel -match '^https?://') { continue }
        $absF = Join-Path $ProjectDir $rel
        if (-not (Test-Path $absF)) { continue }

        Backup-File $absF
        $beforeSize = (Get-Item $absF).Length

        $cssFwd = To-Fwd $absF
        $htmlFwd = To-Fwd $HtmlPath

        $nodeScript = @"
const { PurgeCSS } = require('purgecss');
(async () => {
    const result = await new PurgeCSS().purge({
        content: ['$htmlFwd'],
        css: ['$cssFwd'],
        safelist: {
            greedy: [
                /^elementor-/, /^e-/, /^wp-/, /^swiper-/, /^fa-/, /^eicon-/, /^jet-/,
                /^dialog/, /^flatpickr/, /^animated$/, /^fade/, /^slide/, /^bounce/,
                /^active$/, /^open$/, /^show$/, /^current$/, /^visible$/, /^hidden$/, /^is-/, /^has-/,
                /^screen-reader-text$/
            ]
        }
    });
    if (result.length > 0) {
        require('fs').writeFileSync('$cssFwd', result[0].css, 'utf8');
    }
})();
"@
        $r = Invoke-Native 'node' @('-e', $nodeScript)
        if ($r.ExitCode -eq 0) {
            $afterSize = (Get-Item $absF).Length
            $savPct = if ($beforeSize -gt 0) { [math]::Round((1 - $afterSize / $beforeSize) * 100, 1) } else { 0 }
            $changes += "PurgeCSS $rel ${beforeSize}B -> ${afterSize}B (${savPct}%)"
        } else {
            Write-Output "    [unused-css] WARN: PurgeCSS failed for $rel"
        }
    }

    if ($changes.Count -gt 0) { Write-ChangeLog 'fix_unused_css' $changes $ReportDir }
    Write-Output "    [unused-css] $($changes.Count) changes"
}

# ============================================================
#  FIX: CSS DEFER (aggressive only)
# ============================================================

function Fix-CssDefer {
    param([string]$HtmlPath, [string]$ReportDir)

    Backup-File $HtmlPath
    $html = Get-Html $HtmlPath; $changes = @()

    $cssLinkPattern = '<link[^>]*rel=[''"]stylesheet[''"][^>]*href=[''"]([^''"]+\.css)[''"][^>]*>'
    $cssLinks = [regex]::Matches($html, $cssLinkPattern, [System.Text.RegularExpressions.RegexOptions]'IgnoreCase')

    if ($cssLinks.Count -eq 0) {
        Write-Output "    [css-defer] no stylesheet links found"
        return
    }

    # Determine critical CSS by filename patterns
    $criticalPatterns = @('elementor', 'frontend', 'theme', 'style', 'post-')
    $criticalLinks = @()
    $nonCriticalLinks = @()

    foreach ($m in $cssLinks) {
        $href = $m.Groups[1].Value
        $isCritical = $false
        foreach ($pat in $criticalPatterns) {
            if ($href -match [regex]::Escape($pat)) { $isCritical = $true; break }
        }
        if ($isCritical) {
            $criticalLinks += $m
        } else {
            $nonCriticalLinks += $m
        }
    }

    # Fallback: if no pattern matches, keep first 3 by document order
    if ($criticalLinks.Count -eq 0) {
        $allLinks = @($cssLinks | ForEach-Object { $_ })
        $criticalLinks = @($allLinks | Select-Object -First 3)
        $nonCriticalLinks = @($allLinks | Select-Object -Skip 3)
    }

    $deferCount = 0
    foreach ($m in $nonCriticalLinks) {
        $tag = $m.Value
        $href = $m.Groups[1].Value
        $preloadTag = "<link rel=`"preload`" href=`"$href`" as=`"style`" onload=`"this.onload=null;this.rel='stylesheet'`">`n<noscript><link rel=`"stylesheet`" href=`"$href`"></noscript>"
        $html = $html.Replace($tag, $preloadTag)
        $deferCount++
    }

    if ($deferCount -gt 0) { $changes += "deferred $deferCount non-critical stylesheets" }

    Set-Html $HtmlPath $html
    if ($changes.Count -gt 0) { Write-ChangeLog 'fix_css_defer' $changes $ReportDir }
    Write-Output "    [css-defer] $deferCount deferred"
}

# ============================================================
#  AUDIT (reuse from audit.ps1)
# ============================================================

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

function New-AuditHtml {
    param([string]$ProjectDir, [string]$File, [string]$StubsDir)
    $srcPath = Join-Path $ProjectDir $File
    if (-not (Test-Path $srcPath)) { return $null }
    $content = Get-Content -Raw -Path $srcPath -Encoding UTF8
    $regOpts = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Singleline'
    $content = [regex]::Replace($content, '<\?=\s*\$\w*[Jj]son\s*\?>', '{}', $regOpts)
    $content = [regex]::Replace($content, '<\?.*?\?>', '', $regOpts)
    $fileMap = @{
        '{_from_file:showcases_v2_file_path}'             = '/lighthouse-stubs/showcases_v2.module.js'
        '{_from_file:universal_widget_combined_file_path}' = '/lighthouse-stubs/universal_widget_combined.module.js'
        '{_from_file:form_mask_file_path}'                = '/lighthouse-stubs/form_mask.module.js'
        '{_from_file:showcases_v2_api_link}'              = '/lighthouse-stubs/showcases_v2_api.json'
    }
    foreach ($key in $fileMap.Keys) { $content = $content.Replace($key, $fileMap[$key]) }
    $tokenMap = @{
        '{subid}' = 'subid_local'; '{_subid}' = 'subid_local'; '{pixid}' = 'pixid_local'
        '{_token}' = 'token_local'; '{_offer_id}' = 'offer_local'; '{offer_id}' = 'offer_local'
        '{_campaign_name}' = 'campaign_local'; '{_campaign_id}' = 'campaign_local'
        '{_country}' = 'PE'; '{country}' = 'PE'
        '{ymc}' = 'ymc_local'; '{gua}' = 'gua_local'; '{tpixid}' = 'tpixid_local'
    }
    foreach ($key in $tokenMap.Keys) { $content = $content.Replace($key, $tokenMap[$key]) }
    $content = $content.Replace('../../lander/mv/counters/first.min.js', '/lighthouse-stubs/first.min.js')
    $projStubs = Join-Path $ProjectDir 'lighthouse-stubs'
    if (-not (Test-Path $projStubs)) { Copy-Item -Path $StubsDir -Destination $projStubs -Recurse -Force }
    $outPath = Join-Path $ProjectDir '.lh.audit.html'
    [System.IO.File]::WriteAllText($outPath, $content, [System.Text.UTF8Encoding]::new($false))
    return $outPath
}

function Start-NginxContainer {
    param([string]$Name, [string]$ProjectDir, [int]$Port, [string]$ConfPath, [string]$SslDir)
    $containerName = "lh-fix-${Name}"
    # Clean up any leftover lighthouse containers on this port (e.g. from interrupted audit.ps1)
    $p2 = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    & docker rm -f $containerName *> $null
    $stale = & docker ps -a --filter "publish=$Port" --format '{{.Names}}' 2>$null
    if ($stale) { foreach ($s in $stale) { & docker rm -f $s *> $null } }
    $ErrorActionPreference = $p2
    $projFwd = $ProjectDir -replace '\\', '/'
    $confFwd = $ConfPath -replace '\\', '/'
    $sslFwd = $SslDir -replace '\\', '/'
    $p2 = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $runOutput = & docker run -d --name $containerName -p "${Port}:443" `
        -v "${projFwd}:/usr/share/nginx/html:ro" `
        -v "${confFwd}:/etc/nginx/conf.d/default.conf:ro" `
        -v "${sslFwd}:/etc/nginx/ssl:ro" `
        nginx:1.27-alpine 2>&1
    $runExitCode = $LASTEXITCODE
    $ErrorActionPreference = $p2
    if ($runExitCode -ne 0) {
        throw "docker run failed (exit=$runExitCode): $($runOutput | Out-String)"
    }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $p2 = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
        & docker exec $containerName wget -q -O /dev/null --no-check-certificate https://127.0.0.1/ *> $null
        $ok = ($LASTEXITCODE -eq 0); $ErrorActionPreference = $p2
        if ($ok) { return $containerName }
        Start-Sleep -Seconds 1
    }
    # Dump container logs for debugging
    $p2 = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $logs = & docker logs $containerName 2>&1 | Out-String
    $state = & docker inspect --format '{{.State.Status}}' $containerName 2>&1 | Out-String
    $ErrorActionPreference = $p2
    throw "nginx not reachable within 30s (state: $($state.Trim()), logs: $($logs.Trim()))"
}

function Stop-Container {
    param([string]$Name)
    $p2 = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    & docker rm -f $Name *> $null; $ErrorActionPreference = $p2
}

function Invoke-QuickAudit {
    param([string]$Url, [string]$OutDir, [int]$Runs, [string]$Presets, [string]$Browsers)
    $lhCmd = Get-LighthouseCmd
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $browserList = $Browsers -split ','
    $presetList = $Presets -split ','
    $jobs = @(); $meta = @()
    foreach ($b in $browserList) {
        $bp = Get-BrowserPath $b; if (-not $bp) { continue }
        foreach ($preset in $presetList) {
            for ($r = 1; $r -le $Runs; $r++) {
                $rp = Join-Path $OutDir "lighthouse-${ts}-${b}-${preset}-run${r}.json"
                $lhArgs = @($Url, '--output=json', '--output=html', "--output-path=$rp", '--quiet',
                    '--chrome-flags=--headless=new --no-sandbox --disable-dev-shm-usage --ignore-certificate-errors',
                    "--chrome-path=$bp")
                if ($preset -eq 'desktop') { $lhArgs += '--preset=desktop' }
                $useNpx = ($lhCmd -eq 'npx'); $cmd = $lhCmd
                $job = Start-Job -ScriptBlock {
                    param($c, $npx, $a)
                    if ($npx) { & $c lighthouse @a 2>&1 } else { & $c @a 2>&1 }
                } -ArgumentList $cmd, $useNpx, $lhArgs
                $jobs += $job
                $meta += [pscustomobject]@{ Browser = $b; Preset = $preset; Run = $r; Job = $job; Path = $rp }
            }
        }
    }
    if ($jobs.Count -eq 0) { return @() }
    $jobs | Wait-Job -Timeout 600 | Out-Null
    $reports = @()
    foreach ($m in $meta) {
        $j = $m.Job
        if ($j.State -ne 'Completed') { Receive-Job $j -EA SilentlyContinue | Out-Null; Remove-Job $j -Force -EA SilentlyContinue; continue }
        Receive-Job $j | Out-Null; Remove-Job $j -Force -EA SilentlyContinue
        $jsonPath = $null
        foreach ($c in @($m.Path, ($m.Path -replace '\.json$', '.report.json'))) { if (Test-Path $c) { $jsonPath = $c; break } }
        if (-not $jsonPath) { continue }
        $data = Get-Content -Raw $jsonPath | ConvertFrom-Json
        $cats = $data.categories; $aud = $data.audits
        $reports += [pscustomobject]@{
            Browser = $m.Browser; Preset = $m.Preset; Run = $m.Run; Json = $jsonPath
            Performance   = [math]::Round(($cats.performance.score * 100), 0)
            Accessibility = [math]::Round(($cats.accessibility.score * 100), 0)
            BestPractices = [math]::Round(($cats.'best-practices'.score * 100), 0)
            SEO           = [math]::Round(($cats.seo.score * 100), 0)
            FCP = $aud.'first-contentful-paint'.numericValue
            LCP = $aud.'largest-contentful-paint'.numericValue
            CLS = $aud.'cumulative-layout-shift'.numericValue
        }
    }
    return $reports
}

# ============================================================
#  DIFF REPORT
# ============================================================

function New-DiffReport {
    param($Before, $After, [string]$OutDir)
    $path = Join-Path $OutDir 'diff-report.md'
    $lines = @('# Fix Diff Report', '', "- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", '')
    $lines += '| Metric | Before | After | Delta |'; $lines += '|--------|--------|-------|-------|'
    foreach ($cat in @('Performance','Accessibility','BestPractices','SEO')) {
        $bv = [math]::Round(($Before | Measure-Object -Property $cat -Average).Average, 0)
        $av = [math]::Round(($After | Measure-Object -Property $cat -Average).Average, 0)
        $d = $av - $bv; $ds = if ($d -gt 0) { "+$d" } else { "$d" }
        $lines += "| $cat | $bv | $av | $ds |"
    }
    foreach ($m in @('FCP','LCP','CLS')) {
        $bv = [math]::Round(($Before | Measure-Object -Property $m -Average).Average, $(if ($m -eq 'CLS') { 3 } else { 0 }))
        $av = [math]::Round(($After | Measure-Object -Property $m -Average).Average, $(if ($m -eq 'CLS') { 3 } else { 0 }))
        $unit = if ($m -eq 'CLS') { '' } else { ' ms' }
        $lines += "| $m | ${bv}${unit} | ${av}${unit} | |"
    }
    $lines | Set-Content -Path $path -Encoding UTF8
    Write-Output "    [diff] $path"
}

# ============================================================
#  MAIN
# ============================================================

$prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
& docker info *> $null; $dockerOk = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prev
if (-not $dockerOk) { Write-Output 'ERROR: Docker is not running.'; exit 1 }

if (-not (Test-Path $ProjectsDir)) { throw "Projects dir not found: $ProjectsDir" }

$projects = @()
if ($ProjectName) {
    $single = Join-Path $ProjectsDir $ProjectName
    if (Test-Path $single) { $projects += Get-Item $single } else { throw "Project not found: $single" }
} else {
    if (Test-Path (Join-Path $ProjectsDir $HtmlFile)) {
        $projects += Get-Item $ProjectsDir
    } else {
        Get-ChildItem -Path $ProjectsDir -Directory | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName $HtmlFile)) { $projects += $_ }
        }
    }
}
if ($projects.Count -eq 0) { Write-Output "No projects with $HtmlFile found in $ProjectsDir"; exit 0 }

New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null

Write-Output ''
Write-Output '================================================================'
Write-Output '  Lighthouse Fix Tool'
Write-Output '================================================================'
Write-Output "Projects:  $($projects.Count)"
Write-Output "Reports:   $ReportsDir"
Write-Output ''

$startTime = Get-Date

# Build project info list
$projInfos = @()
$portIdx = 0
foreach ($project in $projects) {
    $portIdx++
    $info = [pscustomobject]@{
        Name        = $project.Name
        Dir         = $project.FullName
        ReportsDir  = Join-Path $ReportsDir $project.Name
        HtmlPath    = Join-Path $project.FullName $HtmlFile
        Port        = $BasePort + $portIdx - 1
        Url         = "https://localhost:$($BasePort + $portIdx - 1)"
        Container   = "lh-fix-$($project.Name)"
        Before      = @()
        After       = @()
        Error       = $null
    }
    New-Item -ItemType Directory -Force -Path $info.ReportsDir | Out-Null
    $projInfos += $info
}

# -- PHASE 1: BEFORE audits (sequential -- Lighthouse needs exclusive CPU) --
if (-not $SkipAuditBefore) {
    Write-Output ''
    Write-Output '-- PHASE 1: BEFORE audits (sequential) --'
    foreach ($p in $projInfos) {
        Write-Output "[$($p.Name)] BEFORE audit (port=$($p.Port))"
        $auditHtml = $null
        try {
            $auditHtml = New-AuditHtml -ProjectDir $p.Dir -File $HtmlFile -StubsDir $stubsDir
            $p.Container = Start-NginxContainer -Name $p.Name -ProjectDir $p.Dir -Port $p.Port -ConfPath $nginxConf -SslDir $sslDir
            $p.Before = Invoke-QuickAudit -Url $p.Url -OutDir (Join-Path $p.ReportsDir 'before') -Runs $Runs -Presets $Presets -Browsers $Browsers
            foreach ($r in $p.Before) { Write-Output "    [$($r.Browser)/$($r.Preset)] Perf=$($r.Performance) A11y=$($r.Accessibility) BP=$($r.BestPractices) CLS=$([math]::Round($r.CLS,3))" }
        }
        catch { Write-Output "[$($p.Name)] BEFORE ERROR: $_"; $p.Error = "$_" }
        finally {
            Stop-Container $p.Container
            if ($auditHtml -and (Test-Path $auditHtml)) { Remove-Item $auditHtml -Force -EA SilentlyContinue }
        }
    }
}

# -- PHASE 2: FIXES (all projects) --
Write-Output ''
Write-Output '-- PHASE 2: FIXES --'
foreach ($p in $projInfos) {
    if ($p.Error) { Write-Output "[$($p.Name)] skipped (error in BEFORE)"; continue }
    Write-Output "[$($p.Name)] FIXES:"

    try {
        Backup-File $p.HtmlPath

        Write-Output "  1. Fonts"
        Fix-Fonts -ProjectDir $p.Dir -ReportDir $p.ReportsDir

        Write-Output "  2. WP Junk"
        Fix-WpJunk -HtmlPath $p.HtmlPath -ProjectDir $p.Dir -ReportDir $p.ReportsDir

        Write-Output "  3. Meta/SEO"
        Fix-Meta -HtmlPath $p.HtmlPath -ReportDir $p.ReportsDir

        Write-Output "  4. Accessibility"
        $baselineJson = ''
        if ($p.Before.Count -gt 0) { $baselineJson = $p.Before[0].Json }
        Fix-A11y -HtmlPath $p.HtmlPath -ReportDir $p.ReportsDir -JsonPath $baselineJson

        Write-Output "  5. Images"
        Fix-Images -HtmlPath $p.HtmlPath -ProjectDir $p.Dir -ReportDir $p.ReportsDir

        Write-Output "  6. GIFs -> MP4"
        Fix-Gifs -HtmlPath $p.HtmlPath -ProjectDir $p.Dir -ReportDir $p.ReportsDir

        Write-Output "  7. Assets (CSS/JS)"
        Fix-Assets -HtmlPath $p.HtmlPath -ProjectDir $p.Dir -ReportDir $p.ReportsDir

        if ($AggressiveCssPrune -or $AggressiveMobile) {
            Write-Output "  8. Purge Unused CSS"
            Fix-UnusedCss -HtmlPath $p.HtmlPath -ProjectDir $p.Dir -ReportDir $p.ReportsDir
        }

        if ($AggressiveCssDefer -or $AggressiveMobile) {
            Write-Output "  9. CSS Defer"
            Fix-CssDefer -HtmlPath $p.HtmlPath -ReportDir $p.ReportsDir
        }
    }
    catch { Write-Output "[$($p.Name)] FIX ERROR: $_"; $p.Error = "$_" }
}

# -- PHASE 3: AFTER audits (sequential) --
if (-not $SkipAuditAfter) {
    Write-Output ''
    Write-Output '-- PHASE 3: AFTER audits (sequential) --'
    foreach ($p in $projInfos) {
        if ($p.Error) { Write-Output "[$($p.Name)] skipped (error)"; continue }
        Write-Output "[$($p.Name)] AFTER audit (port=$($p.Port))"
        $auditHtml = $null
        try {
            $auditHtml = New-AuditHtml -ProjectDir $p.Dir -File $HtmlFile -StubsDir $stubsDir
            $p.Container = Start-NginxContainer -Name $p.Name -ProjectDir $p.Dir -Port $p.Port -ConfPath $nginxConf -SslDir $sslDir
            $p.After = Invoke-QuickAudit -Url $p.Url -OutDir (Join-Path $p.ReportsDir 'after') -Runs $Runs -Presets $Presets -Browsers $Browsers
            foreach ($r in $p.After) { Write-Output "    [$($r.Browser)/$($r.Preset)] Perf=$($r.Performance) A11y=$($r.Accessibility) BP=$($r.BestPractices) CLS=$([math]::Round($r.CLS,3))" }
            if ($p.Before.Count -gt 0 -and $p.After.Count -gt 0) {
                New-DiffReport -Before $p.Before -After $p.After -OutDir $p.ReportsDir
            }
        }
        catch { Write-Output "[$($p.Name)] AFTER ERROR: $_" }
        finally {
            Stop-Container $p.Container
            if ($auditHtml -and (Test-Path $auditHtml)) { Remove-Item $auditHtml -Force -EA SilentlyContinue }
        }
    }
}

# -- CLEANUP: remove stubs and backup dirs from projects --
foreach ($p in $projInfos) {
    $stubsPath = Join-Path $p.Dir 'lighthouse-stubs'
    if (Test-Path $stubsPath) { Remove-Item $stubsPath -Recurse -Force -EA SilentlyContinue }
    # Remove any .lighthouse-backups dirs recursively
    Get-ChildItem -Path $p.Dir -Filter '.lighthouse-backups' -Directory -Recurse -EA SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -EA SilentlyContinue }
}

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

Write-Output ''
Write-Output '================================================================'
Write-Output "  DONE in ${elapsed}s"
Write-Output '================================================================'
Write-Output ''
foreach ($p in $projInfos) {
    if ($p.Before.Count -gt 0 -and $p.After.Count -gt 0) {
        $bPerf = [math]::Round(($p.Before | Measure-Object -Property Performance -Average).Average, 0)
        $aPerf = [math]::Round(($p.After | Measure-Object -Property Performance -Average).Average, 0)
        $bA11y = [math]::Round(($p.Before | Measure-Object -Property Accessibility -Average).Average, 0)
        $aA11y = [math]::Round(($p.After | Measure-Object -Property Accessibility -Average).Average, 0)
        $d1 = $aPerf - $bPerf; $d2 = $aA11y - $bA11y
        $ds1 = if ($d1 -gt 0) { "+$d1" } else { "$d1" }
        $ds2 = if ($d2 -gt 0) { "+$d2" } else { "$d2" }
        Write-Output "  $($p.Name): Perf $bPerf->$aPerf ($ds1)  A11y $bA11y->$aA11y ($ds2)"
    } elseif ($p.Error) {
        Write-Output "  $($p.Name): ERROR"
    } else {
        Write-Output "  $($p.Name): OK"
    }
}
Write-Output ''
Write-Output "Reports:    $ReportsDir"
Write-Output "Changelogs: <project>/fix-changelog.md"
Write-Output "Diff:       <project>/diff-report.md"
Write-Output ''
Write-Output 'TODO (manual):'
Write-Output '  1. Review alt texts -- replace generated ones with meaningful descriptions'
Write-Output '  2. Write proper meta description'
