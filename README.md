# gijiroku-taker

ローカル LLM で動く、macOS 用のリアルタイム議事録アプリ。

## やりたいこと

- システム音声とマイクを同時にキャプチャ
- リアルタイム文字起こし（Whisper, on-device）
- リアルタイム要約。会議中に「今までの議論」が累積・更新されるサマリ
- トピック切り替えの自動セクション区切り
- 質問・決定事項・アクション（担当者）のリアルタイム抽出
- すべてオフライン、クラウド送信なし

## ステータス

MVP。Core ロジックは動作確認済み。音声パイプラインの実機 E2E は未確認（権限プロンプト承認 + 録音 + WhisperKit 初回モデル DL が必要）。

| 機能 | 状態 |
|---|---|
| 累積サマリ生成（Ollama） | テスト緑 |
| 質問・決定・アクション抽出（Ollama） | テスト緑 |
| セッション永続化 + Markdown エクスポート | テスト緑 |
| Core Audio Taps（システム音声） | 実装済み、未通電確認 |
| AVAudioEngine（マイク） | 実装済み、未通電確認 |
| WhisperKit ストリーミング転写 | 実装済み、未通電確認 |
| 話者分離 | 未着手（v2） |
| トピック切替検出 | サマリプロンプトに含む（精度は要評価） |
| 自動提案 | 未着手（v1.5） |

## 構成

| 層 | 技術 |
|---|---|
| 言語 | Swift / SwiftUI |
| 文字起こし | [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)（Metal） |
| 音声キャプチャ | Core Audio Taps（macOS 14.4+）+ AVAudioEngine |
| LLM | Ollama HTTP API（差し替え可能。将来 mlx-swift 検討） |
| 永続化 | ローカルファイル（JSON + Markdown） |

```
Sources/
├── GijirokuCore/          # テスト可能なロジック層
│   ├── Audio/             # AudioChunk
│   ├── Transcription/     # TranscriptSegment, TranscriptionEngine
│   ├── LLM/               # LLMClient, OllamaClient, SummaryEngine, EventExtractor
│   └── Persistence/       # Session, FileSessionStore
└── GijirokuTaker/         # SwiftUI App + 音声デバイス層
    ├── App.swift, AppModel.swift
    ├── UI/                # RootView, TranscriptPane, SummaryPane, EventPane
    ├── Audio/             # AudioCaptureEngine, SystemAudioTap, MicrophoneCapture, AudioChunkBuilder
    └── Transcription/     # WhisperTranscription
```

## 前提条件

- macOS 15 以降（Apple Silicon 推奨）
- Xcode 26 以降
- Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`（約 688 MB、MLX バックエンドに必須）
- Ollama バックエンドを使う場合のみ: [Ollama](https://ollama.com) インストールと `ollama pull qwen2.5:7b`

## セットアップ

```bash
# 1) 初回のみ Metal Toolchain をダウンロード
xcodebuild -downloadComponent MetalToolchain

# 2) アプリビルドと .app パッケージング（xcodebuild 経由で metallib も同梱）
scripts/bundle.sh            # debug ビルド版
# or
scripts/bundle.sh release    # 高速版

# 3) 起動
open build/GijirokuTaker.app
```

初回 Start 押下時に WhisperKit がモデルを HuggingFace から自動 DL、MLX バックエンドの場合は選択された LLM モデル（数 GB）も同様に DL する。マイク権限とシステム音声権限のプロンプトに「許可」する。

## LLM バックエンド

設定画面（`Cmd+,`）から切替可能。

| バックエンド | 特徴 |
|---|---|
| MLX (デフォルト) | mlx-swift-lm + HuggingFace Hub。Ollama 不要、初回モデル DL のみネット必須、その後完全オフライン |
| Ollama | 外部 Ollama サーバー (`http://127.0.0.1:11434`)。事前に `ollama pull` 必要 |

モデルは設定画面の Picker から選択。MLX は推奨モデル（Qwen3-4B-4bit ほか）のキュレートリスト、Ollama は `/api/tags` で取得した実際にインストール済みのモデルが表示される。

## テスト

```bash
# ユニットテスト
swift test

# Ollama を使う統合テスト（qwen2.5:7b 必須）
RUN_OLLAMA_TESTS=1 swift test --filter "ollama"
```

## アーキテクチャの要点

`AppModel`（@MainActor）が中央で以下を回す。

1. `AudioCaptureEngine` がシステム音声＋マイクを 1 秒チャンクで吐く（16kHz mono PCM にリサンプル済み）
2. `WhisperTranscription` actor がチャンクをローリングバッファに貯め、5 秒ごとに直近 25 秒を Whisper に投げて `TranscriptSegment` を流す
3. `AppModel` が確定セグメントを `pendingForSummary` に貯める
4. 30 秒ごとに `SummaryEngine.ingest` と `EventExtractor.extract` を並列で叩く
5. サマリは「現在の累積サマリ JSON＋未要約区間」を Qwen に渡して**差分更新**させる（全文再要約しない、トピック切替時に新セクション作成）
6. UI は SwiftUI の `@Published` で 3 ペイン（字幕／サマリ／イベント）を反応的に表示
7. Stop 時にセッション全体を JSON で永続化、Markdown エクスポート可

## 残作業 / 既知の制限

- システム音声タップが macOS 26 Tahoe で不通。Core Audio Taps の IO callback が初回 1 frame のみで止まる挙動を確認。`stereoGlobalTapButExcludeProcesses` / `stereoMixdownOfProcesses(running)` / `stereoMixdownOfProcesses(all)` の 3 パターンすべて再現。**ScreenCaptureKit (`SCStream` audio only) ベースの実装に切替が必要**（v2）。現状はデフォルト OFF で、マイク経由で会議音声を取り込む運用を推奨
- 話者分離未実装（SpeakerKit を統合する余地あり）
- WhisperKit がローリングバッファのチャンクを再転写するので、同じ区間が複数回 emit されて UI に重複表示される可能性。LocalAgreement 方式の確定検出に未対応
- `isFinal=true` の確定セグメント判定が未実装。現状は全部 interim 扱いだがサマリ対象に加算してしまっている → 精度に影響
- ハルシネーション抑制は文字列リストでハードコード。VAD ベースの根本解決に置換すべき
- Sandbox / Hardened Runtime 未設定（ad-hoc 署名のみ）
- 自動提案（疑問が出た→過去のノート参照、決定→確認 UI 等）未着手
