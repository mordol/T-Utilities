# 모듈 규칙과 추가 절차

T-Utilities는 여러 유틸리티를 한 앱에 담지만, **각 모듈은 혼자 켜고 끌 수 있고 서로의 존재를 모른다**는 원칙으로 만듭니다. 이 문서는 그 원칙을 지키기 위한 규칙(반드시 지킴), 규칙을 기계적으로 확인하는 방법, 새 모듈을 추가하는 절차를 정합니다. 설계 배경은 [PLAN.md §4](../PLAN.md#4-아키텍처)에 있습니다.

## 1. 원칙

- **꺼진 모듈은 없는 것과 같다**: 인스턴스가 없고, 탭·타이머·워처·패널·프로세스도 없으며, 메모리도 차지하지 않는다.
- **모듈은 다른 모듈을 모른다**: 한 모듈의 추가·수정·삭제가 다른 모듈의 동작을 바꾸지 않는다(회귀 범위 = 그 모듈).
- **셸은 모듈 내용을 모른다**: 앱 셸(`App/Sources`)은 `TUModule` 계약과 `ModuleDescriptor`만 보고, 특정 모듈을 아는 곳은 `AppModules.swift`의 등록 목록 하나뿐이다.
- **공통 코드는 TUCore/TUUI에만**: 두 모듈이 같은 코드를 필요로 하면 복사하지 않고 TUCore(로직)나 TUUI(뷰)로 올린다. 공용 패키지는 모듈에 의존하지 않는다.

## 2. 규칙

| # | 규칙 | 확인 |
|---|---|---|
| R1 | 모듈 패키지는 `TUCore`, `TUUI`, `Vendor/*`, 외부 패키지에만 의존한다. 다른 `Mod*`를 import하거나 패키지 의존성으로 두지 않는다. | 스크립트 |
| R2 | `init(context:)`는 설정만 읽는다. 탭·타이머·Task·옵저버·파일·프로세스 같은 자원은 `start()`에서 얻는다. | 계약 테스트(일부), 리뷰 |
| R3 | `start()`에서 얻은 모든 자원은 `stop()`에서 해제한다. `stop()`은 `start()` 없이 불려도(시작 실패 후 정리) 안전해야 한다. | 계약 테스트, 리뷰 |
| R4 | 끈 뒤에는 인스턴스가 해제되어야 한다. 정적 가변 상태(`static var x = …`, `nonisolated(unsafe)`)나 싱글톤에 모듈·자원을 담지 않고, 반복 Task·콜백은 `[weak self]`로 잡는다. | 스크립트, 계약 테스트, 실행 중 누수 로그 |
| R5 | 비동기 작업(설정 `didSet`, 팝오버, 감지 등)이 `stop()` 뒤에 끝나도 시스템 상태(전원 assertion, 탭, 포인터 값, 대지 등)를 다시 바꾸지 않는다. `isStarted` 같은 플래그를 `await` 전후에 확인한다. | 리뷰 |
| R6 | 설정은 `ModuleSettings`(`module.<id>.<key>`)로만 읽고 쓴다. `UserDefaults.standard`, `@AppStorage`, 다른 preference 도메인 쓰기는 금지(예외는 §4). 옛 키를 옮길 때는 `ModuleSettings.migrateLegacyKey`를 `start()`에서 쓴다. | 스크립트, 계약 테스트 |
| R7 | 이벤트 탭은 반드시 TUCore `SupervisedEventTap`으로 만든다. 권한을 잃은 활성 탭은 시스템 전체 입력을 멈추게 하므로 직접 `CGEvent.tapCreate`를 쓰지 않는다. | 스크립트 |
| R8 | 모듈 id는 소문자 영문, 앱 안에서 유일하다. 단축키 이름은 `<id>.<이름>`(저장 키가 전역이므로). | 스크립트, 계약 테스트 |
| R9 | 시스템 전역 상태(전원, 뚜껑 닫힘, 포인터, 대지, 다른 앱 설정)를 바꾸면 `stop()`에서 원래대로 되돌린다. 사용자가 설정 화면에서 직접 바꾸는 macOS 설정 대리 토글만 예외(§4). | 리뷰 |
| R10 | 모든 모듈 테스트에 `ModuleContractTests`가 있다. 권한·하드웨어가 필요 없는 모듈은 `starting: true`로 `start()`까지 확인한다. | 스크립트 |
| R11 | 셸은 특정 모듈을 import하거나 모듈 id로 분기하지 않는다(`AppModules.swift` 제외). 모듈이 셸 기능이 필요하면 `TUModule`/`ModuleContext`에 범용 계약을 추가한다. | 스크립트(import), 리뷰 |

### 확인 방법

- **`task check`** (`Scripts/check-modules.sh`): R1, R4(정적 상태), R6, R7, R8, R10, R11(import), 등록 누락(project.yml·AppModules.swift)을 검사합니다. `task test`와 `Scripts/release.sh`가 먼저 실행하므로 **규칙을 어기면 테스트와 릴리스가 멈춥니다**.
- **계약 테스트** (`TUCore.ModuleContract.violations(of:)`): 임시 설정 저장소로 모듈을 만들고 `stop()`(선택적으로 `start()`→`stop()`)한 뒤, 인스턴스가 해제되는지, 설정 키가 `module.<id>.` 안에 있는지, 단축키 이름이 맞는지, id 형식을 확인합니다.
- **실행 중 누수 로그**: `ModuleRegistry`가 모듈을 끈 2초 뒤에도 인스턴스가 살아 있으면 `fault` 로그를 남깁니다(`log stream --predicate 'subsystem == "com.taegyu.tutilities"'`).
- **리뷰**: 스크립트로 못 잡는 R2·R3·R5·R9는 §6 체크리스트로 확인합니다.

규칙을 꼭 어겨야 하는 줄에는 같은 줄이나 바로 윗줄에 `// module-rules: allow <이유>`를 달고 §4 표에 추가합니다. 표에 없는 표시는 리뷰에서 거절합니다.

## 3. TUCore가 제공하는 공용 서비스

| 서비스 | 용도 |
|---|---|
| `ModuleContext.settings` (`ModuleSettings`) | 모듈 설정 저장소. `value`, `set`, `migrateLegacyKey`. |
| `ModuleContext.log` | `os.Logger`, 카테고리 = 모듈 id. |
| `ModuleContext.popover` (`PopoverControl`) | 메인 팝오버 열기·닫기·토글. |
| `HotkeyDefinition` | 전역 단축키. 레지스트리가 모듈이 켜져 있는 동안만 등록. |
| `SupervisedEventTap` | 권한 상실을 3초마다 확인해 스스로 해제하는 세션 이벤트 탭. `onUninstall`(진행 중 제스처 정리), `onReenable`(이벤트 유실), `onInstalledChange`(상태 표시). |
| `PopoverSize` | 셸이 소유한 팝오버 크기(폭, 목록 높이). 모듈은 **읽기만** 한다. |
| `Permission` | 권한 상태 조회·요청. |
| `ModuleContract` | 계약 테스트. |

## 4. 허용된 예외

| 위치 | 규칙 | 이유 |
|---|---|---|
| `ModAwake/LidSleepGuard.swift` `ClamshellMarker` | R6 | 뚜껑 닫힘 방지 중 앱이 죽었을 때 다음 실행에서 복구하기 위한 표시. 모듈 상태와 무관하게 읽혀야 하고, 기존 사용자 기기에 이미 저장된 키라 옮기면 복구가 한 번 누락될 수 있다. |
| `ModClipboard/Views/ClipboardSectionView.swift` | R6 | 셸이 소유한 `PopoverSize.listHeightKey`를 읽기만 한다(팝오버 세로 크기 조절의 유일한 사용처). |
| `ModWindows/WindowsModule.swift` `SystemTopEdgeFill` | R6, R9 | macOS "메뉴 막대로 드래그하여 화면 채우기" 설정을 사용자가 설정 화면에서 직접 켜고 끄는 대리 토글. 모듈을 꺼도 되돌리지 않는다. |
| `Vendor/WhatCable` (`DarwinSnapshotProvider`의 static watcher) | R3, R4 | 수정하지 않는 vendored 코드. Cable을 꺼도 IOKit watcher가 앱 종료까지 남는다(알려진 한계). |

## 5. 새 모듈 추가 절차

1. **범위 확인**: 기존 모듈과 기능이 겹치면 새 모듈 대신 그 모듈의 옵션으로 넣을지 먼저 정한다. 다른 모듈의 상태가 필요하다면 설계를 다시 본다(R1).
2. **패키지 생성**: `Packages/Mod<Name>/`에 `Package.swift`(의존성은 TUCore/TUUI/외부만), `Sources/Mod<Name>/<Name>Module.swift`, `Tests/Mod<Name>Tests/`.
3. **descriptor**: id(소문자, 유일), 표시 이름, SF Symbol, 필요한 권한, 팝오버 섹션 여부, **위험한 모듈(이벤트 탭, 시스템 설정 변경)은 `enabledByDefault: false`**, 충돌하는 앱 번들 id.
4. **수명 구현**: §2의 R2~R5, R7, R9를 지키도록 `init`/`start`/`stop`을 작성한다. 이벤트 탭은 `SupervisedEventTap`.
5. **계약 테스트**: `Tests/Mod<Name>Tests/ModuleContractTests.swift`를 다른 모듈에서 복사해 타입 이름만 바꾼다. 권한·하드웨어가 필요 없으면 `starting: true`.
6. **등록**: `project.yml`의 `packages:`와 `T-Utilities` 타깃 `dependencies:`, `App/Sources/AppModules.swift`의 import와 `all` 목록에 추가하고 `xcodegen generate`.
7. **확인**: `task test`(규칙 검사 + 모든 패키지 테스트)와 앱 빌드가 통과해야 한다.
8. **실행 확인**: 앱에서 모듈을 켜고 끄기를 몇 번 반복한 뒤 누수 `fault` 로그가 없는지 본다. 권한을 끊었다 다시 주는 경우도 확인한다(이벤트 탭 모듈).
9. **문서**: 서드파티 코드나 아이디어를 썼으면 `THIRD_PARTY_NOTICES.md`, 사용자 안내는 릴리스 노트(`Docs/releases/vX.Y.Z.md`).

## 6. 변경 리뷰 체크리스트

모듈을 고치거나 PR을 리뷰할 때 확인합니다.

- [ ] 바뀐 코드가 다른 모듈 패키지나 셸의 특정 모듈 코드를 건드리지 않는가? 건드린다면 TUCore/TUUI의 범용 계약으로 바꿀 수 있는가?
- [ ] 새 자원(Task, 타이머, 옵저버, 탭, 패널, 프로세스, 캐시)을 `start()`에서 얻고 `stop()`에서 해제하는가?
- [ ] `stop()` 뒤에 끝나는 비동기 작업이 시스템 상태를 다시 바꾸지 않는가(R5)?
- [ ] 시스템 전역 상태를 바꾸면 `stop()`에서 되돌리는가(R9)?
- [ ] 새 설정은 `ModuleSettings`로 저장하고, 키 이름을 바꿨다면 `migrateLegacyKey`로 옮기는가?
- [ ] 두 모듈에 같은 코드가 생기지 않았는가? 생겼다면 TUCore/TUUI로 올렸는가?
- [ ] `// module-rules: allow`를 새로 달았다면 §4 표에 이유가 있는가?
- [ ] `task test`가 통과하는가?

## 7. 감사 기록

### 2026-10-27 (v0.1.9 기준, 모듈 9개)

**확인된 결함과 조치**
- Awake: 감지 중(`await`) 모듈을 끄면, 끝난 tick이 전원 assertion과 뚜껑 닫힘 방지를 다시 켤 수 있었다 → `isStarted` 확인 추가(R5).
- Dictionary: 창 크기·위치를 `UserDefaults.standard`의 `dictionary.panel*` 키에 저장 → `module.dictionary.panel*`로 옮기고 옛 값은 한 번 이전(R6).
- 이벤트 탭 감시 코드가 Windows·Mouse·Switcher에 복사되어 이미 서로 달라짐(감시 Task 중복 방지, 해제 순서, `tapEnable`, 이벤트 유실 처리) → `SupervisedEventTap`으로 통합(R7). 탭이 설치된 동안 소유 객체를 붙잡아 콜백이 해제된 객체를 볼 수 없게 했다.
- 규칙을 강제하는 장치가 없었다(누수 검사는 로그뿐, 모듈 테스트에 계약 검사 없음, 릴리스 때 테스트 미실행, `task test`는 Tests 폴더 없는 TUUI에서 멈춤) → `check-modules.sh`, `ModuleContract`, 릴리스 게이트 추가.
- 셸과 Clipboard가 `popover.listHeight`를 암묵적으로 공유 → 셸 소유·모듈 읽기 전용 계약으로 명시(§3, §4).

**남은 개선 후보 (규칙 위반은 아님)**
- Windows·Switcher의 `status`가 탭 설치 여부 대신 `AXIsProcessTrusted`를 본다(권한이 오래된 상태면 "실행 중"으로 보임). `SupervisedEventTap.isInstalled`로 바꿀 수 있다.
- Clipboard OCR, Cable 새로고침, Mouse 배터리 조회는 `stop()` 직후 몇 초까지 끝날 수 있다. 시스템 상태를 바꾸지는 않지만 Clipboard OCR은 대지에 쓸 수 있다(R5 후보).
- 누수 검사는 실행 중 로그만 남긴다. Mouse 배터리 조회가 2초를 넘길 수 있어 Debug assert로 바꾸지 않았다.
- 팝오버 세로 크기 조절은 Clipboard를 끄면 아무 효과가 없다.
