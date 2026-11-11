# WPS / SeaDrive 调研

记录日期：2026-11-11（Asia/Shanghai）。

## SeaDrive

本机已安装 `/Applications/SeaDrive.app`，Info.plist 记录版本 `3.0.27`。其包内包含 `SeaDrive File Provider.appex`；扩展声明 `com.apple.fileprovider-nonui`、枚举支持、自定义 Pin / Unpin 动作和本地保留装饰。

官方 macOS 文档：

- https://help.seafile.com/drive_client/drive_client_for_macos/

上游客户端源码：

- https://github.com/haiwen/seadrive-gui/blob/master/src/api/requests.cpp
- https://github.com/haiwen/seadrive-gui/blob/master/src/file-provider/file-provider.mm

`requests.cpp` 明确调用 `api2/auth-token/`、`api2/repos/`、`api2/server-info/`、`api2/repos/<id>/download-info/` 等 Seafile API。`file-provider.mm` 调用 `NSFileProviderManager` 添加域、刷新枚举和获取访达路径。

结论：已安装的 SeaDrive 不是通用 WebDAV 客户端，不能直接填 WPS 地址；实现兼容整个 Seafile 协议的 WPS 网关会增加不必要的协议与同步复杂度。可借鉴的是原生 File Provider 的交互与缓存策略。

## 已有可复用实现

| 项目 | 实际观察 | 本次取舍 |
| --- | --- | --- |
| OpenList | 有 WPS 个人 / 企业驱动，提供目录、下载、上传、重命名、移动、删除；文档明确其为逆向接口且不主动维护 | 复用固定版本的本机引擎，避免重写 WPS 协议 |
| Mountain Duck | 支持 WebDAV、按需下载、Keep Offline、Delete Local；官网提供付费许可证与试用 | 能组成现成方案；未购买、安装或验证它与 WPS 的组合 |
| OpenList Desktop | GUI 管理与挂载工具，官方仓库可见 | 未验证其对 WPS 的完整原生本地保留 / 释放体验 |
| PolyDrive | 项目官网声明 WebDAV、File Provider 和缓存释放 | 未安装、未验证与 WPS 的组合 |
| dokisekai/CloudDrive | 仓库声明 WebDAV、原生按需下载和本机 ad-hoc 激活；激活脚本会重签名并重启 Finder / fileproviderd | 仅作为实现可行性的参考，未运行其激活脚本或采信“生产就绪”声明 |

来源：

- https://doc.oplist.org/guide/drivers/wps
- https://github.com/OpenListTeam/OpenList/tree/v4.2.9/drivers/wps
- https://github.com/OpenListTeam/OpenList-Desktop
- https://mountainduck.io/
- https://docs.mountainduck.io/mountainduck/sync/
- https://polydrive.net/
- https://github.com/dokisekai/CloudDrive
- https://github.com/dokisekai/CloudDrive/blob/main/scripts/activate.sh

## 决策

初始方案采用独立的 Swift 原生应用与 File Provider 扩展，后台仅使用本机 OpenList。这样不要求 SeaDrive 支持新协议，也不要求用户把 WPS 文件先同步到另一套 Seafile 服务。

只有域注册成功不足以证明可以挂载文件。因此单独验证 File Provider 的列目录、按需读取、原生缓存释放、重新下载、创建、重命名和删除。真实 WPS 接入与本机 Local 夹具验证分开记录。

Apple 官方参考：

- https://developer.apple.com/documentation/fileprovider
- https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension
- https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager

实现时同时读取本机 SDK 的 `NSFileProviderItem.h`、`NSFileProviderReplicatedExtension.h` 和 `NSFileProviderManager.h`，以当前实际头文件中的签名与可用性为准。

## 2026-11-12 早期调整（已被 0.2.0 替代）

File Provider 域注册成功，但本机 ad-hoc 签名目标访问共享容器时被 TCC 拒绝。Apple 的 App Group 文档要求配置与应用签名匹配，不能据域注册成功推断共享容器可用：

- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups

当时交付改为 AppKit 登录助手 + 本机 OpenList + 系统 WebDAV 挂载，原生扩展暂时禁用。基础挂载连接真实 WPS 企业账号，列出分组内文件并读取 PDF 文件头；独立 Local 夹具的完整读写操作也通过。

这次共享组失败不能证明 File Provider 必须使用 App Group，也不能证明必须购买开发者会员。此前把它直接视为整个原生路线的硬阻塞，判断过早。

## 0.2.0：无共享组的原生路线

同日继续构建独立探针：主应用和扩展均 ad-hoc 签名，完全移除 App Group。经过正常的系统提供程序启用，原生列目录、占位文件、按需读取、驱逐与再次下载全部通过。这证明本机可以运行此签名方式的 File Provider。

随后把 WPS 扩展改为：

- 主应用通过 `NSFileProviderManager.getService` 取得 `NSFileProviderServicing` 暴露的服务；服务标记 `isRestricted = true`，限制为能管理该域的进程。
- 配置通过 XPC 传递，不把凭据放入域公开元数据。macOS 15 及以上使用 `stateDirectoryURL()`，并正确管理其安全作用域。
- 保留和释放通过内容策略及系统驱逐 API 完成，文件夹操作清除已知子孙的覆盖标记。

完整原生 Local 夹具验收通过，安装版也已连接真实企业账号并读取云端 PDF 文件头。原生入口现已启用；本机运行不再以付费证书或 App Group 为前提。分发签名 / 公证与本机运行是另外的问题，本工具没有完成分发验收。

具体测试、尚未验收的真实云端写入与其他限制以 [验证记录](VALIDATION.md) 为准。

## 0.3.0：访达图标与更新

应用普通图标使用 `CFBundleIconFile`；访达侧栏另外读取
`CFBundleIcons > CFBundlePrimaryIcon > CFBundleSymbolName`。将它设为
`externaldrive.badge.icloud` 后，用户刷新并确认侧栏显示了指定符号。
路径栏普通图标还补充了主图标文件声明与 PNG 资源。系统直接读取扩展
图标已返回正确红色图形，访达仍保留过白色扩展占位图；用户打开根目录
的“简介”后确认路径栏刷新成功。该结果支持缓存未及时更新的判断，
不能据此单独确定是哪一项图标声明起效。

Apple 明确说明 `CFBundleSymbolName` 用于 macOS File Provider 域的访达
侧栏；Nextcloud 的 File Provider 扩展也采用同样的配置层级：

- https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleicons/cfbundleprimaryicon/cfbundlesymbolname
- https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleicons/cfbundleprimaryicon/cfbundleiconfiles
- https://github.com/nextcloud/desktop/blob/master/shell_integration/MacOSX/NextcloudIntegration/FileProviderExt/Info.plist

更新实验中，单独注销再登记 `.appex` 造成“插件可见，但现有域找不到可
启动扩展”的状态。重新登记包含它的整个应用后连接恢复，因此更新指引
只使用宿主应用登记，避免把单独插件的 `pluginkit -r/-a` 当作图标刷新。
macFUSE 官方故障文档也记录了缺失 parent record 的同类现象：

- https://github.com/macfuse/macfuse/wiki/Troubleshooting
