#!/usr/bin/env swift

import Foundation
import Security

let SERVICE = "com.pipelineisland.app"
let ACCOUNT = "gitlab.com"

// MARK: - Keychain (this is what a shipped app uses)

func storeToken(_ token: String) -> Bool {
    let del: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: SERVICE,
        kSecAttrAccount as String: ACCOUNT,
    ]
    SecItemDelete(del as CFDictionary)

    var add = del
    add[kSecValueData as String] = token.data(using: .utf8)!
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
}

func loadToken() -> String? {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: SERVICE,
        kSecAttrAccount as String: ACCOUNT,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
          let d = out as? Data else { return nil }
    return String(data: d, encoding: .utf8)
}

// MARK: - Model

struct GQLResponse: Decodable {
    struct Wrap: Decodable { let currentUser: User? }
    struct User: Decodable {
        let username: String
        let authoredMergeRequests: MRConn?
    }
    struct MRConn: Decodable { let nodes: [MR] }
    struct MR: Decodable {
        let title: String
        let webUrl: String
        let project: Project
        let headPipeline: Pipeline?
    }
    struct Project: Decodable { let fullPath: String }
    struct Pipeline: Decodable {
        let status: String
        let startedAt: String?
        let duration: Int?
        let stages: StageConn?
    }
    struct StageConn: Decodable { let nodes: [Stage] }
    struct Stage: Decodable { let name: String; let status: String }
    let data: Wrap?
}

let QUERY = """
query {
  currentUser {
    username
    authoredMergeRequests(state: opened, first: 20) {
      nodes {
        title webUrl
        project { fullPath }
        headPipeline {
          status startedAt duration
          stages { nodes { name status } }
        }
      }
    }
  }
}
"""

// MARK: - Network

func check(token: String) {
    var req = URLRequest(url: URL(string: "https://gitlab.com/api/graphql")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try! JSONSerialization.data(withJSONObject: ["query": QUERY])

    let sem = DispatchSemaphore(value: 0)
    let t0 = Date()
    URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { sem.signal() }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if let err = err { print("NETWORK FAIL: \(err.localizedDescription)"); return }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        print("HTTP \(code) in \(ms)ms")
        guard let data = data else { print("no body"); return }

        guard code == 200 else {
            print("body: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            print("\n=> Networking works. Token rejected — supply a valid PAT.")
            return
        }
        do {
            let r = try JSONDecoder().decode(GQLResponse.self, from: data)
            guard let u = r.data?.currentUser else {
                print("authenticated but no currentUser: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
                return
            }
            print("user: \(u.username)")
            let mrs = u.authoredMergeRequests?.nodes ?? []
            print("open MRs: \(mrs.count)")
            for mr in mrs {
                let p = mr.headPipeline
                let st = p?.status ?? "—"
                let dur = p.flatMap { $0.duration.map { "\($0)s" } } ?? "-"
                print("  [\(st.padded(9))] \(mr.project.fullPath)  \(mr.title.prefix(40))  \(dur)")
                for s in p?.stages?.nodes ?? [] {
                    print("        · \(s.name.padded(14)) \(s.status)")
                }
            }
            print("\n=> FULL NATIVE PATH WORKS. No glab, no stolen creds.")
        } catch {
            print("decode error: \(error)")
            print(String(data: data, encoding: .utf8)?.prefix(400) ?? "")
        }
    }.resume()
    sem.wait()
}

extension String {
    func padded(_ n: Int) -> String {
        count >= n ? self : self + String(repeating: " ", count: n - count)
    }
}

// MARK: - Main

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "check" {
case "store":
    guard args.count > 2 else { print("need token"); exit(1) }
    print(storeToken(args[2]) ? "stored in Keychain" : "keychain write FAILED")
case "check":
    guard let tok = loadToken() else {
        print("no token in Keychain. run: swift AuthSpike.swift store <PAT>")
        exit(1)
    }
    print("keychain read ok (len \(tok.count), prefix \(tok.prefix(5))…)")
    check(token: tok)
default:
    print("usage: store <PAT> | check")
}
