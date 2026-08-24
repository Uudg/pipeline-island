#!/usr/bin/env swift
import Foundation
import Security

func loadToken() -> String? {
    for dp in [true, false] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.pipelineisland.app",
            kSecAttrAccount as String: "gitlab.com",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        q[kSecUseDataProtectionKeychain as String] = dp
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data { return String(data: d, encoding: .utf8) }
    }
    return nil
}

func gql(_ token: String, _ query: String) -> [String: Any]? {
    var req = URLRequest(url: URL(string: "https://gitlab.com/api/graphql")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try! JSONSerialization.data(withJSONObject: ["query": query])
    var result: [String: Any]?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        if let data { result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
    }.resume()
    sem.wait()
    return result
}

guard let token = loadToken() else { print("no token"); exit(1) }

// The app's exact query shape.
let query = """
query {
  currentUser { username }
  projects(membership: true, first: 30, sort: "latest_activity_desc") {
    nodes {
      fullPath
      group { fullPath }
      namespace { fullPath }
    }
  }
}
"""

guard let r = gql(token, query), let data = r["data"] as? [String: Any] else {
    print("query failed"); exit(1)
}
let username = ((data["currentUser"] as? [String: Any])?["username"] as? String) ?? "?"
let nodes = ((data["projects"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []

print("signed in as: \(username)")
print("member projects: \(nodes.count)\n")

struct P { let path: String; let group: String?; let namespace: String? }
let projects = nodes.map {
    P(path: $0["fullPath"] as? String ?? "?",
      group: ($0["group"] as? [String: Any])?["fullPath"] as? String,
      namespace: ($0["namespace"] as? [String: Any])?["fullPath"] as? String)
}

// --- scope: mine (app rule: group == nil && namespace == username)
let mine = projects.filter { $0.group == nil && $0.namespace == username }
print("SCOPE .mine  -> \(mine.count) project(s)")
for p in mine { print("    \(p.path)") }

// The naive rule, for comparison — this is the bug the strict rule avoids.
let naive = projects.filter { $0.group == nil }
if naive.count != mine.count {
    print("  naive 'no group' rule would ALSO include \(naive.count - mine.count):")
    for p in naive where p.namespace != username { print("    \(p.path)  <- someone else's namespace") }
}

// --- scope: groups
let groups = Set(projects.compactMap(\.group))
print("\nSCOPE .groups -> available groups: \(groups.sorted())")
for g in groups.sorted() {
    let inGroup = projects.filter { $0.group == g || ($0.group?.hasPrefix(g + "/") ?? false) }
    print("    \(g): \(inGroup.count) project(s)")
}

// --- scope: all
print("\nSCOPE .all   -> \(projects.count) project(s)")

print("\n=== totals: mine=\(mine.count)  grouped=\(projects.count - naive.count)  all=\(projects.count) ===")
