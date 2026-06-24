// Lightweight update check: ask GitHub for the latest release tag and compare to this build.
// No dependencies, no keys — just a nudge that links to the download. (Full auto-update = Sparkle, later.)
import Foundation

enum UpdateChecker {
    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func check(_ completion: @escaping ((version: String, url: URL)?) -> Void) {
        let api = URL(string: "https://api.github.com/repos/jackarkcreator/jack/releases/latest")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let html = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let newer = isNewer(tag, than: currentVersion())
            DispatchQueue.main.async { completion(newer ? (tag, html) : nil) }
        }.resume()
    }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.lowercased().replacingOccurrences(of: "v", with: "").split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
