# T-Utilities — 통합 유틸리티 앱 계획 (v1.0 확정)

> 상태: **확정** (2026-10-19). 구현 착수 대기
> 앱 이름 `T-Utilities`, 번들 ID `com.taegyu.tutilities`

## 1. 목표 & 확정 범위

CopyNinja의 클립보드 기능을 출발점으로, 개별 앱으로 쓰던 유틸리티들을 **모듈 방식의 단일 메뉴바 앱**으로 통합한다.
새 기능은 "모듈 하나 추가"로 끝나야 하고, 쓰지 않는 모듈은 끄면 메모리에서 해제된다.

| 모듈 | 원본 | 확정 범위 |
|---|---|---|
| Clipboard | CopyNinja (MIT) | 전체 기능 |
| Clock | Second Clock (비공개, 재구현) | 특정 타임존 24시간 표시 1개. 지역 라벨은 옵션 (예: `NY 00:33`) |
| Awake | eclam (MIT) + Amphetamine Enhancer (MIT) 참고 | 수동 / 자동(에이전트 감지) / 끔. **뚜껑 닫힘 상태에서도 방지** |
| Windows | Rectangle (MIT) | Maximize, Next/Prev Display |
| Mouse | LinearMouse (MIT) | 포인터 가속/속도, 스크롤 보정(스무스 제외), 버튼 → Mission Control / 바탕화면 보기, **G304 배터리** |
| Cable | WhatCable (MIT) | 포트/케이블/충전 진단 + Thunderbolt 토폴로지 + 디스플레이 정보. 알림 없음 |
| ~~Share~~ | LocalSend | **이번 범위에서 제외** (향후 후보, 부록 A) |

**배포 조건**
- 본인과 친구 대상이고, 유료 Apple Developer 계정은 없음.
- **macOS 26 이상**, Apple Silicon만 지원.

**라이선스**
- 원본은 모두 MIT임. 복사한 코드는 저작권 고지를 유지하고 `THIRD_PARTY_NOTICES.md`에 모음.
- WhatCable의 EDID 파서는 v4l-utils의 edid-decode에서 가져온 코드라 별도 고지가 필요함.
- 참고 목적의 Paseo는 Apache-2.0이며, 코드는 복사하지 않음.

---

## 2. 원본 분석 요약

### 2.1 CopyNinja (Clipboard)
- Swift 6, SwiftUI + AppKit (NSStatusItem + NSPopover), 외부 의존성 없음, 약 1.9k LOC, 테스트 없음.
- 구조 문제:
  - `AppDelegate` 하나가 모든 일을 하는 구조임.
  - 단축키는 `⌘⇧V` 하나만 하드코딩되어 있음.
  - 설정 창과 설정 저장소가 없음.
  - SwiftPM으로 .app을 수동 조립하고 ad-hoc 서명함.
- 클립보드 기능(약 1.3k LOC: Monitor/Store/Persistence/OCR/Views)은 독립적이라 **모듈로 그대로 이식**함. 셸은 새로 만듦 (확정).

### 2.2 Clock
- 원하는 기능은 메뉴바에 `NY 00:33` 형태(24시간, 라벨 옵션)로 표시하는 것뿐이라 약 100 LOC면 충분함.
- 권한은 필요 없음. 분이 바뀌는 시점에 맞춘 타이머 하나로 동작함.

### 2.3 Awake — 일반 잠자기 방지 vs 뚜껑 닫힘 방지

**두 기능은 다른 메커니즘임.**

| | 일반 방지 (Caffeine, KeepingYouAwake 방식) | 뚜껑 닫힘 방지 (Amphetamine CDM, eclam 방식) |
|---|---|---|
| 막는 것 | 유휴 시간이 지나 자동으로 잠드는 것 | **뚜껑을 닫으면 즉시 잠드는 것** (외부 모니터 없이) |
| API | `IOPMAssertion` (공개 API, 권한 불필요) | 시스템 전역 설정 `SleepDisabled` 또는 clamshell 상태 변경 (비공개 API) |
| 권한 | 없음 | root가 필요하거나, 비공개 user-client를 사용해야 함 |
| 앱이 죽으면 | assertion이 자동 해제되어 안전함 | **설정이 그대로 남음.** 가방 속에서 과열될 수 있으므로 워치독이 필수 |

- Caffeine과 KeepingYouAwake는 `caffeinate`/assertion만 사용함. 그래서 외부 모니터 없이 뚜껑을 닫으면 잠자기를 막지 못함 (확인됨).
- **UltraCat**은 소스가 비공개임 (저장소에는 README만 있음). README의 "helper 승인" 문구로 보아 SMAppService 데몬 방식으로 추정되지만 확인할 수 없음.
- **Amphetamine Enhancer**는 root 없이 `IOPMrootDomain` user-client에 `kPMSetClamshellSleepState`를 호출함 (비공개 API).
  - 앱이 죽었을 때를 대비해 별도 LaunchAgent가 10초마다 상태를 확인하고 복구함.
  - **macOS 26에서 동작하는지는 미검증**임.
- **eclam**은 SMAppService root 데몬 + `IOPMSetSystemPowerSetting("SleepDisabled")`를 사용함.
  - heartbeat 10초 / 20초 워치독, 시작 시 고아 상태 복원, 최대 지속시간, 배터리·열 가드를 갖춤.
  - ad-hoc 빌드도 동작하지만, 업데이트 후 헬퍼가 실행되지 않는 문제가 알려져 있음.
  - 격리 속성(quarantine)이 붙은 앱은 등록할 수 없음.

**유료 계정 없이 쓸 방식 (권장 순서)**
1. **Spike — root 없는 clamshell 호출 (Amphetamine 방식):** macOS 26에서 동작하면 비밀번호 없이 가능함. 복구용으로 사용자 LaunchAgent 워치독을 함께 씀.
2. **기본안 — 레거시 root LaunchDaemon을 1회 설치:**
   - 설치할 때 관리자 비밀번호를 **한 번** 입력받아 `/Library/LaunchDaemons`에 데몬을 둠.
   - 앱과는 Unix 소켓으로 통신하고, 연결한 쪽의 UID를 확인함. API는 on/off와 지속시간만 받음.
   - 데몬이 직접 heartbeat 워치독, 최대 지속시간, 시작 시 고아 상태 복원을 처리함.
   - Developer ID와 Login Items 승인이 필요 없어서 ad-hoc 배포에 가장 견고함.
3. 쓰지 않을 방식:
   - sudoers NOPASSWD: sudo가 약해지고 그 자체로는 복구 장치가 없음.
   - SMAppService + ad-hoc: 업데이트할 때 깨질 수 있음.
   - 토글할 때마다 비밀번호 입력: UX가 나쁨.

**✅ 채택 결과 (P3, 2026-10-19 실측):** root 없는 clamshell 호출이 macOS 27.0.1에서 **동작함**. AC와 배터리 모두에서 뚜껑을 닫고 약 3분 동안 깨어 있었음. 그래서 root 데몬 없이 구현함.
- 앱 크래시 대비: 앱 번들 안의 `AwakeGuard` 보조 프로세스를 heartbeat 파이프로 연결함.
  - 파이프가 끊기거나(앱 종료/크래시) 30초 동안 신호가 없으면(앱 멈춤) 설정을 되돌리고 종료함.
  - `kill -9` 이후 뚜껑을 닫으면 정상적으로 잠드는 것을 확인함.
- 앱 시작 시 항상 설정을 되돌린 뒤 시작함 (앱과 보조 프로세스가 함께 죽었을 경우 대비).
- `AppleClamshellCausesSleep` ioreg 값은 실제 동작을 반영하지 않음 (판단 기준으로 쓰면 안 됨).

**안전 가드 (기본값, 설정에서 변경 가능)**
- AC 미연결 상태에서 배터리 ≤ 20%이면 해제함.
- 열 상태가 `serious` 이상이면 해제함.
- 수동 모드의 지속시간은 1h / 3h / 8h / 무제한 중 선택하고 기본은 3h.
- 앱이 정상 종료되면 즉시 해제함. 앱이 죽으면 20초 안에 데몬이 해제함.

### 2.4 Awake — 에이전트 감지 (Claude / Codex / Cursor + Paseo)

**Paseo 동작 방식 (로컬에서 확인함)**
- 프로세스 구조는 `Paseo.app` → Supervisor → **Daemon(Node)**이고, 에이전트는 데몬의 자식 프로세스로 실행됨.
  - Claude는 `claude --output-format stream-json`로 실행됨.
  - Codex는 app-server로 실행됨.
  - Cursor는 `cursor-agent acp`로 실행됨 (사용자 설정에 있는 커스텀 provider).
- 에이전트별 상태 파일 `~/.paseo/agents/<cwd>/<agentId>.json`에 `lastStatus`(`initializing|running|idle|error|closed`), `lastActivityAt`, `requiresAttention`가 기록됨.
- `paseo ls --json` CLI로도 상태를 조회할 수 있음.
- Paseo로 실행한 에이전트도 **원래 위치의 transcript를 그대로 씀** (`~/.claude/projects/*.jsonl` 등).

**감지 전략 (OR 결합, 5초 주기)**
1. **Paseo:** `paseo.pid`가 있고 해당 프로세스가 살아 있으면, `~/.paseo/agents/*/*.json`에서 `lastStatus ∈ {running, initializing}`인 항목이 있는지 확인함.
   - 파일을 직접 읽는 방식이라 Node CLI를 매번 실행하는 비용이 없음. CLI는 검증용으로만 씀.
   - **`config.json`, `local-credential`, `daemon-keypair.json` 같은 비밀 파일은 절대 읽지 않음.**
2. **Transcript mtime (eclam 방식):** Paseo 밖(터미널, IDE)에서 실행한 에이전트용임.
   - 아래 파일 중 하나가 최근에 수정되었으면 "작업 중"으로 봄.
     - Claude: `~/.claude/projects/*/*.jsonl` (60초)
     - Codex: `~/.codex/sessions/*/*/*/rollout-*.jsonl` (60초)
     - Cursor: `~/.cursor/projects/*/agent-transcripts/*/*.jsonl` (90초)
   - 파일 내용은 읽지 않음.
3. **Grace:** 마지막 "작업 중" 신호 후 60초까지는 방지를 유지함 (도구 호출 사이의 짧은 공백 대응).

입력을 기다리는 상태(`idle`)는 "작업 중"으로 보지 않음.
- 권한 요청 때문에 멈춘 상태도 "작업 중"으로 봄 (확정). 자리를 비운 사이에 잠들면 안 되기 때문임. 설정에서 끌 수 있음.
  - 주의: `requiresAttention`은 `finished`(작업 완료)와 `needs_input`(입력 대기)에서도 켜짐. 그래서 **`attentionReason == "permission"`일 때만** 작업 중으로 봄.
- 감지 대상의 정의는 데이터(JSON)로 둬서 새 에이전트를 코드 수정 없이 추가할 수 있게 함.

### 2.5 Rectangle (Windows)
- 필요한 것은 `AccessibilityElement`, `ScreenDetection`, Maximize / NextPrevDisplay 계산, WindowMover이고 약 400–600 LOC임.
- Accessibility 권한이 필요함.
- 주의할 점:
  - AX와 NSScreen의 y축 방향이 반대임.
  - Dock 자동 숨김 시 visibleFrame을 보정해야 함.
  - Stage Manager 영역을 고려해야 함.
  - `AXEnhancedUserInterface`를 잠시 껐다가 리사이즈해야 함.
  - size → position → size 순서로 적용해야 함.
  - 고정 크기 창이 있음.

### 2.6 LinearMouse (Mouse) — G304 기준

| 기능 | 방식 | 권한 | 이식 규모 |
|---|---|---|---|
| 포인터 가속 끄기 / 속도 | PointerKit: **비공개** `IOHIDServiceClient` 속성 (`HIDPointerAcceleration` = -1 등) | 코드상 확인 없음 (실기기 검증 필요) | 약 250 + 적용 로직 100 |
| 스크롤 반전·선형·속도 | `CGEventTap` + 이벤트 필드 수정. 마우스와 트랙패드는 `isContinuous`로 구분 | Accessibility | 약 400 |
| 버튼 → Mission Control / 바탕화면 보기 | EventTap에서 버튼을 가로채고 **비공개** `CoreDockSendNotification("com.apple.expose.awake" / "com.apple.showdesktop.awake")` 호출 | Accessibility | **약 80** |
| **G304 배터리** | **Logitech HID++ (리시버 경유)** | 코드상 권한 요청 없음 | **약 700–900** |

**LinearMouse가 G304 배터리를 읽는 방법 → 우리도 가능함**
- G304는 LIGHTSPEED 리시버로 연결됨. 그래서 macOS 표준 배터리 속성이 없고, Logitech 전용 프로토콜 **HID++**로 직접 물어봐야 함.
- 동작 순서:
  1. 리시버(VID 0x046D, LIGHTSPEED PID C539 등)의 벤더 HID 인터페이스(usage page 0xFF00)를 `IOHIDDeviceOpen`으로 엶 (점유 모드는 쓰지 않음).
  2. 리시버의 페어링 레지스터 0xB5를 읽어 슬롯 1–6 중 마우스가 있는 슬롯을 찾음 (이름도 여기서 얻음).
  3. 해당 장치에 HID++ 2.0 기능을 다음 순서로 시도함: `0x1004 UnifiedBattery` → `0x1000 BatteryStatus` → `0x1001 BatteryVoltage`.
  4. 전압 방식이면 3.5–4.2V 구간을 선형으로 %에 매핑함 (대략적인 값이라 숫자가 튈 수 있음).
  5. 연결 시 한 번 읽고, 이후에는 장치가 보내는 배터리 알림을 수신함.
- 이식 범위:
  - LinearMouse의 `HIDPPTransport`/`Protocol`/`DeviceIO`(약 400)와 `HIDPPBatteryObservation`(245)은 복사함.
  - 최소 리시버 채널(약 200)과 경량 모니터(약 60)는 새로 작성함.
  - 6k LOC짜리 Logitech 메타데이터 DB는 **필요 없음**.
- G304가 정확히 어떤 기능 번호를 쓰는지는 소스로 확인할 수 없음. 실기기에서 검증해야 함 (Solaar 기준으로는 0x1000으로 추정).

**P5 결과 (2026-10-20 실측):** G304는 `0x1000 BatteryStatus`(슬롯 1, HID++ 4.2). 가속은 공개 simple client로, 속도(`HIDPointerResolution`)는 비공개 `IOHIDEventSystemClientCreate`로만 설정됨. 측면 버튼·스크롤·복원 모두 사용자 확인 완료.

**P5 결정 사항 (2026-10-19):** 마우스를 연결할 때까지 P5를 보류하고 P6 Cable을 먼저 진행함.
- 사용자의 LinearMouse 설정(`~/.config/linearmouse/linearmouse.json`, 수신기 `0x046d:0xc53f`)을 기본값으로 이어받음.
  - 포인터: 가속 0.9, 속도 0.08.
  - 버튼 4(앞으로): Mission Control.
- 버튼 3(뒤로): 바탕화면 보기를 새 기본값으로 함 (LinearMouse에는 아직 설정되어 있지 않았음).
- 스크롤 보정은 기본 꺼짐 (LinearMouse에서도 설정하지 않았음).
- 이벤트 탭 버그는 입력 장애로 이어질 수 있으므로 Mouse 모듈은 기본 꺼짐으로 함.

**버튼 번호:** LinearMouse 기준으로 0=좌, 1=우, 2=휠 클릭, 3=뒤로(측면), 4=앞으로(측면)임. "버튼 3·4"는 **G304의 두 측면 버튼**임 (확정). 설정에서 버튼별로 다시 매핑할 수 있음.

**원본 앱과의 충돌:** LinearMouse와 동시에 실행하면 스크롤 반전이 상쇄되고 버튼이 이중으로 발동함. 시작할 때 `com.lujjjh.LinearMouse`가 실행 중인지 감지해서 경고함. 종료할 때는 HID 속성을 원래 값으로 복원함.

### 2.7 WhatCable (Cable)
- **스택:** Swift, SwiftUI/AppKit, MIT, Apple Silicon 전용.
- **규모:** 소스 약 52k LOC. 그중 Core(UI 없음) 25k와 DarwinBackend(IOKit) 11k가 라이브러리 형태로 분리되어 있음.
- **동작 방식:**
  - 공개 IOKit 레지스트리만 읽음 (`AppleHPMInterface*`, `IOPortTransportState*`, `IOThunderbolt*`, `IOUSBHost*`).
  - 핫플러그는 이벤트로 받음.
  - root와 권한이 필요 없음.
  - 비공개 SMC 접근은 Pro 기능 전용이라 제외함.
- **통합 방식 (확정):** Core + DarwinBackend를 **수정 없이 벤더링**하고 git subtree로 업스트림을 추적함.
  - 그 위에 얇은 모듈 래퍼와 경량 UI를 새로 작성함.
  - 위젯, Pro, CLI, 알림, 진단 업로드는 제외함.
- **한계:**
  - e-marker 칩이 없는 케이블은 정보가 없음.
  - "케이블이 병목" 판정은 휴리스틱임.
  - 비공개 레지스트리 이름에 의존하므로 macOS가 업데이트되면 깨질 수 있음.
  - macOS 26에서 동작하는지 미검증임.

---

## 3. 기술적 가능성 · 리스크 · 한계

### 전제
1. **비샌드박스**여야 함 (AX, EventTap, HID SPI, root 데몬). 따라서 App Store 배포는 불가함.
2. **유료 계정 없이 배포함:**
   - 앱은 **자체 서명 인증서**로 일관되게 서명함. ad-hoc으로 서명하면 빌드할 때마다 서명이 바뀌어 Accessibility 권한이 초기화됨.
   - 친구는 처음 설치할 때 `xattr -dr com.apple.quarantine /Applications/T-Utilities.app`(또는 우클릭 → 열기)를 해야 함. 앱이 노터라이즈되지 않았기 때문임.
   - 자체 서명 인증서로 서명하면 서명 신원이 인증서 해시에 고정되어, 재빌드 후에도 TCC 권한이 유지됨 (**개발 Mac에서 검증 완료**, 2026-10-19). 친구 Mac에서도 같을 것으로 예상하지만 P7에서 확인함.
   - 뚜껑 닫힘 방지용 데몬은 설치할 때 관리자 비밀번호를 한 번 입력받음.

### 리스크

| # | 리스크 | 영향 | 대응 |
|---|---|---|---|
| R1 | 비공개 API (HID 포인터 속성, CoreDock, clamshell/SleepDisabled, Cable 레지스트리) | macOS 업데이트 때 해당 기능이 깨짐 | 모듈 단위로 격리하고 실패하면 해당 기능만 비활성화 + 배지 표시. 원본 프로젝트의 수정을 추적 |
| R2 | 뚜껑 닫힘 방지 상태가 남음 | 가방 속에서 과열되고 배터리가 방전됨 | root 데몬 워치독(heartbeat 20초), 최대 지속시간, 배터리·열 가드, 데몬 시작 시 복원 |
| R3 | root 데몬의 보안 | 같은 사용자 권한의 악성코드가 잠자기를 조작할 수 있음 | API를 on/off와 지속시간으로만 제한하고 UID를 확인. 데몬 바이너리는 root 소유 경로에 둠 |
| R4 | 단일 프로세스에 EventTap과 AX가 있음 | 콜백이 지연되면 입력이 렉 걸림. 크래시 하나로 전체가 죽음 | Tap은 전용 스레드에서 돌리고 비활성화 감지 워치독을 둠. 모듈 시작 실패를 격리 |
| R5 | 원본 앱과 동시 실행 | 이중 적용이 생김 | 원본 앱 감지 + 안내 |
| R6 | 단축키 충돌 | 단축키가 동작하지 않음 | 중앙 레지스트리 + 녹화 UI + 충돌 표시 |
| R7 | WhatCable 벤더 코드가 큼 (약 36k) | 빌드 시간과 앱 크기가 늘어남 | 별도 패키지로 두고, 모듈을 끄면 watcher와 DB를 로드하지 않음 |
| R8 | 서명 없는 배포 | 친구가 설치할 때 마찰이 생기고 권한이 재설정될 수 있음 | 설치 가이드 + 설치 스크립트. 인증서를 일관되게 유지 |
| R9 | 테스트 부족 | 회귀 | 순수 로직(창 좌표, 스크롤 변환, 배터리 디코드, 에이전트 판정, 시계 포맷)부터 단위 테스트 |

### 한계 (수용)
- G304의 배터리 %는 전압을 선형으로 환산하는 방식이면 부정확할 수 있음.
- 스크롤에서 마우스와 트랙패드는 `isContinuous` 휴리스틱으로만 구분함.
- 에이전트 감지는 "이 Mac에서 도는 에이전트"만 대상으로 함. Paseo 데몬을 원격 호스트에 붙였다면 감지하지 못함.
- 모듈을 꺼도 **코드 자체는 바이너리에 남음**. 해제되는 것은 인스턴스, 탭, 워처, 캐시, 리소스(DB)임 (§4.3).

---

## 4. 아키텍처

> 현재 적용되는 모듈 규칙, 검사 방법, 새 모듈 추가 절차는 **[Docs/MODULES.md](Docs/MODULES.md)** 를 따릅니다. 아래는 최초 설계 기록입니다.

### 4.1 프로젝트 구조
- **XcodeGen**(`project.yml`)으로 앱 타깃과 데몬 타깃을 만듦. 모듈은 **로컬 SPM 패키지**로 분리함.

```
T-Utilities/
├─ project.yml
├─ App/                         # 셸: AppDelegate, StatusItem, Popover, SettingsWindow, Onboarding
├─ Packages/
│  ├─ TUCore/                   # TUModule 프로토콜, ModuleRegistry, HotkeyRegistry, Settings, Permissions, Logger
│  ├─ TUUI/                     # 공통 컴포넌트 (섹션 카드, 토글 행, 단축키 레코더, 상태 배지, 서브메뉴 패널)
│  ├─ ModClipboard/             # CopyNinja 이식
│  ├─ ModClock/
│  ├─ ModAwake/                 # 모드, 에이전트 감지, 가드, 데몬 클라이언트
│  ├─ ModWindows/               # Rectangle 일부
│  ├─ ModMouse/                 # PointerKit 일부, EventTap, DockKit, HID++ 배터리
│  └─ ModCable/                 # WhatCable 래퍼 + 경량 UI
├─ Vendor/WhatCable/            # Core + DarwinBackend (수정 없음, git subtree)
├─ App/AwakeGuard/              # 뚜껑 닫힘 방지 fail-safe 보조 프로세스 (root 불필요)
├─ Scripts/                     # 서명, 패키징, 친구용 설치 스크립트
└─ THIRD_PARTY_NOTICES.md
```

### 4.2 모듈 계약
```swift
@MainActor
protocol TUModule: AnyObject {
    // 정적 메타데이터 — 모듈이 꺼져 있어도 설정 UI에 표시
    static var id: String { get }
    static var displayName: String { get }
    static var symbol: String { get }
    static var requiredPermissions: Set<Permission> { get }

    init(context: ModuleContext)       // 설정 저장소, 단축키 레지스트리, 로거 주입
    func start() async throws
    func stop() async                  // 탭/워처/타이머/캐시 모두 해제해야 함

    var status: ModuleStatus { get }   // running / needsPermission / degraded(String) / error(String)
    var hotkeys: [HotkeyDefinition] { get }
    var statusItemAccessory: AnyView? { get }  // 메뉴바 아이콘 옆 텍스트 (Clock)
    var popoverSection: AnyView? { get }       // 팝오버 섹션
    var settingsView: AnyView { get }
}
```

### 4.3 활성화 / 순서 / 메모리 해제
- `ModuleRegistry`는 **모듈 타입(팩토리) 목록**만 항상 들고 있음. 인스턴스는 활성화할 때 생성함.
- **비활성화** 순서:
  1. `stop()`을 호출함.
  2. 단축키 등록과 상태 구독을 해제함.
  3. 팝오버와 메뉴바에서 해당 뷰를 제거함.
  4. **인스턴스 참조를 nil로 만듦** → deinit.
- 모듈 규칙:
  - 무거운 리소스(WhatCable DB, 클립보드 이미지 캐시, HID 매니저, EventTap)는 `start()`에서 만들고 `stop()`에서 해제함.
  - 정적(static) 싱글톤을 금지함 (CopyNinja의 `HotKeyManager.shared` 같은 것은 이식할 때 제거).
- **검증 방법:**
  - 디버그 빌드에서 모듈 인스턴스의 weak 참조가 비활성화 후 nil이 되는지 assert함.
  - 모듈을 켜고 끈 뒤 `footprint`나 Instruments로 메모리가 기준선 근처로 돌아오는지 확인함.
- **순서:** 설정의 "팝오버" 페이지에서 드래그로 순서를 바꿈. `[moduleId]` 배열로 저장함.
- 설정 파일 위치: `UserDefaults` 도메인 `com.taegyu.tutilities`, 키는 `modules.enabled`, `modules.order`, `module.<id>.*`.

### 4.4 공통 서비스
- **Hotkey:** `sindresorhus/KeyboardShortcuts` (MIT, 녹화 UI 포함).
- **Settings:** `@AppStorage` / `Defaults`.
- **Permissions:** Accessibility와 Input Monitoring 상태를 중앙에서 조회함. 해당 모듈을 처음 켤 때만 요청함.
- **Launch at login:** `SMAppService.mainApp`. ad-hoc이나 자체 서명에서도 되는지 P0에서 검증하고, 안 되면 LaunchAgent plist로 대체함.
- **EventTap 공유:** Mouse 모듈 안에 탭 하나를 두고, 스크롤과 버튼 처리기를 체인으로 연결함.
- **로그:** `os.Logger`, 모듈별 카테고리.
- **업데이트:** 처음에는 수동(GitHub Releases + 설치 스크립트). 필요하면 나중에 Sparkle(EdDSA, Developer ID 없이도 동작)을 추가함.

---

## 5. UI 레이아웃 & 스타일

### 5.1 원칙
- 네이티브 macOS 26 스타일 (SwiftUI, SF Symbols, 시스템 accent, 라이트/다크 자동). 커스텀 테마는 만들지 않음.
- **메뉴바 아이템은 1개**: `[메인 아이콘] NY 00:33`
  - 메인 아이콘은 **Awake 상태 표시기**임 (디자인은 미정, §5.6).
  - 시간 텍스트는 Clock 모듈이 붙이는 accessory임. Clock을 끄면 아이콘만 남음.
- 무거운 정보(Cable)는 팝오버 본문에 펼치지 않고 **서브메뉴 패널**에서 보여줌.

### 5.2 메뉴바
```
 … [☕︎ NY 00:33] …
     └ Awake 상태에 따라 아이콘이 바뀜 (끔 / 수동 / 자동-대기 / 자동-작업중 / 뚜껑닫힘 활성)
```
- **좌클릭:** 팝오버.
- **우클릭:** 빠른 메뉴 (Awake 끔/수동/자동, 설정…, 종료).

### 5.3 메인 팝오버 (폭 약 360, 섹션 스택 — 순서와 표시는 설정 따름)
```
┌────────────────────────────────────────┐
│ ☕ Awake        [ 끔 | 수동 | 자동 ]     │  ← Awake 섹션
│    자동 · Claude(Paseo) 작업 중 · 뚜껑닫힘 ✓ │
├────────────────────────────────────────┤
│ 🖱 G304          ▮▮▮▮▯ 72%              │  ← Mouse 섹션 (배터리만 표시)
├────────────────────────────────────────┤
│ 🔌 USB-C   2개 연결 · 96W 충전 ⚡        ›│  ← Cable 섹션: 한 줄 요약 → 서브메뉴
├────────────────────────────────────────┤
│ 📋 Clipboard                            │  ← Clipboard 섹션 (남는 높이를 사용)
│ 🔍 Search…                              │
│ 1  copied text preview …                │
│ 2  🖼 image                              │
│ …                                       │
├────────────────────────────────────────┤
│ ⚙︎ 설정                         ⌘⇧V     │
└────────────────────────────────────────┘
```
- 섹션의 순서와 표시는 설정의 "팝오버" 페이지를 따름. 비활성 모듈은 섹션 자체가 없음.
- Clipboard 섹션은 가변 높이로 남는 공간을 사용하고, 나머지는 고정된 한두 줄임. 팝오버 높이는 내용에 맞추되 최대 약 600까지임.
- `⌘⇧V`(재지정 가능)를 누르면 팝오버를 열고 Clipboard 검색창에 포커스를 줌.
- Windows 모듈은 UI가 없는 백그라운드 모듈이라 팝오버 섹션이 없음.

### 5.4 Cable 서브메뉴 패널
macOS 메뉴의 서브메뉴처럼, Cable 행에 호버하거나 클릭하면 **팝오버 옆에 붙는 보조 패널(NSPanel)**이 열림.
```
 팝오버                      서브메뉴 패널 (폭 약 320)
 🔌 USB-C … ›  ──────▶  ┌──────────────────────────────┐
                        │ 왼쪽 포트 1 · 충전 96W         ›│
                        │ 왼쪽 포트 2 · TB4 40Gb/s       ›│
                        │ 오른쪽 포트 · 비어 있음          │
                        │ ───────────────────────────── │
                        │ Thunderbolt 토폴로지           ›│
                        │ 디스플레이                      ›│
                        └──────────────────────────────┘
                              │ 항목을 클릭하면 같은 패널 안에서 상세로 이동 (← 뒤로)
                              ▼
                        ┌──────────────────────────────┐
                        │ ← 왼쪽 포트 1                 │
                        │ 충전: 96W 중 60W 사용 — 케이블 병목 │
                        │ 케이블: 100W(5A) · USB 3.2 · e-marker│
                        │ 충전기 PDO: 5V3A / 9V3A / 20V4.8A* │
                        │ 장치: …                        │
                        └──────────────────────────────┘
```
- 패널이 열려 있는 동안만 WhatCable 스냅샷을 구독함. 닫히면 구독을 해제하고, 백그라운드에서는 한 줄 요약만 유지함.
- 상세 화면은 섹션을 접고 펼 수 있음 (Disclosure).

### 5.5 설정 창 (NavigationSplitView, 약 720×520)
```
┌──────────────┬────────────────────────────────────────┐
│ 일반          │  팝오버                                  │
│ 팝오버         │  ─────────────────────────────────────  │
│ 권한          │  ≡ ☕ Awake        [● 켜짐]               │
│ ──────────── │  ≡ 🖱 Mouse        [● 켜짐]               │
│ ☕ Awake  🟢  │  ≡ 🔌 Cable        [● 켜짐]               │
│ 🕘 Clock  🟢  │  ≡ 📋 Clipboard    [● 켜짐]               │
│ 📋 Clipboard🟢│  ── 팝오버 섹션 없음 ──                     │
│ 🪟 Windows 🟡 │     🕘 Clock (메뉴바)  [● 켜짐]            │
│ 🖱 Mouse  🟢  │     🪟 Windows        [○ 꺼짐]            │
│ 🔌 Cable  ⚪️  │  ≡ 드래그로 순서 변경 · 끄면 메모리 해제         │
└──────────────┴────────────────────────────────────────┘
```
- **팝오버 페이지:** 모든 모듈의 활성화 토글과 팝오버 섹션 순서를 한곳에서 관리함 (위 와이어프레임).
- **권한 페이지:** Accessibility 등 권한 상태, "시스템 설정 열기", 뚜껑 닫힘 데몬 설치/제거.
- **일반 페이지:** 로그인 시 실행, 단축키 목록(충돌 표시), 원본 앱 충돌 감지.
- **모듈 페이지:**
  - 페이지 위에 켜짐 토글을 두고, 사이드바에는 상태 배지를 표시함 (🟢 동작 / 🟡 권한 필요 / ⚪️ 꺼짐 / 🔴 오류).
  - **Clock:** 타임존 선택, 라벨 표시 on/off, 라벨 텍스트 (기본은 도시 약어, 예: `NY`).
  - **Awake:**
    - 자동 모드 감지 대상 체크 (Claude / Codex / Cursor / Paseo), grace 시간.
    - 뚜껑 닫힘 방지 on/off.
    - 가드 (배터리 %, 열, 최대 지속시간).
  - **Mouse:**
    - 가속 끄기, 속도.
    - 스크롤 반전·선형·줄 수.
    - 버튼 매핑 (기본: 버튼 3 → Mission Control, 버튼 4 → 바탕화면 보기).
    - 배터리 표시.

### 5.6 스타일 가이드
- 폰트는 시스템 기본이고, 숫자(시계, 배터리, W)는 `.monospacedDigit()`를 씀.
- 설정 화면은 `Form` + `.formStyle(.grouped)`를 씀.
- 팝오버 섹션은 공통 `SectionRow`(아이콘 · 제목 · 우측 값 · chevron)를 씀.
- 아이콘은 SF Symbols만 씀: `doc.on.clipboard`, `clock`, `computermouse`, `macwindow`, `cable.connector`, `cup.and.saucer`.
- 색은 accent와 상태색(green/yellow/red)만 씀.
- **메인 아이콘 (미정, 후보):**
  - 끔: `cup.and.saucer`
  - 수동: `cup.and.saucer.fill`
  - 자동-대기: `cup.and.saucer` + 작은 점
  - 자동-작업중: `cup.and.heat.waves.fill`
  - 뚜껑닫힘 활성: 우하단 배지 추가
  - 최종 디자인은 P2에서 결정함.

---

## 6. 단계별 로드맵

| Phase | 내용 | 완료/검증 기준 | 규모(LOC) |
|---|---|---|---|
| **P0 셸** | XcodeGen, 자체 서명 인증서, ModuleRegistry(팩토리/활성화/순서), 팝오버 섹션 스택, 설정 창(일반/팝오버/권한), 단축키 레지스트리 | 더미 모듈 2개로 켜기/끄기, 순서 변경, 끈 뒤 weak 참조가 nil이 되는지 확인. 재빌드 후 AX 권한이 유지되고 로그인 시 실행이 동작함 | 약 900 |
| **P1 Clipboard** | CopyNinja 이식 (싱글톤, 브랜딩, 업데이터 제거) | CopyNinja 기능 체크리스트 100%. 비활성화 시 이미지 캐시가 해제됨 | 약 1.3k |
| **P2 Clock + Awake 기본** | `NY 00:33` accessory, 수동·자동·끔 (IOPMAssertion), Paseo + transcript 감지, 메인 아이콘 상태 | Paseo에서 Claude가 실행 중일 때 `pmset -g assertions`에 표시되고, idle이 된 뒤 grace 후 해제됨. 감지 판정 단위 테스트 | 약 100 + 약 600 |
| **P3 뚜껑 닫힘 방지** ✅ | root 없는 clamshell 호출 + `AwakeGuard` fail-safe, 배터리/열 가드 | 배터리 상태에서 뚜껑을 닫고 약 3분 유지됨. `kill -9` 후 잠듦. 자동 모드 해제 시 뚜껑이 닫혀 있으면 잠듦 (모두 실측 완료) | 약 300 |
| **P4 Windows** | Maximize, Next/Prev Display | 좌표 변환 단위 테스트. 2모니터와 서로 다른 배율에서 확인 | 약 500 |
| **P5 Mouse** | 가속/속도, 스크롤 반전·선형·속도, 측면 버튼 → Mission Control / 바탕화면 보기, G304 HID++ 배터리 | LinearMouse를 끈 상태에서 같은 체감. 종료 시 HID 속성 복원. G304 배터리가 LinearMouse 값과 일치함 | 약 1.8k |
| **P6 Cable** | WhatCable 벤더링, 한 줄 요약 + 서브메뉴 패널 (포트/케이블/충전/TB 토폴로지/디스플레이) | 원본 WhatCable과 같은 판정이 나옴. 벤더 테스트 통과. 모듈을 끄면 watcher가 0개가 됨 | 약 1.5k (+벤더 36k) |
| **P7 친구 배포** | 패키징 스크립트, 설치 가이드(quarantine 해제, 권한), 버전 표기 | 깨끗한 다른 Mac에서 가이드대로 설치하고 모든 모듈이 동작함 | — |

> 순서 근거: 매일 쓰는 것(Clipboard, Clock, Awake)을 먼저 함. **가장 위험한 P3는 일찍 해서** 실패하면 방향을 바꿀 수 있게 함. 그다음 Windows → Mouse → Cable 순으로 진행함.

---

## 7. 결정 기록 (1차 피드백)
1. 베이스 전략: 새 셸 + 클립보드 이식 ✅
2. 유료 계정 없음, 본인/친구용 → 자체 서명 + 수동 배포 ✅
3. macOS 26+ ✅
4. 뚜껑 닫힘 방지 필요. 자동 감지 대상은 Claude/Codex/Cursor + Paseo ✅
5. G304, 측면 버튼 → Mission Control / 바탕화면 보기, 스무스 스크롤 불필요. 배터리는 HID++로 지원 ✅
6. Clock: 24h 1개, 라벨 옵션 ✅
7. 메뉴바 = 메인 아이콘(Awake 상태, 디자인 미정) + 시간. 이름과 번들 ID는 권장안대로 ✅
8. (7번과 같은 질문이었음 — 해결)
9. Cable: TB 토폴로지와 디스플레이 포함, 알림 없음, 벤더링 ✅
- UI: 팝오버의 순서와 활성화를 설정에서 변경하고, 비활성화 시 메모리 해제 ✅
- UI: Cable은 서브메뉴 패널 ✅
- Share 제외 ✅

## 8. 결정 기록 (2차 피드백)
1. 버튼 3·4 = G304 측면 두 버튼 ✅
2. 뚜껑 닫힘 방지: root 없는 방식을 먼저 시도하고, 실패하면 관리자 비밀번호 1회 입력으로 root 데몬 설치 ✅
3. 안전 가드 기본값: 배터리 20% 미만 해제 / 열 serious 이상 해제 / 수동 기본 3시간 ✅
4. 권한 요청 대기 중인 에이전트(`requiresAttention`)도 작업 중으로 보고 잠자기 방지 ✅

---

## 부록 A. 향후 후보 — Share (LocalSend)
- 프로토콜 v2:
  - 탐색: UDP 멀티캐스트 `224.0.0.167:53317`.
  - 전송: 자체 서명 HTTPS, SHA-256 지문으로 확인.
  - REST: `register`, `prepare-upload`, `upload`, `cancel`.
- 네이티브 Swift 구현은 약 1.2–1.8k LOC로 예상함. 가장 어려운 부분은 TLS 서버임.
- Local Network 권한이 필요함.
- 모듈 구조상 나중에 `ModShare` 패키지와 팝오버 섹션을 추가하는 것만으로 붙일 수 있음.

## 부록 B. CPU · 메모리 최적화 리뷰용 요약 (P7 시점, v0.1.0)

> **최신 내용은 [Docs/OPTIMIZATION.md](Docs/OPTIMIZATION.md)** (v0.1.2 기준, 측정 스크립트 `Scripts/measure.sh` 포함). 아래는 v0.1.0 시점 기록.

별도 세션의 최적화 리뷰를 위한 입력 자료. 기준 측정(Debug 빌드, 모든 기본 모듈 활성, 유휴): `footprint` phys_footprint ≈ 48 MB, CPU 0.0%.

### B-1. 모듈 구조
- 앱 셸(`App/Sources`): `AppDelegate` → `ModuleRegistry`(TUCore) + `StatusItemController`(NSStatusItem + NSPopover, SwiftUI `PopoverView`) + `SettingsWindowController`(첫 표시 때 생성, 창은 닫아도 유지 `isReleasedWhenClosed=false`) + `Updater`.
- 모듈 = 로컬 SPM 패키지, `TUModule` 프로토콜. 레지스트리가 활성화 시 인스턴스 생성 → `start()`, 비활성화 시 `stop()` → 참조 해제 → 2초 뒤 weak 참조로 누수 검사(로그).
- 모듈: Clipboard(CopyNinja 이식), Awake(+ `AwakeGuard` 헬퍼 프로세스), Clock, Windows(Rectangle 일부), Cable(WhatCable vendored subtree). Mouse(`ModMouse`, 기본 꺼짐): 포인터 속성(비공개 admin HID 클라이언트), 세션 이벤트 탭(측면 버튼·휠), HID++ 배터리.

### B-2. 주기 작업 · 상주 리소스
| 위치 | 주기 | 내용 | 비고 |
|---|---|---|---|
| `ClipboardMonitor` | 0.5 s, DispatchSourceTimer(utility 큐) | `NSPasteboard.changeCount` 비교, 변경 시에만 읽기 | 가장 잦은 wakeup. 이미지/OCR은 변경 시 1회 |
| `AwakeModule` tick | 5 s | 정책 평가; 자동 모드면 `AgentDetector` 실행 | Detector: Paseo pid/agents JSON 읽기 + 3개 glob(`~/.claude/projects/*/*.jsonl`, `~/.codex/sessions/*/*/*/rollout-*.jsonl`, `~/.cursor/projects/*/agent-transcripts/*/*.jsonl`) 각 파일 `stat`. 세션 파일 수에 비례 — 리뷰 1순위 |
| `LidSleepGuard` heartbeat | 10 s | AwakeGuard 파이프에 1바이트 | 뚜껑 닫힘 방지 활성 중에만 헬퍼 존재 |
| `AwakeGuard` (별도 프로세스) | poll 30 s | stdin EOF/무응답 시 복원 후 종료 | |
| `ClockModule` | 분 경계 1회 | 메뉴바 텍스트 갱신 | |
| `CableModule` | 15 s + 팝오버 열 때 | WhatCable `snapshot()` 전체(IOKit 레지스트리 순회) + `PortReport` 빌드, 요약 계산 시 `CableSnapshotContext` 2회 생성 | 무거운 편. 이벤트 기반(WhatCable watcher) 전환 또는 주기 완화 후보 |
| `MouseModule` (켜져 있을 때만) | 이벤트 | 세션 이벤트 탭(otherMouse·scrollWheel, 메인 런루프) — 모든 휠/측면 버튼 이벤트가 통과 | 콜백은 짧은 분기만 |
| `MouseModule` 탭 감시 | 3 s | 임시 이벤트 탭 생성 후 즉시 해제(백그라운드) — 권한 상실 시 탭 제거 | 권한 상실 시 전체 입력 멈춤 방지용, 생략 불가 |
| `MouseModule` 배터리 | 300 s + 장치 알림 | HID++ 요청(리시버 경유, 1 s 타임아웃) | 장치 연결 변경 시 1 s 뒤 재적용 |
| `Updater` | 1 h 확인 → 실제 네트워크는 24 h 1회 | GitHub API | |
| 설정 화면(권한/Clipboard/Windows 페인) | 1 s | TCC 권한 폴링 | 해당 뷰가 보일 때만 (`.task`) |
| `StatusItemController` | 이벤트 | 로컬 keyDown 모니터(앱 내부 이벤트만) | |

### B-3. 메모리 관련 포인트
- Clipboard: 히스토리 JSON + 이미지 파일(`~/Library/Application Support/T-Utilities/Clipboard/`), `ImageCache`(메모리 캐시) — 상한/해제 정책 확인 필요. 팝오버 리스트(높이 380) 썸네일 디코딩.
- Cable: WhatCable `DarwinSnapshotProvider`의 static watcher 상태가 모듈 비활성화 후에도 남음(알려진 한계).
- SwiftUI `NSHostingView`가 Cable 서브메뉴 표시마다 새로 생성됨.
- Awake 아이콘은 템플릿 이미지 캐시(정적).
- 비활성화 시 해제 검증: P0에서 109→47 MB 확인. 이후 추가된 모듈은 누수 검사 로그만 존재.

### B-4. 알려진 한계 (리뷰 범위 밖이지만 참고)
- P4(외부 모니터 Windows) · P5(Mouse) 하드웨어 테스트 완료 (2026-10-20).
- Windows: Dock/Stage Manager 보정 없음.
- Windows: 수정키(기본 ⌥) + 드래그 이동 / 우클릭 드래그 리사이즈(easy-move-resize 아이디어, Issue #4). 실제 이벤트 탭 동작은 실기기 수동 확인 필요.
- 업데이트 설치는 로컬에서 엔드투엔드 미검증(첫 릴리스 이후 확인 필요).
- Release 빌드는 arm64 전용.
