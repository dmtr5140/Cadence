import SwiftUI

struct YourWaveButton: View {
    @State private var isStarting = false
    @State private var feedback: Feedback?
    @State private var request: Task<Void, Never>?

    private enum Feedback: String, Identifiable {
        case noLikes, libraryUnavailable
        var id: Self { self }
        var message: LocalizedStringKey {
            switch self {
            case .noLikes: return "Отметь несколько треков как понравившиеся."
            case .libraryUnavailable: return "Не удалось открыть медиатеку. Попробуй ещё раз."
            }
        }
    }

    var body: some View {
        Button(action: start) {
            HStack(spacing: 12) {
                Label("Своя волна", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Group {
                    if isStarting { ProgressView() }
                    else { Image(systemName: "play.fill") }
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .onDisappear { request?.cancel() }
        .alert(item: $feedback) { item in
            Alert(title: Text("Своя волна"), message: Text(item.message))
        }
    }

    private func start() {
        isStarting = true
        request = Task { @MainActor in
            defer { isStarting = false; request = nil }
            switch await YourWave.play() {
            case .started: AppRouter.shared.expandPlayer()
            case .noLikes: feedback = .noLikes
            case .libraryUnavailable: feedback = .libraryUnavailable
            case .cancelled: break
            }
        }
    }
}
