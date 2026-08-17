import Testing
import Foundation
@testable import MCPMGateway

@Test func pkceChallengeMatchesTheRFC7636Vector() {
    // RFC 7636 appendix B.
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func pkceVerifierIsUnreservedAndWithinLength() {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    for _ in 0..<50 {
        let v = PKCE.verifier()
        #expect(v.count >= 43 && v.count <= 128)
        #expect(v.rangeOfCharacter(from: allowed.inverted) == nil)
    }
}

@Test func pkceVerifiersAndStatesAreUnique() {
    let verifiers = Set((0..<200).map { _ in PKCE.verifier() })
    #expect(verifiers.count == 200)
    let states = Set((0..<200).map { _ in PKCE.state() })
    #expect(states.count == 200)
}

@Test func pkceStateIsBase64URLWithoutPadding() {
    let s = PKCE.state()
    #expect(s.count == 43)
    #expect(!s.contains("="))
    #expect(!s.contains("+"))
    #expect(!s.contains("/"))
}

@Test func base64URLEncodingDropsPaddingAndURLUnsafeCharacters() {
    // 0xFB 0xFF 0xBF is "+/+/" territory in standard base64.
    let data = Data([0xFB, 0xFF, 0xBF, 0x00])
    #expect(data.base64EncodedString() == "+/+/AA==")
    #expect(data.base64URLEncodedString() == "-_-_AA")
}
