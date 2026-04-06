"""Reproduce: sets 2/3 incrementing by 2 reps instead of 1."""
import pytest
from httpx import AsyncClient
from tests.conftest import create_exercise, create_plan, start_session_from_plan, log_set

pytestmark = pytest.mark.asyncio(loop_scope="function")


class TestOverloadDelta:
    @pytest.mark.parametrize("style", ["rep", "weight", "double"])
    async def test_per_set_delta_is_one(self, client: AsyncClient, style: str):
        """Each set should increment by at most 1 rep from its prior actual,
        regardless of overload style.  Sets 2/3 should NOT jump by 2.
        """
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)

        # Week 1: all sets at 100kg x 8
        w1 = await start_session_from_plan(client, plan["id"], overload_style=style)
        for s in w1["sets"]:
            await log_set(client, w1["id"], s["id"], 100.0, 8)

        # Week 2: overloaded from week 1
        w2 = await start_session_from_plan(client, plan["id"], overload_style=style)
        w2_by = {s["set_number"]: s for s in w2["sets"]}
        print(f"\n[{style}] Week 2 suggestions:")
        for sn in [1, 2, 3]:
            print(f"  Set {sn}: weight={w2_by[sn]['planned_weight_kg']}, reps={w2_by[sn]['planned_reps']}")

        # Simulate fatigue: set 1 hits target, sets 2/3 miss by 1
        w2_actuals = {}
        for s in sorted(w2["sets"], key=lambda x: x["set_number"]):
            sn = s["set_number"]
            target = s["planned_reps"] or 8
            actual = target if sn == 1 else target - 1
            w2_actuals[sn] = actual
            await log_set(client, w2["id"], s["id"], s["planned_weight_kg"] or 100.0, actual)

        print(f"  Logged actuals: {w2_actuals}")

        # Week 3: overloaded from week 2
        w3 = await start_session_from_plan(client, plan["id"], overload_style=style)
        w3_by = {s["set_number"]: s for s in w3["sets"]}
        print("  Week 3 suggestions:")
        for sn in [1, 2, 3]:
            w3r = w3_by[sn]["planned_reps"]
            actual_prev = w2_actuals[sn]
            delta = (w3r - actual_prev) if w3r is not None else None
            print(f"  Set {sn}: reps={w3r}, delta from actual {actual_prev} = {delta}")
            if w3r is not None:
                assert delta <= 1, (
                    f"[{style}] Set {sn}: rep delta from prior actual ({actual_prev}) "
                    f"is {delta} (suggested {w3r}), expected at most +1"
                )

    async def test_hit_target_all_sets_then_fatigue(self, client: AsyncClient):
        """If user hits all targets in week 2, then fatigues in week 3,
        the delta should still be at most +1.
        """
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)

        # Week 1: all 8s
        w1 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        for s in w1["sets"]:
            await log_set(client, w1["id"], s["id"], 100.0, 8)

        # Week 2: user hits ALL targets
        w2 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w2_by = {s["set_number"]: s for s in w2["sets"]}
        print("\nWeek 2 suggestions:")
        w2_actuals = {}
        for sn in [1, 2, 3]:
            reps = w2_by[sn]["planned_reps"] or 8
            weight = w2_by[sn]["planned_weight_kg"] or 100.0
            print(f"  Set {sn}: weight={weight}, reps={reps}")
            await log_set(client, w2["id"], w2_by[sn]["id"], weight, reps)
            w2_actuals[sn] = reps

        # Week 3: set 1 hits, sets 2/3 miss by 1
        w3 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w3_by = {s["set_number"]: s for s in w3["sets"]}
        print("Week 3 suggestions:")
        for sn in [1, 2, 3]:
            planned = w3_by[sn]["planned_reps"]
            delta = (planned - w2_actuals[sn]) if planned else None
            print(f"  Set {sn}: reps={planned}, delta from actual {w2_actuals[sn]} = {delta}")
            if planned is not None and delta is not None:
                assert delta <= 1, (
                    f"Set {sn}: delta {delta} > 1 (prev actual={w2_actuals[sn]}, suggested={planned})"
                )

    async def test_varying_reps_across_sets_week1(self, client: AsyncClient):
        """Week 1: user does different reps per set (e.g. 10, 8, 7).
        Week 2 should increment each set by +1 from its own actual.
        """
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)

        for style in ["weight", "double"]:
            print(f"\n=== {style} ===")
            # Week 1
            w1 = await start_session_from_plan(client, plan["id"], overload_style=style)
            w1_by = {s["set_number"]: s for s in w1["sets"]}
            w1_actuals = {1: 10, 2: 8, 3: 7}
            for sn in [1, 2, 3]:
                await log_set(client, w1["id"], w1_by[sn]["id"], 100.0, w1_actuals[sn])

            # Week 2
            w2 = await start_session_from_plan(client, plan["id"], overload_style=style)
            w2_by = {s["set_number"]: s for s in w2["sets"]}
            print(f"  Week 2 (from {w1_actuals}):")
            for sn in [1, 2, 3]:
                reps = w2_by[sn]["planned_reps"]
                delta = (reps - w1_actuals[sn]) if reps else None
                print(f"    Set {sn}: reps={reps}, delta from actual {w1_actuals[sn]} = {delta}")
                # For weight style, delta might be 0 or negative (weight goes up, reps reset)
                # For double, should be +1
                if style == "double" and reps is not None and delta is not None:
                    assert delta <= 1, f"Set {sn}: delta {delta} > 1"

    @pytest.mark.parametrize("style", ["weight", "double", "rep"])
    async def test_week1_null_planned_then_overload(self, client: AsyncClient, style: str):
        """Week 1 has NULL planned_reps. When overload logic sees prior_planned=None,
        it should set planned=prior_reps, so delta is +1 from actual for all sets.

        Then week 2 has planned_reps set. If user misses on set 2/3,
        week 3 should be +1 from actual, NOT +2.
        """
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)

        for style in [style]:
            print(f"\n=== {style} ===")
            # Week 1: planned_reps are NULL (no prior)
            w1 = await start_session_from_plan(client, plan["id"], overload_style=style)
            w1_by = {s["set_number"]: s for s in w1["sets"]}

            # Verify week 1 has no planned reps
            for sn in [1, 2, 3]:
                assert w1_by[sn]["planned_reps"] is None, f"Week 1 set {sn} should have NULL planned_reps"

            # Log: set 1=10, set 2=8, set 3=7 (different reps per set)
            w1_actuals = {1: 10, 2: 8, 3: 7}
            for sn in [1, 2, 3]:
                await log_set(client, w1["id"], w1_by[sn]["id"], 100.0, w1_actuals[sn])

            # Week 2: should be overloaded from week 1 actuals
            w2 = await start_session_from_plan(client, plan["id"], overload_style=style)
            w2_by = {s["set_number"]: s for s in w2["sets"]}
            print(f"  Week 2 (from actuals {w1_actuals}):")
            for sn in [1, 2, 3]:
                reps = w2_by[sn]["planned_reps"]
                w = w2_by[sn]["planned_weight_kg"]
                delta = (reps - w1_actuals[sn]) if reps else None
                print(f"    Set {sn}: weight={w}, reps={reps}, delta from actual {w1_actuals[sn]} = {delta}")

            # Now user does week 2: set 1 hits, set 2/3 miss by 1
            w2_actuals = {}
            for sn in [1, 2, 3]:
                target = w2_by[sn]["planned_reps"] or 8
                actual = target if sn == 1 else target - 1
                w2_actuals[sn] = actual
                await log_set(client, w2["id"], w2_by[sn]["id"],
                             w2_by[sn]["planned_weight_kg"] or 100.0, actual)

            print(f"  Logged week 2 actuals: {w2_actuals}")

            # Week 3
            w3 = await start_session_from_plan(client, plan["id"], overload_style=style)
            w3_by = {s["set_number"]: s for s in w3["sets"]}
            print("  Week 3:")
            for sn in [1, 2, 3]:
                reps = w3_by[sn]["planned_reps"]
                delta = (reps - w2_actuals[sn]) if reps else None
                print(f"    Set {sn}: reps={reps}, delta from actual {w2_actuals[sn]} = {delta}")

    async def test_weight_first_long_chain_5_weeks(self, client: AsyncClient):
        """Weight-first over 5 weeks with realistic fatigue: set 1 always hits,
        sets 2/3 usually miss by 1. Every week's delta should be at most +1
        from the prior actual.
        """
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)

        # Week 1
        w = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w_by = {s["set_number"]: s for s in w["sets"]}
        w1_actuals = {1: 8, 2: 7, 3: 6}
        for sn in [1, 2, 3]:
            await log_set(client, w["id"], w_by[sn]["id"], 100.0, w1_actuals[sn])
        prev_actuals = w1_actuals
        print(f"\nWeek 1: logged actuals = {w1_actuals}")

        for week in range(2, 7):
            w = await start_session_from_plan(client, plan["id"], overload_style="weight")
            w_by = {s["set_number"]: s for s in w["sets"]}

            print(f"\nWeek {week}:")
            actuals = {}
            for sn in [1, 2, 3]:
                planned_reps = w_by[sn]["planned_reps"]
                planned_weight = w_by[sn]["planned_weight_kg"]
                delta = (planned_reps - prev_actuals[sn]) if planned_reps else None
                print(f"  Set {sn}: weight={planned_weight}, reps={planned_reps}, "
                      f"prev_actual={prev_actuals[sn]}, delta={delta}")

                if planned_reps is not None and delta is not None:
                    assert delta <= 1, (
                        f"Week {week} Set {sn}: delta {delta} > 1! "
                        f"(prev actual={prev_actuals[sn]}, suggested={planned_reps})"
                    )

                # Set 1 always hits; sets 2/3 miss by 1
                actual = planned_reps if sn == 1 else max(1, (planned_reps or 8) - 1)
                actuals[sn] = actual
                await log_set(client, w["id"], w_by[sn]["id"],
                              planned_weight or 100.0, actual)

            print(f"  Logged actuals: {actuals}")
            prev_actuals = actuals

    async def test_weight_first_set23_exceed_planned(self, client: AsyncClient):
        """Weight-first: if sets 2/3 exceed their planned reps, the next
        session should still be +1 from actual, not from planned.
        """
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)

        # Week 1
        w1 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w1_by = {s["set_number"]: s for s in w1["sets"]}
        for sn in [1, 2, 3]:
            await log_set(client, w1["id"], w1_by[sn]["id"], 100.0, 8)

        # Week 2: all sets exceed their planned target
        w2 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w2_by = {s["set_number"]: s for s in w2["sets"]}
        w2_actuals = {}
        print("\nWeek 2:")
        for sn in [1, 2, 3]:
            planned = w2_by[sn]["planned_reps"] or 8
            # User does 2 more than planned on every set
            actual = planned + 2
            w2_actuals[sn] = actual
            print(f"  Set {sn}: planned={planned}, actual={actual}")
            await log_set(client, w2["id"], w2_by[sn]["id"],
                          w2_by[sn]["planned_weight_kg"] or 100.0, actual)

        # Week 3
        w3 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w3_by = {s["set_number"]: s for s in w3["sets"]}
        print("Week 3 suggestions:")
        for sn in [1, 2, 3]:
            planned = w3_by[sn]["planned_reps"]
            weight = w3_by[sn]["planned_weight_kg"]
            delta = (planned - w2_actuals[sn]) if planned else None
            print(f"  Set {sn}: weight={weight}, reps={planned}, "
                  f"prev_actual={w2_actuals[sn]}, delta={delta}")

    async def test_weight_first_exceeds_then_misses(self, client: AsyncClient):
        """Edge case: user exceeds planned on set 2/3, then misses next time.

        Week 1: planned=None, actual=8 for all
        Week 2: planned=9 for all (from overload). User does: set1=9, set2=10 (exceeds!), set3=10
        Week 3: The planned_reps for set2/3 should be +1 from actual (11),
                NOT +2 from planned (9+2=11). Both happen to give the same answer
                here, but the key is that the delta from actual is always +1.

        But then if in Week 3 user does: set2=9 (misses the 11 target)
        Week 4: set2 should be min(9+1, 11) = 10. That's +1 from actual.
                From planned perspective: 11→10 = -1 (going down is fine).
        """
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)

        # Week 1
        w1 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        for s in w1["sets"]:
            await log_set(client, w1["id"], s["id"], 40.0, 8)  # light weight

        # Week 2
        w2 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w2_by = {s["set_number"]: s for s in w2["sets"]}
        print("\nWeek 2 suggestions:")
        for sn in [1, 2, 3]:
            print(f"  Set {sn}: reps={w2_by[sn]['planned_reps']}, weight={w2_by[sn]['planned_weight_kg']}")

        # User exceeds on sets 2/3
        actuals_w2 = {1: w2_by[1]["planned_reps"], 2: (w2_by[2]["planned_reps"] or 8) + 2, 3: (w2_by[3]["planned_reps"] or 8) + 2}
        for sn in [1, 2, 3]:
            await log_set(client, w2["id"], w2_by[sn]["id"],
                         w2_by[sn]["planned_weight_kg"] or 40.0, actuals_w2[sn])
        print(f"  Logged: {actuals_w2}")

        # Week 3
        w3 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w3_by = {s["set_number"]: s for s in w3["sets"]}
        print("Week 3 suggestions:")
        for sn in [1, 2, 3]:
            reps = w3_by[sn]["planned_reps"]
            delta_from_actual = (reps - actuals_w2[sn]) if reps else None
            delta_from_planned = (reps - (w2_by[sn]["planned_reps"] or 8)) if reps else None
            print(f"  Set {sn}: reps={reps}, delta_from_actual={delta_from_actual}, delta_from_planned={delta_from_planned}")
            if reps is not None and delta_from_actual is not None:
                assert delta_from_actual <= 1, (
                    f"Set {sn}: delta from actual {actuals_w2[sn]} is {delta_from_actual}, expected <= 1"
                )

    async def test_weight_first_light_weight_5_weeks(self, client: AsyncClient):
        """Weight-first with light weights (< ~47kg) where Epley bump doesn't
        always trigger. Reps should still never jump more than +1 from actual.
        """
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)

        # Week 1: 30kg x 8 for all
        w = await start_session_from_plan(client, plan["id"], overload_style="weight")
        for s in w["sets"]:
            await log_set(client, w["id"], s["id"], 30.0, 8)
        prev_actuals = {1: 8, 2: 8, 3: 8}
        print(f"\nWeek 1: logged {prev_actuals} @ 30kg")

        for week in range(2, 7):
            w = await start_session_from_plan(client, plan["id"], overload_style="weight")
            w_by = {s["set_number"]: s for s in w["sets"]}

            print(f"\nWeek {week}:")
            actuals = {}
            for sn in [1, 2, 3]:
                reps = w_by[sn]["planned_reps"]
                weight = w_by[sn]["planned_weight_kg"]
                delta = (reps - prev_actuals[sn]) if reps else None
                print(f"  Set {sn}: w={weight}, r={reps}, prev_actual={prev_actuals[sn]}, delta={delta}")

                if reps is not None and delta is not None:
                    assert delta <= 1, (
                        f"Week {week} Set {sn}: delta {delta} > 1! "
                        f"(prev_actual={prev_actuals[sn]}, suggested={reps})"
                    )

                # Set 1 hits, sets 2/3 miss by 1
                actual = reps if sn == 1 else max(1, (reps or 8) - 1)
                actuals[sn] = actual
                await log_set(client, w["id"], w_by[sn]["id"], weight or 30.0, actual)

            print(f"  Logged: {actuals}")
            prev_actuals = actuals

    async def test_weight_first_independent_per_set(self, client: AsyncClient):
        """Weight-first: each set progresses independently.
        188.24 x 7,6,5 (plan target=7):
          Set 1 (hit): weight bumps via Epley, reps reset to 7
          Set 2 (missed): same weight, reps +1 from actual (7)
          Set 3 (missed): same weight, reps +1 from actual (6)
        """
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=7)

        # Week 1: 188.24kg x 7,6,5
        w1 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w1_by = {s["set_number"]: s for s in w1["sets"]}
        await log_set(client, w1["id"], w1_by[1]["id"], 188.24, 7)
        await log_set(client, w1["id"], w1_by[2]["id"], 188.24, 6)
        await log_set(client, w1["id"], w1_by[3]["id"], 188.24, 5)

        # Week 2: each set independently
        w2 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w2_by = {s["set_number"]: s for s in w2["sets"]}

        print("\nWeek 2 (from 188.24 x 7,6,5):")
        for sn in [1, 2, 3]:
            w = w2_by[sn]["planned_weight_kg"]
            r = w2_by[sn]["planned_reps"]
            print(f"  Set {sn}: weight={w}, reps={r}")

        # Set 1 (hit target=7): weight bumps, reps reset
        assert w2_by[1]["planned_weight_kg"] > 188.24, "Set 1 weight should increase"
        assert w2_by[1]["planned_reps"] == 7, f"Set 1 reps should reset to 7, got {w2_by[1]['planned_reps']}"

        # Set 2 (missed, 6 < 7): same weight, +1 rep
        assert w2_by[2]["planned_weight_kg"] == 188.24, \
            f"Set 2 weight should stay at 188.24, got {w2_by[2]['planned_weight_kg']}"
        assert w2_by[2]["planned_reps"] == 7, \
            f"Set 2 reps should be 7 (+1 from 6), got {w2_by[2]['planned_reps']}"

        # Set 3 (missed, 5 < 7): same weight, +1 rep
        assert w2_by[3]["planned_weight_kg"] == 188.24, \
            f"Set 3 weight should stay at 188.24, got {w2_by[3]['planned_weight_kg']}"
        assert w2_by[3]["planned_reps"] == 6, \
            f"Set 3 reps should be 6 (+1 from 5), got {w2_by[3]['planned_reps']}"

    async def test_weight_first_no_bump_reps_still_progress(self, client: AsyncClient):
        """Weight-first: when set 1 does NOT trigger a weight bump (e.g. all sets
        missed or weight-first falls back to rep accumulation), sets 2/3 should
        still get +1 rep normally since there's no weight increase to double-dip.
        """
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)

        # Week 1: light weight where bump won't trigger easily
        # All sets MISS their target
        w1 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w1_by = {s["set_number"]: s for s in w1["sets"]}
        await log_set(client, w1["id"], w1_by[1]["id"], 100.0, 6)  # missed
        await log_set(client, w1["id"], w1_by[2]["id"], 100.0, 5)  # missed
        await log_set(client, w1["id"], w1_by[3]["id"], 100.0, 4)  # at floor

        # Week 2: since set 1 missed, weight shouldn't bump. Reps should be +1 each.
        w2 = await start_session_from_plan(client, plan["id"], overload_style="weight")
        w2_by = {s["set_number"]: s for s in w2["sets"]}

        print("\nWeek 2 (all missed, from 100 x 6,5,4):")
        for sn in [1, 2, 3]:
            w = w2_by[sn]["planned_weight_kg"]
            r = w2_by[sn]["planned_reps"]
            print(f"  Set {sn}: weight={w}, reps={r}")

        # Weight should be same (100) — no bump since set 1 missed
        assert w2_by[1]["planned_weight_kg"] == 100.0, \
            f"Weight should stay at 100 when set 1 missed, got {w2_by[1]['planned_weight_kg']}"

        # Reps should progress +1 from actual since no weight change
        assert w2_by[1]["planned_reps"] == 7, f"Set 1: expected 7, got {w2_by[1]['planned_reps']}"
        assert w2_by[2]["planned_reps"] == 6, f"Set 2: expected 6, got {w2_by[2]['planned_reps']}"
        assert w2_by[3]["planned_reps"] == 5, f"Set 3: expected 5, got {w2_by[3]['planned_reps']}"

    async def test_multi_week_accumulation(self, client: AsyncClient):
        """Run 4 weeks with consistent fatigue pattern and check no set drifts by +2."""
        ex = await create_exercise(client)
        plan = await create_plan(client, ex["id"], sets=3, reps=8)
        style = "weight"

        prev_actuals = {1: 8, 2: 8, 3: 8}

        # Week 1
        w = await start_session_from_plan(client, plan["id"], overload_style=style)
        for s in w["sets"]:
            await log_set(client, w["id"], s["id"], 100.0, 8)

        for week in range(2, 5):
            w = await start_session_from_plan(client, plan["id"], overload_style=style)
            w_by = {s["set_number"]: s for s in w["sets"]}

            print(f"\nWeek {week}:")
            actuals = {}
            for sn in [1, 2, 3]:
                planned = w_by[sn]["planned_reps"]
                weight = w_by[sn]["planned_weight_kg"]
                delta = (planned - prev_actuals[sn]) if planned else None
                print(f"  Set {sn}: weight={weight}, reps={planned}, "
                      f"delta from prev actual ({prev_actuals[sn]}) = {delta}")

                if planned is not None and delta is not None:
                    assert delta <= 1, (
                        f"Week {week} Set {sn}: delta {delta} > 1 "
                        f"(prev actual={prev_actuals[sn]}, suggested={planned})"
                    )

                # Simulate: set 1 hits, sets 2/3 miss by 1
                actual = planned if sn == 1 else max(1, (planned or 8) - 1)
                actuals[sn] = actual
                await log_set(client, w["id"], w_by[sn]["id"],
                              weight or 100.0, actual)

            prev_actuals = actuals
