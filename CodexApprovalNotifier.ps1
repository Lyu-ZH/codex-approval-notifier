param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE ".codex"),
    [int]$PollSeconds = 2,
    [int]$CatchUpMinutes = 0,
    [int]$CatchUpSeconds = 0,
    [int]$RepeatMinutes = 3,
    [switch]$EnableApprovalAlert,
    [switch]$DisableUserInputAlert = $true,
    [switch]$TestAlert,
    [string]$AlertFile = "",
    [switch]$Once,
    [switch]$DryRun,
    [int]$AutoCloseSeconds = 0,
    [switch]$DisableCompletionAlert,
    [switch]$EnableTurnCompletionAlert = $true,
    [switch]$DisableGoalCompleteAlert,
    [switch]$DisableInterruptedAlert,
    [switch]$TestCompletionAlert,
    [switch]$TestGoalCompleteAlert,
    [switch]$TestInterruptedAlert,
    [switch]$TestFailedTurnAlert,
    [switch]$DisableLockScreenDesktopSkip,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:SeenCalls = @{}
$script:FileOffsets = @{}
$script:SessionVisibility = @{}
$script:LastAlertByKey = @{}
$script:LogPath = Join-Path $PSScriptRoot "notifier.log"
$script:Mutex = $null
$script:StartedAt = [DateTimeOffset]::UtcNow
$script:EventCutoff = $script:StartedAt.AddSeconds(-[Math]::Max($CatchUpSeconds, $CatchUpMinutes * 60))

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    if (-not $Quiet) {
        Write-Host $line
    }
}

function ConvertTo-LocalText {
    param([string]$UtcText)
    if ([string]::IsNullOrWhiteSpace($UtcText)) {
        return (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    try {
        return ([DateTimeOffset]::Parse($UtcText).ToLocalTime()).ToString("yyyy-MM-dd HH:mm:ss")
    } catch {
        return $UtcText
    }
}

function Test-IsWindowsLocked {
    if ($DisableLockScreenDesktopSkip) {
        return $false
    }

    try {
        $user32 = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CodexNotifierUser32 {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SwitchDesktop(IntPtr hDesktop);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool GetUserObjectInformation(IntPtr hObj, int nIndex, StringBuilder pvInfo, int nLength, out int lpnLengthNeeded);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool CloseDesktop(IntPtr hDesktop);

    public const int UOI_NAME = 2;
    public const uint DESKTOP_READOBJECTS = 0x0001;
    public const uint DESKTOP_SWITCHDESKTOP = 0x0100;
}
"@
        if (-not ([System.Management.Automation.PSTypeName]"CodexNotifierUser32").Type) {
            Add-Type -TypeDefinition $user32
        }

        $desiredAccess = [CodexNotifierUser32]::DESKTOP_READOBJECTS -bor [CodexNotifierUser32]::DESKTOP_SWITCHDESKTOP
        $desktop = [CodexNotifierUser32]::OpenInputDesktop(0, $false, $desiredAccess)
        if ($desktop -eq [IntPtr]::Zero) {
            Write-Log "Windows lock check: OpenInputDesktop returned no desktop; treating as locked."
            return $true
        }

        try {
            $needed = 0
            $nameBuffer = New-Object System.Text.StringBuilder 256
            $gotName = [CodexNotifierUser32]::GetUserObjectInformation($desktop, [CodexNotifierUser32]::UOI_NAME, $nameBuffer, $nameBuffer.Capacity, [ref]$needed)
            $desktopName = ""
            if ($gotName) {
                $desktopName = $nameBuffer.ToString()
            }

            $canSwitch = [CodexNotifierUser32]::SwitchDesktop($desktop)
            if ($desktopName -and $desktopName -ne "Default") {
                Write-Log ("Windows lock check: input desktop is {0}; treating as locked." -f $desktopName)
                return $true
            }
            if (-not $canSwitch) {
                Write-Log "Windows lock check: SwitchDesktop failed; treating as locked."
                return $true
            }
            return $false
        } finally {
            [void][CodexNotifierUser32]::CloseDesktop($desktop)
        }
    } catch {
        Write-Log ("Could not detect lock screen state; desktop alert will be skipped to avoid lock-screen popups: {0}" -f $_.Exception.Message)
        return $true
    }
}

function Get-RequestKey {
    param($Event)
    $kind = Get-EventKind -Event $Event
    if ($Event.CallId) {
        return "{0}|{1}|{2}" -f $kind, $Event.File, $Event.CallId
    }
    return "{0}|{1}|{2}|{3}" -f $kind, $Event.File, $Event.Timestamp, $Event.Command
}

function Get-EventKind {
    param($Event)
    if ($null -ne $Event -and $Event.PSObject.Properties.Name -contains "Kind") {
        $kind = [string]$Event.Kind
        if (-not [string]::IsNullOrWhiteSpace($kind)) {
            return $kind
        }
    }
    return "approval"
}

function Get-EventText {
    param($Event)
    $kind = Get-EventKind -Event $Event
    if ($kind -eq "user_input") {
        return [pscustomobject]@{
            DesktopTitle = "Codex needs your input"
            DialogTitle = "Codex needs your input"
            Subtitle = "Codex has a question for you. Open the conversation to respond."
            MobileTitle = "Codex 等待你的回复"
            MobileSummary = "有新的交互请求，请回到 Codex 查看并回复。"
            LogPrefix = "User input request detected"
        }
    }
    if ($kind -eq "goal_complete") {
        return [pscustomobject]@{
            DesktopTitle = "Codex goal complete"
            DialogTitle = "Codex goal complete"
            Subtitle = "Codex has completed the active Goal. Switch back to Codex to review it."
            MobileTitle = "Codex Goal 已完成"
            MobileSummary = "Goal 模式任务已完成，请回到 Codex 查看。"
            LogPrefix = "Codex goal completed"
        }
    }
    if ($kind -eq "task_complete") {
        return [pscustomobject]@{
            DesktopTitle = "Codex turn finished"
            DialogTitle = "Codex turn finished"
            Subtitle = "Codex has finished this response turn. Switch back to Codex to review it."
            MobileTitle = "Codex 回答已完成"
            MobileSummary = "Codex 本轮回答已结束，请回到 Codex 查看。"
            LogPrefix = "Codex turn completed"
        }
    }
    if ($kind -eq "turn_aborted") {
        return [pscustomobject]@{
            DesktopTitle = "Codex turn interrupted"
            DialogTitle = "Codex turn interrupted"
            Subtitle = "Codex stopped before finishing this response. Switch back to Codex to check what happened."
            MobileTitle = "Codex 对话已中断"
            MobileSummary = "Codex 本轮对话意外中断，请回到 Codex 查看。"
            LogPrefix = "Codex turn interrupted"
        }
    }
    if ($kind -eq "turn_failed") {
        return [pscustomobject]@{
            DesktopTitle = "Codex turn failed"
            DialogTitle = "Codex turn failed"
            Subtitle = "Codex hit an error before finishing this response. Switch back to Codex to check what happened."
            MobileTitle = "Codex 对话出错"
            MobileSummary = "Codex 本轮对话因错误中断，请回到 Codex 查看。"
            LogPrefix = "Codex turn failed"
        }
    }

    return [pscustomobject]@{
        DesktopTitle = "Codex approval request"
        DialogTitle = "Codex approval request"
        Subtitle = "An approval request was issued. Automatic review may handle it; check Codex for its status."
        MobileTitle = "Codex 审批请求"
        MobileSummary = "检测到审批请求，请回到 Codex 查看；自动审批可能已处理。"
        LogPrefix = "Approval request detected"
    }
}

function Get-ShortText {
    param(
        [string]$Text,
        [int]$MaxLength = 380
    )
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    $singleLine = ($Text -replace "\s+", " ").Trim()
    if ($singleLine.Length -le $MaxLength) {
        return $singleLine
    }
    return $singleLine.Substring(0, $MaxLength - 3) + "..."
}

function Get-PayloadTextProperty {
    param(
        $Payload,
        [string]$Name
    )
    if ($null -eq $Payload) {
        return ""
    }
    if ($Payload.PSObject.Properties.Name -contains $Name) {
        return [string]$Payload.PSObject.Properties[$Name].Value
    }
    return ""
}

function Get-JavaScriptStringProperty {
    param(
        [string]$Source,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    $escapedName = [regex]::Escape($Name)
    $doublePattern = '["'']?\b{0}["'']?\s*:\s*"(?<value>(?:\\.|[^"\\])*)"' -f $escapedName
    $match = [regex]::Match($Source, $doublePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($match.Success) {
        $literal = '"' + $match.Groups["value"].Value + '"'
        try {
            return [string]($literal | ConvertFrom-Json)
        } catch {
            return [string]$match.Groups["value"].Value
        }
    }

    $singlePattern = '["'']?\b{0}["'']?\s*:\s*''(?<value>(?:\\.|[^''\\])*)''' -f $escapedName
    $match = [regex]::Match($Source, $singlePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($match.Success) {
        try {
            return [regex]::Unescape([string]$match.Groups["value"].Value)
        } catch {
            return [string]$match.Groups["value"].Value
        }
    }

    return ""
}

function Get-NestedCustomToolName {
    param([string]$Source)

    if ([string]::IsNullOrWhiteSpace($Source)) {
        return ""
    }
    $match = [regex]::Match($Source, '\btools\.([A-Za-z0-9_]+)\s*\(')
    if ($match.Success) {
        return [string]$match.Groups[1].Value
    }
    return ""
}

function Test-IsApprovalCall {
    param($Json)

    if ($null -eq $Json -or $Json.type -ne "response_item") {
        return $null
    }
    if ($null -eq $Json.payload) {
        return $null
    }

    $payloadType = Get-PayloadTextProperty -Payload $Json.payload -Name "type"
    $tool = Get-PayloadTextProperty -Payload $Json.payload -Name "name"
    $argumentsText = ""
    $command = ""
    $justification = ""
    $prefixRule = ""

    if ($payloadType -eq "function_call") {
        $argumentsText = Get-PayloadTextProperty -Payload $Json.payload -Name "arguments"
        if ([string]::IsNullOrWhiteSpace($argumentsText) -or
            $argumentsText -notmatch '"sandbox_permissions"\s*:\s*"require_escalated"') {
            return $null
        }

        try {
            $args = $argumentsText | ConvertFrom-Json
        } catch {
            $args = $null
        }
        if ($null -ne $args) {
            if ($args.PSObject.Properties.Name -contains "command") {
                $command = [string]$args.command
            } elseif ($args.PSObject.Properties.Name -contains "cmd") {
                $command = [string]$args.cmd
            }
            if ($args.PSObject.Properties.Name -contains "justification") {
                $justification = [string]$args.justification
            }
            if ($args.PSObject.Properties.Name -contains "prefix_rule") {
                $prefixRule = ($args.prefix_rule | ConvertTo-Json -Compress)
            }
        }
    } elseif ($payloadType -eq "custom_tool_call") {
        $argumentsText = Get-PayloadTextProperty -Payload $Json.payload -Name "input"
        if ([string]::IsNullOrWhiteSpace($argumentsText) -or
            $argumentsText -notmatch '["'']?\bsandbox_permissions["'']?\s*:\s*["'']require_escalated["'']') {
            return $null
        }

        $nestedTool = Get-NestedCustomToolName -Source $argumentsText
        if (-not [string]::IsNullOrWhiteSpace($nestedTool)) {
            $tool = $nestedTool
        }
        $command = Get-JavaScriptStringProperty -Source $argumentsText -Name "command"
        if (-not $command) { $command = Get-JavaScriptStringProperty -Source $argumentsText -Name "cmd" }
        $justification = Get-JavaScriptStringProperty -Source $argumentsText -Name "justification"
    } else {
        return $null
    }

    return [pscustomobject]@{
        Kind = "approval"
        Timestamp = [string]$Json.timestamp
        Tool = $tool
        CallId = Get-PayloadTextProperty -Payload $Json.payload -Name "call_id"
        Command = $command
        Justification = $justification
        PrefixRule = $prefixRule
        RawArguments = $argumentsText
        File = ""
    }
}

function Test-IsUserInputCall {
    param($Json)
    if ($DisableUserInputAlert -or $null -eq $Json -or $Json.type -ne "response_item" -or $null -eq $Json.payload) {
        return $null
    }
    $payload = $Json.payload
    $type = Get-PayloadTextProperty $payload "type"
    $tool = Get-PayloadTextProperty $payload "name"
    $argumentsText = ""
    $summary = ""
    if ($type -eq "function_call") {
        if ($tool -notmatch '(^|[._])request_(user_input(?:_async)?|permissions)$') { return $null }
        $argumentsText = Get-PayloadTextProperty $payload "arguments"
        try {
            $request = $argumentsText | ConvertFrom-Json
            if ($request.PSObject.Properties.Name -contains "questions") {
                $questions = @($request.questions | ForEach-Object {
                    $question = Get-PayloadTextProperty $_ "question"
                    if (-not $question) { $question = Get-PayloadTextProperty $_ "title" }
                    if ($question) { $question }
                })
                $summary = $questions -join "；"
            }
            if (-not $summary) { $summary = Get-PayloadTextProperty $request "reason" }
        } catch { }
    } elseif ($type -eq "custom_tool_call") {
        $argumentsText = Get-PayloadTextProperty $payload "input"
        $requestMatch = [regex]::Match($argumentsText, '\btools\.([A-Za-z0-9_]*request_(?:user_input(?:_async)?|permissions))\s*\(')
        if (-not $requestMatch.Success) { return $null }
        $tool = $requestMatch.Groups[1].Value
        $summary = Get-JavaScriptStringProperty $argumentsText "question"
        if (-not $summary) { $summary = Get-JavaScriptStringProperty $argumentsText "title" }
    } else { return $null }
    return [pscustomobject]@{
        Kind = "user_input"
        Timestamp = [string]$Json.timestamp
        Tool = $tool
        CallId = Get-PayloadTextProperty $payload "call_id"
        Command = ""
        Justification = $summary
        PrefixRule = ""
        RawArguments = ""
        File = ""
    }
}

function Test-IsFailedTurnComplete {
    param($Json)

    if ($DisableInterruptedAlert) {
        return $null
    }
    if ($null -eq $Json -or $Json.type -ne "event_msg") {
        return $null
    }
    if ($null -eq $Json.payload -or $Json.payload.type -ne "task_complete") {
        return $null
    }
    if (-not ($Json.payload.PSObject.Properties.Name -contains "error") -or $null -eq $Json.payload.error) {
        return $null
    }

    $turnId = Get-PayloadTextProperty -Payload $Json.payload -Name "turn_id"
    $message = ""
    $errorInfo = ""
    if ($Json.payload.error.PSObject.Properties.Name -contains "message") {
        $message = [string]$Json.payload.error.message
    }
    if ($Json.payload.error.PSObject.Properties.Name -contains "codex_error_info") {
        $errorInfo = [string]$Json.payload.error.codex_error_info
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        try {
            $message = ($Json.payload.error | ConvertTo-Json -Compress)
        } catch {
            $message = "Unknown Codex error"
        }
    }

    $durationText = ""
    if ($Json.payload.PSObject.Properties.Name -contains "duration_ms") {
        $durationMs = [int64]$Json.payload.duration_ms
        if ($durationMs -gt 0) {
            $durationText = "，已运行约 {0:N1} 秒" -f ($durationMs / 1000.0)
        }
    }

    $summary = "Codex 本轮对话因错误中断{0}，请回到 Codex 查看。" -f $durationText
    $detail = Get-ShortText $message 1200
    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        $summary = "{0}`r`n错误: {1}" -f $summary, $detail
    }
    if (-not [string]::IsNullOrWhiteSpace($errorInfo)) {
        $summary = "{0}`r`n类型: {1}" -f $summary, $errorInfo
    }

    return [pscustomobject]@{
        Kind = "turn_failed"
        Timestamp = [string]$Json.timestamp
        Tool = ""
        CallId = $turnId
        Command = "Codex turn failed"
        Justification = $summary
        PrefixRule = ""
        RawArguments = $message
        File = ""
    }
}

function Test-IsTaskComplete {
    param($Json)

    if ($DisableCompletionAlert -or -not $EnableTurnCompletionAlert) {
        return $null
    }
    if ($null -eq $Json -or $Json.type -ne "event_msg") {
        return $null
    }
    if ($null -eq $Json.payload -or $Json.payload.type -ne "task_complete") {
        return $null
    }

    return [pscustomobject]@{
        Kind = "task_complete"
        Timestamp = [string]$Json.timestamp
        Tool = ""
        CallId = Get-PayloadTextProperty $Json.payload "turn_id"
        Command = "Codex answer finished"
        Justification = "Codex 本轮回答已结束，请回到 Codex 查看。"
        PrefixRule = ""
        RawArguments = ""
        File = ""
    }
}

function Test-IsTurnInterrupted {
    param($Json)

    if ($DisableInterruptedAlert) {
        return $null
    }
    if ($null -eq $Json -or $Json.type -ne "event_msg") {
        return $null
    }
    if ($null -eq $Json.payload -or $Json.payload.type -ne "turn_aborted") {
        return $null
    }

    $turnId = ""
    $reason = ""
    $durationText = ""
    if ($Json.payload.PSObject.Properties.Name -contains "turn_id") {
        $turnId = [string]$Json.payload.turn_id
    }
    if ($Json.payload.PSObject.Properties.Name -contains "reason") {
        $reason = [string]$Json.payload.reason
    }
    if ($Json.payload.PSObject.Properties.Name -contains "duration_ms") {
        $durationMs = [int64]$Json.payload.duration_ms
        if ($durationMs -gt 0) {
            $durationText = "，已运行约 {0:N1} 秒" -f ($durationMs / 1000.0)
        }
    }

    $message = "Codex 本轮对话意外中断，请回到 Codex 查看。"
    if (-not [string]::IsNullOrWhiteSpace($reason)) {
        $message = "Codex 本轮对话中断，原因: {0}{1}。请回到 Codex 查看。" -f $reason, $durationText
    } elseif (-not [string]::IsNullOrWhiteSpace($durationText)) {
        $message = "Codex 本轮对话意外中断{0}，请回到 Codex 查看。" -f $durationText
    }

    return [pscustomobject]@{
        Kind = "turn_aborted"
        Timestamp = [string]$Json.timestamp
        Tool = ""
        CallId = $turnId
        Command = "Codex turn interrupted"
        Justification = $message
        PrefixRule = ""
        RawArguments = ""
        File = ""
    }
}

function Test-IsGoalComplete {
    param($Json)

    if ($DisableGoalCompleteAlert) {
        return $null
    }
    if ($null -eq $Json -or $Json.type -ne "response_item") {
        return $null
    }
    if ($null -eq $Json.payload) {
        return $null
    }

    $payloadType = Get-PayloadTextProperty -Payload $Json.payload -Name "type"
    $argumentsText = ""
    $status = ""

    if ($payloadType -eq "function_call") {
        if ((Get-PayloadTextProperty -Payload $Json.payload -Name "name") -ne "update_goal") {
            return $null
        }
        $argumentsText = Get-PayloadTextProperty -Payload $Json.payload -Name "arguments"
        if ([string]::IsNullOrWhiteSpace($argumentsText)) {
            return $null
        }
        try {
            $args = $argumentsText | ConvertFrom-Json
            if ($null -ne $args -and $args.PSObject.Properties.Name -contains "status") {
                $status = [string]$args.status
            }
        } catch {
            if ($argumentsText -match '"status"\s*:\s*"complete"') {
                $status = "complete"
            }
        }
    } elseif ($payloadType -eq "custom_tool_call") {
        $argumentsText = Get-PayloadTextProperty -Payload $Json.payload -Name "input"
        if ([string]::IsNullOrWhiteSpace($argumentsText) -or
            $argumentsText -notmatch '\btools\.update_goal\s*\(') {
            return $null
        }
        $status = Get-JavaScriptStringProperty -Source $argumentsText -Name "status"
        if ([string]::IsNullOrWhiteSpace($status) -and
            $argumentsText -match '\bstatus\s*:\s*["'']complete["'']') {
            $status = "complete"
        }
    } else {
        return $null
    }

    if ($status -ne "complete") {
        return $null
    }

    return [pscustomobject]@{
        Kind = "goal_complete"
        Timestamp = [string]$Json.timestamp
        Tool = "update_goal"
        CallId = Get-PayloadTextProperty -Payload $Json.payload -Name "call_id"
        Command = "Codex goal completed"
        Justification = "Goal 模式任务已完成，请回到 Codex 查看。"
        PrefixRule = ""
        RawArguments = $argumentsText
        File = ""
    }
}

function Show-ApprovalAlert {
    param($Event)

    $eventKind = Get-EventKind -Event $Event
    $eventText = Get-EventText -Event $Event
    $isCompletion = ($eventKind -eq "task_complete" -or $eventKind -eq "goal_complete")
    $isInterruption = ($eventKind -eq "turn_aborted" -or $eventKind -eq "turn_failed")

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $eventText.DesktopTitle
    $form.TopMost = $true
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(720, 420)
    $form.MinimumSize = New-Object System.Drawing.Size(600, 360)
    if ($isInterruption) {
        $form.BackColor = [System.Drawing.Color]::FromArgb(255, 242, 238)
    } elseif ($isCompletion) {
        $form.BackColor = [System.Drawing.Color]::FromArgb(232, 248, 241)
    } else {
        $form.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
    }
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false

    $title = New-Object System.Windows.Forms.Label
    $title.Text = $eventText.DialogTitle
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold)
    if ($isInterruption) {
        $title.ForeColor = [System.Drawing.Color]::FromArgb(132, 39, 19)
    } elseif ($isCompletion) {
        $title.ForeColor = [System.Drawing.Color]::FromArgb(16, 84, 66)
    } else {
        $title.ForeColor = [System.Drawing.Color]::FromArgb(92, 44, 0)
    }
    $title.AutoSize = $false
    $title.Location = New-Object System.Drawing.Point(24, 20)
    $title.Size = New-Object System.Drawing.Size(660, 48)
    $form.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = $eventText.Subtitle
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 12)
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(62, 62, 62)
    $subtitle.AutoSize = $false
    $subtitle.Location = New-Object System.Drawing.Point(28, 72)
    $subtitle.Size = New-Object System.Drawing.Size(650, 28)
    $form.Controls.Add($subtitle)

    $timeLabel = New-Object System.Windows.Forms.Label
    $timeLabel.Text = "Detected: {0}" -f (ConvertTo-LocalText $Event.Timestamp)
    $timeLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $timeLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $timeLabel.AutoSize = $false
    $timeLabel.Location = New-Object System.Drawing.Point(28, 106)
    $timeLabel.Size = New-Object System.Drawing.Size(650, 24)
    $form.Controls.Add($timeLabel)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = "Vertical"
    $box.Font = New-Object System.Drawing.Font("Consolas", 10)
    $box.BackColor = [System.Drawing.Color]::White
    $box.Location = New-Object System.Drawing.Point(28, 140)
    $box.Size = New-Object System.Drawing.Size(650, 160)

    $details = @()
    if ($isCompletion) {
        if ($Event.Justification) {
            $details += $Event.Justification
        } else {
            $details += $eventText.MobileSummary
        }
        if ($Event.File) {
            $details += "Session: " + [System.IO.Path]::GetFileName([string]$Event.File)
        }
    } elseif ($isInterruption) {
        if ($Event.Justification) {
            $details += $Event.Justification
        } else {
            $details += $eventText.MobileSummary
        }
        if ($Event.CallId) {
            $details += "Turn: " + [string]$Event.CallId
        }
        if ($Event.File) {
            $details += "Session: " + [System.IO.Path]::GetFileName([string]$Event.File)
        }
    } else {
        if ($Event.Justification) {
            $details += "Reason: " + (Get-ShortText $Event.Justification 800)
        }
        if ($Event.Command) {
            $details += "Command: " + (Get-ShortText $Event.Command 1200)
        }
        if ($Event.PrefixRule) {
            $details += "Reusable rule: " + (Get-ShortText $Event.PrefixRule 500)
        }
        if ($details.Count -eq 0) {
            $details += "A Codex approval request was detected."
        }
    }
    $box.Text = ($details -join [Environment]::NewLine)
    $form.Controls.Add($box)

    $openButton = New-Object System.Windows.Forms.Button
    $openButton.Text = "Open Cursor"
    $openButton.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $openButton.Location = New-Object System.Drawing.Point(28, 318)
    $openButton.Size = New-Object System.Drawing.Size(140, 42)
    $openButton.Add_Click({
        try {
            Start-Process "cursor:"
        } catch {
            try {
                Start-Process "cursor"
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Could not open Cursor automatically. Please switch to Cursor manually.", "Codex notifier")
            }
        }
    })
    $form.Controls.Add($openButton)

    $dismissButton = New-Object System.Windows.Forms.Button
    $dismissButton.Text = "Dismiss"
    $dismissButton.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $dismissButton.Location = New-Object System.Drawing.Point(538, 318)
    $dismissButton.Size = New-Object System.Drawing.Size(140, 42)
    $dismissButton.Add_Click({ $form.Close() })
    $form.Controls.Add($dismissButton)

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = "Copy Details"
    $copyButton.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $copyButton.Location = New-Object System.Drawing.Point(386, 318)
    $copyButton.Size = New-Object System.Drawing.Size(140, 42)
    $copyButton.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($box.Text)
    })
    $form.Controls.Add($copyButton)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 800
    $timer.Tag = 0
    $timer.Add_Tick({
        $flashState = [int]$timer.Tag
        if ($isInterruption -and $flashState % 2 -eq 0) {
            $form.BackColor = [System.Drawing.Color]::FromArgb(255, 229, 222)
        } elseif ($isInterruption) {
            $form.BackColor = [System.Drawing.Color]::FromArgb(255, 242, 238)
        } elseif ($isCompletion -and $flashState % 2 -eq 0) {
            $form.BackColor = [System.Drawing.Color]::FromArgb(221, 244, 234)
        } elseif ($isCompletion) {
            $form.BackColor = [System.Drawing.Color]::FromArgb(232, 248, 241)
        } elseif ($flashState % 2 -eq 0) {
            $form.BackColor = [System.Drawing.Color]::FromArgb(255, 245, 200)
        } else {
            $form.BackColor = [System.Drawing.Color]::FromArgb(255, 252, 235)
        }
        $timer.Tag = $flashState + 1
        if ($flashState -gt 8) {
            $timer.Stop()
        }
    })
    $form.Add_Shown({
        $form.Activate()
        $timer.Start()
        if ($isCompletion) {
            [System.Media.SystemSounds]::Asterisk.Play()
        } elseif ($isInterruption) {
            for ($i = 0; $i -lt 3; $i++) {
                [System.Media.SystemSounds]::Hand.Play()
                Start-Sleep -Milliseconds 280
            }
        } else {
            for ($i = 0; $i -lt 4; $i++) {
                [System.Media.SystemSounds]::Exclamation.Play()
                Start-Sleep -Milliseconds 260
            }
        }
    })
    $form.Add_FormClosed({
        $timer.Dispose()
    })

    if ($AutoCloseSeconds -gt 0) {
        $closeTimer = New-Object System.Windows.Forms.Timer
        $closeTimer.Interval = [Math]::Max(1, $AutoCloseSeconds) * 1000
        $closeTimer.Add_Tick({
            $closeTimer.Stop()
            $form.Close()
        })
        $form.Add_Shown({ $closeTimer.Start() })
        $form.Add_FormClosed({ $closeTimer.Dispose() })
    }

    [void]$form.ShowDialog()
}

function ConvertTo-VbsStringLiteral {
    param([string]$Text)
    if ($null -eq $Text) {
        $Text = ""
    }
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $parts = @()
    foreach ($line in ($normalized -split "`n", -1)) {
        $parts += '"' + ($line -replace '"', '""') + '"'
    }
    if ($parts.Count -eq 0) {
        return '""'
    }
    return ($parts -join " & vbCrLf & ")
}

function Start-AlertProcess {
    param($Event)

    $eventKind = Get-EventKind -Event $Event
    $eventText = Get-EventText -Event $Event
    $isCompletion = ($eventKind -eq "task_complete" -or $eventKind -eq "goal_complete")
    $isInterruption = ($eventKind -eq "turn_aborted" -or $eventKind -eq "turn_failed")
    $details = @()
    $details += $eventText.DialogTitle + "."
    $details += ""
    $details += $eventText.Subtitle
    $details += ""
    $details += "Detected: " + (ConvertTo-LocalText $Event.Timestamp)
    if ($isCompletion) {
        if ($Event.File) {
            $details += "Session: " + [System.IO.Path]::GetFileName([string]$Event.File)
        }
    } elseif ($isInterruption) {
        if ($Event.Justification) {
            $details += "Reason: " + (Get-ShortText $Event.Justification 500)
        }
        if ($Event.CallId) {
            $details += "Turn: " + [string]$Event.CallId
        }
        if ($Event.File) {
            $details += "Session: " + [System.IO.Path]::GetFileName([string]$Event.File)
        }
    } else {
        if ($Event.Justification) {
            $details += "Reason: " + (Get-ShortText $Event.Justification 500)
        }
        if ($Event.Command) {
            $details += "Command: " + (Get-ShortText $Event.Command 900)
        }
    }

    $message = ($details -join "`r`n")
    $vbsPath = Join-Path $PSScriptRoot ("pending-approval-{0}.vbs" -f ([Guid]::NewGuid().ToString("N")))
    $vbsMessage = ConvertTo-VbsStringLiteral -Text $message
    $vbsTitle = ConvertTo-VbsStringLiteral -Text $eventText.DesktopTitle
    $popupSeconds = [Math]::Max(0, $AutoCloseSeconds)
    $popupStyle = 4144
    if ($isInterruption) {
        $popupStyle = 4112
    } elseif ($isCompletion) {
        $popupStyle = 4160
    }
    $vbs = @"
On Error Resume Next
Set shell = CreateObject("WScript.Shell")
msg = $vbsMessage
title = $vbsTitle
shell.Popup msg, $popupSeconds, title, $popupStyle
Set fso = CreateObject("Scripting.FileSystemObject")
fso.DeleteFile WScript.ScriptFullName, True
"@

    try {
        Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding Unicode
        Start-Process -FilePath "wscript.exe" -ArgumentList ('"{0}"' -f $vbsPath) -WindowStyle Normal
        Write-Log ("Alert popup launched via wscript: {0}" -f $vbsPath)
    } catch {
        Write-Log ("Could not start wscript alert; showing alert inline: {0}" -f $_.Exception.Message)
        Show-ApprovalAlert -Event $Event
    }
}

function Send-MobileNotification {
    param($Event)

    $configPath = Join-Path $PSScriptRoot "mobile-notify.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return
    }

    try {
        $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
        if ($null -eq $config -or -not $config.enabled) {
            return
        }
        if ([string]$config.provider -ne "bark") {
            Write-Log ("Mobile notification skipped: unsupported provider {0}" -f $config.provider)
            return
        }

        $baseUrl = ([string]$config.url).Trim().TrimEnd("/")
        if ([string]::IsNullOrWhiteSpace($baseUrl)) {
            return
        }

        $eventKind = Get-EventKind -Event $Event
        $eventText = Get-EventText -Event $Event
        $title = [uri]::EscapeDataString($eventText.MobileTitle)
        $summary = $eventText.MobileSummary
        if ($eventKind -eq "approval" -or $eventKind -eq "user_input") {
            if ($Event.Justification) {
                $summary = Get-ShortText $Event.Justification 180
            } elseif ($Event.Command) {
                $summary = "审批请求：" + (Get-ShortText $Event.Command 180)
            }
        } elseif (($eventKind -eq "turn_aborted" -or $eventKind -eq "turn_failed") -and $Event.Justification) {
            $summary = Get-ShortText $Event.Justification 180
        }
        $body = [uri]::EscapeDataString($summary)

        $query = @()
        if ($config.PSObject.Properties.Name -contains "sound" -and -not [string]::IsNullOrWhiteSpace([string]$config.sound)) {
            $query += "sound=$([uri]::EscapeDataString([string]$config.sound))"
        }
        if ($config.PSObject.Properties.Name -contains "level" -and -not [string]::IsNullOrWhiteSpace([string]$config.level)) {
            $query += "level=$([uri]::EscapeDataString([string]$config.level))"
        }
        $queryText = ""
        if ($query.Count -gt 0) {
            $queryText = "?" + ($query -join "&")
        }

        $uri = "$baseUrl/$title/$body$queryText"
        $maxAttempts = 3
        $timeoutSeconds = 12
        $retryDelaySeconds = 5
        if ($config.PSObject.Properties.Name -contains "maxAttempts") {
            $maxAttempts = [Math]::Max(1, [int]$config.maxAttempts)
        }
        if ($config.PSObject.Properties.Name -contains "timeoutSeconds") {
            $timeoutSeconds = [Math]::Max(3, [int]$config.timeoutSeconds)
        }
        if ($config.PSObject.Properties.Name -contains "retryDelaySeconds") {
            $retryDelaySeconds = [Math]::Max(1, [int]$config.retryDelaySeconds)
        }

        $lastError = $null
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                $response = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec $timeoutSeconds
                if ($response.PSObject.Properties.Name -notcontains "code" -or [int]$response.code -ne 200) {
                    throw "Bark did not acknowledge this notification with code 200."
                }
                Write-Log ("Mobile notification sent via Bark: {0} (attempt {1}/{2})" -f ($response.message | Out-String).Trim(), $attempt, $maxAttempts)
                return
            } catch {
                $lastError = $_.Exception.Message -replace 'https?://\S+', '[endpoint redacted]'
                Write-Log ("Mobile notification attempt {0}/{1} failed: {2}" -f $attempt, $maxAttempts, $lastError)
                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Seconds $retryDelaySeconds
                }
            }
        }
        Write-Log ("Mobile notification failed after {0} attempts: {1}" -f $maxAttempts, $lastError)
    } catch {
        Write-Log ("Mobile notification failed: {0}" -f ($_.Exception.Message -replace 'https?://\S+', '[endpoint redacted]'))
    }
}
function Send-AlertIfDue {
    param($Event)

    $key = Get-RequestKey $Event
    $now = Get-Date
    if ($script:LastAlertByKey.ContainsKey($key)) {
        $last = $script:LastAlertByKey[$key]
        if (($now - $last).TotalMinutes -lt $RepeatMinutes) {
            return
        }
    }
    $script:LastAlertByKey[$key] = $now
    $eventText = Get-EventText -Event $Event
    if ((Get-EventKind -Event $Event) -ne "approval") {
        Write-Log ("{0}: {1}" -f $eventText.LogPrefix, (Get-ShortText ([System.IO.Path]::GetFileName([string]$Event.File)) 180))
    } else {
        Write-Log ("{0}: {1}" -f $eventText.LogPrefix, (Get-ShortText $Event.Command 180))
    }
    if ($DryRun) {
        Write-Log "Dry run: no desktop or mobile notification was sent."
        return
    }
    try {
        if (Test-IsWindowsLocked) {
            Write-Log "Desktop alert skipped because Windows is locked; mobile notification will still be sent."
        } else {
            Start-AlertProcess -Event $Event
        }
    } catch {
        Write-Log ("Desktop notification failed: {0}" -f $_.Exception.Message)
    }
    try {
        Send-MobileNotification -Event $Event
    } catch {
        Write-Log ("Mobile notification failed: {0}" -f ($_.Exception.Message -replace 'https?://\S+', '[endpoint redacted]'))
    }
}

function Read-NewLines {
    param([System.IO.FileInfo]$File)

    $path = $File.FullName
    $start = 0L
    if ($script:FileOffsets.ContainsKey($path)) {
        $start = [int64]$script:FileOffsets[$path]
    } else {
        if ($File.LastWriteTimeUtc -ge $script:EventCutoff.UtcDateTime) {
            $start = 0L
        } else {
            $start = $File.Length
        }
    }

    if ($File.Length -lt $start) {
        $start = 0L
    }
    if ($File.Length -eq $start) {
        $script:FileOffsets[$path] = $File.Length
        return @()
    }

    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ([int]($stream.Length - $start))
        $read = 0
        while ($read -lt $buffer.Length) {
            $count = $stream.Read($buffer, $read, $buffer.Length - $read)
            if ($count -eq 0) { break }
            $read += $count
        }
        $lastNewline = $read - 1
        while ($lastNewline -ge 0 -and $buffer[$lastNewline] -ne 10) { $lastNewline-- }
        if ($lastNewline -lt 0) {
            $script:FileOffsets[$path] = $start
            return @()
        }
        $script:FileOffsets[$path] = $start + $lastNewline + 1
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $lastNewline + 1).TrimStart([char]0xFEFF)
    } finally {
        $stream.Dispose()
    }

    if ([string]::IsNullOrEmpty($text)) {
        return @()
    }
    return ($text -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-IsUserSession {
    param([System.IO.FileInfo]$File)
    if ($script:SessionVisibility.ContainsKey($File.FullName)) {
        return $script:SessionVisibility[$File.FullName]
    }
    try {
        $stream = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
            try { $firstLine = $reader.ReadLine() } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
        if (-not $firstLine) { return $false }
        $metadata = $firstLine | ConvertFrom-Json
        $visible = $true
        if ($metadata.type -eq "session_meta" -and $metadata.payload.PSObject.Properties.Name -contains "source") {
            $source = $metadata.payload.source
            if ($null -ne $source -and $source.PSObject.Properties.Name -contains "subagent") {
                $visible = $false
            }
        }
        $script:SessionVisibility[$File.FullName] = $visible
        return $visible
    } catch { return $false }
}

function Process-SessionFile {
    param([System.IO.FileInfo]$File)

    if (-not (Test-IsUserSession -File $File)) { return @() }
    $events = @()
    foreach ($line in (Read-NewLines -File $File)) {
        try {
            $json = $line | ConvertFrom-Json
            if ([DateTimeOffset]::Parse([string]$json.timestamp) -lt $script:EventCutoff) { continue }
        } catch {
            continue
        }

        $event = Test-IsUserInputCall -Json $json
        if ($null -eq $event -and $EnableApprovalAlert) {
            $event = Test-IsApprovalCall -Json $json
        }
        if ($null -eq $event) {
            $event = Test-IsGoalComplete -Json $json
        }
        if ($null -eq $event) {
            $event = Test-IsFailedTurnComplete -Json $json
        }
        if ($null -eq $event) {
            $event = Test-IsTurnInterrupted -Json $json
        }
        if ($null -eq $event) {
            $event = Test-IsTaskComplete -Json $json
        }
        if ($null -eq $event) {
            continue
        }
        $event.File = $File.FullName

        $key = Get-RequestKey $event
        if ($script:SeenCalls.ContainsKey($key)) {
            continue
        }
        $script:SeenCalls[$key] = $true
        $events += $event
    }
    return $events
}

function Get-SessionFiles {
    $sessionsPath = Join-Path $CodexHome "sessions"
    if (-not (Test-Path -LiteralPath $sessionsPath)) {
        throw "Codex sessions directory not found: $sessionsPath"
    }
    return Get-ChildItem -LiteralPath $sessionsPath -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
}

if (-not [string]::IsNullOrWhiteSpace($AlertFile)) {
    try {
        $event = Get-Content -Raw -Encoding UTF8 -LiteralPath $AlertFile | ConvertFrom-Json
        Remove-Item -LiteralPath $AlertFile -Force -ErrorAction SilentlyContinue
        Show-ApprovalAlert -Event $event
    } catch {
        Write-Log ("Could not show alert from file: {0}" -f $_.Exception.Message)
    }
    return
}

if ($TestAlert) {
    $event = [pscustomobject]@{
        Kind = "approval"
        Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        Tool = "shell_command"
        CallId = "test-alert"
        Command = "Example command requiring approval"
        Justification = "This is a test alert from CodexApprovalNotifier.ps1."
        PrefixRule = ""
        RawArguments = ""
        File = ""
    }
    Send-AlertIfDue -Event $event
    return
}

if ($TestCompletionAlert) {
    $event = [pscustomobject]@{
        Kind = "task_complete"
        Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        Tool = ""
        CallId = "test-completion-alert"
        Command = "Codex answer finished"
        Justification = "Codex 本轮回答已结束，请回到 Codex 查看。"
        PrefixRule = ""
        RawArguments = ""
        File = ""
    }
    Send-AlertIfDue -Event $event
    return
}

if ($TestGoalCompleteAlert) {
    $event = [pscustomobject]@{
        Kind = "goal_complete"
        Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        Tool = "update_goal"
        CallId = "test-goal-complete-alert"
        Command = "Codex goal completed"
        Justification = "Goal 模式任务已完成，请回到 Codex 查看。"
        PrefixRule = ""
        RawArguments = '{"status":"complete"}'
        File = ""
    }
    Send-AlertIfDue -Event $event
    return
}

if ($TestInterruptedAlert) {
    $event = [pscustomobject]@{
        Kind = "turn_aborted"
        Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        Tool = ""
        CallId = "test-interrupted-alert"
        Command = "Codex turn interrupted"
        Justification = "Codex 本轮对话意外中断，请回到 Codex 查看。"
        PrefixRule = ""
        RawArguments = ""
        File = ""
    }
    Send-AlertIfDue -Event $event
    return
}

if ($TestFailedTurnAlert) {
    $event = [pscustomobject]@{
        Kind = "turn_failed"
        Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        Tool = ""
        CallId = "test-failed-turn-alert"
        Command = "Codex turn failed"
        Justification = "这是一条模拟的 Codex 执行失败通知，用于测试双端提醒。"
        PrefixRule = ""
        RawArguments = "Simulated failure for notification test"
        File = ""
    }
    Send-AlertIfDue -Event $event
    return
}

$mutexName = "Local\CodexApprovalNotifier-" + ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Resolve-Path $PSCommandPath).Path)) -replace "[^A-Za-z0-9]", "")
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-Log "Another Codex notifier is already running. Exiting."
    return
}

Write-Log "Codex notifier started."
Write-Log ("Alerts enabled: approvals={0}, user input={1}, turn completion={2}; desktop and mobile delivery enabled." -f [bool]$EnableApprovalAlert, (-not $DisableUserInputAlert), ([bool]$EnableTurnCompletionAlert -and -not $DisableCompletionAlert))
Write-Log "Watching: $(Join-Path $CodexHome 'sessions')"
Write-Log "Press Ctrl+C in this window to stop."

try {
    while ($true) {
        try {
            foreach ($file in (Get-SessionFiles)) {
                foreach ($event in (Process-SessionFile -File $file)) {
                    Send-AlertIfDue -Event $event
                }
            }
        } catch {
            Write-Log ("Error: {0}" -f $_.Exception.Message)
        }
        if ($Once) {
            break
        }
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
    }
} finally {
    if ($null -ne $script:Mutex) {
        try {
            $script:Mutex.ReleaseMutex()
        } catch {}
        $script:Mutex.Dispose()
    }
}



