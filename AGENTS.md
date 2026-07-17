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
| `temp-info-....json` | 一次 `-J` 的完整資訊；備援用 `--load-info-json`；成功後可刪 |
| `hls-....mp4` | 存在則跳過 HLS 下載；完成後保留 |
| `full-....mp4` | 存在則跳過整支下載，走裁切路徑；完成後保留 |
| `trim-clip-....mp4` | 通過 `Test-UsableTrimFile` 才跳過裁切；完成後保留 |

`Test-UsableTrimFile` 會拒絕異常大的裁切檔（例如 32 秒片段卻有 1103 MB），並強制重新裁切。

成功後保留所有相關 `.mp4`（`hls-` / `full-` / `trim-` / `clip-`），只刪除 `temp-info-*.json` 與 `.part` / `.ytdl` 殘檔。

## 7. 整體流程

**優先路徑（HLS）：** 只呼叫一次 `yt-dlp -J`，從 JSON 取 m3u8 URL 交給 ffmpeg。

```
yt-dlp -J（一次）→ temp-info-*.json
    ↓
ffmpeg -ss/-to -i m3u8_url -c copy → hls-*.mp4   （進度：[HLS]）
    ↓
ffmpeg NVENC 轉檔 → clip-*.mp4                    （進度：[ENC]）
```

**備援路徑（JSON 無 HLS / ffmpeg HLS 失敗）：**

```
yt-dlp --load-info-json temp-info-*.json（不重新解析）→ full-*.mp4
    ↓
ffmpeg stream copy 裁切 → trim-*.mp4   （進度：[TRIM]）
    ↓
ffmpeg NVENC 轉檔 → clip-*.mp4          （進度：[ENC]）
```

## 8. HLS：一次 `-J`，不要 `-F` 再 `-f` 重新解析

### 現象

手動 `yt-dlp -F` 有時看得到 `m3u8`，再查一次（或接著 `-f` 下載）就消失，只剩 DASH `https`，報 `Requested format is not available`。

### 原因

YouTube 的 m3u8 需透過 **Deno** 解 JS challenge，且常只在**某一次**完整解析時出現。

若先 `-F` / 取標題再 `-f` 下載，等於把「有 HLS 的那一次」用掉；後續請求常走 `android vr` 精簡路徑。

### 規則

- **主流程只呼叫一次 `yt-dlp -J`**（含 `web_safari,default` + `--no-cache-dir`），取得 title / formats / url。
- 有 HLS：把 `formats[].url`（與 `http_headers`）直接丟給 **ffmpeg** 做 `-ss/-to` 片段下載；**不要**再呼叫 yt-dlp `-f`。
- 無 HLS 或 ffmpeg HLS 失敗：用 **`yt-dlp --load-info-json`** 整支下載（重用同一份 JSON，不重新走 extractor）。
- 禁止主流程先 `Test-VideoHasHls` / `-F` 再下載。
- `-ss` / `-to` 必須在 ffmpeg `-i` **前面**（與裁切規則相同）。
- 用 `Get-DenoExecutable` 找 Deno（PATH + `%USERPROFILE%\.deno\bin` 等常見路徑）。
- PATH 已有 `deno` 時**不要**傳 `--js-runtimes`（yt-dlp 預設啟用 deno）。
- 必須傳路徑時用 `deno:C:/Users/.../deno.exe`（**正斜線**），避免 `deno:C:\` 被截斷。
- **不要**在沒有 Deno 時強制 `--js-runtimes node`。
- `Test-VideoHasHls` 僅保留作除錯；正常下載路徑不要呼叫。

## 9. 改完必做

1. 確認語法：`pwsh -NoProfile -File yt-best.ps1`（應 Usage 錯誤，非 ParserError）
2. 提醒使用者執行 `.\install.ps1` 更新 `~/.local/bin` 的副本
