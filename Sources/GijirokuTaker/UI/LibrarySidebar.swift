import SwiftUI
import GijirokuCore

struct LibrarySidebar: View {
    @ObservedObject var library: LibraryModel
    @EnvironmentObject private var appModel: AppModel
    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var editingProject: Project?
    @State private var confirmingDeletionCount: Int = 0
    @State private var showingDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            recordingHeader
            Divider()
            sessionsList
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.reload()
                } label: { Image(systemName: "arrow.clockwise") }
                .help(L10n.string("sidebar.reload"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    confirmingDeletionCount = library.selectedSessionIDs.count
                    showingDeleteConfirm = true
                } label: { Image(systemName: "trash") }
                .disabled(library.selectedSessionIDs.isEmpty)
                .help(library.selectedSessionIDs.isEmpty
                      ? L10n.string("sidebar.no_selection_for_delete")
                      : L10n.format("sidebar.delete_selected_count", library.selectedSessionIDs.count))
            }
        }
        .confirmationDialog(
            L10n.format("sheet.confirm_delete_title", confirmingDeletionCount),
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("project.delete"), role: .destructive) {
                let ids = library.selectedSessionIDs
                library.deleteSessions(ids)
            }
            Button(L10n.string("sheet.cancel"), role: .cancel) {}
        } message: {
            Text(loc: "sheet.confirm_delete_message")
        }
        .sheet(isPresented: $showingNewProject) { projectCreateSheet }
        .sheet(item: $editingProject) { project in
            ProjectEditSheet(
                project: project,
                onSave: { updated in
                    library.updateProject(updated)
                    editingProject = nil
                },
                onCancel: { editingProject = nil }
            )
        }
    }

    private var addProjectButton: some View {
        Button {
            newProjectName = ""
            showingNewProject = true
        } label: {
            Label(loc: "sidebar.add_project", systemImage: "folder.badge.plus")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Recording header

    private var recordingHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if appModel.isRecording {
                    appModel.stopRecording()
                } else {
                    appModel.startRecording()
                    library.selection = [.live]
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: appModel.isRecording ? "stop.circle.fill" : "record.circle.fill")
                        .font(.title2)
                        .foregroundStyle(appModel.isRecording ? Color.secondary : Color.red)
                    Text(loc: appModel.isRecording ? "recording.stop" : "recording.start")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command])

            if appModel.summaryProgress.isBusy || appModel.isRecording {
                HStack(spacing: 6) {
                    if appModel.isRecording, !appModel.summaryProgress.isBusy {
                        Image(systemName: "waveform")
                            .foregroundStyle(.red)
                    }
                    Text(appModel.isRecording ? appModel.statusMessage : appModel.summaryProgress.displayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(8)
    }

    // MARK: - Sessions list

    private var sessionsList: some View {
        List(selection: $library.selection) {
            // 「録音中」エントリ: 録音 view にフォーカスするための tag
            Section {
                Label {
                    Text(loc: "recording.in_progress_screen")
                } icon: {
                    Image(systemName: "waveform")
                        .foregroundStyle(appModel.isRecording ? .red : .secondary)
                }
                .tag(LibrarySelection.live)
            }

            Section {
                addProjectButton
            }

            Section(L10n.string("sidebar.unfiled")) {
                if library.sessions(in: nil).isEmpty {
                    Text(loc: "sidebar.no_recordings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(library.sessions(in: nil)) { row in
                        sessionRow(row)
                    }
                }
            }

            ForEach(library.projects) { project in
                Section {
                    if library.sessions(in: project.id).isEmpty {
                        Text(loc: "sidebar.project_no_recordings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(library.sessions(in: project.id)) { row in
                            sessionRow(row)
                        }
                    }
                } header: {
                    projectHeader(project)
                }
                .contextMenu {
                    Button(L10n.string("project.set_active")) { library.activeProjectID = project.id }
                    Button(L10n.string("project.edit")) { editingProject = project }
                    Divider()
                    Button(L10n.string("project.delete"), role: .destructive) { library.deleteProject(project) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func projectHeader(_ project: Project) -> some View {
        HStack(spacing: 6) {
            Text(project.name)
                .lineLimit(1)
                .truncationMode(.tail)
            if library.activeProjectID == project.id {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .help(L10n.string("project.set_active_help"))
            }
        }
    }

    private func sessionRow(_ row: SessionSummaryRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(row.startedAt.formatted(date: .numeric, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tag(LibrarySelection.session(row.id))
        .contextMenu {
            Menu(L10n.string("project.move_to")) {
                Button(L10n.string("project.unfiled")) { library.moveSession(row, to: nil) }
                ForEach(library.projects) { p in
                    Button(p.name) { library.moveSession(row, to: p.id) }
                }
            }
            Divider()
            Button(L10n.string("project.delete"), role: .destructive) {
                library.deleteSessions([row.id])
            }
        }
    }

    private var projectCreateSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc: "sheet.new_project_title").font(.headline)
            TextField(L10n.string("sheet.project_name_label"), text: $newProjectName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L10n.string("sheet.cancel")) { showingNewProject = false }
                Button(L10n.string("sheet.create")) {
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

}
