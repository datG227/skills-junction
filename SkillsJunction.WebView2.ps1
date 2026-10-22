param([switch]$BackendServer)

# Skills Junction: manage per-skill Windows directory junctions from a desktop UI.
# Existing folders at the destination are never replaced or deleted.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

if (-not ('SkillsJunction.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SkillsJunction {
    public static class Native {
        const uint FILE_READ_ATTRIBUTES = 0x80;
        const uint FILE_SHARE_READ = 1;
        const uint FILE_SHARE_WRITE = 2;
        const uint FILE_SHARE_DELETE = 4;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        const uint FSCTL_GET_REPARSE_POINT = 0x000900A8;
        const uint IO_REPARSE_TAG_MOUNT_POINT = 0xA0000003;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(SafeFileHandle handle, uint control,
            IntPtr input, uint inputLength, byte[] output, uint outputLength,
            out uint returned, IntPtr overlapped);

        public static string GetJunctionTarget(string path) {
            using (SafeFileHandle handle = CreateFile(path, FILE_READ_ATTRIBUTES,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    IntPtr.Zero, OPEN_EXISTING,
                    FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                    IntPtr.Zero)) {
                if (handle.IsInvalid)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                byte[] data = new byte[16 * 1024];
                uint returned;
                if (!DeviceIoControl(handle, FSCTL_GET_REPARSE_POINT, IntPtr.Zero, 0,
                        data, (uint)data.Length, out returned, IntPtr.Zero)) {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 4390) return null; // Not a reparse point.
                    throw new Win32Exception(error);
                }
                if (BitConverter.ToUInt32(data, 0) != IO_REPARSE_TAG_MOUNT_POINT)
                    return null;
                int nameOffset = BitConverter.ToUInt16(data, 8);
                int nameLength = BitConverter.ToUInt16(data, 10);
                string target = Encoding.Unicode.GetString(data, 16 + nameOffset, nameLength);
                if (target.StartsWith(@"\??\UNC\", StringComparison.OrdinalIgnoreCase))
                    target = @"\" + target.Substring(8);
                else if (target.StartsWith(@"\??\", StringComparison.OrdinalIgnoreCase))
                    target = target.Substring(4);
                return Path.GetFullPath(target);
            }
        }
    }
}
'@
}

# Modal dialogs must be anchored to the app's window, otherwise they appear
# behind it because this script runs inside a hidden console process.
if (-not ('SkillsJunction.Dialogs' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SkillsJunction {
    public static class Dialogs {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
    }
    public sealed class WindowOwner : System.Windows.Forms.IWin32Window {
        public WindowOwner(IntPtr handle) { Handle = handle; }
        public IntPtr Handle { get; private set; }
    }
}
'@ -ReferencedAssemblies System.Windows.Forms
}

function Get-OwnerWindow {
    $handle = [SkillsJunction.Dialogs]::GetForegroundWindow()
    if ($handle -ne [IntPtr]::Zero) { return [SkillsJunction.WindowOwner]::new($handle) }
    return $null
}

function Show-Message([string] $Text, [string] $Caption) {
    $owner = Get-OwnerWindow
    if ($owner) { return [System.Windows.Forms.MessageBox]::Show($owner, $Text, $Caption) }
    return [System.Windows.Forms.MessageBox]::Show($Text, $Caption)
}

function Repair-Text([string] $Value) {
    if ([string]::IsNullOrEmpty($Value) -or $Value.IndexOf([char]0xC3) -lt 0) { return $Value }
    $codePage = [System.Text.Encoding]::GetEncoding('windows-1252')
    $current = $Value
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if ($current.IndexOf([char]0xC3) -lt 0) { break }
        $bytes = $codePage.GetBytes($current)
        $next = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($next -eq $current) { break }
        $current = $next
    }
    return $current
}

$script:AppFolder = Join-Path $env:LOCALAPPDATA 'SkillsJunction'
$script:ConfigPath = Join-Path $script:AppFolder 'pairs.json'
$script:Pairs = [System.Collections.ArrayList]::new()
$script:Window = $null
$script:CardsPanel = $null

function Get-NormalPath([string] $Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd([char[]]@('\', '/')) }
    return $full
}

function Test-SamePath([string] $First, [string] $Second) {
    try { return [string]::Equals((Get-NormalPath $First), (Get-NormalPath $Second), [StringComparison]::OrdinalIgnoreCase) }
    catch { return $false }
}

function Test-PathInside([string] $Parent, [string] $Child) {
    $parentPath = (Get-NormalPath $Parent).TrimEnd('\') + '\'
    $childPath = Get-NormalPath $Child
    return $childPath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)
}

function Test-ReparsePoint([string] $Path) {
    if (-not [System.IO.Directory]::Exists($Path)) { return $false }
    return (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-ManagedEntry($Pair, [string] $Name) {
    return @($Pair.Managed | Where-Object { [string]::Equals($_.Name, $Name, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)[0]
}

function Get-ActiveLinkCount($Pair) {
    $count = 0
    foreach ($entry in @($Pair.Managed)) {
        $destination = Join-Path $Pair.Target $entry.Name
        if (-not [System.IO.Directory]::Exists($destination)) { continue }
        try {
            $actual = [SkillsJunction.Native]::GetJunctionTarget($destination)
            if ($actual -and (Test-SamePath $actual $entry.Source)) { $count++ }
        } catch { }
    }
    return $count
}

function Save-Pairs {
    [System.IO.Directory]::CreateDirectory($script:AppFolder) | Out-Null
    $items = @($script:Pairs | ForEach-Object {
        [ordered]@{
            id = $_.Id; name = $_.Name; group = $_.Group
            source = $_.Source; target = $_.Target
            createdTargetRoot = [bool]$_.CreatedTargetRoot
            managed = @($_.Managed | ForEach-Object { [ordered]@{ name = $_.Name; source = $_.Source } })
        }
    })
    $json = ConvertTo-Json -InputObject ([ordered]@{ version = 1; pairs = $items }) -Depth 7
    $temp = $script:ConfigPath + '.tmp'
    [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $script:ConfigPath -Force | Out-Null
}

function Load-Pairs {
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) { return }
    try {
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($item in @($config.pairs)) {
            if (-not $item.id -or -not $item.source -or -not $item.target) { continue }
            $managed = @($item.managed | ForEach-Object {
                if ($_.name -and $_.source) { [pscustomobject]@{ Name = [string]$_.name; Source = [string]$_.source } }
            })
            [void]$script:Pairs.Add([pscustomobject]@{
                Id = [string]$item.id; Name = [string]$item.name; Group = [string]$item.group
                Source = [string]$item.source; Target = [string]$item.target
                CreatedTargetRoot = [bool]$item.createdTargetRoot
                Managed = @($managed)
            })
        }
    } catch {
        Show-Message "Không đọc được cấu hình:`n$($_.Exception.Message)`n`nTệp cấu hình: $script:ConfigPath" 'Skills Junction' | Out-Null
    }
}

function Get-PairValidationError($Pair, [string] $Source, [string] $Target) {
    if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($Target)) { return 'Hãy chọn thư mục Skills nguồn và đích.' }
    try { $sourcePath = Get-NormalPath $Source; $targetPath = Get-NormalPath $Target }
    catch { return 'Đường dẫn thư mục không hợp lệ.' }
    if (Test-SamePath $sourcePath $targetPath) { return 'Nguồn và đích phải là hai thư mục khác nhau.' }
    if ((Test-PathInside $sourcePath $targetPath) -or (Test-PathInside $targetPath $sourcePath)) {
        return 'Nguồn và đích không thể nằm bên trong nhau.'
    }
    foreach ($other in $script:Pairs) {
        if ($Pair -and $other.Id -eq $Pair.Id) { continue }
        if ((Test-SamePath $other.Source $sourcePath) -and (Test-SamePath $other.Target $targetPath)) {
            return 'Cặp thư mục này đã có trong danh sách.'
        }
    }
    return $null
}

function Enable-Pair($Pair) {
    if (-not [System.IO.Directory]::Exists($Pair.Source)) { throw "Không tìm thấy thư mục nguồn:`n$($Pair.Source)" }
    if (Test-ReparsePoint $Pair.Target) { throw "Thư mục đích đang là một Junction hoặc liên kết khác. Hãy chọn thư mục đích thật:`n$($Pair.Target)" }
    if (-not [System.IO.Directory]::Exists($Pair.Target)) {
        $parent = [System.IO.Directory]::GetParent((Get-NormalPath $Pair.Target))
        if (-not $parent -or -not [System.IO.Directory]::Exists($parent.FullName)) {
            throw "Thư mục cha của đích chưa tồn tại:`n$($parent.FullName)"
        }
        [System.IO.Directory]::CreateDirectory($Pair.Target) | Out-Null
        $Pair.CreatedTargetRoot = $true
        Save-Pairs
    }

    $created = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    $folders = @([System.IO.Directory]::GetDirectories($Pair.Source))
    foreach ($sourceFolder in $folders) {
        $sourceInfo = [System.IO.DirectoryInfo]::new($sourceFolder)
        if (($sourceInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $skipped.Add("$($sourceInfo.Name) (nguồn đã là liên kết)")
            continue
        }
        $destination = Join-Path $Pair.Target $sourceInfo.Name
        if ([System.IO.Directory]::Exists($destination) -or [System.IO.File]::Exists($destination)) {
            $existingTarget = $null
            if ([System.IO.Directory]::Exists($destination)) {
                try { $existingTarget = [SkillsJunction.Native]::GetJunctionTarget($destination) } catch { }
            }
            $managedEntry = Get-ManagedEntry $Pair $sourceInfo.Name
            if ($managedEntry -and $existingTarget -and (Test-SamePath $existingTarget $sourceFolder)) { continue }
            $skipped.Add($sourceInfo.Name)
            continue
        }

        if (-not (Get-ManagedEntry $Pair $sourceInfo.Name)) {
            $Pair.Managed = @($Pair.Managed) + @([pscustomobject]@{ Name = $sourceInfo.Name; Source = (Get-NormalPath $sourceFolder) })
            Save-Pairs
        }
        try {
            New-Item -ItemType Junction -Path $destination -Target $sourceFolder -ErrorAction Stop | Out-Null
            $created.Add($sourceInfo.Name)
        } catch {
            $Pair.Managed = @($Pair.Managed | Where-Object { $_.Name -ne $sourceInfo.Name })
            Save-Pairs
            $skipped.Add("$($sourceInfo.Name) (lỗi: $($_.Exception.Message))")
        }
    }
    Save-Pairs
    if ($created.Count -eq 0 -and (Get-ActiveLinkCount $Pair) -eq 0 -and $skipped.Count -gt 0) {
        throw "Chưa tạo được Junction nào. Các mục trùng tên ở đích được giữ nguyên:`n• $($skipped -join "`n• ")"
    }
    $message = if ($created.Count) { "Đã tạo $($created.Count) Junction." } else { 'Các Junction hiện có vẫn hoạt động.' }
    if ($skipped.Count) { $message += "`n`nBỏ qua và giữ nguyên $($skipped.Count) mục trùng tên hoặc không hợp lệ:`n• $($skipped -join "`n• ")" }
    return $message
}

function Disable-Pair($Pair) {
    $removed = [System.Collections.Generic.List[string]]::new()
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Pair.Managed)) {
        $destination = Join-Path $Pair.Target $entry.Name
        if (-not [System.IO.Directory]::Exists($destination)) {
            $removed.Add($entry.Name)
            $Pair.Managed = @($Pair.Managed | Where-Object { $_.Name -ne $entry.Name })
            Save-Pairs
            continue
        }
        try { $actual = [SkillsJunction.Native]::GetJunctionTarget($destination) }
        catch { $actual = $null }
        if ($actual -and (Test-SamePath $actual $entry.Source)) {
            [System.IO.Directory]::Delete($destination, $false)
            $removed.Add($entry.Name)
            $Pair.Managed = @($Pair.Managed | Where-Object { $_.Name -ne $entry.Name })
            Save-Pairs
        } else {
            $kept.Add($entry.Name)
        }
    }

    if ($Pair.CreatedTargetRoot -and $Pair.Managed.Count -eq 0 -and [System.IO.Directory]::Exists($Pair.Target) -and -not (Test-ReparsePoint $Pair.Target)) {
        if (@([System.IO.Directory]::GetFileSystemEntries($Pair.Target)).Count -eq 0) {
            [System.IO.Directory]::Delete($Pair.Target, $false)
            $Pair.CreatedTargetRoot = $false
        }
    }
    Save-Pairs
    $message = "Đã gỡ $($removed.Count) Junction do ứng dụng quản lý. Skills ở nguồn và thư mục có sẵn ở đích được giữ nguyên."
    if ($kept.Count) { $message += "`n`nKhông gỡ được các mục đã thay đổi hoặc không còn khớp nguồn:`n• $($kept -join "`n• ")" }
    return $message
}


if (-not $BackendServer) { throw 'Tệp này chỉ dành cho ứng dụng WebView2.' }
Load-Pairs

function Get-PublicPairs {
    $items = foreach ($pair in $script:Pairs) {
        [ordered]@{
            id = $pair.Id; name = $pair.Name; group = $pair.Group
            source = $pair.Source; target = $pair.Target
            on = ((Get-ActiveLinkCount $pair) -gt 0)
        }
    }
    return $items
}

function Get-ApiPair([string] $Id) {
    return @($script:Pairs | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)[0]
}

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$script:BackendRunning = $true
while ($script:BackendRunning) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    $requestId = ''
    try {
        $request = $line | ConvertFrom-Json -ErrorAction Stop
        # Names may arrive mis-decoded from the host console; recover UTF-8 text.
        foreach ($field in @('name', 'group', 'source', 'target', 'currentPath', 'path')) {
            $property = $request.PSObject.Properties[$field]
            if ($property) { $request.$field = Repair-Text ([string]$request.$field) }
        }
        $requestId = [string]$request.requestId
        $response = [ordered]@{ requestId = $requestId; ok = $true }
        switch ([string]$request.action) {
            'load' { $response.pairs = @(Get-PublicPairs) }
            'browse' {
                $picker = [System.Windows.Forms.FolderBrowserDialog]::new()
                $picker.Description = 'Chọn thư mục Skills'
                $picker.ShowNewFolderButton = $false
                if ($request.currentPath -and [System.IO.Directory]::Exists([string]$request.currentPath)) { $picker.SelectedPath = [string]$request.currentPath }
                $owner = Get-OwnerWindow
                $result = if ($owner) { $picker.ShowDialog($owner) } else { $picker.ShowDialog() }
                if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $response.selectedPath = $picker.SelectedPath }
                else { $response.selectedPath = $null }
                $response.field = [string]$request.field
                $picker.Dispose()
            }
            'add' {
                $name = ([string]$request.name).Trim()
                $group = ([string]$request.group).Trim()
                $source = ([string]$request.source).Trim()
                $target = ([string]$request.target).Trim()
                if (-not $name) { throw 'Hãy nhập tên đích.' }
                $validation = Get-PairValidationError $null $source $target
                if ($validation) { throw $validation }
                $newPair = [pscustomobject]@{
                    Id = [guid]::NewGuid().ToString('N'); Name = $name
                    Group = $(if ($group) { $group } else { 'Skills dùng chung' })
                    Source = $source; Target = $target; CreatedTargetRoot = $false; Managed = @()
                }
                [void]$script:Pairs.Add($newPair)
                try {
                    $response.message = Enable-Pair $newPair
                } catch {
                    if ((Get-ActiveLinkCount $newPair) -gt 0) { $null = Disable-Pair $newPair }
                    [void]$script:Pairs.Remove($newPair)
                    Save-Pairs
                    throw
                }
                $response.pairs = @(Get-PublicPairs)
            }
            'edit' {
                $pair = Get-ApiPair ([string]$request.id)
                if (-not $pair) { throw 'Không tìm thấy cặp Junction này.' }
                $name = ([string]$request.name).Trim()
                $group = ([string]$request.group).Trim()
                $source = ([string]$request.source).Trim()
                $target = ([string]$request.target).Trim()
                if (-not $name) { throw 'Hãy nhập tên đích.' }
                $validation = Get-PairValidationError $pair $source $target
                if ($validation) { throw $validation }
                if ((Get-ActiveLinkCount $pair) -gt 0 -and ((-not (Test-SamePath $pair.Source $source)) -or (-not (Test-SamePath $pair.Target $target)))) {
                    throw 'Hãy tắt Junction trước khi đổi thư mục nguồn hoặc đích.'
                }
                $pair.Name = $name; $pair.Group = $(if ($group) { $group } else { 'Skills dùng chung' })
                $pair.Source = $source; $pair.Target = $target
                Save-Pairs
                $response.message = 'Đã lưu thay đổi.'
                $response.pairs = @(Get-PublicPairs)
            }
            'toggle' {
                $pair = Get-ApiPair ([string]$request.id)
                if (-not $pair) { throw 'Không tìm thấy cặp Junction này.' }
                if ([bool]$request.enabled) { $response.message = Enable-Pair $pair }
                else { $response.message = Disable-Pair $pair }
                $response.pairs = @(Get-PublicPairs)
            }
            'delete' {
                $pair = Get-ApiPair ([string]$request.id)
                if (-not $pair) { throw 'Không tìm thấy cặp Junction này.' }
                if ($pair.Managed.Count -gt 0) {
                    $null = Disable-Pair $pair
                    if ($pair.Managed.Count -gt 0) { throw 'Một số Junction đã thay đổi nên được giữ nguyên. Cấu hình chưa bị xóa.' }
                }
                [void]$script:Pairs.Remove($pair)
                Save-Pairs
                $response.message = 'Đã xóa cấu hình Junction.'
                $response.pairs = @(Get-PublicPairs)
            }
            'skills' {
                $pair = Get-ApiPair ([string]$request.id)
                if (-not $pair) { throw 'Không tìm thấy cặp Junction này.' }
                $skills = @()
                if ([System.IO.Directory]::Exists($pair.Source)) {
                    $skills = @([System.IO.Directory]::GetDirectories($pair.Source) | ForEach-Object {
                        $name = [System.IO.Path]::GetFileName($_)
                        $destination = Join-Path $pair.Target $name
                        $managed = Get-ManagedEntry $pair $name
                        $state = if ($managed -and [System.IO.Directory]::Exists($destination)) { 'Junction do ứng dụng quản lý' } elseif (Test-Path -LiteralPath $destination) { 'Đích đã có sẵn · giữ nguyên' } else { 'Chưa liên kết' }
                        [ordered]@{ name = $name; state = $state }
                    })
                }
                $response.pairId = $pair.Id
                $response.skills = $skills
            }
            'open' {
                $openPath = [string]$request.path
                if ([string]::IsNullOrWhiteSpace($openPath)) { throw 'Thiếu đường dẫn thư mục.' }
                if (-not [System.IO.Directory]::Exists($openPath)) { throw "Thư mục không tồn tại:`n$openPath" }
                Start-Process -FilePath 'explorer.exe' -ArgumentList $openPath
                $response.message = ''
            }
            'quit' { $script:BackendRunning = $false }
            default { throw 'Yêu cầu không hợp lệ.' }
        }
    } catch {
        $response = [ordered]@{ requestId = $requestId; ok = $false; error = $_.Exception.Message }
    }
    $json = ConvertTo-Json -InputObject $response -Depth 12 -Compress
    # Emit pure-ASCII JSON (standard \uXXXX escapes) so any console codepage
    # mis-read by the host cannot corrupt Vietnamese text.
    $json = [regex]::Replace($json, '[^\x00-\x7F]', { param($match) '\u' + ([int][char]$match.Value).ToString('x4') })
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}
