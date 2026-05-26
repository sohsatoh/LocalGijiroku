import SwiftUI
import GijirokuCore

struct LibrarySidebar: View {
    @ObservedObject var library: LibraryModel
    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var renamingProject: Project?
    @State private var renameDraft = ""

    var body: some View {
        List(selection: Binding(
            get: { library.selection },
            set: { if let value = $0 { library.selection = value } }
        )) {
            Section {
                Label {
                    Text("録音中")
                } icon: {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                }
                .tag(LibrarySelection.live)
            }

            Section("未分類") {
                ForEach(library.sessions(in: nil)) { row in
                    sessionRow(row)
                }
                if library.sessions(in: nil).isEmpty {
                    Text("（なし）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(library.projects) { project in
                Section {
                    ForEach(library.sessions(in: project.id)) { row in
                        sessionRow(row)
                    }
                    if library.sessions(in: project.id).isEmpty {
                        Text("（このプロジェクトには録音がありません）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(project.name)
                        if library.activeProjectID == project.id {
                            Image(systemName: "record.circle")
                                .foregroundStyle(.red)
                                .help("新しい録音はこのプロジェクトに保存されます")
                        }
                        Spacer()
                    }
                }
                .contextMenu {
                    Button("ここに録音先を設定") { library.activeProjectID = project.id }
                    Button("名前を変更") {
                        renamingProject = project
                        renameDraft = project.name
                    }
                    Divider()
                    Button("削除", role: .destructive) { library.deleteProject(project) }
                }
            }
        }
        .frame(minWidth: 240)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.reload()
                } label: { Image(systemName: "arrow.clockwise") }
                .help("再読み込み")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newProjectName = ""
                    showingNewProject = true
                } label: { Image(systemName: "folder.badge.plus") }
                .help("プロジェクトを作成")
            }
        }
        .sheet(isPresented: $showingNewProject) {
            projectCreateSheet
        }
        .sheet(item: $renamingProject) { project in
            projectRenameSheet(project)
        }
    }

    private func sessionRow(_ row: SessionSummaryRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title).font(.body)
            Text(row.startedAt.formatted(date: .numeric, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(LibrarySelection.session(row.id))
        .contextMenu {
            Menu("プロジェクトに移動") {
                Button("（未分類）") { library.moveSession(row, to: nil) }
                ForEach(library.projects) { p in
                    Button(p.name) { library.moveSession(row, to: p.id) }
                }
            }
            Divider()
            Button("削除", role: .destructive) { library.deleteSession(row) }
        }
    }

    private var projectCreateSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新規プロジェクト").font(.headline)
            TextField("名前", text: $newProjectName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("キャンセル") { showingNewProject = false }
                Button("作成") {
                    let created = library.createProject(name: newProjectName)
                    library.activeProjectID = created.id
                    showingNewProject = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func projectRenameSheet(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プロジェクト名を変更").font(.headline)
            TextField("名前", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("キャンセル") { renamingProject = nil }
                Button("保存") {
                    library.renameProject(project, to: renameDraft)
                    renamingProject = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
