import AppKit
import Foundation

enum BrowserManager {
    private static let supportedBrowsers: [(bundleID: String, appName: String, isSafari: Bool)] = [
        ("com.google.Chrome", "Google Chrome", false),
        ("com.brave.Browser", "Brave Browser", false),
        ("com.apple.Safari", "Safari", true)
    ]

    static func fetchOpenTabs() -> [BrowserTabItem] {
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )

        var tabs: [BrowserTabItem] = []
        for browser in supportedBrowsers where runningBundleIDs.contains(browser.bundleID) {
            if browser.isSafari {
                tabs.append(contentsOf: fetchSafariTabs())
            } else {
                tabs.append(contentsOf: fetchChromiumTabs(appName: browser.appName))
            }
        }
        return tabs
    }

    static func closeTab(_ tab: BrowserTabItem) {
        let script: String
        if tab.browserName == "Safari" {
            script = """
            tell application "Safari"
                if (count of windows) >= \(tab.windowIndex) then
                    tell window \(tab.windowIndex)
                        if (count of tabs) >= \(tab.tabIndex) then
                            close tab \(tab.tabIndex)
                        end if
                    end tell
                end if
            end tell
            """
        } else {
            script = """
            tell application "\(tab.browserName)"
                if (count of windows) >= \(tab.windowIndex) then
                    tell window \(tab.windowIndex)
                        if (count of tabs) >= \(tab.tabIndex) then
                            close tab \(tab.tabIndex)
                        end if
                    end tell
                end if
            end tell
            """
        }
        runAppleScript(script)
    }

    static func closeAllInactiveTabs(in browserName: String? = nil) {
        let tabs = fetchOpenTabs()
            .filter { !$0.isActive && (browserName == nil || $0.browserName == browserName) }
            // Close highest tab indices first so earlier indices don't shift.
            .sorted {
                if $0.windowIndex != $1.windowIndex { return $0.windowIndex > $1.windowIndex }
                return $0.tabIndex > $1.tabIndex
            }
        for tab in tabs {
            closeTab(tab)
        }
    }

    private static func fetchChromiumTabs(appName: String) -> [BrowserTabItem] {
        let script = """
        set outText to ""
        tell application "\(appName)"
            set wIdx to 0
            repeat with w in windows
                set wIdx to wIdx + 1
                set activeIdx to active tab index of w
                set tIdx to 0
                repeat with t in tabs of w
                    set tIdx to tIdx + 1
                    set isAct to "0"
                    if tIdx is equal to activeIdx then set isAct to "1"
                    set tTitle to title of t
                    set tURL to URL of t
                    set outText to outText & wIdx & "\t" & tIdx & "\t" & isAct & "\t" & tTitle & "\t" & tURL & linefeed
                end repeat
            end repeat
        end tell
        return outText
        """
        let output = runAppleScript(script)
        return parseTabLines(output, browserName: appName)
    }

    private static func fetchSafariTabs() -> [BrowserTabItem] {
        let script = """
        set outText to ""
        tell application "Safari"
            set wIdx to 0
            repeat with w in windows
                set wIdx to wIdx + 1
                set curTab to current tab of w
                set tIdx to 0
                repeat with t in tabs of w
                    set tIdx to tIdx + 1
                    set isAct to "0"
                    if t is equal to curTab then set isAct to "1"
                    set tTitle to name of t
                    set tURL to URL of t
                    set outText to outText & wIdx & "\t" & tIdx & "\t" & isAct & "\t" & tTitle & "\t" & tURL & linefeed
                end repeat
            end repeat
        end tell
        return outText
        """
        let output = runAppleScript(script)
        return parseTabLines(output, browserName: "Safari")
    }

    private static func parseTabLines(_ output: String, browserName: String) -> [BrowserTabItem] {
        var result: [BrowserTabItem] = []
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard cols.count >= 5,
                  let wIdx = Int(cols[0]),
                  let tIdx = Int(cols[1]) else { continue }
            let isActive = cols[2] == "1"
            let title = String(cols[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = String(cols[4]).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(
                BrowserTabItem(
                    id: "\(browserName)-\(wIdx)-\(tIdx)-\(url)",
                    browserName: browserName,
                    windowIndex: wIdx,
                    tabIndex: tIdx,
                    title: title.isEmpty ? url : title,
                    url: url,
                    isActive: isActive
                )
            )
        }
        return result
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
