from app.services.diet_phase import weekly_adjustment


def test_weekly_adjustment_no_data_has_no_suggestion():
    result = weekly_adjustment(
        current_avg=None,
        previous_avg=None,
        phase_type="cut",
        target_rate_pct=0.7,
    )

    assert result["status"] == "no_data"
    assert result["actual_rate_pct"] is None
    assert result["suggestion"] is None
    assert result["cal_adjustment"] == 0
