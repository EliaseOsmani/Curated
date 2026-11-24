//
//  UIIMage+AverageColor.swift
//  Curated
//
//  Created by Eliase Osmani on 2/11/26.
//

import UIKit
import CoreImage

// CIContext is thread-safe and expensive to create, so all images share one.
private nonisolated let averageColorContext = CIContext(
    options: [.workingColorSpace: NSNull()]
)

extension UIImage {
    /// Computes the tint color without blocking the main thread.
    var averageColorInBackground: UIColor? {
        get async {
            let image = self
            return await Task.detached(priority: .utility) {
                image.averageColor
            }.value
        }
    }

    nonisolated var averageColor: UIColor? {
        guard var inputImage = CIImage(image: self) else { return nil }

        // An average doesn't need full resolution.
        let maxSide = max(inputImage.extent.width, inputImage.extent.height)
        if maxSide > 64 {
            let scale = 64 / maxSide
            inputImage = inputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let extent = inputImage.extent
        let filter = CIFilter(name: "CIAreaAverage")
        filter?.setValue(inputImage, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)

        guard let outputImage = filter?.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        averageColorContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return UIColor(
            red: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            alpha: 1
        )
    }
}
