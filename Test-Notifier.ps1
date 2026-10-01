param([string]$NotifierPath = (Join-Path $PSScriptRoot 'CodexApprovalNotifier.ps1'))
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $PSScriptRoot ('test-data-' + [guid]::NewGuid().ToString('N'))
$testSessions = Join-Path $testRoot 'sessions'
New-Item -ItemType Directory -Path $testSessions -Force | Out-Null
try {
. $NotifierPath -CodexHome $testRoot -Once -DryRun -Quiet
$script:Passed = 0
function Assert-True($Condition, [string]$Label) {
    if (-not $Condition) { throw "FAILED: $Label" }
    $script:Passed++
    Write-Output "PASS: $Label"
}
function New-ToolEvent([string]$Name, [string]$Arguments, [string]$CallId = 'call-1') {
    [pscustomobject]@{ type='response_item'; timestamp=[DateTimeOffset]::UtcNow.ToString('o'); payload=[pscustomobject]@{type='function_call';name=$Name;arguments=$Arguments;call_id=$CallId} }
}
function New-CustomEvent([string]$InputText) {
    [pscustomobject]@{type='response_item';timestamp=[DateTimeOffset]::UtcNow.ToString('o');payload=[pscustomobject]@{type='custom_tool_call';name='exec';input=$InputText;call_id='custom-1'}}
}
function New-EndEvent([string]$TurnId) {
    [pscustomobject]@{type='event_msg';timestamp=[DateTimeOffset]::UtcNow.ToString('o');payload=[pscustomobject]@{type='task_complete';turn_id=$TurnId}}
}
Assert-True (-not $EnableApprovalAlert -and $DisableUserInputAlert -and $EnableTurnCompletionAlert) 'requests default to disabled while every-turn alerts stay enabled'
$defaultPath = Join-Path $testSessions 'default-settings.jsonl'
$defaultRecords = @(
    (New-ToolEvent 'exec_command' '{"cmd":"echo test","sandbox_permissions":"require_escalated"}' 'default-approval'),
    (New-ToolEvent 'request_user_input_async' '{"questions":[{"title":"Test?"}]}' 'default-question'),
    (New-EndEvent 'default-completion')
)
$defaultText = ($defaultRecords | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 }) -join "`n"
[IO.File]::WriteAllText($defaultPath,$defaultText + "`n",[Text.UTF8Encoding]::new($false))
$defaultResults = @(Process-SessionFile (Get-Item -LiteralPath $defaultPath))
Assert-True ($defaultResults.Count -eq 1 -and $defaultResults[0].Kind -eq 'task_complete') 'default pipeline ignores both request types and retains completion'
$EnableApprovalAlert = $true
$DisableUserInputAlert = $false
$event = Test-IsApprovalCall (New-ToolEvent 'exec_command' '{"cmd":"echo test","sandbox_permissions":"require_escalated","justification":"permission test"}')
Assert-True ($event.Kind -eq 'approval' -and $event.Command -eq 'echo test') 'direct approval recognizes cmd'
$event = Test-IsApprovalCall (New-CustomEvent 'await tools.exec_command({"cmd":"echo custom","sandbox_permissions":"require_escalated","justification":"quoted keys"});')
Assert-True ($event.Kind -eq 'approval' -and $event.Command -eq 'echo custom' -and $event.Justification -eq 'quoted keys') 'wrapped approval recognizes quoted JavaScript keys'
$event = Test-IsApprovalCall (New-CustomEvent "await tools.exec_command({cmd:'echo single',sandbox_permissions:'require_escalated'});")
Assert-True ($event.Command -eq 'echo single') 'wrapped approval recognizes single-quoted values'
$event = Test-IsUserInputCall (New-ToolEvent 'request_user_input_async' '{"questions":[{"title":"Test question?"}]}')
Assert-True ($event.Kind -eq 'user_input' -and $event.Justification -eq 'Test question?') 'async question includes question text'
$event = Test-IsUserInputCall (New-ToolEvent 'functions.request_user_input' '{"questions":[{"question":"Choose one"}]}')
Assert-True ($event.Kind -eq 'user_input') 'namespaced synchronous questions are recognized'
$event = Test-IsUserInputCall (New-CustomEvent 'await tools.request_user_input_async({questions:[{title:"Wrapped question"}]});')
Assert-True ($event.Kind -eq 'user_input' -and $event.Justification -eq 'Wrapped question') 'wrapped questions are recognized'
Assert-True ($null -eq (Test-IsUserInputCall (New-ToolEvent 'exec_command' '{}'))) 'ordinary tool calls do not trigger input alerts'
$event = Test-IsTaskComplete (New-EndEvent 'turn-a')
Assert-True ($event.Kind -eq 'task_complete' -and $event.CallId -eq 'turn-a') 'normal response completion uses the turn ID'
$DisableCompletionAlert = $true
Assert-True ($null -eq (Test-IsTaskComplete (New-EndEvent 'disabled'))) 'completion opt-out still works'
$DisableCompletionAlert = $false
$script:EventCutoff = [DateTimeOffset]::UtcNow.AddMinutes(-1)
$pathA = Join-Path $testSessions 'a.jsonl'
$old = New-EndEvent 'old-turn'
$old.timestamp = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
$fresh = New-EndEvent 'same-turn'
$lines = ($old | ConvertTo-Json -Compress -Depth 8) + "`n" + ($fresh | ConvertTo-Json -Compress -Depth 8) + "`n"
[IO.File]::WriteAllText($pathA,$lines,[Text.UTF8Encoding]::new($false))
$events = @(Process-SessionFile (Get-Item -LiteralPath $pathA))
Assert-True ($events.Count -eq 1 -and $events[0].CallId -eq 'same-turn') 'startup filters old events from recently updated files'
Assert-True (@(Process-SessionFile (Get-Item -LiteralPath $pathA)).Count -eq 0) 'unchanged file is not replayed'
[IO.File]::AppendAllText($pathA,($fresh | ConvertTo-Json -Compress -Depth 8) + "`n",[Text.UTF8Encoding]::new($false))
Assert-True (@(Process-SessionFile (Get-Item -LiteralPath $pathA)).Count -eq 0) 'duplicate event is not sent twice'
$pathB = Join-Path $testSessions 'b.jsonl'
[IO.File]::WriteAllText($pathB,($fresh | ConvertTo-Json -Compress -Depth 8) + "`n",[Text.UTF8Encoding]::new($false))
Assert-True (@(Process-SessionFile (Get-Item -LiteralPath $pathB)).Count -eq 1) 'different sessions are not suppressed by the same turn ID'
$partialPath = Join-Path $testSessions 'partial.jsonl'
$partial = New-EndEvent 'partial-turn'
$partial | Add-Member -NotePropertyName note -NotePropertyValue ([string][char]0x4E2D)
$partialText = $partial | ConvertTo-Json -Compress -Depth 8
$splitAt = [int]($partialText.Length / 2)
[IO.File]::WriteAllText($partialPath,$partialText.Substring(0,$splitAt),[Text.UTF8Encoding]::new($false))
Assert-True (@(Process-SessionFile (Get-Item -LiteralPath $partialPath)).Count -eq 0) 'incomplete JSONL event waits for remaining bytes'
[IO.File]::AppendAllText($partialPath,$partialText.Substring($splitAt) + "`n",[Text.UTF8Encoding]::new($false))
Assert-True (@(Process-SessionFile (Get-Item -LiteralPath $partialPath)).Count -eq 1) 'completed JSONL event is not lost'
$unicodePath = Join-Path $testSessions 'unicode.jsonl'
$unicodeEvent = New-EndEvent 'unicode-turn'
$unicodeEvent | Add-Member -NotePropertyName note -NotePropertyValue ([string][char]0x4E2D)
$unicodeBytes = [Text.Encoding]::UTF8.GetBytes(($unicodeEvent | ConvertTo-Json -Compress -Depth 8) + "`n")
$unicodeSplit = [Array]::IndexOf($unicodeBytes, [byte]0xE4)
[IO.File]::WriteAllBytes($unicodePath, [byte[]]$unicodeBytes[0..$unicodeSplit])
Assert-True (@(Process-SessionFile (Get-Item -LiteralPath $unicodePath)).Count -eq 0) 'partial UTF-8 character does not advance the file offset'
$unicodeStream = [IO.File]::OpenWrite($unicodePath)
try { [void]$unicodeStream.Seek(0,[IO.SeekOrigin]::End); $unicodeStream.Write($unicodeBytes,$unicodeSplit + 1,$unicodeBytes.Length - $unicodeSplit - 1) } finally { $unicodeStream.Dispose() }
Assert-True (@(Process-SessionFile (Get-Item -LiteralPath $unicodePath)).Count -eq 1) 'split UTF-8 character is preserved on the next poll'
$failure = New-EndEvent 'failed-turn'
$failure.payload | Add-Member -NotePropertyName error -NotePropertyValue ([pscustomobject]@{message='test failure'})
$failurePath = Join-Path $testSessions 'failure.jsonl'
[IO.File]::WriteAllText($failurePath,($failure | ConvertTo-Json -Compress -Depth 8) + "`n",[Text.UTF8Encoding]::new($false))
$events = @(Process-SessionFile (Get-Item -LiteralPath $failurePath))
Assert-True ($events.Count -eq 1 -and $events[0].Kind -eq 'turn_failed') 'failed turn generates only a failure notification'
foreach ($i in 1..30) { [IO.File]::WriteAllText((Join-Path $testSessions ("extra-$i.jsonl")), '') }
Assert-True (@(Get-SessionFiles).Count -gt 24) 'session coverage is not capped at 24 chats'
$internalPath = Join-Path $testSessions 'guardian.jsonl'
$metadata = [pscustomobject]@{type='session_meta';payload=[pscustomobject]@{source=[pscustomobject]@{subagent=[pscustomobject]@{other='guardian'}}}}
[IO.File]::WriteAllText($internalPath,($metadata | ConvertTo-Json -Compress -Depth 8) + "`n" + ((New-EndEvent 'guardian-turn') | ConvertTo-Json -Compress -Depth 8) + "`n",[Text.UTF8Encoding]::new($false))
Assert-True (@(Process-SessionFile (Get-Item -LiteralPath $internalPath)).Count -eq 0) 'internal automatic-review sessions do not notify'
$visiblePath = Join-Path $testSessions 'visible.jsonl'
$metadata.payload.source = 'vscode'
[IO.File]::WriteAllText($visiblePath,($metadata | ConvertTo-Json -Compress -Depth 8) + "`n" + ((New-EndEvent 'visible-turn') | ConvertTo-Json -Compress -Depth 8) + "`n",[Text.UTF8Encoding]::new($false))
Assert-True (@(Process-SessionFile (Get-Item -LiteralPath $visiblePath)).Count -eq 1) 'user-visible Codex conversations still notify'
$script:Calls = [Collections.Generic.List[string]]::new()
function Test-IsWindowsLocked { return $false }
function Start-AlertProcess { param($Event); $script:Calls.Add('desktop') }
function Send-MobileNotification { param($Event); $script:Calls.Add('mobile') }
$DryRun = $false
$event = Test-IsTaskComplete (New-EndEvent 'delivery-test')
Send-AlertIfDue $event
Assert-True (($script:Calls -join ',') -eq 'desktop,mobile') 'both channels are called, desktop first'
$script:Calls.Clear()
Send-AlertIfDue $event
Assert-True ($script:Calls.Count -eq 0) 'delivery deduplication prevents repeat pushes'
function Start-AlertProcess { param($Event); $script:Calls.Add('desktop'); throw 'simulated desktop failure' }
$event.CallId = 'desktop-failure-test'
Send-AlertIfDue $event
Assert-True (($script:Calls -join ',') -eq 'desktop,mobile') 'phone is attempted even if desktop fails'
$script:Calls.Clear()
$DryRun = $true
$event.CallId = 'dry-run-test'
Send-AlertIfDue $event
Assert-True ($script:Calls.Count -eq 0) 'dry run sends neither channel'
Write-Output ("ALL {0} TESTS PASSED" -f $script:Passed)

} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([char]92) + [char]92
    if ($resolvedTestRoot.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot) -match '^test-data-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
