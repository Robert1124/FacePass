import Foundation
import FacePassCompanionCore

public enum StandByIntentDependencies {
    public static func makeUnlockClient(
        configuration: FacePassCompanionConfiguration = .default
    ) throws -> StandByUnlockClient {
        let endpointCache = EndpointCache(configuration: configuration)
        let keyStore = try CompanionKeyStore(configuration: configuration)
        let counterStore = UserDefaultsStandByUnlockCounterStore(configuration: configuration)

        return StandByUnlockClient(
            endpointCache: endpointCache,
            rediscoveryService: BonjourRediscoveryService(),
            keyStore: keyStore,
            counterStore: counterStore
        )
    }
}
