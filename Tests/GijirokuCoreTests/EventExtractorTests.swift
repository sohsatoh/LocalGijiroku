import Testing
import Foundation
@testable import GijirokuCore

@Test func parsesAllEventKinds() throws {
    let json = """
    {"events":[
      {"kind":"action","text":"Update docs","owner":"alice","due":"Friday"},
      {"kind":"question","text":"Which DB do we use?"},
      {"kind":"decision","text":"Adopt Postgres"}
    ]}
    """
    let events = try EventExtractor.parse(response: json)
    #expect(events.count == 3)
    #expect(events[0].kind == .action)
    #expect(events[0].owner == "alice")
    #expect(events[0].dueDate == "Friday")
    #expect(events[1].kind == .question)
    #expect(events[1].owner == nil)
    #expect(events[2].kind == .decision)
}

@Test func parsesEmptyEventsArray() throws {
    let events = try EventExtractor.parse(response: "{\"events\":[]}")
    #expect(events.isEmpty)
}

@Test func dropsUnknownKind() throws {
    let json = """
    {"events":[{"kind":"banter","text":"hello"},{"kind":"action","text":"do thing"}]}
    """
    let events = try EventExtractor.parse(response: json)
    #expect(events.count == 1)
    #expect(events[0].kind == .action)
}

@Test func normalizesEmptyOwnerToNil() throws {
    let json = """
    {"events":[{"kind":"action","text":"X","owner":"","due":""}]}
    """
    let events = try EventExtractor.parse(response: json)
    #expect(events.count == 1)
    #expect(events[0].owner == nil)
    #expect(events[0].dueDate == nil)
}

@Test func tolerantToUppercaseKind() throws {
    let events = try EventExtractor.parse(response: "{\"events\":[{\"kind\":\"ACTION\",\"text\":\"X\"}]}")
    #expect(events.count == 1)
    #expect(events[0].kind == .action)
}
