# Hermes Agent macOS 双架构离线包构建器

本工程在 GitHub Actions 的真实 macOS runner 上生成并验证：

- `Hermes-Offline-macOS-arm64-0.18.2.zip`：Apple Silicon
- `Hermes-Offline-macOS-x64-0.18.2.zip`：Intel Mac

固定上游版本：

- Hermes Agent `0.18.2`
- tag `v2026.7.7.2`
- commit `9de9c25f620ff7f1ce0fd5457d596052d5159596`

## 使用

1. 将本工程推送到 GitHub 仓库。
2. 打开 Actions → **Build Hermes macOS offline bundles**。
3. 点击 **Run workflow**。
4. 两个矩阵任务通过后下载 Artifacts。

工作流在最终 ZIP 上传前完成：固定提交和外部资产 SHA-256 校验、Python 依赖构建、Desktop 原生构建、Mach-O/native module 检查、payload 与 bundle SHA-256、内核级断网沙箱安装、CLI/import/Node/rg/Electron GUI 探针、codesign 与 Gatekeeper 状态记录、ZIP 解压回读和第二次安装验证。每个 ZIP 还会生成 GitHub build provenance attestation。

下载后可验证构建来源：

```bash
gh attestation verify Hermes-Offline-macOS-arm64-0.18.2.zip \
  --repo smartwang/hermes-offline-macos-builder
```

## 本地静态检查

```bash
bash -n scripts/build-macos-offline.sh
bash -n templates/install-offline.sh
bash -n templates/install-offline.command
python scripts/manifest_tool.py --help
python -m unittest discover -s tests -v
python scripts/validate_project.py
```

Windows 只能执行静态检查；最终原生构建和运行验证必须由工作流的 macOS runner 完成。
