/*
  CPU_emulator.c（詳細コメント版 / GNU環境（gcc/clang）での利用を想定）

  ※今回の「GNUにしなさい」の意味について
  - このファイルは MSVC の __asm { ... } のような“インラインアセンブラ構文”は使っていない。
    つまり「GNU拡張インラインasmへ変換する」対象ではなく、もともと純粋なCコードである。
  - ただし、元コードは C言語としては非推奨な `void main(void)` を使っているので、
    GNUツールチェーン（gcc/clang）で警告を減らし、移植性を上げるために
    `int main(void)` に直すのが実務的である。
  - また、C言語には予約語 `or` が無いので通常は大丈夫だが、
    C++としてコンパイルすると `or` は代替トークン（||）として扱われて衝突する。
    将来C++で扱う可能性があるなら関数名を変更するのが安全である（ここではC前提で据え置く）。

  【このプログラムの位置づけ（自作CPU観点）】
  - 「実機CPU」ではなく、「自作CPUの命令セット（ISA）をソフトウェアで模擬する」エミュレータである。
  - CPUの典型的な命令実行サイクル（Fetch → Decode → Execute）を、
    Cのループと switch 文で再現している。
  - 命令は16bit（short）で表され、ROMに格納された命令列をPCで順番に取り出して実行する。
  - レジスタファイル（reg[8]）、命令メモリ（rom[256]）、データメモリ（ram[256]）を持つ
    典型的な「教育用CPUモデル」になっている。
*/

#include <stdio.h>

/* --- 命令オペコード定義（上位ビットに格納される） ---
   このエミュレータでは命令(ir)の上位5bit（ir >> 11）をオペコードとして扱う。

   命令フォーマットの概略（16bit）：
     [15:11] opcode (5bit)
     [10:8]  regA  (3bit)  ※命令によっては使わない
     [7:5]   regB  (3bit)  ※命令によっては使わない
     [7:0]   imm/addr (8bit) ※LDL/LDH/JE/JMP/LD/STなど

   自作CPU設計では「命令フォーマット（ビット割り当て）」は最重要仕様であり、
   ここでは非常に単純な固定長16bit命令として設計されている。
*/
#define MOV      0
#define ADD      1
#define SUB      2
#define AND      3
#define OR       4
#define SL       5
#define SR       6
#define SRA      7
#define LDL      8
#define LDH      9
#define CMP     10
#define JE      11
#define JMP     12
#define LD      13
#define ST      14
#define HLT     15

/* --- レジスタ番号（0〜7） ---
   reg[8] が「レジスタファイル」。REG0..REG7 はそのインデックス。
*/
#define REG0 0
#define REG1 1
#define REG2 2
#define REG3 3
#define REG4 4
#define REG5 5
#define REG6 6
#define REG7 7

/* --- CPU状態（グローバル） ---
   - reg: 汎用レジスタ8本（16bit）
   - rom: 命令メモリ（最大256語）
   - ram: データメモリ（最大256語）

   自作CPUに対応付けると：
   - reg[] はレジスタファイル
   - rom[] は命令ROM（プログラム格納領域）
   - ram[] はデータRAM（メモリ/IO領域としても流用）
*/
short reg[8];
short rom[256];
short ram[256];

/* assembler() は「アセンブラの役割」をC関数でやっている。
   - 本来アセンブラは人間が書いた命令（ニーモニック）を機械語に変換するが、
     ここでは C の関数（add/ldh/je...）を呼んで機械語(short)を組み立て、
     rom[] に書き込んでいる。
*/
void assembler(void);

/* 以下は「機械語を組み立てる関数」群。
   - mov/add/sub/... は命令語（16bit）を返す。
   - op_code/op_regA/... は命令語（ir）からフィールドを取り出すデコーダ。
*/
short mov(short, short);
short add(short, short);
short sub(short, short);
short and(short, short);
short or(short, short);
short sl(short);
short sr(short);
short sra(short);
short ldl(short, short);
short ldh(short, short);
short cmp(short, short);
short je(short);
short jmp(short);
short ld(short, short);
short st(short, short);
short hlt(void);
short op_code(short);
short op_regA(short);
short op_regB(short);
short op_data(short);
short op_addr(short);

/*
  メイン：Fetch-Decode-Execute ループを回す。

  【CPU実行サイクル（典型）】
  1) Fetch:  ir = rom[pc]   （PCが指す命令を取り出す）
  2) PC++:   pc = pc + 1    （次命令へ進める ※分岐命令が上書きする場合あり）
  3) Decode: opcode = op_code(ir) 等で命令フィールドを取り出す
  4) Execute: opcodeに応じて reg/ram/pc/flag を更新する
  5) HLT で停止

  ※本来のCPUでは同時にフラグレジスタや例外などもあるが、ここでは最小限。
*/
int main(void) {
    /* --- CPUの内部状態（ローカル） --- */
    short pc;       // Program Counter：次に実行する命令のアドレス（romインデックス）
    short ir;       // Instruction Register：取り出した命令語（16bit）
    short flag_eq;  // CMPの結果（等しいかどうか）を保持する簡易フラグ

    /*
      assembler() が rom[] に「実行するプログラム（命令列）」を書き込む。
      - ここでは 1+2+...+10=55 を計算するプログラムを組み立てている。
      - 自作CPUで言えば「ROMにプログラムを書き込む」工程に相当する。
    */
    assembler();

    /* PCとフラグを初期化（CPUリセット動作に相当） */
    pc = 0;
    flag_eq = 0;

    /*
      命令実行ループ：
      - HLT命令に遭遇するまで回す。
      - ここでは do-while を使っているので、少なくとも1命令は必ず実行する。
    */
    do {
        /* --- Fetch --- */
        ir = rom[pc];

        /*
          観測用ログ：
          - pc: 現在の命令アドレス
          - ir: 命令語を16進数で表示
          - reg0..reg3: レジスタの一部を表示

          自作CPU開発でも、命令トレース（PC/IR/レジスタ）がデバッグの基本になる。
        */
        printf(" %5d  %5x  %5d  %5d  %5d  %5d\n",
               pc, ir, reg[0], reg[1], reg[2], reg[3]);

        /*
          PC更新：
          - 通常の逐次実行では「次の命令」を指すため pc++ する。
          - ただし分岐命令（JE/JMP）が発動した場合は、
            ここで増やしたPCを後で上書きする（典型的な実装手法）。
        */
        pc = pc + 1;

        /* --- Decode + Execute（switchで命令ディスパッチ） --- */
        switch (op_code(ir)) {

            case MOV:
                /* MOV: regA = regB
                   - レジスタ間転送（データパスの基本）
                */
                reg[op_regA(ir)] = reg[op_regB(ir)];
                break;

            case ADD:
                /* ADD: regA = regA + regB
                   - レジスタ同士の加算（ALU）
                */
                reg[op_regA(ir)] = reg[op_regA(ir)] + reg[op_regB(ir)];
                break;

            case SUB:
                /* SUB: regA = regA - regB
                   - 減算（ALU）
                */
                reg[op_regA(ir)] = reg[op_regA(ir)] - reg[op_regB(ir)];
                break;

            case AND:
                /* AND: regA = regA & regB
                   - ビット論理積（ALU）
                */
                reg[op_regA(ir)] = reg[op_regA(ir)] & reg[op_regB(ir)];
                break;

            case OR:
                /* OR: regA = regA | regB
                   - ビット論理和（ALU）
                */
                reg[op_regA(ir)] = reg[op_regA(ir)] | reg[op_regB(ir)];
                break;

            case SL:
                /* SL: regA = regA << 1
                   - 1bit左シフト（論理シフト）
                   - 自作CPUではシフタの実装（barrel shifter等）が論点になる。
                */
                reg[op_regA(ir)] = reg[op_regA(ir)] << 1;
                break;

            case SR:
                /* SR: regA = regA >> 1
                   - 右シフト。Cの >> は signed の場合「算術右シフト」になることが多いが、
                     仕様としては処理系依存部分がある。
                   - このコードでは SR と SRA を分けて定義しているが、
                     SR実装が算術になってしまう可能性がある点は注意。
                */
                reg[op_regA(ir)] = reg[op_regA(ir)] >> 1;
                break;

            case SRA:
                /* SRA: 算術右シフト（符号ビットを維持）
                   - ここでは手動で符号ビット(0x8000)を残す形で実装している。
                   - ただし、この実装は「元の最上位ビットをそのまま OR する」だけなので、
                     本来の算術右シフト（上位ビットを埋める）と完全一致しない場合がある。

                     例：regA が負（MSB=1）のとき、本来は
                       (regA >> 1) の上位ビットが 1 で埋まるべきだが、
                     Cの >> が既に算術右シフトなら、このORは二重に符号を扱う可能性がある。
                     教材としては「算術右シフトとは何か」を示す意図と理解するのが良い。

                   自作CPUでの設計：
                   - 論理右シフト(SR)と算術右シフト(SRA)を命令として分けるか
                   - あるいは同一命令でビット幅/符号属性により振る舞いを変えるか
                     を決める必要がある。
                */
                reg[op_regA(ir)] = (reg[op_regA(ir)] & 0x8000) | (reg[op_regA(ir)] >> 1);
                break;

            case LDL:
                /* LDL: regA の下位8bitに即値をロード
                   - regA = (regA & 0xff00) | (imm & 0x00ff)
                   - 16bit即値を1命令でロードできないISAの場合、
                     上位/下位を分けてセットする手法が典型である（RISC-VのLUI/ADDIの発想に近い）。

                   自作CPU観点：
                   - 即値ロード命令は必須級。
                   - 8bit即値を命令内に埋め込む設計なので、命令フォーマットが簡単。
                */
                reg[op_regA(ir)] = (reg[op_regA(ir)] & 0xff00) | (op_data(ir) & 0x00ff);
                break;

            case LDH:
                /* LDH: regA の上位8bitに即値をロード
                   - regA = (imm << 8) | (regA & 0x00ff)
                   - LDLと組み合わせて16bit定数を構成する。

                   注意：
                   - op_data(ir) は 0..255 のはずだが、shortの符号拡張が混ざると困るので、
                     マスク（&0x00ff）を意識する設計は重要。
                */
                reg[op_regA(ir)] = (op_data(ir) << 8) | (reg[op_regA(ir)] & 0x00ff);
                break;

            case CMP:
                /* CMP: regA と regB を比較して flag_eq を更新
                   - 本来のCPUではフラグレジスタ（ZF等）に格納されるが、
                     ここでは簡単のため flag_eq だけを持つ。
                */
                if (reg[op_regA(ir)] == reg[op_regB(ir)]) {
                    flag_eq = 1;
                } else {
                    flag_eq = 0;
                }
                break;

            case JE:
                /* JE: Jump if Equal
                   - flag_eq が 1 のとき PC を addr に変更（分岐）
                   - PCはすでに pc++ されているが、分岐が成立した場合はここで上書きする。
                */
                if (flag_eq == 1) pc = op_addr(ir);
                break;

            case JMP:
                /* JMP: unconditional jump
                   - 無条件に PC を addr に変更する。
                */
                pc = op_addr(ir);
                break;

            case LD:
                /* LD: regA = ram[addr]
                   - メモリロード命令。データメモリから読み出してレジスタへ入れる。
                */
                reg[op_regA(ir)] = ram[op_addr(ir)];
                break;

            case ST:
                /* ST: ram[addr] = regA
                   - メモリストア命令。レジスタの値をデータメモリへ書く。
                   - 教材では addr=64 を「I/Oポート相当」として扱っている。
                */
                ram[op_addr(ir)] = reg[op_regA(ir)];
                break;

            default:
                /* 未定義命令の扱い
                   - 現状は何もしない（NOP相当）としている。
                   - 自作CPUでは未定義命令を例外にするか、NOPとして無視するかを決める必要がある。
                */
                break;
        }

    } while (op_code(ir) != HLT);  // HLT命令が来たら停止

    /*
      実行結果の確認：
      - このサンプルプログラムでは ST により REG0 を ram[64] に書き込む。
      - したがってここでは ram[64] が 55 になっていることが期待される。
    */
    printf("ram[64] = %d \n", ram[64]);

    return 0;
}

/*
  assembler():
  - rom[] に命令語を並べて「プログラム」を構成する。
  - この例では 1+2+...+10 = 55 を計算して、途中経過を ram[64] に書く。

  ただし、この命令列は“よくある加算ループ”とは少し違う点がある。
  - REG2 をカウンタのように増やして REG3(=10) と比較しているが、
    インクリメント命令が用意されていないため、
    「REG2 を REG2 + REG1 で増やす」という形になっている。
    （REG1が1であるため、結果的に REG2 が 1ずつ増える。）

  命令列の意味（概略）：
  - REG0: 出力/保存用（ram[64]へ書く値）
  - REG1: 定数1
  - REG2: カウンタ（1,2,3,...,10）
  - REG3: 定数10（比較対象）

  実行の流れ：
    REG0 = 0
    REG1 = 1
    REG2 = 0
    REG3 = 10
  ループ(PC=8):
    REG2 = REG2 + REG1     // 1ずつ増える → 1..10
    REG0 = REG0 + REG2     // 総和を蓄積
    ram[64] = REG0         // “I/O”へ書き込み
    if (REG2 == REG3) goto 14
    goto 8
  14: HLT
*/
void assembler(void) {
    rom[0]  = ldh(REG0, 0);
    rom[1]  = ldl(REG0, 0);
    rom[2]  = ldh(REG1, 0);
    rom[3]  = ldl(REG1, 1);
    rom[4]  = ldh(REG2, 0);
    rom[5]  = ldl(REG2, 0);
    rom[6]  = ldh(REG3, 0);
    rom[7]  = ldl(REG3, 10);
    rom[8]  = add(REG2, REG1);
    rom[9]  = add(REG0, REG2);
    rom[10] = st(REG0, 64);
    rom[11] = cmp(REG2, REG3);
    rom[12] = je(14);
    rom[13] = jmp(8);
    rom[14] = hlt();
}

/* --- 以下、命令語のエンコード関数群 ---
   それぞれ「opcode」と「レジスタ番号」「即値/アドレス」を、ビットフィールドに詰めて16bit命令語を返す。

   ビット配置（再掲）：
     [15:11] opcode
     [10:8]  regA
     [7:5]   regB
     [7:0]   imm/addr

   自作CPU観点：
   - ここはまさに「アセンブラ」のコアであり、ISA仕様をそのままコード化した部分である。
   - opcodeのビット幅、レジスタ数、即値幅を変えると、ここの設計も全て変わる。
*/

short mov(short ra, short rb) { return ((MOV << 11) | (ra << 8) | (rb << 5)); }
short add(short ra, short rb) { return ((ADD << 11) | (ra << 8) | (rb << 5)); }
short sub(short ra, short rb) { return ((SUB << 11) | (ra << 8) | (rb << 5)); }
short and(short ra, short rb) { return ((AND << 11) | (ra << 8) | (rb << 5)); }
short or (short ra, short rb) { return ((OR  << 11) | (ra << 8) | (rb << 5)); }
short sl(short ra)            { return ((SL  << 11) | (ra << 8)); }
short sr(short ra)            { return ((SR  << 11) | (ra << 8)); }
short sra(short ra)           { return ((SRA << 11) | (ra << 8)); }

short ldl(short ra, short ival) {
    /* LDL: 下位8bit即値を埋め込む */
    return ((LDL << 11) | (ra << 8) | (ival & 0x00ff));
}

short ldh(short ra, short ival) {
    /* LDH: 上位8bit即値を埋め込む（実行時に <<8 される） */
    return ((LDH << 11) | (ra << 8) | (ival & 0x00ff));
}

short cmp(short ra, short rb) { return ((CMP << 11) | (ra << 8) | (rb << 5)); }
short je(short addr)          { return ((JE  << 11) | (addr & 0x00ff)); }
short jmp(short addr)         { return ((JMP << 11) | (addr & 0x00ff)); }
short ld(short ra, short addr){ return ((LD  << 11) | (ra << 8) | (addr & 0x00ff)); }
short st(short ra, short addr){ return ((ST  << 11) | (ra << 8) | (addr & 0x00ff)); }
short hlt(void)               { return (HLT << 11); }

/* --- デコーダ（命令語からフィールドを取り出す） --- */

short op_code(short ir) {
    /* opcodeは上位5bit */
    return (ir >> 11);
}

short op_regA(short ir) {
    /* regAは[10:8]の3bit */
    return ((ir >> 8) & 0x0007);
}

short op_regB(short ir) {
    /* regBは[7:5]の3bit */
    return ((ir >> 5) & 0x0007);
}

short op_data(short ir) {
    /* 下位8bit（即値データ） */
    return (ir & 0x00ff);
}

short op_addr(short ir) {
    /* 下位8bit（アドレス） */
    return (ir & 0x00ff);
}

/*
  【GNUでのコンパイル例（Ubuntu / gcc）】
    gcc -O0 -g CPU_emulator.c -o CPU_emulator

  【実行例】
    ./CPU_emulator
*/
