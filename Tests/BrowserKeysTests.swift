import AppKit
import Testing

struct BrowserKeysTests {
  @Test func typedCharactersUseTheirUSKeys() {
    #expect(BrowserKeys.stroke(typing: "a") == KeyStroke(code: 0, characters: "a"))
    #expect(BrowserKeys.stroke(typing: "A") == KeyStroke(code: 0, characters: "A", modifiers: .shift))
    #expect(BrowserKeys.stroke(typing: "?") == KeyStroke(code: 44, characters: "?", modifiers: .shift))
    #expect(BrowserKeys.stroke(typing: "\n") == KeyStroke(code: 36, characters: "\r"))
    #expect(BrowserKeys.stroke(typing: "é") == KeyStroke(code: 0, characters: "é"))
  }

  @Test func namedKeysTakeModifiers() throws {
    #expect(try BrowserKeys.stroke(named: "Enter") == KeyStroke(code: 36, characters: "\r"))
    #expect(try BrowserKeys.stroke(named: "cmd+a") == KeyStroke(code: 0, characters: "a", modifiers: .command))
    #expect(try BrowserKeys.stroke(named: "cmd+shift+Z") == KeyStroke(code: 6, characters: "z", modifiers: [.command, .shift]))
    #expect(try BrowserKeys.stroke(named: "shift+ArrowLeft").modifiers == [.shift, .function, .numericPad])
    #expect(try BrowserKeys.stroke(named: "cmd++").code == 24)
    #expect(try BrowserKeys.stroke(named: "F5").code == 96)
  }

  @Test func unknownNamesThrow() {
    #expect(throws: UnknownKey.self) { try BrowserKeys.stroke(named: "Hyper+a") }
    #expect(throws: UnknownKey.self) { try BrowserKeys.stroke(named: "Bogus") }
    #expect(throws: UnknownKey.self) { try BrowserKeys.flags("cmd+fn") }
  }

  @Test func clickModifiersJoinWithPlus() throws {
    #expect(try BrowserKeys.flags("") == [])
    #expect(try BrowserKeys.flags("cmd+shift") == [.command, .shift])
  }
}
