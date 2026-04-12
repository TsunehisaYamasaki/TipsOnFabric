# Microsoft Fabric セマンティックモデルを無制限に更新する方法

## 背景

Microsoft Fabric / Power BI Premium / PPU 容量のセマンティックモデルは、**UI（スケジュール更新）で最大 48 回/日** の制限があります。  
しかし、以下の方法を使うと **API ベースの更新には固定の回数制限がなく**、容量のリソース（CPU・メモリ）が許す限り事実上無制限に更新できます。

| 方法 | 回数制限 | 特徴 |
|------|----------|------|
| UI スケジュール更新 | 最大 48 回/日 | GUI から設定 |
| Power BI REST API (Enhanced Refresh) | **無制限**（容量リソース依存） | HTTP ベース、非同期 |
| XMLA エンドポイント + TMSL/PowerShell | **無制限**（容量リソース依存） | SQL Server Management Studio や PowerShell から利用 |
| Fabric Notebook (semantic-link) | **無制限**（REST API 経由） | Python からノートブック実行 |

---

## 前提条件

- **アカウント**: `your-account@yourtenant.onmicrosoft.com`
- **ワークスペース**: `<YourWorkspaceName>`
- **セマンティックモデル**: `<YourSemanticModelName>`
- ワークスペースが **Fabric 容量 または Premium 容量** に割り当てられていること
- XMLA エンドポイントが **読み取り/書き込み** に設定されていること（管理ポータルで確認）
- **Azure CLI** がインストール済みで `az login` 済みであること（トークン取得に使用）

---

## 方法 1: Power BI REST API（Enhanced Refresh）

### 1-1. ワークスペース ID とデータセット ID の取得

PowerShell で以下を実行します。

```powershell
# Azure PowerShell モジュールのインストール（初回のみ）
Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force

# Power BI にサインイン
# ※ Connect-PowerBIServiceAccount を直接実行するとフリーズする場合があるため、
#    Azure CLI でトークンを取得して -Token パラメーターで渡す方法を推奨します。
$token = az account get-access-token --resource https://analysis.windows.net/powerbi/api --query accessToken -o tsv
Connect-PowerBIServiceAccount -Token $token

# ワークスペース ID を取得
$workspace = Get-PowerBIWorkspace -Name "<YourWorkspaceName>"
$workspace.Id

# データセット ID を取得
$dataset = Get-PowerBIDataset -WorkspaceId $workspace.Id | Where-Object { $_.Name -eq "<YourSemanticModelName>" }
$dataset.Id
```

### 1-2. Enhanced Refresh API でモデルを更新

```powershell
# 変数設定（上で取得した ID を入れてください）
$workspaceId = $workspace.Id
$datasetId   = $dataset.Id

# リクエストボディ
$body = @{
    type           = "Full"
    commitMode     = "transactional"
    maxParallelism = 2
    retryCount     = 2
    timeout        = "02:00:00"
} | ConvertTo-Json

# Enhanced Refresh API を呼び出し
$url = "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$datasetId/refreshes"
Invoke-PowerBIRestMethod -Url $url -Method Post -Body $body

Write-Host "更新リクエストを送信しました（非同期で実行されます）"
```

### 1-3. 更新状態の確認

```powershell
# 最新の更新履歴を取得
$refreshUrl = "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$datasetId/refreshes?`$top=5"
$result = Invoke-PowerBIRestMethod -Url $refreshUrl -Method Get
$result | ConvertFrom-Json | Select-Object -ExpandProperty value |
    Format-Table requestId, refreshType, status, startTime, endTime
```

---

## 方法 2: XMLA エンドポイント + PowerShell

XMLA エンドポイントを使うと TMSL（Tabular Model Scripting Language）で直接更新コマンドを送信できます。

### 2-1. 前提: XMLA エンドポイントの有効化

管理ポータル → **容量設定** → **Power BI ワークロード** → **XMLA エンドポイント** を **読み取り/書き込み** に設定します。

### 2-2. Analysis Services モジュールのインストール

```powershell
Install-Module -Name SqlServer -Scope CurrentUser -Force
```

### 2-3. TMSL コマンドで更新を実行

```powershell
# XMLA エンドポイント（ワークスペース接続文字列）
$xmlaEndpoint = "powerbi://api.powerbi.com/v1.0/myorg/<YourWorkspaceName>"

# TMSL refresh コマンド
$tmslCommand = @"
{
  "refresh": {
    "type": "full",
    "objects": [
      {
        "database": "<YourSemanticModelName>"
      }
    ]
  }
}
"@

# 実行（Azure AD 認証が自動的に行われます）
# -ConnectionTimeout: 接続タイムアウト（秒）、デフォルト 60 秒
# -QueryTimeout: クエリ実行タイムアウト（秒）、デフォルト無制限（0）
Invoke-ASCmd -Server $xmlaEndpoint -Query $tmslCommand -ConnectionTimeout 120 -QueryTimeout 180
Write-Host "XMLA エンドポイント経由で更新を実行しました"
```

> **ヒント**: `type` には以下の値を指定できます。  
> - `full` … 全データの完全更新  
> - `dataOnly` … データのみ更新（再計算なし）  
> - `automatic` … サービスが最適な方法を自動判断  
> - `calculate` … 計算列・メジャー等の再計算のみ  

### 2-4. SQL Server Management Studio (SSMS) から実行する場合

1. SSMS を起動し、サーバー名に `powerbi://api.powerbi.com/v1.0/myorg/<YourWorkspaceName>` を入力
2. 認証で自分のアカウントでサインイン
3. 新しいクエリウィンドウで上記の TMSL コマンドを実行

> **注意**: SSMS で Analysis Services がグレーアウトしている場合は、[Analysis Services クライアントライブラリ（MSOLAP）](https://learn.microsoft.com/en-us/analysis-services/client-libraries) を別途インストールし、SSMS を再起動してください。

---

## 方法 3: Fabric Notebook（Python / semantic-link）

Fabric ノートブック内から Python で REST API を呼び出す方法です。

### 3-1. ノートブックでの実行コード

```python
import sempy.fabric as fabric
import json
import time

# Fabric REST Client（ノートブック内では自動認証されます）
client = fabric.FabricRestClient()

# ワークスペース ID とデータセット ID を取得
workspace_id = fabric.resolve_workspace_id("<YourWorkspaceName>")
datasets = client.get(f"/v1.0/myorg/groups/{workspace_id}/datasets").json()["value"]
dataset_id = next(d["id"] for d in datasets if d["name"] == "<YourSemanticModelName>")

print(f"Workspace ID: {workspace_id}")
print(f"Dataset ID:   {dataset_id}")

# Enhanced Refresh の実行
refresh_body = {
    "type": "Full",
    "commitMode": "transactional",
    "maxParallelism": 2,
    "retryCount": 2
}

response = client.post(
    f"/v1.0/myorg/groups/{workspace_id}/datasets/{dataset_id}/refreshes",
    json=refresh_body
)
print(f"ステータスコード: {response.status_code}")  # 202 なら成功

# 更新状態を確認
time.sleep(10)
history = client.get(
    f"/v1.0/myorg/groups/{workspace_id}/datasets/{dataset_id}/refreshes?$top=3"
).json()["value"]

for r in history:
    print(f"  {r.get('requestId', 'N/A')} | {r.get('status', 'N/A')} | {r.get('refreshType', 'N/A')} | {r.get('startTime', 'N/A')}")
```

### 3-2. ループで定期更新する例

```python
import time

# 1時間ごとに更新を繰り返す例（回数制限なし）
for i in range(100):
    response = client.post(
        f"/v1.0/myorg/groups/{workspace_id}/datasets/{dataset_id}/refreshes",
        json={"type": "Full"}
    )
    print(f"[{i+1}回目] ステータス: {response.status_code}")

    # 更新完了を待つ
    while True:
        time.sleep(30)
        status = client.get(
            f"/v1.0/myorg/groups/{workspace_id}/datasets/{dataset_id}/refreshes?$top=1"
        ).json()["value"][0]
        if status["status"] != "Unknown":
            print(f"  結果: {status['status']}")
            break

    # 次の更新まで待機（必要に応じて調整）
    time.sleep(3600)
```

---

## まとめ

| 項目 | UI スケジュール | REST API | XMLA エンドポイント |
|------|----------------|----------|---------------------|
| 更新回数上限 | 48 回/日 | 無制限* | 無制限* |
| 認証 | ブラウザ | OAuth 2.0 トークン | Azure AD |
| 自動化 | 固定スケジュールのみ | Power Automate・スクリプト等と連携可 | スクリプト・SSMS |
| パーティション単位更新 | 不可 | 可能 | 可能 |
| 進捗確認 | UI のみ | GET API で可能 | SSMS で確認 |

\* 容量リソース（CPU/メモリ）の範囲内。同時に実行できる更新は 1 つのみ（2 つ目はキューまたは拒否）。

### 注意事項

1. **同時更新制限**: 1 つのセマンティックモデルに対して同時に実行可能な更新は **1 件のみ** です。既に実行中の場合は `400 Bad Request` が返ります。
2. **タイムアウト**: デフォルトは 5 時間。`timeout` パラメーターで調整可能。リトライ含めて最大 24 時間。
3. **容量への負荷**: 頻繁な更新は容量の CPU/メモリを消費します。必要な頻度を見極めて設定してください。
4. **XMLA エンドポイント**: F64 以上の SKU で利用可能です。F2〜F32 では利用できません。
5. **SSMS の Analysis Services 接続**: SSMS 22.x で Analysis Services がグレーアウトしている場合は、MSOLAP プロバイダーを別途インストールしてください。

---

## 参考リンク

- [Enhanced refresh with the Power BI REST API](https://learn.microsoft.com/en-us/power-bi/connect-data/asynchronous-refresh)
- [Data refresh in Power BI](https://learn.microsoft.com/en-us/power-bi/connect-data/refresh-data)
- [XMLA endpoint connectivity](https://learn.microsoft.com/en-us/power-bi/enterprise/service-premium-connect-tools)
- [What is Power BI Premium?](https://learn.microsoft.com/en-us/fabric/enterprise/powerbi/service-premium-what-is)
- [Analysis Services client libraries](https://learn.microsoft.com/en-us/analysis-services/client-libraries)
