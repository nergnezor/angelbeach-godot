// MatchFilmer — the REAL match (full GameMode inherited) but with an automated
// camera trigger: a HighResShot every FilmInterval while a rally is live, then
// quit after MaxShots. Used to verify movement quality (approach, split step,
// dives, plants) from actual gameplay without a human at the editor. Launch:
//
//   UnrealEditor BeachVolleyball.uproject "/Game/CourtLevel?game=/Script/Angelscript.MatchFilmerGameMode" \
//       -game -RenderOffscreen -resx=1280 -resy=720 -log
class AMatchFilmerGameMode : ABeachVolleyballGameMode
{
	// Two cadences: BASE while the rally flows, BURST while something athletic is
	// happening (anyone airborne or diving). Bursts give consecutive frames close
	// enough to read as a flipbook — the only way stills can judge MOTION.
	float BaseInterval = 0.5f;
	float BurstInterval = 0.15f;
	int MaxShots = 120;

	private float FilmTimer = 0.0f;
	private int ShotIdx = 0;
	private bool bQuitScheduled = false;
	private TArray<AVolleyballPlayer> Players;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		Super::BeginPlay();
		// Shorter dead-ball pause: we're here to film rallies, not waiting.
		ServeDelay = 2.0f;

		TArray<AActor> Found;
		GetAllActorsOfClass(AVolleyballPlayer, Found);
		for (AActor A : Found)
		{
			AVolleyballPlayer P = Cast<AVolleyballPlayer>(A);
			if (P != nullptr) Players.Add(P);
		}
	}

	// Something worth a burst: any player airborne or diving.
	private bool IsActionHappening() const
	{
		for (AVolleyballPlayer P : Players)
		{
			if (!P.bIsGrounded || P.IsDiving())
				return true;
		}
		return false;
	}

	// A serve choreography in progress (toss -> strike happens BEFORE the rally
	// phase starts, so it needs its own filming window).
	private bool IsServeHappening() const
	{
		for (AVolleyballPlayer P : Players)
		{
			if (P.ServePhase > 0.001f)
				return true;
		}
		return false;
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaSeconds)
	{
		if (bQuitScheduled) return;
		if (Ball == nullptr) return;

		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		bool bServeShow = IsServeHappening();
		bool bRally = (GS != nullptr && GS.GamePhase == EGamePhase::Phase_Rally && Ball.bInPlay);
		if (!bRally && !bServeShow) return;

		bool bAction = IsActionHappening() || bServeShow;
		FilmTimer += DeltaSeconds;
		if (FilmTimer < (bAction ? BurstInterval : BaseInterval)) return;
		FilmTimer = 0.0f;

		ShotIdx++;
		// 100+idx keeps filenames zero-padded for sorting.
		FString ShotName = "Film_" + (100 + ShotIdx);
		System::ExecuteConsoleCommand("HighResShot 1280x720 filename=" + ShotName);
		Log("FILM shot=" + ShotName + " ballPos=(" + int(Ball.Position.X) + ","
			+ int(Ball.Position.Y) + "," + int(Ball.Position.Z) + ")"
			+ " touches=" + (GS != nullptr ? GS.TouchesThisRally : 0)
			+ (bServeShow ? " SERVE" : "")
			+ (bAction ? " BURST" : ""));

		if (ShotIdx >= MaxShots)
		{
			bQuitScheduled = true;
			Log("FILM done — quitting");
			System::SetTimer(this, n"QuitFilm", 2.0f, bLooping = false);
		}
	}

	UFUNCTION()
	void QuitFilm()
	{
		System::ExecuteConsoleCommand("quit");
	}
}
