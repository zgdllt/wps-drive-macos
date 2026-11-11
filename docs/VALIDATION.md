# 验证记录

2026-11-11 开始开发，2026-11-12 继续验收，时区 Asia/Shanghai。

## 已通过

- `bash scripts/test.sh`：稳定文件标识、缓存保留状态持久化、目录重命名对子路径的更新、跨目录移动变更、递归删除元数据、路径名边界。
- 真实 OpenList JSON 回归：`hashinfo: "null"`、空 digest 和结构化 `hash_info`；无摘要时回退到修改时间与大小。
- 独立 Local 存储：上传与下载字节一致；中文、空格、`% # ?` 文件名；重命名、异步移动等待、删除。
- 无凭据的 WebDAV `PROPFIND` 被 401 拒绝；本机服务仅绑定 `127.0.0.1`。
- 应用、引擎和扩展编译、macOS 13.0 deployment target、本机签名校验。
- File Provider 域注册 API 返回成功。
- `WPSDrive --mount-test`：系统 WebDAV 卷名 WPS；回读的服务器来源匹配；挂载后的读取、中文文件写入、重命名、删除、正常弹出均通过。2026-11-12 00:39（Asia/Shanghai）最终运行输出 `MOUNT_VERIFICATION_PASSED` 和 `CLEANUP: fixture removed`。
- 旧版应用正常退出后，自家 WebDAV 卷、引擎宿主和 OpenList 子进程均已退出。
- 安装到 `~/Applications/WPS Drive.app`，深度严格签名校验通过；启动后自动恢复已有企业账号登录，未要求重新提供 Cookie。
- 安装版实际挂载至 `/Volumes/WPS`。访达能列出根分组，并进入“我的企业文档”显示 51 项。只读提取一份云端 PDF 的前 5 字节，返回 `%PDF-`；未检查整份内容或编辑保存。
- 0.2.0 界面检查：登录按钮图标与文字无重叠；访达按钮有工具提示与无障碍名称；原生云盘选项已启用。
- 清理了本项目早期创建的 `wps-probe` / `wps-verification-*` 测试域。

挂载测试报告：`~/Library/Application Support/WPS Drive/mount-verification.txt`。所有写入、重命名和删除测试均使用独立 Local 夹具，未对真实 WPS 文件执行这些操作。

## 0.2.0 原生验收

2026-11-12，在本机 macOS 27.3 / Apple Silicon 上，仅用 ad-hoc 签名完成，无 App Group。

- 最小 `WPS Native Probe`：移除共享组 entitlement 和 `NSExtensionFileProviderDocumentGroup`；经正常系统激活后，原生枚举、完整 256 KiB 读取、驱逐为无内容占位项、再次读取通过。
- 最终安装版 `--finder-self-test` 于 01:37:28 输出 `NATIVE_VERIFICATION_PASSED`，进程以 0 退出，自己的测试域、夹具和引擎均清理。
- 配置经 `isRestricted = true` 的系统 XPC 服务传递；扩展取得按域分配的状态目录并持有安全作用域。没有共享组访问。
- 初始合成文件大小 262144 字节，`st_blocks = 0`，含 `SF_DATALESS` 标志；完整按需读取与夹具字节一致。
- 本地内容驱逐后，后端文件保持不变；保留操作在没有打开文件的情况下主动下载；释放取消保留并恢复占位状态，之后再次读取字节一致。
- 单独保留子文件，再释放父文件夹成功；重新保留父文件夹时子文件继承保留策略，没有残留 `false` 覆盖父级。
- 访达交互阶段观察到合成文件恢复 `SF_DATALESS`，随后原生创建、重命名、删除到达后端，清理通过。该记录不独立区分自定义释放动作和系统移除下载动作。
- 真实企业账号的原生根目录列出“我的企业文档 / 自动备份”；从 `~/Library/CloudStorage/WPSDrive-WPS` 读取一份真实 PDF 的前 5 字节，返回 `%PDF-`。
- 正常退出安装版后，自家引擎和子进程退出；再次启动后无需重新登录，自动恢复“企业空间 · 原生云盘”状态。真实原生目录路径保持不变。

报告位于主应用的数据目录：`native-probe.txt`、`native-verification.txt`。共享容器失败仅适用于被替代的早期实现，不能再据此判断本机原生功能不可行。

本轮未重置 TCC、重启 Finder / 整个 fileproviderd 或修改 SeaDrive。

## 已发现并处理

- OpenList v4.2.9 首次运行需显式设置 `OPENLIST_ADMIN_PASSWORD` 才会自动创建管理员。随机初始密码仅经引导子进程的环境变量传递，不进入 argv 或用户日志。
- `/api/fs/move` 返回异步任务；只有全部任务的 `state == 2` 才算完成。
- WPS 下载依赖驱动的请求头，改经认证 WebDAV 的 `native_proxy` 下载，避免直连 `raw_url` 丢失请求头。
- macOS NetFS 对自定义挂载点返回 `EPERM`；改为回退到系统分配的卷路径，最终挂载与文件操作通过。
- 早期 macOS 27.3 拒绝共享组目录访问；已改为无共享组的受限服务与独立状态目录。此阻塞已解决，原生功能已启用。
- `stateDirectoryURL()` 返回安全作用域 URL，需在索引异步写入期间持续持有；仅取路径会被系统拒绝。
- `NSFileProviderServicing` 需显式声明；只写同名 Swift 方法不足以暴露服务。
- 保留操作需先等待系统接收枚举信号，再等待稳定，避免跨 XPC 通道的验收竞态。
- 首次原生登录会先保存已验证账号；系统扩展尚未启用时，启用后可点刷新恢复，不必再次登录。
- 同一 bundle 的构建目录副本与安装版同时存在会造成路径和实例混淆；最终验收使用 `~/Applications/WPS Drive.app`，只保留该版运行。

## 尚未验收

- 真实 WPS 上传、跨端编辑冲突、删除、完整文件下载与保存；个人账号；长期运行和网络中断恢复；其他 macOS 版本。
- 独立记录自定义释放动作的具体调用与完成日志；交互测试已有驱逐结果，未保留菜单项来源。

## 0.3.0 发布准备

2026-11-12，继续使用同一台 Mac。

- 索引与独立 OpenList 后端回归再次通过；未增加真实云端写入测试。
- 新用户默认原生模式；旧配置缺少模式字段也默认原生，显式保存的网络磁盘选择保留。分段索引经独立只读审查；安装版显示“原生云盘”在首位且选中。
- 点击关闭按钮和 Command-W 关闭主窗口均已验证：`NSRunningApplication.activationPolicy` 为 `accessory`（1），进程未退出；重新打开窗口恢复 `regular`（0）。应用菜单包含关闭窗口命令。
- 全应用观察窗口关闭，覆盖主窗口、登录和标准“关于”窗口；“关于”窗口参与时的完整交互未单独实测。
- 应用使用用户指定的红色 `externaldrive.badge.icloud` 图标。安装路径最初命中系统占位图缓存；仅刷新本应用后，系统的应用与运行中图标读取均返回正确图形。
- 侧栏通过 `CFBundleIcons > CFBundlePrimaryIcon > CFBundleSymbolName` 声明相同系统符号。用户已刷新并提供侧栏生效截图。
- 路径栏普通图标与侧栏符号分开处理；扩展包含 ICNS、PNG 资源及主图标文件声明。系统直接读取扩展已返回正确红色图标，但访达路径栏一度仍显示白色扩展占位图。用户打开其“简介”后确认路径栏也刷新成功。
- 对单独扩展执行注销/重新登记曾使宿主关联失效，返回 “The application cannot be used right now”。仅对已安装的整个应用执行 `lsregister -f -R`，再点刷新，已恢复原有域和受限 XPC 连接。未移除真实域或重建真实文件缓存。
- Git 本地仓库已初始化，公开候选文件经凭据格式扫描和忽略路径核对。个人冷文件盘点、运行数据、引擎下载和构建目录均排除。
- GitHub Actions 配置已完成，脚本语法与 YAML 解析通过。公开仓库为 `zgdllt/wps-drive-macos`；远端构建结果见 [Actions](https://github.com/zgdllt/wps-drive-macos/actions)，此处记录本机验证范围。

最终发布候选为 0.3.0 / build 5。DMG 完整校验与 DMG、ZIP 的 SHA-256
清单检查通过；ZIP 解包后的应用再次通过 `codesign --verify --deep --strict`。
包内应用与扩展均包含一致的红色图标，OpenList 对应源码哈希与固定下载值
一致。检查包内容未包含账号数据库、日志或个人文档。

关窗后原生域仍启用，扩展存活，诊断显示不需重新认证、索引错误数为 0。
上述检查没有替代其他 Mac 的安装验收或真实 WPS 写入测试。
