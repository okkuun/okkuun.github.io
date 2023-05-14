---
author: Takafumi Okukubo
pubDatetime: 2023-05-14
title: Synapse Dedicated SQL Poolは「分散」と「Index」の組み合わせで最適化する
postSlug: dedicated-tips
featured: false
draft: false
tags:
  - Azure
ogImage: ""
description: AzureのDedicated(専用) SQL Poolを使う時、最低限知っておけばなんとかなりそうなことをまとめました。
---

[Dedicated SQL Pool](https://learn.microsoft.com/en-us/azure/synapse-analytics/sql-data-warehouse/sql-data-warehouse-overview-what-is)は Microsoft Azure のサービスの 1 つで、主にデータウェアハウスに使用されます。
要は Snowflake や Redshift の Azure 版です。

<!-- 今まで約一年半ほど使用してきて、ようやく慣れてきた感が出てきましたが、今後は別のデータウェアハウスのサービスを使用することになりました。せっかくなので、これまでの学びや公式情報にはないけれど経験上こうしたら早くなった気がするということまでまとめていきます。 -->

本記事では Dedicated SQL Pool を初めて触る方向けに、最低限の tips をまとめます。
理解がより進んでいる方は、[Microsoft のベストプラクティス](https://github.com/MicrosoftDocs/azure-docs/blob/main/articles/synapse-analytics/sql/best-practices-dedicated-sql-pool.md)を読むと良いです。

※この記事を書いた日から時間が経ち、古い情報になっている可能性があります。あらかじめご了承ください。

## Table of contents

## テーブル作成時、「分散」と「Index」の組み合わせで最適化する

データを格納するためのテーブルを作成するとき、Dedicated SQL Pool では以下のように記述します。
例えば全国展開しているコンビニエンスストアの購買データが以下のようになっていると仮定しましょう（小売市場での業務経験がないので頓珍漢な構造になっていればすいません）。
テーブルやカラムの名前は適当です。

```sql
CREATE TABLE [Shema名].[Table名]
(
      [Datetime]   datetime -- 購買事象発生日時
    , [StoreID]    int      -- お店のID
    , [ProductID]  int      -- 買った商品のID
    , [IsCashless] bit      -- 現金なら0, キャッシュレス支払いなら1
)
WITH
(
    DISTRIBUTION = ROUND_ROBIN
    , CLUSTERED COLUMNSTORE INDEX
)
;
```

<!-- ここで重要なのは2つのオプションです。分散とIndex -->

他のデータベース、データウェアハウスに関するサービスと同じように`CREATE TABLE`でテーブルを宣言しますが、一方で`WITH`の後で 2 つのオプションを指定していることが分かります。
このデータ量や用途に合わせて指定していくことが、Dedicated SQL Pool を使用する上で重要になります。

1 つ目の`DISTRIBUTION = ROUND_ROBIN`の部分では、データをどのようなルールに従って分散させるか指定しています。
Dedicated SQL Pool は、インターフェイス上では 1 つのテーブルとして扱われていますが、裏側で 60 個のコンピュートノードにデータを分散させています。
いわゆる Massively Parallel Processing Database と呼ばれるものの一種であり、Big なデータを効率よく処理するため、このような設計となっています。
一方で、ノード間での無駄なデータ移動や、ノードごとのデータ量がなるべく均一になるように、ユーザー側の設定が必要になります。

2 つ目の`CLUSTERED COLUMNSTORE INDEX`と書いてある部分では、テーブルの Index について指定できます。
こちらもデータ量や用途に応じてオプションを変えることも可能です。

繰り返しになりますが、この分散設定と Index 設定を適切に行うことが重要になってきます。

<!-- 分散について説明。HashでJoin早くなるもここで。Hashの偏りはDataFactoryでもここで。 -->

## 分散方法は`HASH`を検討し、無理そうなら他の選択肢を検討する

分散方法には 3 つの選択肢があります。
まとめると、以下のような判断基準で分散方法を指定すれば良いと考えます。

- `ROUND_ROBIN`: 下 2 つのパターンにハマらなかったとき、ステージング（保管）用のテーブルのとき
- `HASH`: JOIN で使用する特定のカラムがあり、60 個のノードへそこそこ均一に分散できそうなとき
- `REPLICATE`: データ量が小さいとき

このように考える根拠を簡単に書いていきます。

### `ROUND_ROBIN`

```sql
CREATE TABLE [Shema名].[Table名]
(
    ...
)
WITH
(
    DISTRIBUTION = ROUND_ROBIN
)
;
```

1 つ目の`ROUND_ROBIN`は単純で、データをランダムに 60 個のコンピュートノードに分散させます。
デフォルトではこちらが指定されるみたいです。
ノードごとにデータ量の偏りが発生することもないため、難しいことを考えずに指定できるという意味では楽チンです。
後述する`HASH`のようなアルゴリズムを通すこともないため、純粋にテーブルを作成したり、この手法で設計されたテーブルに INSERT するのは高速である可能性も高いです。

一方で、この手法を用いて分散させたテーブルを使用した JOIN や集計が非効率になることを考慮した方が良いです。
`ROUND_ROBIN`で作成されたテーブルを JOIN などに使用する場合は、使用するカラムに従ってデータを並び替えるが発生し、処理効率を低下させる原因になるためです。
作成したテーブルを基に、別のテーブルへの挿入などが場合は、次に紹介する`HASH`を使用した方が計算効率を向上させる可能性があります。

### `HASH`

```sql
CREATE TABLE [Shema名].[Table名]
(
    ...
)
WITH
(
    DISTRIBUTION = HASH([StoreID])
)
;
```

（[管理者権限で設定](https://learn.microsoft.com/ja-jp/sql/t-sql/statements/create-materialized-view-as-select-transact-sql?view=azure-sqldw-latest#distribution-option)すれば、複数カラムの指定も可能です。）

```sql
CREATE TABLE [Shema名].[Table名]
(
    ...
)
WITH
(
    DISTRIBUTION = HASH([StoreID], [ProductID])
)
;
```

特定のカラムに従って分散させる選択肢が 2 つ目の`HASH`です。
指定したカラムの同じ値のデータが、同じノードに配置されるように分散します。
このような設計にすることで、指定したカラムが JOIN の結合キーとなるときや、GROUP BY で集計するときに大きな効果を発揮します。
例えば JOIN する際、結合キーの同じ値が属しているノード同士を突き合わせれば、ノード間をまたいでデータを検索する必要がなくなります。

ただ`HASH`も決して万能ではなく、今回のテーブル例だと`HASH([IsCashless])`とするのは得策ではありません。
`IsCashless`の値の種類は`0`と`1`(と`NULL`)しか存在しないためです。
指定したカラムを基に各コンピュートノードへ分散配置するとき、値の種類が 60 個よりも極端に少ないと、ノードが 60 個あるうちの数個しか利用しないことになり、分散させる意味がなくなってしまいます。
他にも日付列や`NULL`の多いカラムは分散に使用するカラムとして指定するべきではないみたいです。

また指定するカラムの分布に偏りがあると、分散自体うまくいかない可能性があります。
1 つのノードにデータが集中することで、多数のノードが計算終了しても 1 つのノードのせいでいつまでも計算完了待ち...なんてことが発生してしまいます。
分散したデータの偏りを確認するには、下記の記事が参考になります。

[お使いのディストリビューションが適切な選択かどうかを判断する方法](https://learn.microsoft.com/ja-jp/azure/synapse-analytics/sql-data-warehouse/sql-data-warehouse-tables-distribute?source=recommendations#how-to-tell-if-your-distribution-is-a-good-choice) (2023/05/12 Access)

### `REPLICATE`

```sql
CREATE TABLE [Shema名].[Table名]
(
    ...
)
WITH
(
    DISTRIBUTION = REPLICATE
)
;
```

最後に 3 つ目の`REPLICATE`ですが、こちらは少し毛色が違うものです。
60 個のノードに分散させるというよりは、その名の通りテーブルを複製します。
全てのノードに同じデータが配置されるため、ノードを跨いだデータ移動が全く発生しない一方、データ容量が大きいとそれぞれのノードに負担をかけることになります。
データ量が小さい、テーブルのレコード数が少ない（2GB より小さい）場合は`REPLICATE`を選択すると良さそうです。

<!-- Indexについて説明。非クラスター化Indexもここで -->

## テーブル作成時に Index の設定が可能

前述の通り、Dedicated SQL Pool ではテーブル作成時に Index を指定できます。
Index には 4 つの選択肢があります。とりあえず以下のような判断基準で良さそうです。

- `CLUSTERED COLUMNSTORE INDEX`: 6,000 万行以上のテーブル向け、何も考えたくない場合でもとりあえずこれ
- `CLUSTERED INDEX ([COLUMN名])`: マスタテーブルのようにカラムに応じて少数のデータを探索したいテーブル向け
- `HEAP`: 小さいテーブル向け
- **非クラスター化 Index**: `CLUSTERED INDEX ([COLUMN名])`や`HEAP`と組み合わせる。

### `CLUSTERED COLUMNSTORE INDEX`

```sql
CREATE TABLE [Shema名].[Table名]
(
    ...
)
WITH
(
    CLUSTERED COLUMNSTORE INDEX
)
;
```

<!-- 論理の飛躍あり -->

データを圧縮することで、大きなデータでも効率よく扱えるようになるようです。
ドキュメントには 6,000 万行を超えると期待された Index の効果を発揮できるとあります。
特に何も指定しなければ（前述のコードから`CLUSTERED COLUMNSTORE INDEX`が取り除かれた場合）、デフォルトとしてこちらの Index が与えられるようです。

この Index を使用しているテーブルでは、使用するカラムのみ抽出するように心掛けましょう。
一部のカラムしか使用しない場合に`SELECT * FROM TABLE`みたいな書き方をすると、せっかくの Index 効果を発揮できません。
列ごとにグループを作成するようなデータ圧縮の方法をとっているらしく、不要なカラムまで`*`で取得しようとすると、その読み込みだけでオーバーヘッドが生じます。

### `CLUSTERED INDEX ([COLUMN名])`

```sql
CREATE TABLE [Shema名].[Table名]
(
    ...
)
WITH
(
    CLUSTERED INDEX ([StoreID])
)
;
```

指定したカラムに対する検索を向上させるため、[B-tree インデックス](https://qiita.com/kiyodori/items/f66a545a47dc59dd8839)のような Index を与えるものです。
ごく少数の行を検索するときに効果的とのことなので、マスタテーブル（例えば、商品 ID と商品名の対応表のようなテーブル）などに適用を考えると良いでしょう。

### `HEAP`

```sql
CREATE TABLE [Shema名].[Table名]
(
    ...
)
WITH
(
    HEAP
)
;
```

`HEAP`は小さいテーブル使用時に、読み込みを高速化される可能性があります。
ここでいう「小さいテーブル」は、正直定義が曖昧です。
6,000 万行以上は`CLUSTERED COLUMNSTORE INDEX`を使うと良いですが、かといって 59,999,999 行だと絶対 NG というわけでもないみたいです。
もし際どいデータ量である場合は実験して決めるのが良いでしょう。

### 非クラスター化 Index

```sql
CREATE TABLE [Shema名].[Table名]
(
    ...
)
WITH
(
    ...
)
;

-- 例えば[StoreID]にIndexを与えるとき
CREATE INDEX sampleIndex ON [Shema名].[Table名]([StoreID])
;
```

指定したカラムに対する検索を向上させるため、[B-tree インデックス](https://qiita.com/kiyodori/items/f66a545a47dc59dd8839)のような Index を与えるものです。
`CLUSTERED INDEX ([COLUMN名])`で指定しなかったカラムや、`HEAP`で作成されたテーブルと組み合わせることが想定されます。

`CLUSTERED INDEX ([COLUMN名])`との違いは、Index とテーブルが分離しているということらしいです。
非クラスター化 Index では、Index で行番号を検索したあと、関連する行を引っ張ってくる時間が発生します。
これがタイムロスとなるため、可能な限り`CLUSTERED INDEX`を使用するのが良さそうです。

<!-- 統計情報を頻繁に更新しておくと良い？ -->

<!-- withで思い処理→一ときテーブル挟んだ方が早いかも？機能は限定的 -->
<!-- ## 大きなテーブルをCTEで読み込む前に、一時テーブルを挟むと高速化?

定量的なエビデンスのない体験談で恐縮ですが、一応ご紹介させていただきます（会社での具体的ケースを明かすわけにもいかず...）。

多くのデータベースサービスと同じく、インラインビューをSELECT文の前に書くCTE（共通一時テーブル; メモリに書き込まれるインラインビュー）を書くことができます。 -->

<!-- ユニークキーなどは役に立たない、とも限らない -->

## 終わりに

まとめると、テーブル作成時の`WITH`の設定に気を遣えば、まずはどうにでもなるでしょうということです。
もちろんもっと高度な Tips はたくさんありますので、[Microsoft のベストプラクティス](https://github.com/MicrosoftDocs/azure-docs/blob/main/articles/synapse-analytics/sql/best-practices-dedicated-sql-pool.md)も読んでください。

---

- [Azure Synapse Analytics で専用 SQL プールを使用して分散テーブルを設計するためのガイダンス](https://learn.microsoft.com/ja-jp/azure/synapse-analytics/sql-data-warehouse/sql-data-warehouse-tables-distribute?source=recommendations) (2023/05/10 Access)
- 斎藤友樹 (2022) 『[エンジニアのための]データ分析基盤入門 データ活用を促進する! プラットフォーム&データ品質の考え方』技術評論社
- [Synapse SQL プールでレプリケート テーブルを使用するための設計ガイダンス](https://learn.microsoft.com/ja-jp/azure/synapse-analytics/sql-data-warehouse/design-guidance-for-replicated-tables) (2023/05/10 Access)
- [Azure Synapse Analytics : Choose Right Index and Partition (Dedicated SQL Pools)](https://tsmatz.wordpress.com/2020/10/16/azure-synapse-analytics-sql-dedicated-pool-columnstore-index-partition/)(2023/05/13 Access)
