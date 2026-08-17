import AppKit
import SwiftUI
import MCPMCore

/// Square icon for a server: an SF Symbol for well-known servers, otherwise a favicon for remote
/// hosts, otherwise a tinted monogram. The monogram draws immediately and the favicon cross-fades
/// in once it has been fetched, so rows never wait on the network.
struct ServerIcon: View {
    let server: Server
    var size: CGFloat = 26

    @State private var favicon: NSImage?

    private var source: IconSource {
        IconSource.resolve(name: server.name, kind: server.kind, url: server.url,
                           command: server.command, args: server.args)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: size * 0.27, style: .continuous) }

    var body: some View {
        content
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch source {
        case .symbol(let name):
            symbolTile(name)
        case .monogram(let text, let hue):
            monogramTile(text, hue: hue)
        case .favicon(let hosts):
            monogramTile(IconSource.monogram(for: server.name), hue: IconSource.hue(server.name))
                .overlay {
                    if let favicon {
                        Image(nsImage: favicon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .clipShape(shape)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: favicon != nil)
                .task(id: hosts) {
                    guard let data = await FaviconCache.shared.iconData(for: hosts) else { return }
                    favicon = NSImage(data: data)
                }
        }
    }

    private func symbolTile(_ name: String) -> some View {
        let tint = Self.tint(hue: IconSource.hue(server.name))
        return shape.fill(tint.opacity(0.16))
            .overlay {
                Image(systemName: name)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(tint)
            }
    }

    private func monogramTile(_ text: String, hue: Int) -> some View {
        shape.fill(Self.tint(hue: hue))
            .overlay {
                Text(text)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2)
            }
    }

    private static func tint(hue: Int) -> Color {
        Color(hue: Double(hue) / 360, saturation: 0.55, brightness: 0.75)
    }
}

/// Fetches and caches favicons: memory for the session, PNGs on disk under the app's caches
/// directory. Every failure is silent and remembered for the session so a dead host is asked once.
actor FaviconCache {
    static let shared = FaviconCache()

    private enum Entry {
        case icon(Data)
        case missing

        var data: Data? { if case .icon(let d) = self { return d } else { return nil } }
    }

    private var memory: [String: Entry] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private let directory: URL
    private let session: URLSession

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = caches.appending(path: "co.charmtechnologies.mcpmanager/icons", directoryHint: .isDirectory)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// PNG data for the first of `hosts` that has an icon, or nil if none does. Never throws.
    func iconData(for hosts: [String]) async -> Data? {
        let key = hosts.joined(separator: "_")
        if let entry = memory[key] { return entry.data }
        if let running = inFlight[key] { return await running.value }

        let file = directory.appending(path: "\(Self.fileName(key)).png", directoryHint: .notDirectory)
        let session = self.session
        let directory = self.directory
        let task = Task<Data?, Never> {
            if let cached = try? Data(contentsOf: file) { return cached }
            guard let png = await Self.download(hosts: hosts, session: session) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
            return png
        }
        inFlight[key] = task

        let data = await task.value
        inFlight[key] = nil
        memory[key] = data.map(Entry.icon) ?? .missing
        return data
    }

    /// Per host: the site's own icon first, then Google's favicon service, then DuckDuckGo's.
    /// Both services answer a miss with 404 and a placeholder image, so the status code is what
    /// separates a real icon from a grey globe.
    private static func download(hosts: [String], session: URLSession) async -> Data? {
        for host in hosts {
            let sources = [
                "https://\(host)/favicon.ico",
                "https://www.google.com/s2/favicons?domain=\(host)&sz=64",
                "https://icons.duckduckgo.com/ip3/\(host).ico",
            ].compactMap(URL.init(string:))

            for url in sources {
                guard let (data, response) = try? await session.data(from: url),
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let png = pngData(from: data)
                else { continue }
                return png
            }
        }
        return nil
    }

    /// Normalizes whatever the host served (.ico, .svg, .png) to PNG, and rejects anything
    /// AppKit can't decode — an HTML error page, say.
    private static func pngData(from data: Data) -> Data? {
        guard !data.isEmpty, let image = NSImage(data: data), image.isValid,
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func fileName(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}
