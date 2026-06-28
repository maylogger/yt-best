param()

$ErrorActionPreference = 'Stop'

function Resolve-YtBestArguments {
  param([string[]]$InputArgs)

  if ($InputArgs.Count -lt 3) {
    throw 'Usage: yt-best URL START_TIME END_TIME'
  }

  $end = $InputArgs[-1]
  $start = $InputArgs[-2]
  $urlParts = $InputArgs[0..($InputArgs.Count - 3)]

  $url = if ($urlParts.Count -eq 1) {
    $urlParts[0]
  }
  else {
    $urlParts -join '='
  }

  return @{
    Url = $url
    Start = $start
    End = $end
  }
}

$parsed = Resolve-YtBestArguments -InputArgs $args
$Url = $parsed.Url
$Start = $parsed.Start
$End = $parsed.End

$ErrorActionPreference = 'Stop'

function Write-Step {
  param([string]$Message)
  Write-Host "[>] $Message" -ForegroundColor Cyan
}

function Write-Done {
  param([string]$Message)
  Write-Host "[OK] $Message" -ForegroundColor Green
}

function Get-YtDlpJsRuntimeArgs {
  if (Get-Command deno -ErrorAction SilentlyContinue) {
    return @()
  }

  if (Get-Command node -ErrorAction SilentlyContinue) {
    return @('--js-runtimes', 'node')
  }

  Write-Warning '未找到 Deno 或 Node.js，YouTube 解析可能失敗。建議安裝 Deno 2.3+。'
  return @()
}

function ConvertTo-SafeFileName {
  param([string]$Name)

  $invalidPattern = '[<>:"/\\|?*]'
  $safe = [Regex]::Replace($Name, $invalidPattern, '-')
  $safe = $safe -replace '\s+', ' '
  $safe = $safe.Trim(' .-')

  if ([string]::IsNullOrWhiteSpace($safe)) {
    return 'clip'
  }

  if ($safe.Length -gt 150) {
    $safe = $safe.Substring(0, 150).Trim(' .-')
  }

  return $safe
}

function Get-VideoTitle {
  param(
    [string[]]$JsArgs,
    [string]$Url
  )

  # --print title 對含 # 的標題會截斷；用 JSON 編碼可取得完整標題
  $titleJson = (& yt-dlp @JsArgs --print '%(title)j' --no-download --no-warnings $Url 2>$null | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($titleJson)) {
    return 'clip'
  }

  $title = $titleJson | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace($title)) {
    return 'clip'
  }

  return $title.Trim()
}

function ConvertTo-SafeTimeToken {
  param([string]$Time)
  return ($Time -replace ':', '-')
}

$workDir = Get-Location
$section = "*$Start-$End"
$format = '301/300/93/91'

Write-Host ''
Write-Host 'yt-best 開始處理' -ForegroundColor Yellow
Write-Host "  URL   : $Url"
Write-Host "  時段  : $Start -> $End"
Write-Host "  方式  : HLS 片段下載 + NVENC H.264 (CQ 35, 音訊 copy)"
Write-Host ''

$tempPath = $null

try {
  $jsArgs = Get-YtDlpJsRuntimeArgs

  Write-Step '正在取得 YouTube 影片名稱...'
  $videoTitle = Get-VideoTitle -JsArgs $jsArgs -Url $Url

  $safeTitle = ConvertTo-SafeFileName $videoTitle
  $timeRange = "$(ConvertTo-SafeTimeToken $Start)_$(ConvertTo-SafeTimeToken $End)"
  $finalName = "clip-$safeTitle-$timeRange.mp4"
  $outputPath = Join-Path $workDir $finalName
  $tempPath = Join-Path $workDir "temp-$finalName"

  Write-Host "  名稱  : $videoTitle"
  Write-Host "  暫存  : $tempPath"
  Write-Host "  輸出  : $outputPath"
  Write-Host ''

  Write-Step '正在解析影片並下載指定片段 (yt-dlp)...'
  Write-Host '      解析完後會顯示 [download] 進度，請稍候'
  Write-Host ''

  $ytDlpArgs = $jsArgs + @(
    '--download-sections', $section
    '--force-keyframes-at-cuts'
    '-f', $format
    '--force-overwrites'
    '--no-part'
    '--progress'
    '--newline'
    '--downloader-args', 'ffmpeg:-loglevel warning -stats -stats_period 2'
    '-o', $tempPath
    $Url
  )

  & yt-dlp @ytDlpArgs
  if ($LASTEXITCODE -ne 0) {
    throw 'yt-dlp 下載失敗'
  }

  if (-not (Test-Path $tempPath)) {
    throw "找不到暫存檔案：$tempPath"
  }

  Write-Host ''
  Write-Step '正在轉檔 (ffmpeg NVENC H.264 CQ 35, 音訊 copy, VFR, faststart)...'
  Write-Host ''

  & ffmpeg `
    -hide_banner `
    -loglevel warning `
    -stats `
    -stats_period 2 `
    -i $tempPath `
    -map 0:v:0 `
    -map 0:a:0? `
    -c:v h264_nvenc `
    -rc vbr `
    -cq 35 `
    -b:v 0 `
    -pix_fmt yuv420p `
    -fps_mode vfr `
    -c:a copy `
    -movflags +faststart `
    -y $outputPath

  if ($LASTEXITCODE -ne 0) {
    throw 'ffmpeg 轉檔失敗'
  }

  Write-Host ''
  if (Test-Path $outputPath) {
    $sizeMb = [math]::Round((Get-Item $outputPath).Length / 1MB, 2)
    Write-Done "完成！已輸出 $outputPath ($sizeMb MB)"

    if (Test-Path $tempPath) {
      Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
    }

    Get-ChildItem -Path $workDir -Filter "temp-$finalName*" -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like '*.part' -or $_.Name -like '*.ytdl' } |
      Remove-Item -Force -ErrorAction SilentlyContinue
  }
  else {
    throw "找不到輸出檔案：$outputPath"
  }
}
catch {
  Write-Host ''
  if ($tempPath -and (Test-Path $tempPath)) {
    Write-Host "[!] 已保留暫存檔：$tempPath" -ForegroundColor Yellow
    Write-Host '    可稍後手動轉檔，或重新執行 yt-best' -ForegroundColor Yellow
  }

  if ($_.Exception.Message -notmatch 'Pipeline has been stopped|Operation canceled') {
    Write-Host "[X] 失敗：$($_.Exception.Message)" -ForegroundColor Red
  }
  else {
    Write-Host '[X] 已取消' -ForegroundColor Red
  }

  exit 1
}
