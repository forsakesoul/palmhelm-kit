import Testing
import Foundation
@testable import PalmhelmKit

@Suite struct ScreenTests {
    @Test func decodesOkAndUnavailable() throws {
        let ok = try JSONDecoder().decode(ScreenSnapshot.self, from: Data(#"{"status":"ok","revision":"0123456789abcdef","t":1,"cols":120,"rows":40,"lines":["⏺ Bash(pnpm test)","  ⎿  Running…"],"truncated":false}"#.utf8))
        #expect(ok.isOK && ok.lines?.count == 2 && ok.hidden == nil)
        let un = try JSONDecoder().decode(ScreenSnapshot.self, from: Data(#"{"status":"unavailable"}"#.utf8))
        #expect(!un.isOK && un.lines == nil)
        let hidden = try JSONDecoder().decode(ScreenSnapshot.self, from: Data(#"{"status":"ok","revision":"x","t":1,"lines":["（内容已隐藏）"],"truncated":false,"hidden":true}"#.utf8))
        #expect(hidden.hidden == true && hidden.lines?.count == 1)
    }
}
