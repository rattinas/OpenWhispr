#!/usr/bin/env python3
"""
Patch SettingsView.swift to add a Sparkle-powered Updates tab.
Safe to run multiple times — idempotent (won't double-insert).
"""
import sys
from pathlib import Path

PATH = Path("/Users/bene/Documents/Projekte/OpenWhispr/TalkIsCheap/Sources/TalkIsCheap/Views/SettingsView.swift")

if not PATH.exists():
    print(f"ERROR: {PATH} not found")
    sys.exit(1)

content = PATH.read_text()

# ─── Insert 1: Register the tab ─────────────────────────────────────────
marker1 = 'licenseTab.tabItem { Label("License", systemImage: "lock.shield") }.tag("license")'
new_tab_line = 'updatesTab.tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag("updates")'

if new_tab_line in content:
    print("ℹ️  Tab registration already present — skipping")
else:
    if marker1 not in content:
        print(f"ERROR: Could not find marker for insert 1:\n  {marker1}")
        sys.exit(1)
    replacement = marker1 + "\n            " + new_tab_line
    content = content.replace(marker1, replacement, 1)
    print("✅ Inserted tab registration")

# ─── Insert 2: Add updatesTab computed property ─────────────────────────
marker2 = "    // MARK: - Sheets"
updates_block = """    // MARK: - Updates

    private var updatesTab: some View {
        Form {
            Section("Version") {
                HStack {
                    Text("Current version")
                    Spacer()
                    Text(UpdateManager.shared.currentVersion)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("Automatic Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { UpdateManager.shared.automaticChecks },
                    set: { UpdateManager.shared.automaticChecks = $0 }
                ))
                Text("Checks once per day. Updates are cryptographically signed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Check for Updates Now") {
                    UpdateManager.shared.checkForUpdates()
                }
                .disabled(!UpdateManager.shared.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
    }

"""

if "private var updatesTab" in content:
    print("ℹ️  updatesTab property already present — skipping")
else:
    if marker2 not in content:
        print(f"ERROR: Could not find marker for insert 2:\n  {marker2}")
        sys.exit(1)
    content = content.replace(marker2, updates_block + marker2, 1)
    print("✅ Inserted updatesTab computed property")

PATH.write_text(content)
print(f"✅ {PATH} patched successfully")
