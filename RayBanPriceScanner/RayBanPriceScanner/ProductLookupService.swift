import Foundation

final class ProductLookupService {
    static let shared = ProductLookupService()
    private init() {}

    func lookup(upc: String) async throws -> ProductInfo? {
        let cleanUPC = upc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanUPC.isEmpty == false else { return nil }

        if let upcDB = try? await lookupUPCItemDB(upc: cleanUPC) {
            return upcDB
        }
        if let barcodeLookup = try? await lookupBarcodeLookup(upc: cleanUPC) {
            return barcodeLookup
        }
        if let monster = try? await lookupBarcodeMonster(upc: cleanUPC) {
            return monster
        }
        if let off = try? await lookupOpenFoodFacts(upc: cleanUPC) {
            return off
        }
        return nil
    }

    // MARK: - UPCItemDB

    private func lookupUPCItemDB(upc: String) async throws -> ProductInfo? {
        guard let url = URL(string: "https://api.upcitemdb.com/prod/trial/lookup?upc=\(upc)") else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(UPCResponse.self, from: data)
        guard let item = decoded.items.first else { return nil }

        let title = item.title ?? "Unknown Product"
        let bestOffer = item.offers
            .compactMap { offer -> (price: Double, merchant: String?, link: URL?)? in
                guard let price = offer.price else { return nil }
                let url: URL? = {
                    if let link = offer.link, let u = URL(string: link) {
                        return u
                    }
                    return nil
                }()
                return (price, offer.merchant, url)
            }
            .sorted(by: { $0.price < $1.price })
            .first

        return ProductInfo(
            title: title,
            lowestPrice: bestOffer?.price,
            merchant: bestOffer?.merchant,
            purchaseURL: bestOffer?.link
        )
    }

    // MARK: - OpenFoodFacts fallback (no prices, but gives product name/brand)

    private func lookupOpenFoodFacts(upc: String) async throws -> ProductInfo? {
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v0/product/\(upc).json") else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(OFFResponse.self, from: data)
        guard decoded.status == 1, let product = decoded.product else { return nil }

        let title = product.productName ?? product.brands ?? "Unknown product"
        let merchant = product.stores ?? product.brands
        let purchaseURL = product.url.flatMap { URL(string: $0) }

        return ProductInfo(
            title: title,
            lowestPrice: nil,
            merchant: merchant,
            purchaseURL: purchaseURL
        )
    }

    // MARK: - BarcodeLookup (requires API key in Info.plist: BARCODE_LOOKUP_KEY)

    private func lookupBarcodeLookup(upc: String) async throws -> ProductInfo? {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "BARCODE_LOOKUP_KEY") as? String,
              apiKey.isEmpty == false else {
            return nil
        }

        guard let url = URL(string: "https://api.barcodelookup.com/v3/products?barcode=\(upc)&formatted=y&key=\(apiKey)") else {
            return nil
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(BarcodeLookupResponse.self, from: data)
        guard let product = decoded.products.first else { return nil }

        let title = product.title ?? "Unknown Product"
        let priceStore = product.stores?
            .compactMap { store -> (Double, String?, URL?)? in
                guard let priceString = store.price else { return nil }
                let cleaned = priceString
                    .replacingOccurrences(of: "$", with: "")
                    .replacingOccurrences(of: ",", with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard let priceValue = Double(cleaned) else { return nil }
                let url: URL? = store.link.flatMap { URL(string: $0) }
                return (priceValue, store.name, url)
            }
            .sorted(by: { $0.0 < $1.0 })
            .first

        return ProductInfo(
            title: title,
            lowestPrice: priceStore?.0,
            merchant: priceStore?.1,
            purchaseURL: priceStore?.2
        )
    }

    // MARK: - Barcode Monster (no key, basic metadata only)

    private func lookupBarcodeMonster(upc: String) async throws -> ProductInfo? {
        guard let url = URL(string: "https://barcode.monster/api/\(upc)") else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(BarcodeMonsterResponse.self, from: data)
        let title = decoded.product?.name ?? decoded.product?.description ?? decoded.code ?? "Unknown product"
        let merchant = decoded.product?.brand ?? decoded.product?.manufacturer

        // No price info available from this API.
        return ProductInfo(
            title: title,
            lowestPrice: nil,
            merchant: merchant,
            purchaseURL: nil
        )
    }

    // MARK: - Debug helper: aggregate why lookups fail

    func debugLookup(upc: String) async -> String {
        let cleanUPC = upc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanUPC.isEmpty == false else { return "UPC empty" }

        do {
            if let upcDB = try await lookupUPCItemDB(upc: cleanUPC) {
                return "UPCItemDB success: \(upcDB.title)"
            } else {
                return "UPCItemDB returned no items"
            }
        } catch {
            return "UPCItemDB error: \(error.localizedDescription)"
        }
    }
}

// MARK: - API MODELS

private struct UPCResponse: Decodable {
    let items: [UPCItem]
}

private struct UPCItem: Decodable {
    let title: String?
    let offers: [UPCOffer]
}

private struct UPCOffer: Decodable {
    let price: Double?
    let merchant: String?
    let link: String?
}

private struct OFFResponse: Decodable {
    let status: Int?
    let product: OFFProduct?
}

private struct OFFProduct: Decodable {
    let productName: String?
    let brands: String?
    let stores: String?
    let url: String?

    private enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case brands
        case stores
        case url
    }
}

// BarcodeLookup models
private struct BarcodeLookupResponse: Decodable {
    let products: [BLProduct]
}

private struct BLProduct: Decodable {
    let title: String?
    let stores: [BLStore]?
}

private struct BLStore: Decodable {
    let name: String?
    let price: String?
    let link: String?
}

// Barcode Monster models
private struct BarcodeMonsterResponse: Decodable {
    let code: String?
    let product: BMProduct?
}

private struct BMProduct: Decodable {
    let name: String?
    let brand: String?
    let manufacturer: String?
    let description: String?
}
