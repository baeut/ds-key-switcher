# ===========================================================================
#  客户端重启助手：只重启「当前正在运行」的客户端，未运行的原样跳过
#  被 switch-core.ps1 / tray.ps1 以 dot-source 方式引用
# ===========================================================================
$script:ClientDefs = @(
    # Reasonix 实测切换 key 后立即生效（每次请求读 .env），重启只会白断会话
    [pscustomobject]@{ Name = 'Reasonix';         Proc = 'Reasonix.exe';         Desc = 'Reasonix';         Skip = $true; SkipReason = '热生效，无需重启' }
    [pscustomobject]@{ Name = 'DeepSeek Harness'; Proc = 'DeepSeek Harness.exe'; Desc = 'DeepSeek Harness' }
    [pscustomobject]@{ Name = 'Hypercode';        Proc = 'HyperCode.exe';        Desc = 'Hypercode' }
    # codex.exe 是控制台程序，且 app-server 由 Codex 桌面版通过 stdio 托管：
    # 独立拉起会弹黑窗、还会和桌面版脱钩，桌面版自己也有一挂就重连的机制
    [pscustomobject]@{ Name = 'codex';            Proc = 'codex.exe';            Desc = 'codex';            Skip = $true; SkipReason = 'CLI 天然读新配置；桌面版单独走下一项' }
    # Codex 桌面版（ChatGPT.exe，WindowsApps 包）：只能整体重启，用 AUMID 拉起
    [pscustomobject]@{ Name = 'Codex Desktop';    Proc = 'ChatGPT.exe';          Desc = 'Codex 桌面版';     Aumid = 'auto' }
)

# Codex 桌面版的 AUMID 各机可能不同，优先从「开始菜单应用」里查
function Resolve-CodexAumid {
    try {
        $app = Get-StartApps -ErrorAction SilentlyContinue |
            Where-Object { $_.AppID -match 'OpenAI\.Codex' } |
            Select-Object -First 1
        if ($app) { return $app.AppID }
    }
    catch { }
    return $null
}

# WindowsApps / 桌面桥应用：杀主进程后按 AUMID 拉起
function Restart-AumidApp {
    param($Def, [switch]$DryRun)
    $main = Get-CimInstance Win32_Process -Filter "Name='$($Def.Proc)'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -notmatch '--type=' } |
        Sort-Object CreationDate |
        Select-Object -First 1
    if (-not $main) { return [pscustomobject]@{ name = $Def.Desc; action = 'skip'; detail = '未运行' } }

    $aumid = $Def.Aumid
    if ($aumid -eq 'auto') { $aumid = Resolve-CodexAumid }
    if ([string]::IsNullOrWhiteSpace($aumid)) {
        return [pscustomobject]@{ name = $Def.Desc; action = 'fail'; detail = '找不到 AUMID，请手动重启该应用' }
    }
    if ($DryRun) { return [pscustomobject]@{ name = $Def.Desc; action = 'dry-run'; detail = "AUMID=$aumid" } }

    try {
        Stop-Process -Id $main.ProcessId -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 20; $i++) {
            if (-not (Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 300
        }
        Start-Sleep -Milliseconds 900
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList "shell:AppsFolder\$aumid" | Out-Null
        Start-Sleep -Milliseconds 1200
        return [pscustomobject]@{ name = $Def.Desc; action = 'restarted'; detail = $aumid }
    }
    catch {
        return [pscustomobject]@{ name = $Def.Desc; action = 'fail'; detail = $_.Exception.Message }
    }
}

function Get-ClientMainProcess {
    param($Def)
    Get-CimInstance Win32_Process -Filter "Name='$($Def.Proc)'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -notmatch '--type=' } |
        Sort-Object CreationDate |
        Select-Object -First 1
}

# 从原命令行里剥掉可执行文件路径，保留真正的启动参数
function Get-ClientLaunchArgs {
    param([string]$Exe, [string]$Cmd)
    if ([string]::IsNullOrWhiteSpace($Cmd)) { return '' }
    $c = $Cmd.Trim()
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -lt 0) { return '' }
        return $c.Substring($end + 1).Trim()
    }
    if ($c.StartsWith($Exe, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $c.Substring($Exe.Length).Trim()
    }
    return ''
}

function Restart-Client {
    param($Def, [switch]$DryRun)

    if ($Def.Skip) { return [pscustomobject]@{ name = $Def.Desc; action = 'skip'; detail = $Def.SkipReason } }
    if ($Def.Aumid) { return Restart-AumidApp -Def $Def -DryRun:$DryRun }

    $main = Get-ClientMainProcess -Def $Def
    if (-not $main) { return [pscustomobject]@{ name = $Def.Desc; action = 'skip'; detail = '未运行' } }

    $exe = $main.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{ name = $Def.Desc; action = 'fail'; detail = "找不到可执行文件: $exe" }
    }
    $argLine = Get-ClientLaunchArgs -Exe $exe -Cmd $main.CommandLine

    if ($DryRun) {
        return [pscustomobject]@{ name = $Def.Desc; action = 'dry-run'; detail = "$exe $argLine" }
    }

    # 1) 先礼貌关窗，不行再强杀
    try {
        $proc = Get-Process -Id $main.ProcessId -ErrorAction Stop
        $closed = $proc.CloseMainWindow()
        if (-not $closed -or -not $proc.WaitForExit(4000)) {
            Stop-Process -Id $main.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Stop-Process -Id $main.ProcessId -Force -ErrorAction SilentlyContinue
    }

    # 2) 等进程树彻底退出（最多 6 秒）
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 300
    }
    Start-Sleep -Milliseconds 700

    # 3) 用原路径 + 原参数拉起（Hidden：避免控制台程序弹黑窗）
    try {
        if ($argLine) { Start-Process -FilePath $exe -ArgumentList $argLine -WindowStyle Hidden | Out-Null }
        else { Start-Process -FilePath $exe -WindowStyle Hidden | Out-Null }
        Start-Sleep -Milliseconds 600
        return [pscustomobject]@{ name = $Def.Desc; action = 'restarted'; detail = $exe }
    }
    catch {
        return [pscustomobject]@{ name = $Def.Desc; action = 'fail'; detail = $_.Exception.Message }
    }
}

function Restart-AllClients {
    param([switch]$DryRun)
    $out = New-Object System.Collections.ArrayList
    foreach ($def in $script:ClientDefs) {
        [void]$out.Add((Restart-Client -Def $def -DryRun:$DryRun))
    }
    return $out
}
