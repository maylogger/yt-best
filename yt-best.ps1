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

function Get-DenoExecutable {
  $deno = Get-Command deno -ErrorAction SilentlyContinue
  if ($deno) {
    return $deno.Source
  }

  $candidates = @(
    (Join-Path $env:USERPROFILE '.deno\bin\deno.exe')
    (Join-Path $env:LOCALAPPDATA 'deno\deno.exe')
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  return $null
}

function Join-YtDlpArgs {
  param([object[]]$Parts)

  $result = [System.Collections.Generic.List[string]]::new()
  foreach ($part in $Parts) {
    if ($null -eq $part) {
      continue
    }

    foreach ($item in @($part)) {
      [void]$result.Add([string]$item)
    }
  }

  return ,@([string[]]$result.ToArray())
}

function Get-YtDlpJsRuntimeArgs {
  # yt-dlp 預設已啟用 deno；PATH 找得到就不必傳參
  if (Get-Command deno -ErrorAction SilentlyContinue) {
    return [string[]]@()
  }

  $denoPath = Get-DenoExecutable
  if ($denoPath) {
    # Windows 路徑改用 /，避免 deno:C:\ 被誤判成 runtime 名稱
    $denoUnixPath = $denoPath -replace '\\', '/'
    return @('--js-runtimes', "deno:$denoUnixPath")
  }

  if (Get-Command node -ErrorAction SilentlyContinue) {
    Write-Warning '未找到 Deno。YouTube m3u8/HLS 可能無法偵測，建議安裝 Deno 2.3+。'
    return [string[]]@()
  }

  Write-Warning '未找到 Deno 或 Node.js，YouTube 解析可能失敗。建議安裝 Deno 2.3+。'
  return [string[]]@()
}

function Test-DenoAvailable {
  if (Get-DenoExecutable) {
    return $true
  }

  return [bool](Get-DenoExecutable)
}

function Get-YtDlpYoutubeHlsExtractorArgs {
  # web_safari 才較容易帶出 m3u8；default 作備援避免只剩 images
  return @(
    '--no-cache-dir'
    '--extractor-args'
    'youtube:player_client=web_safari,default'
  )
}

function Get-YtDlpHlsProbeArgs {
  param([string[]]$JsArgs)

  return Join-YtDlpArgs $JsArgs, (Get-YtDlpYoutubeHlsExtractorArgs)
}

function Get-YtDlpHlsDownloadArgs {
  return Get-YtDlpYoutubeHlsExtractorArgs
}

function Get-YtDlpVideoInfo {
  param(
    [string[]]$JsArgs,
    [string]$Url,
    [string]$InfoJsonPath
  )

  $ytArgs = Join-YtDlpArgs $JsArgs, (Get-YtDlpYoutubeHlsExtractorArgs), @(
    '-J'
    '--no-download'
    $Url
  )

  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'

  try {
    $jsonLines = & yt-dlp @ytArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
      throw 'yt-dlp 解析影片資訊失敗'
    }

    $jsonText = if ($jsonLines -is [array]) {
      ($jsonLines | ForEach-Object { $_.ToString() }) -join "`n"
    }
    else {
      [string]$jsonLines
    }

    if ([string]::IsNullOrWhiteSpace($jsonText)) {
      throw 'yt-dlp 解析影片資訊失敗（空回應）'
    }

    $info = $jsonText | ConvertFrom-Json
    if (-not $info) {
      throw 'yt-dlp 解析影片資訊失敗（JSON 無效）'
    }

    if ($InfoJsonPath) {
      [System.IO.File]::WriteAllText($InfoJsonPath, $jsonText, [System.Text.UTF8Encoding]::new($false))
    }

    $title = if ($info.title) { ([string]$info.title).Trim() } else { 'clip' }
    if ([string]::IsNullOrWhiteSpace($title)) {
      $title = 'clip'
    }

    return @{
      Title = $title
      Formats = @($info.formats)
      JsonText = $jsonText
      Info = $info
      InfoJsonPath = $InfoJsonPath
    }
  }
  finally {
    $ErrorActionPreference = $previousErrorAction
  }
}

function Select-HlsFormatFromInfo {
  param(
    [object[]]$Formats,
    [string[]]$PreferredIds = @('301', '300', '96', '95', '93', '91')
  )

  $formats = @($Formats)
  if ($formats.Count -eq 0) {
    return $null
  }

  foreach ($id in $PreferredIds) {
    $match = $formats | Where-Object { [string]$_.format_id -eq $id } | Select-Object -First 1
    if (-not $match) {
      continue
    }

    $url = if ($match.url) { [string]$match.url } elseif ($match.manifest_url) { [string]$match.manifest_url } else { $null }
    if ([string]::IsNullOrWhiteSpace($url)) {
      continue
    }

    return @{
      FormatId = [string]$match.format_id
      Url = $url
      HttpHeaders = $match.http_headers
      Height = $match.height
    }
  }

  $hlsFormats = @(
    $formats | Where-Object {
      ($_.protocol -match 'm3u8') -and ($_.url -or $_.manifest_url)
    } | Sort-Object {
      if ($null -eq $_.height) { 0 } else { [int]$_.height }
    } -Descending
  )

  $best = $hlsFormats | Select-Object -First 1
  if (-not $best) {
    return $null
  }

  $bestUrl = if ($best.url) { [string]$best.url } else { [string]$best.manifest_url }
  return @{
    FormatId = [string]$best.format_id
    Url = $bestUrl
    HttpHeaders = $best.http_headers
    Height = $best.height
  }
}

function ConvertTo-FfmpegHeadersArgument {
  param($HttpHeaders)

  if ($null -eq $HttpHeaders) {
    return $null
  }

  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($prop in $HttpHeaders.PSObject.Properties) {
    if ([string]::IsNullOrWhiteSpace($prop.Name)) {
      continue
    }

    [void]$lines.Add("$($prop.Name): $($prop.Value)")
  }

  if ($lines.Count -eq 0) {
    return $null
  }

  return (($lines -join "`r`n") + "`r`n")
}

function Get-YoutubeVideoId {
  param([string]$Url)

  if ($Url -match '(?i)(?:youtu\.be/|v=|/shorts/|/live/|youtube\.com/embed/)([a-zA-Z0-9_-]{11})') {
    return $Matches[1]
  }

  if ($Url -match '^[a-zA-Z0-9_-]{11}$') {
    return $Url
  }

  return (ConvertTo-SafeFileName $Url)
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

function Test-YtDlpOutputIndicatesBot {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return $false
  }

  return ($Text -match "Sign in to confirm|not a bot|confirm you.?re not|HTTP Error 403|This content isn.t available")
}

function Test-YtDlpFormatsOutputHasM3u8 {
  param([string]$Output)

  if ([string]::IsNullOrWhiteSpace($Output)) {
    return $false
  }

  if ($Output -match 'Downloading m3u8 information') {
    return $true
  }

  # 對齊 yt-dlp -F 表格 PROTO 欄的 m3u8（-J 的 JSON 常漏掉 m3u8）
  return ($Output -match '\|\s*m3u8(_native)?\s*\|' -or $Output -match '\s+m3u8(_native)?\s+\│')
}

function Test-YtDlpFormatsOutputGotFormats {
  param([string]$Output)

  if ([string]::IsNullOrWhiteSpace($Output)) {
    return $false
  }

  return ($Output -match 'Available formats for' -or $Output -match '\|\s*https\s*\|')
}

function Test-YtDlpOutputUsedAndroidVrFastPath {
  param(
    [string]$Output,
    [bool]$HasM3u8,
    [bool]$GotFormats
  )

  if (-not $GotFormats -or $HasM3u8) {
    return $false
  }

  if ($Output -match 'Downloading m3u8 information|Downloading player|\[jsc:deno\]') {
    return $false
  }

  return ($Output -match 'Downloading android vr player API JSON')
}

function Test-YtDlpHlsProbe {
  param(
    [string[]]$JsArgs,
    [string]$Url
  )

  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'

  try {
    $lines = & yt-dlp @JsArgs -F --no-download $Url 2>&1
    $outputText = ($lines | ForEach-Object { $_.ToString() }) -join "`n"

    if (Test-YtDlpOutputIndicatesBot $outputText) {
      return @{
        HasM3u8 = $false
        BotDetected = $true
        GotFormats = $false
        UsedAndroidVrFastPath = $false
      }
    }

    if ($LASTEXITCODE -ne 0) {
      return @{
        HasM3u8 = $false
        BotDetected = $false
        GotFormats = $false
        UsedAndroidVrFastPath = $false
      }
    }

    $hasM3u8 = Test-YtDlpFormatsOutputHasM3u8 $outputText
    $gotFormats = Test-YtDlpFormatsOutputGotFormats $outputText

    return @{
      HasM3u8 = $hasM3u8
      BotDetected = $false
      GotFormats = $gotFormats
      UsedAndroidVrFastPath = (Test-YtDlpOutputUsedAndroidVrFastPath -Output $outputText -HasM3u8 $hasM3u8 -GotFormats $gotFormats)
    }
  }
  finally {
    $ErrorActionPreference = $previousErrorAction
  }
}

function Test-VideoHasHls {
  param(
    [string[]]$JsArgs,
    [string]$Url
  )

  # 最多 2 次 -F：第一次檢查；僅 android vr 快取路徑時才重試一次
  $probeArgs = Get-YtDlpHlsProbeArgs -JsArgs $JsArgs
  $probe = Test-YtDlpHlsProbe -JsArgs $probeArgs -Url $Url

  if ($probe.HasM3u8) {
    return @{
      HasHls = $true
      BotBlocked = $false
      UncertainHls = $false
    }
  }

  if ($probe.BotDetected) {
    return @{
      HasHls = $false
      BotBlocked = $true
      UncertainHls = $false
    }
  }

  if ($probe.UsedAndroidVrFastPath) {
    $retry = Test-YtDlpHlsProbe -JsArgs $probeArgs -Url $Url
    if ($retry.HasM3u8) {
      return @{
        HasHls = $true
        BotBlocked = $false
        UncertainHls = $false
      }
    }

    if ($retry.BotDetected) {
      return @{
        HasHls = $false
        BotBlocked = $true
        UncertainHls = $false
      }
    }

    return @{
      HasHls = $false
      BotBlocked = $false
      UncertainHls = $retry.GotFormats
    }
  }

  return @{
    HasHls = $false
    BotBlocked = $false
    UncertainHls = $probe.GotFormats
  }
}

function Read-DownloadFallbackConfirmation {
  param(
    [switch]$DenoMissing,
    [switch]$BotBlocked,
    [switch]$UncertainHls,
    [switch]$HlsDownloadFailed
  )

  if ($HlsDownloadFailed) {
    $response = Read-Host '[!] HLS 片段下載失敗（格式可能已消失或不可用）。是否改整支下載後裁切？(Y/n)'
  }
  elseif ($DenoMissing) {
    $response = Read-Host '[!] 警告：目前無法取得 HLS/m3u8（需 Deno 完整解析 YouTube）。是否改整支下載後裁切？(Y/n)'
  }
  elseif ($BotBlocked) {
    $response = Read-Host '[!] 警告：YouTube 要求驗證（bot），暫時無法確認 HLS。是否改整支下載後裁切？(Y/n)'
  }
  elseif ($UncertainHls) {
    $response = Read-Host '[!] 警告：暫時無法確認 HLS（yt-dlp 可能走了 android vr 快取路徑）。是否改整支下載後裁切？(Y/n)'
  }
  else {
    $response = Read-Host '[!] 警告：這支影片沒有 HLS/m3u8。你要改成整支下載後裁切嗎？(Y/n)'
  }
  if ([string]::IsNullOrWhiteSpace($response)) {
    return $true
  }

  return ($response -notmatch '^[Nn]')
}

function Invoke-YtDlpDownload {
  param([string[]]$YtDlpArgs)

  & yt-dlp @YtDlpArgs
  return ($LASTEXITCODE -eq 0)
}

function Invoke-HlsSectionDownload {
  param(
    [string]$HlsUrl,
    $HttpHeaders,
    [string]$Start,
    [string]$End,
    [string]$OutputPath
  )

  $ffmpegArgs = [System.Collections.Generic.List[string]]::new()
  foreach ($arg in @(
      '-hide_banner'
      '-loglevel', 'error'
      '-nostats'
      '-progress', 'pipe:1'
      '-protocol_whitelist', 'file,http,https,tcp,tls,crypto'
    )) {
    [void]$ffmpegArgs.Add($arg)
  }

  $headerArg = ConvertTo-FfmpegHeadersArgument $HttpHeaders
  if ($headerArg) {
    [void]$ffmpegArgs.Add('-headers')
    [void]$ffmpegArgs.Add($headerArg)
  }

  foreach ($arg in @(
      '-ss', $Start
      '-to', $End
      '-i', $HlsUrl
      '-map', '0:v:0'
      '-map', '0:a:0?'
      '-c', 'copy'
      '-movflags', '+faststart'
      '-y', $OutputPath
    )) {
    [void]$ffmpegArgs.Add($arg)
  }

  Invoke-FfmpegWithProgress -FfmpegArgs $ffmpegArgs.ToArray() -ProgressLabel 'HLS' -FailureMessage 'ffmpeg HLS 片段下載失敗'
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
# 無 HLS 時整支下載：最佳視訊 + 最佳音訊，合併成 mp4（透過 --load-info-json，不再重新解析）
$fullFormat = 'bv*+ba/b'

Write-Host ''
Write-Host 'yt-best 開始處理' -ForegroundColor Yellow
Write-Host "  URL   : $Url"
Write-Host "  時段  : $Start -> $End"
Write-Host ''

$tempPath = $null
$trimTempPath = $null
$infoJsonPath = $null

try {
  $jsArgs = Join-YtDlpArgs (Get-YtDlpJsRuntimeArgs), '--no-playlist'
  $videoKey = Get-YoutubeVideoId $Url
  $timeRange = "$(ConvertTo-SafeTimeToken $Start)_$(ConvertTo-SafeTimeToken $End)"
  $hlsTempPath = Join-Path $workDir "hls-$videoKey-$timeRange.mp4"
  $fullTempPath = Join-Path $workDir "full-$videoKey-$timeRange.mp4"
  $infoJsonPath = Join-Path $workDir "temp-info-$videoKey.json"
  $useHlsDownload = $false

  if (-not (Test-DenoAvailable)) {
    Write-Host '[!] 未找到 Deno。YouTube HLS/m3u8 通常需要 Deno；若無 HLS 會改整支下載。' -ForegroundColor Yellow
    Write-Host ''
  }

  Write-Step '正在解析影片資訊...'
  $videoInfo = Get-YtDlpVideoInfo -JsArgs $jsArgs -Url $Url -InfoJsonPath $infoJsonPath
  $videoTitle = $videoInfo.Title
  $safeTitle = ConvertTo-SafeFileName $videoTitle
  $finalName = "clip-$safeTitle-$timeRange.mp4"
  $outputPath = Join-Path $workDir $finalName

  Write-Host "  名稱  : $videoTitle"
  Write-Host "  資訊  : $infoJsonPath"
  Write-Host "  輸出  : $outputPath"
  Write-Host ''

  if (Test-UsableMediaFile $hlsTempPath) {
    Write-Host "[!] 發現既有 HLS 暫存檔 ($(Get-MediaFileSizeMb $hlsTempPath) MB)，跳過下載。" -ForegroundColor Yellow
    Write-Host ''
    $useHlsDownload = $true
    $tempPath = $hlsTempPath
  }
  elseif (Test-UsableMediaFile $fullTempPath) {
    Write-Host "[!] 發現既有完整暫存檔 ($(Get-MediaFileSizeMb $fullTempPath) MB)，跳過下載。" -ForegroundColor Yellow
    Write-Host ''
    $useHlsDownload = $false
    $tempPath = $fullTempPath
  }
  else {
    $hlsFormatInfo = Select-HlsFormatFromInfo -Formats $videoInfo.Formats
    $needFullDownload = $false

    if ($hlsFormatInfo) {
      Write-Host "  方式  : HLS 片段（format $($hlsFormatInfo.FormatId)）→ ffmpeg 直抓 → NVENC"
      Write-Host ''
      Write-Step "正在以 ffmpeg 下載 HLS 片段 $($hlsFormatInfo.FormatId)..."
      Write-Host ''

      try {
        Invoke-HlsSectionDownload -HlsUrl $hlsFormatInfo.Url -HttpHeaders $hlsFormatInfo.HttpHeaders -Start $Start -End $End -OutputPath $hlsTempPath
        if (Test-UsableMediaFile $hlsTempPath) {
          $useHlsDownload = $true
          $tempPath = $hlsTempPath
        }
        else {
          throw 'ffmpeg HLS 下載後找不到可用暫存檔'
        }
      }
      catch {
        Write-Host ''
        Write-Host "[!] HLS 片段下載失敗：$($_.Exception.Message)" -ForegroundColor Yellow
        if (-not (Read-DownloadFallbackConfirmation -HlsDownloadFailed)) {
          if ($infoJsonPath -and (Test-Path $infoJsonPath)) {
            Remove-Item $infoJsonPath -Force -ErrorAction SilentlyContinue
          }
          Write-Host ''
          Write-Host '[!] 已停止下載。' -ForegroundColor Yellow
          exit 0
        }

        $needFullDownload = $true
      }
    }
    else {
      Write-Host '[!] 這次解析結果沒有可用的 HLS/m3u8。' -ForegroundColor Yellow
      if (-not (Read-DownloadFallbackConfirmation)) {
        if ($infoJsonPath -and (Test-Path $infoJsonPath)) {
          Remove-Item $infoJsonPath -Force -ErrorAction SilentlyContinue
        }
        Write-Host ''
        Write-Host '[!] 已停止下載。' -ForegroundColor Yellow
        exit 0
      }

      $needFullDownload = $true
    }

    if ($needFullDownload) {
      $useHlsDownload = $false
      $tempPath = $fullTempPath
      Write-Host ''
      Write-Host '  方式  : 整支下載（--load-info-json，不重新解析）→ 裁切 → NVENC'
      Write-Host ''
      Write-Step '正在下載完整影片 (yt-dlp --load-info-json)...'
      Write-Host '      進度會在同一行更新，請稍候'
      Write-Host ''

      $fullDownloadArgs = @(
        '--load-info-json', $infoJsonPath
        '-f', $fullFormat
        '--merge-output-format', 'mp4'
        '--force-overwrites'
        '--no-part'
        '--progress'
        '--downloader-args', 'ffmpeg:-loglevel warning -stats -stats_period 2'
        '-o', $fullTempPath
      )

      $fullOk = Invoke-YtDlpDownload -YtDlpArgs $fullDownloadArgs
      if (-not ($fullOk -or (Test-UsableMediaFile $fullTempPath))) {
        throw 'yt-dlp 下載失敗'
      }

      if (-not $fullOk) {
        Write-Host "[!] 下載失敗，但暫存檔可用 ($(Get-MediaFileSizeMb $fullTempPath) MB)，繼續後續步驟。" -ForegroundColor Yellow
        Write-Host ''
      }
    }
  }

  if (-not (Test-UsableMediaFile $tempPath)) {
    throw "找不到暫存檔案：$tempPath"
  }

  Write-Host "  暫存  : $tempPath"
  if ($useHlsDownload) {
    Write-Host '  方式  : HLS 片段 + NVENC H.264 (CQ 35, 音訊 copy)'
  }
  else {
    Write-Host '  方式  : 整支下載 → 裁切 → NVENC H.264 (CQ 35, 音訊 copy)'
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

    # 保留 hls-/full-/trim-/clip- 等 mp4；只清掉一次解析用的 temp-info JSON
    if ($infoJsonPath -and (Test-Path $infoJsonPath)) {
      Remove-Item $infoJsonPath -Force -ErrorAction SilentlyContinue
    }

    Get-ChildItem -Path $workDir -Filter "hls-$videoKey-$timeRange*" -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like '*.part' -or $_.Name -like '*.ytdl' } |
      Remove-Item -Force -ErrorAction SilentlyContinue

    Get-ChildItem -Path $workDir -Filter "full-$videoKey-$timeRange*" -ErrorAction SilentlyContinue |
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

  if ($infoJsonPath -and (Test-Path $infoJsonPath)) {
    Write-Host "[!] 已保留解析 JSON：$infoJsonPath" -ForegroundColor Yellow
  }

  if ($_.Exception.Message -notmatch 'Pipeline has been stopped|Operation canceled') {
    Write-Host "[X] 失敗：$($_.Exception.Message)" -ForegroundColor Red
  }
  else {
    Write-Host '[X] 已取消' -ForegroundColor Red
  }

  exit 1
}
