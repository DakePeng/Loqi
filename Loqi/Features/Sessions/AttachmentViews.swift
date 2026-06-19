import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Small rounded thumbnail for an attached photo, loaded off the main
/// thread. Used inline in the live transcript and the session detail.
struct AttachmentThumbnail: View {
    let attachment: SessionRecord.Attachment
    var height: CGFloat = 88

    @State private var image: UIImage?

    var body: some View {
        thumbnailContent
        .frame(width: height * 4 / 3, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            if attachment.ocrText != nil || attachment.vlmDescription != nil {
                Image(systemName: "text.viewfinder")
                    .font(.caption2)
                    .padding(4)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(4)
            }
        }
        .task(id: attachment.fileName) {
            let url = SessionArchive.attachmentURL(fileName: attachment.fileName)
            let loaded = await Task.detached(priority: .utility) {
                let image = UIImage(contentsOfFile: url.path(percentEncoded: false))
                return image?.preparingForDisplay() ?? image
            }.value
            image = loaded
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.loqiTertiarySystemFill)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

/// Full-screen photo viewer: zoomable image, extracted text, optional
/// caption editing and delete (detail view only; nil handlers hide them).
struct AttachmentViewer: View {
    let attachment: SessionRecord.Attachment
    var onSaveCaption: (@MainActor (String) -> Void)? = nil
    var onDelete: (@MainActor () -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var captionDraft = ""
    @State private var showingText = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .containerRelativeFrame([.horizontal, .vertical])
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let ocr = attachment.ocrText, !ocr.isEmpty {
                        Button("Text in image", systemImage: "text.viewfinder") {
                            showingText = true
                        }
                    }
                    if let image {
                        ShareLink(
                            item: Image(uiImage: image),
                            preview: SharePreview("Photo", image: Image(uiImage: image)))
                    }
                    if onDelete != nil {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            confirmDelete = true
                        }
                    }
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .automatic) {
                    if let ocr = attachment.ocrText, !ocr.isEmpty {
                        Button("Text in image", systemImage: "text.viewfinder") {
                            showingText = true
                        }
                    }
                    if let image {
                        ShareLink(
                            item: Image(uiImage: image),
                            preview: SharePreview("Photo", image: Image(uiImage: image)))
                    }
                    if onDelete != nil {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            confirmDelete = true
                        }
                    }
                }
                #endif
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if let description = attachment.vlmDescription, !description.isEmpty {
                        ScrollView {
                            extractedSection("Description", text: description)
                                .padding()
                        }
                        .frame(maxHeight: 160)
                        .background(.thinMaterial)
                    }
                    if onSaveCaption != nil {
                        TextField("Add a caption", text: $captionDraft)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .onSubmit { onSaveCaption?(captionDraft) }
                            .padding()
                            .background(.bar)
                    }
                }
            }
            .sheet(isPresented: $showingText) {
                NavigationStack {
                    ScrollView {
                        Text(attachment.ocrText ?? "")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("Text in image")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                }
                .presentationDetents([.medium, .large])
            }
            .confirmationDialog(
                "Delete this photo?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .task {
            captionDraft = attachment.caption ?? ""
            let url = SessionArchive.attachmentURL(fileName: attachment.fileName)
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path(percentEncoded: false))
            }.value
        }
    }

    @ViewBuilder
    private func extractedSection(_ title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
