//
//  Llmresponseparsingpropertytests .swift
//  BabySleepTrackerTests
//
//  Created by MacBook on 15.08.2026.
//

import Foundation
//
//  LLMResponseParsingPropertyTests.swift
//  BabySleepTrackerTests
//
//  The LLM layer can't be tested for an "exact right answer" the way the
//  rule engine can — wording varies every call. What we CAN and MUST test
//  is the contract the parser enforces around that non-determinism:
//  structural validity, safe fallbacks, and no silent data corruption
//  when the model returns something malformed. These are property tests,
//  not equality tests — they assert invariants that must hold across
//  many different inputs, not one specific golden output.
//

import Foundation
import XCTest

@testable import BabySleepTracker

final class LLMResponseParsingPropertyTests: XCTestCase {

    var sut: DefaultSleepCoachLLMAgent!

    override func setUp() {
        super.setUp()
        sut = DefaultSleepCoachLLMAgent()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Structural validity

    func test_parseResponse_withWellFormedJSON_shouldExtractAllFields() {
        let json = """
        {
          "pattern_insight": "Naps are getting more consistent this week.",
          "coach_message": "Great progress! Try keeping the first nap around 9am.",
          "alert": null,
          "confidence_note": "Prediction reliability is medium-high."
        }
        """

        let result = sut.parseResponse(json)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.patternInsight, "Naps are getting more consistent this week.")
        XCTAssertEqual(result?.coachMessage, "Great progress! Try keeping the first nap around 9am.")
        XCTAssertNil(result?.alert)
        XCTAssertEqual(result?.confidenceNote, "Prediction reliability is medium-high.")
    }

    func test_parseResponse_withNonNullAlert_shouldSurfaceIt() {
        let json = """
        {
          "pattern_insight": "Wake window is trending shorter.",
          "coach_message": "Watch for early tired cues today.",
          "alert": "Baby has been awake for over 4 hours.",
          "confidence_note": "High reliability."
        }
        """

        let result = sut.parseResponse(json)

        XCTAssertEqual(result?.alert, "Baby has been awake for over 4 hours.")
    }

    // MARK: - The model wraps JSON in markdown fences fairly often — must still parse

    func test_parseResponse_withMarkdownCodeFences_shouldStillParse() {
        let fenced = """
        ```json
        {
          "pattern_insight": "Stable pattern.",
          "coach_message": "Keep it up.",
          "alert": null,
          "confidence_note": "Good reliability."
        }
        ```
        """

        let result = sut.parseResponse(fenced)

        XCTAssertNotNil(result, "Markdown-fenced JSON is a known model quirk and must not break parsing.")
        XCTAssertEqual(result?.patternInsight, "Stable pattern.")
    }

    // MARK: - Missing fields must degrade to safe defaults, never crash or propagate nil silently

    func test_parseResponse_withMissingFields_shouldDefaultToEmptyStringsNotCrash() {
        let partial = """
        {
          "pattern_insight": "Only this field is present."
        }
        """

        let result = sut.parseResponse(partial)

        XCTAssertNotNil(result, "Partial JSON is still structurally valid JSON and should parse.")
        XCTAssertEqual(result?.patternInsight, "Only this field is present.")
        XCTAssertEqual(result?.coachMessage, "", "Missing string fields must default to empty, not crash.")
        XCTAssertEqual(result?.confidenceNote, "")
        XCTAssertNil(result?.alert)
    }

    // MARK: - Genuinely broken output must fail closed (nil), never return corrupted data

    func test_parseResponse_withMalformedJSON_shouldReturnNilRatherThanGuessing() {
        let broken = "The baby is sleeping well, confidence is high, no JSON here."

        let result = sut.parseResponse(broken)

        XCTAssertNil(result, "Non-JSON model output must fail closed instead of silently fabricating a response.")
    }

    func test_parseResponse_withEmptyString_shouldReturnNil() {
        XCTAssertNil(sut.parseResponse(""))
    }

    func test_parseResponse_withTruncatedJSON_shouldReturnNilRatherThanPartialGarbage() {
        let truncated = """
        {
          "pattern_insight": "Naps are stable",
          "coach_message": "Keep track
        """

        XCTAssertNil(sut.parseResponse(truncated), "Truncated JSON must fail closed, not return a half-parsed object.")
    }

    // MARK: - Property: whitespace and fence variations never change the extracted content

    func test_parseResponse_property_surroundingWhitespaceNeverAffectsExtractedContent() {
        let variants = [
            #"{"pattern_insight":"X","coach_message":"Y","alert":null,"confidence_note":"Z"}"#,
            "\n\n  {\"pattern_insight\":\"X\",\"coach_message\":\"Y\",\"alert\":null,\"confidence_note\":\"Z\"}  \n",
            "```json\n{\"pattern_insight\":\"X\",\"coach_message\":\"Y\",\"alert\":null,\"confidence_note\":\"Z\"}\n```",
        ]

        let results = variants.map { sut.parseResponse($0) }

        XCTAssertTrue(results.allSatisfy { $0 != nil }, "All three are valid content wrapped differently — none should fail.")
        XCTAssertTrue(
            results.allSatisfy { $0?.patternInsight == "X" && $0?.coachMessage == "Y" && $0?.confidenceNote == "Z" },
            "Formatting noise around valid JSON must never change the parsed content."
        )
    }
}
