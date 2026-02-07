-- reg_wb.vhd（詳細コメント版：WriteBack段のレジスタファイル書き込み）
--
-- 【このモジュールの目的（CPU設計観点）】
-- - CPUの WriteBack（WB）段として、Execute段が生成した書き戻しデータ `REG_IN` を、
--   指定された宛先レジスタ番号 `N_REG` に書き込む（= レジスタファイル更新）役割を担う。
-- - `REG_WEN`（Write Enable）が '1' のときのみ書き込みを行い、
--   '0' のときはレジスタ内容を保持する。
-- - RESET_N='0' のときは、全レジスタ（REG_0〜REG_7）をゼロクリアする。
--
-- 【段階実行（FT→DC→EX→WB）での位置づけ】
-- - exec.vhd は命令を解釈して「書き戻し値（REG_IN）」「書き戻し有効（REG_WEN）」を作るが、
--   実際にレジスタの状態を更新するのはこの reg_wb である。
-- - つまり reg_wb は “CPUの状態（レジスタファイル）” を保持する実体であり、
--   ここがCPUの逐次状態（state）そのものになる。
--
-- 【このCPUにおけるレジスタファイルの表現】
-- - レジスタは 8本（REG_0〜REG_7）、各16bit。
-- - 本設計は「8本をそれぞれ独立した信号として持つ」構成で、
--   大規模化には不向きだが教育用には波形で追いやすい。
-- - Decode段（reg_dc）はこれらREG_0〜REG_7を入力として受け取り、読み出し用MUXを作る。
--   WriteBack段（reg_wb）はそれらを更新することで、次命令以降の読み出しに反映させる。
-- - これにより「読み出し（reg_dc）と書き込み（reg_wb）」が分離され、
--   段分割CPUらしい構成になっている。
--
-- 【書き込みアルゴリズム（1サイクルの挙動）】
-- - CLK_WB 立ち上がりで以下を評価する。
--
--   1) RESET_N='0' なら：
--      - 全レジスタを 0 に初期化する
--      - これによりCPU状態が既知値から開始できる（bring-upで重要）
--
--   2) RESETでなければ、REG_WEN='1' のとき：
--      - 宛先番号 N_REG に応じて REG_0〜REG_7 のどれか1本へ REG_IN を書き込む
--
--   3) REG_WEN='0' のとき：
--      - 何も書かず保持（前サイクルの値を保持）
--
-- 【CPU設計として重要な点】
-- - “REG_WEN が 1 のときのみ state が更新される” という規則が、
--   命令の副作用を定義している（MOV/ADD/LDなどは更新、CMP/JMPなどは更新なし）。
-- - 同期書き込み（CLK_WB）であるため、同一命令内で
--   「読み出し→演算→書き込み」が段跨ぎで順序づけされる。
--   これはパイプラインの概念を最小構成で実現している、と捉えられる。
--
-- 【注意点】
-- - N_REG は 3bit なので基本的に "000"〜"111" のはずだが、
--   シミュレーションで X/U を含むと others に落ち、書き込みが起きない。
--   bring-upで“書けていない”原因になるので波形確認が重要である。
-- - RESET_N は同期リセットとして扱われている（CLK_WB立ち上がりでのみ反映）。
--   外部でRESETのタイミングを設計する際は、その前提を揃える必要がある。


library IEEE;
use IEEE.std_logic_1164.all;

-- ============================================================
-- entity: WriteBack段のレジスタファイル（8x16bit）書き込み
-- ============================================================
entity reg_wb is
    port
    (
        -- WriteBack段クロック：レジスタ更新が確定するタイミング
        CLK_WB  : in  std_logic;

        -- アクティブLowリセット（WBクロックで同期的に反映）
        RESET_N : in  std_logic;

        -- 書き込み宛先レジスタ番号（3bit：0〜7）
        N_REG   : in  std_logic_vector(2 downto 0);

        -- 書き込みデータ（execが生成した演算結果/ロード結果など）
        REG_IN  : in  std_logic_vector(15 downto 0);

        -- 書き込み有効（Write Enable）
        -- 1のときのみレジスタファイルを更新する
        REG_WEN : in  std_logic;

        -- レジスタファイルの各レジスタ値（外部へ公開）
        REG_0   : out std_logic_vector(15 downto 0);
        REG_1   : out std_logic_vector(15 downto 0);
        REG_2   : out std_logic_vector(15 downto 0);
        REG_3   : out std_logic_vector(15 downto 0);
        REG_4   : out std_logic_vector(15 downto 0);
        REG_5   : out std_logic_vector(15 downto 0);
        REG_6   : out std_logic_vector(15 downto 0);
        REG_7   : out std_logic_vector(15 downto 0)
    );
end reg_wb;

-- ============================================================
-- architecture RTL: 同期書き込みのレジスタファイル
-- ============================================================
architecture RTL of reg_wb is
begin

    process(CLK_WB)
    begin
        -- WBクロック立ち上がりでレジスタ更新を行う
        if (CLK_WB'event and CLK_WB = '1') then

            -- ------------------------------------------------
            -- リセット：全レジスタを0クリア
            -- ------------------------------------------------
            if (RESET_N = '0') then
                REG_0 <= "0000000000000000";
                REG_1 <= "0000000000000000";
                REG_2 <= "0000000000000000";
                REG_3 <= "0000000000000000";
                REG_4 <= "0000000000000000";
                REG_5 <= "0000000000000000";
                REG_6 <= "0000000000000000";
                REG_7 <= "0000000000000000";

            -- ------------------------------------------------
            -- 書き込み：REG_WEN=1 のときだけ宛先へ書く
            -- ------------------------------------------------
            elsif (REG_WEN = '1') then
                case N_REG is
                    when "000" => REG_0 <= REG_IN; -- R0
                    when "001" => REG_1 <= REG_IN; -- R1
                    when "010" => REG_2 <= REG_IN; -- R2
                    when "011" => REG_3 <= REG_IN; -- R3
                    when "100" => REG_4 <= REG_IN; -- R4
                    when "101" => REG_5 <= REG_IN; -- R5
                    when "110" => REG_6 <= REG_IN; -- R6
                    when "111" => REG_7 <= REG_IN; -- R7
                    when others => null;           -- 未定義時は書かない
                end case;
            end if;

            -- REG_WEN=0 のときは何もしない＝全レジスタ保持（前回値を維持）
        end if;
    end process;

end RTL;

-- 【検証の観点（CPU bring-up）】
-- - REG_WEN=1 のときだけレジスタが更新されること（CMP/JMP等で更新されないこと）
-- - N_REG が想定通りの番号になっていること（デコード〜exec〜WBの伝搬整合）
-- - RESET_N のタイミングで全レジスタが確実に0になっていること
