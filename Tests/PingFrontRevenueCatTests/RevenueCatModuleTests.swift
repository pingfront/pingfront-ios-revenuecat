import PingFrontCore
import PingFrontRevenueCat
import Testing

@Suite("RevenueCat module")
struct RevenueCatModuleTests {
    @Test("The README's setup compiles and names the module pingfront.revenuecat")
    func module() {
        let options = RevenueCatOptions(offerings: ["winter_sale", "default"]) { _ in .cancelled }
        let modules: [PingFrontModule] = [.revenueCat, .revenueCat(options)]
        #expect(modules.map(\.id) == ["pingfront.revenuecat", "pingfront.revenuecat"])
        #expect(options.presentsPaywalls)
        #expect(RevenueCatOptions().offerings == nil)
    }
}
