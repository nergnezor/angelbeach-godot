// End-zone camera: fixed behind Team A's baseline, tilts up to follow the ball
class ABeachVolleyballCamera : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCameraComponent CameraComp;

	// Fixed camera behind Team A's baseline, looking down the length of the court.
	//
	// HEIGHT IS THE DEPTH CUE. At the old 420 the view was almost level with the
	// sand, which foreshortens the court so hard that 16 m of depth collapsed into a
	// thin band — the whole playfield occupied barely a third of the frame height and
	// there was no way to judge how far apart anyone stood. Lifting the eye to 900
	// opens the court back out into a readable rectangle: near and far baselines
	// separate, the gap between players becomes a distance you can actually see, and
	// the long shadows the low sun throws land inside frame instead of off the bottom.
	//
	// 560, and the distance stays at the original 1050. Both numbers are the result of
	// overshooting first:
	//   900 @ -1250 — far too steep. The court shrank to a small rectangle mid-frame
	//                 with a big empty foreground, and the horizon rode up so high the
	//                 sunset stopped working as a backdrop.
	//   640 @ -1100 — better, but moving the camera BACK while raising it shrinks the
	//                 players; readability of the figures went down, not up.
	// Raising the eye is what buys depth; moving back only costs size. So lift, and
	// stay put. At 560 the two court halves, the net's footprint on the sand and the
	// gaps between players all read, while the near player is still large in frame.
	FVector CamPos = FVector(-1050, 0, 560);

	// Aim slightly above the sand rather than at it, which keeps the horizon (and the
	// sunset) in the upper third instead of tipping it out of frame.
	FVector CurrentLookAt = FVector(0, 0, 140);

	float FollowSpeed = 4.0f;

	UPROPERTY()
	ABall Ball;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		SetActorLocation(CamPos);

		APlayerController PC = Gameplay::GetPlayerController(0);
		if (PC != nullptr)
			PC.SetViewTargetWithBlend(this, 0.0f);

		FindBall();
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		if (Ball == nullptr) FindBall();

		// Look at court centre; follow the ball's height only gently and clamp it so
		// the camera never tilts up into empty sky on high balls.
		FVector Target = FVector(0, 0, 140);
		if (Ball != nullptr && Ball.bInPlay)
			Target.Z = Math::Clamp(140.0f + Ball.Position.Z * 0.25f, 140.0f, 320.0f);

		// Smooth tilt toward target
		float Alpha = Math::Clamp(FollowSpeed * DeltaTime, 0.0f, 1.0f);
		CurrentLookAt = CurrentLookAt + (Target - CurrentLookAt) * Alpha;

		FVector LookDir = (CurrentLookAt - CamPos).GetSafeNormal();
		SetActorRotation(LookDir.Rotation());
	}

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
