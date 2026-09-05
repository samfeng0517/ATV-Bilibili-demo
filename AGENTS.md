# ATV Bilibili 專案指南

tvOS 16.0+ 的 Bilibili 用戶端，使用 Swift 5.0+ 與 Xcode project。

## 工作與驗證

- 依變更影響選擇檔案與檢查，不要求每次閱讀完整架構手冊。
- 一般編譯驗證使用 `fastlane build_simulator`；模擬器名稱以本機可用裝置為準，設定見 `fastlane/Fastfile`。
- 目前沒有專案測試套件。程式變更以相關編譯與操作驗證為主；純文件修改檢查 diff、連結與內容一致性。
- tvOS UI 修改在工具可用時以 Simulator 或 Apple TV 檢查 focus、遙控器操作與受影響流程；無法操作時明確回報。
- `fastlane build_unsign_ipa` 僅用於要求產出未簽署 IPA 的任務。它會清除根目錄的 `Payload`、`*.xcarchive`、`*.ipa`、`*.zip`，先確認需要保留的既有產物；不要當作一般編譯檢查。
- 在授權範圍內完成實作、必要驗證與本次變更造成的問題修正，不在第一版後停下等待確認。

## 架構與慣例

- 既有 tvOS 元件支援 focus engine；沿用 `BLButton`、`BLMotionCollectionViewCell` 等元件。`BLButton` 使用 `onPrimaryAction`。
- 影片列表優先沿用 `StandardVideoCollectionViewController`；播放器擴充沿用 `CommonPlayerPlugin`。
- API、簽章、cookie 與帳號狀態沿用 Request layer 與 `AccountManager`；依端點使用既有簽章方式。
- 修改導覽、Feed、播放器、彈幕或請求層時，按需閱讀 [架構與元件參考](docs/ARCHITECTURE.md) 對應章節；方法與精確數值以程式碼為準。
