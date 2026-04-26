import CoreGraphics
import Foundation

public struct FaceEmbeddingPreprocessor {
    public static let defaultPreprocessingVersion = "vision-bounds-rgb-nchw-112-centered-v1"

    private let outputWidth: Int
    private let outputHeight: Int
    private let preprocessingVersion: String
    private let colorSpace: CGColorSpace

    public init(
        outputWidth: Int = AlignedFaceEmbeddingInput.expectedWidth,
        outputHeight: Int = AlignedFaceEmbeddingInput.expectedHeight,
        preprocessingVersion: String = Self.defaultPreprocessingVersion,
        colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    ) {
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.preprocessingVersion = preprocessingVersion
        self.colorSpace = colorSpace
    }

    public func makeInput(
        from image: CGImage,
        visionNormalizedFaceBounds bounds: CGRect
    ) throws -> AlignedFaceEmbeddingInput {
        guard image.width > 0, image.height > 0 else {
            throw FaceEmbeddingPreprocessorError.invalidImageDimensions(width: image.width, height: image.height)
        }

        guard outputWidth == AlignedFaceEmbeddingInput.expectedWidth,
              outputHeight == AlignedFaceEmbeddingInput.expectedHeight
        else {
            throw FaceEmbeddingPreprocessorError.unsupportedOutputDimensions(
                width: outputWidth,
                height: outputHeight
            )
        }

        guard !preprocessingVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FaceEmbeddingPreprocessorError.missingPreprocessingVersion
        }

        let cropRect = try squarePixelCropRect(
            forVisionNormalizedBounds: bounds,
            imageWidth: image.width,
            imageHeight: image.height
        )

        guard let croppedImage = image.cropping(to: cropRect) else {
            throw FaceEmbeddingPreprocessorError.cropFailed
        }

        let rgbaBytes = try resizedRGBABytes(from: croppedImage)
        var values = Array(repeating: Float(0), count: AlignedFaceEmbeddingInput.expectedValueCount)
        let planeSize = outputWidth * outputHeight

        for pixelIndex in 0..<planeSize {
            let rgbaIndex = pixelIndex * 4
            values[pixelIndex] = Self.centeredFloat(fromByte: rgbaBytes[rgbaIndex])
            values[planeSize + pixelIndex] = Self.centeredFloat(fromByte: rgbaBytes[rgbaIndex + 1])
            values[(planeSize * 2) + pixelIndex] = Self.centeredFloat(fromByte: rgbaBytes[rgbaIndex + 2])
        }

        return try AlignedFaceEmbeddingInput(
            width: outputWidth,
            height: outputHeight,
            channelCount: AlignedFaceEmbeddingInput.expectedChannelCount,
            layout: .rgbChannelsFirst,
            preprocessingVersion: preprocessingVersion,
            values: values
        )
    }

    private func squarePixelCropRect(
        forVisionNormalizedBounds bounds: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) throws -> CGRect {
        guard bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.size.width.isFinite,
              bounds.size.height.isFinite,
              bounds.width > 0,
              bounds.height > 0,
              bounds.minX >= 0,
              bounds.minY >= 0,
              bounds.maxX <= 1,
              bounds.maxY <= 1
        else {
            throw FaceEmbeddingPreprocessorError.invalidFaceBounds
        }

        let imageWidth = CGFloat(imageWidth)
        let imageHeight = CGFloat(imageHeight)
        let faceRect = CGRect(
            x: bounds.minX * imageWidth,
            y: (1.0 - bounds.maxY) * imageHeight,
            width: bounds.width * imageWidth,
            height: bounds.height * imageHeight
        )

        guard faceRect.width >= 1, faceRect.height >= 1 else {
            throw FaceEmbeddingPreprocessorError.faceBoundsTooSmall
        }

        let side = max(faceRect.width, faceRect.height)
        guard side <= imageWidth, side <= imageHeight else {
            throw FaceEmbeddingPreprocessorError.faceCropOutsideImage
        }

        var originX = faceRect.midX - side / 2
        var originY = faceRect.midY - side / 2
        originX = min(max(0, originX), imageWidth - side)
        originY = min(max(0, originY), imageHeight - side)

        let integralCrop = CGRect(
            x: floor(originX),
            y: floor(originY),
            width: ceil(side),
            height: ceil(side)
        ).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

        guard integralCrop.width >= 1, integralCrop.height >= 1 else {
            throw FaceEmbeddingPreprocessorError.faceCropOutsideImage
        }

        return integralCrop
    }

    private func resizedRGBABytes(from image: CGImage) throws -> [UInt8] {
        let bytesPerPixel = 4
        let bytesPerRow = outputWidth * bytesPerPixel
        var bytes = Array(repeating: UInt8(0), count: outputHeight * bytesPerRow)

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &bytes,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw FaceEmbeddingPreprocessorError.renderFailed
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        return bytes
    }

    private static func centeredFloat(fromByte byte: UInt8) -> Float {
        (Float(byte) - 127.5) / 127.5
    }
}

public enum FaceEmbeddingPreprocessorError: Error, Equatable, CustomStringConvertible {
    case invalidImageDimensions(width: Int, height: Int)
    case unsupportedOutputDimensions(width: Int, height: Int)
    case missingPreprocessingVersion
    case invalidFaceBounds
    case faceBoundsTooSmall
    case faceCropOutsideImage
    case cropFailed
    case renderFailed

    public var description: String {
        switch self {
        case let .invalidImageDimensions(width, height):
            return "Face embedding preprocessing image dimensions are invalid: \(width)x\(height)."
        case let .unsupportedOutputDimensions(width, height):
            return "Face embedding preprocessing output dimensions are unsupported: \(width)x\(height)."
        case .missingPreprocessingVersion:
            return "Face embedding preprocessing version is missing."
        case .invalidFaceBounds:
            return "Face embedding preprocessing face bounds are invalid."
        case .faceBoundsTooSmall:
            return "Face embedding preprocessing face bounds are too small."
        case .faceCropOutsideImage:
            return "Face embedding preprocessing crop is outside the image."
        case .cropFailed:
            return "Face embedding preprocessing crop failed."
        case .renderFailed:
            return "Face embedding preprocessing render failed."
        }
    }
}
