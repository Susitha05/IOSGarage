import SwiftUI

extension Double {
    var money: String { formatted(.currency(code: Locale.current.currency?.identifier ?? "USD").precision(.fractionLength(0))) }
}

extension AppointmentStatus {
    var color: Color {
        switch self {
        case .pending: .orange; case .confirmed: .blue; case .inProgress: .purple
        case .completed: .green; case .rejected, .cancelled: .red; case .noShow: .gray
        }
    }
}

struct Badge: View {
    let text: String; let color: Color
    var body: some View {
        Text(text).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
            .accessibilityLabel("Status: \(text)")
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity, minHeight: 48)
            .background(tint.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
    }
}

extension View {
    func numeric() -> some View { keyboardType(.numberPad) }
}
