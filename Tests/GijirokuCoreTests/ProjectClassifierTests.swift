import Testing
import Foundation
@testable import GijirokuCore

@Test func parsesProjectNameField() throws {
    let json = "{\"projectName\":\"Acme Renewal\",\"reason\":\"matches renewal discussion\"}"
    let chosen = try ProjectClassifier.parse(response: json)
    #expect(chosen == "Acme Renewal")
}

@Test func parsesAlternateProjectFieldNames() throws {
    let snakeCase = "{\"project_name\":\"Alpha\"}"
    #expect(try ProjectClassifier.parse(response: snakeCase) == "Alpha")

    let bare = "{\"project\":\"Beta\"}"
    #expect(try ProjectClassifier.parse(response: bare) == "Beta")

    let nameOnly = "{\"name\":\"Gamma\"}"
    #expect(try ProjectClassifier.parse(response: nameOnly) == "Gamma")
}

@Test func parsesNoneSentinel() throws {
    let json = "{\"projectName\":\"none\"}"
    let chosen = try ProjectClassifier.parse(response: json)
    #expect(chosen == "none")
}

@Test func tolerantToProseWrappingJSON() throws {
    let raw = """
    Here is the result:
    {"projectName":"Acme Renewal"}
    Let me know if you need more detail.
    """
    let chosen = try ProjectClassifier.parse(response: raw)
    #expect(chosen == "Acme Renewal")
}

@Test func tolerantToThinkBlock() throws {
    let raw = """
    <think>
    The summary mentions invoicing and Acme; that maps to Acme Renewal.
    </think>
    {"projectName":"Acme Renewal"}
    """
    let chosen = try ProjectClassifier.parse(response: raw)
    #expect(chosen == "Acme Renewal")
}

@Test func matchesByExactName() {
    let candidates: [ProjectClassifier.Candidate] = [
        .init(id: UUID(), name: "Acme Renewal"),
        .init(id: UUID(), name: "Onboarding 2026"),
    ]
    let id = ProjectClassifier.match(name: "Acme Renewal", against: candidates)
    #expect(id == candidates[0].id)
}

@Test func matchIsCaseInsensitiveAndWhitespaceTolerant() {
    let id = UUID()
    let candidates: [ProjectClassifier.Candidate] = [
        .init(id: id, name: "Acme   Renewal"),
    ]
    #expect(ProjectClassifier.match(name: "  acme renewal ", against: candidates) == id)
}

@Test func matchReturnsNilForNoneSentinel() {
    let candidates: [ProjectClassifier.Candidate] = [
        .init(id: UUID(), name: "Acme"),
    ]
    #expect(ProjectClassifier.match(name: "none", against: candidates) == nil)
    #expect(ProjectClassifier.match(name: "None", against: candidates) == nil)
    #expect(ProjectClassifier.match(name: "NONE", against: candidates) == nil)
}

@Test func matchReturnsNilForEmptyName() {
    let candidates: [ProjectClassifier.Candidate] = [
        .init(id: UUID(), name: "Acme"),
    ]
    #expect(ProjectClassifier.match(name: "", against: candidates) == nil)
    #expect(ProjectClassifier.match(name: "   ", against: candidates) == nil)
}

@Test func matchReturnsNilWhenNameDoesNotExist() {
    let candidates: [ProjectClassifier.Candidate] = [
        .init(id: UUID(), name: "Acme"),
    ]
    // LLM hallucinated a project name; classifier must refuse to invent one.
    #expect(ProjectClassifier.match(name: "Initech", against: candidates) == nil)
}

@Test func throwsOnEmptyResponse() {
    #expect(throws: LLMParseError.self) {
        _ = try ProjectClassifier.parse(response: "   ")
    }
}

@Test func returnsEmptyStringWhenNoFieldFound() throws {
    // Schema-shaped object but with an unrelated key — parser should not
    // throw (it's still valid JSON) but should yield an empty pick that
    // `match(...)` then translates into "no classification".
    let chosen = try ProjectClassifier.parse(response: "{\"foo\":\"bar\"}")
    #expect(chosen.isEmpty)
}

@Test func classifyReturnsNilWithNoCandidates() async throws {
    let classifier = ProjectClassifier(
        client: StubLLMClient(response: "{\"projectName\":\"Anything\"}"),
        config: .init(model: "test")
    )
    let result = try await classifier.classify(
        summary: CumulativeSummary(sections: [.init(title: "T", bullets: ["x"])]),
        title: nil,
        candidates: []
    )
    #expect(result == nil)
}

@Test func classifyReturnsNilWithEmptySummary() async throws {
    let classifier = ProjectClassifier(
        client: StubLLMClient(response: "{\"projectName\":\"Acme\"}"),
        config: .init(model: "test")
    )
    let id = UUID()
    let result = try await classifier.classify(
        summary: CumulativeSummary(),
        title: nil,
        candidates: [.init(id: id, name: "Acme")]
    )
    #expect(result == nil)
}

@Test func classifyPicksMatchedCandidate() async throws {
    let classifier = ProjectClassifier(
        client: StubLLMClient(response: "{\"projectName\":\"Acme Renewal\"}"),
        config: .init(model: "test")
    )
    let acmeID = UUID()
    let result = try await classifier.classify(
        summary: CumulativeSummary(sections: [.init(title: "T", bullets: ["renewal terms"])]),
        title: "Acme review",
        candidates: [
            .init(id: acmeID, name: "Acme Renewal"),
            .init(id: UUID(), name: "Onboarding"),
        ]
    )
    #expect(result == acmeID)
}

@Test func classifyHonorsNoneSentinel() async throws {
    let classifier = ProjectClassifier(
        client: StubLLMClient(response: "{\"projectName\":\"none\"}"),
        config: .init(model: "test")
    )
    let result = try await classifier.classify(
        summary: CumulativeSummary(sections: [.init(title: "T", bullets: ["unrelated"])]),
        title: nil,
        candidates: [.init(id: UUID(), name: "Acme")]
    )
    #expect(result == nil)
}

// MARK: - Test helpers

private struct StubLLMClient: LLMClient {
    let response: String

    func chat(
        model: String,
        messages: [LLMMessage],
        format: LLMResponseFormat,
        maxTokens: Int
    ) async throws -> String {
        response
    }
}
