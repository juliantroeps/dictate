import Foundation
import Testing

@testable import dictate

struct TextSpliceTests {
    @Test func validMidStringSplice() {
        let result = TextSplice.splice(value: "hello", range: CFRange(location: 2, length: 1), with: "X")
        #expect(result == "heXlo")
    }

    @Test func appendAtEnd() {
        let result = TextSplice.splice(value: "hi", range: CFRange(location: 2, length: 0), with: "!")
        #expect(result == "hi!")
    }

    @Test func replaceSelection() {
        let result = TextSplice.splice(value: "abcd", range: CFRange(location: 1, length: 2), with: "X")
        #expect(result == "aXd")
    }

    @Test func emptyValueZeroRange() {
        let result = TextSplice.splice(value: "", range: CFRange(location: 0, length: 0), with: "x")
        #expect(result == "x")
    }

    @Test func outOfBoundsLocationPastEnd() {
        let result = TextSplice.splice(value: "hi", range: CFRange(location: 5, length: 0), with: "x")
        #expect(result == nil)
    }

    @Test func outOfBoundsLengthExceedsString() {
        let result = TextSplice.splice(value: "hi", range: CFRange(location: 1, length: 5), with: "x")
        #expect(result == nil)
    }

    @Test func negativeLocation() {
        let result = TextSplice.splice(value: "hi", range: CFRange(location: -1, length: 0), with: "x")
        #expect(result == nil)
    }

    @Test func utf16MultibyteSplice() {
        // "café" has NSString length 4 (UTF-16); splice after the 'é' at index 4
        let value = "café"
        #expect((value as NSString).length == 4)
        let result = TextSplice.splice(value: value, range: CFRange(location: 4, length: 0), with: "!")
        #expect(result == "café!")
    }

    @Test func locationAtEndWithNonzeroLength() {
        // location == length is valid for inserts, but any length there is out of bounds
        let result = TextSplice.splice(value: "hi", range: CFRange(location: 2, length: 1), with: "x")
        #expect(result == nil)
    }

    @Test func overflowingLengthDoesNotTrap() {
        // regression for the overflow-safe additive guard
        let result = TextSplice.splice(value: "hi", range: CFRange(location: 1, length: Int.max), with: "x")
        #expect(result == nil)
    }
}
