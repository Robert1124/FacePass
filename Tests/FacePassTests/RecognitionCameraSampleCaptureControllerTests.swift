import CoreGraphics
import FacePassCore
import XCTest
@testable import FacePass

final class RecognitionCameraSampleCaptureControllerTests: XCTestCase {
    func testRecognitionModeCapturedSampleFinishesWithoutWaitingForTimeout() async throws {
        let runState = RecognitionCameraSampleCaptureRunState(captureMode: .recognition)
        let sample = try makeSample()

        let task = Task<FaceSampleCaptureResult, Never> {
            await withCheckedContinuation { continuation in
                runState.setContinuation(continuation)
            }
        }

        runState.recordCapturedSample(
            FaceSampleCaptureSummary(sample: sample, processedFrameCount: 1)
        )

        let result = await awaitResult(
            task,
            runState: runState,
            timeoutNanoseconds: 100_000_000
        )

        guard case let .captured(summary) = try XCTUnwrap(result) else {
            return XCTFail("Expected captured result, got \(String(describing: result)).")
        }
        XCTAssertEqual(summary.processedFrameCount, 1)
    }

    private func awaitResult(
        _ task: Task<FaceSampleCaptureResult, Never>,
        runState: RecognitionCameraSampleCaptureRunState,
        timeoutNanoseconds: UInt64
    ) async -> FaceSampleCaptureResult? {
        await withTaskGroup(of: FaceSampleCaptureResult?.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                runState.finish(.cancelled) { _ in }
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func makeSample() throws -> FaceEnrollmentSample {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.imageCreationFailed
        }

        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage() else {
            throw TestError.imageCreationFailed
        }

        return FaceEnrollmentSample(
            image: image,
            visionNormalizedFaceBounds: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
        )
    }

    private enum TestError: Error {
        case imageCreationFailed
    }
}
