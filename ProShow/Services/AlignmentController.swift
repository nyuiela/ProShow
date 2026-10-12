import Foundation
import CoreGraphics

/// Multi-selection align and distribute in canvas coordinates.
enum AlignmentController {
    static func align(_ alignment: CanvasAlign, elements: inout [CanvasObject], in box: CanvasBounds) {
        for index in elements.indices {
            switch alignment {
            case .left:
                elements[index].transform.x = box.x
            case .right:
                elements[index].transform.x = box.x + box.width - elements[index].transform.width
            case .top:
                elements[index].transform.y = box.y
            case .bottom:
                elements[index].transform.y = box.y + box.height - elements[index].transform.height
            case .centerX:
                elements[index].transform.x = box.x + (box.width - elements[index].transform.width) / 2
            case .centerY:
                elements[index].transform.y = box.y + (box.height - elements[index].transform.height) / 2
            }
        }
    }

    static func distribute(_ axis: CanvasDistribute, elements: inout [CanvasObject]) {
        let sorted = elements.sorted {
            axis == .horizontal ? $0.transform.x < $1.transform.x : $0.transform.y < $1.transform.y
        }
        guard sorted.count >= 3, let first = sorted.first, let last = sorted.last else { return }

        switch axis {
        case .horizontal:
            let span = (last.transform.x + last.transform.width) - first.transform.x
            let occupied = sorted.reduce(0) { $0 + $1.transform.width }
            let gap = (span - occupied) / Double(sorted.count - 1)
            var cursor = first.transform.x
            for item in sorted {
                guard let index = elements.firstIndex(where: { $0.id == item.id }) else { continue }
                elements[index].transform.x = cursor
                cursor += elements[index].transform.width + gap
            }
        case .vertical:
            let span = (last.transform.y + last.transform.height) - first.transform.y
            let occupied = sorted.reduce(0) { $0 + $1.transform.height }
            let gap = (span - occupied) / Double(sorted.count - 1)
            var cursor = first.transform.y
            for item in sorted {
                guard let index = elements.firstIndex(where: { $0.id == item.id }) else { continue }
                elements[index].transform.y = cursor
                cursor += elements[index].transform.height + gap
            }
        }
    }
}
