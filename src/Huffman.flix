///
/// Port of `org.lichess.compression.game.Huffman` (Scala) to Flix.
///
/// The static 256-entry code table and the decoding tree built from it are the
/// whole of this module; a single wrong bit here corrupts every encoded game, so
/// the table below was mechanically transcribed from the Scala source rather than
/// retyped. The Scala writes each code as a binary string and calls
/// `Integer.parseInt(s, 2)` at class-init time; here the same values appear as
/// decimal `Int32` literals, with the original bit string kept in the comment. No
/// code exceeds 31 bits, so every value is a non-negative Java `int` and the
/// conversion is exact.
///
/// Differences forced by Flix, none of them observable in the output:
///
///   - Flix has no `null`, so the Scala `Node(zero, one, leaf)` class — where a
///     leaf is the node with `zero == null && one == null` — becomes the ADT
///     `Node.Leaf(Int32)` / `Node.Branch(Node, Node)`. The Scala `leaf == -1`
///     sentinel on interior nodes has no counterpart because it is unreachable.
///   - Flix has no memoization and no global state: a top-level `def` is
///     recomputed on every call, so `CODES` and `ROOT` cannot be zero-argument
///     `def`s that callers hit per move. Instead `mkTable()` builds both once into
///     an immutable `HuffmanTable`, and `write`/`read` take it as their first
///     argument. `HuffmanTable` is pure, region-free data, so during integration it
///     can simply become a field of the shared `Tables` struct.
///   - `(0 to 0xff).find(...)` becomes an explicit ascending tail-recursive scan,
///     which fixes the same left-to-right order the Scala relies on.
///   - Scala's `assert(bits <= 32)` in `buildTree` is dropped: it is unreachable.
///     The table is a complete prefix code (its Kraft sum is exactly 1 and its
///     longest code is 31 bits), so the recursion always finds a leaf by depth 31.
///
mod Huffman {

    ///
    /// The Scala `private case class Symbol(code: Int, bits: Int)`.
    ///
    pub enum Symbol with Eq, ToString {
        case Symbol(Int32, Int32)
    }

    ///
    /// The Scala `private class Node(zero, one, leaf)`.
    ///
    /// `Node(leaf)` is `Leaf(leaf)`; `Node(zero, one)` is `Branch(zero, one)`.
    ///
    pub enum Node with Eq, ToString {
        case Leaf(Int32)
        case Branch(Node, Node)
    }

    ///
    /// `CODES` plus the `ROOT` decoding tree built from it, bundled so that the
    /// caller can build them once and hold them.
    ///
    pub enum HuffmanTable {
        case HuffmanTable(Vector[Symbol], Node)
    }

    ///
    /// Build the code table and its decoding tree. Call once and keep the result:
    /// `buildTree` visits 511 nodes and scans up to 256 entries at each one.
    ///
    pub def mkTable(): HuffmanTable =
        let cs = codes();
        HuffmanTable.HuffmanTable(cs, buildTree(cs, 0, 0))

    ///
    /// `write(value, writer)`: emit the code for `value` in `CODES`.
    ///
    pub def write(t: HuffmanTable, value: Int32, w: BitWriter[r]): Unit \ r = {
        match t {
            case HuffmanTable.HuffmanTable(cs, _) => match Vector.get(value, cs) {
                case Symbol.Symbol(code, bits) => BitWriter.writeBits(code, bits, w)
            }
        };
        // Trailing `()`: see the note in `mod Board`. A tail call to another def
        // is compiled to a heap continuation dispatched through `Thunk$.invoke()`.
        ()
    }

    ///
    /// `read(reader)`: walk the decoding tree one bit at a time until a leaf.
    ///
    @Inline
    pub def read(t: HuffmanTable, rd: BitReader[r]): Int32 \ r =
        match t {
            case HuffmanTable.HuffmanTable(_, root) => traverse(root, rd)
        }

    ///
    /// The Scala inner `traverse`, which descends to a leaf and then reads `.leaf`.
    ///
    def traverse(node: Node, rd: BitReader[r]): Int32 \ r =
        match node {
            case Node.Leaf(value) => value
            case Node.Branch(zero, one) =>
                if (BitReader.readBits(1, rd) == 0)
                    traverse(zero, rd)
                else
                    traverse(one, rd)
        }

    ///
    /// `buildTree(code, bits)`: the symbol whose code is exactly these `bits` bits
    /// if there is one, otherwise the branch on the next bit.
    ///
    pub def buildTree(cs: Vector[Symbol], code: Int32, bits: Int32): Node =
        match findSymbol(cs, code, bits, 0) {
            case Some(i) => Node.Leaf(i)
            case None    =>
                Node.Branch(
                    buildTree(cs, Bits.shl(code, 1), bits + 1),
                    buildTree(cs, Bits.bor(Bits.shl(code, 1), 1), bits + 1))
        }

    ///
    /// `(0 to 0xff).find(i => CODES(i).code == code && CODES(i).bits == bits)`.
    ///
    def findSymbol(cs: Vector[Symbol], code: Int32, bits: Int32, i: Int32): Option[Int32] =
        if (i > 0xff)
            None
        else
            match Vector.get(i, cs) {
                case Symbol.Symbol(c, b) =>
                    if (c == code and b == bits)
                        Some(i)
                    else
                        findSymbol(cs, code, bits, i + 1)
            }

    ///
    /// `CODES`: the static table, transcribed from `game/Huffman.scala`.
    ///
    /// Each entry is `Symbol(code, bits)`; the comment gives the index and the
    /// original binary string. Frequencies from the Scala source are omitted.
    ///
    pub def codes(): Vector[Symbol] =
        Vector#{
        Symbol.Symbol(0, 2),  //   0: 0b00
        Symbol.Symbol(4, 3),  //   1: 0b100
        Symbol.Symbol(13, 4),  //   2: 0b1101
        Symbol.Symbol(10, 4),  //   3: 0b1010
        Symbol.Symbol(5, 4),  //   4: 0b0101
        Symbol.Symbol(29, 5),  //   5: 0b11101
        Symbol.Symbol(23, 5),  //   6: 0b10111
        Symbol.Symbol(14, 5),  //   7: 0b01110
        Symbol.Symbol(12, 5),  //   8: 0b01100
        Symbol.Symbol(8, 5),  //   9: 0b01000
        Symbol.Symbol(61, 6),  //  10: 0b111101
        Symbol.Symbol(57, 6),  //  11: 0b111001
        Symbol.Symbol(60, 6),  //  12: 0b111100
        Symbol.Symbol(51, 6),  //  13: 0b110011
        Symbol.Symbol(50, 6),  //  14: 0b110010
        Symbol.Symbol(48, 6),  //  15: 0b110000
        Symbol.Symbol(45, 6),  //  16: 0b101101
        Symbol.Symbol(44, 6),  //  17: 0b101100
        Symbol.Symbol(31, 6),  //  18: 0b011111
        Symbol.Symbol(27, 6),  //  19: 0b011011
        Symbol.Symbol(19, 6),  //  20: 0b010011
        Symbol.Symbol(26, 6),  //  21: 0b011010
        Symbol.Symbol(127, 7),  //  22: 0b1111111
        Symbol.Symbol(125, 7),  //  23: 0b1111101
        Symbol.Symbol(126, 7),  //  24: 0b1111110
        Symbol.Symbol(124, 7),  //  25: 0b1111100
        Symbol.Symbol(112, 7),  //  26: 0b1110000
        Symbol.Symbol(99, 7),  //  27: 0b1100011
        Symbol.Symbol(61, 7),  //  28: 0b0111101
        Symbol.Symbol(37, 7),  //  29: 0b0100101
        Symbol.Symbol(36, 7),  //  30: 0b0100100
        Symbol.Symbol(226, 8),  //  31: 0b11100010
        Symbol.Symbol(197, 8),  //  32: 0b11000101
        Symbol.Symbol(121, 8),  //  33: 0b01111001
        Symbol.Symbol(455, 9),  //  34: 0b111000111
        Symbol.Symbol(393, 9),  //  35: 0b110001001
        Symbol.Symbol(241, 9),  //  36: 0b011110001
        Symbol.Symbol(240, 9),  //  37: 0b011110000
        Symbol.Symbol(908, 10),  //  38: 0b1110001100
        Symbol.Symbol(784, 10),  //  39: 0b1100010000
        Symbol.Symbol(1818, 11),  //  40: 0b11100011010
        Symbol.Symbol(1570, 11),  //  41: 0b11000100010
        Symbol.Symbol(3638, 12),  //  42: 0b111000110110
        Symbol.Symbol(3142, 12),  //  43: 0b110001000110
        Symbol.Symbol(7278, 13),  //  44: 0b1110001101110
        Symbol.Symbol(6286, 13),  //  45: 0b1100010001110
        Symbol.Symbol(14558, 14),  //  46: 0b11100011011110
        Symbol.Symbol(12574, 14),  //  47: 0b11000100011110
        Symbol.Symbol(29118, 15),  //  48: 0b111000110111110
        Symbol.Symbol(25150, 15),  //  49: 0b110001000111110
        Symbol.Symbol(58238, 16),  //  50: 0b1110001101111110
        Symbol.Symbol(50302, 16),  //  51: 0b1100010001111110
        Symbol.Symbol(100607, 17),  //  52: 0b11000100011111111
        Symbol.Symbol(232959, 18),  //  53: 0b111000110111111111
        Symbol.Symbol(232957, 18),  //  54: 0b111000110111111101
        Symbol.Symbol(201212, 18),  //  55: 0b110001000111111100
        Symbol.Symbol(465916, 19),  //  56: 0b1110001101111111100
        Symbol.Symbol(402427, 19),  //  57: 0b1100010001111111011
        Symbol.Symbol(931835, 20),  //  58: 0b11100011011111111011
        Symbol.Symbol(931826, 20),  //  59: 0b11100011011111110010
        Symbol.Symbol(931824, 20),  //  60: 0b11100011011111110000
        Symbol.Symbol(1863669, 21),  //  61: 0b111000110111111110101
        Symbol.Symbol(1863654, 21),  //  62: 0b111000110111111100110
        Symbol.Symbol(1863650, 21),  //  63: 0b111000110111111100010
        Symbol.Symbol(1609705, 21),  //  64: 0b110001000111111101001
        Symbol.Symbol(1609704, 21),  //  65: 0b110001000111111101000
        Symbol.Symbol(3727336, 22),  //  66: 0b1110001101111111101000
        Symbol.Symbol(3727302, 22),  //  67: 0b1110001101111111000110
        Symbol.Symbol(3219415, 22),  //  68: 0b1100010001111111010111
        Symbol.Symbol(3219413, 22),  //  69: 0b1100010001111111010101
        Symbol.Symbol(7454675, 23),  //  70: 0b11100011011111111010011
        Symbol.Symbol(7454622, 23),  //  71: 0b11100011011111110011110
        Symbol.Symbol(7454606, 23),  //  72: 0b11100011011111110001110
        Symbol.Symbol(7454607, 23),  //  73: 0b11100011011111110001111
        Symbol.Symbol(6438828, 23),  //  74: 0b11000100011111110101100
        Symbol.Symbol(14909243, 24),  //  75: 0b111000110111111100111011
        Symbol.Symbol(14909348, 24),  //  76: 0b111000110111111110100100
        Symbol.Symbol(14909247, 24),  //  77: 0b111000110111111100111111
        Symbol.Symbol(14909242, 24),  //  78: 0b111000110111111100111010
        Symbol.Symbol(12877659, 24),  //  79: 0b110001000111111101011011
        Symbol.Symbol(12877651, 24),  //  80: 0b110001000111111101010011
        Symbol.Symbol(12877649, 24),  //  81: 0b110001000111111101010001
        Symbol.Symbol(29818483, 25),  //  82: 0b1110001101111111001110011
        Symbol.Symbol(29818481, 25),  //  83: 0b1110001101111111001110001
        Symbol.Symbol(29818482, 25),  //  84: 0b1110001101111111001110010
        Symbol.Symbol(25755301, 25),  //  85: 0b1100010001111111010100101
        Symbol.Symbol(25755316, 25),  //  86: 0b1100010001111111010110100
        Symbol.Symbol(25755297, 25),  //  87: 0b1100010001111111010100001
        Symbol.Symbol(59636987, 26),  //  88: 0b11100011011111110011111011
        Symbol.Symbol(59636985, 26),  //  89: 0b11100011011111110011111001
        Symbol.Symbol(59636986, 26),  //  90: 0b11100011011111110011111010
        Symbol.Symbol(59636984, 26),  //  91: 0b11100011011111110011111000
        Symbol.Symbol(51510635, 26),  //  92: 0b11000100011111110101101011
        Symbol.Symbol(119274799, 27),  //  93: 0b111000110111111110100101111
        Symbol.Symbol(103021268, 27),  //  94: 0b110001000111111101011010100
        Symbol.Symbol(103021269, 27),  //  95: 0b110001000111111101011010101
        Symbol.Symbol(119273922, 27),  //  96: 0b111000110111111100111000010
        Symbol.Symbol(119273923, 27),  //  97: 0b111000110111111100111000011
        Symbol.Symbol(103021203, 27),  //  98: 0b110001000111111101010010011
        Symbol.Symbol(238549587, 28),  //  99: 0b1110001101111111101001010011
        Symbol.Symbol(206042405, 28),  // 100: 0b1100010001111111010100100101
        Symbol.Symbol(238547843, 28),  // 101: 0b1110001101111111001110000011
        Symbol.Symbol(238547842, 28),  // 102: 0b1110001101111111001110000010
        Symbol.Symbol(238547840, 28),  // 103: 0b1110001101111111001110000000
        Symbol.Symbol(477095682, 29),  // 104: 0b11100011011111110011100000010
        Symbol.Symbol(412084745, 29),  // 105: 0b11000100011111110101000001001
        Symbol.Symbol(477095683, 29),  // 106: 0b11100011011111110011100000011
        Symbol.Symbol(412084744, 29),  // 107: 0b11000100011111110101000001000
        Symbol.Symbol(412084739, 29),  // 108: 0b11000100011111110101000000011
        Symbol.Symbol(824169502, 30),  // 109: 0b110001000111111101010000011110
        Symbol.Symbol(954198374, 30),  // 110: 0b111000110111111110100101100110
        Symbol.Symbol(954198359, 30),  // 111: 0b111000110111111110100101010111
        Symbol.Symbol(824169485, 30),  // 112: 0b110001000111111101010000001101
        Symbol.Symbol(954198370, 30),  // 113: 0b111000110111111110100101100010
        Symbol.Symbol(824169480, 30),  // 114: 0b110001000111111101010000001000
        Symbol.Symbol(824169477, 30),  // 115: 0b110001000111111101010000000101
        Symbol.Symbol(824169472, 30),  // 116: 0b110001000111111101010000000000
        Symbol.Symbol(824169482, 30),  // 117: 0b110001000111111101010000001010
        Symbol.Symbol(824169613, 30),  // 118: 0b110001000111111101010010001101
        Symbol.Symbol(824169619, 30),  // 119: 0b110001000111111101010010010011
        Symbol.Symbol(824169618, 30),  // 120: 0b110001000111111101010010010010
        Symbol.Symbol(824169617, 30),  // 121: 0b110001000111111101010010010001
        Symbol.Symbol(824169616, 30),  // 122: 0b110001000111111101010010010000
        Symbol.Symbol(824169611, 30),  // 123: 0b110001000111111101010010001011
        Symbol.Symbol(824169610, 30),  // 124: 0b110001000111111101010010001010
        Symbol.Symbol(824169609, 30),  // 125: 0b110001000111111101010010001001
        Symbol.Symbol(824169608, 30),  // 126: 0b110001000111111101010010001000
        Symbol.Symbol(824169607, 30),  // 127: 0b110001000111111101010010000111
        Symbol.Symbol(824169606, 30),  // 128: 0b110001000111111101010010000110
        Symbol.Symbol(824169603, 30),  // 129: 0b110001000111111101010010000011
        Symbol.Symbol(824169602, 30),  // 130: 0b110001000111111101010010000010
        Symbol.Symbol(824169499, 30),  // 131: 0b110001000111111101010000011011
        Symbol.Symbol(824169498, 30),  // 132: 0b110001000111111101010000011010
        Symbol.Symbol(824169497, 30),  // 133: 0b110001000111111101010000011001
        Symbol.Symbol(824169496, 30),  // 134: 0b110001000111111101010000011000
        Symbol.Symbol(824169493, 30),  // 135: 0b110001000111111101010000010101
        Symbol.Symbol(824169492, 30),  // 136: 0b110001000111111101010000010100
        Symbol.Symbol(824169605, 30),  // 137: 0b110001000111111101010010000101
        Symbol.Symbol(824169604, 30),  // 138: 0b110001000111111101010010000100
        Symbol.Symbol(824169503, 30),  // 139: 0b110001000111111101010000011111
        Symbol.Symbol(824169501, 30),  // 140: 0b110001000111111101010000011101
        Symbol.Symbol(824169500, 30),  // 141: 0b110001000111111101010000011100
        Symbol.Symbol(824169601, 30),  // 142: 0b110001000111111101010010000001
        Symbol.Symbol(824169600, 30),  // 143: 0b110001000111111101010010000000
        Symbol.Symbol(824169487, 30),  // 144: 0b110001000111111101010000001111
        Symbol.Symbol(824169486, 30),  // 145: 0b110001000111111101010000001110
        Symbol.Symbol(824169484, 30),  // 146: 0b110001000111111101010000001100
        Symbol.Symbol(824169495, 30),  // 147: 0b110001000111111101010000010111
        Symbol.Symbol(824169494, 30),  // 148: 0b110001000111111101010000010110
        Symbol.Symbol(824169481, 30),  // 149: 0b110001000111111101010000001001
        Symbol.Symbol(824169476, 30),  // 150: 0b110001000111111101010000000100
        Symbol.Symbol(824169475, 30),  // 151: 0b110001000111111101010000000011
        Symbol.Symbol(824169474, 30),  // 152: 0b110001000111111101010000000010
        Symbol.Symbol(824169473, 30),  // 153: 0b110001000111111101010000000001
        Symbol.Symbol(824169483, 30),  // 154: 0b110001000111111101010000001011
        Symbol.Symbol(824169615, 30),  // 155: 0b110001000111111101010010001111
        Symbol.Symbol(824169614, 30),  // 156: 0b110001000111111101010010001110
        Symbol.Symbol(824169612, 30),  // 157: 0b110001000111111101010010001100
        Symbol.Symbol(1908396733, 31),  // 158: 0b1110001101111111101001010111101
        Symbol.Symbol(1908396735, 31),  // 159: 0b1110001101111111101001010111111
        Symbol.Symbol(1908396706, 31),  // 160: 0b1110001101111111101001010100010
        Symbol.Symbol(1908396767, 31),  // 161: 0b1110001101111111101001011011111
        Symbol.Symbol(1908396708, 31),  // 162: 0b1110001101111111101001010100100
        Symbol.Symbol(1908396729, 31),  // 163: 0b1110001101111111101001010111001
        Symbol.Symbol(1908396762, 31),  // 164: 0b1110001101111111101001011011010
        Symbol.Symbol(1908396754, 31),  // 165: 0b1110001101111111101001011010010
        Symbol.Symbol(1908396752, 31),  // 166: 0b1110001101111111101001011010000
        Symbol.Symbol(1908396730, 31),  // 167: 0b1110001101111111101001010111010
        Symbol.Symbol(1908396683, 31),  // 168: 0b1110001101111111101001010001011
        Symbol.Symbol(1908396682, 31),  // 169: 0b1110001101111111101001010001010
        Symbol.Symbol(1908396681, 31),  // 170: 0b1110001101111111101001010001001
        Symbol.Symbol(1908396680, 31),  // 171: 0b1110001101111111101001010001000
        Symbol.Symbol(1908396679, 31),  // 172: 0b1110001101111111101001010000111
        Symbol.Symbol(1908396678, 31),  // 173: 0b1110001101111111101001010000110
        Symbol.Symbol(1908396677, 31),  // 174: 0b1110001101111111101001010000101
        Symbol.Symbol(1908396676, 31),  // 175: 0b1110001101111111101001010000100
        Symbol.Symbol(1908396759, 31),  // 176: 0b1110001101111111101001011010111
        Symbol.Symbol(1908396758, 31),  // 177: 0b1110001101111111101001011010110
        Symbol.Symbol(1908396757, 31),  // 178: 0b1110001101111111101001011010101
        Symbol.Symbol(1908396756, 31),  // 179: 0b1110001101111111101001011010100
        Symbol.Symbol(1908396727, 31),  // 180: 0b1110001101111111101001010110111
        Symbol.Symbol(1908396726, 31),  // 181: 0b1110001101111111101001010110110
        Symbol.Symbol(1908396693, 31),  // 182: 0b1110001101111111101001010010101
        Symbol.Symbol(1908396692, 31),  // 183: 0b1110001101111111101001010010100
        Symbol.Symbol(1908396725, 31),  // 184: 0b1110001101111111101001010110101
        Symbol.Symbol(1908396724, 31),  // 185: 0b1110001101111111101001010110100
        Symbol.Symbol(1908396695, 31),  // 186: 0b1110001101111111101001010010111
        Symbol.Symbol(1908396694, 31),  // 187: 0b1110001101111111101001010010110
        Symbol.Symbol(1908396721, 31),  // 188: 0b1110001101111111101001010110001
        Symbol.Symbol(1908396720, 31),  // 189: 0b1110001101111111101001010110000
        Symbol.Symbol(1908396691, 31),  // 190: 0b1110001101111111101001010010011
        Symbol.Symbol(1908396690, 31),  // 191: 0b1110001101111111101001010010010
        Symbol.Symbol(1908396781, 31),  // 192: 0b1110001101111111101001011101101
        Symbol.Symbol(1908396780, 31),  // 193: 0b1110001101111111101001011101100
        Symbol.Symbol(1908396779, 31),  // 194: 0b1110001101111111101001011101011
        Symbol.Symbol(1908396778, 31),  // 195: 0b1110001101111111101001011101010
        Symbol.Symbol(1908396775, 31),  // 196: 0b1110001101111111101001011100111
        Symbol.Symbol(1908396774, 31),  // 197: 0b1110001101111111101001011100110
        Symbol.Symbol(1908396689, 31),  // 198: 0b1110001101111111101001010010001
        Symbol.Symbol(1908396688, 31),  // 199: 0b1110001101111111101001010010000
        Symbol.Symbol(1908396771, 31),  // 200: 0b1110001101111111101001011100011
        Symbol.Symbol(1908396770, 31),  // 201: 0b1110001101111111101001011100010
        Symbol.Symbol(1908396769, 31),  // 202: 0b1110001101111111101001011100001
        Symbol.Symbol(1908396768, 31),  // 203: 0b1110001101111111101001011100000
        Symbol.Symbol(1908396777, 31),  // 204: 0b1110001101111111101001011101001
        Symbol.Symbol(1908396776, 31),  // 205: 0b1110001101111111101001011101000
        Symbol.Symbol(1908396687, 31),  // 206: 0b1110001101111111101001010001111
        Symbol.Symbol(1908396686, 31),  // 207: 0b1110001101111111101001010001110
        Symbol.Symbol(1908396675, 31),  // 208: 0b1110001101111111101001010000011
        Symbol.Symbol(1908396674, 31),  // 209: 0b1110001101111111101001010000010
        Symbol.Symbol(1908396685, 31),  // 210: 0b1110001101111111101001010001101
        Symbol.Symbol(1908396684, 31),  // 211: 0b1110001101111111101001010001100
        Symbol.Symbol(1908396751, 31),  // 212: 0b1110001101111111101001011001111
        Symbol.Symbol(1908396750, 31),  // 213: 0b1110001101111111101001011001110
        Symbol.Symbol(1908396673, 31),  // 214: 0b1110001101111111101001010000001
        Symbol.Symbol(1908396672, 31),  // 215: 0b1110001101111111101001010000000
        Symbol.Symbol(1908396761, 31),  // 216: 0b1110001101111111101001011011001
        Symbol.Symbol(1908396760, 31),  // 217: 0b1110001101111111101001011011000
        Symbol.Symbol(1908396773, 31),  // 218: 0b1110001101111111101001011100101
        Symbol.Symbol(1908396772, 31),  // 219: 0b1110001101111111101001011100100
        Symbol.Symbol(1908396717, 31),  // 220: 0b1110001101111111101001010101101
        Symbol.Symbol(1908396716, 31),  // 221: 0b1110001101111111101001010101100
        Symbol.Symbol(1908396723, 31),  // 222: 0b1110001101111111101001010110011
        Symbol.Symbol(1908396722, 31),  // 223: 0b1110001101111111101001010110010
        Symbol.Symbol(1908396713, 31),  // 224: 0b1110001101111111101001010101001
        Symbol.Symbol(1908396712, 31),  // 225: 0b1110001101111111101001010101000
        Symbol.Symbol(1908396783, 31),  // 226: 0b1110001101111111101001011101111
        Symbol.Symbol(1908396782, 31),  // 227: 0b1110001101111111101001011101110
        Symbol.Symbol(1908396747, 31),  // 228: 0b1110001101111111101001011001011
        Symbol.Symbol(1908396746, 31),  // 229: 0b1110001101111111101001011001010
        Symbol.Symbol(1908396739, 31),  // 230: 0b1110001101111111101001011000011
        Symbol.Symbol(1908396738, 31),  // 231: 0b1110001101111111101001011000010
        Symbol.Symbol(1908396715, 31),  // 232: 0b1110001101111111101001010101011
        Symbol.Symbol(1908396714, 31),  // 233: 0b1110001101111111101001010101010
        Symbol.Symbol(1908396745, 31),  // 234: 0b1110001101111111101001011001001
        Symbol.Symbol(1908396744, 31),  // 235: 0b1110001101111111101001011001000
        Symbol.Symbol(1908396743, 31),  // 236: 0b1110001101111111101001011000111
        Symbol.Symbol(1908396742, 31),  // 237: 0b1110001101111111101001011000110
        Symbol.Symbol(1908396737, 31),  // 238: 0b1110001101111111101001011000001
        Symbol.Symbol(1908396736, 31),  // 239: 0b1110001101111111101001011000000
        Symbol.Symbol(1908396732, 31),  // 240: 0b1110001101111111101001010111100
        Symbol.Symbol(1908396711, 31),  // 241: 0b1110001101111111101001010100111
        Symbol.Symbol(1908396710, 31),  // 242: 0b1110001101111111101001010100110
        Symbol.Symbol(1908396734, 31),  // 243: 0b1110001101111111101001010111110
        Symbol.Symbol(1908396707, 31),  // 244: 0b1110001101111111101001010100011
        Symbol.Symbol(1908396705, 31),  // 245: 0b1110001101111111101001010100001
        Symbol.Symbol(1908396704, 31),  // 246: 0b1110001101111111101001010100000
        Symbol.Symbol(1908396766, 31),  // 247: 0b1110001101111111101001011011110
        Symbol.Symbol(1908396709, 31),  // 248: 0b1110001101111111101001010100101
        Symbol.Symbol(1908396765, 31),  // 249: 0b1110001101111111101001011011101
        Symbol.Symbol(1908396764, 31),  // 250: 0b1110001101111111101001011011100
        Symbol.Symbol(1908396728, 31),  // 251: 0b1110001101111111101001010111000
        Symbol.Symbol(1908396763, 31),  // 252: 0b1110001101111111101001011011011
        Symbol.Symbol(1908396753, 31),  // 253: 0b1110001101111111101001011010001
        Symbol.Symbol(1908396755, 31),  // 254: 0b1110001101111111101001011010011
        Symbol.Symbol(1908396731, 31)   // 255: 0b1110001101111111101001010111011
        }
}

mod TestHuffmanSelf {
    use Huffman.Node
    use Huffman.Symbol

    ///
    /// The table has 256 entries, and the ends of it survived transcription.
    ///
    @Test
    pub def testCodesTable(): Unit \ Assert =
        let cs = Huffman.codes();
        Assert.assertEq(expected = 256, Vector.length(cs));
        // 0b00, 0b100, 0b1101
        Assert.assertEq(expected = Symbol.Symbol(0, 2), Vector.get(0, cs));
        Assert.assertEq(expected = Symbol.Symbol(4, 3), Vector.get(1, cs));
        Assert.assertEq(expected = Symbol.Symbol(13, 4), Vector.get(2, cs));
        // 0b1100010001111110 and 0b1110001101111111101001010111011
        Assert.assertEq(expected = Symbol.Symbol(50302, 16), Vector.get(51, cs));
        Assert.assertEq(expected = Symbol.Symbol(1908396731, 31), Vector.get(255, cs))

    ///
    /// Bytes produced by writing a single symbol, checked against the output of the
    /// Scala `org.lichess.compression.game.Huffman` running on this machine.
    ///
    @Test
    pub def testWriteKnownBytes(): Unit \ Assert = region rc {
        let t = Huffman.mkTable();
        def single(v) = {
            let w = BitWriter.mk(rc);
            Huffman.write(t, v, w);
            Array.toList(BitWriter.toArray(w)) |> List.map(Bits.byteToUnsigned)
        };
        Assert.assertEq(expected = 0x00 :: Nil, single(0));
        Assert.assertEq(expected = 0xd0 :: Nil, single(2));
        Assert.assertEq(expected = 0xc4 :: 0x7f :: 0x80 :: Nil, single(52));
        Assert.assertEq(expected = 0xe3 :: 0x7f :: 0xa5 :: 0x76 :: Nil, single(255))
    }

    ///
    /// Writing 0..255 back to back gives the 788 bytes the Scala produces, and the
    /// decoding tree reads them back in order.
    ///
    @Test
    pub def testRoundTripAll(): Unit \ Assert = region rc {
        let t = Huffman.mkTable();
        let w = BitWriter.mk(rc);
        def write(v) = if (v <= 255) { Huffman.write(t, v, w); write(v + 1) } else ();
        write(0);
        let bytes = BitWriter.toArray(w);
        Assert.assertEq(expected = 788, Array.length(bytes));
        Assert.assertEq(expected = 0x26, Bits.byteToUnsigned(Array.get(0, bytes)));
        Assert.assertEq(expected = 0x60, Bits.byteToUnsigned(Array.get(787, bytes)));
        let rd = BitReader.mk(rc, bytes);
        def read(v, acc) = if (v <= 255) read(v + 1, Huffman.read(t, rd) :: acc) else List.reverse(acc);
        Assert.assertEq(expected = List.range(0, 256), read(0, Nil))
    }

    ///
    /// `buildTree` bottoms out on the shortest code, `0b00` for symbol 0, and the
    /// root itself is never a leaf.
    ///
    @Test
    pub def testTreeShape(): Unit \ Assert =
        let cs = Huffman.codes();
        Assert.assertEq(expected = Node.Leaf(0), Huffman.buildTree(cs, 0, 2));
        Assert.assertEq(expected = Node.Leaf(1), Huffman.buildTree(cs, 4, 3));
        match Huffman.buildTree(cs, 0, 0) {
            case Node.Leaf(_)      => Assert.fail("root must be a branch")
            case Node.Branch(_, _) => ()
        }
}
