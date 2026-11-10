// Only for the disposable GitHub-hosted macOS test session. Use the normal
// consent UI; never edit TCC databases or change the production application's
// permissions. Match both the CI sender and our one test receiver before acting.
import AppKit
import ApplicationServices

guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
      ProcessInfo.processInfo.environment["DISK_WATCH_AUTOMATION_TESTS"] == "1" else {
    fputs("Automation fixture consent is restricted to the disposable CI session.\n", stderr)
    exit(1)
}
guard AXIsProcessTrusted() else {
    fputs("The CI runner lacks Accessibility authorization for the fixture consent UI.\n", stderr)
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func descendants(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 12 else { return [root] }
    let children = attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return [root] + children.prefix(100).flatMap { descendants($0, depth: depth + 1) }
}
let deadline = Date().addingTimeInterval(180)
while Date() < deadline {
    for application in NSWorkspace.shared.runningApplications {
        let root = AXUIElementCreateApplication(application.processIdentifier)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for window in windows {
            let elements = descendants(window)
            let description = elements.flatMap { element in
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap {
                    attribute(element, $0) as? String
                }
            }.joined(separator: " ")
            guard description.contains("hosted-compute-agent"), description.contains("TextEdit"),
                  description.contains("control"), description.contains("Allow") else { continue }
            for element in elements where attribute(element, kAXRoleAttribute) as? String == kAXButtonRole {
                guard attribute(element, kAXTitleAttribute) as? String == "Allow"
                        || attribute(element, kAXDescriptionAttribute) as? String == "Allow" else { continue }
                guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { continue }
                print("Approved the normal CI-runner → TextEdit consent dialog for the disposable fixture.")
                exit(0)
            }
        }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
}
fputs("No matching CI TextEdit consent dialog appeared.\n", stderr)
exit(1)
