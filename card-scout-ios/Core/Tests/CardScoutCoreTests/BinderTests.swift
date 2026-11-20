import XCTest
@testable import CardScoutCore

final class BinderTests: XCTestCase {
    func testBinderSearchAcceptsThePrintedNumberWithOrWithoutSeparators() {
        let entry = ChecklistCard(number: "BPP-118", player: "Bo Jackson", team: "Ohio State")
        for query in ["#BPP118", "bpp118", "BPP-118", "BPP 118", "#BPP–118", "  #BPP-118  ", "Bo Jackson", "Ohio State", ""] {
            XCTAssertTrue(entry.matchesBinderSearch(query), query)
        }
        XCTAssertTrue(entry.matchesBinderNumber("#BPP118"))
        XCTAssertFalse(entry.matchesBinderNumber("Bo Jackson"))
        for query in ["#BCP118", "BPP1180", "#", "BPP/118"] {
            XCTAssertFalse(entry.matchesBinderSearch(query), query)
        }
    }

    private func collection(_ id: String, _ name: String, year: Int = 2025, subset: String = "Base") -> CardCollection {
        CardCollection(id: id, name: name, year: year, brand: "Fixture", subset: subset, cards: [])
    }

    func testClosestChecklistCountsOnlyVerifiedDistinctSlotsInCompleteSets() {
        var catalog = collection("full", "Flagship")
        catalog.cards = ["1", "2", "3"].map { ChecklistCard(number: $0, player: "Fixture", team: "") }
        catalog.checklistComplete = true
        var partial = catalog; partial.id = "partial"; partial.checklistComplete = false
        var incomplete = catalog; incomplete.id = "gap"; incomplete.expectedCount = 4
        func copy(_ set: String, _ number: String) -> OwnedCard {
            var a = CardAnalysis(recommendation: "Keep", marketCheckedAt: "", marketSources: [], confidence: "high", conditionNotes: "", rationale: "", needsReview: false)
            a.collectionID = set; a.cardNumber = number; a.identityConfirmed = true
            return OwnedCard(id: UUID().uuidString, state: "analyzed", analysis: a)
        }
        var draft = copy("full", "3"); draft.isScanDraft = true
        var uncertain = copy("full", "3"); uncertain.analysis?.identityConfirmed = false
        var library = Library(); library.collections = [catalog, partial, incomplete]
        library.cards = [copy("full","1"), copy("full","1"), copy("full","2"), copy("full","99"), draft, uncertain, copy("partial","1"), copy("gap","1")]
        XCTAssertEqual(library.closestChecklist?.checklist.id, "full")
        XCTAssertEqual(library.closestChecklist?.owned, 2)
        XCTAssertEqual(library.closestChecklist?.remaining, 1)
        library.cards.append(copy("full","3"))
        XCTAssertNil(library.closestChecklist)
    }

    func testFamiliesContainYearsAndTypesWithoutChangingChecklistIdentity() {
        let sets = [collection("base", "Bowman Football"), collection("chrome", "Bowman Chrome", subset: "Chrome"),
                    collection("old", "Bowman Football", year: 2024), collection("optic", "Donruss Optic"),
                    collection("donruss", "Donruss"), collection("select", "Select"), collection("prizm", "Prizm")]
        let binders = CollectionBinder.group(sets)
        XCTAssertEqual(binders.count, 4)
        let bowman = binders.first { $0.name == "Bowman Football" }!
        XCTAssertEqual(Set(bowman.collections.map(\.id)), ["base", "chrome", "old"])
        XCTAssertEqual(bowman.collections.last?.year, 2024)
        XCTAssertEqual(binders.first { $0.name == "Donruss" }?.collections.count, 2)
        XCTAssertEqual(CollectionBinder.group(sets.reversed()).map(\.id), binders.map(\.id))
    }

    func testToppsProductsGetSeparateBindersAcrossAliasesAndYears() throws {
        var short = collection("short", "Chrome Football")
        short.brand = "Topps"
        let sets = [collection("flag", "Topps Flagship"), collection("flag2", "Topps Flagship Football", year: 2026),
                    short, collection("chrome", "2025 Topps Chrome Football"), collection("premium", "Topps Chrome Black"),
                    collection("other", "Chrome Football"), collection("bowman", "Topps Bowman Chrome")]
        let groups = CollectionBinder.group(sets)
        XCTAssertEqual(Set(try XCTUnwrap(groups.first { $0.name == "Topps Flagship Football" }).collections.map(\.id)), ["flag", "flag2"])
        XCTAssertEqual(Set(try XCTUnwrap(groups.first { $0.name == "Topps Chrome" }).collections.map(\.id)), ["short", "chrome"])
        XCTAssertEqual(groups.first { $0.id == "bowman football" }?.collections.first?.id, "bowman")
        XCTAssertEqual(groups.flatMap(\.collections).count, sets.count)
    }

    func testSpecialsUseConfirmedEvidenceWithinTheExactBinder() throws {
        let base = collection("base", "Topps Chrome")
        var parallel = base; parallel.id = "refractor"; parallel.parallel = "Refractor"
        let insert = collection("insert", "Topps Chrome", subset: "Future Stars")
        let flagship = collection("flagship", "Topps Flagship", year: 2026)
        let prospects = collection("prospects", "Bowman", year: 2026, subset: "Chrome Prospects")
        let auto = collection("autos", "Topps Chrome", subset: "Rookie Autographs")
        let relic = collection("relics", "Topps Chrome", subset: "Rookie Relics")
        let variation = collection("variation", "Topps Chrome", subset: "Image Variation")
        func owned(_ id: String, _ checklist: CardCollection, serial: String? = nil) -> OwnedCard {
            var a = CardAnalysis(recommendation: "Keep", marketCheckedAt: "", marketSources: [], confidence: "high", conditionNotes: "", rationale: "", needsReview: false)
            a.collectionID = checklist.id; a.identityConfirmed = true; a.subset = checklist.subset
            a.serialNumber = serial; a.rookie = true
            return OwnedCard(id: id, state: "analyzed", analysis: a)
        }
        var unknown = owned("unconfirmed", parallel); unknown.analysis?.identityConfirmed = false
        var draft = owned("draft", insert); draft.isScanDraft = true
        var pending = owned("pending", parallel); pending.hasProvisionalAnalysis = true
        var possible = owned("possible", base); possible.analysis?.parallel = "Possible Autograph?"
        var shortPrint = owned("ssp", base); shortPrint.analysis?.parallel = "Image Variation SSP"
        var caseHit = owned("case-hit", base); caseHit.analysis?.parallel = "Case Hit"
        var favorite = owned("ordinary", base); favorite.isFavorite = true; favorite.isCollectible = true
        favorite.analysis?.marketHighCents = 100_000
        var library = Library()
        library.collections = [base, parallel, insert, flagship, prospects, auto, relic, variation]
        library.cards = [favorite, unknown, draft, pending, possible, shortPrint, caseHit, owned("invalid-serial", base, serial: "24/10"),
                         owned("insert", insert), owned("parallel", parallel), owned("insert-copy", insert),
                         owned("one", base, serial: "1/1"), owned("numbered", parallel, serial: "04/25"),
                         owned("auto", auto), owned("relic", relic), owned("variation", variation),
                         owned("outside", flagship, serial: "01/10"), owned("ordinary-prospect", prospects)]
        let result = try XCTUnwrap(library.binders.first { $0.id == "topps chrome" }).specials(in: library)
        XCTAssertEqual(result.map(\.kind), [.numbered, .numbered, .autograph, .relic, .shortPrint, .caseHit, .variation, .parallel, .insert, .insert])
        XCTAssertEqual(result.prefix(2).map(\.id), ["one", "numbered"])
        XCTAssertEqual(result.first { $0.id == "parallel" }?.edition, "Refractor")
        XCTAssertEqual(result.first { $0.id == "numbered" }?.serial, "04/25")
        XCTAssertEqual(result.last?.edition, "Future Stars")
        XCTAssertTrue(try XCTUnwrap(library.binders.first { $0.id == "bowman football" }).specials(in: library).isEmpty)
    }

    func testOnlyConfirmedOwnedFamiliesReachShelfAndKeepSiblingChecklists() throws {
        var library = Library()
        let editions = [collection("flag-base", "Topps Flagship"), collection("flag-insert", "Topps Flagship Football"),
                        collection("chrome", "Topps Chrome"), collection("select", "Panini Select")]
        library.collections = editions
        func owned(_ checklist: String, confirmed: Bool) -> OwnedCard {
            var a = CardAnalysis(recommendation: "Keep", marketCheckedAt: "", marketSources: [], confidence: "high", conditionNotes: "", rationale: "", needsReview: false)
            a.collectionID = checklist; a.identityConfirmed = confirmed
            return OwnedCard(state: "analyzed", analysis: a)
        }
        XCTAssertTrue(library.binders.isEmpty)
        var draft = owned("chrome", confirmed: true); draft.isScanDraft = true
        library.cards = [draft, owned("select", confirmed: false), owned("removed-checklist", confirmed: true), OwnedCard()]
        XCTAssertTrue(library.binders.isEmpty)
        library.cards.append(owned("flag-insert", confirmed: true))
        library.cards.append(owned("flag-insert", confirmed: true))
        let binder = try XCTUnwrap(library.binders.first)
        XCTAssertEqual(library.binders.count, 1)
        XCTAssertEqual(binder.product, .flagship)
        XCTAssertEqual(Set(binder.collections.map(\.id)), ["flag-base", "flag-insert"])
        XCTAssertEqual(binder.cards(in: library).count, 2)
        library.cards.removeLast()
        XCTAssertEqual(library.binders.count, 1)
        library.cards.removeLast()
        XCTAssertTrue(library.binders.isEmpty)
    }

    func testNamedCoversAcceptProductAliasesAndKeepUnknownProductsDistinct() throws {
        let products: [(String, String, BinderProduct)] = [
            ("Flagship", "Topps", .flagship), ("Bowman Chrome", "Topps", .bowman),
            ("Select", "Panini", .select), ("Stadium Club", "Topps", .stadiumClub),
            ("Heritage", "Topps", .heritage), ("Resurgence", "Topps", .resurgence),
            ("Phoenix", "Panini", .phoenix), ("Absolute", "Panini", .absolute)
        ]
        for (name, brand, expected) in products {
            var short = collection("short", name); short.brand = brand
            var full = collection("full", "2025 \(brand) \(name) Football"); full.brand = brand
            let binders = CollectionBinder.group([short, full])
            XCTAssertEqual(binders.count, 1, name)
            XCTAssertEqual(binders.first?.product, expected, name)
            XCTAssertEqual(binders.first?.name, expected.rawValue)
        }
        var heritageChrome = collection("one", "Topps Heritage Chrome"); heritageChrome.brand = "Topps"
        var other = collection("two", "Heritage"); other.brand = "Other"
        var generic = collection("three", "Rise"); generic.brand = "Brand A"
        var unrelated = generic; unrelated.id = "four"; unrelated.brand = "Brand B"
        let binders = CollectionBinder.group([heritageChrome, other, generic, unrelated])
        XCTAssertEqual(Set(binders.map(\.id)).count, 4)
        XCTAssertTrue(binders.allSatisfy { $0.product == nil })
        XCTAssertTrue(binders.contains { $0.name == "Topps Heritage Chrome" })
    }

    func testCountsKeepCopiesAndExcludeDraftsAndUnassignedCards() {
        var library = Library()
        library.collections = [collection("base", "Bowman Football")]
        var analysis = CardAnalysis(recommendation: "Keep", marketCheckedAt: "", marketSources: [], confidence: "high", conditionNotes: "", rationale: "", needsReview: false)
        analysis.collectionID = "base"; analysis.identityConfirmed = true
        let first = OwnedCard(analysis: analysis)
        var draft = OwnedCard(analysis: analysis); draft.isScanDraft = true
        library.cards = [first, OwnedCard(analysis: analysis), draft, OwnedCard()]
        XCTAssertEqual(library.binders[0].cards(in: library).count, 2)
    }

    func testBinderValuesCountPhysicalCopiesAndOnlyUseAvailablePrices() throws {
        let base = collection("base", "Topps Chrome")
        let insert = collection("insert", "Topps Chrome", subset: "Future Stars")
        let other = collection("other", "Topps Flagship")
        let now = Date()
        func card(_ id: String, in checklist: CardCollection, price: Int? = nil, currency: String = "EUR") -> OwnedCard {
            var analysis = CardAnalysis(recommendation: "Keep", marketCheckedAt: "2026-11-20", marketSources: [],
                confidence: "high", conditionNotes: "", rationale: "", needsReview: false)
            analysis.collectionID = checklist.id
            analysis.cardNumber = "1"
            analysis.subset = checklist.subset
            analysis.identityConfirmed = true
            if let price { analysis.setFixtureScoutValue(price, currency: currency, asOf: now) }
            return OwnedCard(id: id, state: "analyzed", analysis: analysis)
        }
        var draft = card("draft", in: base, price: 10_000)
        draft.isScanDraft = true
        var library = Library()
        library.collections = [base, insert, other]
        library.cards = [
            card("copy1", in: base, price: 150), card("copy2", in: base, price: 150),
            card("unpriced", in: base), card("insert", in: insert, price: 1_000, currency: "USD"),
            card("other", in: other, price: 5_000), draft
        ]
        library.removedCards = [card("removed", in: base, price: 20_000)]
        try library.setPersonalPrice(cardID: "copy2", amountCents: 275, currency: "EUR", asOf: now)

        let binder = try XCTUnwrap(library.binders.first { $0.product == .chrome })
        let cards = binder.cards(in: library)
        let prices = DashboardValueCache()
        let total = BinderValue(cards: cards, prices: prices, asOf: now)
        XCTAssertEqual(total.centsByCurrency, ["EUR": 425, "USD": 1_000])
        XCTAssertEqual(total.pricedCards, 3)
        XCTAssertEqual(total.ownedCards, 4)

        let checklist = BinderValue(cards: base.ownedCards(in: cards), prices: prices, asOf: now)
        XCTAssertEqual(checklist.centsByCurrency, ["EUR": 425])
        XCTAssertEqual(checklist.pricedCards, 2)
        XCTAssertEqual(checklist.ownedCards, 3)
        let specials = BinderValue(cards: binder.specials(in: library).map(\.card), prices: prices, asOf: now)
        XCTAssertEqual(specials.centsByCurrency, ["USD": 1_000])
        XCTAssertTrue(BinderValue(cards: [library.cards[2]], prices: prices, asOf: now).centsByCurrency.isEmpty)
    }

    func testCollectiblesPersistIndependentlyOfFavoritesAndSurviveAnalysisUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root)
        var card = OwnedCard(); card.isCollectible = true; card.isFavorite = false
        var draft = OwnedCard(); draft.isCollectible = true; draft.isScanDraft = true
        var library = Library(); library.cards = [card, draft]
        let analysis = CardAnalysis(recommendation: "Keep", marketCheckedAt: "", marketSources: [], confidence: "high", conditionNotes: "", rationale: "", needsReview: false)
        try library.applyJobResult(cardID: card.id, jobID: card.jobID, status: "analyzed", analysis: analysis, collection: nil, error: nil)
        try disk.save(library)
        let reloaded = try disk.load()
        XCTAssertEqual(reloaded.collectibles.map(\.id), [card.id])
        XCTAssertEqual(reloaded.cards[0].isFavorite, false)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as! [String: Any]
        object.removeValue(forKey: "isCollectible")
        XCTAssertNil(try JSONDecoder().decode(OwnedCard.self, from: JSONSerialization.data(withJSONObject: object)).isCollectible)
    }
}
