import Foundation

struct ProductInfo: Identifiable {
    let id = UUID()
    let title: String
    let lowestPrice: Double?
    let merchant: String?
    let purchaseURL: URL?
}
