# Fabric 容量の自動一時停止・再開（スケジュール実行）

最終更新日: 2026-04-16

---

## 1. 概要

Microsoft Fabric の F SKU 容量は **一時停止（Suspend）** すると課金が停止し、**再開（Resume）** すると課金が再開します。  
これをスケジュール実行することで、使用しない時間帯（夜間・休日）のコストを削減できます。

### 自動化の方法

Azure PowerShell の `Az.Fabric` モジュールを使用し、Windows タスクスケジューラでスケジュール実行する方法を案内します。

---

## 2. 前提条件

- **F SKU 容量** であること（P SKU / Trial は対象外）
- 実行アカウント（サービスプリンシパル）に以下の Azure RBAC 権限が必要:
  - `Microsoft.Fabric/capacities/read`
  - `Microsoft.Fabric/capacities/write`
  - `Microsoft.Fabric/capacities/suspend/action`
  - `Microsoft.Fabric/capacities/resume/action`
- 最も簡単なのは、対象リソースグループまたは容量に **Contributor** ロールを付与すること

---

## 3. Azure PowerShell（Az.Fabric モジュール）

### 3-1. 対象環境（例）

| 項目 | 値 |
|---|---|
| サブスクリプション ID | `<YOUR_SUBSCRIPTION_ID>` |
| リソースグループ | `<YOUR_RESOURCE_GROUP>` |
| 容量名 | `<YOUR_CAPACITY_NAME>` |
| SKU | F64 |
| リージョン | （ご自身のリージョン） |
| サービスプリンシパル名 | `<YOUR_SP_NAME>` |
| ApplicationId | `<YOUR_APPLICATION_ID>` |
| TenantId | `<YOUR_TENANT_ID>` |

### 3-2. コマンド

```powershell
# モジュールインストール（初回のみ）
Install-Module -Name Az.Fabric -Scope CurrentUser -Force

# ログイン
Connect-AzAccount -SubscriptionId "<YOUR_SUBSCRIPTION_ID>"

# --- 一時停止 ---
Suspend-AzFabricCapacity `
    -CapacityName "<YOUR_CAPACITY_NAME>" `
    -ResourceGroupName "<YOUR_RESOURCE_GROUP>"

# --- 再開 ---
Resume-AzFabricCapacity `
    -CapacityName "<YOUR_CAPACITY_NAME>" `
    -ResourceGroupName "<YOUR_RESOURCE_GROUP>"

# --- 現在の状態を確認 ---
Get-AzFabricCapacity `
    -CapacityName "<YOUR_CAPACITY_NAME>" `
    -ResourceGroupName "<YOUR_RESOURCE_GROUP>" | Select-Object Name, State, SkuName
```

### 3-3. スケジュール実行（Windows タスクスケジューラ）

スクリプト: `Fabric-Suspend.ps1`

```powershell
# Fabric-Suspend.ps1
param(
    [string]$Action = "Suspend"   # "Suspend" or "Resume"
)

$CapacityName      = "<YOUR_CAPACITY_NAME>"
$ResourceGroupName = "<YOUR_RESOURCE_GROUP>"
$SubscriptionId    = "<YOUR_SUBSCRIPTION_ID>"

# サービスプリンシパル認証情報
$TenantId      = "<YOUR_TENANT_ID>"
$ApplicationId = "<YOUR_APPLICATION_ID>"
$Secret        = "<YOUR_CLIENT_SECRET>"

$secureSecret = ConvertTo-SecureString $Secret -AsPlainText -Force
$credential   = New-Object System.Management.Automation.PSCredential($ApplicationId, $secureSecret)
Connect-AzAccount -ServicePrincipal -TenantId $TenantId -Credential $credential `
    -SubscriptionId $SubscriptionId | Out-Null

$cap = Get-AzFabricCapacity -CapacityName $CapacityName -ResourceGroupName $ResourceGroupName
if ($Action -eq "Suspend" -and $cap.State -ne "Paused") {
    Suspend-AzFabricCapacity -CapacityName $CapacityName -ResourceGroupName $ResourceGroupName
} elseif ($Action -eq "Resume" -and $cap.State -ne "Active") {
    Resume-AzFabricCapacity -CapacityName $CapacityName -ResourceGroupName $ResourceGroupName
}
```

タスクスケジューラに登録:

```powershell
# 一時停止: 毎日 22:00（例）
$scriptPath     = "<スクリプトの絶対パス>\Fabric-Suspend.ps1"
$triggerSuspend = New-ScheduledTaskTrigger -Daily -At "22:00"
$actionSuspend  = New-ScheduledTaskAction `
    -Execute "pwsh.exe" `
    -Argument ('-NoProfile -File "{0}" -Action Suspend' -f $scriptPath)
Register-ScheduledTask `
    -TaskName "Fabric-Suspend" `
    -Trigger $triggerSuspend `
    -Action $actionSuspend

# 再開: 毎日 08:00（例）
$triggerResume = New-ScheduledTaskTrigger -Daily -At "08:00"
$actionResume  = New-ScheduledTaskAction `
    -Execute "pwsh.exe" `
    -Argument ('-NoProfile -File "{0}" -Action Resume' -f $scriptPath)
Register-ScheduledTask `
    -TaskName "Fabric-Resume" `
    -Trigger $triggerResume `
    -Action $actionResume
```

> **認証**: `Connect-AzAccount -ServicePrincipal` でサービスプリンシパル認証を使用。対話的ログインはスケジュール実行では使えない。  
> シークレットをスクリプトに直書きする場合は、ファイルのアクセス権を制限すること。本番環境では Azure Key Vault からの取得を推奨。

---

## 4. 注意事項

| 項目 | 説明 |
|---|---|
| **一時停止中のコンテンツ** | 容量に割り当てられたワークスペースのコンテンツは**アクセス不可**になる |
| **累積オーバーチャージ** | 一時停止時に未精算のオーバーチャージが**即座に Azure 請求に加算**される |
| **スロットリング解除** | 容量がスロットリング中の場合、一時停止するとスロットリングが**即座に解除**される |
| **再開の所要時間** | 通常 1〜2 分。大規模容量では数分かかる場合あり |
| **Spark ジョブ** | 一時停止すると実行中の Spark ジョブが**キャンセル**される |
| **データパイプライン** | スケジュール実行中のパイプラインは失敗する。再開後に再トリガーが必要 |
| **セマンティックモデル** | 再開後の最初のアクセス時にモデルがメモリにロードされるため、初回レスポンスが遅い |

---

## 5. コスト削減の試算例

F8 容量（約 $1.03/時間）を夜間・休日に一時停止した場合:

| パターン | 稼働時間/月 | 月額概算 (USD) | 削減率 |
|---|---|---|---|
| 24時間365日稼働 | 730 時間 | ~$752 | — |
| 平日 8:00–21:00 のみ（13h × 22日） | 286 時間 | ~$295 | **61% 削減** |
| 平日 9:00–18:00 のみ（9h × 22日） | 198 時間 | ~$204 | **73% 削減** |

> 実際のコストは SKU・リージョンにより異なる。最新価格は [Azure 料金計算ツール](https://azure.microsoft.com/pricing/calculator/) で確認。

---

## 6. 参考リンク

- [Pause and resume your capacity - Microsoft Learn](https://learn.microsoft.com/fabric/enterprise/pause-resume)
- [Suspend-AzFabricCapacity](https://learn.microsoft.com/powershell/module/az.fabric/suspend-azfabriccapacity)
- [Resume-AzFabricCapacity](https://learn.microsoft.com/powershell/module/az.fabric/resume-azfabriccapacity)
