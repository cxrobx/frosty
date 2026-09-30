// Verify an Ed25519 signature the way Sparkle does: the signature covers the raw bytes
// of the update archive; both the public key (SUPublicEDKey) and the signature
// (sparkle:edSignature) are base64 of the raw key / raw 64-byte signature.
//
//   swiftc -O scripts/ed25519-verify.swift -o ed25519-verify
//   ed25519-verify <public-key-b64> <signature-b64> <file>
//
// Exit 0 = valid, 1 = invalid or malformed, 2 = bad usage. Used by
// scripts/verify-update-feed.sh, which checks against only the PUBLIC key in the
// repo's Info.plist, so it needs no Keychain and can never sign anything.
import CryptoKit
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: ed25519-verify <public-key-b64> <signature-b64> <file>", code: 2) }

guard let keyData = Data(base64Encoded: args[1]), keyData.count == 32 else {
    fail("public key is not base64 of 32 bytes")
}
guard let signature = Data(base64Encoded: args[2]), signature.count == 64 else {
    fail("signature is not base64 of 64 bytes")
}
guard let file = FileManager.default.contents(atPath: args[3]) else { fail("cannot read \(args[3])") }
guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    fail("not a valid Ed25519 public key")
}

if key.isValidSignature(signature, for: file) {
    print("signature valid")
} else {
    fail("signature INVALID")
}
