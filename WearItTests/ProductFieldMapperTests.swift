import Foundation
import Testing
@testable import WearIt

struct ProductFieldMapperTests {

    @Test func shortSleeveTShirtMapsToTopNotShorts() {
        let path = "KNIT SHIRTS T-SHIRT SHORT SLEEVE"
        let title = "Short Sleeve T-Shirt"
        let category = ProductFieldMapper.mapCategory(path: path, title: title)
        let itemType = ProductFieldMapper.mapItemType(path: path, title: title, category: category)

        #expect(category == .top)
        #expect(itemType == .tshirt)
        #expect(!ProductFieldMapper.hasStandaloneShorts("\(path) \(title)".lowercased()))
    }

    @Test func cornflowerBlueMapsToLightBlue() {
        let colors = ProductFieldMapper.mapColors(colorField: "CORNFLOWER BLUE/C3173", title: nil)
        #expect(colors.first == .lightBlue)
        #expect(!colors.contains(.blue))
    }

    @Test func chinoShortMapsToBottomShorts() {
        let title = "Chino Short"
        let category = ProductFieldMapper.mapCategory(path: "", title: title)
        let itemType = ProductFieldMapper.mapItemType(path: "", title: title, category: category)

        #expect(category == .bottom)
        #expect(itemType == .shorts)
    }

    @Test func cottonMaterialParses() {
        let materials = ProductFieldMapper.mapMaterials("100% COTTON")
        #expect(materials == [.cotton])
    }

    @Test func weakTitleDoesNotGuessCategory() {
        let category = ProductFieldMapper.mapCategory(path: "", title: "Style 539151")
        #expect(category == nil)
        let itemType = ProductFieldMapper.mapItemType(path: "", title: "Style 539151", category: nil)
        #expect(itemType == nil)
    }

    @Test func autoFillShortSleeveDoesNotBecomeShorts() {
        let mapped = AutoFillMapper.mapClassifierLabel("short sleeve t-shirt")
        #expect(mapped.category == .top)
        #expect(mapped.itemType == .tshirt)
    }

    @Test func autoFillShortsStillMaps() {
        let mapped = AutoFillMapper.mapClassifierLabel("denim shorts")
        #expect(mapped.category == .bottom)
        #expect(mapped.itemType == .shorts)
    }

    @Test func candleIsRejectedAsNonApparel() {
        #expect(!ProductFieldMapper.isLikelyApparel(
            path: "Home & Garden > Candles",
            title: "Vanilla Scented Candle",
            mappedCategory: nil
        ))
    }

    @Test func tShirtIsAcceptedAsApparel() {
        #expect(ProductFieldMapper.isLikelyApparel(
            path: "KNIT SHIRTS T-SHIRT",
            title: "Short Sleeve T-Shirt",
            mappedCategory: .top
        ))
    }

    @Test func unknownNonClothingTitleIsRejected() {
        #expect(!ProductFieldMapper.isLikelyApparel(
            path: "",
            title: "Style 539151",
            mappedCategory: nil
        ))
    }

    @Test func hebrewTShirtAndNavyMap() {
        let path = "men shirts tshirts"
        let title = "טי שרט שקפקפה"
        let category = ProductFieldMapper.mapCategory(path: path, title: title)
        let itemType = ProductFieldMapper.mapItemType(path: path, title: title, category: category)
        let colors = ProductFieldMapper.mapColors(colorField: "כחול נייבי", title: title)

        #expect(category == .top)
        #expect(itemType == .tshirt)
        #expect(colors.first == .navy)
    }

    @Test func asosURLSlugFallbackFillsApparelFields() throws {
        let url = URL(string: "https://www.asos.com/polo-ralph-lauren/polo-ralph-lauren-short-sleeve-pique-shirt-slim-fit-player-logo-in-white/prd/203027027?ctaRef=my+orders")!
        let product = try #require(ProductPageMetadataService.productFromURLSlug(url))

        #expect(product.brand?.localizedCaseInsensitiveContains("ralph lauren") == true)
        #expect(product.title?.localizedCaseInsensitiveContains("shirt") == true)
        #expect(product.colors.contains(.white))
        #expect(product.category == .top)
        #expect(product.imageURL?.absoluteString.contains("203027027-1-white") == true)
        try ProductFieldMapper.requireApparel(product)
    }

    @Test func asosLightBlueSlugBuildsCDNImage() throws {
        let url = URL(string: "https://www.asos.com/polo-ralph-lauren/polo-ralph-lauren-custom-fit-oxford-shirt-in-light-blue/prd/208639913#colourWayId-208639917")!
        let product = try #require(ProductPageMetadataService.productFromURLSlug(url))

        #expect(product.colors.contains(.lightBlue))
        #expect(product.imageURL?.absoluteString ==
                "https://images.asos-media.com/products/polo-ralph-lauren-custom-fit-oxford-shirt-in-light-blue/208639913-1-lightblue")
        try ProductFieldMapper.requireApparel(product)
    }
}
