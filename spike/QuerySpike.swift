#!/usr/bin/env swift
import Foundation
import Security

let SERVICE = "com.pipelineisland.app", ACCOUNT = "gitlab.com"

func loadToken() -> String? {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: SERVICE, kSecAttrAccount as String: ACCOUNT,
        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
          let d = out as? Data else { return nil }
    return String(data: d, encoding: .utf8)
}

func gql(_ token: String, _ query: String) -> [String: Any]? {
    var req = URLRequest(url: URL(string: "https://gitlab.com/api/graphql")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try! JSONSerialization.data(withJSONObject: ["query": query])
    var result: [String: Any]?
    let sem = DispatchSemaphore(value: 0)
    let t0 = Date()
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        defer { sem.signal() }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        print("   HTTP \(code) in \(ms)ms")
        if let d = data { result = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
    }.resume()
    sem.wait()
    return result
}

guard let token = loadToken() else { print("no token"); exit(1) }

let Q = """
query {
  projects(membership: true, first: 30, sort: "latest_activity_desc") {
    nodes {
      fullPath
      pipelines(first: 3) {
        nodes {
          iid status ref source duration startedAt finishedAt
          detailedStatus { text }
          stages { nodes { name status } }
          user { username }
        }
      }
    }
  }
}
"""

print("=== project-centric pipeline query ===")
guard let r = gql(token, Q) else { print("no response"); exit(1) }
if let errs = r["errors"] {
    print("GraphQL errors: \(errs)")
    exit(1)
}
let data = r["data"] as? [String: Any]
let projects = ((data?["projects"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
print("projects returned: \(projects.count)\n")

var totalPipelines = 0, active = 0
for p in projects {
    let path = p["fullPath"] as? String ?? "?"
    let pls = ((p["pipelines"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
    if pls.isEmpty { continue }
    print("\(path)")
    for pl in pls {
        totalPipelines += 1
        let st = pl["status"] as? String ?? "?"
        if st == "RUNNING" || st == "PENDING" || st == "CREATED" { active += 1 }
        let iid = pl["iid"] as? String ?? "?"
        let ref = pl["ref"] as? String ?? "?"
        let dur = pl["duration"] as? Int
        let stages = ((pl["stages"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let stageStr = stages.map { "\($0["name"] as? String ?? "?"):\(($0["status"] as? String ?? "?").lowercased())" }
                             .joined(separator: " ")
        print("   #\(iid) [\(st)] \(ref) \(dur.map { "\($0)s" } ?? "-")")
        if !stageStr.isEmpty { print("        \(stageStr)") }
    }
}
print("\n=== totals: \(totalPipelines) pipelines, \(active) active ===")
print(totalPipelines > 0
    ? "=> CORRECT QUERY CONFIRMED — this is what the island polls."
    : "=> still empty; query needs another pass.")
