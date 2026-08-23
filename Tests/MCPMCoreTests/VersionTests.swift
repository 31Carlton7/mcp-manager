import Testing
import Foundation
@testable import MCPMCore

@Test func versionIsSemver() {
    let range = MCPMVersion.current.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression)
    #expect(range != nil, "MCPMVersion.current must be MAJOR.MINOR.PATCH, got \"\(MCPMVersion.current)\"")
}
