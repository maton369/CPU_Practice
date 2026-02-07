-- ram_dc_wb.vhd（詳細コメント版）
--
-- 【このモジュールの役割（CPU設計観点）】
-- - これは「RAMの読み出し（Decode側/DC）と書き込み（WriteBack側/WB）を1つにまとめた」周辺回路である。
-- - CPUの典型的なデータメモリアクセスは、
--     - Load命令：メモリ → レジスタ（読み出し）
--     - Store命令：レジスタ → メモリ（書き込み）
--   という2種類に分かれる。
--
-- - この設計では、読み出しは DC クロック（CLK_DC）で行い、
--   書き込みは WB クロック（CLK_WB）で行う。
--   つまり “擬似的な多段パイプライン” のように段ごとのクロックを分けて、
--   読みと書きを衝突しにくくしている。
--
-- 【メモリマップ（ここがCPU作りで超重要）】
-- - アドレス空間のうち、次のようなルールが埋め込まれている：
--
--   0〜63 : 内部RAM（RAM_ARRAY）にアクセス
--   64    : 出力I/O（IO64_OUT）に書き込むと外部へ出力（メモリマップドI/O）
--   65    : 入力I/O（IO65_IN）を読むと外部入力を取得（メモリマップドI/O）
--
-- - これは「メモリとI/Oを同じ“アドレス”で扱う」メモリマップドI/Oの最小例である。
--   自作CPUにおいては、ロード/ストア命令でI/Oできるようになるので便利。
--
-- 【注意：このモジュールは2クロックドメイン】
-- - CLK_DC と CLK_WB の2つのクロックで同じアドレス（ADDR_INT）を参照している。
-- - ここでの前提は「CLK_GEN が段クロックを順番に1周期ずつ立てる」ような構造で、
--   DC段とWB段が同時に立たず、かつアドレスが安定している、ということ。
-- - もしクロックが非同期だったり重なったりすると、CDC（Clock Domain Crossing）問題が発生する。
--   その場合は、アドレスやデータを各段でラッチする（パイプラインレジスタ化する）などが必要になる。

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;

entity ram_dc_wb is
    port (
        -- DC段（Decode/Memory Read段）のクロック
        -- Load命令などで「メモリを読む」タイミングに対応する想定。
        CLK_DC   : in std_logic;

        -- WB段（WriteBack/Memory Write段）のクロック
        -- Store命令などで「メモリへ書く」タイミングに対応する想定。
        CLK_WB   : in std_logic;

        -- メモリアドレス（8bit）
        -- 0〜255 を表現できるが、内部RAMは 0〜63 だけを実装している。
        RAM_ADDR : in std_logic_vector(7 downto 0);

        -- 書き込みデータ（Store時にRAMへ入る値）
        RAM_IN   : in std_logic_vector(15 downto 0);

        -- 入力I/O（アドレス=65で読み出される外部入力）
        IO65_IN  : in std_logic_vector(15 downto 0);

        -- 書き込み許可（Store命令のときだけ 1 になる想定）
        RAM_WEN  : in std_logic;

        -- 読み出しデータ（Load時にCPUへ返す値）
        RAM_OUT  : out std_logic_vector(15 downto 0);

        -- 出力I/O（アドレス=64に書くと外部へ出る値）
        IO64_OUT : out std_logic_vector(15 downto 0)
    );
end ram_dc_wb;

architecture RTL of ram_dc_wb is

    -- 【内部RAMの表現】
    -- - 16bit幅のワードを持つRAMとして扱う。
    -- - 実体は “配列” なので、FPGA合成でブロックRAMに推論されるかはツール/記述に依存する。
    -- - ここでは 64ワード（0..63）と小さいため、最適化でレジスタ配列として実装される場合もある。
    subtype RAM_WORD is std_logic_vector(15 downto 0);
    type RAM_ARRAY_TYPE is array (0 to 63) of RAM_WORD;

    signal RAM_ARRAY : RAM_ARRAY_TYPE;

    -- 【アドレスの整数化】
    -- - VHDLでは配列のインデックスに integer を使うことが多いため、
    --   std_logic_vector のアドレスを integer に変換して使う。
    -- - 0..255 の範囲として宣言しているが、実際にRAM_ARRAYで参照するのは 0..63 だけ。
    --
    -- 注意：
    -- - conv_integer は std_logic_unsigned 由来の変換関数。
    -- - numeric_std を使う流儀では to_integer(unsigned(...)) に置き換えるのが一般的。
    signal ADDR_INT  : integer range 0 to 255;

begin
    -- RAM_ADDR を整数へ変換
    -- ※この代入は組合せ的に見えるので、RAM_ADDRが変わるたびに ADDR_INT も更新される。
    ADDR_INT <= conv_integer(RAM_ADDR);

    -- =========================================================
    -- 読み出し（DC段）
    -- =========================================================
    -- - CLK_DC の立ち上がりで RAM_OUT を更新する。
    -- - “同期読み出し”として扱っている（クロックで出力が切り替わる）。
    --
    -- CPU設計観点：
    -- - Load命令では、この RAM_OUT を exec段などで受け取り、次のWBでレジスタへ書き戻す。
    -- - メモリマップドI/Oの読み（ADDR=65）もここで処理するため、
    --   CPU側からは「普通のロード命令」で入力値を読める。
    process (CLK_DC)
    begin
        if (CLK_DC'event and CLK_DC = '1') then
            if (ADDR_INT < 64) then
                -- 0..63 は内部RAM領域：RAM_ARRAYからデータを読む
                RAM_OUT <= RAM_ARRAY(ADDR_INT);

            elsif (ADDR_INT = 65) then
                -- 65 は入力I/O領域：外部入力(IO65_IN)を読む
                -- 自作CPU的には「IN命令」等を作らずとも Load で入力が読める。
                RAM_OUT <= IO65_IN;

            end if;

            -- 注意：
            -- - 64（出力I/O）は “読む”処理が書かれていないので、
            --   ADDR_INT=64 のとき RAM_OUT は更新されない（前の値保持になり得る）。
            -- - “読み出し無効時はRAM_OUTを0にする”などを決めたい場合は else を追加する。
        end if;
    end process;

    -- =========================================================
    -- 書き込み（WB段）
    -- =========================================================
    -- - CLK_WB の立ち上がりで、RAM_WEN=1 のときのみ書き込みを行う。
    -- - Store命令のコミット（確定）段としてWB段で書く設計思想。
    --
    -- CPU設計観点：
    -- - “書き込みはWBで確定”にすると、命令の副作用が揃いやすい（パイプライン風の整理）。
    -- - ADDR=64 のときは内部RAMではなく IO64_OUT へ出力する（メモリマップド出力）。
    process (CLK_WB)
    begin
        if (CLK_WB'event and CLK_WB = '1') then
            if (RAM_WEN = '1') then

                if (ADDR_INT < 64) then
                    -- 0..63 は内部RAM：RAM_IN をRAMに書く
                    -- Store命令の典型動作。
                    RAM_ARRAY(ADDR_INT) <= RAM_IN;

                elsif (ADDR_INT = 64) then
                    -- 64 は出力I/O：RAM_IN を外部出力(IO64_OUT)に反映
                    -- たとえば7セグ表示、LED、UART送信レジスタなどの“出力レジスタ”に相当。
                    IO64_OUT <= RAM_IN;

                end if;

                -- 注意：
                -- - ADDR=65（入力I/O）への書き込みは定義していない（無視）。
                -- - “入力I/OはRead Only”として自然な設計。
            end if;
        end if;
    end process;

end RTL;

-- ============================================================
-- 追加の設計メモ（レビュー観点での注意点）
-- ============================================================
--
-- (1) アドレスの安定性
-- - ADDR_INT はRAM_ADDRから組合せ変換されており、DC/WBの両プロセスで参照される。
-- - 「DC段のアドレス」と「WB段のアドレス」が別物であるなら、
--   本来は各段でアドレスをラッチ（例：ADDR_DC、ADDR_WB）し、段ごとに固定すべきである。
-- - この設計が成立する前提は、
--   “段クロックが順番に立ち、アドレスがその間ずっと同じ”というマイクロシーケンスである。
--
-- (2) RAM_OUT の未定義（保持）問題
-- - ADDR=64 や ADDR>65 のとき RAM_OUT を更新していないため、
--   シミュレーションで意図しない保持が見える可能性がある。
-- - 動作を明確にしたいなら、
--     else RAM_OUT <= (others => '0');
--   のようにデフォルトを与える方がデバッグしやすい。
--
-- (3) std_logic_unsigned の依存
-- - 今後の拡張で numeric_std に寄せるなら、
--   conv_integer や + 演算の扱いを統一するのが望ましい。
--
-- (4) 合成時のメモリ推論
-- - RAM_ARRAY のような配列RAMは、書き方によってはブロックRAM推論に失敗し、
--   レジスタの塊として実装されることがある。
-- - 実機で容量を増やす/周波数を上げるなら、altsyncram等の明示IP化も検討対象になる。
