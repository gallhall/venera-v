# venera-v
[![flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/gallhall/venera-v)](https://github.com/gallhall/venera-v/blob/master/LICENSE)
[![Download](https://img.shields.io/github/v/release/gallhall/venera-v)](https://github.com/gallhall/venera-v/releases)

[English](README.md) | 简体中文

一个支持本地和网络内容的漫画与视频阅读器。

venera-v 是 [venera](https://github.com/venera-app/venera) 的分支，venera 已停止维护。
venera-v 保留了 venera 的全部功能，并增加了视频播放。

## 功能
- 阅读本地漫画
- 使用 javascript 编写漫画源
- 从网络漫画源阅读漫画
- 管理收藏的漫画
- 下载漫画
- 查看漫画的评论、标签等信息（需漫画源支持）
- 登录后评论、评分等操作（需漫画源支持）

### 视频（venera-v 新增）
- 视频源：`mediaType = "video"` 的漫画源，通过 `video.loadPlayInfo` 提供播放地址
- 视频播放器：选集、全屏、手势、锁定、快进快退，并记住播放设置
- 播放历史，从上次的位置继续播放
- 按选择的画质下载剧集（包括 DASH 流），离线播放，并可导出为文件
- 导入本地视频和字幕
- 打开视频网页来查找视频流
- iOS 上使用系统播放器播放，支持锁屏控制

## 下载
Android、iOS、Windows、macOS 和 Linux（deb、Arch）的安装包在 [Releases](https://github.com/gallhall/venera-v/releases) 页面。

venera-v 是独立的应用（Android 包名为 `com.github.gallhall.venerav`），可以和 venera 同时安装。

## 从源码构建
1. 克隆本仓库
2. 安装 flutter，见 [flutter.dev](https://flutter.dev/docs/get-started/install)
3. 安装 rust，见 [rustup.rs](https://rustup.rs/)
4. 构建对应平台，例如 `flutter build apk`

在 GitHub 上发布 Release 会运行 `Build ALL` 工作流，构建所有平台并把安装包上传到这个 Release。

## 编写漫画源
见 [Comic Source](doc/comic_source.md)

## 编写视频源
见 [Video Source](doc/video_source.md)。[demo_video.js](doc/demo_video.js) 是一个完整的示例，播放的是公开的测试视频流。

## 致谢

### venera
本项目基于 [wgh136](https://github.com/wgh136) 及其贡献者的 [venera](https://github.com/venera-app/venera)。

### 标签翻译
[EhTagTranslation](https://github.com/EhTagTranslation/Database)

漫画标签的中文翻译来自这个项目。

## Headless 模式
见 [Headless Doc](doc/headless_doc.md)
