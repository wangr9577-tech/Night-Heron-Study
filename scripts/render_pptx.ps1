param([string]$SourcePath, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$pptApp = $null
$deck = $null
try {
    [void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
    $pptApp = New-Object -ComObject PowerPoint.Application
    $pptApp.AutomationSecurity = 3
    $pptApp.DisplayAlerts = 1
    $deck = $pptApp.Presentations.Open($SourcePath, $true, $false, $false)
    $deck.Export($OutputDirectory, 'PNG', 1280, 720)
} finally {
    if ($null -ne $deck) { $deck.Close(); [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($deck) }
    if ($null -ne $pptApp) {
        if ($pptApp.Presentations.Count -eq 0) { $pptApp.Quit() }
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($pptApp)
    }
}
