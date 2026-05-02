# PDF Reader

原生 macOS 阅读器：**PDF**（PDFKit）、**EPUB**（嵌入式 WebKit 运行时）。SwiftUI + AppKit。

## 环境要求

- macOS **14.0** 或更高
- **Xcode**（建议当前正式版或与工程 Swift 版本匹配的工具链）

## 在 Xcode 中打开与运行

在项目根目录（含 `PDF-Reader.xcodeproj`）执行：

```bash
open PDF-Reader.xcodeproj
```

在 Xcode 中选择 Scheme **PDF-Reader**，菜单 **Product → Run**（或 `⌘R`）。

## 命令行编译

进入项目根目录后执行。**Scheme**、**项目名称**区分大小写，与工程中一致：`PDF-Reader`。

### Debug 构建（默认）

```bash
cd /path/to/PDF-Reader

xcodebuild -project PDF-Reader.xcodeproj \
  -scheme PDF-Reader \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

### Release 构建

```bash
xcodebuild -project PDF-Reader.xcodeproj \
  -scheme PDF-Reader \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

### 将产物输出到本地目录（便于拷贝 `.app`）

```bash
xcodebuild -project PDF-Reader.xcodeproj \
  -scheme PDF-Reader \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath ./DerivedData \
  build
```

构建成功后，应用在：

`DerivedData/Build/Products/Release/PDF Reader.app`

（Debug 配置的子目录名为 `Debug`。）

### 仅用命令行路径打开构建好的 App（示例）

Debug 产物默认在 Xcode 的 DerivedData 下，也可用上面 `-derivedDataPath` 固定位置后执行：

```bash
open "./DerivedData/Build/Products/Release/PDF Reader.app"
```

## Git Tag 与 GitHub 自动打包

仓库已包含工作流 [.github/workflows/release-on-tag.yml](.github/workflows/release-on-tag.yml)：**推送以 `v` 开头的 tag**（如 `v1.0.0`）后，GitHub Actions 会在 `macOS` 上跑一次 **Release** 构建，将 `PDF Reader.app` 打成 ZIP，并**自动创建/更新**对应的 **GitHub Release**，把 ZIP 挂在 Release 附件里。

### 1. 本地打 tag（推荐附注 annotated tag）

在项目根目录、且默认分支已与远程同步的前提下：

```bash
# 选一个与版本号一致的 tag（须以 v 开头，与工作流匹配）
git tag -a v1.0.0 -m "Release 1.0.0"

# 推到 GitHub（只推 tag）
git push origin v1.0.0

# 或一次性推送分支上所有本地 tag（慎用）
git push origin --tags
```

推送成功后，打开 GitHub 仓库页的 **Actions** 查看运行日志；成功后到 **Releases** 页面下载 `PDF-Reader-v1.0.0-macos.zip`（文件名中的版本与 tag 一致）。

### 2. 也可在网页上 Release 时再打 tag

在 GitHub **Releases → Draft a new release** 里填写 **Tag**：例如 `v1.0.0`，选择「从 tag 创建」并发布——同样会 `push` 一个 tag，只要符合 `v*`，仍会触发同一工作流。

### 3. 权限与 Runner 限制

- 若 CI 报错与 **token 写 Release** 有关：在仓库 **Settings → Actions → General**，将 **Workflow permissions** 设为可读写 Contents（或勾选允许 GITHUB_TOKEN 写入）。
- Runner 上使用 **跳过你本机的开发者签名**：产物为**未签名** `.app`，适合内测或未公证分发；需要 **公证 / 上架**时，请在本地用 Xcode 选择你的 Team 做 **Archive** 与 **notarize**。

### 4. 调整触发规则

若要匹配其它 tag 格式（例如 `1.0.0` 无 `v` 前缀），请修改工作流里 `on.push.tags` 的 glob 表达式。
