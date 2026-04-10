import Foundation

/// Installs macOS Finder Quick Actions (Services) that call TalkIsCheap
enum QuickActionInstaller {
    private static let servicesDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Services")

    /// Install Quick Actions if not already present
    static func installIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: servicesDir, withIntermediateDirectories: true)

        installWorkflow(
            name: "TalkIsCheap — Transcribe",
            script: transcribeScript
        )
        installWorkflow(
            name: "TalkIsCheap — Transcribe & Summarize",
            script: transcribeSummarizeScript
        )

        Log.write("Quick Actions installed to ~/Library/Services/")
    }

    private static func installWorkflow(name: String, script: String) {
        let workflowDir = servicesDir.appendingPathComponent("\(name).workflow/Contents")
        let fm = FileManager.default

        // Skip if already exists
        if fm.fileExists(atPath: workflowDir.path) { return }

        try? fm.createDirectory(at: workflowDir, withIntermediateDirectories: true)

        // Info.plist
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>NSServices</key>
            <array>
                <dict>
                    <key>NSMenuItem</key>
                    <dict>
                        <key>default</key>
                        <string>\(name)</string>
                    </dict>
                    <key>NSMessage</key>
                    <string>runWorkflowAsService</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        try? plist.write(to: workflowDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        // document.wflow — Automator workflow XML that runs a shell script
        let wflow = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AMApplicationBuild</key>
            <string>523</string>
            <key>AMApplicationVersion</key>
            <string>2.10</string>
            <key>AMDocumentVersion</key>
            <string>2</string>
            <key>actions</key>
            <array>
                <dict>
                    <key>action</key>
                    <dict>
                        <key>AMAccepts</key>
                        <dict>
                            <key>Container</key>
                            <string>List</string>
                            <key>Optional</key>
                            <false/>
                            <key>Types</key>
                            <array>
                                <string>com.apple.cocoa.path</string>
                            </array>
                        </dict>
                        <key>AMActionVersion</key>
                        <string>1.0.2</string>
                        <key>AMApplication</key>
                        <array>
                            <string>Automator</string>
                        </array>
                        <key>AMBundleIdentifier</key>
                        <string>com.apple.RunShellScript</string>
                        <key>AMCategory</key>
                        <string>AMCategoryUtilities</string>
                        <key>AMIconName</key>
                        <string>Terminal</string>
                        <key>AMName</key>
                        <string>Run Shell Script</string>
                        <key>AMProvides</key>
                        <dict>
                            <key>Container</key>
                            <string>List</string>
                            <key>Types</key>
                            <array>
                                <string>com.apple.cocoa.string</string>
                            </array>
                        </dict>
                        <key>AMRequiredResources</key>
                        <array/>
                        <key>ActionBundlePath</key>
                        <string>/System/Library/Automator/Run Shell Script.action</string>
                        <key>ActionName</key>
                        <string>Run Shell Script</string>
                        <key>ActionParameters</key>
                        <dict>
                            <key>COMMAND_STRING</key>
                            <string>\(script)</string>
                            <key>CheckedForUserDefaultShell</key>
                            <true/>
                            <key>inputMethod</key>
                            <integer>1</integer>
                            <key>shell</key>
                            <string>/bin/bash</string>
                            <key>source</key>
                            <string></string>
                        </dict>
                        <key>BundleIdentifier</key>
                        <string>com.apple.RunShellScript</string>
                        <key>CFBundleVersion</key>
                        <string>1.0.2</string>
                        <key>CanShowSelectedItemsWhenRun</key>
                        <false/>
                        <key>CanShowWhenRun</key>
                        <true/>
                        <key>Category</key>
                        <array>
                            <string>AMCategoryUtilities</string>
                        </array>
                        <key>Class Name</key>
                        <string>RunShellScriptAction</string>
                        <key>InputUUID</key>
                        <string>A1A1A1A1-A1A1-A1A1-A1A1-A1A1A1A1A1A1</string>
                        <key>Keywords</key>
                        <array>
                            <string>Shell</string>
                            <string>Script</string>
                            <string>Command</string>
                            <string>Run</string>
                        </array>
                        <key>OutputUUID</key>
                        <string>B2B2B2B2-B2B2-B2B2-B2B2-B2B2B2B2B2B2</string>
                    </dict>
                </dict>
            </array>
            <key>connectors</key>
            <dict/>
            <key>workflowMetaData</key>
            <dict>
                <key>workflowTypeIdentifier</key>
                <string>com.apple.Automator.servicesMenu</string>
                <key>serviceInputTypeIdentifier</key>
                <string>com.apple.Automator.fileSystemObject</string>
                <key>serviceApplicationBundleID</key>
                <string>com.apple.finder</string>
            </dict>
        </dict>
        </plist>
        """
        try? wflow.write(to: workflowDir.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)
    }

    // Shell scripts that open TalkIsCheap with the file path
    private static let transcribeScript = """
    for f in "$@"; do
        open "talkischeap://transcribe?path=$f"
    done
    """

    private static let transcribeSummarizeScript = """
    for f in "$@"; do
        open "talkischeap://transcribe-summarize?path=$f"
    done
    """
}
