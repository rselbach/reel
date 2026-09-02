import CoreGraphics

struct ZoomLayout: Equatable, Sendable {
    let sourceCropRect: CGRect
    let requestedFocalPoint: CGPoint

    static func resolve(
        sourceSize: CGSize,
        focalPoint: UnitPoint2D,
        scale: Double = ZoomScene.scale
    ) -> ZoomLayout? {
        guard
            sourceSize.width.isFinite,
            sourceSize.height.isFinite,
            sourceSize.width > 0,
            sourceSize.height > 0,
            scale.isFinite,
            scale >= 1
        else { return nil }

        let cropSize = CGSize(
            width: sourceSize.width / scale,
            height: sourceSize.height / scale
        )
        let requestedPoint = CGPoint(
            x: sourceSize.width * focalPoint.x,
            y: sourceSize.height * focalPoint.y
        )
        let origin = CGPoint(
            x: min(max(0, requestedPoint.x - cropSize.width / 2), sourceSize.width - cropSize.width),
            y: min(max(0, requestedPoint.y - cropSize.height / 2), sourceSize.height - cropSize.height)
        )
        return ZoomLayout(
            sourceCropRect: CGRect(origin: origin, size: cropSize),
            requestedFocalPoint: requestedPoint
        )
    }

    func sourceToOutputTransform(outputSize: CGSize) -> CGAffineTransform? {
        guard
            outputSize.width.isFinite,
            outputSize.height.isFinite,
            outputSize.width > 0,
            outputSize.height > 0,
            sourceCropRect.width > 0,
            sourceCropRect.height > 0
        else { return nil }

        return CGAffineTransform(
            translationX: -sourceCropRect.minX,
            y: -sourceCropRect.minY
        )
        .concatenating(
            CGAffineTransform(
                scaleX: outputSize.width / sourceCropRect.width,
                y: outputSize.height / sourceCropRect.height
            )
        )
    }
}
