extends PanelContainer
class_name StockCard
## A small "share certificate" card representing the stock a player holds in one
## chain. Fully theme-driven: the chain's colour and display name come from
## ThemeDef, so re-skinning the game restyles the cards automatically.
##
## Price is the headline figure (the number that matters most when deciding
## whether to buy/sell/hold) — held-share count is a small corner badge, not
## the focal point. Also reused as a purely illustrative chain icon (e.g.
## ui/game/game.gd's _build_dispose_actions(), which sets count to a fixed
## 2/1 to diagram a 2-for-1 trade rather than showing a real holding).

func setup(chain: int, count: int, price: int, theme_def: ThemeDef) -> void:
	var col := theme_def.chain_color(chain)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col.darkened(0.55)
	sb.border_color = col
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	add_theme_stylebox_override("panel", sb)
	custom_minimum_size = Vector2(104, 78)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	add_child(box)

	var name_lbl := Label.new()
	name_lbl.text = theme_def.chain_name(chain)
	name_lbl.add_theme_color_override("font_color", col.lightened(0.4))
	name_lbl.add_theme_font_size_override("font_size", 14)
	box.add_child(name_lbl)

	var price_lbl := Label.new()
	price_lbl.text = "%s%d" % [theme_def.currency_symbol, price]
	price_lbl.add_theme_color_override("font_color", theme_def.color_label)
	price_lbl.add_theme_font_size_override("font_size", 24)
	box.add_child(price_lbl)

	# Share count: a small badge in the bottom-right corner, not the headline.
	var bottom := HBoxContainer.new()
	box.add_child(bottom)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	var count_lbl := Label.new()
	count_lbl.text = "x%d" % count
	count_lbl.add_theme_color_override("font_color", theme_def.color_label.darkened(0.2))
	count_lbl.add_theme_font_size_override("font_size", 12)
	bottom.add_child(count_lbl)
