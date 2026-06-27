extends ThemeDef
class_name FantasyTheme
## Medieval/fantasy re-theming of Acquire. Chains renamed to fantasy kingdoms,
## colors adjusted to a rich, darker palette with golds and jewel tones.
## Terminology swapped to fit fantasy setting (Kingdoms instead of Corporations, etc.)
##
## All themeable fields are already declared as @export vars on the parent
## ThemeDef, so this subclass only overrides their default values in _init()
## instead of re-declaring them (GDScript does not allow a child class to
## redeclare a member that already exists on its parent).

func _init() -> void:
	## --- Base palette (medieval aesthetic) ---
	color_background = Color(0.008, 0.07, 0.097, 1.0)         # deep charcoal
	color_empty = Color(0.18, 0.16, 0.20, 1.0)              # stone/slate
	color_lone_tile = Color(0.465, 0.368, 0.13, 1.0)          # parchment
	color_hover = Color(0.36, 0.32, 0.40, 1.0)              # highlighted stone
	color_placed = Color(0.86, 0.72, 0.20, 1.0)             # bright gold (drop target)
	color_playable = Color(0.98, 0.85, 0.30, 1.0)           # golden glow (legal squares)
	color_label = Color(0.94, 0.90, 0.82, 1.0)              # cream/parchment text

	## --- Per-chain identity (indexed by AcqEnums.ChainId) ---
	chain_names = PackedStringArray([
		"The Border Clans",         # 0 - Tower (military, gray/silver)
		"The Merchant Guild",       # 1 - Luxor (trade, gold)
		"The Suncrest Imperium",    # 2 - American (empire, bright gold/yellow)
		"The Moonlit Principality", # 3 - Worldwide (mystical, silver/blue)
		"The Vanguard Alliance",    # 4 - Festival (noble coalition, deep blue/purple)
		"The Golden Citadel",       # 5 - Imperial (wealth/prestige, gold)
		"The Obsidian Spire",       # 6 - Continental (ancient/dark, obsidian purple/black)
	])

	chain_colors = PackedColorArray([
		Color(0.65, 0.68, 0.72),    # Border Clans     - steel gray
		Color(0.85, 0.65, 0.15),    # Merchant Guild   - amber gold
		Color(0.80, 0.20, 0.18),    # Suncrest         - crimson red
		Color(0.20, 0.40, 0.78),    # Moonlit Princip. - deep blue
		Color(0.20, 0.55, 0.30),    # Vanguard         - forest green
		Color(0.55, 0.25, 0.65),    # Golden Citadel   - royal purple
		Color(0.15, 0.55, 0.58),    # Obsidian Spire   - dark teal
	])

	## --- Terminology replacements (fantasy setting) ---
	term_corporation = "Kingdom"
	term_stock = "Influence"
	term_stockholder = "Patron"
	term_money = "Gold"
	term_merger = "Annexation"
	currency_symbol = "G"
