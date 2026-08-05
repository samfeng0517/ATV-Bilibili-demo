# ATV-Bilibili-demo CDN 功能紀錄

## 目標

在不破壞 Bilibili 原始播放 URL 與 fallback 機制的前提下，提供可由 Apple TV APP 管理的 CDN 節點功能：

- APP 既有「音視訊」區塊內的 CDN 設定。
- 支援多個手動節點。
- 可選擇自動、指定節點或僅使用 Bilibili 原始節點。
- 定期自動更新遠端節點清單。
- 從 GitHub JSON 下載 CDN 清單。
- 自訂節點失效時仍可回退到原始 `base_url` 與 `backup_url`。

## 修改方向

### 節點資料與設定

- 以 Codable model 表示節點名稱、hostname、來源與穩定 ID。
- 手動節點、GitHub 節點、目前選擇、更新開關、清單網址及更新時間皆保存於 `UserDefaults`。
- 內建節點：`cn-jxnc-cmcc-bcache-06.bilivideo.com`。
- 驗證 hostname、排除重複項目，並限制單次遠端清單最多匯入 50 個節點。

### APP 設定頁

- 所有 CDN 選項直接展開在「設定 → 音視訊」區塊，不另開獨立頁面。
- 可新增、編輯及刪除多個手動節點。
- 節點選單包含：
  - 自動選擇：由既有 CDN 測速流程擇優。
  - 僅使用 Bilibili 原始節點。
  - 指定某個內建、手動或 GitHub 節點。
- 可編輯 GitHub 清單網址、立即更新、切換每 24 小時自動更新，以及清除已下載清單。

### GitHub 清單更新

- 預設來源為 repository `main` 分支根目錄的 `cdn-list.json`。
- 接受 `github.com` 與 `raw.githubusercontent.com` 的 HTTPS 網址。
- 一般 GitHub `blob` 網址會轉換成 raw content 網址。
- 支援包裝物件、物件陣列或 hostname 字串陣列三種 JSON 格式。
- APP 啟用時檢查是否超過 24 小時並自動更新；同時發生的更新會合併成同一個請求。
- 遠端更新不覆蓋手動節點，清單變更時會修正已失效的遠端節點選擇。

### 播放流程

- 使用 `URLComponents` 僅替換 DASH `base_url` 的 hostname，保留 scheme、path、query、簽名參數與 fragment。
- 候選順序為「自訂節點 URL → 原始 base URL → 原始 backup URLs」，並依序去重。
- 固定節點模式會將指定 hostname 作為 SIDX 與起播首選。
- 自動模式將所有有效節點交由 `CDNDiagnostics` 實測選速；起播採小樣本並行測速，
  總等待時間受單次請求超時約束，並短暫快取勝出節點，避免隨清單節點數量線性增加。
- SIDX 或分段從自訂節點取得失敗時，繼續嘗試完整保留的 Bilibili 原始候選。
- 以 `[CustomCDN]` Console log 記錄注入順序、候選順序、更新結果與實際成功 hostname，不記錄 token 或 cookie。

## 主要檔案

- `BilibiliLive/Component/CDNNodeStore.swift`
- `BilibiliLive/Component/Settings.swift`
- `BilibiliLive/Module/Personal/SettingsViewController.swift`
- `BilibiliLive/Component/Player/BilibiliVideoResourceLoaderDelegate.swift`
- `BilibiliLive/Component/Video/Plugins/BVideoPlayPlugin.swift`
- `BilibiliLive/AppDelegate.swift`
- `cdn-list.json`

## 驗證

- 使用 `BilibiliLive` scheme 對 generic tvOS Simulator 執行無簽章 build。
- 執行 `git diff --check` 與 JSON 格式檢查。
- 確認未修改 Team ID、Bundle Identifier、簽章設定或 dependency。
- 實機測試時檢查 `[CustomCDN]` log，確認節點注入、SIDX 成功 hostname、分段 hostname 與原始 URL fallback。
