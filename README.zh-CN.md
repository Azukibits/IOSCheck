# IOSCheck

[English](README.md)

`IOSCheck` 是一个原生 `macOS` 图形界面工具，用来管理多个 Apple 账号，并尽量减少你在登录时反复手动输入的次数。

它不绕过苹果受保护的登录流程，而是走一个现实可行的方向：

- 本地保存账号元数据
- 使用 `macOS Keychain` 保存密码
- 在 `macOS` 当前焦点输入框里自动填充 `Apple ID` 或密码

## 功能特性

- 原生 `AppKit` 图形界面
- 多 Apple 账号资料管理
- 密码通过 `Security.framework` 写入系统钥匙串
- 一键复制 `Apple ID`
- 一键复制密码
- 延时自动填充 `Apple ID`
- 延时自动填充密码
- 密码复制到剪贴板后 `60` 秒自动清空

## 安全设计

- 账号元数据与密码强制分离
- 本地文件只保存别名和 `Apple ID`
- 密码仅保存到系统 `Keychain`
- 本地配置目录权限会收紧到当前用户
- 主界面不会长期明文显示密码
- 敏感剪贴板内容会在 `60` 秒后自动清空

## 自动填充说明

`IOSCheck` 的自动填充不是直接入侵别的程序输入框，而是通过这条链路完成：

1. `Apple ID` 会先进入剪贴板，再延时发送一次 `Cmd+V`
2. 密码会在延时后通过辅助功能模拟逐字键入
3. 你在倒计时内切换到目标输入框

这要求：

- 你为 `IOSCheck` 开启 `辅助功能` 权限
- 目标是可接收键盘输入的 `macOS` 输入框

这个功能适合：

- 桌面网页登录框
- macOS 应用里的账号输入框
- 你自己控制焦点切换的场景

## 重要限制

- 它不能直接切换 `iPhone/iPad` 的 `iCloud`
- 它不能直接完成 iOS 上受保护的 Apple 登录流程
- 如果目标输入框屏蔽辅助功能注入，它也无法强制写入

如果你想要的是“在 iPhone 系统登录界面里由第三方程序自动帮你填完并提交”，那不是这个层级的应用能做到的。

## 构建方式

```bash
cmake -S . -B build
cmake --build build
```

如果 `cmake` 不在 `PATH`：

```bash
/Applications/CLion.app/Contents/bin/cmake/mac/aarch64/bin/cmake -S . -B build
/Applications/CLion.app/Contents/bin/cmake/mac/aarch64/bin/cmake --build build
```

产物位置：

```text
build/IOSCheck.app
```

## 首次打开说明

当前发布版本还没有 Apple Developer 签名和公证。

如果你从 GitHub 下载后看到“已损坏”或“无法验证开发者”，这通常是 `macOS Gatekeeper` 拦截了未签名应用，不是包体本身坏了。

可用方式：

1. 打开 `.dmg`
2. 把 `IOSCheck.app` 拖到 `Applications`
3. 双击 `Open IOSCheck.command`

这个脚本会尝试移除隔离标记并启动应用。

## 技术栈

- `Objective-C++`
- `AppKit`
- `Security.framework`
- `CMake`
