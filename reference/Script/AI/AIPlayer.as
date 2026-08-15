// AI player - volleyball state machine: Receive -> Set -> Attack with proper
// roles, height-aware contacts, and team coordination (no flip-flopping).

enum EPlayerRole { Role_Back, Role_Front }

class AAIPlayer : AVolleyballPlayer
{
	UPROPERTY(BlueprintReadWrite) float Difficulty = 0.75f;
	UPROPERTY(BlueprintReadWrite) EPlayerRole Role = EPlayerRole::Role_Back;
	UPROPERTY() ABall Ball;
	UPROPERTY() AAIPlayer Teammate;  // the other player on this team

	float ReactionDelay = 0.0f;
	float ReactionTimer = 0.0f;

	// True if I made my team's most recent contact — so my teammate takes the
	// next touch (digger != setter != attacker), preventing one player from
	// making all three touches and committing a fourth-touch fault.
	bool bIMadeLastTouch = false;

	// --- Contact-height windows (relative to ball Z) ---
	// Dig:   ball low, near waist/chest      -> bump it up
	// Set:   ball at chest/head height       -> soft high arc
	// Spike: ball above head while airborne  -> drive it down
	const float DigMaxZ   = 130.0f;   // ball below this = dig
	const float SetMinZ   = 110.0f;
	const float SetMaxZ   = 220.0f;
	const float SpikeMinZ = 200.0f;   // need a jump to reach

	void Setup(ETeam Team, EPlayerRole InRole, float InDifficulty,
		ABall InBall, ASandFX InSand, ACourt InCourt, ABeachVolleyballGameMode InGM)
	{
		TeamSide = Team;
		Role = InRole;
		Difficulty = InDifficulty;
		Ball = InBall;
		Sand = InSand;
		Court = InCourt;
		GM = InGM;
		MoveSpeed = 420.0f + Difficulty * 220.0f;
		ReactionDelay = Math::Lerp(0.35f, 0.04f, Difficulty);

		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;
		if (Team == ETeam::Team_A) { CourtMinX = -900.0f; CourtMaxX = -5.0f; }
		else                       { CourtMinX =    5.0f; CourtMaxX = 900.0f; }
	}

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		InitPlayer();
		CourtMinX = -900.0f; CourtMaxX = -5.0f;
		CourtMinY = -450.0f; CourtMaxY = 450.0f;
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		UpdatePlayer(DeltaTime);
		if (Ball == nullptr) FindBall();

		// Split step runs at full frame rate (not gated by ReactionDelay) so the
		// dip lands exactly on the opponent's contact.
		UpdateSplitStep(DeltaTime);

		// Dead ball (between points / before serve): WALK to my ready position so
		// the next rally starts from a proper formation — nobody sprints between
		// points. Also clear touch ownership: it must NOT leak into the next
		// rally, or last rally's final toucher refuses the serve receive and the
		// wrong (far) player has to scramble for it.
		// A serve in progress owns the player until the follow-through completes —
		// note this is checked BEFORE the dead-ball branch because the ball goes
		// live at the strike (phase 0.78) while the gesture runs to 1.0.
		if (bServing)
		{
			RunServeSequence(DeltaTime);
			return;
		}

		RunAIBrain(DeltaTime);
	}

	// The dead-ball reset, perception latency and reaction gate, in one place.
	// AHumanPlayer runs the same brain as its fallback and used to carry its own
	// copy of this sequence — a copy that had drifted: it was missing the whole
	// perception-latency block and every per-rally reset, so Team A's back player
	// reacted to ball events with zero delay and carried stale commitment flags
	// (bIntendSet, bOnTwoDecided, a plant that PLANVA measures settle time from)
	// across rallies. It was also the player that logs nothing, since bDebugAI is
	// only set on B1/B2. Shared, it cannot diverge again.
	// Returns true if the caller should stop here for this frame.
	protected bool RunAIBrain(float DeltaTime)
	{
		if (Ball == nullptr || !Ball.bInPlay)
		{
			bIMadeLastTouch = false;
			PlanSlackLog = -1.0f;   // an unconsumed promise must not leak into the next rally
			bHitterPlanted = false; // ...nor a stale plant (PLANVA settle counts from it)
			PlantedFor = 0.0f;
			bOnTwoDecided = false;  // per-ball decisions die with the ball
			bChoseOnTwo = false;
			bIntendSet = false;
			bOnTwoLoggedNotViable = false;
			bSpikeCueOn = false;    // a committed attack cue must not outlive its ball
			MoveToHold(ReadyPosition(), DeltaTime, 0.5f);
			PreFaceForServe();
			return true;
		}

		// PLAN vs ACTUAL bookkeeping: how long the hitter has stood planted
		// (read by OnBallContact's PLANVA telemetry line).
		PlantedFor = bHitterPlanted ? PlantedFor + DeltaTime : 0.0f;

		// PERCEPTION LATENCY (first principles): a ball EVENT — any touch, the
		// serve going live — is not seen instantly. The previous action keeps
		// running for a visual-reaction beat before any re-planning; stored
		// move input and the facing hold carry the old intent through the gap.
		// The split step is exempt above: it is anticipatory, not a reaction.
		ABeachVolleyballGameState PGS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		int PerceptStamp = (PGS != nullptr)
			? int(PGS.LastTouchTeam) * 100 + PGS.TouchesThisRally + (Ball.bInPlay ? 1000 : 0)
			: -1;
		if (PerceptStamp != PrevPerceptStamp)
		{
			PrevPerceptStamp = PerceptStamp;
			PerceptionTimer = PerceptionLatency;
		}
		if (PerceptionTimer > 0.0f)
		{
			PerceptionTimer -= DeltaTime;
			return true;
		}

		ReactionTimer += DeltaTime;
		if (ReactionTimer < ReactionDelay) return true;
		ReactionTimer = 0.0f;

		UpdateAI(DeltaTime);
		return false;
	}

	// Human visual reaction to an unanticipated event (~0.16s). Separate from
	// ReactionDelay (the decision cadence): this one fires per EVENT.
	const float PerceptionLatency = 0.16f;
	private float PerceptionTimer = 0.0f;
	private int PrevPerceptStamp = -12345;

	// Formation spot to occupy while the ball is dead, depending on whether our
	// team is serving or receiving:
	//  - RECEIVING team: both players spread across mid-court, one per Y half, ready
	//    to dig the serve.
	//  - SERVING team: the server (back) stands behind the baseline; the non-server
	//    (front) waits up at the net.
	// By convention the Back-role player is the server.
	protected FVector ReadyPosition() const
	{
		float Sign = MySign();
		float Z = FloorZ + PlayerHeight;

		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		bool bWeServe = (GS != nullptr && GS.ServingTeam == TeamSide);

		if (bWeServe)
		{
			if (Role == EPlayerRole::Role_Back)
				return FVector(Sign * 820.0f, 0.0f, Z);     // server behind the baseline
			else
				return FVector(Sign * 130.0f, 0.0f, Z);     // partner up at the net
		}

		return HomePosition();
	}

	// Stable base position for each role. This is where a player resets while
	// the opponent constructs its play and when supporting a teammate: do not
	// chase a ball that is not ours. The front/back depth keeps two useful
	// options while the small Y split covers the court without both players
	// wandering toward every lateral ball movement.
	private FVector HomePosition() const
	{
		float Sign = MySign();
		float X = (Role == EPlayerRole::Role_Front) ? 250.0f : 560.0f;
		float Y = (Role == EPlayerRole::Role_Front) ? -120.0f : 120.0f;
		return FVector(Sign * X, Y, FloorZ + PlayerHeight);
	}

	// ---------------------------------------------------------------
	// Serve — a real motion, not a ball teleport: the server walks to the
	// baseline, tosses with the LEFT hand (the ball rides the hand up), draws the
	// right arm back, strikes overhead and follows through. The ball launches at
	// the strike moment, from the strike point. GameMode starts this via
	// BeginServe(); RunServeSequence ticks it while the ball is dead.
	// ---------------------------------------------------------------
	protected bool bServing = false;
	private float ServeSeqTimer = 0.0f;
	private bool bServeLaunched = false;
	private FVector PendingServeVel;
	// Toss free-flight state: the ball is RELEASED from the left hand and flies
	// ballistically (computed here — it isn't in play yet) until the strike.
	private bool bTossReleased = false;
	private FVector TossVel;
	private FVector TossReleasePos;
	private float TossReleaseTime = 0.0f;
	const float TossReleasePhase = 0.55f;   // left hand lets go
	const float ServeStrikePhase = 0.78f;   // right hand meets the ball
	// Unhurried, like a real serve ritual (~2s toss->strike). Also required: the
	// Anim BP's FBIK effectors interpolate toward their targets with limited
	// speed, so a faster choreography outruns the arms (the toss never rose when
	// this was 1.15s — the hand lagged half a metre behind its target).
	const float ServeSeqDuration = 1.9f;

	void BeginServe(FVector ServeVel)
	{
		bServing = true;
		bServeLaunched = false;
		bTossReleased = false;
		ServeSeqTimer = 0.0f;
		PendingServeVel = ServeVel;
	}

	// While waiting at the baseline as the upcoming server, face the court — the
	// serve ritual must not start with a 180° pirouette (the toss hand swings
	// around with the turning body and the carry starts at the hip).
	//
	// Gated on bHolding (MoveToHold's "arrived and standing still" flag, set by
	// the MoveToHold(ReadyPosition(), ...) call this same tick, just above ours
	// in the dead-ball branch): forcing the net-facing unconditionally, from the
	// moment the ball goes dead, held it for the ENTIRE walk back to the baseline
	// spot — including legs whose actual travel was AWAY from the net. Facing
	// net while translating away from it is a backward walk (MoveDirAngle ≈
	// 180), which is exactly the "runs toward the net but moves backwards" look.
	// Waiting for arrival means the turn happens while planted (pure rotation,
	// no translation to mismatch), well before RunServeSequence needs it.
	protected void PreFaceForServe()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr || GS.ServingTeam != TeamSide || Role != EPlayerRole::Role_Back)
			return;
		if (!bHolding)
			return;
		FacingDir = FVector(-MySign(), 0, 0);
		bHasFacing = true;
	}

	protected void RunServeSequence(float Dt)
	{
		if (Ball == nullptr) { bServing = false; ServePhase = 0.0f; return; }

		ServeSeqTimer += Dt;
		ServePhase = Math::Clamp(ServeSeqTimer / ServeSeqDuration, 0.0f, 1.0f);

		// Face the opponent court; the IK choreography runs off ServePhase.
		FacingDir = FVector(-MySign(), 0, 0);
		bHasFacing = true;
		Reach(EHitType::Hit_Serve);
		MovePlayer(FVector2D::ZeroVector);

		// A REAL toss: the ball rides the left hand up, is RELEASED into a short
		// free flight (up and back down to release height — a precise beach
		// toss), and launches only when the right hand whips through at the
		// strike phase. Launching straight off the glued hand made the ball
		// simply fly away from the left hand with no toss and no visible strike.
		if (!bServeLaunched && Mesh != nullptr)
		{
			if (ServePhase < TossReleasePhase)
			{
				FVector Carry = Mesh.GetBoneTransform(n"hand_l").Location + FVector(0, 0, 16);
				Ball.Position = Carry;
				Ball.BallVel = FVector::ZeroVector;
				Ball.SetActorLocation(Carry);
			}
			else if (ServePhase < ServeStrikePhase)
			{
				if (!bTossReleased)
				{
					bTossReleased = true;
					// Symmetric flight: peaks mid-window and returns to release
					// height exactly at the strike, so the ball is back where the
					// choreographed strike hand (StrikeR ≈ toss apex) meets it.
					TossReleasePos = Ball.Position;
					TossReleaseTime = ServeSeqTimer;
					float TFree = (ServeStrikePhase - TossReleasePhase) * ServeSeqDuration;
					TossVel = FVector(0, 0, 490.0f * TFree);
				}
				// CLOSED-FORM flight, not per-frame Euler: HighResShot hitches
				// (0.3-0.5s frames during filming) fed giant steps into the Euler
				// toss and slammed the ball to waist height before the strike —
				// the analytic parabola is immune to frame time.
				float T = ServeSeqTimer - TossReleaseTime;
				FVector TossPos = TossReleasePos
					+ FVector(0, 0, TossVel.Z * T - 490.0f * T * T);
				Ball.Position = TossPos;
				Ball.SetActorLocation(TossPos);
			}
			else
			{
				// Strike: launch from wherever the toss actually is. The contact
				// cooldown stops the ball bouncing off the server's own raised
				// hands on its first in-play frame (it starts near the strike hand).
				bServeLaunched = true;
				Ball.Launch(Ball.Position, PendingServeVel);
				Ball.PlayerHitCooldown = 0.35f;
				if (GM != nullptr)
					GM.OnServeLaunched();
			}
		}

		if (ServePhase >= 1.0f)
		{
			bServing = false;
			ServePhase = 0.0f;
		}
	}

	// ---------------------------------------------------------------
	// Main decision loop (protected so AHumanPlayer can reuse it as its
	// AI fallback when no gamepad input is active)
	// ---------------------------------------------------------------
	protected void UpdateAI(float DeltaTime)
	{
		// Ball is on the opponent's side: play DEFENSE and clear our touch-ownership
		// so the next receive starts fresh.
		if (!IsBallComingToMySide())
		{
			bIMadeLastTouch = false;
			bOnTwoDecided = false;
			bChoseOnTwo = false;
			bIntendSet = false;
			bOnTwoLoggedNotViable = false;
			PlayDefense(DeltaTime);
			return;
		}

		int Touches = TeamTouches();          // how many times WE have touched it
		FVector Landing = Ball.PredictLanding();

		// Decide my job for this contact based on touch count + role
		if (AmIHitter(Landing))
		{
			if (bDebugAI) Log(DebugTag() + " HITTER t=" + Touches + " ballZ=" + int(Ball.Position.Z) + " grounded=" + bIsGrounded);
			PlayHitter(Touches, DeltaTime);
		}
		else
		{
			if (bDebugAI) Log(DebugTag() + " SUPPORT t=" + Touches);
			PlaySupport(Landing, DeltaTime);
		}
	}

	// Temporary diagnostics — set true on ONE player from GameMode to inspect.
	bool bDebugAI = false;
	private FString DebugTag() const
	{
		FString T = (TeamSide == ETeam::Team_A) ? "A" : "B";
		FString R = (Role == EPlayerRole::Role_Front) ? "Front" : "Back";
		return T + "/" + R;
	}

	// ---------------------------------------------------------------
	// Role assignment — deterministic so the two players never swap
	// mid-rally and end up chasing the same ball.
	// ---------------------------------------------------------------
	private bool AmIHitter(FVector Landing)
	{
		if (Teammate == nullptr) return true;

		// I never take two contacts in a row — if I made the last touch, it's
		// my teammate's turn now. This guarantees digger != setter != attacker.
		if (bIMadeLastTouch)          { bWasHitter = false; return false; }
		if (Teammate.bIMadeLastTouch) { bWasHitter = true;  return true;  }

		// Fresh ball coming over (no team touches yet): closest player digs,
		// with the back player favored for deep balls (typical serve receive).
		float MyDist    = (GetActorLocation() - Landing).Size2D();
		float TheirDist = (Teammate.GetActorLocation() - Landing).Size2D();

		bool bDeep = IsDeep(Landing.X);
		if (bDeep && Role == EPlayerRole::Role_Back)  { bWasHitter = true;  return true;  }
		if (bDeep && Role == EPlayerRole::Role_Front) { bWasHitter = false; return false; }

		// STICKY ROLE: with a bare closest-player rule, two nearly equidistant
		// teammates swapped hitter/support every AI tick and both shuttled
		// between two goals. The incumbent keeps the ball unless the partner
		// is CLEARLY closer.
		float Margin = bWasHitter ? 60.0f : -60.0f;
		bWasHitter = MyDist <= TheirDist + Margin;
		return bWasHitter;
	}

	// Hysteresis state for AmIHitter (who owns the current ball).
	private bool bWasHitter = false;

	// Attack-on-two decision, made once per second ball (see PlayHitter).
	private bool bOnTwoDecided = false;
	private bool bChoseOnTwo = false;

	// Sticky set-vs-bump intention for the second touch (hysteresis ±0.15s
	// of slack — see PlayHitter).
	private bool bIntendSet = false;
	private bool bOnTwoLoggedNotViable = false;
	private int SetIntentLogs = 0;

	// Hysteresis state for the hitter's plant (see PlayHitter).
	private bool bHitterPlanted = false;

	// ---------------------------------------------------------------
	// I am the player who will contact the ball this touch
	// ---------------------------------------------------------------
	private void PlayHitter(int Touches, float DeltaTime)
	{
		if (Touches >= 2)
		{
			// ATTACK: get under a high ball, jump, and spike at the peak
			ApproachForSpike(DeltaTime);
			return;
		}

		// ATTACK ON TWO: a perfect reception hangs through the strike zone, and
		// the second toucher then holds BOTH options — jump on it, or pass to
		// the partner — committing as late as the physics allow. Viability is
		// re-proven every tick against the jump budget; the moment it collapses
		// (ball dropped, plant unreachable) we fall through to the set below,
		// so the pass option stays open until just before contact. The choice
		// itself is made ONCE per ball (sticky — a flip-flopping intention is
		// exactly what the anti-flicker work exists to prevent).
		if (Touches == 1)
		{
			FVector Strike2;
			float Tau2 = PredictBallTimeToHeight(SpikeStrikeZ(), Strike2);
			bool bViable = false;
			if (Tau2 > 0.0f)
			{
				float TimeToApex2 = LoadedJumpVelocity / Math::Abs(Gravity);
				FVector Plant2 = ClampToCourt(FVector(Strike2.X + MySign() * 35.0f, Strike2.Y, 0));
				float Sprint2 = this.BodyTravelTime((GetActorLocation() - Plant2).Size2D());
				bViable = (Tau2 - (TimeToApex2 + JumpLoadDuration)) > Sprint2 - 0.10f;
			}
			if (!bOnTwoDecided && bViable)
			{
				bOnTwoDecided = true;
				// Surprise attack more often at higher difficulty; a blocked-in
				// lane would be checked here if blockers keyed on-2 (they key
				// the third ball, which is what makes this a surprise).
				bChoseOnTwo = Math::RandRange(0.0f, 1.0f) < 0.45f + 0.35f * Difficulty;
				Log("ONTWO decided chose=" + bChoseOnTwo + " tau=" + int(Tau2 * 100));
			}
			else if (!bOnTwoDecided && !bOnTwoLoggedNotViable)
			{
				// Not viable (yet): leave undecided so a rising ball can still
				// qualify, but log why ONCE for the telemetry greps.
				bOnTwoLoggedNotViable = true;
				Log("ONTWO notViable tau=" + int(Tau2 * 100));
			}
			if (bChoseOnTwo && bViable)
			{
				ApproachForSpike(DeltaTime);
				return;
			}
			if (bChoseOnTwo && !bViable)
				bChoseOnTwo = false;   // late fallback: play the pass instead
		}

		// Decide our intended contact type. A fingerpass (set) is legal only if we
		// can get UNDER the ball with our forehead in time. We judge this against the
		// spot where the ball will be at forehead height (where we're heading) and
		// whether we can plausibly reach that spot before the ball arrives — not the
		// ball's current position, which is still mid-flight when we decide.
		EHitType Intend;
		if (Touches == 0)
		{
			Intend = EHitType::Hit_Bump;   // first touch (receive) is always a dig
		}
		else
		{
			// A fingerpass demands being comfortably UNDER the ball at forehead
			// height — in budget terms: that contact is playable with slack to
			// spare. The old check was a fixed radius; the budget knows better
			// (a slow floaty ball 3m away IS settable, a fast one 1m away isn't).
			// STICKY with hysteresis: re-deciding this from raw slack every AI
			// tick alternated Set(crouch .2)/Bump(crouch .5+) at the boundary —
			// a visible up-and-down bob while preparing the pass (which the
			// jitter monitor missed: the rise leg of the square wave stayed
			// under its rate threshold). Upgrade to Set only with real slack,
			// abandon it only when the budget has clearly failed.
			float ForeheadZ = GetActorLocation().Z + PlayerHeight * 0.9f;
			bool bPrevIntendSet = bIntendSet;
			float LogTau = 0.0f;
			if (bIntendSet)
			{
				// RETENTION: already committed — stay Set as long as the ball
				// still physically crosses forehead height ahead of us. No
				// re-litigating the travel budget against the spot we're
				// already standing at (see BallStillCrossesHeight).
				bIntendSet = this.BallStillCrossesHeight(ForeheadZ, LogTau);
			}
			else
			{
				// DECISION: full time budget before COMMITTING to a fingerpass.
				FInterceptPlan SetPlan = this.PlanIntercept(ForeheadZ, ForeheadZ);
				bIntendSet = SetPlan.bReachable && SetPlan.Slack >= 0.15f;
				LogTau = SetPlan.BallTime;
			}
			Intend = bIntendSet ? EHitType::Hit_Set : EHitType::Hit_Bump;
			if (SetIntentLogs < 50 && (bPrevIntendSet != bIntendSet || SetIntentLogs < 30))
			{
				SetIntentLogs++;
				Log("SETINTENT tau=" + int(LogTau * 100) + " intendSet=" + bIntendSet
					+ " wasSet=" + bPrevIntendSet);
			}
		}

		// Aim where we want to send it (sets the bounce direction for contact).
		// The reception pops to the setter zone; the SECOND ball is always
		// PLACED at the pin (see DoSet) no matter which stroke plays it.
		if (Touches == 0) DoDig();
		else              DoSet();

		// ONE budget decides everything below (MotionPlan.as): the highest
		// playable contact given ball time vs body time vs hand time, the
		// exact run speed the budget demands, when the reach must start, and
		// whether the ball is only reachable by diving.
		FInterceptPlan Plan = this.PlanIntercept(ContactHeightFor(Intend), FloorZ + 112.0f);

		// Desperate ball: nothing playable on foot but the dive window is open.
		if (Plan.bDive && CanDive())
		{
			StartDive(Plan.Contact - GetActorLocation());
			if (bDebugAI) Log(DebugTag() + " DIVE tau=" + int(Plan.BallTime * 100)
				+ " bodyT=" + int(Plan.BodyTime * 100));
		}
		if (IsDiving())
		{
			// The dive owns movement and facing; just keep the platform out.
			Reach(EHitType::Hit_Bump);
			return;
		}

		// PLAN vs ACTUAL: record the FIRST promise the budget made for this
		// contact (later ticks re-plan with shrinking τ and always converge to
		// slack≈0 — the informative number is what was booked at commitment).
		if (PlanSlackLog < 0.0f)
		{
			PlanSlackLog = Plan.Slack;
			PlanSpeedFracLog = Plan.SpeedFraction;
		}

		// UNCERTAINTY BUDGET: slack-rich ball — hold my expectation point (the
		// pin approach spot) in a ready stance instead of chasing the current
		// read; commit when remaining slack no longer buys the drift back.
		// τ only shrinks, so stage → go crosses exactly once — no flicker.
		if (Plan.bReachable && Plan.bStage)
		{
			MoveToHold(MyPinApproachStart(), DeltaTime, 0.6f);
			RequestCrouch(0.25f);
			FaceBall();
			return;
		}

		// Stand where the plan meets the ball — MINUS a standoff along the
		// flight chord, so the contact happens IN FRONT of the chest where the
		// platform/cup is, never on top of the head. (Chord, not live velocity:
		// the live velocity swings during the rally and churned the goal.)
		FVector PlaySpot = Plan.Contact;
		FVector Chord = FVector(PlaySpot.X - Ball.Position.X, PlaySpot.Y - Ball.Position.Y, 0);
		FVector Vel2D = FVector(Ball.BallVel.X, Ball.BallVel.Y, 0);
		float Standoff = (Intend == EHitType::Hit_Set) ? 10.0f : 35.0f;
		FVector Back = (Chord.SizeSquared() > 400.0f && Vel2D.DotProduct(Chord) > 0.0f)
			? Chord.GetSafeNormal()
			: FVector::ZeroVector;                     // vertical drop/outbound: no standoff
		FVector Goal = ClampToCourt(FVector(PlaySpot.X, PlaySpot.Y, 0) + Back * Standoff);
		float DistToGoal = (GetActorLocation() - Goal).Size2D();

		// Plant state with HYSTERESIS: the goal recomputes every tick with a
		// few cm of prediction noise, and a bare radius check flip-flopped
		// planted <-> running at tick rate — the crouch request alternated
		// with it and the knees vibrated (the jitter monitor's residual
		// crouchFlips after the chest-feedback fix).
		if (bHitterPlanted)
		{
			if (DistToGoal > PlantRadius + 35.0f) bHitterPlanted = false;
		}
		else if (DistToGoal <= PlantRadius)
			bHitterPlanted = true;

		if (!bHitterPlanted)
			MoveToward2D(Goal, DeltaTime, false, Plan.SpeedFraction);
		else
		{
			MovePlayer(FVector2D::ZeroVector);
			// Planted and waiting: LOW base. A bagger wants the centre of mass
			// down (legs set the height; the arms just hold their slope).
			RequestCrouch(Intend == EHitType::Hit_Bump ? 0.45f : 0.25f);
		}

		// The HITTER requests ball-facing. Conditional facing decided HERE (travel
		// vs ball, re-judged every AI tick) oscillated at the gate boundary,
		// whipping the chest-anchored IK targets around so the arms never
		// converged — hands ended up 80-115cm from their targets at contact. The
		// single rotation authority (UpdatePlayer) may still override this with
		// travel-facing during a genuine hurried run away from the facing
		// (turn-and-run, hysteretic, suspended once the reach gesture is live) —
		// one central, flicker-proof decision instead of many per-caller ones.
		FaceBall();

		// Wind up when the budget says the hand clock has started — no distance
		// condition: a late receive is saved by arms extending WHILE closing.
		if (Plan.bStartGesture)
			Reach(Intend);
	}

	// Distance at which we START preparing the swing/arms. Generous so the wind-up
	// has time to develop before the ball gets here.
	const float PrepareDistance = 280.0f;

	// How close (cm) we must be to the landing spot before we plant and reach.
	// Tight so we actually arrive UNDER the ball rather than stopping short — the
	// main reason passes were poor was planting half a metre off the contact spot.
	const float PlantRadius = 40.0f;

	// How close (horizontally, cm) we must be under the ball to use a fingerpass
	// (set). Beyond this we're not under it in time and must bagger instead. Widened
	// so that whenever we've actually run under a high ball we fingerpass it (better
	// height/control) instead of defaulting to a flat bagger.
	const float UnderBallRadius = 100.0f;

	// The world Z at which we want to meet the ball — stroke-aware, at the point
	// THIS body controls best. True hip-height (85cm) contact was tried and the
	// FBIK could not converge to knee-low targets in the ~0.2s the ball spends
	// there — waist height (~112cm) is where the hands arrive fastest from ready,
	// which IS the physical optimum for this rig. Sets are taken above the brow.
	private float ContactHeightFor(EHitType Intend) const
	{
		if (Intend == EHitType::Hit_Set)
			return GetActorLocation().Z + PlayerHeight * 0.9f;
		return FloorZ + 112.0f;
	}

	// Back-compat for callers that don't know the stroke yet (dig by default).
	private float ContactHeight() const
	{
		return ContactHeightFor(EHitType::Hit_Bump);
	}

	// Simulate the ball forward and return its (X,Y,Z) when it next descends to the
	// given height. If it never reaches that height (already below / rising away),
	// fall back to the ground landing prediction.
	private FVector PredictBallAtHeight(float TargetZ) const
	{
		FVector Pos;
		PredictBallTimeToHeight(TargetZ, Pos);
		return Pos;
	}

	// Same simulation, but also returns WHEN (seconds from now) the ball next
	// descends through TargetZ — the number that lets us TIME a jump or a dive
	// instead of just aiming at a spot. Returns -1 if the ball never crosses that
	// height before landing (OutPos then holds the ground landing prediction).
	protected float PredictBallTimeToHeight(float TargetZ, FVector& OutPos) const
	{
		FVector P = Ball.Position;
		FVector V = Ball.BallVel;
		const float G = -980.0f;
		const float Dt = 0.02f;
		float T = 0.0f;
		while (T < 3.0f)
		{
			V.Z += G * Dt;
			FVector Next = P + V * Dt;
			// Detect a downward crossing of TargetZ between P and Next.
			if (P.Z >= TargetZ && Next.Z <= TargetZ && V.Z < 0.0f)
			{
				OutPos = Next;
				return T + Dt;
			}
			P = Next;
			T += Dt;
			if (P.Z <= 0.0f) break;
		}
		OutPos = Ball.PredictLanding();
		return -1.0f;
	}

	private void FaceBall()
	{
		// Request facing via the single rotation authority (UpdatePlayer lerps to it)
		// rather than snapping the rotation here — snapping fought the travel-facing
		// and caused jerky spinning, especially mid-jump.
		FVector To = Ball.Position - GetActorLocation();
		To.Z = 0;
		if (To.SizeSquared() > 1.0f)
		{
			FacingDir = To.GetSafeNormal();
			bHasFacing = true;
		}
	}

	// ---------------------------------------------------------------
	// I am NOT contacting this touch — get to the right support spot.
	// Crucially, anticipate MY upcoming touch in the three-touch rhythm:
	//  - after our receive (1 touch), I'll be the setter -> go to the setter zone
	//  - after our set (2 touches), I'll be the attacker -> go to the net to spike
	// so I'm already in position when the ball comes to me.
	// ---------------------------------------------------------------
	private void PlaySupport(FVector Landing, float DeltaTime)
	{
		int Touches = TeamTouches();
		FVector Target;

		if (Touches == 1)
		{
			// Our receive is up; I set next. Get UNDER where the ball will actually
			// drop to forehead height as early as possible — not just the nominal
			// setter zone — so I'm planted under it in time to play a clean, high
			// fingerpass instead of arriving late and scrambling a bagger. Fall back
			// to the setter zone only before the receive has been hit (no useful
			// prediction yet).
			// (Handled fully in the branch below — see Touches == 1 early-out.)
			Target = HomePosition();
		}
		else if (Touches == 2)
		{
			// Our set is up and my TEAMMATE attacks (I just set it — AmIHitter
			// never gives me two touches in a row). Reset behind the hitter at the
			// role's home rather than following their approach or the ball's Y. This
			// is the stable cover point for a block rebound without needless motion.
			Target = HomePosition();
		}
		else
		{
			// First contact is somebody else's receive. Stay in the middle of the
			// assigned zone until the touch happens; only the designated hitter
			// travels to the incoming ball.
			Target = HomePosition();
		}

		// During OUR possession the supporter never ball-chases: they wait at
		// the approach start behind their OWN-half pin, because that is where
		// the next pass is coming (every pass targets the partner's pin). At
		// Touches==0 I'm the upcoming setter; at Touches==1 I'm the attacker
		// loading the approach — same spot either way.
		if (Touches == 0 || Touches == 1)
		{
			MoveToward2D(MyPinApproachStart(), DeltaTime, false, 1.0f);
			FaceBall();
			return;
		}

		// Always keep at least MinSeparation from my teammate so our team holds two
		// distinct options: whoever gets the ball can attack into open space OR pass
		// to the well-separated partner. Push my target away from the teammate along
		// the line between us until we're far enough apart.
		Target = SpreadFromTeammate(Target);

		// Take the spot and HOLD it (no constant shuffling), facing the play in a
		// ready stance once there. Repositioning is a jog FACING THE TRAVEL —
		// there's no ball to chase, just ground to cover.
		Target = ClampToCourt(Target);
		MoveToHold(Target, DeltaTime, 0.75f);
		RequestCrouch(0.18f);
		if ((Target - GetActorLocation()).Size2D() < 150.0f)
			FaceAttacker();
	}

	// Turn to face whichever teammate/opponent is about to attack (or the ball), so
	// we're oriented into the play while standing still.
	private void FaceAttacker()
	{
		// Same single-authority facing request (smooth lerp in UpdatePlayer).
		FVector Look = Ball.Position - GetActorLocation();
		Look.Z = 0;
		if (Look.SizeSquared() > 1.0f)
		{
			FacingDir = Look.GetSafeNormal();
			bHasFacing = true;
		}
	}

	// Minimum desired distance between teammates: about half the court width, so an
	// attacker always has a spike option AND a clearly separated pass option.
	const float MinSeparation = 450.0f;   // ~half of the 900cm-wide court

	// Nudge a desired position away from my teammate so we end up at least
	// MinSeparation apart. Keeps the original spot when we're already spread.
	private FVector SpreadFromTeammate(FVector Desired) const
	{
		if (Teammate == nullptr) return Desired;
		FVector Mate = Teammate.GetActorLocation();
		FVector Away = FVector(Desired.X - Mate.X, Desired.Y - Mate.Y, 0);
		float Dist = Away.Size2D();
		if (Dist >= MinSeparation) return Desired;          // already far enough

		// Too close: move out to MinSeparation along the away direction. If we're
		// almost on top of each other, push along Y (down the court) by default.
		FVector Dir = (Dist > 1.0f) ? Away.GetSafeNormal2D() : FVector(0, 1, 0);
		FVector Spread = Mate + Dir * MinSeparation;
		return FVector(Spread.X, Spread.Y, Desired.Z);
	}

	// ---------------------------------------------------------------
	// Spike approach — world-class shape: wait loaded at an approach start point
	// BEHIND the predicted strike spot, then a committed sprint through the
	// plant, jumping so the apex coincides with the ball arriving at strike
	// height. Momentum now carries through the jump (no air steering), which is
	// exactly how a real approach converts run speed into attack reach.
	// ---------------------------------------------------------------
	// Contact height for the jump attack: with the loaded jump (~115cm rise at
	// the heavy player gravity) the hands top out ~355cm at apex — strike
	// where the descending ball is slow and still inside that envelope. These
	// are real beach volleyball numbers (net 243, contact ~350).
	// Strike height DERIVED from jump physics: actor base + the loaded jump's
	// ballistic rise (v²/2g) + the rig's raised-hand reach above the actor
	// centre (the one measured constant). Retuning jump speed or gravity
	// re-derives the strike zone automatically instead of stranding a magic
	// 350 that silently stops matching the body. (Sanity: 112 + 115 + 123 ≈ 350.)
	const float StrikeReachAboveCenter = 123.0f;
	float SpikeStrikeZ() const
	{
		float Rise = (LoadedJumpVelocity * LoadedJumpVelocity) / (2.0f * Math::Abs(Gravity));
		return FloorZ + PlayerHeight + Rise + StrikeReachAboveCenter;
	}
	const float ApproachBack = 200.0f;  // run-up starts this far behind the plant

	private void ApproachForSpike(float DeltaTime)
	{
		float TimeToApex = LoadedJumpVelocity / Math::Abs(Gravity);   // ≈ 0.35s (loaded jump)

		FVector Strike;
		float Tau = PredictBallTimeToHeight(SpikeStrikeZ(), Strike);

		if (Tau < 0.0f)
		{
			// The set never gets to strike height — no jump attack available. Get
			// under where it drops to play height and hit it over instead.
			FVector PlaySpot = PredictBallAtHeight(ContactHeight());
			MoveToward2D(ClampToCourt(FVector(PlaySpot.X, PlaySpot.Y, 0)), DeltaTime);
			FaceBall();
			DoSpike();   // still aim into the opponent court
			if ((GetActorLocation() - Ball.Position).Size() < PrepareDistance)
				Reach(EHitType::Hit_Bump);
			return;
		}

		// Plant just our-side of the strike point so contact happens in front of
		// the hitting shoulder, not on top of the head.
		FVector Plant = ClampToCourt(FVector(Strike.X + MySign() * 35.0f, Strike.Y, 0));
		float DistToPlant = (GetActorLocation() - Plant).Size2D();
		// Same body-time model as the intercept budget (accel-limited + lag).
		float SprintTime = this.BodyTravelTime(DistToPlant);

		bool bGo = false;
		if (bIsGrounded)
		{
			if (Tau > SprintTime + TimeToApex + 0.25f)
			{
				// Early: wait loaded at the approach start point behind the plant —
				// coiled stance, eyes on the ball, arms QUIET until the run starts.
				FVector Start = ClampToCourt(Plant + FVector(MySign() * ApproachBack, 0, 0));
				MoveToHold(Start, DeltaTime, 0.8f);
				RequestCrouch(0.25f);
				FaceBall();
			}
			else
			{
				bGo = true;
				// GO: committed sprint TO the plant point, shoulders OPEN —
				// a right-handed hitter runs in with the left shoulder leading and
				// the chest turned ~22° off the ball line, loading the torso. The
				// body squares up through the jump (FaceBall in the air + the slow
				// rotation lerp gives exactly that uncoiling). Sprint only OUTSIDE
				// the jump radius: full-speed drive through the plant made the
				// hitter overshoot and violently shuttle back and forth over it
				// while waiting for the jump window.
				MoveToward2D(Plant, DeltaTime, DistToPlant > 90.0f);
				FVector To = Ball.Position - GetActorLocation();
				To.Z = 0;
				if (To.SizeSquared() > 1.0f)
				{
					const float OpenRad = -22.0f * PI / 180.0f;
					float C = Math::Cos(OpenRad);
					float Sn = Math::Sin(OpenRad);
					FVector N = To.GetSafeNormal();
					FacingDir = FVector(N.X * C - N.Y * Sn, N.X * Sn + N.Y * C, 0);
					bHasFacing = true;
				}
				// Leave the ground one apex-time before the ball reaches the strike
				// height; stop driving so the jump converts momentum, not input.
				// MARGIN BIAS MATTERS: an EARLY jump tops out while the ball is
				// still above the hands (a guaranteed whiff — stats2: 13 jumps, 0
				// contacts at +0.18); a LATE jump meets the ball a touch lower but
				// still inside the envelope. Keep the margin tiny so AI tick
				// jitter lands on the late (reachable) side.
				// The gather (JumpLoadDuration) happens BEFORE takeoff, so the
				// decision fires one load earlier. StartLoadedJump does the
				// plant (momentum brake — full-speed jumps drifted 3-4m past
				// the strike point) and the deep full-body sink.
				// Window sized to the decision cadence (this gate is examined
				// every ReactionDelay) but capped LATE-biased: an early jump
				// tops out above the ball and whiffs, a late one still meets
				// it inside the envelope (stats2 autopsy).
				float JumpEps = Math::Clamp(ReactionDelay * 0.4f, 0.02f, 0.05f);
				if (DistToPlant < 90.0f && Tau <= TimeToApex + JumpLoadDuration + JumpEps)
				{
					MovePlayer(FVector2D::ZeroVector);
					StartLoadedJump();
					if (bDebugAI && IsJumpLoading()) Log(DebugTag() + " SPIKE JUMP tau=" + int(Tau * 100) + " dist=" + int(DistToPlant));
				}
			}
		}
		else
		{
			// Airborne: no swimming; momentum carries us to the strike. Square the
			// shoulders to the ball — uncoiling from the open approach stance.
			MovePlayer(FVector2D::ZeroVector);
			FaceBall();
		}

		// Wind up ONLY during the committed run and the jump itself — an attacker
		// standing at the approach start with arms already loaded read as random
		// arm-raising. The IK develops backswing -> cocked -> strike as the ball
		// drops toward the strike point. The reach is asked only while the ball
		// is ABOVE the chest: once a whiffed ball has fallen past it, stop
		// asking for the spike so AutoReach can flip to a desperation bump —
		// arms stuck in spike pose can never play the low rescue.
		if ((bGo || !bIsGrounded) && Ball.Position.Z > GetActorLocation().Z + 40.0f)
		{
			DoSpike();
			Reach(EHitType::Hit_Spike);
		}
	}

	// ---------------------------------------------------------------
	// Contacts — the ball now physically bounces off the player. These set the
	// AIM target so OnBallContact (on the base player) knows where to send it.
	// ---------------------------------------------------------------
	// The shared setter target: where a receive lands and where the setter goes.
	// Central in Y (0) so the second-ball attack can go either direction, and a bit
	// off the net (so the set has room) — a high, central, attackable second ball.
	private FVector SetterZone() const
	{
		return FVector(MySign() * SetterZoneX, 0.0f, FloorZ + PlayerHeight);
	}
	const float SetterZoneX = 280.0f;

	// PLACEMENT RULE (Erik): every pass goes to one metre inside the antenna
	// on the PARTNER's half, and every player EXPECTS passes at the pin on
	// their OWN half. The halves are static per role (Front owns -Y, Back
	// owns +Y — matching HomePosition), which closes the system: the left
	// player receives toward the right pin where the partner already waits,
	// that partner plays the second ball there and passes back to the left
	// pin where the receiver-turned-attacker is loading their approach.
	// Nobody ball-chases; everyone anticipates.
	private float MyHalfPinY() const
	{
		float HalfMax = (Role == EPlayerRole::Role_Front) ? CourtMinY : CourtMaxY;
		return (HalfMax < 0.0f) ? HalfMax + 100.0f : HalfMax - 100.0f;
	}

	private FVector PartnerPinTarget() const
	{
		// Aim point = the FLOOR at the partner's pin: the ballistic target is
		// where the arc comes DOWN, so an air target let an unattacked pass
		// sail on and land ~2m out of court. Grounding it keeps the ball in
		// play if nobody touches it; the partner intercepts the same arc at
		// their contact height on its way down.
		float PartnerHalfMax = (Role == EPlayerRole::Role_Front) ? CourtMaxY : CourtMinY;
		float AimY = (PartnerHalfMax < 0.0f) ? PartnerHalfMax + 100.0f : PartnerHalfMax - 100.0f;
		return FVector(MySign() * 50.0f, AimY, 20.0f);
	}

	// Where I WAIT for the pass I'm expecting: the approach start behind my
	// own-half pin, ready to run in and attack or set whatever arrives.
	protected FVector MyPinApproachStart() const
	{
		return ClampToCourt(FVector(
			MySign() * (50.0f + ApproachBack), MyHalfPinY(), FloorZ + PlayerHeight));
	}

	private void DoDig()
	{
		AimAt(PartnerPinTarget());
	}

	private void DoSet()
	{
		AimAt(PartnerPinTarget());
	}

	private void DoSpike()
	{
		// Aim down into the opponent's open court; OnBallContact forces the angle.
		AimAt(PickAttackTarget());
	}

	// Tell the base player where to send the ball on the next physical contact.
	private void AimAt(FVector WorldTarget)
	{
		DesiredAim = WorldTarget;
		bHasAim = true;
	}

	// Aim for the opponent's open court, away from their players
	private FVector PickAttackTarget() const
	{
		float OppSign = -MySign();
		float TargetX = OppSign * Math::Lerp(350.0f, 700.0f, Difficulty);

		// Aim to whichever Y half is less defended — approximate by aiming
		// opposite our own attacker's Y, with error that shrinks with skill
		float AimY = (GetActorLocation().Y > 0) ? -250.0f : 250.0f;
		float Error = Math::RandRange(-180.0f, 180.0f) * (1.0f - Difficulty);
		AimY = Math::Clamp(AimY + Error, CourtMinY + 60.0f, CourtMaxY - 60.0f);

		return FVector(TargetX, AimY, FloorZ + BallRadiusGuess());
	}

	private float BallRadiusGuess() const { return (Ball != nullptr) ? Ball.BallRadius : 10.66f; }

	// ---------------------------------------------------------------
	// Positioning helpers
	// ---------------------------------------------------------------
	private FVector SupportPos(FVector Landing) const
	{
		float Sign = MySign();
		if (Role == EPlayerRole::Role_Front)
		{
			// Front player: stay at net ready to attack, track ball Y
			float Y = Math::Clamp(Landing.Y, CourtMinY + 100.0f, CourtMaxY - 100.0f);
			return FVector(Sign * 170.0f, Y, FloorZ + PlayerHeight);
		}
		else
		{
			// Back player: cover deep court behind the attacker
			float Y = Math::Clamp(Landing.Y * 0.5f, CourtMinY + 100.0f, CourtMaxY - 100.0f);
			return FVector(Sign * 620.0f, Y, FloorZ + PlayerHeight);
		}
	}

	// ---------------------------------------------------------------
	// Defense: the ball is on the opponent's side. Two defenders split the court
	// (one covers each Y half) UNLESS it's a clear jump-spike threat at the net —
	// then the front player blocks at the net and the back player covers the line
	// behind the block.
	// ---------------------------------------------------------------
	private void PlayDefense(float DeltaTime)
	{
		FVector Goal;
		AAIPlayer Attacker = FindAttackingOpponent();
		// Default assumption: the opponent WILL spike, so we commit to the block.
		// We only drop OFF the block once their pass/set turns out to be poor (too
		// far off the net or too low to attack) — then there's nothing to block and
		// we fall back into court defense.
		bool bAttackable = IsPassAttackable();

		if (Role == EPlayerRole::Role_Front && bAttackable)
		{
			// BLOCK, with discipline. Grounded at the net = LOW ready stance,
			// hands loaded — never arms-up statue. The block jump keys off the
			// real cue elite blockers use: the ATTACKER LEAVING THE GROUND (with a
			// fast-descending ball at the net as fallback). Arms go up only once
			// we're airborne; the IK reaches the hands to the ball.
			float NetX = MySign() * 55.0f;   // right up at the net on our side

			// Aim the block at the middle of the opponent's court so a stuffed ball
			// drops there (DesiredAim drives the hand angle in UpdateIKTargets).
			AimAt(FVector(-MySign() * 300.0f, 0.0f, FloorZ));

			AAIPlayer Att = FindAttackingOpponent();
			bool bSpikeIncoming = UpdateSpikeIncoming(Att);
			// Hold the middle of the net while the opponent is still building. Track
			// laterally only after the attack cue; following every set's small Y
			// drift was visually busy and gave up the centre for no benefit.
			float BlockY = bSpikeIncoming
				? Math::Clamp(Ball.Position.Y, CourtMinY + 60.0f, CourtMaxY - 60.0f)
				: HomePosition().Y;
			Goal = FVector(NetX, BlockY, FloorZ + PlayerHeight);

			if (bIsGrounded)
			{
				float Horiz = (GetActorLocation() - FVector(Goal.X, Goal.Y, 0)).Size2D();
				if (bSpikeIncoming && Horiz < 90.0f)
				{
					// Kill the drive FIRST so the block jump is vertical — momentum
					// carries in the air, and drifting into the net is a fault.
					// Blocks load too: the same full-body gather, matching the
					// attacker's own load delay.
					MovePlayer(FVector2D::ZeroVector);
					float HSpd = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
					if (HSpd < 90.0f)
						StartLoadedJump();
				}
				else
				{
					// Track the ball along the net in a loaded stance, hands low.
					MoveToward2D(Goal, DeltaTime, false, 0.85f);
					RequestCrouch(0.3f);
				}
			}
			else
			{
				// Airborne: hold still (no drift) and throw up the block NOW.
				MovePlayer(FVector2D::ZeroVector);
				Reach(EHitType::Hit_Block);
			}
			if (bDebugAI) Log(DebugTag() + " DEFEND BLOCK ballZ=" + int(Ball.Position.Z)
				+ " air=" + !bIsGrounded + " incoming=" + bSpikeIncoming);
			return;
		}
		else if (Role == EPlayerRole::Role_Back && bAttackable)
		{
			// Back defender starts from the centre of the deep zone. Do not mirror
			// the opponent's lateral setup; move toward that line only when the
			// attacker has actually committed to the spike.
			Goal = HomePosition();
			// Same hysteresed cue as the blocker — this copy of the raw OR moved
			// the deep defender's goal just as far, just as often.
			bool bSpikeIncoming = UpdateSpikeIncoming(Attacker);
			if (bSpikeIncoming && Attacker != nullptr)
				Goal.Y = Math::Clamp(-Attacker.GetActorLocation().Y * 0.6f,
					CourtMinY + 80.0f, CourtMaxY - 80.0f);
		}
		else
		{
			// No actual attack cue: return to the fixed base, then react when the
			// ball crosses. This replaces continuous pre-emptive roaming.
			Goal = HomePosition();
		}

		if (bDebugAI) Log(DebugTag() + " DEFEND " + (bAttackable ? "BLOCK/COVER" : "SPLIT")
			+ " ballX=" + int(Ball.Position.X) + " ballZ=" + int(Ball.Position.Z));
		// Take the defensive spot and HOLD it, facing the play — in a LOW athletic
		// base, never flat-footed upright: a defender waiting tall reads amateur.
		// Jog into position facing the travel; face up once settled.
		Goal = ClampToCourt(Goal);
		MoveToHold(Goal, DeltaTime, 0.75f);
		RequestCrouch(0.22f);
		if ((Goal - GetActorLocation()).Size2D() < 150.0f)
			FaceAttacker();
	}

	// Find the opponent who is about to hit — the one closest to the ball on the
	// other side of the net.
	private AAIPlayer FindAttackingOpponent() const
	{
		TArray<AActor> Players;
		GetAllActorsOfClass(AVolleyballPlayer, Players);
		AAIPlayer Best = nullptr;
		float BestDist = 99999.0f;
		for (AActor A : Players)
		{
			AAIPlayer P = Cast<AAIPlayer>(A);
			if (P == nullptr || P.TeamSide == TeamSide) continue;   // only opponents
			float D = (P.GetActorLocation() - Ball.Position).Size();
			if (D < BestDist) { BestDist = D; Best = P; }
		}
		return Best;
	}

	// Remembered block/drop decision, with HYSTERESIS so it doesn't flip every frame
	// (which made players run back and forth). Once committed to the block we hold it
	// until the pass is CLEARLY un-attackable; once dropped we don't re-commit until
	// the ball is CLEARLY attackable again. The two thresholds don't overlap.
	private bool bCommittedToBlock = false;

	private bool IsPassAttackable()
	{
		// A block is only ever an answer to the opponent BUILDING an attack — they
		// must have touched the ball this possession. Serves and balls we just
		// sent over are met in receive formation, never at the net (nobody blocks
		// a serve; committing the front player to the net against serves forced a
		// hopeless 3m backpedal whenever the serve turned out to be his).
		ABeachVolleyballGameState GSB = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		ETeam Opp = (TeamSide == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
		if (GSB == nullptr || GSB.LastTouchTeam != Opp || GSB.TouchesThisRally < 1)
		{
			bCommittedToBlock = false;
			return false;
		}

		float BallOffNet = Math::Abs(Ball.Position.X);
		float BallZ = Ball.Position.Z;
		bool bOpponentSide = (TeamSide == ETeam::Team_A) ? Ball.Position.X > -50.0f
		                                                 : Ball.Position.X <  50.0f;

		if (!bOpponentSide)
		{
			bCommittedToBlock = false;
			return false;
		}

		if (bCommittedToBlock)
		{
			// Stay on the block until the pass is clearly bad: well off the net OR
			// dropped low. Wide margins so small ball motion doesn't drop the block.
			if (BallOffNet > 420.0f || BallZ < 110.0f)
				bCommittedToBlock = false;
		}
		else
		{
			// Commit to the block only when the ball is clearly a real attack setup:
			// near the net and high. Tighter than the drop thresholds (hysteresis gap).
			if (BallOffNet < 300.0f && BallZ > 170.0f)
				bCommittedToBlock = true;
		}

		return bCommittedToBlock;
	}

	// ---------------------------------------------------------------
	// Queries
	// ---------------------------------------------------------------
	private float MySign() const { return (TeamSide == ETeam::Team_A) ? -1.0f : 1.0f; }

	private int TeamTouches() const
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return 0;
		// Only count touches that belong to our team this rally
		if (GS.LastTouchTeam == TeamSide) return GS.TouchesThisRally;
		return 0;  // ball just crossed to us — this is our receive (touch 0)
	}

	// Should our team actively go play the ball right now? Only when the ball is
	// genuinely on our side of the net — not while it's still high over the
	// opponent's court (even if it's predicted to eventually cross to us).
	private bool IsBallComingToMySide() const
	{
		bool bBallOnMySide = (TeamSide == ETeam::Team_A) ? Ball.Position.X <= 0.0f
		                                                 : Ball.Position.X >= 0.0f;

		// If the ball is physically on our side, it's ours to play.
		if (bBallOnMySide) return true;

		// Ball is on the opponent's side. Only commit early if it has clearly
		// crossed toward us (moving to our side AND already low enough that the
		// predicted landing is on our court) — otherwise hold and defend.
		bool bMovingToMe = (TeamSide == ETeam::Team_A) ? Ball.BallVel.X < -50.0f
		                                               : Ball.BallVel.X >  50.0f;
		if (!bMovingToMe) return false;

		FVector Landing = Ball.PredictLanding();
		bool bLandMine = (TeamSide == ETeam::Team_A) ? Landing.X <= 0.0f
		                                             : Landing.X >= 0.0f;
		if (!bLandMine) return false;

		// If the opponent will NOT touch this ball again — it's a serve in
		// flight, or their third (final) touch is already over — CHARGE NOW.
		// The receive needs every tenth of flight time: waiting for the ball to
		// reach the net gave the receiver 0.35s to cover the last 1.4m and made
		// clean serves into aces. While they're still building (touches 1-2),
		// hold the defensive shape until the ball is actually near the net.
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS != nullptr)
		{
			ETeam Opp = (TeamSide == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
			bool bServeIncoming = (GS.LastTouchTeam == ETeam::Team_None && GS.ServingTeam == Opp);
			bool bAttackOver = (GS.LastTouchTeam == Opp && GS.TouchesThisRally >= 3);
			if (bServeIncoming || bAttackOver) return true;
		}
		// Require the ball to be near or past the net before charging in.
		return Math::Abs(Ball.Position.X) < 250.0f;
	}

	private bool IsDeep(float X) const
	{
		if (TeamSide == ETeam::Team_A) return X < -350.0f;
		return X > 350.0f;
	}

	// Horizontal reach to the ball's current position
	private bool IsWithinReach() const
	{
		FVector ToBall = Ball.Position - GetActorLocation();
		return ToBall.Size2D() < 110.0f;
	}

	private FVector ClampToCourt(FVector P) const
	{
		return FVector(
			Math::Clamp(P.X, CourtMinX + 40.0f, CourtMaxX - 40.0f),
			Math::Clamp(P.Y, CourtMinY + 40.0f, CourtMaxY - 40.0f),
			FloorZ + PlayerHeight);
	}

	// ---------------------------------------------------------------
	// Movement (no auto-jump here — jumping is decided by spike logic)
	// ---------------------------------------------------------------
	// --- Spike-incoming cue, with the same commit/release discipline every other
	// decision in here already has ------------------------------------------
	// This was a raw OR of three threshold tests, re-evaluated every AI tick. All
	// three inputs (attacker airborne, ball near net, ball descending fast) can
	// cross back and forth within one flight, and a single toggle moves the block
	// goal from the net centre out to the ball's Y — up to 2.7m. That is far past
	// MoveToHold's 110cm StartMoving, so the hold releases and the player runs,
	// then runs back. No existing detector saw it: the run itself is perfectly
	// smooth, so neither velocity nor yaw ever reverses. It shows up as goalJumps.
	//
	// Bands do not overlap, matching the block-commitment pattern below: commit on
	// the real cue, release only when the ball is clearly no longer an attack.
	private bool bSpikeCueOn = false;
	private bool UpdateSpikeIncoming(AAIPlayer Att)
	{
		bool bAttackerAirborne = (Att != nullptr && !Att.bIsGrounded);
		float BallX = Math::Abs(Ball.Position.X);
		float BallZ = Ball.Position.Z;

		if (!bSpikeCueOn)
		{
			// Commit: the attacker has left the ground with the ball at the net, or
			// the ball is already coming down hard.
			bool bNearNet = BallX < 350.0f && BallZ > 220.0f;
			if ((bAttackerAirborne && bNearNet) || (bNearNet && Ball.BallVel.Z < -250.0f))
				bSpikeCueOn = true;
		}
		else
		{
			// Release on a wider band, so the small drifts that flipped the raw
			// test cannot un-commit us mid-approach.
			if (BallX > 480.0f || BallZ < 150.0f)
				bSpikeCueOn = false;
		}
		return bSpikeCueOn;
	}

	private void MoveToward2D(FVector Target, float Dt, bool bSprint = false, float SpeedCap = 1.0f)
	{
		ReportMoveGoal(Target);
		FVector Dir = Target - GetActorLocation();
		Dir.Z = 0;
		float D = Dir.Size2D();
		// The stop zone must exceed the braking distance from the slowest arrive
		// speed (GroundDecel brakes ~9cm from 250cm/s) — an 8cm zone made the
		// player overshoot, flip direction and shake at frame rate on the spot.
		if (D <= 25.0f)
		{
			MovePlayer(FVector2D::ZeroVector);
			return;
		}

		// Pros decelerate INTO position (gather step) instead of running full tilt
		// and stopping dead — except on a committed spike approach (bSprint).
		// SpeedCap lets callers hustle only as fast as the situation demands.
		float Scale = bSprint ? 1.0f : Math::Min(Math::Clamp(D / 150.0f, 0.25f, 1.0f), SpeedCap);

		// During the split step the feet are planted; only a tiny shuffle allowed.
		if (SplitStepTimer > 0.0f)
			Scale *= 0.12f;

		FVector N = Dir.GetSafeNormal2D();
		MovePlayer(FVector2D(N.X * Scale, N.Y * Scale));
	}

	// --- Split step: the signature read-and-react habit of elite defenders — a
	// quick loading dip with planted feet the instant the OPPONENT strikes the
	// ball (or the serve launches), THEN explode toward the read.
	protected float SplitStepTimer = 0.0f;
	const float SplitStepDuration = 0.26f;
	private int PrevTouchStamp = -1;
	private bool bPrevBallInPlay = false;

	protected void UpdateSplitStep(float Dt)
	{
		// The split step is the anticipatory READ load — it belongs BEFORE the
		// approach, not on top of a committed contact. Once we're actively
		// reaching for this ball the reach/RequestCrouch stance owns the hips;
		// letting the dip's rise phase overlap the dig produced a fast up-down
		// bob right at the meet on quick balls (the read hadn't finished before
		// contact). Cancel it the moment we commit — a real player who has no
		// time to gather simply skips the hop.
		if (bReaching)
			SplitStepTimer = 0.0f;

		if (SplitStepTimer > 0.0f)
		{
			SplitStepTimer -= Dt;
			// Dip envelope: sink and rise over the duration.
			float Prog = 1.0f - SplitStepTimer / SplitStepDuration;
			ExtraCrouch = Math::Max(ExtraCrouch, 0.5f * Math::Sin(Prog * PI));
		}
		if (Ball == nullptr) return;

		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;

		// Serve launch: the ball just went live against us.
		if (Ball.bInPlay && !bPrevBallInPlay && GS.ServingTeam != TeamSide)
			SplitStepTimer = SplitStepDuration;
		bPrevBallInPlay = Ball.bInPlay;

		// Opponent contact: their touch team/count just changed. But a defender
		// split-steps ONCE, on the ATTACKER'S swing — not on every touch of their
		// possession. Firing on their receive AND set AND attack stacked three
		// dips in a row and read as the body shaking up and down before we ever
		// dug the ball. The attack is the touch that DRIVES THE BALL TOWARD US;
		// their own-side receive/set keep it on their court (X small or away), so
		// gate on the post-contact velocity heading to our side. The serve above
		// is the serve-phase equivalent of that same read.
		int Stamp = int(GS.LastTouchTeam) * 100 + GS.TouchesThisRally;
		if (Stamp != PrevTouchStamp)
		{
			bool bOpponentHit = GS.LastTouchTeam != TeamSide
				&& GS.LastTouchTeam != ETeam::Team_None && Ball.bInPlay;
			// Ball now driving to our side (their attack), not along their own.
			bool bDrivenAtUs = (TeamSide == ETeam::Team_A)
				? Ball.BallVel.X < -150.0f : Ball.BallVel.X > 150.0f;
			if (bOpponentHit && bDrivenAtUs)
				SplitStepTimer = SplitStepDuration;
			PrevTouchStamp = Stamp;
		}
	}

	// Positional "hold": move to the target, but once we arrive STAY PUT until the
	// target drifts well away. This kills the constant micro-shuffling during
	// defense/support — you take your spot, face up, and stand still. Hysteresis:
	// start moving only past StartMoving, stop as soon as within Arrived.
	private bool bHolding = false;
	protected void MoveToHold(FVector Target, float Dt, float SpeedCap = 1.0f)
	{
		// Report here too, not just via MoveToward2D: while holding, a target that
		// teleports never reaches MoveToward2D at all until the hold breaks, and
		// that break is exactly the event worth counting.
		ReportMoveGoal(Target);
		const float StartMoving = 110.0f;   // must drift this far before we re-chase
		const float Arrived     = 35.0f;    // close enough — plant and hold
		float D = (Target - GetActorLocation()).Size2D();

		if (bHolding)
		{
			if (D > StartMoving) bHolding = false;   // target moved a lot; reposition
		}
		else
		{
			if (D <= Arrived) bHolding = true;        // arrived; lock in place
		}

		if (bHolding)
			MovePlayer(FVector2D::ZeroVector);        // stand still
		else
			MoveToward2D(Target, Dt, false, SpeedCap);
	}

	// ---------------------------------------------------------------
	// The base player registers the touch when the ball physically bounces off
	// us; we just record that it was us, so the teammate takes the next contact.
	void OnTouchRegistered() override
	{
		bIMadeLastTouch = true;
		if (Teammate != nullptr)
			Teammate.bIMadeLastTouch = false;
	}

	// No two contacts in a row — I'm transparent to the ball right after I hit it.
	bool CanContactBall() const override
	{
		return !bIMadeLastTouch;
	}

	protected void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
