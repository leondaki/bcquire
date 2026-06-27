extends ThemeDef
class_name FantasyTheme
## Medieval/fantasy re-theming of Acquire. Chains renamed to fantasy kingdoms,
## colors adjusted to a rich, darker palette with golds and jewel tones.
## Terminology swapped to fit fantasy setting (Kingdoms instead of Corporations, etc.)

## --- Base palette (medieval aesthetic) ---
@export var color_background: Color = Color(0.08, 0.07, 0.09, 1.0)         # deep charcoal
@export var color_empty: Color = Color(0.18, 0.16, 0.20, 1.0)              # stone/slate
@export var color_lone_tile: Color = Color(0.64, 0.60, 0.48, 1.0)          # parchment
@export var color_hover: Color = Color(0.36, 0.32, 0.40, 1.0)              # highlighted stone
@export var color_placed: Color = Color(0.86, 0.72, 0.20, 1.0)             # bright gold (drop target)
@export var color_playable: Color = Color(0.98, 0.85, 0.30, 1.0)           # golden glow (legal squares)
@export var color_label: Color = Color(0.94, 0.90, 0.82, 1.0)              # cream/parchment text

## --- Per-chain identity (indexed by AcqEnums.ChainId) ---
@export var chain_names: PackedStringArray = PackedStringArray([
	"The Border Clans",         # 0 - Tower (military, gray/silver)
	"The Merchant Guild",       # 1 - Luxor (trade, gold)
	"The Suncrest Imperium",    # 2 - American (empire, bright gold/yellow)
	"The Moonlit Principality", # 3 - Worldwide (mystical, silver/blue)
	"The Vanguard Alliance",    # 4 - Festival (noble coalition, deep blue/purple)
	"The Golden Citadel",       # 5 - Imperial (wealth/prestige, gold)
	"The Obsidian Spire",       # 6 - Continental (ancient/dark, obsidian purple/black)
])

@export var chain_colors: PackedColorArray = PackedColorArray([
	Color(0.68, 0.72, 0.74),    # Border Clans     - steel gray
	Color(0.92, 0.78, 0.24),    # Merchant Guild   - merchant gold
	Color(0.98, 0.82, 0.18),    # Suncrest         - bright sun gold
	Color(0.76, 0.82, 0.92),    # Lunaria          - moonlit silver/blue
	Color(0.48, 0.58, 0.88),    # Vanguard         - noble blue/purple
	Color(0.96, 0.80, 0.20),    # Golden Citadel   - pure gold
	Color(0.42, 0.32, 0.62),    # Obsidian Spire   - dark obsidian purple
])

## --- Terminology replacements (fantasy setting) ---
@export var term_corporation: String = "Kingdom"
@export var term_stock: String = "Influence"
@export var term_stockholder: String = "Patron"
@export var term_money: String = "Gold"
@export var term_merger: String = "Annexation"
@export var currency_symbol: String = "G"

func chain_name(chain: int) -> String:
	if chain >= 0 and chain < chain_names.size():
		return chain_names[chain]
	return "—"

func chain_color(chain: int) -> Color:
	if chain >= 0 and chain < chain_colors.size():
		return chain_colors[chain]
	return color_lone_tile
