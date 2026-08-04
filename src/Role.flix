///
/// The chess piece model: `Role` and `Piece`.
///
/// Port of `src/main/scala/game/model.scala`:
///
/// ```scala
/// case class Piece(white: Boolean, role: Role)
///
/// enum Role(val index: Int, val symbol: String):
///   case PAWN   extends Role(0, "")
///   case KNIGHT extends Role(1, "N")
///   case BISHOP extends Role(2, "B")
///   case ROOK   extends Role(3, "R")
///   case QUEEN  extends Role(4, "Q")
///   case KING   extends Role(5, "K")
/// ```
///
/// Scala attaches `index` and `symbol` to the enum cases as constructor
/// parameters. Flix enums carry no such per-case metadata, so the two tables
/// become total functions `Role.index` and `Role.symbol`. The declaration order
/// below is the index order, which is what the derived `Order` instance follows.
///

///
/// The role (kind) of a chess piece.
///
pub enum Role with Eq, Order, ToString, Hash {
    case Pawn
    case Knight
    case Bishop
    case Rook
    case Queen
    case King
}

mod Role {

    ///
    /// The dense index of `r`, in `0..5`.
    ///
    /// Used as a table index (`Move.PSQT(role.index)`, `ZobristHash.hashPiece`)
    /// and inside `Move.score`, so the exact values matter.
    ///
    pub def index(r: Role): Int32 = match r {
        case Role.Pawn   => 0
        case Role.Knight => 1
        case Role.Bishop => 2
        case Role.Rook   => 3
        case Role.Queen  => 4
        case Role.King   => 5
    }

    ///
    /// The SAN symbol of `r`. Pawns have the empty symbol, exactly as in Scala.
    ///
    pub def symbol(r: Role): String = match r {
        case Role.Pawn   => ""
        case Role.Knight => "N"
        case Role.Bishop => "B"
        case Role.Rook   => "R"
        case Role.Queen  => "Q"
        case Role.King   => "K"
    }

    ///
    /// The inverse of `index`: `None` when `i` is out of `0..5`.
    ///
    /// Scala reaches for `Role.fromOrdinal`, which throws on a bad index; here
    /// the partiality is explicit.
    ///
    pub def fromIndex(i: Int32): Option[Role] = match i {
        case 0 => Some(Role.Pawn)
        case 1 => Some(Role.Knight)
        case 2 => Some(Role.Bishop)
        case 3 => Some(Role.Rook)
        case 4 => Some(Role.Queen)
        case 5 => Some(Role.King)
        case _ => None
    }

    ///
    /// All roles in index order, i.e. Scala's `Role.values`.
    ///
    pub def all(): List[Role] =
        Role.Pawn :: Role.Knight :: Role.Bishop :: Role.Rook :: Role.Queen :: Role.King :: Nil
}

///
/// A piece: a colour flag (`true` = white, matching the Scala `Boolean`) and a role.
///
pub enum Piece with Eq, Order, ToString, Hash {
    case Piece(Bool, Role)
}

mod Piece {

    ///
    /// `true` if the piece is white.
    ///
    pub def white(p: Piece): Bool =
        let Piece.Piece(w, _) = p;
        w

    ///
    /// The role of the piece.
    ///
    pub def role(p: Piece): Role =
        let Piece.Piece(_, r) = p;
        r
}
