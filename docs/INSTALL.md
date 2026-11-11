# 安装 WPS Drive

当前版本是 Apple Silicon Mac 的实验性预发布版，未使用 Developer ID
签名或公证。已在本机 macOS 27.3 上验证；其他 Mac 的首次安装尚未验收。

1. 打开 DMG，将 WPS Drive 拖到“应用程序”。也可以把 ZIP 中的应用放到
   `~/Applications`。固定使用一个安装位置，避免同时运行多个副本。
2. 启动 WPS Drive。若 macOS 阻止运行，确认来源和 SHA-256 后，在
   “系统设置 > 隐私与安全性”查看是否提供“仍要打开”。
   不需要关闭 Gatekeeper、SIP 或修改系统隐私数据库。
3. 点击“登录 WPS”，在 WPS 官方网页完成登录，点击“使用此账号”。
4. 首次默认使用“原生云盘”。根据系统提示，在
   “系统设置 > 通用 > 登录项与扩展 > 文件提供程序”启用 WPS Drive，
   然后回到应用点刷新。系统版本不同，设置名称可能略有差异。
5. 点击“在访达中打开”，在 WPS Drive 中打开文件；右键可选择
   “保留在本地”或“释放本地空间”。

关闭窗口后只保留菜单栏图标，连接继续运行。点菜单栏的 WPS Drive
重新打开窗口；点“在访达中打开”可直接访问文件。退出整个应用会停止
连接，重新启动后自动恢复已有账号和模式。

## 更新

先从菜单栏退出旧版，再用新应用替换原安装位置，启动同一位置的应用。
不要同时启动下载目录、DMG、构建目录和应用程序目录中的不同副本。
账号数据保存在应用程序包外，替换应用不会清除登录。

若访达路径栏仍显示旧的白色扩展图标，可选中 WPS Drive 根目录，
打开“显示简介”（Command-I），让访达重新读取图标。本机更新后已用
此操作刷新成功；侧栏符号和路径栏普通图标可能不会同时刷新。

若更新后出现 “The application cannot be used right now”，先退出应用，
只对实际安装位置重新登记整个应用，再启动并点刷新。例如安装在
`~/Applications` 时：

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R "$HOME/Applications/WPS Drive.app"
```

安装在 `/Applications` 时相应替换路径。不要单独注销/重加 `.appex`，
也不需要删除云盘域、登录数据或本地缓存。

## 当前限制

- 真实企业账号已验证目录与 PDF 文件头读取；上传、编辑保存、冲突和
  删除仅用独立 Local 夹具验证，尚未完成真实 WPS 写入验收。
- 当前支持一个已连接账号。个人账号和长期离线恢复尚未验收。
- Cookie 保存在本机 OpenList 数据库中，不是 Keychain 加密存储。
  不要上传整个应用数据目录、数据库或含凭据的日志。
- WPS 驱动使用非官方接口，服务端变化可能影响连接。

完整状态和验证范围见仓库的 `README.md` 与 `docs/VALIDATION.md`。
包内许可证、第三方说明和 OpenList 对应源码位于
`WPS Drive.app/Contents/Resources/`。
