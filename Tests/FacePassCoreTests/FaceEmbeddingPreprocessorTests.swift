import CoreGraphics
import XCTest
@testable import FacePassCore

final class FaceEmbeddingPreprocessorTests: XCTestCase {
    func testFullImageBoundsProduce112By112RGBChannelsFirstInput() throws {
        let image = try makeImage(width: 112, height: 112) { _, _ in
            RGBA(red: 255, green: 128, blue: 0)
        }
        let preprocessor = FaceEmbeddingPreprocessor()

        let input = try preprocessor.makeInput(
            from: image,
            visionNormalizedFaceBounds: CGRect(x: 0, y: 0, width: 1, height: 1)
        )

        XCTAssertEqual(input.width, 112)
        XCTAssertEqual(input.height, 112)
        XCTAssertEqual(input.channelCount, 3)
        XCTAssertEqual(input.layout, .rgbChannelsFirst)
        XCTAssertEqual(input.preprocessingVersion, FaceEmbeddingPreprocessor.defaultPreprocessingVersion)
        XCTAssertEqual(input.values.count, AlignedFaceEmbeddingInput.expectedValueCount)

        let planeSize = 112 * 112
        XCTAssertEqual(input.values[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(input.values[planeSize], Float(128 - 127.5) / 127.5, accuracy: 0.0001)
        XCTAssertEqual(input.values[planeSize * 2], -1.0, accuracy: 0.0001)
        XCTAssertTrue(input.values.allSatisfy(\.isFinite))
    }

    func testCenteredNormalizationMapsByteExtremesAndMidpoints() throws {
        let image = try makeImage(width: 112, height: 112) { x, _ in
            if x < 56 {
                return RGBA(red: 255, green: 127, blue: 0)
            }
            return RGBA(red: 255, green: 128, blue: 0)
        }
        let preprocessor = FaceEmbeddingPreprocessor()

        let input = try preprocessor.makeInput(
            from: image,
            visionNormalizedFaceBounds: CGRect(x: 0, y: 0, width: 1, height: 1)
        )

        let planeSize = 112 * 112
        let leftPixel = 0
        let rightPixel = 56
        XCTAssertEqual(input.values[leftPixel], 1.0, accuracy: 0.0001)
        XCTAssertEqual(input.values[planeSize + leftPixel], Float(127 - 127.5) / 127.5, accuracy: 0.0001)
        XCTAssertEqual(input.values[(planeSize * 2) + leftPixel], -1.0, accuracy: 0.0001)
        XCTAssertEqual(input.values[planeSize + rightPixel], Float(128 - 127.5) / 127.5, accuracy: 0.0001)
        XCTAssertTrue(input.values.allSatisfy(\.isFinite))
    }

    func testVisionNormalizedBoundsUseLowerLeftOriginAndCropRequestedRegion() throws {
        let image = try makeImage(width: 224, height: 224) { _, y in
            if y < 112 {
                return RGBA(red: 255, green: 0, blue: 0)
            }
            return RGBA(red: 0, green: 0, blue: 255)
        }
        let preprocessor = FaceEmbeddingPreprocessor()

        let input = try preprocessor.makeInput(
            from: image,
            visionNormalizedFaceBounds: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        )

        let planeSize = 112 * 112
        XCTAssertEqual(input.values[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(input.values[planeSize], -1.0, accuracy: 0.0001)
        XCTAssertEqual(input.values[planeSize * 2], -1.0, accuracy: 0.0001)
    }

    func testNonSquareBoundsAreCenteredIntoSquareCrop() throws {
        let image = try makeImage(width: 112, height: 112) { x, _ in
            if x < 56 {
                return RGBA(red: 0, green: 255, blue: 0)
            }
            return RGBA(red: 0, green: 0, blue: 255)
        }
        let preprocessor = FaceEmbeddingPreprocessor()

        let input = try preprocessor.makeInput(
            from: image,
            visionNormalizedFaceBounds: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        )

        let planeSize = 112 * 112
        XCTAssertEqual(input.values[0], -1.0, accuracy: 0.0001)
        XCTAssertEqual(input.values[planeSize], 1.0, accuracy: 0.0001)
        XCTAssertEqual(input.values[planeSize * 2], -1.0, accuracy: 0.0001)
    }

    func testInvalidBoundsFailClosedWithTypedErrors() throws {
        let image = try makeImage(width: 112, height: 112) { _, _ in
            RGBA(red: 255, green: 255, blue: 255)
        }
        let preprocessor = FaceEmbeddingPreprocessor()

        XCTAssertThrowsPreprocessorError(
            try preprocessor.makeInput(
                from: image,
                visionNormalizedFaceBounds: CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5)
            ),
            .invalidFaceBounds
        )

        XCTAssertThrowsPreprocessorError(
            try preprocessor.makeInput(
                from: image,
                visionNormalizedFaceBounds: CGRect(x: 0, y: 0, width: 0, height: 0.5)
            ),
            .invalidFaceBounds
        )

        XCTAssertThrowsPreprocessorError(
            try preprocessor.makeInput(
                from: image,
                visionNormalizedFaceBounds: CGRect(x: 0, y: 0, width: 0.001, height: 0.001)
            ),
            .faceBoundsTooSmall
        )
    }

    func testUnsupportedOutputShapeAndMissingVersionFailClosed() throws {
        let image = try makeImage(width: 112, height: 112) { _, _ in
            RGBA(red: 255, green: 255, blue: 255)
        }

        XCTAssertThrowsPreprocessorError(
            try FaceEmbeddingPreprocessor(outputWidth: 111).makeInput(
                from: image,
                visionNormalizedFaceBounds: CGRect(x: 0, y: 0, width: 1, height: 1)
            ),
            .unsupportedOutputDimensions(width: 111, height: 112)
        )

        XCTAssertThrowsPreprocessorError(
            try FaceEmbeddingPreprocessor(preprocessingVersion: " ").makeInput(
                from: image,
                visionNormalizedFaceBounds: CGRect(x: 0, y: 0, width: 1, height: 1)
            ),
            .missingPreprocessingVersion
        )
    }

    private func XCTAssertThrowsPreprocessorError(
        _ expression: @autoclosure () throws -> AlignedFaceEmbeddingInput,
        _ expectedError: FaceEmbeddingPreprocessorError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? FaceEmbeddingPreprocessorError, expectedError, file: file, line: line)
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> RGBA
    ) throws -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = Array(repeating: UInt8(0), count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                let index = (y * bytesPerRow) + (x * bytesPerPixel)
                bytes[index] = color.red
                bytes[index + 1] = color.green
                bytes[index + 2] = color.blue
                bytes[index + 3] = color.alpha
            }
        }

        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            throw TestImageError.makeImageFailed
        }

        return image
    }
}

private struct RGBA {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

private enum TestImageError: Error {
    case makeImageFailed
}
