// Sand burst FX: sprays grains UP and outward on impacts and footsteps.
//
// Procedural CPU particle pool rendered as camera-facing quads (asset-free).
// Niagara systems can be assigned for GPU sand; the actual spawn call is wired
// once the base scripts are confirmed compiling against this engine (see Burst).

class ASandFX : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UProceduralMeshComponent DustMesh;

	// Optional Niagara systems (author in editor, then assign on the actor).
	UPROPERTY()
	UNiagaraSystem ImpactSystem;

	UPROPERTY()
	UNiagaraSystem FootstepSystem;

	// --- CPU particle pool ---
	const int   MaxParticles = 260;
	const float PGravity     = -980.0f;
	const float PDrag        = 0.6f;
	const float GroundZ      = 0.0f;

	private TArray<FVector> PPos;
	private TArray<FVector> PVel;
	private TArray<float>   PLife;     // remaining seconds
	private TArray<float>   PLifeMax;
	private TArray<float>   PSize;
	private int NextFree = 0;
	private bool bDustDirty = false;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		for (int i = 0; i < MaxParticles; i++)
		{
			PPos.Add(FVector::ZeroVector);
			PVel.Add(FVector::ZeroVector);
			PLife.Add(0.0f);
			PLifeMax.Add(1.0f);
			PSize.Add(2.0f);
		}
	}

	// Strong upward sand spray from a ball impact.
	UFUNCTION(BlueprintCallable)
	void Burst(FVector Pos, FVector ImpactVel, float Strength)
	{
		float S = Math::Clamp(Strength, 0.1f, 3.0f);

		// NOTE: When ImpactSystem is assigned, spawn it here once the Niagara
		// AngelScript namespace is confirmed, e.g.:
		//   Niagara::SpawnSystemAtLocation(ImpactSystem, Pos, FRotator::ZeroRotator);
		// Until then (and whenever no system is set) the procedural spray runs.

		int Count = int(18.0f + S * 34.0f);
		SprayFallback(Pos, ImpactVel, S, Count, 1.0f);
	}

	// Smaller puff kicked up under a footstep.
	UFUNCTION(BlueprintCallable)
	void Footstep(FVector Pos, float Strength)
	{
		float S = Math::Clamp(Strength, 0.1f, 2.0f);

		if (FootstepSystem != nullptr)
		{
			Niagara::SpawnSystemAtLocation(FootstepSystem, Pos, FRotator::ZeroRotator);
			return;
		}

		int Count = int(6.0f + S * 10.0f);
		SprayFallback(Pos, FVector(0, 0, 0), S, Count, 0.5f);
	}

	// Emit Count grains with a strong vertical component.
	private void SprayFallback(FVector Pos, FVector ImpactVel, float Strength,
		int Count, float Scale)
	{
		FVector HBias = FVector(-ImpactVel.X, -ImpactVel.Y, 0).GetSafeNormal();

		for (int n = 0; n < Count; n++)
		{
			int idx = NextFree;
			NextFree = (NextFree + 1) % MaxParticles;

			float ang = Math::RandRange(0.0f, 2.0f * PI);
			float radial = Math::RandRange(0.2f, 1.0f);
			FVector OutDir = FVector(Math::Cos(ang), Math::Sin(ang), 0) * radial
				+ HBias * 0.6f;

			float hSpeed = Math::RandRange(60.0f, 220.0f) * Strength * Scale;
			float upSpeed = Math::RandRange(220.0f, 520.0f) * Strength * Scale;

			PPos[idx] = Pos + FVector(0, 0, 2);
			PVel[idx] = OutDir.GetSafeNormal() * hSpeed + FVector(0, 0, upSpeed);
			float life = Math::RandRange(0.45f, 0.95f);
			PLife[idx] = life;
			PLifeMax[idx] = life;
			PSize[idx] = Math::RandRange(1.5f, 4.0f) * (0.7f + Strength * 0.3f);
		}
		bDustDirty = true;
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		bool bAnyAlive = false;
		float damp = 1.0f - Math::Clamp(PDrag * DeltaTime, 0.0f, 1.0f);

		for (int i = 0; i < MaxParticles; i++)
		{
			if (PLife[i] <= 0.0f) continue;
			bAnyAlive = true;

			PVel[i].Z += PGravity * DeltaTime;
			PVel[i] *= damp;
			PPos[i] += PVel[i] * DeltaTime;

			if (PPos[i].Z <= GroundZ)
			{
				PPos[i].Z = GroundZ;
				PVel[i] = FVector::ZeroVector;
				PLife[i] = Math::Min(PLife[i], 0.12f);
			}

			PLife[i] -= DeltaTime;
		}

		if (bAnyAlive || bDustDirty)
		{
			bDustDirty = false;
			RebuildDust();
		}
	}

	// Render alive grains as small quads facing the side camera (-Y).
	private void RebuildDust()
	{
		TArray<FVector> V;
		TArray<int32> T;
		TArray<FVector> N;
		TArray<FVector2D> UV;
		TArray<FLinearColor> C;
		TArray<FVector2D> NoUV;
		TArray<FProcMeshTangent> Tan;

		for (int i = 0; i < MaxParticles; i++)
		{
			if (PLife[i] <= 0.0f) continue;

			float frac = PLife[i] / PLifeMax[i];
			float s = PSize[i] * (0.4f + 0.6f * frac);
			FVector P = PPos[i];
			int b = V.Num();

			V.Add(P + FVector(-s, 0, -s));
			V.Add(P + FVector( s, 0, -s));
			V.Add(P + FVector( s, 0,  s));
			V.Add(P + FVector(-s, 0,  s));

			for (int k = 0; k < 4; k++) N.Add(FVector(0, -1, 0));
			UV.Add(FVector2D(0, 0)); UV.Add(FVector2D(1, 0));
			UV.Add(FVector2D(1, 1)); UV.Add(FVector2D(0, 1));

			float shade = 0.85f + 0.15f * frac;
			for (int k = 0; k < 4; k++)
				C.Add(FLinearColor(0.95f * shade, 0.86f * shade, 0.66f * shade, 1));

			T.Add(b); T.Add(b + 2); T.Add(b + 1);
			T.Add(b); T.Add(b + 3); T.Add(b + 2);
		}

		if (V.Num() == 0)
		{
			DustMesh.ClearMeshSection(0);
			return;
		}

		DustMesh.CreateMeshSection_LinearColor(0, V, T, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			C, Tan, false, false);
	}
}
