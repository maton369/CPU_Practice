-- cpu15_sim.vhd（詳細コメント版：cpu15のトップ相当をテストベンチで結線して動作確認する）
--
-- 【このファイルの目的（テストベンチとしての役割）】
-- - cpu15.vhd（トップ統合）と同等の“部品の繋ぎ方”を、テストベンチ側で明示的に行い、
--   Fetch/Decode/Execute/WriteBack の段分割CPUが正しく動くかをシミュレーションで検証する。
-- - テストベンチは「外部入力（CLK/RESET/IO入力）を与える」ことで回路を駆動し、
--   内部信号（PC、命令、レジスタ、RAM、IO出力）が想定通り遷移するかを波形で観察する。
--
-- 【このCPUのマイクロアーキテクチャ（段分割の流れ）】
--  この設計は 4相の段階実行（擬似パイプライン）で動く。
--
--   1) FT（Fetch） : PC（P_COUNT）を使ってPROMから命令語（PROM_OUT）を読む
--   2) DC（Decode）: 命令語をOP_CODE/OP_DATAへ分解し、必要なレジスタ/メモリを読み出す
--   3) EX（Execute）: 命令実行（ALU/分岐/Load/Store）し、次PCと書き戻し制御を生成する
--   4) WB（WriteBack）: レジスタやRAM/I/Oへ書き込みを確定し、CPU状態を更新する
--
--  重要なのは、FT/DC/EX/WBが同一クロックで同時に動くのではなく、
--  clk_gen が 4相クロック（CLK_FT/CLK_DC/CLK_EX/CLK_WB）を順番に立てることで、
--  1命令の処理が「段ごとに時間的に分離」されて進む点である。
--
-- 【このテストベンチで確認したい典型シナリオ】
-- - fetch.vhd 内の定数MEMに格納されたサンプルプログラム（1+2+…+10=55）を実行し、
--   ST命令でIO64_OUT（番地0x40=64）に55が書き込まれることを確認する。
-- - 観測の軸：
--   - P_COUNT（PC）が分岐で 8 に戻る／最終的に HLT で止まる
--   - PROM_OUT が PCに応じた命令列になっている
--   - REG_0 等が ADD で更新される
--   - RAM_WEN と IO64_OUT が ST 命令タイミングで更新される
--
-- 【注意点（テストベンチの落とし穴）】
-- - このTBでは IO65_IN を初期化していないため、未定義(X)のままになる可能性がある。
--   本サンプルプログラムは IO65_IN を読まない（LDしない）なら問題になりにくいが、
--   波形上のX汚染を避けるなら IO65_IN <= (others => '0'); のように初期化すると良い。
-- - RESET_N は “同期リセット” として exec/reg_wb で扱われているため、
--   いつ解除するか（CLK_EX/CLK_WBのタイミング）を意識するとデバッグが楽になる。


library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

-- ============================================================
-- entity: テストベンチは外部端子を持たない（刺激生成のみ）
-- ============================================================
entity cpu15_sim is
end cpu15_sim;

-- ============================================================
-- architecture SIM: cpu15相当の各ブロックを結線し、CLK/RESETを与える
-- ============================================================
architecture SIM of cpu15_sim is

    -- --------------------------------------------------------
    -- DUTを構成するコンポーネント宣言（cpu15トップと同じ構成要素）
    -- --------------------------------------------------------

    -- 4相クロック生成（FT/DC/EX/WBの順に1周期内で立てる）
    component clk_gen
        port
        (
            CLK     : in  std_logic;  -- ベースクロック（TBが作る）
            CLK_FT  : out std_logic;  -- Fetch相
            CLK_DC  : out std_logic;  -- Decode相
            CLK_EX  : out std_logic;  -- Execute相
            CLK_WB  : out std_logic   -- WriteBack相
        );
    end component;

    -- 命令メモリ（PROM）読み出し：PC→命令語
    component fetch
        port
        (
            CLK_FT   : in  std_logic;
            P_COUNT  : in  std_logic_vector(7 downto 0);
            PROM_OUT : out std_logic_vector(14 downto 0)
        );
    end component;

    -- 命令語を OP_CODE/OP_DATA に分解（= 命令デコード）
    component decode
        port
        (
            CLK_DC   : in  std_logic;
            PROM_OUT : in  std_logic_vector(14 downto 0);
            OP_CODE  : out std_logic_vector(3 downto 0);
            OP_DATA  : out std_logic_vector(7 downto 0)
        );
    end component;

    -- レジスタ読み出し（番号→値）を行うデコード段のMUX
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

    -- メモリ読み出し（番地→値）を行うデコード段のMUX（＋IO65_INマップ）
    component ram_dc
        port
        (
            CLK_DC    : in  std_logic;
            RAM_0     : in  std_logic_vector(15 downto 0);
            RAM_1     : in  std_logic_vector(15 downto 0);
            RAM_2     : in  std_logic_vector(15 downto 0);
            RAM_3     : in  std_logic_vector(15 downto 0);
            RAM_4     : in  std_logic_vector(15 downto 0);
            RAM_5     : in  std_logic_vector(15 downto 0);
            RAM_6     : in  std_logic_vector(15 downto 0);
            RAM_7     : in  std_logic_vector(15 downto 0);
            IO65_IN   : in  std_logic_vector(15 downto 0);   -- メモリマップド入力（0x41）
            RAM_AD_IN : in  std_logic_vector(7 downto 0);    -- 命令下位8bitを番地として扱う設計
            RAM_AD_OUT: out std_logic_vector(7 downto 0);    -- WB段へアドレス伝搬
            RAM_OUT   : out std_logic_vector(15 downto 0)    -- 読み出し値（LDで使う）
        );
    end component;

    -- 命令実行（ALU/分岐/Load/Store制御生成）
    component exec
        port
        (
            CLK_EX  : in  std_logic;
            RESET_N : in  std_logic;
            OP_CODE : in  std_logic_vector(3 downto 0);
            REG_A   : in  std_logic_vector(15 downto 0);
            REG_B   : in  std_logic_vector(15 downto 0);
            OP_DATA : in  std_logic_vector(7 downto 0);
            RAM_OUT : in  std_logic_vector(15 downto 0);

            P_COUNT : out std_logic_vector(7 downto 0);      -- 次PC（Fetchへ）
            REG_IN  : out std_logic_vector(15 downto 0);     -- レジスタ書き戻し値（WBへ）
            RAM_IN  : out std_logic_vector(15 downto 0);     -- メモリ書き込み値（WBへ）
            REG_WEN : out std_logic;                         -- レジスタ書き込み許可
            RAM_WEN : out std_logic                          -- メモリ書き込み許可
        );
    end component;

    -- レジスタファイル書き込み（WB段で状態確定）
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

    -- RAM/I/O書き込み（WB段で副作用確定）
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

            IO64_OUT : out std_logic_vector(15 downto 0)     -- 0x40書き込みで更新される出力
        );
    end component;

    -- --------------------------------------------------------
    -- 内部信号（DUT内配線をTB側で再現）
    -- --------------------------------------------------------
    signal CLK      : std_logic;
    signal RESET_N  : std_logic;

    -- メモリマップドI/O（入力側/出力側）
    signal IO65_IN  : std_logic_vector(15 downto 0);
    signal IO64_OUT : std_logic_vector(15 downto 0);

    -- 4相クロック
    signal CLK_FT : std_logic;
    signal CLK_DC : std_logic;
    signal CLK_EX : std_logic;
    signal CLK_WB : std_logic;

    -- PCと命令語
    signal P_COUNT  : std_logic_vector(7 downto 0);
    signal PROM_OUT : std_logic_vector(14 downto 0);

    -- デコード結果
    signal OP_CODE : std_logic_vector(3 downto 0);
    signal OP_DATA : std_logic_vector(7 downto 0);

    -- レジスタ番号とオペランド
    signal N_REG_A : std_logic_vector(2 downto 0);
    signal N_REG_B : std_logic_vector(2 downto 0);
    signal REG_A   : std_logic_vector(15 downto 0);
    signal REG_B   : std_logic_vector(15 downto 0);

    -- 書き戻し・制御
    signal REG_IN  : std_logic_vector(15 downto 0);
    signal REG_WEN : std_logic;

    -- レジスタファイルの実体（reg_wbが保持し、reg_dcが読む）
    signal REG_0 : std_logic_vector(15 downto 0);
    signal REG_1 : std_logic_vector(15 downto 0);
    signal REG_2 : std_logic_vector(15 downto 0);
    signal REG_3 : std_logic_vector(15 downto 0);
    signal REG_4 : std_logic_vector(15 downto 0);
    signal REG_5 : std_logic_vector(15 downto 0);
    signal REG_6 : std_logic_vector(15 downto 0);
    signal REG_7 : std_logic_vector(15 downto 0);

    -- RAM（小規模）の実体（ram_wbが保持し、ram_dcが読む）
    signal RAM_IN   : std_logic_vector(15 downto 0);
    signal RAM_ADDR : std_logic_vector(7 downto 0);
    signal RAM_OUT  : std_logic_vector(15 downto 0);
    signal RAM_WEN  : std_logic;
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
    -- DUT相当の結線（cpu15トップでやる配線をTB側で再現）
    -- ========================================================

    -- 4相クロック生成：TBのCLKを元にFT/DC/EX/WB相を作る
    C1 : clk_gen port map(
        CLK    => CLK,
        CLK_FT => CLK_FT,
        CLK_DC => CLK_DC,
        CLK_EX => CLK_EX,
        CLK_WB => CLK_WB
    );

    -- Fetch相：PC→PROM→命令語
    C2 : fetch port map(
        CLK_FT   => CLK_FT,
        P_COUNT  => P_COUNT,
        PROM_OUT => PROM_OUT
    );

    -- Decode相：命令語→OP_CODE/OP_DATA
    C3 : decode port map(
        CLK_DC   => CLK_DC,
        PROM_OUT => PROM_OUT,
        OP_CODE  => OP_CODE,
        OP_DATA  => OP_DATA
    );

    -- Decode相：レジスタA読み出し（命令のraフィールド相当）
    C4 : reg_dc port map(
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
        N_REG_OUT => N_REG_A,     -- 宛先番号（WBへ伝えるため保持）
        REG_OUT   => REG_A        -- オペランドA（EXで使用）
    );

    -- Decode相：レジスタB読み出し（命令のrbフィールド相当）
    C5 : reg_dc port map(
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

    -- Decode相：RAM/IO読み出し（アドレス=命令下位8bit）
    -- ここでRAM_ADDR（=RAM_AD_OUT）をWB段へ“アドレス伝搬”しているのが設計のキモ。
    C6 : ram_dc port map(
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
        RAM_AD_OUT => RAM_ADDR,   -- ST時の書き込み先にもなるため保持してWBへ渡す
        RAM_OUT    => RAM_OUT     -- LD時にEXが参照する値
    );

    -- Execute相：命令実行（次PC/書き戻し値/書き込み制御を生成）
    C7 : exec port map(
        CLK_EX  => CLK_EX,
        RESET_N => RESET_N,
        OP_CODE => OP_CODE,
        REG_A   => REG_A,
        REG_B   => REG_B,
        OP_DATA => OP_DATA,
        RAM_OUT => RAM_OUT,
        P_COUNT => P_COUNT,
        REG_IN  => REG_IN,
        RAM_IN  => RAM_IN,
        REG_WEN => REG_WEN,
        RAM_WEN => RAM_WEN
    );

    -- WriteBack相：レジスタファイル更新（命令結果をCPU状態として確定）
    C8 : reg_wb port map(
        CLK_WB  => CLK_WB,
        RESET_N => RESET_N,
        N_REG   => N_REG_A,       -- raフィールドが宛先になる設計
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

    -- WriteBack相：RAM/I/O更新（ST命令の副作用を確定）
    C9 : ram_wb port map(
        CLK_WB   => CLK_WB,
        RAM_ADDR => RAM_ADDR,     -- DC段で確定した番地がWBまで保持されている前提
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

    -- ========================================================
    -- テスト刺激（入力波形生成）
    -- ========================================================

    -- ベースクロック生成：20ns周期（10ns High, 10ns Low）
    -- clk_gen がこれを受けて 4相クロックを順番に立てる。
    process
    begin
        CLK <= '1';
        wait for 10 ns;
        CLK <= '0';
        wait for 10 ns;
    end process;

    -- リセット生成：
    -- - 最初の100nsはRESET_N='0'でCPUを初期化
    -- - 以降はRESET_N='1'で実行開始
    process
    begin
        RESET_N <= '0';
        wait for 100 ns;
        RESET_N <= '1';
        wait;
    end process;

    -- （推奨）I/O入力の初期化：X汚染を避けたい場合に有効
    -- 本サンプルではIO65_INを使わないなら必須ではないが、
    -- 波形の見やすさのために入れておくと良い。
    --
    -- process
    -- begin
    --     IO65_IN <= (others => '0');
    --     wait;
    -- end process;

end SIM;

-- 【波形での観察ポイント（実務的チェックリスト）】
-- - RESET解除後：
--   - P_COUNT が 0 → 1 → 2 → ... と進み、JMP/JEで 8/14 に飛ぶ
--   - PROM_OUT が PC に応じた命令語になっている（fetchのMEM）
--   - REG_0 が加算で増え、最終的に 55 になる（プログラム依存）
--   - ST命令タイミングで RAM_WEN=1 になり、IO64_OUT が 55 に更新される
--   - HLT命令で REG_WEN/RAM_WEN が 0 になり、PCが更新されなくなる（停止状態）
