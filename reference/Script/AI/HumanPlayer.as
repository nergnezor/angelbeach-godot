// Human player - inherits the full AI state machine and plays as a coordinated
// AI teammate until gamepad input is detected, then becomes player-controlled.

class AHumanPlayer : AAIPlayer
{
	UPROPERTY(DefaultComponent)
	UInputComponent ScriptInputComponent;

	// True once the player has pressed anything on the gamepad
	bool bPlayerControlled = false;

	// Input axes (used when bPlayerControlled == true)
	float AxisForward = 0.0f;
	float AxisRight = 0.0f;


	// Deliberately replaces AAIPlayer's BeginPlay/Tick (we gate the AI on
	// bPlayerControlled), so we intentionally do not call Super.
	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		InitPlayer();
		TeamSide = ETeam::Team_A;
		Role = EPlayerRole::Role_Back;
		Difficulty = 0.75f;

		CourtMinX = -900.0f;
		CourtMaxX = -5.0f;
		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;

		MoveSpeed = 420.0f + Difficulty * 220.0f;
		ReactionDelay = Math::Lerp(0.35f, 0.04f, Difficulty);

		// Bind input — only fires when this pawn is possessed
		ScriptInputComponent.BindAxis(n"MoveForward",   FInputAxisHandlerDynamicSignature(this, n"OnMoveForward"));
		ScriptInputComponent.BindAxis(n"MoveRight",     FInputAxisHandlerDynamicSignature(this, n"OnMoveRight"));
		ScriptInputComponent.BindAction(n"Jump",  EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnJump"));
		ScriptInputComponent.BindAction(n"Pass",  EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnPass"));
		ScriptInputComponent.BindAction(n"Set",   EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnSet"));
		ScriptInputComponent.BindAction(n"Spike", EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnSpike"));

		// No touch bindings here on purpose. Script in this fork cannot read the
		// raw touch stream at all: APlayerController.OnInputTouchBegin/End are
		// AActor's "this actor was touched" delegates (need collision, never fire
		// for a controller), APlayerController.GetInputTouchState isn't callable
		// with any argument spelling, and UInputComponent::BindTouch isn't bound.
		// So movement comes from the engine's virtual joystick via the ordinary
		// Gamepad_LeftX/Y axis mappings above (see Config/DefaultInput.ini), and
		// the action buttons come from HUD hit boxes (see ABeachVolleyballHUD).
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		UpdatePlayer(DeltaTime);

		if (Ball == nullptr) FindBall();

		// Split step reacts to opponent contacts at full frame rate (same as the
		// pure AI player — see AAIPlayer.Tick).
		UpdateSplitStep(DeltaTime);

		// Serve sequence owns the pawn (AI serves even for the human side until
		// gamepad serving exists). Runs through the follow-through past launch.
		if (bServing)
		{
			RunServeSequence(DeltaTime);
			return;
		}

		if (bPlayerControlled && Ball != nullptr && Ball.bInPlay)
		{
			// Direct control: player drives movement, hits via buttons
			MovePlayer(FVector2D(AxisForward, AxisRight));
			return;
		}

		// AI fallback — the SAME brain as AAIPlayer, not a copy of it: dead-ball
		// resets, perception latency and the reaction gate all included.
		RunAIBrain(DeltaTime);
	}

	// ---- Input handlers ----

	UFUNCTION()
	void OnMoveForward(float32 Value)
	{
		if (!bPlayerControlled && Math::Abs(Value) > 0.1f)
			TakeControl();
		AxisForward = Value;
	}

	UFUNCTION()
	void OnMoveRight(float32 Value)
	{
		if (!bPlayerControlled && Math::Abs(Value) > 0.1f)
			TakeControl();
		AxisRight = Value;
	}

	UFUNCTION()
	void OnJump(FKey Key)
	{
		DoJump();
	}

	UFUNCTION()
	void OnPass(FKey Key)
	{
		DoPass();
	}

	UFUNCTION()
	void OnSet(FKey Key)
	{
		DoSet();
	}

	UFUNCTION()
	void OnSpike(FKey Key)
	{
		DoSpike();
	}

	// ---- Touch input (Android on-screen controls; see ABeachVolleyballHUD) ----
	// The HUD drives these directly instead of the FKey-based handlers above:
	// there is no real key behind a screen tap, and the axis handlers already
	// take a plain float so they need no touch-specific twin.

	void TouchMove(float32 Forward, float32 Right)
	{
		OnMoveForward(Forward);
		OnMoveRight(Right);
	}

	void TouchJump()  { DoJump(); }
	void TouchPass()  { DoPass(); }
	void TouchSet()   { DoSet(); }
	void TouchSpike() { DoSpike(); }

	private void DoJump()
	{
		if (!bPlayerControlled) TakeControl();
		Jump();
	}

	private void DoPass()
	{
		if (!bPlayerControlled) TakeControl();
		if (Ball == nullptr) FindBall();
		TryPass(Ball);
	}

	private void DoSet()
	{
		if (!bPlayerControlled) TakeControl();
		if (Ball == nullptr) FindBall();
		TrySet(Ball);
	}

	private void DoSpike()
	{
		if (!bPlayerControlled) TakeControl();
		if (Ball == nullptr) FindBall();
		TrySpike(Ball);
	}

	private void TakeControl()
	{
		bPlayerControlled = true;
		Print("Player control activated!");
	}
}
