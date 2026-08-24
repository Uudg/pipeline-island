#!/usr/bin/env swift
import Foundation
import Security

func loadToken() -> String? {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.pipelineisland.app",
        kSecAttrAccount as String: "gitlab.com",
        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
          let d = out as? Data else { return nil }
    return String(data: d, encoding: .utf8)
}

func gql(_ token: String, _ query: String) -> (Int, [String: Any]?) {
    var req = URLRequest(url: URL(string: "https://gitlab.com/api/graphql")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try! JSONSerialization.data(withJSONObject: ["query": query])
    var code = -1; var result: [String: Any]?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        defer { sem.signal() }
        code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if let d = data { result = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
    }.resume()
    sem.wait()
    return (code, result)
}

let Q = """
query {
  project(fullPath: "acme/web-app") {
    pipelines(first: 1) {
      nodes {
        iid status ref duration
        stages { nodes { name status } }
        jobs { nodes { name status stage { name } } }
      }
    }
  }
}
"""

guard let token = loadToken() else { print("no token"); exit(1) }

// ISO8601 wall clock for the log
let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"

print("polling acme/web-app — adaptive interval, 5 min ceiling")
print("time     status    dur  stages")
print(String(repeating: "─", count: 64))

let deadline = Date().addingTimeInterval(300)
var lastSignature = ""
var polls = 0, totalMs = 0
var sawActive = false, sawTerminal = false
var interval: UInt32 = 5

while Date() < deadline {
    let t0 = Date()
    let (code, r) = gql(token, Q)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    polls += 1; totalMs += ms
    guard code == 200,
          let node = ((((r?["data"] as? [String: Any])?["project"] as? [String: Any])?["pipelines"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first
    else { print("\(fmt.string(from: Date()))  HTTP \(code) — retry"); sleep(5); continue }

    let iid = node["iid"] as? String ?? "?"
    let status = node["status"] as? String ?? "?"
    let dur = node["duration"] as? Int
    let stages = ((node["stages"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
    let stageStr = stages.map { "\($0["name"] as? String ?? "?"):\(($0["status"] as? String ?? "?").lowercased())" }
                         .joined(separator: " ")
    let jobs = ((node["jobs"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
    let running = jobs.filter { ($0["status"] as? String) == "RUNNING" }
                      .map { $0["name"] as? String ?? "?" }

    let isActive = ["RUNNING", "PENDING", "CREATED", "WAITING_FOR_RESOURCE"].contains(status)
    if isActive { sawActive = true }
    if ["SUCCESS", "FAILED", "CANCELED"].contains(status), sawActive { sawTerminal = true }

    // adaptive backoff: fast while active, slow when idle
    interval = isActive ? 5 : 20

    let sig = "\(iid)|\(status)|\(stageStr)|\(running.joined(separator: ","))"
    if sig != lastSignature {
        let d = dur.map { "\($0)s" } ?? "–"
        print("\(fmt.string(from: Date()))  #\(iid) \(status.padding(toLength: min(9, max(9, status.count)), withPad: " ", startingAt: 0))  \(d.padding(toLength: 5, withPad: " ", startingAt: 0)) \(stageStr)")
        if !running.isEmpty { print("          ▸ running: \(running.joined(separator: ", "))") }
        lastSignature = sig
    }

    if sawTerminal {
        print(String(repeating: "─", count: 64))
        print("TERMINAL STATE REACHED — full lifecycle observed")
        break
    }
    sleep(interval)
}

print("polls: \(polls) | avg latency: \(polls > 0 ? totalMs/polls : 0)ms")
print(sawActive && sawTerminal
      ? "=> RUNTIME LOOP CONFIRMED: active→terminal transition captured live."
      : sawActive ? "=> saw active state; timed out before terminal."
                  : "=> never saw an active pipeline (trigger one and rerun).")
