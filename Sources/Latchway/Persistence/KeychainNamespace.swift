enum LatchwayKeychainNamespace {
    static func service(
        applicationID: String,
        environment: String,
        clientRuntime: LatchwayClientRuntime
    ) -> String {
        "dev.latchway.sdk.\(clientRuntime.platformIdentifier).\(applicationID).\(environment)"
    }

    static func componentService(
        applicationID: String,
        environment: String,
        definitionID: String
    ) -> String {
        "dev.latchway.sdk.ios.\(applicationID).\(environment).component.\(definitionID)"
    }
}
