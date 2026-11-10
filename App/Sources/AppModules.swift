import ModAwake
import ModCable
import ModClipboard
import ModClock
import ModDictionary
import ModMouse
import ModRemote
import ModStats
import ModSwitcher
import ModWindows
import TUCore

/// Every module the app ships with, in default order. Adding a module = adding its type here.
@MainActor
enum AppModules {
    static let all: [any TUModule.Type] = [
        AwakeModule.self,
        ClipboardModule.self,
        CableModule.self,
        ClockModule.self,
        WindowsModule.self,
        MouseModule.self,
        DictionaryModule.self,
        StatsModule.self,
        SwitcherModule.self,
        RemoteModule.self,
    ]
}
