// HUD placeholder - score display is handled via UMG or future widget implementation.
//
// What this actually draws is the Android action buttons: Jump/Pass/Set/Spike in
// a diamond in the bottom-right corner, the touch equivalent of the
// Space/E/LeftShift/F bindings in DefaultInput.ini. MOVEMENT IS NOT DRAWN HERE —
// it is the engine's own virtual joystick overlay, configured in
// Config/DefaultInput.ini, which needs no script at all.
//
// WHY IT IS SPLIT THAT WAY. Script in this fork cannot read the raw touch stream:
// APlayerController.OnInputTouchBegin/End are AActor's "this actor was touched"
// delegates (they need collision and never fire for a controller — that shipped a
// build where every control drew perfectly and did nothing),
// APlayerController.GetInputTouchState would not compile with any spelling of its
// first argument, and UInputComponent::BindTouch is not bound either. What IS
// available is AHUD's hit box system, which the engine itself routes touches
// into, so the buttons are registered as hit boxes each frame and answered in
// HitBoxClick below. A joystick cannot be built out of hit boxes (it needs
// continuous finger tracking), hence the engine overlay for movement.
//
// Drawn with AHUD::DrawRect/DrawText (no textures) to match the "no binary assets
// in git" rule in CLAUDE.md. Desktop/gamepad players never see any of it:
// GM.IsMobilePlatform() gates the whole thing, and AHumanPlayer plays itself as
// AI until real input arrives.
//
// GM is wired by ABeachVolleyballGameMode.SpawnActors (there is no
// BlueprintCallable "get the game mode" on UWorld/AActor in this fork — GameMode
// pushes the reference down to whoever needs it, same as for ABall and
// AHumanPlayer).

class ABeachVolleyballHUD : AHUD
{
	ABeachVolleyballGameMode GM;

	// Updated every DrawHUD; the hit boxes are registered from the same numbers
	// in the same pass, so the drawn button and its touch target cannot drift.
	private float ScreenSizeX = 1280.0f;
	private float ScreenSizeY = 720.0f;

	private const float ButtonRadius = 48.0f;

	UFUNCTION(BlueprintOverride)
	void DrawHUD(int SizeX, int SizeY)
	{
		if (GM == nullptr || !GM.IsMobilePlatform())
			return;

		ScreenSizeX = float(SizeX);
		ScreenSizeY = float(SizeY);

		DrawButton(JumpCenter(),  "Jump",  n"BtnJump");
		DrawButton(PassCenter(),  "Pass",  n"BtnPass");
		DrawButton(SetCenter(),   "Set",   n"BtnSet");
		DrawButton(SpikeCenter(), "Spike", n"BtnSpike");
	}

	// ---- Layout (screen space, anchored to the bottom-right corner) --------
	// Kept clear of the engine joystick overlay: its right stick sits around
	// three-quarters across the screen, this cluster hugs the corner.

	private FVector2D ClusterCenter() const
	{
		return FVector2D(ScreenSizeX - 200.0f, ScreenSizeY - 220.0f);
	}

	private FVector2D JumpCenter()  const { return ClusterCenter() + FVector2D(0.0f, 90.0f); }
	private FVector2D PassCenter()  const { return ClusterCenter() + FVector2D(-90.0f, 0.0f); }
	private FVector2D SpikeCenter() const { return ClusterCenter() + FVector2D(90.0f, 0.0f); }
	private FVector2D SetCenter()   const { return ClusterCenter() + FVector2D(0.0f, -90.0f); }

	// ---- Drawing + hit boxes -------------------------------------------------

	// No GetTextSize on this HUD build, so labels aren't pixel-centred — just
	// nudged by a rough half-width guess. Cosmetic only; the hit box is the real
	// touch target and it is registered from the button rect, not the text.
	private void DrawButton(FVector2D Center, FString Label, FName BoxName)
	{
		FVector2D TopLeft = Center - FVector2D(ButtonRadius, ButtonRadius);
		FVector2D Size = FVector2D(ButtonRadius * 2.0f, ButtonRadius * 2.0f);

		DrawRect(FLinearColor(0.0f, 0.0f, 0.0f, 0.30f),
			TopLeft.X, TopLeft.Y, Size.X, Size.Y);

		float ApproxHalfWidth = Label.Len() * 4.0f;
		DrawText(Label, FLinearColor(1.0f, 1.0f, 1.0f, 0.85f),
			Center.X - ApproxHalfWidth, Center.Y - 8.0f, nullptr, 1.0f, false);

		// Consumes the touch so a tap on a button never also reaches the world.
		AddHitBox(TopLeft, Size, BoxName, true, 0);
	}

	// ---- Button presses ----------------------------------------------------

	UFUNCTION(BlueprintOverride)
	void HitBoxClick(FName BoxName)
	{
		AHumanPlayer Pawn = (GM != nullptr) ? GM.HumanPawn : nullptr;
		if (Pawn == nullptr)
			return;

		if (BoxName == n"BtnJump")       Pawn.TouchJump();
		else if (BoxName == n"BtnPass")  Pawn.TouchPass();
		else if (BoxName == n"BtnSet")   Pawn.TouchSet();
		else if (BoxName == n"BtnSpike") Pawn.TouchSpike();
	}
}
