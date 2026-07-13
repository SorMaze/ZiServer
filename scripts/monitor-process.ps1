param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [ValidateRange(1, 86400)]
    [int]$DurationSeconds = 60,

    [ValidateRange(100, 60000)]
    [int]$IntervalMilliseconds = 1000,

    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProcessSample {
    param([int]$Id, [datetime]$StartedAt)

    $process = Get-Process -Id $Id -ErrorAction Stop
    [pscustomobject]@{
        timestamp_utc       = [DateTime]::UtcNow.ToString('o')
        elapsed_ms          = [math]::Round(([DateTime]::UtcNow - $StartedAt).TotalMilliseconds)
        pid                 = $process.Id
        working_set_mib     = [math]::Round($process.WorkingSet64 / 1MB, 2)
        private_memory_mib  = [math]::Round($process.PrivateMemorySize64 / 1MB, 2)
        virtual_memory_mib  = [math]::Round($process.VirtualMemorySize64 / 1MB, 2)
        handle_count        = $process.HandleCount
        thread_count        = @($process.Threads).Count
        cpu_seconds         = [math]::Round($process.CPU, 3)
    }
}

$startedAt = [DateTime]::UtcNow
$deadline = $startedAt.AddSeconds($DurationSeconds)
$samples = [System.Collections.Generic.List[object]]::new()

while ([DateTime]::UtcNow -lt $deadline) {
    try {
        $samples.Add((Get-ProcessSample -Id $ProcessId -StartedAt $startedAt))
    } catch [System.ArgumentException] {
        break
    }
    Start-Sleep -Milliseconds $IntervalMilliseconds
}

if ($samples.Count -eq 0) {
    throw "Process $ProcessId was not available for sampling."
}

if ($OutFile) {
    $samples | Export-Csv -Path $OutFile -NoTypeInformation -Encoding utf8
}

$first = $samples[0]
$last = $samples[$samples.Count - 1]
[pscustomobject]@{
    samples                  = $samples.Count
    elapsed_seconds          = [math]::Round(($last.elapsed_ms - $first.elapsed_ms) / 1000, 2)
    working_set_delta_mib    = [math]::Round($last.working_set_mib - $first.working_set_mib, 2)
    private_memory_delta_mib = [math]::Round($last.private_memory_mib - $first.private_memory_mib, 2)
    handle_delta             = $last.handle_count - $first.handle_count
    thread_delta             = $last.thread_count - $first.thread_count
    output                   = if ($OutFile) { $OutFile } else { $null }
}
