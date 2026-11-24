# Venera-V 移动同步探针

探针使用合成数据，无需配置 WebDAV 或访问应用数据库。同步核心源码与 Venera-V `f996dc6` 一致。

- P14 启动时自动执行。记录 12 个有效向量、8 个无效向量、字段乱序和 E1 身份冲突测试结果。
- R8 点击 **Measure 50,000 records**，记录首次完成时的设备型号、系统版本、用时、峰值 RSS。如果应用被系统终止，记录系统诊断和当时的操作。可以使用 `--dart-define=AUTO_R8=true` 在 P14 完成后自动开始。
- A1 同时显示几个固定 sourceKey 的运行时哈希。另需在两台真机使用相同测试来源和作品 ID，通过 Venera-V 导出只含合成数据的 `.venera`，再用 [compare_backup_types.py](../compare_backup_types.py) 比较实际数据库行。

Android 测试 APK 支持 ARM64 和 x86_64。iOS 需要在具备 Flutter 和 Xcode 的 Mac 上构建。iOS 真机签名使用测试团队和独立的应用标识。

```sh
flutter pub get
flutter run --release -d <测试机设备标识>
```

iPhone 的后台同步恢复要在 Venera-V 测试 IPA 验收。分别在下载阶段和写入阶段切到主屏幕，返回后核对本地数据，并记录从后台返回、手动重试（如需）至完成的过程。设置中的日志可核对 `stage download`、`stage apply` 和同步结果。若日志显示前后两次运行都未在写入阶段进入后台，需要用更大一批合成记录重试。
