# Hermes Agent macOS 离线安装包

## 版本与适用范围

- Hermes Agent：`@HERMES_VERSION@`
- 发布标签：`@HERMES_REF@`
- 固定提交：`@HERMES_COMMIT@`
- 平台：macOS `@ARCH@`
- 构建与云端验证系统：`@BUILD_OS@`

`arm64` 版本用于 Apple Silicon（M1/M2/M3/M4/M5）；`x64` 版本用于 Intel Mac。两种包不能混用。

## 安装

1. 在目标 Mac 上完整解压 ZIP，建议使用 Finder 自带的“归档实用工具”。
2. 双击 `install-offline.command`。
3. 如果 macOS 阻止脚本运行：右键该文件，选择“打开”。
4. 安装完成后从 `~/Applications/Hermes.app` 启动 Hermes。

默认安装目录：

- Hermes Agent 与运行时：`~/.hermes`
- 命令行入口：`~/.local/bin/hermes`
- Desktop：`~/Applications/Hermes.app`

不要求管理员权限，不会修改 `/Applications` 或 `/usr/local`。

## 离线范围

安装器本身不访问网络。包内含：

- Hermes Agent 固定源码 checkout
- Python `@PYTHON_VERSION@` runtime
- 已安装的 `[all]` Python 依赖
- Node.js `@NODE_VERSION@`
- uv `@UV_VERSION@`
- ripgrep `@RG_VERSION@`
- 对应架构的 Hermes Desktop / Electron runtime

不包含：

- API Key、OAuth 登录信息或用户配置
- 本地大模型权重
- Playwright/Camofox 浏览器缓存
- ffmpeg（核心功能不依赖；语音媒体转换需要时可后续安装）
- Portable Git（macOS 的 Git 通常由 Xcode Command Line Tools 提供；缺少 Git 只影响项目 Git 操作和在线更新）

模型供应商登录和在线模型调用仍需要网络。这里的“离线”指 Hermes 的安装阶段无需访问 GitHub、PyPI、npm、Node.js CDN 或 Electron CDN。

## 安装器参数

```bash
./install-offline.sh --applications-dir "$HOME/Applications" --no-path --no-launch
```

`HERMES_HOME` 固定使用 Desktop 原生默认值 `$HOME/.hermes`，以确保从 Finder 启动时能定位同一套 backend。Desktop 应用目录可自定义，但必须位于当前用户 HOME 下。

## 完整性校验

同目录 `.sha256` 文件用于校验最终 ZIP。安装脚本先使用 macOS 系统 `/usr/bin/shasum` 校验 bundle 普通文件，再根据 `MANIFEST.json` 校验 payload 内每个文件、符号链接和 Unix 权限。

从 GitHub 下载后、转移到离线 Mac 前，建议在联网电脑上验证 GitHub 构建来源：

```bash
gh attestation verify Hermes-Offline-macOS-@ARCH@-@HERMES_VERSION@.zip \
  --repo smartwang/hermes-offline-macos-builder
```

随后校验 SHA-256：

```bash
shasum -a 256 -c Hermes-Offline-macOS-@ARCH@-@HERMES_VERSION@.zip.sha256
```

## Gatekeeper 与签名

此自动构建使用 ad-hoc 签名，不是 Apple Developer ID 公证版本。首次打开可能需要 Finder 右键 →“打开”，或在“系统设置 → 隐私与安全性”中允许。

若以后配置 Apple Developer ID，可在 GitHub Actions 中增加正式 codesign、notarization 和 stapling，而不改变离线安装结构。

## 安装位置与回滚

Hermes backend 固定安装到 `$HOME/.hermes`；可用 `--applications-dir` 调整 `Hermes.app` 目录。所有安装目标都必须位于当前用户 HOME 下，且不得包含 symlink 或与离线包目录重叠。

安装失败时，旧的 `hermes-agent`、runtime、Node、命令链接、安装报告和 `Hermes.app` 会从 `~/.hermes/offline-backups/` 自动回滚；配置、sessions、skills 和 memory 不会被删除。
