$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($PSCommandPath) {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    }
    exit
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinDrag {
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);
}
"@
function Set-Round($control, [int]$radius) {
    if ($control.Width -lt 2 -or $control.Height -lt 2) { return }
    $r = [Math]::Min($radius, [Math]::Min($control.Width, $control.Height))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $r, $r, 180, 90)
    $path.AddArc($control.Width - $r, 0, $r, $r, 270, 90)
    $path.AddArc($control.Width - $r, $control.Height - $r, $r, $r, 0, 90)
    $path.AddArc(0, $control.Height - $r, $r, $r, 90, 90)
    $path.CloseFigure()
    $control.Region = New-Object System.Drawing.Region($path)
}
function Get-ScanReport {
    param([string]$Mode, [string]$Target)
    $ErrorActionPreference = 'SilentlyContinue'
    $script:rows = New-Object System.Collections.Generic.List[object]
    $script:seen = @{}
    function Add-Row([string]$Kind, [string]$User, [string]$Account, [string]$Source, [string]$Note) {
        if ([string]::IsNullOrWhiteSpace($User) -and [string]::IsNullOrWhiteSpace($Account)) { return }
        $User = ([string]$User).Trim()
        $Account = ([string]$Account).Trim()
        if ($User.Length -gt 64) { $User = $User.Substring(0, 64) }
        if ($Account.Length -gt 120) { $Account = $Account.Substring(0, 120) }
        $key = ($Kind + '|' + $User + '|' + $Account).ToLowerInvariant()
        if ($script:seen.ContainsKey($key)) { return }
        $script:seen[$key] = $true
        $script:rows.Add([pscustomobject]@{ Kind = $Kind; User = $User; Account = $Account; Source = $Source; Note = $Note })
    }
    function Read-Text([string]$Path) {
        try {
            $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
            if ($fs.Length -gt 20MB) { $fs.Close(); return '' }
            $buf = New-Object byte[] $fs.Length
            [void]$fs.Read($buf, 0, $buf.Length)
            $fs.Close()
            return [System.Text.Encoding]::UTF8.GetString($buf)
        } catch {
            try {
                $tmp = Join-Path $env:TEMP ([IO.Path]::GetRandomFileName())
                [System.IO.File]::Copy($Path, $tmp, $true)
                $buf = [System.IO.File]::ReadAllBytes($tmp)
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                if ($buf.Length -gt 20MB) { return '' }
                return [System.Text.Encoding]::UTF8.GetString($buf)
            } catch { return '' }
        }
    }
    function Add-MinecraftText([string]$Text, [string]$Source) {
        if (-not $Text) { return }
        foreach ($m in [regex]::Matches($Text, '"minecraftProfile"\s*:\s*\{[\s\S]{0,500}?"name"\s*:\s*"([A-Za-z0-9_]{3,16})"[\s\S]{0,800}?"username"\s*:\s*"([^"]{2,80})"')) {
            Add-Row 'Minecraft Java' $m.Groups[1].Value $m.Groups[2].Value $Source ''
        }
        foreach ($m in [regex]::Matches($Text, '"username"\s*:\s*"([^"]{2,80})"[\s\S]{0,800}?"minecraftProfile"\s*:\s*\{[\s\S]{0,400}?"name"\s*:\s*"([A-Za-z0-9_]{3,16})"')) {
            Add-Row 'Minecraft Java' $m.Groups[2].Value $m.Groups[1].Value $Source ''
        }
        foreach ($m in [regex]::Matches($Text, '"displayName"\s*:\s*"([A-Za-z0-9_]{3,16})"')) {
            Add-Row 'Minecraft' $m.Groups[1].Value '' $Source ''
        }
        foreach ($m in [regex]::Matches($Text, '"originalUsername"\s*:\s*"([A-Za-z0-9_]{3,16})"[\s\S]{0,300}?"minecraftUsername"\s*:\s*"([A-Za-z0-9_]{3,16})"')) {
            $note = ''
            if ($m.Groups[1].Value -ne $m.Groups[2].Value) { $note = '[RENAMED]' }
            Add-Row 'Minecraft' $m.Groups[2].Value $m.Groups[1].Value $Source $note
        }
        foreach ($m in [regex]::Matches($Text, '\{[^{}]*"name"\s*:\s*"([A-Za-z0-9_]{3,16})"[^{}]*"uuid"\s*:\s*"([^"]+)"')) {
            Add-Row 'Minecraft' $m.Groups[1].Value $m.Groups[2].Value $Source '(This username was found in the past on this PC)'
        }
        foreach ($m in [regex]::Matches($Text, 'Loaded content for \[\s*([A-Za-z0-9_]{3,16})\s*\]')) {
            Add-Row 'Lunar' $m.Groups[1].Value '' $Source ''
        }
        foreach ($m in [regex]::Matches($Text, 'Got Lunar Client Token for \s*([A-Za-z0-9_]{3,16})')) {
            Add-Row 'Lunar' $m.Groups[1].Value '' $Source ''
        }
        foreach ($m in [regex]::Matches($Text, 'Auth config: mode=Authenticated,.*name=([A-Za-z0-9_]{3,16})')) {
            Add-Row 'Hytale' $m.Groups[1].Value '' $Source ''
        }
        foreach ($m in [regex]::Matches($Text, '--name\s+([A-Za-z0-9_]{3,16})')) {
            Add-Row 'Minecraft' $m.Groups[1].Value '' $Source ''
        }
    }
    $mcFiles = @(
        "$env:APPDATA\.minecraft\launcher_accounts.json",
        "$env:APPDATA\.minecraft\launcher_accounts_microsoft_store.json",
        "$env:APPDATA\.minecraft\launcher_profiles.json",
        "$env:APPDATA\.minecraft\accounts.json",
        "$env:APPDATA\.minecraft\usercache.json",
        "$env:APPDATA\.minecraft\usernamecache.json",
        "$env:APPDATA\.feather\account.json",
        "$env:APPDATA\.feather\accounts.json"
    )
    $dirs = @(
        "$env:USERPROFILE\.lunarclient", "$env:APPDATA\.lunarclient", "$env:APPDATA\lunarclient",
        "$env:APPDATA\Badlion Client", "$env:LOCALAPPDATA\Badlion Client",
        "$env:APPDATA\.tlauncher", "$env:APPDATA\TLauncher", "$env:APPDATA\Feather Launcher", "$env:APPDATA\.feather",
        "$env:APPDATA\PrismLauncher", "$env:APPDATA\MultiMC", "$env:APPDATA\PolyMC", "$env:APPDATA\.technic",
        "$env:APPDATA\ModrinthApp", "$env:APPDATA\ATLauncher", "$env:APPDATA\gdlauncher", "$env:APPDATA\GDLauncher",
        "$env:APPDATA\SKlauncher", "$env:APPDATA\Minecraft Launcher"
    )
    foreach ($p in $mcFiles) { if (Test-Path -LiteralPath $p) { Add-MinecraftText (Read-Text $p) $p } }
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Length -lt 8MB -and $_.Name -match '(?i)account|launcher_accounts|launcher_profiles|usercache|usernamecache|\.log$'
        } | Select-Object -First 80 | ForEach-Object { Add-MinecraftText (Read-Text $_.FullName) $_.FullName }
    }
    if ($Mode -ne 'minecraft') {
        foreach ($steam in @(
            "$env:LOCALAPPDATA\Steam\config\loginusers.vdf",
            "C:\Program Files (x86)\Steam\config\loginusers.vdf",
            "C:\Program Files\Steam\config\loginusers.vdf"
        )) {
            if (-not (Test-Path -LiteralPath $steam)) { continue }
            $text = Read-Text $steam
            foreach ($m in [regex]::Matches($text, '"AccountName"\s*"([^"]+)"[\s\S]{0,400}?"PersonaName"\s*"([^"]+)"')) {
                Add-Row 'Steam' $m.Groups[2].Value $m.Groups[1].Value $steam ''
            }
            foreach ($m in [regex]::Matches($text, '"PersonaName"\s*"([^"]+)"[\s\S]{0,400}?"AccountName"\s*"([^"]+)"')) {
                Add-Row 'Steam' $m.Groups[1].Value $m.Groups[2].Value $steam ''
            }
        }
        $discordDirs = @(
            "$env:APPDATA\discord", "$env:APPDATA\discordcanary", "$env:APPDATA\discordptb", "$env:APPDATA\discorddevelopment",
            "$env:APPDATA\Lightcord", "$env:APPDATA\ArmCord", "$env:APPDATA\Vencord", "$env:APPDATA\Vesktop",
            "$env:LOCALAPPDATA\Discord", "$env:LOCALAPPDATA\Vencord", "$env:LOCALAPPDATA\Vesktop"
        )
        $badDiscord = @('discord','null','undefined','username','everyone','here','system','webhook','clyde','unknown','true','false')
        foreach ($dir in $discordDirs) {
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            $scanDirs = @(
                (Join-Path $dir 'Local Storage\leveldb'),
                (Join-Path $dir 'Session Storage'),
                (Join-Path $dir 'logs'),
                (Join-Path $dir 'IndexedDB'),
                (Join-Path $dir 'Network')
            ) | Where-Object { Test-Path -LiteralPath $_ }
            if ($scanDirs.Count -eq 0) { $scanDirs = @($dir) }
            foreach ($scanDir in $scanDirs) {
                Get-ChildItem -LiteralPath $scanDir -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object {
                    $_.Length -gt 0 -and $_.Length -lt 20MB -and $_.Extension -match '(?i)\.(ldb|log|old|sqlite|json)$' -and $_.FullName -notmatch '\\app-\\|\\modules\\|\\discord_desktop_core'
                } | ForEach-Object {
                    $text = Read-Text $_.FullName
                    if (-not $text) { return }
                    $patterns = @(
                        '"username"\s*:\s*"([^"\\]{2,32})"[\s\S]{0,180}?"id"\s*:\s*"(\d{17,20})"',
                        '"id"\s*:\s*"(\d{17,20})"[\s\S]{0,180}?"username"\s*:\s*"([^"\\]{2,32})"',
                        '"username"\s*:\s*"([^"\\]{2,32})"[\s\S]{0,120}?"global_name"\s*:\s*"([^"\\]{1,64})"',
                        '"global_name"\s*:\s*"([^"\\]{1,64})"[\s\S]{0,120}?"username"\s*:\s*"([^"\\]{2,32})"'
                    )
                    foreach ($m in [regex]::Matches($text, $patterns[0])) {
                        $u = $m.Groups[1].Value
                        if ($badDiscord -contains $u.ToLowerInvariant()) { continue }
                        Add-Row 'Discord' $u $m.Groups[2].Value $_.FullName ''
                    }
                    foreach ($m in [regex]::Matches($text, $patterns[1])) {
                        $u = $m.Groups[2].Value
                        if ($badDiscord -contains $u.ToLowerInvariant()) { continue }
                        Add-Row 'Discord' $u $m.Groups[1].Value $_.FullName ''
                    }
                    foreach ($m in [regex]::Matches($text, $patterns[2])) {
                        $u = $m.Groups[1].Value
                        $g = $m.Groups[2].Value
                        if ($badDiscord -contains $u.ToLowerInvariant()) { continue }
                        if ($g -eq 'null') { $g = '' }
                        Add-Row 'Discord' $u $g $_.FullName ''
                    }
                    foreach ($m in [regex]::Matches($text, $patterns[3])) {
                        $u = $m.Groups[2].Value
                        $g = $m.Groups[1].Value
                        if ($badDiscord -contains $u.ToLowerInvariant()) { continue }
                        if ($g -eq 'null') { $g = '' }
                        Add-Row 'Discord' $u $g $_.FullName ''
                    }
                }
            }
        }
        foreach ($hf in @(
            "$env:LOCALAPPDATA\hytale-launcher.log",
            "$env:APPDATA\Hytale\UserData",
            "$env:APPDATA\Hytale\Logs"
        )) {
            if (-not (Test-Path -LiteralPath $hf)) { continue }
            $files = @()
            if ((Get-Item -LiteralPath $hf).PSIsContainer) {
                $files = Get-ChildItem -LiteralPath $hf -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 8MB } | Select-Object -First 30
            } else { $files = @(Get-Item -LiteralPath $hf) }
            foreach ($file in $files) { Add-MinecraftText (Read-Text $file.FullName) $file.FullName }
        }
        Get-ChildItem 'C:\Users' -Force -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -notin @('Public','Default','Default User','All Users')
        } | ForEach-Object { Add-Row 'Windows User Profile' $_.Name '' $_.FullName '' }
    }
    if ($Mode -eq 'target' -and $Target) {
        $q = $Target.Trim()
        $cmp = [System.StringComparison]::OrdinalIgnoreCase
        $kept = New-Object System.Collections.Generic.List[object]
        foreach ($row in @($script:rows)) {
            $hit = $false
            foreach ($part in @([string]$row.User, [string]$row.Account, [string]$row.Source)) {
                if ($part -and $part.IndexOf($q, $cmp) -ge 0) { $hit = $true; break }
            }
            if ($hit) { $kept.Add($row) }
        }
        $script:rows = $kept
        $safe = $q -replace '[\[\]]', ''
        $seenPath = @{}
        if ($safe) {
            $roots = @(
                "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents", "$env:USERPROFILE\Downloads",
                "$env:APPDATA\.minecraft", "$env:APPDATA\.lunarclient", "$env:USERPROFILE\.lunarclient",
                "$env:APPDATA\Badlion Client", "$env:APPDATA\.feather", "$env:APPDATA\discord",
                "$env:APPDATA\discordcanary", "$env:APPDATA\discordptb", "$env:APPDATA\Vencord", "$env:APPDATA\Vesktop",
                "$env:LOCALAPPDATA\Discord"
            )
            foreach ($root in $roots) {
                if (-not (Test-Path -LiteralPath $root)) { continue }
                Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name.IndexOf($safe, $cmp) -ge 0 -and $_.FullName -notmatch '\\Microsoft\\Windows\\|\\Packages\\' } |
                    Select-Object -First 25 | ForEach-Object {
                        if ($seenPath.ContainsKey($_.FullName)) { return }
                        $seenPath[$_.FullName] = $true
                        Add-Row 'Target' $q $_.FullName 'File name match' ''
                    }
                Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -gt 0 -and $_.Length -lt 8MB -and $_.Extension -match '(?i)\.(json|log|txt|ldb|vdf|old)$' -and $_.FullName -notmatch '\\app-\\|\\modules\\|\\Microsoft\\Windows\\' } |
                    Select-Object -First 80 | ForEach-Object {
                        if ($seenPath.ContainsKey($_.FullName)) { return }
                        $text = Read-Text $_.FullName
                        if (-not $text) { return }
                        $m = [regex]::Match($text, [regex]::Escape($q), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                        if (-not $m.Success) { return }
                        $seenPath[$_.FullName] = $true
                        Add-Row 'Target' $m.Value $_.FullName 'Text match' ''
                    }
            }
        }
    }
    $store = Join-Path $env:LOCALAPPDATA 'AltChecker\previous.txt'
    $old = @()
    if (Test-Path -LiteralPath $store) { $old = @(Get-Content -LiteralPath $store) }
    $lines = New-Object System.Collections.Generic.List[string]
    $names = New-Object System.Collections.Generic.List[string]
    if ($Mode -eq 'target') { $lines.Add('Target: ' + $Target) ; $lines.Add('') }
    if ($script:rows.Count -eq 0) {
        $lines.Add('No accounts found.')
    } else {
        $lines.Add(('Accounts Found: {0}' -f $script:rows.Count))
        $lines.Add('')
        foreach ($row in $script:rows) {
            $past = $false
            if ($row.User -and ($old -contains $row.User)) { $past = $true }
            $lines.Add($row.Kind)
            if ($row.User) { $lines.Add(' [Username] ' + $row.User); if ($names -notcontains $row.User) { [void]$names.Add($row.User) } }
            if ($row.Account) { $lines.Add(' [Account]  ' + $row.Account) }
            if ($row.Note) { $lines.Add(' ' + $row.Note) }
            if ($past -and $row.Note -notmatch 'past') { $lines.Add(' (This username was found in the past on this PC)') }
            if ($row.Source) { $lines.Add(' ' + $row.Source) }
            $lines.Add('')
        }
    }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $store) | Out-Null
        $all = @($old + $names) | Where-Object { $_ } | Select-Object -Unique
        Set-Content -LiteralPath $store -Value $all -Encoding UTF8
    } catch {}
    $lines.Add('USN Journal Information')
    $created = $null
    try { $created = (Get-Item -LiteralPath '\\?\C:\$Extend\$UsnJrnl' -Force).CreationTime } catch {}
    $raw = (& fsutil usn queryjournal C: 2>&1 | Out-String)
    if ($raw -match '(?i)error|denied|not valid|not an NTFS') {
        $lines.Add('Journal created < 24h ago. Likely manually cleared.')
    } elseif ($created) {
        $age = (Get-Date) - $created
        if ($age.TotalHours -lt 24) { $lines.Add('Journal created < 24h ago. Likely manually cleared.') }
        elseif ($age.TotalDays -lt 14) { $lines.Add('Journal active for < 14 days. Possible overwrite.') }
        else { $lines.Add('Journal active for > 14 days. Normal behavior.') }
    } else {
        $lines.Add('Journal is present.')
    }
    $lines.Add('')
    $lines.Add('Scan Complete')
    return ($lines -join "`r`n")
}
$bg = [System.Drawing.Color]::FromArgb(16, 16, 16)
$field = [System.Drawing.Color]::FromArgb(28, 28, 28)
$border = [System.Drawing.Color]::FromArgb(58, 58, 58)
$muted = [System.Drawing.Color]::FromArgb(154, 154, 154)
$white = [System.Drawing.Color]::White
$ink = [System.Drawing.Color]::FromArgb(16, 16, 16)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Alt Checker'
$form.ClientSize = New-Object System.Drawing.Size(560, 680)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'None'
$form.BackColor = $bg
$form.ForeColor = $white
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$icoPath = Join-Path $env:TEMP 'AltChecker.ico'
$script:icoBytes = [Convert]::FromBase64String((@'
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
Ff0HiRaO5Bc18HgAAAAASUVORK5CYII=
'@ -replace '\s',''))
[IO.File]::WriteAllBytes($icoPath, $script:icoBytes)
$script:icoStream = New-Object System.IO.MemoryStream(,$script:icoBytes)
$form.Icon = New-Object System.Drawing.Icon($script:icoStream)
$form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)
$drag = {
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [WinDrag]::ReleaseCapture() | Out-Null
        [WinDrag]::SendMessage($form.Handle, 0xA1, 2, 0) | Out-Null
    }
}
$form.Add_MouseDown($drag)
function Lerp-Color($a, $b, [double]$t) {
    if ($t -lt 0) { $t = 0 }
    if ($t -gt 1) { $t = 1 }
    return [System.Drawing.Color]::FromArgb(
        [int]($a.R + ($b.R - $a.R) * $t),
        [int]($a.G + ($b.G - $a.G) * $t),
        [int]($a.B + ($b.B - $a.B) * $t))
}
$close = New-Object System.Windows.Forms.Button
$close.Text = [char]0x00D7
$close.Size = New-Object System.Drawing.Size(36, 32)
$close.Location = New-Object System.Drawing.Point(508, 12)
$close.FlatStyle = 'Flat'
$close.BackColor = $bg
$close.ForeColor = [System.Drawing.Color]::FromArgb(186, 186, 186)
$close.Font = New-Object System.Drawing.Font('Segoe UI', 12)
$close.FlatAppearance.BorderSize = 0
$close.Cursor = [System.Windows.Forms.Cursors]::Hand
$close.Add_Click({ $form.Close() })
$form.Controls.Add($close)
$label = New-Object System.Windows.Forms.Label
$label.Text = 'Alt Checker'
$label.AutoSize = $false
$label.Size = New-Object System.Drawing.Size(420, 30)
$label.Location = New-Object System.Drawing.Point(24, 14)
$label.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$label.ForeColor = $white
$label.BackColor = $bg
$label.Add_MouseDown($drag)
$form.Controls.Add($label)
$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Pick a scan. The username box only opens for Target Scan.'
$hint.AutoSize = $false
$hint.Size = New-Object System.Drawing.Size(500, 18)
$hint.Location = New-Object System.Drawing.Point(24, 48)
$hint.ForeColor = $muted
$hint.BackColor = $bg
$form.Controls.Add($hint)
$script:mode = 'generic'
$script:hover = ''
$script:mix = @{}
$script:cards = @()
$script:targetOpen = 0.0
$script:targetGoal = 0.0
$script:focusedTarget = $false
$script:scanning = $false
$script:barPos = 0
$script:dots = 0
$script:dotTick = 0
function New-ModeCard($title, $desc, $id, $y) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = "$title    $desc"
    $b.Tag = $id
    $b.Size = New-Object System.Drawing.Size(512, 48)
    $b.Location = New-Object System.Drawing.Point(24, $y)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $b.TextAlign = 'MiddleLeft'
    $b.Padding = New-Object System.Windows.Forms.Padding(14, 0, 8, 0)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.BackColor = $field
    $b.ForeColor = $white
    $form.Controls.Add($b)
    $script:cards += $b
    $script:mix[$id] = 0.0
    return $b
}
$generic = New-ModeCard 'Generic' 'Minecraft, Steam, Discord, Hytale, Windows' 'generic' 78
$mcBtn = New-ModeCard 'Minecraft' 'Vanilla, Lunar, Badlion, Feather, TLauncher' 'minecraft' 134
$targetBtn = New-ModeCard 'Target' 'Find one username, any capitalization' 'target' 190
$targetLbl = New-Object System.Windows.Forms.Label
$targetLbl.Text = 'Username'
$targetLbl.AutoSize = $false
$targetLbl.Size = New-Object System.Drawing.Size(200, 16)
$targetLbl.ForeColor = $muted
$targetLbl.BackColor = $bg
$targetLbl.Visible = $false
$form.Controls.Add($targetLbl)
$targetBorder = New-Object System.Windows.Forms.Panel
$targetBorder.Size = New-Object System.Drawing.Size(512, 44)
$targetBorder.BackColor = $border
$targetBorder.Visible = $false
$form.Controls.Add($targetBorder)
$targetInner = New-Object System.Windows.Forms.Panel
$targetInner.Location = New-Object System.Drawing.Point(1, 1)
$targetInner.Size = New-Object System.Drawing.Size(510, 42)
$targetInner.BackColor = $field
$targetBorder.Controls.Add($targetInner)
$targetBox = New-Object System.Windows.Forms.TextBox
$targetBox.AutoSize = $false
$targetBox.BorderStyle = 'None'
$targetBox.Font = New-Object System.Drawing.Font('Segoe UI', 12)
$targetBox.Location = New-Object System.Drawing.Point(12, 8)
$targetBox.Size = New-Object System.Drawing.Size(486, 26)
$targetBox.BackColor = $field
$targetBox.ForeColor = $white
$targetBox.TabStop = $true
$targetInner.Controls.Add($targetBox)
$targetInner.Add_Click({ $form.ActiveControl = $targetBox; $targetBox.Focus() | Out-Null })
$targetBorder.Add_Click({ $form.ActiveControl = $targetBox; $targetBox.Focus() | Out-Null })
$start = New-Object System.Windows.Forms.Button
$start.Text = 'Start Scan'
$start.Size = New-Object System.Drawing.Size(512, 44)
$start.FlatStyle = 'Flat'
$start.BackColor = $white
$start.ForeColor = $ink
$start.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$start.FlatAppearance.BorderSize = 0
$start.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($start)
$status = New-Object System.Windows.Forms.Label
$status.Text = 'Ready'
$status.AutoSize = $false
$status.Size = New-Object System.Drawing.Size(512, 18)
$status.ForeColor = $muted
$status.BackColor = $bg
$form.Controls.Add($status)
$track = New-Object System.Windows.Forms.Panel
$track.Size = New-Object System.Drawing.Size(512, 4)
$track.BackColor = [System.Drawing.Color]::FromArgb(46, 46, 46)
$form.Controls.Add($track)
$fill = New-Object System.Windows.Forms.Panel
$fill.Size = New-Object System.Drawing.Size(140, 4)
$fill.BackColor = $white
$fill.Left = -140
$track.Controls.Add($fill)
$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.ReadOnly = $true
$box.ScrollBars = 'Vertical'
$box.WordWrap = $true
$box.Font = New-Object System.Drawing.Font('Consolas', 9)
$box.BackColor = $field
$box.ForeColor = $white
$box.BorderStyle = 'None'
$form.Controls.Add($box)
$copy = New-Object System.Windows.Forms.Button
$copy.Text = 'Copy Usernames'
$copy.Size = New-Object System.Drawing.Size(512, 40)
$copy.Location = New-Object System.Drawing.Point(24, 628)
$copy.FlatStyle = 'Flat'
$copy.BackColor = $field
$copy.ForeColor = $white
$copy.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$copy.FlatAppearance.BorderSize = 0
$copy.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($copy)
function Update-Cards {
    if ($script:mode -eq 'target') { $script:targetGoal = 1.0 } else { $script:targetGoal = 0.0 }
}
function Paint-Cards {
    foreach ($c in @($script:cards)) {
        if ($c.Tag -eq $script:mode) {
            $c.BackColor = $white
            $c.ForeColor = $ink
        } elseif ($c.Tag -eq $script:hover) {
            $c.BackColor = [System.Drawing.Color]::FromArgb(54, 54, 54)
            $c.ForeColor = $white
        } else {
            $c.BackColor = $field
            $c.ForeColor = $white
        }
    }
}
function Start-Ui { if (-not $ui.Enabled) { $ui.Start() } }
$generic.Add_MouseEnter({ $script:hover = 'generic'; Paint-Cards })
$generic.Add_MouseLeave({ if ($script:hover -eq 'generic') { $script:hover = '' }; Paint-Cards })
$generic.Add_Click({ $script:mode = 'generic'; Update-Cards; Paint-Cards; Apply-Layout })
$mcBtn.Add_MouseEnter({ $script:hover = 'minecraft'; Paint-Cards })
$mcBtn.Add_MouseLeave({ if ($script:hover -eq 'minecraft') { $script:hover = '' }; Paint-Cards })
$mcBtn.Add_Click({ $script:mode = 'minecraft'; Update-Cards; Paint-Cards; Apply-Layout })
$targetBtn.Add_MouseEnter({ $script:hover = 'target'; Paint-Cards })
$targetBtn.Add_MouseLeave({ if ($script:hover -eq 'target') { $script:hover = '' }; Paint-Cards })
$targetBtn.Add_Click({ $script:mode = 'target'; Update-Cards; Paint-Cards; Apply-Layout; $form.ActiveControl = $targetBox; $targetBox.Focus() | Out-Null })
$start.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$start.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
$copy.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(46, 46, 46)
$copy.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
function Apply-Layout {
    $gap = 0
    if ($script:mode -eq 'target') { $gap = 74 }
    $base = 250
    $targetLbl.Location = New-Object System.Drawing.Point(24, $base)
    $targetBorder.Location = New-Object System.Drawing.Point(24, ($base + 20))
    $show = $script:mode -eq 'target'
    $targetLbl.Visible = $show
    $targetBorder.Visible = $show
    if ($show) { $targetBorder.BringToFront(); $targetBox.BringToFront() }
    $start.Location = New-Object System.Drawing.Point(24, ($base + $gap))
    $status.Location = New-Object System.Drawing.Point(24, ($start.Bottom + 10))
    $track.Location = New-Object System.Drawing.Point(24, ($status.Bottom + 6))
    $box.Location = New-Object System.Drawing.Point(24, ($track.Bottom + 12))
    $box.Size = New-Object System.Drawing.Size(512, ($copy.Top - 12 - $box.Top))
}
$ui = New-Object System.Windows.Forms.Timer
$ui.Interval = 20
$ui.Add_Tick({
    if ($script:scanning) {
        $script:barPos = ($script:barPos + 18) % ($track.Width + $fill.Width)
        $fill.Left = $script:barPos - $fill.Width
        $script:dotTick++
        if (($script:dotTick % 8) -eq 0) {
            $script:dots = ($script:dots + 1) % 3
            $status.Text = 'Scanning' + ('.' * ($script:dots + 1))
        }
        if ($script:scanHandle -and $script:scanHandle.IsCompleted) {
            $script:scanning = $false
            $fill.Left = -140
            $text = ''
            try { $text = [string]@($script:scanPs.EndInvoke($script:scanHandle))[0] } catch { $text = $_.Exception.Message }
            try { $script:scanPs.Dispose(); $script:scanRs.Close() } catch {}
            $box.Text = $text
            $status.Text = 'Scan complete'
            $start.Enabled = $true
            $start.Text = 'Start Scan'
            $ui.Stop()
        }
    } else {
        $ui.Stop()
    }
})
$form.Add_Shown({
    Set-Round $form 22
    Paint-Cards
    Update-Cards
    Apply-Layout
})
$targetBox.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $_.SuppressKeyPress = $true; $start.PerformClick() } })
$copy.Add_Click({
    $names = @([regex]::Matches($box.Text, '(?m)^ \[Username\] (.+)$') | ForEach-Object { $_.Groups[1].Value })
    if ($names.Count -eq 0) { $status.Text = 'No username to copy.'; return }
    Set-Clipboard ($names -join "`r`n")
    $copy.Text = 'Copied'
    $status.Text = 'Copied ' + $names.Count + ' username(s).'
    $reset = New-Object System.Windows.Forms.Timer
    $reset.Interval = 900
    $reset.Add_Tick({ $copy.Text = 'Copy Usernames'; $reset.Stop() })
    $reset.Start()
})
$start.Add_Click({
    if ($script:mode -eq 'target' -and -not $targetBox.Text.Trim()) { $status.Text = 'Type a username first.'; $targetBox.Focus() | Out-Null; return }
    $start.Enabled = $false
    $start.Text = 'Scanning'
    $status.Text = 'Scanning.'
    $box.Text = ''
    $script:scanning = $true
    $script:barPos = 0
    Start-Ui
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry('Get-ScanReport', ${function:Get-ScanReport}.ToString())))
    $script:scanRs = [runspacefactory]::CreateRunspace($iss)
    $script:scanRs.Open()
    $script:scanPs = [powershell]::Create()
    $script:scanPs.Runspace = $script:scanRs
    [void]$script:scanPs.AddCommand('Get-ScanReport').AddParameter('Mode', $script:mode).AddParameter('Target', $targetBox.Text)
    $script:scanHandle = $script:scanPs.BeginInvoke()
})
Update-Cards
Paint-Cards
Apply-Layout
[void]$form.ShowDialog()
$ui.Stop()
