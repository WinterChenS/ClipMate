[中文](README.md) | [**日本語**](README.ja.md) | [한국어](README.ko.md) | [English](README.en.md)

# ClipMate - macOS クリップボードマネージャー

macOS向けPasteアプリの高忠実度クローン。ネイティブSwift 6 + SwiftUI/AppKitで開発。

![ClipMate プレビュー](assets/screenshots/preview.jpg)

> ✅ **Xcode不要！** `swift build` + `build.sh` で直接コンパイル＆パッケージング。Apple SiliconとIntel Macの両方に対応。

## 機能一覧

| モジュール | 機能 | ステータス |
|-----------|------|-----------|
| 📋 クリップボード監視 | テキスト・画像・ファイル・リンク・リッチテキストのリアルタイム監視 | ✅ |
| 📜 履歴パネル | 横スクロールカードリスト、高忠実度Paste UI、ドミナントカラー抽出 | ✅ |
| 🔍 全文検索 | FTS5全文インデックス、300msデバウンスリアルタイム検索 | ✅ |
| 📌 ピンボード | ピン留めボードのグループ管理、カラーラベル、右クリック削除/リネーム | ✅ |
| ⭐ お気に入り | 重要なクリップボード項目のブックマーク | ✅ |
| ⌨️ グローバルホットキー | ⌘⇧V でパネル表示切替（Carbon RegisterEventHotKey） | ✅ |
| 🚫 アプリ除外 | パスワードマネージャーなどの機密アプリを除外 | ✅ |
| ⚙️ 環境設定 | ログイン時起動 / Dockアイコン / 通知 / ストレージ管理 / データエクスポート | ✅ |
| ☁️ iCloud同期 | iCloud Driveユビキティコンテナ同期（Xcode署名が必要） | ✅ |
| 🔐 アクセシビリティ検出 | 権限喪失時の自動アラート、再インストール後の再認証ガイド | ✅ |
| 🎨 アプリアイコン | メニューバー + Dockアイコン、フルサイズicns | ✅ |

## ビルドと実行

### 方法1：build.sh ワンクリックビルド（推奨）

```bash
cd PasteClone

# ユニバーサルバイナリ（デフォルト、Mシリーズ + Intel Mac両対応）
./build.sh

# Apple Siliconのみ
./build.sh --arch arm64

# Intel Macのみ
./build.sh --arch x86_64
```

ビルド成果物は `.build/` ディレクトリに格納されます：

| 成果物 | 説明 |
|--------|------|
| `ClipMate-1.0.0-Universal.dmg` | ユニバーサルバイナリ（デフォルト） |
| `ClipMate-1.0.0-ARM.dmg` | Apple Siliconのみ |
| `ClipMate-1.0.0-Intel.dmg` | Intel Macのみ |

**サブコマンド**：

```bash
./build.sh build       # コンパイルのみ
./build.sh bundle      # コンパイル + .app パッケージ + 署名
./build.sh dmg         # フルパイプライン（デフォルト）
./build.sh run         # コンパイルして実行
./build.sh clean       # ビルド成果物をクリーン
```

### 方法2：手動ビルド

```bash
# リリースビルド
swift build -c release

# 実行
.build/release/ClipMate
```

### 方法3：Xcode（Xcode + 開発者アカウントが必要）

```bash
open PasteClone.xcodeproj
# ⌘R で実行
```

> ⚠️ iCloud同期機能は、有効なProvisioning Profileを持つXcode経由でのビルドが必要です。`build.sh`ビルドでは、iCloudエンタイトルメントが自動的に削除され、起動失敗を防止します。

## 依存関係

| ライブラリ | バージョン | 用途 |
|-----------|-----------|------|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 6.29 | SQLite ORM + FTS5全文検索 |

## 技術ハイライト

- **クリップボード監視**: `NSPasteboard.changeCount` ポーリング方式（0.5秒間隔）、除外ルール対応
- **UI**: `NSPanel` HUDすりガラス背景 + SwiftUI横スクロールカードギャラリー
- **データ**: GRDB + FTS5全文インデックス、`~/Library/Application Support/ClipMate/` に保存
- **グローバルホットキー**: Carbon `RegisterEventHotKey` API（⌘⇧V）、LSUIElementモード
- **マルチアーキテクチャ**: `swift build --arch` + `lipo -create` でユニバーサルバイナリ生成
- **コード署名**: PlistBuddyでiCloudエンタイトルメントをフィルタリング後にcodesign、error 153を防止
- **Swift 6**: `@MainActor` を全面的に採用し並行処理の安全性を確保、strict concurrencyモード

## 動作環境

- **最小**: macOS 14.0 (Sonoma)
- **推奨**: macOS 15.0 (Sequoia)

## 権限について

初回起動時、**システム設定 > プライバシーとセキュリティ > アクセシビリティ** で権限を付与する必要があります。付与しない場合、クイックペースト機能は動作しません。再インストール後は、旧エントリを削除してから再度追加してください。

## ライセンス

MIT License
