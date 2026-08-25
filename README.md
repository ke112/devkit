# DevKit

DevKit 是一个原生 macOS 开发工具集合，当前包含 iOS 模拟器管理、图片叠加、iOS App 发版和 TinyPNG 图片压缩四个独立模块。界面使用 SwiftUI，系统集成与图片处理使用 AppKit 和 Foundation，不依赖第三方库。

## 功能

### iOS 模拟器管理

- 按 iOS Runtime 分组展示本机模拟器、状态、UDID 和屏幕规格
- 自动刷新、手动刷新以及 CoreSimulator 异常恢复
- 启动、关闭、重置、删除和按原型号重建单个模拟器
- 为指定 Runtime 创建主流机型或全部受支持机型
- 批量删除 Runtime 下的模拟器，或连同 Runtime 镜像彻底删除
- 在 Finder 中打开模拟器目录，点击设备信息可复制到剪贴板

### 图片叠加

- 通过文件选择器或拖拽导入底图和上层图片
- 实时调节上层图片透明度并预览叠加结果
- 按底图原始像素尺寸导出 PNG
- 上层图片保持宽高比并居中适配底图画布

### TinyPNG 图片压缩

- 通过文件选择器或拖拽选择单张图片或文件夹
- 调用项目内置 TinyPNG 脚本，支持 PNG、JPG、JPEG 和 WebP
- 默认自动替换原图；关闭开关后在输入路径同级生成带时间戳的输出目录，并保留原文件名和文件夹相对路径
- 上传前跳过超过 5 MB 的单张图片，避免触发 TinyPNG 限制
- 通过“上传状态”面板查看每张图片状态、缩略图预览、原图路径和执行日志
- 显示总压缩前后大小、节省比例，以及每张图片的原始大小、压缩大小和节省比例
- 支持主动停止；离开压缩页面或 DevKit 退出时会终止压缩子进程
- 压缩进行中返回页面会先确认是否停止任务

## 环境要求

- macOS 15.2 或更高版本
- 完整版 Xcode，并已安装所需 iOS Simulator Runtime
- Xcode Command Line Tools 指向完整 Xcode

如 simctl 无法使用，可执行：

~~~bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
~~~

## 构建与测试

使用 Xcode：

~~~bash
open devkit.xcodeproj
~~~

命令行构建：

~~~bash
xcodebuild \
  -project devkit.xcodeproj \
  -scheme devkit \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
~~~

运行单元测试：

~~~bash
xcodebuild test \
  -project devkit.xcodeproj \
  -scheme devkit \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
~~~

## 打包与安装

package_release.sh 会归档并校验 Release 应用，生成并保留以下产物：

- build/DevKit.zip
- /Applications/DevKit.app

打包完成并校验安装版后，脚本会删除项目目录和 Xcode DerivedData 中 Bundle ID 为 `com.zhihua.devkit` 的其他 `DevKit.app`，只保留 `/Applications/DevKit.app`。

执行：

~~~bash
./package_release.sh
~~~

脚本使用项目当前的 Apple Development 自动签名配置。当 /Applications 不可写时，安装阶段会请求 sudo。脚本不会自动启动应用。

当前产物未进行 Apple Notarization。将 ZIP 复制到其他 Mac 后，如果系统提示无法打开，可将应用放入 /Applications，再执行：

~~~bash
sudo xattr -r -d com.apple.quarantine /Applications/DevKit.app
~~~

## 操作风险

- “重置”会抹掉模拟器内的应用和数据，但保留设备及 UDID。
- “删除并重新创建”会删除原设备及数据，再按原设备型号和 Runtime 创建新设备；新设备会获得新的 UDID。
- “删除当前模拟器”不会自动创建替代设备。
- “彻底删除”会同时删除对应 iOS Runtime 镜像，通常会释放数 GB 空间。该操作不可撤销，重新使用时需要通过 Xcode 下载 Runtime。

执行删除或重建前，请确认目标 Runtime、设备名称和 UDID。

## 项目结构

~~~text
devkit/
├── ContentView.swift
├── devkitApp.swift
├── Features/
│   ├── ImageOverlay/
│   └── SimulatorManagement/
└── Assets.xcassets/
DevKitTests/
package_release.sh
~~~

模拟器、图片叠加和 App Store 发版模块按各自流程处理数据。TinyPNG 模块会将符合条件的图片上传到 TinyPNG 进行云端压缩；模拟器模块仅调用本机 Xcode 和 CoreSimulator 工具。
