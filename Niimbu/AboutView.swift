import SwiftUI

/// Version details and when this install stops opening.
enum AppBuild {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// When the provisioning profile the app was installed with runs out; the app won't open after that.
    /// Nil where there's no profile (e.g. a Mac build signed without one), which doesn't expire.
    static let expiry: Date? = {
        #if os(iOS)
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        #else
        let url: URL? = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #endif
        // The profile is a signed envelope around a plain XML plist; pull the plist out.
        guard let url, let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    static var daysLeft: Int? {
        guard let expiry else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: .now, to: expiry).day ?? 0)
    }

    /// Close enough to expiry to warn on the main screen.
    static var expiresSoon: Bool { (daysLeft ?? .max) <= 14 }

    static var daysLeftText: String? {
        daysLeft.map { $0 == 1 ? "1 day left" : "\($0) days left" }
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        appIcon
                            .resizable()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                        Text("Niimbu").font(.title2.bold())
                        Text("Labels for NIIMBOT printers").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("This install") {
                    LabeledContent("Version", value: AppBuild.version)
                    if let expiry = AppBuild.expiry, let left = AppBuild.daysLeftText {
                        LabeledContent("Expires", value: expiry.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("Time left") {
                            Text(left).foregroundStyle(AppBuild.expiresSoon ? .orange : .secondary)
                        }
                    } else {
                        LabeledContent("Expires", value: "Never")
                    }
                }

                Section {
                    LabeledContent("Made for", value: "NIIMBOT D110 M")
                    Text("Other D-series printers and the B1 use the same code but are untested.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Section("Credits") {
                    Link("niimbluelib by MultiMote", destination: URL(string: "https://github.com/MultiMote/niimbluelib")!)
                    Link("NiimPrintX by labbots", destination: URL(string: "https://github.com/labbots/NiimPrintX")!)
                    Link("niimprint by AndBondStyle", destination: URL(string: "https://github.com/AndBondStyle/niimprint")!)
                    Text("The printer protocol is ported from niimbluelib (MIT License).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("About")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 520)
        #endif
    }

    private var appIcon: Image {
        #if os(iOS)
        // iOS doesn't expose the icon by name in the asset catalog; the compiled icon files are in the bundle.
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let name = (primary["CFBundleIconFiles"] as? [String])?.last,
           let image = UIImage(named: name) {
            return Image(uiImage: image)
        }
        return Image(systemName: "app")
        #else
        return Image(nsImage: NSApplication.shared.applicationIconImage)
        #endif
    }
}
