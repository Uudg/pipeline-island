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

guard let token = loadToken() else { print("no token"); exit(1) }

let query = """
query {
  projects(membership: true, first: 30, sort: "latest_activity_desc") {
    nodes {
      fullPath
      pipelines(first: 3) {
        nodes { iid status finishedAt duration user { username } }
      }
    }
  }
}
"""

var req = URLRequest(url: URL(string: "https://gitlab.com/api/graphql")!)
req.httpMethod = "POST"
req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.httpBody = try! JSONSerialization.data(withJSONObject: ["query": query])

let sem = DispatchSemaphore(value: 0)
var payload: [String: Any]?
URLSession.shared.dataTask(with: req) { d, _, _ in
    defer { sem.signal() }
    if let d { payload = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
}.resume()
sem.wait()

guard let nodes = ((((payload?["data"] as? [String: Any])?["projects"] as? [String: Any])?["nodes"]) as? [[String: Any]]) else {
    print("query failed"); exit(1)
}

// The app's linger windows.
let finishedLinger: TimeInterval = 30
let failedLinger: TimeInterval = 600
let activeStates = ["CREATED", "PENDING", "RUNNING", "WAITING_FOR_RESOURCE", "PREPARING"]

let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let isoPlain = ISO8601DateFormatter()

func parse(_ s: String?) -> Date? {
    guard let s else { return nil }
    return iso.date(from: s) ?? isoPlain.date(from: s)
}

let now = Date()
var total = 0, shownOld = 0, shownNew = 0
var oldRows: [String] = [], newRows: [String] = []

for proj in nodes {
    let path = proj["fullPath"] as? String ?? "?"
    let pls = ((proj["pipelines"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
    for p in pls {
        total += 1
        let status = p["status"] as? String ?? "?"
        let iid = p["iid"] as? String ?? "?"
        let isActive = activeStates.contains(status)
        let finished = parse(p["finishedAt"] as? String)
        let age = finished.map { now.timeIntervalSince($0) }

        // OLD behaviour: failures with no observed finish stayed FOREVER.
        let oldShown = isActive || status == "FAILED"
        // NEW behaviour: judged on real finishedAt.
        var newShown = isActive
        if !isActive, let age {
            newShown = status == "FAILED" ? age < failedLinger : age < finishedLinger
        }

        if oldShown {
            shownOld += 1
            let days = age.map { Int($0 / 86400) } ?? -1
            oldRows.append("  \(path) #\(iid) \(status) — finished \(days)d ago")
        }
        if newShown { shownNew += 1; newRows.append("  \(path) #\(iid) \(status)") }
    }
}

print("total pipelines fetched: \(total)\n")
print("OLD filter would show \(shownOld):")
oldRows.forEach { print($0) }
print("\nNEW filter shows \(shownNew):")
if newRows.isEmpty { print("  (none — nothing running, nothing recently finished)") }
newRows.forEach { print($0) }
print("\n=> removed \(shownOld - shownNew) stale row(s) from the island")
