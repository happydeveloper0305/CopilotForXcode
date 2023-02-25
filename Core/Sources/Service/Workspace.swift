import CopilotModel
import CopilotService
import Foundation
import SuggestionInjector
import XPCShared

@ServiceActor
final class Filespace {
    struct Snapshot: Equatable {
        var linesHash: Int
        var cursorPosition: CursorPosition
    }

    let fileURL: URL
    var suggestions: [CopilotCompletion] = [] {
        didSet { lastSuggestionUpdateTime = Environment.now() }
    }

    var suggestionIndex: Int = 0
    var suggestionSourceSnapshot: Snapshot = .init(linesHash: -1, cursorPosition: .outOfScope)
    var presentingSuggestion: CopilotCompletion? {
        guard suggestions.endIndex > suggestionIndex, suggestionIndex >= 0 else { return nil }
        return suggestions[suggestionIndex]
    }

    private(set) var lastSuggestionUpdateTime: Date = Environment.now()
    var isExpired: Bool {
        Environment.now().timeIntervalSince(lastSuggestionUpdateTime) > 60 * 60 * 8
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func reset() {
        suggestions = []
        suggestionIndex = 0
    }
}

@ServiceActor
final class Workspace {
    let projectRootURL: URL
    var lastTriggerDate = Environment.now()
    var isExpired: Bool {
        Environment.now().timeIntervalSince(lastTriggerDate) > 60 * 60 * 8
    }

    private(set) var filespaces = [URL: Filespace]()
    var isRealtimeSuggestionEnabled: Bool {
        UserDefaults.shared.bool(forKey: SettingsKey.realtimeSuggestionToggle)
    }

    var realtimeSuggestionRequests = Set<Task<Void, Error>>()

    private lazy var service: CopilotSuggestionServiceType = Environment
        .createSuggestionService(projectRootURL)

    init(projectRootURL: URL) {
        self.projectRootURL = projectRootURL
    }

    func canAutoTriggerGetSuggestions(
        forFileAt fileURL: URL,
        lines: [String],
        cursorPosition: CursorPosition
    ) -> Bool {
        guard isRealtimeSuggestionEnabled else { return false }
        guard let filespace = filespaces[fileURL] else { return true }
        if lines.hashValue != filespace.suggestionSourceSnapshot.linesHash { return true }
        if cursorPosition != filespace.suggestionSourceSnapshot.cursorPosition { return true }
        return false
    }

    static func fetchOrCreateWorkspaceIfNeeded(fileURL: URL) async throws -> (workspace: Workspace, filespace: Filespace) {
        let projectURL = try await Environment.fetchCurrentProjectRootURL(fileURL)
        let workspaceURL = projectURL ?? fileURL
        let workspace = workspaces[workspaceURL] ?? Workspace(projectRootURL: workspaceURL)
        let filespace = workspace.filespaces[fileURL] ?? .init(fileURL: fileURL)
        if workspace.filespaces[fileURL] == nil {
            workspace.filespaces[fileURL] = filespace
        }
        workspaces[workspaceURL] = workspace
        return (workspace, filespace)
    }
}

extension Workspace {
    @discardableResult
    func generateSuggestions(
        forFileAt fileURL: URL,
        content: String,
        lines: [String],
        cursorPosition: CursorPosition,
        tabSize: Int,
        indentSize: Int,
        usesTabsForIndentation: Bool,
        shouldcancelInFlightRealtimeSuggestionRequests: Bool = true
    ) async throws -> [CopilotCompletion] {
        if shouldcancelInFlightRealtimeSuggestionRequests {
            cancelInFlightRealtimeSuggestionRequests()
        }
        lastTriggerDate = Environment.now()

        let filespace = filespaces[fileURL] ?? .init(fileURL: fileURL)
        if filespaces[fileURL] == nil {
            filespaces[fileURL] = filespace
        }

        let snapshot = Filespace.Snapshot(
            linesHash: lines.hashValue,
            cursorPosition: cursorPosition
        )

        filespace.suggestionSourceSnapshot = snapshot

        let completions = try await service.getCompletions(
            fileURL: fileURL,
            content: lines.joined(separator: ""),
            cursorPosition: cursorPosition,
            tabSize: tabSize,
            indentSize: indentSize,
            usesTabsForIndentation: usesTabsForIndentation,
            ignoreSpaceOnlySuggestions: true
        )

        filespace.suggestions = completions
        
        return completions
    }

    func selectNextSuggestion(
        forFileAt fileURL: URL,
        content _: String,
        lines: [String]
    ) {
        cancelInFlightRealtimeSuggestionRequests()
        lastTriggerDate = Environment.now()
        guard let filespace = filespaces[fileURL],
              filespace.suggestions.count > 1
        else { return }
        filespace.suggestionIndex += 1
        if filespace.suggestionIndex >= filespace.suggestions.endIndex {
            filespace.suggestionIndex = 0
        }
    }

    func selectPreviousSuggestion(
        forFileAt fileURL: URL,
        content _: String,
        lines: [String]
    ) {
        cancelInFlightRealtimeSuggestionRequests()
        lastTriggerDate = Environment.now()
        guard let filespace = filespaces[fileURL],
              filespace.suggestions.count > 1
        else { return }
        filespace.suggestionIndex -= 1
        if filespace.suggestionIndex < 0 {
            filespace.suggestionIndex = filespace.suggestions.endIndex - 1
        }
    }

    func rejectSuggestion(forFileAt fileURL: URL) {
        cancelInFlightRealtimeSuggestionRequests()
        lastTriggerDate = Environment.now()
        Task {
            await service.notifyRejected(filespaces[fileURL]?.suggestions ?? [])
        }
        filespaces[fileURL]?.reset()
    }

    func acceptSuggestion(forFileAt fileURL: URL) -> CopilotCompletion? {
        cancelInFlightRealtimeSuggestionRequests()
        lastTriggerDate = Environment.now()
        guard let filespace = filespaces[fileURL],
              !filespace.suggestions.isEmpty,
              filespace.suggestionIndex >= 0,
              filespace.suggestionIndex < filespace.suggestions.endIndex
        else { return nil }

        var allSuggestions = filespace.suggestions
        let suggestion = allSuggestions.remove(at: filespace.suggestionIndex)

        Task {
            await service.notifyAccepted(suggestion)
            await service.notifyRejected(allSuggestions)
        }

        filespaces[fileURL]?.reset()

        return suggestion
    }
}

@available(*, deprecated, message: "These should be replaced.")
extension Workspace {
    func getRealtimeSuggestedCode(
        forFileAt fileURL: URL,
        content: String,
        lines: [String],
        cursorPosition: CursorPosition,
        tabSize: Int,
        indentSize: Int,
        usesTabsForIndentation: Bool
    ) -> UpdatedContent? {
        cancelInFlightRealtimeSuggestionRequests()
        guard isRealtimeSuggestionEnabled else { return nil }

        let filespace = filespaces[fileURL] ?? .init(fileURL: fileURL)
        if filespaces[fileURL] == nil {
            filespaces[fileURL] = filespace
        }

        let injector = SuggestionInjector()
        var extraInfo = SuggestionInjector.ExtraInfo()
        var lines = lines
        var cursorPosition = cursorPosition

        injector.rejectCurrentSuggestions(
            from: &lines,
            cursorPosition: &cursorPosition,
            extraInfo: &extraInfo
        )

        let snapshot = Filespace.Snapshot(
            linesHash: lines.hashValue,
            cursorPosition: cursorPosition
        )

        if snapshot != filespace.suggestionSourceSnapshot {
            let task = Task {
                let result = try await getSuggestedCode(
                    forFileAt: fileURL,
                    content: content,
                    lines: lines,
                    cursorPosition: cursorPosition,
                    tabSize: tabSize,
                    indentSize: indentSize,
                    usesTabsForIndentation: usesTabsForIndentation,
                    shouldcancelInFlightRealtimeSuggestionRequests: false
                )
                try Task.checkCancellation()
                if result != nil {
                    try? await Environment.triggerAction("Real-time Suggestions")
                }
            }

            realtimeSuggestionRequests.insert(task)

            return UpdatedContent(
                content: String(lines.joined(separator: "")),
                newCursor: cursorPosition,
                modifications: extraInfo.modifications
            )
        }

        if filespace.suggestions.isEmpty || snapshot != filespace.suggestionSourceSnapshot {
            return .init(
                content: content,
                newCursor: cursorPosition,
                modifications: extraInfo.modifications
            )
        }

        injector.proposeSuggestion(
            intoContentWithoutSuggestion: &lines,
            completion: filespace.suggestions[filespace.suggestionIndex],
            index: filespace.suggestionIndex,
            count: filespace.suggestions.count,
            extraInfo: &extraInfo
        )

        return .init(
            content: String(lines.joined(separator: "")),
            newCursor: cursorPosition,
            modifications: extraInfo.modifications
        )
    }

    func getSuggestedCode(
        forFileAt fileURL: URL,
        content: String,
        lines: [String],
        cursorPosition: CursorPosition,
        tabSize: Int,
        indentSize: Int,
        usesTabsForIndentation: Bool,
        shouldcancelInFlightRealtimeSuggestionRequests: Bool = true
    ) async throws -> UpdatedContent? {
        if shouldcancelInFlightRealtimeSuggestionRequests {
            cancelInFlightRealtimeSuggestionRequests()
        }
        lastTriggerDate = Environment.now()
        let injector = SuggestionInjector()
        var lines = lines
        var cursorPosition = cursorPosition

        let filespace = filespaces[fileURL] ?? .init(fileURL: fileURL)
        if filespaces[fileURL] == nil {
            filespaces[fileURL] = filespace
        }
        var extraInfo = SuggestionInjector.ExtraInfo()
        let snapshot = Filespace.Snapshot(
            linesHash: lines.hashValue,
            cursorPosition: cursorPosition
        )

        injector.rejectCurrentSuggestions(
            from: &lines,
            cursorPosition: &cursorPosition,
            extraInfo: &extraInfo
        )

        filespace.suggestionSourceSnapshot = snapshot

        let completions = try await service.getCompletions(
            fileURL: fileURL,
            content: lines.joined(separator: ""),
            cursorPosition: cursorPosition,
            tabSize: tabSize,
            indentSize: indentSize,
            usesTabsForIndentation: usesTabsForIndentation,
            ignoreSpaceOnlySuggestions: true
        )

        guard filespace.suggestionSourceSnapshot == snapshot else { return nil }

        if completions.isEmpty {
            return .init(
                content: content,
                newCursor: cursorPosition,
                modifications: extraInfo.modifications
            )
        }

        filespace.suggestions = completions
        injector.proposeSuggestion(
            intoContentWithoutSuggestion: &lines,
            completion: completions[0],
            index: 0,
            count: completions.count,
            extraInfo: &extraInfo
        )

        return .init(
            content: String(lines.joined(separator: "")),
            newCursor: cursorPosition,
            modifications: extraInfo.modifications
        )
    }

    func getNextSuggestedCode(
        forFileAt fileURL: URL,
        content _: String,
        lines: [String],
        cursorPosition: CursorPosition
    ) -> UpdatedContent? {
        cancelInFlightRealtimeSuggestionRequests()
        lastTriggerDate = Environment.now()
        guard let filespace = filespaces[fileURL],
              filespace.suggestions.count > 1
        else { return nil }
        var cursorPosition = cursorPosition
        filespace.suggestionIndex += 1
        if filespace.suggestionIndex >= filespace.suggestions.endIndex {
            filespace.suggestionIndex = 0
        }

        let suggestion = filespace.suggestions[filespace.suggestionIndex]
        let injector = SuggestionInjector()
        var extraInfo = SuggestionInjector.ExtraInfo()
        var lines = lines
        injector.rejectCurrentSuggestions(
            from: &lines,
            cursorPosition: &cursorPosition,
            extraInfo: &extraInfo
        )
        injector.proposeSuggestion(
            intoContentWithoutSuggestion: &lines,
            completion: suggestion,
            index: filespace.suggestionIndex,
            count: filespace.suggestions.count,
            extraInfo: &extraInfo
        )

        return .init(
            content: String(lines.joined(separator: "")),
            newCursor: cursorPosition,
            modifications: extraInfo.modifications
        )
    }

    func getPreviousSuggestedCode(
        forFileAt fileURL: URL,
        content _: String,
        lines: [String],
        cursorPosition: CursorPosition
    ) -> UpdatedContent? {
        cancelInFlightRealtimeSuggestionRequests()
        lastTriggerDate = Environment.now()
        guard let filespace = filespaces[fileURL],
              filespace.suggestions.count > 1
        else { return nil }
        var cursorPosition = cursorPosition
        filespace.suggestionIndex -= 1
        if filespace.suggestionIndex < 0 {
            filespace.suggestionIndex = filespace.suggestions.endIndex - 1
        }
        var extraInfo = SuggestionInjector.ExtraInfo()
        let suggestion = filespace.suggestions[filespace.suggestionIndex]
        let injector = SuggestionInjector()
        var lines = lines
        injector.rejectCurrentSuggestions(
            from: &lines,
            cursorPosition: &cursorPosition,
            extraInfo: &extraInfo
        )
        injector.proposeSuggestion(
            intoContentWithoutSuggestion: &lines,
            completion: suggestion,
            index: filespace.suggestionIndex,
            count: filespace.suggestions.count,
            extraInfo: &extraInfo
        )

        return .init(
            content: String(lines.joined(separator: "")),
            newCursor: cursorPosition,
            modifications: extraInfo.modifications
        )
    }

    func getSuggestionAcceptedCode(
        forFileAt fileURL: URL,
        content _: String,
        lines: [String],
        cursorPosition: CursorPosition
    ) -> UpdatedContent? {
        cancelInFlightRealtimeSuggestionRequests()
        lastTriggerDate = Environment.now()
        guard let filespace = filespaces[fileURL],
              !filespace.suggestions.isEmpty,
              filespace.suggestionIndex >= 0,
              filespace.suggestionIndex < filespace.suggestions.endIndex
        else { return nil }

        var cursorPosition = cursorPosition
        var extraInfo = SuggestionInjector.ExtraInfo()
        var allSuggestions = filespace.suggestions
        let suggestion = allSuggestions.remove(at: filespace.suggestionIndex)
        let injector = SuggestionInjector()
        var lines = lines
        injector.rejectCurrentSuggestions(
            from: &lines,
            cursorPosition: &cursorPosition,
            extraInfo: &extraInfo
        )
        injector.acceptSuggestion(
            intoContentWithoutSuggestion: &lines,
            cursorPosition: &cursorPosition,
            completion: suggestion,
            extraInfo: &extraInfo
        )

        Task {
            await service.notifyAccepted(suggestion)
            await service.notifyRejected(allSuggestions)
        }

        filespaces[fileURL]?.reset()
        return .init(
            content: String(lines.joined(separator: "")),
            newCursor: cursorPosition,
            modifications: extraInfo.modifications
        )
    }

    func getSuggestionRejectedCode(
        forFileAt fileURL: URL,
        content _: String,
        lines: [String],
        cursorPosition: CursorPosition
    ) -> UpdatedContent {
        cancelInFlightRealtimeSuggestionRequests()
        lastTriggerDate = Environment.now()
        let injector = SuggestionInjector()
        var lines = lines
        var cursorPosition = cursorPosition
        var extraInfo = SuggestionInjector.ExtraInfo()
        injector.rejectCurrentSuggestions(
            from: &lines,
            cursorPosition: &cursorPosition,
            extraInfo: &extraInfo
        )

        Task {
            await service.notifyRejected(filespaces[fileURL]?.suggestions ?? [])
        }

        filespaces[fileURL]?.reset()
        return .init(
            content: String(lines.joined(separator: "")),
            newCursor: cursorPosition,
            modifications: extraInfo.modifications
        )
    }
}

extension Workspace {
    func cleanUp() {
        for (fileURL, filespace) in filespaces {
            if filespace.isExpired {
                filespaces[fileURL] = nil
            }
        }
    }

    func cancelInFlightRealtimeSuggestionRequests() {
        for task in realtimeSuggestionRequests {
            task.cancel()
        }
        realtimeSuggestionRequests = []
    }
}
