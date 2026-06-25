# Dataverse サンプルデータ作成手順

Dataverse の検証用に、顧客テーブル（`new_customer`）へ投入するサンプルデータを作成する手順です。  
この手順では、Excel/CSV でデータを生成して Dataverse にインポートします。

---

## 1. 前提

- Power Platform 環境に Dataverse が有効化されていること
- インポート実行ユーザーにテーブル作成/データ投入の権限があること
- 文字コードは UTF-8 を使用すること

---

## 2. テーブル例（`new_customer`）

サンプルでは次の列を使います。

| 論理名 | 表示名 | 型 | 必須 |
|---|---|---|---|
| `new_customerid` | 顧客ID | テキスト | ○ |
| `new_name` | 顧客名 | テキスト | ○ |
| `new_email` | メールアドレス | テキスト | - |
| `new_prefecture` | 都道府県 | 選択肢（またはテキスト） | - |
| `new_signupdate` | 登録日 | 日付のみ | - |
| `new_status` | ステータス | 選択肢 | - |
| `new_amount` | 累計購入額 | 通貨（または小数） | - |

---

## 3. そのまま使える CSV サンプル（10 件）

以下を `dataverse-customers-sample.csv` として保存します。

```csv
new_customerid,new_name,new_email,new_prefecture,new_signupdate,new_status,new_amount
CUST-0001,山田 太郎,taro.yamada@example.com,東京都,2026-01-12,Active,120000
CUST-0002,佐藤 花子,hanako.sato@example.com,神奈川県,2026-01-15,Active,98000
CUST-0003,鈴木 一郎,ichiro.suzuki@example.com,大阪府,2026-02-01,Inactive,25000
CUST-0004,高橋 美咲,misaki.takahashi@example.com,愛知県,2026-02-10,Active,176000
CUST-0005,伊藤 健,ken.ito@example.com,福岡県,2026-02-18,Prospect,0
CUST-0006,渡辺 彩,aya.watanabe@example.com,北海道,2026-03-03,Active,43000
CUST-0007,中村 陽介,yosuke.nakamura@example.com,京都府,2026-03-19,Inactive,15500
CUST-0008,小林 直子,naoko.kobayashi@example.com,兵庫県,2026-04-02,Active,222000
CUST-0009,加藤 大輔,daisuke.kato@example.com,千葉県,2026-04-11,Prospect,0
CUST-0010,吉田 真由美,mayumi.yoshida@example.com,埼玉県,2026-05-07,Active,67000
```

---

## 4. 100 件を自動生成する PowerShell 例

```powershell
$prefectures = @('東京都','神奈川県','大阪府','愛知県','福岡県','北海道','京都府','兵庫県','千葉県','埼玉県')
$statuses = @('Active','Inactive','Prospect')

$rows = 1..100 | ForEach-Object {
    $id = "CUST-{0:D4}" -f $_
    $signup = (Get-Date '2026-01-01').AddDays((Get-Random -Minimum 0 -Maximum 180)).ToString('yyyy-MM-dd')
    $status = $statuses[(Get-Random -Minimum 0 -Maximum $statuses.Count)]
    $amount = if ($status -eq 'Prospect') { 0 } else { Get-Random -Minimum 1000 -Maximum 300000 }

    [pscustomobject]@{
        new_customerid = $id
        new_name       = "テスト顧客$id"
        new_email      = ("customer{0}@example.com" -f $_)
        new_prefecture = $prefectures[(Get-Random -Minimum 0 -Maximum $prefectures.Count)]
        new_signupdate = $signup
        new_status     = $status
        new_amount     = $amount
    }
}

$rows | Export-Csv -Path ".\dataverse-customers-sample-100.csv" -NoTypeInformation -Encoding UTF8
Write-Host "CSV を出力しました: .\dataverse-customers-sample-100.csv"
```

---

## 5. Dataverse へインポート

1. Power Apps Maker Portal を開く  
2. 対象環境で **テーブル** → `new_customer` を開く  
3. **データ** タブで **データを取得**（Excel または CSV）を選択  
4. 列マッピングで `new_customerid` を主キーに対応付ける  
5. インポートを実行し、エラー行がないか確認する  

---

## 6. 注意点

- 本番データを含めず、サンプル専用の値のみを使用する
- メールや電話番号は必ずダミー値（`example.com` など）を使う
- 再投入時は重複キー（`new_customerid`）の挙動（上書き/失敗）を事前確認する
