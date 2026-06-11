import XCTest
@testable import FlowType

final class SessionStateTests: XCTestCase {

    func testStateEquatable() {
        let a: SessionState = .idle
        let b: SessionState = .idle
        XCTAssertEqual(a, b)

        let c: SessionState = .recording(elapsedSeconds: 5)
        let d: SessionState = .recording(elapsedSeconds: 5)
        XCTAssertEqual(c, d)

        let e: SessionState = .recording(elapsedSeconds: 5)
        let f: SessionState = .recording(elapsedSeconds: 10)
        XCTAssertNotEqual(e, f)
    }

    /// Every state has a distinct status title (all 7 cases covered).
    func testStateStatusTitles() {
        XCTAssertEqual(SessionState.idle.statusTitle, "准备就绪")
        XCTAssertEqual(SessionState.recording(elapsedSeconds: 0).statusTitle, "Listening...")
        XCTAssertEqual(SessionState.processing(provider: "Test").statusTitle, "Test...")
        XCTAssertEqual(SessionState.polishing(preview: "").statusTitle, "润色中...")
        XCTAssertEqual(SessionState.injecting.statusTitle, "输入中...")
        XCTAssertEqual(SessionState.notice("温和提示").statusTitle, "温和提示")
        XCTAssertEqual(SessionState.error("msg").statusTitle, "出错了")
    }

    func testStateIsRecordingIndicator() {
        XCTAssertFalse(SessionState.idle.isRecordingIndicator)
        XCTAssertTrue(SessionState.recording(elapsedSeconds: 5).isRecordingIndicator)
        XCTAssertFalse(SessionState.processing(provider: "Test").isRecordingIndicator)
        XCTAssertFalse(SessionState.injecting.isRecordingIndicator)
        XCTAssertFalse(SessionState.notice("msg").isRecordingIndicator)
        XCTAssertFalse(SessionState.error("msg").isRecordingIndicator)
    }

    func testStateShowSpinner() {
        XCTAssertFalse(SessionState.idle.showSpinner)
        XCTAssertFalse(SessionState.recording(elapsedSeconds: 0).showSpinner)
        XCTAssertTrue(SessionState.processing(provider: "Test").showSpinner)
        XCTAssertTrue(SessionState.polishing(preview: "").showSpinner)
        XCTAssertFalse(SessionState.injecting.showSpinner)
        XCTAssertFalse(SessionState.notice("msg").showSpinner)
        XCTAssertFalse(SessionState.error("msg").showSpinner)
    }

    /// The floating panel hides only in .idle (all 7 cases covered).
    func testStateShowPanel() {
        XCTAssertFalse(SessionState.idle.showPanel)
        XCTAssertTrue(SessionState.recording(elapsedSeconds: 0).showPanel)
        XCTAssertTrue(SessionState.processing(provider: "Test").showPanel)
        XCTAssertTrue(SessionState.polishing(preview: "").showPanel)
        XCTAssertTrue(SessionState.injecting.showPanel)
        XCTAssertTrue(SessionState.notice("msg").showPanel)
        XCTAssertTrue(SessionState.error("msg").showPanel)
    }
}
