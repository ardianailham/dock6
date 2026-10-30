<#
.SYNOPSIS
    DOCK6 Docker Builder for Windows (PowerShell)
.DESCRIPTION
    Builds the dock6-suite Docker image using Docker Desktop on Windows
    and generates Windows-friendly execution wrappers (PowerShell, CMD, and Bash)
    inside the dock6/bin directory.
.PARAMETER Dockerfile
    The Dockerfile to build. Defaults to Dockerfile.gnu_w_parallel.
.EXAMPLE
    .\dockerize_windows.ps1
.EXAMPLE
    .\dockerize_windows.ps1 -Dockerfile Dockerfile.gnu_w_parallel
#>

[CmdletBinding()]
param(
    [Parameter(Position=0, Mandatory=$false)]
    [string]$Dockerfile = "Dockerfile.windows_gnu_w_parallel"
)

$ErrorActionPreference = "Stop"

# Determine script directory and repo root
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path

# Locate Dockerfile
$DockerfilePath = if ([System.IO.Path]::IsPathRooted($Dockerfile)) {
    $Dockerfile
} elseif (Test-Path (Join-Path $ScriptDir $Dockerfile)) {
    Join-Path $ScriptDir $Dockerfile
} elseif (Test-Path (Join-Path (Get-Location).Path $Dockerfile)) {
    (Resolve-Path (Join-Path (Get-Location).Path $Dockerfile)).Path
} else {
    Join-Path $ScriptDir $Dockerfile
}

if (!(Test-Path $DockerfilePath)) {
    Write-Error "Dockerfile not found: $DockerfilePath"
    exit 1
}

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " Building DOCK6 Docker image for Windows               " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "Dockerfile: $DockerfilePath"
Write-Host "Repo Root:  $RepoRoot"

# Ensure dispatcher_windows.sh has LF line endings (required for Linux containers)
$DispatcherPath = Join-Path $ScriptDir "dispatcher_windows.sh"
if (Test-Path $DispatcherPath) {
    Write-Host "Normalizing line endings of dispatcher_windows.sh to LF..."
    $bytes = [System.IO.File]::ReadAllBytes($DispatcherPath)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    [System.IO.File]::WriteAllBytes($DispatcherPath, [System.Text.Encoding]::UTF8.GetBytes($normalized))
}

# Run docker build
Write-Host "`nRunning docker build..." -ForegroundColor Green
$buildCmd = "docker build -f `"$DockerfilePath`" -t dock6-suite `"$RepoRoot`""
Write-Host $buildCmd -ForegroundColor DarkGray
Invoke-Expression $buildCmd

if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

# Ensure bin directory exists
$BinDir = Join-Path $RepoRoot "bin"
if (!(Test-Path $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
}

Write-Host "`nGenerating executable wrappers in $BinDir..." -ForegroundColor Green

# 1. Generate dock6-suite.ps1 (PowerShell wrapper)
$ps1Path = Join-Path $BinDir "dock6-suite.ps1"
$ps1Content = @'
<#
.SYNOPSIS
    DOCK6 Docker Suite Runner for Windows (PowerShell)
.DESCRIPTION
    Executes DOCK6 binaries or opens an interactive shell inside the dock6-suite Docker container.
.PARAMETER b
    The binary name and arguments to execute inside the container (e.g. "dock6 -i dock.in -o dock.out").
.PARAMETER v
    Additional file(s) or folder(s) to mount into the container workspace.
.PARAMETER h
    Display help and usage.
.EXAMPLE
    .\dock6-suite.ps1
    Enters interactive bash session.
.EXAMPLE
    .\dock6-suite.ps1 -b "dock6 -i dock.in -o dock.out"
.EXAMPLE
    .\dock6-suite.ps1 -v "..\other_dir" -b "dock6 -i dock.in -o dock.out"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$b = "",

    [Parameter(Mandatory=$false)]
    [string[]]$v = @(),

    [Parameter(Mandatory=$false)]
    [switch]$h
)

function Show-Usage {
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host '  Interactive: .\dock6-suite.ps1 [-v <path> ...]'
    Write-Host '  Run Command: .\dock6-suite.ps1 -b "<binary> [args...]" [-v <path> ...]'
    Write-Host ""
    Write-Host "Examples:"
    Write-Host '  .\dock6-suite.ps1'
    Write-Host '  .\dock6-suite.ps1 -b "dock6 -i dock.in -o dock.out"'
    Write-Host '  .\dock6-suite.ps1 -b "mpirun -n 4 dock6.mpi -i dock.in -o dock.out"'
    Write-Host '  .\dock6-suite.ps1 -v "C:\path\to\extra_files" -b "dock6 -i dock.in -o dock.out"'
    exit 1
}

if ($h) {
    Show-Usage
}

$CONTAINER_PATH = "/app/workspace"
$CurrentHostDir = (Get-Location).Path

# Build volume arguments
$VolumeArgs = @()
if ($v) {
    foreach ($item in $v) {
        if (-not [string]::IsNullOrWhiteSpace($item)) {
            if (Test-Path $item) {
                $resolved = (Resolve-Path $item).Path
                $leaf = Split-Path -Leaf $resolved
                $VolumeArgs += "-v"
                $VolumeArgs += "${resolved}:${CONTAINER_PATH}/${leaf}"
            } else {
                Write-Warning "Path to mount not found on host: $item"
            }
        }
    }
}

Write-Host "#############################################################" -ForegroundColor Cyan
Write-Host "# Working directory in container: $CONTAINER_PATH" -ForegroundColor Cyan
Write-Host "# Host directory mounted:         $CurrentHostDir" -ForegroundColor Cyan
if ($VolumeArgs.Count -gt 0) {
    Write-Host "# Additional mounts:              $($VolumeArgs -join ' ')" -ForegroundColor Cyan
}
if (-not [string]::IsNullOrWhiteSpace($b)) {
    Write-Host "# Binary call:                    $b" -ForegroundColor Cyan
} else {
    Write-Host "# Mode:                           Interactive bash shell" -ForegroundColor Cyan
}
Write-Host "#############################################################" -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($b)) {
    # Interactive bash session
    docker run -it --rm --entrypoint /bin/bash `
        @VolumeArgs `
        -v "${CurrentHostDir}:${CONTAINER_PATH}" `
        -w $CONTAINER_PATH `
        dock6-suite
} else {
    # Run binary command inside container
    # Using bash -c ensures flags, arguments, redirects, and environment paths resolve seamlessly
    docker run --rm `
        @VolumeArgs `
        -v "${CurrentHostDir}:${CONTAINER_PATH}" `
        -w $CONTAINER_PATH `
        --entrypoint /bin/bash `
        dock6-suite -c "$b"
}
'@

[System.IO.File]::WriteAllText($ps1Path, $ps1Content, [System.Text.Encoding]::UTF8)

# 2. Generate dock6-suite.bat (CMD wrapper)
$batPath = Join-Path $BinDir "dock6-suite.bat"
$batContent = @'
@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dock6-suite.ps1" %*
exit /b %ERRORLEVEL%
'@

[System.IO.File]::WriteAllText($batPath, $batContent, [System.Text.Encoding]::ASCII)

# 3. Generate dock6-suite.docker (Bash wrapper compatible with Git Bash / WSL / MSYS on Windows)
$dockerShPath = Join-Path $BinDir "dock6-suite.docker"
$dockerShContent = @'
#!/bin/bash

# Disable MSYS path mangling on Windows (Git Bash)
export MSYS_NO_PATHCONV=1

usage() { 
    echo "Usage: dock6-suite.docker [ -h help ] [ -b BINARY CALL WITH ARGUMENTS ] [ -v mounting files and folders ]" 1>&2;
    echo "Interactive Mode Usage: dock6-suite.docker [ -h help ] [ -v mounting files and folders ]" 1>&2;
    exit 1; 
}

CONTAINER_PATH="/app/workspace"
VOLUMES=()
BINARYCALL=""

if [ $# -eq 0 ]; then
    echo "No arguments provided...entering interactive mode"
fi

while getopts 'v:b:h' OPTION; do
  case "$OPTION" in
    v)
      FULL_PATH="$(realpath "$OPTARG" 2>/dev/null || readlink -f "$OPTARG")"
      BASE_NAME="$(basename "$OPTARG")"
      VOLUMES+=("-v" "$FULL_PATH:$CONTAINER_PATH/$BASE_NAME")
      ;;
    b)
      BINARYCALL="$OPTARG"
      ;;
    ? | h | *)
      usage
      ;;
  esac
done
shift "$((OPTIND -1))"

HOST_DIR="$(pwd -W 2>/dev/null || pwd -P 2>/dev/null || pwd)"

echo "#############################################################"
echo "# Mounting working directory: $HOST_DIR -> $CONTAINER_PATH"
if [ ${#VOLUMES[@]} -gt 0 ]; then
    echo "# Additional volume mounts: ${VOLUMES[*]}"
fi
echo "# Working directory in container: $CONTAINER_PATH"
if [ -n "$BINARYCALL" ]; then
    echo "# Binary call: $BINARYCALL"
else
    echo "# Mode: Interactive bash shell"
fi
echo "#############################################################"

if [ -z "$BINARYCALL" ]; then
    docker run -it --rm --entrypoint /bin/bash \
        "${VOLUMES[@]}" \
        -v "$HOST_DIR:$CONTAINER_PATH" \
        -w "$CONTAINER_PATH" \
        dock6-suite
else
    docker run --rm \
        "${VOLUMES[@]}" \
        -v "$HOST_DIR:$CONTAINER_PATH" \
        -w "$CONTAINER_PATH" \
        --entrypoint /bin/bash \
        dock6-suite -c "$BINARYCALL"
fi
'@

# Write as LF line endings for bash compatibility
$lfDockerSh = $dockerShContent.Replace("`r`n", "`n")
[System.IO.File]::WriteAllBytes($dockerShPath, [System.Text.Encoding]::UTF8.GetBytes($lfDockerSh))

Write-Host "`nSuccessfully created:" -ForegroundColor Green
Write-Host "  - $ps1Path (PowerShell)"
Write-Host "  - $batPath (CMD / Batch)"
Write-Host "  - $dockerShPath (Bash / Git Bash)"
Write-Host "`nSetup complete! You can now run DOCK6 via dock6-suite in PowerShell, CMD, or Git Bash." -ForegroundColor Cyan
