import SwiftUI
import Latchway

private let brand = Color(red: 0.04, green: 0.49, blue: 0.43)

struct ContentView: View {
    @StateObject private var model = ChatModel()
    @State private var email = ""
    @State private var password = ""
    @State private var creating = false
    @State private var draft = ""
    @State private var showConnection = false
    @State private var showSettings = false
    @State private var sendTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if model.email == nil { login }
                else { chat }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(model.email == nil ? "" : "LatchwayChat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.email != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showConnection = true } label: {
                            Image(systemName: model.verified ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                                .foregroundStyle(model.verified ? brand : .orange)
                        }.accessibilityLabel("Connection details")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("New conversation", systemImage: "square.and.pencil") { model.clearChat() }
                            Button("Settings", systemImage: "gearshape") { showSettings = true }
                            Button("Connection details", systemImage: "network") { showConnection = true }
                            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                                Task { await model.signOut() }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .disabled(model.busy || model.streaming)
                        .accessibilityLabel("Chat options")
                    }
                }
            }
            .sheet(isPresented: $showConnection) { connection }
            .sheet(isPresented: $showSettings) { settings }
            .task { await model.start() }
        }
        .tint(brand)
    }

    private var login: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 42, weight: .medium)).foregroundStyle(brand)
                        .padding(18).background(brand.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
                    Text("LatchwayChat").font(.largeTitle.bold())
                    Text("A real conversation.\nA verified device.").font(.title2.weight(.medium))
                    Text("Ask anything about Latchway. Your identity comes from Firebase; your iPhone proves itself with App Attest.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 18) {
                    Picker("Account action", selection: $creating) {
                        Text("Sign In").tag(false)
                        Text("Sign Up").tag(true)
                    }.pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Email address").font(.caption.weight(.semibold))
                        TextField("you@example.com", text: $email)
                            .keyboardType(.emailAddress).textContentType(.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("auth.email")
                            .padding(13).background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Password").font(.caption.weight(.semibold))
                        SecureField(creating ? "At least 8 characters" : "Your password", text: $password)
                            .textContentType(creating ? .newPassword : .password)
                            .accessibilityIdentifier("auth.password")
                            .padding(13).background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let error = model.errorMessage { errorBanner(error) }
                    Button {
                        let submittedPassword = password
                        password = ""
                        Task { await model.authenticate(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: submittedPassword, creating: creating) }
                    } label: {
                        HStack {
                            if model.busy { ProgressView().tint(.white) }
                            Text(model.busy ? "Connecting…" : (creating ? "Create account" : "Sign in securely"))
                            if !model.busy { Image(systemName: "arrow.right") }
                        }.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("auth.submit")
                    .disabled(model.busy || email.isEmpty || password.count < (creating ? 8 : 1))
                }
                .padding(22).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 10) {
                    Label("No provider API key on your phone", systemImage: "key.slash")
                    Label("Chat history stays in memory", systemImage: "clock.badge.checkmark")
                    Text("DEVELOPMENT DEMO · HABITIFY-HOSTED GATEWAY")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).padding(.top, 4)
                }.font(.footnote).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: model.verified ? "checkmark.seal.fill" : "exclamationmark.shield") }
                Text(model.connectionStatus).font(.caption)
                Spacer(minLength: 0)
                if !model.verified && !model.busy {
                    Button("Retry") { Task { await model.reconnect() } }.font(.caption.bold())
                }
            }
            .foregroundStyle(model.verified ? brand : Color.secondary)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground))
            HStack {
                Label(model.engine.title, systemImage: model.engine == .foundationModels ? "apple.intelligence" : "network")
                Spacer()
                Button("Settings") { showSettings = true }.disabled(model.streaming || model.busy)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if model.messages.isEmpty { welcome }
                        ForEach(model.weatherLookups) { lookup in
                            Label("Weather checked · \(lookup.location) · \(lookup.temperature.formatted()) °C", systemImage: "cloud.sun.fill")
                                .font(.caption).foregroundStyle(brand)
                                .padding(10).background(brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        ForEach(model.messages) { message in
                            HStack(alignment: .top) {
                                if message.role == "user" { Spacer(minLength: 36) }
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(message.role == "user" ? "YOU" : "LATCHWAY")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(message.role == "user" ? Color.white.opacity(0.75) : brand)
                                    if message.content.isEmpty { ProgressView().padding(.vertical, 4) }
                                    else { Text(.init(message.content)).textSelection(.enabled).font(.body) }
                                }
                                .padding(16)
                                .foregroundStyle(message.role == "user" ? Color.white : Color.primary)
                                .background(message.role == "user" ? brand : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                                if message.role != "user" { Spacer(minLength: 12) }
                            }.id(message.id)
                        }
                        if let error = model.errorMessage { errorBanner(error) }
                    }.padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages) { _, _ in
                    if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Ask about Latchway…", text: $draft, axis: .vertical)
                        .lineLimit(1...5).focused($composerFocused)
                        .accessibilityIdentifier("chat.composer").disabled(!model.verified || model.busy)
                        .padding(13).background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    Button {
                        if model.streaming { sendTask?.cancel() }
                        else { submit(draft) }
                    } label: {
                        Image(systemName: model.streaming ? "stop.fill" : "arrow.up")
                            .font(.headline).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(brand, in: Circle())
                    }
                    .accessibilityLabel(model.streaming ? "Stop reply" : "Send message")
                    .accessibilityIdentifier("chat.send")
                    .disabled(!model.verified || model.busy || (!model.streaming && (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 6000)))
                }
                Text(model.lastUsage?.total_tokens.map { "\($0.formatted()) tokens · Temporary chat · AI can make mistakes" }
                     ?? "Temporary chat · AI can make mistakes")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            .background(Color(.secondarySystemGroupedBackground))
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Meet your gateway.").font(.title.bold()).padding(.top, 32)
            Text("Explore how Latchway connects app identity, device trust, and AI—through a real, live conversation.").foregroundStyle(.secondary)
            ForEach(model.engine == .foundationModels
                    ? ["How does Latchway work?", "What's the weather in Singapore?", "Check the weather in London and Tokyo", "How does the weather tool work?"]
                    : ["How does Latchway work?", "How do I integrate the iOS SDK?", "Explain App Attest and DPoP", "How are daily token quotas enforced?"], id: \.self) { prompt in
                Button { submit(prompt) } label: {
                    HStack { Text(prompt); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.subheadline).padding(15)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
                }.disabled(!model.verified || model.busy || model.streaming)
            }
        }.padding(.bottom, 20)
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Chat implementation", selection: Binding(get: { model.engine }, set: { engine in
                        Task { await model.selectEngine(engine) }
                    })) {
                        ForEach(ChatEngine.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline).accessibilityIdentifier("settings.engine")
                } header: { Text("Chat engine") } footer: {
                    Text("Switching starts a new, in-memory conversation. Both modes use Firebase Auth, real App Attest, Secure Enclave DPoP, and the Habitify-hosted Latchway gateway.")
                }
                Section("Foundation Models") {
                    Label("Apple LanguageModelSession + Latchway executor", systemImage: "apple.intelligence")
                    Label("Weather check tool with multi-turn context", systemImage: "cloud.sun")
                    Text("This is a remote model through Latchway—not Apple's on-device model. Weather uses Open-Meteo and GeoNames; only the city you request is sent. No GPS permission is used.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Weather data: Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                }
                Section("Custom URLSession") {
                    Text("Direct authenticated Chat Completions streaming through Latchway. No Foundation Models tool loop.")
                }
            }
            .disabled(model.busy || model.streaming)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
        }
    }

    private var connection: some View {
        NavigationStack {
            List {
                Section("Live connection") {
                    LabeledContent("Gateway", value: "latchway.habitify.me")
                    LabeledContent("Firebase", value: "latchway")
                    LabeledContent("Environment", value: "Development")
                    LabeledContent("Account", value: model.email ?? "Signed out")
                }
                Section("Device-bound session") {
                    LabeledContent("State", value: model.diagnostics?.sessionState.rawValue ?? "Not established")
                    LabeledContent("Attestation", value: model.diagnostics?.trustProvider ?? "Not verified")
                    LabeledContent("Trust", value: model.diagnostics?.trustLevel ?? "Not verified")
                    LabeledContent("Key storage", value: model.diagnostics?.keyStorage.rawValue ?? "Unavailable")
                    LabeledContent("Server", value: model.diagnostics?.serverVersion ?? "Unknown")
                }
                if let limit = model.quota?.limits.first(where: { $0.metric == "total_tokens" }) {
                    Section("Daily input + output allowance · UTC") {
                        LabeledContent("Used", value: limit.used?.formatted() ?? "Unknown")
                        LabeledContent("Remaining", value: limit.remaining?.formatted() ?? "Unknown")
                        LabeledContent("Maximum", value: limit.maximum?.formatted() ?? "Unknown")
                    }
                }
                if let requestID = model.requestID {
                    Section("Last gateway request") { Text(requestID).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Section {
                    Text("Chat messages are kept only in this process's memory. Firebase sign-in and Latchway session credentials use their secure persistence. The gateway records redacted request and usage metadata; upstream providers process the conversation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connection proof").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showConnection = false } } }
        }
    }

    private func submit(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        composerFocused = false
        sendTask = Task { await model.send(text) }
    }

    private func errorBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("error.message")
    }
}
