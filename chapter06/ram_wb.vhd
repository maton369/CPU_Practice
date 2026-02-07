-- ram_wb.vhd（詳細コメント版：WriteBack段のRAM/I/O書き込み・メモリマップド出力）
--
-- 【このモジュールの目的（CPU設計観点）】
-- - CPUの WriteBack（WB）段として、store命令（ST）が要求する「メモリ書き込み」を確定させる。
-- - Execute段（exec）が生成した
--     - 書き込みデータ：RAM_IN（storeする値）
--     - 書き込み許可：RAM_WEN（Write Enable）
--   と、アドレス経路から渡される書き込み先番地 RAM_ADDR を入力に取り、
--   CLK_WB 立ち上がりで該当メモリ（RAM_0〜RAM_7）またはI/O出力（IO64_OUT）へ書き込む。
--
-- 【段階実行（FT→DC→EX→WB）での位置づけ】
-- - exec は “ST命令なら RAM_IN を作って RAM_WEN=1 を出す” ところまでで、
--   実際にメモリの状態を更新するのはこの ram_wb である。
-- - したがって ram_wb は reg_wb と同様に「CPUの状態（RAMの内容）」を保持する実体であり、
--   ここで初めて store の副作用（メモリ更新）が確定する。
--
-- 【メモリマップドI/O（出力側）の実装】
-- - アドレス "01000000"（16進で 0x40 = 10進で 64）への書き込みは、
--   RAMではなく IO64_OUT へ書き込む。
-- - これにより CPUは「メモリへ store するのと同じ命令形式」で外部出力を駆動できる。
--   自作CPUでよく使う “メモリマップドI/O” の最小実装である。
--
-- 【書き込みアルゴリズム（1サイクルの挙動）】
-- - CLK_WB 立ち上がりで以下を評価する。
--
--   1) RAM_WEN='1' のときだけ書き込みが発生する
--      - '0' のときは何もせず保持（メモリ状態は変化しない）
--
--   2) RAM_ADDR を case でデコードし、対象を1つ選んで RAM_IN を代入する
--      - 0〜7：小規模RAM（RAM_0〜RAM_7）
--      - 0x40(64)：IO64_OUT（外部出力ポート）
--      - それ以外：others => null（何もしない）
--
-- 【CPU設計として重要な点】
-- - “RAM_WEN が 1 のときのみ副作用が出る” という規則が store命令の意味そのものになる。
-- - Decode段の ram_dc は読み出し（アドレス→RAM_OUT）を担当し、
--   WriteBack段の ram_wb は書き込み（アドレス+データ+WEN→RAM更新）を担当する。
--   これにより load/store のデータパスが段分割で成立している。
--
-- 【注意点（bring-upで詰まりやすい）】
-- - others => null のため、未定義アドレスへのstoreは“何も起きない”。
--   その結果、storeが効いていないように見える場合がある。
-- - RAM_ADDR が段跨ぎで正しく伝搬していないと、
--   “データは正しいのに書き込み先がズレる” という典型バグになる。
--   ST命令の検証では、RAM_WEN / RAM_IN / RAM_ADDR を同時に波形で追うのが重要である。
-- - IO64_OUT は「最後に書かれた値を保持するレジスタ」として振る舞う。
--   7セグ表示やLED等の出力デバイスを駆動する用途に相当する。


library IEEE;
use IEEE.std_logic_1164.all;

-- ============================================================
-- entity: WriteBack段のRAM/I/O書き込みポート
-- ============================================================
entity ram_wb is
    port
    (
        -- WriteBack段クロック：書き込み（状態更新）を確定するタイミング
        CLK_WB   : in  std_logic;

        -- 書き込み先アドレス（8bit）
        -- 0〜7はRAM、0x40(64)はI/O出力へマップしている
        RAM_ADDR : in  std_logic_vector(7 downto 0);

        -- 書き込みデータ（storeする値）
        RAM_IN   : in  std_logic_vector(15 downto 0);

        -- 書き込み有効（Write Enable）
        -- 1のときのみ、RAM/IOの状態を更新する
        RAM_WEN  : in  std_logic;

        -- 小規模RAM（8ワード）の各ワード内容（外部へ公開）
        -- ここがRAMの“状態”の実体になっている
        RAM_0    : out std_logic_vector(15 downto 0);
        RAM_1    : out std_logic_vector(15 downto 0);
        RAM_2    : out std_logic_vector(15 downto 0);
        RAM_3    : out std_logic_vector(15 downto 0);
        RAM_4    : out std_logic_vector(15 downto 0);
        RAM_5    : out std_logic_vector(15 downto 0);
        RAM_6    : out std_logic_vector(15 downto 0);
        RAM_7    : out std_logic_vector(15 downto 0);

        -- メモリマップドI/O出力ポート（番地 0x40 = 64）
        -- CPUが ST でこの番地へ書くと外部出力が更新される
        IO64_OUT : out std_logic_vector(15 downto 0)
    );
end ram_wb;

-- ============================================================
-- architecture RTL: 同期書き込み（CLK_WB立ち上がりで確定）
-- ============================================================
architecture RTL of ram_wb is
begin

    process(CLK_WB)
    begin
        -- WBクロック立ち上がりで書き込みを行う
        if (CLK_WB'event and CLK_WB = '1') then

            -- ------------------------------------------------
            -- RAM_WEN=1 のときだけ、副作用（書き込み）を起こす
            -- ------------------------------------------------
            if (RAM_WEN = '1') then

                -- 書き込み先アドレスをデコードして対象へRAM_INを書き込む
                case RAM_ADDR is
                    -- addr 0〜7：小規模RAM
                    when "00000000" => RAM_0    <= RAM_IN;
                    when "00000001" => RAM_1    <= RAM_IN;
                    when "00000010" => RAM_2    <= RAM_IN;
                    when "00000011" => RAM_3    <= RAM_IN;
                    when "00000100" => RAM_4    <= RAM_IN;
                    when "00000101" => RAM_5    <= RAM_IN;
                    when "00000110" => RAM_6    <= RAM_IN;
                    when "00000111" => RAM_7    <= RAM_IN;

                    -- addr 64 (0x40)：メモリマップドI/O出力
                    -- RAMではなく、外部出力レジスタとして更新する
                    when "01000000" => IO64_OUT <= RAM_IN;

                    -- 未定義番地：何もしない（状態更新なし）
                    when others     => null;
                end case;
            end if;

            -- RAM_WEN=0 のときは何もしない＝RAM/IOは前回値を保持
        end if;
    end process;

end RTL;

-- 【検証の観点（store命令のbring-up）】
-- - ST命令時に RAM_WEN が1になっているか
-- - RAM_ADDR が意図した番地（例：64ならIO64_OUT）になっているか
-- - RAM_IN が意図したデータになっているか
-- - それらが CLK_WB 境界で同時に揃っているか（段跨ぎ整合）
