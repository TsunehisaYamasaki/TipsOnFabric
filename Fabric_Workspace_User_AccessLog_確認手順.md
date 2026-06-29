# Fabric Workspace User Access Log 確認手順

この手順は、Power BI / Fabric Activity Log から特定 Workspace に関するユーザー操作を確認するためのものです。

Workspace の「ユーザーアクセスログ」は、目的によって次の 3 種類に分けて確認します。

1. Workspace 内の Report、Semantic model、Lakehouse、Warehouse などを誰が利用したか
2. Workspace のユーザー追加、削除、ロール変更がいつ行われたか
3. 現在 Workspace にアクセス権を持つユーザー、グループ、サービスプリンシパルは誰か

Activity Log は Power BI / Fabric 管理者向けの監査ログです。Workspace 単位で確認する場合は、対象 Workspace の ID を解決し、Activity Log の `WorkspaceId` で絞り込みます。

## 参考情報

- [Access the Power BI activity log - Power BI](https://learn.microsoft.com/ja-jp/power-bi/guidance/admin-activity-log)
- [Operation list - Microsoft Fabric](https://learn.microsoft.com/ja-jp/fabric/admin/operation-list)
- [Admin - Get Activity Events](https://learn.microsoft.com/ja-jp/rest/api/power-bi/admin/get-activity-events)
- [Admin - Groups GetGroupUsersAsAdmin](https://learn.microsoft.com/ja-jp/rest/api/power-bi/admin/groups-get-group-users-as-admin)
- [Groups - Get Group Users](https://learn.microsoft.com/ja-jp/rest/api/power-bi/groups/get-group-users)

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
az login --tenant '<tenant-id-or-domain>'
```

ブラウザー認証でターミナルが戻らない場合は、実行中の `az login` を `Ctrl+C` で停止してから、デバイスコード方式に切り替えます。

```powershell
az login --tenant '<tenant-id-or-domain>' --use-device-code
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

## 5. 対象 Workspace を指定する

```powershell
$workspaceName = '<workspace-name>'
$daysToCheck = 28
```

例:

```powershell
$workspaceName = 'Sales Analytics'
$daysToCheck = 28
```

## 6. Workspace ID を解決する

Activity Log のイベントは、Workspace 名だけでなく ID を使って絞り込むと安定します。

Fabric administrator としてテナント内の Workspace を確認する場合は、管理 API を使用します。

```powershell
$workspaceResponse = Invoke-RestMethod `
    -Method Get `
    -Headers $headers `
    -Uri "https://api.powerbi.com/v1.0/myorg/admin/groups?`$top=5000"

$workspace = @(
    $workspaceResponse.value |
        Where-Object { $_.name -eq $workspaceName }
)

if ($workspace.Count -ne 1) {
    Write-Host "Workspace match count: $($workspace.Count)"
    $workspaceResponse.value |
        Where-Object { $_.name -like "*$workspaceName*" } |
        Select-Object id, name, type, state |
        Format-Table -AutoSize
    throw "Workspace '$workspaceName' was not uniquely found."
}

$workspaceId = $workspace[0].id

[pscustomobject]@{
    WorkspaceName = $workspace[0].name
    WorkspaceId = $workspaceId
    Type = $workspace[0].type
    State = $workspace[0].state
} | Format-List
```

自分が管理者またはメンバーとして参加している Workspace だけを対象にする場合は、次の API でも確認できます。

```powershell
Invoke-RestMethod `
    -Method Get `
    -Headers $headers `
    -Uri "https://api.powerbi.com/v1.0/myorg/groups?`$top=5000"
```

## 7. まず 1 日分で疎通確認する

Activity Type を指定しない場合、その日の Activity Log 全体を取得してから Workspace ID で絞り込みます。テナントのイベント数が多い場合は、後述の「Activity Type を絞って取得する」を使ってください。

```powershell
$activityDate = ([datetime]::UtcNow.Date).ToString('yyyy-MM-dd')

$rawEvents = Get-PowerBIActivityEvent `
    -StartDateTime ($activityDate + 'T00:00:00.000') `
    -EndDateTime ($activityDate + 'T23:59:59.999')

$events = @()
if ($rawEvents) {
    $events = @($rawEvents | ConvertFrom-Json)
}

$matchedEvents = @(
    $events |
        Where-Object { $_.WorkspaceId -eq $workspaceId }
)

Write-Host "Date UTC: $activityDate"
Write-Host "Total events: $($events.Count)"
Write-Host "Matched workspace events: $($matchedEvents.Count)"

$matchedEvents |
    Sort-Object CreationTime -Descending |
    Select-Object -First 50 `
        @{Name = 'CreationTimeUtc'; Expression = { ([datetime]$_.CreationTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } },
        UserId,
        Activity,
        WorkSpaceName,
        ItemName,
        ArtifactName,
        ClientIP |
    Format-Table -AutoSize
```

Activity Log の元データは UTC です。ただし、`ConvertFrom-Json` 後に PowerShell が `CreationTime` を表示するとローカル時刻のように見える場合があるため、この手順では `CreationTimeUtc` として明示的に UTC へ変換して表示します。

## 8. 直近 N 日分をユーザーごとに集計する

```powershell
$todayUtc = [datetime]::UtcNow.Date
$allWorkspaceEvents = @()
$totalScannedEvents = 0

for ($dayOffset = 0; $dayOffset -lt $daysToCheck; $dayOffset++) {
    $targetDateUtc = $todayUtc.AddDays(-$dayOffset)
    $activityDate = $targetDateUtc.ToString('yyyy-MM-dd')

    $rawEvents = Get-PowerBIActivityEvent `
        -StartDateTime ($activityDate + 'T00:00:00.000') `
        -EndDateTime ($activityDate + 'T23:59:59.999')

    $events = @()
    if ($rawEvents) {
        $events = @($rawEvents | ConvertFrom-Json)
    }

    $totalScannedEvents += $events.Count

    $matchedEvents = @(
        $events |
            Where-Object { $_.WorkspaceId -eq $workspaceId }
    )

    if ($matchedEvents.Count -gt 0) {
        $allWorkspaceEvents += $matchedEvents
    }

    Write-Host ("{0}: scanned={1}, workspaceMatched={2}" -f $activityDate, $events.Count, $matchedEvents.Count)
}

$summary = @(
    $allWorkspaceEvents |
        Where-Object { $_.UserId } |
        Group-Object UserId |
        Sort-Object Count -Descending |
        ForEach-Object {
            $eventsForUser = @($_.Group)
            $firstEvent = $eventsForUser | Sort-Object CreationTime | Select-Object -First 1
            $lastEvent = $eventsForUser | Sort-Object CreationTime -Descending | Select-Object -First 1

            [pscustomobject]@{
                UserId = $_.Name
                Count = $_.Count
                FirstActivityUtc = ([datetime]$firstEvent.CreationTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                LastActivityUtc = ([datetime]$lastEvent.CreationTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                Activities = (($eventsForUser.Activity | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
                ClientIPs = (($eventsForUser.ClientIP | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
            }
        }
)

Write-Host ''
Write-Host ("Range UTC: {0} through {1}" -f $todayUtc.AddDays(-($daysToCheck - 1)).ToString('yyyy-MM-dd'), $todayUtc.ToString('yyyy-MM-dd'))
Write-Host "Total scanned events: $totalScannedEvents"
Write-Host "Total matched workspace events: $($allWorkspaceEvents.Count)"

$summary | Format-Table -AutoSize
```

## 9. Activity 種類別に集計する

Workspace 内でどの種類の操作が多いかを確認します。

```powershell
$activitySummary = @(
    $allWorkspaceEvents |
        Group-Object Activity |
        Sort-Object Count -Descending |
        Select-Object Name, Count
)

$activitySummary | Format-Table -AutoSize
```

代表的な Activity の例:

| Activity | 意味 |
|---|---|
| `ViewReport` | Power BI Report の閲覧 |
| `ViewDashboard` | Dashboard の閲覧 |
| `ReadArtifact` | Fabric item の読み取り |
| `ViewWarehouse` | Warehouse の表示 |
| `ViewSqlAnalyticsEndpointLakehouse` | Lakehouse の SQL analytics endpoint の表示 |
| `ReadFileOrGetBlob` | OneLake ファイルまたは BLOB の読み取り |
| `ListFilePath` | OneLake パス配下の一覧表示 |
| `ExportActivityEvents` | Activity Log の抽出 |

## 10. 直近のアクセス明細を見る

```powershell
$recentEvents = @(
    $allWorkspaceEvents |
        Sort-Object CreationTime -Descending |
        Select-Object -First 100 `
            @{Name = 'CreationTimeUtc'; Expression = { ([datetime]$_.CreationTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } },
            UserId,
            Activity,
            WorkSpaceName,
            ItemName,
            ArtifactName,
            ReportName,
            DatasetName,
            ClientIP,
            ConsumptionMethod,
            DistributionMethod
)

$recentEvents | Format-Table -AutoSize
```

## 11. Workspace の権限変更ログを確認する

Workspace に対するユーザー追加、削除、ロール変更を確認する場合は、Workspace 関連の権限操作に絞ります。

```powershell
$workspaceAccessChangeActivities = @(
    'AddWorkspaceRoleViaAdminApi',
    'UpdateWorkspaceRoleViaAdminApi',
    'DeleteWorkspaceRoleViaAdminApi',
    'AddGroupMembers',
    'DeleteGroupMembers',
    'UpdateWorkspaceAccess'
)

$workspaceAccessReadActivities = @(
    'GetWorkspaceUsersViaAdminApi',
    'GetGroupUsersAsAdmin',
    'GetGroupUsers'
)

$permissionEvents = @(
    $allWorkspaceEvents |
        Where-Object {
            $workspaceAccessChangeActivities -contains $_.Activity -or
            $workspaceAccessChangeActivities -contains $_.Operation -or
            $workspaceAccessReadActivities -contains $_.Activity -or
            $workspaceAccessReadActivities -contains $_.Operation -or
            $_.Activity -match 'Workspace.*Access|Workspace.*Role|GroupMembers|GroupUsers'
        }
)

$permissionEvents |
    Sort-Object CreationTime -Descending |
    Select-Object `
        @{Name = 'CreationTimeUtc'; Expression = { ([datetime]$_.CreationTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } },
        UserId,
        Activity,
        Operation,
        WorkSpaceName,
        WorkspaceId,
        ClientIP |
    Format-Table -AutoSize
```

`GetWorkspaceUsersViaAdminApi`、`GetGroupUsersAsAdmin`、`GetGroupUsers` は、権限を変更したイベントではなく、権限一覧を取得した API 呼び出しのログです。実際の追加、削除、更新を見たい場合は `Add*`、`Update*`、`Delete*` 系のイベントを中心に確認します。

## 12. 現在の Workspace アクセス権一覧を確認する

これはログではなく、現時点のスナップショットです。過去の変更履歴を見たい場合は、前のステップの Activity Log を確認します。

Fabric administrator として取得する場合:

```powershell
$currentUsersResponse = Invoke-RestMethod `
    -Method Get `
    -Headers $headers `
    -Uri "https://api.powerbi.com/v1.0/myorg/admin/groups/$workspaceId/users"

$currentUsers = @($currentUsersResponse.value)

$currentUsers |
    Sort-Object principalType, groupUserAccessRight, displayName |
    Select-Object displayName, emailAddress, groupUserAccessRight, principalType, identifier, graphId |
    Format-Table -AutoSize
```

Workspace の管理者またはメンバーとして取得する場合:

```powershell
$currentUsersResponse = Invoke-RestMethod `
    -Method Get `
    -Headers $headers `
    -Uri "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/users"

$currentUsers = @($currentUsersResponse.value)

$currentUsers |
    Sort-Object principalType, groupUserAccessRight, displayName |
    Select-Object displayName, emailAddress, groupUserAccessRight, principalType, identifier |
    Format-Table -AutoSize
```

## 13. Activity Type を絞って取得する

テナントの Activity Log が多い場合は、すべての Activity を取得せず、確認したい Activity Type だけを取得します。

```powershell
$activityTypesToCheck = @(
    'ViewReport',
    'ViewDashboard',
    'ReadArtifact',
    'ViewWarehouse',
    'ViewSqlAnalyticsEndpointLakehouse',
    'ReadFileOrGetBlob',
    'ListFilePath',
    'AddWorkspaceRoleViaAdminApi',
    'UpdateWorkspaceRoleViaAdminApi',
    'DeleteWorkspaceRoleViaAdminApi',
    'AddGroupMembers',
    'DeleteGroupMembers',
    'UpdateWorkspaceAccess'
)

$todayUtc = [datetime]::UtcNow.Date
$filteredWorkspaceEvents = @()

for ($dayOffset = 0; $dayOffset -lt $daysToCheck; $dayOffset++) {
    $targetDateUtc = $todayUtc.AddDays(-$dayOffset)
    $activityDate = $targetDateUtc.ToString('yyyy-MM-dd')

    foreach ($activityType in $activityTypesToCheck) {
        $rawEvents = Get-PowerBIActivityEvent `
            -StartDateTime ($activityDate + 'T00:00:00.000') `
            -EndDateTime ($activityDate + 'T23:59:59.999') `
            -ActivityType $activityType

        $events = @()
        if ($rawEvents) {
            $events = @($rawEvents | ConvertFrom-Json)
        }

        $matchedEvents = @(
            $events |
                Where-Object { $_.WorkspaceId -eq $workspaceId }
        )

        if ($matchedEvents.Count -gt 0) {
            $filteredWorkspaceEvents += $matchedEvents
        }

        Write-Host ("{0} {1}: scanned={2}, workspaceMatched={3}" -f $activityDate, $activityType, $events.Count, $matchedEvents.Count)
    }
}

$filteredWorkspaceEvents |
    Sort-Object CreationTime -Descending |
    Select-Object -First 100 `
        @{Name = 'CreationTimeUtc'; Expression = { ([datetime]$_.CreationTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } },
        UserId,
        Activity,
        WorkSpaceName,
        ItemName,
        ArtifactName,
        ClientIP |
    Format-Table -AutoSize
```

Activity Type を増やす場合は、[Operation list - Microsoft Fabric](https://learn.microsoft.com/ja-jp/fabric/admin/operation-list) で対象操作名を確認してから `$activityTypesToCheck` に追加します。

## 14. CSV に保存する

```powershell
$outputFolder = Join-Path (Get-Location) 'activity-log-output'
New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null

$timestamp = [datetime]::UtcNow.ToString('yyyyMMddHHmmss')

$summaryPath = Join-Path $outputFolder "workspace-access-summary-$timestamp.csv"
$activitySummaryPath = Join-Path $outputFolder "workspace-activity-summary-$timestamp.csv"
$eventsPath = Join-Path $outputFolder "workspace-access-events-$timestamp.csv"
$permissionEventsPath = Join-Path $outputFolder "workspace-permission-events-$timestamp.csv"
$currentUsersPath = Join-Path $outputFolder "workspace-current-users-$timestamp.csv"

$summary | Export-Csv -Path $summaryPath -NoTypeInformation -Encoding UTF8
$activitySummary | Export-Csv -Path $activitySummaryPath -NoTypeInformation -Encoding UTF8
$recentEvents | Export-Csv -Path $eventsPath -NoTypeInformation -Encoding UTF8
$permissionEvents | Export-Csv -Path $permissionEventsPath -NoTypeInformation -Encoding UTF8
$currentUsers | Export-Csv -Path $currentUsersPath -NoTypeInformation -Encoding UTF8

Write-Host "User summary CSV: $summaryPath"
Write-Host "Activity summary CSV: $activitySummaryPath"
Write-Host "Recent events CSV: $eventsPath"
Write-Host "Permission events CSV: $permissionEventsPath"
Write-Host "Current users CSV: $currentUsersPath"
```

## 実行結果例

次は公開用のサンプルです。実際のユーザー名、テナント名、Workspace ID、Client IP は掲載しないようにしてください。

### ユーザーごとの Workspace Activity 集計

| UserId | Count | FirstActivityUtc | LastActivityUtc | Activities |
|---|---:|---|---|---|
| user1@example.com | 45 | 2026-06-14T00:12:10Z | 2026-06-14T10:31:18Z | ViewReport, ReadArtifact |
| user2@example.com | 12 | 2026-06-13T23:51:02Z | 2026-06-14T01:08:44Z | ViewWarehouse, ReadFileOrGetBlob |

### Activity 種類別集計

| Name | Count |
|---|---:|
| ViewReport | 40 |
| ReadArtifact | 12 |
| ViewWarehouse | 5 |

### 現在の Workspace アクセス権一覧

| displayName | emailAddress | groupUserAccessRight | principalType |
|---|---|---|---|
| User One | user1@example.com | Admin | User |
| Analytics Members |  | Member | Group |
| Reporting App |  | Viewer | App |

## 読み方と注意点

- Workspace にアクセスしたこと自体を示す単一のイベントだけを見るのではなく、Workspace 内の item に対する操作を `WorkspaceId` で集めて判断します。
- 単に Fabric ポータル上で Workspace 一覧や画面を開いただけの操作は、期待する形で Activity Log に出ない場合があります。
- Report 閲覧は `ViewReport`、Fabric item の読み取りは `ReadArtifact`、OneLake のファイル読み取りは `ReadFileOrGetBlob` など、item 種類ごとに Activity が分かれます。
- `Count` はアクセス回数の目安です。ページ遷移、再読み込み、共有経由、アプリ経由、API 実行などで複数イベントが記録されることがあります。
- `CreationTime` は UTC 基準で扱うことを推奨します。
- Activity Log の抽出自体も `ExportActivityEvents` として記録されることがあります。
- `GetWorkspaceUsersViaAdminApi`、`GetGroupUsersAsAdmin`、`GetGroupUsers` は権限一覧を取得した操作のログであり、権限変更そのものではありません。
- 現在の Workspace アクセス権一覧はスナップショットです。過去に誰が追加、削除、変更されたかは Activity Log 側を確認します。
- 公開ドキュメントに実ユーザーの UPN、テナント名、Workspace ID、Client IP を含めないようにします。

## トラブルシューティング

### `Get-PowerBIActivityEvent` が失敗する

- 実行ユーザーが Fabric administrator か確認します。
- `Connect-PowerBIServiceAccount -Token $token` を再実行します。
- トークン取得時の `--resource` が `https://analysis.windows.net/powerbi/api` になっているか確認します。
- 取得対象の日付が UTC の同一日内になっているか確認します。

### Workspace が見つからない

- Workspace 名の完全一致を確認します。
- 大文字小文字や余分なスペースを確認します。
- 候補表示に出た `id`, `name`, `state` を見て、変数の値を修正します。
- 自分が参加していない Workspace まで確認する場合は、`/myorg/groups` ではなく `/myorg/admin/groups` を使用します。

### イベント数が多くて時間がかかる

- Step 13 のように Activity Type を絞って取得します。
- 確認期間を短くします。
- 日次で Activity Log を保存し、Lakehouse、KQL Database、Storage、または SIEM 側で検索します。

### 現在の Workspace ユーザー一覧を取得できない

- Fabric administrator として実行する場合は `/myorg/admin/groups/{groupId}/users` を使用します。
- Workspace の管理者またはメンバーとして実行する場合は `/myorg/groups/{groupId}/users` を使用します。
- Workspace ユーザー権限の更新は反映に時間がかかる場合があります。

### 28 日より古いログを確認したい

- Activity Log API から直接遡れる期間には制限があります。
- 長期確認が必要な場合は、日次で Activity Log を Lakehouse、KQL Database、Storage、または SIEM に保存する運用にします。