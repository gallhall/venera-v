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
- 把 [Kazumi](https://github.com/Predidit/Kazumi) 的动漫规则和 [Animeko](https://github.com/creamycake-anime/animeko-subs) 的订阅源用作视频源，见 [Kazumi Rules](doc/kazumi_rules.md)
- 视频播放器：选集、全屏、手势、锁定、快进快退，并记住播放设置；在播放器内切换来源和线路，播放失败时自动换源
- 播放历史，从上次的位置继续播放
- 按选择的画质下载剧集（包括 DASH 流），离线播放，并可导出为文件
- 导入本地视频和字幕
- 打开视频网页来查找视频流
- 所有平台均使用 media_kit 播放

### 看番（venera-v 新增）
- [Bangumi](https://bgm.tv)：按条目找番、放送表、收藏，并同步观看进度
- BT：从蜜柑计划、Nyaa 等 RSS 源边下边播，可设置偏好的字幕组、分辨率和字幕；也可以下载
- 弹幕：B 站弹幕优先，[弹弹play](https://www.dandanplay.com) 备用
- 在播放器里查看 Bangumi 的条目吐槽和单集评论
- [Anime4K](https://github.com/bloc97/Anime4K) 超分，手机有专门的档位，掉帧或发热时自动降档
- ASS/SSA 特效字幕，各平台内置中日韩字体
- 按番剧和剧集管理缓存

## 下载
Android、iOS、Windows、macOS 和 Linux（deb、Arch）的安装包在 [Releases](https://github.com/gallhall/venera-v/releases) 页面。

venera-v 是独立的应用（Android 包名为 `com.github.gallhall.venerav`），可以和 venera 同时安装。

## 相关链接
- [Releases](https://github.com/gallhall/venera-v/releases)：各个版本的安装包
- [venerav-configs](https://github.com/gallhall/venerav-configs)：venera-v 默认使用的漫画源列表
- [Telegram 频道](https://t.me/VeneraV_Updates)：新版本发布通知
- [venera](https://github.com/venera-app/venera)：venera-v 所基于的项目

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

### Kazumi
[Kazumi](https://github.com/Predidit/Kazumi) 和 [KazumiRules](https://github.com/Predidit/KazumiRules)

venera-v 支持 Kazumi 的动漫规则格式。

### Animeko
[Animeko](https://github.com/open-ani/animeko) 和 [animeko-subs](https://github.com/creamycake-anime/animeko-subs)

venera-v 支持 Animeko 的订阅源，BT 和 RSS 播放参考了 Animeko 的做法。

### 其他
- [Bangumi](https://bgm.tv)：条目、剧集、收藏和评论
- [弹弹play](https://www.dandanplay.com) 和哔哩哔哩：弹幕
- [Anime4K](https://github.com/bloc97/Anime4K)：超分着色器
- [media_kit](https://github.com/media-kit/media-kit)：播放
- [dtorrent_task_v2](https://github.com/atlet99/dtorrent_task_v2)、[rhttp](https://codeberg.org/Tienisto/rhttp)、[tray_manager](https://github.com/leanflutter/tray_manager) 和 [connectivity_plus](https://github.com/fluttercommunity/plus_plugins)：修改后放在 `packages/` 中

## Headless 模式
见 [Headless Doc](doc/headless_doc.md)
