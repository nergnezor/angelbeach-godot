// PhotoBooth — automated pose-inspection mode for iterating on animation/IK
// WITHOUT a human at the editor. Launch with:
//
//   UnrealEditor BeachVolleyball.uproject "/Game/CourtLevel?game=/Script/Angelscript.PhotoBoothGameMode" \
//       -game -RenderOffscreen -resx=1280 -resy=720 -log
//
// It spawns ONE player and a frozen ball, steps through every hit pose, moves a
// camera around the player, takes a HighResShot per (pose, camera) and quits.
// Screenshots land in Saved/Screenshots/; a "BOOTH" log line per shot records
// hand-vs-ball / hand-vs-IK-target distances so images pair with numbers.

// The booth dummy never physically contacts the ball: poses place the ball
// inside catch radius on purpose, and a real contact would swing/knock it away
// mid-photo. (This also disables AutoReachForBall, so the booth's forced
// Reach() choice is exactly what gets photographed — fully deterministic.)
class APhotoBoothDummy : AVolleyballPlayer
{
	bool CanContactBall() const override { return false; }
}

// One pose to photograph: where the ball is held (relative to the player's
// FEET, in actor space: X=fwd, Y=right, Z=up) and which gesture to force.
struct FBoothPose
{
	FString Name;
	EHitType Type;
	bool bReach;          // false = neutral idle (no gesture)
	FVector BallOffset;
	// >= 0: freeze the serve choreography at this phase (Hit_Serve poses). The
	// ball is glued to the toss hand while the phase is pre-strike (< 0.78),
	// mirroring the real serve sequence; BallOffset is used after the strike.
	float ServePhase = -1.0f;
}

// One camera position: offset from the player's feet (actor space) + what
// point (relative to feet) to aim at.
struct FBoothCam
{
	FString Name;
	FVector Offset;
	FVector LookAt;
}

class APhotoBoothGameMode : AGameModeBase
{
	default GameStateClass = ABeachVolleyballGameState;
	default DefaultPawnClass = nullptr;
	// Engine base HUD: no score overlay on the photos.
	default HUDClass = AHUD;

	APhotoBoothDummy Dummy;
	ABall Ball;
	AActor CamActor;

	TArray<FBoothPose> Poses;
	TArray<FBoothCam> Cams;

	int PoseIdx = 0;
	int CamIdx = 0;
	// Phase 0 = pose settling (IK easing in), phase 1 = camera settled -> shoot,
	// phase 2 = hold still after the shot. HighResShot captures a few FRAMES after
	// the console command, so the camera must not move again until the capture has
	// happened — without the hold, every PNG shows the NEXT camera position.
	int Phase = 0;
	float PhaseTimer = 0.0f;
	// TSR/Lumen need a few frames after a camera cut before the image is clean.
	const float PoseSettle = 1.1f;
	const float CamSettle = 0.6f;
	const float ShotHold = 0.5f;
	bool bDone = false;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		BuildShotList();
		SetupWorld();
		System::SetTimer(this, n"AttachCamera", 0.1f, bLooping = false);
	}

	private void BuildShotList()
	{
		// Ball offsets chosen so the AUTO hit-type logic (were it active) would
		// agree with the forced type — these are the real in-game contact windows.
		FBoothPose P;

		P.Name = "idle";  P.Type = EHitType::Hit_None;  P.bReach = false;
		P.BallOffset = FVector(60, 500, 150);   // far away: tests head look-at only
		Poses.Add(P);

		P.Name = "bump";  P.Type = EHitType::Hit_Bump;  P.bReach = true;
		P.BallOffset = FVector(75, 0, 95);      // waist height in front
		Poses.Add(P);

		P.Name = "bump_low";  P.Type = EHitType::Hit_Bump;  P.bReach = true;
		P.BallOffset = FVector(55, 0, 60);      // very low: shows crouch depth
		Poses.Add(P);

		P.Name = "set";  P.Type = EHitType::Hit_Set;  P.bReach = true;
		P.BallOffset = FVector(20, 0, 205);     // above the forehead
		Poses.Add(P);

		P.Name = "spike";  P.Type = EHitType::Hit_Spike;  P.bReach = true;
		P.BallOffset = FVector(95, 0, 235);     // high in front (strike point)
		Poses.Add(P);

		P.Name = "spike_cock";  P.Type = EHitType::Hit_Spike;  P.bReach = true;
		P.BallOffset = FVector(95, 0, 420);     // ball still high: shows the loaded backswing
		Poses.Add(P);

		P.Name = "block";  P.Type = EHitType::Hit_Block;  P.bReach = true;
		P.BallOffset = FVector(140, 0, 255);    // high on the other side of the net line
		Poses.Add(P);

		// Serve choreography keyframes (ball glued to the toss hand pre-strike).
		P.Type = EHitType::Hit_Serve;  P.bReach = true;

		P.Name = "serve_toss";    P.ServePhase = 0.5f;   P.BallOffset = FVector(30, 5, 150);
		Poses.Add(P);
		P.Name = "serve_cock";    P.ServePhase = 0.72f;  P.BallOffset = FVector(26, 10, 202);  // ball hangs at toss apex
		Poses.Add(P);
		P.Name = "serve_strike";  P.ServePhase = 0.84f;  P.BallOffset = FVector(35, 10, 215);
		Poses.Add(P);
		P.Name = "serve_follow";  P.ServePhase = 0.97f;  P.BallOffset = FVector(160, 10, 230);
		Poses.Add(P);

		FBoothCam C;
		C.Name = "front34";  C.Offset = FVector(240, 190, 165);  C.LookAt = FVector(0, 0, 110);
		Cams.Add(C);
		C.Name = "side";     C.Offset = FVector(10, 320, 130);   C.LookAt = FVector(0, 0, 115);
		Cams.Add(C);
		C.Name = "front";    C.Offset = FVector(260, 0, 150);    C.LookAt = FVector(0, 0, 120);
		Cams.Add(C);
	}

	private void SetupWorld()
	{
		// Neutral, bright daylight straight overhead — pose reading beats mood here.
		ADirectionalLight Sun = Cast<ADirectionalLight>(
			SpawnActor(ADirectionalLight, FVector(0, 0, 10000), FRotator(-90, 0, 0)));
		if (Sun != nullptr)
		{
			UDirectionalLightComponent LC = Cast<UDirectionalLightComponent>(
				Sun.GetComponentByClass(UDirectionalLightComponent));
			if (LC != nullptr)
			{
				LC.SetIntensity(8.0f);
				LC.SetLightColor(FLinearColor(1.0f, 0.97f, 0.92f));
				LC.CastShadows = true;
				LC.SetAtmosphereSunLight(true);
			}
		}
		SpawnActor(ASkyAtmosphere, FVector::ZeroVector, FRotator::ZeroRotator);
		ASkyLight Sky = Cast<ASkyLight>(SpawnActor(ASkyLight, FVector(0, 0, 500), FRotator::ZeroRotator));
		if (Sky != nullptr)
		{
			USkyLightComponent SLC = Cast<USkyLightComponent>(Sky.GetComponentByClass(USkyLightComponent));
			if (SLC != nullptr) { SLC.SetRealTimeCapture(true); SLC.SetIntensity(1.8f); }
		}

		// Court gives ground + net context in frame.
		SpawnActor(ACourt, FVector::ZeroVector, FRotator::ZeroRotator);

		Dummy = Cast<APhotoBoothDummy>(SpawnActor(APhotoBoothDummy, FVector(-300, 0, 90), FRotator::ZeroRotator));
		if (Dummy != nullptr)
			Dummy.InitPlayer();

		Ball = Cast<ABall>(SpawnActor(ABall, FVector(-240, 500, 150), FRotator::ZeroRotator));

		CamActor = SpawnActor(ACameraActor, FVector(-60, 190, 165), FRotator::ZeroRotator);
	}

	UFUNCTION()
	void AttachCamera()
	{
		APlayerController PC = Gameplay::GetPlayerController(0);
		if (PC != nullptr && CamActor != nullptr)
			PC.SetViewTargetWithBlend(CamActor, 0.0f);
		MoveCam(0);
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaSeconds)
	{
		if (bDone || Dummy == nullptr || Ball == nullptr) return;
		if (PoseIdx >= Poses.Num()) return;

		FBoothPose Pose = Poses[PoseIdx];

		// Hold the ball at the pose position (re-frozen every frame — the ball's
		// own physics tick may nudge it a hair; this wins). Serve keyframes glue
		// the ball to the toss hand instead, exactly like the real sequence.
		FVector Feet = Dummy.GetActorLocation() - FVector(0, 0, Dummy.PlayerHeight);
		FVector Fwd = Dummy.GetActorForwardVector();
		FVector Right = Dummy.GetActorRightVector();
		FVector BallPos = Feet + Fwd * Pose.BallOffset.X + Right * Pose.BallOffset.Y
			+ FVector(0, 0, Pose.BallOffset.Z);
		if (Pose.ServePhase >= 0.0f && Pose.ServePhase < 0.6f && Dummy.Mesh != nullptr)
			BallPos = Dummy.Mesh.GetBoneTransform(n"hand_l").Location + FVector(0, 0, 16);
		Ball.Position = BallPos;
		Ball.BallVel = FVector::ZeroVector;
		Ball.SetActorLocation(BallPos);
		Ball.bInPlay = true;

		// Drive the pose. Reach() must be re-asserted every frame (it lapses),
		// and must run BEFORE UpdatePlayer so UpdateAnimation consumes it.
		Dummy.FacingDir = FVector(1, 0, 0);
		Dummy.bHasFacing = true;
		Dummy.ServePhase = Math::Max(Pose.ServePhase, 0.0f);
		if (Pose.bReach)
			Dummy.Reach(Pose.Type);
		Dummy.UpdatePlayer(DeltaSeconds);

		// Shot sequencing: settle pose -> settle camera -> shoot -> HOLD -> advance.
		PhaseTimer += DeltaSeconds;
		if (Phase == 0)
		{
			if (PhaseTimer >= PoseSettle)
			{
				MoveCam(CamIdx);
				Phase = 1;
				PhaseTimer = 0.0f;
			}
		}
		else if (Phase == 1)
		{
			if (PhaseTimer >= CamSettle)
			{
				Shoot(Pose);
				Phase = 2;
				PhaseTimer = 0.0f;
			}
		}
		else if (PhaseTimer >= ShotHold)
		{
			CamIdx++;
			PhaseTimer = 0.0f;
			if (CamIdx < Cams.Num())
			{
				MoveCam(CamIdx);
				Phase = 1;
			}
			else
			{
				CamIdx = 0;
				PoseIdx++;
				Phase = 0;
				if (PoseIdx >= Poses.Num())
				{
					bDone = true;
					Log("BOOTH done — quitting");
					// Give the last shot a beat to flush to disk before exit.
					System::SetTimer(this, n"QuitBooth", 1.5f, bLooping = false);
				}
			}
		}
	}

	private void MoveCam(int Idx)
	{
		if (CamActor == nullptr || Dummy == nullptr || Idx >= Cams.Num()) return;
		FBoothCam C = Cams[Idx];
		FVector Feet = Dummy.GetActorLocation() - FVector(0, 0, Dummy.PlayerHeight);
		FVector Fwd = Dummy.GetActorForwardVector();
		FVector Right = Dummy.GetActorRightVector();
		FVector Pos = Feet + Fwd * C.Offset.X + Right * C.Offset.Y + FVector(0, 0, C.Offset.Z);
		FVector Look = Feet + Fwd * C.LookAt.X + Right * C.LookAt.Y + FVector(0, 0, C.LookAt.Z);
		CamActor.SetActorLocation(Pos);
		CamActor.SetActorRotation((Look - Pos).GetSafeNormal().Rotation());
	}

	private void Shoot(FBoothPose Pose)
	{
		FString CamName = Cams[CamIdx].Name;
		FString ShotName = "Booth_" + Pose.Name + "_" + CamName;
		System::ExecuteConsoleCommand("HighResShot 1280x720 filename=" + ShotName);

		// Numeric companion to the image: did the hands actually get to the ball,
		// and does the skeleton follow the IK targets we asked for?
		if (Dummy.Mesh != nullptr && Dummy.Anim != nullptr)
		{
			FVector HandR = Dummy.Mesh.GetBoneTransform(n"hand_r").Location;
			FVector HandL = Dummy.Mesh.GetBoneTransform(n"hand_l").Location;
			Log("BOOTH shot=" + ShotName
				+ " handR_ball=" + int((HandR - Ball.Position).Size())
				+ " handL_ball=" + int((HandL - Ball.Position).Size())
				+ " handR_vs_target=" + int((HandR - Dummy.Anim.HandTargetR).Size())
				+ " handL_vs_target=" + int((HandL - Dummy.Anim.HandTargetL).Size())
				+ " ikAlpha=" + int(Dummy.Anim.IKAlpha * 100)
				+ " crouch=" + int(Dummy.Anim.CrouchAmount * 100));
			// Orientation ground truth: where the body actually points and where the
			// camera actually is, so image reading isn't guesswork. Head/pelvis X
			// give the torso's true world heading independent of actor yaw.
			FVector HeadB = Dummy.Mesh.GetBoneTransform(n"head").Location;
			FVector Pelv = Dummy.Mesh.GetBoneTransform(n"pelvis").Location;
			Log("BOOTH_ORIENT shot=" + ShotName
				+ " actorYaw=" + int(Dummy.GetActorRotation().Yaw)
				+ " camPos=(" + int(CamActor.GetActorLocation().X) + "," + int(CamActor.GetActorLocation().Y) + "," + int(CamActor.GetActorLocation().Z) + ")"
				+ " camYaw=" + int(CamActor.GetActorRotation().Yaw)
				+ " handR=(" + int(HandR.X) + "," + int(HandR.Y) + ")"
				+ " handL=(" + int(HandL.X) + "," + int(HandL.Y) + ")"
				+ " head=(" + int(HeadB.X) + "," + int(HeadB.Y) + "," + int(HeadB.Z) + ")"
				+ " pelvis=(" + int(Pelv.X) + "," + int(Pelv.Y) + "," + int(Pelv.Z) + ")");
		}
		else
		{
			Log("BOOTH shot=" + ShotName + " (no mesh/anim!)");
		}
	}

	UFUNCTION()
	void QuitBooth()
	{
		System::ExecuteConsoleCommand("quit");
	}
}
