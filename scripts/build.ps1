[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')]
    [string] $Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'The desktop app must be built on Windows.' }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactRoot = Join-Path $repoRoot 'artifacts'
$publishRoot = [IO.Path]::GetFullPath((Join-Path $artifactRoot 'publish'))
if (-not $publishRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Publish output must stay inside the repository.'
}
# Validate the exact generated target and its parent before recursive cleanup.
foreach ($generatedPath in @($artifactRoot, $publishRoot)) {
    if ((Test-Path -LiteralPath $generatedPath) -and
        ((Get-Item -LiteralPath $generatedPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Generated output cannot be a junction or symbolic link: $generatedPath"
    }
}
if ([IO.Directory]::Exists($publishRoot)) {
    # Directory.Delete removes nested reparse points without following their targets.
    # https://learn.microsoft.com/en-us/dotnet/api/system.io.directory.delete
    [IO.Directory]::Delete($publishRoot, $true)
}
Push-Location $repoRoot
try {
    $project = 'src/SkillsJunction.Desktop/SkillsJunction.Desktop.csproj'
    dotnet restore $project --locked-mode
    if ($LASTEXITCODE -ne 0) { throw 'Locked NuGet restore failed.' }
    dotnet build $project -c Release --no-restore -p:Version=$Version -warnaserror
    if ($LASTEXITCODE -ne 0) { throw 'Desktop build failed.' }
    dotnet publish $project -c Release --no-build --no-restore -p:Version=$Version -o $publishRoot
    if ($LASTEXITCODE -ne 0) { throw 'Desktop publish failed.' }
    Write-Output "Application: $(Join-Path $publishRoot 'SkillsJunction.WebView2.exe')"
} finally { Pop-Location }
