param (
    [string]$FlowDeveloperName = "Revenant_Read_Workflow_Status_Example"
)

Write-Host "Querying inactive versions for flow: $FlowDeveloperName..." -ForegroundColor Cyan

$query = "SELECT Id, VersionNumber, Status FROM Flow WHERE Definition.DeveloperName = '$FlowDeveloperName' AND Status != 'Active'"
$result = sf data query --query $query --use-tooling-api --json | ConvertFrom-Json

$records = $result.result.records

if ($records -and $records.Count -gt 0) {
    Write-Host "Found $($records.Count) inactive version(s). Starting deletion..." -ForegroundColor Yellow
    foreach ($flow in $records) {
        Write-Host "Deleting version ID $($flow.Id) (Status: $($flow.Status))..."
        $deleteResult = sf data delete record --sobject Flow --record-id $flow.Id --use-tooling-api --json | ConvertFrom-Json
        if ($deleteResult.status -eq 0) {
            Write-Host "Successfully deleted version ID $($flow.Id)" -ForegroundColor Green
        } else {
            Write-Warning "Failed to delete version ID $($flow.Id)"
        }
    }
    Write-Host "Purge complete!" -ForegroundColor Green
} else {
    Write-Host "No inactive versions found for flow: $FlowDeveloperName." -ForegroundColor Green
}
