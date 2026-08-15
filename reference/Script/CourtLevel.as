// Level script: directional light, sky atmosphere, ambient setup

class ACourtLevelScript : ALevelScriptActor
{
	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		SetupLighting();
		SetupPostProcess();
		SpawnCamera();
	}

	private void SetupLighting()
	{
		SpawnActor(ADirectionalLight,
			FVector(0, 0, 10000), FRotator(-8, -55, 0));

		SpawnActor(ASkyAtmosphere,
			FVector::ZeroVector, FRotator::ZeroRotator);

		SpawnActor(ASkyLight,
			FVector(0, 0, 500), FRotator::ZeroRotator);

		SpawnActor(AExponentialHeightFog,
			FVector(0, 0, 100), FRotator::ZeroRotator);
	}

	private void SetupPostProcess()
	{
	}

	private void SpawnCamera()
	{
		SpawnActor(ABeachVolleyballCamera,
			FVector(0, -1400, 350), FRotator(0, 90, 0));
	}
}
