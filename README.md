# yt-best

從 YouTube 下載指定時間片段，並以 NVENC 轉成可在 Windows 預覽的 MP4。

## 需求

- PowerShell
- [yt-dlp](https://github.com/yt-dlp/yt-dlp)
- [ffmpeg](https://ffmpeg.org/)（含 NVENC）
- [Deno](https://deno.com/) 或 Node.js 22+（YouTube JS 解析）

## 安裝

```powershell
.\install.ps1
```

會複製 `yt-best.ps1` 到 `%USERPROFILE%\.local\bin`，並設定 PATH / PATHEXT。

## 用法

```powershell
yt-best https://www.youtube.com/watch?v=VIDEO_ID 55:41 1:00:48
```

輸出檔名：

```text
clip-{YouTube 標題}-{開始}_{結束}.mp4
```

## 流程

1. yt-dlp 以 HLS 下載指定片段到 `temp-clip-....mp4`
2. ffmpeg NVENC H.264（CQ 35）+ 音訊 copy + faststart
3. 成功後刪除 temp 檔；中斷或失敗時保留 temp 檔
