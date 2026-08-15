// Beach volleyball ball - Euler physics, procedural sphere mesh, collision

class ABall : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UProceduralMeshComponent MeshComp;

	// Physics state (BallVel avoids clash with APawn::GetVelocity if ever reparented)
	FVector BallVel = FVector(0, 0, 0);
	FVector Position = FVector(0, 0, 300);

	const float Gravity = -980.0f;       // cm/s²
	const float BallRadius = 10.66f;     // Mikasa VLS300 / FIVB: 66-68cm circumference (~67cm -> d 21.3cm)
	const float Restitution = 0.75f;     // bounce coefficient
	const float AirDrag = 0.02f;         // drag per second (see StepPhysics scaling)
	const float FloorZ = 5.0f;           // floor collision height

	// Net geometry (set by Court)
	float NetX = 0.0f;
	float NetTopZ = 243.0f;              // regulation net height (243cm)
	float NetHalfThickness = 2.5f;

	bool bInPlay = false;

	// Brief lockout after a player contact so one touch doesn't register twice
	// while the ball is still overlapping the player.
	float PlayerHitCooldown = 0.0f;

	// References (set by GameMode)
	UPROPERTY()
	ASandFX Sand;
	UPROPERTY()
	ACourt Court;
	UPROPERTY()
	ABeachVolleyballGameMode GM;

	UFUNCTION(BlueprintCallable)
	void Launch(FVector Origin, FVector InitVel)
	{
		Position = Origin;
		BallVel = InitVel;
		SetActorLocation(Position);
		bInPlay = true;
	}

	UFUNCTION(BlueprintCallable)
	void HitBall(FVector ImpulseDir, float Speed)
	{
		BallVel = ImpulseDir.GetSafeNormal() * Speed;
	}

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		BuildSphereMesh();

		// Glowing yellow ball: drive the material colour with an HDR (>1) yellow so
		// it reads as self-lit and blooms, and attach a yellow point light so it
		// actually casts a warm glow on the court.
		UMaterialInterface BallMat = Cast<UMaterialInterface>(LoadObject(nullptr,
			"/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));
		if (BallMat != nullptr)
		{
			UMaterialInstanceDynamic MID = MeshComp.CreateDynamicMaterialInstance(0, BallMat);
			if (MID != nullptr)
				MID.SetVectorParameterValue(n"Color", FLinearColor(2.4f, 2.3f, 0.25f, 1.0f)); // HDR yellow (R≈G), glows
		}

		UPointLightComponent Glow = UPointLightComponent::Create(this);
		Glow.AttachToComponent(MeshComp);
		Glow.SetLightColor(FLinearColor(1.0f, 0.95f, 0.3f));
		Glow.SetIntensity(1500.0f);
		Glow.SetAttenuationRadius(350.0f);
		Glow.SetCastShadows(false);
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		if (!bInPlay)
			return;
		// Substep: a hitchy frame (HighResShot writes, shader compiles) can be
		// 0.3-0.5s — one Euler step that long tunnels the ball through floors,
		// nets and contact windows. Cap each physics step at 20ms.
		float Remaining = DeltaTime;
		while (Remaining > 0.0f)
		{
			float Step = Math::Min(Remaining, 0.02f);
			StepPhysics(Step);
			Remaining -= Step;
		}
		SetActorLocation(Position);
		UpdateSpin(DeltaTime);
	}

	// Roll the ball in its travel direction so the spin is visible. A ball moving
	// forward spins about the horizontal axis perpendicular to its velocity, at
	// angular speed v / radius. Purely visual (markings on the ball reveal it).
	// Uses AddActorLocalRotation each frame so spin accumulates without quaternion
	// math: pitch is "rolling forward" in the actor's local frame, and the actor's
	// yaw is aligned to the travel direction so the roll axis stays correct.
	private void UpdateSpin(float Dt)
	{
		FVector Flat = FVector(BallVel.X, BallVel.Y, 0);
		float FlatSpeed = Flat.Size();
		if (FlatSpeed < 5.0f) return;

		// Point the ball's local +X along travel (flat), then roll about local Y
		// (pitch) to make the surface move in the travel direction.
		float Yaw = Flat.Rotation().Yaw;
		float DegPerSec = (BallVel.Size() / (2.0f * PI * BallRadius)) * 360.0f;
		SpinAngle += DegPerSec * Dt;
		if (SpinAngle > 360.0f) SpinAngle -= 360.0f;

		SetActorRotation(FRotator(SpinAngle, Yaw, 0.0f));
	}

	private float SpinAngle = 0.0f;

	UFUNCTION()
	void OnRestartTimer()
	{
		if (GM != nullptr) GM.ResetMatch();
	}

	void StartRestartCountdown(float Delay)
	{
		System::SetTimer(this, n"OnRestartTimer", Delay, bLooping = false);
	}

	private void StepPhysics(float Dt)
	{
		if (PlayerHitCooldown > 0.0f)
			PlayerHitCooldown -= Dt;

		// Apply gravity
		BallVel.Z += Gravity * Dt;

		// Air drag — AirDrag is a per-second fraction, scaled by Dt so it's
		// frame-rate independent. (It used to be applied per frame, ~0.21/s at
		// 60fps, which braked serves so hard they fell short of the net.)
		float Speed = BallVel.Size();
		if (Speed > 0.1f)
			BallVel -= BallVel.GetSafeNormal() * Speed * AirDrag * Dt;

		// Integrate position (remember where we were for the net-plane test —
		// reconstructing it from velocity with a fixed 0.016 step missed real
		// crossings whenever the frame time differed, leaving bServePhase stuck
		// and misattributing rally endings as serve faults).
		float PrevX = Position.X;
		Position += BallVel * Dt;

		// Player body/arm collision — ball physically bounces off players
		CheckPlayerCollision();

		// Floor collision
		if (Position.Z - BallRadius <= FloorZ)
		{
			FVector ImpactVel = BallVel;
			float vDown = Math::Max(0.0f, -BallVel.Z);

			Position.Z = FloorZ + BallRadius;
			BallVel.Z = -BallVel.Z * Restitution;
			BallVel.X *= 0.85f;
			BallVel.Y *= 0.85f;

			if (vDown > 60.0f)
			{
				float Strength = Math::Clamp(vDown / 500.0f, 0.2f, 3.0f);
				FVector Ground = FVector(Position.X, Position.Y, 0.0f);
				if (Sand != nullptr)
					Sand.Burst(Ground, ImpactVel, Strength);
				if (Court != nullptr)
					Court.DeformSand(Ground, 28.0f + Strength * 22.0f, 5.0f + Strength * 9.0f);
			}

			if (GM != nullptr)
				GM.OnBallHitFloor(Position);
		}

		CheckNetCollision(PrevX);
	}

	// Bounce the ball off any player whose arm region it overlaps. The player
	// decides the outgoing velocity (hit type, aim, arc) in OnBallContact.
	private void CheckPlayerCollision()
	{
		if (PlayerHitCooldown > 0.0f) return;

		TArray<AActor> Players;
		GetAllActorsOfClass(AVolleyballPlayer, Players);

		for (AActor A : Players)
		{
			AVolleyballPlayer P = Cast<AVolleyballPlayer>(A);
			if (P == nullptr) continue;

			// A player who just touched the ball is transparent until someone
			// else touches it — enforces "no two contacts in a row".
			if (!P.CanContactBall())
				continue;

			// Ball only bounces off hands/forearms now.
			FVector Center;
			if (!P.GetArmContact(Position, BallRadius, Center))
				continue;

			// Contact: let the player compute the bounce from real physics.
			FVector NewVel = P.OnBallContact(Position, BallVel, Center);
			if (NewVel.SizeSquared() > 1.0f)
				BallVel = NewVel;

			// Push the ball just outside the limb so it doesn't stick.
			float Reach = 18.0f + BallRadius;
			FVector Out = (Position - Center).GetSafeNormal();
			if (Out.SizeSquared() < 0.01f) Out = FVector(0, 0, 1);
			Position = Center + Out * (Reach + 1.0f);

			PlayerHitCooldown = 0.25f;
			break;  // only one contact per frame
		}
	}

	private void CheckNetCollision(float PrevX)
	{
		if ((PrevX < NetX) != (Position.X < NetX))
		{
			if (Position.Z < NetTopZ + BallRadius)
			{
				// Hit the net.
				BallVel.X = -BallVel.X * 0.3f;
				Position.X = (Position.X < NetX)
					? NetX - NetHalfThickness - BallRadius
					: NetX + NetHalfThickness + BallRadius;

				if (GM != nullptr)
					GM.OnBallHitNet();
			}
			else
			{
				// Cleared the net cleanly — tell the GM (a serve is now good).
				if (GM != nullptr)
					GM.OnBallCrossedNet();
			}
		}
	}

	private void BuildSphereMesh()
	{
		TArray<FVector> Verts;
		TArray<int32> Tris;
		TArray<FVector> Normals;
		TArray<FVector2D> UVs;
		TArray<FLinearColor> Colors;
		TArray<FVector2D> NoUV;
		TArray<FProcMeshTangent> Tangents;

		int Stacks = 12;
		int Slices = 16;
		float R = BallRadius;

		for (int i = 0; i <= Stacks; i++)
		{
			float Phi = PI * i / Stacks;
			for (int j = 0; j <= Slices; j++)
			{
				float Theta = 2.0f * PI * j / Slices;
				FVector N = FVector(
					Math::Sin(Phi) * Math::Cos(Theta),
					Math::Sin(Phi) * Math::Sin(Theta),
					Math::Cos(Phi)
				);
				Verts.Add(N * R);
				Normals.Add(N);
				UVs.Add(FVector2D(float(j) / Slices, float(i) / Stacks));
				Colors.Add(FLinearColor(1, 1, 1, 1));
			}
		}

		for (int i = 0; i < Stacks; i++)
		{
			for (int j = 0; j < Slices; j++)
			{
				int A = i * (Slices + 1) + j;
				int B = A + 1;
				int C = A + Slices + 1;
				int D = C + 1;
				Tris.Add(A); Tris.Add(C); Tris.Add(B);
				Tris.Add(B); Tris.Add(C); Tris.Add(D);
			}
		}

		MeshComp.CreateMeshSection_LinearColor(0, Verts, Tris, Normals, UVs,
			NoUV, NoUV, NoUV, Colors, Tangents, true);
	}

	FVector PredictLanding(float MaxTime = 3.0f) const
	{
		FVector PPos = Position;
		FVector PVel = BallVel;
		float Dt = 0.05f;
		float T = 0;

		while (T < MaxTime)
		{
			PVel.Z += Gravity * Dt;
			PPos += PVel * Dt;
			T += Dt;
			if (PPos.Z <= FloorZ + BallRadius)
				return PPos;
		}
		return PPos;
	}
}
