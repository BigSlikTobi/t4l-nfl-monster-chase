import Foundation

public enum PrintedField: String, CaseIterable, Identifiable, Sendable {
    case number, player, year, serial
    public var id: Self { self }
    public func normalized(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 80 else { return nil }
        switch self {
        case .player:
            return text.contains(where: \.isLetter) ? text : nil
        case .number:
            let value = text.hasPrefix("#") ? String(text.dropFirst()) : text
            return value.range(of: #"^[A-Za-z0-9]+([.\-][A-Za-z0-9]+)*$"#, options: .regularExpression) == nil ? nil : value.uppercased()
        case .year:
            return text.count == 4 && text.allSatisfy(\.isNumber) ? text : nil
        case .serial:
            let values = text.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard values.count == 2, values.allSatisfy({ (1...7).contains($0.count) && $0.allSatisfy(\.isNumber) }),
                  let copy = Int(values[0]), let run = Int(values[1]), copy > 0, copy <= run else { return nil }
            return values.joined(separator: "/")
        }
    }
}

public enum ScanCheck: Hashable, Sendable {
    case photo(CardPhotoSide), reading(PrintedField), finish, checklist, tilt
}

extension OwnedCard {
    public var reviewVariants: [CardSightVariant] {
        guard hasCurrentAnalysis, analysis?.cardSightIdentity != nil else { return [] }
        let variants = analysis?.cardSightVariants ?? []
        guard let serial = printedReadings?[PrintedField.serial.rawValue],
              let run = Int(serial.split(separator: "/").last.map(String.init) ?? "") else { return variants }
        return variants.filter { $0.numberedTo == nil || $0.numberedTo == run }
    }

    public var scanChecks: [ScanCheck] {
        if awaitingBack == true { return [.photo(.back)] }
        if automaticScan == true || analysis?.finishPolicy != nil {
            return canAddTilt && declinedReviewJobID != jobID ? [.tilt] : []
        }
        guard !isAwaitingAnalysis, state != "failed", declinedReviewJobID != jobID,
              let issue = ReviewIssue.identity(self) else { return [] }
        let a = analysis
        let notes = (a?.uncertainties ?? []).joined(separator: " ").lowercased()
        var checks: [ScanCheck] = []
        let serialClue = ["serial", "nummerierung", "stamped", "prägestempel"].contains(where: notes.contains)
        let numberClue = ["card number", "card #", "kartennummer", "checklist number"].contains(where: notes.contains)
        let assignedRun = a?.cardSightVariants?.first { $0.id == a?.cardSightIdentity?.parallelID }?.numberedTo
        if matchNotice == "catalog_missing" && a?.knownIdentityConflict == nil { return [] }
        if backFile == nil { checks.append(.photo(.back)) }
        if a?.player?.isEmpty != false && printedReadings?["player"] == nil { checks.append(.reading(.player)) }
        if (a?.cardNumber?.isEmpty != false || numberClue) && printedReadings?["number"] == nil { checks.append(.reading(.number)) }
        if a?.year == nil && printedReadings?["year"] == nil { checks.append(.reading(.year)) }
        if (serialClue || (assignedRun != nil && a?.serialNumber == nil) || a?.knownIdentityConflict != nil && a?.serialNumber != nil),
           printedReadings?["serial"] == nil { checks.append(.reading(.serial)) }
        if !reviewVariants.isEmpty && a?.identityConfirmed != true { checks.append(.finish) }
        let guide = CardIdentityReview(card: self)
        if guide.photoGuidance != nil, backFile != nil,
           ["glare", "blur", "unscharf", "spiegel", "verdeckt", "unreadable"].contains(where: notes.contains),
           !checks.contains(.photo(guide.recommendedSide)) { checks.append(.photo(guide.recommendedSide)) }
        if a?.knownIdentityConflict != nil || (matchSuggestions?.isEmpty == false && a?.identityConfirmed != true) ||
            (!checks.contains(.finish) && issue.kind != .back) { checks.append(.checklist) }
        return checks
    }
    public var analysisTextWithReadings: String? {
        guard let printedReadings, !printedReadings.isEmpty else { return captureText }
        let labels = PrintedField.allCases.compactMap { field in printedReadings[field.rawValue].map { field.rawValue + ": " + $0 } }
        let hint = (["Collector transcription: " + labels.joined(separator: ", ")] + [captureText].compactMap { $0 }).joined(separator: "\n")
        return String(hint.unicodeScalars.prefix(2_000))
    }
    public func conflictsWithReading(_ field: PrintedField, value: String) -> Bool {
        let known: String?
        switch field {
        case .number: known = analysis?.cardNumber
        case .year: known = analysis?.year.map(String.init)
        case .player: known = analysis?.player
        case .serial: known = analysis?.serialNumber
        }
        guard let known, let normalized = field.normalized(known) else { return false }
        if field == .serial {
            return normalized.split(separator: "/").compactMap { Int($0) } != value.split(separator: "/").compactMap { Int($0) }
        }
        return normalized.localizedCaseInsensitiveCompare(value) != .orderedSame
    }
}

extension Library {
    /// Observations belong to the physical card. Saving one never fills a binder slot.
    public mutating func recordReading(_ field: PrintedField, raw: String, cardID: String, jobID: String, reopen: Bool) throws {
        guard let value = field.normalized(raw), let i = cards.firstIndex(where: { $0.id == cardID && $0.jobID == jobID }),
              !cards[i].isAwaitingAnalysis, !cards[i].conflictsWithReading(field, value: value) || reopen else { throw StoreError.invalidResult }
        if reopen { try declineScanMatch(cardID: cardID, jobID: jobID) }
        var readings = cards[i].printedReadings ?? [:]
        readings[field.rawValue] = value
        cards[i].printedReadings = readings
    }

    public mutating func declineScanMatch(cardID: String, jobID: String) throws {
        guard let i = cards.firstIndex(where: { $0.id == cardID && $0.jobID == jobID }), !cards[i].isAwaitingAnalysis,
              cards[i].awaitingBack != true else { throw StoreError.invalidResult }
        supersededJobIDs = Array(Set((supersededJobIDs ?? []) + [jobID]))
        cards[i].analysisJobID = UUID().uuidString.lowercased()
        if var analysis = cards[i].analysis {
            let notes = analysis.uncertainties
            analysis.clearAssessmentAfterCorrection()
            analysis.uncertainties = notes; analysis.identityConfirmed = false; analysis.collectionID = nil
            cards[i].analysis = analysis
        }
        cards[i].state = "unidentified"; cards[i].manualAssignment = nil; cards[i].scanSelection = nil
        cards[i].hasProvisionalAnalysis = cards[i].analysis != nil
        cards[i].requestedVariantID = nil; cards[i].refreshOfJobID = nil; cards[i].preservesPreviousAnalysis = false
        cards[i].matchSuggestions = nil; cards[i].matchNotice = nil
        cards[i].declinedReviewJobID = cards[i].jobID
    }
}
