# Power BI Report Access Log 確認手順

この手順は、Power BI Activity Log から特定 Workspace の特定 Report にアクセスしたユーザーを確認するためのものです。

Activity Log は Power BI / Fabric 管理者向けの監査ログです。特定レポートの閲覧イベントを確認する場合は、操作名 `ViewReport` を取得し、Workspace ID と Report ID で絞り込みます。

## 参考情報

- [Access the Power BI activity log - Power BI](https://learn.microsoft.com/ja-jp/power-bi/guidance/admin-activity-log)
- [Operation list - Microsoft Fabric](https://learn.microsoft.com/ja-jp/fabric/admin/operation-list)
- [Admin - Get Activity Events](https://learn.microsoft.com/ja-jp/rest/api/power-bi/admin/get-activity-events)

## 前提条件

- 実行ユーザーが Fabric administrator であること。
- Azure CLI で対象テナントにログインできること。
- Power BI Management PowerShell module がインストール済みであること。
- Activity Log から直接取得できる期間は通常、直近 28 日です。

28 日より前のログを確認したい場合は、日次で Activity Log を Lakehouse、KQL Database、Storage、または SIEM に保存する運用にします。

## 1. PowerShell を開く

PowerShell 7 以降を推奨します。VS Code のターミナルでも実行できます。

```powershell
$PSVersionTable.PSVersion
```

## 2. Power BI module を確認する

```powershell
Get-Module -ListAvailable MicrosoftPowerBIMgmt* |
    Select-Object Name, Version, Path |
    Format-Table -AutoSize
```

未インストールの場合は、次のコマンドでインストールします。

```powershell
Install-Module MicrosoftPowerBIMgmt -Scope CurrentUser
```

## 3. Azure CLI で対象アカウントにログインする

まず、既に対象アカウントでログイン済みか確認します。

```powershell
az account show --query user.name -o tsv
```

期待するアカウントが表示される場合、`az login` は不要です。未ログイン、または別アカウントが表示される場合のみログインします。

```powershell
az login --tenant <tenant-id-or-domain>
```

ブラウザー認証でターミナルが戻らない場合は、実行中の `az login` を `Ctrl+C` で停止してから、デバイスコード方式に切り替えます。

```powershell
az login --tenant <tenant-id-or-domain> --use-device-code
```

## 4. Power BI API 用トークンで接続する

Power BI REST API 用のトークンを取得し、Power BI PowerShell module に渡します。

```powershell
$token = az account get-access-token `
    --resource https://analysis.windows.net/powerbi/api `
    --query accessToken `
    -o tsv

Connect-PowerBIServiceAccount -Token $token
$headers = @{ Authorization = "Bearer $token" }
```

トークンの有効期限が切れた場合は、このステップを再実行します。

## 5. 対象 Workspace と Report を指定する

```powershell
$workspaceName = '<workspace-name>'
$reportName = '<report-name>'
$daysToCheck = 28
```

例:

```powershell
$workspaceName = 'Sales Analytics'
$reportName = 'Sales Performance Report'
$daysToCheck = 28
```

## 6. Workspace ID と Report ID を解決する

Activity Log のイベントは、Workspace 名や Report 名だけでなく ID を使って絞り込むと安定します。

```powershell
$workspaceResponse = Invoke-RestMethod `
    -Method Get `
    -Headers $headers `
    -Uri "https://api.powerbi.com/v1.0/myorg/groups?`$top=5000"

$workspace = @(
    $workspaceResponse.value |
        Where-Object { $_.name -eq $workspaceName }
)

if ($workspace.Count -ne 1) {
    Write-Host "Workspace match count: $($workspace.Count)"
    $workspaceResponse.value |
        Where-Object { $_.name -like "*$workspaceName*" } |
        Select-Object id, name |
        Format-Table -AutoSize
    throw "Workspace '$workspaceName' was not uniquely found."
}

$reportResponse = Invoke-RestMethod `
    -Method Get `
    -Headers $headers `
    -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($workspace[0].id)/reports"

$report = @(
    $reportResponse.value |
        Where-Object { $_.name -eq $reportName }
)

if ($report.Count -ne 1) {
    Write-Host "Report match count: $($report.Count)"
    $reportResponse.value |
        Where-Object { $_.name -like "*$reportName*" } |
        Select-Object id, name, datasetId |
        Format-Table -AutoSize
    throw "Report '$reportName' was not uniquely found in workspace '$workspaceName'."
}

$workspaceId = $workspace[0].id
$reportId = $report[0].id

[pscustomobject]@{
    WorkspaceName = $workspace[0].name
    WorkspaceId = $workspaceId
    ReportName = $report[0].name
    ReportId = $reportId
    DatasetId = $report[0].datasetId
} | Format-List
```

## 7. まず 1 日分で疎通確認する

```powershell
$activityDate = ([datetime]::UtcNow.Date).ToString('yyyy-MM-dd')

$rawEvents = Get-PowerBIActivityEvent `
    -StartDateTime ($activityDate + 'T00:00:00.000') `
    -EndDateTime ($activityDate + 'T23:59:59.999') `
    -ActivityType 'ViewReport'

$events = @()
if ($rawEvents) {
    $events = @($rawEvents | ConvertFrom-Json)
}

$matchedEvents = @(
    $events |
        Where-Object {
            $_.WorkspaceId -eq $workspaceId -and
            (
                $_.ReportId -eq $reportId -or
                $_.ArtifactId -eq $reportId -or
                $_.ReportName -eq $reportName -or
                $_.ArtifactName -eq $reportName
            )
        }
)

Write-Host "Date UTC: $activityDate"
Write-Host "ViewReport events: $($events.Count)"
Write-Host "Matched report events: $($matchedEvents.Count)"

$matchedEvents |
    Select-Object `
        @{Name = 'CreationTimeUtc'; Expression = { ([datetime]$_.CreationTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } },
        UserId,
        ClientIP,
        ConsumptionMethod,
        DistributionMethod,
        ReportName,
        ArtifactName |
    Format-Table -AutoSize
```

Activity Log の元データは UTC です。ただし、`ConvertFrom-Json` 後に PowerShell が `CreationTime` を表示するとローカル時刻のように見える場合があるため、この手順では `CreationTimeUtc` として明示的に UTC へ変換して表示します。

## 8. 直近 N 日分をユーザーごとに集計する

```powershell
$todayUtc = [datetime]::UtcNow.Date
$allMatchedEvents = @()
$totalScannedEvents = 0

for ($dayOffset = 0; $dayOffset -lt $daysToCheck; $dayOffset++) {
    $targetDateUtc = $todayUtc.AddDays(-$dayOffset)
    $activityDate = $targetDateUtc.ToString('yyyy-MM-dd')

    $rawEvents = Get-PowerBIActivityEvent `
        -StartDateTime ($activityDate + 'T00:00:00.000') `
        -EndDateTime ($activityDate + 'T23:59:59.999') `
        -ActivityType 'ViewReport'

    $events = @()
    if ($rawEvents) {
        $events = @($rawEvents | ConvertFrom-Json)
    }

    $totalScannedEvents += $events.Count

    $matchedEvents = @(
        $events |
            Where-Object {
                $_.WorkspaceId -eq $workspaceId -and
                (
                    $_.ReportId -eq $reportId -or
                    $_.ArtifactId -eq $reportId -or
                    $_.ReportName -eq $reportName -or
                    $_.ArtifactName -eq $reportName
                )
            }
    )

    if ($matchedEvents.Count -gt 0) {
        $allMatchedEvents += $matchedEvents
    }

    Write-Host ("{0}: scanned={1}, matched={2}" -f $activityDate, $events.Count, $matchedEvents.Count)
}

$summary = @(
    $allMatchedEvents |
        Group-Object UserId |
        Sort-Object Count -Descending |
        ForEach-Object {
            $eventsForUser = @($_.Group)
            $firstEvent = $eventsForUser | Sort-Object CreationTime | Select-Object -First 1
            $lastEvent = $eventsForUser | Sort-Object CreationTime -Descending | Select-Object -First 1

            [pscustomobject]@{
                UserId = $_.Name
                Count = $_.Count
                FirstAccessUtc = ([datetime]$firstEvent.CreationTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                LastAccessUtc = ([datetime]$lastEvent.CreationTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                ClientIPs = (($eventsForUser.ClientIP | Sort-Object -Unique) -join ', ')
                ConsumptionMethods = (($eventsForUser.ConsumptionMethod | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
                DistributionMethods = (($eventsForUser.DistributionMethod | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
            }
        }
)

Write-Host ''
Write-Host ("Range UTC: {0} through {1}" -f $todayUtc.AddDays(-($daysToCheck - 1)).ToString('yyyy-MM-dd'), $todayUtc.ToString('yyyy-MM-dd'))
Write-Host "Total scanned ViewReport events: $totalScannedEvents"
Write-Host "Total matched report view events: $($allMatchedEvents.Count)"

$summary | Format-Table -AutoSize
```

## 9. 直近のアクセス明細を見る

```powershell
$recentEvents = @(
    $allMatchedEvents |
        Sort-Object CreationTime -Descending |
        Select-Object -First 50 `
            @{Name = 'CreationTimeUtc'; Expression = { ([datetime]$_.CreationTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } },
            UserId,
            ClientIP,
            ConsumptionMethod,
            DistributionMethod,
            ReportName,
            ArtifactName
)

$recentEvents | Format-Table -AutoSize
```

## 10. CSV に保存する

```powershell
$outputFolder = Join-Path (Get-Location) 'activity-log-output'
New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null

$timestamp = [datetime]::UtcNow.ToString('yyyyMMddHHmmss')

$summaryPath = Join-Path $outputFolder "report-access-summary-$timestamp.csv"
$eventsPath = Join-Path $outputFolder "report-access-events-$timestamp.csv"

$summary | Export-Csv -Path $summaryPath -NoTypeInformation -Encoding UTF8
$recentEvents | Export-Csv -Path $eventsPath -NoTypeInformation -Encoding UTF8

Write-Host "Summary CSV: $summaryPath"
Write-Host "Events CSV: $eventsPath"
```

## 実行結果例

次は公開用のサンプルです。実際のユーザー名、テナント名、Workspace ID、Report ID、Client IP は掲載しないようにしてください。

| UserId | Count | FirstAccessUtc | LastAccessUtc | ConsumptionMethods | DistributionMethods |
|---|---:|---|---|---|---|
| `user1@example.com` | 32 | `2026-06-14T00:21:03Z` | `2026-06-14T11:15:58Z` | `Power BI Web` | `Shared, Workspace` |
| `user2@example.com` | 10 | `2026-06-14T00:13:41Z` | `2026-06-14T00:46:41Z` | `Power BI Web` | `Workspace` |

## 読み方と注意点

- ユーザーが Report を閲覧したイベントは `ViewReport` です。
- `Count` はアクセス回数の目安です。ページ遷移、再読み込み、共有経由、アプリ経由などで複数イベントが記録されることがあります。
- `CreationTime` は UTC 基準で扱うことを推奨します。
- Report が Power BI app 経由で閲覧された場合、一部の容量情報などが null になることがあります。
- Activity Log の抽出自体も `ExportActivityEvents` として記録されることがありますが、この手順では `ViewReport` のみを対象にしているため通常は混ざりません。
- 公開ドキュメントに実ユーザーの UPN、テナント名、Workspace ID、Report ID、Client IP を含めないようにします。

## トラブルシューティング

### `Get-PowerBIActivityEvent` が失敗する

- 実行ユーザーが Fabric administrator か確認します。
- `Connect-PowerBIServiceAccount -Token $token` を再実行します。
- トークン取得時の `--resource` が `https://analysis.windows.net/powerbi/api` になっているか確認します。

### Workspace または Report が見つからない

- Workspace 名と Report 名の完全一致を確認します。
- 大文字小文字や余分なスペースを確認します。
- 候補表示に出た `id`, `name` を見て、変数の値を修正します。

### 28 日より古いログを確認したい

- Activity Log API から直接遡れる期間には制限があります。
- 長期確認が必要な場合は、日次で Activity Log を Lakehouse、KQL Database、Storage、または SIEM に保存する運用にします。
