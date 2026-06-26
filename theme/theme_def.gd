extends Resource
class_name ThemeDef
## All cosmetic / themeable configuration in one place. UI scenes read ONLY from
## the active ThemeDef; the core rules engine never imports it. Re-skinning the
## game (e.g. for the Steam release) means authoring a new .tres + art folder and
## pointing the game at it — gameplay code is untouched.
##
## Chains are addressed by their stable AcqEnums.ChainId index (0..6). The arrays
## below are indexed the same way, so swapping the names/colours here re-themes
## the board, the founding popup, and the stock cards all at once.

## --- Board layout ---
@export var board_width: int = 12
@export var board_height: int = 9
@export var tile_size: Vector2 = Vector2(52, 52)

## --- Base palette ---
@export var color_background: Color = Color(0.09, 0.10, 0.13, 1.0)
@export var color_empty: Color = Color(0.16, 0.18, 0.22, 1.0)        # empty board cell
@export var color_lone_tile: Color = Color(0.55, 0.58, 0.64, 1.0)    # placed, no chain
@export var color_hover: Color = Color(0.30, 0.34, 0.42, 1.0)
@export var color_placed: Color = Color(0.20, 0.55, 0.85, 1.0)       # drop-target highlight
@export var color_playable: Color = Color(0.92, 0.82, 0.28, 1.0)     # current player's legal squares
@export var color_label: Color = Color(0.92, 0.94, 0.97, 1.0)

## --- Per-chain identity (indexed by AcqEnums.ChainId) ---
@export var chain_names: PackedStringArray = PackedStringArray([
	"Tower", "Luxor", "American", "Worldwide", "Festival", "Imperial", "Continental",
])
@export var chain_colors: PackedColorArray = PackedColorArray([
	Color(0.95, 0.78, 0.20),  # Tower      - gold
	Color(0.85, 0.30, 0.25),  # Luxor      - red
	Color(0.22, 0.48, 0.86),  # American   - blue
	Color(0.52, 0.36, 0.66),  # Worldwide  - purple
	Color(0.30, 0.66, 0.42),  # Festival   - green
	Color(0.92, 0.56, 0.20),  # Imperial   - orange
	Color(0.22, 0.64, 0.70),  # Continental- teal
])

func chain_name(chain: int) -> String:
	if chain >= 0 and chain < chain_names.size():
		return chain_names[chain]
	return "—"

func chain_color(chain: int) -> Color:
	if chain >= 0 and chain < chain_colors.size():
		return chain_colors[chain]
	return color_lone_tile
