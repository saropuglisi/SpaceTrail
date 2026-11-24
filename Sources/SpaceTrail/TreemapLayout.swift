import CoreGraphics

enum TreemapLayout {
    /// Arranges descending, positive weights in strips chosen for legible aspect ratios.
    static func rectangles(for weights: [Int64], in size: CGSize, balanced: Bool = false) -> [CGRect] {
        let total = weights.reduce(0.0) { $0 + Double($1) }
        guard total > 0, size.width > 0, size.height > 0 else { return [] }
        // Spread a fifth of the canvas evenly so small entries stay selectable.
        let proportionalShare = balanced ? 0.8 : 1.0
        let evenShare = (1 - proportionalShare) / Double(weights.count)
        let areas = weights.map {
            CGFloat(proportionalShare * Double($0) / total + evenShare) * size.width * size.height
        }
        var remaining = CGRect(origin: .zero, size: size)
        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var first = 0

        while first < areas.count {
            let vertical = remaining.width >= remaining.height
            let side = vertical ? remaining.height : remaining.width
            let depth = vertical ? remaining.width : remaining.height
            guard side > 0, depth > 0 else { break }
            var end = first + 1
            var area = areas[first]
            var worst = aspect(area: area, largest: area, smallest: area, side: side)
            while end < areas.count {
                let nextArea = area + areas[end]
                let nextWorst = aspect(area: nextArea, largest: areas[first], smallest: areas[end], side: side)
                guard nextWorst <= worst else { break }
                area = nextArea
                worst = nextWorst
                end += 1
            }

            let thickness = end == areas.count ? depth : min(depth, area / side)
            var offset: CGFloat = 0
            for index in first..<end {
                let available = max(0, side - offset)
                let length = index == end - 1 ? available : min(available, side * areas[index] / area)
                if vertical {
                    result.append(CGRect(x: remaining.minX, y: remaining.minY + offset,
                                         width: thickness, height: length))
                } else {
                    result.append(CGRect(x: remaining.minX + offset, y: remaining.minY,
                                         width: length, height: thickness))
                }
                offset += length
            }
            if vertical {
                remaining.origin.x += thickness
                remaining.size.width -= thickness
            } else {
                remaining.origin.y += thickness
                remaining.size.height -= thickness
            }
            first = end
        }
        return result
    }

    private static func aspect(area: CGFloat, largest: CGFloat, smallest: CGFloat, side: CGFloat) -> CGFloat {
        let strip = area / side
        return max(largest / (strip * strip), (strip * strip) / smallest)
    }
}
