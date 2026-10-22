# ===========================================================================
#  DeepSeek Key Switcher - 托盘常驻
#  右键托盘图标：切公司 / 切个人，一次写全 codex、DeepSeek Harness、
#  Reasonix、Hypercode 的 key + 模型(deepseek-flash) + 最高 reasoning 档。
# ===========================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- 单实例锁：桌面图标 / VBS 重复点也只跑一个托盘 -------------------------
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\DeepSeekKeySwitcherTray', [ref]$createdNew)
if (-not $createdNew) {
    # 已有实例在跑，直接安静退出
    exit 0
}

$Root        = $PSScriptRoot
$CorePath    = Join-Path $Root 'switch-core.ps1'
$SecretsPath = Join-Path $Root 'secrets.env'
$StatePath   = Join-Path $Root 'state.json'
$LogPath     = Join-Path $Root 'switch.log'
$SettingsPath = Join-Path $Root 'settings.json'
$StartupLnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeepSeek Key Switcher.lnk'

$script:Busy = $false
$script:AutoRestart = $true
$script:LastToggle = [DateTime]::MinValue

function Read-Settings {
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $s = [System.IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
            if ($s.PSObject.Properties['autoRestart']) { $script:AutoRestart = [bool]$s.autoRestart }
        }
        catch { }
    }
}
function Save-Settings {
    $o = [pscustomobject]@{ autoRestart = $script:AutoRestart }
    [System.IO.File]::WriteAllText($SettingsPath, ($o | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}
Read-Settings

function Read-Slots {
    $slots = [ordered]@{ company = ''; personal = '' }
    if (Test-Path -LiteralPath $SecretsPath) {
        foreach ($line in [System.IO.File]::ReadAllLines($SecretsPath)) {
            $l = $line.Trim()
            if ($l -eq '' -or $l.StartsWith('#')) { continue }
            $eq = $l.IndexOf('=')
            if ($eq -lt 1) { continue }
            $k = $l.Substring(0, $eq).Trim().ToLower()
            if ($slots.Contains($k)) { $slots[$k] = $l.Substring($eq + 1).Trim() }
        }
    }
    return $slots
}

function Read-Active {
    if (Test-Path -LiteralPath $StatePath) {
        try { return ([System.IO.File]::ReadAllText($StatePath) | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 3, 3, 26, 26)
    $brush.Dispose()
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $icon.Clone()
}

$script:IconCompany  = New-DotIcon ([System.Drawing.Color]::FromArgb(46, 125, 50))
$script:IconPersonal = New-DotIcon ([System.Drawing.Color]::FromArgb(21, 101, 192))
$script:IconIdle     = New-DotIcon ([System.Drawing.Color]::FromArgb(97, 97, 97))

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Icon = $script:IconIdle
$script:Notify.Text = 'DeepSeek Key Switcher'
$script:Notify.Visible = $true

$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:Notify.ContextMenuStrip = $script:Menu

function Show-Balloon {
    param([string]$Title, [string]$Text, [string]$Kind = 'Info')
    $script:Notify.BalloonTipTitle = $Title
    $script:Notify.BalloonTipText  = $Text
    switch ($Kind) {
        'Error' { $script:Notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error }
        'Warning' { $script:Notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning }
        default { $script:Notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info }
    }
    $script:Notify.ShowBalloonTip(5000)
}

function Invoke-RestartOnly {
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        . (Join-Path $Root 'clients.ps1')
        $rs = Restart-AllClients
        $restarted = @($rs | Where-Object { $_.action -eq 'restarted' })
        $failedRestart = @($rs | Where-Object { $_.action -eq 'fail' })
        if ($restarted.Count -gt 0) {
            $msg = ($restarted | ForEach-Object { $_.name }) -join '、'
            if ($failedRestart.Count -gt 0) { $msg += '；失败：' + (($failedRestart | ForEach-Object { $_.name }) -join '、') }
            Show-Balloon '已重启客户端' $msg 'Info'
        }
        else {
            Show-Balloon '没有需要重启的客户端' '四个客户端都没在运行。' 'Info'
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "重启失败：`n`n$($_.Exception.Message)",
            'DeepSeek Key Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally { $script:Busy = $false }
}

# 左键单击托盘图标：在 公司 / 个人 之间直接来回切
function Invoke-ToggleKey {
    if ($script:Busy) { return }
    # 防抖：双击/连点只认第一次
    if (([DateTime]::Now - $script:LastToggle).TotalMilliseconds -lt 1500) { return }
    $script:LastToggle = [DateTime]::Now

    $state = Read-Active
    $current = ''
    if ($state -and $state.profile) { $current = $state.profile }
    $target = if ($current -eq 'company') { 'personal' } else { 'company' }

    $slots = Read-Slots
    if ([string]::IsNullOrWhiteSpace($slots[$target])) {
        Show-Balloon '另一个 key 还没填' "secrets.env 里的 $($target.ToUpper())= 是空的，先填好再点。" 'Warning'
        $script:Menu.Show([System.Windows.Forms.Cursor]::Position)
        return
    }
    Invoke-Switch -Profile $target
}

function Invoke-Switch {
    param([string]$Profile)
    if ($script:Busy) { return }
    $slots = Read-Slots
    if ([string]::IsNullOrWhiteSpace($slots[$Profile])) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "secrets.env 里 $($Profile.ToUpper())= 还是空的。`n`n现在打开这个文件填写？",
            'DeepSeek Key Switcher',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Process notepad.exe $SecretsPath }
        return
    }
    $script:Busy = $true
    try {
        $coreParams = @{ Profile = $Profile }
        if ($script:AutoRestart) { $coreParams['RestartClients'] = $true }
        $raw = (& $CorePath @coreParams) -join "`n"
        $obj = $null
        try { $obj = $raw.Trim() | ConvertFrom-Json } catch { $obj = $null }
        if (-not $obj) {
            [System.Windows.Forms.MessageBox]::Show(
                "切换脚本没有返回结果。`n`n输出：`n$raw",
                'DeepSeek Key Switcher',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }
        $failed = @($obj.items | Where-Object { -not $_.ok })
        $restartText = ''
        if ($obj.PSObject.Properties['restarts'] -and $obj.restarts) {
            $rs = @($obj.restarts)
            $restarted = @($rs | Where-Object { $_.action -eq 'restarted' })
            $restartFailed = @($rs | Where-Object { $_.action -eq 'fail' })
            if ($restarted.Count -gt 0) {
                $restartText = '已重启：' + (($restarted | ForEach-Object { $_.name }) -join '、')
            }
            else {
                $restartText = '没有正在运行的客户端需要重启'
            }
            if ($restartFailed.Count -gt 0) {
                $restartText += '；失败：' + (($restartFailed | ForEach-Object { $_.name }) -join '、')
            }
        }
        if ($failed.Count -eq 0) {
            $msg = "4 个客户端已写入 $($obj.model) / effort=$($obj.effort)。"
            if ($restartText) { $msg += "`n$restartText" }
            else { $msg += "`n重启客户端后生效。" }
            Show-Balloon "已切到 $Profile key (…$($obj.keyTail))" $msg 'Info'
        }
        else {
            $detail = ($failed | ForEach-Object { "- $($_.target)：$($_.message)" }) -join "`n"
            Show-Balloon "切换有 $($failed.Count) 项失败" $detail 'Error'
            [System.Windows.Forms.MessageBox]::Show(
                "以下目标写入失败，其余已生效：`n`n$detail",
                'DeepSeek Key Switcher',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "切换失败：`n`n$($_.Exception.Message)",
            'DeepSeek Key Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally {
        $script:Busy = $false
        Update-Ui
    }
}

function Set-Autostart {
    param([bool]$Enable)
    if ($Enable) {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($StartupLnk)
        $lnk.TargetPath = (Join-Path $env:SystemRoot 'System32\wscript.exe')
        $lnk.Arguments = '"' + (Join-Path $Root 'start-tray.vbs') + '"'
        $lnk.WorkingDirectory = $Root
        $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,77"
        $lnk.Save()
    }
    else {
        if (Test-Path -LiteralPath $StartupLnk) { Remove-Item -LiteralPath $StartupLnk -Force }
    }
}

function Update-Status {
    $state = Read-Active
    if ($state) {
        $who = if ($state.profile -eq 'company') { '公司' } else { '个人' }
        $script:Notify.Icon = if ($state.profile -eq 'company') { $script:IconCompany } else { $script:IconPersonal }
        $script:Notify.Text = "DeepSeek Key: $who (…$($state.keyTail))"
    }
    else {
        $script:Notify.Icon = $script:IconIdle
        $script:Notify.Text = 'DeepSeek Key Switcher'
    }
}

function Update-Ui {
    $state = Read-Active
    $slots = Read-Slots

    Update-Status
    $script:Menu.Items.Clear()

    if ($state) {
        $who = if ($state.profile -eq 'company') { '公司' } else { '个人' }
        $title = "当前：$who key (…$($state.keyTail))  $($state.at)"
    }
    else {
        $title = '当前：还没切换过'
    }
    $head = $script:Menu.Items.Add($title)
    $head.Enabled = $false

    $hint = $script:Menu.Items.Add('左键单击图标 = 直接切到另一个 key')
    $hint.Enabled = $false

    [void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    foreach ($slot in @('company', 'personal')) {
        $label = if ($slot -eq 'company') { '切到公司 key' } else { '切到个人 key' }
        if ([string]::IsNullOrWhiteSpace($slots[$slot])) {
            $label += '  （未填写）'
        }
        $item = $script:Menu.Items.Add($label)
        if ($state -and $state.profile -eq $slot) { $item.Checked = $true }
        $item.Tag = $slot
        $item.add_Click({ param($s, $e) Invoke-Switch -Profile $s.Tag })
    }

    $autoRestartItem = $script:Menu.Items.Add('切换后自动重启客户端')
    $autoRestartItem.Checked = $script:AutoRestart
    $autoRestartItem.add_Click({
        $script:AutoRestart = -not $script:AutoRestart
        Save-Settings
        Update-Ui
    })

    $restartOnly = $script:Menu.Items.Add('仅重启客户端（不切 key）')
    $restartOnly.add_Click({ Invoke-RestartOnly })

    [void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $reload = $script:Menu.Items.Add('重新加载密钥文件')
    $reload.add_Click({ Update-Ui; Show-Balloon '已重新加载' 'secrets.env 已重新读取。' })

    $edit = $script:Menu.Items.Add('编辑密钥文件')
    $edit.add_Click({ Start-Process notepad.exe $SecretsPath })

    $openDir = $script:Menu.Items.Add('打开工具目录')
    $openDir.add_Click({ Start-Process explorer.exe $Root })

    $openLog = $script:Menu.Items.Add('查看切换日志')
    $openLog.add_Click({
        if (Test-Path -LiteralPath $LogPath) { Start-Process notepad.exe $LogPath }
        else { Show-Balloon '还没有日志' '还没执行过切换。' 'Info' }
    })

    [void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $auto = $script:Menu.Items.Add('开机自启')
    $auto.Checked = Test-Path -LiteralPath $StartupLnk
    $auto.add_Click({
        param($s, $e)
        Set-Autostart -Enable (-not (Test-Path -LiteralPath $StartupLnk))
        Update-Ui
    })

    $quit = $script:Menu.Items.Add('退出')
    $quit.add_Click({
        $script:Notify.Visible = $false
        $script:Context.ExitThread()
    })
}

$script:Context = New-Object System.Windows.Forms.ApplicationContext
$script:Menu.add_Opening({ Update-Ui })

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 3000
$script:Timer.add_Tick({ Update-Status })
$script:Timer.Start()

Update-Ui
Show-Balloon 'DeepSeek Key Switcher 已启动' '左键单击 = 来回切 key，右键 = 菜单。'

# 左键单击托盘图标 → 立刻切到另一个 key（右键仍弹菜单）
$script:Notify.add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-ToggleKey }
})

[System.Windows.Forms.Application]::Run($script:Context)
