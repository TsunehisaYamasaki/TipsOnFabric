# Dataverse サンプルデータ作成手順（冷蔵庫メーカー業務向け）

冷蔵庫の製造工場における業務横断（製造・販売・経理・保守）を想定した Dataverse 検証用データを作成する手順です。  
この手順では、関連テーブルを用意し、CSV で投入します。

---

## 1. 前提

- Power Platform 環境に Dataverse が有効化されていること
- インポート実行ユーザーにテーブル作成/データ投入の権限があること
- 文字コードは UTF-8 を使用すること

---

## 2. テーブル構成（業務横断）

| テーブル論理名 | 用途 | 主キー例 | 関連先 |
|---|---|---|---|
| `new_factory` | 製造工場マスタ | `new_factoryid` | `new_product` |
| `new_product` | 冷蔵庫製品マスタ | `new_productid` | `new_factory`, `new_sales`, `new_maintenance` |
| `new_sales` | 販売実績 | `new_salesid` | `new_product` |
| `new_accounting` | 経理仕訳（売上・原価） | `new_accountingid` | `new_sales`, `new_product` |
| `new_maintenance` | 保守対応履歴 | `new_maintenanceid` | `new_product` |

---

## 3. そのまま使える CSV サンプル

以下をそれぞれ CSV ファイルとして保存してインポートします。

### 3-1. 製造工場（`new_factory.csv`）

```csv
new_factoryid,new_name,new_region,new_capacitypermonth,new_manager
FAC-001,東日本冷機工場,関東,12000,田中 一郎
FAC-002,西日本冷機工場,関西,10000,中村 由美
FAC-003,九州冷機工場,九州,8000,佐々木 健
```

### 3-2. 冷蔵庫製品（`new_product.csv`）

```csv
new_productid,new_modelname,new_category,new_factoryid,new_releaseyear,new_unitcost
PRD-1001,FrostFree 300,家庭用,FAC-001,2025,48000
PRD-1002,FreshPro 450,家庭用,FAC-002,2026,62000
PRD-2001,StoreMax 900,業務用,FAC-003,2025,185000
PRD-2002,CoolLine 1200,業務用,FAC-002,2026,240000
```

### 3-3. 販売実績（`new_sales.csv`）

```csv
new_salesid,new_saledate,new_productid,new_quantity,new_unitprice,new_channel,new_customername
SAL-0001,2026-04-10,PRD-1001,45,78000,量販店,株式会社ライト電機
SAL-0002,2026-04-12,PRD-1002,30,98000,EC,山田 太郎
SAL-0003,2026-04-18,PRD-2001,8,285000,法人直販,株式会社北海ストア
SAL-0004,2026-04-26,PRD-2002,5,345000,代理店,関西冷機販売
```

### 3-4. 経理仕訳（`new_accounting.csv`）

```csv
new_accountingid,new_entrydate,new_salesid,new_productid,new_entrytype,new_amount,new_note
ACC-0001,2026-04-10,SAL-0001,PRD-1001,売上,3510000,4月第2週 家庭用販売
ACC-0002,2026-04-10,SAL-0001,PRD-1001,売上原価,2160000,原価計上
ACC-0003,2026-04-18,SAL-0003,PRD-2001,売上,2280000,業務用一括納品
ACC-0004,2026-04-18,SAL-0003,PRD-2001,売上原価,1480000,原価計上
```

### 3-5. 保守履歴（`new_maintenance.csv`）

```csv
new_maintenanceid,new_servicedate,new_productid,new_issuecategory,new_cost,new_status,new_partner
MNT-0001,2026-05-01,PRD-1002,冷却不良,12000,完了,東日本サービス
MNT-0002,2026-05-06,PRD-2001,コンプレッサー異音,38000,完了,九州メンテナンス
MNT-0003,2026-05-11,PRD-2002,ドアパッキン劣化,9000,対応中,関西テクニカル
```

---

## 4. Dataverse へインポート（推奨順）

参照関係があるため、次の順でインポートします。

1. `new_factory.csv`
2. `new_product.csv`
3. `new_sales.csv`
4. `new_accounting.csv`
5. `new_maintenance.csv`

Power Apps Maker Portal で対象テーブルを開き、**データを取得**（CSV）から投入します。

---

## 5. 注意点

- 本番データを含めず、サンプル専用の値のみを使用する
- 顧客名・メール・会社名はダミー値を使う
- 参照列（例: `new_factoryid`, `new_productid`, `new_salesid`）の整合性を崩さない
- 再投入時は重複キーの挙動（上書き/失敗）を事前確認する
