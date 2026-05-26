# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

macOS SwiftUI app that records meetings, transcribes them with WhisperKit on-device, and produces rolling LLM summaries + extracted decisions/actions/questions with MLX (or Ollama as a backend alternative). Everything runs locally; nothing leaves the device.

## Commands you'll actually use

```bash
# Unit tests (Swift Testing, ~50 tests, all hermetic)
swift test

# Integration tests against a live Ollama (skipped unless env var is set)
RUN_OLLAMA_TESTS=1 swift test --filter "ollama"

# Run a single test
swift test --filter "TranscriptDeduper"

# Build the executable products (no .app, no Metal shaders)
swift build

# Build the .app bundle (REQUIRED for running the GUI)
bash scripts/bundle.sh           # debug
bash scripts/bundle.sh release   # release

# One-off, only the first time you build on a new machine:
xcodebuild -downloadComponent MetalToolchain   # ~688 MB, needed for MLX

# Regenerate the app icon (.icns)
bash scripts/make-icon.sh

# Launch what you just built
open build/GijirokuTaker.app

# CLI E2E runner — useful to test the audio→transcript→LLM pipeline
# without the GUI / permission prompts.
.build/debug/GijirokuCLI /path/to/audio.wav
LLM_BACKEND=mlx WHISPER_MODEL=tiny WHISPER_LANG=ja .build/debug/GijirokuCLI ...
NO_SUMMARY=1 .build/debug/GijirokuCLI audio.wav     # transcribe only
```

`swift build` alone produces a runnable executable but **MLX will crash at runtime** (`Failed to load the default metallib`). The GUI must be built through `scripts/bundle.sh` because MLX's Metal shaders only compile through `xcodebuild`, not through SwiftPM's CLI driver. The bundle script wraps the linked binary into a `.app` and copies in all SwiftPM resource bundles (`mlx-swift_Cmlx.bundle` carries `default.metallib`, `GijirokuTaker_GijirokuTaker.bundle` carries the `.lproj` strings).

## Architecture

Four SwiftPM targets, layered:

```
GijirokuCore  (no deps)         pure logic: AudioChunk, TranscriptSegment,
                                LLMClient protocol, OllamaClient,
                                SummaryEngine / EventExtractor (think-tag
                                stripping + balanced-JSON extraction),
                                SummaryStyle, Project, Session,
                                FileSessionStore, FileProjectStore
                                 │
GijirokuLLM   ─── deps on Core, MLX, HuggingFace, Tokenizers
                                MLXClient (actor) — caches loaded
                                ModelContainer keyed by model id; ignores
                                fraction>=0.99 progress callbacks to avoid
                                flashing "downloading" in the UI when the
                                model is already cached.
                                ModelCatalog: curated mlx-community list +
                                Ollama dynamic /api/tags provider.
                                 │
GijirokuTaker (app target)      AppModel @MainActor owns the live session
                                pipeline; LibraryModel.shared owns the
                                Project+Session library on disk.
                                Audio: SystemAudioCapture (ScreenCaptureKit),
                                MicrophoneCapture (AVAudioEngine),
                                AudioChunkBuilder (resample+chunk),
                                AudioCaptureEngine (orchestrator + waveform
                                multicast).
                                Transcription: WhisperTranscription actor;
                                SpeakerTracker (cross-window stable labels).
                                UI: NavigationSplitView, OnboardingView,
                                SettingsView, RecordingView, SessionDetailView.

GijirokuCLI                     headless runner for E2E pipeline tests
                                (used during development; does not work
                                with MLX because no .app bundle).
```

### Live recording data flow

1. `AppModel.startRecording` builds per-session engines from `SettingsModel` + `LibraryModel.shared.activeProjectID` (so settings/style/project changes take effect on next Start).
2. `AudioCaptureEngine.start()` returns an `AsyncStream<AudioChunk>`. The same chunks are multicast to any `subscribeWaveform()` consumers (UI level meters).
3. `WhisperTranscription.transcribe(_:)` consumes that stream, batches into a 25s rolling buffer, runs WhisperKit every 5s, optionally runs SpeakerKit on the same window, then yields `TranscriptSegment`s.
4. `AppModel.append(segment:)` runs the segments through `TranscriptDeduper` (containment + jaccard + ±12s time gate) before adding to `transcript` and `pendingForSummary`.
5. Every `summaryUpdateInterval` seconds (default 30s) `flushSummaryWindow` ships `pendingForSummary` to `SummaryEngine.ingest` (incremental — passes current summary as JSON + delta segments) and then `EventExtractor.extract`. New events are merged with `EventMerger` (kind + 20-char-prefix dedupe; later events upgrade owner/due in place, keep the original UUID so UI ordering stays stable).
6. On Stop, `generateTitle()` asks the LLM for a ≤20-char title, then `Session(projectId:, title:, ...)` is written via `FileSessionStore.save` and `LibraryModel.shared.reload()` refreshes the sidebar.

### Why the split between AppModel and LibraryModel

AppModel = the **currently recording** session, lifecycle-tied to Start/Stop. LibraryModel = persistent **library** of all sessions and projects on disk, also responsible for regenerating summaries on past sessions (`regenerateSummary(for:)`). Both publish their own `SummaryProgress` so the live recording badge and the per-session "Re-summarize" badge can run independently.

## Key design decisions you'll bump into

### Logging that actually shows up

OSLog `.info` / `.notice` are reliably suppressed when the app is launched as a SwiftPM-built bundle. The codebase uses `fputs(stderr)` for the messages we depend on during debugging (`startRecording`, `flushSummaryWindow`, `MLXClient.chat`, `SystemAudioCapture` lifecycle). Run with `nohup .../GijirokuTaker > /tmp/gijiroku_stdout.log 2>&1 &` to capture them. OSLog is still used for high-volume audio callbacks because we don't want them in stdout.

### Localization

`Sources/GijirokuTaker/Resources/{ja,en}.lproj/Localizable.strings` is shipped via SwiftPM `.process("Resources")`. All UI text goes through `L10n.string(_:)` / `L10n.format(_:_:)` / `Text(loc: "key")` / `Label(loc:systemImage:)` (defined in `UI/Localization.swift`). These reach `Bundle.module`, not `Bundle.main`. `defaultLocalization: "ja"` is set on the Package so the SPM resource bundle is wired correctly. Only two textual classes remain hard-coded — the Whisper hallucination dictionary (`WhisperTranscription.swift`) and the LLM-output prefix stripper in `AppModel.sanitizeTitle`. Both operate on model output, not user-facing strings.

### Project / Session storage

Plain JSON files under `~/Library/Application Support/GijirokuTaker/{Projects,Sessions}/`. `Session.projectId: UUID?` is optional so sessions saved before projects existed remain valid (they show under 未分類 / Unfiled). Schema changes need to keep `Codable` backwards-compatible.

### SummaryStyle resolution

Four-layer (`builtin → user → project → session`), each layer fills only fields whose string is non-empty or int is > 0. `AppModel.startRecording` and `LibraryModel.regenerateSummary` both call `SummaryStyle.resolved(user:project:session:)`.

### LLM output sanitation

`SummaryEngine.stripThinkBlocks(_:)` and `SummaryEngine.firstBalancedJSONObject(in:)` are public and reused by `EventExtractor.parse` and by `AppModel.sanitizeTitle`. Reasoning models (Qwen3 etc.) emit `<think>...</think>` and prose around the JSON; both are stripped.

### SwiftUI view identity

`SessionDetailView` is parameterised by `session: Session` but stores `@State var loadedSession` initialized from `init`. Without `.id(sessionID)` on the parent, SwiftUI re-uses the same instance and the panes look frozen when switching sessions. `RootView` applies `.id(id)` for exactly this reason — keep it that way.

### AVAudioEngine voice processing ducking

Apple's VoiceProcessingIO ducks other system audio (i.e. the meeting audio you're recording) by default. We set `voiceProcessingOtherAudioDuckingConfiguration` to `.min` and default the toggle to OFF — headphones is the recommended setup.

## Known constraints / surprises

### Core Audio Taps don't work on macOS 26 Tahoe

Apple Developer Forums #825780 documents the regression: the IO callback delivers one frame and then stops, regardless of `stereoGlobalTapButExcludeProcesses` vs. `stereoMixdownOfProcesses(allProcesses)`. The app uses ScreenCaptureKit (`SystemAudioCapture.swift`) instead; the `.screen` output is added with a 1 fps `minimumFrameInterval` because SCStream refuses to deliver audio-only.

### AudioBufferList is a flexible-array struct

`UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)` only allocates space for one `mBuffers` slot. Passing this to `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` with non-interleaved stereo writes a second slot past the end and corrupts the malloc heap (the crash surfaces minutes later in `_CFBundleCreate`). `SystemAudioCapture.toAVAudioPCMBuffer()` allocates `MemoryLayout<AudioBufferList>.size + (channels-1) * MemoryLayout<AudioBuffer>.size` bytes via `UnsafeMutableRawPointer.allocate(byteCount:alignment:)`.

### SpeakerKit's SpeakerEmbedding is internal

Cross-window speaker continuity uses `SpeakerTracker` (time-overlap clustering between rolling Whisper windows), not embeddings. Trade-offs are documented in the file's header comment.

### AVAudioConverter .endOfStream is sticky

Across calls if you reuse the converter. `AudioChunkBuilder.convertToMono16k` calls `converter.reset()` every time — without it the first chunk converts, then every subsequent chunk returns 0 frames.

### macOS 14.4 availability guards are gone

The audio stack no longer carries `@available(macOS 14.4, *)` because the Package targets `.macOS(.v15)` (Swift 6.0 PackageDescription). If we ever lower the deployment target we'd need to re-introduce availability guards on `SystemAudioCapture` and SCStream usage.

## Repository conventions

- Comments explain **why**, not what. Don't add `// MARK:` proliferation or restate the function name.
- New user-facing text always goes via `L10n` + both `Localizable.strings`. Code review hint: `grep -rEn '"[^"]*[ぁ-んァ-ヶ一-龯][^"]*"' Sources/GijirokuTaker/UI/` should return zero hits (it's currently dry-run clean — only LLM-output parsers and the Whisper hallucination dictionary contain hard-coded Japanese, and they're not UI strings).
- Tests live in `Tests/GijirokuCoreTests/` (Swift Testing, not XCTest). The Core layer is what's worth unit testing; audio IO and SwiftUI views are integration-tested manually via the CLI runner and the bundled app.

## Auto-commit policy

Claude Code commits proactively, at appropriate granularity, without waiting for the user to ask. The goal is a clean, readable `git log` that a future contributor can scan for context.

Commit after each coherent unit of work lands and builds + tests green. "Coherent" means one feature, one bug fix, or one refactor — not "everything I did in this session".

Granularity rules of thumb:

- Each commit should pass `swift test` on its own.
- One feature touching N files → one commit, even if N is large. Don't artificially split.
- Two unrelated changes → two commits, even if they touch overlapping files (use `git add -p` or stage individual files).
- Pure refactors (rename, extract) go in their own commit, separate from behavior changes.
- Docs / strings / config tweaks that accompany a feature ride along in that feature's commit. Standalone doc-only changes get their own `docs:` commit.

Commit messages use Conventional Commit prefixes (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`). Subject line ≤ 72 chars, present-tense imperative. The body explains the *why* — what changed is in the diff.

Include `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` at the end of every Claude-authored commit as the co-authorship trailer.

Never commit build artifacts (`build/`, `.build/`, `xcode-build/`), local model caches, recordings, or anything matching `.gitignore`. Re-run `git status` before staging to confirm.

Only push when the user explicitly asks; commits accumulate locally otherwise.

## Docs hygiene after each change

After landing a coherent unit of work, check whether `README.md` and this
`CLAUDE.md` still describe reality and update them when they don't. Diff-
based minimal edits — don't rewrite, don't reorganize, just fix what's
stale. Triggers worth thinking about:

- Public API shape change (new method on `SummaryEngine` /
  `EventExtractor`, renamed lifecycle hook in `AppModel`, new persistence
  store, etc.)
- New command, env var, or build step in `scripts/`
- Architectural shift (e.g. transcription mode changes, new actor on the
  hot path, new on-disk directory under Application Support)
- Settings / config additions, removed dependencies, model defaults
  flipping

When skipping a doc update, that's a positive decision, not the default —
sanity-check that the existing wording still matches the new behaviour
before moving on.
