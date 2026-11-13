// The companion app: how to turn the keyboard on, a box to try it in, and what it keeps.
// (The keyboard's own settings, learned words and training rounds live inside the keyboard,
// since iOS doesn't let this app see the keyboard's storage without Full Access.)

import SwiftUI
import UIKit

@main
struct TrailApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-UITestHarness") {
                HarnessView().ignoresSafeArea(.keyboard)
            } else {
                HomeView()
            }
        }
    }
}

/// Whether Trail is in the iPhone's keyboard list (read from the system's keyboard setting).
func trailKeyboardEnabled() -> Bool? {
    guard let list = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] else { return nil }
    let me = (Bundle.main.bundleIdentifier ?? "") + ".keyboard"
    return list.contains(me)
}

struct HomeView: View {
    @State private var practice = ""
    @State private var enabled = trailKeyboardEnabled()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Your own swipe keyboard. It learns the words you use and how you swipe, and keeps it all on this iPhone.")
                        .foregroundColor(.secondary)

                    Card(title: "1. Turn it on", status: statusText) {
                        Text("Tap Open Settings, then Keyboards, and turn on Trail. Leave “Allow Full Access” off: Trail doesn’t need it, and with it off iOS gives the keyboard no network access at all.")
                        Button(action: openSettings) {
                            Text("Open Settings").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("home.openSettings")
                        Text("Or: Settings › General › Keyboard › Keyboards › Add New Keyboard › Trail.")
                            .font(.footnote).foregroundColor(.secondary)
                    }

                    Card(title: "2. Switch to it", status: nil) {
                        Text("In any app, touch and hold the globe 🌐 (or the emoji key) below the keyboard and pick Trail. Tap it to flip between keyboards.")
                        Text("Password fields always use Apple’s keyboard, and phone-number fields use the number pad. That’s iOS, not a fault.")
                            .font(.footnote).foregroundColor(.secondary)
                    }

                    Card(title: "3. Try it here", status: nil) {
                        ZStack(alignment: .topLeading) {
                            if practice.isEmpty {
                                Text("Type or swipe here…").foregroundColor(.secondary).padding(.top, 8).padding(.leading, 5)
                            }
                            TextEditor(text: $practice)
                                .frame(minHeight: 120)
                                .accessibilityIdentifier("home.practice")
                        }
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                    }

                    Card(title: "4. Teach it how you swipe", status: nil) {
                        Text("On Trail’s suggestion bar, tap the sliders button at the left (it shows when no word is in progress), then Start a training round. Swipe the word shown, 20 to a round. It starts adjusting to how you swipe after 20 swipes and keeps improving up to about 150. Words you miss come back in later rounds.")
                        Text("Picking a different word from the suggestion bar after a swipe also teaches it: that word comes up more, the wrong guess less. Hold any suggestion to never see it again.")
                            .font(.footnote).foregroundColor(.secondary)
                    }

                    Card(title: "What it keeps", status: nil) {
                        Text("Single words you use (and how often), words you rejected or blocked, a running summary of how you swipe, and training results, per language. Never sentences, never your swipes, nothing from password, email, web address, username, code, address or card fields.")
                        Text("It’s all in Trail’s settings on the keyboard (sliders button) under Learned words and Never suggest, where you can delete any of it. It stays on this iPhone: no network access, and left out of backups.")
                            .font(.footnote).foregroundColor(.secondary)
                    }

                    Card(title: "Keeping it installed", status: nil) {
                        Text("Installed with a free Apple ID, Trail stops opening after 7 days unless it’s refreshed. Sideloadly on your PC refreshes it automatically when your iPhone is plugged in or on the same Wi-Fi with Wi-Fi sync on. Your learned words survive a refresh.")
                            .font(.footnote)
                    }

                    Text("Trail \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.footnote).foregroundColor(.secondary)
                }
                .padding()
            }
            .navigationTitle("Trail")
        }
        .navigationViewStyle(.stack)
        .onChange(of: phase) { p in
            if p == .active { enabled = trailKeyboardEnabled() }
        }
    }

    private var statusText: String? {
        switch enabled {
        case .some(true): return "On ✓"
        case .some(false): return "Not on yet"
        case .none: return nil
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

struct Card<Content: View>: View {
    let title: String
    let status: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let s = status { Text(s).font(.subheadline).foregroundColor(s.hasSuffix("✓") ? .green : .orange) }
            }
            content
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
    }
}
