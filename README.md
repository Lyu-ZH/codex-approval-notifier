# Codex Approval Notifier

[![Windows tests](https://github.com/Lyu-ZH/codex-approval-notifier/actions/workflows/test.yml/badge.svg)](https://github.com/Lyu-ZH/codex-approval-notifier/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**更适合习惯在 Cursor 或 VS Code 中使用 Codex 插件的用户。** 在不直接使用 Codex 桌面客户端的工作流程中，编辑器内的任务消息不一定会触发系统通知，切换窗口或离开电脑后容易错过。

**支持 Windows 与 iOS 双端提醒：** Windows 端运行监视器并显示桌面弹窗，iPhone 端通过 Bark 接收推送，帮助你及时获知回答完成、任务中断或执行失败。

工具基于 PowerShell，增量读取本机 Codex 的 JSONL 会话日志，也可配合 Codex 桌面应用使用。它是独立社区工具，不是 OpenAI 官方项目。

## 当前默认行为

| 事件 | Windows 桌面 | iOS 手机（Bark） |
| --- | --- | --- |
| 每轮回答结束，包括普通回答 | 开启 | 配置后开启 |
| Goal 完成调用 | 开启 | 配置后开启 |
| 对话中断或执行失败 | 开启 | 配置后开启 |
| 审批请求，包括自动审批请求 | **默认关闭** | **默认关闭** |
| 交互提问、用户输入请求 | **默认关闭** | **默认关闭** |

- 覆盖本机用户聊天，过滤自动审批器等内部子代理会话。
- 按会话与事件去重，保留每一轮新回答的完成提醒。
- 先尝试桌面弹窗，再尝试手机推送；手机网络故障不会阻止桌面提醒。
- 支持登录自启动、意外退出后重启和定时运行检查。
- 启动时只补读指定时间范围的事件，不重放整段历史；支持尚未写完的 JSONL 记录。

## 环境要求

- Windows 10 / 11，Windows PowerShell 5.1。
- Codex 在本机生成会话日志，默认目录为 `%USERPROFILE%\.codex\sessions`。
- Windows Script Host 可用。桌面提醒使用 `wscript.exe` 弹窗，**不是 Windows 通知中心的 Toast 通知**。
- 如需手机提醒，在 iPhone 上安装 Bark 并准备个人推送地址；不配置手机也可以使用 Windows 桌面提醒。

无需安装 Python、Node.js 或第三方 PowerShell 模块。

## 快速开始

1. 在 [Releases](https://github.com/Lyu-ZH/codex-approval-notifier/releases) 下载 Windows ZIP 并解压，或克隆本仓库。
2. 双击 `start-notifier.bat`。手动运行期间保留 PowerShell 窗口。
3. 使用 Codex 完成一轮对话，观察桌面提醒。

需要长期后台运行时，双击 `install-startup.bat`。它会安装或更新名为 `Codex Approval Notifier` 的当前用户计划任务，在登录时启动，并在异常退出后尝试重启。安装程序会停止已有的同名脚本进程；请先关闭不需要替换的其他副本。

停止后台运行并取消自启动：双击 `uninstall-startup.bat`。手动运行的实例可通过关闭窗口或按 `Ctrl+C` 停止。

## 配置手机通知

1. 将 `mobile-notify.example.json` 复制为同目录下的 `mobile-notify.json`。
2. 将 `url` 中的 `YOUR_DEVICE_KEY` 替换为自己的 Bark 设备 Key，也可使用自己部署的 Bark 服务地址。
3. 将 `enabled` 改为 `true`，保存配置。

```json
{
  "enabled": true,
  "provider": "bark",
  "url": "https://api.day.app/YOUR_DEVICE_KEY",
  "sound": "bell",
  "level": "active",
  "maxAttempts": 3,
  "timeoutSeconds": 12,
  "retryDelaySeconds": 5
}
```

`mobile-notify.json` 已加入 `.gitignore`，不要提交自己的设备 Key。开启手机推送后，事件摘要会发送到所配置的 Bark 服务；启用请求提醒时，摘要可能包含请求说明或截短的命令，错误提醒可能包含错误信息。

电脑锁屏时跳过桌面弹窗，仍尝试手机推送。日志中的 Bark `success` 表示服务器接受了推送，不保证手机已经显示；手机的联网状态、通知权限和专注模式也会影响显示。

## 可选设置

默认启动脚本保持请求提醒关闭。需要重新启用审批及交互提问提醒时，在 **PowerShell 窗口**中运行：

```powershell
.\CodexApprovalNotifier.ps1 -EnableApprovalAlert -DisableUserInputAlert:$false
```

自动审批模式下，审批请求可能在通知到达前已经处理，通知并不表示请求仍在等待人工确认。

指定其他 Codex 数据目录：

```powershell
.\CodexApprovalNotifier.ps1 -CodexHome 'D:\YourCodexHome'
```

常用参数：

| 参数 | 作用 |
| --- | --- |
| `-PollSeconds 2` | 日志轮询间隔，默认 2 秒 |
| `-CatchUpSeconds 30` | 启动时检查最近 30 秒的事件 |
| `-DisableCompletionAlert` | 关闭普通回答结束提醒 |
| `-DisableGoalCompleteAlert` | 关闭 Goal 完成调用提醒 |
| `-DisableInterruptedAlert` | 关闭中断和失败提醒 |
| `-AutoCloseSeconds 30` | 弹窗 30 秒后自动关闭；默认等待手动关闭 |
| `-Once -DryRun` | 只扫描一次，不发送桌面或手机通知 |

## 测试

双击 `test-alert.bat`，主动发送一次审批测试弹窗及已配置的手机推送。此手动测试不受“日常请求提醒关闭”的设置限制。

模拟一次回答完成通知：

```powershell
.\CodexApprovalNotifier.ps1 -TestCompletionAlert -AutoCloseSeconds 30
```

仅检查事件识别、不发送通知：

```powershell
.\CodexApprovalNotifier.ps1 -Once -DryRun -CatchUpMinutes 10
```

运行自动测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Notifier.ps1
```

测试使用合成日志和模拟通知函数，不会联系 Bark 或弹出窗口。GitHub Actions 在 Windows 上运行同一套测试。

## 工作方式与限制

程序读取日志中的 `task_complete`、`turn_aborted` 及相关工具调用来生成提醒。Goal 提醒依据 `update_goal(status="complete")` 调用，未进一步核验调用结果。日志格式变化可能需要更新解析器。

程序不会自动批准或拒绝请求，不修改 Codex 的审批模式、聊天日志或编辑器配置。运行日志保存在 `notifier.log`，用于检查检测与发送结果。关闭普通弹窗不会自动打开其他编辑器。

版本记录见 [CHANGELOG.md](CHANGELOG.md)。本项目采用 [MIT License](LICENSE)。
