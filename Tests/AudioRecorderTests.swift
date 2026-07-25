import XCTest
import AVFoundation
@testable import DogballWhisper

final class AudioRecorderTests: XCTestCase {

    // The meter reports full scale before it has processed real audio, and the
    // mic's auto-gain settles during the first fraction of a second. Both would
    // draw a spurious burst of tall bars the moment recording starts.
    func testWarmUpReadingsRenderAsSilence() {
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: 0, at: 0.05), 0)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -10, at: 0.2), 0)
    }

    func testDecibelsMapIntoZeroToOneAfterWarmUp() {
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: 0, at: 1.0), 1)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -25, at: 1.0), 0.5)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -50, at: 1.0), 0)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -160, at: 1.0), 0)
    }

    func testLevelsStartFullWidthSoTheWaveformDoesNotGrowFromNothing() {
        let recorder = AudioRecorder()
        XCTAssertEqual(recorder.levels.count, AudioRecorder.levelWindowSize)
        XCTAssertTrue(recorder.levels.allSatisfy { $0 == 0 })
    }

    func testStopWithoutStartReturnsNil() {
        let recorder = AudioRecorder()
        XCTAssertNil(recorder.stop())
    }

    func testCancelWithoutStartIsASafeNoOp() {
        let recorder = AudioRecorder()
        recorder.cancel()
    }

    // Guards the contract the engines depend on: a real 16kHz mono WAV on disk.
    // Needs mic permission, so it is opt-in: RUN_AUDIO_IT=1 ./scripts/test.sh
    func testRecordsA16kMonoWavFile() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_AUDIO_IT"] == "1")
        let recorder = AudioRecorder()
        try recorder.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        let result = try XCTUnwrap(recorder.stop())

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertGreaterThan(result.duration, 0.3)

        let file = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)

        recorder.cancel()
    }
}
