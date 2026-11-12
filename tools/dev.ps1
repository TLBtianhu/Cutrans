param(
    [Parameter(Position = 0)]
    [ValidateSet('bootstrap', 'build', 'verify-repository')]
    [string] $Action = 'build',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments = @()
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$pythonwPath = $null
$pythonwCommand = Get-Command pythonw.exe -ErrorAction SilentlyContinue
if ($pythonwCommand) {
    $pythonwPath = $pythonwCommand.Source
} else {
    # uv-managed Python keeps pythonw.exe beside the interpreter but does not
    # put it on PATH; find the interpreter without changing global PATH.
    $uv = Get-Command uv.exe -ErrorAction SilentlyContinue
    if ($uv) {
        $found = & $uv.Source python find 3.12 2>$null
        if ($LASTEXITCODE -eq 0 -and $found) {
            $candidate = Join-Path (Split-Path ($found | Select-Object -First 1)) 'pythonw.exe'
            if (Test-Path $candidate) { $pythonwPath = $candidate }
        }
    }
    if (-not $pythonwPath) {
        # uv also keeps managed interpreters under %APPDATA%\uv\python when
        # uv.exe itself is unavailable. Prefer the newest recorded 3.x.
        $uvPythonRoot = Join-Path $env:APPDATA 'uv\python'
        $candidates = @(Get-ChildItem -LiteralPath $uvPythonRoot -Directory -Filter 'cpython-*' -ErrorAction SilentlyContinue |
            Sort-Object { if ($_.Name -match '^cpython-(\d+\.\d+)') { [version]$Matches[1] } else { [version]'0.0' } } -Descending)
        foreach ($candidate in $candidates) {
            $pythonw = Join-Path $candidate.FullName 'pythonw.exe'
            if (Test-Path -LiteralPath $pythonw) { $pythonwPath = $pythonw; break }
        }
    }
}
if (-not $pythonwPath) {
    throw 'Python 3 with pythonw.exe is required on PATH (or uv-managed Python 3.12).'
}
$caseId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$request = @{ action = $Action.ToLowerInvariant(); arguments = @($Arguments) } | ConvertTo-Json -Compress
$payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))
$runnerPath = Join-Path $PSScriptRoot 'dev.py'
$logPath = Join-Path $repositoryRoot "scratch\verification\developer-$caseId\run.log"

# Base64 and the generated case id contain no command-line quoting characters.
# Windows filenames cannot contain a double quote; never pass this through cmd.
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $pythonwPath
$startInfo.Arguments = '-B "' + $runnerPath + '" --case ' + $caseId + ' --request ' + $payload
$startInfo.WorkingDirectory = $repositoryRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
Write-Host "Running $Action. Log: $logPath"
$childProcess = New-Object System.Diagnostics.Process
$childProcess.StartInfo = $startInfo
if (-not $childProcess.Start()) { throw 'Could not start the hidden developer runner.' }
$childProcess.WaitForExit()
$exitCode = $childProcess.ExitCode
$childProcess.Dispose()
Write-Host "Exit: $exitCode. Log: $logPath"
exit $exitCode
