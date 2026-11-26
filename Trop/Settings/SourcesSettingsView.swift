//
// SourcesSettingsView.swift
// Trop
//
// Which services are on, what they need, and what they cannot do. The notes
// are the honest part: Yandex needs Plus, Spotify has no stream, VK has no
// access, Apple Music hands playback to the system player.
//

import SwiftUI

struct SourcesSettingsView: View {
    @Environment(SourceRegistry.self) private var registry

    @State private var soundCloudID = SoundCloudSource.storedClientID ?? ""
    @State private var yandexToken = YandexSource.token ?? ""
    @State private var yandexStatus: String?
    @State private var isChecking = false

    var body: some View {
        @Bindable var registry = registry

        List {
            Section {
                NavigationLink {
                    SourcesSearchView()
                } label: {
                    Label("Поиск по источникам", systemImage: "magnifyingglass")
                }

                NavigationLink {
                    ServiceAccountsView()
                } label: {
                    Label("Аккаунты сервисов", systemImage: "person.badge.key")
                }

                Picker("Режим", selection: $registry.mode) {
                    ForEach(SourceRegistry.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if registry.mode == .only {
                    Picker("Сервис", selection: $registry.only) {
                        ForEach(SourceID.allCases.filter { $0.isAvailable && $0 != .youtube }) { id in
                            Text(id.title).tag(id)
                        }
                    }
                }
            } header: {
                Text("Поиск")
            } footer: {
                Text("«Вперемешку» опрашивает все включённые сервисы и перемешивает выдачу, «только один» — лишь выбранный.")
            }

            Section {
                LabeledContent("YouTube Music", value: "Встроен")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { registry.isEnabled(.soundcloud) },
                    set: { registry.setEnabled(.soundcloud, $0) }
                )) {
                    Text("SoundCloud")
                }

                if registry.isEnabled(.soundcloud) {
                    TextField("client_id (необязательно)", text: $soundCloudID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { SoundCloudSource.setClientID(soundCloudID) }

                    Button("Сохранить и найти client_id") {
                        Task {
                            SoundCloudSource.setClientID(soundCloudID)
                            if let id = try? await SoundCloudSource.clientID() {
                                await MainActor.run { soundCloudID = id }
                            }
                        }
                    }
                    .font(.footnote)
                }
            } header: {
                Text("SoundCloud")
            } footer: {
                Text("Публичный поиск и публичные треки играют напрямую. Go+ и треки с ограничением правообладателя вернут ошибку — это ограничение сервиса, не приложения.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { registry.isEnabled(.yandex) },
                    set: { registry.setEnabled(.yandex, $0) }
                )) {
                    Text("Яндекс Музыка")
                }

                if registry.isEnabled(.yandex) {
                    SecureField("OAuth-токен", text: $yandexToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button("Сохранить токен") {
                            YandexSource.setToken(yandexToken)
                            yandexStatus = nil
                        }
                        Spacer()
                        Button(isChecking ? "Проверяю…" : "Проверить") {
                            YandexSource.setToken(yandexToken)
                            isChecking = true
                            Task {
                                defer { Task { @MainActor in isChecking = false } }
                                do {
                                    let status = try await YandexSource.accountStatus()
                                    await MainActor.run {
                                        yandexStatus = status.hasPlus
                                            ? "\(status.name) · Плюс активен"
                                            : "\(status.name) · Плюса нет, только каталог"
                                    }
                                } catch {
                                    await MainActor.run { yandexStatus = error.localizedDescription }
                                }
                            }
                        }
                        .disabled(isChecking)
                    }
                    .font(.footnote)

                    if let yandexStatus {
                        Text(yandexStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Яндекс Музыка")
            } footer: {
                Text("Нужен Яндекс Плюс. Без подписки сервис отдаёт каталог и 30-секундные превью, полный поток — только подписчику. Токен хранится на устройстве.")
            }

            Section {
                unavailableRow(.spotify)
                unavailableRow(.vk)
                unavailableRow(.appleMusic)
            } header: {
                Text("Пока не подключены")
            }
        }
        .navigationTitle("Источники")
    }

    @ViewBuilder
    private func unavailableRow(_ id: SourceID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(id.title)
            if let note = id.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
