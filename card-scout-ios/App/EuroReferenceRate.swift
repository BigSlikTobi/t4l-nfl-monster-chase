import Foundation

struct EuroReferenceRate: Codable {
    let rates: [String: Decimal]
    let publishedOn: String

    static func fetch() async throws -> Self {
        let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
        let request = URLRequest(url: url, timeoutInterval: 8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Self {
        let parser = XMLParser(data: data)
        let feed = Feed()
        parser.delegate = feed
        guard parser.parse(), let day = feed.day, feed.rates["USD"] != nil else {
            throw URLError(.cannotParseResponse)
        }
        return Self(rates: feed.rates, publishedOn: day)
    }

    private final class Feed: NSObject, XMLParserDelegate {
        var day: String?
        var rates: [String: Decimal] = [:]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            guard elementName == "Cube" else { return }
            if let date = attributes["time"] { day = date }
            guard day != nil, let currency = attributes["currency"], let rawRate = attributes["rate"],
                  let rate = Decimal(string: rawRate, locale: Locale(identifier: "en_US_POSIX")),
                  rate > 0 else { return }
            rates[currency] = rate
        }
    }
}
