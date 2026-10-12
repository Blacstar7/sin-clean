import AppKit
import SwiftUI

enum SpaceAnalysisDirectoryChoice: Sendable {
    case cancelled
    case selected([URL])
}

@MainActor
protocol SpaceAnalysisDirectoryChoosing {
    func chooseDirectories() -> SpaceAnalysisDirectoryChoice
}

@MainActor
struct NativeSpaceAnalysisDirectoryChooser: SpaceAnalysisDirectoryChoosing {
    func chooseDirectories() -> SpaceAnalysisDirectoryChoice {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择空间分析范围")
        panel.message = String(localized: "选择一个或多个目录；本轮只保存范围，不会开始扫描。")
        panel.prompt = String(localized: "加入范围")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        return panel.runModal() == .OK ? .selected(panel.urls) : .cancelled
    }
}

@MainActor
final class SpaceAnalysisScopeViewModel: ObservableObject {
    @Published private(set) var selectedScopes: [SpaceAnalysisScope]
    @Published private(set) var lastRejection: SpaceAnalysisScopeRejection?
    @Published private(set) var feedbackRevision: UInt64 = 0

    let commonScopeCandidates: [SpaceAnalysisScopeCandidate]

    private let validator: any SpaceAnalysisScopeValidating
    private let directoryChooser: any SpaceAnalysisDirectoryChoosing

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        validator: any SpaceAnalysisScopeValidating = SpaceAnalysisScopeValidator(),
        directoryChooser: (any SpaceAnalysisDirectoryChoosing)? = nil,
        initialScopes: [SpaceAnalysisScope] = [],
        initialRejection: SpaceAnalysisScopeRejection? = nil
    ) {
        commonScopeCandidates = SpaceAnalysisCommonScope.allCases.map {
            $0.candidate(homeDirectory: homeDirectory)
        }
        self.validator = validator
        // Construct the AppKit-backed chooser inside the main-actor initializer.
        // Newer Swift toolchains evaluate default argument expressions in a
        // nonisolated context, which cannot call this @MainActor initializer.
        self.directoryChooser = directoryChooser ?? NativeSpaceAnalysisDirectoryChooser()
        selectedScopes = initialScopes
        lastRejection = initialRejection
    }

    func addCommonScope(_ candidate: SpaceAnalysisScopeCandidate) {
        add(candidate)
    }

    func chooseOtherDirectories() {
        switch directoryChooser.chooseDirectories() {
        case .cancelled:
            return
        case .selected(let urls):
            var lastBatchRejection: SpaceAnalysisScopeRejection?
            for url in urls {
                let candidate = SpaceAnalysisScopeCandidate(
                    displayName: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                    path: url.path,
                    source: .chosenDirectory
                )
                switch validator.validate(candidate, existingScopes: selectedScopes) {
                case .accepted(let scope):
                    selectedScopes.append(scope)
                case .rejected(let rejection):
                    lastBatchRejection = rejection
                }
            }
            if let lastBatchRejection {
                publish(lastBatchRejection)
            } else {
                lastRejection = nil
            }
        }
    }

    func add(_ candidate: SpaceAnalysisScopeCandidate) {
        switch validator.validate(candidate, existingScopes: selectedScopes) {
        case .accepted(let scope):
            selectedScopes.append(scope)
            lastRejection = nil
        case .rejected(let rejection):
            publish(rejection)
        }
    }

    func removeScope(id: SpaceAnalysisScope.ID) {
        selectedScopes.removeAll { $0.id == id }
        lastRejection = nil
    }

    func clearScopes() {
        selectedScopes.removeAll(keepingCapacity: false)
        lastRejection = nil
    }

    private func publish(_ rejection: SpaceAnalysisScopeRejection) {
        lastRejection = rejection
        feedbackRevision &+= 1
        AccessibilityNotification.Announcement(rejection.message).post()
    }
}
