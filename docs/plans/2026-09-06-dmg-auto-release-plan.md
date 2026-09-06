# DMG 打包与自动发布实施计划

**目标：** 在本机和 GitHub 的 macOS 环境生成可安装的 DMG，并在每次推送到 `main` 后更新固定的 `latest` Release。

**实现方式：** 现有 `build-app.sh` 继续负责生成应用；新增独立的 DMG 脚本负责安装盘结构；GitHub Actions 只负责编排检查、打包、验证和发布。整个流程不增加第三方打包依赖。

**使用技术：** Swift Package Manager、zsh、`hdiutil`、GitHub Actions、GitHub CLI。

## 约束

- 支持 macOS 14 及以上。
- Release 标签固定为 `latest`。
- 构建或 DMG 验证失败时不得更新 Release。
- 当前继续使用临时签名，并在 README 说明首次打开方式。
- 不提交之前生成失败的图标草稿。

## 任务一：本地 DMG 打包

**文件：**

- 新增 `scripts/build-dmg.sh`

**步骤：**

- [x] 调用 `scripts/build-app.sh` 生成应用。
- [x] 检查应用签名、可执行文件和图标。
- [x] 在临时目录放入应用及指向 `/Applications` 的快捷入口。
- [x] 使用 `hdiutil create` 输出临时 DMG，成功后再替换正式文件。
- [x] 挂载 DMG，确认两个入口存在，然后卸载。

## 任务二：GitHub 自动发布

**文件：**

- 新增 `.github/workflows/release.yml`

**步骤：**

- [x] 设置 `main` 推送和手动运行两种触发方式。
- [x] 使用 GitHub macOS 环境执行核心检查和 DMG 脚本。
- [x] 生成 SHA-256 校验文件。
- [x] 使用固定 `latest` 标签创建或更新 Release。
- [x] 上传 DMG 和校验文件，覆盖同名旧文件。
- [x] 设置并发控制，只保留最新发布任务。

## 任务三：用户文档

**文件：**

- 修改 `README.md`
- 修改 `README_zh.md`

**步骤：**

- [x] 增加固定 DMG 下载入口。
- [x] 说明拖入“应用程序”目录的安装方式。
- [x] 说明当前未经过 Apple 公证以及首次打开方式。

## 任务四：整体验证

**步骤：**

- [x] 运行核心检查与生产构建。
- [x] 验证应用签名。
- [x] 执行 DMG 脚本。
- [x] 挂载并检查 DMG 内容，然后卸载。
- [x] 检查工作流语法、README 链接和 Git 差异。
- [x] 推送后查看 GitHub Actions，确认 `latest` Release 及两个附件。
