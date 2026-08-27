enum LatchwayKeychainNamespace {
    static func service(
        applicationID: String,
        environment: String,
        clientRuntime: LatchwayClientRuntime
    ) -> String {
        "dev.latchway.sdk.\(clientRuntime.platformIdentifier).\(applicationID).\(environment)"
    }
}
