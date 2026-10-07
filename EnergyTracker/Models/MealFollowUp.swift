import Foundation
import SwiftData

/// A correction or extra detail the user adds after the initial estimate.
@Model
final class MealFollowUp {
    var text: String = ""
    var createdAt: Date = Date()
    /// The model's summary of what it changed; nil until the follow-up has been applied.
    var reply: String?
    var rawResponse: String?
    var meal: Meal?

    init(text: String) {
        self.text = text
    }

    var isApplied: Bool { reply != nil }
}
