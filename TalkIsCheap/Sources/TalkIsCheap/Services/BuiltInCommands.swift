import Foundation

/// Intercepts common voice queries (weather, crypto prices) with free
/// public APIs so we answer in <1 s instead of routing through Brave +
/// Claude where "Bitcoin price?" just yields "check CoinMarketCap".
///
/// Runs in AppState.performSearch BEFORE connector routing and web
/// search. Returns a ready-made SearchResult if it matches, else nil.
enum BuiltInCommands {
    static func tryHandle(query: String) async -> SearchResult? {
        let q = query.lowercased()
        if let result = await handleCrypto(query: query, lower: q) { return result }
        if let result = await handleStock(query: query, lower: q) { return result }
        if let result = await handleWeather(query: query, lower: q) { return result }
        return nil
    }

    // MARK: - Stocks / ETFs / Indices / FX (Yahoo Finance, no key)

    private static let stockIntentMarkers = [
        "aktie", "aktien", "stock", "stocks", "share", "shares",
        "etf", "etfs", "kurs", "preis", "price",
        "börse", "boerse", "exchange", "index", "ticker",
        "nasdaq", "dax", "s&p", "dow", "nikkei"
    ]

    /// Well-known brand → ticker shortcuts so "Tesla Aktie" skips the
    /// search step and hits the chart endpoint directly.
    private static let tickerAliases: [(names: [String], symbol: String)] = [
        (["apple"],                   "AAPL"),
        (["tesla"],                   "TSLA"),
        (["microsoft"],               "MSFT"),
        (["nvidia"],                  "NVDA"),
        (["amazon"],                  "AMZN"),
        (["meta", "facebook"],        "META"),
        (["alphabet", "google"],      "GOOGL"),
        (["netflix"],                 "NFLX"),
        (["amd"],                     "AMD"),
        (["intel"],                   "INTC"),
        (["sap"],                     "SAP"),
        (["siemens"],                 "SIE.DE"),
        (["volkswagen", "vw"],        "VOW3.DE"),
        (["bmw"],                     "BMW.DE"),
        (["mercedes"],                "MBG.DE"),
        (["allianz"],                 "ALV.DE"),
        (["deutsche bank"],           "DBK.DE"),
        (["sp 500", "s&p 500", "s&p"], "^GSPC"),
        (["dow jones", "dow"],        "^DJI"),
        (["nasdaq"],                  "^IXIC"),
        (["dax"],                     "^GDAXI"),
        (["ftse"],                    "^FTSE"),
        (["nikkei"],                  "^N225"),
        (["vwce"],                    "VWCE.DE"),
        (["spy"],                     "SPY"),
        (["qqq"],                     "QQQ"),
        (["voo"],                     "VOO"),
        (["msci world", "mwrd"],      "URTH"),
    ]

    private static func handleStock(query: String, lower: String) async -> SearchResult? {
        let hasStockIntent = stockIntentMarkers.contains { lower.contains($0) }

        // 1. Fast path: user-said brand name or ticker we know directly.
        for entry in tickerAliases {
            for name in entry.names {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\b"
                if lower.range(of: pattern, options: .regularExpression) != nil {
                    if hasStockIntent || name.count >= 4 {
                        if let result = try? await fetchAndFormatQuote(symbol: entry.symbol, query: query) {
                            return result
                        }
                    }
                }
            }
        }

        // 2. Slow path: if the query looks stock-ish, use Yahoo's search to
        //    resolve whatever the user said to a ticker, then hit the chart
        //    endpoint. Only triggered when the query explicitly mentions
        //    stock/aktie/kurs/etf to avoid hijacking generic questions.
        guard hasStockIntent else { return nil }

        let searchTerm = stripIntentWords(from: query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchTerm.count >= 2 else { return nil }
        guard let resolved = try? await yahooSearch(term: searchTerm) else { return nil }
        return try? await fetchAndFormatQuote(symbol: resolved.symbol, query: query, fallbackName: resolved.name)
    }

    private static func stripIntentWords(from query: String) -> String {
        var s = query
        for word in stockIntentMarkers + ["aktuell", "current", "wie", "was", "kurs", "preis"] {
            s = s.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct YahooSearchMatch {
        let symbol: String
        let name: String
    }

    private static func yahooSearch(term: String) async throws -> YahooSearchMatch? {
        let urlStr = "https://query1.finance.yahoo.com/v1/finance/search?q=\(term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term)&quotesCount=3&newsCount=0"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) TalkIsCheap/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 6
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quotes = json["quotes"] as? [[String: Any]],
              let first = quotes.first,
              let symbol = first["symbol"] as? String
        else { return nil }
        let name = (first["longname"] as? String)
            ?? (first["shortname"] as? String)
            ?? symbol
        return YahooSearchMatch(symbol: symbol, name: name)
    }

    private struct QuoteData {
        let symbol: String
        let name: String
        let currency: String
        let price: Double
        let prevClose: Double?
        let exchange: String?
    }

    private static func fetchYahooQuote(symbol: String) async throws -> QuoteData? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        let urlStr = "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=1d"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) TalkIsCheap/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 6
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let result = results.first,
              let meta = result["meta"] as? [String: Any]
        else { return nil }
        let price = (meta["regularMarketPrice"] as? Double) ?? 0
        let prev = meta["chartPreviousClose"] as? Double
        let currency = meta["currency"] as? String ?? "USD"
        let exchange = meta["exchangeName"] as? String
        let longName = (meta["longName"] as? String)
            ?? (meta["shortName"] as? String)
            ?? (meta["symbol"] as? String)
            ?? symbol
        return QuoteData(
            symbol: symbol, name: longName, currency: currency,
            price: price, prevClose: prev, exchange: exchange
        )
    }

    private static func fetchAndFormatQuote(symbol: String, query: String, fallbackName: String? = nil) async throws -> SearchResult? {
        guard var quote = try await fetchYahooQuote(symbol: symbol) else { return nil }
        if let fallback = fallbackName, quote.name == symbol { quote = QuoteData(
            symbol: quote.symbol, name: fallback, currency: quote.currency,
            price: quote.price, prevClose: quote.prevClose, exchange: quote.exchange
        ) }

        var md = "## \(quote.name) (\(quote.symbol))\n\n"
        md += "**\(formatCurrency(quote.price, currency: quote.currency))**"
        if let prev = quote.prevClose, prev > 0 {
            let diff = quote.price - prev
            let pct = diff / prev * 100
            let arrow = diff >= 0 ? "↑" : "↓"
            md += " · \(arrow) \(String(format: "%.2f", abs(pct)))% \(diff >= 0 ? "+" : "")\(String(format: "%.2f", diff))"
        }
        md += "\n"
        if let ex = quote.exchange { md += "Exchange: \(ex)\n" }

        _ = query
        let chartURL = "https://www.tradingview.com/symbols/\(quote.symbol.replacingOccurrences(of: "^", with: ""))/"
        return SearchResult(
            query: query,
            answer: md,
            sources: [SearchSource(
                title: "Yahoo Finance — \(quote.symbol)",
                url: "https://finance.yahoo.com/quote/\(quote.symbol)",
                thumbnail: nil
            )],
            images: [],
            widgetUrl: chartURL,
            connectorId: "stock",
            connectorName: "Finance",
            connectorIcon: "chart.line.uptrend.xyaxis"
        )
    }

    // MARK: - Crypto

    /// Most common tokens mapped to their CoinGecko IDs. Not exhaustive —
    /// falls back to CoinGecko's search API when the spoken token isn't
    /// in the table.
    private static let cryptoMap: [(patterns: [String], coinGecko: String, symbol: String)] = [
        (["bitcoin", "btc"],      "bitcoin",      "BTC"),
        (["ethereum", "ether", "eth"], "ethereum", "ETH"),
        (["solana", "sol"],       "solana",       "SOL"),
        (["ripple", "xrp"],       "ripple",       "XRP"),
        (["cardano", "ada"],      "cardano",      "ADA"),
        (["dogecoin", "doge"],    "dogecoin",     "DOGE"),
        (["polygon", "matic"],    "matic-network","MATIC"),
        (["chainlink", "link"],   "chainlink",    "LINK"),
        (["avalanche", "avax"],   "avalanche-2",  "AVAX"),
        (["polkadot", "dot"],     "polkadot",     "DOT"),
        (["litecoin", "ltc"],     "litecoin",     "LTC"),
        (["uniswap", "uni"],      "uniswap",      "UNI"),
        (["arbitrum", "arb"],     "arbitrum",     "ARB"),
        (["optimism", "op"],      "optimism",     "OP"),
        (["shiba", "shib"],       "shiba-inu",    "SHIB"),
        (["pepe"],                "pepe",         "PEPE"),
        (["toncoin", "ton"],      "the-open-network", "TON"),
    ]

    private static func handleCrypto(query: String, lower: String) async -> SearchResult? {
        // Need a price-intent signal to avoid hijacking "write about bitcoin".
        let priceWords = ["preis", "price", "kurs", "wert", "worth", "cost", "aktuell", "current", "rate", "wie viel", "was kostet", "what is", "how much"]
        let hasPriceIntent = priceWords.contains { lower.contains($0) }

        guard let coin = cryptoMap.first(where: { entry in
            entry.patterns.contains { p in
                // word-boundary match so "stetig" doesn't match "eth".
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: p))\\b"
                return lower.range(of: pattern, options: .regularExpression) != nil
            }
        }) else {
            return nil
        }

        // If the user JUST said a coin name without a price verb, still answer
        // (voice queries are terse). Only skip when the query is clearly
        // about something else ("bitcoin whitepaper", "ethereum roadmap").
        let nonPriceMarkers = ["whitepaper", "roadmap", "history", "geschichte", "erfinder", "invented", "what is the goal"]
        if !hasPriceIntent && nonPriceMarkers.contains(where: { lower.contains($0) }) {
            return nil
        }

        guard let data = try? await fetchCryptoPrice(coinId: coin.coinGecko) else { return nil }

        let md = formatCrypto(data: data, symbol: coin.symbol)
        return SearchResult(
            query: query,
            answer: md,
            sources: [
                SearchSource(title: "CoinGecko — \(coin.symbol)", url: "https://www.coingecko.com/en/coins/\(coin.coinGecko)", thumbnail: nil)
            ],
            images: [],
            widgetUrl: "https://www.tradingview.com/symbols/\(coin.symbol)USD/",
            connectorId: "crypto",
            connectorName: "CoinGecko",
            connectorIcon: "bitcoinsign.circle.fill"
        )
    }

    private struct CryptoPrice {
        let name: String
        let priceUSD: Double
        let priceEUR: Double?
        let change24h: Double?
        let marketCap: Double?
        let marketRank: Int?
    }

    private static func fetchCryptoPrice(coinId: String) async throws -> CryptoPrice {
        let url = URL(string: "https://api.coingecko.com/api/v3/coins/\(coinId)?localization=false&tickers=false&community_data=false&developer_data=false&sparkline=false")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let name = json["name"] as? String ?? coinId
        let market = json["market_data"] as? [String: Any] ?? [:]
        let prices = market["current_price"] as? [String: Any] ?? [:]
        let priceUSD = (prices["usd"] as? Double) ?? 0
        let priceEUR = prices["eur"] as? Double
        let change24h = (market["price_change_percentage_24h"] as? Double)
        let caps = market["market_cap"] as? [String: Any] ?? [:]
        let marketCap = caps["usd"] as? Double
        let rank = json["market_cap_rank"] as? Int
        return CryptoPrice(
            name: name, priceUSD: priceUSD, priceEUR: priceEUR,
            change24h: change24h, marketCap: marketCap, marketRank: rank
        )
    }

    private static func formatCrypto(data: CryptoPrice, symbol: String) -> String {
        let priceUSDStr = formatCurrency(data.priceUSD, currency: "USD")
        var md = "## \(data.name) (\(symbol))\n\n"
        md += "**\(priceUSDStr)**"
        if let change = data.change24h {
            let arrow = change >= 0 ? "↑" : "↓"
            md += " · \(arrow) \(String(format: "%.2f", abs(change)))% (24h)"
        }
        md += "\n"
        if let eur = data.priceEUR {
            md += "EUR \(formatCurrency(eur, currency: "EUR"))\n"
        }
        if let cap = data.marketCap {
            md += "\nMarket cap: \(formatLargeNumber(cap, currency: "USD"))"
        }
        if let rank = data.marketRank {
            md += " · Rank #\(rank)"
        }
        return md
    }

    // MARK: - Weather (wttr.in — no API key required)

    private static let weatherWords = ["wetter", "weather", "temperatur", "temperature", "regen", "sonne", "sonnig", "rainy", "forecast", "vorhersage"]

    private static func handleWeather(query: String, lower: String) async -> SearchResult? {
        guard weatherWords.contains(where: { lower.contains($0) }) else { return nil }

        // Extract location — everything after "in <city>" / "für <city>"
        // / "for <city>". If we can't find one, default to the user's
        // Mac-configured location via ~wttr.in's "Auto".
        let locationMarkers = [" in ", " für ", " for ", " at ", " around "]
        var location = ""
        for marker in locationMarkers {
            if let range = lower.range(of: marker) {
                location = String(query[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "?.!,;"))
                break
            }
        }

        let locSlug = location.isEmpty
            ? ""  // wttr.in defaults to IP-based location
            : location
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
                .replacingOccurrences(of: "%20", with: "+") ?? ""

        let urlStr = "https://wttr.in/\(locSlug)?format=j1"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let md = formatWeather(json: json, location: location)
        return SearchResult(
            query: query,
            answer: md,
            sources: [SearchSource(title: "wttr.in", url: urlStr.replacingOccurrences(of: "?format=j1", with: ""), thumbnail: nil)],
            images: [],
            widgetUrl: nil,
            connectorId: "weather",
            connectorName: "Weather",
            connectorIcon: "cloud.sun.fill"
        )
    }

    private static func formatWeather(json: [String: Any], location: String) -> String {
        let current = ((json["current_condition"] as? [[String: Any]])?.first) ?? [:]
        let nearest = ((json["nearest_area"] as? [[String: Any]])?.first) ?? [:]
        let areaNames = nearest["areaName"] as? [[String: Any]] ?? []
        let countryNames = nearest["country"] as? [[String: Any]] ?? []
        let areaName = (areaNames.first?["value"] as? String)
            ?? (location.isEmpty ? "" : location.capitalized)
        let countryName = (countryNames.first?["value"] as? String) ?? ""
        let displayLocation = [areaName, countryName].filter { !$0.isEmpty }.joined(separator: ", ")

        let tempC = current["temp_C"] as? String ?? "—"
        let feelsC = current["FeelsLikeC"] as? String ?? "—"
        let humidity = current["humidity"] as? String ?? "—"
        let windKph = current["windspeedKmph"] as? String ?? "—"
        let description = ((current["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? ""

        let icon = weatherEmoji(for: description)
        var md = "## \(icon) Weather in \(displayLocation.isEmpty ? "your area" : displayLocation)\n\n"
        md += "**\(tempC)°C** · \(description)\n"
        md += "Feels like \(feelsC)°C · Humidity \(humidity)% · Wind \(windKph) km/h\n"

        // 3-day glance
        if let forecast = json["weather"] as? [[String: Any]], !forecast.isEmpty {
            md += "\n### Next 3 days\n"
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let out = DateFormatter()
            out.dateFormat = "EEE"
            out.locale = Locale.autoupdatingCurrent
            for day in forecast.prefix(3) {
                let minT = day["mintempC"] as? String ?? "—"
                let maxT = day["maxtempC"] as? String ?? "—"
                let dateStr = day["date"] as? String ?? ""
                let pretty = df.date(from: dateStr).map(out.string(from:)) ?? dateStr
                let hourly = day["hourly"] as? [[String: Any]] ?? []
                let midday = hourly.first(where: { ($0["time"] as? String) == "1200" }) ?? hourly.first ?? [:]
                let cond = ((midday["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? ""
                md += "- **\(pretty)** \(minT)°–\(maxT)° · \(weatherEmoji(for: cond)) \(cond)\n"
            }
        }
        return md
    }

    private static func weatherEmoji(for desc: String) -> String {
        let d = desc.lowercased()
        if d.contains("thunder") || d.contains("storm") { return "⛈️" }
        if d.contains("rain") || d.contains("drizzle") || d.contains("shower") { return "🌧️" }
        if d.contains("snow") || d.contains("sleet") || d.contains("blizzard") { return "🌨️" }
        if d.contains("fog") || d.contains("mist") || d.contains("haze") { return "🌫️" }
        if d.contains("cloud") { return "☁️" }
        if d.contains("sunny") || d.contains("clear") { return "☀️" }
        if d.contains("partly") { return "⛅" }
        return "🌡️"
    }

    // MARK: - Shared helpers

    private static func formatCurrency(_ value: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = value < 1 ? 6 : 2
        return f.string(from: NSNumber(value: value)) ?? "\(currency) \(value)"
    }

    private static func formatLargeNumber(_ value: Double, currency: String) -> String {
        let symbol = currency == "USD" ? "$" : currency == "EUR" ? "€" : ""
        if value >= 1_000_000_000_000 {
            return String(format: "%@%.2fT", symbol, value / 1_000_000_000_000)
        }
        if value >= 1_000_000_000 {
            return String(format: "%@%.2fB", symbol, value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%@%.2fM", symbol, value / 1_000_000)
        }
        return formatCurrency(value, currency: currency)
    }
}
