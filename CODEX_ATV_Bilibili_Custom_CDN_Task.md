# Codex 任務：為 ATV-Bilibili-demo 加入自訂 Bilibili CDN 候選節點

你正在修改一個 tvOS 專案：

- Repository: `ATV-Bilibili-demo`
- Target platform: Apple TV / tvOS
- Goal: 在不破壞原始播放與 fallback 的前提下，加入一個自訂 Bilibili CDN 候選節點
- Preferred CDN host:

```text
cn-jxnc-cmcc-bcache-06.bilivideo.com
```

請嚴格依照以下階段執行。

---

## Phase 1：只讀分析，不要修改任何檔案

先閱讀：

```text
AGENTS.md
```

接著檢查與播放、DASH URL、CDN 選擇、SIDX、AVPlayer 資源載入相關的程式碼。

優先查看：

```text
BilibiliLive/Component/Player/BilibiliVideoResourceLoaderDelegate.swift
BilibiliLive/Component/Player/CDNDiagnostics.swift
```

也請搜尋：

```text
playableURLs
cdnCandidates
preferredHost
SidxDownloader
setBilibili
base_url
backup_url
AVPlayer
AVURLAsset
```

### 分析目標

請說明：

1. 從 Bilibili `playurl` API 回傳，到 AVPlayer 實際請求影音分段的完整流程。
2. `base_url` 與 `backup_url` 在哪裡整理成候選 URL。
3. 音訊與視訊是否共用相同的 URL 候選邏輯。
4. `playableURLs`、`cdnCandidates`、`preferredHost`、`CDNDiagnostics` 與 `SidxDownloader` 之間的關係。
5. `SidxDownloader` 是否只嘗試前幾個 URL，例如 `urls.prefix(3)`。
6. 自訂 CDN URL 最安全、最小的注入點。
7. 實作需要修改哪些檔案。
8. 可能的風險與 edge cases。
9. 可用的 Xcode project、scheme 與 tvOS Simulator build 指令。

### 限制

此階段：

- 不要修改任何檔案。
- 不要建立設定頁。
- 不要修改簽名。
- 不要修改 Team ID。
- 不要修改 Bundle Identifier。
- 不要更新 dependency。
- 不要 commit。
- 不要自行假設架構，必須以目前 repository 的程式碼為準。

完成後先回報分析與實作計畫，等待我確認。

---

## Phase 2：實作最小 MVP

在我確認 Phase 1 計畫後，再開始修改。

### 功能需求

目前先硬編碼以下 preferred host：

```text
cn-jxnc-cmcc-bcache-06.bilivideo.com
```

目標行為：

1. 從原始 Bilibili DASH `base_url` 建立一個 hostname 被替換的 URL。
2. 只替換 hostname。
3. 保留以下內容不變：
   - scheme
   - path
   - query string
   - signed parameters
   - fragment
4. 自訂 CDN URL 放在原始候選 URL 前面。
5. 原始 `base_url` 與所有 `backup_url` 必須完整保留。
6. 自訂 CDN 失敗時，播放器必須可以自動 fallback 到原始 URL。
7. 不得使用 DNS override。
8. 不得加入 proxy。
9. 不得做 HTTPS interception。
10. 不得加入第三方 dependency。

### 建議候選順序

最終順序應接近：

```text
1. 從 base_url 改寫出的自訂 CDN URL
2. 原始 base_url
3. 原始 backup_url 1
4. 原始 backup_url 2
5. 其他原始 backup URLs
```

不要產生：

```text
1. 自訂 base_url
2. 自訂 backup_url 1
3. 自訂 backup_url 2
4. 原始 base_url
```

原因是如果 `SidxDownloader` 只看 `urls.prefix(3)`，前三個候選不應全部都是同一個自訂 CDN，否則會失去真正的 fallback。

### URL 改寫 helper

請建立一個小型、純函式 helper，需求如下：

- 輸入：
  - 原始 URL 字串
  - 目標 hostname
- 使用 `URLComponents`
- 僅處理：
  - `http`
  - `https`
- 原始 URL 必須存在 hostname
- 只替換 hostname
- 保留 path、query、fragment
- 不得丟失 Bilibili URL 的簽名參數
- 若原始 URL 有明確 port，替換 hostname 時移除舊 port，除非目標設定明確包含 port
- parsing 失敗時回傳 `nil`
- 不可 crash
- 不可 force unwrap

### playableURLs

調整 `playableURLs` 或目前實際負責整理 DASH URL 的等價位置：

- 先加入一個從 `base_url` 改寫出的 preferred CDN URL
- 再加入所有原始 URL
- 按順序去重
- 不要移除任何原始 fallback
- 除非目前架構有明確理由，音訊與視訊都應套用相同邏輯

### Logging

加入簡短且容易搜尋的 debug logging，至少可以看到：

```text
original host
injected preferred host
candidate URL order
actual successful host
```

建議 log prefix：

```text
[CustomCDN]
```

不要記錄 cookie、token 或其他敏感資訊。

### 修改範圍

優先只修改：

```text
BilibiliLive/Component/Player/BilibiliVideoResourceLoaderDelegate.swift
```

只有在目前實際架構確實需要時，才修改其他檔案。

禁止：

- 修改 project signing
- 修改 Team ID
- 修改 Bundle Identifier
- 修改 provisioning
- 修改 dependency
- 做無關 formatting
- 重構其他 player 邏輯
- 新增設定 UI
- 自動 commit

開始修改前，先列出你預計修改的函式與 diff 結構。

---

## Phase 3：驗證

修改完成後執行以下檢查。

### Git 檢查

```bash
git diff --check
git status --short
git diff --stat
```

確認：

- 沒有 trailing whitespace
- 沒有非預期檔案
- 沒有簽名或 project 設定被修改

### 找出正確 scheme

先執行：

```bash
xcodebuild -list -project BilibiliLive.xcodeproj
```

不要猜測 scheme 名稱。

### Build

使用實際找到的 scheme，對 tvOS Simulator build。

指令形式應接近：

```bash
xcodebuild \
  -project BilibiliLive.xcodeproj \
  -scheme "<ACTUAL_SCHEME>" \
  -sdk appletvsimulator \
  -destination "generic/platform=tvOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

若 repository 使用 workspace，請改用正確的 `.xcworkspace`。

### 回報內容

請回報：

1. 修改了哪些檔案。
2. 每個修改的目的。
3. 候選 URL 的實際排序。
4. 是否同時套用音訊與視訊。
5. `SidxDownloader` 前三個 URL 會是什麼。
6. `git diff --check` 結果。
7. `xcodebuild` 結果。
8. 所有 warning 與 error。
9. 一份精簡的 diff summary。
10. 實機 Apple TV 測試時應搜尋哪些 Console log。

不要自動 commit。

---

## Phase 4：保守 Code Review

修改與 build 完成後，請再做一次獨立 review。

此階段不要修改檔案。

Review 重點：

- Bilibili signed URL query 是否完整保留
- `URLComponents` hostname replacement 是否正確
- 原始 `base_url` 是否保留
- 所有 `backup_url` 是否保留
- `urls.prefix(3)` 是否仍包含有效原始 fallback
- 音訊與視訊是否一致
- 是否產生重複候選 URL
- 是否影響 PCDN 原有排序
- 是否影響 SIDX cache
- 是否增加不必要的起播延遲
- 是否有 actor、thread safety 或 concurrency 問題
- 是否意外修改簽名或 project file
- 是否有無關 formatting churn

先列 blocking findings，再列非 blocking findings。

最後只能以下列其中一句結尾：

```text
SAFE TO TEST ON DEVICE
```

或：

```text
NOT SAFE TO TEST ON DEVICE
```

---

## 實機測試條件

Simulator build 通過後，我會自行使用 Xcode 安裝到實體 Apple TV。

請告訴我應如何驗證：

1. 自訂 CDN 是否被注入第一順位。
2. 音訊與視訊是否都使用候選機制。
3. SIDX 是否可從自訂 CDN 成功取得。
4. 實際影音分段是否走自訂 host。
5. 自訂 CDN 故意填錯時，是否可以 fallback。
6. 快轉後是否能恢復播放。
7. 切換畫質是否正常。
8. 下一集是否正常。
9. 長時間播放是否出現重新緩衝或換線問題。

---

## 後續功能目前不要做

本次 MVP 完成前，不要實作：

- tvOS 設定頁
- 自訂 hostname 文字輸入
- 多個手動節點
- 節點選單
- 播放中手動切 CDN
- 自動更新節點清單
- 從 GitHub 下載 CDN list
- UDM SE 整合
- DNS override
- VPN routing
- HTTPS proxy
- MITM
- telemetry
- analytics

先完成最小、安全、可 fallback 的版本。
