<#
  DeepSeek Key Switcher - 核心切换逻辑
  ---------------------------------------------------------------------------
  一条命令把下面 4 个客户端的 DeepSeek 凭据 + 模型 + reasoning 档位写成同一套：

    codex               ~/.codex/config.toml (provider http_headers) + auth.json
    DeepSeek Harness    ~/.dsh/.env + profiles/desktop/cordis.patch.yml
    Reasonix            %APPDATA%/reasonix/.env + config.toml
    Hypercode           ~/.local/share/hypercode/auth.json + ~/.config/hypercode/hypercode.jsonc

  模型固定 deepseek-flash（= DeepSeek V4.1 Flash 1017），reasoning 取各端最高档。
  写入前整份备份到 backups/<时间戳>/，任何一段失败都不影响其它段。

  用法:
    powershell -NoProfile -ExecutionPolicy Bypass -File switch-core.ps1 -Profile company
    powershell -NoProfile -ExecutionPolicy Bypass -File switch-core.ps1 -Profile personal -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('company', 'personal')]
    [string]$Profile,

    [switch]$DryRun,

    # 切换完成后重启「当前正在运行」的客户端，让新 key 立即生效
    [switch]$RestartClients
)

$ErrorActionPreference = 'Stop'

$Root        = $PSScriptRoot
$SecretsPath = Join-Path $Root 'secrets.env'
$StatePath   = Join-Path $Root 'state.json'
$BackupRoot  = Join-Path $Root 'backups'
$LogPath     = Join-Path $Root 'switch.log'

# ---- 目标路径 --------------------------------------------------------------
$CodexHome       = Join-Path $env:USERPROFILE '.codex'
$DshHome         = Join-Path $env:USERPROFILE '.dsh'
$ReasonixHome    = Join-Path $env:APPDATA 'reasonix'
$HypercodeAuth   = Join-Path $env:USERPROFILE '.local\share\hypercode'
$HypercodeConfig = Join-Path $env:USERPROFILE '.config\hypercode'

# ---- 统一下发的模型参数 ----------------------------------------------------
# deepseek-flash 的官方元数据即 "DeepSeek V4.1 Flash 1017"，reasoning 合法值 low/high/max。
$ModelId        = 'deepseek-flash'
$EffortMax      = 'max'
$EffortCodex    = 'xhigh'                  # codex 自己的最高档，等价官方 max
$ReasonixModel  = 'deepseek/deepseek-flash'
$HypercodeModel = 'deepseek/deepseek-flash'

# ===========================================================================
# 通用文本处理（全部按行/定点替换，保持文件其余内容与换行风格不变）
# ===========================================================================
function Get-Newline {
    param([string]$Text)
    if ($Text -match "`r`n") { return "`r`n" }
    return "`n"
}

function Write-FileAtomic {
    param([string]$Path, [string]$Text, [string]$Label)
    if ($DryRun) {
        # 演练模式不碰真实配置，把结果落到 dryrun/ 供 diff
        $dir = Join-Path $Root 'dryrun'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        if (-not $Label) { $Label = Split-Path -Leaf $Path }
        [System.IO.File]::WriteAllText((Join-Path $dir $Label), $Text, (New-Object System.Text.UTF8Encoding($false)))
        return
    }
    $tmp = $Path + '.dstmp'
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Set-TomlTopKey {
    param([string]$Text, [string]$Key, [string]$Value)
    $nl = Get-Newline $Text
    $lines = $Text -split "`r?`n"
    $end = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[') { $end = $i; break }
    }
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    for ($i = 0; $i -lt $end; $i++) {
        if ($lines[$i] -match $pattern) {
            $lines[$i] = $Key + ' = "' + $Value + '"'
            return ($lines -join $nl)
        }
    }
    $insertAt = 0
    for ($i = 0; $i -lt $end; $i++) { if ($lines[$i].Trim() -ne '') { $insertAt = $i + 1 } }
    $new = @()
    if ($insertAt -gt 0) { $new += $lines[0..($insertAt - 1)] }
    $new += ($Key + ' = "' + $Value + '"')
    if ($insertAt -lt $lines.Count) { $new += $lines[$insertAt..($lines.Count - 1)] }
    return ($new -join $nl)
}

function Set-TomlSectionKey {
    param(
        [string]$Text, [string]$Section, [string]$Key, [string]$Value,
        [string]$Indent = '', [switch]$Raw
    )
    $nl = Get-Newline $Text
    $lines = $Text -split "`r?`n"
    $secPat = '^\s*\[' + [regex]::Escape($Section) + '\]\s*$'
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $secPat) { $start = $i; break }
    }
    if ($start -lt 0) { throw "未找到 TOML 段 [$Section]" }
    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[') { $end = $i; break }
    }
    if ($Raw) { $rendered = $Key + ' = ' + $Value } else { $rendered = $Key + ' = "' + $Value + '"' }
    $keyPat = '^(\s*)' + [regex]::Escape($Key) + '\s*='
    for ($i = $start + 1; $i -lt $end; $i++) {
        if ($lines[$i] -match $keyPat) {
            $lines[$i] = $Matches[1] + $rendered
            return ($lines -join $nl)
        }
    }
    $insertAt = $end
    for ($i = $end - 1; $i -gt $start; $i--) {
        if ($lines[$i].Trim() -ne '') { $insertAt = $i + 1; break }
    }
    $new = @()
    if ($insertAt -gt 0) { $new += $lines[0..($insertAt - 1)] }
    $new += ($Indent + $rendered)
    if ($insertAt -lt $lines.Count) { $new += $lines[$insertAt..($lines.Count - 1)] }
    return ($new -join $nl)
}

function Set-EnvValue {
    param([string]$Text, [string]$Key, [string]$Value)
    $nl = Get-Newline $Text
    $pattern = '(?m)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=.*$'
    $line = $Key + '=' + $Value
    if ([regex]::IsMatch($Text, $pattern)) {
        $re = New-Object System.Text.RegularExpressions.Regex($pattern)
        return $re.Replace($Text, $line, 1)
    }
    $t = $Text
    if ($t.Length -gt 0 -and -not $t.EndsWith("`n")) { $t += $nl }
    return $t + $line + $nl
}

function Set-YamlBlockValue {
    param([string]$Text, [string]$AnchorId, [string]$Key, [string]$Value, [string]$Indent = '    ')
    $nl = Get-Newline $Text
    $lines = $Text -split "`r?`n"
    $anchPat = '^\s*-\s+id:\s*' + [regex]::Escape($AnchorId) + '\s*$'
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $anchPat) { $start = $i; break }
    }
    if ($start -lt 0) { throw "未找到 YAML 锚点 '- id: $AnchorId'" }
    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-\s+') { $end = $i; break }
    }
    $keyPat = '^(\s+)' + [regex]::Escape($Key) + '\s*:'
    for ($i = $start + 1; $i -lt $end; $i++) {
        if ($lines[$i] -match $keyPat) {
            $lines[$i] = $Matches[1] + $Key + ': ' + $Value
            return ($lines -join $nl)
        }
    }
    $insertAt = $end
    for ($i = $end - 1; $i -gt $start; $i--) {
        if ($lines[$i].Trim() -ne '') { $insertAt = $i + 1; break }
    }
    $new = @()
    if ($insertAt -gt 0) { $new += $lines[0..($insertAt - 1)] }
    $new += ($Indent + $Key + ': ' + $Value)
    if ($insertAt -lt $lines.Count) { $new += $lines[$insertAt..($lines.Count - 1)] }
    return ($new -join $nl)
}

function Set-JsoncBuildModel {
    param([string]$Text, [string]$Model, [string]$Variant)
    $m = [regex]::Match($Text, '("build"\s*:\s*\{)([^}]*)(\})')
    if (-not $m.Success) { throw 'JSONC 中未找到 "build": { ... } 节点' }
    $inner = $m.Groups[2].Value
    if (-not [regex]::IsMatch($inner, '"model"\s*:')) { throw 'JSONC 的 build 节点缺少 "model"' }
    if (-not [regex]::IsMatch($inner, '"variant"\s*:')) { throw 'JSONC 的 build 节点缺少 "variant"' }
    $inner = [regex]::Replace($inner, '("model"\s*:\s*")[^"]*(")', '${1}' + $Model + '${2}')
    $inner = [regex]::Replace($inner, '("variant"\s*:\s*")[^"]*(")', '${1}' + $Variant + '${2}')
    $start = $m.Groups[2].Index
    return $Text.Substring(0, $start) + $inner + $Text.Substring($start + $m.Groups[2].Length)
}

function Set-JsonRawKey {
    param([string]$Text, [string]$Pattern, [string]$Value)
    if (-not [regex]::IsMatch($Text, $Pattern)) { throw 'JSON 里没找到目标字段，未做修改' }
    return [regex]::Replace($Text, $Pattern, '${1}' + $Value + '${2}')
}

# ===========================================================================
# 备份 / 结果收集
# ===========================================================================
$BackupDir = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
if (-not $DryRun) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

function Backup-Target {
    param([string]$Path, [string]$Label)
    if ($DryRun) { return }
    if (Test-Path -LiteralPath $Path) {
        Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupDir $Label) -Force -ErrorAction SilentlyContinue
    }
}

# 只留最近 30 次备份
if (-not $DryRun) {
    Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -Skip 30 |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

$Results = New-Object System.Collections.ArrayList
function Add-Result {
    param([string]$Target, [bool]$Ok, [string]$Message)
    [void]$Results.Add([pscustomobject]@{ target = $Target; ok = $Ok; message = $Message })
}

# ===========================================================================
# 读取密钥
# ===========================================================================
if (-not (Test-Path -LiteralPath $SecretsPath)) {
    throw "缺少密钥文件: $SecretsPath"
}
$secrets = @{}
foreach ($line in [System.IO.File]::ReadAllLines($SecretsPath)) {
    $l = $line.Trim()
    if ($l -eq '' -or $l.StartsWith('#')) { continue }
    $eq = $l.IndexOf('=')
    if ($eq -lt 1) { continue }
    $secrets[$l.Substring(0, $eq).Trim().ToUpper()] = $l.Substring($eq + 1).Trim()
}
$slotName = $Profile.ToUpper()
if (-not $secrets.ContainsKey($slotName) -or [string]::IsNullOrWhiteSpace($secrets[$slotName])) {
    throw "secrets.env 里的 $slotName= 还没填 key"
}
$key = $secrets[$slotName]
if ($key -notmatch '^sk-[A-Za-z0-9_\-]{8,}$') {
    throw "secrets.env 里的 $slotName 看起来不是合法 DeepSeek key（需 sk- 开头）"
}

# ===========================================================================
# 1) codex
# ===========================================================================
$codexCfg = Join-Path $CodexHome 'config.toml'
try {
    if (-not (Test-Path -LiteralPath $codexCfg)) { throw "找不到 $codexCfg" }
    Backup-Target $codexCfg 'codex-config.toml'
    $t = [System.IO.File]::ReadAllText($codexCfg)
    $t = Set-TomlTopKey -Text $t -Key 'model' -Value $ModelId
    $t = Set-TomlTopKey -Text $t -Key 'model_reasoning_effort' -Value $EffortCodex
    $t = Set-TomlSectionKey -Text $t -Section 'model_providers.deepseek' -Key 'http_headers' `
        -Value ('{ Authorization = "Bearer ' + $key + '" }') -Raw
    Write-FileAtomic -Path $codexCfg -Text $t -Label 'codex-config.toml'
    Add-Result 'codex/config.toml' $true "$ModelId / effort=$EffortCodex / Authorization 已同步"
}
catch { Add-Result 'codex/config.toml' $false $_.Exception.Message }

$codexAuth = Join-Path $CodexHome 'auth.json'
try {
    if (Test-Path -LiteralPath $codexAuth) {
        Backup-Target $codexAuth 'codex-auth.json'
        $t = [System.IO.File]::ReadAllText($codexAuth)
        $t = Set-JsonRawKey -Text $t -Pattern '("OPENAI_API_KEY"\s*:\s*")[^"]*(")' -Value $key
        Write-FileAtomic -Path $codexAuth -Text $t -Label 'codex-auth.json'
        Add-Result 'codex/auth.json' $true 'OPENAI_API_KEY 已同步'
    }
    else { Add-Result 'codex/auth.json' $true '无此文件，跳过' }
}
catch { Add-Result 'codex/auth.json' $false $_.Exception.Message }

# ===========================================================================
# 2) DeepSeek Harness (dsh)
# ===========================================================================
$dshEnv = Join-Path $DshHome '.env'
try {
    if (-not (Test-Path -LiteralPath $dshEnv)) { throw "找不到 $dshEnv" }
    Backup-Target $dshEnv 'dsh.env'
    $t = [System.IO.File]::ReadAllText($dshEnv)
    $t = Set-EnvValue -Text $t -Key 'DEEPSEEK_API_KEY' -Value $key
    Write-FileAtomic -Path $dshEnv -Text $t -Label 'dsh.env'
    Add-Result 'dsh/.env' $true 'DEEPSEEK_API_KEY 已同步'
}
catch { Add-Result 'dsh/.env' $false $_.Exception.Message }

$dshProfile = Join-Path $DshHome 'profiles\desktop\cordis.patch.yml'
try {
    if (-not (Test-Path -LiteralPath $dshProfile)) { throw "找不到 $dshProfile" }
    Backup-Target $dshProfile 'dsh-cordis.patch.yml'
    $t = [System.IO.File]::ReadAllText($dshProfile)
    $t = Set-YamlBlockValue -Text $t -AnchorId 'agent-default-model' -Key 'provider' -Value 'deepseek-official'
    $t = Set-YamlBlockValue -Text $t -AnchorId 'agent-default-model' -Key 'model' -Value $ModelId
    $t = Set-YamlBlockValue -Text $t -AnchorId 'agent-default-model' -Key 'reasoningEffort' -Value $EffortMax
    Write-FileAtomic -Path $dshProfile -Text $t -Label 'dsh-cordis.patch.yml'
    Add-Result 'dsh/cordis.patch.yml' $true "$ModelId / reasoningEffort=$EffortMax"
}
catch { Add-Result 'dsh/cordis.patch.yml' $false $_.Exception.Message }

# ===========================================================================
# 3) Reasonix
# ===========================================================================
$rEnv = Join-Path $ReasonixHome '.env'
try {
    if (-not (Test-Path -LiteralPath $rEnv)) { throw "找不到 $rEnv" }
    Backup-Target $rEnv 'reasonix.env'
    $t = [System.IO.File]::ReadAllText($rEnv)
    $t = Set-EnvValue -Text $t -Key 'DEEPSEEK_API_KEY' -Value $key
    # provider "deepseek"（默认模型走这家）引用的是 REASONIX_CONNECTION_*_KEY，必须同步
    foreach ($m in [regex]::Matches($t, '(?m)^[ \t]*(REASONIX_CONNECTION_[0-9A-F]+_KEY)[ \t]*=')) {
        $t = Set-EnvValue -Text $t -Key $m.Groups[1].Value -Value $key
    }
    Write-FileAtomic -Path $rEnv -Text $t -Label 'reasonix.env'
    Add-Result 'reasonix/.env' $true 'DEEPSEEK_API_KEY + REASONIX_CONNECTION_*_KEY 已同步'
}
catch { Add-Result 'reasonix/.env' $false $_.Exception.Message }

$rCfg = Join-Path $ReasonixHome 'config.toml'
try {
    if (-not (Test-Path -LiteralPath $rCfg)) { throw "找不到 $rCfg" }
    Backup-Target $rCfg 'reasonix-config.toml'
    $t = [System.IO.File]::ReadAllText($rCfg)
    $t = Set-TomlTopKey -Text $t -Key 'default_model' -Value $ReasonixModel
    $t = Set-TomlSectionKey -Text $t -Section 'agent' -Key 'planner_model' -Value $ReasonixModel -Indent '  '
    $t = Set-TomlSectionKey -Text $t -Section 'agent' -Key 'subagent_model' -Value $ReasonixModel -Indent '  '
    $t = Set-TomlSectionKey -Text $t -Section 'agent' -Key 'subagent_effort' -Value $EffortMax -Indent '  '
    Write-FileAtomic -Path $rCfg -Text $t -Label 'reasonix-config.toml'
    Add-Result 'reasonix/config.toml' $true "$ReasonixModel / subagent_effort=$EffortMax"
}
catch { Add-Result 'reasonix/config.toml' $false $_.Exception.Message }

# ===========================================================================
# 4) Hypercode
# ===========================================================================
$hcAuth = Join-Path $HypercodeAuth 'auth.json'
try {
    if (-not (Test-Path -LiteralPath $hcAuth)) { throw "找不到 $hcAuth" }
    Backup-Target $hcAuth 'hypercode-auth.json'
    $t = [System.IO.File]::ReadAllText($hcAuth)
    $t = Set-JsonRawKey -Text $t -Pattern '("deepseek"\s*:\s*\{[^}]*?"key"\s*:\s*")[^"]*(")' -Value $key
    Write-FileAtomic -Path $hcAuth -Text $t -Label 'hypercode-auth.json'
    Add-Result 'hypercode/auth.json' $true 'deepseek.key 已同步'
}
catch { Add-Result 'hypercode/auth.json' $false $_.Exception.Message }

$hcCfg = Join-Path $HypercodeConfig 'hypercode.jsonc'
try {
    if (-not (Test-Path -LiteralPath $hcCfg)) { throw "找不到 $hcCfg" }
    Backup-Target $hcCfg 'hypercode.jsonc'
    $t = [System.IO.File]::ReadAllText($hcCfg)
    $t = Set-JsoncBuildModel -Text $t -Model $HypercodeModel -Variant $EffortMax
    Write-FileAtomic -Path $hcCfg -Text $t -Label 'hypercode.jsonc'
    Add-Result 'hypercode/hypercode.jsonc' $true "$HypercodeModel / variant=$EffortMax"
}
catch { Add-Result 'hypercode/hypercode.jsonc' $false $_.Exception.Message }

# ===========================================================================
# 状态 / 日志 / 输出
# ===========================================================================
$okAll = -not ($Results | Where-Object { -not $_.ok })
$summary = [pscustomobject]@{
    profile = $Profile
    model   = $ModelId
    effort  = $EffortMax
    keyTail = $key.Substring($key.Length - 4)
    at      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    dryRun  = [bool]$DryRun
    ok      = $okAll
    items   = @($Results)
    restarts = @()
}

# 切换完成后重启正在运行的客户端，让新 key 生效
if ($RestartClients) {
    . (Join-Path $Root 'clients.ps1')
    $restartList = Restart-AllClients -DryRun:$DryRun
    $summary.restarts = @($restartList)
    if (-not $DryRun) {
        $restartLine = '    restart: ' + (($restartList | ForEach-Object { $_.name + '=' + $_.action }) -join ', ')
        Add-Content -LiteralPath $LogPath -Value $restartLine -Encoding UTF8
    }
}


if (-not $DryRun) {
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    $logLine = '[' + $summary.at + '] ' + $Profile + ' -> ok=' + $okAll + ' | ' +
        (($Results | ForEach-Object { $_.target + '=' + $(if ($_.ok) { 'ok' } else { 'FAIL' }) }) -join ', ')
    Add-Content -LiteralPath $LogPath -Value $logLine -Encoding UTF8
}

$summary | ConvertTo-Json -Depth 6 -Compress
