-- cpu_dec.vhd（詳細コメント版）
--
-- 【このモジュールの目的（CPUを“動かして見せる”ための周辺回路）】
-- - cpu15（15bit命令/16bitデータの簡易CPUコア）を実体化し、
--   CPUが外部に出力する IO64_OUT（16bit）を「人間が読める形」に変換して表示する。
--
--   具体的には：
--   1) cpu15 から IO64_OUT_TP（16bit）を受け取る
--   2) 16bitの2進値を 10進の各桁（万/千/百/十/一）へ分解する（bin_dec10000,1000,100,10）
--   3) 各桁（0〜9）を 7セグ表示パターンへ変換する（dec_7seg）
--   4) HEX4..HEX0（7seg×5桁）へ出力する
--
-- 【CPU設計観点で重要な点】
-- - これは「CPUコア」と「I/O表示（周辺回路）」を分離する構成の典型である。
--   CPUは “メモリマップドI/O（IO64_OUT）に値を書くだけ” を責務として持ち、
--   その値をどう表示するかは周辺回路に任せる。
-- - 自作CPUでは bring-up 時に “結果が目で見える” ことが非常に重要である。
--   ロジックアナライザ/波形だけでなく、7セグに値が出るとデバッグが一気に楽になる。
--
-- 【信号の流れ（データパス）】
--   IO65_IN (外部入力) ─┐
--                         ├→ cpu15 → IO64_OUT_TP(16bit) → 10進分解 → 7seg変換 → HEX4..HEX0
--   RESET_N/CLK ─────────┘
--
-- 【注意：本コード中の `IO65_IN and "0000001111111111"` について】
-- - ここは “入力を下位10bitだけ有効にするマスク” の意図と推測できる。
-- - ただし、std_logic_vector に対する `and` は本来ビットごとの論理演算であり、
--   ライブラリ/ツールチェーンによっては型解釈が厳しくてエラーになる可能性がある。
--   （このファイルでは std_logic_unsigned を use していないため特に注意）
-- - 合成・シミュレーションの互換性を高めるなら、マスク定数を別signal/constantにして
vv--   ビット幅を明示し、必要なら numeric_std を使って論理演算の意図を明確にすると良い。


library IEEE;
use IEEE.std_logic_1164.all;

-- ============================================================
-- entity：外部I/O（CPUへの入力と、表示用7セグ出力）
-- ============================================================
entity cpu_dec is
    port
    (
        CLK      : in  std_logic;                          -- ベースクロック
        RESET_N  : in  std_logic;                          -- リセット（Low有効）
        IO65_IN  : in  std_logic_vector(15 downto 0);      -- CPUへ渡す外部入力（メモリマップド入力想定）
        IO64_OUT : out std_logic_vector(15 downto 0);      -- CPUからの外部出力（メモリマップド出力想定）

        -- 7セグ表示（HEX4が最上位桁、HEX0が最下位桁）
        HEX4 : out std_logic_vector(6 downto 0);
        HEX3 : out std_logic_vector(6 downto 0);
        HEX2 : out std_logic_vector(6 downto 0);
        HEX1 : out std_logic_vector(6 downto 0);
        HEX0 : out std_logic_vector(6 downto 0)
    );
end cpu_dec;

-- ============================================================
-- architecture：CPUコア＋10進変換＋7セグ変換の“周辺統合”
-- ============================================================
architecture RTL of cpu_dec is

    -- --------------------------------------------------------
    -- cpu15：CPUコア（演算/分岐/ロードストア等を担当）
    -- --------------------------------------------------------
    component cpu15
        port
        (
            CLK      : in  std_logic;
            RESET_N  : in  std_logic;
            IO65_IN  : in  std_logic_vector(15 downto 0);
            IO64_OUT : out std_logic_vector(15 downto 0)
        );
    end component;

    -- --------------------------------------------------------
    -- 2進→10進桁分解ブロック群
    --
    -- ここでは “除算/剰余” を段階的に行うイメージ：
    --  - bin_dec10000 : 入力 / 10000 の商（万の位）と余り
    --  - bin_dec1000  : 余り / 1000  の商（千の位）と余り
    --  - bin_dec100   : 余り / 100   の商（百の位）と余り
    --  - bin_dec10    : 余り / 10    の商（十の位）と余り（=一の位）
    --
    -- CPU設計観点：
    --  - CPU自体に “10進表示” 命令は普通入れない。
    --    表示やデバッグのための変換は周辺回路に逃がすのが典型。
    -- --------------------------------------------------------

    component bin_dec10000
        port
        (
            BIN_IN    : in  std_logic_vector(15 downto 0);   -- 16bit入力
            DEC_OUT4  : out std_logic_vector(3 downto 0);    -- 万の位（0〜9想定）
            REMINDER4 : out std_logic_vector(13 downto 0)    -- 余り（0〜9999相当を入れるため14bit程度）
        );
    end component;

    component bin_dec1000
        port
        (
            BIN_IN3    : in  std_logic_vector(13 downto 0);   -- 前段余り
            DEC_OUT3   : out std_logic_vector(3 downto 0);    -- 千の位
            REMINDER3  : out std_logic_vector(9 downto 0)     -- 余り（0〜999相当）
        );
    end component;

    component bin_dec100
        port
        (
            BIN_IN2    : in  std_logic_vector(9 downto 0);    -- 前段余り
            DEC_OUT2   : out std_logic_vector(3 downto 0);    -- 百の位
            REMINDER2  : out std_logic_vector(6 downto 0)     -- 余り（0〜99相当）
        );
    end component;

    component bin_dec10
        port
        (
            BIN_IN1    : in  std_logic_vector(6 downto 0);    -- 前段余り
            DEC_OUT1   : out std_logic_vector(3 downto 0);    -- 十の位
            REMINDER1  : out std_logic_vector(3 downto 0)     -- 一の位（0〜9）
        );
    end component;

    -- --------------------------------------------------------
    -- 10進1桁（0〜9）→ 7セグ点灯パターン変換
    -- --------------------------------------------------------
    component dec_7seg is
        port
        (
            DIN  : in  std_logic_vector(3 downto 0);          -- 0〜9を想定
            SEG7 : out std_logic_vector(6 downto 0)           -- 7セグ点灯パターン
        );
    end component;

    -- --------------------------------------------------------
    -- 内部信号（CPU出力・10進各桁・余り伝搬）
    -- --------------------------------------------------------

    -- CPUからの生の16bit出力（後段の表示変換に入れる）
    signal IO64_OUT_TP : std_logic_vector(15 downto 0);

    -- 10進各桁（万/千/百/十/一）を4bitに保持（BCD的扱い）
    signal DEC_OUT4 : std_logic_vector(3 downto 0);  -- 万の位
    signal DEC_OUT3 : std_logic_vector(3 downto 0);  -- 千の位
    signal DEC_OUT2 : std_logic_vector(3 downto 0);  -- 百の位
    signal DEC_OUT1 : std_logic_vector(3 downto 0);  -- 十の位
    signal DEC_OUT0 : std_logic_vector(3 downto 0);  -- 一の位（bin_dec10のREMINDER1を接続）

    -- 段階除算の“余り”を伝搬する信号
    signal REMINDER4 : std_logic_vector(13 downto 0); -- 0..9999相当
    signal REMINDER3 : std_logic_vector(9 downto 0);  -- 0..999相当
    signal REMINDER2 : std_logic_vector(6 downto 0);  -- 0..99相当

begin

    -- ========================================================
    -- 1) CPUコア（cpu15）を実体化
    -- ========================================================
    -- CPUは IO65_IN を入力として受け取り、IO64_OUT を出力として返す。
    --
    -- `IO65_IN and "0000001111111111"` は下位10bitだけを有効にするマスクに見える。
    -- CPU側が入力範囲を10bit前提で設計されている、あるいは外部SW入力(10bit)を想定している、
    -- といった設計意図が考えられる。
    C1 : cpu15
        port map(
            CLK      => CLK,
            RESET_N  => RESET_N,

            -- 入力マスク：上位6bitを0に落として下位10bitのみ通す意図
            -- ※ツール互換性が気になる場合は、constant MASK : std_logic_vector(15 downto 0) := "0000001111111111";
            --   のように明示し、IO65_IN and MASK と書くと読みやすい。
            IO65_IN  => IO65_IN and "0000001111111111",

            -- CPU出力は一旦内部信号に受け、表示変換にも回す
            IO64_OUT => IO64_OUT_TP
        );

    -- ========================================================
    -- 2) 16bit値（IO64_OUT_TP）を10進各桁へ分解
    -- ========================================================

    -- 万の位を取り出し、余り（0〜9999）を REMINDER4 に渡す
    C2 : bin_dec10000
        port map(
            BIN_IN    => IO64_OUT_TP,
            DEC_OUT4  => DEC_OUT4,
            REMINDER4 => REMINDER4
        );

    -- 千の位を取り出し、余り（0〜999）を REMINDER3 に渡す
    C3 : bin_dec1000
        port map(
            BIN_IN3    => REMINDER4,
            DEC_OUT3   => DEC_OUT3,
            REMINDER3  => REMINDER3
        );

    -- 百の位を取り出し、余り（0〜99）を REMINDER2 に渡す
    C4 : bin_dec100
        port map(
            BIN_IN2    => REMINDER3,
            DEC_OUT2   => DEC_OUT2,
            REMINDER2  => REMINDER2
        );

    -- 十の位を取り出し、余り（=一の位）を DEC_OUT0 に渡す
    C5 : bin_dec10
        port map(
            BIN_IN1    => REMINDER2,
            DEC_OUT1   => DEC_OUT1,
            REMINDER1  => DEC_OUT0
        );

    -- ========================================================
    -- 3) 10進1桁（0〜9）を 7セグ表示パターンへ変換
    -- ========================================================

    -- 上位桁（万の位）→ HEX4
    C6 : dec_7seg
        port map(
            DIN  => DEC_OUT4,
            SEG7 => HEX4
        );

    -- 千の位 → HEX3
    C7 : dec_7seg
        port map(
            DIN  => DEC_OUT3,
            SEG7 => HEX3
        );

    -- 百の位 → HEX2
    C8 : dec_7seg
        port map(
            DIN  => DEC_OUT2,
            SEG7 => HEX2
        );

    -- 十の位 → HEX1
    C9 : dec_7seg
        port map(
            DIN  => DEC_OUT1,
            SEG7 => HEX1
        );

    -- 一の位 → HEX0
    C10 : dec_7seg
        port map(
            DIN  => DEC_OUT0,
            SEG7 => HEX0
        );

    -- ========================================================
    -- 4) CPU出力を外部端子にもそのまま出す
    -- ========================================================
    -- 表示用だけでなく、外部の他回路/テスト点でもIO64_OUTを使えるようにする。
    IO64_OUT <= IO64_OUT_TP;

end RTL;

-- 【この設計をCPU bring-upに使うときの見方】
-- - cpu15 が ST 命令などで IO64_OUT_TP を更新すると、同時にこの周辺回路が10進分解して7セグへ表示する。
-- - まずは波形で IO64_OUT_TP が期待値（例：55）になっていることを確認し、
--   次に HEX0..HEX4 が正しい数字を表示しているかを確認すると、
--   “CPU側の問題” と “表示変換側の問題” を切り分けやすい。
