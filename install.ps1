$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$source = Join-Path $projectRoot 'yt-best.ps1'
$binDir = Join-Path $env:USERPROFILE '.local\bin'
$target = Join-Path $binDir 'yt-best.ps1'

if (-not (Test-Path $source)) {
  throw "找不到來源腳本：$source"
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Copy-Item -Path $source -Destination $target -Force

$userPathext = [Environment]::GetEnvironmentVariable('PATHEXT', 'User')
if ([string]::IsNullOrEmpty($userPathext)) {
  $userPathext = [Environment]::GetEnvironmentVariable('PATHEXT', 'Machine')
}

if ($userPathext -notlike '.PS1*') {
  [Environment]::SetEnvironmentVariable('PATHEXT', '.PS1;' + $userPathext, 'User')
  Write-Host '已將 .PS1 加入使用者 PATHEXT'
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$binDir*") {
  [Environment]::SetEnvironmentVariable('Path', "$binDir;$userPath", 'User')
  Write-Host '已將 ~/.local/bin 加入使用者 PATH'
}

Write-Host "已安裝：$target"
Write-Host '請重新開啟 PowerShell 後執行 yt-best'
