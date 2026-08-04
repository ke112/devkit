import SwiftUI

// Loading状态视图
struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 8) {
                Text("正在加载模拟器设备...")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("初次启动可能需要几秒钟时间")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(40)
    }

}

// 空状态视图
struct EmptyStateView: View {
    let onRefresh: () -> Void
    var isAutoRefreshPaused: Bool = false
    var refreshFailureMessage: String? = nil

    var body: some View {
        VStack(spacing: 24) {
            // 空状态图标
            VStack(spacing: 16) {
                Image(systemName: refreshFailureMessage == nil ? "iphone.slash" : "exclamationmark.triangle")
                    .font(.system(size: 60))
                    .foregroundColor(.gray.opacity(0.6))

                VStack(spacing: 8) {
                    Text(refreshFailureMessage == nil ? "暂无可用的模拟器设备" : "无法获取模拟器列表")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    if let refreshFailureMessage {
                        Text("\(refreshFailureMessage)\n\n完成设置后点击下方刷新按钮重新检测。")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                    } else if isAutoRefreshPaused {
                        Text("自动刷新已暂停（CoreSimulator 可能异常）\n请点击下方刷新按钮尝试恢复")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                    } else {
                        Text("请在 Xcode 中创建 iOS 模拟器设备，\n或点击刷新重新检测设备")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                    }
                }
            }

            // 操作按钮
            HStack(spacing: 12) {
                // 刷新按钮
                Button(action: onRefresh) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // 打开Xcode按钮
                Button(action: {
                    // 打开Xcode
                    if let url = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: "com.apple.dt.Xcode")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("打开 Xcode")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
    }
}

struct EmptyRuntimeGroupView: View {
    let runtimeName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已安装 \(runtimeName) Runtime，但当前还没有模拟器设备。")
                .font(.subheadline)
                .foregroundColor(.primary)

            Text("点击右上角 + 可为该版本创建常用模拟器。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
    }
}

// 简单的吐司通知视图
struct ToastView: View {
    let message: String
    @Binding var isShowing: Bool

    var body: some View {
        VStack {
            Text(message)
                .padding()
                .background(Color.black.opacity(0.7))
                .foregroundColor(Color.white)
                .cornerRadius(10)
                .padding(.horizontal, 20)
        }
        .onAppear {
            // 2秒后自动隐藏
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                withAnimation {
                    isShowing = false
                }
            }
        }
    }
}

// 主界面布局UI
struct SimulatorManagementView: View {
    @StateObject private var simulatorManager = SimulatorManager()
    @State private var showingToast = false
    @State private var toastMessage = ""
    @State private var showingCreateOptions = false
    @State private var showingDeleteConfirm = false
    @State private var runtimeToCreate: SimulatorManager.DeviceGroup? = nil
    @State private var runtimeToDelete: SimulatorManager.DeviceGroup? = nil

    var body: some View {
        /// 设备列表（分组显示）
        ZStack {
            // 主内容区域
            if simulatorManager.isLoading {
                // Loading状态
                LoadingView()
            } else if simulatorManager.deviceGroups.isEmpty {
                // 空状态
                EmptyStateView(onRefresh: {
                    simulatorManager.manualResumeAutoRefresh()
                }, isAutoRefreshPaused: simulatorManager.isAutoRefreshPaused,
                   refreshFailureMessage: simulatorManager.refreshFailureMessage)
            } else {
                // 设备列表
                List {
                    ForEach(simulatorManager.deviceGroups) { group in
                        let isDeletingRuntime = simulatorManager.deletingRuntimeIdentifier == group.runtime
                        let deleteProgressText =
                            simulatorManager.deletingRuntimeIncludesRuntime
                            ? "正在彻底删除..."
                            : "正在删除模拟器..."

                        Section(header: 
                            HStack {
                                Text(group.displayName)
                                    .font(.headline)

                                if isDeletingRuntime {
                                    ProgressView()
                                        .controlSize(.small)

                                    Text(deleteProgressText)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()
                                Button(action: {
                                    simulatorManager.showSimulatorsInFinder(for: group.runtime)
                                }) {
                                    Image(systemName: "folder")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(group.devices.isEmpty || isDeletingRuntime)
                                .help(
                                    isDeletingRuntime
                                        ? deleteProgressText
                                        : group.devices.isEmpty
                                        ? "当前版本还没有模拟器目录"
                                        : "Show simulators in Finder")

                                // 创建模拟器按钮
                                Button(action: {
                                    runtimeToCreate = group
                                    showingCreateOptions = true
                                }) {
                                    Image(systemName: "plus.circle")
                                        .font(.caption)
                                        .foregroundColor(.green.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .disabled(isDeletingRuntime)
                                .help(isDeletingRuntime ? deleteProgressText : "选择要创建的模拟器范围")
                                
                                // 删除按钮
                                Button(action: {
                                    runtimeToDelete = group
                                    showingDeleteConfirm = true
                                }) {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundColor(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .disabled(isDeletingRuntime)
                                .help(
                                    isDeletingRuntime
                                        ? deleteProgressText
                                        : group.devices.isEmpty
                                        ? "彻底删除该版本 Runtime 镜像"
                                        : "删除该版本的模拟器或 Runtime")
                            }
                        ) {
                            if group.devices.isEmpty {
                                EmptyRuntimeGroupView(runtimeName: group.displayName)
                            } else {
                                ForEach(group.devices) { device in
                                    DeviceRow(
                                        device: device,
                                        simulatorManager: simulatorManager,
                                        showToast: { message in
                                            toastMessage = message
                                            withAnimation {
                                                showingToast = true
                                            }
                                        })
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }

            // 显示错误提示
            if simulatorManager.hasError, let errorMessage = simulatorManager.lastError {
                VStack {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                        
                        Spacer()
                        
                        Button("关闭") {
                            simulatorManager.clearError()
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal, 16)
                    
                    Spacer()
                }
            }
            
            // 显示吐司提示
            if showingToast {
                VStack {
                    Spacer()
                    ToastView(message: toastMessage, isShowing: $showingToast)
                    Spacer().frame(height: 50)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("iOS 模拟器管理")
        .onAppear {
            simulatorManager.start()
        }
        .onDisappear {
            simulatorManager.stop()
        }
        .confirmationDialog(
            "添加 \(runtimeToCreate?.displayName ?? "") 模拟器",
            isPresented: $showingCreateOptions,
            titleVisibility: .visible
        ) {
            Button("添加主流机型") {
                if let group = runtimeToCreate {
                    simulatorManager.createDevices(for: group.runtime, mode: .popular)
                    toastMessage = "正在为 \(group.displayName) 添加主流模拟器..."
                    withAnimation {
                        showingToast = true
                    }
                }
                runtimeToCreate = nil
            }
            Button("添加全部支持设备") {
                if let group = runtimeToCreate {
                    simulatorManager.createDevices(for: group.runtime, mode: .all)
                    toastMessage = "正在为 \(group.displayName) 添加全部支持设备..."
                    withAnimation {
                        showingToast = true
                    }
                }
                runtimeToCreate = nil
            }
            Button("取消", role: .cancel) {
                runtimeToCreate = nil
            }
        } message: {
            Text("你可以只添加常用主流机型，或一次性添加该版本支持的全部 iPhone / iPad 模拟器。")
        }
        .confirmationDialog(
            "删除 \(runtimeToDelete?.displayName ?? "") 版本",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            if let group = runtimeToDelete, !group.devices.isEmpty {
                Button("仅删除模拟器设备", role: .destructive) {
                    simulatorManager.deleteDevicesForRuntime(group.runtime, deleteRuntime: false) {
                        success in
                        toastMessage =
                            success
                            ? "已删除 \(group.displayName) 的 \(group.devices.count) 个模拟器"
                            : "删除 \(group.displayName) 时出现问题"
                        withAnimation {
                            showingToast = true
                        }
                    }
                    toastMessage = "正在删除 \(group.displayName) 的 \(group.devices.count) 个模拟器..."
                    withAnimation {
                        showingToast = true
                    }
                    runtimeToDelete = nil
                }
            }
            Button("彻底删除（含 Runtime 镜像）", role: .destructive) {
                if let group = runtimeToDelete {
                    simulatorManager.deleteDevicesForRuntime(group.runtime, deleteRuntime: true) {
                        success in
                        toastMessage =
                            success
                            ? "已彻底删除 \(group.displayName) 及其 Runtime"
                            : "彻底删除 \(group.displayName) 时出现问题"
                        withAnimation {
                            showingToast = true
                        }
                    }
                    toastMessage = "正在彻底删除 \(group.displayName) 及其 Runtime..."
                    withAnimation {
                        showingToast = true
                    }
                }
                runtimeToDelete = nil
            }
            Button("取消", role: .cancel) {
                runtimeToDelete = nil
            }
        } message: {
            if let group = runtimeToDelete {
                if group.devices.isEmpty {
                    Text("当前没有模拟器设备，只剩 \(group.displayName) Runtime 镜像。\n\n彻底删除会卸载该 Runtime 并释放约 5-10GB 空间。")
                } else {
                    Text("共 \(group.devices.count) 个设备\n\n• 仅删除设备：删除模拟器及其数据\n• 彻底删除：同时删除 iOS Runtime 镜像（释放 5-10GB 空间）")
                }
            }
        }
    }
}

// 设备行视图组件
struct DeviceRow: View {
    let device: SimulatorDevice
    let simulatorManager: SimulatorManager
    let showToast: (String) -> Void
    @State private var showingResetConfirm = false
    @State private var showingRecreateConfirm = false
    @State private var showingDeleteConfirm = false

    var body: some View {
        let isDeviceOperating = simulatorManager.operatingDeviceUDID == device.udid
        let isRuntimeDeleting = simulatorManager.deletingRuntimeIdentifier == device.runtime
        let isActionDisabled = simulatorManager.isOperating || isRuntimeDeleting

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                    if device.screenSize > 0 {
                        HStack(spacing: 6) {
                            Text("\(String(format: "%.1f", device.screenSize))\"")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if !device.resolution.isEmpty {
                                Text("•")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(device.resolution)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if !device.logicalResolution.isEmpty {
                                Text("•")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(device.logicalResolution)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .fixedSize()
                    }
                }

                Text("UDID: \(device.udid)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                copyDeviceInfoToClipboard()
            }

            Spacer()
                .frame(width: 30)

            HStack(spacing: 12) {
                if isDeviceOperating, let action = simulatorManager.operatingDeviceAction {
                    ProgressView()
                        .controlSize(.small)

                    Text(action.progressText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    showingResetConfirm = true
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundColor(.orange.opacity(0.9))
                }
                .buttonStyle(.plain)
                .disabled(isActionDisabled)
                .help(isActionDisabled ? "当前有操作正在执行" : "重置当前模拟器")

                Button(action: {
                    showingRecreateConfirm = true
                }) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundColor(.blue.opacity(0.8))
                }
                .buttonStyle(.plain)
                .disabled(isActionDisabled)
                .help(isActionDisabled ? "当前有操作正在执行" : "删除并重新创建当前模拟器")
                .accessibilityLabel("删除并重新创建当前模拟器")

                Button(action: {
                    showingDeleteConfirm = true
                }) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .disabled(isActionDisabled)
                .help(isActionDisabled ? "当前有操作正在执行" : "删除当前模拟器")

                Toggle(
                    "",
                    isOn: Binding(
                        get: { device.state == "Booted" },
                        set: { newValue in
                            if newValue {
                                simulatorManager.bootDevice(udid: device.udid)
                            } else {
                                simulatorManager.shutdownDevice(udid: device.udid)
                            }
                        }
                    )
                )
                .toggleStyle(.switch)
                .fixedSize()
                .disabled(isActionDisabled)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "重置 \(device.name)",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("重置当前模拟器", role: .destructive) {
                simulatorManager.eraseDevice(udid: device.udid) { success in
                    showToast(success ? "已重置 \(device.name)" : "重置 \(device.name) 时出现问题")
                }
                showToast("正在重置 \(device.name)...")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会抹掉这台模拟器里的应用和数据，但保留这台模拟器本身。")
        }
        .confirmationDialog(
            "重建 \(device.name)",
            isPresented: $showingRecreateConfirm,
            titleVisibility: .visible
        ) {
            Button("删除并重新创建", role: .destructive) {
                simulatorManager.recreateDevice(udid: device.udid) { success in
                    showToast(success ? "已重建 \(device.name)" : "重建 \(device.name) 时出现问题")
                }
                showToast("正在重建 \(device.name)...")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除这台模拟器及其数据，然后按当前设备型号和 Runtime 重新创建。显示名称保持不变，新设备会获得新的 UDID。")
        }
        .confirmationDialog(
            "删除 \(device.name)",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除当前模拟器", role: .destructive) {
                simulatorManager.deleteDevice(udid: device.udid) { success in
                    showToast(success ? "已删除 \(device.name)" : "删除 \(device.name) 时出现问题")
                }
                showToast("正在删除 \(device.name)...")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除这台模拟器及其数据，但不会删除所属的 Runtime。")
        }
    }

    // 复制设备信息到剪贴板
    private func copyDeviceInfoToClipboard() {
        // 构建设备信息字符串
        var infoString = "设备• \(device.name)"

        if device.screenSize > 0 {
            infoString += "\n尺寸• \(String(format: "%.1f", device.screenSize))\""
        }

        if !device.resolution.isEmpty {
            infoString += "\n分辨率• \(device.resolution)"
        }

        if !device.logicalResolution.isEmpty {
            infoString += "\n屏幕点• \(device.logicalResolution)"
        }
        
        // 添加UDID信息
        infoString += "\nUDID• \(device.udid)"

        // 复制到剪贴板
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(infoString, forType: .string)

        // 显示吐司提示
        showToast("已复制")
    }
}

#Preview {
    SimulatorManagementView()
}
