import SwiftUI
import CardScoutCore

struct PersonalPriceEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let cardID: String
    let price: PersonalCardPrice?
    @State private var amount: String
    @State private var currency: String

    init(cardID: String, price: PersonalCardPrice?) {
        self.cardID = cardID; self.price = price
        _amount = State(initialValue: price.map { decimalInput($0.amountCents) } ?? "")
        _currency = State(initialValue: price?.currency ?? "EUR")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(tr("0,00"), text: $amount)
                        .keyboardType(.decimalPad).accessibilityLabel(tr("Dein Preis"))
                    Picker(tr("Währung"), selection: $currency) {
                        ForEach(CardPurchase.currencies, id: \.self) { Text(trDisplay($0)).tag($0) }
                    }
                } header: { Text(tr("Dein Preis")) } footer: {
                    Text(tr("Persönliche Schätzung für Burn Count."))
                }
                if price != nil {
                    Section {
                        Button(tr("Preis entfernen"), role: .destructive) {
                            if store.savePersonalPrice(cardID, amountCents: nil, currency: currency) { dismiss() }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Color.scoutCanvas)
            .navigationTitle(tr("Dein Preis")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Abbrechen")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Speichern")) {
                        guard let cents = PersonalCardPrice.parseAmount(amount) else { return }
                        if store.savePersonalPrice(cardID, amountCents: cents, currency: currency) { dismiss() }
                    }.fontWeight(.semibold).disabled(PersonalCardPrice.parseAmount(amount) == nil)
                }
            }
        }
    }
}
