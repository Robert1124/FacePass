import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeImage: View {
    let payload: [String: Any]?

    var body: some View {
        Group {
            if let image = makeQRCodeImage() {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("StandBy Unlock pairing QR code")
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pairing QR code unavailable")
            }
        }
        .frame(width: 180, height: 180)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private func makeQRCodeImage() -> NSImage? {
        guard let payload,
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
