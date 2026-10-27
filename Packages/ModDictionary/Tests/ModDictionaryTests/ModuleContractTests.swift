import Testing
import TUCore
@testable import ModDictionary

/// Required for every module (Docs/MODULES.md). Checked by Scripts/check-modules.sh.
@MainActor
struct ModuleContractTests {
    @Test func followsModuleContract() async {
        #expect(await ModuleContract.violations(of: DictionaryModule.self, starting: true) == [])
    }
}
