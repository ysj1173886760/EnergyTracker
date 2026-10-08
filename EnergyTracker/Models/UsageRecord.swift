import Foundation
import SwiftData

@Model
final class UsageRecord {
    var date: Date = Date()
    var feature: String = ""
    var model: String = ""
    var provider: String?
    var generationID: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
    var cost: Double?
    var succeeded: Bool = false
    var errorSummary: String?
    var subjectID: String?

    init(_ entry: UsageEntry) {
        date = entry.date
        feature = entry.feature
        model = entry.model
        provider = entry.provider
        generationID = entry.generationID
        promptTokens = entry.promptTokens
        completionTokens = entry.completionTokens
        reasoningTokens = entry.reasoningTokens
        cost = entry.cost
        succeeded = entry.succeeded
        errorSummary = entry.errorSummary
        subjectID = entry.subjectID
    }

    var entry: UsageEntry {
        UsageEntry(
            date: date,
            feature: feature,
            model: model,
            provider: provider,
            generationID: generationID,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            reasoningTokens: reasoningTokens,
            cost: cost,
            succeeded: succeeded,
            errorSummary: errorSummary,
            subjectID: subjectID
        )
    }
}
