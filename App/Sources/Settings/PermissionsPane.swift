import SwiftUI
import TUCore

struct PermissionsPane: View {
    let registry: ModuleRegistry
    let permissions: PermissionCenter

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases, id: \.self) { permission in
                    let users = registry.visibleDescriptors.filter { $0.requiredPermissions.contains(permission) }
                    LabeledContent {
                        if permissions.isGranted(permission) {
                            Label("허용됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("허용하기…") { permissions.request(permission) }
                        }
                    } label: {
                        Text(permission.displayName)
                        Text(users.isEmpty ? "사용하는 모듈 없음" : users.map(\.displayName).joined(separator: ", "))
                    }
                }
            } footer: {
                Text("권한은 해당 모듈을 처음 켤 때 요청됩니다. 시스템 설정에서 허용한 뒤 이 화면으로 돌아오면 갱신됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("권한")
        // TCC has no change notification; poll only while this pane is visible.
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
