#if canImport(FoundationModels) && compiler(>=6.4)
import FoundationModels
import LatchwayFoundationModels
import Testing

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
@Test func foundationModelsErrorHasSafeDescription() {
    #expect(LatchwayFoundationModelsError.invalidGatewayStream.errorDescription != nil)
}
#endif
