# yt-best Agent 備忘

本檔記錄 `yt-best.ps1` 開發時踩過的坑，**修改此腳本前必讀**。

## 1. 編輯 PowerShell 函式：不可弄掉 `function` 宣告

曾兩次在「插入新函式」時，用 `StrReplace` 把既有函式的 `function Foo {` 標頭一起替換掉，只留下 `param(...)` 與函式體，導致：

```
ParserError: Unexpected token '}' in expression or statement.
```

**規則：**

- 新增 `Test-UsableTrimFile` 等函式時，**只插入新區塊**，不要以 `function Test-UsableMediaFile {` 當錨點做替換。
- 插入後確認每個函式都有完整結構：`function Name {` → `param(...)` → 函式體 → `}`。
- 改完執行 `pwsh -NoProfile -File yt-best.ps1`（無參數應只噴 Usage，不能有 ParserError）。

**目前易混淆的函式群（順序）：**

- `Test-UsableTrimFile`
- `Test-UsableMediaFile`
- `Get-MediaFileSizeMb`
- `Test-VideoHasHls`

## 2. 單行進度：禁止中文與 ANSI 在 `[Console]::Write`

### 現象

終端機顯示 `[??] time=...`，或結尾出現 `[??]` 亂碼。

### 原因

1. **中文標籤**（`裁切`、`轉檔`）經 `[Console]::Write()` 輸出時，在 Windows 主控台編碼下常變成 `??`。
2. **ANSI 清除碼** `` `e[2K `` 在不支援 VT 的主控台會被印成可見的 `[??]`。

### 規則

- `Write-InlineProgress` 的進度前綴**只用 ASCII**：`TRIM`、`ENC`。
- 中文只用在 `Write-Step` / `Write-Host`（一般換行輸出）。
- **不要用** `` `e[2K ``；單行更新只用 `` `r `` + `PadRight`。
- 完成時用 `Write-Host $Message`（`-Final`），不要用帶控制碼的 `Console.WriteLine`。

## 3. ffmpeg 子行程：禁止 `BeginErrorReadLine` + PowerShell script block

### 現象

```
PSInvalidOperationException: There is no Runspace available to run scripts in this thread.
```

整個 `pwsh` 行程崩潰。

### 原因

`$process.add_ErrorDataReceived({ ... })` 的 script block 在 .NET 背景執行緒執行，該執行緒沒有 PowerShell Runspace。

### 規則

- `Invoke-FfmpegWithProgress`：**不要** `RedirectStandardError = $true` + `BeginErrorReadLine` + script block。
- 設 `RedirectStandardError = $false`，讓 ffmpeg 錯誤直接進主控台。
- 進度只讀 `stdout`（`-progress pipe:1`）。

## 4. ffmpeg 裁切（stream copy）參數順序

### 錯誤寫法（會裁出超大檔或幾乎整支影片）

```powershell
-ss $Start -i $Input -t $Duration -c copy
# 或
-i $Input -ss $Start -to $End -c copy   # 慢，從頭解碼
```

### 正確寫法（快速、只複製片段）

```powershell
-ss $Start -to $End -i $InputPath -map 0:v:0 -map 0:a:0? -c copy ...
```

`-ss` 與 `-to` 都必須在 `-i` **前面**（input options）。

## 5. yt-dlp 進度：不要加 `--newline`

`--newline` 會讓每次進度更新都換行。只要單行更新，保留 `--progress`、**移除** `--newline`。

## 6. 暫存檔續跑與驗證

| 檔案 | 行為 |
|------|------|
| `temp-clip-....mp4` | 存在則跳過 yt-dlp 下載；下載失敗但檔案可用也繼續 |
| `trim-clip-....mp4` | 通過 `Test-UsableTrimFile` 才跳過裁切 |

`Test-UsableTrimFile` 會拒絕異常大的裁切檔（例如 32 秒片段卻有 1103 MB），並強制重新裁切。

## 7. 整體流程（無 HLS 備援路徑）

```
yt-dlp 整支下載 → temp-*.mp4
    ↓
ffmpeg stream copy 裁切 → trim-*.mp4   （進度：[TRIM]）
    ↓
ffmpeg NVENC 轉檔 → clip-*.mp4          （進度：[ENC]）
```

HLS 路徑跳過裁切，yt-dlp 直接下載片段後只做 `[ENC]` 轉檔。

## 8. HLS 偵測需要 Deno，不可強制 `--js-runtimes node`

### 現象

手動 `yt-dlp -F` 看得到 `m3u8`，但 `Test-VideoHasHls` 回報沒有 HLS。

### 原因

YouTube 的 m3u8 清單需透過 **Deno** 解 JS challenge，且 yt-dlp 會做**額外 API 請求**才列出 m3u8。

若走快取的 `android vr` 精簡路徑（第二次 `-F` 常見），會**跳過** `Downloading player`、`[jsc:deno]`、`Downloading m3u8 information`，格式表只剩 `https`（DASH）。這不是影片沒有 HLS，而是 yt-dlp 沒去查。

### 規則

- HLS **檢查**必須加：`--no-cache-dir` + `--extractor-args youtube:player_client=web_safari,default`
- HLS **下載**也要加：`--extractor-args youtube:player_client=web_safari,default`
- 用 `Get-DenoExecutable` 找 Deno（PATH + `%USERPROFILE%\.deno\bin` 等常見路徑）。
- PATH 已有 `deno` 時**不要**傳 `--js-runtimes`（yt-dlp 預設啟用 deno）。
- 必須傳路徑時用 `deno:C:/Users/.../deno.exe`（**正斜線**），避免 `deno:C:\` 被截斷。
- **不要**在沒有 Deno 時強制 `--js-runtimes node`。
- HLS 檢查用 `yt-dlp -J` 解析 `formats[].protocol`，不要只靠 `-F | Out-String` 搜尋 `m3u8` 字串。
- `Test-VideoHasHls` 應以多組 js runtime 參數重試（原參數、空參數、`deno`、`deno:/path`）。

## 9. 改完必做

1. 確認語法：`pwsh -NoProfile -File yt-best.ps1`（應 Usage 錯誤，非 ParserError）
2. 提醒使用者執行 `.\install.ps1` 更新 `~/.local/bin` 的副本
