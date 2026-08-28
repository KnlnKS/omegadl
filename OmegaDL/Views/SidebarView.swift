import MegaKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedSourceID) {
            Section("Account") {
                if let account = model.account {
                    row(account)
                        .contextMenu {
                            Button("Sign Out", role: .destructive) { model.signOut() }
                        }
                } else {
                    Button {
                        model.isSigningIn = true
                    } label: {
                        Label("Sign In…", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.plain)
                }
            }

            if !model.links.isEmpty {
                Section("Links") {
                    ForEach(model.links) { source in
                        row(source)
                            .contextMenu {
                                Button(downloadTitle(for: source)) { model.downloadEverything(from: source) }
                                    .disabled(source.tree == nil)
                                Divider()
                                Button("Copy Link") { copy(source) }
                                Button("Remove", role: .destructive) { model.remove(source) }
                            }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.isAddingLink = true
            } label: {
                Label("Add Link", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.accessoryBar)
            .keyboardShortcut("l", modifiers: .command)
            .padding(8)
        }
        .onChange(of: model.selectedSourceID) {
            model.currentFolder = nil
        }
    }

    private func row(_ source: Source) -> some View {
        Label(source.name, systemImage: source.symbol)
            .lineLimit(1)
            .truncationMode(.middle)
            .tag(source.id)
    }

    private func downloadTitle(for source: Source) -> String {
        source.link?.kind == .file ? "Download" : "Download Folder"
    }

    private func copy(_ source: Source) {
        guard let link = source.link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
    }
}
