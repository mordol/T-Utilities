import Testing
import TUCore
@testable import ModStats

/// Required for every module (Docs/MODULES.md). Checked by Scripts/check-modules.sh.
@MainActor
struct ModuleContractTests {
    @Test func followsModuleContract() async {
        #expect(await ModuleContract.violations(of: StatsModule.self, starting: true) == [])
    }
}
