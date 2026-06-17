import XCTest

/// Drives the first-run onboarding on a booted simulator. English is forced
/// so queries don't depend on the device locale, and the onboarding gate is
/// overridden through the argument domain so the tests never need a freshly
/// wiped container. Grant the mic up front to keep runs non-interactive:
///   xcrun simctl privacy booted grant microphone com.kunzhipeng.loqi
final class OnboardingFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchOntoRegionStep() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitest-reset-onboarding",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        app.buttons["Get Started"].tap()
        let mic = app.buttons["Allow Microphone"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        mic.tap()

        XCTAssertTrue(
            app.staticTexts["Where should models download from?"]
                .waitForExistence(timeout: 10),
            "region step should follow the permission step")
        return app
    }

    /// Region choice + model checklist render, and skipping lands in the app
    /// without starting any download.
    func testChinaRegionThenSkipLandsInApp() {
        let app = launchOntoRegionStep()

        // en_US locale ⇒ Global carries the "Suggested" badge.
        XCTAssertTrue(app.staticTexts["Suggested"].exists)

        app.staticTexts["China mainland"].tap()
        app.buttons["Continue"].tap()

        XCTAssertTrue(
            app.staticTexts["Choose what to download"].waitForExistence(timeout: 5))
        for title in [
            "Apple speech recognition",
            "Translation language packs",
            "SenseVoice live recognition",
            "Speaker recognition",
            "Qwen3.5 2B AI model",
            "Qwen3-ASR re-transcription",
        ] {
            XCTAssertTrue(app.staticTexts[title].exists, "missing row: \(title)")
        }
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Total download:'")).firstMatch.exists)

        app.buttons["Skip for now"].tap()
        XCTAssertTrue(
            app.tabBars.buttons["Record"].waitForExistence(timeout: 15),
            "skip should complete onboarding into the tab view")
    }

    /// The download step starts its queue and "Skip remaining" settles every
    /// row, revealing the finish button.
    func testDownloadStepSkipRemainingFinishes() {
        let app = launchOntoRegionStep()

        app.buttons["Continue"].tap()
        XCTAssertTrue(
            app.staticTexts["Choose what to download"].waitForExistence(timeout: 5))
        app.buttons["Download"].tap()

        XCTAssertTrue(
            app.staticTexts["Downloading models"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Apple speech recognition"].exists)
        XCTAssertTrue(app.staticTexts["Translation language packs"].exists)

        let skipRemaining = app.buttons["Skip remaining"]
        XCTAssertTrue(skipRemaining.waitForExistence(timeout: 5))
        skipRemaining.tap()

        let finish = app.buttons["Start Using Loqi"]
        XCTAssertTrue(
            finish.waitForExistence(timeout: 10),
            "skip remaining should settle all rows and reveal the finish button")
        finish.tap()
        XCTAssertTrue(app.tabBars.buttons["Record"].waitForExistence(timeout: 15))
    }

    /// Real network: SenseVoice alone (~240 MB from ModelScope) downloads to
    /// completion, which must flip the live engine to it. Named to sort
    /// last; verify afterwards with
    ///   xcrun simctl spawn booted defaults read com.kunzhipeng.loqi asr.engine
    func testSenseVoiceOnlyDownloadCompletes() {
        let app = launchOntoRegionStep()

        app.staticTexts["China mainland"].tap()
        app.buttons["Continue"].tap()
        XCTAssertTrue(
            app.staticTexts["Choose what to download"].waitForExistence(timeout: 5))

        // Leave only SenseVoice checked (Qwen3-ASR starts unchecked).
        app.staticTexts["Translation language packs"].tap()
        app.staticTexts["Speaker recognition"].tap()
        app.staticTexts["Qwen3.5 2B AI model"].tap()
        app.buttons["Download"].tap()

        XCTAssertTrue(
            app.staticTexts["Downloading models"].waitForExistence(timeout: 5))
        let finish = app.buttons["Start Using Loqi"]
        XCTAssertTrue(
            finish.waitForExistence(timeout: 600),
            "SenseVoice download should settle every row")
        finish.tap()
        XCTAssertTrue(app.tabBars.buttons["Record"].waitForExistence(timeout: 15))
    }
}
