-- cpu15.vhd（詳細コメント版：CPUトップ階層 / データパス統合）
--
-- 【このファイルの位置づけ（自作CPU観点）】
-- - 本ファイルは “CPU全体を部品としてまとめるトップ階層（top module）” である。
-- - ここでは個々の演算や状態遷移の実装（ALUやレジスタ書き込みの中身）を直接書かず、
--   既に用意された各ステージ部品（fetch/decode/exec/writebackなど）を
--   配線して1つのCPUとして成立させている。
--
-- 【全体アーキテクチャの意図（ステージ分割）】
-- - 本CPUは、命令処理を大きく以下の段（ステージ）に分割している。
--
--   1) Fetch  : PC（P_COUNT）で命令ROM（PROM）から命令を取り出す
--   2) Decode : 取り出した命令を OP_CODE / OP_DATA 等に分解する
--   3) Read   : 命令が指定するレジスタ・RAMを参照し、オペランドを用意する
--   4) Exec   : ALU演算/分岐/ロードストア制御などを行い、次PCや書き込みデータを生成する
--   5) WB     : レジスタ/RAMへ結果を書き戻す
--
-- - これらを別々のクロック（CLK_FT/CLK_DC/CLK_EX/CLK_WB）で進める点が特徴である。
--   一般的なCPUの“単一クロックでのパイプライン”とは異なり、
--   clk_gen がベースクロック CLK を加工して各段用のタイミングを作り出す構造になっている。
--
-- 【重要：トップ階層の責務】
-- - トップ階層の責務は「各部品の接続（インタフェース整合）」と
--   「CPU全体で一貫した信号の流れ（命令→オペランド→結果→書き戻し）」を保つこと。
-- - 自作CPUで最も起こりやすい致命傷は
--   - 命令ビットフィールドの取り違え（PROM_OUTのビット切り出し）
--   - レジスタ番号と書き込み先のズレ
--   - RAMアドレス/データのタイミングずれ
--   - ステージクロックの位相/更新順の破綻
--   であり、このファイルはそれらの “配線設計” を担う。
--
-- 【I/O（メモリマップドI/O風）】
-- - IO65_IN  : 外部からCPUへ入る入力（RAM側でアドレス65相当として扱う想定）
-- - IO64_OUT : CPUから外部へ出す出力（RAM側でアドレス64相当として扱う想定）
-- - つまり RAMアクセス命令を使って I/O ポート（64/65）を叩く構成であり、
--   自作CPUでよくある “メモリマップドI/O” の簡易形になっている。
--
-- 【std_logic_unsigned の注意】
-- - ここでは主に配線なので算術演算は少ないが、プロジェクト全体の方針として入っている。
-- - 近年は numeric_std 推奨だが、教材方針として踏襲している。


library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

-- ============================================================
-- entity: CPUトップの外部インタフェース
-- ============================================================
entity cpu15 is
    port
    (
        -- ベースクロック入力
        -- clk_gen により Fetch/Decode/Exec/WB 用のクロックへ分配される。
        CLK       : in  std_logic;

        -- リセット（アクティブ Low っぽい命名：RESET_N）
        -- exec / reg_wb など主要な状態を持つブロックへ渡される。
        RESET_N   : in  std_logic;

        -- 外部入力（I/Oポート相当）
        -- ram_dc へ入り、特定アドレス参照時のRAM値として供給される想定。
        IO65_IN   : in  std_logic_vector(15 downto 0);

        -- 外部出力（I/Oポート相当）
        -- ram_wb から出力され、特定アドレスへの store 結果を外部へ見せる想定。
        IO64_OUT  : out std_logic_vector(15 downto 0)
    );
end cpu15;

-- ============================================================
-- architecture RTL: トップ階層の統合配線
-- ============================================================
architecture RTL of cpu15 is

    -- ========================================================
    -- コンポーネント宣言群（下位ブロックのインタフェース）
    -- ========================================================
    -- ここでは “中身” は書かず、入出力だけを宣言し、
    -- 後段でインスタンス化して配線する。

    -- --------------------------------------------------------
    -- clk_gen: ステージクロック生成
    -- --------------------------------------------------------
    -- ベースクロック CLK を、各段用のクロックに分割/整形するブロック。
    -- このCPUは段ごとに別クロックを使うため、タイミング設計の要。
    component clk_gen
        port
        (
            CLK     : in  std_logic;
            CLK_FT  : out std_logic;  -- Fetch用
            CLK_DC  : out std_logic;  -- Decode用
            CLK_EX  : out std_logic;  -- Execute用
            CLK_WB  : out std_logic   -- WriteBack用
        );
    end component;

    -- --------------------------------------------------------
    -- fetch: 命令フェッチ（PROM参照）
    -- --------------------------------------------------------
    -- P_COUNT（8bit PC）で命令ROM（PROM）を参照し、15bit命令を出力する。
    component fetch
        port
        (
            CLK_FT   : in  std_logic;
            P_COUNT  : in  std_logic_vector(7 downto 0);
            PROM_OUT : out std_logic_vector(14 downto 0)
        );
    end component;

    -- --------------------------------------------------------
    -- decode: 命令デコード（OP_CODE/OP_DATA抽出）
    -- --------------------------------------------------------
    -- PROM_OUT（15bit命令）を分解してオペコードと即値/データを取り出す。
    component decode
        port
        (
            CLK_DC   : in  std_logic;
            PROM_OUT : in  std_logic_vector(14 downto 0);
            OP_CODE  : out std_logic_vector(3 downto 0);
            OP_DATA  : out std_logic_vector(7 downto 0)
        );
    end component;

    -- --------------------------------------------------------
    -- reg_dc: レジスタ読み出し（デコード段）
    -- --------------------------------------------------------
    -- N_REG_IN で指定されたレジスタ番号の値を REG_OUT に出す。
    -- 同時に N_REG_OUT を出しており、後段（WB等）で “どのレジスタ番号か” を保持する用途がある。
    component reg_dc
        port
        (
            CLK_DC    : in  std_logic;
            N_REG_IN  : in  std_logic_vector(2 downto 0);
            REG_0     : in  std_logic_vector(15 downto 0);
            REG_1     : in  std_logic_vector(15 downto 0);
            REG_2     : in  std_logic_vector(15 downto 0);
            REG_3     : in  std_logic_vector(15 downto 0);
            REG_4     : in  std_logic_vector(15 downto 0);
            REG_5     : in  std_logic_vector(15 downto 0);
            REG_6     : in  std_logic_vector(15 downto 0);
            REG_7     : in  std_logic_vector(15 downto 0);
            N_REG_OUT : out std_logic_vector(2 downto 0);
            REG_OUT   : out std_logic_vector(15 downto 0)
        );
    end component;

    -- --------------------------------------------------------
    -- ram_dc: RAM読み出し（デコード段）
    -- --------------------------------------------------------
    -- 命令中のアドレス等から RAM_AD_IN を受け取り、
    -- RAM_0〜RAM_7（小容量RAMの“バンク/分割”表現）から該当値を出力する。
    -- IO65_IN も入力に含まれており、特定アドレスで外部入力に切り替える設計が想定される。
    component ram_dc
        port
        (
            CLK_DC     : in  std_logic;
            RAM_AD_IN  : in  std_logic_vector(7 downto 0);
            RAM_0      : in  std_logic_vector(15 downto 0);
            RAM_1      : in  std_logic_vector(15 downto 0);
            RAM_2      : in  std_logic_vector(15 downto 0);
            RAM_3      : in  std_logic_vector(15 downto 0);
            RAM_4      : in  std_logic_vector(15 downto 0);
            RAM_5      : in  std_logic_vector(15 downto 0);
            RAM_6      : in  std_logic_vector(15 downto 0);
            RAM_7      : in  std_logic_vector(15 downto 0);
            IO65_IN    : in  std_logic_vector(15 downto 0);
            RAM_AD_OUT : out std_logic_vector(7 downto 0);
            RAM_OUT    : out std_logic_vector(15 downto 0)
        );
    end component;

    -- --------------------------------------------------------
    -- exec: 実行段（ALU/分岐/ロードストア制御）
    -- --------------------------------------------------------
    -- OP_CODE/REG_A/REG_B/OP_DATA/RAM_OUT を入力として
    -- - 次PC（P_COUNT）
    -- - レジスタ書き込みデータ（REG_IN）と書き込み許可（REG_WEN）
    -- - RAM書き込みデータ（RAM_IN）と書き込み許可（RAM_WEN）
    -- を生成する “CPUの頭脳” に相当する段。
    component exec
        port
        (
            CLK_EX   : in  std_logic;
            RESET_N  : in  std_logic;
            OP_CODE  : in  std_logic_vector(3 downto 0);
            REG_A    : in  std_logic_vector(15 downto 0);
            REG_B    : in  std_logic_vector(15 downto 0);
            OP_DATA  : in  std_logic_vector(7 downto 0);
            RAM_OUT  : in  std_logic_vector(15 downto 0);
            P_COUNT  : out std_logic_vector(7 downto 0);
            REG_IN   : out std_logic_vector(15 downto 0);
            RAM_IN   : out std_logic_vector(15 downto 0);
            REG_WEN  : out std_logic;
            RAM_WEN  : out std_logic
        );
    end component;

    -- --------------------------------------------------------
    -- reg_wb: レジスタ書き戻し（WB段）
    -- --------------------------------------------------------
    -- exec で生成された REG_IN を、指定レジスタ番号 N_REG へ書き戻す。
    -- 出力として REG_0〜REG_7 を持ち、トップ内の“レジスタファイル状態”を保持する役割もある。
    component reg_wb
        port
        (
            CLK_WB  : in  std_logic;
            RESET_N : in  std_logic;
            N_REG   : in  std_logic_vector(2 downto 0);
            REG_IN  : in  std_logic_vector(15 downto 0);
            REG_WEN : in  std_logic;
            REG_0   : out std_logic_vector(15 downto 0);
            REG_1   : out std_logic_vector(15 downto 0);
            REG_2   : out std_logic_vector(15 downto 0);
            REG_3   : out std_logic_vector(15 downto 0);
            REG_4   : out std_logic_vector(15 downto 0);
            REG_5   : out std_logic_vector(15 downto 0);
            REG_6   : out std_logic_vector(15 downto 0);
            REG_7   : out std_logic_vector(15 downto 0)
        );
    end component;

    -- --------------------------------------------------------
    -- ram_wb: RAM書き戻し（WB段）+ 外部出力ポート生成
    -- --------------------------------------------------------
    -- exec で生成された RAM_IN を RAM_ADDR に store する。
    -- IO64_OUT を出しているので、特定アドレスへの store を外部出力へ反映する設計が想定される。
    component ram_wb
        port
        (
            CLK_WB   : in  std_logic;
            RAM_ADDR : in  std_logic_vector(7 downto 0);
            RAM_IN   : in  std_logic_vector(15 downto 0);
            RAM_WEN  : in  std_logic;
            RAM_0    : out std_logic_vector(15 downto 0);
            RAM_1    : out std_logic_vector(15 downto 0);
            RAM_2    : out std_logic_vector(15 downto 0);
            RAM_3    : out std_logic_vector(15 downto 0);
            RAM_4    : out std_logic_vector(15 downto 0);
            RAM_5    : out std_logic_vector(15 downto 0);
            RAM_6    : out std_logic_vector(15 downto 0);
            RAM_7    : out std_logic_vector(15 downto 0);
            IO64_OUT : out std_logic_vector(15 downto 0)
        );
    end component;

    -- ========================================================
    -- 内部信号（配線）
    -- ========================================================
    -- ステージクロック
    signal CLK_FT   : std_logic;
    signal CLK_DC   : std_logic;
    signal CLK_EX   : std_logic;
    signal CLK_WB   : std_logic;

    -- プログラムカウンタ（PC）
    signal P_COUNT  : std_logic_vector(7 downto 0);

    -- 命令（PROM出力）
    signal PROM_OUT : std_logic_vector(14 downto 0);

    -- デコード結果
    signal OP_CODE  : std_logic_vector(3 downto 0);
    signal OP_DATA  : std_logic_vector(7 downto 0);

    -- レジスタ番号（命令から抽出した参照先）
    signal N_REG_A  : std_logic_vector(2 downto 0);
    signal N_REG_B  : std_logic_vector(2 downto 0);

    -- exec→WBへ渡すデータ
    signal REG_IN   : std_logic_vector(15 downto 0);
    signal RAM_IN   : std_logic_vector(15 downto 0);

    -- デコード段で読み出したレジスタ値（オペランド）
    signal REG_A    : std_logic_vector(15 downto 0);
    signal REG_B    : std_logic_vector(15 downto 0);

    -- 書き込み許可
    signal REG_WEN  : std_logic;
    signal RAM_WEN  : std_logic;

    -- レジスタファイルの状態（reg_wbが保持し、reg_dcが参照する）
    signal REG_0    : std_logic_vector(15 downto 0);
    signal REG_1    : std_logic_vector(15 downto 0);
    signal REG_2    : std_logic_vector(15 downto 0);
    signal REG_3    : std_logic_vector(15 downto 0);
    signal REG_4    : std_logic_vector(15 downto 0);
    signal REG_5    : std_logic_vector(15 downto 0);
    signal REG_6    : std_logic_vector(15 downto 0);
    signal REG_7    : std_logic_vector(15 downto 0);

    -- RAMアドレスとRAMデータ（ram_dc/ram_wb間の受け渡し）
    signal RAM_ADDR : std_logic_vector(7 downto 0);
    signal RAM_OUT  : std_logic_vector(15 downto 0);

    -- RAMの状態（ram_wbが保持し、ram_dcが参照する）
    signal RAM_0    : std_logic_vector(15 downto 0);
    signal RAM_1    : std_logic_vector(15 downto 0);
    signal RAM_2    : std_logic_vector(15 downto 0);
    signal RAM_3    : std_logic_vector(15 downto 0);
    signal RAM_4    : std_logic_vector(15 downto 0);
    signal RAM_5    : std_logic_vector(15 downto 0);
    signal RAM_6    : std_logic_vector(15 downto 0);
    signal RAM_7    : std_logic_vector(15 downto 0);

begin

    -- ========================================================
    -- (1) ステージクロック生成
    -- ========================================================
    -- ベースCLKから、各段のクロックを生成する。
    -- 段ごとの更新順序・位相はCPUの正しさに直結するため、clk_genが要になる。
    C1 : clk_gen
        port map(
            CLK     => CLK,
            CLK_FT  => CLK_FT,
            CLK_DC  => CLK_DC,
            CLK_EX  => CLK_EX,
            CLK_WB  => CLK_WB
        );

    -- ========================================================
    -- (2) Fetch段：命令をROMから取得
    -- ========================================================
    -- exec が更新する PC（P_COUNT）を使って命令を取り出す。
    C2 : fetch
        port map(
            CLK_FT   => CLK_FT,
            P_COUNT  => P_COUNT,
            PROM_OUT => PROM_OUT
        );

    -- ========================================================
    -- (3) Decode段：命令をOP_CODE/OP_DATAへ分解
    -- ========================================================
    C3 : decode
        port map(
            CLK_DC   => CLK_DC,
            PROM_OUT => PROM_OUT,
            OP_CODE  => OP_CODE,
            OP_DATA  => OP_DATA
        );

    -- ========================================================
    -- (4) レジスタ読み出し（デコード段）
    -- ========================================================
    -- PROM_OUTのビットフィールドからレジスタ番号を取り出し、
    -- 対応するREG値を REG_A / REG_B としてexecへ渡す。
    --
    -- 注意：ここは命令フォーマットの要で、ビット切り出しミスは致命的。
    -- - (10 downto 8) を Aオペランドのレジスタ番号
    -- - (7 downto 5)  を Bオペランドのレジスタ番号
    -- として使っている。
    C4 : reg_dc
        port map(
            CLK_DC    => CLK_DC,
            N_REG_IN  => PROM_OUT(10 downto 8),
            REG_0     => REG_0,
            REG_1     => REG_1,
            REG_2     => REG_2,
            REG_3     => REG_3,
            REG_4     => REG_4,
            REG_5     => REG_5,
            REG_6     => REG_6,
            REG_7     => REG_7,
            N_REG_OUT => N_REG_A,
            REG_OUT   => REG_A
        );

    C5 : reg_dc
        port map(
            CLK_DC    => CLK_DC,
            N_REG_IN  => PROM_OUT(7 downto 5),
            REG_0     => REG_0,
            REG_1     => REG_1,
            REG_2     => REG_2,
            REG_3     => REG_3,
            REG_4     => REG_4,
            REG_5     => REG_5,
            REG_6     => REG_6,
            REG_7     => REG_7,
            N_REG_OUT => N_REG_B,
            REG_OUT   => REG_B
        );

    -- ========================================================
    -- (5) RAM読み出し（デコード段）
    -- ========================================================
    -- PROM_OUT(7 downto 0) をアドレス入力として渡しているため、
    -- 命令下位8bitがRAMアドレス（またはI/Oアドレス）として扱われる設計が想定される。
    -- IO65_IN を入力に持つので、特定アドレスで外部入力へ切替える実装がram_dc内にあるはず。
    C6 : ram_dc
        port map(
            CLK_DC     => CLK_DC,
            RAM_AD_IN  => PROM_OUT(7 downto 0),
            RAM_0      => RAM_0,
            RAM_1      => RAM_1,
            RAM_2      => RAM_2,
            RAM_3      => RAM_3,
            RAM_4      => RAM_4,
            RAM_5      => RAM_5,
            RAM_6      => RAM_6,
            RAM_7      => RAM_7,
            IO65_IN    => IO65_IN,
            RAM_AD_OUT => RAM_ADDR,
            RAM_OUT    => RAM_OUT
        );

    -- ========================================================
    -- (6) Exec段：演算/分岐/書き込み制御の生成
    -- ========================================================
    -- CPUの中心。デコード結果とオペランドとRAM_OUTを使って、
    -- 次PC、レジスタ書き込みデータ、RAM書き込みデータ、各WENを生成する。
    C7 : exec
        port map(
            CLK_EX   => CLK_EX,
            RESET_N  => RESET_N,
            OP_CODE  => OP_CODE,
            REG_A    => REG_A,
            REG_B    => REG_B,
            OP_DATA  => OP_DATA,
            RAM_OUT  => RAM_OUT,
            P_COUNT  => P_COUNT,
            REG_IN   => REG_IN,
            RAM_IN   => RAM_IN,
            REG_WEN  => REG_WEN,
            RAM_WEN  => RAM_WEN
        );

    -- ========================================================
    -- (7) WriteBack段：レジスタへ書き戻し
    -- ========================================================
    -- N_REG（ここではN_REG_A）を宛先として REG_IN を書く想定。
    -- この “宛先レジスタ番号” の扱いは命令仕様の核心なので、
    -- 実際のISAで「書き込み先がAなのかBなのか/別フィールドなのか」を再確認すべきポイント。
    C8 : reg_wb
        port map(
            CLK_WB  => CLK_WB,
            RESET_N => RESET_N,
            N_REG   => N_REG_A,
            REG_IN  => REG_IN,
            REG_WEN => REG_WEN,
            REG_0   => REG_0,
            REG_1   => REG_1,
            REG_2   => REG_2,
            REG_3   => REG_3,
            REG_4   => REG_4,
            REG_5   => REG_5,
            REG_6   => REG_6,
            REG_7   => REG_7
        );

    -- ========================================================
    -- (8) WriteBack段：RAMへ書き戻し + 外部出力
    -- ========================================================
    -- RAM_ADDR は ram_dc で確定したアドレスを使う。
    -- RAM_WEN が1のとき RAM_IN を該当アドレスへ書く。
    -- IO64_OUT は ram_wb 側で “特定アドレスへの書き込み” を外部出力へ反映する想定。
    C9 : ram_wb
        port map(
            CLK_WB   => CLK_WB,
            RAM_ADDR => RAM_ADDR,
            RAM_IN   => RAM_IN,
            RAM_WEN  => RAM_WEN,
            RAM_0    => RAM_0,
            RAM_1    => RAM_1,
            RAM_2    => RAM_2,
            RAM_3    => RAM_3,
            RAM_4    => RAM_4,
            RAM_5    => RAM_5,
            RAM_6    => RAM_6,
            RAM_7    => RAM_7,
            IO64_OUT => IO64_OUT
        );

end RTL;

-- 【自作CPUとしての観測ポイント（トップ統合でバグりやすい所）】
-- - 命令フォーマット：
--   PROM_OUT(10 downto 8) / (7 downto 5) / (7 downto 0) の意味が一貫しているか
-- - 書き戻し宛先：
--   reg_wb の N_REG に N_REG_A を渡しているが、命令仕様上正しい宛先か
-- - RAMアドレスのタイミング：
--   ram_dc が出す RAM_ADDR を WB段で使うため、段跨ぎの保持/整合が崩れていないか
-- - ステージクロック：
--   clk_gen の位相関係が “データが準備されてから次段がサンプルする” になっているか
