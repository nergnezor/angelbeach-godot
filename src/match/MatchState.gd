# Scoring and phase — the port of Script/Match/GameState.as.
#
# Its own file, and a plain RefCounted rather than a node, because these are
# rules: no scene tree, no rendering, no RNG, nothing to tick. That makes them
# the one part of the match that can be checked by reading it. Match.gd owns the
# choreography; this owns what the choreography is worth.
#
# Rally scoring throughout — every rally is a point, and the winner of the rally
# serves next. That is what makes ServingTeam a function of who scored rather
# than a rotation.
extends RefCounted
class_name MatchState

enum Team { A = 0, B = 1, NONE = 2 }

enum Phase { PRE_GAME, SERVING, RALLY, POINT_SCORED, SET_OVER, MATCH_OVER }

# Sets 1 and 2 go to 21, a deciding third set to 15. Both still need two clear
# points, which is handled in add_point rather than here.
static func set_limit(set_number: int) -> int:
	return 15 if set_number >= 3 else 21

var score_a := 0
var score_b := 0
var sets_won_a := 0
var sets_won_b := 0
var current_set := 1
var serving_team: Team = Team.A
var phase: Phase = Phase.PRE_GAME
var winner: Team = Team.NONE

# Touches by the side currently in possession, capped at three.
var touches_this_rally := 0
var last_touch_team: Team = Team.NONE

func reset() -> void:
	score_a = 0
	score_b = 0
	sets_won_a = 0
	sets_won_b = 0
	current_set = 1
	serving_team = Team.A
	phase = Phase.PRE_GAME
	winner = Team.NONE
	touches_this_rally = 0
	last_touch_team = Team.NONE

func add_point(scoring_team: Team) -> void:
	if scoring_team == Team.A:
		score_a += 1
	else:
		score_b += 1

	# Rally scoring: the side that won the point serves the next one.
	serving_team = scoring_team
	phase = Phase.POINT_SCORED

	var limit := set_limit(current_set)
	var a_wins := score_a >= limit and (score_a - score_b) >= 2
	var b_wins := score_b >= limit and (score_b - score_a) >= 2

	if a_wins or b_wins:
		if a_wins:
			sets_won_a += 1
		else:
			sets_won_b += 1

		if sets_won_a >= 2 or sets_won_b >= 2:
			winner = Team.A if a_wins else Team.B
			phase = Phase.MATCH_OVER
		else:
			current_set += 1
			phase = Phase.SET_OVER
			score_a = 0
			score_b = 0
			# Sides switch every set, so the serve goes back to A on even counts.
			serving_team = Team.A if (sets_won_a + sets_won_b) % 2 == 0 else Team.B

	touches_this_rally = 0
	last_touch_team = Team.NONE

# Returns false when the touch is the fourth by the same side, which is the
# fault. The counter resets on a change of possession rather than on a crossing,
# so a block that stays on the blocker's side still starts their count over.
func register_touch(touching_team: Team) -> bool:
	if touching_team == last_touch_team:
		touches_this_rally += 1
		if touches_this_rally > 3:
			return false
	else:
		touches_this_rally = 1
		last_touch_team = touching_team
	return true

func start_rally() -> void:
	phase = Phase.RALLY
	touches_this_rally = 0
	last_touch_team = Team.NONE

func score_string() -> String:
	return "%d : %d" % [score_a, score_b]

func sets_string() -> String:
	return "Sets %d - %d" % [sets_won_a, sets_won_b]
