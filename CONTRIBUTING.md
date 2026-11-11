# 开发与反馈

构建需要 Apple Silicon Mac、Swift 命令行工具和 macOS 26 SDK 或更新版本。
完整 Xcode 不是必需条件。运行时最低目标是 macOS 13；实际测试范围见
`docs/VALIDATION.md`。

```sh
bash scripts/fetch-engine.sh
bash scripts/test.sh
bash scripts/build.sh
bash scripts/package.sh
```

构建产物在 `dist/`，不提交到 Git。菜单栏和窗口行为需在有桌面会话的
Mac 上手动验证；CI 只运行独立后端与索引测试、构建和打包，不声称通过
File Provider 激活或访达交互验收。

原生回归在合成 Local 夹具上运行：

```sh
"dist/WPS Drive.app/Contents/MacOS/WPSDrive" --self-test
```

先退出其他 WPS Drive 副本，并按正常系统流程启用扩展。该命令会创建并
删除本工具自己的测试域和临时数据，不使用真实 WPS 文件。完整说明见
`docs/VALIDATION.md`。

报告问题时提供应用版本、Mac 芯片、macOS 版本、原生或网络磁盘模式、
复现步骤及脱敏后的错误信息。不要提供 Cookie、登录令牌、数据库、
完整账号目录或带签名的下载链接。涉及云端写入的改动先用 Local 夹具
复现，再在获授权的测试账号和文件上验证。
