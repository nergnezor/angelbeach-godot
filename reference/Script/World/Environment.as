// Surrounding environment: the sea, and the SKY DOME that stands in for
// SkyAtmosphere on mobile.
//
// WHY THERE IS A DOME AT ALL. Android has SkyAtmosphere disabled (it wants an
// authored sky mesh; re-enabling it was tested and rendered nothing), so for a
// long time nothing drew the sky and device screenshots had a black band across
// the top of frame. Three attempts to make ExponentialHeightFog cover for it all
// failed — falloff 0.5, 0.2 and 0.02 — because height fog only tints RENDERED
// GEOMETRY. The bright region under the black band was never sky: it was the
// water plane receding to the horizon, fully fogged. The "seam" was the horizon
// itself, and above it there is no geometry for fog to colour. No fog setting
// can paint an empty background.
//
// So the sky needs to BE geometry. This is the same move that fixed the net:
// when an engine feature will not apply on mobile, build the thing out of
// procedural geometry and the one material that is known to work.
//
// The dome sits INSIDE the fog's start distance on purpose, so the gradient is
// never hazed away.
//
// THE DOME IS ALSO THE SEA, and there is no water plane any more. A flat water
// quad was tried for a long time and never once rendered blue. Measuring at
// x=600 in build 175 settled that it was not being drawn as sea at all: every
// pixel from the horizon down to the sand edge was (193,127,69), the dome's own
// warm horizon band, with no water band anywhere in between.
//
// CORRECTION to what this comment used to claim: BasicShapeMaterial does expose
// a real "Roughness" scalar parameter (checked directly in
// Engine/Content/BasicShapes/BasicShapeMaterial.uasset — it has both a
// MaterialExpressionVectorParameter "Color" and a MaterialExpressionScalarParameter
// "Roughness"), so the SetScalarParameterValue calls were NOT silent no-ops and
// that was never the reason. The quad is gone anyway because a dome band is the
// simpler thing: at these grazing angles a distant wall and a flat plane are
// indistinguishable, and colouring the bands below the horizon as sea removes a
// whole surface — and its reflections — rather than tuning them.
class AEnvironment : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	USceneComponent Root;

	UPROPERTY(DefaultComponent, Attach = Root)
	UProceduralMeshComponent SkyMesh;

	// Dome radius must clear the whole playfield (sand corners reach ~1580, the
	// match camera sits 1400 out) and stay under the fog's start distance so the
	// gradient is not hazed away.
	//
	// 3000 was too tight. The sand skirt now reaches 900 along the view axis, so
	// it left only ~700 units of sea between the beach and the dome — a sliver
	// that vanished into the horizon, and every sample below the horizon came
	// back sand-coloured. 5000 gives the sea roughly 4000 units to be a sea in.
	// The fog start moves with it (GameMode.as).
	const float SkyRadius    = 5000.0f;
	// Each band is a separate mesh section, so band count is also the draw-call
	// count for the sky — 40 is a deliberate ceiling. It is needed because a solid
	// colour per band means the gradient can only ever be a staircase, and at 18
	// bands the steps were visible as stripes across the sky. 32 segments is
	// plenty around the horizontal now that the seams sit closer together.
	const int   SkyBands     = 40;
	const int   SkySegments  = 32;
	// The dome runs well below the horizon because these lower bands ARE the sea.
	const float SkyBottomDeg = -30.0f;

	// THESE BLUES LOOK ABSURD ON PURPOSE — read this before "fixing" them.
	//
	// The scene light is deeply warm (sun 1.0/0.6/0.35, and the sky light bounces
	// off this dome, which is warm too). Measuring the sand pins down what that
	// does: albedo (0.62,0.52,0.36) renders (122,82,43), i.e. a per-channel gain
	// of (0.314,0.162,0.067). Blue comes out at 21% of red. Any honest blue albedo
	// is crushed to grey-brown, which is exactly why the sea has been warm cream
	// in every screenshot and why the zenith band came out (136,81,47) instead of
	// the dark blue it was set to.
	//
	// So the albedos are pre-divided by that gain. Blue above 1.0 is not a
	// mistake: it is what it costs to land a dusk blue through a warm light.
	//   zenith -> linear (0.015,0.035,0.090)
	//   sea    -> linear (0.010,0.023,0.096)
	// If the lighting is ever retuned, re-measure the gain and redo this division
	// rather than eyeballing new numbers.
	private FLinearColor SkySeaColor     = FLinearColor(0.03f, 0.14f, 0.85f, 1.0f);
	private FLinearColor SkyHorizonColor = FLinearColor(0.95f, 0.58f, 0.34f, 1.0f);
	private FLinearColor SkyZenithColor  = FLinearColor(0.05f, 0.22f, 1.34f, 1.0f);

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		BuildSky();
	}

	// Deliberate duplicate of ACourt::ApplySolidColorMaterial (see there for why
	// BasicShapeMaterial and what it trades off). It cannot be shared: this fork
	// compiles each .as file as its own module, so a global function is only
	// visible inside its own file — nothing in Script/ calls a global across files.
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

	// Banded dome: each elevation band is its own mesh section with its own solid
	// colour, so a stepped gradient stands in for a real sky material.
	private void BuildSky()
	{
		// CRITICAL: a closed dome around the whole scene that casts shadows would
		// occlude the directional light — the sun sits at pitch -6, so its rays
		// come in through the dome WALL — and put the entire court in shadow.
		SkyMesh.SetCastShadow(false);

		for (int b = 0; b < SkyBands; b++)
		{
			float t0 = float(b) / float(SkyBands);
			float t1 = float(b + 1) / float(SkyBands);
			float E0 = (SkyBottomDeg + (90.0f - SkyBottomDeg) * t0) * PI / 180.0f;
			float E1 = (SkyBottomDeg + (90.0f - SkyBottomDeg) * t1) * PI / 180.0f;

			TArray<FVector> V; TArray<int32> T; TArray<FVector> N;
			TArray<FVector2D> UV; TArray<FLinearColor> C;
			TArray<FVector2D> NoUV; TArray<FProcMeshTangent> Tan;

			FLinearColor Col = SkyBandColor((t0 + t1) * 0.5f);

			for (int s = 0; s < SkySegments; s++)
			{
				float A0 = 2.0f * PI * s / SkySegments;
				float A1 = 2.0f * PI * (s + 1) / SkySegments;

				int B = V.Num();
				V.Add(SkyPoint(A0, E0)); V.Add(SkyPoint(A1, E0));
				V.Add(SkyPoint(A1, E1)); V.Add(SkyPoint(A0, E1));

				// Both windings. The dome is viewed from the inside, and emitting
				// the back faces too costs a few hundred triangles while making it
				// impossible to get the winding order backwards and end up with an
				// invisible sky.
				T.Add(B+0); T.Add(B+1); T.Add(B+2);
				T.Add(B+0); T.Add(B+2); T.Add(B+3);
				T.Add(B+0); T.Add(B+2); T.Add(B+1);
				T.Add(B+0); T.Add(B+3); T.Add(B+2);

				for (int i = 0; i < 4; i++)
				{
					// Normal up, not outward: the material is lit, and a uniform
					// normal means every band takes identical lighting. The gradient
					// then comes purely from the albedos below, which is predictable
					// — an outward normal would shade each band by its own angle to
					// the sun and fight the gradient.
					N.Add(FVector(0, 0, 1));
					UV.Add(FVector2D(0, 0));
					C.Add(Col);
				}
			}

			SkyMesh.CreateMeshSection_LinearColor(b, V, T, N, UV, NoUV, NoUV, NoUV, C, Tan, false);
			ApplySolidColorMaterial(SkyMesh, b, Col);
		}
	}

	private FVector SkyPoint(float Azimuth, float Elevation) const
	{
		float CosE = Math::Cos(Elevation);
		return FVector(Math::Cos(Azimuth) * CosE * SkyRadius,
			Math::Sin(Azimuth) * CosE * SkyRadius,
			Math::Sin(Elevation) * SkyRadius);
	}

	// Sea -> warm horizon -> zenith, over the part of the dome you can actually SEE.
	//
	// T runs 0..1 across the dome's full -30..90 degrees, but the match camera
	// shows very little of that. Getting this wrong has put the interesting colour
	// off-screen twice already: sqrt(T) climbed too fast and bleached the horizon,
	// then T*T went the other way and left the top of frame only 39% of the way to
	// blue. Widening it to complete at 42 degrees was still too generous — in the
	// letterboxed 2640x1080 view the top of frame is only about 20 degrees up, and
	// the sky measured (166,121,121) there: mauve, not the intended blue.
	//
	// So the transition completes at 25 degrees, and the band BELOW the horizon
	// runs from the warm strip down into sea blue over about 12 degrees. What you
	// get in frame is the classic sunset stack: dark sea, a bright warm band at
	// the waterline, blue above.
	private FLinearColor SkyBandColor(float T) const
	{
		// Elevation 0 is T=0.25; -12 degrees is T=0.15; +25 degrees is T=0.458.
		if (T <= 0.25f)
		{
			float k = Math::Clamp((T - 0.15f) / 0.10f, 0.0f, 1.0f);
			k = k * k * (3.0f - 2.0f * k);
			return Blend(SkySeaColor, SkyHorizonColor, k);
		}

		float k = Math::Clamp((T - 0.25f) / 0.208f, 0.0f, 1.0f);
		k = k * k * (3.0f - 2.0f * k);
		return Blend(SkyHorizonColor, SkyZenithColor, k);
	}

	private FLinearColor Blend(FLinearColor A, FLinearColor B, float K) const
	{
		return FLinearColor(
			A.R + (B.R - A.R) * K,
			A.G + (B.G - A.G) * K,
			A.B + (B.B - A.B) * K,
			1.0f);
	}

}
