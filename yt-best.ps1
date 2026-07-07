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

function Write-ShareText {
  param(
    [string]$Title,
    [string]$Url,
    [string]$Start,
    [string]$End
  )

  Write-Host ''
  Write-Host "來源分享： $Title"
  Write-Host "影片網址： $Url"
  Write-Host "起始時間： $Start"
  Write-Host "結束時間： $End"
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

function Test-VideoHasHls {
  param(
    [string[]]$JsArgs,
    [string]$Url
  )

  $formats = (& yt-dlp @JsArgs -F --no-warnings $Url | Out-String)
  if ($LASTEXITCODE -ne 0) {
    throw 'yt-dlp 無法列出影片格式'
  }

  return ($formats -match '\bm3u8\b')
}

function Read-DownloadFallbackConfirmation {
  $response = Read-Host '[!] 警告：這支影片沒有 HLS/m3u8。你要改成整支下載後裁切嗎？(Y/n)'
  if ([string]::IsNullOrWhiteSpace($response)) {
    return $true
  }

  return ($response -notmatch '^[Nn]')
}

function Invoke-ClipTranscode {
  param(
    [string]$InputPath,
    [string]$OutputPath,
    [string]$Start = $null,
    [string]$End = $null
  )

  $ffmpegArgs = @(
    '-hide_banner'
    '-loglevel', 'warning'
    '-stats'
    '-stats_period', '2'
    '-i', $InputPath
  )

  if ($Start -and $End) {
    $ffmpegArgs += @('-ss', $Start, '-to', $End)
  }

  $ffmpegArgs += @(
    '-map', '0:v:0'
    '-map', '0:a:0?'
    '-c:v', 'h264_nvenc'
    '-rc', 'vbr'
    '-cq', '35'
    '-b:v', '0'
    '-pix_fmt', 'yuv420p'
    '-fps_mode', 'vfr'
    '-c:a', 'copy'
    '-movflags', '+faststart'
    '-y', $OutputPath
  )

  & ffmpeg @ffmpegArgs
  if ($LASTEXITCODE -ne 0) {
    throw 'ffmpeg 轉檔失敗'
  }
}

$workDir = Get-Location
$section = "*$Start-$End"
# HLS only（支援 --download-sections 只抓片段）；AV1 優先，無 AV1 時退回 H.264 HLS
# 301/300=AV1 HLS，96/95=1080p/720p H.264 HLS，93/91=較低畫質 H.264 HLS
$hlsFormat = '301/300/96/95/93/91'
# 無 HLS 時整支下載：最佳視訊 + 最佳音訊，合併成 mp4
$fullFormat = 'bv*+ba/b'

Write-Host ''
Write-Host 'yt-best 開始處理' -ForegroundColor Yellow
Write-Host "  URL   : $Url"
Write-Host "  時段  : $Start -> $End"
Write-Host ''

$tempPath = $null

try {
  $jsArgs = Get-YtDlpJsRuntimeArgs

  Write-Step '正在檢查影片是否提供 HLS 串流...'
  $useHlsDownload = Test-VideoHasHls -JsArgs $jsArgs -Url $Url
  if (-not $useHlsDownload) {
    if (-not (Read-DownloadFallbackConfirmation)) {
      Write-Host ''
      Write-Host '[!] 已停止下載。' -ForegroundColor Yellow
      exit 0
    }
  }

  if ($useHlsDownload) {
    Write-Host '  方式  : HLS 片段下載（自動選最佳可用畫質）+ NVENC H.264 (CQ 35, 音訊 copy)'
  }
  else {
    Write-Host '  方式  : 整支下載（最佳影音畫質）→ 裁切指定時段 → NVENC H.264 (CQ 35, 音訊 copy)'
  }
  Write-Host ''

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

  if ($useHlsDownload) {
    Write-Step '正在解析影片並下載指定片段 (yt-dlp)...'
  }
  else {
    Write-Step '正在下載完整影片 (yt-dlp，最佳影音畫質)...'
  }
  Write-Host '      解析完後進度會在同一行更新，請稍候'
  Write-Host ''

  if ($useHlsDownload) {
    $ytDlpArgs = $jsArgs + @(
      '--download-sections', $section
      '--force-keyframes-at-cuts'
      '-f', $hlsFormat
      '--force-overwrites'
      '--no-part'
      '--progress'
      '--downloader-args', 'ffmpeg:-loglevel warning -stats -stats_period 2'
      '-o', $tempPath
      $Url
    )
  }
  else {
    $ytDlpArgs = $jsArgs + @(
      '-f', $fullFormat
      '--merge-output-format', 'mp4'
      '--force-overwrites'
      '--no-part'
      '--progress'
      '--downloader-args', 'ffmpeg:-loglevel warning -stats -stats_period 2'
      '-o', $tempPath
      $Url
    )
  }

  & yt-dlp @ytDlpArgs
  if ($LASTEXITCODE -ne 0) {
    throw 'yt-dlp 下載失敗'
  }

  if (-not (Test-Path $tempPath)) {
    throw "找不到暫存檔案：$tempPath"
  }

  Write-Host ''
  if ($useHlsDownload) {
    Write-Step '正在轉檔 (ffmpeg NVENC H.264 CQ 35, 音訊 copy, VFR, faststart)...'
  }
  else {
    Write-Step "正在裁切 $Start -> $End 並轉檔 (ffmpeg NVENC H.264 CQ 35, 音訊 copy, VFR, faststart)..."
  }
  Write-Host ''

  if ($useHlsDownload) {
    Invoke-ClipTranscode -InputPath $tempPath -OutputPath $outputPath
  }
  else {
    Invoke-ClipTranscode -InputPath $tempPath -OutputPath $outputPath -Start $Start -End $End
  }

  Write-Host ''
  if (Test-Path $outputPath) {
    $sizeMb = [math]::Round((Get-Item $outputPath).Length / 1MB, 2)
    Write-Done "完成！檔案已輸出 $outputPath ($sizeMb MB)"
    Write-ShareText -Title $videoTitle -Url $Url -Start $Start -End $End

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
