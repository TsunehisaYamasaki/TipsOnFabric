<#
.SYNOPSIS
    Fabric 容量の一時停止（Suspend）または再開（Resume）を実行する。
.PARAMETER Action
    "Suspend" または "Resume" を指定。
#>
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Suspend", "Resume")]
    [string]$Action = "Suspend"
)

$CapacityName     = "<YOUR_CAPACITY_NAME>"
$ResourceGroupName = "<YOUR_RESOURCE_GROUP>"
$SubscriptionId    = "<YOUR_SUBSCRIPTION_ID>"

# サービスプリンシパル認証情報
$TenantId      = "<YOUR_TENANT_ID>"
$ApplicationId = "<YOUR_APPLICATION_ID>"
$Secret        = "<YOUR_CLIENT_SECRET>"

# ログファイル（スクリプトと同じフォルダに出力）
$logFile = Join-Path $PSScriptRoot "Fabric-PauseResume.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function Write-Log {
    param([string]$Message)
    "$timestamp | $Message" | Tee-Object -FilePath $logFile -Append
}

# Azure に接続（サービスプリンシパル）
try {
    $secureSecret = ConvertTo-SecureString $Secret -AsPlainText -Force
    $credential   = New-Object System.Management.Automation.PSCredential($ApplicationId, $secureSecret)
    Connect-AzAccount -ServicePrincipal -TenantId $TenantId -Credential $credential -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Log "Azure に接続済み (サービスプリンシパル, AppId: $ApplicationId)"
}
catch {
    Write-Log "ERROR: サービスプリンシパルでの接続に失敗: $_"
    exit 1
}

# 現在の容量状態を取得
try {
    $cap = Get-AzFabricCapacity `
        -CapacityName $CapacityName `
        -ResourceGroupName $ResourceGroupName `
        -ErrorAction Stop
    Write-Log "容量: $($cap.Name) | 状態: $($cap.State) | SKU: $($cap.SkuName)"
}
catch {
    Write-Log "ERROR: 容量の取得に失敗: $_"
    exit 1
}

# アクション実行
if ($Action -eq "Suspend") {
    if ($cap.State -eq "Paused") {
        Write-Log "容量は既に一時停止中です。スキップします。"
    }
    else {
        Write-Log "容量を一時停止しています..."
        Suspend-AzFabricCapacity `
            -CapacityName $CapacityName `
            -ResourceGroupName $ResourceGroupName `
            -ErrorAction Stop
        Write-Log "容量を一時停止しました。"
    }
}
elseif ($Action -eq "Resume") {
    if ($cap.State -eq "Active") {
        Write-Log "容量は既にアクティブです。スキップします。"
    }
    else {
        Write-Log "容量を再開しています..."
        Resume-AzFabricCapacity `
            -CapacityName $CapacityName `
            -ResourceGroupName $ResourceGroupName `
            -ErrorAction Stop
        Write-Log "容量を再開しました。"
    }
}

# ============================================================
# タスクスケジューラ登録 / 登録解除
# 必要に応じてコメントを外して実行してください。
# ============================================================

<#
# --- 登録 ---
$scriptPath = Join-Path $PSScriptRoot "Fabric-Suspend.ps1"

# 一時停止: 毎日 22:00（例）
$triggerSuspend = New-ScheduledTaskTrigger -Daily -At "22:00"
$actionSuspend  = New-ScheduledTaskAction -Execute "pwsh.exe" `
    -Argument ('-NoProfile -File "{0}" -Action Suspend' -f $scriptPath)
Register-ScheduledTask -TaskName "Fabric-Suspend" -Trigger $triggerSuspend -Action $actionSuspend -Force

# 再開: 毎日 08:00（例）
$triggerResume = New-ScheduledTaskTrigger -Daily -At "08:00"
$actionResume  = New-ScheduledTaskAction -Execute "pwsh.exe" `
    -Argument ('-NoProfile -File "{0}" -Action Resume' -f $scriptPath)
Register-ScheduledTask -TaskName "Fabric-Resume" -Trigger $triggerResume -Action $actionResume -Force
#>

<#
# --- 登録解除 ---
Unregister-ScheduledTask -TaskName "Fabric-Suspend" -Confirm:$false
Unregister-ScheduledTask -TaskName "Fabric-Resume" -Confirm:$false
#>
