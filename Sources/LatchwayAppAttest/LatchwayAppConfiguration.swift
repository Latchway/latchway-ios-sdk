import Foundation
#if !COCOAPODS
import Latchway
#endif

public extension LatchwayApp {
    /// Configure from either native or React Native first. No auth SDK or
    /// bootstrap registration is needed; the signed root group stays explicit.
    static func configure(_ options: LatchwayAppOptions,
                          name: String = LatchwayAppRegistry.defaultName) async throws -> LatchwayApp {
        let factory: LatchwayAccountAttestationFactory?
        if let root = options.rootKeychainAccessGroup {
            factory = { LatchwayAppAttestProvider(rootKeychainAccessGroup: root, storageNamespace: $0) }
        } else { factory = nil }
        return try await LatchwayAppRegistry.shared.configure(options, name: name, attestationFactory: factory)
    }
}
