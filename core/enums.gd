extends RefCounted
class_name AcqEnums
## Shared constants, enums, and coordinate helpers for the Acquire rules engine.
## Pure logic only — no UI, no networking. Everything cosmetic (names, colours)
## lives in ThemeDef; this file only holds the stable, rules-level identities.

# --- Board geometry ---------------------------------------------------------
const BOARD_WIDTH: int = 12
const BOARD_HEIGHT: int = 9
const TILE_COUNT: int = BOARD_WIDTH * BOARD_HEIGHT  # 108

# --- Rules constants --------------------------------------------------------
const CHAIN_COUNT: int = 7
const STOCK_PER_CHAIN: int = 25      # shares of each chain in the bank at start
const SAFE_SIZE: int = 11            # a chain this big can never be merged away
const END_GAME_SIZE: int = 41        # a chain this big lets a player end the game
const RACK_SIZE: int = 6             # tiles a player holds at once
const STARTING_CASH: int = 6000
const MAX_BUY_PER_TURN: int = 3      # shares a player may buy in one turn

# A board cell holds one of:
#   CELL_EMPTY            -> no tile placed
#   ChainId.NONE (-1)     -> a tile is placed but belongs to no chain ("lone")
#   ChainId.TOWER..CONTINENTAL (0..6) -> a tile belonging to that chain
const CELL_EMPTY: int = -2

## The seven hotel chains, grouped by price tier (cheap / medium / expensive).
## Logic refers to chains by these stable ids — never by display name, which is
## supplied by ThemeDef so the game can be re-skinned without touching rules.
enum ChainId {
	NONE = -1,
	# cheap tier
	TOWER,
	LUXOR,
	# medium tier
	AMERICAN,
	WORLDWIDE,
	FESTIVAL,
	# expensive tier
	IMPERIAL,
	CONTINENTAL,
}

## Phases of a single player's turn (drives the UI state machine).
enum GamePhase {
	SETUP,
	PLACE_TILE,      # current player must place a tile from their rack
	FOUND_CHAIN,     # placement founded a chain; player picks which one
	RESOLVE_MERGER,  # placement merged chains; resolve survivor + stock disposal
	BUY_STOCK,       # player may buy up to MAX_BUY_PER_TURN shares
	GAME_OVER,
}

## What happens when a tile is placed at a given cell. Computed BEFORE the tile
## is committed so the UI can react (popups) or refuse the placement.
enum PlacementKind {
	ISOLATED,        # no neighbours — becomes a lone tile
	FOUND,           # touches lone tile(s) and a chain slot is free — founds a chain
	GROW,            # touches exactly one chain — that chain grows
	MERGE,           # touches two or more chains — they merge
	ILLEGAL_DEAD,    # would merge two or more SAFE chains — permanently unplayable
	ILLEGAL_TEMP,    # would found a chain but all seven are already on the board
}

## Coordinate convention used everywhere: col is 0..11, row is 0..8.
## The human-facing label is column-number + row-letter, e.g. (6, 2) -> "7C".
static func tile_label(col: int, row: int) -> String:
	return "%d%s" % [col + 1, char(65 + row)]
