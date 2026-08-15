// Base player pawn — movement, jump, physical ball contact, IK targets,
// and skeletal (Manny) body. Drives UVolleyballAnimInstance (see PlayerAnim.as).

class AVolleyballPlayer : APawn
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCapsuleComponent Capsule;

	UPROPERTY(DefaultComponent, Attach = Capsule)
	USkeletalMeshComponent Mesh;

	// Team identity, as a ring drawn on the sand under the player.
	//
	// It is a ring and not a coloured jersey because the body isn't just untinted
	// on Android, it's unlit — pure (0,0,0) at the torso in a device screenshot,
	// while the sky/sand next to it are lit correctly (see ApplyTeamMaterial).
	// Rather than keep guessing inside a material that cannot be opened here, put
	// the team colour on geometry we control, using the same procedural mesh +
	// BasicShapeMaterial path that already works for the court, the net and the
	// sky.
	UPROPERTY(DefaultComponent, Attach = Capsule)
	UProceduralMeshComponent TeamRing;

	// The ring is built once at construction, so editing TeamRingColor() would not show
	// up on players that already exist — hot reload swaps code, it does not re-run
	// construction. Holding the material instance and the colour last pushed to it lets
	// UpdatePlayer notice a changed return value and repaint, so colour edits are live.
	UMaterialInstanceDynamic RingMID;
	FLinearColor AppliedRingColor = FLinearColor(-1, -1, -1, -1);

	float MoveSpeed = 450.0f;
	// PLAYER gravity is ~2x earth (the ball keeps real -980): with real g the
	// tuned jump heights hung airborne ~1.5s and read as moon-floating. Heavy
	// player gravity + scaled jump speeds is the standard trick for snappy,
	// athletic jumps — rise ~70cm reactive / ~115cm loaded, air time ~0.7s.
	float JumpVelocity = 520.0f;
	float Gravity = -1900.0f;

	FVector PlayerVelocity = FVector::ZeroVector;
	bool bIsGrounded = true;
	float FloorZ = 0.0f;
	float PlayerHeight = 90.0f;

	// Single source of truth for body facing. AI/look code sets a desired facing
	// direction (flat); UpdatePlayer smoothly turns the actor toward it ONCE per
	// frame. This avoids multiple SetActorRotation callers fighting each other,
	// which caused jerky spinning (especially around jumps).
	FVector FacingDir = FVector(1, 0, 0);
	bool bHasFacing = false;
	private float FacingHoldTimer = 0.0f;   // facing requests lapse on this
	// Rate-limited FacingDir: the raw target the AI recomputes wholesale every
	// reaction tick (a close/fast ball can swing its bearing through a wide
	// angle in one tick); this is what the rotation and turn-run alignment
	// actually track, so the body is never asked to reverse turn direction
	// instantaneously when the raw target crosses to the other side.
	private FVector SmFacingDir = FVector(1, 0, 0);
	const float FacingDirMaxTurnRate = 300.0f;   // deg/s — limits the TARGET
	// Ceiling on how fast the BODY itself may rotate (deg/s). Distinct from the
	// above, which only ever limited where the body was aiming. Measured peak
	// before this existed: 1239 deg/s, median 566.
	const float BodyMaxTurnRate = 450.0f;
	// The one rate-limited facing target that all three sources feed through.
	private FVector SmWantDir;
	// Committed turn direction (signed degrees, last frame's Delta) — breaks
	// the near-180° shortest-path tie deterministically instead of by float
	// noise. See the rotation block in UpdatePlayer.
	private float RotDirBias = 0.0f;

	ETeam TeamSide = ETeam::Team_A;
	bool bCanHit = true;
	float HitCooldown = 0.4f;
	float HitTimer = 0.0f;

	float CourtMinX = -900.0f;
	float CourtMaxX = -5.0f;
	float CourtMinY = -450.0f;
	float CourtMaxY = 450.0f;

	UPROPERTY() ASandFX Sand;
	UPROPERTY() ACourt Court;
	UPROPERTY() ABeachVolleyballGameMode GM;

	private float StepTimer = 0.0f;
	private float ReachTimer = 0.0f;
	private FVector ReachDir = FVector(0, 0, 1);

	// Animation: we write state into this each frame; the Anim Blueprint blends.
	// Anim and CurrentHit are public so the IK mixin module (PlayerIK.as) can read
	// the current hit type and write the computed effector targets into the AnimInstance.
	UVolleyballAnimInstance Anim;
	EHitType CurrentHit = EHitType::Hit_None;
	private float HitAnimTimer = 0.0f;
	private float HitAnimDuration = 0.65f;  // hit pose swings up and back over this time

	void InitPlayer()
	{
		FloorZ = 0.0f;
		SetupMesh();
	}

	private void SetupMesh()
	{
		if (Mesh == nullptr) return;

		// Use SKM_Manny_Simple (the renderable SkeletalMesh) copied into the project.
		// NOTE: SK_Mannequin is the *Skeleton* asset, not a mesh — don't load that.
		// All bundled template anim clips reference this skeleton, so they play
		// without retargeting.
		USkeletalMesh SkMesh = Cast<USkeletalMesh>(LoadObject(nullptr,
			"/Game/Characters/Mannequins/Meshes/SKM_Manny_Simple.SKM_Manny_Simple"));
		if (SkMesh == nullptr)
		{
			// The local template copy originated in UE 5.6. On a strict mobile
			// loader it can fail before its packages have been re-saved in UE 5.7.
			// MoverExamples is enabled for this project and supplies the matching,
			// current-engine Manny mesh as a safe runtime fallback.
			//
			// Verified 2026-08-02 that Android does NOT take this path — removing it
			// entirely changed nothing on device, so the /Game mesh does load there.
			// Worth knowing if this is ever suspected again: under match lighting this
			// fallback mesh renders near-black (torso (2,1,0) vs (68,44,26)), so if it
			// ever DOES get taken it looks like a bug in its own right.
			Log("VolleyballPlayer: project Manny mesh unavailable; trying MoverExamples copy");
			SkMesh = Cast<USkeletalMesh>(LoadObject(nullptr,
				"/MoverExamples/Characters/Mannequins/Meshes/SKM_Manny_Simple.SKM_Manny_Simple"));
		}
		if (SkMesh == nullptr)
		{
			// Content not found — keep player visible with a fallback box
			Log("VolleyballPlayer: both Manny mesh load paths failed; using fallback box");
			Print("VolleyballPlayer: Manny mesh failed to load, using fallback box", Duration = 8.0f);
			SpawnFallbackBox();
			return;
		}

		Mesh.SkeletalMeshAsset = SkMesh;

		// Stand the mesh on the capsule floor and face along +X
		Mesh.SetRelativeLocation(FVector(0, 0, -PlayerHeight));
		Mesh.SetRelativeRotation(FRotator(0, -90, 0));

		// Use a blended Animation Blueprint when available (preferred — gives
		// idle/walk/run blendspace + jump/fall + bump/set/spike montages), and
		// fall back to the raw Angelscript anim instance otherwise so the game
		// still runs before the Anim BP is authored in the editor.
		Mesh.SetAnimationMode(EAnimationMode::AnimationBlueprint);

		UClass AnimBP = Cast<UClass>(LoadObject(nullptr,
			"/Game/Characters/Mannequin/ABP_VolleyballPlayer.ABP_VolleyballPlayer_C"));
		if (AnimBP != nullptr)
			Mesh.SetAnimInstanceClass(AnimBP);
		else
			Mesh.SetAnimInstanceClass(UVolleyballAnimInstance);

		Anim = Cast<UVolleyballAnimInstance>(Mesh.GetAnimInstance());

		// Tint per-team via the body material's vertex/param if available
		ApplyTeamMaterial();
		BuildTeamRing();
	}

	// Flat annulus on the sand in the player's team colour.
	private void BuildTeamRing()
	{
		const int Segs = 24;
		const float RInner = 42.0f;
		const float ROuter = 58.0f;

		TArray<FVector> V; TArray<int32> T; TArray<FVector> N;
		TArray<FVector2D> UV; TArray<FLinearColor> C;
		TArray<FVector2D> NoUV; TArray<FProcMeshTangent> Tan;

		for (int i = 0; i < Segs; i++)
		{
			float A = 2.0f * PI * i / Segs;
			float Cx = Math::Cos(A);
			float Sy = Math::Sin(A);
			V.Add(FVector(Cx * RInner, Sy * RInner, 0));
			V.Add(FVector(Cx * ROuter, Sy * ROuter, 0));
		}

		for (int i = 0; i < Segs; i++)
		{
			int A0 = i * 2;
			int B0 = ((i + 1) % Segs) * 2;
			T.Add(A0); T.Add(B0);     T.Add(B0 + 1);
			T.Add(A0); T.Add(B0 + 1); T.Add(A0 + 1);
			// Reverse winding as well, so it reads from above whichever way the
			// front face ends up pointing.
			T.Add(A0); T.Add(B0 + 1); T.Add(B0);
			T.Add(A0); T.Add(A0 + 1); T.Add(B0 + 1);
		}

		FLinearColor Col = TeamRingColor();
		for (int i = 0; i < V.Num(); i++)
		{
			N.Add(FVector(0, 0, 1));
			UV.Add(FVector2D(0, 0));
			C.Add(Col);
		}

		TeamRing.CreateMeshSection_LinearColor(0, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);
		TeamRing.SetCastShadow(false);

		// Same helper as ACourt/AEnvironment, copied rather than shared: this fork
		// compiles each .as file as its own module, so a global function is only
		// visible inside its own file.
		UMaterialInterface Base = Cast<UMaterialInterface>(LoadObject(nullptr,
			"/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));
		if (Base != nullptr)
		{
			RingMID = TeamRing.CreateDynamicMaterialInstance(0, Base);
			if (RingMID != nullptr)
			{
				RingMID.SetVectorParameterValue(n"Color", Col);
				AppliedRingColor = Col;
			}
		}
	}

	// Repaint the ring when TeamRingColor() starts returning something else, which is
	// what makes a hot-reloaded colour edit visible on players that are already on court.
	private void RefreshTeamRingColor()
	{
		if (RingMID == nullptr)
			return;

		FLinearColor Want = TeamRingColor();
		if (Want.R == AppliedRingColor.R && Want.G == AppliedRingColor.G
			&& Want.B == AppliedRingColor.B && Want.A == AppliedRingColor.A)
			return;

		RingMID.SetVectorParameterValue(n"Color", Want);
		AppliedRingColor = Want;
	}

	// Pre-divided by the measured per-channel light gain (0.314,0.162,0.067) — see
	// the long note in Environment.as. Blue reaches the screen at 21% of red under
	// this sunset, so an honest blue would read as grey; 3.0 in the blue channel is
	// what it costs to actually look blue. Red is lifted too, but less, since it
	// needs no help getting through.
	private FLinearColor TeamRingColor() const
	{
		return (TeamSide == ETeam::Team_A)
			? FLinearColor(0.10f, 0.60f, 3.00f, 1)
			: FLinearColor(1.60f, 0.25f, 0.15f, 1);
	}

	// Visible placeholder so a player is never invisible if the mesh can't load
	private void SpawnFallbackBox()
	{
		UStaticMeshComponent Box = UStaticMeshComponent::Create(this);
		Box.AttachToComponent(Capsule);
		UStaticMesh Cube = Cast<UStaticMesh>(LoadObject(nullptr,
			"/Engine/BasicShapes/Cube.Cube"));
		if (Cube != nullptr)
		{
			Box.SetStaticMesh(Cube);
			Box.SetRelativeScale3D(FVector(0.4f, 0.6f, 1.7f));
			Box.SetRelativeLocation(FVector(0, 0, 0));
			UMaterialInterface BaseMat = Box.GetMaterial(0);
			if (BaseMat != nullptr)
			{
				UMaterialInstanceDynamic MID = Box.CreateDynamicMaterialInstance(0, BaseMat);
				if (MID != nullptr)
					MID.SetVectorParameterValue(n"Color", TeamColor());
			}
		}
	}

	private void ApplyTeamMaterial()
	{
		if (Mesh == nullptr) return;

		// Keep the mesh's OWN imported materials (MI_Manny_01/02_New) and only tint
		// them. They were suspected for a long time of being broken on Android —
		// several builds replaced them with the engine DefaultMaterial, and one with
		// a custom mobile-safe material authored just for this. None of that was
		// necessary: measured on device, a trivial custom material and the stock one
		// land within noise of each other (body max (121,82,46) vs (114,82,53)). The
		// bodies were black because almost no light reached the side of them the
		// camera sees — see the sun-aiming note in GameMode.as::SetupWorld.
		//
		// THE PARAMETER IS "Paint Tint", WITH THE SPACE (read off the assets, not
		// guessed: SKM_Manny_Simple uses MI_Manny_01_New and MI_Manny_02_New;
		// MI_Manny_01_New is a child of M_Mannequin and overrides "Paint Tint").
		// Setting a parameter that does not exist is a silent no-op, not an error,
		// which is how two earlier wrong names went unnoticed.
		int NumSlots = Mesh.GetNumMaterials();
		for (int i = 0; i < NumSlots; i++)
		{
			UMaterialInterface SlotMat = Mesh.GetMaterial(i);
			if (SlotMat == nullptr) continue;

			UMaterialInstanceDynamic MID = Mesh.CreateDynamicMaterialInstance(i, SlotMat);
			if (MID != nullptr)
				MID.SetVectorParameterValue(n"Paint Tint", TeamBodyTint());
		}
	}

	// Kept close to the material's own default (0.92 grey) on purpose. "Paint Tint"
	// MULTIPLIES the body texture, so the HDR values TeamColor() uses would crush or
	// blow out the texture and hand back the flat silhouette this whole exercise was
	// about. Team identity is carried by TeamRing on the sand; this is only a hint.
	private FLinearColor TeamBodyTint() const
	{
		return (TeamSide == ETeam::Team_A)
			? FLinearColor(0.74f, 0.88f, 1.06f, 1)
			: FLinearColor(1.06f, 0.84f, 0.76f, 1);
	}

	void UpdatePlayer(float DeltaTime)
	{
		// Pin the team ring to the sand. It hangs off the capsule so it follows the
		// player around, but the capsule also rises on a jump, and a marker ring
		// floating at head height would read as a bug rather than as a shadow.
		// Cancelling the actor's Z keeps it flat on the beach at all times.
		TeamRing.SetRelativeLocation(FVector(0, 0, 2.0f - GetActorLocation().Z));
		RefreshTeamRingColor();

		// Crouch release runs FIRST, before any writer: with the decay at the
		// end of the frame it subtracted from what dive/tuck/split-step had
		// just asserted and ExtraCrouch sawtoothed ±0.04 at frame rate — the
		// universal residual the jitter monitor kept catching. Decay first,
		// writers last, the final value each frame is the writer's.
		//
		// TWO CHANNELS with different lifetimes (see the declarations):
		//  - ExtraCrouch (frame-rate transients: split step, dive, jump load,
		//    land absorb, air tuck) decays EVERY frame. Its writers run every
		//    frame while active, so decay-then-rewrite reproduces the envelope
		//    exactly and the value falls the instant the envelope stops.
		//  - HeldCrouch (tick-rate AI stance via RequestCrouch) is HELD across
		//    the reaction-tick gap and only decays once the hold lapses.
		// The old single channel gave the transients the HELD lifetime too: a
		// split-step peak Max()-ed in while a stance hold was live could not
		// decay until the hold gap — and the gaps land on ball events — so the
		// knee stuck deep through the approach and popped up at the meet. The
		// two are re-combined by Max at the read site, so the deepest legitimate
		// request still wins; only the STUCK residual is gone.
		ExtraCrouch = Math::Max(0.0f, ExtraCrouch - 2.5f * DeltaTime);
		CrouchHoldTimer -= DeltaTime;
		if (CrouchHoldTimer <= 0.0f)
			HeldCrouch = Math::Max(0.0f, HeldCrouch - 2.5f * DeltaTime);

		// Dive overrides input; otherwise ease velocity toward the stored input.
		UpdateDive(DeltaTime);
		UpdateJumpLoad(DeltaTime);
		if (!IsDiving())
			ApplyMoveInput(DeltaTime);

		// Gravity
		if (!bIsGrounded)
			PlayerVelocity.Z += Gravity * DeltaTime;

		bool bWasGrounded = bIsGrounded;
		float FallSpeed = -PlayerVelocity.Z;

		FVector NewLoc = GetActorLocation() + PlayerVelocity * DeltaTime;

		// Floor clamp
		if (NewLoc.Z <= FloorZ + PlayerHeight)
		{
			NewLoc.Z = FloorZ + PlayerHeight;
			PlayerVelocity.Z = 0;
			bIsGrounded = true;
		}

		// Court bounds
		NewLoc.X = Math::Clamp(NewLoc.X, CourtMinX, CourtMaxX);
		NewLoc.Y = Math::Clamp(NewLoc.Y, CourtMinY, CourtMaxY);

		SetActorLocation(NewLoc);

		// Sand FX + landing absorption: knees flex on touchdown, deeper after a
		// bigger fall — a stiff-legged landing is both unphysical and unreadable.
		FVector Feet = FVector(NewLoc.X, NewLoc.Y, 0.0f);
		if (bIsGrounded && !bWasGrounded && FallSpeed > 120.0f)
		{
			float Strength = Math::Clamp(FallSpeed / 600.0f, 0.3f, 1.6f);
			if (Sand != nullptr) Sand.Footstep(Feet, Strength * 1.4f);
			if (Court != nullptr) Court.DeformSand(Feet, 24.0f, 4.0f + Strength * 6.0f);
			LandAbsorbTimer = 0.3f;
			LandAbsorbDepth = Math::Clamp(FallSpeed / 900.0f, 0.3f, 0.7f);
		}
		if (LandAbsorbTimer > 0.0f)
		{
			LandAbsorbTimer -= DeltaTime;
			ExtraCrouch = Math::Max(ExtraCrouch, LandAbsorbDepth * (LandAbsorbTimer / 0.3f));
		}

		// Airborne attack tuck: knees come up through the ascent of a spike or
		// block jump (release on the way down) — legs trail dead otherwise.
		if (!bIsGrounded && PlayerVelocity.Z > -100.0f
			&& (CurrentHit == EHitType::Hit_Spike || CurrentHit == EHitType::Hit_Block))
		{
			ExtraCrouch = Math::Max(ExtraCrouch, 0.35f);
		}
		if (bIsGrounded)
		{
			float HSpeed = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
			if (HSpeed > 80.0f)
			{
				StepTimer += DeltaTime;
				float Interval = Math::Clamp(120.0f / HSpeed, 0.18f, 0.5f);
				if (StepTimer >= Interval)
				{
					StepTimer = 0.0f;
					if (Sand != nullptr) Sand.Footstep(Feet, 0.5f);
					if (Court != nullptr) Court.DeformSand(Feet, 16.0f, 3.0f);
				}
			}
			else StepTimer = 0.0f;
		}

		// Hit cooldown
		if (!bCanHit)
		{
			HitTimer += DeltaTime;
			if (HitTimer >= HitCooldown) { bCanHit = true; HitTimer = 0; }
		}

		if (ReachTimer > 0.0f) ReachTimer -= DeltaTime;

		// Auto-reach: whenever the ball is close and I'm allowed to play it, hold
		// the arms out toward it (pose chosen by height) so the gesture is a held
		// motion regardless of AI role. The AI's Reach() can still override type.
		AutoReachForBall();

		// SINGLE rotation authority. Prefer the AI's desired facing (e.g. toward the
		// ball); otherwise face the travel direction so locomotion reads correctly.
		// Always a smooth lerp — never a snap — so the body never jerks.
		// A facing request HOLDS for a beat (same lapse pattern as Reach/crouch):
		// the AI only re-asserts every reaction tick (~0.1s), and clearing the
		// request per frame made the rotation target alternate ball-facing on
		// tick frames / travel-facing between them — a visible two-pose shimmer.
		//
		// FacingDir ITSELF is rate-limited before use (SmFacingDir): the AI
		// recomputes it whole-cloth from the live ball bearing every reaction
		// tick, and a close/fast ball can swing that bearing through a large
		// angle in one tick. The body's lerp toward Want is already smooth,
		// but a smooth chase of a TARGET that itself teleports still reverses
		// the output turn direction the instant the target crosses to the
		// other side — the exact yaw-rate-sign-flip the motion monitor was
		// still catching after every source-side (bTurnRun) dwell fix. Rate-
		// limiting the target directly removes the reversal at its root
		// instead of chasing which system supplied it.
		if (FacingDir.SizeSquared() > 0.01f)
		{
			float CurYaw = SmFacingDir.Rotation().Yaw;
			float TargetYaw = FacingDir.Rotation().Yaw;
			float Step = Math::Clamp(Math::FindDeltaAngleDegrees(CurYaw, TargetYaw),
				-FacingDirMaxTurnRate * DeltaTime, FacingDirMaxTurnRate * DeltaTime);
			SmFacingDir = FRotator(0.0f, CurYaw + Step, 0.0f).Vector();
		}

		float HSpeed2 = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
		if (bHasFacing)
			FacingHoldTimer = 0.2f;
		else
			FacingHoldTimer -= DeltaTime;

		UpdateTurnRun(DeltaTime);

		FVector RawWant = FVector::ZeroVector;
		if (bTurnRun)
			// Face the commanded travel (the intent), not the lagging velocity:
			// the turn starts the same frame the run does. Demand ≥ 0.35 while
			// engaged, so this is never a degenerate direction.
			RawWant = FVector(MoveInput.X, MoveInput.Y, 0);
		else if (FacingHoldTimer > 0.0f && FacingDir.SizeSquared() > 0.01f)
			RawWant = FVector(SmFacingDir.X, SmFacingDir.Y, 0);
		else if (HSpeed2 > 30.0f)
			RawWant = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);

		// ALL THREE SOURCES pass through one rate-limited target, not just the
		// held-request one. Only src=1 was smoothed before, so the two unsmoothed
		// paths (velocity, turn-and-run) and — worse — every SWITCH between the
		// three handed the body a target that had teleported. Measured over 142
		// flips: none sat near the 180° band RotDirBias guards, the sources were
		// churning 65/45/32 between themselves instead. Smoothing the SELECTED
		// target makes a source change a continuous move rather than a step.
		if (RawWant.SizeSquared() > 0.01f)
		{
			if (SmWantDir.SizeSquared() < 0.01f) SmWantDir = RawWant.GetSafeNormal2D();
			float CurWantYaw = SmWantDir.Rotation().Yaw;
			float NewWantYaw = RawWant.Rotation().Yaw;
			float WStep = Math::Clamp(Math::FindDeltaAngleDegrees(CurWantYaw, NewWantYaw),
				-FacingDirMaxTurnRate * DeltaTime, FacingDirMaxTurnRate * DeltaTime);
			SmWantDir = FRotator(0.0f, CurWantYaw + WStep, 0.0f).Vector();
		}
		FVector Want = SmWantDir;

		if (Want.SizeSquared() > 0.01f)
		{
			// Manual yaw step instead of a fresh LerpShortestPath every frame.
			// CONFIRMED (YFLIP telemetry, dt rock-steady ~1ms — not a frame-
			// pacing artifact): near an exact 180° turn, "shortest path" is
			// numerically DEGENERATE — clockwise and counter-clockwise are
			// equally short, so a fraction of a degree of float noise in Cur
			// or Want flips which way LerpShortestPath picks, reversing the
			// output rotation direction between two adjacent frames at full
			// rate. Once a turn is committed to a direction, keep going that
			// way through the ambiguous zone (RotDirBias) instead of letting
			// each frame re-decide "shortest" from scratch.
			FRotator Cur = GetActorRotation();
			float TargetYaw = Want.Rotation().Yaw;
			float Delta = Math::FindDeltaAngleDegrees(Cur.Yaw, TargetYaw);
			bool bDeltaPos = Delta >= 0.0f;
			bool bBiasPos = RotDirBias >= 0.0f;
			if (Math::Abs(RotDirBias) > 1.0f && Math::Abs(Math::Abs(Delta) - 180.0f) < 15.0f
				&& bDeltaPos != bBiasPos)
				Delta = bDeltaPos ? Delta - 360.0f : Delta + 360.0f;
			if (Math::Abs(Delta) > 1.0f) RotDirBias = Delta;

			// Proportional approach with an ATHLETIC CEILING. The gain alone is
			// uncapped: a 180° error yields 180*8 = 1440 deg/s on the first frame,
			// and the live telemetry measured a 566 deg/s median and 1239 deg/s
			// peak — four times FacingDirMaxTurnRate, which only ever limited the
			// target. A human pivoting hard manages roughly 400-500 deg/s; past
			// that the body reads as a turret, not a player. Same shape the crouch
			// sink argues for: proportional so micro-corrections stay micro, with
			// the cap only catching the outliers.
			float Alpha = Math::Clamp(8.0f * DeltaTime, 0.0f, 1.0f);
			float Step = Delta * Alpha;
			float MaxStep = BodyMaxTurnRate * DeltaTime;
			Step = Math::Clamp(Step, -MaxStep, MaxStep);
			SetActorRotation(FRotator(Cur.Pitch, Cur.Yaw + Step, Cur.Roll));
		}
		// Debug attribution for YFLIP (see UpdateMotionMonitor): which source
		// picked this frame's facing target, and what it pointed at.
		DbgFacingSrc = bTurnRun ? 2 : ((FacingHoldTimer > 0.0f && FacingDir.SizeSquared() > 0.01f) ? 1 : 0);
		DbgWantYaw = (Want.SizeSquared() > 0.01f) ? Want.Rotation().Yaw : DbgWantYaw;
		bHasFacing = false;   // requests lapse via FacingHoldTimer above

		UpdatePredictedMeet();
		UpdateAnimation(DeltaTime, HSpeed2);
		UpdateMotionMonitor(DeltaTime);
	}

	// Feed movement + hit state into the AnimInstance. The Anim Blueprint reads
	// these and does the actual blending in its AnimGraph.
	private void UpdateAnimation(float DeltaTime, float HSpeed)
	{
		GestureAge += DeltaTime;

		// Decay the swing timer. Keep CurrentHit set until the pose has fully
		// relaxed (below) so the arm doesn't snap to neutral mid-gesture.
		if (HitAnimTimer > 0.0f)
		{
			HitAnimTimer -= DeltaTime;
			if (HitAnimTimer < 0.0f) HitAnimTimer = 0.0f;
		}

		if (Anim == nullptr)
		{
			if (Mesh != nullptr)
				Anim = Cast<UVolleyballAnimInstance>(Mesh.GetAnimInstance());
			if (Anim == nullptr) return;
		}

		// Local-space velocity so the Anim BP can blend fwd/back/strafe directionally
		FVector Fwd   = GetActorForwardVector();
		FVector Right = GetActorRightVector();
		FVector FlatVel = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);

		Anim.Speed         = HSpeed;
		Anim.ForwardSpeed  = FlatVel.DotProduct(Fwd);
		Anim.StrafeSpeed   = FlatVel.DotProduct(Right);
		// Travel-vs-facing angle for an orientation-aware blendspace. Only updated
		// while actually moving: recomputing it from near-zero velocity sprayed
		// noise, and holding the last heading keeps the blend continuous through
		// stops. With the turn-and-run override this stays near 0 during real
		// runs; the residual backpedal/shuffle band is what the ABP can now blend.
		if (HSpeed > 30.0f)
			Anim.MoveDirAngle = Math::Atan2(Anim.StrafeSpeed, Anim.ForwardSpeed) * (180.0f / PI);
		// HYSTERESIS: a single threshold made bIsMoving flip every frame when
		// the speed hovered at the boundary (deceleration, hold drift), and the
		// Anim BP popped between the idle and locomotion poses at frame rate.
		bMovingState = bMovingState ? (HSpeed > 30.0f) : (HSpeed > 70.0f);
		Anim.bIsMoving     = bMovingState;
		Anim.bIsInAir      = !bIsGrounded;
		Anim.VerticalSpeed = PlayerVelocity.Z;
		Anim.bDiving       = IsDiving();

		Anim.bIsHitting = HitAnimTimer > 0.0f || bReaching;
		Anim.HitType    = CurrentHit;

		// Head tracks the ball: always look at it while it's in play, so every
		// player keeps their eyes on the ball. The Anim BP drives a Look At node on
		// the head bone toward LookTarget with weight LookAlpha.
		{
			ABall LB = GetWorldBall();
			if (LB != nullptr && LB.bInPlay)
			{
				Anim.LookTarget = LB.Position;
				Anim.LookAlpha  = 1.0f;
			}
			else
			{
				Anim.LookAlpha  = 0.0f;   // no ball to watch — relax to neutral
			}
		}

		// Two phases:
		//  - REACHING: while waiting for the ball, hold the arms extended toward
		//    it (steady pose) so the hands/forearms are where the ball arrives.
		//  - SWING: at contact, a 0->1->0 envelope swings the arms through.
		float TargetPose;
		if (HitAnimTimer > 0.0f)
		{
			float Progress = (HitAnimDuration > 0.0f)
				? 1.0f - Math::Clamp(HitAnimTimer / HitAnimDuration, 0.0f, 1.0f)
				: 0.0f;
			TargetPose = Math::Sin(Progress * PI);   // 0..1..0 swing
		}
		else if (bReaching)
		{
			TargetPose = 0.85f;   // hold arms extended, ready
		}
		else
		{
			TargetPose = 0.0f;    // arms relax to neutral
		}

		// Smoothly ease the actual pose toward the target so arms move fluidly
		// instead of snapping between reach / swing / neutral each frame.
		float Speed = (TargetPose > CurrentPose) ? 14.0f : 8.0f;  // reach fast, relax slower
		float Alpha = Math::Clamp(Speed * DeltaTime, 0.0f, 1.0f);
		CurrentPose = CurrentPose + (TargetPose - CurrentPose) * Alpha;

		// IK Alpha and pose SHAPE are separate concerns. The IK node should apply
		// (nearly) fully whenever we're gesturing, so the hands actually reach the
		// targets — NOT scaled by CurrentPose, or we'd double-dampen (40% reach *
		// 40% IK = 16% visible motion, which read as "arms barely move").
		// CurrentPose instead drives only the ready->contact SHAPE inside
		// UpdateIKTargets. We ramp IKAlpha quickly to 1 once any gesture starts.
		float TargetIK = (CurrentPose > 0.02f) ? 1.0f : 0.0f;
		float IKSpeed = (TargetIK > IKWeight) ? 12.0f : 6.0f;
		IKWeight = IKWeight + (TargetIK - IKWeight) * Math::Clamp(IKSpeed * DeltaTime, 0.0f, 1.0f);

		Anim.HitAlpha = CurrentPose;
		Anim.IKAlpha  = IKWeight;
		// Pose shape uses the full 0..1 gesture curve, remapped so even the 0.85
		// reach hold reaches the contact shape (reach should look committed).
		float Shape = Math::Clamp(CurrentPose / 0.85f, 0.0f, 1.0f);
		this.UpdateIKTargets(Shape, DeltaTime);   // mixin in PlayerIK.as

		// Once the gesture has fully relaxed and we're no longer hitting/reaching,
		// release the hit type so the next contact can pick a fresh one. The
		// release respects the same dwell as Reach — a release/re-reach cycle
		// is just as much a flicker as a type swap.
		if (HitAnimTimer <= 0.0f && !bReaching && CurrentPose < 0.02f
			&& CurrentHit != EHitType::Hit_None && GestureAge >= MinGestureDwell)
		{
			CurrentHit = EHitType::Hit_None;
			GestureAge = 0.0f;
		}

		// Per-attempt summary tracking: while gesturing, remember how close the hand
		// actually got to the ball. Emit ONE line when the attempt ends — far less
		// noise than per-frame, and it answers the real question: did the hand reach
		// the ball, and did it score a contact? The serve gesture is excluded: the
		// server "chasing" his own departing serve polluted the miss statistics.
		if (CurrentPose > 0.05f && CurrentHit != EHitType::Hit_Serve)
		{
			ABall TB = GetWorldBall();
			if (TB != nullptr && TB.bInPlay && Mesh != nullptr)
			{
				bAttemptActive = true;
				float DR = (TB.Position - Mesh.GetBoneTransform(n"hand_r").Location).Size();
				float DL = (TB.Position - Mesh.GetBoneTransform(n"hand_l").Location).Size();
				float D = Math::Min(DR, DL);
				if (D < AttemptClosest)
				{
					AttemptClosest = D;
					// Record body vs ball gap at the closest moment, split into
					// horizontal vs vertical so we can tell WHY the hand misses:
					// big horiz = standing beside it; big vert = ball too high/low.
					FVector Loc = GetActorLocation();
					AttemptHoriz = (Loc - FVector(TB.Position.X, TB.Position.Y, 0)).Size2D();
					AttemptVert  = TB.Position.Z - (Loc.Z + PlayerHeight);  // + above head
					AttemptPose  = CurrentPose;
					AttemptIK    = IKWeight;
					// Facing error: angle between where we look and where the ball is.
					FVector ToBallFlat = FVector(TB.Position.X - Loc.X, TB.Position.Y - Loc.Y, 0).GetSafeNormal();
					AttemptFacing = GetActorForwardVector().DotProduct(ToBallFlat);  // 1=facing, -1=away
					// THE decisive number: how far the actual hand is from the target
					// we ASKED the IK for. Small = IK follows target (our target is
					// wrong); large = IK ignores target (wiring/space is wrong).
					FVector HandR = Mesh.GetBoneTransform(n"hand_r").Location;
					AttemptHandVsTarget = (HandR - Anim.HandTargetR).Size();
					// And how far our target itself is from the ball.
					AttemptTargetVsBall = (Anim.HandTargetR - TB.Position).Size();
				}
			}
		}
		else if (bAttemptActive)
		{
			// Attempt just ended — report closest approach vs the catch radius.
			if (bDebugHit)
			{
				ABall CB = GetWorldBall();
				float Catch = ArmContactRadius + (CB != nullptr ? CB.BallRadius : 10.66f);
				Log("ATTEMPT type=" + int(CurrentHit)
					+ " closestHand=" + int(AttemptClosest)
					+ " catch=" + int(Catch)
					+ " | bodyHoriz=" + int(AttemptHoriz)
					+ " ballVsHead=" + int(AttemptVert)
					+ " pose=" + int(AttemptPose * 100)
					+ " ik=" + int(AttemptIK * 100)
					+ " facing=" + int(AttemptFacing * 100)
					+ " | handVsTarget=" + int(AttemptHandVsTarget)
					+ " targetVsBall=" + int(AttemptTargetVsBall)
					+ (AttemptClosest <= Catch ? "  -> SHOULD HIT" : "  -> MISS"));
			}
			bAttemptActive = false;
			AttemptClosest = 99999.0f;
		}

		// Reach/crouch requests lapse on a short timer (see Reach/RequestCrouch)
		// so they survive the gap between AI reaction ticks but still fade when
		// the AI stops asking.
		ReachHoldTimer -= DeltaTime;
		if (ReachHoldTimer <= 0.0f)
			bReaching = false;
		// (Crouch decay moved to the TOP of UpdatePlayer — it must run before
		// the per-frame writers, not after them.)
	}

	private bool bAttemptActive = false;
	private float AttemptClosest = 99999.0f;
	private float AttemptHoriz = 0.0f;
	private float AttemptVert = 0.0f;
	private float AttemptPose = 0.0f;
	private float AttemptIK = 0.0f;
	private float AttemptFacing = 0.0f;
	private float AttemptHandVsTarget = 0.0f;
	private float AttemptTargetVsBall = 0.0f;

	private float CurrentPose = 0.0f;   // smoothed arm-pose SHAPE weight (ready->contact)
	private float IKWeight = 0.0f;      // smoothed IK node Alpha (how much IK applies)
	private bool bMovingState = false;  // hysteresis state for Anim.bIsMoving

	// --- Motion naturalness monitor ----------------------------------------
	// DETECTS unnatural motion signatures directly instead of waiting for a
	// human to spot them: velocity direction reversals, yaw oscillation,
	// crouch flapping, and IK-sink violations, each over a sliding window.
	// Emits JITTER log lines that headless runs grep — the permanent motion-
	// quality regression check.
	bool bMonitorMotion = true;
	private float MonWindow = 0.0f;
	private int MonMoveFlips = 0;
	private int MonYawFlips = 0;
	private int MonCrouchFlips = 0;
	private int MonIKTeleports = 0;
	private FVector MonPrevVel;
	private float MonPrevYaw = 0.0f;
	private float MonPrevYawDelta = 0.0f;
	private float MonPrevCrouch = 0.0f;
	private float MonPrevCrouchDelta = 0.0f;
	private FVector MonPrevHandR;
	private bool bMonInit = false;
	private int MonCFlipLogs = 0;
	// Written by UpdateIKTargets each frame so CFLIP can attribute the source.
	float DbgPoseCrouch = 0.0f;
	float DbgWantCrouch = 0.0f;
	// The sink's legitimate speed ceiling this frame (swing boost included) —
	// written by UpdateIKTargets so the teleport check tracks the same limit.
	float SinkBoostLog = 1.0f;
	// Rolling peak of the hand-target speed (cm/s), decaying — logged by
	// TriggerHit as the SWING line so whip speeds are measurable per stroke.
	float PeakHandSpd = 0.0f;
	// Facing attribution written each frame (see the rotation block in
	// UpdatePlayer) so a YFLIP log can attribute WHICH source's target
	// reversed: 0=travel-velocity, 1=held facing request, 2=turn-and-run.
	int DbgFacingSrc = -1;
	float DbgWantYaw = 0.0f;
	private int MonYFlipLogs = 0;
	private float MonPrevDt = 0.0f;   // testing whether YFLIP correlates with erratic frame pacing

	// RUN TOTALS — the window counters above reset every 0.5s and only ever print
	// on threshold breach, so a clean run and a run where the monitor silently
	// stopped working look identical, and a worse build can log the same capped
	// 60 YFLIP lines as a better one. These accumulate for the whole rally and are
	// emitted unconditionally as MOTIONSTATS, with seconds-in-motion as the
	// denominator so two runs of different length are comparable.
	private int MonTotMoveFlips = 0;
	private int MonTotYawFlips = 0;
	private int MonTotCrouchFlips = 0;
	private int MonTotIKTeleports = 0;
	private float MonMovingTime = 0.0f;
	private float MonYawRateSum = 0.0f;    // |rate| while turning, for the mean
	private float MonYawRateSamples = 0.0f;
	private float MonYawRateMax = 0.0f;
	// Goal jumps: the movement TARGET teleporting is invisible to every detector
	// above — MoveToHold absorbs it into a perfectly smooth run in the wrong
	// direction, so no velocity or yaw reversal ever fires. Threshold sits above
	// MoveToHold's 110cm StartMoving, i.e. only jumps big enough to actually make
	// the player run somewhere else count.
	private FVector MonPrevGoal;
	private bool bMonGoalInit = false;
	private int MonGoalJumps = 0;

	// BONE-LEVEL JITTER — the solver's OUTPUT, which is what the eye actually sees.
	// Every detector above watches script INTENT (velocity, yaw, crouch, hand
	// targets). The visible pose is the FBIK solve on top of that, and the solver
	// re-solves the whole chain — pelvis and spine included — from the hand
	// targets every frame, so it can shake while every input reads clean. That is
	// the blind spot the previous pass named and could not measure.
	//
	// footSlide is the classic skating tell: a foot in contact with the sand
	// should be stationary in WORLD space. Any horizontal travel while it is
	// planted is the foot sliding under the body.
	private FVector MonPrevFootL;
	private FVector MonPrevFootR;
	private FVector MonPrevPelvis;
	private FVector MonPrevPelvisVel;
	private bool bMonBoneInit = false;
	private float MonFootSlide = 0.0f;    // cm accumulated while planted
	private int MonPelvisFlips = 0;       // pelvis direction reversals (the sink can't see these)

	// Called by the AI whenever it commands a movement target. Reporting the same
	// target twice in a frame is harmless (delta 0), so both MoveToHold and
	// MoveToward2D can call it without double counting.
	void ReportMoveGoal(FVector Goal)
	{
		if (bMonGoalInit && (Goal - MonPrevGoal).Size2D() > 150.0f)
			MonGoalJumps++;
		MonPrevGoal = Goal;
		bMonGoalInit = true;
	}

	// Emitted per rally from GameMode.LogRallyEnd — one greppable regression
	// number per player instead of "eyeball the flipbook".
	void EmitMotionStats()
	{
		if (!bMonitorMotion) return;
		int YawMean = (MonYawRateSamples > 0.0f) ? int(MonYawRateSum / MonYawRateSamples) : 0;
		Log("MOTIONSTATS " + GetName()
			+ " moving=" + int(MonMovingTime * 100.0f)
			+ " moveFlips=" + MonTotMoveFlips
			+ " yawFlips=" + MonTotYawFlips
			+ " crouchFlips=" + MonTotCrouchFlips
			+ " ikTeleports=" + MonTotIKTeleports
			+ " goalJumps=" + MonGoalJumps
			+ " yawRateMean=" + YawMean
			+ " yawRateMax=" + int(MonYawRateMax)
			+ " footSlide=" + int(MonFootSlide)
			+ " pelvisFlips=" + MonPelvisFlips);
		MonTotMoveFlips = 0;
		MonTotYawFlips = 0;
		MonTotCrouchFlips = 0;
		MonTotIKTeleports = 0;
		MonGoalJumps = 0;
		MonMovingTime = 0.0f;
		MonYawRateSum = 0.0f;
		MonYawRateSamples = 0.0f;
		MonYawRateMax = 0.0f;
		MonFootSlide = 0.0f;
		MonPelvisFlips = 0;
	}

	private void UpdateMotionMonitor(float DeltaTime)
	{
		if (!bMonitorMotion || DeltaTime <= 0.0f) return;
		float Yaw = GetActorRotation().Yaw;
		float CrouchNow = (Anim != nullptr) ? Anim.CrouchAmount : 0.0f;
		FVector HandR = (Anim != nullptr) ? Anim.HandTargetR : FVector::ZeroVector;

		if (!bMonInit)
		{
			bMonInit = true;
			MonPrevVel = PlayerVelocity;
			MonPrevYaw = Yaw;
			MonPrevCrouch = CrouchNow;
			MonPrevHandR = HandR;
			return;
		}

		// 1) Locomotion reversals: both frames moving, direction flipped.
		FVector V = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);
		FVector PV = FVector(MonPrevVel.X, MonPrevVel.Y, 0);
		if (V.Size() > 60.0f && PV.Size() > 60.0f
			&& V.DotProduct(PV) < -0.2f * V.Size() * PV.Size())
		{
			MonMoveFlips++;
			MonTotMoveFlips++;
		}
		// Denominator: only time actually spent moving is comparable between runs.
		if (V.Size() > 60.0f) MonMovingTime += DeltaTime;

		// 2) Yaw oscillation: turn direction alternates at a real turn RATE.
		// Thresholds are rates (per second), not per-frame deltas — a per-frame
		// threshold silently under-detects at high frame rates (nullrhi runs
		// uncapped and the first detector pass saw nothing at any fps).
		float YawDelta = Math::FindDeltaAngleDegrees(MonPrevYaw, Yaw);
		float YawRate = YawDelta / DeltaTime;
		if (Math::Abs(YawRate) > 60.0f && Math::Abs(MonPrevYawDelta) > 60.0f
			&& YawRate * MonPrevYawDelta < 0.0f)
		{
			MonYawFlips++;
			MonTotYawFlips++;
			if (MonYFlipLogs < 60)
			{
				MonYFlipLogs++;
				FVector V2 = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);
				Log("YFLIP rate=" + int(YawRate) + " prevRate=" + int(MonPrevYawDelta)
					+ " yaw=" + int(Yaw) + " src=" + DbgFacingSrc + " wantYaw=" + int(DbgWantYaw)
					+ " dt=" + DeltaTime + " prevDt=" + MonPrevDt
					+ " moveIn=(" + int(MoveInput.X * 100.0f) + "," + int(MoveInput.Y * 100.0f) + ")"
					+ " velDir=(" + int(V2.X) + "," + int(V2.Y) + ") speed=" + int(V2.Size())
					+ " hit=" + int(CurrentHit) + " grounded=" + bIsGrounded);
			}
		}
		if (Math::Abs(YawRate) > 20.0f) MonPrevYawDelta = YawRate;
		MonPrevDt = DeltaTime;
		// Turn-rate distribution: the flip COUNT says how often direction reverses,
		// this says how violently the body turns at all — the thing that reads as
		// unnatural even when the direction never reverses.
		if (Math::Abs(YawRate) > 20.0f)
		{
			MonYawRateSum += Math::Abs(YawRate);
			MonYawRateSamples += 1.0f;
			MonYawRateMax = Math::Max(MonYawRateMax, Math::Abs(YawRate));
		}

		// 3) Crouch flapping: knee direction alternates at a real rate. The
		// threshold must catch ASYMMETRIC oscillation too: the proportional
		// sink rises at gain 3, so the up-leg of a ±0.3 square wave moves at
		// ~0.9/s — a 1.0 threshold declared the visible set/bump pose bob
		// "no jitter" while Erik watched it. 0.6 catches both legs.
		float CrouchRate = (CrouchNow - MonPrevCrouch) / DeltaTime;
		if (Math::Abs(CrouchRate) > 0.6f && Math::Abs(MonPrevCrouchDelta) > 0.6f
			&& CrouchRate * MonPrevCrouchDelta < 0.0f)
		{
			MonCrouchFlips++;
			MonTotCrouchFlips++;
			// Component dump: which upstream source is alternating? (pose*blend
			// vs ExtraCrouch vs the sink itself). Capped so logs stay readable.
			if (MonCFlipLogs < 60)
			{
				MonCFlipLogs++;
				Log("CFLIP rate=" + CrouchRate + " prevRate=" + MonPrevCrouchDelta
					+ " sm=" + CrouchNow + " want=" + DbgWantCrouch
					+ " pose=" + DbgPoseCrouch + " extra=" + ExtraCrouch + " held=" + HeldCrouch
					+ " dt=" + DeltaTime + " hit=" + int(CurrentHit)
					+ " speed=" + int(FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size()));
			}
		}
		if (Math::Abs(CrouchRate) > 0.3f) MonPrevCrouchDelta = CrouchRate;

		// 4) IK-sink violation: the hand target moved faster than the sink's
		// speed limit allows — something writes past the anti-flicker sink.
		// The ceiling follows SinkBoostLog: a swing legitimately opens it.
		float HandStep = (HandR - MonPrevHandR).Size();
		if (HandStep > 900.0f * SinkBoostLog * DeltaTime * 1.6f + 2.0f)
		{
			MonIKTeleports++;
			MonTotIKTeleports++;
		}
		// Rolling hand-speed peak for the SWING telemetry (decays ~0.5s).
		PeakHandSpd = Math::Max(HandStep / DeltaTime, PeakHandSpd - 4000.0f * DeltaTime);

		// 5) What the solver actually produced this frame.
		if (Mesh != nullptr)
		{
			FVector FootL = Mesh.GetBoneTransform(n"foot_l").Translation;
			FVector FootR = Mesh.GetBoneTransform(n"foot_r").Translation;
			FVector Pelvis = Mesh.GetBoneTransform(n"pelvis").Translation;

			if (!bMonBoneInit)
			{
				bMonBoneInit = true;
				MonPrevFootL = FootL;
				MonPrevFootR = FootR;
				MonPrevPelvis = Pelvis;
			}
			else if (bIsGrounded)
			{
				// A foot counts as planted when it is within 12cm of the sand.
				// Horizontal travel while planted is slide, in cm.
				float FloorPlant = FloorZ + 12.0f;
				if (FootL.Z < FloorPlant)
					MonFootSlide += FVector(FootL.X - MonPrevFootL.X, FootL.Y - MonPrevFootL.Y, 0).Size();
				if (FootR.Z < FloorPlant)
					MonFootSlide += FVector(FootR.X - MonPrevFootR.X, FootR.Y - MonPrevFootR.Y, 0).Size();

				// Pelvis reversals, measured the same rate-based way as the rest:
				// the hips flipping direction at frame rate is the "shaky" look
				// even when velocity and yaw are both perfectly smooth.
				FVector PVel = (Pelvis - MonPrevPelvis) / DeltaTime;
				if (PVel.Size() > 40.0f && MonPrevPelvisVel.Size() > 40.0f
					&& PVel.DotProduct(MonPrevPelvisVel) < -0.2f * PVel.Size() * MonPrevPelvisVel.Size())
					MonPelvisFlips++;
				if (PVel.Size() > 15.0f) MonPrevPelvisVel = PVel;
			}
			MonPrevFootL = FootL;
			MonPrevFootR = FootR;
			MonPrevPelvis = Pelvis;
		}

		MonPrevVel = PlayerVelocity;
		MonPrevYaw = Yaw;
		MonPrevCrouch = CrouchNow;
		MonPrevHandR = HandR;

		MonWindow += DeltaTime;
		if (MonWindow >= 0.5f)
		{
			if (MonMoveFlips >= 2 || MonYawFlips >= 3 || MonCrouchFlips >= 3 || MonIKTeleports >= 1)
			{
				Log("JITTER team=" + int(TeamSide)
					+ " moveFlips=" + MonMoveFlips
					+ " yawFlips=" + MonYawFlips
					+ " crouchFlips=" + MonCrouchFlips
					+ " ikTeleports=" + MonIKTeleports
					+ " speed=" + int(FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size())
					+ " hit=" + int(CurrentHit)
					+ " grounded=" + bIsGrounded);
			}
			MonWindow = 0.0f;
			MonMoveFlips = 0;
			MonYawFlips = 0;
			MonCrouchFlips = 0;
			MonIKTeleports = 0;
		}
	}

	// ANTI-FLICKER SINK STATE: everything the ABP sees is speed-limited at the
	// single write point (end of UpdateIKTargets). Public: the mixin owns them.
	FVector SmHandR;
	FVector SmHandL;
	FVector SmPoleR;
	FVector SmPoleL;
	FRotator SmRotR;
	FRotator SmRotL;
	float SmCrouch = 0.0f;
	bool bSmInit = false;

	// Extra crouch (0..1) from FRAME-RATE transient envelopes (split step, dive,
	// jump load, landing absorb, air tuck). Written by Max every frame while the
	// envelope is active; decays every frame (top of UpdatePlayer) so it releases
	// the instant the envelope ends. Combined with HeldCrouch by Max in the IK.
	float ExtraCrouch = 0.0f;

	// Extra crouch (0..1) from the AI's TICK-RATE stance requests (RequestCrouch:
	// ready stance, planted wait, block track, defensive base). The AI only
	// re-asserts every ReactionDelay, so this is HELD across the gap (CrouchHoldTimer)
	// and only decays once the AI stops asking — separate lifetime from the
	// per-frame transients so a transient peak can't get frozen at the held rate.
	float HeldCrouch = 0.0f;

	// Landing absorption state (knees flex on touchdown, see UpdatePlayer).
	private float LandAbsorbTimer = 0.0f;
	private float LandAbsorbDepth = 0.5f;

	// AI sets this while preparing to play the ball, with the hit type it
	// intends, so the arms extend toward the ball before contact. Requests are
	// held for a beat (not cleared per-frame) because the AI only re-asserts
	// every ReactionDelay — clearing each frame made poses sawtooth between ticks.
	bool bReaching = false;
	private float ReachHoldTimer = 0.0f;
	private float CrouchHoldTimer = 0.0f;

	void Reach(EHitType Type)
	{
		bReaching = true;
		ReachHoldTimer = 0.25f;
		if (HitAnimTimer > 0.0f) return;   // don't override an active swing
		if (Type != CurrentHit)
		{
			// ANTI-FLICKER: a gesture must live MinGestureDwell before another
			// may replace it — two systems disagreeing about the stroke at
			// different rates alternated IK branches per frame. Real contacts
			// (TriggerHit) bypass this: they're events, not opinions.
			if (GestureAge < MinGestureDwell) return;
			CurrentHit = Type;
			GestureAge = 0.0f;
		}
	}

	// Age of the current gesture type; guards against per-frame branch flips.
	private float GestureAge = 10.0f;
	const float MinGestureDwell = 0.15f;

	// Crouch request that survives between AI reaction ticks (ready stance etc.).
	// Per-frame writers (split step, dive) set ExtraCrouch directly instead — this
	// channel is HELD across the tick gap; theirs decays every frame.
	void RequestCrouch(float Amount)
	{
		HeldCrouch = Math::Max(HeldCrouch, Amount);
		CrouchHoldTimer = 0.25f;
	}

	// 0 outside a strike, ramping 0->1 over the contact swing that TriggerHit
	// starts. The IK uses this to swing the arms THROUGH the ball along the aim
	// at contact — a static contact pose reads as catching, not hitting.
	float SwingProgress() const
	{
		if (HitAnimTimer <= 0.0f || HitAnimDuration <= 0.0f) return 0.0f;
		return 1.0f - Math::Clamp(HitAnimTimer / HitAnimDuration, 0.0f, 1.0f);
	}

	// Serve choreography phase (0 = idle, ramps 0->1 through toss + strike).
	// Driven by the AI serve sequence; read by the Hit_Serve branch in PlayerIK.
	float ServePhase = 0.0f;

	// --- Predicted meet points, cached once per frame -----------------------
	// Where the incoming ball will next descend through bump-platform height
	// (waist, FloorZ+112) and through set height (above the brow). The IK PARKS
	// the platform/cup at these STATIC points instead of chasing the live ball:
	// the ABP's FBIK effectors converge on static targets (booth-verified) but
	// lag behind moving ones — chasing is why fast serves went through the arms.
	FVector PredictedMeetLow;
	bool bHasPredictedMeetLow = false;
	FVector PredictedMeetHigh;
	bool bHasPredictedMeetHigh = false;

	private bool PredictBallCrossZ(ABall B, float TargetZ, FVector& Out) const
	{
		FVector P = B.Position;
		FVector V = B.BallVel;
		if (P.Z <= TargetZ && V.Z <= 0.0f) { Out = P; return true; }   // already at/below, dropping
		const float SimDt = 0.025f;
		float T = 0.0f;
		while (T < 2.5f)
		{
			V.Z += -980.0f * SimDt;
			P += V * SimDt;
			if (P.Z <= TargetZ && V.Z < 0.0f) { Out = P; return true; }
			if (P.Z <= 0.0f) break;
			T += SimDt;
		}
		return false;
	}

	private void UpdatePredictedMeet()
	{
		bHasPredictedMeetLow = false;
		bHasPredictedMeetHigh = false;
		ABall B = GetWorldBall();
		if (B == nullptr || !B.bInPlay) return;
		bHasPredictedMeetLow  = PredictBallCrossZ(B, FloorZ + 112.0f, PredictedMeetLow);
		bHasPredictedMeetHigh = PredictBallCrossZ(B, GetActorLocation().Z + PlayerHeight * 0.9f, PredictedMeetHigh);
	}

	// Distance (cm) at which any player auto-reaches toward the ball. Kept tight so
	// players don't flail at a ball that's still metres away — the AI drives the
	// deliberate reach as it closes in; this is just a safety net at true arm range.
	float AutoReachDistance = 115.0f;

	// Reach for the ball automatically when it's near and I may legally play it.
	// Hit type is picked from the ball's height relative to my body.
	private void AutoReachForBall()
	{
		if (!CanContactBall()) return;
		// An active deliberate reach (AI/dive) owns the pose. AutoReach re-picking
		// the hit type from geometry at frame rate fought the AI's 9Hz choice —
		// alternating IK branches every frame read as violent hand flicker. This
		// is only the safety net for UNDESIGNATED players; it takes over 0.25s
		// after the AI stops asking (which also covers the post-whiff rescue).
		if (bReaching) return;
		ABall B = GetWorldBall();
		if (B == nullptr || !B.bInPlay) return;

		float Dist = (GetActorLocation() - B.Position).Size();
		if (Dist > AutoReachDistance) return;

		// Only if the ball is actually COMING at me (approaching, or dropping
		// right on top of me). A ball merely passing nearby made every bystander
		// throw their arms up, which read as random flailing.
		FVector ToMe = GetActorLocation() - B.Position;
		bool bComing = B.BallVel.DotProduct(ToMe) > 0.0f
			|| (B.BallVel.Z < 0.0f
				&& (GetActorLocation() - FVector(B.Position.X, B.Position.Y, 0)).Size2D() < 80.0f);
		if (!bComing) return;

		// Same rule as the AI: a fingerpass (set) is only legal if we're actually
		// UNDER the ball with the forehead — close horizontally AND ball at/above
		// forehead height. Airborne over a high ball = spike. Otherwise bagger.
		float ForeheadZ = GetActorLocation().Z + PlayerHeight * 0.9f;
		float HorizToBall = (GetActorLocation() - FVector(B.Position.X, B.Position.Y, 0)).Size2D();
		bool bUnderBall = HorizToBall < 70.0f;
		bool bHighEnough = B.Position.Z > ForeheadZ;

		EHitType Type;
		if (!bIsGrounded && bHighEnough)
			Type = EHitType::Hit_Spike;          // jumping at a high ball
		else if (bUnderBall && bHighEnough)
			Type = EHitType::Hit_Set;            // under it in time -> fingerpass
		else
			Type = EHitType::Hit_Bump;           // late/low -> bagger

		Reach(Type);
	}


	// --- Physical ball contact ---------------------------------------------
	// The ball calls these. The player no longer teleports the ball's velocity;
	// instead the ball bounces off the player's arm region, and we trigger the
	// matching animation + register the touch.

	// Ball only bounces off hands and forearms. Each is a small sphere centered
	// on the bone, in world space. Radius is how thick the limb is for contact.
	// Forearm/hand contact thickness. A real forearm-platform / cupped hands sweep
	// a fatter volume than a single bone point, so this is generous on purpose:
	// effective catch radius = ArmContactRadius + BallRadius (~42cm), which fairly
	// represents an outstretched arm meeting the ball.
	float ArmContactRadius = 32.0f;

	// Test the ball against the hand/forearm bones. If any is within reach,
	// fills OutCenter with that bone's position and returns true.
	bool GetArmContact(FVector BallPos, float BallRadius, FVector& OutCenter) const
	{
		if (Mesh == nullptr) return false;

		// Bones that can legally play the ball (hands + forearms, both sides).
		FName Bones0 = n"hand_r";
		FName Bones1 = n"hand_l";
		FName Bones2 = n"lowerarm_r";
		FName Bones3 = n"lowerarm_l";

		float Reach = ArmContactRadius + BallRadius;
		float ReachSq = Reach * Reach;

		FVector P;
		P = Mesh.GetBoneTransform(Bones0).Location;
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }
		P = Mesh.GetBoneTransform(Bones1).Location;
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }
		P = Mesh.GetBoneTransform(Bones2).Location;
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }
		P = Mesh.GetBoneTransform(Bones3).Location;
		if ((BallPos - P).SizeSquared() <= ReachSq) { OutCenter = P; return true; }

		return false;
	}

	// Where this player wants to send the ball (set by AI each frame). The ball
	// uses this as the bounce direction on contact.
	FVector DesiredAim = FVector::ZeroVector;
	bool bHasAim = false;

	// PLAN vs ACTUAL: the AI hitter records the budget's promise (slack, speed)
	// and how long it has stood planted; the contact grades them (PLANVA line).
	float PlanSlackLog = -1.0f;
	float PlanSpeedFracLog = -1.0f;
	float PlantedFor = 0.0f;

	// Whether this player is allowed to touch the ball right now. Overridden by
	// AI so a player who made the team's last touch is "transparent" until a
	// different player (teammate or opponent) touches it — no double contacts.
	bool CanContactBall() const { return true; }

	// Solve the launch velocity that carries the ball from P to T on a parabola
	// peaking Apex cm above the higher endpoint. This is what a controlled
	// volleyball contact IS: pros don't reflect the ball, they place it — the
	// dig pops to the setter zone, the set floats to the attack spot, both with
	// deliberate arc. (Air drag ~2%/s shortens it slightly; acceptable.)
	FVector BallisticVelocity(FVector P, FVector T, float Apex) const
	{
		const float G = 980.0f;
		float PeakZ = Math::Max(P.Z, T.Z) + Math::Max(Apex, 40.0f);
		float Vz = Math::Sqrt(2.0f * G * (PeakZ - P.Z));
		float TUp = Vz / G;
		float TDown = Math::Sqrt(2.0f * Math::Max(PeakZ - T.Z, 1.0f) / G);
		float TTotal = Math::Max(TUp + TDown, 0.15f);
		return FVector((T.X - P.X) / TTotal, (T.Y - P.Y) / TTotal, Vz);
	}

	// --- Net-plane flight tests (net at X=0). Used to GUARANTEE the three-touch
	// protocol physically: touches 1-2 must stay on our side, touch 3 must clear
	// the tape. Ballistic, drag ignored (2%/s — the margins absorb it).
	private bool CrossesNetPlane(FVector P, FVector V) const
	{
		if (Math::Abs(V.X) < 1.0f) return false;
		float TCross = -P.X / V.X;
		if (TCross <= 0.0f) return false;
		float ZAtCross = P.Z + V.Z * TCross - 490.0f * TCross * TCross;
		return ZAtCross > 0.0f;   // still airborne when it reaches the plane
	}

	private float HeightAtNetPlane(FVector P, FVector V) const
	{
		float TCross = -P.X / V.X;
		return P.Z + V.Z * TCross - 490.0f * TCross * TCross;
	}

	// Minimum height the flight must have over the net plane: tape + ball + margin.
	private float NetClearZ()
	{
		ABall B = GetWorldBall();
		float Tape = (B != nullptr) ? B.NetTopZ + B.BallRadius : 254.0f;
		return Tape + 28.0f;
	}

	// Any opponent parked in the block lane at the net where this flight crosses?
	// A shot that clears the tape by centimetres lands exactly in the standing
	// blocker's catch envelope (hands ~240 + 42cm radius ≈ the 282 tape margin)
	// — a real hitter sees the block and shoots OVER it.
	private bool BlockerInLane(float YAtNet)
	{
		TArray<AActor> Players;
		GetAllActorsOfClass(AVolleyballPlayer, Players);
		for (AActor A : Players)
		{
			AVolleyballPlayer P = Cast<AVolleyballPlayer>(A);
			if (P == nullptr || P.TeamSide == TeamSide) continue;
			FVector L = P.GetActorLocation();
			if (Math::Abs(L.X) < 200.0f && Math::Abs(L.Y - YAtNet) < 160.0f)
				return true;
		}
		return false;
	}

	// A placed attack over the net: ballistic to T, arc raised until it clears
	// the tape — and the BLOCK, when someone is standing in the crossing lane.
	// Raising the apex raises the whole interior of the parabola, so the loop is
	// monotone and terminates. Starts flat/fast (a driven shot) and only lofts
	// as much as the contact height / block force it to.
	FVector AttackBallistic(FVector P, FVector T)
	{
		float Apex = 90.0f;
		FVector V = BallisticVelocity(P, T, Apex);
		int Guard = 0;
		while (Guard < 10 && CrossesNetPlane(P, V))
		{
			float TCross = -P.X / V.X;
			float ZC = P.Z + V.Z * TCross - 490.0f * TCross * TCross;
			float YC = P.Y + V.Y * TCross;
			float Need = NetClearZ() + (BlockerInLane(YC) ? 75.0f : 0.0f);
			if (ZC >= Need) break;
			Apex += 70.0f;
			V = BallisticVelocity(P, T, Apex);
			Guard++;
		}
		return V;
	}

	// Called by the ball when it physically touches this player. The ball gives
	// its current velocity; we return the post-contact velocity.
	//
	// THE THREE-TOUCH PROTOCOL LIVES HERE, not in raw contact geometry: the
	// reception (team touch 1) is ALWAYS a bagger (overhand serve receive is a
	// fault in beach anyway), the second touch is a bagger or a hand set, and
	// the third touch attacks over the net — jump spike if we're airborne at a
	// high ball, otherwise a placed shot. Every controlled contact is ballistic
	// placement now; the old "aimless flail" reflection branch was a rally
	// killer (random direction at 600cm/s) and is gone.
	FVector OnBallContact(FVector BallPos, FVector BallVelIn, FVector Center)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		int MyTouches = (GS != nullptr && GS.LastTouchTeam == TeamSide) ? GS.TouchesThisRally : 0;

		// A fingerpass is taken at the FOREHEAD, not above the crown. The setter
		// aims to contact at PlayerHeight*0.9 (ContactHeightFor(Hit_Set)); keying
		// the set/bump split off the OLD full-head threshold (PlayerHeight*1.0)
		// meant a perfectly-placed overhead ball at 171cm classified as a BUMP
		// because it sat below the 180cm crown — so nobody ever fingerpassed.
		// Use a forehead threshold a hair below the setter's own target so the
		// intended contact reliably reads as a set. (Kept below the target, not
		// at it, for prediction slack.)
		float SetMinContactZ = GetActorLocation().Z + PlayerHeight * 0.82f;
		bool bHigh = BallPos.Z > SetMinContactZ;
		// An active block gesture at the net keeps its identity — the protocol
		// would otherwise re-type a stuff block as a "reception" and float a
		// point-blank spike gently to the setter zone.
		bool bBlockContact = (CurrentHit == EHitType::Hit_Block && !bIsGrounded);

		EHitType Type;
		if (bBlockContact)
			Type = EHitType::Hit_Block;
		else if (MyTouches == 0)
			Type = EHitType::Hit_Bump;                                   // reception: always bagger
		else if (MyTouches == 1)
			// ATTACK ON TWO is legal: a perfect reception hangs through the
			// strike zone and the second toucher may choose to jump on it —
			// an airborne high contact here IS that choice, made physical.
			Type = (!bIsGrounded && bHigh) ? EHitType::Hit_Spike
			     : ((bHigh && bIsGrounded) ? EHitType::Hit_Set : EHitType::Hit_Bump);
		else
			Type = (!bIsGrounded && bHigh) ? EHitType::Hit_Spike
			     : (bHigh ? EHitType::Hit_Set : EHitType::Hit_Bump);     // grounded attack = shot
		bool bAttackTouch = !bBlockContact
			&& (MyTouches >= 2 || Type == EHitType::Hit_Spike);

		// Where we're sending it. The AI aims continuously; if no aim is active
		// (scramble), fall back to the protocol's natural target: pop receptions
		// to the setter zone, second balls to the attack spot, third balls deep
		// into the opponent court.
		float Own = (TeamSide == ETeam::Team_A) ? -1.0f : 1.0f;
		FVector Target;
		if (bHasAim)
			Target = DesiredAim;
		else if (bBlockContact)
			Target = FVector(-Own * 300.0f, 0.0f, FloorZ);
		else if (MyTouches == 0 || MyTouches == 1)
			// Placement rule: every pass arcs down to the far pin (floor target
			// so an unattacked pass stays IN — see FarPinTarget).
			Target = FVector(Own * 50.0f, (BallPos.Y > 0.0f) ? -350.0f : 350.0f, 20.0f);
		else
			Target = FVector(-Own * 500.0f, (BallPos.Y > 0.0f) ? -180.0f : 180.0f, 15.0f);

		// CONTACT QUALITY (first principles): control degrades with everything
		// the body still has going on at contact — residual locomotion (a
		// moving platform aims worse; quadratic, so a settling drift barely
		// matters while a sprint scatters badly) and unconverged hands (strike
		// hand vs its IK target). This is what makes the planner's "arrive
		// planted and early" measurably worth paying for.
		float BodySpd = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
		float HandErr = 0.0f;
		if (Mesh != nullptr && Anim != nullptr)
			HandErr = (Mesh.GetBoneTransform(n"hand_r").Location - Anim.HandTargetR).Size();
		float AimErrCm = 0.0f;
		if (!bBlockContact)
		{
			float SpeedFrac = Math::Clamp(BodySpd / MoveSpeed, 0.0f, 1.5f);
			AimErrCm = 140.0f * SpeedFrac * SpeedFrac + 0.5f * Math::Min(HandErr, 120.0f);
			if (AimErrCm > 2.0f)
			{
				float Ang = Math::RandRange(0.0f, 2.0f * PI);
				Target += FVector(Math::Cos(Ang), Math::Sin(Ang), 0)
					* (Math::RandRange(0.35f, 1.0f) * AimErrCm);
			}
		}

		// Physical reflection (arms as a surface) — the flavor component.
		FVector GeoNormal = (BallPos - Center).GetSafeNormal();
		if (GeoNormal.SizeSquared() < 0.01f) GeoNormal = FVector(0, 0, 1);
		FVector AimDir = (Target - BallPos).GetSafeNormal();
		FVector Normal = (GeoNormal * 0.35f + AimDir * 0.65f).GetSafeNormal();
		float VDotN = BallVelIn.DotProduct(Normal);
		FVector Reflected = (BallVelIn - Normal * (2.0f * VDotN)) * 0.35f;

		FVector OutVel;
		if (bBlockContact)
		{
			// A block is a wall, not a placement: real reflection plus a firm
			// downward push toward the middle of their court.
			FVector BlockDir = AimDir;
			BlockDir.Z = Math::Min(BlockDir.Z, -0.15f);
			OutVel = Reflected + BlockDir.GetSafeNormal() * 420.0f;
		}
		else if (bAttackTouch)
		{
			if (Type == EHitType::Hit_Spike)
			{
				// True strike: reflection + hard swing. But never into the tape —
				// if this contact physically can't power over, convert to a driven
				// shot (that's what a hitter does with a low/tight ball).
				FVector SwingDir = AimDir;
				SwingDir.Z = Math::Min(SwingDir.Z, -0.2f);
				OutVel = Reflected + SwingDir.GetSafeNormal() * 1050.0f;
				if (!CrossesNetPlane(BallPos, OutVel) || HeightAtNetPlane(BallPos, OutVel) < NetClearZ())
					OutVel = AttackBallistic(BallPos, Target);
			}
			else
			{
				// Shot: pure placed arc, guaranteed over.
				OutVel = AttackBallistic(BallPos, Target);
			}
		}
		else
		{
			// Touch 1-2: placed arc to our own side. The dash of reflection keeps
			// hot serves feeling physical — but if it would carry the ball over
			// the net (protocol break: only touch 3 crosses), drop it and keep
			// the pure ballistic, which by construction stays on our side.
			// Arc by TOUCH NUMBER and QUALITY. The SECOND ball is the pass the
			// attacker jumps on — with the floor target at the pin its arc must
			// peak ~490 to hang through the 350 strike zone (apex counts above
			// the higher endpoint, so grounding the target lowered every peak
			// by ~3m and the jump attack vanished). The RECEPTION's height is
			// EARNED by contact quality: a planted, converged dig floats the
			// same attackable arc (and the partner may then spike on 2 or
			// hand-set), while a scrambled one only manages the flat
			// defensive pop. Quality gating the arc means "perfect reception
			// = options" falls out of the physics instead of a rule.
			float Apex = (MyTouches == 1)
				? 340.0f
				: Math::Lerp(340.0f, 260.0f, Math::Clamp(AimErrCm / 50.0f, 0.0f, 1.0f));
			FVector Pure = BallisticVelocity(BallPos, Target, Apex);
			OutVel = Pure + Reflected * 0.15f;
			if (CrossesNetPlane(BallPos, OutVel))
				OutVel = Pure;
		}

		// PLAN vs ACTUAL: grade the budget's promise at the moment of truth.
		// slack/speedFrac are what the plan booked (×100), settle is how long
		// the body was planted before this contact, bodySpd/handErr/aimErr are
		// what the contact actually paid.
		Log("PLANVA touch=" + MyTouches + " type=" + int(Type)
			+ " slack=" + int(PlanSlackLog * 100.0f)
			+ " speedFrac=" + int(PlanSpeedFracLog * 100.0f)
			+ " settle=" + int(PlantedFor * 100.0f)
			+ " bodySpd=" + int(BodySpd)
			+ " handErr=" + int(HandErr)
			+ " aimErr=" + int(AimErrCm)
			+ " grounded=" + bIsGrounded);
		PlanSlackLog = -1.0f;
		PlanSpeedFracLog = -1.0f;

		TriggerHit(Type, OutVel.GetSafeNormal());
		RegisterHit(GetWorldBall());
		bHasAim = false;
		return OutVel;
	}

	// The ball passes itself for touch registration; we keep a cached ref.
	// Public so the IK mixin can locate the ball to aim the hands at it.
	private ABall CachedBall;
	ABall GetWorldBall()
	{
		if (CachedBall == nullptr)
		{
			TArray<AActor> Found;
			GetAllActorsOfClass(ABall, Found);
			if (Found.Num() > 0) CachedBall = Cast<ABall>(Found[0]);
		}
		return CachedBall;
	}

	// Called by gameplay code each time a contact happens. Sets which upper-body
	// hit montage the Anim Blueprint should blend in.
	protected void TriggerHit(EHitType Type, FVector WorldDir)
	{
		ReachDir = WorldDir.GetSafeNormal();
		CurrentHit = Type;      // a real contact is an event — no dwell gate
		GestureAge = 0.0f;
		HitAnimTimer = HitAnimDuration;
		// Whip telemetry: rolling peak of hand-target speed entering this
		// contact (cm/s). A real spike/serve whip should read 1500-2300; a
		// bump platform a few hundred.
		Log("SWING type=" + int(Type) + " peakHand=" + int(PeakHandSpd));
		if (bDebugHit)
		{
			FString Cls = (Anim != nullptr) ? "" + Anim.GetClass().GetName() : "NULL";
			Log("HIT type=" + int(Type) + " AnimInstance=" + Cls);
		}
	}

	bool bDebugHit = false;

	// Back-compat: a generic reach with no specific hit type.
	protected void TriggerReach(FVector WorldDir)
	{
		TriggerHit(EHitType::Hit_Bump, WorldDir);
	}


	UFUNCTION(BlueprintCallable)
	void MovePlayer(FVector2D Input)
	{
		// Store the desired move; UpdatePlayer eases the real velocity toward it.
		// Players no longer teleport between speeds — explosive first step, hard
		// plant when stopping, and momentum carries through jumps (with only weak
		// steering in the air, so no mid-jump swimming).
		MoveInput = Input;
	}

	// Desired input this frame (unit length or less). Consumed by UpdatePlayer.
	private FVector2D MoveInput = FVector2D::ZeroVector;

	// --- TURN-AND-RUN (first principles) -----------------------------------
	// Nobody runs backward across a court: backpedal/shuffle exist only for
	// short, slow adjustment steps. A player who has real ground to cover
	// TURNS, runs facing the travel, and squares back up to the ball while
	// decelerating into the spot (the head look-at keeps the eyes on the ball
	// the whole way — exactly how a receiver tracks over the shoulder). So a
	// ball-facing request is OVERRIDDEN by travel-facing while the commanded
	// movement is both brisk and clearly against that facing. Judged on the
	// INTENT (MoveInput demand), not the lagging velocity, so the body turns
	// as the run starts, not after it. Hysteresis on both gates — demand and
	// alignment bands don't overlap — so the choice cannot flicker at a
	// boundary (per-frame conditional facing is exactly what caused the old
	// two-pose shimmer this replaces). Never while a gesture is live: contact
	// needs the squared-up chest the IK targets anchor to.
	private bool bTurnRun = false;
	// Minimum time bTurnRun must hold a state before it may flip again. The
	// Demand/Align hysteresis bands don't overlap, which stops FLICKER from a
	// signal drifting slowly across a boundary — but FacingDir is the AI's raw
	// ball-direction request, re-asserted whole-cloth every reaction tick
	// (~10Hz): it can JUMP 20-40° in one tick near the ball, clearing BOTH
	// bands in a single step and re-deciding engage/release every tick (a
	// travel/turn-run source shimmer, same family as the old gesture/crouch
	// flicker bugs). A dwell timer — the same fix used everywhere else in this
	// file — gives the noisy comparison time to settle before re-deciding.
	private float TurnRunDwellTimer = 0.0f;
	const float TurnRunMinDwell = 0.3f;

	private void UpdateTurnRun(float DeltaTime)
	{
		if (TurnRunDwellTimer > 0.0f) TurnRunDwellTimer -= DeltaTime;

		// Compute the DESIRED state first, decide whether to apply it LAST —
		// every path (including the early-out ones) must cross the same dwell
		// gate. The previous version force-applied bTurnRun=false from the
		// early-outs without checking the timer at all, so it never actually
		// stopped a state that was flapping because bWantFacing itself was
		// flapping (FacingHoldTimer lapsing between AI ticks) — exactly the
		// residual src=0<->1<->2 churn the YFLIP telemetry kept showing.
		bool bWantFacing = FacingHoldTimer > 0.0f && FacingDir.SizeSquared() > 0.01f;
		bool bGestureLive = bReaching || CurrentPose > 0.15f || IsDiving();
		bool bDesired = bTurnRun;

		if (!bWantFacing || bGestureLive || !bIsGrounded)
		{
			bDesired = false;
		}
		else
		{
			FVector InDir = FVector(MoveInput.X, MoveInput.Y, 0);
			float Demand = InDir.Size();               // 0..1 commanded speed fraction
			if (Demand < 0.05f)
			{
				bDesired = false;
			}
			else
			{
				float Align = InDir.GetSafeNormal()
					.DotProduct(FVector(SmFacingDir.X, SmFacingDir.Y, 0).GetSafeNormal());
				if (bTurnRun)
				{
					// Release when the run winds down (MoveToward2D's arrival taper
					// drops the demand ~50cm out) or the travel no longer fights the
					// facing (ball ahead again: the two agree anyway).
					if (Demand < 0.35f || Align > 0.55f) bDesired = false;
				}
				else
				{
					// Engage only for a genuine hurried run well off the facing
					// (>70°) — beyond what a shuffle/backpedal covers with the eyes
					// still useful. The spike approach's open-shoulder facing
					// (~22° off travel) stays far inside the gate.
					if (Demand > 0.55f && Align < 0.35f) bDesired = true;
				}
			}
		}

		if (bDesired != bTurnRun)
		{
			if (TurnRunDwellTimer > 0.0f) return;   // switched too recently: hold
			bTurnRun = bDesired;
			TurnRunDwellTimer = TurnRunMinDwell;
		}
	}

	// Horizontal acceleration rates (cm/s²). Ground values give a sprinter-like
	// first step (0→full in ~0.2s) and a decisive plant (full→0 in ~0.13s, sliding
	// ~30cm — matches the AI's 40cm plant radius). Air rate is weak on purpose.
	// ANISOTROPIC LOCOMOTION (first principles): legs drive hardest along the
	// facing — backpedaling keeps the eyes on the ball at ~62% of forward
	// speed, shuffling sideways ~81%. The MotionPlan planner reads the same
	// scale, so its time budgets and the sim can never disagree about how
	// fast a facing-locked hitter really closes.
	const float BackpedalScale = 0.62f;
	float MoveDirSpeedScale(FVector Dir) const
	{
		FVector F = GetActorForwardVector();
		FVector D = FVector(Dir.X, Dir.Y, 0.0f);   // params are const in AS
		F.Z = 0.0f;
		if (F.SizeSquared() < 0.01f || D.SizeSquared() < 0.01f) return 1.0f;
		float Dot = F.GetSafeNormal().DotProduct(D.GetSafeNormal());
		return Math::Lerp(BackpedalScale, 1.0f, (Dot + 1.0f) * 0.5f);
	}

	float GroundAccel = 2400.0f;
	float GroundDecel = 3400.0f;
	float AirAccel = 350.0f;

	// Ease PlayerVelocity.XY toward the requested input velocity.
	private void ApplyMoveInput(float DeltaTime)
	{
		FVector Cur = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0);
		FVector InDir = FVector(MoveInput.X, MoveInput.Y, 0);
		// Anisotropic: top speed scales with travel-vs-facing (see
		// MoveDirSpeedScale). Applied at the input level so the AI planner and
		// any future gamepad input obey the same body.
		FVector Target = InDir * (MoveSpeed * MoveDirSpeedScale(InDir));

		float Rate;
		if (!bIsGrounded)
			Rate = AirAccel;
		else if (Target.SizeSquared() > Cur.SizeSquared() + 1.0f)
			Rate = GroundAccel;
		else
			Rate = GroundDecel;

		FVector Delta = Target - Cur;
		float MaxStep = Rate * DeltaTime;
		if (Delta.Size() > MaxStep)
			Delta = Delta.GetSafeNormal() * MaxStep;

		PlayerVelocity.X = Cur.X + Delta.X;
		PlayerVelocity.Y = Cur.Y + Delta.Y;
	}

	// --- Dive: explosive low lunge at a ball that can't be reached on foot -----
	// Physics-only (no dive montage dependency): a burst of speed with a small hop,
	// body forced low via ExtraCrouch, arms reaching via the normal bump IK. The
	// recovery phase keeps the player slow and low while "getting up".
	float DiveTimer = 0.0f;
	float DiveRecoverTimer = 0.0f;
	private FVector DiveDir = FVector(1, 0, 0);
	const float DiveDuration = 0.42f;
	const float DiveRecovery = 0.75f;
	const float DiveSpeedMul = 1.75f;

	bool IsDiving() const { return DiveTimer > 0.0f; }
	bool CanDive() const { return bIsGrounded && DiveTimer <= 0.0f && DiveRecoverTimer <= 0.0f; }

	void StartDive(FVector WorldDir)
	{
		FVector Flat = FVector(WorldDir.X, WorldDir.Y, 0);
		if (Flat.SizeSquared() < 0.01f) return;
		DiveDir = Flat.GetSafeNormal();
		DiveTimer = DiveDuration;
		// Small hop so the lunge leaves the ground for a beat (scaled for the
		// heavy player gravity).
		PlayerVelocity.Z = 200.0f;
		bIsGrounded = false;
	}

	private void UpdateDive(float DeltaTime)
	{
		if (DiveTimer > 0.0f)
		{
			DiveTimer -= DeltaTime;
			// The dive owns the velocity and the facing while active.
			PlayerVelocity.X = DiveDir.X * MoveSpeed * DiveSpeedMul;
			PlayerVelocity.Y = DiveDir.Y * MoveSpeed * DiveSpeedMul;
			FacingDir = DiveDir;
			bHasFacing = true;
			ExtraCrouch = 1.0f;
			if (DiveTimer <= 0.0f)
				DiveRecoverTimer = DiveRecovery;
		}
		else if (DiveRecoverTimer > 0.0f)
		{
			DiveRecoverTimer -= DeltaTime;
			// Getting up: still low, easing back to standing.
			ExtraCrouch = Math::Max(ExtraCrouch, 0.85f * (DiveRecoverTimer / DiveRecovery));
		}
	}

	UFUNCTION(BlueprintCallable)
	void Jump()
	{
		if (bIsGrounded)
		{
			PlayerVelocity.Z = JumpVelocity;
			bIsGrounded = false;
		}
	}

	// --- Loaded jump: the full-body gather every real attack/block jump has —
	// plant, sink deep (the arms are already back in the swing windup), then
	// explode. The load converts the gather into HEIGHT: ~115cm rise vs the
	// reactive jump's ~70cm (at the heavy player gravity above).
	float JumpLoadTimer = 0.0f;
	const float JumpLoadDuration = 0.16f;
	const float LoadedJumpVelocity = 660.0f;

	bool IsJumpLoading() const { return JumpLoadTimer > 0.0f; }

	void StartLoadedJump()
	{
		if (!bIsGrounded || JumpLoadTimer > 0.0f) return;
		// The plant: the gather brakes the run — momentum becomes height, and
		// the small residue drifts the body into the contact during the ascent.
		PlayerVelocity.X *= 0.25f;
		PlayerVelocity.Y *= 0.25f;
		JumpLoadTimer = JumpLoadDuration;
	}

	private void UpdateJumpLoad(float DeltaTime)
	{
		if (JumpLoadTimer <= 0.0f) return;
		if (!bIsGrounded) { JumpLoadTimer = 0.0f; return; }   // knocked airborne: cancel

		// Sink through the load — deepest right before the explosion.
		float Prog = 1.0f - JumpLoadTimer / JumpLoadDuration;
		ExtraCrouch = Math::Max(ExtraCrouch, 0.65f * Prog);

		JumpLoadTimer -= DeltaTime;
		if (JumpLoadTimer <= 0.0f)
		{
			PlayerVelocity.Z = LoadedJumpVelocity;
			bIsGrounded = false;
		}
	}

	UFUNCTION(BlueprintCallable)
	void TryPass(ABall Ball)
	{
		if (Ball == nullptr || !bCanHit || !IsNearBall(Ball)) return;
		float XDir = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;
		FVector Dir = FVector(XDir * 0.4f, 0, 1.0f).GetSafeNormal();
		Ball.HitBall(Dir, 520.0f);
		TriggerHit(EHitType::Hit_Bump, FVector(0, 0, 1));
		RegisterHit(Ball);
	}

	UFUNCTION(BlueprintCallable)
	void TrySet(ABall Ball)
	{
		if (Ball == nullptr || !bCanHit || !IsNearBall(Ball)) return;
		float XDir = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;
		FVector Dir = FVector(XDir * 0.65f, 0, 0.76f).GetSafeNormal();
		Ball.HitBall(Dir, 620.0f);
		TriggerHit(EHitType::Hit_Set, FVector(XDir * 0.5f, 0, 1.0f));
		RegisterHit(Ball);
	}

	UFUNCTION(BlueprintCallable)
	void TrySpike(ABall Ball)
	{
		if (Ball == nullptr || !bCanHit || !IsNearBall(Ball)) return;
		float XDir = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;
		FVector ToNet = FVector(XDir, 0, -0.35f).GetSafeNormal();
		Ball.HitBall(ToNet, 1300.0f);
		TriggerHit(EHitType::Hit_Spike, FVector(XDir * 0.4f, 0, 1.0f));
		RegisterHit(Ball);
	}

	// Generic hit toward a direction with an explicit hit type (used by AI).
	void HitToward(FVector Dir, float Speed, ABall Ball, EHitType Type = EHitType::Hit_Bump)
	{
		if (Ball == nullptr || !bCanHit) return;
		Ball.HitBall(Dir, Speed);
		TriggerHit(Type, Dir);
		RegisterHit(Ball);
	}

	protected bool IsNearBall(ABall Ball) const
	{
		return (GetActorLocation() - Ball.GetActorLocation()).Size() < 120.0f;
	}

	protected void RegisterHit(ABall Ball)
	{
		bCanHit = false; HitTimer = 0;
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS != nullptr)
		{
			bool bValid = GS.RegisterTouch(TeamSide);
			if (!bValid && GM != nullptr) GM.OnTouchViolation(TeamSide);
			// Rally telemetry: which team, which touch number, which stroke.
			if (bValid && GM != nullptr)
				GM.OnTouchForRally(TeamSide, GS.TouchesThisRally, CurrentHit);
		}
		OnTouchRegistered();
	}

	// Hook for subclasses (AI) to react when this player legally touches the ball.
	protected void OnTouchRegistered() {}

	// Team colour for the fallback cube (SpawnFallbackBox) when the mesh itself
	// fails to load. The real body no longer uses this — see ApplyTeamMaterial —
	// team identity there is TeamRingColor() on the sand ring instead.
	//
	// Deliberately over-1.0 (HDR), the same trick Ball.as uses to make the ball
	// actually read as yellow: BasicShapeMaterial's "Color" multiplies into a lit
	// shade, so sub-1.0 values read as dark under this scene's warm, dim light.
	private FLinearColor TeamColor() const
	{
		return (TeamSide == ETeam::Team_A)
			? FLinearColor(0.30f, 0.70f, 1.90f, 1)
			: FLinearColor(1.90f, 0.35f, 0.30f, 1);
	}

}
