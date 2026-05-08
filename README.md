# Rabbit Gatekeeper

瀏覽器 extension：在你選定的網站上累積使用時間到達上限時，跳出去背的兔子強制讓你休息。仿 [cat-gatekeeper](https://github.com/zokuzoku/cat-gatekeeper)。

支援 Chrome + Firefox（Manifest V3）。

## 目錄結構

```
gatekeeper/
├── extension/                成品（裝進瀏覽器）
│   ├── manifest.json
│   ├── content.js / popup.html / popup.js / shared.js / content.css
│   ├── _locales/{en,zh_TW}/messages.json
│   └── assets/
│       ├── rabbit.webm       VP9 alpha 影片
│       └── rabbiticon{16,48,128}.png
├── process_video.swift       Apple Vision 去背 pipeline 原始碼
├── process_video             編好的執行檔（macOS Apple Silicon）
├── extract_alpha.swift       單幀去背測試工具
├── tools/realesrgan/         AI 升頻工具（Real-ESRGAN）
├── rabbit.mov                原始素材（IMG_8521，備份）
└── rabbit2.mp4               目前 production 用的 Sora 影片
```

## Setup（新 Mac 第一次）

```bash
# 1. macOS 開發工具（編 swift + Apple Vision API）
xcode-select --install

# 2. ffmpeg（含 libvpx-vp9 編 alpha webm）
brew install ffmpeg

# 3. 編 process_video 執行檔
cd /path/to/gatekeeper
swiftc -O process_video.swift -o process_video

# 4. （選用）下載 Real-ESRGAN binary，如果 tools/realesrgan/ 沒帶過來
mkdir -p tools/realesrgan && cd tools/realesrgan
gh release download v0.2.5.0 --repo xinntao/Real-ESRGAN \
  --pattern "realesrgan-ncnn-vulkan-*macos.zip"
unzip -o realesrgan-ncnn-vulkan-*macos.zip
chmod +x realesrgan-ncnn-vulkan
xattr -d com.apple.quarantine realesrgan-ncnn-vulkan 2>/dev/null || true
cd ../..
```

## 安裝 extension

**Chrome / Edge / Brave**：
1. 開 `chrome://extensions/`
2. 右上角開啟「開發人員模式」
3. 點「載入未封裝項目」→ 選 `extension/` 資料夾
4. 改設定，預設 30 分鐘觸發 5 分鐘休息

**Firefox**：
1. 開 `about:debugging#/runtime/this-firefox`
2. 點「臨時載入附加元件」→ 選 `extension/manifest.json`
3. 註：Firefox 臨時載入每次重啟瀏覽器要重新載入

## 從新影片產生 rabbit.webm

完整流程（換素材或畫質不滿意時）：

```bash
# 0. 先看影片資訊（記下 fps 跟尺寸，後面會用）
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,r_frame_rate,duration \
  source.mp4

# 1. 找對的裁切區域（試幾次調參數，目標：只剩主體）
ffmpeg -y -i source.mp4 -vf "crop=W:H:X:Y" -frames:v 1 -update 1 /tmp/check.png
# 開 /tmp/check.png 看，調整 crop=W:H:X:Y 直到乾淨

# 2. 裁切影片
ffmpeg -y -i source.mp4 -vf "crop=W:H:X:Y" -c:v libx264 -crf 18 -an /tmp/cropped.mp4

# 3. Apple Vision 去背 → ProRes alpha mov
ENHANCE=0 REFINE=1 ./process_video /tmp/cropped.mp4 /tmp/alpha.mov

# 4. 解出 PNG（從 ProRes，不要從 webm，不然 alpha 會掉）
mkdir -p /tmp/frames /tmp/alpha_4x /tmp/combined
ffmpeg -y -i /tmp/alpha.mov -pix_fmt rgba /tmp/frames/%05d.png

# 5. AI 升頻 RGB（4× ；alpha 會丟掉，下一步補回）
cd tools/realesrgan
# 第一次在新 Mac 上跑被 Gatekeeper 擋的話：
chmod +x realesrgan-ncnn-vulkan
xattr -d com.apple.quarantine realesrgan-ncnn-vulkan 2>/dev/null || true
./realesrgan-ncnn-vulkan -i /tmp/frames -o /tmp/frames_4x -n realesrgan-x4plus -s 4 -f png
cd ..

# 6. alpha 用 lanczos 升頻 + 合回 RGB
ffmpeg -y -i /tmp/frames/%05d.png -vf "alphaextract,scale=W*4:H*4:flags=lanczos" /tmp/alpha_4x/%05d.png
ffmpeg -y -i /tmp/frames_4x/%05d.png -i /tmp/alpha_4x/%05d.png -filter_complex "[0:v][1:v]alphamerge" /tmp/combined/%05d.png

# 7. 編 webm（VP9 + alpha）— framerate 用 step 0 看到的數字
ffmpeg -y -framerate 30 -i /tmp/combined/%05d.png \
  -c:v libvpx-vp9 -pix_fmt yuva420p -b:v 0 -crf 30 \
  -auto-alt-ref 0 -metadata:s:v:0 alpha_mode=1 -an \
  extension/assets/rabbit.webm

# 8. 驗證 alpha 真的有編進去（看 ALPHA_MODE tag，不要看 pix_fmt）
ffprobe -v error -select_streams v:0 -show_streams extension/assets/rabbit.webm | grep -i alpha
# 要看到：TAG:ALPHA_MODE=1
# 註：ffprobe 看 pix_fmt 永遠顯示 yuv420p（不準），瀏覽器才是判讀 ALPHA_MODE 的

# 9. reload extension（chrome://extensions/ 點 ↻），F5 測試頁面
```

如果不需要升頻（影片解析度夠高），跳過 step 5–6，step 7 直接讀 `/tmp/frames/%05d.png`。

## 常見坑

- **改 extension 後沒生效**：reload extension 後**所有已開啟的測試分頁都要 F5**，不然舊的 content.js 還在跑。
- **Console 噴 `Extension context invalidated`**：上面這個原因。F5 該分頁就好。
- **alpha 變黑色矩形**：在某一步從 `.webm` 解 PNG（alpha 會掉）。永遠從 ProRes `.mov` 解。
- **Vision 把背景一起去背**：主體跟其他物件視覺連在一起。先用 ffmpeg crop 裁緊一點。
- **HEVC 沒辦法存 alpha**：別嘗試 `-c:v hevc -tag:v hvc1`。alpha 只有 ProRes 4444 跟 VP9 yuva420p 兩條路。
- **計時器一直停在 0**：分頁失焦時不累加（design）。測的時候別讓 DevTools 偷走 focus。
- **網域沒比對到**：popup 「監控的網站」要包含當前 hostname。`192.168.1.x` 之類 IP 也支援。

## process_video.swift 環境變數

| 變數 | 預設 | 作用 |
|---|---|---|
| `MASK_DIR` | (off) | 設了就讀外部 PNG mask 取代 Apple Vision |
| `MERGE_ALL` | 0 | 設 `1` 把全部偵測到的 instance 合併（多主體場景用，例如多隻兔子同框）。預設只挑最大那個 instance，單主體時對，群體時會掉旁邊的小主體 |
| `ENHANCE` | 1 | 跑 Vision 前對影格做銳化 + 對比 |
| `REFINE` | 1 | 對 mask 做空間修整（補洞 + 邊緣 blur + 軟 threshold） |
| `SMOOTH` | 1.0 | 時間平滑（< 1.0 會有拖影，**別開**） |
| `CLOSE` | 2.0 | morphological close 半徑 |
| `EDGEBLUR` | 1.0 | mask 邊緣 gaussian blur 半徑 |
| `THRESH` | 6.0 | 軟 threshold 強度 |

## extract_alpha.swift（快速單幀測試）

```bash
swiftc extract_alpha.swift -o extract_alpha
./extract_alpha video.mp4 out.png 2.5    # 第 2.5 秒抓一幀去背
```

## 重編 process_video

只有改 `process_video.swift` 才需要：

```bash
swiftc -O process_video.swift -o process_video
```

需要 Xcode Command Line Tools（`xcode-select --install`）。

## Pipeline 設計筆記

- **為什麼不用 SAM 2？** 試過了，prompt 對單一影片很脆弱，會中途 derail 把整個 bbox 當成前景。Apple Vision 對乾淨主體更穩。
- **為什麼不用 RVM？** 試過了，餵兔子直接抓不到（訓練資料偏向人）。
- **為什麼裁切？** Apple Vision 會把「視覺上連在一起的物件」當作同一個前景。Sora 影片中兔子坐在台基上，Vision 會把兔子+台基一起去背 → 先裁掉台基才行。
- **為什麼不開時間平滑？** 兔子一動就有拖影（前一幀的 mask 殘留 40% 在新位置看到黑色洞）。改用空間 morphological close 補洞穩定多了。
- **為什麼 alpha 要分開升頻？** Real-ESRGAN 不認 alpha 通道，會把 RGBA 當 RGB 處理，alpha 全變 255。必須 RGB 跟 alpha 各自升頻再 alphamerge 合回。
