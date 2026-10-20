// Checks a signed appcast before it's published, the way Sparkle checks it in the app, but with
// only the public EdDSA key: the appcast's signature, and its one update: the download URL, length,
// version, and the zip's signature. See SPUExtractAppcastContent and SUSignatureVerifier in Sparkle.
//   swift scripts/verify-appcast.swift <appcast.xml> <zip> <download URL prefix> <public key> <version>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("verify-appcast: \(message)\n".utf8))
    exit(1)
}

func read(_ path: String) -> Data {
    do {
        return try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        fail("can't read \(path): \(error.localizedDescription)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 5 else {
    fail("usage: verify-appcast.swift <appcast.xml> <zip> <download URL prefix> <public key> <version>")
}
let (appcastPath, zipPath, prefix, publicKeyBase64, version) =
    (arguments[0], arguments[1], arguments[2], arguments[3], arguments[4])

guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
else { fail("the public key isn't a base64-encoded EdDSA key") }

func verify(_ signatureBase64: String?, for data: Data, _ what: String) {
    guard let signatureBase64, let signature = Data(base64Encoded: signatureBase64) else {
        fail("\(what) has no EdDSA signature")
    }
    guard publicKey.isValidSignature(signature, for: data) else {
        fail("\(what)'s EdDSA signature doesn't match the public key")
    }
}

// The appcast's signature is in its last "<!-- sparkle-signatures:" comment and covers everything
// before that comment.
let appcast = read(appcastPath)
guard let start = appcast.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards),
      let end = appcast.range(of: Data("-->".utf8), in: start.upperBound..<appcast.endIndex)
else { fail("the appcast isn't signed") }
let content = appcast[appcast.startIndex..<start.lowerBound]
var fields: [String: String] = [:]
for line in String(decoding: appcast[start.upperBound..<end.lowerBound], as: UTF8.self).split(separator: "\n") {
    if let colon = line.firstIndex(of: ":") {
        fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
}
verify(fields["edSignature"], for: content, "the appcast")
guard fields["length"] == String(content.count) else { fail("the appcast's signed length is wrong") }

let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
let document: XMLDocument
do {
    document = try XMLDocument(data: content)
} catch {
    fail("the appcast isn't valid XML: \(error.localizedDescription)")
}
guard let items = try? document.nodes(forXPath: "/rss/channel/item") as? [XMLElement], items.count == 1 else {
    fail("the appcast must have exactly one item")
}
let item = items[0]
func text(_ name: String) -> String? {
    item.elements(forLocalName: name, uri: sparkle).first?.stringValue
}
guard text("version") == version, text("shortVersionString") == version else {
    fail("the update's version isn't \(version)")
}
guard text("releaseNotesLink") == nil, item.elements(forName: "description").first?.stringValue?.isEmpty == false else {
    fail("the release notes must be embedded in the appcast")
}
guard let enclosure = item.elements(forName: "enclosure").first, item.elements(forName: "enclosure").count == 1 else {
    fail("the update must have exactly one enclosure")
}
let zip = read(zipPath)
let zipName = URL(fileURLWithPath: zipPath).lastPathComponent
guard enclosure.attribute(forName: "url")?.stringValue == prefix + zipName else {
    fail("the update's URL isn't \(prefix + zipName)")
}
guard enclosure.attribute(forName: "length")?.stringValue == String(zip.count) else {
    fail("the update's length isn't the size of \(zipName)")
}
verify(enclosure.attribute(forLocalName: "edSignature", uri: sparkle)?.stringValue, for: zip, zipName)

print("Verified \(appcastPath): signed, and offers version \(version) at \(prefix + zipName), signed.")
