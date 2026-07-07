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

function ConvertTo-TimeSpanFromClock {
  param([string]$Time)

  $parts = $Time -split ':'
  switch ($parts.Count) {
    2 {
      return [TimeSpan]::FromMinutes([int]$parts[0]) + [TimeSpan]::FromSeconds([int]$parts[1])
    }
    3 {
      return [TimeSpan]::FromHours([int]$parts[0]) + [TimeSpan]::FromMinutes([int]$parts[1]) + [TimeSpan]::FromSeconds([int]$parts[2])
    }
    default {
      throw "無法解析時間：$Time"
    }
  }
}

function Get-ClipDurationToken {
  param(
    [string]$Start,
    [string]$End
  )

  $duration = ConvertTo-TimeSpanFromClock $End - ConvertTo-TimeSpanFromClock $Start
  if ($duration.TotalSeconds -le 0) {
    throw "結束時間必須晚於起始時間：$Start -> $End"
  }

  return $duration.ToString('c')
}

function Test-UsableTrimFile {
  param(
    [string]$TrimPath,
    [string]$FullPath,
    [string]$Start,
    [string]$End
  )

  if (-not (Test-UsableMediaFile $TrimPath)) {
    return $false
  }

  if (-not (Test-UsableMediaFile $FullPath)) {
    return $true
  }

  $trimSize = (Get-Item $TrimPath).Length
  $fullSize = (Get-Item $FullPath).Length
  $durationSec = (ConvertTo-TimeSpanFromClock $End - ConvertTo-TimeSpanFromClock $Start).TotalSeconds

  if ($trimSize -gt ($fullSize * 0.8)) {
    return $false
  }

  $maxExpectedBytes = [math]::Max(200MB, $durationSec * 5MB)
  if ($trimSize -gt $maxExpectedBytes) {
    return $false
  }

  return $true
}

function Test-UsableMediaFile {
  param([string]$Path)

  if (-not (Test-Path $Path)) {
    return $false
  }

  return (Get-Item $Path).Length -gt 0
}

function Get-MediaFileSizeMb {
  param([string]$Path)

  return [math]::Round((Get-Item $Path).Length / 1MB, 2)
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

function Write-InlineProgress {
  param(
    [string]$Message,
    [switch]$Final
  )

  if ($Final) {
    Write-Host $Message
    return
  }

  if ([Console]::IsOutputRedirected) {
    return
  }

  try {
    $width = 100
    $consoleWidth = [Console]::WindowWidth
    if ($consoleWidth -gt 40) {
      $width = $consoleWidth - 1
    }

    [Console]::Write("`r" + $Message.PadRight($width))
  }
  catch {
    # 進行中更新失敗時略過，避免中斷轉檔
  }
}

function Invoke-FfmpegWithProgress {
  param(
    [string[]]$FfmpegArgs,
    [string]$ProgressLabel,
    [string]$FailureMessage
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'ffmpeg'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $false
  $psi.CreateNoWindow = $true

  if ($psi.PSObject.Properties.Name -contains 'ArgumentList') {
    foreach ($arg in $FfmpegArgs) {
      [void]$psi.ArgumentList.Add($arg)
    }
  }
  else {
    $escapedArgs = $FfmpegArgs | ForEach-Object {
      if ($_ -match '[\s"]') {
        '"' + ($_ -replace '"', '\"') + '"'
      }
      else {
        $_
      }
    }
    $psi.Arguments = $escapedArgs -join ' '
  }

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi

  [void]$process.Start()

  $progressData = @{}
  while ($true) {
    $line = $process.StandardOutput.ReadLine()
    if ($null -eq $line) {
      if ($process.HasExited) {
        break
      }

      Start-Sleep -Milliseconds 50
      continue
    }

    if ($line -notmatch '^([^=]+)=(.*)$') {
      continue
    }

    $progressData[$Matches[1]] = $Matches[2]
    if ($Matches[1] -ne 'progress') {
      continue
    }

    $time = if ($progressData['out_time']) {
      ($progressData['out_time'] -replace '\.\d+$', '')
    }
    else {
      '00:00:00'
    }
    $speed = if ($progressData['speed']) { $progressData['speed'] } else { '?' }
    $sizeMb = if ($progressData['total_size']) {
      '{0:N2}' -f ([double]$progressData['total_size'] / 1MB)
    }
    else {
      '?'
    }

    if ($Matches[2] -eq 'end') {
      Write-InlineProgress "[$ProgressLabel] 完成 time=$time speed=$speed size=${sizeMb}MB" -Final
    }
    else {
      Write-InlineProgress "[$ProgressLabel] time=$time speed=$speed size=${sizeMb}MB"
    }
  }

  $process.WaitForExit()

  if ($process.ExitCode -ne 0) {
    throw $FailureMessage
  }
}

function Invoke-ClipTrim {
  param(
    [string]$InputPath,
    [string]$OutputPath,
    [string]$Start,
    [string]$End
  )

  $ffmpegArgs = @(
    '-hide_banner'
    '-loglevel', 'error'
    '-nostats'
    '-progress', 'pipe:1'
    '-ss', $Start
    '-to', $End
    '-i', $InputPath
    '-map', '0:v:0'
    '-map', '0:a:0?'
    '-c', 'copy'
    '-movflags', '+faststart'
    '-y', $OutputPath
  )

  Invoke-FfmpegWithProgress -FfmpegArgs $ffmpegArgs -ProgressLabel 'TRIM' -FailureMessage 'ffmpeg 裁切失敗'
}

function Invoke-ClipTranscode {
  param(
    [string]$InputPath,
    [string]$OutputPath
  )

  $ffmpegArgs = @(
    '-hide_banner'
    '-loglevel', 'error'
    '-nostats'
    '-progress', 'pipe:1'
    '-i', $InputPath
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

  Invoke-FfmpegWithProgress -FfmpegArgs $ffmpegArgs -ProgressLabel 'ENC' -FailureMessage 'ffmpeg 轉檔失敗'
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
$trimTempPath = $null

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

  if (Test-UsableMediaFile $tempPath) {
    Write-Host "[!] 發現既有暫存檔 ($(Get-MediaFileSizeMb $tempPath) MB)，跳過下載，直接繼續後續步驟。" -ForegroundColor Yellow
    Write-Host ''
  }
  else {
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
      if (Test-UsableMediaFile $tempPath) {
        Write-Host "[!] 下載失敗，但暫存檔可用 ($(Get-MediaFileSizeMb $tempPath) MB)，繼續後續步驟。" -ForegroundColor Yellow
        Write-Host ''
      }
      else {
        throw 'yt-dlp 下載失敗'
      }
    }
  }

  if (-not (Test-UsableMediaFile $tempPath)) {
    throw "找不到暫存檔案：$tempPath"
  }

  Write-Host ''
  if ($useHlsDownload) {
    Write-Step '正在轉檔 (ffmpeg NVENC H.264 CQ 35, 音訊 copy, VFR, faststart)...'
    Write-Host ''
    Invoke-ClipTranscode -InputPath $tempPath -OutputPath $outputPath
  }
  else {
    $trimTempPath = Join-Path $workDir "trim-$finalName"

    if (Test-UsableTrimFile -TrimPath $trimTempPath -FullPath $tempPath -Start $Start -End $End) {
      Write-Host "[!] 發現既有裁切暫存檔 ($(Get-MediaFileSizeMb $trimTempPath) MB)，跳過裁切，直接轉檔。" -ForegroundColor Yellow
      Write-Host ''
    }
    else {
      if (Test-UsableMediaFile $trimTempPath) {
        Write-Host "[!] 既有裁切暫存檔 ($(Get-MediaFileSizeMb $trimTempPath) MB) 大小異常，重新裁切。" -ForegroundColor Yellow
        Write-Host ''
      }

      Write-Step "正在裁切 $Start -> $End (ffmpeg stream copy)..."
      Write-Host ''
      Invoke-ClipTrim -InputPath $tempPath -OutputPath $trimTempPath -Start $Start -End $End

      Write-Host ''
    }

    Write-Step '正在轉檔 (ffmpeg NVENC H.264 CQ 35, 音訊 copy, VFR, faststart)...'
    Write-Host ''
    Invoke-ClipTranscode -InputPath $trimTempPath -OutputPath $outputPath
  }

  Write-Host ''
  if (Test-Path $outputPath) {
    $sizeMb = [math]::Round((Get-Item $outputPath).Length / 1MB, 2)
    Write-Done "完成！檔案已輸出 $outputPath ($sizeMb MB)"
    Write-ShareText -Title $videoTitle -Url $Url -Start $Start -End $End

    if (Test-Path $tempPath) {
      Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
    }

    if ($trimTempPath -and (Test-Path $trimTempPath)) {
      Remove-Item $trimTempPath -Force -ErrorAction SilentlyContinue
    }

    Get-ChildItem -Path $workDir -Filter "temp-$finalName*" -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like '*.part' -or $_.Name -like '*.ytdl' } |
      Remove-Item -Force -ErrorAction SilentlyContinue

    Get-ChildItem -Path $workDir -Filter "trim-$finalName*" -ErrorAction SilentlyContinue |
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

  if ($trimTempPath -and (Test-Path $trimTempPath)) {
    Write-Host "[!] 已保留裁切暫存檔：$trimTempPath" -ForegroundColor Yellow
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
