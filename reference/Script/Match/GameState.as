// Beach Volleyball Game State - rally scoring, phase management

enum ETeam
{
	Team_A = 0,
	Team_B = 1,
	Team_None = 2
}

enum EGamePhase
{
	Phase_PreGame,
	Phase_Serving,
	Phase_Rally,
	Phase_PointScored,
	Phase_SetOver,
	Phase_MatchOver
}

// Set scoring limits per volleyball rules: sets 1-2 to 21, deciding set to 15
int GetSetLimit(int SetNumber)
{
	if (SetNumber >= 3)
		return 15;
	return 21;
}

class ABeachVolleyballGameState : AGameStateBase
{
	UPROPERTY(BlueprintReadOnly)
	int ScoreA = 0;

	UPROPERTY(BlueprintReadOnly)
	int ScoreB = 0;

	UPROPERTY(BlueprintReadOnly)
	int SetsWonA = 0;

	UPROPERTY(BlueprintReadOnly)
	int SetsWonB = 0;

	UPROPERTY(BlueprintReadOnly)
	int CurrentSet = 1;

	UPROPERTY(BlueprintReadOnly)
	ETeam ServingTeam = ETeam::Team_A;

	UPROPERTY(BlueprintReadOnly)
	EGamePhase GamePhase = EGamePhase::Phase_PreGame;

	UPROPERTY(BlueprintReadOnly)
	ETeam MatchWinner = ETeam::Team_None;

	// Touches per side in current rally (max 3)
	int TouchesThisRally = 0;
	ETeam LastTouchTeam = ETeam::Team_None;

	void AddPoint(ETeam ScoringTeam)
	{
		if (ScoringTeam == ETeam::Team_A)
			ScoreA++;
		else
			ScoreB++;

		ServingTeam = ScoringTeam;
		GamePhase = EGamePhase::Phase_PointScored;

		int Limit = GetSetLimit(CurrentSet);

		bool AWins = ScoreA >= Limit && (ScoreA - ScoreB) >= 2;
		bool BWins = ScoreB >= Limit && (ScoreB - ScoreA) >= 2;

		if (AWins || BWins)
		{
			if (AWins) SetsWonA++;
			else SetsWonB++;

			if (SetsWonA >= 2 || SetsWonB >= 2)
			{
				MatchWinner = AWins ? ETeam::Team_A : ETeam::Team_B;
				GamePhase = EGamePhase::Phase_MatchOver;
			}
			else
			{
				CurrentSet++;
				GamePhase = EGamePhase::Phase_SetOver;
				ScoreA = 0;
				ScoreB = 0;
				// Switch sides every set
				ServingTeam = (SetsWonA + SetsWonB) % 2 == 0 ? ETeam::Team_A : ETeam::Team_B;
			}
		}

		TouchesThisRally = 0;
		LastTouchTeam = ETeam::Team_None;
	}

	bool RegisterTouch(ETeam TouchingTeam)
	{
		if (TouchingTeam == LastTouchTeam)
		{
			TouchesThisRally++;
			if (TouchesThisRally > 3)
				return false; // Fault: too many touches
		}
		else
		{
			TouchesThisRally = 1;
			LastTouchTeam = TouchingTeam;
		}
		return true;
	}

	void StartRally()
	{
		GamePhase = EGamePhase::Phase_Rally;
		TouchesThisRally = 0;
		LastTouchTeam = ETeam::Team_None;
	}

	FString GetScoreString() const
	{
		return "" + ScoreA + " : " + ScoreB;
	}

	FString GetSetsString() const
	{
		return "Sets " + SetsWonA + " - " + SetsWonB;
	}
}
