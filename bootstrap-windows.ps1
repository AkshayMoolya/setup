# CloudLCMS - Windows bootstrap.
# A blank Windows laptop has no bash, so this installs Git for Windows (which
# ships Git Bash) and then runs setup.sh with it, passing any arguments through.
#
#   powershell -ExecutionPolicy Bypass -File setup\bootstrap-windows.ps1
#   powershell -ExecutionPolicy Bypass -File setup\bootstrap-windows.ps1 --verify

$ErrorActionPreference = 'Stop'

function Find-GitBash {
    foreach ($p in @("$env:ProgramFiles\Git\bin\bash.exe",
                     "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
                     "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

$bash = Find-GitBash
if (-not $bash) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget is missing. Install 'App Installer' from the Microsoft Store, then run this again." -ForegroundColor Red
        exit 1
    }
    Write-Host "Installing Git for Windows ..." -ForegroundColor Cyan
    winget install --id Git.Git --exact --silent --accept-package-agreements --accept-source-agreements
    $bash = Find-GitBash
    if (-not $bash) {
        Write-Host "Git installed but bash.exe was not found. Open a new PowerShell window and run this again." -ForegroundColor Red
        exit 1
    }
}

$script = Join-Path $PSScriptRoot 'setup.sh'
Write-Host "Running setup.sh with $bash" -ForegroundColor Cyan
& $bash $script @args
exit $LASTEXITCODE
