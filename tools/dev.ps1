param(
    [Parameter(Position = 0)]
    [ValidateSet('bootstrap', 'build', 'verify-repository')]
    [string] $Action = 'build',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments = @()
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$pythonwCommand = Get-Command pythonw.exe -ErrorAction SilentlyContinue
if (-not $pythonwCommand) {
    throw 'Python 3 with pythonw.exe is required on PATH.'
}
$caseId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$request = @{ action = $Action.ToLowerInvariant(); arguments = @($Arguments) } | ConvertTo-Json -Compress
$payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))
$runnerPath = Join-Path $PSScriptRoot 'dev.py'
$logPath = Join-Path $repositoryRoot "scratch\verification\developer-$caseId\run.log"

# Base64 and the generated case id contain no command-line quoting characters.
# Windows filenames cannot contain a double quote; never pass this through cmd.
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $pythonwCommand.Source
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
