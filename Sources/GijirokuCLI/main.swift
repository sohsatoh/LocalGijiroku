import Foundation
import AVFoundation
import GijirokuCore
import GijirokuLLM
import WhisperKit

@main
struct GijirokuCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("Usage: gijiroku-cli <audio-file>\n".utf8))
            exit(2)
        }
        let audioPath = args[1]
        let summarize = (ProcessInfo.processInfo.environment["NO_SUMMARY"] != "1")

        let modelName = ProcessInfo.processInfo.environment["WHISPER_MODEL"]
            ?? "large-v3-v20240930_626MB"
        let lang = ProcessInfo.processInfo.environment["WHISPER_LANG"] ?? "ja"

        do {
            print("==> Loading WhisperKit (model=\(modelName), first run downloads)...")
            let config = WhisperKitConfig(model: modelName)
            let whisper = try await WhisperKit(config)
            print("==> WhisperKit loaded.")

            print("==> Loading audio: \(audioPath)")
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
            let durationSec = Double(samples.count) / 16_000.0
            print("==> Audio: \(samples.count) samples (\(String(format: "%.2f", durationSec)) s at 16 kHz)")

            print("==> Transcribing (language=\(lang))...")
            let options = DecodingOptions(
                task: .transcribe,
                language: lang,
                detectLanguage: false,
                skipSpecialTokens: true,
                withoutTimestamps: false
            )
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
            print("==> Got \(results.count) transcription result(s).")

            var segments: [TranscriptSegment] = []
            let now = Date()
            var fullText = ""
            for (i, result) in results.enumerated() {
                print("  Result #\(i): \(result.segments.count) segment(s), language=\(result.language)")
                for seg in result.segments {
                    let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    print("    [\(String(format: "%.2f", seg.start))-\(String(format: "%.2f", seg.end))] \(text)")
                    guard !text.isEmpty else { continue }
                    fullText += text + " "
                    segments.append(TranscriptSegment(
                        source: .system,
                        text: text,
                        startTime: now.addingTimeInterval(TimeInterval(seg.start)),
                        endTime: now.addingTimeInterval(TimeInterval(seg.end)),
                        isFinal: true
                    ))
                }
            }
            print("==> Full transcript: \(fullText)")

            guard !segments.isEmpty else {
                FileHandle.standardError.write(Data("ERROR: transcription produced no segments\n".utf8))
                exit(3)
            }

            guard summarize else {
                print("==> NO_SUMMARY=1, skipping LLM stage.")
                exit(0)
            }

            let backendName = ProcessInfo.processInfo.environment["LLM_BACKEND"] ?? "ollama"
            let llmModel: String
            let client: any LLMClient
            switch backendName.lowercased() {
            case "mlx":
                llmModel = ProcessInfo.processInfo.environment["LLM_MODEL"] ?? "mlx-community/Qwen3-4B-4bit"
                print("==> Using MLX backend (model=\(llmModel))")
                client = MLXClient { progress in
                    let pct = Int(progress.fraction * 100)
                    if pct % 5 == 0 {
                        print("  ...downloading model \(pct)%")
                    }
                }
            default:
                llmModel = ProcessInfo.processInfo.environment["LLM_MODEL"] ?? "qwen2.5:7b"
                print("==> Using Ollama backend (model=\(llmModel))")
                client = OllamaClient()
            }

            print("==> Summarizing...")
            let summaryEngine = SummaryEngine(
                client: client,
                config: .init(model: llmModel, language: "Japanese")
            )
            let summary = try await summaryEngine.ingest(newSegments: segments)
            print("==> Summary sections: \(summary.sections.count)")
            for section in summary.sections {
                print("  ## \(section.title)")
                for bullet in section.bullets {
                    print("    - \(bullet)")
                }
            }

            print("==> Extracting events...")
            let extractor = EventExtractor(client: client, config: .init(model: llmModel))
            let events = try await extractor.extract(from: segments)
            print("==> Events: \(events.count)")
            for event in events {
                let owner = event.owner.map { " owner=\($0)" } ?? ""
                let due = event.dueDate.map { " due=\($0)" } ?? ""
                print("  [\(event.kind.rawValue)] \(event.text)\(owner)\(due)")
            }

            print("==> Done.")
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }
}
