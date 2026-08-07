# 移除快捷键绑定功能设计

## 目标

完全移除 MenuTools 的“快捷键绑定”功能，不再显示设置 Tab、不再启动全局快捷键监听、不再执行或录制快捷键动作，并清理当前用户已经保存的快捷键绑定数据。

## 范围

- 从 `SettingsView` 删除快捷键绑定 Tab 及其依赖注入。
- 从 `MenuToolsApp` 删除绑定 Store、全局事件监听器、权限服务和权限恢复任务。
- 删除仅服务于快捷键绑定的源文件与测试文件。
- 删除四种语言资源中的快捷键绑定本地化文案。
- 删除当前用户默认值中的 `shortcutBindingsV2`、`shortcutBindingsV2.corruptedBackup` 和旧版 `shortcutBindings`。

## 保留项

- 通用设置、Finder 右键工具和平滑滚动设置继续保留。
- 面板中的“快捷开关”文案和功能不属于快捷键绑定功能，继续保留。
- `SpaceService` 及其他非快捷键调用方继续保留；只删除快捷键专用的动作执行路径。

## 验收标准

- 设置窗口只显示通用、右键工具和平滑滚动三个 Tab。
- 应用启动不再创建 `ShortcutEventMonitor` 或 `ShortcutPermissionRecovery`。
- 源码和测试中不再存在快捷键绑定专用类型及其引用。
- `shortcutBindingsV2`、损坏备份和旧版绑定 key 被清理。
- `swift test`、`swift build -c release` 和 `./build.sh` 均通过。
