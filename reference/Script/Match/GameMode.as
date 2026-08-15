// Beach Volleyball Game Mode - spawn, serve flow, scoring, match restart

class ABeachVolleyballGameMode : AGameModeBase
{
	UPROPERTY(BlueprintReadOnly)
	ABall Ball;

	UPROPERTY(BlueprintReadOnly)
	AHumanPlayer HumanPawn;  // Team A back — AI until gamepad input

	UPROPERTY(BlueprintReadOnly)
	AAIPlayer PlayerA2;  // Team A front

	UPROPERTY(BlueprintReadOnly)
	AAIPlayer PlayerB1;  // Team B back

	UPROPERTY(BlueprintReadOnly)
	AAIPlayer PlayerB2;  // Team B front

	UPROPERTY(BlueprintReadOnly)
	ACourt Court;

	UPROPERTY(BlueprintReadOnly)
	ASandFX SandFX;

	float MatchRestartDelay = 5.0f;

	default HUDClass = ABeachVolleyballHUD;
	default GameStateClass = ABeachVolleyballGameState;
	default DefaultPawnClass = nullptr;

	// Debug: global slow-motion so contact timing / animations are easy to read.
	// Set to 1.0 for normal speed.
	float TimeScale = 1.0f;

	// --- Mobile stand-ins for what Lumen gives desktop for free -----------------
	// Desktop is the reference look; these exist only to let mobile land on the same
	// image. Tune them against a real desktop capture, not by eye — and capture it at
	// FULL quality (MatchFilmer without -es31). The ES3.1 preview is a different
	// picture: it put the body average at (68,44,26) while the actual desktop build
	// renders (71,49,40) in the same shot, so tuning to the preview aims at the wrong
	// target. Mobile currently lands on (68,54,38) against that (71,49,40).
	const FLinearColor SandBounceColor         = FLinearColor(0.55f, 0.30f, 0.12f, 1.0f);
	const float        MobileSkyLightIntensity = 5.2f;
	// The SkyLight's UPPER hemisphere captures the dome, which is blue-violet, so a
	// plain intensity boost fills the bodies with cool light. Tinting the SkyLight warm
	// biases it back toward the sand-bounce cast desktop gets from Lumen. Measured on
	// device against the full-quality desktop body average (71,49,40), R/G 1.45:
	//   no tint          -> (56,50,38)  R/G 1.12
	//   (1.0,0.70,0.48)  -> (68,54,38)  R/G 1.26   <- this one
	//   (1.0,0.57,0.33)  -> (66,52,37)  R/G 1.27
	// Note the third row: pushing the tint further moved the body colour *not at all*.
	// Past this point the SkyLight is no longer what decides the body's hue — the
	// mannequin's own near-neutral albedo and the direct sun rim are — so don't reach
	// for a stronger tint here expecting a warmer body. Brightness lands on desktop's
	// number; the residual coolness in R/G would have to come out of the material or
	// the post-process, not this light.
	const FLinearColor MobileSkyLightTint      = FLinearColor(1.0f, 0.70f, 0.48f, 1.0f);

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		Gameplay::SetGlobalTimeDilation(TimeScale);
		SetupWorld();
		SpawnActors();
		StartMatch();
	}

	// Angelscript has no platform macro, so this is the single place that decides
	// what "mobile" means. Everything gated on it is a stand-in for a renderer
	// feature mobile lacks — never a different art direction. Also used by
	// ABeachVolleyballHUD to decide whether to draw the on-screen touch controls.
	UFUNCTION(BlueprintPure)
	bool IsMobilePlatform() const
	{
		FString P = Gameplay::GetPlatformName();
		return P == "Android" || P == "IOS";
	}

	private void SetupWorld()
	{
		// Sun: pitch -90 puts it straight overhead (noon), light travelling
		// straight down — yaw is irrelevant at the zenith. This replaces the
		// earlier low-sunset sun (pitch -6, warm backlit rim); see git history
		// if that mood needs to come back.
		//
		// THE SUN IS THE SAME ON EVERY PLATFORM. Under the old low sun, mobile
		// rendered the players as black silhouettes from the backlighting (body
		// average (12,8,5) on device against (68,44,26) on desktop) — that's
		// what SandBounceColor/MobileSkyLightTint below were built to fix. An
		// overhead sun lights the tops of the players directly on every
		// platform instead of backlighting them, so that specific failure mode
		// should no longer apply, but the mobile fill values were tuned against
		// the old sun angle and have not been re-measured against this one.
		bool bMobile = IsMobilePlatform();

		ADirectionalLight SunActor = Cast<ADirectionalLight>(
			SpawnActor(ADirectionalLight, FVector(0, 0, 10000), FRotator(-90, 0, 0)));
		if (SunActor != nullptr)
		{
			UDirectionalLightComponent LC = Cast<UDirectionalLightComponent>(
				SunActor.GetComponentByClass(UDirectionalLightComponent));
			if (LC != nullptr)
			{
				LC.SetIntensity(6.0f);                                 // bright enough; atmosphere adds glow
				LC.SetLightColor(FLinearColor(1.0f, 0.98f, 0.92f));   // neutral noon sun, not sunset-warm
				LC.CastShadows = true;
				LC.SetAtmosphereSunLight(true);                        // visible sun disc for the flare
			}
		}

		// SkyAtmosphere owns the sky: real sun disc (for the lens flare) plus the
		// sunset horizon-glow-to-blue gradient driven by the low sun above.
		SpawnActor(ASkyAtmosphere, FVector::ZeroVector, FRotator::ZeroRotator);

		// Surrounding environment: water plane beyond the sand (sky is the atmosphere).
		SpawnActor(AEnvironment, FVector::ZeroVector, FRotator::ZeroRotator);

		// SkyLight captures the sky for soft ambient fill so the court isn't black.
		ASkyLight SkyLightActor = Cast<ASkyLight>(
			SpawnActor(ASkyLight, FVector(0, 0, 500), FRotator::ZeroRotator));
		if (SkyLightActor != nullptr)
		{
			USkyLightComponent SLC = Cast<USkyLightComponent>(
				SkyLightActor.GetComponentByClass(USkyLightComponent));
			if (SLC != nullptr)
			{
				SLC.SetRealTimeCapture(true);
				// Raised alongside the -1.5 EV exposure cut. The cut is aimed at the
				// sun-lit sand that was clipping; without more ambient it would also
				// crush the players, who are dark-skinned meshes sitting in their own
				// shadow. More fill, less overall exposure: the sand comes down, the
				// bodies do not go to pure black.
				SLC.SetIntensity(bMobile ? MobileSkyLightIntensity : 3.0f);

				if (bMobile)
				{
					// MOBILE STANDS IN FOR LUMEN HERE.
					//
					// With the sun this low and behind the players, the only thing
					// lighting the side the camera sees is bounce off the sunlit sand.
					// Desktop gets that from Lumen GI; mobile has no GI at all, which is
					// the entire reason the bodies went black there.
					//
					// A SkyLight's lower hemisphere is a flat colour (black by default),
					// so it normally contributes nothing from below. Filling it with the
					// sand's own bounce colour is the standard approximation — the engine
					// says so itself in SkyLightComponent.h: "useful to approximate
					// skylight bounce lighting". One call, no per-frame cost, and it adds
					// exactly the missing term rather than a different look.
					//
					// The colour is the sand albedo (0.62,0.52,0.36 in Court.as) warmed by
					// the sun's own tint and scaled down to bounce strength — sand does not
					// return all of what hits it.
					SLC.SetLowerHemisphereColor(SandBounceColor);
					SLC.SetLightColor(MobileSkyLightTint);
				}
			}
		}

		// (Single directional light only — a second one triggers UE's "competing
		// directional lights" warning. The bright SkyLight fills the shadows.)

		AExponentialHeightFog FogActor = Cast<AExponentialHeightFog>(
			SpawnActor(AExponentialHeightFog, FVector(0, 0, 100), FRotator::ZeroRotator));
		if (FogActor != nullptr)
		{
			UExponentialHeightFogComponent FC = Cast<UExponentialHeightFogComponent>(
				FogActor.GetComponentByClass(UExponentialHeightFogComponent));
			if (FC != nullptr)
			{
				// Thin, distant haze only — NOT a thick coloured band over the court.
				// The previous dense volumetric fog read as smoke, not a sunset.
				//
				// On device the old start distance saturated everything past the
				// court to the inscattering colour: the sea, the far sand and the
				// sky all came out as the same flat cream. Pushing the start out to
				// 3500 clears the court and the near water (~2000-3000 from the
				// match camera), while everything further still fades to warm haze.
				// (That alone did NOT turn the sea blue — the water at that range is
				// unfogged and still rendered warm, because it is reflecting the
				// sky, and the sky was warm haze. Hence the SkyAtmosphere change.)
				//
				FC.SetFogDensity(0.002f);
				// Stretching the fog layer upward (falloff 0.5 -> 0.1) was an attempt
				// to make the fog double as the sky on Android, where SkyAtmosphere
				// was switched off. It did not work — the top of frame went from
				// (13,5,3) to (17,8,3), still black — and it made things worse for
				// the sea, because a taller layer means more fog along the near-
				// horizontal view rays that look at the water.
				//
				// Re-enabling SkyAtmosphere for Android did NOT bring a sky back —
				// the top of frame went (17,8,3) -> (7,2,1), i.e. still black and
				// slightly darker, since the falloff went the wrong way at the same
				// time. Mobile really does want an authored sky mesh, so the
				// original comment in AndroidEngine.ini was right after all.
				//
				// That leaves the fog as the sky whether we like it or not, so stop
				// fighting it and make the layer genuinely tall.
				//
				// Note the samples so far do NOT settle this on their own: falloff
				// 0.5 -> top (13,5,3), 0.2 -> (7,2,1), 0.1 -> (17,8,3) is not
				// monotonic, and those shots differ in aspect ratio, framing and
				// whether SkyAtmosphere was on, so "top of frame" is not even the
				// same piece of sky. What they do agree on is that every value in
				// that range leaves a black band, i.e. the seam stays in frame.
				// 0.02 is five times taller than the tallest tried, chosen to put
				// the seam decisively out of frame rather than to interpolate a
				// trend. Court level is unaffected: the fog still starts at 3500.
				FC.SetFogHeightFalloff(0.02f);
				// Was a warm (0.9,0.5,0.3) orange to match the old low sunset sun;
				// with the sun overhead there's no horizon glow to match, so this
				// substitute Android "sky" goes neutral midday blue instead.
				FC.SetFogInscatteringColor(FLinearColor(0.55f, 0.68f, 0.85f));
				FC.SetVolumetricFog(false);
				// Must stay OUTSIDE the sky dome (radius 5000 in Environment.as).
				// Fog saturates to its inscattering colour within a couple of
				// thousand units at this density, so anything it reaches turns warm
				// cream — that is what hid the sea for so long. With the dome now
				// providing the sky, fog has no job left except far-field haze, and
				// starting it past the dome keeps it from bleaching the gradient or
				// the water.
				FC.SetStartDistance(5200.0f);
				// Was warm to glow toward the low sunset sun disc; with the sun
				// at the zenith this glow isn't visible from a horizontal camera
				// anyway, so keep it neutral rather than falsely warm.
				FC.SetDirectionalInscatteringColor(FLinearColor(0.95f, 0.95f, 0.9f));
				FC.SetDirectionalInscatteringExponent(8.0f);
			}
		}

		APostProcessVolume PPV = Cast<APostProcessVolume>(
			SpawnActor(APostProcessVolume, FVector::ZeroVector, FRotator::ZeroRotator));
		if (PPV != nullptr)
		{
			PPV.bUnbound = true;
			PPV.Priority = 1.0f;
			FPostProcessSettings PP = PPV.Settings;
			PP.bOverride_BloomIntensity = true;
			PP.BloomIntensity = 0.8f;
			PP.bOverride_BloomThreshold = true;
			PP.BloomThreshold = 1.0f;
			// EXPOSURE — measured, not guessed. The scene was blowing out: sand
			// rendered (243,225,196) at albedo 0.93, and after dropping the albedo
			// by a third to 0.62 it still rendered (241,218,184). Linear red moved
			// 0.878 -> 0.880, i.e. not at all, which only happens when the surface
			// is clipping. Albedo was never the lever — the light was.
			//
			// Sand at 0.62 albedo wants to land near 0.35 linear (a proper tan), so
			// the scene needs about 0.56x the light it was getting. That is -1.5 EV,
			// hence +1.0 -> -0.5. Everything else falls out of clipping with it:
			// line paint and net tape stop being pure white, and the near-black net
			// cord finally reads as cord instead of grey.
			//
			// Nudged back up (-0.5 -> +0.25) now the sky dome exists. -1.5 EV was
			// measured against a scene lit partly by a very bright fog "sky"; the
			// dome that replaced it is darker, so the sky light bouncing off it is
			// weaker and the sand fell from 117 to 82 grey — muddy. This is about
			// +0.75 EV back, which puts the sand near 107 without going anywhere
			// near the clipping it started at.
			PP.bOverride_AutoExposureBias = true;
			PP.AutoExposureBias = 0.25f;
			PP.bOverride_AutoExposureMinBrightness = true;
			PP.AutoExposureMinBrightness = 0.5f;
			PP.bOverride_AutoExposureMaxBrightness = true;
			PP.AutoExposureMaxBrightness = 3.0f;
			// Lens flare on the bright sun disc.
			PP.bOverride_LensFlareIntensity = true;
			PP.LensFlareIntensity = 1.0f;
			PP.bOverride_LensFlareBokehSize = true;
			PP.LensFlareBokehSize = 3.0f;
			PP.bOverride_VignetteIntensity = true;
			PP.VignetteIntensity = 0.35f;
			PPV.Settings = PP;
		}

		SpawnActor(ABeachVolleyballCamera, FVector(0, -1400, 350), FRotator(0, 90, 0));
	}

	private void SpawnActors()
	{
		Court = Cast<ACourt>(SpawnActor(ACourt, FVector::ZeroVector, FRotator::ZeroRotator));
		SandFX = Cast<ASandFX>(SpawnActor(ASandFX, FVector::ZeroVector, FRotator::ZeroRotator));

		Ball = Cast<ABall>(SpawnActor(ABall, FVector(0, 0, 300), FRotator::ZeroRotator));
		if (Ball != nullptr)
		{
			Ball.Sand = SandFX;
			Ball.Court = Court;
			Ball.GM = this;
		}

		// Team A: back player = human-controlled (AI until gamepad input)
		HumanPawn = Cast<AHumanPlayer>(SpawnActor(AHumanPlayer, FVector(-600, 100, 90), FRotator::ZeroRotator));
		if (HumanPawn != nullptr)
		{
			HumanPawn.Sand = SandFX;
			HumanPawn.Court = Court;
			HumanPawn.GM = this;
			HumanPawn.Ball = Ball;

			// Possess so input bindings fire, then restore camera as ViewTarget
			APlayerController PC = Gameplay::GetPlayerController(0);
			if (PC != nullptr)
			{
				PC.Possess(HumanPawn);
				// Delay one frame so camera actor exists before we switch to it
				System::SetTimer(this, n"RestoreCamera", 0.05f, bLooping = false);

				// Hand the HUD its GameMode reference the same way Ball/HumanPawn
				// get theirs — there is no BlueprintCallable "get the game mode"
				// to pull it from the HUD side.
				ABeachVolleyballHUD BVHUD = Cast<ABeachVolleyballHUD>(PC.GetHUD());
				if (BVHUD != nullptr)
					BVHUD.GM = this;
			}
		}

		PlayerA2 = Cast<AAIPlayer>(SpawnActor(AAIPlayer, FVector(-150, -100, 90), FRotator::ZeroRotator));
		if (PlayerA2 != nullptr)
			PlayerA2.Setup(ETeam::Team_A, EPlayerRole::Role_Front, 0.80f, Ball, SandFX, Court, this);

		// Team B: back player deep right, front player near net right
		PlayerB1 = Cast<AAIPlayer>(SpawnActor(AAIPlayer, FVector(600, -100, 90), FRotator::ZeroRotator));
		if (PlayerB1 != nullptr)
		{
			PlayerB1.Setup(ETeam::Team_B, EPlayerRole::Role_Back, 0.75f, Ball, SandFX, Court, this);
			PlayerB1.bDebugAI = true;
			PlayerB1.bDebugHit = true;
		}

		PlayerB2 = Cast<AAIPlayer>(SpawnActor(AAIPlayer, FVector(150, 100, 90), FRotator::ZeroRotator));
		if (PlayerB2 != nullptr)
		{
			PlayerB2.Setup(ETeam::Team_B, EPlayerRole::Role_Front, 0.80f, Ball, SandFX, Court, this);
			PlayerB2.bDebugAI = true;
			PlayerB2.bDebugHit = true;
		}

		// Wire up teammates so AI can coordinate. HumanPawn is now an AAIPlayer,
		// so it pairs with PlayerA2 just like the Team B duo.
		if (PlayerA2 != nullptr && HumanPawn != nullptr) { PlayerA2.Teammate = HumanPawn; HumanPawn.Teammate = PlayerA2; }
		if (PlayerB1 != nullptr && PlayerB2 != nullptr) { PlayerB1.Teammate = PlayerB2; PlayerB2.Teammate = PlayerB1; }
	}

	private void StartMatch()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS != nullptr)
		{
			GS.ScoreA = 0;
			GS.ScoreB = 0;
			GS.SetsWonA = 0;
			GS.SetsWonB = 0;
			GS.CurrentSet = 1;
			GS.ServingTeam = ETeam::Team_A;
			GS.GamePhase = EGamePhase::Phase_PreGame;
			GS.MatchWinner = ETeam::Team_None;
		}
		ScheduleServe();
	}

	// Pause after a dead ball (point won / ball down) before the next serve, so
	// players can reset and the rally has a clear beat.
	float ServeDelay = 5.0f;

	private void ScheduleServe()
	{
		if (Ball == nullptr) return;
		Ball.bInPlay = false;
		System::SetTimer(this, n"ServeBall", ServeDelay, bLooping = false);
	}

	UFUNCTION(BlueprintCallable)
	void ServeBall()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr || Ball == nullptr) return;

		// Serve must clearly clear the 243cm net ~5-8m away: strong forward +
		// strong upward arc. The velocity is handed to the SERVING PLAYER, who
		// performs a real toss + overhead strike and launches the ball from the
		// strike point (see AAIPlayer.RunServeSequence). Rally bookkeeping happens
		// in OnServeLaunched at the strike moment.
		// Slightly floaty (780/640 rather than a flat rocket): the extra hang time
		// is what gives the receiver's FBIK arms time to converge on the platform —
		// rallies need the SERVE to be returnable, not an ace machine.
		FVector ServeVel;
		AAIPlayer Server;
		if (GS.ServingTeam == ETeam::Team_A)
		{
			ServeVel = FVector(780, Math::RandRange(-140.0f, 140.0f), 640);
			Server = HumanPawn;
		}
		else
		{
			ServeVel = FVector(-780, Math::RandRange(-140.0f, 140.0f), 640);
			Server = PlayerB1;
		}

		if (Server != nullptr)
		{
			Server.BeginServe(ServeVel);
		}
		else
		{
			// Fallback (server missing): old direct launch so the match never stalls.
			float Sign = (GS.ServingTeam == ETeam::Team_A) ? -1.0f : 1.0f;
			Ball.Launch(FVector(Sign * 800.0f, 0, 250), ServeVel);
			OnServeLaunched();
		}
	}

	// Called by the serving player at the strike moment (ball just went live).
	void OnServeLaunched()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;
		GS.StartRally();

		// Track the serve until it clears the net. A serve must go directly over —
		// if it hits the net or lands without crossing, it's a service fault.
		bServePhase = true;
		ServingTeamThisServe = GS.ServingTeam;

		// Fresh rally telemetry (see OnTouchForRally).
		RallyCrossings = 0;
		RallySeq = "";
	}

	// True from serve launch until the serve has crossed the net (or faulted).
	private bool bServePhase = false;
	private ETeam ServingTeamThisServe = ETeam::Team_None;

	// --- Rally telemetry -------------------------------------------------
	// The measurable definition of "they play volleyball": how many times the
	// ball crossed the net this rally, and the exact touch sequence (which team,
	// which touch number, which stroke). One RALLY line per rally at its end.
	private int RallyCrossings = 0;
	private FString RallySeq = "";

	private FString HitName(EHitType T) const
	{
		if (T == EHitType::Hit_Bump)  return "Bump";
		if (T == EHitType::Hit_Set)   return "Set";
		if (T == EHitType::Hit_Spike) return "Spike";
		if (T == EHitType::Hit_Block) return "Block";
		if (T == EHitType::Hit_Serve) return "Serve";
		return "?";
	}

	// Called by the player on every legal touch (RegisterHit).
	void OnTouchForRally(ETeam Team, int TouchNum, EHitType Type)
	{
		FString T = (Team == ETeam::Team_A) ? "A" : "B";
		RallySeq += " " + T + TouchNum + ":" + HitName(Type);
	}

	private void LogRallyEnd(FString Reason)
	{
		Log("RALLY end reason=" + Reason + " crossings=" + RallyCrossings
			+ " seq=[" + RallySeq + " ]");

		// Motion-quality totals per player, on the same hook, so every rally in a
		// headless run yields one comparable regression line per player.
		TArray<AVolleyballPlayer> MonPlayers;
		GetAllActorsOfClass(AVolleyballPlayer, MonPlayers);
		for (AVolleyballPlayer P : MonPlayers)
			if (P != nullptr) P.EmitMotionStats();

		RallyCrossings = 0;
		RallySeq = "";
	}

	// Called by the ball when it crosses the net plane, so we know the serve was good.
	UFUNCTION(BlueprintCallable)
	void OnBallCrossedNet()
	{
		bServePhase = false;
		RallyCrossings++;
	}

	UFUNCTION(BlueprintCallable)
	void OnBallHitFloor(FVector HitPos)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;
		if (GS.GamePhase != EGamePhase::Phase_Rally) return;

		ETeam ScoringTeam;
		if (bServePhase)
		{
			// Ball landed while still a serve = it never cleared the net = fault.
			// Point to the receiving team regardless of which side it landed on.
			bServePhase = false;
			ScoringTeam = (ServingTeamThisServe == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
			LogRallyEnd("serve_fault_floor");
		}
		else if (HitPos.X < 0)
		{
			ScoringTeam = ETeam::Team_B;
			LogRallyEnd("floor_A x=" + int(HitPos.X) + " y=" + int(HitPos.Y));
		}
		else
		{
			ScoringTeam = ETeam::Team_A;
			LogRallyEnd("floor_B x=" + int(HitPos.X) + " y=" + int(HitPos.Y));
		}

		GS.AddPoint(ScoringTeam);

		if (GS.GamePhase == EGamePhase::Phase_MatchOver)
		{
			if (Ball != nullptr)
				Ball.StartRestartCountdown(MatchRestartDelay);
		}
		else
		{
			ScheduleServe();
		}
	}

	UFUNCTION(BlueprintCallable)
	void OnBallHitNet()
	{
		// A serve that hits the net is a service fault — point to the receiving team.
		if (!bServePhase) return;
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr || GS.GamePhase != EGamePhase::Phase_Rally) return;

		bServePhase = false;
		ETeam Receiver = (ServingTeamThisServe == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
		LogRallyEnd("serve_net");
		GS.AddPoint(Receiver);
		ScheduleServe();
	}

	UFUNCTION(BlueprintCallable)
	void OnTouchViolation(ETeam FaultingTeam)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;

		LogRallyEnd((FaultingTeam == ETeam::Team_A) ? "touches_A" : "touches_B");
		ETeam ScoringTeam = (FaultingTeam == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
		GS.AddPoint(ScoringTeam);
		ScheduleServe();
	}

	UFUNCTION(BlueprintCallable)
	void ResetMatch()
	{
		StartMatch();
	}

	UFUNCTION()
	void RestoreCamera()
	{
		APlayerController PC = Gameplay::GetPlayerController(0);
		if (PC == nullptr) return;
		TArray<AActor> Found;
		GetAllActorsOfClass(ABeachVolleyballCamera, Found);
		if (Found.Num() > 0)
			PC.SetViewTargetWithBlend(Found[0], 0.0f);
	}
}
