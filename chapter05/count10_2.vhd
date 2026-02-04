-- count10_2.vhd（詳細コメント版）
--
-- 【このモジュールの目的（自作CPU観点）】
-- - 0〜9 を繰り返しカウントする（mod-10）4bitカウンタである。
-- - count10.vhd と同じ機能（0→1→…→9→0→…）を持つが、
--   回路構造を
--     1) 次状態を計算する「組合せ回路（next-state logic）」
--     2) 次状態を保持する「順序回路（状態レジスタ：D-FF群）」
--   に明確に分離している点が特徴である。
--
-- 【なぜこの分離が重要か（CPU設計の基本）】
-- - 自作CPUの設計では、ほぼすべての回路が
--     「組合せ回路（データパス/制御ロジック）」＋「状態レジスタ（PC/レジスタ/IR等）」
--   で構成される。
-- - 典型形：
--     next_state = f(current_state, inputs)
--     state      <= next_state   (on rising clock)
-- - 本モジュールは、その “同期設計の基本形” を最小のカウンタで示している。
--
-- 【アルゴリズム（FSMとしての状態遷移）】
-- - 状態：COUNT_TMP（4bit）
-- - 次状態：COUNT_TMP_NEXT（4bit）
-- - 遷移規則（組合せロジック）：
--     if COUNT_TMP == 9:
--         COUNT_TMP_NEXT = 0
--     else:
--         COUNT_TMP_NEXT = COUNT_TMP + 1
-- - 更新規則（順序ロジック）：
--     on rising_edge(CLK):
--         COUNT_TMP <= COUNT_TMP_NEXT
--
-- - 結果として状態は 0→1→…→9→0→… と循環する。
--
-- 【注意：このコードのRST】
-- - entity には RST があるが、現状のアーキテクチャでは RST を一切使っていない。
-- - つまり「リセット機能が未実装」であり、電源投入直後のCOUNT_TMPは未定義になり得る。
--   （シミュレーションでは 'U' が混ざる、実機ではFFの初期値が不定など）
-- - 自作CPUでは初期状態（PC=0等）が非常に重要なので、通常は
--   - 同期リセット
--   - 非同期リセット
--   - 初期値付与（FPGA合成依存）
--   のいずれかで初期化戦略を明確にする必要がある。
--
-- 【std_logic_unsigned の注意】
-- - std_logic_unsigned は古い拡張で、std_logic_vector を unsigned とみなして + を可能にする。
-- - 近年は numeric_std（unsigned型）推奨だが、教材方針としてここでは踏襲する。


library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

-- ============================================================
-- entity: 入出力（ポート）の宣言
-- ============================================================
entity count10_2 is
    port
    (
        -- CLK: クロック入力（立ち上がりで状態更新）
        CLK   : in  std_logic;

        -- RST: リセット入力（※この実装では未使用）
        -- 仕様としては存在するが、内部で参照していないため、機能上はリセットされない。
        RST   : in  std_logic;

        -- COUNT: 現在のカウント値（外部出力）
        COUNT : out std_logic_vector(3 downto 0)
    );
end count10_2;

-- ============================================================
-- architecture: 回路（内部実装）の記述
-- ============================================================
architecture RTL of count10_2 is

    -- --------------------------------------------------------
    -- 状態レジスタ（current state）
    -- --------------------------------------------------------
    -- COUNT_TMP が「現在の状態」を保持するレジスタ（4bit）に相当する。
    -- D-FFを4本束ねた状態ベクトルとして考えられる。
    signal COUNT_TMP      : std_logic_vector(3 downto 0);

    -- --------------------------------------------------------
    -- 次状態（next state）
    -- --------------------------------------------------------
    -- COUNT_TMP_NEXT は「次のクロックで COUNT_TMP に入れたい値」を表す信号。
    -- CPUで言うと、PC_NEXT や REG_WRITE_DATA のような “次状態候補” に相当する。
    signal COUNT_TMP_NEXT : std_logic_vector(3 downto 0);

begin

    -- ========================================================
    -- 1) 組合せ回路（next-state logic）
    -- ========================================================
    -- 目的：現在状態 COUNT_TMP から、次状態 COUNT_TMP_NEXT を決定する。
    --
    -- process(COUNT_TMP) としているので、COUNT_TMP が変化すると即座に再評価される。
    -- クロックは関与しないため、純粋な組合せロジックである。
    --
    -- 注意（設計の一般形）：
    -- - 実際のCPUでは inputs（命令ビット、フラグ、外部入力）も next-state の決定に関わる。
    -- - ここでは最小例として current_state のみで決まる。
    process(COUNT_TMP)
    begin
        -- 9（1001）なら次は0（0000）に戻す → mod-10
        if (COUNT_TMP = "1001") then
            COUNT_TMP_NEXT <= "0000";

        -- それ以外は +1
        else
            -- std_logic_unsigned により、COUNT_TMP を unsigned として +1 できる。
            COUNT_TMP_NEXT <= COUNT_TMP + 1;
        end if;
    end process;

    -- ========================================================
    -- 2) 順序回路（state register, D-FF）
    -- ========================================================
    -- 目的：クロック立ち上がりで COUNT_TMP <= COUNT_TMP_NEXT として状態を更新する。
    --
    -- これは “D-FFだけからなる状態保持ブロック” と見なせる。
    -- 自作CPUでは PC レジスタや汎用レジスタ、IR、フラグなどが全てこの形で実装される。
    process(CLK)
    begin
        if (CLK'event and CLK = '1') then
            -- 次状態を現在状態へラッチする（同期更新）
            COUNT_TMP <= COUNT_TMP_NEXT;
        end if;
    end process;

    -- ========================================================
    -- 3) 外部出力
    -- ========================================================
    -- 内部状態（COUNT_TMP）を外部に見せる。
    -- bring-upでは “状態が期待通り進んでいるか” を観測するのに重要。
    COUNT <= COUNT_TMP;

end RTL;

-- 【発展（CPU設計に近づける改修の方向性）】
-- - RSTを実際に使う（同期リセット/非同期リセットのどちらにするか決める）
-- - enable を追加して「カウント停止」「1周期だけ進める」など制御可能にする
-- - next-state logic を process(COUNT_TMP, RST) にして、RSTで next を0にするなど、
--   状態遷移の設計をよりCPUの制御回路に近づけられる
