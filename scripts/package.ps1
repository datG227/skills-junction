[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')]
    [string] $Version,
    [string] $PublishDirectory,
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
if (-not $PublishDirectory) { $PublishDirectory = Join-Path $PSScriptRoot '../artifacts/publish' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot '../artifacts/releases' }
$publishRoot = [IO.Path]::GetFullPath($PublishDirectory).TrimEnd('\', '/')
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$required = @(
    'SkillsJunction.WebView2.exe', 'SkillsJunction.WebView2.dll',
    'SkillsJunction.WebView2.deps.json', 'SkillsJunction.WebView2.runtimeconfig.json',
    'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll',
    'WebView2Loader.dll', 'backend/SkillsJunction.WebView2.ps1',
    'web/index.html', 'web/app.js', 'web/styles.css', 'README.md', 'LICENSE'
)
$files = @($required | ForEach-Object {
    $file = Join-Path $publishRoot $_
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing published file: $_. Run scripts/build.ps1 first." }
    $item = Get-Item -LiteralPath $file -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Cannot package a linked file: $_" }
    $item
})
$runtimePath = Join-Path $publishRoot 'runtimes'
if (Test-Path -LiteralPath $runtimePath) {
    $runtimeItems = @((Get-Item -LiteralPath $runtimePath -Force)) + @(Get-ChildItem -LiteralPath $runtimePath -Recurse -Force)
    if (@($runtimeItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        throw 'Cannot package linked runtime files or directories.'
    }
    $files += @($runtimeItems | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.dll' })
}
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$archiveName = "SkillsJunction-v$Version-win-x64.zip"
$archivePath = Join-Path $outputRoot $archiveName
$tempPath = Join-Path $outputRoot ($archiveName + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
$stream = [IO.File]::Open($tempPath, [IO.FileMode]::CreateNew)
try {
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($file in $files) {
            if (-not $file.FullName.StartsWith($publishRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'A package file escaped the published directory.'
            }
            $relative = $file.FullName.Substring($publishRoot.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName,
                "SkillsJunction-v$Version/$relative", [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $zip.Dispose() }
    Move-Item -LiteralPath $tempPath -Destination $archivePath -Force -ErrorAction Stop
} finally {
    $stream.Dispose()
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
}
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $outputRoot 'SHA256SUMS.txt'), "$hash  $archiveName`n", [Text.UTF8Encoding]::new($false))
Write-Output $archivePath
