-- ram_dc.vhd（詳細コメント版：Decode段のRAM/I/O読み出しポート / アドレスデコード）
--
-- 【このモジュールの目的（CPU設計観点）】
-- - CPUの Decode 段において、命令が指定するメモリアドレス `RAM_AD_IN` を受け取り、
--   そのアドレスに対応するメモリ（RAM_0〜RAM_7）またはI/O（IO65_IN）を選択して
--   `RAM_OUT` として次段（Execute）へ渡す。
-- - 同時に、参照したアドレスそのものを `RAM_AD_OUT` として段を跨いで保持する。
--   これは WriteBack段の store（書き込み）で “どこへ書くか” を確定させるために必要になる。
--
-- 【このCPUにおける位置づけ】
-- - cpu15.vhd のトップ配線では、命令語の下位8bit（例：PROM_OUT(7 downto 0)）が
--   `RAM_AD_IN` として ram_dc に渡される。
-- - したがって ram_dc は
--   「メモリ番地（8bit）→読み出しデータ（16bit）」
--   を生成する “メモリ読み出しポート（read port）” の役割を担う。
--
-- 【重要：この設計はメモリマップドI/Oを含む】
-- - アドレス "01000001"（16進で 0x41 = 10進で 65）にアクセスした場合、
--   RAMではなく `IO65_IN` を返すようになっている。
-- - つまり、CPUから見るとI/Oもメモリの一部として見える（メモリマップドI/O）。
--   自作CPUでは実装が単純で拡張もしやすい典型設計である。
--
-- 【読み出しアルゴリズム（同期MUXとして動く）】
-- 1) CLK_DC の立ち上がりで RAM_AD_IN を評価する
-- 2) case 文で対応する入力（RAM_0〜RAM_7 または IO65_IN）を選ぶ
-- 3) 選んだ値を RAM_OUT にラッチして次段へ渡す
--
-- - reg_dc と同様、これは “同期MUX + 出力レジスタ” に近い実装である。
-- - 小規模教材としては分かりやすいが、RAMサイズを増やすと case が巨大になりやすい。
--
-- 【RAM_AD_OUT を常時出す意味（CPU設計で重要）】
-- - `RAM_AD_OUT <= RAM_AD_IN;` は組合せで常にアドレスを次段へ流している。
-- - 典型的には、Decode段で読み出したアドレスを Execute段・WriteBack段でも参照し、
--   store命令の書き込み先やI/O出力先を確定させるために使う。
-- - 段階実行では「どのアドレスを対象にしている命令か」を段跨ぎで保持することが必須なので、
--   ここはCPUの制御情報の伝搬路になっている。
--
-- 【注意：others => null の挙動】
-- - アドレスが 0〜7 と 65(0x41) 以外の場合は `null` で何もしないため、
--   RAM_OUT は更新されず前回値を保持する可能性がある。
-- - bring-up/シミュレーションでは、未定義アドレスアクセス時に
--   「前回の値が残っただけ」なのに正しい読み出しと誤解しないよう注意が必要である。
-- - 堅牢化するなら、others で RAM_OUT <= (others=>'0') のように既知値へ落とす設計もある。


library IEEE;
use IEEE.std_logic_1164.all;

-- ============================================================
-- entity: Decode段のRAM/I/O読み出し（1ポート分）
-- ============================================================
entity ram_dc is
    port
    (
        -- Decode段クロック：ここで読み出し結果をラッチして次段へ渡す
        CLK_DC      : in  std_logic;

        -- 命令から来るRAMアドレス（8bit）
        -- LD/ST系命令や、I/Oアクセスの番地として解釈される。
        RAM_AD_IN   : in  std_logic_vector(7 downto 0);

        -- 小規模RAM（8ワード）の各内容（外部から入力として与えられる）
        -- 実体のRAMはram_wb側で保持し、ここでは“読み出し用に配線”している形になっている。
        RAM_0       : in  std_logic_vector(15 downto 0);
        RAM_1       : in  std_logic_vector(15 downto 0);
        RAM_2       : in  std_logic_vector(15 downto 0);
        RAM_3       : in  std_logic_vector(15 downto 0);
        RAM_4       : in  std_logic_vector(15 downto 0);
        RAM_5       : in  std_logic_vector(15 downto 0);
        RAM_6       : in  std_logic_vector(15 downto 0);
        RAM_7       : in  std_logic_vector(15 downto 0);

        -- メモリマップドI/O入力（例：I/O番地65）
        IO65_IN     : in  std_logic_vector(15 downto 0);

        -- 次段へ渡すアドレス（storeの書き込み先確定などで使用）
        RAM_AD_OUT  : out std_logic_vector(7 downto 0);

        -- 読み出しデータ（次段へ渡すオペランド）
        RAM_OUT     : out std_logic_vector(15 downto 0)
    );
end ram_dc;

-- ============================================================
-- architecture RTL: case分岐でメモリ/I/Oを選択し、段クロックでラッチ
-- ============================================================
architecture RTL of ram_dc is

begin

    -- ========================================================
    -- Decode段：アドレスデコードして読み出し値を確定
    -- ========================================================
    process(CLK_DC)
    begin
        if (CLK_DC'event and CLK_DC = '1') then

            -- ------------------------------------------------
            -- RAM_AD_IN に応じてどの入力を読むかを決める
            -- ------------------------------------------------
            -- 0〜7：小規模RAM
            -- 0x41(65)：IO65_IN（メモリマップドI/O）
            case RAM_AD_IN is
                when "00000000" => RAM_OUT <= RAM_0;    -- addr 0
                when "00000001" => RAM_OUT <= RAM_1;    -- addr 1
                when "00000010" => RAM_OUT <= RAM_2;    -- addr 2
                when "00000011" => RAM_OUT <= RAM_3;    -- addr 3
                when "00000100" => RAM_OUT <= RAM_4;    -- addr 4
                when "00000101" => RAM_OUT <= RAM_5;    -- addr 5
                when "00000110" => RAM_OUT <= RAM_6;    -- addr 6
                when "00000111" => RAM_OUT <= RAM_7;    -- addr 7

                -- addr 65 (0x41)：外部入力ポートを読む
                when "01000001" => RAM_OUT <= IO65_IN;

                -- 想定外アドレス：更新しない（前回値保持になり得る）
                when others     => null;
            end case;

        end if;
    end process;

    -- ========================================================
    -- アドレスはそのまま次段へ流す（段跨ぎで保持）
    -- ========================================================
    -- store命令などで「書き込み先アドレス」をWriteBack段まで伝搬するために重要。
    RAM_AD_OUT <= RAM_AD_IN;

end RTL;

-- 【CPU拡張の観点】
-- - RAMを増やすならRAM_0〜の固定入力方式ではなく、配列化してインデックス参照に寄せる。
-- - I/O番地を増やすなら、0x41以外のアドレスもメモリマップしてcaseを拡張する。
-- - 未定義アドレス時は既知値へ落とす（ゼロ/エラーコード）とデバッグが安定する。
