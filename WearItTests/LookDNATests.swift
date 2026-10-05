import Foundation
import Testing
@testable import WearIt

struct LookDNATests {

    private func garment(_ category: Category, _ color: ColorTag, fit: FitTag? = nil, formality: Int = 3) -> Garment {
        let g = Garment()
        g.category = category
        g.colorTags = [color]
        g.fitTag = fit
        g.formality = formality
        return g
    }

    @Test func neutralsWithOneColorAreNeutralPlusPop() {
        let dna = LookDNA(garments: [garment(.top, .red), garment(.bottom, .denim), garment(.shoes, .white)])
        #expect(dna.scheme == .neutralPlusPop)
        #expect(dna.priorScore > 0.8)
    }

    @Test func oppositeLoudColorsScoreBelowNeutralPop() {
        let clash = LookDNA(garments: [garment(.top, .yellow), garment(.bottom, .purple)])
        let pop = LookDNA(garments: [garment(.top, .yellow), garment(.bottom, .black)])
        #expect(clash.priorScore < pop.priorScore)
    }

    @Test func looseTopWithSlimBottomIsBalanced() {
        let dna = LookDNA(garments: [
            garment(.top, .white, fit: .oversized),
            garment(.bottom, .black, fit: .slim),
        ])
        #expect(dna.silhouette == .balanced)
    }

    @Test func vectorHasFixedSize() {
        let dna = LookDNA(garments: [garment(.top, .navy), garment(.bottom, .beige)])
        #expect(dna.vector.count == LookDNA.vectorSize)
        #expect(dna.similarity(to: dna) > 0.99)
    }
}
