# LocalGijiroku

[English](./README.md) | 日本語

macOS 向けの「全部ローカルで動く」議事録レコーダー。音声を録音し、WhisperKit で端末上で文字起こしし、ローリングサマリと決定事項・アクション・質問の抽出までを完結させます — マシンの外に 1 バイトも出しません。

## できること

- **マイク音声** と **システム音声** を同時にキャプチャ (Zoom / Meet の相手側の声も取り込めます)。
- **WhisperKit** でリアルタイムに多言語文字起こし (日本語・英語を重点的にチューニング)。
- 30 秒ごとに新しい transcript を **ローカル LLM** (MLX または Ollama) に渡し:
  - 話題が動くたびにセクション単位で更新される **ローリングサマリ**
  - **構造化イベント** (質問 / 決定事項 / アクションアイテム。担当者と期限が発話されていれば一緒に抽出) の抽出
- オプションで **Pyannote (SpeakerKit) による話者分離**。ローリング窓を時間オーバーラップでクラスタリングしてラベルを横断的に安定化。
- セッションは **プロジェクト** にまとめられ、ディスク上はプレーン JSON として保存。Markdown でエクスポート可。

## プライバシー

音声、transcript、サマリ、抽出されたイベントは全てこの Mac の中に留まります。ネットワーク通信は初回モデルダウンロードのみ (MLX / WhisperKit / SpeakerKit が HuggingFace から取得)。録音中のネットワークアクティビティを観察するか、`~/Library/Application Support/GijirokuTaker/` (ディスク上のフォルダ名は SwiftPM のターゲット名のまま) を覗くと検証できます。

## 動作要件

- macOS 15 (Sequoia) 以降 — macOS 26 Tahoe で動作確認済み。
- Apple Silicon Mac (MLX は Apple Silicon 専用)。
- Xcode 26 と **Metal Toolchain** コンポーネント:

  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```

- オプション: バンドルの MLX より [Ollama](https://ollama.com) を使いたい場合のみ。

## ビルドと起動

```bash
# 1. 初回のみ: Metal Toolchain をインストール (上記参照)。
# 2. .app をビルド (MLX の Metal シェーダを default.metallib にコンパイル
#    する必要があるので xcodebuild 必須)。
bash scripts/bundle.sh           # debug
bash scripts/bundle.sh release   # release

# 3. 起動。
open build/LocalGijiroku.app
```

初回 **録音開始** を押すと、macOS が **マイク** と **画面録画** の権限を要求します。画面録画は ScreenCaptureKit でシステム音声を取り込むためにだけ使用され、映像は記録しません。

MLX モデルを初めて選んだときは ~2〜5 GB が HuggingFace から `~/.cache/huggingface/hub/` にダウンロードされます。

## バックエンド

| バックエンド | セットアップ | 備考 |
| --- | --- | --- |
| **MLX** (デフォルト) | 不要 — 初回利用時にモデルが自動ダウンロード。 | アプリプロセス内で完結。`mlx-community/` 配下から Qwen3 1.7B 〜 Qwen2.5 14B を厳選収録。 |
| **Ollama** | `brew install ollama && ollama pull qwen2.5:7b` | すでに Ollama を動かしている人向け。設定 → LLM タブには `ollama list` の結果がそのまま並びます。 |

## テスト

```bash
swift test                                       # ~50 個の hermetic ユニットテスト
RUN_OLLAMA_TESTS=1 swift test --filter ollama    # 実 Ollama との integration
.build/debug/GijirokuCLI /path/to/audio.wav      # WAV ファイルからヘッドレス E2E
```

## アーキテクチャ (1 段落)

4 ターゲットの SwiftPM ワークスペース — `GijirokuCore` (音声型、永続化、LLM クライアントプロトコル、サマリ/イベントエンジン)、`GijirokuLLM` (MLX 連携、モデルカタログ)、`GijirokuTaker` (SwiftUI アプリ本体 — UI、ScreenCaptureKit + AVAudioEngine による音声キャプチャ、WhisperKit 文字起こし、SpeakerKit 話者分離)、`GijirokuCLI` (ヘッドレス E2E ランナー)。詳細な設計ノートと既知の制約は `CLAUDE.md` を参照。

## ライセンス

[MIT](./LICENSE) — 詳細はファイル参照。
