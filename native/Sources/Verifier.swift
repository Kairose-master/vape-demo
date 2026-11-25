import Foundation
import Darwin
@main enum VerifierMain {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            print("Usage: NativeVerifier RUN_PACKAGE.json PINNED_PUBLIC_KEY.raw PINNED_TRUST_SET.json")
            exit(64)
        }
        let result: NativeVerification
        do {
            result = verifyNative(packageData:try Data(contentsOf:URL(fileURLWithPath:args[1])),
                                  pinnedPublicKey:try Data(contentsOf:URL(fileURLWithPath:args[2])),
                                  pinnedTrustData:try Data(contentsOf:URL(fileURLWithPath:args[3])))
        } catch {
            result = NativeVerification(verdict:"indeterminate",valid:false,complete:false,reason:"Evidence or independently supplied trust input missing",events:[])
        }
        print(String(decoding:try! canonical(result),as:UTF8.self))
        exit(result.valid && result.complete ? 0 : 2)
    }
}
