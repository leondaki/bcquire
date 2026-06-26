extends RefCounted
class_name StockMarket
## The classic Acquire stock price chart and majority/minority bonus rules.
## Pure functions of (chain, size) — no state. Prices depend on the chain's
## price tier (which group it belongs to) and the chain's current tile count.
##
## Price chart (per share), by size bracket and tier:
##
##   size  | cheap | medium | expensive
##   ------+-------+--------+----------
##     2   |  200  |  300   |   400
##     3   |  300  |  400   |   500
##     4   |  400  |  500   |   600
##     5   |  500  |  600   |   700
##    6-10 |  600  |  700   |   800
##   11-20 |  700  |  800   |   900
##   21-30 |  800  |  900   |  1000
##   31-40 |  900  | 1000   |  1100
##    41+  | 1000  | 1100   |  1200
##
## Majority shareholder bonus = 10x the share price; minority = 5x.

## Price tier of a chain: 0 = cheap, 1 = medium, 2 = expensive.
static func tier_of(chain: int) -> int:
	match chain:
		AcqEnums.ChainId.TOWER, AcqEnums.ChainId.LUXOR:
			return 0
		AcqEnums.ChainId.AMERICAN, AcqEnums.ChainId.WORLDWIDE, AcqEnums.ChainId.FESTIVAL:
			return 1
		_:
			return 2  # IMPERIAL, CONTINENTAL

## Current price of one share of `chain` given its `size` (tile count).
## A chain smaller than 2 isn't really on the market and is priced at 0.
static func price(chain: int, size: int) -> int:
	if size < 2:
		return 0
	var bracket: int
	if size == 2:
		bracket = 0
	elif size == 3:
		bracket = 1
	elif size == 4:
		bracket = 2
	elif size == 5:
		bracket = 3
	elif size <= 10:
		bracket = 4
	elif size <= 20:
		bracket = 5
	elif size <= 30:
		bracket = 6
	elif size <= 40:
		bracket = 7
	else:
		bracket = 8
	# Base column (cheap tier) is 200 + 100 per bracket; each higher tier adds 100.
	return 200 + bracket * 100 + tier_of(chain) * 100

static func majority_bonus(chain: int, size: int) -> int:
	return price(chain, size) * 10

static func minority_bonus(chain: int, size: int) -> int:
	return price(chain, size) * 5
