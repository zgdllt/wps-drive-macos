# GitHub 发布

目标版本：`v0.3.0`，实验性预发布。此文档记录发布操作，实际构建状态
和可下载版本以仓库的 Actions 与 Releases 页面为准。

## 构建

```sh
bash scripts/fetch-engine.sh
bash scripts/test.sh
bash scripts/build.sh
bash scripts/package.sh
```

产物：

- `dist/release/WPS-Drive-v0.3.0-macos-arm64.dmg`
- `dist/release/WPS-Drive-v0.3.0-macos-arm64.zip`
- `dist/release/SHA256SUMS`

DMG 与 ZIP 内的应用均包含 MIT 许可证、第三方说明、OpenList 的 AGPL
许可证及 `v4.2.9` 对应源码。分发包不包含本机账号数据、数据库、运行
日志或个人文档。

## 远端发布

公开仓库：[zgdllt/wps-drive-macos](https://github.com/zgdllt/wps-drive-macos)。
发布步骤：

1. 推送已审查的源码和 `main` 分支。
2. 等待 GitHub Actions 的构建结果，检查其安装包与本机验收范围。
3. 创建 `v0.3.0` 标签和预发布 Release，使用下方说明，上传全部三个
   发布产物。

工作流仅构建并上传 Actions artifact，不自动创建公开 Release。
ad-hoc 签名分发到其他 Mac 的首次安装仍需实测；不应把当前单机验收描述为
普遍兼容或已公证。

## Release 说明

WPS Drive for macOS 0.3.0（实验性预发布）

在访达中浏览 WPS 云端文件，按需下载，并可保留在本地或释放本地空间。
使用 Swift / AppKit、Apple File Provider 和本机 OpenList。

- 默认原生云盘；提供网络磁盘备选模式。
- 红色云盘图标，关闭窗口后仅留菜单栏。
- 支持个人 / 企业驱动；真实验收目前覆盖企业账号的目录与 PDF 文件头。
- 本机 Local 夹具已验证完整读写、保留、释放、再次下载和目录继承。

仅提供 Apple Silicon 安装包。运行时最低目标 macOS 13，本次实际验收
环境 macOS 27.3；其他系统及其他 Mac 的安装尚未验收。使用 ad-hoc
签名，未使用 Developer ID 或公证。

真实 WPS 上传、编辑保存、删除、跨端冲突和长期离线恢复尚未完成验收。
这是独立非官方工具；WPS 接口变化可能影响连接。安装与首次启用见
`docs/INSTALL.md`。
