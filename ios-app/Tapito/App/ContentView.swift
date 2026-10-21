import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AgentSessionController
    @ObservedObject var statusPiP: StatusPiPController
    @ObservedObject private var sessions: ConversationStore
    let commands: SessionCommandService
    /// Shared voice session; each navigation destination owns its bottom layout.
    let voice: TapitoVoiceController
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [UUID] = []
    @State private var consumedActivityNavigationID: UUID?
    @State private var search = ""
    private enum Panel: String, Identifiable { case settings; var id: String { rawValue } }
    @State private var panel: Panel?
    init(model: AgentSessionController, statusPiP: StatusPiPController, commands: SessionCommandService, voice: TapitoVoiceController) {
        self.commands = commands
        self.voice = voice
        self.model = model; self.statusPiP = statusPiP; self.sessions = model.sessions
    }
    private var visible: [AgentConversation] {
        sessions.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sessions.conversations.isEmpty {
                    VStack(spacing: 22) {
                        Spacer()
                        Image(systemName: "cursorarrow.rays").font(.system(size: 42, weight: .medium)).foregroundStyle(TapitoPalette.accent)
                            .frame(width: 98, height: 98).background(TapitoPalette.ink, in: RoundedRectangle(cornerRadius: 32))
                        VStack(spacing: 8) {
                            Text("把想法，变成行动。").font(.system(.title2, design: .rounded, weight: .bold))
                            Text("说出目标，让 Tapito 帮你操作 iPhone。\n随时查看进展，也随时可以停止。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }
                        Button(action: createConversation) { Label("开始新任务", systemImage: "arrow.up.right").padding(.horizontal, 20).padding(.vertical, 6) }
                            .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("newConversation")
                        Spacer(); Spacer()
                    }.padding(28).frame(maxWidth: .infinity)
                } else {
                    List {
                        Section {
                            Button(action: createConversation) {
                                HStack(spacing: 16) {
                                    Image(systemName: "cursorarrow.rays").font(.title2).foregroundStyle(TapitoPalette.accent)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("有什么交给我？").font(.title3.weight(.semibold)).foregroundStyle(.white)
                                        Text("一句话，开始一个新任务").font(.caption).foregroundStyle(.white.opacity(0.6))
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "plus").foregroundStyle(TapitoPalette.accent)
                                }.padding(20).background(TapitoPalette.ink, in: RoundedRectangle(cornerRadius: 24))
                            }.buttonStyle(.plain).accessibilityIdentifier("newTaskCard")
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 20, trailing: 16))
                                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                        }
                        Section("最近会话") {
                        if let warning = sessions.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                        ForEach(visible) { session in
                            NavigationLink(value: session.id) {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: session.phase == .running ? "circle.dotted" : "bubble.left")
                                        .foregroundStyle(.indigo).frame(width: 36, height: 36)
                                        .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text(session.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        HStack(spacing: 6) {
                                            Text(session.phase.label)
                                            Text("·")
                                            Text(session.updatedAt, style: .relative)
                                        }.font(.caption2).foregroundStyle(.tertiary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.vertical, 4)
                            }
                            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16))
                            .swipeActions { if !model.isRunning(in: session.id) { Button("删除", role: .destructive) { sessions.delete(session.id) } } }
                        }
                        if visible.isEmpty { ContentUnavailableView.search(text: search) }
                        }
                    }.listStyle(.plain)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VoiceSessionPanel(controller: voice, session: voice.session)
            }
            .navigationTitle("Tapito")
            .searchable(text: $search, prompt: "搜索会话")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { panel = .settings } label: { Image(systemName: "gear") }.accessibilityLabel("设置") }
                ToolbarItem(placement: .topBarTrailing) { Button(action: createConversation) { Image(systemName: "square.and.pencil") }.accessibilityLabel("新建会话").accessibilityIdentifier("newConversationToolbar") }
            }
            .navigationDestination(for: UUID.self) { id in
                ConversationView(model: model, conversationID: id, voice: voice).id(id)
            }
            .sheet(item: $panel) { item in
                switch item {
                case .settings: SettingsView(model: model)
                }
            }

        }
        .tint(.indigo)
        .onOpenURL { url in
            if url == URL(string: "tapito://home") {
                consumedActivityNavigationID = model.activityNavigation?.id
                path = []; panel = nil
            } else { model.openActivityURL(url) }
        }
        .onChange(of: path) { old, new in
            for id in old where !new.contains(id) { model.discardConversationDraft(id) }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("--task-pip-probe"),
               ProcessInfo.processInfo.arguments.contains("--background-stream-probe"), let id = sessions.conversations.first?.id {
                path = [id]
            }
        }
        #endif
        .onChange(of: model.activityNavigation, initial: true) { _, _ in
            routeActivityNavigation()
        }
        .alert("实时活动链接", isPresented: Binding(get: { model.activityLinkError != nil }, set: { if !$0 { model.activityLinkError = nil } })) {
            Button("知道了") { model.activityLinkError = nil }
        } message: { Text(model.activityLinkError ?? "") }
        .onChange(of: commands.pendingRoute, initial: true) { _, _ in routePreparedTask() }
        .onChange(of: model.running) { _, _ in routePreparedTask() }
        .onChange(of: model.stopping) { _, _ in routePreparedTask() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { routeActivityNavigation(); routePreparedTask() }
        }
        .onChange(of: panel) { _, value in if value == nil { routePreparedTask() } }
    }
    private func routeActivityNavigation() {
        // A completion can arrive while UIKit is still displaying another app.
        // Keep its destination pending until this scene can mount the message UI.
        guard scenePhase == .active, let destination = model.activityNavigation,
              consumedActivityNavigationID != destination.id else { return }
        consumedActivityNavigationID = destination.id
        panel = nil
        path = [destination.route.sessionID]
    }
    private func routePreparedTask() {
        guard scenePhase == .active, panel == nil, let id = commands.pendingRoute,
              path.last != id else { return }
        if case .open(let destination) = try? commands.perform(SessionCommand(.open, sessionID: id, source: .app)) {
            path = [destination]
        }
    }
    private func createConversation() {
        path.append(model.createConversationDraft(mode: .live))
    }
}
