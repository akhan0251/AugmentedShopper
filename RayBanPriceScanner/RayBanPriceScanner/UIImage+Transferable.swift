// Wrapper to avoid conforming UIImage directly, preventing future conflicts if UIKit
// adds Transferable conformance.
import SwiftUI
import UniformTypeIdentifiers

struct TransferableImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { wrapped in
            wrapped.image.pngData() ?? Data()
        }
    }
}
