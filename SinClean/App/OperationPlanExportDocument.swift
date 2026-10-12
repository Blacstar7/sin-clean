import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct OperationPlanTextFileDocument: FileDocument {
    /// A concrete filename-backed type keeps FileDocument and the native save
    /// panel's extension policy on the same declaration.
    static let contentType = UTType(filenameExtension: "txt", conformingTo: .plainText) ?? .plainText

    static var readableContentTypes: [UTType] { [contentType] }
    static var writableContentTypes: [UTType] { [contentType] }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        self.text = try Self.decodeUTF8(from: configuration.file)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        exportFileWrapper()
    }

    func exportFileWrapper() -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }

    static func decodeUTF8(from wrapper: FileWrapper) throws -> String {
        guard wrapper.isRegularFile,
              let data = wrapper.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }

    /// The native panel owns the `.txt` suffix through `contentType`; only the
    /// safe leaf stem is supplied as its editable default name.
    static func defaultFilename(from suggestedFilename: String) -> String {
        let leaf = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        let stem = (leaf as NSString).deletingPathExtension
        return stem.isEmpty ? "SinClean-operation-plan" : stem
    }
}

struct OperationPlanExportFeedback: Equatable {
    enum Kind: Equatable {
        case success
        case cancelled
        case failure
    }

    let message: String
    let kind: Kind
}

enum OperationPlanSaveError: Error, Equatable {
    case invalidFilenameExtension
}

extension OperationPlanSaveError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidFilenameExtension:
            return String(localized: "导出目标不是 TXT 文件")
        }
    }
}

@MainActor
enum OperationPlanExportUI {
    static func presentSavePanel(
        document: OperationPlanTextFileDocument,
        suggestedFilename: String,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let panel = NSSavePanel()
        panel.title = String(localized: "导出 Sin Clean 操作计划")
        panel.message = String(localized: "只读审阅文件，不构成执行授权。")
        panel.prompt = String(localized: "导出")
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.allowedContentTypes = OperationPlanTextFileDocument.writableContentTypes
        panel.nameFieldStringValue = OperationPlanTextFileDocument.defaultFilename(from: suggestedFilename) + ".txt"

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else {
                completion(.failure(CocoaError(.userCancelled)))
                return
            }
            guard destination.pathExtension.lowercased() == "txt" else {
                completion(.failure(OperationPlanSaveError.invalidFilenameExtension))
                return
            }
            do {
                try document.exportFileWrapper().write(
                    to: destination,
                    options: .atomic,
                    originalContentsURL: nil
                )
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return error is CancellationError
            || (cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError)
    }
}
