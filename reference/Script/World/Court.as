// Beach volleyball court - sand, net, lines, posts via ProceduralMeshComponent

class ACourt : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UProceduralMeshComponent SandMesh;

	UPROPERTY(DefaultComponent, Attach = SandMesh)
	UProceduralMeshComponent NetMesh;

	UPROPERTY(DefaultComponent, Attach = SandMesh)
	UProceduralMeshComponent LinesMesh;

	UPROPERTY(DefaultComponent, Attach = SandMesh)
	UProceduralMeshComponent PostsMesh;

	// Court dimensions (cm) - regulation 16m x 8m
	const float CourtHalfLength = 800.0f;   // 16m / 2
	const float CourtHalfWidth  = 400.0f;   //  8m / 2
	const float SandDepth       = 30.0f;
	const float NetHeight       = 243.0f;   // men's net height
	const float NetHalfThick    = 2.5f;
	const float PostHeight      = 260.0f;
	const float PostRadius      = 5.0f;
	const float LineWidth       = 5.0f;

	// Surface colours, driven into a solid-colour material per section
	// (see ACourt::ApplySolidColorMaterial). Plain members, not const: every other const in this
	// file is a primitive, and const object members are not worth the compile risk.
	//
	// These are ALBEDO, not final pixel colours. The values here were originally
	// picked for an unlit vertex-colour material, where the colour IS what you
	// see; the material is lit now, so the sun multiplies them — and 0.93 sand
	// over a bright sunset clipped to near-white, which is why the first working
	// build came out looking like a snowfield. Keep these in the range real
	// surfaces actually reflect (dry sand ~0.5, white line paint ~0.8) and let
	// the lighting do the brightening.
	private FLinearColor SandBaseColor = FLinearColor(0.62f, 0.52f, 0.36f, 1.0f);
	private FLinearColor NetBandColor  = FLinearColor(0.03f, 0.03f, 0.04f, 1.0f);
	private FLinearColor NetTapeColor  = FLinearColor(0.75f, 0.75f, 0.72f, 1.0f);
	private FLinearColor LineColor     = FLinearColor(0.80f, 0.80f, 0.76f, 1.0f);
	// Posts are the exception to the clipping above: measured linear 0.235 at 0.45
	// albedo, so they were sitting at roughly half light, not saturated. They take
	// the -1.5 EV exposure cut at face value where the sand only loses its
	// blow-out, so lift the albedo to keep them from going muddy.
	private FLinearColor PostColor     = FLinearColor(0.65f, 0.62f, 0.56f, 1.0f);

	// --- Deformable sand heightfield ---
	const int   SandGridX    = 80;      // cells along X
	const int   SandGridY    = 48;      // cells along Y
	const float SandMinZ     = -24.0f;  // deepest a crater can go
	const float SandHealRate = 0.35f;   // how fast footprints/craters refill

	private float SandW = 0.0f;         // half-extent X
	private float SandD = 0.0f;         // half-extent Y
	private float SandCellX = 1.0f;
	private float SandCellY = 1.0f;

	// Persistent per-vertex height offset (negative = pushed down).
	private TArray<float> SandHeight;
	private TArray<FVector> SandV;
	private TArray<FVector> SandN;
	private TArray<FVector2D> SandUV;
	private TArray<FProcMeshTangent> SandTan;
	private TArray<FVector2D> NoUV;     // empty UV channels for mesh calls

	private bool bSandDirty = false;
	private float SandUpdateAccum = 0.0f;
	const float SandUpdateInterval = 0.06f;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		BuildSand();
		BuildNet();
		BuildLines();
		BuildPosts();
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		// Slowly heal deformations back toward flat.
		bool bAnyHeal = false;
		float HealFactor = 1.0f - Math::Clamp(SandHealRate * DeltaTime, 0.0f, 1.0f);
		for (int i = 0; i < SandHeight.Num(); i++)
		{
			if (Math::Abs(SandHeight[i]) > 0.05f)
			{
				SandHeight[i] *= HealFactor;
				bAnyHeal = true;
			}
			else if (SandHeight[i] != 0.0f)
			{
				SandHeight[i] = 0.0f;
				bAnyHeal = true;
			}
		}
		if (bAnyHeal) bSandDirty = true;

		// Throttle the (relatively heavy) mesh rebuild.
		if (bSandDirty)
		{
			SandUpdateAccum += DeltaTime;
			if (SandUpdateAccum >= SandUpdateInterval)
			{
				SandUpdateAccum = 0.0f;
				bSandDirty = false;
				RebuildSandMesh();
			}
		}
	}

	private int SandIdx(int ix, int iy) const
	{
		return iy * (SandGridX + 1) + ix;
	}

	// Subdivided sand grid so it can be dented into craters and footprints.
	private void BuildSand()
	{
		// Wider sand skirt (was +200 on each side). At 2 m the beach ended barely
		// outside the sidelines, so on device the court read as a slab dropped into
		// the sea rather than a court marked out on a beach. 5 m gives it somewhere
		// to sit; grid cells go from 25 to ~32 cm, still finer than a footprint.
		SandW = CourtHalfLength + 500.0f; // extra sand border
		SandD = CourtHalfWidth + 500.0f;
		SandCellX = (2.0f * SandW) / SandGridX;
		SandCellY = (2.0f * SandD) / SandGridY;

		TArray<int32> T;
		SandV.Empty();
		SandN.Empty();
		SandUV.Empty();
		SandTan.Empty();
		SandHeight.Empty();

		for (int iy = 0; iy <= SandGridY; iy++)
		{
			for (int ix = 0; ix <= SandGridX; ix++)
			{
				float x = -SandW + ix * SandCellX;
				float y = -SandD + iy * SandCellY;
				SandV.Add(FVector(x, y, 0));
				SandN.Add(FVector(0, 0, 1));
				SandUV.Add(FVector2D(float(ix) / SandGridX, float(iy) / SandGridY));
				SandHeight.Add(0.0f);
			}
		}

		for (int iy = 0; iy < SandGridY; iy++)
		{
			for (int ix = 0; ix < SandGridX; ix++)
			{
				int A = SandIdx(ix, iy);
				int B = SandIdx(ix + 1, iy);
				int C = SandIdx(ix + 1, iy + 1);
				int D = SandIdx(ix, iy + 1);
				T.Add(A); T.Add(C); T.Add(B);
				T.Add(A); T.Add(D); T.Add(C);
			}
		}

		SandMesh.CreateMeshSection_LinearColor(0, SandV, T, SandN, SandUV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			SandColors(), SandTan, true, false);

		// The sand is the mesh that made the packaged-build material bug obvious: it
		// is the only section whose UVs span 0..1, so the engine's fallback material
		// stretched its checker texture right across the court. see ACourt::ApplySolidColorMaterial
		// for why /Engine/EngineDebugMaterials/VertexColorMaterial (used here before)
		// never applied on Android. SandColors() still writes the per-vertex crater
		// tint into the section; a solid-colour material cannot show it, but the data
		// is there for an authored vertex-colour material later.
		UMaterialInstanceDynamic SandMID = ApplySolidColorMaterial(SandMesh, 0, SandBaseColor);
		// Sand is about as matte as a surface gets. Left glossy, a big flat plane
		// picks up a broad specular sheen from the low sun and washes out on top of
		// the exposure problem.
		if (SandMID != nullptr)
		{
			SandMID.SetScalarParameterValue(n"Roughness", 0.95f);
			SandMID.SetScalarParameterValue(n"Metallic", 0.0f);
		}
	}

	// Sand colour, darkened slightly inside craters (compacted/shadowed sand).
	private TArray<FLinearColor> SandColors() const
	{
		TArray<FLinearColor> C;
		for (int i = 0; i < SandV.Num(); i++)
		{
			float depth = Math::Clamp(-SandHeight[i] / -SandMinZ, 0.0f, 1.0f);
			float shade = 1.0f - depth * 0.35f;
			C.Add(FLinearColor(SandBaseColor.R * shade,
				SandBaseColor.G * shade, SandBaseColor.B * shade, 1));
		}
		return C;
	}

	// Push the sand down at a world position: crater with a small raised rim.
	UFUNCTION(BlueprintCallable)
	void DeformSand(FVector WorldPos, float Radius, float Depth)
	{
		if (SandHeight.Num() == 0) return;

		FVector Local = WorldPos - GetActorLocation();
		float InvR = (Radius > 1.0f) ? 1.0f / Radius : 1.0f;
		float RimR = Radius * 1.5f;

		int minX = Math::Clamp(int((Local.X - RimR + SandW) / SandCellX) - 1, 0, SandGridX);
		int maxX = Math::Clamp(int((Local.X + RimR + SandW) / SandCellX) + 1, 0, SandGridX);
		int minY = Math::Clamp(int((Local.Y - RimR + SandD) / SandCellY) - 1, 0, SandGridY);
		int maxY = Math::Clamp(int((Local.Y + RimR + SandD) / SandCellY) + 1, 0, SandGridY);

		for (int iy = minY; iy <= maxY; iy++)
		{
			for (int ix = minX; ix <= maxX; ix++)
			{
				int idx = SandIdx(ix, iy);
				FVector P = SandV[idx];
				float d = FVector(P.X - Local.X, P.Y - Local.Y, 0).Size();

				if (d < Radius)
				{
					float t = d * InvR;
					float fall = 1.0f - t * t;
					SandHeight[idx] = Math::Max(SandMinZ, SandHeight[idx] - Depth * fall);
				}
				else if (d < RimR)
				{
					float t = (d - Radius) / (RimR - Radius);
					float rim = (1.0f - t) * Depth * 0.18f;
					SandHeight[idx] += rim;
				}
			}
		}

		bSandDirty = true;
	}

	// Recompute vertex Z + normals from the height grid and push to the mesh.
	private void RebuildSandMesh()
	{
		for (int i = 0; i < SandV.Num(); i++)
		{
			FVector P = SandV[i];
			SandV[i] = FVector(P.X, P.Y, SandHeight[i]);
		}

		for (int iy = 0; iy <= SandGridY; iy++)
		{
			for (int ix = 0; ix <= SandGridX; ix++)
			{
				int xl = Math::Max(ix - 1, 0);
				int xr = Math::Min(ix + 1, SandGridX);
				int yl = Math::Max(iy - 1, 0);
				int yr = Math::Min(iy + 1, SandGridY);
				float dzx = (SandHeight[SandIdx(xr, iy)] - SandHeight[SandIdx(xl, iy)])
					/ ((xr - xl) * SandCellX);
				float dzy = (SandHeight[SandIdx(ix, yr)] - SandHeight[SandIdx(ix, yl)])
					/ ((yr - yl) * SandCellY);
				SandN[SandIdx(ix, iy)] = FVector(-dzx, -dzy, 1).GetSafeNormal();
			}
		}

		SandMesh.UpdateMeshSection_LinearColor(0, SandV, SandN, SandUV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			SandColors(), SandTan, false);
	}

	// Net: a real volleyball net reads as a dark, SEE-THROUGH mesh band with a
	// white top tape — not a solid coloured wall.
	//
	// It gets its transparency from GEOMETRY, not from a translucent material:
	// the band is woven out of thin horizontal and vertical strings with gaps
	// between them, so you look through the holes. That side-steps the whole
	// problem that sank the two previous attempts — M_SimpleTranslucent rendered
	// a solid red sheet, and the engine debug materials do not apply in a
	// packaged build at all (see ACourt::ApplySolidColorMaterial) — since a woven
	// net needs no alpha to be see-through.
	private void BuildNet()
	{
		float HW = CourtHalfWidth + 30.0f;
		const float TapeHeight = 7.0f;                 // white top tape band (cm)
		float BandTop = NetHeight - TapeHeight;        // mesh hangs below the tape
		const float BandBottom = 100.0f;               // net mesh stops ~1m off the sand

		// --- Section 0: the woven net band
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> N;
			TArray<FVector2D> UV; TArray<FLinearColor> C; TArray<FProcMeshTangent> Tan;

			// Regulation beach volleyball mesh is ~10 cm square. Slightly coarser
			// here so the string count stays modest on mobile: ~72 verticals plus
			// ~11 horizontals is a few hundred triangles, and at match camera
			// distance the weave reads correctly.
			const float Spacing = 12.0f;   // gap between string centres (cm)
			const float StringW = 1.6f;    // string thickness (cm)

			int VCount = int((2.0f * HW) / Spacing);
			for (int i = 0; i <= VCount; i++)
			{
				float y = -HW + i * Spacing;
				AddNetStrip(V, T, N, UV, C, NetBandColor,
					y - StringW * 0.5f, y + StringW * 0.5f, BandBottom, BandTop);
			}

			int HCount = int((BandTop - BandBottom) / Spacing);
			for (int i = 0; i <= HCount; i++)
			{
				float z = BandBottom + i * Spacing;
				AddNetStrip(V, T, N, UV, C, NetBandColor,
					-HW, HW, z - StringW * 0.5f, z + StringW * 0.5f);
			}

			NetMesh.CreateMeshSection_LinearColor(0, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);
			ApplySolidColorMaterial(NetMesh, 0, NetBandColor);
		}

		// --- Section 1: white top tape — the classic visual cue for the net line
		{
			TArray<FVector> V; TArray<int32> T; TArray<FVector> N;
			TArray<FVector2D> UV; TArray<FLinearColor> C; TArray<FProcMeshTangent> Tan;

			AddNetStrip(V, T, N, UV, C, NetTapeColor, -HW, HW, BandTop, NetHeight);
			NetMesh.CreateMeshSection_LinearColor(1, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);

			ApplySolidColorMaterial(NetMesh, 1, NetTapeColor);
		}
	}

	// One double-sided quad in the net plane (X≈0), spanning Y0..Y1 by Z0..Z1.
	// Appends to the arrays; the CALLER creates the mesh section. (The version
	// this replaced hardcoded vertex indices 0..7 and created section 0 itself,
	// so it could only ever be called once per section — the tape call overwrote
	// the band's geometry and the band never existed as its own section.)
	private void AddNetStrip(TArray<FVector>& V, TArray<int32>& T, TArray<FVector>& N,
		TArray<FVector2D>& UV, TArray<FLinearColor>& C, FLinearColor Col,
		float Y0, float Y1, float Z0, float Z1)
	{
		int B = V.Num();

		// Front face
		V.Add(FVector(-NetHalfThick, Y0, Z0)); V.Add(FVector(-NetHalfThick, Y1, Z0));
		V.Add(FVector(-NetHalfThick, Y1, Z1)); V.Add(FVector(-NetHalfThick, Y0, Z1));
		T.Add(B+0); T.Add(B+1); T.Add(B+2); T.Add(B+0); T.Add(B+2); T.Add(B+3);
		// Back face
		V.Add(FVector( NetHalfThick, Y1, Z0)); V.Add(FVector( NetHalfThick, Y0, Z0));
		V.Add(FVector( NetHalfThick, Y0, Z1)); V.Add(FVector( NetHalfThick, Y1, Z1));
		T.Add(B+4); T.Add(B+5); T.Add(B+6); T.Add(B+4); T.Add(B+6); T.Add(B+7);

		for (int i = 0; i < 8; i++)
		{
			N.Add(FVector(0, 0, 1));
			UV.Add(FVector2D(0, 0));
			C.Add(Col);
		}
	}

	// Court boundary lines and center line
	private void BuildLines()
	{
		TArray<FVector> V;
		TArray<int32> T;
		TArray<FVector> N;
		TArray<FVector2D> UV;
		TArray<FProcMeshTangent> Tan;
		float H = 1.0f; // slightly above sand

		AddLine(V, T, N, UV,
			FVector(-CourtHalfLength, -CourtHalfWidth, H),
			FVector( CourtHalfLength, -CourtHalfWidth, H),
			LineWidth);
		AddLine(V, T, N, UV,
			FVector(-CourtHalfLength,  CourtHalfWidth, H),
			FVector( CourtHalfLength,  CourtHalfWidth, H),
			LineWidth);
		AddLine(V, T, N, UV,
			FVector(-CourtHalfLength, -CourtHalfWidth, H),
			FVector(-CourtHalfLength,  CourtHalfWidth, H),
			LineWidth);
		AddLine(V, T, N, UV,
			FVector( CourtHalfLength, -CourtHalfWidth, H),
			FVector( CourtHalfLength,  CourtHalfWidth, H),
			LineWidth);

		LinesMesh.CreateMeshSection_LinearColor(0, V, T, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			TArray<FLinearColor>(), Tan, false, false);

		TArray<FLinearColor> C;
		for (int i = 0; i < V.Num(); i++) C.Add(LineColor);
		LinesMesh.UpdateMeshSection_LinearColor(0, V, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			C, Tan, false);

		// Never had a material at all — the court lines were drawn in whatever the
		// engine's fallback material happened to look like.
		ApplySolidColorMaterial(LinesMesh, 0, LineColor);
	}

	private void AddLine(TArray<FVector>& Verts, TArray<int32>& Tris,
		TArray<FVector>& Normals, TArray<FVector2D>& UVs,
		FVector A, FVector B, float Width)
	{
		FVector Dir = (B - A).GetSafeNormal();
		FVector Side = FVector(-Dir.Y, Dir.X, 0) * Width * 0.5f;
		int Base = Verts.Num();

		Verts.Add(A - Side); Verts.Add(A + Side);
		Verts.Add(B + Side); Verts.Add(B - Side);

		Tris.Add(Base); Tris.Add(Base+1); Tris.Add(Base+2);
		Tris.Add(Base); Tris.Add(Base+2); Tris.Add(Base+3);

		for (int i = 0; i < 4; i++) Normals.Add(FVector(0,0,1));
		UVs.Add(FVector2D(0,0)); UVs.Add(FVector2D(1,0));
		UVs.Add(FVector2D(1,1)); UVs.Add(FVector2D(0,1));
	}

	// Two cylindrical posts
	private void BuildPosts()
	{
		TArray<FVector> V;
		TArray<int32> T;
		TArray<FVector> N;
		TArray<FVector2D> UV;
		TArray<FProcMeshTangent> Tan;

		int Segs = 8;
		AddCylinder(V, T, N, UV, FVector(0, -CourtHalfWidth - 30.0f, 0), PostRadius, PostHeight, Segs);
		AddCylinder(V, T, N, UV, FVector(0,  CourtHalfWidth + 30.0f, 0), PostRadius, PostHeight, Segs);

		PostsMesh.CreateMeshSection_LinearColor(0, V, T, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			TArray<FLinearColor>(), Tan, false, false);

		TArray<FLinearColor> C;
		for (int i = 0; i < V.Num(); i++) C.Add(PostColor);
		PostsMesh.UpdateMeshSection_LinearColor(0, V, N, UV,
			TArray<FVector2D>(), TArray<FVector2D>(), TArray<FVector2D>(),
			C, Tan, false);

		// Never had a material either (same as BuildLines above).
		ApplySolidColorMaterial(PostsMesh, 0, PostColor);
	}

	private void AddCylinder(TArray<FVector>& Verts, TArray<int32>& Tris,
		TArray<FVector>& Normals, TArray<FVector2D>& UVs,
		FVector Base, float Radius, float Height, int Segments)
	{
		int Offset = Verts.Num();
		for (int i = 0; i < Segments; i++)
		{
			float A = 2.0f * PI * i / Segments;
			float Nx = Math::Cos(A);
			float Ny = Math::Sin(A);
			Verts.Add(Base + FVector(Nx * Radius, Ny * Radius, 0));
			Verts.Add(Base + FVector(Nx * Radius, Ny * Radius, Height));
			Normals.Add(FVector(Nx, Ny, 0));
			Normals.Add(FVector(Nx, Ny, 0));
			UVs.Add(FVector2D(float(i)/Segments, 0));
			UVs.Add(FVector2D(float(i)/Segments, 1));
		}
		for (int i = 0; i < Segments; i++)
		{
			int A = Offset + i * 2;
			int B = Offset + ((i + 1) % Segments) * 2;
			Tris.Add(A);   Tris.Add(B);   Tris.Add(B+1);
			Tris.Add(A);   Tris.Add(B+1); Tris.Add(A+1);
		}
	}

	// Shipping-safe solid-colour material for this actor's procedural mesh sections.
	//
	// WHY THIS EXISTS — do not go back to /Engine/EngineDebugMaterials/*:
	// Court.as and Environment.as used to load VertexColorMaterial and
	// M_SimpleUnlitTranslucent from /Engine/EngineDebugMaterials/. Those render fine
	// in the editor but NEVER applied in a packaged Android build: every procedural
	// mesh came out with the engine's own fallback material instead. The give-away is
	// visible in any device screenshot — the sand is the only mesh whose UVs span
	// 0..1 (BuildSand), and it is the only one showing a checkerboard, because the
	// fallback material's checker texture gets stretched across that UV range; every
	// other mesh sets UV (0,0) on all verts, samples one texel, and comes out flat
	// cream (posts, court lines, and the water plane that should be filling the
	// horizon in blue). Force-cooking the debug materials via AlwaysCookMaps did not
	// help — they are editor/debug content and are not usable material assets in a
	// cooked Shipping build.
	//
	// BasicShapeMaterial is ordinary shipping content (it is the material the
	// /Engine/BasicShapes meshes use, and SpawnFallbackBox in VolleyballPlayer.as
	// already relies on it) and exposes a "Color" vector parameter, so a Dynamic
	// Material Instance per section gives each mesh its colour.
	//
	// TRADE-OFFS this makes, both deliberate:
	//  - It is LIT, where the debug materials were unlit. Sand/water now take the
	//    sunset directional light, which is what you want anyway.
	//  - It is OPAQUE and ignores vertex colour. So the sand's per-vertex crater/
	//    footprint darkening (SandColors) and the net band's see-through alpha are
	//    not rendered. The vertex colours are still written into the mesh sections,
	//    so an authored vertex-colour material would bring the crater feedback back
	//    for free. A genuinely see-through net needs either an authored translucent
	//    material or net-shaped geometry (thin strips) instead of a solid quad.
	//
	// A PRIVATE METHOD, deliberately duplicated in AEnvironment rather than shared:
	// this fork compiles each .as file as its own module, so a global function is
	// only visible inside its own file (note nothing in Script/ calls a global across
	// files — MotionPlan.as's MB_* helpers are used only within MotionPlan.as). A
	// shared helper in a new file is worse still: the cook loads scripts via a hot
	// reload, which does not even discover new .as files.
	//
	// Note the material is static-mesh-only: ProceduralMeshComponent is fine (it uses
	// the same local vertex factory), but do NOT use it on the skeletal player mesh —
	// that was tried and rejected at runtime with "missing bUsedWithSkeletalMesh=True!".
	// Typed to UProceduralMeshComponent rather than the UMeshComponent base because
	// this fork's bindings do not implicitly upcast the component handle.
	private UMaterialInstanceDynamic ApplySolidColorMaterial(UProceduralMeshComponent Comp, int Section, FLinearColor Color)
	{
		if (Comp == nullptr) return nullptr;

		UMaterialInterface Base = Cast<UMaterialInterface>(LoadObject(nullptr,
			"/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));
		if (Base == nullptr) return nullptr;

		UMaterialInstanceDynamic MID = Comp.CreateDynamicMaterialInstance(Section, Base);
		if (MID != nullptr)
			MID.SetVectorParameterValue(n"Color", Color);
		return MID;
	}
}
