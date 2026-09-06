# DMG 打包与自动发布设计

## 目标

为 Codex Switcher 提供可下载、可拖入“应用程序”目录安装的 DMG，并在每次代码推送到 `main` 后，由 GitHub 自动构建和更新固定的 `latest` Release。

本次先使用现有的本机临时签名。Apple Developer ID 签名和公证需要开发者证书，后续单独配置。

## 发布方式

仓库只维护一个持续更新的 Release：

- 标签固定为 `latest`。
- Release 标题固定为 `Codex Switcher Latest`。
- 每次 `main` 推送成功构建后，用新 DMG 替换 Release 中的旧文件。
- Release 说明记录本次提交号和构建时间。
- 固定下载地址不会随提交变化。

这种方式适合当前持续开发阶段，不会为每次小改动积累大量正式版本。以后需要稳定版本时，可以在此流程之外增加按 `v*` 标签发布的正式版本。

## 本地 DMG 打包

新增 `scripts/build-dmg.sh`，职责保持单一：

1. 调用现有 `scripts/build-app.sh` 生成 `dist/Codex Switcher.app`。
2. 验证应用签名和必要文件是否存在。
3. 创建临时 DMG 目录。
4. 将应用复制到目录中。
5. 创建指向 `/Applications` 的快捷入口。
6. 使用 macOS 自带的 `hdiutil` 生成压缩 DMG。
7. 输出 `dist/Codex-Switcher.dmg`。

脚本使用临时目录完成中间步骤，生成失败时不会留下不完整的正式 DMG。

## GitHub 自动流程

新增 `.github/workflows/release.yml`，只在以下情况运行：

- 推送到 `main`。
- 用户在 GitHub Actions 页面手动执行。

工作流在 GitHub 提供的 macOS 环境中执行：

1. 拉取本次提交。
2. 运行 Swift 核心检查。
3. 调用 DMG 打包脚本。
4. 挂载 DMG，确认其中包含应用和“应用程序”快捷入口。
5. 计算 DMG 的 SHA-256 校验值。
6. 更新 `latest` 标签，使其指向本次提交。
7. 创建或更新固定 Release，并替换 DMG 和校验文件。

工作流只申请发布所需的仓库内容写权限。构建或验证失败时，发布步骤不会执行，原 Release 保持可用。

为避免多个快速推送互相覆盖，同一时间只保留最新的发布任务，较旧且尚未完成的任务会取消。

## 签名和系统提示

当前 `build-app.sh` 使用临时签名，因此 GitHub 可以生成结构完整的 DMG，但下载到其他 Mac 后，系统可能提示无法验证开发者。

本次 README 会明确说明首次打开方式，不承诺已经通过 Apple 公证。以后配置 Apple Developer ID 时，再把证书、密码和公证凭据保存为 GitHub Secrets，并在 DMG 发布前完成正式签名与公证。

## README 调整

英文和中文 README 都增加：

- 固定 `latest` Release 下载入口。
- DMG 的安装方式。
- 当前签名状态和首次打开提示。

英文 README 继续作为默认入口，中文 README 保留互相跳转。

## 验证标准

本地检查：

- Swift 核心检查通过。
- 应用构建成功且签名验证通过。
- DMG 可以挂载。
- DMG 中存在 `Codex Switcher.app` 和 `Applications` 快捷入口。
- 卸载 DMG 后没有残留挂载点。

推送后的检查：

- GitHub Actions 在 macOS 环境成功完成。
- `latest` 标签指向最新的 `main` 提交。
- `Codex Switcher Latest` Release 存在。
- Release 中可以下载 DMG 和 SHA-256 校验文件。
- README 的下载地址指向固定 Release。
