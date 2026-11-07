// AutoVibeAds payload builder & signer.
//
// Usage (run from the repo root):
//   swift tools/build-payload.swift genkey <private-key-file>
//       Generates an Ed25519 keypair. Writes the private key (base64, raw 32 bytes)
//       to <private-key-file> with 0600 permissions and prints the public key.
//       KEEP THE PRIVATE KEY OUT OF THIS REPO. Back it up; losing it means
//       shipping a new app build with a new public key.
//
//   swift tools/build-payload.swift build <private-key-file>
//       Scans rules-*.json and scriptlets.json in the current directory,
//       validates them, writes index.json (manifest with counts, sha256 and a
//       monotonic `built` timestamp) and index.json.sig (Ed25519 over the exact
//       bytes of index.json).

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("usage: build-payload.swift genkey|build <private-key-file>")
}
let keyPath = arguments[2]

switch arguments[1] {
case "genkey":
    guard !FileManager.default.fileExists(atPath: keyPath) else {
        fail("\(keyPath) already exists; refusing to overwrite a signing key")
    }
    let key = Curve25519.Signing.PrivateKey()
    try! key.rawRepresentation.base64EncodedString().write(
        toFile: keyPath, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: keyPath)
    print("private key written to \(keyPath) (base64, keep it secret, back it up)")
    print("public key (embed in the app):")
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "build":
    guard let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    else { fail("cannot read private key at \(keyPath)") }

    let cwd = FileManager.default.currentDirectoryPath
    let entries = try! FileManager.default.contentsOfDirectory(atPath: cwd)
    let ruleFiles = entries.filter { $0.hasPrefix("rules-") && $0.hasSuffix(".json") }.sorted()
    guard !ruleFiles.isEmpty else { fail("no rules-*.json files in \(cwd); run from the repo root") }

    var counts: [String: Int] = [:]
    var hashes: [String: String] = [:]
    for file in ruleFiles {
        let data = try! Data(contentsOf: URL(fileURLWithPath: file))
        guard let rules = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            fail("\(file) is not a JSON array of content-blocker rules")
        }
        counts[file] = rules.count
        hashes[file] = sha256Hex(data)
    }

    let scriptletsFile = "scriptlets.json"
    let scriptletsData = try! Data(contentsOf: URL(fileURLWithPath: scriptletsFile))
    guard let scriptlets = try? JSONSerialization.jsonObject(with: scriptletsData) as? [String: String] else {
        fail("\(scriptletsFile) must be a JSON object mapping host -> javascript string")
    }
    hashes[scriptletsFile] = sha256Hex(scriptletsData)

    let manifest: [String: Any] = [
        "version": 1,
        "built": Int(Date().timeIntervalSince1970),
        "rules": ruleFiles,
        "scriptlets": scriptletsFile,
        "hosts": scriptlets.keys.sorted(),
        "counts": counts,
        "sha256": hashes,
    ]
    let manifestData = try! JSONSerialization.data(
        withJSONObject: manifest, options: [.sortedKeys])
    try! manifestData.write(to: URL(fileURLWithPath: "index.json"))

    let signature = try! key.signature(for: manifestData)
    try! signature.base64EncodedString().write(
        toFile: "index.json.sig", atomically: true, encoding: .utf8)

    let total = ruleFiles.reduce(0) { $0 + (counts[$1] ?? 0) }
    print("index.json: \(ruleFiles.count) rule lists, \(total) rules, \(scriptlets.count) scriptlet hosts")
    print("index.json.sig: signed with \(keyPath)")
    print("public key check: \(key.publicKey.rawRepresentation.base64EncodedString())")

default:
    fail("unknown command \(arguments[1]); use genkey or build")
}
